#!/usr/bin/env python3
"""长稳监控器的协议、时长解析与报告回归测试。"""

from __future__ import annotations

import argparse
import asyncio
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "deploy" / "scripts" / "soak-vm.py"
SPEC = importlib.util.spec_from_file_location("vmate_soak", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载 {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DurationTest(unittest.TestCase):
    def test_units_and_rejections(self) -> None:
        self.assertEqual(MODULE.parse_duration("30s"), 30)
        self.assertEqual(MODULE.parse_duration("2h"), 7200)
        with self.assertRaises(ValueError):
            MODULE.parse_duration("0s")
        with self.assertRaises(ValueError):
            MODULE.parse_duration("1.5h")


class MonitorProtocolTest(unittest.IsolatedAsyncioTestCase):
    async def test_running_qmp_writes_passing_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_dir:
            root = pathlib.Path(temporary_dir)
            socket_path = root / "qmp.sock"
            output_path = root / "soak.jsonl"

            async def handle_qmp(
                reader: asyncio.StreamReader, writer: asyncio.StreamWriter
            ) -> None:
                greeting = {"QMP": {"version": {"qemu": {"major": 11}}}}
                writer.write((json.dumps(greeting) + "\n").encode())
                await writer.drain()
                responses = {
                    "qmp_capabilities": {},
                    "query-status": {"status": "running", "running": True},
                    "query-cpus-fast": [{"cpu-index": index} for index in range(4)],
                    "query-memory-size-summary": {"base-memory": 8 * 1024**3},
                    "query-blockstats": [],
                }
                while line := await reader.readline():
                    request = json.loads(line)
                    command = request.get("execute")
                    response = {
                        "return": responses.get(command, {}),
                        "id": request.get("id"),
                    }
                    writer.write((json.dumps(response) + "\n").encode())
                    await writer.drain()
                writer.close()
                await writer.wait_closed()

            server = await asyncio.start_unix_server(handle_qmp, str(socket_path))
            args = argparse.Namespace(
                qmp=str(socket_path),
                duration="1s",
                interval=0.1,
                timeout=1.0,
                pid=None,
                output=str(output_path),
                allow_paused=False,
                max_consecutive_failures=2,
            )
            try:
                result = await MODULE.monitor(args)
            finally:
                server.close()
                await server.wait_closed()

            self.assertEqual(result, 0)
            samples = output_path.read_text(encoding="utf-8").splitlines()
            self.assertGreaterEqual(len(samples), 2)
            summary_path = output_path.with_suffix(".jsonl.summary.json")
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["statuses"], {"running": summary["samples"]})


if __name__ == "__main__":
    unittest.main()
