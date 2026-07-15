#!/usr/bin/env bash
# Static/unit coverage for the locked 538.33 -> GTX 1050 INF build pipeline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILDER="$REPO_ROOT/deploy/host/build-vgpu-driver-patch.py"
ASSET_LIB="$REPO_ROOT/deploy/lib/vgpu-driver-assets.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$BUILDER" ]] || fail "builder is missing or not executable: $BUILDER"
python3 -m py_compile "$BUILDER"

python3 - "$BUILDER" "$ASSET_LIB" <<'PY'
import importlib.util
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import zipfile

builder_path = Path(sys.argv[1])
asset_lib = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("vgpu_patch_builder", builder_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def refuse(callable_, contains):
    try:
        callable_()
    except module.Refusal as error:
        assert contains in str(error), (contains, str(error))
    else:
        raise AssertionError(f"expected refusal containing {contains!r}")


# The Python pipeline and shared shell verifier must stay on the same immutable
# source archive and DriverVer.  A filename alone is never accepted as proof.
shell = asset_lib.read_text(encoding="utf-8")
shell_hash = re.search(r"^VGPU_DRIVER_ZIP_SHA256=(\w+)$", shell, re.MULTILINE).group(1)
shell_ver = re.search(r"^VGPU_DRIVER_VERSION=(\S+)$", shell, re.MULTILINE).group(1)
assert module.SOURCE_ZIP_SHA256 == shell_hash
assert module.EXPECTED_DRIVER_VER == f"01/25/2024, {shell_ver}"
assert module.SOURCE_INF_PATH == "Display.Driver/nvgridsw.inf"


def baseline():
    lines = [
        "; fixture\r\n",
        "[Version]\r\n",
        "DriverVer   = 01/25/2024, 31.0.15.3833\r\n",
        "\r\n",
        "[Manufacturer]\r\n",
        "%NVIDIA_A% = NVIDIA_Devices,NTamd64.10.0...14393,NTamd64.10.0...17098\r\n",
        "\r\n",
        "[NVIDIA_Devices.NTamd64.10.0...14393]\r\n",
        "%NVIDIA_DEV.1E30.1325.10DE% = Section019, PCI\\VEN_10DE&DEV_1E30&SUBSYS_132510DE \r\n",
        "%NVIDIA_DEV.1E30.1326.10DE% = Section019, PCI\\VEN_10DE&DEV_1E30&SUBSYS_132610DE \r\n",
        "\r\n",
        "[NVIDIA_Devices.NTamd64.10.0...17098]\r\n",
        "%NVIDIA_DEV.1E30.1325.10DE% = Section020, PCI\\VEN_10DE&DEV_1E30&SUBSYS_132510DE \r\n",
        "%NVIDIA_DEV.1E30.1326.10DE% = Section020, PCI\\VEN_10DE&DEV_1E30&SUBSYS_132610DE \r\n",
        "\r\n",
        "[Section019]\r\n",
        "CopyFiles = foo\r\n",
        "\r\n",
        "[Section020]\r\n",
        "CopyFiles = foo\r\n",
        "\r\n",
        "[Strings]\r\n",
        'NVIDIA_DEV.1E30.1325.10DE = "NVIDIA GRID RTX6000-1Q"\r\n',
        'NVIDIA_DEV.1E30.1326.10DE = "NVIDIA GRID RTX6000-2Q"\r\n',
    ]
    return "".join(lines).encode("ascii")


source = baseline()
patched = module.patch_inf(source, "gtx1050_2gb")
model_14393 = (
    b"%NVIDIA_DEV.1C81.11C0.1028% = Section019, "
    b"PCI\\VEN_10DE&DEV_1C81&SUBSYS_11C01028\r\n"
)
model_17098 = (
    b"%NVIDIA_DEV.1C81.11C0.1028% = Section020, "
    b"PCI\\VEN_10DE&DEV_1C81&SUBSYS_11C01028\r\n"
)
string_line = b'NVIDIA_DEV.1C81.11C0.1028 = "NVIDIA GeForce GTX 1050"\r\n'
assert patched.count(model_14393) == 1
assert patched.count(model_17098) == 1
assert patched.count(string_line) == 1
assert patched.count(b"DEV_1E30&SUBSYS_132610DE") == 2
assert module.patch_inf(patched, "gtx1050_2gb") == patched

# Removing only the three audited lines reconstructs every original byte.
recovered = patched
for line in (model_14393, model_17098, string_line):
    recovered = recovered.replace(line, b"")
assert recovered == source

# A partial/conflicting patch, wrong install-section anchor, wrong version, or
# relaxed subsystem match must all fail closed.
refuse(lambda: module.patch_inf(source + string_line, "gtx1050_2gb"), "audited entry")
refuse(
    lambda: module.patch_inf(source.replace(b"Section020, PCI", b"Section019, PCI"), "gtx1050_2gb"),
    "RTX6000-2Q anchor",
)
refuse(
    lambda: module.patch_inf(source.replace(b"31.0.15.3833", b"31.0.15.5324"), "gtx1050_2gb"),
    "DriverVer",
)
refuse(
    lambda: module.patch_inf(source.replace(b"SUBSYS_132510DE", b"SUBSYS_11C01028", 1), "gtx1050_2gb"),
    "audited entry",
)

# Exact injected rows are not allowed to occur in a different section too.
wrong_section_duplicate = patched.replace(
    b"[NVIDIA_Devices.NTamd64.10.0...14393]\r\n",
    b"[NVIDIA_Devices.NTamd64.10.0...14393]\r\n" + model_17098,
    1,
)
refuse(
    lambda: module.patch_inf(wrong_section_duplicate, "gtx1050_2gb"),
    "exactly once globally",
)

# Existing artifacts are checked against an inventory derived from the locked
# archive, never against hashes supplied only by the artifact's own manifest.
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    archive_path = root / "fixture.zip"
    payload = b"GOOD"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(module.SOURCE_INF_PATH, source)
        archive.writestr("Display.Driver/payload.bin", payload)
    output = root / "output"
    with zipfile.ZipFile(archive_path, "r") as archive:
        canonical_files = module._canonical_inventory(archive, patched)
        built_manifest, created = module.build_output_directory(
            archive, source, output, "gtx1050_2gb"
        )
        assert created
        assert built_manifest["files"] == canonical_files
        reused_manifest, created = module.build_output_directory(
            archive, source, output, "gtx1050_2gb"
        )
        assert not created
        assert reused_manifest == built_manifest

    payload_path = output / "Display.Driver/payload.bin"
    manifest_path = output / module.MANIFEST_NAME

    poisoned_files = {key: dict(value) for key, value in canonical_files.items()}
    poisoned_payload = b"EVIL"
    payload_path.write_bytes(poisoned_payload)
    poisoned_files["Display.Driver/payload.bin"] = {
        "size": len(poisoned_payload),
        "sha256": hashlib.sha256(poisoned_payload).hexdigest(),
    }
    manifest_path.write_text(
        json.dumps(module._manifest("gtx1050_2gb", poisoned_files, patched)),
        encoding="utf-8",
    )
    refuse(
        lambda: module.verify_output_directory(
            output, "gtx1050_2gb", source, canonical_files
        ),
        "locked source archive",
    )
PY

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
printf 'not the locked archive\n' >"$TMP_DIR/$(
    basename "${VGPU_DRIVER_ZIP_NAME:-553.24-display-driver.zip}"
)"
if "$BUILDER" --source-zip "$TMP_DIR/553.24-display-driver.zip" \
        --output-dir "$TMP_DIR/out" >"$TMP_DIR/out.log" 2>"$TMP_DIR/err.log"; then
    fail "an archive with the wrong SHA256 was accepted"
fi
grep -Fq 'REFUSE: source archive SHA256 mismatch' "$TMP_DIR/err.log" \
    || fail "wrong archive hash did not produce a clear refusal"
[[ ! -e "$TMP_DIR/out" ]] || fail "failed validation left an output directory"

echo "PASS: locked 538.33 GTX 1050 INF patch builder"
