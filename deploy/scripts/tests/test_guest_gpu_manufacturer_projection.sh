#!/usr/bin/env bash
# 验证 GPU Manufacturer 只走 Config Manager UI 属性，且直接信任链前后不变。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/scripts/gpu-manufacturer-projection.ps1"
TRUST_HELPER="$REPO_ROOT/deploy/guest-stealth/display-driver-trust.ps1"
PROJECTOR="$REPO_ROOT/deploy/guest-stealth/launcher/gpu-manufacturer-projector.c"
DRIVER_DIR="$REPO_ROOT/deploy/scripts/stock-viogpudo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null || fail "缺少 pwsh"
command -v x86_64-w64-mingw32-gcc >/dev/null || fail "缺少 MinGW"
[[ -f "$HELPER" && -f "$TRUST_HELPER" && -f "$PROJECTOR" ]] \
    || fail "制造商投影/信任源码不完整"
[[ "$(wc -l < "$HELPER")" -le 500 ]] || fail "PowerShell helper 超过 500 行"
[[ "$(wc -l < "$PROJECTOR")" -le 500 ]] || fail "C projector 超过 500 行"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FIXTURE="$TMP_DIR/manufacturer-fixture.ps1"
RUNTIME_HELPER="$TMP_DIR/gpu-manufacturer-projection.ps1"
cp "$HELPER" "$RUNTIME_HELPER"
cp "$TRUST_HELPER" "$TMP_DIR/display-driver-trust.ps1"

cat > "$FIXTURE" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$global:manufacturerCaseName = $env:MANUFACTURER_TEST_CASE
$global:manufacturerTrustReads = 0
$global:manufacturerDriverPath = ''

function Get-PnpDevice {
    param($Class, [switch]$PresentOnly, $ErrorAction)
    return [pscustomobject]@{
        InstanceId = 'PCI\VEN_1AF4&DEV_1050&SUBSYS_138010DE&REV_A2\3&1&0&30'
        Status = 'OK'
        Problem = 'CM_PROB_NONE'
    }
}

function Get-PnpDeviceProperty {
    param($InstanceId, $KeyName, $ErrorAction)
    if ($KeyName -eq 'DEVPKEY_Device_Service') {
        $service = if ($global:manufacturerCaseName -eq 'bad-binding') {
            'BasicDisplay'
        } else {
            'VioGpuDod'
        }
        return [pscustomobject]@{ Type = 'String'; Data = $service }
    }
    if ($KeyName -eq 'DEVPKEY_Device_DriverInfPath') {
        return [pscustomobject]@{ Type = 'String'; Data = 'oem3.inf' }
    }
    if ($KeyName -eq 'DEVPKEY_Device_Manufacturer') {
        $manufacturer = if ($global:manufacturerCaseName -eq 'bad-property') {
            'Red Hat, Inc.'
        } else {
            'NVIDIA'
        }
        return [pscustomobject]@{ Type = 'String'; Data = $manufacturer }
    }
    throw ('意外 PnP 属性：' + $KeyName)
}

function Get-ItemProperty {
    param($LiteralPath, $ErrorAction)
    return [pscustomobject]@{
        Type = 1
        ImagePath = $global:manufacturerDriverPath
    }
}

function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    if ($ClassName -eq 'Win32_PnPSignedDriver') {
        throw '制造商门禁不应查询会滞后/假阴性的 Win32_PnPSignedDriver'
    }
    if ($ClassName -ne 'Win32_SystemDriver') {
        throw ('意外 CIM 类：' + $ClassName)
    }
    $global:manufacturerTrustReads++
    return [pscustomobject]@{
        Name = 'VioGpuDod'
        State = 'Running'
        Started = $true
        PathName = $global:manufacturerDriverPath
    }
}

function Get-AuthenticodeSignature {
    param($LiteralPath, $ErrorAction)
    $thumbprint = if ($global:manufacturerCaseName -eq 'bad-signature') {
        '0000000000000000000000000000000000000000'
    } else {
        'A5D13378E659DDC05C03EE71B432DD667A302999'
    }
    return [pscustomobject]@{
        Status = 'Valid'
        SignerCertificate = [pscustomobject]@{
            Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation'
            Issuer = 'CN=Microsoft Windows Third Party Component CA 2014, O=Microsoft Corporation'
            Thumbprint = $thumbprint
        }
    }
}

$testRoot = Join-Path $env:MANUFACTURER_TEST_ROOT $global:manufacturerCaseName
$systemDirectory = Join-Path (Join-Path $testRoot 'Windows') 'System32'
$driverDirectory = Join-Path $systemDirectory 'drivers'
$infDirectory = Join-Path (Join-Path $testRoot 'Windows') 'INF'
[void](New-Item -ItemType Directory -Path $driverDirectory -Force)
[void](New-Item -ItemType Directory -Path $infDirectory -Force)
$global:manufacturerDriverPath = Join-Path $driverDirectory 'viogpudo.sys'
$publishedInf = Join-Path $infDirectory 'oem3.inf'
Copy-Item -LiteralPath $env:MANUFACTURER_DRIVER_SYS `
    -Destination $global:manufacturerDriverPath
Copy-Item -LiteralPath $env:MANUFACTURER_DRIVER_INF -Destination $publishedInf
if ($global:manufacturerCaseName -eq 'modified-inf') {
    [IO.File]::AppendAllText($publishedInf, 'modified')
}

$projector = if ($global:manufacturerCaseName -eq 'projector-failure') {
    '/usr/bin/gnufalse'
} else {
    '/usr/bin/gnutrue'
}
$failed = $false
$failureMessage = ''
try {
    & $env:MANUFACTURER_HELPER -Vendor NVIDIA `
        -InstanceId 'PCI\VEN_1AF4&DEV_1050&SUBSYS_138010DE&REV_A2\3&1&0&30' `
        -ProjectorPath $projector -SystemDirectory $systemDirectory
} catch {
    $failed = $true
    $failureMessage = $_.Exception.Message
}

if ($global:manufacturerCaseName -eq 'success') {
    if ($failed -or $global:manufacturerTrustReads -ne 2) {
        throw ('成功路径没有在投影前后各验证一次直接信任链：failed=' +
            $failed + '; reads=' + $global:manufacturerTrustReads +
            '; error=' + $failureMessage)
    }
} elseif (-not $failed) {
    throw ('失败用例被错误接受：' + $global:manufacturerCaseName)
}
POWERSHELL

for case_name in success bad-binding bad-signature modified-inf \
        projector-failure bad-property; do
    MANUFACTURER_HELPER="$RUNTIME_HELPER" \
    MANUFACTURER_TEST_ROOT="$TMP_DIR/runtime" \
    MANUFACTURER_DRIVER_SYS="$DRIVER_DIR/viogpudo.sys" \
    MANUFACTURER_DRIVER_INF="$DRIVER_DIR/viogpudo.inf" \
    MANUFACTURER_TEST_CASE="$case_name" \
        pwsh -NoProfile -NonInteractive -File "$FIXTURE" >/dev/null
done

x86_64-w64-mingw32-gcc \
    -std=c11 -Wall -Wextra -Werror -municode -mconsole \
    -static -static-libgcc -Wl,--no-insert-timestamp \
    "$PROJECTOR" -lsetupapi -lcfgmgr32 \
    -o "$TMP_DIR/gpu-manufacturer-projector.exe"
file "$TMP_DIR/gpu-manufacturer-projector.exe" | grep -F 'PE32+ executable' >/dev/null \
    || fail "projector 不是 Windows PE64 EXE"

grep -F 'CM_Set_DevNode_PropertyW' "$PROJECTOR" >/dev/null \
    || fail "projector 没有使用 Config Manager 属性 API"
grep -F '0xa45c254e' "$PROJECTOR" >/dev/null \
    || fail "projector 缺少 DEVPKEY_Device_Manufacturer FMTID"
grep -F '    13' "$PROJECTOR" >/dev/null \
    || fail "projector 缺少 DEVPKEY_Device_Manufacturer PID 13"
if grep -E 'RegSetValue|SetupDiSetDeviceRegistryProperty' "$PROJECTOR" >&2; then
    fail "projector 不得修改 Enum Mfg 或 Class 安装字段"
fi

grep -F "'gpu-manufacturer-projection.ps1', 'gpu-manufacturer-projector.exe'" \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" >/dev/null \
    || fail "respawn 没有持久化 manufacturer helper 与 projector"
grep -F "'display-driver-trust.ps1', 'refresh-gpu-name.ps1'" \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" >/dev/null \
    || fail "respawn 没有给持久 manufacturer helper 发布公共信任 helper"
grep -F "gpu-manufacturer-projection.ps1') -Vendor \$cfg.SpoofVendor" \
    "$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1" >/dev/null \
    || fail "名称刷新任务没有按 profile Vendor 调用 manufacturer helper"
grep -F "Assert-ActiveStockDriver -States @(\$binding)" "$HELPER" >/dev/null \
    || fail "制造商投影前后没有复用活动驱动直接信任链"
if grep -F 'Get-CimInstance -ClassName Win32_PnPSignedDriver' "$HELPER" >&2; then
    fail "制造商投影重新依赖了不可靠的 WMI 签名投影"
fi

echo "OK: GPU manufacturer projection preserves the direct driver trust chain"
