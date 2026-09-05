#!/usr/bin/env python3
"""No-device fixtures for the live QEMU capability-only probe."""

import errno
import importlib.util
from pathlib import Path
import struct
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    "vgpu_dmabuf_probe", REPO / "deploy/host/probe-vgpu-dmabuf.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class CapabilityProbeTest(unittest.TestCase):
    def test_only_two_probe_ioctls_with_zeroed_plane_inputs(self):
        with mock.patch.object(probe.fcntl, "ioctl", return_value=0) as ioctl:
            for plane in (probe.VFIO_GFX_PLANE_TYPE_DMABUF,
                          probe.VFIO_GFX_PLANE_TYPE_REGION):
                self.assertEqual(probe.query_support(51, plane), ("supported", 0))
        self.assertEqual(ioctl.call_count, 2)
        for call, flags in zip(ioctl.call_args_list, (3, 5)):
            fd, request, payload, mutate = call.args
            self.assertEqual((fd, request, mutate), (51, 0x3B72, True))
            self.assertEqual(struct.unpack_from("=II", payload), (64, flags))
            self.assertEqual(payload[8:], bytes(56))

    def test_only_einval_means_unsupported(self):
        for number, status in ((errno.EINVAL, "unsupported"),
                               (errno.EPERM, "error"),
                               (errno.ENOTTY, "error"), (errno.EIO, "error")):
            with self.subTest(errno=number), mock.patch.object(
                    probe.fcntl, "ioctl", side_effect=OSError(number, "fixture")):
                self.assertEqual(probe.query_support(51, 2), (status, number))

    def run_mock_probe(self, *, check_only=False, mismatch=False,
                       dup_error=None, answers=None, expected_vm=None):
        identity = ("/build/qemu-system-x86_64", 123)
        identities = [identity, (identity[0], 124) if mismatch else identity]
        with mock.patch.object(probe.platform, "system", return_value="Linux"), \
                mock.patch.object(probe.platform, "machine", return_value="x86_64"), \
                mock.patch.object(probe, "process_identity", side_effect=identities), \
                mock.patch.object(probe.os, "pidfd_open", return_value=101), \
                mock.patch.object(probe, "select_vfio_fd", return_value=51), \
                mock.patch.object(probe, "duplicate_fd", return_value=102,
                                  side_effect=dup_error), \
                mock.patch.object(probe.os, "readlink", return_value=probe.VFIO_DEVICE_LINK), \
                mock.patch.object(probe, "process_vm_name", return_value="vm1"), \
                mock.patch.object(probe, "query_support", side_effect=answers) as query, \
                mock.patch.object(probe.os, "close") as close:
            try:
                result = probe.probe_running_qemu(
                    40015, check_only=check_only, expected_vm=expected_vm)
            except probe.ProbeError as exc:
                result = exc
        return result, query.call_args_list, close.call_args_list

    def test_unsupported_dmabuf_still_queries_region_and_closes_both_fds(self):
        result, queries, closes = self.run_mock_probe(
            answers=[("unsupported", errno.EINVAL), ("supported", 0)])
        self.assertEqual(queries, [mock.call(102, 2), mock.call(102, 4)])
        self.assertEqual(result["SOURCE_REGION"], "supported")
        self.assertEqual(result["END_TO_END_GPU"], "unavailable")
        self.assertEqual(result["PROBE_RESULT"], "complete")
        self.assertEqual(closes, [mock.call(102), mock.call(101)])

    def test_supported_source_does_not_claim_import_or_end_to_end_success(self):
        result, _, _ = self.run_mock_probe(answers=[("supported", 0)] * 2)
        self.assertEqual(result["END_TO_END_GPU"], "unverified")

    def test_query_error_is_incomplete_not_unsupported(self):
        result, queries, _ = self.run_mock_probe(
            answers=[("error", errno.EIO), ("supported", 0)])
        self.assertEqual(len(queries), 2)
        self.assertEqual(result["END_TO_END_GPU"], "unverified")
        self.assertEqual(result["PROBE_RESULT"], "incomplete")

    def test_check_only_issues_no_ioctl_and_closes_duplicates(self):
        result, queries, closes = self.run_mock_probe(check_only=True)
        self.assertEqual(queries, [])
        self.assertEqual(result["SOURCE_DMABUF"], "not-probed")
        self.assertEqual(closes, [mock.call(102), mock.call(101)])

    def test_identity_race_aborts_before_ioctl(self):
        result, queries, closes = self.run_mock_probe(mismatch=True)
        self.assertIsInstance(result, probe.ProbeError)
        self.assertEqual(result.operation, "qemu-process-identity-changed")
        self.assertEqual(queries, [])
        self.assertEqual(closes, [mock.call(102), mock.call(101)])

    def test_denied_duplication_aborts_before_ioctl_and_closes_pidfd(self):
        result, queries, closes = self.run_mock_probe(
            dup_error=OSError(errno.EPERM, "fixture"))
        self.assertEqual(result.operation, "pidfd-getfd")
        self.assertEqual(result.error_number, errno.EPERM)
        self.assertEqual(queries, [])
        self.assertEqual(closes, [mock.call(101)])

    def test_changed_vm_label_aborts_before_ioctl(self):
        result, queries, closes = self.run_mock_probe(expected_vm=2)
        self.assertEqual(result.operation, "qemu-vm-name-changed")
        self.assertEqual(queries, [])
        self.assertEqual(closes, [mock.call(102), mock.call(101)])

    def test_vm_lookup_is_exact_and_requires_one_process(self):
        entries = [Path("/proc/1"), Path("/proc/11"), Path("/proc/self")]
        with mock.patch.object(Path, "iterdir", return_value=entries), \
                mock.patch.object(probe, "process_identity"), \
                mock.patch.object(probe, "process_vm_name", side_effect=["vm1", "vm11"]):
            self.assertEqual(probe.find_vm_pid(1), 1)
        with mock.patch.object(Path, "iterdir", return_value=entries), \
                mock.patch.object(probe, "process_identity"), \
                mock.patch.object(probe, "process_vm_name", return_value="vm1"):
            with self.assertRaisesRegex(probe.ProbeError, "multiple-qemu"):
                probe.find_vm_pid(1)


if __name__ == "__main__":
    unittest.main()
