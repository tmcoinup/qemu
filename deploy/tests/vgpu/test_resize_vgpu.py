#!/usr/bin/env python3
"""Exercise GPU-only preservation, stopped-host gates and transaction recovery."""
import contextlib
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import shlex
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "scripts/resize-vgpu.py"
SPEC = importlib.util.spec_from_file_location("resize_vgpu", SOURCE)
resize = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resize)


class ResizeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "vms"
        (self.root / "control").mkdir(parents=True)
        for filename in (".storage.lock", ".identity.lock"):
            (self.root / "control" / filename).touch()
        self.runtime = resize.Runtime()
        self.runtime.proc = self.base / "proc"
        self.runtime.proc.mkdir()
        self.runtime.devices = self.base / "mdev"
        self.runtime.devices.mkdir()
        self.runtime.pci = self.base / "pci"
        gpu = self.runtime.pci / "0000:04:00.0"
        gpu.mkdir(parents=True)
        (gpu / "vendor").write_text("0x10de\n")
        (gpu / "device").write_text("0x1e82\n")
        for resource, tier in (("nvidia-256", "1024"), ("nvidia-257", "2048")):
            folder = gpu / "mdev_supported_types" / resource
            folder.mkdir(parents=True)
            (folder / "description").write_text(f"framebuffer={tier}M, num_heads=1")
            (folder / "available_instances").write_text("8")
        self.runtime.version = self.base / "version"
        self.runtime.version.write_text("535.161.05\n")
        self.runtime.host_lock = self.base / "host.lock"
        self.runtime.host_lock.touch()
        self.host = self.base / "vgpu-host.conf"
        self.host.write_text(
            "VGPU_MGPU=0000:04:00.0\nVGPU_HOST_FB_MODE=equal\n"
            "VGPU_HOST_FB_TIER_MB=1024\nVGPU_RESOURCE_PROFILE=nvidia-256\n"
            "VGPU_RESOURCE_FB_MB=1024\nVGPU_TOTAL_FB_MB=16384\nSPOOF_MODE=B\n"
            "VGPU_CONSOLE_INTERVAL_US=8333\nVGPU_HOST_CPU_NODE_BIND=all\n")
        self.targets = []
        for vm_id, brand in ((1, "msi"), (2, "asus"), (3, "gigabyte")):
            instance = self.root / str(vm_id)
            (instance / "run").mkdir(parents=True)
            for filename in ("start.lock", "disk.lock"):
                (instance / "run" / filename).touch()
            fields = resize.profile(f"gtx750_{brand}_1gb")
            text = (f"VM_ID={vm_id}\nVM_UUID=original-uuid-{vm_id}\n"
                    f'VM_MAC="00:1b:21:00:00:0{vm_id}"\nSYS_SN="original board {vm_id}"\n'
                    "G11_HARDWARE_CONTRACT_VERSION=3\nSPOOF_MODE=B\n"
                    'VGPU_IDENTITY_TARGET=name-only\nMONITOR_SERIAL="original monitor"\n'
                    'SSD_SN="original disk"\nCPU_MODEL=Core-i7-4960X\nGUEST_MEM_MB=8192\n')
            # Match create-vm.sh's double-quoted strings instead of reusing
            # the migration writer's serializer to construct our inputs.
            for key, value in fields.items():
                literal = f'"{value}"' if key in ("GPU_NAME", "GPU_VBIOS", "GPU_MEMORY_MAKER") else value
                text += f"{key}={literal}\n"
            (instance / "vm.conf").write_text(text)
            (instance / "vm.conf").chmod(0o444)
            for filename in ("disk.qcow2", "nvram.fd", "tpm-state"):
                (instance / filename).write_bytes(b"persistent state must not change\x00")
            self.targets.append(f"{vm_id}:gtx750ti_{brand}_2gb")
        self.before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.host_before = self.host.read_bytes()

    def proposal(self):
        return resize.plan(self.root, self.targets, [self.host])

    def assert_original(self):
        for path, data in self.before.items():
            self.assertEqual(path.read_bytes(), data, str(path))
        self.assertEqual(self.host.read_bytes(), self.host_before)

    def test_only_gpu_changes_and_exact_restore(self):
        proposal = self.proposal()
        self.assert_original()  # Preparing a plan is read-only.
        with contextlib.redirect_stdout(io.StringIO()):
            backup = resize.apply(proposal, self.runtime)
        for path, data in self.before.items():
            if path.name == "vm.conf":
                actual = path.read_bytes()
                self.assertEqual(resize.untouched(actual, resize.GPU_FIELDS),
                                 resize.untouched(data, resize.GPU_FIELDS))
                self.assertEqual(resize.parse(actual)["GPU_VRAM_MB"], "2048")
                self.assertEqual(path.stat().st_mode & 0o777, 0o444)
            else:
                self.assertEqual(path.read_bytes(), data)
        self.assertEqual(resize.parse(self.host.read_bytes())["VGPU_CONSOLE_INTERVAL_US"], "8333")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(resize.apply(self.proposal(), self.runtime))
            resize.restore(backup, self.runtime)
        self.assert_original()

    def test_consumer_parser_rejects_old_output_and_accepts_new(self):
        proposal = self.proposal()
        configs = [e for e in proposal["changes"] if e["kind"] == "vm"]
        self.assertIn(b'GPU_NAME="NVIDIA GeForce GTX 750 Ti"\n', configs[0]["after"])
        self.assertIn(b'GPU_VBIOS="Version 82.07.25.00.1F"\n', configs[0]["after"])
        resize.validate_vm_configs(configs)
        broken = dict(configs[0])
        broken["after"] = broken["after"].replace(
            b'GPU_NAME="NVIDIA GeForce GTX 750 Ti"',
            b"GPU_NAME='NVIDIA GeForce GTX 750 Ti'")
        with self.assertRaisesRegex(ValueError, "unquoted value for GPU_NAME is malformed"):
            resize.validate_vm_configs([broken])

    def test_legacy_quotes_repair_and_original_migration_rollback(self):
        with contextlib.redirect_stdout(io.StringIO()):
            backup = resize.apply(self.proposal(), self.runtime)
        journal_path = backup / "journal.json"
        journal = json.loads(journal_path.read_text())
        legacy = {}
        for entry in journal["entries"]:
            if entry["kind"] != "vm":
                continue
            # Reproduce an old deployed config AND its original rollback log.
            data = Path(entry["path"]).read_bytes()
            values = resize.parse(data)
            for key in ("GPU_NAME", "GPU_VBIOS"):
                data = data.replace(f'{key}="{values[key]}"'.encode(),
                                    f"{key}={shlex.quote(values[key])}".encode())
            resize.atomic_write(entry["path"], data, entry)
            (backup / entry["after"]).write_bytes(data)
            entry["after_sha256"] = resize.digest(data)
            legacy[entry["path"]] = data
        journal_path.write_text(json.dumps(journal))
        # No write permission on the host config is needed for a GPU quote fix.
        real_access = resize.os.access
        def writable(path, mode):
            return False if Path(path) == self.host.parent else real_access(path, mode)
        with mock.patch.object(resize.os, "access", side_effect=writable):
            with contextlib.redirect_stdout(io.StringIO()):
                resize.repair_quotes(self.root, ["1", "2", "3"], [self.host], self.runtime)
        for path, old in legacy.items():
            data = Path(path).read_bytes()
            self.assertEqual(resize.parse(data), resize.parse(old))
            self.assertEqual(resize.untouched(data, resize.GPU_FIELDS),
                             resize.untouched(old, resize.GPU_FIELDS))
            self.assertNotIn(b"GPU_NAME='", data)
        with contextlib.redirect_stdout(io.StringIO()):
            resize.restore(backup, self.runtime)
        self.assert_original()

    def test_incomplete_fleet_and_corrupt_profile_refused(self):
        with self.assertRaisesRegex(ValueError, "仍是其它容量"):
            resize.plan(self.root, self.targets[:2], [self.host])
        conf = self.root / "3/vm.conf"
        conf.chmod(0o644)
        conf.write_bytes(conf.read_bytes().replace(b"GPU_VRAM_MB=1024", b"GPU_VRAM_MB=2048"))
        with self.assertRaisesRegex(ValueError, "原显卡字段"):
            self.proposal()
        self.assertEqual(self.host.read_bytes(), self.host_before)

    def test_active_vm_mdev_and_lock_refused(self):
        proposal = self.proposal()
        (self.runtime.devices / "active").touch()
        with self.assertRaisesRegex(ValueError, "活动 mdev"):
            resize.apply(proposal, self.runtime)
        (self.runtime.devices / "active").unlink()
        process = self.runtime.proc / "123"
        process.mkdir()
        (process / "cmdline").write_bytes(b"/bin/qemu-system-x86_64\x00-name\x00vm1\x00")
        with self.assertRaisesRegex(ValueError, "QEMU PID"):
            resize.apply(proposal, self.runtime)
        (process / "cmdline").unlink()
        with (self.root / "1/run/start.lock").open("rb") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, "生命周期锁"):
                resize.apply(proposal, self.runtime)
        self.assert_original()

    def test_publish_failure_rolls_back_earlier_files(self):
        original_write = resize.atomic_write
        counter = 0

        def fail_second(path, data, entry):
            nonlocal counter
            counter += 1
            if counter == 2:
                raise OSError("injected disk error")
            return original_write(path, data, entry)

        with mock.patch.object(resize, "atomic_write", side_effect=fail_second):
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(OSError, "injected disk error"):
                    resize.apply(self.proposal(), self.runtime)
        self.assert_original()

    def test_permission_gate_prevents_partial_migration(self):
        with mock.patch.object(resize.os, "access", return_value=False):
            with self.assertRaisesRegex(ValueError, "需要管理员权限"):
                resize.apply(self.proposal(), self.runtime)
        self.assert_original()

    def test_rollback_refuses_later_user_edits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            backup = resize.apply(self.proposal(), self.runtime)
        conf = self.root / "1/vm.conf"
        conf.chmod(0o644)
        conf.write_bytes(conf.read_bytes().replace(b"GUEST_MEM_MB=8192", b"GUEST_MEM_MB=16384"))
        with self.assertRaisesRegex(ValueError, "迁移后另有修改"):
            resize.restore(backup, self.runtime)
        self.assertEqual(resize.parse(conf.read_bytes())["GUEST_MEM_MB"], "16384")


if __name__ == "__main__":
    unittest.main()
