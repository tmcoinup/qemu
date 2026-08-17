#!/usr/bin/env python3
"""Regression tests for safe validation of an offline Windows primary hive."""

from __future__ import annotations

import importlib.util
import struct
import sys
from collections.abc import Callable
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPO_ROOT / "deploy/lib/windows_hive.py"

spec = importlib.util.spec_from_file_location("g11_windows_hive", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit(f"FAIL: cannot load {MODULE_PATH}")
windows_hive = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = windows_hive
spec.loader.exec_module(windows_hive)


HBIN = 0x1000
PHYSICAL_SIZE = 0xC00000
HIVE_BINS_SIZE = 0xB63000
LOGICAL_END = HBIN + HIVE_BINS_SIZE
STALE_HBIN_END = 0xBD5000
SEQUENCE = 1796


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def update_checksum(data: bytearray) -> None:
    checksum = 0
    for offset in range(0, 0x1FC, 4):
        checksum ^= struct.unpack_from("<I", data, offset)[0]
    struct.pack_into("<I", data, 0x1FC, checksum)


def put_hbin(data: bytearray, offset: int, size: int) -> None:
    require(offset >= HBIN and offset % HBIN == 0,
            f"test generated an invalid hbin offset: {offset:#x}")
    require(size >= HBIN and size % HBIN == 0,
            f"test generated an invalid hbin size: {size:#x}")
    require(offset + size <= len(data),
            f"test hbin overruns fixture: {offset:#x}+{size:#x}")
    data[offset:offset + 4] = b"hbin"
    struct.pack_into("<II", data, offset + 4, offset - HBIN, size)


def build_vm3_fixture() -> bytearray:
    """Mirror the boundaries and bin counts observed in VM3's clean SYSTEM."""

    data = bytearray(PHYSICAL_SIZE)
    data[:4] = b"regf"
    struct.pack_into("<II", data, 4, SEQUENCE, SEQUENCE)
    struct.pack_into("<II", data, 0x14, 1, 5)  # major/minor version
    struct.pack_into("<II", data, 0x1C, 0, 1)  # primary/direct-memory
    struct.pack_into("<I", data, 0x24, 0x20)   # root cell offset
    struct.pack_into("<I", data, 0x28, HIVE_BINS_SIZE)
    struct.pack_into("<I", data, 0x2C, 1)

    # VM3 has 2561 logical bins over 2915 4-KiB pages.  This distribution
    # reproduces both that count and its final 0x4000 bin at 0xb60000.
    offset = HBIN
    for _ in range(351):
        put_hbin(data, offset, 2 * HBIN)
        offset += 2 * HBIN
    for _ in range(2209):
        put_hbin(data, offset, HBIN)
        offset += HBIN
    require(offset == 0xB60000,
            f"logical fixture reached unexpected final bin: {offset:#x}")
    put_hbin(data, offset, 4 * HBIN)
    offset += 4 * HBIN
    require(offset == LOGICAL_END,
            f"logical fixture ends at {offset:#x}, expected {LOGICAL_END:#x}")

    # These 63 bins are old physical-file slack.  They are outside Length and
    # are deliberately followed by zero padding.  A validator that walks to
    # physical EOF reproduces the production failure at exactly 0xbd5000.
    for _ in range(50):
        put_hbin(data, offset, 2 * HBIN)
        offset += 2 * HBIN
    for _ in range(13):
        put_hbin(data, offset, HBIN)
        offset += HBIN
    require(offset == STALE_HBIN_END,
            f"stale hbin prefix ends at {offset:#x}")
    require(not any(data[STALE_HBIN_END:]),
            "fixture zero tail unexpectedly contains data")

    update_checksum(data)
    return data


def expect_refusal(
    name: str,
    source: bytearray,
    mutate: Callable[[bytearray], None],
) -> None:
    candidate = bytearray(source)
    mutate(candidate)
    before = bytes(candidate)
    try:
        windows_hive.validate_primary_hive(candidate, label=name)
    except windows_hive.WindowsHiveError:
        pass
    else:
        raise AssertionError(f"{name}: malformed hive was accepted")
    require(bytes(candidate) == before,
            f"{name}: failed validation modified its input")


fixture = build_vm3_fixture()
fixture_before = bytes(fixture)
result = windows_hive.validate_primary_hive(fixture, label="VM3 SYSTEM hive")
require(bytes(fixture) == fixture_before,
        "successful validation modified the VM3 fixture")
require(result.logical_end == LOGICAL_END,
        f"logical end differs: {result.logical_end:#x}")
require(result.physical_size == PHYSICAL_SIZE,
        f"physical size differs: {result.physical_size:#x}")
require(result.hbin_count == 2561,
        f"logical hbin count differs: {result.hbin_count}")
require(result.slack_size == PHYSICAL_SIZE - LOGICAL_END,
        f"physical slack differs: {result.slack_size:#x}")
require(result.sequence == SEQUENCE,
        f"clean sequence differs: {result.sequence!r}")


unaligned_tail = bytearray(fixture)
unaligned_tail.extend(b"\xA5")
unaligned_tail_before = bytes(unaligned_tail)
unaligned_result = windows_hive.validate_primary_hive(
    unaligned_tail, label="non-aligned physical slack")
require(bytes(unaligned_tail) == unaligned_tail_before,
        "non-aligned physical slack was modified")
require(unaligned_result.logical_end == LOGICAL_END,
        "physical tail changed the logical hive boundary")
require(unaligned_result.physical_size == PHYSICAL_SIZE + 1,
        "non-aligned physical size was not reported exactly")
require(unaligned_result.slack_size == PHYSICAL_SIZE + 1 - LOGICAL_END,
        "non-aligned physical slack was not reported exactly")
require(unaligned_result.hbin_count == 2561,
        "physical tail changed the logical hbin count")
require(unaligned_result.sequence == SEQUENCE,
        "physical tail changed the clean sequence")


def length_past_eof(data: bytearray) -> None:
    struct.pack_into("<I", data, 0x28, PHYSICAL_SIZE)
    update_checksum(data)


expect_refusal("Length beyond EOF", fixture, length_past_eof)


def break_logical_chain(data: bytearray) -> None:
    data[0x3000:0x3004] = b"\x00" * 4


expect_refusal("logical hbin chain break", fixture, break_logical_chain)


def wrong_relative_offset(data: bytearray) -> None:
    struct.pack_into("<I", data, HBIN + 4, 1)


expect_refusal("hbin relative offset", fixture, wrong_relative_offset)


def zero_hbin_size(data: bytearray) -> None:
    struct.pack_into("<I", data, HBIN + 8, 0)


expect_refusal("zero hbin size", fixture, zero_hbin_size)


def unaligned_hbin_size(data: bytearray) -> None:
    struct.pack_into("<I", data, HBIN + 8, 0x1800)


expect_refusal("unaligned hbin size", fixture, unaligned_hbin_size)


def hbin_crosses_logical_end(data: bytearray) -> None:
    struct.pack_into("<I", data, 0xB60000 + 8, 5 * HBIN)


expect_refusal("hbin crosses declared Length", fixture,
               hbin_crosses_logical_end)


def dirty_sequence(data: bytearray) -> None:
    struct.pack_into("<I", data, 8, SEQUENCE - 1)
    update_checksum(data)


expect_refusal("mismatched sequence", fixture, dirty_sequence)


def wrong_checksum(data: bytearray) -> None:
    stored = struct.unpack_from("<I", data, 0x1FC)[0]
    struct.pack_into("<I", data, 0x1FC, stored ^ 1)


expect_refusal("wrong base-block checksum", fixture, wrong_checksum)

print("PASS: Windows primary hive validation honors logical Length and refuses corruption")
