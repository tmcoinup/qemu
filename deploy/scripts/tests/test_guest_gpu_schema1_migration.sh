#!/usr/bin/env bash
# 使用纯内存 RegistryKey 替身验证旧 versioned schema-1 与 main/main carrier
# 均 fail-closed；测试不访问 Linux 上不存在的真实注册表。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REFRESH_SCRIPT="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"
GPU_CONTRACT="$REPO_ROOT/deploy/scripts/gpu-board-identity-contract.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v pwsh >/dev/null 2>&1 || fail "缺少 pwsh"
[[ -f "$GPU_CONTRACT" ]] || fail "缺少共享 GPU identity contract"

REFRESH_SCRIPT="$REFRESH_SCRIPT" GPU_CONTRACT="$GPU_CONTRACT" \
    pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:GPU_CONTRACT
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:REFRESH_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "refresh AST parse failed" }

foreach ($name in @("Get-ExactRegistryValue", "Get-CurrentGpuIdentity")) {
    $node = $ast.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq $name
    }, $true)
    if ($null -eq $node) { throw ("缺少 refresh 函数：" + $name) }
    Invoke-Expression $node.Extent.Text
}
$removedHint = $ast.Find({
    param($candidate)
    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -eq "Get-LegacyVersionedIdentityHint"
}, $true)
if ($null -ne $removedHint) {
    throw "refresh 仍公开 versioned schema-1 migration hint"
}

function New-FakeRegistryKey {
    $key = [pscustomobject]@{ Values=@{}; Kinds=@{}; Children=@{} }
    $key | Add-Member ScriptMethod GetValueNames { return @($this.Values.Keys) }
    $key | Add-Member ScriptMethod GetValueKind {
        param($Name)
        return $this.Kinds[$Name]
    }
    $key | Add-Member ScriptMethod GetValue {
        param($Name, $DefaultValue, $Options)
        if ($this.Values.ContainsKey($Name)) { return $this.Values[$Name] }
        return $DefaultValue
    }
    $key | Add-Member ScriptMethod OpenSubKey {
        param($Path, $Writable)
        if ($this.Children.ContainsKey($Path)) { return $this.Children[$Path] }
        return $null
    }
    $key | Add-Member ScriptMethod Dispose {}
    return $key
}

function Set-FakeValue($Key, [string]$Name, $Value, $Kind) {
    $Key.Values[$Name] = $Value
    $Key.Kinds[$Name] = $Kind
}

$string = [Microsoft.Win32.RegistryValueKind]::String
$dword = [Microsoft.Win32.RegistryValueKind]::DWord
$id = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
$base = New-FakeRegistryKey
$root = New-FakeRegistryKey
$version = New-FakeRegistryKey
$base.Children["SOFTWARE\StealthGPU"] = $root
$root.Children["Identities\" + $id] = $version
Set-FakeValue $root CurrentIdentity $id $string
Set-FakeValue $version IdentitySchemaVersion 1 $dword
$rootCount = $root.Values.Count
$versionCount = $version.Values.Count
$rejected = $false
try {
    Get-CurrentGpuIdentity -BaseKeyOverride $base | Out-Null
} catch {
    $rejected = $_.Exception.Message.Contains(
        "schema-1 versioned GPU 身份已停止兼容")
}
if (-not $rejected -or $root.Values.Count -ne $rootCount -or
    $version.Values.Count -ne $versionCount) {
    throw "旧 versioned schema-1 未在只读阶段明确 fail-closed"
}

$snapshot = [pscustomobject]@{
    IdentitySchemaVersion=1
    SpoofRevisionId=0xA1
}
foreach ($sourceText in @(
        "PCI\VEN_1AF4&DEV_1050&SUBSYS_A1011AF4&REV_A1\3&TEST&0&30",
        "PCI\VEN_1AF4&DEV_1050&SUBSYS_1C8210DE&REV_A1\3&TEST&0&30")) {
    $source = [regex]::Match($sourceText,
        "^PCI\\VEN_1AF4&DEV_1050&SUBSYS_([0-9A-F]{4})([0-9A-F]{4})&REV_([0-9A-F]{2})(?:&|\\)")
    if (Test-GpuLogicalBinding $snapshot $source) {
        throw ("schema-1 或旧 main/main carrier 被共享契约接受：" + $sourceText)
    }
}
foreach ($subsys in @("1C8210DE", "67FF1002", "A1131AF4")) {
    if ($null -ne (Get-GpuBoardAutoDetectProfile $subsys)) {
        throw ("旧式或未知 carrier 被 AutoDetect 接受：" + $subsys)
    }
}
' >/dev/null

echo "OK: versioned schema-1 and legacy carriers fail closed"
