#!/usr/bin/env python3
"""供 Bash 加载器调用的整机平台清单命令行接口。"""

from __future__ import annotations

import base64
import pathlib
import sys
from typing import Any

from platform_manifest import load_manifest
from platform_manifest_export import export_pairs


def select_platform(root: dict[str, Any], wanted_id: str) -> dict[str, Any]:
    """按稳定 ID 查找平台，未知 ID 必须 fail closed。"""
    selected = next(
        (item for item in root["platforms"] if item["id"] == wanted_id),
        None,
    )
    if selected is None:
        raise ValueError(f"平台不存在：{wanted_id}")
    return selected


def print_index(root: dict[str, Any]) -> None:
    """输出 shell 池使用的稳定、无转义分隔索引。"""
    for item in root["platforms"]:
        cpu = item["cpu"]
        print("|".join((
            item["id"],
            str(item["enabled"]).lower(),
            cpu["vendor_id"],
            str(cpu["max_mhz"]),
            str(cpu["threads"]),
            str(cpu["tsc_mhz"]),
        )))


def print_legacy(root: dict[str, Any], action: str) -> None:
    """为尚未迁移的 CPU_POOL/BOARD_POOL 输出去重兼容行。"""
    rows: list[str] = []
    seen: set[str] = set()
    for item in root["platforms"]:
        if not item["enabled"]:
            continue
        cpu, board, smbios = item["cpu"], item["board"], item["cpu"]["smbios"]
        if action == "legacy_cpu":
            row = "|".join((
                cpu["qemu_arg"], cpu["vendor_id"], cpu["name"],
                str(cpu["max_mhz"]), str(cpu["current_mhz"]), cpu["part"],
                smbios["family"], cpu["socket"],
            ))
        else:
            row = "|".join((
                cpu["socket"], board["manufacturer"], board["product"],
                board["family"], board["version"], board["serial_fn"],
                board["subsystem_vendor"], board["subsystem_device"],
            ))
        if row not in seen:
            seen.add(row)
            rows.append(row)
    print("\n".join(rows))


def print_export(
    root: dict[str, Any],
    platform: dict[str, Any],
    strict_hardware: str,
    allow_compatibility: str,
) -> None:
    """执行 compatibility 授权门禁后，以 base64 投影完整平台。"""
    if not platform["enabled"]:
        explicitly_allowed = allow_compatibility == "1"
        legacy_non_strict = strict_hardware == "0"
        if (
            platform["status"] != "compatibility"
            or not (explicitly_allowed or legacy_non_strict)
        ):
            raise ValueError(
                f"平台已禁用：{platform['id']}；"
                "如确认接受 Q35 行为边界，需显式允许 compatibility"
            )
        print(
            "WARN: 加载 Q35/ICH9 compatibility 平台，不能宣称真实目标主板行为："
            f"{platform['id']}",
            file=sys.stderr,
        )
    for key, value in export_pairs(root, platform).items():
        encoded = base64.b64encode(str(value).encode("utf-8")).decode("ascii")
        print(f"{key}\t{encoded}")


def run(argv: list[str]) -> None:
    """解析固定内部参数并执行只读动作。"""
    if len(argv) != 6:
        raise ValueError(
            "用法: platform_manifest_cli.py MANIFEST ACTION ID STRICT ALLOW"
        )
    manifest_path = pathlib.Path(argv[1])
    action, wanted_id, strict_hardware, allow_compatibility = argv[2:]
    root = load_manifest(manifest_path)
    if action == "validate":
        print(
            f"OK: platform manifest schema=1 "
            f"platforms={len(root['platforms'])}"
        )
    elif action == "index":
        print_index(root)
    elif action == "status":
        print(select_platform(root, wanted_id)["status"])
    elif action in ("legacy_cpu", "legacy_board"):
        print_legacy(root, action)
    elif action == "export":
        print_export(
            root,
            select_platform(root, wanted_id),
            strict_hardware,
            allow_compatibility,
        )
    else:
        raise ValueError(f"未知清单动作：{action}")


def main() -> int:
    """把内部异常转成稳定错误输出和非零退出码。"""
    try:
        run(sys.argv)
    except (OSError, ValueError) as exc:
        manifest = sys.argv[1] if len(sys.argv) > 1 else "<missing>"
        print(f"ERROR: 无法使用平台清单 {manifest}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
