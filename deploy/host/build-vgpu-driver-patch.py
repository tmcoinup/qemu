#!/usr/bin/env python3
"""Build a fail-closed NVIDIA vGPU 538.33 consumer-ID driver package.

The historical source asset name says 553.24, but the only accepted payload is
the project-verified 538.33 Display.Driver archive.  This tool deliberately
supports only audited profiles.  Adding another profile requires adding its
exact model-section mapping and regression coverage here first.

The output keeps the vendor catalog for provenance, but changing nvgridsw.inf
invalidates it.  A guest-side installer must remove/regenerate/sign the catalog
before invoking pnputil.  The generated manifest records that requirement.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
from typing import Any
import zipfile


SOURCE_ASSET_NAME = "553.24-display-driver.zip"
SOURCE_ZIP_SHA256 = (
    "a3d7ad8b8082d6ac6214565b4766b5190a819bc9b7574765b14897e0db809690"
)
SOURCE_INF_PATH = "Display.Driver/nvgridsw.inf"
SOURCE_INF_SHA256 = (
    "67a240e1d464cf97dabfec1a7cecf000eaa9ddfd702f32ba2c8771f17905dc2b"
)
EXPECTED_DRIVER_VER = "01/25/2024, 31.0.15.3833"
EXPECTED_MANUFACTURER = (
    "%NVIDIA_A% = NVIDIA_Devices,NTamd64.10.0...14393,"
    "NTamd64.10.0...17098"
)
MANIFEST_NAME = ".vgpu-patch-manifest.json"
MANIFEST_SCHEMA = 1


PROFILES: dict[str, dict[str, Any]] = {
    "gtx1050_2gb": {
        "name": "NVIDIA GeForce GTX 1050",
        "vendor_id": "10DE",
        "device_id": "1C81",
        "subsystem_vendor_id": "1028",
        "subsystem_device_id": "11C0",
        "model_sections": {
            "NVIDIA_Devices.NTamd64.10.0...14393": "Section019",
            "NVIDIA_Devices.NTamd64.10.0...17098": "Section020",
        },
    },
}


class Refusal(RuntimeError):
    """An input or output did not match the audited package shape."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _driver_ver(lines: list[bytes]) -> str:
    matches: list[str] = []
    pattern = re.compile(rb"^DriverVer\s*=\s*(.*?)\r\n$")
    for line in lines:
        match = pattern.fullmatch(line)
        if match:
            matches.append(match.group(1).decode("ascii"))
    if matches != [EXPECTED_DRIVER_VER]:
        shown = ", ".join(repr(value) for value in matches) or "missing"
        raise Refusal(
            f"nvgridsw.inf DriverVer is {shown}; expected exactly "
            f"{EXPECTED_DRIVER_VER!r}"
        )
    return matches[0]


def _section_bounds(lines: list[bytes], section: str) -> tuple[int, int]:
    header = f"[{section}]\r\n".encode("ascii")
    indexes = [index for index, line in enumerate(lines) if line == header]
    if len(indexes) != 1:
        raise Refusal(
            f"expected exactly one [{section}] section; found {len(indexes)}"
        )
    start = indexes[0] + 1
    end = len(lines)
    for index in range(start, len(lines)):
        if lines[index].startswith(b"[") and lines[index].endswith(b"]\r\n"):
            end = index
            break
    return start, end


def _target_lines(profile_name: str) -> tuple[dict[str, bytes], bytes]:
    profile = PROFILES[profile_name]
    device = profile["device_id"]
    subdevice = profile["subsystem_device_id"]
    subvendor = profile["subsystem_vendor_id"]
    vendor = profile["vendor_id"]
    string_key = f"NVIDIA_DEV.{device}.{subdevice}.{subvendor}"
    models = {
        model_section: (
            f"%{string_key}% = {install_section}, "
            f"PCI\\VEN_{vendor}&DEV_{device}&SUBSYS_{subdevice}{subvendor}\r\n"
        ).encode("ascii")
        for model_section, install_section in profile["model_sections"].items()
    }
    string_line = f'{string_key} = "{profile["name"]}"\r\n'.encode("ascii")
    return models, string_line


def _has_any_target_reference(lines: list[bytes], profile_name: str) -> bool:
    profile = PROFILES[profile_name]
    needles = (
        f"DEV_{profile['device_id']}".encode("ascii"),
        f"NVIDIA_DEV.{profile['device_id']}".encode("ascii"),
        (
            f"SUBSYS_{profile['subsystem_device_id']}"
            f"{profile['subsystem_vendor_id']}"
        ).encode("ascii"),
    )
    return any(any(needle.lower() in line.lower() for needle in needles) for line in lines)


def _verify_complete_target(lines: list[bytes], profile_name: str) -> None:
    model_lines, string_line = _target_lines(profile_name)
    allowed = set(model_lines.values()) | {string_line}

    for model_section, expected in model_lines.items():
        start, end = _section_bounds(lines, model_section)
        if lines[start:end].count(expected) != 1:
            raise Refusal(
                f"patched INF must contain exactly one audited entry in "
                f"[{model_section}]"
            )
        if lines.count(expected) != 1:
            raise Refusal(
                f"patched INF audited entry for [{model_section}] must occur "
                "exactly once globally"
            )

    strings_start, strings_end = _section_bounds(lines, "Strings")
    if lines[strings_start:strings_end].count(string_line) != 1:
        raise Refusal("patched INF must contain exactly one audited Strings entry")
    if lines.count(string_line) != 1:
        raise Refusal("patched INF audited Strings entry must occur exactly once globally")

    profile = PROFILES[profile_name]
    target_markers = (
        f"DEV_{profile['device_id']}".encode("ascii"),
        f"NVIDIA_DEV.{profile['device_id']}".encode("ascii"),
        (
            f"SUBSYS_{profile['subsystem_device_id']}"
            f"{profile['subsystem_vendor_id']}"
        ).encode("ascii"),
    )
    unexpected = [
        line
        for line in lines
        if any(marker.lower() in line.lower() for marker in target_markers)
        and line not in allowed
    ]
    if unexpected:
        rendered = unexpected[0].decode("ascii", errors="backslashreplace").rstrip()
        raise Refusal(f"unexpected/conflicting target-ID entry: {rendered}")


def patch_inf(source: bytes, profile_name: str) -> bytes:
    """Return the exactly audited INF transformation; safe to call twice."""
    if profile_name not in PROFILES:
        raise Refusal(f"unsupported profile: {profile_name}")
    if b"\x00" in source:
        raise Refusal("nvgridsw.inf unexpectedly contains NUL bytes")
    try:
        source.decode("ascii")
    except UnicodeDecodeError as error:
        raise Refusal("nvgridsw.inf is not ASCII as expected") from error
    if not source or not source.endswith(b"\r\n"):
        raise Refusal("nvgridsw.inf must be non-empty CRLF text")
    if re.search(rb"(?<!\r)\n|\r(?!\n)", source):
        raise Refusal("nvgridsw.inf has unexpected non-CRLF line endings")

    lines = source.splitlines(keepends=True)
    _driver_ver(lines)

    manufacturer_start, manufacturer_end = _section_bounds(lines, "Manufacturer")
    manufacturer_lines = [line.rstrip(b"\r\n") for line in lines[manufacturer_start:manufacturer_end] if line.strip()]
    expected_manufacturer = EXPECTED_MANUFACTURER.encode("ascii")
    if manufacturer_lines != [expected_manufacturer]:
        raise Refusal("nvgridsw.inf Manufacturer model-section mapping changed")

    # These install sections must still exist independently of their model rows.
    _section_bounds(lines, "Section019")
    _section_bounds(lines, "Section020")

    model_lines, string_line = _target_lines(profile_name)
    if _has_any_target_reference(lines, profile_name):
        _verify_complete_target(lines, profile_name)
        return source

    # Insert each model directly before the audited RTX6000-2Q source row whose
    # install section is being reused.  An upstream layout change is a refusal.
    profile = PROFILES[profile_name]
    for model_section, install_section in profile["model_sections"].items():
        start, end = _section_bounds(lines, model_section)
        anchor = (
            f"%NVIDIA_DEV.1E30.1326.10DE% = {install_section}, "
            "PCI\\VEN_10DE&DEV_1E30&SUBSYS_132610DE \r\n"
        ).encode("ascii")
        matches = [index for index in range(start, end) if lines[index] == anchor]
        if len(matches) != 1:
            raise Refusal(
                f"expected one RTX6000-2Q anchor in [{model_section}]; "
                f"found {len(matches)}"
            )
        lines.insert(matches[0], model_lines[model_section])

    strings_start, strings_end = _section_bounds(lines, "Strings")
    string_anchor = (
        'NVIDIA_DEV.1E30.1326.10DE = "NVIDIA GRID RTX6000-2Q"\r\n'
    ).encode("ascii")
    matches = [
        index for index in range(strings_start, strings_end) if lines[index] == string_anchor
    ]
    if len(matches) != 1:
        raise Refusal(
            f"expected one RTX6000-2Q Strings anchor; found {len(matches)}"
        )
    lines.insert(matches[0], string_line)

    patched = b"".join(lines)
    patched_lines = patched.splitlines(keepends=True)
    _verify_complete_target(patched_lines, profile_name)

    # Strong preservation proof: removing only our three exact injected lines
    # must recover the source byte-for-byte.  Existing NVIDIA entries therefore
    # cannot be silently rewritten or dropped.
    injected = set(model_lines.values()) | {string_line}
    recovered = b"".join(line for line in patched_lines if line not in injected)
    if recovered != source:
        raise Refusal("internal preservation check failed while patching nvgridsw.inf")
    return patched


def verify_source_archive(source_zip: Path) -> tuple[zipfile.ZipFile, bytes]:
    if not source_zip.is_file():
        raise Refusal(f"source archive is missing: {source_zip}")
    actual_hash = sha256_file(source_zip)
    if actual_hash != SOURCE_ZIP_SHA256:
        raise Refusal(
            f"source archive SHA256 mismatch: expected {SOURCE_ZIP_SHA256}, "
            f"got {actual_hash}"
        )

    archive = zipfile.ZipFile(source_zip, "r")
    seen: set[str] = set()
    inf_members: list[zipfile.ZipInfo] = []
    for info in archive.infolist():
        name = info.filename
        path = PurePosixPath(name)
        if not name or "\\" in name or path.is_absolute() or ".." in path.parts:
            archive.close()
            raise Refusal(f"unsafe archive member: {name!r}")
        folded = name.casefold().rstrip("/")
        if folded in seen:
            archive.close()
            raise Refusal(f"duplicate archive member: {name!r}")
        seen.add(folded)
        unix_mode = (info.external_attr >> 16) & 0xFFFF
        if unix_mode and stat.S_ISLNK(unix_mode):
            archive.close()
            raise Refusal(f"symbolic links are not allowed in archive: {name!r}")
        if info.flag_bits & 0x1:
            archive.close()
            raise Refusal(f"encrypted archive member is not allowed: {name!r}")
        if name == SOURCE_INF_PATH:
            inf_members.append(info)

    if len(inf_members) != 1:
        archive.close()
        raise Refusal(
            f"expected exactly one {SOURCE_INF_PATH}; found {len(inf_members)}"
        )
    with archive.open(inf_members[0], "r") as stream:
        source_inf = stream.read()
    actual_inf_hash = hashlib.sha256(source_inf).hexdigest()
    if actual_inf_hash != SOURCE_INF_SHA256:
        archive.close()
        raise Refusal(
            f"source nvgridsw.inf SHA256 mismatch: expected {SOURCE_INF_SHA256}, "
            f"got {actual_inf_hash}"
        )
    _driver_ver(source_inf.splitlines(keepends=True))
    return archive, source_inf


def _copy_member(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo, destination: Path
) -> dict[str, Any]:
    digest = hashlib.sha256()
    size = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    with archive.open(info, "r") as source, destination.open("wb") as target:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            target.write(chunk)
            digest.update(chunk)
            size += len(chunk)
    if size != info.file_size:
        raise Refusal(
            f"short extraction for {info.filename}: expected {info.file_size}, got {size}"
        )
    unix_mode = (info.external_attr >> 16) & 0o777
    if unix_mode:
        destination.chmod(unix_mode)
    return {"size": size, "sha256": digest.hexdigest()}


def _canonical_inventory(
    archive: zipfile.ZipFile, patched: bytes
) -> dict[str, dict[str, Any]]:
    """Derive the output inventory from the already locked source archive."""
    files: dict[str, dict[str, Any]] = {}
    for info in archive.infolist():
        if info.is_dir():
            continue
        if info.filename == SOURCE_INF_PATH:
            files[info.filename] = {
                "size": len(patched),
                "sha256": hashlib.sha256(patched).hexdigest(),
            }
            continue

        digest = hashlib.sha256()
        size = 0
        with archive.open(info, "r") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
        if size != info.file_size:
            raise Refusal(
                f"short archive read for {info.filename}: "
                f"expected {info.file_size}, got {size}"
            )
        files[info.filename] = {"size": size, "sha256": digest.hexdigest()}
    return files


def _manifest(profile_name: str, files: dict[str, dict[str, Any]], patched: bytes) -> dict[str, Any]:
    profile = PROFILES[profile_name]
    model_lines, string_line = _target_lines(profile_name)
    return {
        "schema": MANIFEST_SCHEMA,
        "artifact": "nvidia-vgpu-538.33-consumer-id-patch",
        "source": {
            "asset_name": SOURCE_ASSET_NAME,
            "sha256": SOURCE_ZIP_SHA256,
            "inf_path": SOURCE_INF_PATH,
            "inf_sha256": SOURCE_INF_SHA256,
            "driver_ver": EXPECTED_DRIVER_VER,
        },
        "profile": {
            "key": profile_name,
            "name": profile["name"],
            "pci_id": f"{profile['vendor_id']}:{profile['device_id']}",
            "subsystem_id": (
                f"{profile['subsystem_vendor_id']}:{profile['subsystem_device_id']}"
            ),
        },
        "patch": {
            "model_entries": {
                section: line.decode("ascii").rstrip("\r\n")
                for section, line in model_lines.items()
            },
            "strings_entry": string_line.decode("ascii").rstrip("\r\n"),
            "patched_inf_sha256": hashlib.sha256(patched).hexdigest(),
        },
        "catalog": {
            "status": "vendor-catalog-invalid-after-inf-patch",
            "path": "Display.Driver/nvgridsw.cat",
            "required_action": "regenerate-and-sign-before-pnputil",
        },
        "files": dict(sorted(files.items())),
    }


def _load_manifest(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
        if len(raw) > 1024 * 1024:
            raise Refusal(f"manifest is unexpectedly large: {path}")
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Refusal(f"cannot read generated manifest {path}: {error}") from error
    if not isinstance(value, dict):
        raise Refusal(f"generated manifest is not an object: {path}")
    return value


def _validate_inventory_schema(files: object) -> dict[str, dict[str, Any]]:
    if not isinstance(files, dict) or not files:
        raise Refusal("generated manifest has no file inventory")
    for relative, record in files.items():
        if not isinstance(relative, str) or not relative:
            raise Refusal("generated manifest contains an invalid file path")
        if not isinstance(record, dict) or set(record) != {"size", "sha256"}:
            raise Refusal(f"invalid manifest record for {relative}")
        size = record["size"]
        digest = record["sha256"]
        if type(size) is not int or size < 0:
            raise Refusal(f"invalid manifest size for {relative}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Refusal(f"invalid manifest SHA256 for {relative}")
    return files


def verify_output_directory(
    output_dir: Path,
    profile_name: str,
    source_inf: bytes,
    canonical_files: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    if output_dir.is_symlink() or not output_dir.is_dir():
        raise Refusal(f"output is not a regular directory: {output_dir}")
    manifest_path = output_dir / MANIFEST_NAME
    manifest = _load_manifest(manifest_path)
    files = _validate_inventory_schema(manifest.get("files"))
    if files != canonical_files:
        raise Refusal(
            "generated manifest file inventory does not match the locked source archive"
        )

    patched_inf_path = output_dir / SOURCE_INF_PATH
    try:
        patched = patched_inf_path.read_bytes()
    except OSError as error:
        raise Refusal(f"cannot read patched INF: {error}") from error
    if patch_inf(patched, profile_name) != patched:
        raise Refusal("existing patched INF is not idempotent")

    model_lines, string_line = _target_lines(profile_name)
    injected = set(model_lines.values()) | {string_line}
    recovered = b"".join(
        line for line in patched.splitlines(keepends=True) if line not in injected
    )
    if recovered != source_inf:
        raise Refusal("existing output does not preserve the locked source INF")

    actual_paths: set[str] = set()
    for path in output_dir.rglob("*"):
        if path.is_symlink():
            raise Refusal(f"output contains a symbolic link: {path}")
        if path.is_dir():
            continue
        if path.is_file():
            relative = path.relative_to(output_dir).as_posix()
            if relative != MANIFEST_NAME:
                actual_paths.add(relative)
        else:
            raise Refusal(f"output contains a non-regular filesystem node: {path}")
    if actual_paths != set(files):
        missing = sorted(set(files) - actual_paths)
        extra = sorted(actual_paths - set(files))
        raise Refusal(f"output file inventory mismatch; missing={missing}, extra={extra}")

    for relative, expected in canonical_files.items():
        path = output_dir / PurePosixPath(relative)
        if path.stat().st_size != expected.get("size"):
            raise Refusal(f"output size mismatch: {relative}")
        if sha256_file(path) != expected.get("sha256"):
            raise Refusal(f"output SHA256 mismatch: {relative}")

    expected_manifest = _manifest(profile_name, canonical_files, patched)
    if manifest != expected_manifest:
        raise Refusal("generated manifest metadata does not match the audited build")
    return manifest


def build_output_directory(
    archive: zipfile.ZipFile,
    source_inf: bytes,
    output_dir: Path,
    profile_name: str,
) -> tuple[dict[str, Any], bool]:
    patched = patch_inf(source_inf, profile_name)
    if patched == source_inf:
        raise Refusal("locked source archive is unexpectedly already patched")

    if output_dir.exists() or output_dir.is_symlink():
        canonical_files = _canonical_inventory(archive, patched)
        manifest = verify_output_directory(
            output_dir, profile_name, source_inf, canonical_files
        )
        return manifest, False

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.tmp-", dir=output_dir.parent)
    )
    try:
        files: dict[str, dict[str, Any]] = {}
        for info in archive.infolist():
            relative = PurePosixPath(info.filename)
            target = temporary.joinpath(*relative.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            files[info.filename] = _copy_member(archive, info, target)

        inf_path = temporary / SOURCE_INF_PATH
        inf_path.write_bytes(patched)
        files[SOURCE_INF_PATH] = {
            "size": len(patched),
            "sha256": hashlib.sha256(patched).hexdigest(),
        }
        manifest = _manifest(profile_name, files, patched)
        manifest_bytes = (
            json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
        ).encode("utf-8")
        (temporary / MANIFEST_NAME).write_bytes(manifest_bytes)

        # Verify the temporary tree before exposing it at the final path.
        verify_output_directory(temporary, profile_name, source_inf, files)
        try:
            temporary.rename(output_dir)
        except FileExistsError as error:
            raise Refusal(f"output appeared concurrently: {output_dir}") from error
        return manifest, True
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def _default_stage_dir() -> Path:
    if os.environ.get("STAGE_DIR"):
        return Path(os.environ["STAGE_DIR"])
    image_root = Path(os.environ.get("IMAGE_ROOT", "/home/ubuntu/images"))
    return image_root / "staging"


def parse_args(argv: list[str]) -> argparse.Namespace:
    stage_dir = _default_stage_dir()
    parser = argparse.ArgumentParser(
        description=(
            "Build an audited 538.33 Display.Driver directory containing the "
            "selected consumer PCI identity."
        )
    )
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILES),
        default="gtx1050_2gb",
        help="audited target profile (default: %(default)s)",
    )
    parser.add_argument(
        "--source-zip",
        type=Path,
        default=stage_dir / SOURCE_ASSET_NAME,
        help="locked source Display.Driver archive",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "destination directory (default: staging/538.33-PROFILE-patched); "
            "an existing valid artifact is verified and reused"
        ),
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="verify source and patch preconditions without writing output",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="verify an existing output directory without modifying it",
    )
    args = parser.parse_args(argv)
    if args.check_only and args.verify_only:
        parser.error("--check-only and --verify-only are mutually exclusive")
    if args.output_dir is None:
        args.output_dir = stage_dir / f"538.33-{args.profile}-patched"
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    archive: zipfile.ZipFile | None = None
    try:
        archive, source_inf = verify_source_archive(args.source_zip)
        patched = patch_inf(source_inf, args.profile)
        if patched == source_inf:
            raise Refusal("locked source archive is unexpectedly already patched")
        if args.check_only:
            print(
                f"[vgpu-patch] verified source 538.33 and audited patch for "
                f"{args.profile}"
            )
            return 0
        if args.verify_only:
            canonical_files = _canonical_inventory(archive, patched)
            manifest = verify_output_directory(
                args.output_dir, args.profile, source_inf, canonical_files
            )
            print(
                f"[vgpu-patch] verified existing artifact: {args.output_dir} "
                f"({manifest['patch']['patched_inf_sha256']})"
            )
            return 0

        manifest, created = build_output_directory(
            archive, source_inf, args.output_dir, args.profile
        )
        verb = "built" if created else "verified existing"
        print(f"[vgpu-patch] {verb}: {args.output_dir}")
        print(f"[vgpu-patch] DriverVer: {EXPECTED_DRIVER_VER}")
        print(
            f"[vgpu-patch] patched INF SHA256: "
            f"{manifest['patch']['patched_inf_sha256']}"
        )
        print(
            "[vgpu-patch] catalog status: INVALID; guest installer must "
            "regenerate and sign nvgridsw.cat before pnputil"
        )
        return 0
    except (Refusal, OSError, zipfile.BadZipFile) as error:
        print(f"[vgpu-patch] REFUSE: {error}", file=sys.stderr)
        return 1
    finally:
        if archive is not None:
            archive.close()


if __name__ == "__main__":
    raise SystemExit(main())
