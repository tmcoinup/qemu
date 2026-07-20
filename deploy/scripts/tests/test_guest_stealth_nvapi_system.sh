#!/usr/bin/env bash
# 验证 GPU-Z 2.70 直接双击所需的双架构系统 NVAPI 发布链。
# shellcheck disable=SC2016
# 单引号中的 `$` 是 PowerShell/源码断言，必须按字面值传给被测脚本。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALLER="$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1"
TRANSACTION_HELPER="$REPO_ROOT/deploy/guest-stealth/nvapi-system-transaction.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
APPLY="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
IDENTITY_HELPER="$REPO_ROOT/deploy/scripts/persist-gpu-profile.ps1"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
PACKAGE_SCRIPT="$REPO_ROOT/deploy/guest-stealth/package.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
README="$REPO_ROOT/deploy/guest-stealth/README.md"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$INSTALLER" "$TRANSACTION_HELPER" "$RESPAWN" "$APPLY" "$IDENTITY_HELPER" \
        "$BUILD_SCRIPT" "$PACKAGE_SCRIPT" \
        "$NVAPI_DIR/nvapi.dll" "$NVAPI_DIR/nvapi64.dll"; do
    [[ -f "$path" ]] || fail "缺少系统 NVAPI 链文件: $path"
done
[[ ! -e "$REPO_ROOT/deploy/guest-stealth/launch-nvapi-tool.ps1" ]] \
    || fail "按需 app-local helper 仍作为第二条用户路径存在"
[[ "$(xxd -p -l 3 "$INSTALLER")" == 'efbbbf' ]] \
    || fail "install-nvapi-system.ps1 缺少 Windows PowerShell 5.1 UTF-8 BOM"

PS_FILES="$INSTALLER:$TRANSACTION_HELPER:$RESPAWN:$APPLY:$IDENTITY_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $failed = $false
    foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        foreach ($errorItem in $errors) {
            $failed = $true
            [Console]::Error.WriteLine("{0}: {1}", $path, $errorItem.Message)
        }
    }
    if ($failed) { exit 1 }
' || fail "系统 NVAPI PowerShell AST 解析失败"

command -v llvm-readobj >/dev/null 2>&1 || fail "缺少 PE 检查工具: llvm-readobj"

x86_hash="$(sha256sum "$NVAPI_DIR/nvapi.dll" | awk '{print $1}')"
x64_hash="$(sha256sum "$NVAPI_DIR/nvapi64.dll" | awk '{print $1}')"
for hash in "$x86_hash" "$x64_hash"; do
    grep -F "$hash" "$INSTALLER" >/dev/null \
        || fail "系统 installer 没有锁定 payload 摘要 $hash"
    grep -F "$hash" "$BUILD_SCRIPT" >/dev/null \
        || fail "build-exe.sh 没有锁定 payload 摘要 $hash"
done
# 上一版当前发布物必须在升级时转入 historical；否则已安装 VM 会被当成未知 DLL。
for old_hash in \
    d2fa115d4ece2da0361106113f0289a5499c6e78d491567bf466b60a3a010f14 \
    c0e39803f8484d9dc23559576762564bc84b44fb3c90c7562829e8c96f15a83d \
    a5de31d15ff0f4038ef1b54a75fbac0ab472797d3424e1468f9e6d047cc58139 \
    207e41c9eaa7641d3e2af32e99a5f874a87978b310676db325d572f8b954dd72 \
    79b05e4707fa3b4882279995898ea99e74f584e31d10f9733c24714eb79ea80d \
    8b32d767e69526c535cce361a9d5853fc6f21f7f348600fabfefe7f46db708cc \
    63ecadd497f955a599e8a12ea7f45fd92915a47570be473d166ddbb3d462c13e \
    585ef928f54548ed2ac9eae1dfcdd5b12e4fd8a9ab5f7d94257ca01df68cdf81 \
    5ad43a193ccf0c3dacc769f4267d394502708fc1a5191d9b1338ba8485ea9c94 \
    311b95768f8bbd18fb30f0e1144c9f2c50cc4f8433b870768c4a439f57844f56 \
    1638720952a6187773372f29837c3bb26804eaeaf00938a8c2f42996bc4dd972 \
    1d39f3dada172f62b62f801de434ceda3060caf3b0887381d0b853771f3b97cf; do
    grep -F "$old_hash" "$INSTALLER" >/dev/null \
        || fail "上一版系统 NVAPI 摘要未转入 historical allowlist: $old_hash"
done

llvm-readobj --file-headers "$NVAPI_DIR/nvapi.dll" |
    grep -F 'Machine: IMAGE_FILE_MACHINE_I386 (0x14C)' >/dev/null \
    || fail "nvapi.dll 不是 GPU-Z 2.70 所需 PE32/i386"
llvm-readobj --file-headers "$NVAPI_DIR/nvapi64.dll" |
    grep -F 'Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)' >/dev/null \
    || fail "nvapi64.dll 不是 PE32+/AMD64"
for dll in "$NVAPI_DIR/nvapi.dll" "$NVAPI_DIR/nvapi64.dll"; do
    [[ "$(llvm-readobj --coff-exports "$dll" |
        grep -c '^  Name: nvapi_QueryInterface$')" -eq 1 ]] \
        || fail "$(basename "$dll") 没有精确导出 nvapi_QueryInterface"
done

# 在 Linux 临时目录执行 installer 的纯文件事务函数：覆盖 absent/current/历史托管、
# 未知文件拒绝，以及第二架构提交失败后第一架构回滚。测试不访问宿主系统目录。
INSTALLER_PATH="$INSTALLER" TRANSACTION_HELPER_PATH="$TRANSACTION_HELPER" \
X86_DLL="$NVAPI_DIR/nvapi.dll" \
X64_DLL="$NVAPI_DIR/nvapi64.dll" TEST_ROOT="$(mktemp -d)" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $source = [IO.File]::ReadAllText($env:INSTALLER_PATH)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "installer AST 不可用" }
    foreach ($name in @(
        "Get-LowerSha256", "Get-PeMetadata", "Assert-PlainFile",
        "Assert-NvapiBinary", "Test-HashInAllowList",
        "Get-SystemProjectionEntryState", "Get-SystemProjectionEntrySnapshot",
        "Remove-TransactionFile", "Move-VerifiedHistoricalTarget",
        "Publish-SystemProjectionEntries")) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
        }, $true)
        if ($null -eq $definition) { throw ("缺少函数: " + $name) }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $helperSource = [IO.File]::ReadAllText($env:TRANSACTION_HELPER_PATH)
    $helperAst = [Management.Automation.Language.Parser]::ParseInput(
        $helperSource, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "transaction helper AST 不可用" }
    foreach ($definition in @($helperAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $x86Hash = Get-LowerSha256 $env:X86_DLL
    $x64Hash = Get-LowerSha256 $env:X64_DLL
    Assert-NvapiBinary $env:X86_DLL $x86Hash 0x014C 0x010B
    Assert-NvapiBinary $env:X64_DLL $x64Hash 0x8664 0x020B

    $targetRoot = Join-Path $env:TEST_ROOT "targets"
    $x86Dir = Join-Path $targetRoot "x86"
    $x64Dir = Join-Path $targetRoot "x64"
    [IO.Directory]::CreateDirectory($x86Dir) | Out-Null
    [IO.Directory]::CreateDirectory($x64Dir) | Out-Null
    $entries = @(
        [pscustomobject]@{
            FileName="nvapi.dll"; Source=$env:X86_DLL; Directory=$x86Dir
            Target=(Join-Path $x86Dir "nvapi.dll"); ExpectedHash=$x86Hash
            HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
            State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""; CommitAction=""
        },
        [pscustomobject]@{
            FileName="nvapi64.dll"; Source=$env:X64_DLL; Directory=$x64Dir
            Target=(Join-Path $x64Dir "nvapi64.dll"); ExpectedHash=$x64Hash
            HistoricalHashes=@(); Machine=0x8664; Magic=0x020B
            State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""; CommitAction=""
        }
    )
    if ((Get-SystemProjectionEntryState $entries[0]) -ne "Absent") {
        throw "缺失目标没有识别为 Absent"
    }
    Publish-SystemProjectionEntries $entries
    if ((Get-LowerSha256 $entries[0].Target) -cne $x86Hash -or
        (Get-LowerSha256 $entries[1].Target) -cne $x64Hash) {
        throw "双架构 absent 提交结果错误"
    }
    if ((Get-SystemProjectionEntryState $entries[0]) -ne "Current") {
        throw "当前目标没有识别为 Current"
    }

    # 重跑正式 EXE 时两份系统 DLL 通常已经是当前摘要。此时 durable receipt 的
    # Action=Unchanged，三个临时路径都为空；Finalize 必须把它视为幂等成功，不能
    # 将空 Discard 传给 Test-Path 后触发 ParameterBindingValidationException。
    foreach ($entry in $entries) {
        $entry.State=""; $entry.ObservedHash=""; $entry.Stage=""
        $entry.Backup=""; $entry.Discard=""; $entry.CommitAction=""
    }
    $unchangedId = "44444444444444444444444444444444"
    $unchangedReceipt = Join-Path $env:TEST_ROOT ($unchangedId + ".json")
    Publish-SystemProjectionEntries $entries $unchangedReceipt $unchangedId
    Finalize-NvapiProjectionReceipt $entries $unchangedReceipt $unchangedId
    if (Test-Path -LiteralPath $unchangedReceipt) {
        throw "Unchanged NVAPI receipt 没有幂等 Finalize"
    }

    $historical = [pscustomobject]@{
        Target=$entries[0].Target; ExpectedHash=$x64Hash
        HistoricalHashes=@($x86Hash)
    }
    if ((Get-SystemProjectionEntryState $historical) -ne "ManagedHistorical") {
        throw "已知历史摘要没有识别为 ManagedHistorical"
    }

    # 确定性模拟“预检后、替换前，真实安装器换入新文件”。helper 必须原子移走
    # 此刻的实体，发现摘要不等于快照后原样恢复，不能把它当历史 DLL 覆盖。
    $raceDir = Join-Path $env:TEST_ROOT "race"
    [IO.Directory]::CreateDirectory($raceDir) | Out-Null
    $raceTarget = Join-Path $raceDir "nvapi.dll"
    [IO.File]::Copy($env:X86_DLL, $raceTarget)
    $raceEntry = [pscustomobject]@{
        Target=$raceTarget; Backup=(Join-Path $raceDir "detached.dll")
        ObservedHash=$x86Hash
    }
    [IO.File]::Delete($raceTarget)
    [IO.File]::Copy($env:X64_DLL, $raceTarget)
    try {
        Move-VerifiedHistoricalTarget $raceEntry
        throw "竞态换入文件被错误放行"
    } catch {
        if ($_.Exception.Message -eq "竞态换入文件被错误放行") { throw }
    }
    if ((Get-LowerSha256 $raceTarget) -cne $x64Hash -or
        (Test-Path -LiteralPath $raceEntry.Backup)) {
        throw "竞态拒绝后没有原样保留换入文件"
    }
    $unknown = [pscustomobject]@{
        Target=$entries[0].Target; ExpectedHash=$x64Hash; HistoricalHashes=@()
    }
    try {
        $null = Get-SystemProjectionEntryState $unknown
        throw "未知目标被错误放行"
    } catch {
        if ($_.Exception.Message -eq "未知目标被错误放行") { throw }
    }

    # 第二架构存在未知 DLL 时必须在 staging 前失败，第一架构目标和临时文件均不出现。
    $preflightRoot = Join-Path $env:TEST_ROOT "preflight"
    $preflightFirst = Join-Path $preflightRoot "first"
    $preflightSecond = Join-Path $preflightRoot "second"
    [IO.Directory]::CreateDirectory($preflightFirst) | Out-Null
    [IO.Directory]::CreateDirectory($preflightSecond) | Out-Null
    $unknownTarget = Join-Path $preflightSecond "nvapi64.dll"
    [IO.File]::Copy($env:X86_DLL, $unknownTarget)
    $preflightEntries = @(
        [pscustomobject]@{
            FileName="nvapi.dll"; Source=$env:X86_DLL; Directory=$preflightFirst
            Target=(Join-Path $preflightFirst "nvapi.dll"); ExpectedHash=$x86Hash
            HistoricalHashes=@(); Machine=0x014C; Magic=0x010B
            State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""; CommitAction=""
        },
        [pscustomobject]@{
            FileName="nvapi64.dll"; Source=$env:X64_DLL; Directory=$preflightSecond
            Target=$unknownTarget; ExpectedHash=$x64Hash; HistoricalHashes=@()
            Machine=0x8664; Magic=0x020B
            State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""; CommitAction=""
        }
    )
    try {
        Publish-SystemProjectionEntries $preflightEntries
        throw "未知第二架构没有阻止事务"
    } catch {
        if ($_.Exception.Message -eq "未知第二架构没有阻止事务") { throw }
    }
    if ((Test-Path -LiteralPath $preflightEntries[0].Target) -or
        @(Get-ChildItem -LiteralPath $preflightFirst -Force).Count -ne 0) {
        throw "未知第二架构失败前已经写入第一架构目录"
    }

    $rollbackRoot = Join-Path $env:TEST_ROOT "rollback"
    $firstDir = Join-Path $rollbackRoot "first"
    $secondDir = Join-Path $rollbackRoot "second"
    [IO.Directory]::CreateDirectory($firstDir) | Out-Null
    [IO.Directory]::CreateDirectory($secondDir) | Out-Null
    $firstTarget = Join-Path $firstDir "nvapi.dll"
    $rollbackEntries = @(
        [pscustomobject]@{
            FileName="nvapi.dll"; Source=$env:X86_DLL; Directory=$firstDir
            Target=$firstTarget; ExpectedHash=$x86Hash; HistoricalHashes=@()
            Machine=0x014C; Magic=0x010B
            State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""; CommitAction=""
        },
        [pscustomobject]@{
            FileName="nvapi64.dll"; Source=$env:X64_DLL; Directory=$secondDir
            Target=(Join-Path $secondDir "missing/nvapi64.dll")
            ExpectedHash=$x64Hash; HistoricalHashes=@()
            Machine=0x8664; Magic=0x020B
            State=""; ObservedHash=""; Stage=""; Backup=""; Discard=""; CommitAction=""
        }
    )
    try {
        Publish-SystemProjectionEntries $rollbackEntries
        throw "故障注入没有失败"
    } catch {
        if ($_.Exception.Message -eq "故障注入没有失败") { throw }
    }
    if (Test-Path -LiteralPath $firstTarget) {
        throw "第二架构失败后第一架构没有回滚"
    }

    function New-DurableFixture {
        param([string]$Name)
        $root = Join-Path $env:TEST_ROOT $Name
        $dir32 = Join-Path $root "x86"; $dir64 = Join-Path $root "x64"
        [IO.Directory]::CreateDirectory($dir32) | Out-Null
        [IO.Directory]::CreateDirectory($dir64) | Out-Null
        $target32 = Join-Path $dir32 "nvapi.dll"
        $target64 = Join-Path $dir64 "nvapi64.dll"
        # 用另一架构 PE 充当摘要不同的“历史托管文件”；发布路径仍会对新文件做
        # 真实 PE 架构校验，旧文件在此只用于可逆字节恢复测试。
        [IO.File]::Copy($env:X64_DLL, $target32)
        [IO.File]::Copy($env:X86_DLL, $target64)
        $pair = @(
            [pscustomobject]@{
                FileName="nvapi.dll"; Source=$env:X86_DLL; Directory=$dir32
                Target=$target32; ExpectedHash=$x86Hash; HistoricalHashes=@($x64Hash)
                Machine=0x014C; Magic=0x010B; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction=""
            },
            [pscustomobject]@{
                FileName="nvapi64.dll"; Source=$env:X64_DLL; Directory=$dir64
                Target=$target64; ExpectedHash=$x64Hash; HistoricalHashes=@($x86Hash)
                Machine=0x8664; Magic=0x020B; State=""; ObservedHash=""
                Stage=""; Backup=""; Discard=""; CommitAction=""
            }
        )
        return [pscustomobject]@{ Root=$root; Entries=$pair }
    }

    # 故障注入：installer 已成功并保留 receipt，但 CompleteIdentity 抛异常。
    # apply 的 finally 必须使用同一 ID 显式回滚两个 DLL，恢复 schema-1 reader。
    $completeFixture = New-DurableFixture "complete-failure"
    $completeId = "11111111111111111111111111111111"
    $completeReceipt = Join-Path $completeFixture.Root ($completeId + ".json")
    Publish-SystemProjectionEntries $completeFixture.Entries $completeReceipt $completeId
    if (-not (Test-Path -LiteralPath $completeReceipt)) { throw "deferred receipt 未落盘" }
    try {
        throw "injected CompleteIdentity failure"
    } catch {
        if ($_.Exception.Message -cne "injected CompleteIdentity failure") { throw }
        Rollback-NvapiProjectionReceipt $completeFixture.Entries `
            $completeReceipt $completeId
    }
    if ((Get-LowerSha256 $completeFixture.Entries[0].Target) -cne $x64Hash -or
        (Get-LowerSha256 $completeFixture.Entries[1].Target) -cne $x86Hash -or
        (Test-Path -LiteralPath $completeReceipt)) {
        throw "CompleteIdentity 故障后双架构旧 DLL/receipt 未恢复"
    }

    # 模拟 kill 落在“旧 x86 已移到 backup、新 x86 尚未成为 Target”的 Detached
    # 组合；x64 仍保持 Committed。只依赖预写 receipt 即应同时恢复两者。
    $halfFixture = New-DurableFixture "half-commit"
    $halfId = "22222222222222222222222222222222"
    $halfReceipt = Join-Path $halfFixture.Root ($halfId + ".json")
    Publish-SystemProjectionEntries $halfFixture.Entries $halfReceipt $halfId
    [IO.File]::Delete($halfFixture.Entries[0].Target)
    Rollback-NvapiProjectionReceipt $halfFixture.Entries $halfReceipt $halfId
    if ((Get-LowerSha256 $halfFixture.Entries[0].Target) -cne $x64Hash -or
        (Get-LowerSha256 $halfFixture.Entries[1].Target) -cne $x86Hash) {
        throw "Detached/Committed 混合状态没有从 durable receipt 恢复"
    }

    $finalFixture = New-DurableFixture "finalize"
    $finalId = "33333333333333333333333333333333"
    $finalReceipt = Join-Path $finalFixture.Root ($finalId + ".json")
    Publish-SystemProjectionEntries $finalFixture.Entries $finalReceipt $finalId
    Finalize-NvapiProjectionReceipt $finalFixture.Entries $finalReceipt $finalId
    if ((Get-LowerSha256 $finalFixture.Entries[0].Target) -cne $x86Hash -or
        (Get-LowerSha256 $finalFixture.Entries[1].Target) -cne $x64Hash -or
        (Test-Path -LiteralPath $finalReceipt)) {
        throw "Finalize 未保留新 DLL 或未清理 receipt"
    }
    Remove-Item -LiteralPath $env:TEST_ROOT -Recurse -Force
' || fail "系统 NVAPI 纯函数/双架构事务测试失败"

grep -F '[Environment+SpecialFolder]::SystemX86' "$INSTALLER" >/dev/null \
    || fail "x86 DLL 没有使用 Known Folder SysWOW64"
grep -F "Join-Path \$SystemX86 'nvapi.dll'" "$INSTALLER" >/dev/null \
    || fail "GPU-Z PE32 的 nvapi.dll 没有发布到 SysWOW64"
grep -F "Join-Path \$System64 'nvapi64.dll'" "$INSTALLER" >/dev/null \
    || fail "x64 helper 的 nvapi64.dll 没有发布到 System32"
if grep -F '[IO.File]::Replace' "$INSTALLER" >/dev/null; then
    fail "历史 DLL 仍使用带 hash-check/replace 竞态的无条件路径替换"
fi
grep -F 'Move-VerifiedHistoricalTarget -Entry $entry' "$INSTALLER" >/dev/null \
    || fail "历史 DLL 没有先原子移走实体再校验摘要"
grep -F 'Rollback-NvapiProjectionReceipt' "$INSTALLER" >/dev/null \
    || fail "双架构提交缺少 durable receipt 回滚"
grep -F 'Undo-NvapiProjectionEntry' "$TRANSACTION_HELPER" >/dev/null \
    || fail "durable transaction helper 缺少单项状态机回滚"
journal_line="$(grep -n -F 'if ($hasJournal) { Write-NvapiProjectionReceipt' \
    "$INSTALLER" | cut -d: -f1)"
stage_copy_line="$(grep -n -F 'Copy-Item -LiteralPath $entry.Source -Destination $entry.Stage' \
    "$INSTALLER" | cut -d: -f1)"
first_system_move_line="$(grep -n -F 'Move-NvapiFileWriteThrough $entry.Stage $entry.Target' \
    "$INSTALLER" | head -1 | cut -d: -f1)"
[[ -n "$journal_line" && -n "$stage_copy_line" && -n "$first_system_move_line" && \
    "$journal_line" -lt "$stage_copy_line" && "$journal_line" -lt "$first_system_move_line" ]] \
    || fail "durable journal 没有在首个 staging/系统 Move 前原子落盘"
grep -F 'MoveFileEx($Source, $Destination, [uint32]8)' \
    "$TRANSACTION_HELPER" >/dev/null \
    || fail "durable rename 没有使用 MoveFileExW WRITE_THROUGH"
grep -F 'Sync-NvapiFileData -Path $entry.Stage' "$INSTALLER" >/dev/null \
    || fail "staged DLL 在提交目录项前没有 Flush(true)"
production_file_moves="$(rg -n '\[IO\.File\]::Move' "$INSTALLER" \
    "$TRANSACTION_HELPER" | grep -v 'Move(\$Source, \$Destination)' || true)"
[[ -z "$production_file_moves" ]] \
    || fail "生产提交/回滚仍绕过 write-through Move: $production_file_moves"
grep -F '$movedHash -cne $Entry.ObservedHash' "$INSTALLER" >/dev/null \
    || fail "提交没有核对原子移走实体与预检快照"
grep -F '拒绝覆盖未知 NVAPI DLL' "$INSTALLER" >/dev/null \
    || fail "installer 没有 fail-closed 保护真实/未知 NVAPI"
if rg -n 'Get-Process|ProcessName' "$INSTALLER" >&2; then
    fail "系统级 NVAPI 发布不得按 GPU-Z 或其它检测工具进程名特判"
fi
grep -F '[IO.FileShare]::None' "$INSTALLER" >/dev/null \
    || fail "系统 NVAPI installer 没有跨进程排他锁"

if grep -Ei 'Invoke-WebRequest|Invoke-RestMethod|https?://|takeown|icacls|bcdedit' \
        "$INSTALLER" "$TRANSACTION_HELPER" "$RESPAWN" >&2; then
    fail "系统 NVAPI 链引入网络、所有权夺取或启动/签名链修改"
fi
if grep -Ei 'driver-signing|EfiGuard|GPU_SELFSIGNED' "$INSTALLER" >&2; then
    fail "系统用户态投影恢复了自签/深层 PCI 路径"
fi

grep -F 'install-nvapi-system.ps1' "$APPLY" >/dev/null \
    || fail "apply 没有在 identity 事务内调用系统 NVAPI installer"
grep -F 'GPU-Z 2.70' "$RESPAWN" >/dev/null \
    || fail "respawn 缺少 GPU-Z 直接运行契约说明"
grep -F "'-AutoDetect', '-NvapiPayloadDir', \$PSScriptRoot" "$RESPAWN" >/dev/null \
    || fail "respawn 没有把受保护 payload 目录交给 apply 的 identity 事务"
if grep -F '& $powershellExe @nvapiArgs' "$RESPAWN" >/dev/null; then
    fail "respawn 仍在 identity Complete 后重复调用 NVAPI installer"
fi
spoof_call_line="$(grep -n -F '& $powershellExe @spoofArgs' \
    "$RESPAWN" | cut -d: -f1)"
projection_call_line="$(grep -n -F '& $powershellExe @projectionArgs' \
    "$RESPAWN" | cut -d: -f1)"
final_line="$(grep -n '^if (\$NoReboot)' "$RESPAWN" | tail -n 1 | cut -d: -f1)"
[[ -n "$spoof_call_line" && \
    -n "$projection_call_line" && -n "$final_line" ]] \
    || fail "无法定位 apply、HardwareID 与最终成功顺序"
(( spoof_call_line < projection_call_line && projection_call_line < final_line )) \
    || fail "HardwareID 没有位于 identity+GPU API 成功之后、最终成功之前"

# 跨组件升级必须由 apply 自己收口：reader Prepare 在 pointer Commit 前，
# identity Complete 后才 Finalize；失败 finally 先恢复旧 pointer，再恢复历史 reader。
APPLY_PATH="$APPLY" pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $env:APPLY_PATH, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "apply AST 不可用" }
    $nvapiParameter = @($ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq "NvapiPayloadDir"
    })
    if ($nvapiParameter.Count -ne 1 -or $null -eq $nvapiParameter[0].DefaultValue) {
        throw "NvapiPayloadDir 必须是保留 standalone 兼容的可选参数"
    }
    $guard = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally -and
            $node.Finally.Extent.Text.Contains("-RollbackIdentity")
    }, $true)
    if ($null -eq $guard) { throw "缺少 identity durable finally" }
    $body = $guard.Body.Extent.Text
    $finally = $guard.Finally.Extent.Text
    foreach ($marker in @(
        "& `$powershellExe @gpuApiInstallArgs",
        "-CommitIdentity `$identityTransactionId",
        "-CompleteIdentity `$identityTransactionId",
        "`$completeInspection = & `$identityHelperSource -InspectIdentity",
        "`$completeResolution = & `$identityHelperSource -RollbackIdentity",
        "`$resolvedState -ceq",
        "& `$powershellExe @gpuApiFinalizeArgs")) {
        if (-not $body.Contains($marker)) {
            throw ("GPU API/identity 原子窗口缺少：" + $marker)
        }
    }
    $installOffset = $body.IndexOf("& `$powershellExe @gpuApiInstallArgs")
    $commitOffset = $body.IndexOf("-CommitIdentity `$identityTransactionId")
    $completeOffset = $body.IndexOf("-CompleteIdentity `$identityTransactionId")
    $finalizeOffset = $body.IndexOf("& `$powershellExe @gpuApiFinalizeArgs")
    if (-not ($installOffset -lt $commitOffset -and
        $commitOffset -lt $completeOffset -and
        $completeOffset -lt $finalizeOffset)) {
        throw "Prepare → Commit → Complete → Finalize 顺序错误"
    }
    $readerRollbackOffset = $finally.IndexOf("& `$powershellExe @gpuApiRecoveryArgs")
    $identityRollbackOffset = $finally.IndexOf("-RollbackIdentity `$identityTransactionId")
    if ($readerRollbackOffset -lt 0 -or $identityRollbackOffset -lt 0 -or
        $identityRollbackOffset -ge $readerRollbackOffset) {
        throw "失败路径没有先恢复旧 pointer、再恢复历史 reader"
    }
    if (-not $finally.Contains("-not `$identityCompletionUnresolved")) {
        throw "Complete 状态无法裁决时仍会破坏两份 durable journal"
    }
' || fail "GPU API coordinator 与 identity 的顺序/失败回滚契约测试失败"
IDENTITY_HELPER_PATH="$IDENTITY_HELPER" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile(
        $env:IDENTITY_HELPER_PATH,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "identity helper AST 不可用"}
    $needle="ParameterSetName -eq " + [char]39 + "Inspect" + [char]39
    $inspect=$ast.Find({param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains($needle)
    },$true)
    if($null -eq $inspect){throw "缺少 Complete 只读 Inspect 参数集"}
    $text=$inspect.Extent.Text
    if(-not $text.Contains("Read-TransactionReceipt")){throw "Inspect 未读取 durable receipt"}
    foreach($writer in @(".SetValue(",".DeleteValue(","Invoke-TransactionRollback",
        "Set-CurrentIdentityPointer","Clear-PendingIdentity")){
        if($text.Contains($writer)){throw ("Inspect 不是只读操作："+$writer)}
    }
' || fail "CompleteIdentity 只读状态裁决契约测试失败"
for payload_name in install-nvapi-system.ps1 nvapi-system-transaction.ps1 \
        nvapi.dll nvapi64.dll; do
    grep -F "$payload_name" "$BUILD_SCRIPT" >/dev/null \
        || fail "build-exe.sh 缺少 payload: $payload_name"
    grep -F "L\"$payload_name\"" "$LAUNCHER" >/dev/null \
        || fail "launcher 释放表缺少 payload: $payload_name"
    grep -F "$payload_name" "$PACKAGE_SCRIPT" >/dev/null \
        || fail "legacy package 缺少 payload: $payload_name"
done
grep -F 'GPU-Z 2.70' "$README" >/dev/null \
    || fail "README 缺少 GPU-Z 2.70 直接运行说明"

installer_code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
    "$INSTALLER")"
[[ "$installer_code_lines" -le 500 ]] \
    || fail "install-nvapi-system.ps1 非注释代码超过 500 行: $installer_code_lines"
transaction_code_lines="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' \
    "$TRANSACTION_HELPER")"
[[ "$transaction_code_lines" -le 500 ]] \
    || fail "nvapi-system-transaction.ps1 非注释代码超过 500 行: $transaction_code_lines"

echo "OK: guest-stealth direct GPU-Z dual-architecture system NVAPI checks passed"
