#!/usr/bin/env bash
# Enforce the fail-closed contract for the NVAPI shim's app-local mode.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
INSTALL_SCRIPT="$REPO_ROOT/deploy/guest/install-nvapi-shim.ps1"

python3 - "$INSTALL_SCRIPT" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def require(needle, context="installer"):
    if needle not in text:
        fail(f"{context} lacks {needle!r}")


def function_body(name):
    match = re.search(
        rf"(?m)^function\s+{re.escape(name)}(?:\s|\()",
        text,
    )
    if not match:
        fail(f"installer lacks function {name}")
    opening = text.find("{", match.start())
    if opening < 0:
        fail(f"function {name} lacks an opening brace")
    depth = 0
    for offset in range(opening, len(text)):
        char = text[offset]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1 : offset]
    fail(f"function {name} has unbalanced braces")


require("[string]$ApplicationExe = ''")
require("Invoke-AppLocalMode $ApplicationExe -Remove:$Uninstall")
require("# App-local mode returns before all system-wide mutation code below.")
require("PendingFileRenameOperations")

dispatch = text.index("Invoke-AppLocalMode $ApplicationExe -Remove:$Uninstall")
system_uninstall = text.index("if ($Uninstall)", dispatch)
system_scratch = text.index("New-Item -Type Directory -Force 'C:\\nv'", dispatch)
if not dispatch < system_uninstall < system_scratch:
    fail("app-local dispatch does not return before system-wide mutation")

invoke = function_body("Invoke-AppLocalMode")
for needle in (
    "Assert-AppLocalPathIsRegular $applicationItem",
    "Get-PeMachine $resolvedApplication",
    "[int]$_.machine -eq $applicationMachine",
    "ApplicationExe must not be inside the Windows directory",
    "Get-AppLocalPairState $target $backup $arch.machine",
    "Get-SystemNvapiPath $arch",
    "Assert-OriginalNvidiaImage $systemOriginal $arch.machine",
    "Stage-VerifiedShim $arch $stagedShim",
    "Assert-OriginalNvidiaImage $stagedOriginal $arch.machine",
    "matching app-local NVAPI pair is already installed",
    "Install-NewAppLocalPair",
    "Update-AppLocalPair",
    "Remove-AppLocalPair",
):
    if needle not in invoke:
        fail(f"Invoke-AppLocalMode lacks {needle!r}")
for forbidden in (
    "Take-Own",
    "Set-ItemProperty",
    "PendingFileRenameOperations",
    "New-Item -Type Directory -Force 'C:\\nv'",
):
    if forbidden in invoke:
        fail(f"app-local dispatcher contains system-wide mutation {forbidden!r}")

regular_path = function_body("Assert-AppLocalPathIsRegular")
for needle in (
    "$ApplicationItem.PSProvider.Name -cne 'FileSystem'",
    "[IO.FileAttributes]::ReparsePoint",
    "$directory = $directory.Parent",
):
    if needle not in regular_path:
        fail(f"app-local path validation lacks {needle!r}")

system_path = function_body("Get-SystemNvapiPath")
for needle in ("'System32'", "'Sysnative'", "'SysWOW64'"):
    if needle not in system_path:
        fail(f"system NVAPI source resolver lacks {needle}")
for forbidden in ("Copy-Item", "Move-Item", "Remove-Item", "Take-Own"):
    if forbidden in system_path:
        fail(f"system NVAPI source resolver mutates files via {forbidden}")

original = function_body("Assert-OriginalNvidiaImage")
for needle in (
    "$version.CompanyName -notmatch '\\ANVIDIA(?: Corporation)?\\z'",
    "[string]$signature.Status -cne 'Valid'",
    "$signerSubject -match 'NVIDIA'",
    "'\\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)'",
    "$signerSubject -ceq [string]$signature.SignerCertificate.Issuer",
    "$isSelfIssued -or",
    "-not $trustedSigner",
):
    if needle not in original:
        fail(f"original-NVAPI signature validation lacks {needle!r}")

state = function_body("Get-AppLocalPairState")
for needle in (
    "$targetExists -xor $backupExists",
    "Conflicting pre-existing local NVAPI files",
    "[IO.FileAttributes]::ReparsePoint",
    "Assert-ShimImage $Target $ExpectedMachine",
    "Assert-OriginalNvidiaImage $Backup $ExpectedMachine",
):
    if needle not in state:
        fail(f"app-local conflict validation lacks {needle!r}")

stage = function_body("Stage-VerifiedShim")
for needle in (
    "$Arch.expected",
    "$Arch.source",
    "$Arch.name",
    "Assert-ShimImage $Destination $Arch.machine",
    "Get-FileHash -LiteralPath $Destination -Algorithm SHA256",
):
    if needle not in stage:
        fail(f"matching-shim staging lacks {needle!r}")

new_pair = function_body("Install-NewAppLocalPair")
for needle in (
    "$targetInstalled = $false",
    "$backupInstalled = $false",
    "Assert-AppLocalPairContent",
    "newly created files were rolled back",
):
    if needle not in new_pair:
        fail(f"new-pair transaction lacks {needle!r}")
if "Move-Item" not in new_pair or "Move-Item -LiteralPath $StagedShim" not in new_pair:
    fail("new-pair transaction does not move the staged matching shim")
if re.search(r"Move-Item[^\r\n]*-Force", new_pair):
    fail("new-pair transaction can overwrite a racing pre-existing DLL")

update_pair = function_body("Update-AppLocalPair")
for needle in (
    '.rollback"',
    "$newTargetInstalled",
    "$newBackupInstalled",
    "Assert-AppLocalPairContent",
    "prior files were restored",
):
    if needle not in update_pair:
        fail(f"idempotent update transaction lacks {needle!r}")

remove_pair = function_body("Remove-AppLocalPair")
for needle in (
    '.remove"',
    "Move-Item -LiteralPath $Target",
    "Move-Item -LiteralPath $Backup",
    "Move-Item -LiteralPath $removedTarget -Destination $Target",
    "the installed pair was restored",
):
    if needle not in remove_pair:
        fail(f"safe app-local uninstall lacks {needle!r}")

content = function_body("Assert-AppLocalPairContent")
for needle in (
    "Get-AppLocalPairState",
    "Get-FileHash -LiteralPath $Target",
    "Get-FileHash -LiteralPath $Backup",
    "failed final hash verification",
):
    if needle not in content:
        fail(f"installed-pair verification lacks {needle!r}")

print("PASS: NVAPI app-local installer fail-closed/static contract")
PY
