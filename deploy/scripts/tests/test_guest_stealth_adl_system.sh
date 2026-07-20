#!/usr/bin/env bash
# 验证三个经典 ADL 系统目标的只读预检、fail-closed 发布与 durable 收据恢复。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/deploy/guest-stealth/install-adl-system.ps1"
TRANSACTION="$REPO_ROOT/deploy/guest-stealth/adl-system-transaction.ps1"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$INSTALLER" "$TRANSACTION" "$ADL_DIR/atiadlxy.dll" \
        "$ADL_DIR/atiadlxx.dll"; do
    [[ -f "$path" ]] || fail "缺少 ADL 系统发布文件：$path"
done
[[ "$(xxd -p -l 3 "$INSTALLER")" == "efbbbf" ]] \
    || fail "ADL installer 缺少 Windows PowerShell 5.1 UTF-8 BOM"

PS_FILES="$INSTALLER:$TRANSACTION" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $failed = $false
    foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        foreach ($item in $errors) {
            $failed = $true
            [Console]::Error.WriteLine("{0}: {1}", $path, $item.Message)
        }
    }
    if ($failed) { exit 1 }
' || fail "ADL PowerShell AST 解析失败"

# 三个目标均来自 Windows Known Folder：32 位两个别名，64 位一个标准名称。
for contract in \
        '[Environment+SpecialFolder]::Windows' \
        '[Environment+SpecialFolder]::System' \
        '[Environment+SpecialFolder]::SystemX86' \
        "Source=(Join-Path \$PayloadRoot 'atiadlxy.dll')" \
        "Source=(Join-Path \$PayloadRoot 'atiadlxx32.dll')" \
        "Source=(Join-Path \$PayloadRoot 'atiadlxx.dll')" \
        "Target=(Join-Path \$SystemX86 'atiadlxy.dll')" \
        "Target=(Join-Path \$SystemX86 'atiadlxx.dll')" \
        "Target=(Join-Path \$System64 'atiadlxx.dll')"; do
    grep -F "$contract" "$INSTALLER" >/dev/null \
        || fail "ADL Known Folder/三目标映射缺少：$contract"
done
grep -F "Join-Path \$windowsRoot 'System32'" "$INSTALLER" >/dev/null \
    || fail "System64 没有与 Windows\\System32 交叉校验"
grep -F "Join-Path \$windowsRoot 'SysWOW64'" "$INSTALLER" >/dev/null \
    || fail "SystemX86 没有与 Windows\\SysWOW64 交叉校验"

# 系统级读取层不得下载、按进程注入、修改 ACL/签名策略，或写入某个检测工具的
# app-local 深层目录。摘要、PE 和普通文件校验是唯一发布边界。
if rg -ni \
    'Invoke-WebRequest|Start-BitsTransfer|Net\\.WebClient|HttpClient|https?://|Get-Process|ProcessName|Set-Acl|Get-Acl|icacls|SetAccessControl|GetAccessControl|AuthenticodeSignature|signtool|LocalApplicationData|GPU-Z\\.exe' \
        "$INSTALLER" "$TRANSACTION" >&2; then
    fail "ADL 系统发布重新引入网络、进程特判、ACL、签名或 app-local 路径"
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
INSTALLER_PATH="$INSTALLER" TRANSACTION_PATH="$TRANSACTION" \
X86_DLL="$ADL_DIR/atiadlxy.dll" X64_DLL="$ADL_DIR/atiadlxx.dll" \
TEST_ROOT="$TEST_ROOT" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    function Import-Functions {
        param([string]$Path)
        $source = [IO.File]::ReadAllText($Path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            $source, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ("AST 不可用：" + $Path) }
        foreach ($definition in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    . Import-Functions $env:INSTALLER_PATH
    . Import-Functions $env:TRANSACTION_PATH

    $x86Hash = Get-LowerSha256 $env:X86_DLL
    $x64Hash = Get-LowerSha256 $env:X64_DLL
    Assert-AdlBinary $env:X86_DLL $x86Hash 0x014C 0x010B
    Assert-AdlBinary $env:X64_DLL $x64Hash 0x8664 0x020B

    function New-Entries {
        param([string]$Name, [switch]$Historical)
        $root = Join-Path $env:TEST_ROOT $Name
        $x86 = Join-Path $root "x86"; $x64 = Join-Path $root "x64"
        [IO.Directory]::CreateDirectory($x86) | Out-Null
        [IO.Directory]::CreateDirectory($x64) | Out-Null
        $items = @(
            [pscustomobject]@{
                FileName="atiadlxy.dll"; Source=$env:X86_DLL; Directory=$x86
                Target=(Join-Path $x86 "atiadlxy.dll"); ExpectedHash=$x86Hash
                HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
                State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""
                CommitAction=""
            },
            [pscustomobject]@{
                FileName="atiadlxx.dll"; Source=$env:X86_DLL; Directory=$x86
                Target=(Join-Path $x86 "atiadlxx.dll"); ExpectedHash=$x86Hash
                HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
                State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""
                CommitAction=""
            },
            [pscustomobject]@{
                FileName="atiadlxx.dll"; Source=$env:X64_DLL; Directory=$x64
                Target=(Join-Path $x64 "atiadlxx.dll"); ExpectedHash=$x64Hash
                HistoricalHashes=@(); Machine=0x8664; Magic=0x020B
                State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""
                CommitAction=""
            }
        )
        if ($Historical) {
            [IO.File]::Copy($env:X64_DLL, $items[0].Target)
            [IO.File]::Copy($env:X64_DLL, $items[1].Target)
            [IO.File]::Copy($env:X86_DLL, $items[2].Target)
            $items[0].HistoricalHashes=@($x64Hash)
            $items[1].HistoricalHashes=@($x64Hash)
            $items[2].HistoricalHashes=@($x86Hash)
        }
        return [pscustomobject]@{ Root=$root; Entries=$items }
    }

    # 第三个目标含未知/真实 AMD 字节时，必须在 receipt/stage/首目标写入前拒绝。
    $blocked = New-Entries "blocked"
    [IO.File]::WriteAllText($blocked.Entries[2].Target, "real-amd-or-unknown")
    $blockedId = "11111111111111111111111111111111"
    $blockedReceipt = Join-Path $blocked.Root ($blockedId + ".json")
    try {
        Publish-AdlProjection $blocked.Entries $blockedReceipt $blockedId
        throw "未知第三目标被错误放行"
    } catch {
        if ($_.Exception.Message -eq "未知第三目标被错误放行") { throw }
        if ($_.Exception.Message -cnotmatch "未知或真实 AMD ADL") {
            throw ("fail-closed 错误摘要不明确：" + $_.Exception.Message)
        }
    }
    if ((Test-Path $blocked.Entries[0].Target) -or
        (Test-Path $blocked.Entries[1].Target) -or
        (Test-Path $blockedReceipt) -or
        @(Get-ChildItem $blocked.Entries[0].Directory -Force).Count -ne 0) {
        throw "三目标全预检完成前已产生写入"
    }

    # Absent 发布后回滚必须删除三个新目标与 receipt。
    $rollback = New-Entries "rollback"
    $rollbackId = "22222222222222222222222222222222"
    $rollbackReceipt = Join-Path $rollback.Root ($rollbackId + ".json")
    Publish-AdlProjection $rollback.Entries $rollbackReceipt $rollbackId
    foreach ($entry in $rollback.Entries) {
        Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
    }
    Rollback-AdlProjectionReceipt $rollback.Entries $rollbackReceipt $rollbackId
    if (@($rollback.Entries | Where-Object { Test-Path $_.Target }).Count -ne 0 -or
        (Test-Path $rollbackReceipt)) { throw "Absent durable rollback 未收口" }

    # 三个历史托管目标的 Finalize 必须保留新字节、删除旧备份和 receipt。
    $finalize = New-Entries "finalize" -Historical
    $finalizeId = "33333333333333333333333333333333"
    $finalizeReceipt = Join-Path $finalize.Root ($finalizeId + ".json")
    Publish-AdlProjection $finalize.Entries $finalizeReceipt $finalizeId
    Finalize-AdlProjectionReceipt $finalize.Entries $finalizeReceipt $finalizeId
    foreach ($entry in $finalize.Entries) {
        Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        if ($entry.Backup -and (Test-Path $entry.Backup)) {
            throw ("Finalize 遗留备份：" + $entry.Backup)
        }
    }
    if (Test-Path $finalizeReceipt) { throw "Finalize 遗留 durable receipt" }
'

for source in "$INSTALLER" "$TRANSACTION"; do
    [[ "$(wc -l < "$source")" -le 500 ]] \
        || fail "ADL 系统发布单文件超过 500 行：$source"
done

echo "OK: ADL three-target preflight, fail-closed and durable recovery passed"
