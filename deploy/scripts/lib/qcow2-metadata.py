#!/usr/bin/env python3
"""为 qcow2 离线优化器解析并验证 qemu-img info JSON。"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
from collections.abc import Mapping, Sequence
from typing import TextIO


EMPTY_FIELD = "__VMATE_QCOW2_NONE__"


class MetadataError(RuntimeError):
    """镜像元数据不满足安全转换或目标布局契约。"""


def open_input(path: str) -> tuple[TextIO, bool]:
    """读取文件或标准输入，让 shell 不必解析 JSON。"""

    if path == "-":
        return sys.stdin, False
    return pathlib.Path(path).open(encoding="utf-8"), True


def load_info(path: str) -> Mapping[str, object]:
    """只接受 qemu-img info 返回的单个 JSON object。"""

    stream, should_close = open_input(path)
    try:
        value = json.load(stream)
    finally:
        if should_close:
            stream.close()
    if not isinstance(value, dict):
        raise MetadataError("qemu-img info JSON 顶层必须是 object")
    return value


def format_data(info: Mapping[str, object]) -> Mapping[str, object]:
    """返回 qcow2 format-specific.data，拒绝类型混淆。"""

    specific = info.get("format-specific", {})
    if not isinstance(specific, dict):
        raise MetadataError("format-specific 不是 object")
    data = specific.get("data", {})
    if not isinstance(data, dict):
        raise MetadataError("format-specific.data 不是 object")
    return data


def require_plain_qcow2(info: Mapping[str, object]) -> tuple[int, str, str, str]:
    """拒绝转换会丢失语义的快照、bitmap 和外置数据文件。"""

    if info.get("format") != "qcow2":
        raise MetadataError("实例盘格式不是 qcow2")
    size = info.get("virtual-size")
    if type(size) is not int or size <= 0:
        raise MetadataError("virtual-size 必须是正整数")
    if info.get("dirty-flag") is True:
        raise MetadataError("镜像带 dirty flag，请先修复再优化")
    if info.get("snapshots"):
        raise MetadataError("镜像含内部快照，默认转换会丢失快照")
    data = format_data(info)
    if data.get("data-file"):
        raise MetadataError("不支持带 external data file 的实例盘")
    if data.get("bitmaps"):
        raise MetadataError("镜像含 persistent bitmap，拒绝静默丢失")

    recorded = info.get("backing-filename") or ""
    resolved = info.get("full-backing-filename") or ""
    backing_format = info.get("backing-filename-format") or ""
    for label, value in (
        ("backing-filename", recorded),
        ("full-backing-filename", resolved),
        ("backing-filename-format", backing_format),
    ):
        if not isinstance(value, str) or any(char in value for char in "\r\n\0"):
            raise MetadataError(f"{label} 非法")
        if value == EMPTY_FIELD:
            raise MetadataError(f"{label} 与内部空值标记冲突")
    if bool(recorded) != bool(resolved):
        raise MetadataError("backing 记录路径与解析路径不完整")
    if recorded and backing_format != "qcow2":
        raise MetadataError("backing 声明格式不是 qcow2")
    return size, recorded, resolved, backing_format


def inspect(info: Mapping[str, object]) -> None:
    """输出固定四行，路径已拒绝换行符。"""

    size, recorded, resolved, backing_format = require_plain_qcow2(info)
    print(size)
    print(recorded or EMPTY_FIELD)
    print(resolved or EMPTY_FIELD)
    print(backing_format or EMPTY_FIELD)


def validate(
    info: Mapping[str, object],
    expected_size: int,
    expected_backing: str,
    expected_cluster_size: int,
) -> None:
    """验证转换产物完整进入 VMate 性能布局。"""

    size, recorded, resolved, _ = require_plain_qcow2(info)
    data = format_data(info)
    if size != expected_size:
        raise MetadataError("转换后 virtual-size 发生变化")
    if info.get("cluster-size") != expected_cluster_size:
        raise MetadataError("转换后 cluster-size 不符合性能契约")
    if data.get("compat") != "1.1" or data.get("extended-l2") is not True:
        raise MetadataError("转换后未启用 qcow2 v3 Extended L2")
    if data.get("lazy-refcounts") is not False or data.get("corrupt") is True:
        raise MetadataError("转换后 refcount/完整性状态异常")
    if expected_backing:
        if not recorded or os.path.realpath(resolved) != os.path.realpath(expected_backing):
            raise MetadataError("转换后 backing 链发生变化")
    elif recorded or resolved:
        raise MetadataError("独立盘转换后意外出现 backing")


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="解析/验证 qcow2 metadata")
    subparsers = parser.add_subparsers(dest="action", required=True)
    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("json_path")
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("json_path")
    validate_parser.add_argument("expected_size", type=int)
    validate_parser.add_argument("expected_backing")
    validate_parser.add_argument("expected_cluster_size", type=int)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    try:
        args = parse_args(arguments)
        info = load_info(args.json_path)
        if args.action == "inspect":
            inspect(info)
        else:
            validate(
                info,
                args.expected_size,
                "" if args.expected_backing == "-" else args.expected_backing,
                args.expected_cluster_size,
            )
        return 0
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError, MetadataError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
