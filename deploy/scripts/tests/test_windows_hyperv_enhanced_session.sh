#!/usr/bin/env bash
# Hyper-V Enhanced Session：VMBus 固定传输、RDP GPU/AVC 策略与事务回滚。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.HyperV.EnhancedSession.ps1"
ENTRY="$GPUP/Enable-VMateHyperVEnhancedSession.ps1"
CONNECT="$GPUP/Connect-VMateGpuPVM.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$ENTRY" "$CONNECT"; do
    [[ -f "$file" ]] || fail "missing Enhanced Session file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
done
(( $(wc -l < "$MODULE") <= 500 )) ||
    fail 'Enhanced Session module exceeds 500 lines'

for text in \
    'function Enable-VMateHyperVEnhancedSession' \
    'function Get-VMateHyperVEnhancedSessionStatus' \
    'Set-VMHost -EnableEnhancedSessionMode $true' \
    "Transport -cne 'VMBus'" \
    'bEnumerateHWBeforeSW' \
    'AVCHardwareEncodePreferred' \
    'AVC444ModePreferred' \
    'fDenyTSConnections' \
    'RemoteDesktop-UserMode-In-TCP' \
    'RemoteDesktop-UserMode-In-UDP' \
    'Get-NetTCPConnection -State Listen' \
    'Restore-RegistrySnapshot' \
    'Set-VMHost -EnableEnhancedSessionMode $false' \
    'CredentialPersisted = $false' \
    'RuntimeModelSwitch = $false'; do
    require_text "$text" "$MODULE"
done
require_text '[PSCredential]$GuestCredential' "$ENTRY"
require_text "Join-Path \$env:SystemRoot 'System32\vmconnect.exe'" "$CONNECT"
require_text "Transport = 'VMBus'" "$CONNECT"
require_text 'Get-AuthenticodeSignature -LiteralPath $vmConnect' "$CONNECT"
require_text 'RuntimeModelSwitch = $false' "$CONNECT"

if rg -n 'ConvertFrom-SecureString|Export-Clixml|Set-Content|Add-Type|'\
'mstsc\.exe|SendKeys|mouse_event|keybd_event' "$MODULE" "$ENTRY" "$CONNECT"; then
    fail 'credential persistence or injected input found in Enhanced Session path'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; Enhanced Session static contract passed'
    exit 0
fi

VMATE_HYPERV_ENHANCED="$MODULE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_HYPERV_ENHANCED
$script:hostEnabled = $false
function Import-Module { param($Name, $ErrorAction) }
function Get-VM {
    param($Name, $ErrorAction)
    [pscustomobject]@{ Name = $Name
        Id = [Guid]"282f1a79-363d-4267-a653-994d9b5d1d19"
        State = "Running"; Version = "9.0"
        EnhancedSessionTransportType = "VMBus" }
}
function Get-VMHost {
    param($ErrorAction)
    [pscustomobject]@{ EnableEnhancedSessionMode = $script:hostEnabled }
}
function Set-VMHost {
    param([bool]$EnableEnhancedSessionMode, $ErrorAction)
    $script:hostEnabled = $EnableEnhancedSessionMode
}
function Invoke-VMateHyperVEnhancedSessionGuestConfigure {
    param($VMName, $GuestCredential)
    [pscustomobject]@{ Ready = $true; RestartRequired = $true
        GpuName = "NVIDIA GeForce RTX 4060 Ti"
        Before = [pscustomobject]@{ Registry = @(); Services = @() }
        After = [pscustomobject]@{ Registry = @(); Services = @() } }
}
$secure = ConvertTo-SecureString "test" -AsPlainText -Force
$credential = [PSCredential]::new("mock\\user", $secure)
$result = Enable-VMateHyperVEnhancedSession "mock" $credential
if (-not $result.Ready -or -not $result.HostChanged -or
    -not $result.RestartRequired -or -not $script:hostEnabled -or
    $result.Transport -cne "VMBus" -or $result.CredentialPersisted) {
    throw "Enhanced Session mocked transaction failed"
}
'

echo 'PASS: Hyper-V Enhanced Session transaction contract'
