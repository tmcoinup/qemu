#!/usr/bin/env python3
"""严格解析 qemu-img 的 JSON 指标，避免 shell 把缺失/布尔字段当作数字。"""

from __future__ import annotations

import json
import pathlib
import sys
from collections.abc import Mapping, Sequence
from typing import TextIO


class MetricsError(RuntimeError):
    """输入不是受支持的 qemu-img 指标时返回的受控错误。"""


def open_input(path: str) -> tuple[TextIO, bool]:
    """打开普通 JSON 文件；短横线表示读取调用方管道的标准输入。"""

    if path == "-":
        return sys.stdin, False
    return pathlib.Path(path).open(encoding="utf-8"), True


def load_object(path: str) -> Mapping[str, object]:
    """读取且只接受顶层 JSON object。"""

    stream, should_close = open_input(path)
    try:
        value = json.load(stream)
    finally:
        if should_close:
            stream.close()
    if not isinstance(value, dict):
        raise MetricsError("qemu-img JSON 顶层必须是 object")
    return value


def nonnegative_integer(data: Mapping[str, object], key: str) -> int:
    """返回严格非负整数；Python bool 虽继承 int，但在这里必须拒绝。"""

    value = data.get(key)
    if type(value) is not int or value < 0:
        raise MetricsError(f"qemu-img JSON 字段 {key!r} 必须是非负整数")
    return value


def optional_nonnegative_integer(data: Mapping[str, object], key: str) -> int:
    """qemu-img 会省略值为零的 cluster 计数；缺失仅在这些字段上等价于零。"""

    if key not in data:
        return 0
    return nonnegative_integer(data, key)


def parse_measure(data: Mapping[str, object]) -> tuple[int, int]:
    """解析 convert 输出空间上界，并验证两个指标的基本关系。"""

    required = nonnegative_integer(data, "required")
    fully_allocated = nonnegative_integer(data, "fully-allocated")
    if required == 0 or fully_allocated < required:
        raise MetricsError("qemu-img measure 返回了不可能的容量关系")
    return required, fully_allocated


def parse_check(data: Mapping[str, object]) -> tuple[int, int, int, int]:
    """解析 qcow2 布局；check-errors 非零时直接拒绝镜像。"""

    check_errors = nonnegative_integer(data, "check-errors")
    compressed = optional_nonnegative_integer(data, "compressed-clusters")
    allocated = optional_nonnegative_integer(data, "allocated-clusters")
    fragmented = optional_nonnegative_integer(data, "fragmented-clusters")
    total = nonnegative_integer(data, "total-clusters")
    if check_errors != 0:
        raise MetricsError(f"qemu-img check 报告 {check_errors} 个错误")
    if compressed > allocated or fragmented > allocated or allocated > total:
        raise MetricsError("qemu-img check 返回了不可能的 cluster 计数关系")
    return compressed, allocated, fragmented, total


def main(arguments: Sequence[str]) -> int:
    """输出适合 Bash ``read`` 的单行十进制字段。"""

    try:
        if len(arguments) != 2 or arguments[0] not in ("measure", "check"):
            raise MetricsError(
                "usage: qemu-image-metrics.py measure|check JSON_PATH|-"
            )
        data = load_object(arguments[1])
        values = parse_measure(data) if arguments[0] == "measure" \
            else parse_check(data)
        print(" ".join(str(value) for value in values))
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, MetricsError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
