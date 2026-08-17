#!/usr/bin/env python3
"""Fail-closed structural validation for an offline Windows primary hive.

The REGF base block declares the logical hive-bin length at offset ``0x28``.
Windows commonly keeps reusable file slack after that logical end; the slack
may contain old ``hbin`` records and does not belong to the current hive.  A
validator must therefore verify the complete *declared* chain without treating
the physical end of file as an additional hive-bin boundary.

This module is intentionally read-only.  It never repairs sequence numbers,
rewrites the declared length, replays transaction logs, truncates slack, or
updates the base-block checksum.
"""

from __future__ import annotations

import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


REGF_HEADER_SIZE = 0x1000
MIN_HBIN_SIZE = 0x1000
REGF_SEQUENCE_PRIMARY_OFFSET = 0x04
REGF_SEQUENCE_SECONDARY_OFFSET = 0x08
REGF_FILE_TYPE_OFFSET = 0x1C
REGF_FORMAT_OFFSET = 0x20
REGF_HBINS_SIZE_OFFSET = 0x28
REGF_CLUSTER_FACTOR_OFFSET = 0x2C
REGF_CHECKSUM_OFFSET = 0x1FC


class WindowsHiveError(ValueError):
    """The active REGF/hbin structure is unsafe for offline modification."""


@dataclass(frozen=True)
class HiveLayout:
    logical_end: int
    physical_size: int
    hbin_count: int
    slack_size: int
    sequence: int


def _u32(data: bytes | bytearray | memoryview, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _base_block_checksum(data: bytes | bytearray | memoryview) -> int:
    checksum = 0
    for offset in range(0, REGF_CHECKSUM_OFFSET, 4):
        checksum ^= _u32(data, offset)
    return checksum


def validate_primary_hive(
    data: bytes | bytearray | memoryview,
    label: str = "SYSTEM hive",
) -> HiveLayout:
    """Validate one clean primary hive without changing ``data``.

    The hbin chain must exactly cover the base block's declared logical range.
    Bytes after ``logical_end`` are preserved file slack and are deliberately
    not interpreted, required to be zero, or folded into the current hive.
    """

    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("hive data must be bytes-like")
    physical_size = len(data)
    if physical_size < REGF_HEADER_SIZE + MIN_HBIN_SIZE:
        raise WindowsHiveError(
            f"{label} 长度非法: {physical_size:#x}"
        )
    if bytes(data[:4]) != b"regf":
        raise WindowsHiveError(f"{label} 缺少 regf 头")

    primary = _u32(data, REGF_SEQUENCE_PRIMARY_OFFSET)
    secondary = _u32(data, REGF_SEQUENCE_SECONDARY_OFFSET)
    if primary != secondary:
        raise WindowsHiveError(
            f"{label} sequence 未同步: {primary:#x} != {secondary:#x}"
        )

    file_type = _u32(data, REGF_FILE_TYPE_OFFSET)
    if file_type != 0:
        raise WindowsHiveError(
            f"{label} 不是 primary hive: type={file_type:#x}"
        )
    file_format = _u32(data, REGF_FORMAT_OFFSET)
    if file_format != 1:
        raise WindowsHiveError(
            f"{label} REGF format 非法: {file_format:#x}"
        )
    cluster_factor = _u32(data, REGF_CLUSTER_FACTOR_OFFSET)
    if cluster_factor != 1:
        raise WindowsHiveError(
            f"{label} cluster factor 非法: {cluster_factor:#x}"
        )

    expected_checksum = _base_block_checksum(data)
    stored_checksum = _u32(data, REGF_CHECKSUM_OFFSET)
    if stored_checksum != expected_checksum:
        raise WindowsHiveError(
            f"{label} header checksum 非法: "
            f"{stored_checksum:#x} != {expected_checksum:#x}"
        )

    hbins_size = _u32(data, REGF_HBINS_SIZE_OFFSET)
    if hbins_size < MIN_HBIN_SIZE or hbins_size % MIN_HBIN_SIZE:
        raise WindowsHiveError(
            f"{label} 声明的 hbin 长度非法: {hbins_size:#x}"
        )
    logical_end = REGF_HEADER_SIZE + hbins_size
    if logical_end > physical_size:
        raise WindowsHiveError(
            f"{label} 声明终点越过文件: "
            f"{logical_end:#x} > {physical_size:#x}"
        )

    offset = REGF_HEADER_SIZE
    hbin_count = 0
    while offset < logical_end:
        if offset + 0x20 > logical_end or bytes(data[offset:offset + 4]) != b"hbin":
            raise WindowsHiveError(
                f"{label} hbin 链在 {offset:#x} 断裂"
            )
        relative = _u32(data, offset + 4)
        size = _u32(data, offset + 8)
        expected_relative = offset - REGF_HEADER_SIZE
        if relative != expected_relative:
            raise WindowsHiveError(
                f"{label} hbin 偏移异常: "
                f"{relative:#x} != {expected_relative:#x}"
            )
        if (
            size < MIN_HBIN_SIZE
            or size % MIN_HBIN_SIZE
            or offset + size > logical_end
        ):
            raise WindowsHiveError(
                f"{label} hbin 长度异常: off={offset:#x} size={size:#x} "
                f"logical_end={logical_end:#x}"
            )
        offset += size
        hbin_count += 1

    if offset != logical_end:
        raise WindowsHiveError(
            f"{label} hbin 链未覆盖声明范围: "
            f"{offset:#x} != {logical_end:#x}"
        )

    return HiveLayout(
        logical_end=logical_end,
        physical_size=physical_size,
        hbin_count=hbin_count,
        slack_size=physical_size - logical_end,
        sequence=primary,
    )


def validate_primary_hive_file(
    path: str | os.PathLike[str],
    label: str = "SYSTEM hive",
) -> HiveLayout:
    with open(path, "rb") as stream:
        return validate_primary_hive(stream.read(), label)


def _main(argv: Sequence[str]) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {argv[0]} HIVE [LABEL]", file=sys.stderr)
        return 2
    path = Path(argv[1])
    label = argv[2] if len(argv) == 3 else "SYSTEM hive"
    try:
        layout = validate_primary_hive_file(path, label)
    except (OSError, WindowsHiveError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(
        f"{label}: sequence={layout.sequence:#x} "
        f"hbins={layout.hbin_count} logical_end={layout.logical_end:#x} "
        f"physical={layout.physical_size:#x} slack={layout.slack_size:#x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
