#!/usr/bin/env bash
# Hyper-V 直连输入：固定传输、重复事件抑制、失败释放与样例 API 路径兼容。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INPUT="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.Input.ps1"
BRIDGE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.InputBridge.ps1"
STARTER="$REPO_ROOT/deploy/windows/gpup/Start-VMateHyperVInputBridge.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
for file in "$INPUT" "$BRIDGE" "$STARTER"; do
    [[ -f "$file" ]] || fail "missing Hyper-V input file: $file"
    [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] ||
        fail "PowerShell 5.1 UTF-8 BOM missing: $file"
done
(( $(wc -l < "$INPUT") <= 500 )) || fail 'input module exceeds 500 lines'
(( $(wc -l < "$BRIDGE") <= 320 )) || fail 'input bridge exceeds 320 lines'
rg -F --quiet "Transport = 'DirectHyperVCim'" "$INPUT" ||
    fail 'input transport is not fixed'
rg -F --quiet "RuntimeModeSwitchAllowed = \$false" "$BRIDGE" ||
    fail 'bridge does not explicitly prohibit runtime switching'
rg -F --quiet "http://127.0.0.1:" "$BRIDGE" ||
    fail 'bridge is not loopback-only'
if rg -n '0\.0\.0\.0|RuntimeMode.*(Set|Change)|Switch.*Transport' \
        "$INPUT" "$BRIDGE"; then
    fail 'remote binding or runtime input-mode switching found'
fi

powershell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$powershell_bin" ]]; then
    echo 'SKIP: PowerShell not found; Hyper-V input static contract passed'
    exit 0
fi

VMATE_HYPERV_INPUT="$INPUT" VMATE_HYPERV_INPUT_BRIDGE="$BRIDGE" \
"$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_HYPERV_INPUT
. $env:VMATE_HYPERV_INPUT_BRIDGE

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message actual=$Actual expected=$Expected"
    }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "expected failure: $Pattern"
}

$script:vm = [pscustomobject]@{
    ElementName = "mock-vm"; Name = "11111111-2222-3333-4444-555555555555"
    EnabledState = 2
}
$script:keyboard = [pscustomobject]@{
    Kind = "Keyboard"; EnabledState = 2; HealthState = 5
    OperationalStatus = @(2)
}
$script:mouse = [pscustomobject]@{
    Kind = "Mouse"; EnabledState = 2; HealthState = 5
    OperationalStatus = @(2); HorizontalPosition = 10; VerticalPosition = 20
}
$script:head = [pscustomobject]@{
    SystemName = $script:vm.Name; CurrentHorizontalResolution = 1920
    CurrentVerticalResolution = 1080; CurrentRefreshRate = 60
    CurrentBitsPerPixel = 32
}
$script:pressedKeys = @{}
$script:pressedButtons = @{}
$script:calls = [Collections.Generic.List[object]]::new()
$script:failPressCode = $null

function Get-Command {
    param([string]$Name, [object]$ErrorAction)
    return [pscustomobject]@{ Name = $Name; Parameters = @{} }
}
function Get-CimInstance {
    param([string]$Namespace, [string]$ClassName, [object]$ErrorAction)
    if ($ClassName -ceq "Msvm_ComputerSystem") { return $script:vm }
    if ($ClassName -ceq "Msvm_VideoHead") { return $script:head }
    throw "unexpected class $ClassName"
}
function Get-CimAssociatedInstance {
    param($InputObject, [string]$Association, [string]$ResultClassName,
        [object]$ErrorAction)
    if ($ResultClassName -ceq "Msvm_Keyboard") { return $script:keyboard }
    if ($ResultClassName -ceq "Msvm_SyntheticMouse") { return $script:mouse }
    throw "unexpected association result $ResultClassName"
}
function Invoke-CimMethod {
    param($InputObject, [string]$MethodName, [hashtable]$Arguments,
        [object]$ErrorAction)
    [void]$script:calls.Add([pscustomobject]@{
        Kind = $InputObject.Kind; Method = $MethodName
        Arguments = @{} + $Arguments
    })
    switch ($MethodName) {
        "IsKeyPressed" {
            return [pscustomobject]@{ ReturnValue = 0; KeyState =
                $script:pressedKeys.ContainsKey([uint32]$Arguments.KeyCode) }
        }
        "PressKey" {
            $code = [uint32]$Arguments.KeyCode
            if ($null -ne $script:failPressCode -and
                $code -eq [uint32]$script:failPressCode) {
                throw "injected press failure"
            }
            $script:pressedKeys[$code] = $true
        }
        "ReleaseKey" {
            [void]$script:pressedKeys.Remove([uint32]$Arguments.KeyCode)
        }
        "GetButtonState" {
            return [pscustomobject]@{ ReturnValue = 0; IsDown =
                $script:pressedButtons.ContainsKey([uint32]$Arguments.ButtonIndex) }
        }
        "SetButtonState" {
            $button = [uint32]$Arguments.ButtonIndex
            if ([bool]$Arguments.IsDown) { $script:pressedButtons[$button] = $true }
            else { [void]$script:pressedButtons.Remove($button) }
        }
        "SetAbsolutePosition" {
            $script:mouse.HorizontalPosition = [int]$Arguments.HorizontalPosition
            $script:mouse.VerticalPosition = [int]$Arguments.VerticalPosition
        }
        default { throw "unexpected method $MethodName" }
    }
    return [pscustomobject]@{ ReturnValue = 0 }
}

$oldOs = $env:OS
$env:OS = "Windows_NT"
try {
    $session = New-VMateHyperVInputSession "mock-vm"
    Assert-Equal $session.Transport DirectHyperVCim "fixed transport"
    Assert-Equal $session.VMId $script:vm.Name "VM binding"

    $down = Send-VMateHyperVKeyEvent $session Down @(0x11)
    Assert-Equal $down.Forwarded.Count 1 "first key down"
    $again = Send-VMateHyperVKeyEvent $session Down @(0x11)
    Assert-Equal $again.Forwarded.Count 0 "duplicate key down forwarded"
    Assert-Equal $again.Suppressed.Count 1 "duplicate key down suppression"
    Assert-Equal @($script:calls | Where-Object Method -EQ PressKey).Count 1 `
        "duplicate PressKey call"
    $up = Send-VMateHyperVKeyEvent $session Up @(0x11)
    Assert-Equal $up.Forwarded.Count 1 "key up"
    $upAgain = Send-VMateHyperVKeyEvent $session Up @(0x11)
    Assert-Equal $upAgain.Suppressed.Count 1 "duplicate key up suppression"

    $script:failPressCode = [uint32]0x20
    Assert-Throws {
        Send-VMateHyperVKeyEvent $session Down @(0x1F, 0x20)
    } "已释放本批次"
    Assert-Equal $session.PressedKeys.Count 0 "failed batch left tracked key"
    Assert-Equal $script:pressedKeys.Count 0 "failed batch left guest key"
    $script:failPressCode = $null

    $mouseResult = Send-VMateHyperVMouseEvent $session Relative @(
        [pscustomobject]@{ X = 5; Y = -2 },
        [pscustomobject]@{ X = -3; Y = 4 }
    ) -ButtonIndex 0 -ButtonAction Down
    Assert-Equal $mouseResult.FinalPosition.X 12 "relative final X"
    Assert-Equal $mouseResult.FinalPosition.Y 22 "relative final Y"
    Assert-Equal $session.PressedButtons.Count 1 "mouse button tracking"
    $duplicateButton = Send-VMateHyperVMouseEvent $session Absolute @(
        [pscustomobject]@{ X = 12; Y = 22 }
    ) -ButtonIndex 0 -ButtonAction Down
    if ($duplicateButton.ButtonChanged) { throw "duplicate mouse down forwarded" }

    $sessions = @{}
    $query = [Collections.Specialized.NameValueCollection]::new()
    $query["vm"] = "mock-vm"
    $query["action"] = "down"
    $query["code"] = "0x1D,0x38,0x53"
    $bridgeResult = Invoke-VMateHyperVInputBridgeRequest "/sendKey" $query $sessions
    Assert-Equal $bridgeResult.Transport DirectHyperVCim "bridge transport"
    Assert-Equal $bridgeResult.Data.Forwarded.Count 3 "bridge key batch"
    $resolutionQuery = [Collections.Specialized.NameValueCollection]::new()
    $resolutionQuery["vm"] = "mock-vm"
    $resolution = Invoke-VMateHyperVInputBridgeRequest "/getResolution" `
        $resolutionQuery $sessions
    Assert-Equal $resolution.Data.Width 1920 "bridge resolution width"
    Assert-Equal $resolution.Data.RefreshRate 60 "bridge refresh rate"
    Assert-Throws {
        Invoke-VMateHyperVInputBridgeRequest "/sendKey" `
            ([Collections.Specialized.NameValueCollection]::new()) $sessions
    } "缺少请求参数"

    $closed = Close-VMateHyperVInputSession $session
    if (-not $closed.Closed -or $session.PressedButtons.Count -ne 0 -or
        $script:pressedButtons.Count -ne 0) {
        throw "session close did not release mouse button"
    }
    foreach ($item in @($sessions.Values)) {
        [void](Close-VMateHyperVInputSession $item)
    }
} finally {
    $env:OS = $oldOs
}
'

echo 'PASS: Hyper-V direct input and sample-compatible loopback bridge contract'
