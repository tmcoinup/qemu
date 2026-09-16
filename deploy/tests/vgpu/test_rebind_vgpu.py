#!/usr/bin/env python3
"""Run the real rebind wrapper/storage parser with inert lifecycle commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

DEPLOY = Path(__file__).resolve().parents[2]


class RebindTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.deploy = self.root / "deploy"
        self.scripts = self.deploy / "scripts"
        self.scripts.mkdir(parents=True)
        (self.deploy / "lib").symlink_to(DEPLOY / "lib", target_is_directory=True)
        for script in ("rebind-vgpu.sh", "vmctl.sh"):
            shutil.copy2(DEPLOY / "scripts" / script, self.scripts / script)
        self.pool = self.root / "vm pool"
        self.vm = self.pool / "7"
        self.vm.mkdir(parents=True)
        self.config = self.vm / "vm.conf"
        self.original = 'SPOOF_MODE=B\nVGPU_MDEV_PROFILE=nvidia-257\nGPU_NAME="NVIDIA GTX 750 Ti"\nVM_UUID=unchanged\n'
        self.config.write_text(self.original)
        (self.vm / "disk.qcow2").write_bytes(b"inert system disk")
        self.trace = self.root / "trace.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shim = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
kind = Path(sys.argv[0]).name
if kind == 'start-vm.sh':
    phase = 'safe' if any(a.startswith('--driver-install-') for a in sys.argv[1:]) else 'normal'
elif kind == 'sync-monitor-profile.sh':
    phase = 'sync'
else:
    phase = 'sudo'
with open(os.environ['REBIND_TRACE'], 'a') as f:
    f.write(json.dumps({'phase': phase, 'args': sys.argv[1:], 'env': {
        k: os.environ.get(k, '') for k in ('VM_ROOT', 'VMS_DIR', 'VM_INSTANCE_DIR',
        'VM_INSTANCES_DIR', 'VM_START_LOCK_HELD', 'MONITOR_SYNC_SPOOF_MODE')
    }}) + '\\n')
if phase == 'safe' and os.environ.get('REBIND_CHANGE_CONFIG') == '1':
    with open(os.environ['REBIND_CONFIG'], 'a') as f: f.write('VM_MAC=changed\\n')
sys.exit(int(os.environ.get('REBIND_RC_' + phase.upper(), '0')))
'''
        for path in (self.scripts / "start-vm.sh", self.scripts / "sync-monitor-profile.sh", self.bin / "sudo"):
            path.write_text(shim)
            path.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("VM_", "VGPU_", "GUEST_", "SUDO_", "REBIND_"))}
        self.env.update(PATH=f"{self.bin}:/usr/bin:/bin", IMAGE_ROOT=str(self.root),
                        VMS_DIR=str(self.pool), REBIND_TRACE=str(self.trace),
                        REBIND_CONFIG=str(self.config))

    def run_wrapper(self, *args, overrides=None):
        self.trace.unlink(missing_ok=True)
        env = self.env | (overrides or {})
        result = subprocess.run([str(self.scripts / "vmctl.sh"), "gpu-rebind", "7", *args],
                                env=env, text=True, capture_output=True)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []
        return result, calls

    def assert_sequence(self, calls, expected):
        self.assertEqual([c["phase"] for c in calls if c["phase"] != "sudo"], expected)

    def test_success_preserves_config_and_preferences(self):
        result, calls = self.run_wrapper("--proxy", "--cpu-isolate=false", "--memory-prealloc=false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_sequence(calls, ["safe", "sync", "normal"])
        safe, sync, normal = [c for c in calls if c["phase"] != "sudo"]
        self.assertIn("--driver-install-sdl", safe["args"])
        self.assertIn("--no-proxy", safe["args"])
        self.assertNotIn("--proxy", safe["args"])
        for c in (safe, normal):
            for arg in ("--cpu-isolate=false", "--memory-prealloc=false", "--monitor-sync"):
                self.assertIn(arg, c["args"])
            self.assertNotIn("--no-monitor-sync", c["args"])
        self.assertIn("--proxy", normal["args"])
        self.assertIn("--sdl", normal["args"])
        self.assertEqual(sync["args"], ["7", "--force"])
        self.assertEqual(sync["env"]["VM_START_LOCK_HELD"], "0")
        self.assertEqual(sync["env"]["MONITOR_SYNC_SPOOF_MODE"], "B")
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual((self.vm / "disk.qcow2").read_bytes(), b"inert system disk")

    def test_no_followup_after_failed_safe_boot(self):
        result, calls = self.run_wrapper(overrides={"REBIND_RC_SAFE": "23"})
        self.assertEqual(result.returncode, 23)
        self.assert_sequence(calls, ["safe"])

    def test_every_incomplete_sync_blocks_native_start(self):
        for rc in (1, 10, 11, 12, 13):
            with self.subTest(rc=rc):
                result, calls = self.run_wrapper(overrides={"REBIND_RC_SYNC": str(rc)})
                self.assertEqual(result.returncode, rc, result.stderr)
                self.assert_sequence(calls, ["safe", "sync"])
                self.assertEqual(self.config.read_text(), self.original)

    def test_config_change_prevents_offline_write(self):
        result, calls = self.run_wrapper(overrides={"REBIND_CHANGE_CONFIG": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assert_sequence(calls, ["safe"])
        self.assertIn("vm.conf", result.stderr)

    def test_explicit_storage_gtk_and_no_start(self):
        for selector, path, env_key, env_value in (
            ("--vms-dir", self.pool, "VM_ROOT", self.pool),
            ("--vm-dir", self.vm, "VM_INSTANCE_DIR", self.vm),
            ("--instances-dir", self.pool, "VM_INSTANCES_DIR", self.pool),
        ):
            with self.subTest(selector=selector):
                result, calls = self.run_wrapper(selector, str(path), "--gtk", "--no-start")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_sequence(calls, ["safe", "sync"])
                safe, sync = [c for c in calls if c["phase"] != "sudo"]
                self.assertIn("--driver-install-gtk", safe["args"])
                self.assertIn(str(path), safe["args"])
                self.assertEqual(sync["env"][env_key], str(env_value))

    def test_dry_run_is_read_only(self):
        result, calls = self.run_wrapper("--dry-run", "--proxy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        self.assertIn("--driver-install-sdl", result.stdout)
        self.assertEqual(self.config.read_text(), self.original)

    def test_bad_options_fail_before_any_lifecycle_action(self):
        for args in (("--no-monitor-sync",), ("--cpu-isolate=maybe",),
                     ("--vms-dir", "relative"), ("--cpu-isolate=false", "--cpu-isolate=true"),
                     ("--vms-dir", str(self.pool), "--vm-dir", str(self.vm))):
            with self.subTest(args=args):
                result, calls = self.run_wrapper(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_malformed_config_and_non_native_mode_are_rejected(self):
        for content in ("SPOOF_MODE=A\n", "GPU_NAME='Malformed name'\n"):
            with self.subTest(content=content):
                self.config.write_text(content)
                result, calls = self.run_wrapper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
