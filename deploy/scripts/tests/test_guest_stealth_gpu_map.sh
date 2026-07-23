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
}
foreach ($unknown in @(
        "A1131AF4", "138010DE", "1D0110DE", "1C8110DE",
        "1C8210DE", "699F1002", "67FF1002")) {
    if ($null -ne (Get-GpuBoardAutoDetectProfile $unknown)) {
        throw ("未知或旧式 carrier 被接受：" + $unknown)
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
