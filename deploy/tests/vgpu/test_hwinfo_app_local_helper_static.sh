#!/usr/bin/env bash
# Enforce the independent/offline/experimental HWiNFO64 app-local boundary.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HELPER="$REPO_ROOT/deploy/guest/install-hwinfo64-app-local.ps1"
INSTALLER="$REPO_ROOT/deploy/guest/install-nvapi-shim.ps1"
SHIM="$REPO_ROOT/deploy/guest/nvapi-shim/nvapi64.dll"
DOC="$REPO_ROOT/deploy/docs/HWINFO-APP-LOCAL-EXPERIMENT.md"

python3 - "$HELPER" "$INSTALLER" "$SHIM" "$DOC" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

helper_path, installer_path, shim_path, doc_path = map(Path, sys.argv[1:])
helper = helper_path.read_text(encoding="utf-8")
doc = doc_path.read_text(encoding="utf-8")


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def require(needle, source=helper, context="helper"):
    if needle not in source:
        fail(f"{context} lacks {needle!r}")


for needle in (
    "[Parameter(Mandatory = $true)]",
    "[string]$ApplicationExe",
    "'HWiNFO64.exe'",
    "$machine -ne 0x8664",
    "Get-AuthenticodeSignature -LiteralPath $LiteralPath",
    "[string]$signature.Status -cne 'Valid'",
    "$subject -ceq $issuer",
    "$subject -notmatch '(?i)REALiX'",
    "$identityText -notmatch '(?i)HWiNFO'",
    "$identityText -notmatch '(?i)REALiX'",
    "Resolve-RegularFile $ApplicationExe 'ApplicationExe'",
    "Resolve-RegularFile $InstallerPath 'App-local NVAPI installer'",
    "Resolve-RegularFile $X64ShimPath 'x64 NVAPI shim'",
    "& $installer -ApplicationExe $application -Uninstall",
    "-ApplicationExe $application",
    "-X64Path $shim",
    "-ExpectedX64Sha256 $ExpectedX64ShimSha256",
    "does not prove that HWiNFO",
    "[FAKE], GRID, Quadro, or TU104",
):
    require(needle)

for forbidden in (
    "Invoke-WebRequest",
    "Start-BitsTransfer",
    "curl.exe",
    "wget.exe",
    "http://",
    "https://",
    "Take-Own",
    "PendingFileRenameOperations",
    "Set-ItemProperty",
    "Start-Process",
    "Get-ChildItem",
    "System32",
    "SysWOW64",
    "bcdedit",
):
    if forbidden.lower() in helper.lower():
        fail(f"helper contains forbidden network/global/discovery action {forbidden!r}")

hash_pattern = re.compile(
    r"\$Expected(?P<label>Installer|X64Shim)Sha256\s*=\s*"
    r"'(?P<hash>[0-9A-F]{64})'"
)
pinned = {match.group("label"): match.group("hash") for match in hash_pattern.finditer(helper)}
if set(pinned) != {"Installer", "X64Shim"}:
    fail("helper does not pin exactly the installer and x64 shim hashes")

actual_installer = hashlib.sha256(installer_path.read_bytes()).hexdigest().upper()
actual_shim = hashlib.sha256(shim_path.read_bytes()).hexdigest().upper()
if pinned["Installer"] != actual_installer:
    fail("helper's installer hash does not match install-nvapi-shim.ps1")
if pinned["X64Shim"] != actual_shim:
    fail("helper's x64 shim hash does not match nvapi64.dll")

for needle in (
    "独立实验项",
    "不会下载或捆绑 HWiNFO",
    "不会替换 Windows 目录中的 NVAPI",
    "不能保证消失",
    "DEV_1E30",
    "不能证明",
    "install-hwinfo64-app-local.ps1",
):
    require(needle, doc, "documentation")

portable = (helper_path.parents[1] / "package-vgpu-portable.sh").read_text(
    encoding="utf-8"
)
if helper_path.name in portable or "HWINFO-APP-LOCAL-EXPERIMENT" in portable:
    fail("experimental HWiNFO helper was added to the main portable package")

print("PASS: HWiNFO64 helper is explicit, offline, signed-app/x64, app-local, and experimental")
PY
