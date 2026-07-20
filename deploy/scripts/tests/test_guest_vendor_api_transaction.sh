#!/usr/bin/env bash
# 审计 NVIDIA/AMD reader 与版本化 identity pointer 的统一跨组件事务顺序。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COORDINATOR="$REPO_ROOT/deploy/guest-stealth/install-gpu-api-system.ps1"
NVAPI_INSTALL="$REPO_ROOT/deploy/guest-stealth/install-nvapi-system.ps1"
ADL_INSTALL="$REPO_ROOT/deploy/guest-stealth/install-adl-system.ps1"
APPLY="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$COORDINATOR" "$NVAPI_INSTALL" "$ADL_INSTALL" "$APPLY"; do
    [[ -f "$path" ]] || fail "缺少统一厂商 API 事务文件：$path"
done

PS_FILES="$COORDINATOR:$NVAPI_INSTALL:$ADL_INSTALL:$APPLY" \
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
' || fail "统一厂商 API PowerShell AST 解析失败"

python3 - "$COORDINATOR" "$APPLY" <<'PY'
from pathlib import Path
import sys

coordinator = Path(sys.argv[1]).read_text(encoding="utf-8-sig")
apply = Path(sys.argv[2]).read_text(encoding="utf-8-sig")

def require(text: str, needle: str, label: str) -> int:
    offset = text.find(needle)
    if offset < 0:
        raise SystemExit(f"FAIL: 缺少事务契约：{label}")
    return offset

# coordinator 先构造 NVAPI+ADL 的完整 preflightSteps，且整个门禁返回后才进入
# 任一 Install/Prepare。forward 明确包含两者，rollback 则反向。
forward = require(coordinator, "Label='NVAPI'; Script=$nvapiInstaller", "NVAPI forward")
adl_forward = require(coordinator, "Label='ADL'; Script=$adlInstaller", "ADL forward")
preflight = require(
    coordinator,
    "Invoke-GpuApiSteps $preflightSteps 'GPU API 全量只读预检失败'",
    "双 reader 全量 Preflight",
)
prepare_loop = require(coordinator, "foreach ($component in $forward)", "Prepare 循环")
if not (forward < adl_forward < preflight < prepare_loop):
    raise SystemExit("FAIL: 两套 reader 没有全部 Preflight 后再 Prepare")
require(coordinator, "$reverse = @($forward[1], $forward[0])", "reader 反向回滚")
require(
    coordinator,
    "$arguments += @('-TransactionId', $TransactionId)",
    "所有子 installer 复用同一 TransactionId",
)
require(coordinator, "-Deferred:$step.Deferred", "deferred receipt 透传")

# apply 的正式状态机：reader Prepare -> CurrentIdentity Commit -> identity Complete
# -> reader Finalize；异常 finally 中必须先恢复 pointer，才能恢复旧 reader。
prepared = require(apply, "'-Action', 'Install'", "reader Prepare")
commit = require(apply, "-CommitIdentity $identityTransactionId", "pointer Commit")
complete = require(apply, "-CompleteIdentity $identityTransactionId", "identity Complete")
finalize = require(apply, "'-Action', 'Finalize'", "reader Finalize")
if not (prepared < commit < complete < finalize):
    raise SystemExit("FAIL: Prepare→Commit→Complete→Finalize 顺序错误")

finally_at = apply.rfind("} finally {")
if finally_at < 0:
    raise SystemExit("FAIL: 缺少事务契约：outer finally")
rollback_pointer = apply.find("-RollbackIdentity $identityTransactionId", finally_at)
reader_action = apply.find("'-Action', $gpuApiRecoveryAction", finally_at)
if rollback_pointer < 0 or reader_action < 0 or rollback_pointer >= reader_action:
    raise SystemExit("FAIL: 失败收口没有先回滚 identity pointer 再回滚 reader")

# DeferFinalize 跨越多个 PowerShell 进程，不能只依赖单次 child installer 的文件锁。
# coordinator 必须先持久化唯一 reservation；同一 ID 才能 Finalize/Rollback，Recover
# 则按 durable CurrentIdentity 指针裁决遗留 reservation 的收口方向。
reservation_create = require(
    coordinator,
    "New-GpuApiReservation -Path $reservationPath -TransactionId $TransactionId",
    "Prepare 前创建 coordinator reservation",
)
reserved_preflight = coordinator.find(
    "Invoke-GpuApiSteps $preflightSteps 'GPU API 全量只读预检失败'",
    reservation_create,
)
if reserved_preflight < 0 or not (reservation_create < reserved_preflight < prepare_loop):
    raise SystemExit("FAIL: reservation 没有覆盖 Preflight→Prepare 窗口")
require(coordinator, "Assert-GpuApiReservationOwner -Path $reservationPath", "Finalize/Rollback owner 校验")
require(coordinator, "Remove-GpuApiReservation -Path $reservationPath", "成功收口后释放 reservation")
current_identity = require(coordinator, "Get-GpuApiCurrentIdentityToken", "Recover identity 裁决")
settlement = require(coordinator, "$settlementAction = if ($currentIdentity -ceq $leasedTransactionId)", "Recover 收口方向")
if current_identity >= settlement:
    raise SystemExit("FAIL: Recover 没有先读取 durable CurrentIdentity 再裁决 reservation")
PY

# 在 Linux 临时目录执行 reservation 的纯文件状态机。它证明不同 ID 无法趁第一次
# Prepare/identity/Finalize 的进程间隙写入，且 owner 校验不能被错误 ID 删除。
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
COORDINATOR_PATH="$COORDINATOR" TEST_ROOT="$TEST_ROOT" \
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
    . Import-Functions $env:COORDINATOR_PATH

    $directory = Join-Path $env:TEST_ROOT "reservations"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory "active"
    $first = "11111111111111111111111111111111"
    $second = "22222222222222222222222222222222"
    New-GpuApiReservation -Path $path -TransactionId $first
    if ((Read-GpuApiReservation -Path $path) -cne $first) {
        throw "reservation 没有写入首个 owner"
    }
    foreach ($operation in @(
        { New-GpuApiReservation -Path $path -TransactionId $second },
        { Assert-GpuApiReservationOwner -Path $path -TransactionId $second },
        { Remove-GpuApiReservation -Path $path -TransactionId $second })) {
        try {
            & $operation
            throw "不同 TransactionId 被错误放行"
        } catch {
            if ($_.Exception.Message -eq "不同 TransactionId 被错误放行") { throw }
        }
    }
    if (@(Get-ChildItem -LiteralPath $directory -Force -Filter ".active.tmp-*").Count -ne 0) {
        throw "reservation 原子发布遗留临时文件"
    }
    Remove-GpuApiReservation -Path $path -TransactionId $first
    if (Test-Path -LiteralPath $path) { throw "正确 owner 未释放 reservation" }

    # 通过替身验证 Recover 的两个确定性分支，不需要访问 Linux 上不存在的 HKLM。
    $forward = @(
        [pscustomobject]@{ Label="NVAPI"; Script="nvapi" },
        [pscustomobject]@{ Label="ADL"; Script="adl" }
    )
    $reverse = @($forward[1], $forward[0])
    $script:mockIdentity = ""
    $script:recoveryActions = @()
    function Get-GpuApiCurrentIdentityToken { return $script:mockIdentity }
    function Invoke-GpuApiSteps {
        param([object[]]$Steps, [string]$FailurePrefix)
        $script:recoveryActions += @($Steps | ForEach-Object { [string]$_.Action })
    }
    New-GpuApiReservation -Path $path -TransactionId $first
    $script:mockIdentity = $first
    $finalized = Resolve-GpuApiReservation -ReservationPath $path -Forward $forward -Reverse $reverse
    if ($finalized.Action -cne "Finalize" -or
        (($script:recoveryActions -join ",") -cne "Finalize,Finalize") -or
        (Test-Path -LiteralPath $path)) {
        throw "Recover 没有在 CurrentIdentity 命中时 Finalize reservation"
    }
    $script:recoveryActions = @()
    New-GpuApiReservation -Path $path -TransactionId $second
    $script:mockIdentity = ""
    $rolledBack = Resolve-GpuApiReservation -ReservationPath $path -Forward $forward -Reverse $reverse
    if ($rolledBack.Action -cne "Rollback" -or
        (($script:recoveryActions -join ",") -cne "Rollback,Rollback") -or
        (Test-Path -LiteralPath $path)) {
        throw "Recover 没有在 CurrentIdentity 未命中时 Rollback reservation"
    }
    $lock = Open-GpuApiCoordinatorLock -Directory $directory
    $lock.Dispose()
' || fail "GPU API coordinator reservation 状态机测试失败"

# 两家实现均只能按版本化硬件 identity/vendor 裁决；禁止工具进程名、窗口名、
# app-local 复制或 DLL 注入分支。注释里提到检测工具不算特判，故只查可执行机制。
if rg -ni \
    'Get-Process|ProcessName|MainWindowTitle|CreateRemoteThread|WriteProcessMemory|AppInit_DLLs|Image File Execution Options|LocalApplicationData|Copy-Item.*GPU-Z|GPU-Z\\.exe|HWiNFO(32|64)?\\.exe|AIDA64\\.exe' \
        "$NVAPI_INSTALL" "$ADL_INSTALL" "$APPLY" \
        "$NVAPI_DIR"/*.[ch] "$ADL_DIR"/*.[ch] >&2; then
    fail "NVIDIA/AMD reader 仍含按检测进程适配或注入路径"
fi
for contract in \
        "NVAPI + ADL 五个目标完成全量只读预检" \
        "readers prepared before pointer commit" \
        "先把 pointer 恢复旧版"; do
    grep -F "$contract" "$APPLY" >/dev/null \
        || fail "apply 缺少跨组件顺序契约：$contract"
done

[[ "$(wc -l < "$COORDINATOR")" -le 500 ]] \
    || fail "统一厂商 API coordinator 超过 500 行"

echo "OK: unified NVIDIA/AMD reader and identity transaction ordering passed"
