#!/usr/bin/env python3
"""Focused tests for the staging download server and PS1 publication."""

from __future__ import annotations

import functools
import importlib.util
from pathlib import Path
import os
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request


REPO_ROOT = Path(__file__).resolve().parents[3]
SERVER_PATH = REPO_ROOT / "deploy" / "server.py"
SPEC = importlib.util.spec_from_file_location("qemu_stage_server", SERVER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {SERVER_PATH}")
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


class QuietHandler(SERVER.Utf8Handler):
    def log_message(self, fmt, *args):
        pass


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "guest"
        self.stage = self.root / "staging"
        self.source.mkdir()
        self.stage.mkdir()
        self.original_script_src = SERVER.SCRIPT_SRC
        SERVER.SCRIPT_SRC = str(self.source)

    def tearDown(self):
        SERVER.SCRIPT_SRC = self.original_script_src
        self.temporary.cleanup()

    def test_sync_is_content_based_and_atomic(self):
        source = self.source / "setup-winrm.ps1"
        destination = self.stage / source.name
        source.write_bytes(b"new audited script\n")
        destination.write_bytes(b"stale but newer script\n")
        future = time.time() + 3600
        os.utime(destination, (future, future))
        old_inode = destination.stat().st_ino

        self.assertEqual(SERVER.sync_scripts(str(self.stage)), [source.name])
        self.assertEqual(destination.read_bytes(), source.read_bytes())
        self.assertNotEqual(destination.stat().st_ino, old_inode)
        self.assertEqual(list(self.stage.glob(f".{source.name}.*.tmp")), [])

        os.utime(destination, (future, future))
        unchanged_stat = destination.stat()
        self.assertEqual(SERVER.sync_scripts(str(self.stage)), [])
        self.assertEqual(destination.stat().st_ino, unchanged_stat.st_ino)
        self.assertEqual(destination.stat().st_mtime_ns,
                         unchanged_stat.st_mtime_ns)

        external = self.root / "external.ps1"
        external.write_bytes(source.read_bytes())
        destination.unlink()
        destination.symlink_to(external)
        self.assertEqual(SERVER.sync_scripts(str(self.stage)), [source.name])
        self.assertFalse(destination.is_symlink())
        self.assertEqual(destination.read_bytes(), source.read_bytes())

    def test_download_allowlist_boundary(self):
        safe_assets = {
            "setup-winrm.ps1": b"Write-Host safe\n",
            "driver-package.zip": b"ordinary zip asset\n",
            "nested/manifest.json": b'{"safe":true}\n',
        }
        protected_assets = {
            "client_configuration_token.tok": b"private token\n",
            "UPPER.TOK": b"private token\n",
            "VgpuGuestFinish.exe": b"embedded token\n",
            "vgpuguestfinish-debug.zip": b"embedded token\n",
            ".VgpuGuestFinish.exe.meta": b"private metadata\n",
            ".secret": b"private dotfile\n",
            "nested/.hidden": b"private nested dotfile\n",
        }
        for relative, content in {**safe_assets, **protected_assets}.items():
            path = self.stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        (self.stage / "token-link.bin").symlink_to(
            self.stage / "client_configuration_token.tok")

        handler = functools.partial(QuietHandler, directory=str(self.stage))
        httpd = SERVER.ThreadedServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{httpd.server_address[1]}"
        try:
            for relative, expected in safe_assets.items():
                with self.subTest(allowed=relative):
                    with urllib.request.urlopen(f"{base}/{relative}", timeout=2) as response:
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.read(), expected)

            forbidden = [
                "", "nested/", *protected_assets,
                "%2Esecret", "client_configuration_token%2Etok",
                "token-link.bin",
            ]
            for relative in forbidden:
                with self.subTest(forbidden=relative):
                    with self.assertRaises(urllib.error.HTTPError) as raised:
                        urllib.request.urlopen(f"{base}/{relative}", timeout=2)
                    self.assertEqual(raised.exception.code, 403)
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
