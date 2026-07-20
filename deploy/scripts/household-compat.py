#!/usr/bin/env python3
"""查询并导出家用 CPU compatibility 完整组合。"""

from __future__ import annotations

import argparse
import base64
import pathlib
import sys
from typing import Any

from household_compat_export import export_pairs
from household_compat_manifest import load_manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="严格加载家用 CPU compatibility 清单")
    parser.add_argument("manifest", type=pathlib.Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("validate")

    index = subparsers.add_parser("index")
    index.add_argument("--host-class")
    index.add_argument("--threads", type=int)
    index.add_argument("--status", choices=("supported", "compatibility"))

    status = subparsers.add_parser("status")
    status.add_argument("candidate_id")

    export = subparsers.add_parser("export")
    export.add_argument("candidate_id")

    classify = subparsers.add_parser("classify")
    classify.add_argument("vendor_id")
    classify.add_argument("family", type=int)
    classify.add_argument("model", type=int)
    return parser.parse_args()


def stringify(value: Any) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def candidate_by_id(root: dict[str, Any], candidate_id: str) -> dict[str, Any]:
    for candidate in root["candidates"]:
        if candidate["id"] == candidate_id:
            return candidate
    raise ValueError(f"未知 household compatibility ID: {candidate_id}")


def command_index(
    root: dict[str, Any],
    host_class: str | None,
    threads: int | None,
    status: str | None,
) -> int:
    known_classes = {item["id"] for item in root["host_classes"]}
    if host_class is not None and host_class not in known_classes:
        raise ValueError(f"未知 household compatibility 宿主类: {host_class}")
    if threads is not None and threads <= 0:
        raise ValueError("--threads 必须是正整数")
    for candidate in root["candidates"]:
        cpu = candidate["cpu"]
        if status is not None and candidate["status"] != status:
            continue
        if host_class is not None and host_class not in candidate["host_classes"]:
            continue
        if threads is not None and cpu["threads"] != threads:
            continue
        print(
            f"{candidate['id']}|{','.join(candidate['host_classes'])}|"
            f"{cpu['threads']}|{cpu['name']}"
        )
    return 0


def command_classify(root: dict[str, Any], vendor: str, family: int, model: int) -> int:
    for host in root["host_classes"]:
        model_matches = not host["cpuid_models"] or model in host["cpuid_models"]
        if (
            host["vendor_id"] == vendor
            and family in host["cpuid_families"]
            and model_matches
        ):
            print(host["id"])
            return 0
    raise ValueError(
        f"宿主 CPUID 没有受控家用兜底分类: vendor={vendor} "
        f"family={family} model={model}"
    )


def main() -> int:
    args = parse_args()
    try:
        root = load_manifest(args.manifest)
        if args.command == "validate":
            print(root["catalog_revision"])
            return 0
        if args.command == "index":
            return command_index(root, args.host_class, args.threads, args.status)
        if args.command == "classify":
            return command_classify(root, args.vendor_id, args.family, args.model)
        candidate = candidate_by_id(root, args.candidate_id)
        if args.command == "status":
            print(candidate["status"])
            return 0
        if args.command == "export":
            for key, value in export_pairs(root, candidate).items():
                encoded = base64.b64encode(stringify(value).encode("utf-8")).decode("ascii")
                print(f"{key}\t{encoded}")
            return 0
        raise ValueError(f"未知命令: {args.command}")
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
