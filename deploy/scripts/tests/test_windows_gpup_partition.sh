#!/usr/bin/env bash
# GPU-P 宿主 PartitionCount 事务与按物理 GPU 全局并发锁回归。
# Linux CI 始终运行静态门禁；存在 PowerShell 时用纯内存 Hyper-V mock 动态验证。
# shellcheck disable=SC2016
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Common.ps1"
PARTITION="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Partition.ps1"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
require_text() {
    local needle="$1"
    local file="$2"
    rg -F --quiet -- "$needle" "$file" \
        || fail "missing '$needle' in $file"
}
reject_regex() {
    local pattern="$1"
    local file="$2"
    if rg --quiet -- "$pattern" "$file"; then
        fail "forbidden regex '$pattern' in $file"
    fi
}
test_static_contract() {
    local signature lines dry_line mutation_line
    [[ -f "$PARTITION" ]] || fail "missing GPU-P partition module"
    signature="$(od -An -tx1 -N3 "$PARTITION" | tr -d ' \n')"
    [[ "$signature" == "efbbbf" ]] \
        || fail "Windows PowerShell 5.1 UTF-8 BOM missing: $PARTITION"
    lines="$(wc -l <"$PARTITION")"
    (( lines <= 500 )) || fail "$PARTITION exceeds 500 lines: $lines"
    require_text '#Requires -Version 5.1' "$PARTITION"
    require_text "Join-Path \$PSScriptRoot 'VMate.GpuP.Common.ps1'" \
        "$PARTITION"
    require_text '. $gpuPCommon' "$PARTITION"
    local function_name
    for function_name in \
        Get-VMateGpuPValidPartitionCounts \
        Get-VMateGpuPPartitionCountPlan \
        Resolve-VMateGpuPPartitionableGpu \
        Get-VMateGpuPAssignedAdapterSnapshot \
        Invoke-VMateGpuPHostPartitionCountCore \
        Set-VMateGpuPHostPartitionCount \
        Restore-VMateGpuPHostPartitionCount \
        Get-VMateGpuPHostLockName \
        Invoke-VMateGpuPWithHostLock; do
        require_text "function $function_name" "$PARTITION"
    done
    require_text "'PartitionCount' '所选宿主 GPU'" "$PARTITION"
    require_text "PSObject.Properties['ValidPartitionCounts']" "$PARTITION"
    require_text '$current -ge [uint64]$GuestCapacity' "$PARTITION"
    require_text '$_ -ge [uint64]$GuestCapacity' "$PARTITION"
    require_text 'Set-VMHostPartitionableGpu -Name $InstancePath' "$PARTITION"
    require_text 'Get-VMGpuPartitionAdapter -VM $vm' "$PARTITION"
    require_text "\$ownership = 'Unknown'" "$PARTITION"
    require_text "\$ownership = 'SelectedGpu'" "$PARTITION"
    require_text '$otherMatches.Count -eq 1' "$PARTITION"
    require_text 'Get-VMHostPartitionableGpu -ErrorAction Stop' "$PARTITION"
    require_text '$assigned.Count -ne 0' "$PARTITION"
    require_text 'PartitionCount 回读不一致' "$PARTITION"
    require_text '回滚失败' "$PARTITION"
    require_text "Status = 'Unchanged'" "$PARTITION"
    require_text "Status = 'DryRun'" "$PARTITION"
    require_text 'ChangeApplied = $true' "$PARTITION"
    require_text 'ExpectedPartitionCount' "$PARTITION"
    require_text 'PreviousPartitionCount' "$PARTITION"
    require_text "Global\\VMate.GpuP.\$suffix" "$PARTITION"
    require_text '$mutex.WaitOne(' "$PARTITION"
    require_text '[System.Threading.AbandonedMutexException]' "$PARTITION"
    require_text '$mutex.ReleaseMutex()' "$PARTITION"
    require_text '等待所选 GPU 的宿主配置锁超过' "$PARTITION"
    require_text '$configurationLock = Enter-VMateGpuPConfigurationLock' \
        "$PARTITION"
    require_text 'Exit-VMateGpuPConfigurationLock -Mutex $configurationLock' \
        "$PARTITION"
    local global_lock_line gpu_lock_line
    global_lock_line="$(rg -n -F \
        '$configurationLock = Enter-VMateGpuPConfigurationLock' \
        "$PARTITION" | head -n1 | cut -d: -f1)"
    gpu_lock_line="$(rg -n -F \
        'return Invoke-VMateGpuPWithHostLock -InstancePath $InstancePath' \
        "$PARTITION" | head -n1 | cut -d: -f1)"
    [[ -n "$global_lock_line" && -n "$gpu_lock_line" && \
        "$global_lock_line" -lt "$gpu_lock_line" ]] \
        || fail 'public setter does not acquire global lock before per-GPU lock'
    # 分区有效值只能来自 Hyper-V 属性；禁止写死常见数量、型号、厂商或 DEV ID。
    reject_regex 'ValidPartitionCounts[[:space:]]*=[[:space:]]*@\(' "$PARTITION"
    reject_regex '4060|1060|GeForce|Radeon|DEV_[0-9A-Fa-f]{4}|VEN_[0-9A-Fa-f]{4}' \
        "$PARTITION"
    # DryRun 在第一次 setter 调用之前返回，保证零配置写入。
    dry_line="$(rg -n -F 'if ($DryRun.IsPresent)' "$PARTITION" | \
        head -n1 | cut -d: -f1)"
    mutation_line="$(rg -n -- \
        '^[[:space:]]*Set-VMHostPartitionableGpu -Name' "$PARTITION" | \
        head -n1 | cut -d: -f1)"
    [[ -n "$dry_line" && -n "$mutation_line" && "$dry_line" -lt "$mutation_line" ]] \
        || fail 'DryRun does not return before the first PartitionCount mutation'
}
test_dynamic_partition_contract() {
    local shell_bin
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$shell_bin" ]]; then
        echo 'SKIP: PowerShell not found; static GPU-P partition contract passed'
        return
    fi
    VMATE_GPUP_COMMON="$COMMON" VMATE_GPUP_PARTITION="$PARTITION" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_GPUP_COMMON
            . $env:VMATE_GPUP_PARTITION
            function Assert-Equal {
                param([object]$Actual, [object]$Expected, [string]$Message)
                if ([string]$Actual -cne [string]$Expected) {
                    throw "$Message；actual=$Actual expected=$Expected"
                }
            }
            function Assert-Throws {
                param([scriptblock]$Action, [string]$Pattern)
                try { & $Action } catch {
                    if ($_.Exception.Message -notmatch $Pattern) {
                        throw "错误不可诊断：$($_.Exception.Message)"
                    }
                    return
                }
                throw "预期失败但成功：$Pattern"
            }
            function New-TestGpu {
                param([uint64]$Current, [object[]]$Valid)
                return [pscustomobject]@{
                    Name = "\\?\PCI#TEST_GPU#ONE#{guid}\PARAV"
                    PartitionCount = $Current
                    ValidPartitionCounts = $Valid
                }
            }
            $noDowngrade = Get-VMateGpuPPartitionCountPlan `
                (New-TestGpu 8 @(1, 4, 8, 16)) 3
            Assert-Equal $noDowngrade.DesiredPartitionCount 8 `
                "数量足够时发生降级"
            Assert-Equal $noDowngrade.ChangeRequired $false `
                "数量足够时错误标记变更"
            $increase = Get-VMateGpuPPartitionCountPlan `
                (New-TestGpu 1 @(1, 8, 4, 8)) 3
            Assert-Equal $increase.DesiredPartitionCount 4 `
                "没有选择满足容量的最小动态有效值"
            Assert-Throws {
                Get-VMateGpuPPartitionCountPlan `
                    (New-TestGpu 1 @(1, 2, 4)) 5
            } "没有可容纳"
            Assert-Throws {
                Get-VMateGpuPPartitionCountPlan `
                    (New-TestGpu 3 @(1, 2, 4)) 2
            } "不在 ValidPartitionCounts"
            Assert-Throws {
                Get-VMateGpuPPartitionCountPlan `
                    (New-TestGpu 1 @(0, 4)) 2
            } "无法使用"
            $capacity = (Microsoft.PowerShell.Core\Get-Command `
                Set-VMateGpuPHostPartitionCount).Parameters["GuestCapacity"]
            if (-not @($capacity.Attributes | Where-Object { $_.Mandatory }).Count) {
                throw "public GuestCapacity is not mandatory"
            }
            foreach ($name in "ExpectedPartitionCount", "PreviousPartitionCount") {
                $parameter = (Microsoft.PowerShell.Core\Get-Command `
                    Restore-VMateGpuPHostPartitionCount).Parameters[$name]
                if (-not @($parameter.Attributes | Where-Object { $_.Mandatory }).Count) {
                    throw "restore parameter is not mandatory: $name"
                }
            }
            $script:FakeGpu = New-TestGpu 8 @(1, 4, 8)
            $script:FakeGpuInventory = @($script:FakeGpu)
            $script:SetterAvailable = $false
            $script:FakeAdapters = @()
            $script:MutationCount = 0
            $script:SetMode = "Normal"
            $script:GetVmCount = 0
            function Get-Command {
                param([string]$Name, [object]$ErrorAction)
                if ($Name -ceq "Set-VMHostPartitionableGpu" -and
                    -not $script:SetterAvailable) {
                    return $null
                }
                return [pscustomobject]@{ Name = $Name }
            }
            function Get-VMHostPartitionableGpu {
                param([object]$ErrorAction)
                return @($script:FakeGpuInventory)
            }
            function Get-VM {
                param([object]$ErrorAction)
                $script:GetVmCount++
                return [pscustomobject]@{ Name = "guest-one" }
            }
            function Get-VMGpuPartitionAdapter {
                param([object]$VM, [object]$ErrorAction)
                return @($script:FakeAdapters)
            }
            function Set-VMHostPartitionableGpu {
                param(
                    [string]$Name,
                    [uint16]$PartitionCount,
                    [object]$ErrorAction
                )
                $script:MutationCount++
                if ($script:SetMode -ceq "ThrowAfterMutate" -and
                    $script:MutationCount -eq 1) {
                    $script:FakeGpu.PartitionCount = [uint64]$PartitionCount
                    throw "injected setter failure"
                }
                if ($script:SetMode -ceq "IgnoreDesired" -and
                    $script:MutationCount -eq 1) {
                    return
                }
                if ($script:SetMode -ceq "RollbackFailure" -and
                    $script:MutationCount -eq 2) {
                    throw "injected rollback failure"
                }
                $script:FakeGpu.PartitionCount = [uint64]$PartitionCount
            }
            function Reset-Fake {
                param([uint64]$Current = 1)
                $script:FakeGpu = New-TestGpu $Current @(1, 4, 8)
                $script:FakeGpuInventory = @($script:FakeGpu)
                $script:SetterAvailable = $true
                $script:FakeAdapters = @()
                $script:MutationCount = 0
                $script:SetMode = "Normal"
                $script:GetVmCount = 0
            }
            function Assert-AdapterInventoryBlocked {
                param(
                    [object]$Adapter,
                    [string]$Message,
                    [object[]]$AdditionalGpus = @()
                )
                Reset-Fake
                $script:FakeGpuInventory += @($AdditionalGpus)
                $script:FakeAdapters = @($Adapter)
                Assert-Throws {
                    Set-VMateGpuPHostPartitionCount `
                        -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                } "1 个 GPU-P"
                Assert-Equal $script:MutationCount 0 $Message
            }
            $previousOs = $env:OS
            $env:OS = "Windows_NT"
            try {
                $missingCapacityFailed = $false
                try { Set-VMateGpuPHostPartitionCount -InstancePath $script:FakeGpu.Name }
                catch { $missingCapacityFailed = $true }
                if (-not $missingCapacityFailed) { throw "省略 GuestCapacity 未失败" }
                # 旧 Win10 无 setter，但现有数量足够时应保持只读并成功。
                $unchanged = Set-VMateGpuPHostPartitionCount `
                    -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                Assert-Equal $unchanged.Status Unchanged `
                    "无需变更时旧版 Hyper-V 未兼容"
                Assert-Equal $script:MutationCount 0 "只读路径发生写入"
                Assert-Equal $script:GetVmCount 0 "只读路径不应枚举 adapter"
                Reset-Fake
                $script:SetterAvailable = $false
                Assert-Throws {
                    Set-VMateGpuPHostPartitionCount `
                        -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                } "缺少 Set-VMHostPartitionableGpu"
                # 旧 Win10 pathless adapter 归属未知，必须阻断。
                Assert-AdapterInventoryBlocked ([pscustomobject]@{ Id = 1 }) `
                    "归属未知 adapter 存在时仍发生写入"
                # 明确属于所选 GPU 的 adapter 必须阻断（路径比较不区分大小写）。
                Assert-AdapterInventoryBlocked ([pscustomobject]@{
                        Id = 2
                        InstancePath = $script:FakeGpu.Name.ToLowerInvariant()
                    }) "同卡 adapter 存在时仍发生写入"
                # 非空但不在当前 partitionable inventory 的陈旧路径仍属 Unknown。
                Assert-AdapterInventoryBlocked ([pscustomobject]@{
                        Id = 3
                        InstancePath = "\\?\PCI#STALE_GPU#OLD#{guid}\PARAV"
                    }) "陈旧非空 adapter 路径被错误放行"
                $orphanPath = "\\?\PCI#ORPHAN_GPU#OLD#{guid}\PARAV"
                $blankGpu = [pscustomobject]@{ Name = " " }
                Assert-AdapterInventoryBlocked ([pscustomobject]@{
                        Id = 4; InstancePath = $orphanPath
                    }) "空名 inventory 被错误当成另一张卡" `
                    -AdditionalGpus @($blankGpu)
                $duplicatePath = "\\?\PCI#DUP_GPU#OLD#{guid}\PARAV"
                $duplicateGpu = [pscustomobject]@{ Name = $duplicatePath }
                Assert-AdapterInventoryBlocked ([pscustomobject]@{
                        Id = 5; InstancePath = $duplicatePath
                    }) "重复 inventory 路径被错误当成唯一另一张卡" `
                    -AdditionalGpus @($duplicateGpu, $duplicateGpu)
                Reset-Fake
                # 另一张卡的明确非空路径不能阻断所选 GPU 的 PartitionCount。
                $otherPath = "\\?\PCI#OTHER_GPU#TWO#{guid}\PARAV"
                $script:FakeGpuInventory += [pscustomobject]@{
                    Name = $otherPath
                    PartitionCount = [uint64]4
                    ValidPartitionCounts = @(1, 4, 8)
                }
                $script:FakeAdapters = @([pscustomobject]@{
                        Id = 6
                        InstancePath = $otherPath
                    })
                $otherGpuAllowed = Set-VMateGpuPHostPartitionCount `
                    -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                Assert-Equal $otherGpuAllowed.Status Changed `
                    "另一张明确 GPU 的 adapter 被错误阻断"
                Assert-Equal $script:FakeGpu.PartitionCount 4 `
                    "另一张卡 adapter 场景未完成扩容"
                Reset-Fake
                $dry = Set-VMateGpuPHostPartitionCount `
                    -InstancePath $script:FakeGpu.Name -GuestCapacity 3 -DryRun
                Assert-Equal $dry.Status DryRun "DryRun 状态错误"
                Assert-Equal $dry.PartitionCount 4 "DryRun 计划错误"
                Assert-Equal $script:MutationCount 0 "DryRun 发生配置写入"
                Reset-Fake
                $changed = Set-VMateGpuPHostPartitionCount `
                    -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                Assert-Equal $changed.Status Changed "事务状态错误"
                Assert-Equal $script:FakeGpu.PartitionCount 4 "事务未生效"
                Assert-Equal $script:MutationCount 1 "setter 调用次数错误"
                Assert-Equal $changed.ChangeApplied $true "未返回容量回滚 token"
                $restored = Restore-VMateGpuPHostPartitionCount `
                    -InstancePath $script:FakeGpu.Name `
                    -ExpectedPartitionCount 4 -PreviousPartitionCount 1
                Assert-Equal $restored.Status Restored "显式容量回滚失败"
                Assert-Equal $script:FakeGpu.PartitionCount 1 "容量回滚未恢复原值"
                Reset-Fake
                $script:SetMode = "ThrowAfterMutate"
                Assert-Throws {
                    Set-VMateGpuPHostPartitionCount `
                        -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                } "已回滚到原 PartitionCount"
                Assert-Equal $script:FakeGpu.PartitionCount 1 "setter 失败未回滚"
                Assert-Equal $script:MutationCount 2 "失败事务未执行回滚"
                Reset-Fake
                $script:SetMode = "IgnoreDesired"
                Assert-Throws {
                    Set-VMateGpuPHostPartitionCount `
                        -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                } "回读不一致"
                Assert-Equal $script:FakeGpu.PartitionCount 1 "回读失败未恢复原值"
                Reset-Fake
                $script:SetMode = "ThrowAfterMutate"
                # 第二次调用切换成回滚失败模式。
                function Set-VMHostPartitionableGpu {
                    param(
                        [string]$Name,
                        [uint16]$PartitionCount,
                        [object]$ErrorAction
                    )
                    $script:MutationCount++
                    if ($script:MutationCount -eq 1) {
                        $script:FakeGpu.PartitionCount = [uint64]$PartitionCount
                        throw "injected setter failure"
                    }
                    throw "injected rollback failure"
                }
                Assert-Throws {
                    Set-VMateGpuPHostPartitionCount `
                        -InstancePath $script:FakeGpu.Name -GuestCapacity 3
                } "回滚失败.*injected rollback failure"
                $lockPath = "\\?\PCI#SAME_GPU#ONE#{guid}\PARAV"
                $caseVariant = $lockPath.ToLowerInvariant()
                Assert-Equal (Get-VMateGpuPHostLockName $lockPath) `
                    (Get-VMateGpuPHostLockName $caseVariant) `
                    "同一 InstancePath 没有映射到同一锁"
                Assert-Throws {
                    Invoke-VMateGpuPWithHostLock -InstancePath $lockPath `
                        -TimeoutSeconds 2 -ScriptBlock { throw "callback failure" }
                } "callback failure"
                $afterException = Invoke-VMateGpuPWithHostLock `
                    -InstancePath $lockPath -TimeoutSeconds 2 `
                    -ScriptBlock { "released" }
                Assert-Equal $afterException released "异常后 mutex 未释放"
                # 公共 setter 自己按固定顺序拿两层锁，成功和 core 异常都释放。
                $script:LockEvents = [System.Collections.Generic.List[string]]::new()
                function Enter-VMateGpuPConfigurationLock {
                    param([int]$TimeoutSeconds)
                    [void]$script:LockEvents.Add("global-enter")
                    return [pscustomobject]@{ Kind = "global" }
                }
                function Invoke-VMateGpuPWithHostLock {
                    param(
                        [string]$InstancePath,
                        [scriptblock]$ScriptBlock,
                        [int]$TimeoutSeconds
                    )
                    [void]$script:LockEvents.Add("gpu-enter")
                    return & $ScriptBlock
                }
                function Exit-VMateGpuPConfigurationLock {
                    param([object]$Mutex)
                    [void]$script:LockEvents.Add("global-exit")
                }
                Reset-Fake -Current 8
                $script:SetterAvailable = $false
                [void](Set-VMateGpuPHostPartitionCount `
                    -InstancePath $script:FakeGpu.Name -GuestCapacity 3)
                Assert-Equal ($script:LockEvents -join ",") `
                    "global-enter,gpu-enter,global-exit" `
                    "公共 setter 锁顺序错误"
                $script:LockEvents.Clear()
                Reset-Fake -Current 3
                Assert-Throws {
                    Set-VMateGpuPHostPartitionCount `
                        -InstancePath $script:FakeGpu.Name -GuestCapacity 2
                } "不在 ValidPartitionCounts"
                Assert-Equal ($script:LockEvents -join ",") `
                    "global-enter,gpu-enter,global-exit" `
                    "core 异常后公共 setter 未释放全宿主锁"
            } finally {
                $env:OS = $previousOs
            }
            exit 0
        '
}
test_mutex_timeout_when_powershell_exists() {
    local shell_bin temp_dir ready_file holder_pid
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    [[ -n "$shell_bin" ]] || return 0
    temp_dir="$(mktemp -d)"
    ready_file="$temp_dir/ready"
    VMATE_GPUP_COMMON="$COMMON" VMATE_GPUP_PARTITION="$PARTITION" \
        VMATE_GPUP_READY="$ready_file" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_GPUP_COMMON
            . $env:VMATE_GPUP_PARTITION
            $path = "\\?\PCI#LOCK_TIMEOUT#ONE#{guid}\PARAV"
            $name = Get-VMateGpuPHostLockName $path
            $mutex = [System.Threading.Mutex]::new($false, $name)
            $acquired = $false
            try {
                $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
                if (-not $acquired) { throw "holder failed to acquire mutex" }
                [System.IO.File]::WriteAllText($env:VMATE_GPUP_READY, "ready")
                Start-Sleep -Seconds 3
            } finally {
                if ($acquired) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        ' &
    holder_pid=$!
    local waited=0
    while [[ ! -f "$ready_file" && "$waited" -lt 100 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    if [[ ! -f "$ready_file" ]]; then
        wait "$holder_pid" || true
        rm -rf "$temp_dir"
        fail 'mutex holder did not become ready'
    fi
    if ! VMATE_GPUP_COMMON="$COMMON" VMATE_GPUP_PARTITION="$PARTITION" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_GPUP_COMMON
            . $env:VMATE_GPUP_PARTITION
            $path = "\\?\PCI#LOCK_TIMEOUT#ONE#{guid}\PARAV"
            try {
                Invoke-VMateGpuPWithHostLock -InstancePath $path `
                    -TimeoutSeconds 1 -ScriptBlock { throw "must not run" }
                throw "timeout was not enforced"
            } catch {
                if ($_.Exception.Message -notmatch "超过 1s") { throw }
            }
            exit 0
        '; then
        wait "$holder_pid" || true
        rm -rf "$temp_dir"
        fail 'cross-process mutex timeout contract failed'
    fi
    wait "$holder_pid"
    rm -rf "$temp_dir"
}
test_static_contract
test_dynamic_partition_contract
test_mutex_timeout_when_powershell_exists
echo 'OK: Windows GPU-P PartitionCount and host lock checks passed'
