#!/usr/bin/env python3
"""Update one vgpu_unlock-rs per-mdev identity override without touching guests."""

from __future__ import annotations

import argparse
import json
import re
import tomllib
import uuid as uuid_module
from pathlib import Path


SECTION_RE = re.compile(
    r'''^\s*\[\s*mdev\s*\.\s*(?:"([0-9A-Fa-f-]+)"|'([0-9A-Fa-f-]+)'|([0-9A-Fa-f-]+))\s*\]\s*(?:#.*)?$'''
)
ANY_SECTION_RE = re.compile(r"^\s*\[")
GENERATED_MARKERS = {
    "# Per-VM marketing name; generated atomically by start-vm.sh.",
    "# Per-VM GPU identity; generated atomically by start-vm.sh.",
}


def validate_name(value: str) -> str:
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError("GPU name must be printable ASCII") from exc
    # R535 uses a 32-byte vgpu_name field, including its trailing NUL.
    if not 1 <= len(encoded) <= 31 or any(byte < 0x20 or byte > 0x7E for byte in encoded):
        raise ValueError("GPU name must contain 1-31 printable ASCII bytes")
    return value


def parse_u64(value: str) -> int:
    """Parse an unsigned TOML-compatible integer without silent truncation."""
    if not re.fullmatch(r"(?:0[xX][0-9A-Fa-f]+|[0-9]+)", value):
        raise argparse.ArgumentTypeError(
            "PCI identity must be an unsigned decimal or 0x-prefixed integer"
        )
    parsed = int(value, 0)
    if not 0 <= parsed <= 0xFFFFFFFFFFFFFFFF:
        raise argparse.ArgumentTypeError("PCI identity does not fit in an unsigned 64-bit field")
    return parsed


def parse_binary(value: str) -> int:
    if value not in {"0", "1"}:
        raise argparse.ArgumentTypeError("value must be exactly 0 or 1")
    return int(value)


def validate_pci_identity(pci_id: int | None, pci_device_id: int | None) -> None:
    """Validate vgpu_unlock's vdev_id/pdev_id pair and its 16-bit packing."""
    if (pci_id is None) != (pci_device_id is None):
        raise ValueError("pci_id and pci_device_id must be supplied together")
    if pci_id is None:
        return

    # Both vgpu_unlock fields are u64, but NVIDIA's current vdev_id contract is
    # exactly DEV_16:SUBDEV_16 and pdev_id is exactly DEV_16.  Rejecting high
    # bits avoids accidentally accepting a vendor/device tuple such as
    # 0x10DE1C81 and silently advertising a different internal identity.
    if pci_id > 0xFFFFFFFF:
        raise ValueError("pci_id must contain exactly a 16-bit device and 16-bit subdevice")
    if pci_device_id > 0xFFFF:
        raise ValueError("pci_device_id must be a 16-bit PCI device ID")
    if (pci_id >> 16) != pci_device_id:
        raise ValueError(
            "pci_id must be packed as (pci_device_id << 16) | subsystem_device_id"
        )


def canonical_uuid(value: str) -> str | None:
    try:
        return str(uuid_module.UUID(value))
    except ValueError:
        return None


def parsed_target_keys(text: str, mdev_uuid: str) -> set[str]:
    parsed = tomllib.loads(text)
    mdev = parsed.get("mdev", {})
    if not isinstance(mdev, dict):
        raise ValueError("TOML mdev value must be a table")
    return {
        str(key) for key in mdev
        if canonical_uuid(str(key)) == mdev_uuid
    }


def located_target_keys(text: str, mdev_uuid: str) -> set[str]:
    located: set[str] = set()
    for line in text.splitlines():
        match = SECTION_RE.match(line)
        if not match:
            continue
        raw_uuid = next(group for group in match.groups() if group is not None)
        if canonical_uuid(raw_uuid) == mdev_uuid:
            located.add(raw_uuid)
    return located


def discard_orphan_generated_markers(lines: list[str]) -> list[str]:
    """Keep a generated marker only when it still labels an mdev table."""
    output: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() in GENERATED_MARKERS:
            next_nonblank = next(
                (candidate for candidate in lines[index + 1 :] if candidate.strip()),
                None,
            )
            if next_nonblank is None or not SECTION_RE.match(next_nonblank):
                continue
        output.append(line)
    return output


def rewrite(
    text: str,
    mdev_uuid: str,
    name: str | None,
    pci_id: int | None = None,
    pci_device_id: int | None = None,
    frl_enabled: int | None = None,
) -> str:
    validate_pci_identity(pci_id, pci_device_id)
    if frl_enabled not in {None, 0, 1}:
        raise ValueError("frl_enabled must be 0, 1, or absent")
    if name is None and (pci_id is not None or frl_enabled is not None):
        raise ValueError("identity fields cannot be written while removing an mdev override")

    parsed_keys = parsed_target_keys(text, mdev_uuid)
    located_keys = located_target_keys(text, mdev_uuid)
    if parsed_keys - located_keys:
        raise ValueError(
            "target mdev UUID uses an unsupported TOML representation; refusing to append a duplicate table"
        )

    output: list[str] = []
    skipping = False
    for line in text.splitlines():
        match = SECTION_RE.match(line)
        if match:
            raw_uuid = next(group for group in match.groups() if group is not None)
            section_uuid = canonical_uuid(raw_uuid)
            skipping = section_uuid == mdev_uuid
            if skipping:
                continue
        elif skipping and ANY_SECTION_RE.match(line):
            skipping = False
        if not skipping:
            output.append(line)

    output = discard_orphan_generated_markers(output)
    while output and not output[-1].strip():
        output.pop()
    if name is not None:
        quoted_name = json.dumps(name, ensure_ascii=True)
        output.extend([
            "",
            "# Per-VM GPU identity; generated atomically by start-vm.sh.",
            f'[mdev."{mdev_uuid}"]',
            f"card_name = {quoted_name}",
            f"adapter_name = {quoted_name}",
        ])
        if pci_id is not None:
            output.extend([
                f"pci_id = 0x{pci_id:X}",
                f"pci_device_id = 0x{pci_device_id:X}",
            ])
        if frl_enabled is not None:
            output.append(f"frl_enabled = {frl_enabled}")
    rewritten = "\n".join(output) + "\n"
    result = tomllib.loads(rewritten)
    result_mdev = result.get("mdev", {})
    result_keys = {
        str(key) for key in result_mdev
        if canonical_uuid(str(key)) == mdev_uuid
    } if isinstance(result_mdev, dict) else set()
    if name is None:
        if result_keys:
            raise ValueError("target mdev UUID survived removal")
    else:
        if result_keys != {mdev_uuid}:
            raise ValueError("target mdev UUID was not written exactly once")
        entry = result_mdev[mdev_uuid]
        if not isinstance(entry, dict) or entry.get("card_name") != name or \
                entry.get("adapter_name") != name or \
                entry.get("pci_id") != pci_id or \
                entry.get("pci_device_id") != pci_device_id or \
                entry.get("frl_enabled") != frl_enabled:
            raise ValueError("written mdev identity failed semantic validation")
    return rewritten


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--uuid", required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--name")
    group.add_argument("--remove", action="store_true")
    parser.add_argument("--pci-id", type=parse_u64)
    parser.add_argument("--pci-device-id", type=parse_u64)
    parser.add_argument("--frl-enabled", type=parse_binary)
    args = parser.parse_args()

    canonical_uuid = str(uuid_module.UUID(args.uuid))
    name = None if args.remove else validate_name(args.name)
    try:
        validate_pci_identity(args.pci_id, args.pci_device_id)
        if args.remove and (args.pci_id is not None or args.frl_enabled is not None):
            raise ValueError("identity fields cannot be supplied with --remove")
    except ValueError as exc:
        parser.error(str(exc))
    original = args.config.read_text(encoding="utf-8")
    args.output.write_text(
        rewrite(
            original,
            canonical_uuid,
            name,
            args.pci_id,
            args.pci_device_id,
            args.frl_enabled,
        ),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
