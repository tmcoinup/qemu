#!/usr/bin/env bash
# 验证 A123/A323 签名 NO_DRV 识别包、安装器幂等判定和统一 EXE 调用顺序。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/deploy/guest-stealth/install-chipset-device.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
PAYLOAD_DIR="$REPO_ROOT/deploy/scripts/stock-intel-chipset-inf"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$INSTALLER" "$RESPAWN" "$BUILD_SCRIPT" "$LAUNCHER"; do
    [[ -f "$path" ]] || fail "缺少文件: $path"
done
[[ "$(wc -l < "$INSTALLER")" -le 500 ]] \
    || fail "芯片组安装器超过 500 行"

PS_FILES="$INSTALLER:$RESPAWN" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $failed = $false
    foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        foreach ($errorItem in $errors) {
            [Console]::Error.WriteLine("{0}: {1}", $path, $errorItem.Message)
        }
        if ($errors.Count -gt 0) { $failed = $true }
    }
    if ($failed) { exit 1 }
' || fail "PowerShell AST 解析失败"

# 只从 AST 加载纯函数，避免在 Linux 上执行脚本主流程。状态矩阵覆盖两个平台、
# ghost 排除后的空集、Code 28、错误类、非 OEM INF、意外服务和错误设备名称。
INSTALLER_PATH="$INSTALLER" PAYLOAD_DIR="$PAYLOAD_DIR" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $source = [IO.File]::ReadAllText($env:INSTALLER_PATH)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "installer AST 不可用" }

    $neededFunctions = @(
        "ConvertTo-ProblemCode",
        "Find-ChipsetPayload",
        "Get-ChipsetStateProblems",
        "Test-AllChipsetStatesHealthy",
        "Test-SameInstanceSet",
        "Assert-PlainPayloadFile",
        "Assert-ExactPayloadHash",
        "Assert-WhcpCatalog",
        "Assert-ChipsetPayload"
    )
    foreach ($name in $neededFunctions) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
        }, $true)
        if ($null -eq $definition) { throw "缺少函数: $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $ChipsetPayloads = @(
        [pscustomobject]@{
            DeviceId = "A323"
            InfName = "CannonLake-HSystem.inf"
            CatName = "cannonlake-h.cat"
            CatalogFile = "CannonLake-H.cat"
            FriendlyName = "Intel(R) SMBus - A323"
            InfHash = "0793ffcb29ba4dd13e62ec1c406884193cbf893d95e0b49840da609d8447a123"
            CatHash = "9e457455e44a4215610c1160c6b3cbe345a4ee8e2af621e51ef6d1079870dba2"
            SignerThumbprint = "580E5B74E4A43390FE113F7CAD3C138E21776F1E"
        },
        [pscustomobject]@{
            DeviceId = "A123"
            InfName = "SunrisePoint-HSystem.inf"
            CatName = "sunrisepoint-h.cat"
            CatalogFile = "SunrisePoint-H.cat"
            FriendlyName = "Intel(R) 100 Series/C230 Series Chipset Family SMBus - A123"
            InfHash = "4d931028bc5d6f1d28ec05f80e1b365d42a3d0ff00b0aeebe582c07dc83a1f70"
            CatHash = "d22cdfa1018a00aa0b61172017f7bfb8f58382bfa80545e56b2b7a16c0242b9b"
            SignerThumbprint = "A3165BF7F09B48194C3724707023CDA874710D16"
        }
    )

    $a323 = Find-ChipsetPayload -InstanceId "PCI\VEN_8086&DEV_A323&SUBSYS_86941043"
    $a123 = Find-ChipsetPayload -InstanceId "PCI\VEN_8086&DEV_A123&SUBSYS_86941043"
    if ($a323.DeviceId -ne "A323" -or $a123.DeviceId -ne "A123") {
        throw "A123/A323 payload 映射错误"
    }
    if ($null -ne (Find-ChipsetPayload -InstanceId "PCI\VEN_8086&DEV_2930")) {
        throw "真实 ICH9 ID 被误判为投影目标"
    }

    function New-State {
        param(
            [object] $Payload,
            [string] $Status = "OK",
            [int] $ProblemCode = 0,
            [string] $ClassName = "System",
            [string] $InfPath = "oem42.inf",
            [string] $Service = "",
            [string] $FriendlyName = ""
        )
        if ([string]::IsNullOrWhiteSpace($FriendlyName)) {
            $FriendlyName = $Payload.FriendlyName
        }
        [pscustomobject]@{
            InstanceId = ("PCI\VEN_8086&DEV_" + $Payload.DeviceId + "&SUBSYS_86941043")
            Status = $Status
            ProblemCode = $ProblemCode
            ClassName = $ClassName
            InfPath = $InfPath
            Service = $Service
            FriendlyName = $FriendlyName
            Payload = $Payload
        }
    }

    $healthyA323 = New-State -Payload $a323
    $healthyA123 = New-State -Payload $a123 -InfPath "OEM7.INF"
    if (-not (Test-AllChipsetStatesHealthy -States @($healthyA323, $healthyA123))) {
        throw "两个平台的健康状态被拒绝"
    }
    $badStates = @(
        (New-State -Payload $a323 -Status "Error"),
        (New-State -Payload $a323 -ProblemCode 28),
        (New-State -Payload $a323 -ClassName "Other"),
        (New-State -Payload $a323 -InfPath ""),
        (New-State -Payload $a323 -Service "i801"),
        (New-State -Payload $a323 -FriendlyName "SM 总线控制器")
    )
    foreach ($bad in $badStates) {
        if (Test-AllChipsetStatesHealthy -States @($healthyA123, $bad)) {
            throw "异常 SMBus 被另一个健康目标遮蔽"
        }
    }
    if ((ConvertTo-ProblemCode -PropertyValue 28 -FallbackValue $null `
            -Status "Error") -ne 28 -or
        (ConvertTo-ProblemCode -PropertyValue $null -FallbackValue "CM_PROB_NONE" `
            -Status "OK") -ne 0 -or
        (ConvertTo-ProblemCode -PropertyValue $null -FallbackValue $null `
            -Status "Error") -ne -1) {
        throw "ProblemCode 归一化错误"
    }
    if (-not (Test-SameInstanceSet -Expected @($healthyA323.InstanceId,
                $healthyA123.InstanceId) -Actual @($healthyA123.InstanceId,
                $healthyA323.InstanceId))) {
        throw "相同目标集因顺序改变而失败"
    }
    if (Test-SameInstanceSet -Expected @($healthyA323.InstanceId,
            $healthyA123.InstanceId) -Actual @($healthyA323.InstanceId)) {
        throw "目标消失未被检测"
    }

    $script:SignerThumbprint = $a323.SignerThumbprint
    function Get-AuthenticodeSignature {
        [CmdletBinding()] param([string] $LiteralPath)
        [pscustomobject]@{
            Status = "Valid"
            SignerCertificate = [pscustomobject]@{
                Subject = "CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation"
                Issuer = "CN=Microsoft Windows Third Party Component CA 2012, O=Microsoft Corporation"
                Thumbprint = $script:SignerThumbprint
            }
        }
    }
    $resolved = Assert-ChipsetPayload -Payload $a323 -Root $env:PAYLOAD_DIR
    if ([IO.Path]::GetFileName($resolved) -ne $a323.InfName) {
        throw "验证后返回了错误 INF"
    }
    $script:SignerThumbprint = "0000000000000000000000000000000000000000"
    $badSignerRejected = $false
    try {
        Assert-WhcpCatalog -Path (Join-Path $env:PAYLOAD_DIR $a323.CatName) `
            -ExpectedThumbprint $a323.SignerThumbprint
    } catch {
        $badSignerRejected = $_.Exception.Message -match "WHCP"
    }
    if (-not $badSignerRejected) { throw "错误 CAT 签名者未被拒绝" }
' || fail "芯片组安装器纯函数测试失败"

(cd "$PAYLOAD_DIR" && sha256sum -c - <<'HASHES'
0793ffcb29ba4dd13e62ec1c406884193cbf893d95e0b49840da609d8447a123  CannonLake-HSystem.inf
9e457455e44a4215610c1160c6b3cbe345a4ee8e2af621e51ef6d1079870dba2  cannonlake-h.cat
4d931028bc5d6f1d28ec05f80e1b365d42a3d0ff00b0aeebe582c07dc83a1f70  SunrisePoint-HSystem.inf
d22cdfa1018a00aa0b61172017f7bfb8f58382bfa80545e56b2b7a16c0242b9b  sunrisepoint-h.cat
HASHES
) >/dev/null || fail "Intel 芯片组 INF/CAT 摘要不匹配"

for hash in \
    0793ffcb29ba4dd13e62ec1c406884193cbf893d95e0b49840da609d8447a123 \
    9e457455e44a4215610c1160c6b3cbe345a4ee8e2af621e51ef6d1079870dba2 \
    4d931028bc5d6f1d28ec05f80e1b365d42a3d0ff00b0aeebe582c07dc83a1f70 \
    d22cdfa1018a00aa0b61172017f7bfb8f58382bfa80545e56b2b7a16c0242b9b; do
    grep -F "$hash" "$INSTALLER" >/dev/null \
        || fail "安装器缺少 payload 摘要 $hash"
    grep -F "$hash" "$BUILD_SCRIPT" >/dev/null \
        || fail "构建器缺少 payload 摘要 $hash"
done

grep -F 'Get-PnpDevice -PresentOnly' "$INSTALLER" >/dev/null \
    || fail "安装器没有排除 ghost 设备"
grep -F "Join-Path \$systemDirectory 'pnputil.exe'" "$INSTALLER" >/dev/null \
    || fail "安装器没有固定 System32 pnputil"
grep -F '& $pnputil /add-driver $infPath /install' "$INSTALLER" >/dev/null \
    || fail "安装器没有调用 pnputil /install"
grep -F "exit \$RestartRequiredExitCode" "$INSTALLER" >/dev/null \
    || fail "安装器没有保留 3010 重启契约"
grep -F 'Needs_NO_DRV' "$INSTALLER" >/dev/null \
    || fail "安装器没有验证 null-driver 语义"
if grep -Ei 'Invoke-WebRequest|Invoke-RestMethod|http://|https://|devcon|testsigning|nointegritychecks' \
        "$INSTALLER" "$RESPAWN" >&2; then
    fail "guest 运行链引入网络、devcon 或签名绕过"
fi

chipset_call="$(grep -n '^& \$powershellExe @chipsetArgs' "$RESPAWN" | cut -d: -f1)"
display_call="$(grep -n '^& \$powershellExe @driverArgs' "$RESPAWN" | cut -d: -f1)"
spoof_call="$(grep -n '^& \$powershellExe @spoofArgs' "$RESPAWN" | cut -d: -f1)"
[[ -n "$chipset_call" && -n "$display_call" && -n "$spoof_call" ]] \
    || fail "无法定位 guest-stealth 三段安装流程"
(( chipset_call < display_call && display_call < spoof_call )) \
    || fail "芯片组/显示驱动/GPU spoof 调用顺序错误"

grep -F 'if ($chipsetRc -eq 30)' "$RESPAWN" >/dev/null \
    || fail "外层没有处理芯片组重启请求"
grep -F 'Register-RespawnResumeTask -KeepFirstLogon:$FirstLogon' "$RESPAWN" >/dev/null \
    || fail "芯片组重启没有复用二阶段恢复任务"
for payload in install-chipset-device.ps1 CannonLake-HSystem.inf cannonlake-h.cat \
        SunrisePoint-HSystem.inf sunrisepoint-h.cat; do
    grep -F "$payload" "$BUILD_SCRIPT" "$LAUNCHER" >/dev/null \
        || fail "单 EXE 接线缺少 $payload"
done

echo "OK: guest-stealth chipset INF install checks passed"
