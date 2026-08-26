#!/usr/bin/env bash
# GPU-P 动态 RDP：KVP 缺失时 PowerShell Direct 回退、端口门禁与无密码文件。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GPUP="$REPO_ROOT/deploy/windows/gpup"
MODULE="$GPUP/VMate.HyperV.RdpConnection.ps1"
ENTRY="$GPUP/Connect-VMateGpuPRdp.ps1"
OPEN_ENTRY="$GPUP/Open-VMateGpuPRdp.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    rg -F --quiet -- "$1" "$2" || fail "missing '$1' in $2"
}

for file in "$MODULE" "$ENTRY" "$OPEN_ENTRY"; do
    [[ -f "$file" ]] || fail "missing RDP connection file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
done
(( $(wc -l < "$MODULE") <= 560 )) ||
    fail 'RDP connection module exceeds 560 lines'

for text in \
    'function Resolve-VMateGpuPRdpEndpoint' \
    'function Connect-VMateGpuPRdp' \
    'function Open-VMateGpuPExistingRdp' \
    'Get-VMNetworkAdapter -VMName' \
    'Invoke-Command -VMName $VMName -Credential $GuestCredential' \
    "'PowerShellDirectDefaultRoute'" \
    "'HyperVKvp'" \
    'Test-VMateGpuPTcpEndpoint' \
    'BeginConnect($Address, $Port' \
    "Join-Path \$env:SystemRoot 'System32\\mstsc.exe'" \
    'Get-AuthenticodeSignature -LiteralPath $mstsc' \
    'dynamic resolution:i:1' \
    'prompt for credentials:i:1' \
    'password 51:b:' \
    'CredentialPersisted = $false' \
    'PasswordPersisted = $false' \
    'RuntimeModelSwitch = $false' \
    'InputInjection = $false'; do
    require_text "$text" "$MODULE"
done

require_text '[PSCredential]$GuestCredential' "$ENTRY"
require_text "VMate.HyperV.EnhancedSession.ps1" "$ENTRY"
require_text "VMate.HyperV.RdpConnection.ps1" "$ENTRY"
require_text 'Open-VMateGpuPExistingRdp' "$OPEN_ENTRY"
require_text "VMate.HyperV.RdpConnection.ps1" "$OPEN_ENTRY"

if rg -n 'ConvertFrom-SecureString|Export-Clixml|cmdkey|SendKeys|'\
'mouse_event|keybd_event|password 51:b:[0-9A-Fa-f]' \
    "$MODULE" "$ENTRY" "$OPEN_ENTRY"; then
    fail 'credential persistence or injected input found in RDP path'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; RDP connection static contract passed'
    exit 0
fi

VMATE_RDP_MODULE="$MODULE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $env:VMATE_RDP_MODULE, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. $env:VMATE_RDP_MODULE
$text = Get-VMateGpuPRdpFileText -Address "172.24.44.238" `
    -UserName "P11-LAB\VMateLab" -Width 2560 -Height 1440 `
    -FullScreen $false
if ($text -notmatch "desktopwidth:i:2560" -or
    $text -notmatch "desktopheight:i:1440" -or
    $text -notmatch "dynamic resolution:i:1" -or
    $text -match "(?im)^password 51:b:") {
    throw "RDP content contract failed"
}
'

echo 'PASS: Hyper-V GPU-P dynamic RDP connection contract'
