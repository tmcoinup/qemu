#!/usr/bin/env bash
# 验证 guest 侧 AutoDetect 映射与受审计 AIB 板卡目录同步。
#
# clone 后 guest 只能从物理 carrier SUBSYS 反查完整逻辑 bundle；真实 AIB subsystem
# 不得出现在物理 virtio 节点上。未知或旧式“主芯片号 carrier”必须拒绝。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPOOF="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
APPLY_SUPPORT="$REPO_ROOT/deploy/scripts/gpu-spoof-apply-support.ps1"
GPU_CONTRACT="$REPO_ROOT/deploy/scripts/gpu-board-identity-contract.ps1"
GPU_BOARDS="$REPO_ROOT/deploy/hardware/gpu-boards.json"
GPU_CASE_HELPER="$SCRIPT_DIR/fixtures/gpu_board_catalog_cases.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$APPLY_SUPPORT" ]] || fail "缺少 apply AutoDetect helper: $APPLY_SUPPORT"
[[ -f "$GPU_CONTRACT" ]] || fail "缺少 guest GPU identity contract"
[[ -f "$GPU_BOARDS" ]] || fail "缺少 AIB GPU 板卡目录: $GPU_BOARDS"
[[ -f "$GPU_CASE_HELPER" ]] || fail "缺少离线 GPU 板卡测试 helper"
grep -F "Join-Path \$PSScriptRoot 'gpu-spoof-apply-support.ps1'" "$SPOOF" >/dev/null \
    || fail "apply 没有从同目录加载 AutoDetect helper"
grep -F 'Get-GpuBoardAutoDetectProfile -Subsys $subsys' "$APPLY_SUPPORT" >/dev/null \
    || fail "AutoDetect 没有使用共享 guest GPU identity contract"

GPU_CONTRACT="$GPU_CONTRACT" GPU_CASE_HELPER="$GPU_CASE_HELPER" \
    GPU_BOARDS="$GPU_BOARDS" \
    pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:GPU_CONTRACT
. $env:GPU_CASE_HELPER
$cases = @(Get-TestGpuBoardCases $env:GPU_BOARDS)
Assert-TestGpuBoardCoverage $cases
$contracts = @(Get-GpuBoardIdentityContracts)
if ($contracts.Count -ne $cases.Count) { throw "guest contract 数量不是 18" }
$displayNames = New-Object Collections.Generic.List[string]
$fields = [ordered]@{
    CarrierVendorId="CarrierVendor"; CarrierDeviceId="CarrierDevice"
    SpoofName="Name"; SpoofVendor="Vendor"; SpoofBios="Bios"
    SpoofRamMb="RamMb"; SpoofMemoryType="MemoryType"
    SpoofMemoryBusWidthBits="Width"; SpoofBaseClockKHz="Base"
    SpoofBoostClockKHz="Boost"; SpoofMemoryClockKHz="Memory"
    SpoofSliSupported="Sli"; SpoofPciVendorId="PciVendor"
    SpoofPciDeviceId="Device"; SpoofSubsystemVendorId="SubVendor"
    SpoofSubsystemDeviceId="SubDevice"; SpoofRevisionId="Revision"
}
foreach ($case in $cases) {
    $contract = Get-GpuBoardIdentityContract $case.CarrierVendor `
        $case.CarrierDevice
    if ($null -eq $contract) { throw ("缺少 carrier：" + $case.Carrier) }
    foreach ($entry in $fields.GetEnumerator()) {
        if ($contract.($entry.Key) -cne $case.($entry.Value)) {
            throw ("carrier 字段偏移：" + $case.Carrier + "/" + $entry.Key)
        }
    }
    $profile = Get-GpuBoardAutoDetectProfile $case.Carrier
    if ($null -eq $profile -or $profile.Name -cne $case.Name -or
        $profile.Vendor -cne $case.Vendor) {
        throw ("AutoDetect profile 偏移：" + $case.Carrier)
    }
    $expectedDisplayName = $case.Name -replace " \([^()]+\)$", ""
    $displayName = Get-GpuStandardDisplayName `
        -PciVendorId $case.PciVendor -PciDeviceId $case.Device
    if ($displayName -cne $expectedDisplayName -or $displayName.Contains("(")) {
        throw ("Windows 标准显示名映射错误：" + $case.Carrier + "/" + $displayName)
    }
    $displayNames.Add($displayName)
}
$groups = @($displayNames | Group-Object)
if ($groups.Count -ne 6 -or @($groups | Where-Object Count -ne 3).Count -ne 0) {
    throw "18 块 AIB carrier 未精确映射为 6 个标准显示名（每组 3 块）"
}
foreach ($unknownLogicalId in @(
        @(0x10DE, 0xFFFF), @(0xFFFF, 0x1C82), @(0x1002, 0x1C82))) {
    $rejected = $false
    try {
        Get-GpuStandardDisplayName `
            -PciVendorId $unknownLogicalId[0] -PciDeviceId $unknownLogicalId[1]
    } catch { $rejected = $true }
    if (-not $rejected) { throw "未知逻辑主 ID 未 fail-closed" }
}
foreach ($unknown in @(
        "A1131AF4", "138010DE", "1D0110DE", "1C8110DE",
        "1C8210DE", "699F1002", "67FF1002")) {
    if ($null -ne (Get-GpuBoardAutoDetectProfile $unknown)) {
        throw ("未知或旧式 carrier 被接受：" + $unknown)
    }
}
' >/dev/null

# 重复执行时 DriverDesc 已经是标准名称，Class target 只能取自严格 Stage receipt
# 与当前 Enum Driver 的交叉绑定，RDP/其他显示节点的名称不能参与目标选择。
APPLY_SUPPORT="$APPLY_SUPPORT" \
    pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:APPLY_SUPPORT, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "apply support AST parse failed" }
foreach ($functionName in @(
        "Resolve-GpuSpoofActiveClassSubkey",
        "Assert-GpuSpoofActiveClassBinding")) {
    $functionAst = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
    }, $true)
    if ($null -eq $functionAst) {
        throw ("缺少 active Class helper：" + $functionName)
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$source = "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1021AF4&REV_A1\3&AIB&0&30"
$driver = "{4d36e968-e325-11ce-bfc1-08002be10318}\0000"
if ((Resolve-GpuSpoofActiveClassSubkey -SourceInstanceId $source `
        -DriverBinding $driver -StagedClassSubkey "0000") -cne "0000") {
    throw "标准名称重复执行没有解析出唯一 active Class"
}
if ((Resolve-GpuSpoofActiveClassSubkey -SourceInstanceId $source `
        -DriverBinding $driver -StagedClassSubkey "0000" `
        -RequestedSubkey "0000") -cne "0000") {
    throw "显式 active -Subkey 被错误拒绝"
}
foreach ($bad in @(
        @{ Source=$source; Driver=$driver; Staged="0001"; Requested="" },
        @{ Source=$source; Driver=$driver; Staged="0000"; Requested="0001" },
        @{ Source="ROOT\RDPINDIRECTDISPLAY\0000"; Driver=$driver
            Staged="0000"; Requested="" },
        @{ Source=$source; Driver="{4d36e968-e325-11ce-bfc1-08002be10318}\RDP"
            Staged="0000"; Requested="" })) {
    $rejected = $false
    try {
        Resolve-GpuSpoofActiveClassSubkey -SourceInstanceId $bad.Source `
            -DriverBinding $bad.Driver -StagedClassSubkey $bad.Staged `
            -RequestedSubkey $bad.Requested | Out-Null
    } catch { $rejected = $true }
    if (-not $rejected) { throw "非法或非唯一 Class 绑定未被拒绝" }
}
Assert-GpuSpoofActiveClassBinding -Service "VioGpuDod" `
    -ClassInfPath "oem3.inf" -ClassInfSection "VioGpuDod_Inst" `
    -StagedDriverInfPath "oem3.inf"
foreach ($badBinding in @(
        @{ Service="BasicDisplay"; InfPath="oem3.inf"
            Section="VioGpuDod_Inst"; Staged="oem3.inf" },
        @{ Service="VioGpuDod"; InfPath="oem4.inf"
            Section="VioGpuDod_Inst"; Staged="oem3.inf" },
        @{ Service="VioGpuDod"; InfPath="oem3.inf"
            Section="Other_Inst"; Staged="oem3.inf" },
        @{ Service="VioGpuDod"; InfPath="oem3.inf"
            Section="VioGpuDod_Inst"; Staged="display.inf" })) {
    $rejected = $false
    try {
        Assert-GpuSpoofActiveClassBinding -Service $badBinding.Service `
            -ClassInfPath $badBinding.InfPath `
            -ClassInfSection $badBinding.Section `
            -StagedDriverInfPath $badBinding.Staged
    } catch { $rejected = $true }
    if (-not $rejected) {
        throw "非法或漂移的 active Service/INF 绑定未被拒绝"
    }
}
' >/dev/null

grep -F 'if ($AutoDetect -or -not $ListOnly)' "$SPOOF" >/dev/null \
    || fail "手工 apply 路径没有先读取当前 physical carrier"
grep -F 'Assert-GpuSpoofAibProfile -Expected $detectedProfile -Actual $requestedProfile' \
    "$SPOOF" >/dev/null || fail "手工 apply 路径没有执行 AIB canonical bundle 门禁"

# 直接覆盖不带 -AutoDetect 的参数入口：每个用户可写规格字段只改一项，也必须在
# Stage/注册表首写之前被拒绝，不能依赖后置 NVAPI reader 才发现混搭。
APPLY_SUPPORT="$APPLY_SUPPORT" GPU_CASE_HELPER="$GPU_CASE_HELPER" \
    GPU_BOARDS="$GPU_BOARDS" \
    pwsh -NoLogo -NoProfile -NonInteractive -Command '
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:APPLY_SUPPORT, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "apply support AST parse failed" }
$functionAst = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq "Assert-GpuSpoofAibProfile"
}, $true)
if ($null -eq $functionAst) { throw "缺少手工 AIB bundle 门禁" }
. ([scriptblock]::Create($functionAst.Extent.Text))
. $env:GPU_CASE_HELPER
$cases = @(Get-TestGpuBoardCases $env:GPU_BOARDS)
Assert-TestGpuBoardCoverage $cases
foreach ($case in $cases) {
    $expected = @{
        Name=$case.Name; Vendor=$case.Vendor; Bios=$case.Bios
        RamMb=$case.RamMb; MemoryType=$case.MemoryType
        BusWidthBits=$case.Width; BaseClockKHz=$case.Base
        BoostClockKHz=$case.Boost; MemoryClockKHz=$case.Memory
        SliSupported=$case.Sli; PciVendorId=$case.PciVendor
    }
    Assert-GpuSpoofAibProfile -Expected $expected -Actual $expected
    foreach ($field in @(
            "Name", "Vendor", "Bios", "RamMb", "MemoryType", "BusWidthBits",
            "BaseClockKHz", "BoostClockKHz", "MemoryClockKHz", "SliSupported")) {
        $mixed = $expected.Clone()
        $mixed[$field] = if ($mixed[$field] -is [string]) {
            [string]$mixed[$field] + "-MIXED"
        } else { [int]$mixed[$field] + 1 }
        $rejected = $false
        try { Assert-GpuSpoofAibProfile -Expected $expected -Actual $mixed }
        catch { $rejected = $true }
        if (-not $rejected) {
            throw ("手工混搭字段未拒绝：" + $case.StableId + "/" + $field)
        }
    }
}
' >/dev/null

echo "OK: guest AIB carrier map matches audited board catalog"
