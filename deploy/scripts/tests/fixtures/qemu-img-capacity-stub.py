#!/usr/bin/env python3
"""只实现容量单测所需的 qemu-img create/info 最小协议。"""

from __future__ import annotations

import json
import os
import pathlib
import sys


def main() -> int:
    """把虚拟容量写进普通临时文件，避免 CI 依赖已编译的 qemu-img。"""

    arguments = sys.argv[1:]
    if not arguments:
        return 2

    if arguments[0] == "create":
        if "-b" in arguments:
            base_index = arguments.index("-b") + 1
            base = pathlib.Path(arguments[base_index])
            disk = pathlib.Path(arguments[-1])
            disk.write_text(base.read_text(encoding="ascii"), encoding="ascii")
        else:
            disk = pathlib.Path(arguments[-2])
            disk.write_text(arguments[-1], encoding="ascii")
        return 0

    if arguments[0] == "info":
        if os.environ.get("VMATE_QEMU_IMG_MODE") == "invalid-json":
            print("not-json")
            return 0
        disk = pathlib.Path(arguments[-1])
        backing = os.environ.get("VMATE_QEMU_IMG_BACKING", "")
        backing_format = os.environ.get("VMATE_QEMU_IMG_BACKING_FORMAT", "")
        data_file = os.environ.get("VMATE_QEMU_IMG_DATA_FILE", "")
        payload: dict[str, object] = {
            "format": os.environ.get("VMATE_QEMU_IMG_FORMAT", "qcow2"),
            "virtual-size": int(disk.read_text(encoding="ascii")),
        }
        if backing:
            payload["full-backing-filename"] = backing
            payload["backing-filename-format"] = backing_format
        if data_file:
            payload["format-specific"] = {"data": {"data-file": data_file}}
        print(
            json.dumps(payload)
        )
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
