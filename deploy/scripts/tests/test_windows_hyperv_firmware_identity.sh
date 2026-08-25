#!/usr/bin/env bash
# P-11 Hyper-V 固件身份 CSPRNG、WMI 单次提交与回读回归。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.FirmwareIdentity.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1"
    rg -F --quiet -- "$needle" "$MODULE" || fail "missing '$needle'"
}

reject_regex() {
    local pattern="$1"
    if rg --quiet -- "$pattern" "$MODULE"; then
        fail "forbidden pattern '$pattern'"
    fi
}

test_static_contract() {
    [[ -f "$MODULE" ]] || fail "missing firmware identity module"
    [[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] \
        || fail "PowerShell 5.1 UTF-8 BOM missing"
    local lines
    lines="$(wc -l < "$MODULE")"
    (( lines <= 500 )) || fail "module exceeds 500 lines: $lines"

    require_text '#Requires -Version 5.1'
    require_text '[Security.Cryptography.RandomNumberGenerator]::Create()'
    require_text "'root\virtualization\v2'"
    require_text 'Msvm_VirtualSystemSettingData'
    require_text 'Msvm_VirtualSystemManagementService'
    require_text 'ModifySystemSettings($payload)'
    require_text "'Microsoft:Hyper-V:System:Realized'"
    require_text '$state -ne 3'
    require_text '$returnValue -eq 4096'
    require_text '$state -in @(8, 9, 10)'
    require_text '不能假定 BIOSGUID 可回滚'

    local name
    for name in \
        New-VMateHyperVFirmwareIdentityFragment \
        ConvertTo-VMateHyperVFirmwareIdentityFragment \
        Get-VMateHyperVFirmwareIdentitySnapshot \
        Get-VMateHyperVFirmwareVssd \
        Wait-VMateHyperVFirmwareWmiJob \
        Invoke-VMateHyperVFirmwareIdentityTransaction; do
        require_text "function $name"
    done
    for name in BIOSGUID BIOSSerialNumber BaseBoardSerialNumber \
        ChassisSerialNumber ChassisAssetTag; do
        require_text "$name"
    done

    # 低层模块不拥有持久化，也不借助客机投影、注册表或旧 QEMU 设备模型。
    reject_regex '(ConvertTo-Json|WriteAllText|Write-VMate.*Json|Set-ItemProperty|New-ItemProperty)'
    reject_regex '(qemu|whpx|respawn-stealth|nvapi|adl-shim|GPU_SERIAL)'
}

test_dynamic_contract() {
    local shell_bin
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$shell_bin" ]]; then
        echo 'SKIP: PowerShell not found; static firmware identity contract passed'
        return
    fi

    VMATE_HYPERV_FIRMWARE_IDENTITY="$MODULE" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_HYPERV_FIRMWARE_IDENTITY

        function Assert-True {
            param([bool]$Condition, [string]$Message)
            if (-not $Condition) { throw $Message }
        }
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
        function Copy-Identity {
            param([object]$Source)
            return [pscustomobject]@{
                BIOSGUID = [string]$Source.BIOSGUID
                BIOSSerialNumber = [string]$Source.BIOSSerialNumber
                BaseBoardSerialNumber = [string]$Source.BaseBoardSerialNumber
                ChassisSerialNumber = [string]$Source.ChassisSerialNumber
                ChassisAssetTag = [string]$Source.ChassisAssetTag
            }
        }

        $one = New-VMateHyperVFirmwareIdentityFragment
        $two = New-VMateHyperVFirmwareIdentityFragment
        [void](ConvertTo-VMateHyperVFirmwareIdentityFragment $one)
        Assert-True ($one.BIOSGUID -ne $two.BIOSGUID) "CSPRNG GUID 重复"
        Assert-Equal $one.BIOSGUID[15] 4 "GUID 不是 version 4"
        Assert-True ("89AB".Contains($one.BIOSGUID[20])) "GUID variant 错误"
        foreach ($name in "BIOSSerialNumber", "BaseBoardSerialNumber",
            "ChassisSerialNumber", "ChassisAssetTag") {
            Assert-True ([string]$one.$name -cmatch "^[0-9A-F]{32}$") `
                "$name 格式错误"
            Assert-True ([string]$one.$name -cne [string]$two.$name) `
                "$name 随机值重复"
        }
        $broken = $one | Select-Object *
        $broken.BIOSSerialNumber = "bad"
        Assert-Throws {
            ConvertTo-VMateHyperVFirmwareIdentityFragment $broken
        } "4..64 位"
        $custom = $one | Select-Object *
        $custom.BIOSSerialNumber = "BIOS-REAL-0001"
        $custom.BaseBoardSerialNumber = "BOARD-REAL-0001"
        $custom.ChassisSerialNumber = "CHASSIS-REAL-0001"
        $custom.ChassisAssetTag = "ASSET-REAL-0001"
        $normalizedCustom =
            ConvertTo-VMateHyperVFirmwareIdentityFragment $custom
        Assert-Equal $normalizedCustom.BaseBoardSerialNumber `
            "BOARD-REAL-0001" "自定义主板序列未保留"

        # 用纯内存边界替换 Hyper-V WMI；事务核心仍执行完整预检和回读。
        $script:VmState = [uint16]3
        $script:Stored = [pscustomobject]@{
            BIOSGUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            BIOSSerialNumber = "OLD-BIOS"
            BaseBoardSerialNumber = "OLD-BOARD"
            ChassisSerialNumber = "OLD-CHASSIS"
            ChassisAssetTag = "OLD-ASSET"
        }
        $script:ModifyCalls = 0
        $script:CorruptNextApply = $false
        function Get-VMateHyperVFirmwareComputerSystem {
            param([Guid]$VMId)
            return [pscustomobject]@{ EnabledState = $script:VmState }
        }
        function Get-VMateHyperVFirmwareVssd {
            param([Guid]$VMId)
            return Copy-Identity $script:Stored
        }
        function Invoke-VMateHyperVFirmwareWmiModify {
            param([object]$Vssd, [int]$JobTimeoutSeconds)
            $script:ModifyCalls++
            $script:Stored = Copy-Identity $Vssd
            if ($script:CorruptNextApply) {
                $script:CorruptNextApply = $false
                $script:Stored.BIOSSerialNumber = "CORRUPTED"
            }
        }
        # Linux PowerShell 不一定实现 Global 命名空间；mock 只替换同步边界。
        function Enter-VMateHyperVFirmwareIdentityLock {
            param([Guid]$VMId, [int]$TimeoutSeconds)
            return [Threading.Mutex]::new($true)
        }

        $vmId = [Guid]::NewGuid()
        $original = Copy-Identity $script:Stored
        $applied = Invoke-VMateHyperVFirmwareIdentityTransaction `
            -VMId $vmId -Identity $one
        Assert-Equal $applied.Status Applied "事务未报告 Applied"
        Assert-True (Test-VMateHyperVFirmwareIdentityMatch `
                $script:Stored $one) "WMI mock 未保存请求身份"
        Assert-Equal $script:ModifyCalls 1 "成功事务写入次数错误"

        $unchanged = Invoke-VMateHyperVFirmwareIdentityTransaction `
            -VMId $vmId -Identity $one
        Assert-Equal $unchanged.Status Unchanged "幂等事务未报告 Unchanged"
        Assert-Equal $script:ModifyCalls 1 "幂等事务仍执行写入"

        $script:VmState = [uint16]2
        Assert-Throws {
            Invoke-VMateHyperVFirmwareIdentityTransaction `
                -VMId $vmId -Identity $two
        } "只能在 VM Off"
        Assert-Equal $script:ModifyCalls 1 "运行中 VM 发生写入"

        $script:VmState = [uint16]3
        $script:Stored = Copy-Identity $original
        $script:CorruptNextApply = $true
        $beforeFailure = Copy-Identity $script:Stored
        Assert-Throws {
            Invoke-VMateHyperVFirmwareIdentityTransaction `
                -VMId $vmId -Identity $two
        } "部分更改"
        Assert-True (-not (Test-VMateHyperVFirmwareIdentityMatch `
                $script:Stored $beforeFailure)) "部分写入被错误报告为原值"
        Assert-Equal $script:ModifyCalls 2 "失败事务重复写入或尝试 GUID 回滚"

        # 异步 Job 的成功与失败终态均需可诊断。
        $script:JobPoll = 0
        function Get-VMateHyperVFirmwareWmiJob {
            param([string]$JobReference)
            $script:JobPoll++
            if ($script:JobPoll -eq 1) {
                return [pscustomobject]@{ JobState = 4; ErrorCode = 0 }
            }
            return [pscustomobject]@{ JobState = 7; ErrorCode = 0 }
        }
        Wait-VMateHyperVFirmwareWmiJob -JobReference mock -TimeoutSeconds 2 |
            Out-Null
        Assert-Equal $script:JobPoll 2 "异步 Job 未轮询至完成"
        function Get-VMateHyperVFirmwareWmiJob {
            param([string]$JobReference)
            return [pscustomobject]@{
                JobState = 10; ErrorCode = 123
                ErrorDescription = "mock provider failure"
            }
        }
        Assert-Throws {
            Wait-VMateHyperVFirmwareWmiJob `
                -JobReference mock -TimeoutSeconds 2
        } "mock provider failure"
        Assert-Throws {
            Complete-VMateHyperVFirmwareWmiOperation `
                ([pscustomobject]@{ ReturnValue = 5 }) 2
        } "ReturnValue=5"
    '
}

test_static_contract
test_dynamic_contract
echo 'PASS: Hyper-V firmware identity contract'
