#!/usr/bin/env bash
# P-11 宿主启动前全量检测/修复门禁；guest 启动策略保持独立。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
HOST_ENV="$GPUP/VMate.P11.HostEnvironment.ps1"
ESP_BOOT="$GPUP/VMate.P11.EspBootManager.ps1"
COLD_START="$GPUP/VMate.P11.ColdStartArtifacts.ps1"
GPU_ISOLATION="$GPUP/VMate.HyperV.GpuPColdStartIsolation.ps1"
CODE_INTEGRITY="$GPUP/VMate.Windows.CodeIntegrity.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$HOST_ENV" "$ESP_BOOT" "$COLD_START" "$GPU_ISOLATION" \
        "$CODE_INTEGRITY"; do
    [[ -s "$file" ]] || fail "missing P-11 host environment asset: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
done

for text in \
    'function Get-VMateP11HostEnvironmentStatus' \
    'function Repair-VMateP11HostEnvironment' \
    'function Assert-VMateP11HostEnvironment' \
    'function Get-VMateP11ForeignKernelActivity' \
    'function Get-VMateP11GpuPColdStartTransactionStatus' \
    'VMate.P11.EspBootManager.ps1' \
    'VMate.P11.ColdStartArtifacts.ps1' \
    'VMate.HyperV.GpuPColdStartIsolation.ps1' \
    "'Microsoft-Hyper-V-All'" \
    "'Microsoft-Hyper-V-Management-PowerShell'" \
    'Resolve-VMateP11HostPartitionCommand' \
    'TestSigningConfigured' \
    'TestSigningActive' \
    'NoIntegrityChecksConfigured' \
    'HypervisorLaunchType' \
    'ColdStartArtifacts' \
    'GpuPColdStartTransactions' \
    'Repair-VMateHyperVGpuPColdStartTransaction' \
    'GpuPColdStartRecovered:' \
    'EspBootManager' \
    'ForeignKernelActivity' \
    'AutomaticStartAction' \
    '-AutomaticStartAction Nothing' \
    '-AutomaticStopAction ShutDown'; do
    require_text "$text" "$HOST_ENV"
done

for text in \
    'function Get-VMateP11EspBootManagerStatus' \
    'function Repair-VMateP11EspBootManager' \
    'bootmgfw.efi.backup' \
    'bootmgfw.efi.vmate-untrusted-' \
    'MicrosoftSigned'; do
    require_text "$text" "$ESP_BOOT"
done

for text in \
    'function Test-VMateP11ColdStartArtifactManifest' \
    'function New-VMateP11ColdStartArtifactManifest' \
    'vmate-p11-cpuid-cold-start-artifacts-v1'; do
    require_text "$text" "$COLD_START"
done

for text in \
    "'hypervisorlaunchtype', 'auto'" \
    "'testsigning', 'on'" \
    "'testsigning', 'off'" \
    "'nointegritychecks', 'off'"; do
    require_text "$text" "$HOST_ENV"
done

# 默认 P-11 路径与 guest 都要求生产 CI；test signing 只保留给显式隔离实验。
require_text 'param([bool]$RequireTestSigning = $false)' "$HOST_ENV"
require_text 'P-11 默认产品路径要求关闭' "$HOST_ENV"
require_text 'Assert-VMateWindowsProductionCodeIntegrity' "$CODE_INTEGRITY"
if rg -ni '\b(bcdedit|testsigning\s+(on|off)|nointegritychecks)\b' \
    "$GPUP/VMate.GpuP.Guest.ps1" \
    "$GPUP/Test-VMateGpuPGuest.ps1" \
    "$GPUP/VMate.GpuP.GuestValidation.ps1" \
    "$GPUP/VMate.GpuP.GuestDeviceReality.ps1" \
    "$GPUP/VMate.GpuP.GuestMonitor.ps1" \
    "$GPUP/VMate.GpuP.GuestMonitorValidation.ps1"; then
    fail 'guest lifecycle must not modify Code Integrity or BCD'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -n "$powershell_bin" ]]; then
    VMATE_P11_HOST_ENV="$HOST_ENV" \
    VMATE_P11_ESP_BOOT="$ESP_BOOT" \
    VMATE_P11_COLD_START="$COLD_START" \
    VMATE_P11_GPU_ISOLATION="$GPU_ISOLATION" \
    VMATE_P11_CI="$CODE_INTEGRITY" \
        "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        foreach ($file in @($env:VMATE_P11_HOST_ENV, $env:VMATE_P11_ESP_BOOT,
                $env:VMATE_P11_COLD_START, $env:VMATE_P11_GPU_ISOLATION,
                $env:VMATE_P11_CI)) {
            $errors = $null
            $tokens = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $file, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) {
                throw (($errors | ForEach-Object Message) -join "; ")
            }
        }
        . $env:VMATE_P11_HOST_ENV
        foreach ($name in @(
                "Get-VMateP11HostEnvironmentStatus",
                "Repair-VMateP11HostEnvironment",
                "Get-VMateP11GpuPColdStartTransactionStatus",
                "Assert-VMateP11HostEnvironment",
                "Get-VMateP11EspBootManagerStatus",
                "Repair-VMateP11EspBootManager",
                "Test-VMateP11ColdStartArtifactManifest")) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
                throw "missing function: $name"
            }
        }
    '
fi

echo 'PASS: P-11 host environment repair/reboot gate contract'
