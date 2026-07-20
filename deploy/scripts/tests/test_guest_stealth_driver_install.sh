#!/usr/bin/env bash
# 验证统一 EXE 的离线驱动安装顺序、多显卡幂等校验与 3010 重启闭环。
# 下列单引号刻意阻止 Bash 展开内嵌 PowerShell/正则中的 $，中文引号只是测试文案。
# shellcheck disable=SC2016,SC1111
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/deploy/guest-stealth/install-display-driver.ps1"
TRUST_HELPER="$REPO_ROOT/deploy/guest-stealth/display-driver-trust.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
RESTART_HELPER="$REPO_ROOT/deploy/guest-stealth/respawn-restart-state.ps1"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
DRIVER_DIR="$REPO_ROOT/deploy/scripts/stock-viogpudo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$INSTALLER" ]] || fail "缺少离线显示驱动安装脚本"
[[ -f "$TRUST_HELPER" ]] || fail "缺少显示驱动信任 helper"
[[ -f "$RESTART_HELPER" ]] || fail "缺少 respawn 重启状态 helper"
for bounded_file in "$INSTALLER" "$TRUST_HELPER" "$RESTART_HELPER" "$0"; do
    [[ "$(wc -l < "$bounded_file")" -le 500 ]] \
        || fail "显示驱动实现/专项测试超过 500 行: $bounded_file"
done

# pwsh 7 与 Windows PowerShell 5.1 共用语法解析器。这里只做 AST 语法检查，实际
# PnP cmdlet 行为由下方的流程守卫和 Windows VM 验收覆盖。
PS_FILES="$INSTALLER:$TRUST_HELPER:$RESPAWN:$RESTART_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $failed = $false
    foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            $failed = $true
            foreach ($errorItem in $errors) {
                [Console]::Error.WriteLine("{0}: {1}", $path, $errorItem.Message)
            }
        }
    }
    if ($failed) { exit 1 }
' || fail "PowerShell AST 解析失败"

# 在 Linux pwsh 下只加载纯状态判定函数，不调用 Windows PnP/注册表。
# 用单卡、多卡和四个失败维度验证“每个目标都必须健康”的真实逻辑。
INSTALLER_PATH="$INSTALLER" TRUST_HELPER_PATH="$TRUST_HELPER" \
DRIVER_SYS="$DRIVER_DIR/viogpudo.sys" \
DRIVER_INF="$DRIVER_DIR/viogpudo.inf" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $asts = @()
    foreach ($sourcePath in @($env:INSTALLER_PATH, $env:TRUST_HELPER_PATH)) {
        $source = [IO.File]::ReadAllText($sourcePath)
        $tokens = $null
        $errors = $null
        $asts += [System.Management.Automation.Language.Parser]::ParseInput(
            $source, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ("AST 不可用: " + $sourcePath) }
    }

    $neededFunctions = @(
        "Get-DevicePropertyText",
        "Get-PciDisplayState",
        "Test-PnpProblemFree",
        "Get-DisplayStateProblems",
        "Test-AllTargetStatesHealthy",
        "Test-SameTargetSet",
        "Test-ShallowPhysicalDisplayId",
        "Test-StockServiceImagePath",
        "Assert-SafeLocalPath",
        "Assert-SafePlainFile",
        "Assert-SafeDirectory",
        "Assert-ExactFileHash",
        "Assert-WhcpSignature",
        "Get-PublishedInfTrustState",
        "Assert-ActiveStockDriver"
    )
    foreach ($name in $neededFunctions) {
        $definition = $null
        foreach ($ast in $asts) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $name
            }, $true)
            if ($null -ne $definition) { break }
        }
        if ($null -eq $definition) { throw "缺少函数: $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function New-TestDisplayState {
        param(
            [string] $Id,
            [string] $Service = "VioGpuDod",
            [string] $Status = "OK",
            [string] $Problem = "CM_PROB_NONE",
            [string] $InfPath = "oem42.inf",
            [int] $SignedMatchCount = 1,
            [AllowNull()] [string] $SignedInfPath = $null,
            [string] $SignedProvider = "Red Hat, Inc.",
            [bool] $IsSigned = $true,
            [string] $Signer = "Microsoft Windows Hardware Compatibility Publisher"
        )
        if (-not $PSBoundParameters.ContainsKey("SignedInfPath")) {
            $SignedInfPath = $InfPath
        }
        [pscustomobject]@{
            InstanceId = $Id
            Service = $Service
            Status = $Status
            Problem = $Problem
            InfPath = $InfPath
            SignedMatchCount = $SignedMatchCount
            SignedInfPath = $SignedInfPath
            SignedProvider = $SignedProvider
            IsSigned = $IsSigned
            Signer = $Signer
        }
    }

    $idA = "PCI\VEN_1AF4&DEV_1050&SUBSYS_00000001"
    $idB = "PCI\VEN_1AF4&DEV_1050&SUBSYS_00000002"
    $healthyA = New-TestDisplayState -Id $idA
    $healthyB = New-TestDisplayState -Id $idB -Problem "0" -InfPath "OEM7.INF"

    # 执行真实 state collector，证明 WMI 签名关联被带入后验，同时 UI
    # DeviceDesc/Manufacturer 不属于真实驱动健康契约。
    $script:RequestedPropertyKeys = @()
    function Get-PnpDevice {
        [CmdletBinding()]
        param([string] $Class, [switch] $PresentOnly)
        [pscustomobject]@{ InstanceId = $idA; Status = "OK"; Problem = "0" }
    }
    function Get-PnpDeviceProperty {
        [CmdletBinding()]
        param([string] $InstanceId, [string] $KeyName)
        $script:RequestedPropertyKeys += $KeyName
        $value = if ($KeyName -eq "DEVPKEY_Device_Service") {
            "VioGpuDod"
        } elseif ($KeyName -eq "DEVPKEY_Device_DriverInfPath") {
            "oem42.inf"
        } else {
            throw ("不应读取 UI DevProp: " + $KeyName)
        }
        [pscustomobject]@{ Data = $value }
    }
    function Get-CimInstance {
        [CmdletBinding()]
        param([string] $ClassName)
        if ($ClassName -ne "Win32_PnPSignedDriver") {
            throw ("意外 CIM 类: " + $ClassName)
        }
        [pscustomobject]@{
            DeviceID = $idA
            InfName = "oem42.inf"
            DriverProviderName = "Red Hat, Inc."
            IsSigned = $true
            Signer = "Microsoft Windows Hardware Compatibility Publisher"
        }
    }
    $collected = @(Get-PciDisplayState)
    if ($collected.Count -ne 1 -or
        -not (Test-AllTargetStatesHealthy -States $collected `
            -TargetInstanceIds @($idA))) {
        throw "真实 state collector 没有生成完整签名后验状态"
    }

    if (-not (Test-ShallowPhysicalDisplayId -InstanceId $idA)) {
        throw "合法 1AF4:1050 物理目标被拒绝"
    }
    foreach ($deepId in @(
        "PCI\VEN_10DE&DEV_1C82&SUBSYS_1C8210DE",
        "PCI\VEN_1002&DEV_67FF&SUBSYS_67FF1002"
    )) {
        if (Test-ShallowPhysicalDisplayId -InstanceId $deepId) {
            throw ("深层/自签物理目标被浅层门禁接受: " + $deepId)
        }
    }

    if (-not (Test-AllTargetStatesHealthy -States @($healthyA) `
            -TargetInstanceIds @($idA))) {
        throw ("单卡健康场景被误拒绝: " +
            (@(Get-DisplayStateProblems -State $healthyA) -join ", "))
    }
    if (-not (Test-AllTargetStatesHealthy -States @($healthyA, $healthyB) `
            -TargetInstanceIds @($idA, $idB))) {
        throw "多卡全健康场景被误拒绝"
    }
    $uiSpoofed = New-TestDisplayState -Id $idA
    $uiSpoofed | Add-Member -NotePropertyName DeviceDesc `
        -NotePropertyValue "AMD Radeon RX 550"
    $uiSpoofed | Add-Member -NotePropertyName Manufacturer `
        -NotePropertyValue "AMD"
    if (-not (Test-AllTargetStatesHealthy -States @($uiSpoofed) `
            -TargetInstanceIds @($idA))) {
        throw "UI DeviceDesc/Manufacturer 投影不应污染真实包签名判定"
    }

    $badCases = @(
        (New-TestDisplayState -Id $idB -Service "BasicDisplay"),
        (New-TestDisplayState -Id $idB -Status "Error"),
        (New-TestDisplayState -Id $idB -Problem "CM_PROB_FAILED_START"),
        (New-TestDisplayState -Id $idB -InfPath "viogpudo.inf"),
        (New-TestDisplayState -Id $idB -SignedProvider "AMD"),
        (New-TestDisplayState -Id $idB -IsSigned $false),
        (New-TestDisplayState -Id $idB -Signer ""),
        (New-TestDisplayState -Id $idB -SignedInfPath "oem99.inf"),
        (New-TestDisplayState -Id $idB -SignedMatchCount 2)
    )
    foreach ($badB in $badCases) {
        if (Test-AllTargetStatesHealthy -States @($healthyA, $badB) `
                -TargetInstanceIds @($idA, $idB)) {
            throw "多卡场景中的异常目标被其它健康卡遮蔽"
        }
    }
    if (Test-AllTargetStatesHealthy -States @($healthyA) `
            -TargetInstanceIds @($idA, $idB)) {
        throw "消失的原目标被误报为健康"
    }
    if (-not (Test-SameTargetSet -Expected @($idA, $idB) `
            -Actual @($idB, $idA))) {
        throw "同一目标集仅顺序改变时不应失败"
    }
    if (Test-SameTargetSet -Expected @($idA, $idB) -Actual @($idA)) {
        throw "目标集缺卡时被误判为一致"
    }
    if (Test-SameTargetSet -Expected @($idA, $idB) -Actual @($idA, $idA)) {
        throw "重复 InstanceId 遮蔽目标缺失"
    }

    # 在临时 Windows 目录中执行完整 active-trust 函数。注册表、CIM 和签名查询
    # 只替换外部 Windows 接口，真实文件路径遍历和 SHA-256 校验仍执行生产代码。
    $ExpectedHashes = @{
        "viogpudo.sys" = "04e873ad57387a518ad8ccae5116989c63170503c14b9cca0b2067e63876af89"
        "viogpudo.inf" = "48abd56644386e1f0d85c54cd64db93e62a4eb33bc7acb2613f237c6e1c6a0ee"
    }
    $ExpectedWhcpSignerThumbprint = "A5D13378E659DDC05C03EE71B432DD667A302999"
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("vmate-active-driver-" + [Guid]::NewGuid())
    $systemDirectory = Join-Path (Join-Path $testRoot "Windows") "System32"
    $driverTarget = Join-Path (Join-Path $systemDirectory "drivers") "viogpudo.sys"
    $infTarget = Join-Path (Join-Path (Join-Path $testRoot "Windows") "INF") "oem42.inf"
    [void] (New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($driverTarget)) -Force)
    [void] (New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($infTarget)) -Force)
    Copy-Item -LiteralPath $env:DRIVER_SYS -Destination $driverTarget
    Copy-Item -LiteralPath $env:DRIVER_INF -Destination $infTarget
    $script:MockDriverPath = $driverTarget
    $script:MockSignerThumbprint = $ExpectedWhcpSignerThumbprint

    function Stop-DriverInstall {
        param([string] $Message, [int] $Code = 20)
        throw ("STOP[" + $Code + "]: " + $Message)
    }
    function Get-ItemProperty {
        [CmdletBinding()] param([string] $LiteralPath)
        [pscustomobject]@{ Type = 1; ImagePath = $script:MockDriverPath }
    }
    function Get-CimInstance {
        [CmdletBinding()] param([string] $ClassName, [string] $Filter)
        [pscustomobject]@{
            Name = "VioGpuDod"
            State = "Running"
            Started = $true
            PathName = $script:MockDriverPath
        }
    }
    function Get-AuthenticodeSignature {
        [CmdletBinding()] param([string] $LiteralPath)
        [pscustomobject]@{
            Status = "Valid"
            SignerCertificate = [pscustomobject]@{
                Subject = "CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation"
                Issuer = "CN=Microsoft Windows Third Party Component CA 2014, O=Microsoft Corporation"
                Thumbprint = $script:MockSignerThumbprint
            }
        }
    }

    $activeState = New-TestDisplayState -Id $idA -InfPath "oem42.inf"
    try {
        [void] (Assert-ActiveStockDriver -States @($activeState) `
            -SystemDirectory $systemDirectory)

        [IO.File]::AppendAllText($driverTarget, "modified")
        $modifiedRejected = $false
        try {
            Assert-ActiveStockDriver -States @($activeState) -SystemDirectory $systemDirectory
        } catch {
            $modifiedRejected = $_.Exception.Message -match "SHA-256 不匹配"
        }
        if (-not $modifiedRejected) { throw "同服务名的 modified 活动 SYS 未被拒绝" }

        Copy-Item -LiteralPath $env:DRIVER_SYS -Destination $driverTarget -Force
        $script:MockSignerThumbprint = "0000000000000000000000000000000000000000"
        $selfSignedRejected = $false
        try {
            Assert-ActiveStockDriver -States @($activeState) -SystemDirectory $systemDirectory
        } catch {
            $selfSignedRejected = $_.Exception.Message -match "WHCP 签名"
        }
        if (-not $selfSignedRejected) { throw "同服务名的伪造签名活动 SYS 未被拒绝" }

        # 活动 SYS/WHCP 合法时，只有发布 INF 真正不存在才返回可恢复状态；
        # 同名文件一旦存在但摘要错误，AllowMissing 也必须继续 fail closed。
        $script:MockSignerThumbprint = $ExpectedWhcpSignerThumbprint
        Remove-Item -LiteralPath $infTarget -Force
        $missingTrust = Assert-ActiveStockDriver -States @($activeState) `
            -SystemDirectory $systemDirectory -AllowMissingPublishedInf
        if (@($missingTrust.MissingPublishedInfNames).Count -ne 1 -or
            $missingTrust.MissingPublishedInfNames[0] -ine "oem42.inf") {
            throw "缺失发布 INF 没有被精确归类为可恢复状态"
        }

        Copy-Item -LiteralPath $env:DRIVER_INF -Destination $infTarget
        [IO.File]::AppendAllText($infTarget, "modified")
        $modifiedInfRejected = $false
        try {
            Assert-ActiveStockDriver -States @($activeState) `
                -SystemDirectory $systemDirectory -AllowMissingPublishedInf
        } catch {
            $modifiedInfRejected = $_.Exception.Message -match "SHA-256 不匹配"
        }
        if (-not $modifiedInfRejected) {
            throw "已有但摘要错误的发布 INF 被误归类为缺失"
        }
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
' || fail "多 PCI Display 逐目标校验测试失败"

grep -F "Get-PnpDevice -Class 'Display' -PresentOnly" "$TRUST_HELPER" >/dev/null \
    || fail "驱动探测没有排除 ghost 显示设备"
grep -F "DEVPKEY_Device_Service" "$TRUST_HELPER" >/dev/null \
    || fail "驱动探测仍可能依赖可伪装的 FriendlyName"
grep -F "'VioGpuDod'" "$INSTALLER" >/dev/null \
    || fail "缺少真实 VioGpuDod 绑定检查"
grep -F "^PCI\\\\VEN_1AF4&DEV_1050" "$TRUST_HELPER" >/dev/null \
    || fail "缺少 stock 驱动主 PCI ID 白名单"
grep -F '& $pnputilPath /add-driver $infPath /install' "$INSTALLER" >/dev/null \
    || fail "没有执行 pnputil 离线安装"
grep -F "Get-AuthenticodeSignature" "$TRUST_HELPER" >/dev/null \
    || fail "安装前没有验证微软签名"
grep -F "Win32_SystemDriver" "$TRUST_HELPER" >/dev/null \
    || fail "healthy 路径没有关联当前实际加载的 VioGpuDod"
grep -F "Win32_PnPSignedDriver" "$TRUST_HELPER" >/dev/null \
    || fail "后验没有核对 Windows 当前签名驱动关联"
for signed_field in 'Red Hat, Inc.' \
        'Microsoft Windows Hardware Compatibility Publisher' \
        SignedInfPath IsSigned; do
    grep -F "$signed_field" "$TRUST_HELPER" >/dev/null \
        || fail "后验缺少签名关联字段：$signed_field"
done
grep -F "A5D13378E659DDC05C03EE71B432DD667A302999" \
        "$INSTALLER" "$TRUST_HELPER" >/dev/null \
    || fail "活动驱动没有锁定 WHCP 签名者"
grep -F "Assert-SafePlainFile" "$TRUST_HELPER" >/dev/null \
    || fail "活动 SYS/INF 没有逐级拒绝 reparse point"
grep -F -- '-AllowMissingPublishedInf' "$INSTALLER" >/dev/null \
    || fail "活动签名驱动缺失发布 INF 时没有进入受控恢复路径"
grep -F "MissingPublishedInfNames" "$INSTALLER" >/dev/null \
    || fail "发布 INF 缺失状态没有阻止 healthy 快速退出"
grep -F '& $pnputilPath /scan-devices' "$INSTALLER" >/dev/null \
    || fail "恢复后没有通过可信 pnputil 触发 PnP 扫描"
grep -F 'HKLM:\SOFTWARE\StealthGPU\DisplayDriverInstall' "$INSTALLER" >/dev/null \
    || fail "缺少持久化的驱动待重启 marker"
grep -F "\$PendingPhase = 'AwaitingRebootVerification'" "$INSTALLER" >/dev/null \
    || fail "缺少明确的待重启验证阶段"
grep -F '$RestartRequiredExitCode = 30' "$INSTALLER" >/dev/null \
    || fail "待重启契约退出码不是 30"
grep -F -- "-PropertyType MultiString" "$INSTALLER" >/dev/null \
    || fail "多卡 InstanceId 没有用 REG_MULTI_SZ 持久化"
grep -F "SubmittedBootMarker" "$INSTALLER" >/dev/null \
    || fail "marker 没有记录提交安装时的 boot"

if grep -Ei 'Invoke-WebRequest|Invoke-RestMethod|http://|https://' \
        "$INSTALLER" "$TRUST_HELPER" "$RESPAWN" "$RESTART_HELPER" >&2; then
    fail "统一 EXE 安装链仍含 HTTP 请求"
fi
if grep -F 'Disable-PnpDevice' "$INSTALLER" "$TRUST_HELPER" >&2; then
    fail "驱动安装不应禁用正在输出的主显卡"
fi

# 待重启闭环和全目标幂等检查都必须在摘要校验/pnputil 之前。
pending_line="$(grep -n '^\$pendingInstall = Get-PendingDriverInstall$' "$INSTALLER" | cut -d: -f1)"
physical_guard_line="$(grep -n '^\$unsupportedPhysicalTargets = @' "$INSTALLER" | cut -d: -f1)"
healthy_line="$(grep -n '^\$allAlreadyHealthy = Test-AllTargetStatesHealthy' "$INSTALLER" | cut -d: -f1)"
hash_line="$(grep -n '^Assert-EmbeddedDriverPayload$' "$INSTALLER" | cut -d: -f1)"
pnputil_line="$(grep -n '\$pnputilPath /add-driver' "$INSTALLER" | cut -d: -f1)"
[[ -n "$physical_guard_line" && -n "$pending_line" && -n "$healthy_line" && \
    -n "$hash_line" && -n "$pnputil_line" ]] \
    || fail "无法定位驱动幂等流程"
(( physical_guard_line < pending_line && pending_line < healthy_line && \
    healthy_line < hash_line && hash_line < pnputil_line )) \
    || fail "物理 ID 门禁/待重启/快速路径没有先于任何驱动写入"

# 三条成功出口都必须先完成 active trust：重启后二阶段不能先清 marker，
# healthy 快速路径不能只看 Service，pnputil 即时完成也不能直接报告成功。
pending_trust_line="$(grep -n '^    \[void\] (Assert-ActiveStockDriver -States \$before ' \
    "$INSTALLER" | cut -d: -f1)"
active_trust_line="$(grep -n '^    \$activeTrust = Assert-ActiveStockDriver -States \$activeVioStates ' \
    "$INSTALLER" | cut -d: -f1)"
post_install_trust_line="$(grep -n '^\[void\] (Assert-ActiveStockDriver -States \$after ' \
    "$INSTALLER" | cut -d: -f1)"
pending_3010_line="$(grep -n '^if (\$pnputilCode -eq 3010)' "$INSTALLER" | cut -d: -f1)"
healthy_success_line="$(grep -n '^if (\$allAlreadyHealthy -and -not \$repairMissingPublishedInf)' \
    "$INSTALLER" | cut -d: -f1)"
final_success_line="$(grep -n '^    Clear-NewInstallDisplayModeCache$' \
    "$INSTALLER" | tail -n 1 | cut -d: -f1)"
pending_clear_line="$(grep -n '^    Clear-PendingDriverInstall$' "$INSTALLER" | cut -d: -f1)"
[[ -n "$pending_trust_line" && -n "$active_trust_line" && \
    -n "$post_install_trust_line" && -n "$pending_3010_line" && \
    -n "$healthy_success_line" && \
    -n "$final_success_line" && -n "$pending_clear_line" ]] \
    || fail "无法定位三条 active trust 成功出口"
(( pending_trust_line < pending_clear_line && active_trust_line < healthy_success_line && \
    pending_3010_line < post_install_trust_line && \
    post_install_trust_line < final_success_line )) \
    || fail "活动 SYS/INF 信任校验晚于成功出口"

# 3010 必须先写 marker 再返回 30；重启后必须先证明 boot 已变且
# 所有原目标健康，然后才能清 marker。
set_marker_line="$(grep -n '^    Set-PendingDriverInstall ' "$INSTALLER" | cut -d: -f1)"
restart_exit_line="$(grep -n '^    exit \$RestartRequiredExitCode$' "$INSTALLER" | tail -n 1 | cut -d: -f1)"
install_boot_line="$(grep -n '^\$installBootMarker = Get-CurrentBootMarker$' \
    "$INSTALLER" | cut -d: -f1)"
scan_line="$(grep -n '^\s*try { & \$pnputilPath /scan-devices' \
    "$INSTALLER" | cut -d: -f1)"
boot_compare_line="$(grep -n '^    if (\$currentBootMarker -eq ' "$INSTALLER" | cut -d: -f1)"
post_reboot_fail_line="$(grep -n '^    if (-not \$pendingHealthy)' "$INSTALLER" | cut -d: -f1)"
clear_marker_line="$(grep -n '^    Clear-PendingDriverInstall$' "$INSTALLER" | cut -d: -f1)"
[[ -n "$pending_3010_line" && -n "$set_marker_line" && -n "$restart_exit_line" && \
    -n "$install_boot_line" && -n "$scan_line" && -n "$boot_compare_line" && \
    -n "$post_reboot_fail_line" && -n "$clear_marker_line" ]] \
    || fail "无法定位 3010 重启状态机"
(( install_boot_line < pnputil_line && pnputil_line < pending_3010_line && \
    pending_3010_line < set_marker_line && set_marker_line < restart_exit_line && \
    restart_exit_line < scan_line )) \
    || fail "3010 没有按“预取 boot →写 marker →返回 30 →禁止即时后验”处理"
(( boot_compare_line < post_reboot_fail_line && post_reboot_fail_line < clear_marker_line )) \
    || fail "marker 在重启/全目标验证之前被过早清除"

# respawn 必须先让 installer 成功，再运行名称覆盖；否则会重现 BasicDisplay
# 被改名成 GTX、但分辨率仍锁死的现场问题。
driver_call_line="$(grep -n '& \$powershellExe @driverArgs' "$RESPAWN" | cut -d: -f1)"
spoof_call_line="$(grep -n '& \$powershellExe @spoofArgs' "$RESPAWN" | cut -d: -f1)"
[[ -n "$driver_call_line" && -n "$spoof_call_line" ]] \
    || fail "无法定位 respawn 子流程调用"
(( driver_call_line < spoof_call_line )) \
    || fail "GPU 名称覆盖发生在真实驱动安装之前"
if grep -En '(^|[[:space:]])(&[[:space:]]+powershell|Start-Process[[:space:]]+powershell)' \
        "$RESPAWN" >&2; then
    fail "respawn 仍可通过当前目录/PATH 劫持高权限 PowerShell 调用"
fi

# 外层必须把 30 当成“安排重启后二阶段”，不能落入普通失败分支，也不能在
# -NoReboot 下偷偷重启。一次性任务要先注册成功，再调用 shutdown。
grep -F 'if ($driverRc -eq 30)' "$RESPAWN" >/dev/null \
    || fail "respawn 没有识别驱动待重启退出码 30"
grep -F 'Restart-RespawnForPendingWork -PendingExitCode 30' "$RESPAWN" >/dev/null \
    || fail "-NoReboot 路径没有通过统一重启 helper 保留退出码 30"
register_line="$(grep -n 'Register-RespawnResumeTask -MainScriptPath \$MainScriptPath' \
    "$RESTART_HELPER" | head -n 1 | cut -d: -f1)"
shutdown_line="$(grep -n '^    & \$shutdownExe /r ' "$RESTART_HELPER" | cut -d: -f1)"
[[ -n "$register_line" && -n "$shutdown_line" ]] \
    || fail "无法定位驱动二阶段任务/重启调用"
(( register_line < shutdown_line )) \
    || fail "驱动重启发生在一次性恢复任务注册之前"
grep -F -- "-ResumeStage 'Full'" "$RESTART_HELPER" >/dev/null \
    || fail "驱动重启没有明确进入完整恢复阶段"

(cd "$DRIVER_DIR" && sha256sum -c - <<'HASHES'
04e873ad57387a518ad8ccae5116989c63170503c14b9cca0b2067e63876af89  viogpudo.sys
b5122b2e060ec0c2f0157afcdc64c728ec31646819055c8b79ae3f4227472078  viogpudo.cat
48abd56644386e1f0d85c54cd64db93e62a4eb33bc7acb2613f237c6e1c6a0ee  viogpudo.inf
HASHES
) >/dev/null || fail "stock viogpudo 三件套摘要不匹配"

# build 脚本也必须锁定相同摘要，防止运行时检查与构建输入发生漂移。
for hash in \
    04e873ad57387a518ad8ccae5116989c63170503c14b9cca0b2067e63876af89 \
    b5122b2e060ec0c2f0157afcdc64c728ec31646819055c8b79ae3f4227472078 \
    48abd56644386e1f0d85c54cd64db93e62a4eb33bc7acb2613f237c6e1c6a0ee; do
    grep -F "$hash" "$BUILD_SCRIPT" >/dev/null \
        || fail "build-exe.sh 缺少驱动摘要 $hash"
    grep -F "$hash" "$INSTALLER" "$TRUST_HELPER" >/dev/null \
        || fail "显示驱动安装/信任脚本缺少驱动摘要 $hash"
done

echo "OK: guest-stealth offline driver install checks passed"
