#!/usr/bin/env bash
# Hyper-V GPU-P 核心计算、宿主预检与事务边界回归。
#
# Linux CI 通常没有 PowerShell/Hyper-V，因此静态检查必须独立覆盖安全边界；
# 若提供 pwsh/powershell，再执行不访问宿主的纯函数与选择器动态测试。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Common.ps1"
VM_CONFIG="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.VMConfiguration.ps1"
HOST="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Host.ps1"

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

require_regex() {
    local pattern="$1"
    local file="$2"
    rg --quiet -- "$pattern" "$file" \
        || fail "missing regex '$pattern' in $file"
}

reject_regex() {
    local pattern="$1"
    local file="$2"
    if rg --quiet -- "$pattern" "$file"; then
        fail "forbidden regex '$pattern' in $file"
    fi
}

test_static_contract() {
    local file function_name line_count dry_line mutation_line

    [[ -f "$COMMON" ]] || fail "missing GPU-P common module"
    [[ -f "$VM_CONFIG" ]] || fail "missing GPU-P VM configuration module"
    [[ -f "$HOST" ]] || fail "missing GPU-P host module"
    for file in "$COMMON" "$VM_CONFIG" "$HOST"; do
        line_count="$(wc -l <"$file")"
        (( line_count <= 500 )) \
            || fail "$file exceeds 500 lines: $line_count"
        require_text '#Requires -Version 5.1' "$file"
        reject_regex '\b(Read-Host|PromptForChoice|Start-VM|Stop-VM)\b' "$file"
        reject_regex '(DriverStore|pnputil|dism\.exe|Copy-Item)' "$file"
        reject_regex 'DEV_[0-9A-Fa-f]{4}' "$file"
        reject_regex '(GeForce|Radeon|4060|1060)' "$file"
    done

    for function_name in \
        Assert-VMateGpuPPercentage ConvertTo-VMateGpuPUInt64 \
        Get-VMateGpuPVendorInfo ConvertTo-VMateGpuPPartitionIdentitySeed \
        Get-VMateGpuPScaledValue Get-VMateGpuPResourcePlan \
        Resolve-VMateGpuPQuotaRequest Assert-VMateGpuPFullHostVramQuota \
        Get-VMateGpuPCapabilitySnapshot Get-VMateGpuPQuotaSummary \
        Resolve-VMateGpuPHostPartitionCommand \
        Get-VMateGpuPHostPartitionableGpu \
        Test-VMateGpuPHostPartitionSetter \
        Set-VMateGpuPNativePartitionCount; do
        require_text "function $function_name" "$COMMON"
    done
    require_text '[decimal]::Floor(' "$COMMON"
    require_text '[decimal]$totalValue * [decimal]$Percentage' "$COMMON"
    require_text "'VEN_(10DE|1002)" "$COMMON"
    require_text "'Total', 'Available', 'MinPartition'" "$COMMON"
    reject_regex '\[uint64\]\$totalValue[[:space:]]*\*' "$COMMON"
    reject_regex '(NewGuid|RandomNumberGenerator)' "$COMMON"
    require_text "@('Get-VMHostPartitionableGpu', 'Get-VMPartitionableGpu')" \
        "$COMMON"
    require_text "@('Set-VMHostPartitionableGpu', 'Set-VMPartitionableGpu')" \
        "$COMMON"

    require_text "@('VRAM', 'Encode', 'Decode', 'Compute')" "$COMMON"
    require_text '"Total$resource"' "$COMMON"
    require_text '"MaxPartition$resource"' "$COMMON"

    for function_name in \
        Assert-VMateGpuPHostEnvironment Resolve-VMateGpuPHostGpu \
        Get-VMateGpuPVirtualMachine Assert-VMateGpuPVirtualMachine \
        Resolve-VMateGpuPExistingAdapter Get-VMateGpuPOtherAllocations \
        Get-VMateGpuPConfigurationPlan \
        Invoke-VMateGpuPConfiguration; do
        require_text "function $function_name" "$HOST"
    done
    for function_name in Get-VMateGpuPVMConfigurationSnapshot \
        Test-VMateGpuPVMConfigurationMatch Assert-VMateGpuPAppliedState; do
        require_text "function $function_name" "$VM_CONFIG"
    done
    require_text 'LowMmioGapSize' "$VM_CONFIG"
    require_text 'HighMmioGapSize' "$VM_CONFIG"
    require_text "'HyperVCmdlet+VSSD'" "$VM_CONFIG"
    for function_name in \
        Get-VMateGpuPHostPartitionableGpu Get-VMGpuPartitionAdapter \
        Add-VMGpuPartitionAdapter Set-VMGpuPartitionAdapter \
        Remove-VMGpuPartitionAdapter; do
        require_text "$function_name" "$HOST"
    done
    require_text "[ValidateSet('Auto', 'NVIDIA', 'AMD')]" "$HOST"
    require_text 'PartitionIdentitySeed' "$HOST"
    require_text 'CapabilitySnapshot = $capabilitySnapshot' "$HOST"
    require_text "[string]\$VM.State -cne 'Off'" "$HOST"
    require_text '[int]$VM.Generation -ne 2' "$HOST"
    require_text '-GuestControlledCacheTypes $true' "$HOST"
    require_text '-LowMemoryMappedIoSpace $plan.LowMemoryMappedIoSpace' "$HOST"
    require_text '-HighMemoryMappedIoSpace $plan.HighMemoryMappedIoSpace' "$HOST"
    require_text '-CheckpointType Disabled' "$HOST"
    require_text '-AllowOvercommit' "$HOST"
    require_text 'Enter-VMateGpuPConfigurationLock' "$HOST"
    require_text "'Global\VMate.GpuP.HostConfiguration.v1'" "$COMMON"
    require_text "\$AddCommand.Parameters.ContainsKey('InstancePath')" "$COMMON"
    require_text '$RawGpuCount -ne 1' "$COMMON"
    require_text 'AddQuotaParameters' "$HOST"
    require_text 'if ($quota.Overcommitted -and -not $AllowOvercommit.IsPresent)' \
        "$HOST"
    require_text "Action = if (\$null -eq \$current) { 'Add' } else { 'Set' }" \
        "$HOST"
    require_text 'adapter 回滚失败' "$HOST"
    require_text 'VM 配置回滚失败' "$HOST"
    require_text '-Confirm:$false' "$HOST"
    require_text "[void]\$planParameters.Remove('DryRun')" "$HOST"

    # DryRun 必须在首个真实写 cmdlet 之前返回。函数名/required-command 清单中的
    # Set-VM 文本不算调用，因此只匹配带 -VM 参数的事务写入行。
    dry_line="$(rg -n -F 'if ($DryRun.IsPresent)' "$HOST" | cut -d: -f1)"
    mutation_line="$(rg -n -- '^[[:space:]]*Set-VM -VM ' "$HOST" | \
        head -n1 | cut -d: -f1)"
    [[ -n "$dry_line" && -n "$mutation_line" && "$dry_line" -lt "$mutation_line" ]] \
        || fail 'DryRun does not return before the first VM mutation'
}

test_dynamic_pure_functions() {
    local shell_bin
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$shell_bin" ]]; then
        echo 'SKIP: PowerShell not found; comprehensive static GPU-P contract passed'
        return
    fi

    VMATE_GPUP_COMMON="$COMMON" VMATE_GPUP_HOST="$HOST" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_GPUP_COMMON
            . $env:VMATE_GPUP_HOST

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
                param([string]$Name)
                return [pscustomobject]@{
                    Name = $Name
                    ValidPartitionCounts = @(2, 4)
                    PartitionCount = [uint64]4
                    TotalVRAM = [uint64]1000
                    AvailableVRAM = [uint64]700
                    MinPartitionVRAM = [uint64]100
                    MaxPartitionVRAM = [uint64]800
                    OptimalPartitionVRAM = [uint64]500
                    TotalEncode = [uint64]100
                    AvailableEncode = [uint64]75
                    MinPartitionEncode = [uint64]10
                    MaxPartitionEncode = [uint64]80
                    OptimalPartitionEncode = [uint64]50
                    TotalDecode = [uint64]200
                    AvailableDecode = [uint64]150
                    MinPartitionDecode = [uint64]20
                    MaxPartitionDecode = [uint64]150
                    OptimalPartitionDecode = [uint64]100
                    TotalCompute = [uint64]400
                    AvailableCompute = [uint64]300
                    MinPartitionCompute = [uint64]40
                    MaxPartitionCompute = [uint64]300
                    OptimalPartitionCompute = [uint64]200
                }
            }
            $nvidiaPath = "\\?\PCI#VEN_10DE&DEV_AAAA#1#{guid}\PARAV"
            $amdPath = "\\?\PCI#VEN_1002&DEV_BBBB#2#{guid}\PARAV"
            $nvidia = New-TestGpu $nvidiaPath
            $amd = New-TestGpu $amdPath

            $legacyAdapter = [pscustomobject]@{}
            $legacyOwner = Get-VMateGpuPAdapterOwnership $legacyAdapter `
                $nvidiaPath @($nvidiaPath)
            Assert-Equal $legacyOwner.Ownership SelectedGpu `
                "单 GPU Win10 无路径 adapter 未归属到唯一 GPU"
            $ambiguousOwner = Get-VMateGpuPAdapterOwnership $legacyAdapter `
                $nvidiaPath @($nvidiaPath, $amdPath)
            Assert-Equal $ambiguousOwner.Ownership Unknown `
                "多 GPU 无路径 adapter 没有 fail closed"

            Assert-Equal (Get-VMateGpuPScaledValue 1000 100 800 1 VRAM) 100 `
                "厂商下限夹紧失败"
            Assert-Equal (Get-VMateGpuPScaledValue 1000 100 800 50 VRAM) 500 `
                "百分比缩放失败"
            Assert-Equal (Get-VMateGpuPScaledValue 1000 100 800 100 VRAM) 800 `
                "厂商上限夹紧失败"
            $max = [uint64]::MaxValue
            Assert-Equal (Get-VMateGpuPScaledValue $max 0 $max 99 Compute) `
                18262276632972456098 "UInt64 安全缩放失败"
            Assert-Throws { Get-VMateGpuPScaledValue 100 0 100 0 VRAM } "1..100"
            Assert-Throws { Get-VMateGpuPScaledValue 100 0 101 50 VRAM } "超过总量"
            Assert-Throws { ConvertTo-VMateGpuPUInt64 "1.5" Test } "UInt64"

            $fullRequest = Resolve-VMateGpuPQuotaRequest -Percentages @{
                VramPercentage = 50; EncodePercentage = 50
                DecodePercentage = 50; ComputePercentage = 50
            } -FullSharedGpuQuota
            foreach ($name in "VramPercentage", "EncodePercentage",
                "DecodePercentage", "ComputePercentage") {
                Assert-Equal $fullRequest.Percentages.$name 100 `
                    "FullShared 未将 $name 强制为100"
            }
            Assert-Equal $fullRequest.EffectiveAllowOvercommit $true `
                "FullShared 未隐式允许共享配额超配"
            Assert-Equal $fullRequest.QuotaMode FullHostReportedGpuPQuota `
                "FullShared 配额模式错误"
            Assert-Throws {
                Resolve-VMateGpuPQuotaRequest -Percentages @{
                    VramPercentage = 50; EncodePercentage = 100
                    DecodePercentage = 100; ComputePercentage = 100
                } -ExplicitNames VramPercentage -FullSharedGpuQuota
            } "FullSharedGpuQuota.*冲突"

            $plan = Get-VMateGpuPResourcePlan -HostGpu $nvidia `
                -VramPercentage 50 -EncodePercentage 25 `
                -DecodePercentage 10 -ComputePercentage 75
            Assert-Equal $plan.MaxPartitionVRAM 500 "VRAM 计划错误"
            Assert-Equal $plan.MaxPartitionEncode 25 "Encode 计划错误"
            Assert-Equal $plan.MaxPartitionDecode 20 "Decode 下限错误"
            Assert-Equal $plan.MaxPartitionCompute 300 "Compute 计划错误"
            Assert-Equal $plan.MinPartitionVRAM $plan.OptimalPartitionVRAM `
                "固定配额三元组不一致"

            $nvInfo = Get-VMateGpuPVendorInfo $nvidiaPath
            $amdInfo = Get-VMateGpuPVendorInfo $amdPath
            Assert-Equal $nvInfo.Vendor NVIDIA "NVIDIA vendor 解析失败"
            Assert-Equal $nvInfo.VendorId 10DE "NVIDIA vendor ID 解析失败"
            Assert-Equal $amdInfo.Vendor AMD "AMD vendor 解析失败"
            Assert-Throws { Get-VMateGpuPVendorInfo "PCI#VEN_8086&DEV_0000" } `
                "NVIDIA/AMD"
            $seed = "0" * 64
            Assert-Equal (ConvertTo-VMateGpuPPartitionIdentitySeed $seed) $seed `
                "identity seed 规范化失败"
            Assert-Throws { ConvertTo-VMateGpuPPartitionIdentitySeed "abcd" } `
                "64 位"

            $one = Resolve-VMateGpuPHostGpu @($nvidia) "" Auto ""
            Assert-Equal $one.VendorInfo.Vendor NVIDIA "唯一 GPU 选择失败"
            $explicit = Resolve-VMateGpuPHostGpu @($nvidia, $amd) `
                $amdPath AMD ""
            Assert-Equal $explicit.VendorInfo.Vendor AMD "显式 AMD 选择失败"
            Assert-Throws {
                Resolve-VMateGpuPHostGpu @($nvidia, $amd) "" Auto ""
            } "PartitionIdentitySeed"
            $stableA = Resolve-VMateGpuPHostGpu @($nvidia, $amd) "" Auto $seed
            $stableB = Resolve-VMateGpuPHostGpu @($amd, $nvidia) "" Auto $seed
            Assert-Equal $stableA.VendorInfo.InstancePath `
                $stableB.VendorInfo.InstancePath "Auto 选择不稳定"
            $otherSeed = "00000001" + ("0" * 56)
            $otherBrand = Resolve-VMateGpuPHostGpu @($nvidia, $amd) `
                "" Auto $otherSeed
            if ($otherBrand.VendorInfo.Vendor -eq $stableA.VendorInfo.Vendor) {
                throw "不同随机 seed 未覆盖真实多品牌候选"
            }
            Assert-Throws {
                Resolve-VMateGpuPHostGpu @($nvidia) $nvidiaPath AMD ""
            } "无法唯一解析"

            $snapshot = Get-VMateGpuPCapabilitySnapshot $nvidia $nvInfo
            Assert-Equal $snapshot.VendorId 10DE "能力快照 vendor 错误"
            Assert-Equal $snapshot.Resources.VRAM.Total 1000 `
                "能力快照 VRAM 错误"
            [void](Assert-VMateGpuPFullHostVramQuota `
                    ([pscustomobject]@{ MaxPartitionVRAM = [uint64]1000 }) `
                    $snapshot)
            Assert-Throws {
                Assert-VMateGpuPFullHostVramQuota `
                    ([pscustomobject]@{ MaxPartitionVRAM = [uint64]800 }) `
                    $snapshot "full quota mismatch"
            } "full quota mismatch"
            $existing = [pscustomobject]@{
                MaxPartitionVRAM = [uint64]600
                MaxPartitionEncode = [uint64]70
                MaxPartitionDecode = [uint64]140
                MaxPartitionCompute = [uint64]250
            }
            $quota = Get-VMateGpuPQuotaSummary $nvidia $plan @($existing)
            if (-not $quota.Overcommitted -or
                -not $quota.Resources.VRAM.Exceeded) {
                throw "多 VM 超配未被识别"
            }
            $emptyQuota = Get-VMateGpuPQuotaSummary $nvidia $plan @()
            if ($emptyQuota.Overcommitted) {
                throw "单 VM 合法配额被错误拒绝"
            }

            # 以下 fake 仅修改内存对象，证明 DryRun 与事务补偿，不访问 Hyper-V。
            $script:FakeGpu = $nvidia
            $script:FakeAdapters = @()
            $script:MutationCount = 0
            $script:FailAddOnce = $false
            $script:FailSetOnce = $false
            $script:FakeVm = [pscustomobject]@{
                Name = "test-vm"
                Id = [guid]::NewGuid()
                State = "Off"
                Generation = 2
                GuestControlledCacheTypes = $false
                LowMemoryMappedIoSpace = [uint64]256
                HighMemoryMappedIoSpace = [uint64]512
                CheckpointType = "Production"
            }
            function Assert-VMateGpuPHostEnvironment {}
            function Get-VMHostPartitionableGpu {
                param([string]$Name, [string]$ErrorAction)
                return $script:FakeGpu
            }
            function Get-VM {
                param([string]$Name, [string]$ErrorAction)
                return $script:FakeVm
            }
            function Get-VMGpuPartitionAdapter {
                param([object]$VM, [string]$VMName, [string]$ErrorAction)
                return @($script:FakeAdapters)
            }
            function Set-VM {
                param(
                    [object]$VM,
                    [bool]$GuestControlledCacheTypes,
                    [uint64]$LowMemoryMappedIoSpace,
                    [uint64]$HighMemoryMappedIoSpace,
                    [object]$CheckpointType,
                    [switch]$Confirm,
                    [string]$ErrorAction
                )
                $script:MutationCount++
                $VM.GuestControlledCacheTypes = $GuestControlledCacheTypes
                $VM.LowMemoryMappedIoSpace = $LowMemoryMappedIoSpace
                $VM.HighMemoryMappedIoSpace = $HighMemoryMappedIoSpace
                $VM.CheckpointType = [string]$CheckpointType
            }
            function New-FakeAdapter {
                param([object]$Values, [string]$Path)
                return [pscustomobject]@{
                    InstancePath = $Path
                    Id = [guid]::NewGuid()
                    MinPartitionVRAM = [uint64]$Values.MinPartitionVRAM
                    MaxPartitionVRAM = [uint64]$Values.MaxPartitionVRAM
                    OptimalPartitionVRAM = [uint64]$Values.OptimalPartitionVRAM
                    MinPartitionEncode = [uint64]$Values.MinPartitionEncode
                    MaxPartitionEncode = [uint64]$Values.MaxPartitionEncode
                    OptimalPartitionEncode = [uint64]$Values.OptimalPartitionEncode
                    MinPartitionDecode = [uint64]$Values.MinPartitionDecode
                    MaxPartitionDecode = [uint64]$Values.MaxPartitionDecode
                    OptimalPartitionDecode = [uint64]$Values.OptimalPartitionDecode
                    MinPartitionCompute = [uint64]$Values.MinPartitionCompute
                    MaxPartitionCompute = [uint64]$Values.MaxPartitionCompute
                    OptimalPartitionCompute = [uint64]$Values.OptimalPartitionCompute
                }
            }
            function Add-VMGpuPartitionAdapter {
                param(
                    [object]$VM, [string]$InstancePath,
                    [uint64]$MinPartitionVRAM, [uint64]$MaxPartitionVRAM,
                    [uint64]$OptimalPartitionVRAM,
                    [uint64]$MinPartitionEncode, [uint64]$MaxPartitionEncode,
                    [uint64]$OptimalPartitionEncode,
                    [uint64]$MinPartitionDecode, [uint64]$MaxPartitionDecode,
                    [uint64]$OptimalPartitionDecode,
                    [uint64]$MinPartitionCompute, [uint64]$MaxPartitionCompute,
                    [uint64]$OptimalPartitionCompute,
                    [switch]$Passthru, [switch]$Confirm, [string]$ErrorAction
                )
                $script:MutationCount++
                $values = [pscustomobject]$PSBoundParameters
                $adapter = New-FakeAdapter $values $InstancePath
                $script:FakeAdapters = @($adapter)
                if ($script:FailAddOnce) {
                    $script:FailAddOnce = $false
                    throw "fake add failure"
                }
                return $adapter
            }
            function Set-VMGpuPartitionAdapter {
                param(
                    [object]$VMGpuPartitionAdapter,
                    [uint64]$MinPartitionVRAM, [uint64]$MaxPartitionVRAM,
                    [uint64]$OptimalPartitionVRAM,
                    [uint64]$MinPartitionEncode, [uint64]$MaxPartitionEncode,
                    [uint64]$OptimalPartitionEncode,
                    [uint64]$MinPartitionDecode, [uint64]$MaxPartitionDecode,
                    [uint64]$OptimalPartitionDecode,
                    [uint64]$MinPartitionCompute, [uint64]$MaxPartitionCompute,
                    [uint64]$OptimalPartitionCompute,
                    [switch]$Passthru, [switch]$Confirm, [string]$ErrorAction
                )
                $script:MutationCount++
                foreach ($name in @("MinPartitionVRAM", "MaxPartitionVRAM",
                        "OptimalPartitionVRAM", "MinPartitionEncode",
                        "MaxPartitionEncode", "OptimalPartitionEncode",
                        "MinPartitionDecode", "MaxPartitionDecode",
                        "OptimalPartitionDecode", "MinPartitionCompute",
                        "MaxPartitionCompute", "OptimalPartitionCompute")) {
                    $VMGpuPartitionAdapter.$name = $PSBoundParameters[$name]
                }
                if ($script:FailSetOnce) {
                    $script:FailSetOnce = $false
                    throw "fake set failure"
                }
                return $VMGpuPartitionAdapter
            }
            function Remove-VMGpuPartitionAdapter {
                param(
                    [object]$VMGpuPartitionAdapter,
                    [switch]$Confirm,
                    [string]$ErrorAction
                )
                $script:MutationCount++
                $script:FakeAdapters = @()
            }

            $invoke = @{
                VMName = "test-vm"
                InstancePath = $nvidiaPath
                Vendor = "NVIDIA"
                VramPercentage = 50
                EncodePercentage = 50
                DecodePercentage = 50
                ComputePercentage = 50
                PartitionIdentitySeed = $seed
            }
            $dryPlan = Invoke-VMateGpuPConfiguration @invoke -DryRun
            Assert-Equal $dryPlan.Action Add "DryRun action 错误"
            Assert-Equal $script:MutationCount 0 "DryRun 发生写入"
            $result = Invoke-VMateGpuPConfiguration @invoke
            Assert-Equal $result.Succeeded $true "Add 事务失败"
            Assert-Equal $script:FakeAdapters.Count 1 "Add 未创建 adapter"

            # Add 在创建 adapter 后抛错时，必须移除新增项并恢复 VM 四项配置。
            $script:FakeAdapters = @()
            $script:FakeVm.GuestControlledCacheTypes = $false
            $script:FakeVm.LowMemoryMappedIoSpace = [uint64]256
            $script:FakeVm.HighMemoryMappedIoSpace = [uint64]512
            $script:FakeVm.CheckpointType = "Production"
            $script:FailAddOnce = $true
            Assert-Throws { Invoke-VMateGpuPConfiguration @invoke } `
                "已按事务记录完成回滚"
            Assert-Equal $script:FakeAdapters.Count 0 "Add 失败残留 adapter"
            Assert-Equal $script:FakeVm.CheckpointType Production `
                "Add 失败未恢复 VM"

            # 既有 adapter 的 Set 部分失败时，十二项资源与 VM 快照都要恢复。
            $oldPlan = Get-VMateGpuPResourcePlan $nvidia 25 25 25 25
            $oldAdapter = New-FakeAdapter $oldPlan $nvidiaPath
            $script:FakeAdapters = @($oldAdapter)
            $script:FakeVm.GuestControlledCacheTypes = $false
            $script:FakeVm.CheckpointType = "Production"
            $script:FailSetOnce = $true
            Assert-Throws { Invoke-VMateGpuPConfiguration @invoke } `
                "已按事务记录完成回滚"
            Assert-Equal $oldAdapter.MaxPartitionVRAM `
                $oldPlan.MaxPartitionVRAM "Set 失败未恢复 adapter"
            Assert-Equal $script:FakeVm.CheckpointType Production `
                "Set 失败未恢复 VM"

            # 旧 Win10 cmdlet 没有 -InstancePath 时，候选总数必须包含 Intel。
            # 即使受支持厂商池只有一张 NVIDIA，也不能让 Hyper-V 猜卡。
            $script:FakeAdapters = @()
            $intel = New-TestGpu "\\?\PCI#VEN_8086&DEV_CCCC#3#{guid}\PARAV"
            $script:FakeGpu = @($nvidia, $intel)
            function Add-VMGpuPartitionAdapter {
                param([object]$VM, [switch]$Passthru,
                    [switch]$Confirm, [string]$ErrorAction)
                $script:MutationCount++
                $initial = Get-VMateGpuPResourcePlan $script:FakeGpu 1 1 1 1
                $adapter = New-FakeAdapter $initial ""
                $script:FakeAdapters = @($adapter)
                return $adapter
            }
            $beforeFallback = $script:MutationCount
            Assert-Throws { Invoke-VMateGpuPConfiguration @invoke } `
                "只有恰好一张"
            Assert-Equal $script:MutationCount $beforeFallback `
                "旧 Win10 多候选 fallback 发生了写入"

            $unnamed = New-TestGpu ""
            $script:FakeGpu = @($nvidia, $unnamed)
            Assert-Throws { Invoke-VMateGpuPConfiguration @invoke } `
                "只有恰好一张"
            Assert-Equal $script:MutationCount $beforeFallback `
                "旧 Win10 空名称候选 fallback 发生了写入"

            # 恰好一张卡时，瘦 Add 只创建 adapter，随后必须由 Set 写满12项。
            $script:FakeGpu = $nvidia
            $slimResult = Invoke-VMateGpuPConfiguration @invoke
            Assert-Equal $slimResult.Succeeded $true "旧 Win10 瘦 Add 失败"
            Assert-Equal $script:FakeAdapters[0].MaxPartitionVRAM 500 `
                "旧 Win10 瘦 Add 未通过 Set 写入配额"
        '
}

test_static_contract
test_dynamic_pure_functions
echo 'PASS: Windows Hyper-V GPU-P host core contract'
