#!/usr/bin/env python3
"""KVM 能力探测器的无特权单元测试。"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "deploy" / "scripts" / "kvm-capabilities.py"
SPEC = importlib.util.spec_from_file_location("kvm_capabilities", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载 {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class KvmCapabilitiesTest(unittest.TestCase):
    """覆盖成功、失败和 shell 安全输出。"""

    @mock.patch.object(MODULE.os, "close")
    @mock.patch.object(MODULE.os, "open", return_value=10)
    @mock.patch.object(MODULE.fcntl, "ioctl")
    def test_reads_tsc_capabilities(self, ioctl, _open, close):
        def fake_ioctl(fd, command, argument):
            del fd
            if command == MODULE.KVM_CHECK_EXTENSION:
                return 1 if argument in (60, 61) else 0
            if command == MODULE.KVM_CREATE_VM:
                return 11
            if command == MODULE.KVM_CREATE_VCPU:
                return 12
            if command == MODULE.KVM_GET_TSC_KHZ:
                return 2_200_000
            raise AssertionError((command, argument))

        ioctl.side_effect = fake_ioctl
        result = MODULE.inspect_kvm("/fake/kvm")

        self.assertTrue(result.available)
        self.assertTrue(result.tsc_control)
        self.assertTrue(result.get_tsc_khz)
        self.assertEqual(result.host_tsc_khz, 2_200_000)
        self.assertEqual([mock.call(12), mock.call(11), mock.call(10)], close.call_args_list)

    @mock.patch.object(MODULE.os, "open", side_effect=PermissionError(13, "denied"))
    def test_permission_error_is_reported(self, _open):
        result = MODULE.inspect_kvm("/fake/kvm")

        self.assertFalse(result.available)
        self.assertEqual(result.host_tsc_khz, 0)
        self.assertIn("errno=13", result.error)

    def test_shell_output_quotes_error(self):
        result = MODULE.KvmCapabilities(False, False, False, 0, "can't open")
        output = MODULE.format_shell(result)

        self.assertIn("STEALTH_KVM_AVAILABLE=0", output)
        self.assertIn("STEALTH_KVM_ERROR='can'\"'\"'t open'", output)


if __name__ == "__main__":
    unittest.main()
