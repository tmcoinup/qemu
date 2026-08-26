#!/usr/bin/env bash
# P-11 基础 VHDX 独立克隆、身份边界与自动启动安全策略回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.BaseImage.ps1"
LIFECYCLE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Lifecycle.ps1"
ENTRY="$REPO_ROOT/deploy/windows/gpup/New-VMateGpuPVM.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"; }

[[ -f "$MODULE" ]] || fail 'base image module is missing'
[[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] || \
    fail 'base image module lacks UTF-8 BOM'
require_text 'source-must-be-sysprep-generalized' "$MODULE"
require_text 'Set-VHD -Path ([string]$Plan.DestinationPath)' "$MODULE"
require_text '-ResetDiskIdentifier' "$MODULE"
require_text 'function Wait-VMateVhdFileReleased' "$MODULE"
require_text 'RecoveredManagedMount' "$MODULE"
require_text 'VMate.GpuP.BaseImage.ps1' "$LIFECYCLE"
require_text 'Copy-VMateGpuPBaseImage' "$LIFECYCLE"
require_text '-AutomaticStartAction Nothing' "$LIFECYCLE"
require_text '-AutomaticStopAction ShutDown' "$LIFECYCLE"
require_text '[string]$BaseImagePath' "$ENTRY"
require_text 'WillCloneBaseImage' "$ENTRY"
require_text 'paused-CPUID 路径已停用' "$ENTRY"
require_text "'P11SafePartialIdentityColdBoot'" "$ENTRY"

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    VMATE_BASE_MODULE="$MODULE" "$powershell_bin" -NoLogo -NoProfile \
        -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_BASE_MODULE
        $root = Join-Path ([IO.Path]::GetTempPath()) (
            "vmate-p11-clone-test-" + [Guid]::NewGuid().ToString("N"))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $source = Join-Path $root "generalized.vhdx"
        $destination = Join-Path $root "instance\disk.vhdx"
        [IO.File]::WriteAllBytes($source, [byte[]](1,2,3,4,5,6,7,8))
        $script:resetCalled = $false
        function Get-VM { @() }
        function Get-VMHardDiskDrive { @() }
        function Get-VHD {
            param([string]$Path, [string]$ErrorAction)
            [pscustomobject]@{ Attached=$false; ParentPath=""; Size=[uint64]127GB }
        }
        function Set-VHD {
            param([string]$Path, [switch]$ResetDiskIdentifier,
                [string]$ErrorAction)
            if (-not $ResetDiskIdentifier) { throw "disk ID was not reset" }
            $script:resetCalled = $true
        }
        try {
            $plan = Resolve-VMateGpuPBaseImagePlan -BaseImagePath $source `
                -DestinationVhdPath $destination
            if ($plan.GuestGeneralizationPolicy -cne
                "source-must-be-sysprep-generalized") { throw "policy mismatch" }
            $result = Copy-VMateGpuPBaseImage -Plan $plan
            if (-not $script:resetCalled -or -not $result.DiskIdentifierReset) {
                throw "disk identity reset was not attested"
            }
            if (([IO.File]::ReadAllBytes($destination) -join ",") -cne
                ([IO.File]::ReadAllBytes($source) -join ",")) {
                throw "clone content mismatch"
            }
            if (Test-Path -LiteralPath (Join-Path $root "missing-part")) {
                throw "staging residue was retained"
            }
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force }
    '
else
    echo 'SKIP: PowerShell not found; static clone contract passed'
fi

echo 'PASS: Windows GPU-P generalized base VHDX clone contract'
