#!/usr/bin/env python3
"""Check or render the managed G-11 vgpu_unlock profile tables.

The live file also contains runtime ``[mdev."UUID"]`` tables.  This helper
therefore never replaces the complete file with the repository template.  It
only replaces the two managed shared profile tables and verifies that every
other parsed TOML value is unchanged.
"""

from __future__ import annotations

import argparse
import copy
import os
import re
import stat
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MANAGED_PROFILES = ("nvidia-256", "nvidia-257")

# The rewriter deliberately accepts only the canonical bare-key spelling used
# by deploy/host/profile_override.toml.  If TOML parses an equivalent quoted or
# dotted representation that cannot be located surgically, fail closed instead
# of appending a second semantic table.
MANAGED_HEADER_RE = re.compile(
    r"^\s*\[\s*profile\s*\.\s*(nvidia-(?:256|257))\s*\]"
    r"\s*(?:#.*)?(?:\r?\n)?$"
)
ANY_TABLE_HEADER_RE = re.compile(
    r"^\s*\[\[?[^\r\n]+\]\]?\s*(?:#.*)?(?:\r?\n)?$"
)
MDEV_HEADER_RE = re.compile(r"^\s*\[\[?\s*mdev(?:\s*[.\]])")


class SyncError(RuntimeError):
    """A fail-closed input or semantic validation error."""


@dataclass(frozen=True)
class TableRange:
    start: int
    end: int


def require_regular_file(path: Path, label: str) -> None:
    if path.is_symlink():
        raise SyncError(f"{label} must not be a symlink: {path}")
    try:
        mode = path.stat().st_mode
    except OSError as exc:
        raise SyncError(f"cannot stat {label} {path}: {exc}") from exc
    if not stat.S_ISREG(mode):
        raise SyncError(f"{label} is not a regular file: {path}")


def read_toml(path: Path, label: str) -> tuple[str, dict[str, Any]]:
    require_regular_file(path, label)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise SyncError(f"cannot read {label} {path}: {exc}") from exc
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise SyncError(f"invalid TOML in {label} {path}: {exc}") from exc
    if not isinstance(parsed, dict):
        raise SyncError(f"{label} root must be a TOML table: {path}")
    return text, parsed


def profile_table(document: dict[str, Any], label: str) -> dict[str, Any]:
    profiles = document.get("profile", {})
    if not isinstance(profiles, dict):
        raise SyncError(f"{label} profile value must be a table")
    return profiles


def managed_semantics(
    document: dict[str, Any], label: str, *, require_all: bool
) -> dict[str, dict[str, Any]]:
    profiles = profile_table(document, label)
    result: dict[str, dict[str, Any]] = {}
    for key in MANAGED_PROFILES:
        value = profiles.get(key)
        if value is None:
            if require_all:
                raise SyncError(f"{label} is missing [profile.{key}]")
            continue
        if not isinstance(value, dict):
            raise SyncError(f"{label} profile.{key} must be a table")
        result[key] = value
    return result


def locate_managed_ranges(text: str, label: str) -> dict[str, TableRange]:
    lines = text.splitlines(keepends=True)
    table_starts = [
        index
        for index, line in enumerate(lines)
        if ANY_TABLE_HEADER_RE.match(line)
    ]
    ranges: dict[str, TableRange] = {}
    for position, start in enumerate(table_starts):
        match = MANAGED_HEADER_RE.match(lines[start])
        if not match:
            continue
        key = match.group(1)
        if key in ranges:
            raise SyncError(f"{label} contains duplicate [profile.{key}] tables")
        end = table_starts[position + 1] if position + 1 < len(table_starts) else len(lines)
        ranges[key] = TableRange(start=start, end=end)
    return ranges


def validate_locatable_managed_tables(
    text: str,
    document: dict[str, Any],
    label: str,
    *,
    require_all: bool,
) -> dict[str, TableRange]:
    semantic = managed_semantics(document, label, require_all=require_all)
    ranges = locate_managed_ranges(text, label)
    for key in semantic:
        if key not in ranges:
            raise SyncError(
                f"{label} profile.{key} uses an unsupported TOML representation; "
                "refusing to append a duplicate table"
            )
    if require_all:
        for key in MANAGED_PROFILES:
            if key not in ranges:
                raise SyncError(f"{label} cannot locate canonical [profile.{key}]")
    return ranges


def validate_template(
    text: str, document: dict[str, Any]
) -> tuple[dict[str, dict[str, Any]], dict[str, TableRange]]:
    if "mdev" in document:
        raise SyncError("template must not contain any mdev table")
    root_keys = set(document)
    if root_keys != {"profile"}:
        unexpected = ", ".join(sorted(root_keys - {"profile"})) or "<missing profile>"
        raise SyncError(
            "template root must contain only profile; "
            f"unexpected or missing root keys: {unexpected}"
        )
    profiles = profile_table(document, "template")
    profile_keys = set(profiles)
    expected_profiles = set(MANAGED_PROFILES)
    if profile_keys != expected_profiles:
        unexpected = sorted(profile_keys - expected_profiles)
        missing = sorted(expected_profiles - profile_keys)
        details: list[str] = []
        if unexpected:
            details.append("unexpected " + ", ".join(unexpected))
        if missing:
            details.append("missing " + ", ".join(missing))
        raise SyncError(
            "template profile keys must be exactly nvidia-256 and nvidia-257: "
            + "; ".join(details)
        )
    semantics = managed_semantics(document, "template", require_all=True)
    ranges = validate_locatable_managed_tables(
        text, document, "template", require_all=True
    )
    return semantics, ranges


def drift_reasons(
    live: dict[str, Any], canonical: dict[str, dict[str, Any]]
) -> list[str]:
    live_profiles = profile_table(live, "config")
    reasons: list[str] = []
    for key in MANAGED_PROFILES:
        if key not in live_profiles:
            reasons.append(f"missing profile.{key}")
        elif live_profiles[key] != canonical[key]:
            reasons.append(f"profile.{key} differs from template")
    return reasons


def without_managed_profiles(document: dict[str, Any]) -> dict[str, Any]:
    projection = copy.deepcopy(document)
    profiles = projection.get("profile")
    if isinstance(profiles, dict):
        for key in MANAGED_PROFILES:
            profiles.pop(key, None)
    return projection


def canonical_profile_text(
    template_text: str, ranges: dict[str, TableRange]
) -> str:
    lines = template_text.splitlines(keepends=True)
    blocks: list[str] = []
    for key in MANAGED_PROFILES:
        table_range = ranges[key]
        block = "".join(lines[table_range.start : table_range.end]).strip("\r\n")
        if not block:
            raise SyncError(f"template [profile.{key}] block is empty")
        blocks.append(block)
    return "\n\n".join(blocks).rstrip("\r\n") + "\n"


def render_merged(
    live_text: str,
    live_document: dict[str, Any],
    template_text: str,
    template_document: dict[str, Any],
) -> str:
    canonical, template_ranges = validate_template(template_text, template_document)
    reasons = drift_reasons(live_document, canonical)
    if not reasons:
        return live_text

    live_ranges = validate_locatable_managed_tables(
        live_text, live_document, "config", require_all=False
    )
    lines = live_text.splitlines(keepends=True)
    removed: set[int] = set()
    for table_range in live_ranges.values():
        removed.update(range(table_range.start, table_range.end))

    if live_ranges:
        insert_at = min(table_range.start for table_range in live_ranges.values())
    else:
        insert_at = next(
            (
                index
                for index, line in enumerate(lines)
                if MDEV_HEADER_RE.match(line)
            ),
            len(lines),
        )

    before = "".join(
        line
        for index, line in enumerate(lines[:insert_at])
        if index not in removed
    )
    after = "".join(
        line
        for index, line in enumerate(lines[insert_at:], start=insert_at)
        if index not in removed
    )
    canonical_text = canonical_profile_text(template_text, template_ranges)

    merged = before
    if merged and not merged.endswith(("\n", "\r")):
        merged += "\n"
    if merged and not merged.endswith(("\n\n", "\r\n\r\n")):
        merged += "\n"
    merged += canonical_text
    if after:
        if not merged.endswith(("\n\n", "\r\n\r\n")) and not after.startswith(
            ("\n", "\r")
        ):
            merged += "\n"
        merged += after

    try:
        merged_document = tomllib.loads(merged)
    except tomllib.TOMLDecodeError as exc:
        raise SyncError(f"rendered profile override is invalid TOML: {exc}") from exc

    merged_managed = managed_semantics(
        merged_document, "rendered config", require_all=True
    )
    if merged_managed != canonical:
        raise SyncError("rendered managed profile semantics differ from template")
    if without_managed_profiles(merged_document) != without_managed_profiles(
        live_document
    ):
        raise SyncError("rendered config changed an unknown profile, mdev, or other value")
    return merged


def output_aliases_input(output: Path, config: Path) -> bool:
    if os.path.abspath(output) == os.path.abspath(config):
        return True
    try:
        return output.exists() and os.path.samefile(output, config)
    except OSError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="check or render managed G-11 vgpu_unlock profile tables"
    )
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        template_text, template_document = read_toml(args.template, "template")
        live_text, live_document = read_toml(args.config, "config")
        canonical, _ = validate_template(template_text, template_document)

        # Even check mode verifies that any existing managed live table can be
        # located safely.  A later apply must never reinterpret the same input
        # more permissively than check did.
        validate_locatable_managed_tables(
            live_text, live_document, "config", require_all=False
        )
        reasons = drift_reasons(live_document, canonical)
        if args.check:
            if reasons:
                print("profile override drift: " + "; ".join(reasons), file=sys.stderr)
                return 1
            print("profile override managed profiles are synchronized")
            return 0

        assert args.output is not None
        if args.output.is_symlink():
            raise SyncError(f"output must not be a symlink: {args.output}")
        if output_aliases_input(args.output, args.config):
            raise SyncError("output must be different from the live config")
        merged = render_merged(
            live_text, live_document, template_text, template_document
        )
        try:
            args.output.write_text(merged, encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise SyncError(f"cannot write output {args.output}: {exc}") from exc
        print(f"rendered synchronized profile override: {args.output}")
        return 0
    except SyncError as exc:
        print(f"profile override sync: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
