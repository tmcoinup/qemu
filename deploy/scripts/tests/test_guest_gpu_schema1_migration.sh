#!/usr/bin/env bash
# 使用纯内存 RegistryKey 替身验证 versioned schema-1 只作为一次性迁移提示。
# 测试通过 PowerShell AST 提取无副作用函数，不访问 Linux 上不存在的注册表。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REFRESH_SCRIPT="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null 2>&1 || fail "缺少 pwsh"

REFRESH_SCRIPT="$REFRESH_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:REFRESH_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "refresh AST parse failed" }

# 仅加载 schema-1 hint 直接依赖的函数，避免执行脚本主体和真实 HKLM 投影。
foreach ($name in @(
    "Get-ExactRegistryValue", "Assert-GpuIdentityStrings",
    "Get-LegacyVersionedIdentityHint"
)) {
    $node = $ast.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq $name
    }, $true)
    if ($null -eq $node) { throw ("缺少 refresh 函数：" + $name) }
    Invoke-Expression $node.Extent.Text
}

function New-FakeRegistryKey {
    $key = [pscustomobject]@{ Values=@{}; Kinds=@{} }
    $key | Add-Member ScriptMethod GetValueNames { return @($this.Values.Keys) }
    $key | Add-Member ScriptMethod GetValueKind { param($Name) return $this.Kinds[$Name] }
    $key | Add-Member ScriptMethod GetValue {
        param($Name, $DefaultValue, $Options)
        if ($this.Values.ContainsKey($Name)) { return $this.Values[$Name] }
        return $DefaultValue
    }
    return $key
}

function Set-FakeValue($Key, [string]$Name, $Value, $Kind) {
    $Key.Values[$Name] = $Value
    $Key.Kinds[$Name] = $Kind
}

function New-LegacyFixture {
    $string = [Microsoft.Win32.RegistryValueKind]::String
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    $id = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    $source = "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\3&TEST&0&30"
    $root = New-FakeRegistryKey; $version = New-FakeRegistryKey
    Set-FakeValue $root CurrentIdentity $id $string
    Set-FakeValue $version IdentitySchemaVersion 1 $dword
    Set-FakeValue $version IdentityId $id $string
    Set-FakeValue $version SpoofName "NVIDIA GeForce GTX 1050 Ti" $string
    Set-FakeValue $version SpoofVendor "NVIDIA" $string
    Set-FakeValue $version SpoofBios "Version 86.07.48.00.A0" $string
    Set-FakeValue $version SpoofPciVendorId 0x10DE $dword
    Set-FakeValue $version SpoofPciDeviceId 0x1C82 $dword
    Set-FakeValue $version SpoofSubsystemVendorId 0x10DE $dword
    Set-FakeValue $version SpoofSubsystemDeviceId 0x1C82 $dword
    Set-FakeValue $version SpoofRevisionId 0xA1 $dword
    Set-FakeValue $version SpoofPciBusId 0 $dword
    Set-FakeValue $version SpoofPciSlotId 6 $dword
    Set-FakeValue $version SpoofPciFunctionId 0 $dword
    Set-FakeValue $version SpoofRamMb 4096 $dword
    Set-FakeValue $version SourceInstanceId $source $string
    Set-FakeValue $version IdentityMode "shallow-user-projection" $string
    return [pscustomobject]@{ Root=$root; Version=$version; Id=$id }
}

function Assert-HintRejected {
    param($Fixture, [int]$SchemaBefore, [string]$Message)
    $rootCount = $Fixture.Root.Values.Count
    $versionCount = $Fixture.Version.Values.Count
    $rejected = $false
    try {
        Get-LegacyVersionedIdentityHint $Fixture.Root $Fixture.Version `
            $Fixture.Id $SchemaBefore | Out-Null
    } catch { $rejected = $true }
    if (-not $rejected -or $Fixture.Root.Values.Count -ne $rootCount -or
        $Fixture.Version.Values.Count -ne $versionCount) {
        throw $Message
    }
}

# 完整且稳定的 schema-1 只泄露旧名称与 migration 标记，旧 PCI/RAM 等字段
# 只能用于内部一致性检查，不能被调用方当作当前 runtime identity。
$fixture = New-LegacyFixture
$hint = Get-LegacyVersionedIdentityHint $fixture.Root $fixture.Version $fixture.Id 1
$properties = @($hint.PSObject.Properties.Name)
if ($properties.Count -ne 2 -or -not ($properties -ccontains "SpoofName") -or
    -not ($properties -ccontains "IsLegacyMigrationHint") -or
    $hint.SpoofName -cne "NVIDIA GeForce GTX 1050 Ti" -or
    $hint.IsLegacyMigrationHint -ne $true) {
    throw "完整 schema-1 没有返回最小 migration hint"
}

$commonFields = @(
    "IdentitySchemaVersion", "IdentityId", "SpoofName", "SpoofVendor", "SpoofBios",
    "SpoofPciVendorId", "SpoofPciDeviceId", "SpoofSubsystemVendorId",
    "SpoofSubsystemDeviceId", "SpoofRevisionId", "SpoofPciBusId", "SpoofPciSlotId",
    "SpoofPciFunctionId", "SpoofRamMb", "SourceInstanceId", "IdentityMode"
)
foreach ($missingField in $commonFields) {
    $fixture = New-LegacyFixture
    [void]$fixture.Version.Values.Remove($missingField)
    [void]$fixture.Version.Kinds.Remove($missingField)
    Assert-HintRejected $fixture 1 ("缺少 common 字段未拒绝：" + $missingField)
}

# 自 ID、物理 source、schema 或最终 pointer 任一偏离，都可能把不相干身份用作
# rollback/定位基线，因此分别验证 fail-closed 且替身状态保持只读。
$fixture = New-LegacyFixture
Set-FakeValue $fixture.Version IdentityId "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-HintRejected $fixture 1 "错误 schema-1 自 ID 未拒绝"
$fixture = New-LegacyFixture
Set-FakeValue $fixture.Version SourceInstanceId `
    "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8110DE&REV_A1\3&TEST&0&30" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-HintRejected $fixture 1 "source 与逻辑 PCI 身份不一致未拒绝"
$fixture = New-LegacyFixture
Set-FakeValue $fixture.Version IdentitySchemaVersion 2 `
    ([Microsoft.Win32.RegistryValueKind]::DWord)
Assert-HintRejected $fixture 1 "schema 双读变化未拒绝"
$fixture = New-LegacyFixture
Set-FakeValue $fixture.Root CurrentIdentity "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-HintRejected $fixture 1 "CurrentIdentity 双读变化未拒绝"
$fixture = New-LegacyFixture
Set-FakeValue $fixture.Version SpoofRamMb "4096" `
    ([Microsoft.Win32.RegistryValueKind]::String)
Assert-HintRejected $fixture 1 "schema-1 common 字段类型错误未拒绝"
$fixture = New-LegacyFixture
Assert-HintRejected $fixture 2 "非 schema-1 参数进入 migration hint"
' >/dev/null

echo "OK: schema-1 versioned identity exposes only a validated migration hint"
