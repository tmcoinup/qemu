#Requires -Version 5.1

<#
.SYNOPSIS
    事务化协调 Hyper-V VM 的冷启动 CPUID 品牌投影。

.DESCRIPTION
    仅允许 VM 从 Off 状态进入一次极短的 Paused 冷启动窗口。协调器先通过
    固定 SHA-256 的只读用户态探针找出唯一受保护 VID handle，再调用只读、
    非驻留的 VID context driver 核验 partition ID，最后调用白名单仅包含
    0x80000002..0x80000004 的非驻留 CPUID driver。全部成功后才恢复 VM。

    任一步失败都会关闭本次 VM，避免未投影或部分投影的 guest 继续启动。
    本模块不修改 BCD，不开启 test signing，也不允许运行中切换 CPU 型号。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gpuPIsolationModule = Join-Path $PSScriptRoot `
    'VMate.HyperV.GpuPColdStartIsolation.ps1'
if (-not (Get-Command Get-VMateHyperVGpuPColdStartAdapterSnapshot `
        -CommandType Function -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath $gpuPIsolationModule -PathType Leaf)) {
        throw "GPU-P 冷启动隔离模块不存在：$gpuPIsolationModule"
    }
    . $gpuPIsolationModule
}

function Get-VMateHyperVCpuidColdStartProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null,
        [switch]$Required
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Required) { throw "冷启动对象缺少 $Name。" }
        return $DefaultValue
    }
    return $property.Value
}

function Assert-VMateHyperVCpuidColdStartFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Description 不存在：$fullPath"
    }
    $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
    if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$Description SHA-256 不匹配。"
    }
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Sha256 = $actual
    }
}

function ConvertFrom-VMateHyperVHexUInt64 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $text = $Value.Trim()
    if ($text -notmatch '^0[xX][0-9A-Fa-f]{1,16}$') {
        throw "$Label 不是有效的非零 UInt64 十六进制值：$Value"
    }
    $number = [Convert]::ToUInt64($text.Substring(2), 16)
    if ($number -eq 0) { throw "$Label 不能为零。" }
    return $number
}

function Get-VMateHyperVWorkerProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $vmId = ([Guid]$VM.Id).ToString('D')
    $expectedPath = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\vmwp.exe'))
    $rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
        Where-Object {
            [string]$_.Name -ieq 'vmwp.exe' -and
            -not [String]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
            [IO.Path]::GetFullPath([string]$_.ExecutablePath) -ieq
                $expectedPath -and
            [string]$_.CommandLine -match [regex]::Escape($vmId)
        })
    if ($rows.Count -ne 1) {
        throw "VM $($VM.Name) 的 inbox vmwp.exe 必须恰好一个，实际 $($rows.Count)。"
    }
    return $rows[0]
}

function Invoke-VMateHyperVPartitionCandidateProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)][int]$TargetProcessId,
        [Parameter(Mandatory = $true)][string]$ProbePath,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedProbeSha256
    )

    $probe = Assert-VMateHyperVCpuidColdStartFile -Path $ProbePath `
        -ExpectedSha256 $ExpectedProbeSha256 `
        -Description 'VMate VID partition candidate probe'
    $output = @(& $probe.Path '--pid' ([string]$TargetProcessId) `
            '--list-access-denied' 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $document = $null
    try {
        $document = ($output -join '') | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw ('VID candidate probe 没有返回有效 JSON：' +
            ($output -join ' '))
    }
    $reportedPid = [int](Get-VMateHyperVCpuidColdStartProperty `
        $document 'targetPid' 0)
    $enumeration = [bool](Get-VMateHyperVCpuidColdStartProperty `
        $document 'accessDeniedEnumerationRequested' $false)
    $truncated = [bool](Get-VMateHyperVCpuidColdStartProperty `
        $document 'accessDeniedCandidateListTruncated' $true)
    $candidates = @(Get-VMateHyperVCpuidColdStartProperty `
        $document 'accessDeniedCandidateHandles' @())
    $reportedCount = [int](Get-VMateHyperVCpuidColdStartProperty `
        $document 'accessDeniedCandidateCount' -1)
    if ($reportedPid -ne $TargetProcessId -or -not $enumeration -or
        $truncated -or $reportedCount -ne 1 -or $candidates.Count -ne 1) {
        throw ('VID candidate probe 必须返回一个未截断、属于目标 vmwp 的' +
            '受保护 handle。')
    }
    $handle = ConvertFrom-VMateHyperVHexUInt64 `
        -Value ([string]$candidates[0]) -Label 'VID partition handle'
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        TargetProcessId = $TargetProcessId
        PartitionHandle = $handle
        PartitionHandleHex = '0x{0:X}' -f $handle
        ProbeExitCode = $exitCode
        Probe = $probe
        Evidence = $document
    }
}

function Wait-VMateHyperVState {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$State,
        [ValidateRange(1, 120)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ([string]$vm.State -ceq $State) { return $vm }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VM $VMName 未在 $TimeoutSeconds 秒内进入 $State；当前 $($vm.State)。"
}

function Wait-VMateHyperVGuestHeartbeat {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [ValidateRange(5, 300)][int]$TimeoutSeconds
    )

    $heartbeatId = '84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ([string]$vm.State -cne 'Running') {
            throw "等待 guest 心跳时 VM 不再 Running；当前 $($vm.State)。"
        }
        $heartbeat = @(Get-VMIntegrationService -VM $vm `
                -ErrorAction Stop | Where-Object {
                    [string]$_.Id -match $heartbeatId
                })
        if ($heartbeat.Count -ne 1) {
            throw "VM $VMName 的 Heartbeat 集成服务数量异常：$($heartbeat.Count)。"
        }
        $description = [string]$heartbeat[0].PrimaryStatusDescription
        if ([bool]$heartbeat[0].Enabled -and
            -not [String]::IsNullOrWhiteSpace($description) -and
            $description -notmatch '(?i)^no\s*contact$|^无连接$') {
            return [pscustomobject][ordered]@{
                IntegrationServiceId = [string]$heartbeat[0].Id
                PrimaryStatusDescription = $description
                ReadyAtUtc = [DateTime]::UtcNow.ToString('o')
                UptimeSeconds = [double]$vm.Uptime.TotalSeconds
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VM $VMName 未在 $TimeoutSeconds 秒内建立 guest Heartbeat。"
}

function Start-VMateHyperVEnabledTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    # Synchronous Start-VM can return only after the guest has cached its
    # processor brand.  -AsJob returns as soon as the transition is submitted,
    # so the coordinator can pause on the first observable Running state.
    return Start-VM -VM $VM -AsJob -ErrorAction Stop
}

function Start-VMateHyperVCpuidBrandColdBoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][string]$GpuInstancePath,
        [Parameter(Mandatory = $true)][string]$BrandString,
        [Parameter(Mandatory = $true)][string]$PartitionProbePath,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedPartitionProbeSha256,
        [Parameter(Mandatory = $true)][string]$VidContextRunnerPath,
        [Parameter(Mandatory = $true)][string]$VidContextDriverPath,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedVidContextDriverSha256,
        [Parameter(Mandatory = $true)][string]$CpuidRunnerPath,
        [Parameter(Mandatory = $true)][string]$CpuidDriverPath,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedCpuidDriverSha256,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedVmwpSha256,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedVidSha256,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string]$ExpectedVidSysSha256,
        [ValidateRange(1, 120)][int]$StartupTimeoutSeconds = 15,
        [ValidateRange(0.01, 30)][double]$MaxPausedUptimeSeconds = 0.25,
        [ValidateRange(5, 300)][int]$GuestReadyTimeoutSeconds = 90,
        [ValidateRange(0, 60)][int]$GuestStabilizationSeconds = 5,
        [switch]$DryRun
    )

    if ([string]$VM.State -cne 'Off') {
        throw "CPUID 品牌冷启动要求 VM 为 Off；当前 $($VM.State)。"
    }
    if ([int]$VM.Generation -ne 2) {
        throw 'CPUID 品牌冷启动只支持 Generation 2 VM。'
    }
    if ($BrandString.Length -lt 1 -or $BrandString.Length -gt 48 -or
        $BrandString -match '[^\x20-\x7e]') {
        throw 'BrandString 必须是 1..48 字节可打印 ASCII。'
    }
    $partitionProbe = Assert-VMateHyperVCpuidColdStartFile `
        -Path $PartitionProbePath `
        -ExpectedSha256 $ExpectedPartitionProbeSha256 `
        -Description 'VMate VID partition candidate probe'
    $vidRunner = Get-Item -LiteralPath ([IO.Path]::GetFullPath(
            $VidContextRunnerPath)) -ErrorAction Stop
    $cpuidRunner = Get-Item -LiteralPath ([IO.Path]::GetFullPath(
            $CpuidRunnerPath)) -ErrorAction Stop
    if ($vidRunner.PSIsContainer -or $vidRunner.Extension -ine '.ps1' -or
        $cpuidRunner.PSIsContainer -or $cpuidRunner.Extension -ine '.ps1') {
        throw 'VID/CPUID runner 必须是现有 .ps1 文件。'
    }
    $contractId = 'vmate-p11-cpuid-brand-cold-start-coordinator-v2'
    if ($DryRun) {
        $dryRunSnapshot = Get-VMateHyperVGpuPColdStartAdapterSnapshot `
            -VM $VM -GpuInstancePath $GpuInstancePath
        return [pscustomobject][ordered]@{
            SchemaVersion = 2
            ContractId = $contractId
            VMName = [string]$VM.Name
            VMId = ([Guid]$VM.Id).ToString('D')
            BrandString = $BrandString
            StateTransition = @(
                'OffWithGpuP', 'OffWithoutGpuP',
                'RunningWithoutGpuP', 'PausedForCpuidWithoutGpuP',
                'RunningGuestReadyWithoutGpuP',
                'PausedForGpuPAttach', 'PausedWithGpuP',
                'RunningWithGpuP')
            GpuPIsolation =
                'DetachedBeforeStartRestoredAfterGuestReadyPause'
            GuestReadyTimeoutSeconds = $GuestReadyTimeoutSeconds
            GuestStabilizationSeconds = $GuestStabilizationSeconds
            GpuPAdapter = $dryRunSnapshot
            RuntimeModelSwitch = $false
            FailurePolicy = 'turn-off-and-restore-gpup-before-returning'
            PartitionProbe = $partitionProbe
            VidContextRunnerPath = $vidRunner.FullName
            CpuidRunnerPath = $cpuidRunner.FullName
        }
    }

    $configurationLock = $null
    $adapterSnapshot = $null
    $transaction = $null
    $started = $false
    $resumed = $false
    $transactionCommitted = $false
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    $startJob = $null
    try {
        $configurationLock = Enter-VMateGpuPConfigurationLock
        [void](Repair-VMateHyperVGpuPColdStartTransaction -VM $VM)
        $current = Get-VM -Name ([string]$VM.Name) -ErrorAction Stop
        if ([string]$current.State -cne 'Off') {
            throw "GPU-P 隔离前要求 VM 为 Off；当前 $($current.State)。"
        }
        $adapterSnapshot = Get-VMateHyperVGpuPColdStartAdapterSnapshot `
            -VM $current -GpuInstancePath $GpuInstancePath
        $transaction = New-VMateHyperVGpuPColdStartTransaction `
            -VM $current -Snapshot $adapterSnapshot
        Remove-VMateHyperVGpuPColdStartAdapter `
            -VM $current -Snapshot $adapterSnapshot
        Set-VMateHyperVGpuPColdStartTransactionPhase `
            -Transaction $transaction -Phase 'AdapterDetachedWhileOff'

        $startJob = Start-VMateHyperVEnabledTransition -VM $current
        $started = $true
        $running = Wait-VMateHyperVState -VMName $current.Name `
            -State 'Running' -TimeoutSeconds $StartupTimeoutSeconds
        Suspend-VM -VM $running -Confirm:$false -ErrorAction Stop
        $paused = Wait-VMateHyperVState -VMName $current.Name `
            -State 'Paused' -TimeoutSeconds $StartupTimeoutSeconds
        $pausedUptime = [double]$paused.Uptime.TotalSeconds
        if ($pausedUptime -gt $MaxPausedUptimeSeconds) {
            throw ("冷启动暂停窗口已达 {0:N3} 秒，超过上限 {1} 秒。" -f
                $pausedUptime, $MaxPausedUptimeSeconds)
        }

        $worker = Get-VMateHyperVWorkerProcess -VM $paused
        $candidate = Invoke-VMateHyperVPartitionCandidateProbe `
            -TargetProcessId ([int]$worker.ProcessId) `
            -ProbePath $partitionProbe.Path `
            -ExpectedProbeSha256 $partitionProbe.Sha256
        $vidResult = & $vidRunner.FullName `
            -TargetProcessId ([int]$worker.ProcessId) `
            -PartitionHandle ([uint64]$candidate.PartitionHandle) `
            -DriverPath $VidContextDriverPath `
            -ExpectedDriverSha256 $ExpectedVidContextDriverSha256 `
            -ExpectedVmwpSha256 $ExpectedVmwpSha256 `
            -ExpectedVidSha256 $ExpectedVidSha256
        if ($null -eq $vidResult -or -not [bool]$vidResult.QuerySucceeded -or
            -not [bool]$vidResult.ImageMatched -or
            [uint64]$vidResult.PartitionId -eq 0) {
            throw '只读 VID worker-context 核验没有得到可信 partition ID。'
        }
        $apply = & $cpuidRunner.FullName `
            -VMName ([string]$paused.Name) -VMId ([Guid]$paused.Id) `
            -TargetProcessId ([int]$worker.ProcessId) `
            -PartitionHandle ([uint64]$candidate.PartitionHandle) `
            -ExpectedPartitionId ([uint64]$vidResult.PartitionId) `
            -BrandString $BrandString -DriverPath $CpuidDriverPath `
            -ExpectedDriverSha256 $ExpectedCpuidDriverSha256 `
            -ExpectedVmwpSha256 $ExpectedVmwpSha256 `
            -ExpectedVidSha256 $ExpectedVidSha256 `
            -ExpectedVidSysSha256 $ExpectedVidSysSha256 `
            -MaxPausedUptimeSeconds $MaxPausedUptimeSeconds
        if ($null -eq $apply -or -not [bool]$apply.Applied -or
            [bool]$apply.RuntimeModelSwitch -or
            [string]$apply.State -cne 'AppliedWhilePaused') {
            throw 'CPUID 品牌扩展没有返回完整的 paused cold-boot 成功证明。'
        }
        Resume-VM -VM $paused -Confirm:$false -ErrorAction Stop
        $runningWithoutGpu = Wait-VMateHyperVState -VMName $current.Name `
            -State 'Running' -TimeoutSeconds $StartupTimeoutSeconds
        $resumed = $true
        Set-VMateHyperVGpuPColdStartTransactionPhase `
            -Transaction $transaction `
            -Phase 'RunningWithoutAdapterWaitingForGuest'
        $guestReady = Wait-VMateHyperVGuestHeartbeat `
            -VMName $current.Name -TimeoutSeconds $GuestReadyTimeoutSeconds
        if ($GuestStabilizationSeconds -gt 0) {
            Start-Sleep -Seconds $GuestStabilizationSeconds
        }
        $readyVm = Get-VM -Name $current.Name -ErrorAction Stop
        if ([string]$readyVm.State -cne 'Running') {
            throw "GPU-P 延迟挂载前 VM 不再 Running；当前 $($readyVm.State)。"
        }
        Suspend-VM -VM $readyVm -Confirm:$false -ErrorAction Stop
        $gpuAttachPause = Wait-VMateHyperVState -VMName $current.Name `
            -State 'Paused' -TimeoutSeconds $StartupTimeoutSeconds
        [void](Add-VMateHyperVGpuPColdStartAdapter `
                -VM $gpuAttachPause -Snapshot $adapterSnapshot)
        Set-VMateHyperVGpuPColdStartTransactionPhase `
            -Transaction $transaction `
            -Phase 'AdapterRestoredAfterGuestReadyPause'
        Resume-VM -VM (Get-VM -Name $current.Name -ErrorAction Stop) `
            -Confirm:$false -ErrorAction Stop
        $live = Wait-VMateHyperVState -VMName $current.Name `
            -State 'Running' -TimeoutSeconds $StartupTimeoutSeconds
        Set-VMateHyperVGpuPColdStartTransactionPhase `
            -Transaction $transaction -Phase 'RunningWithAdapterRestored'
        $adapterCount = @(Get-VMGpuPartitionAdapter -VM $live `
                -ErrorAction Stop).Count
        if ($adapterCount -ne 1) {
            throw "GPU-P 冷启动完成后必须恰好一个 adapter；实际 $adapterCount。"
        }
        Remove-VMateHyperVGpuPColdStartTransaction ([Guid]$live.Id)
        $transactionCommitted = $true
        return [pscustomobject][ordered]@{
            SchemaVersion = 2
            ContractId = $contractId
            State = 'RunningAfterAppliedColdBoot'
            VMName = [string]$live.Name
            VMId = ([Guid]$live.Id).ToString('D')
            BrandString = $BrandString
            RuntimeModelSwitch = $false
            PausedUptimeSeconds = $pausedUptime
            TargetProcessId = [int]$worker.ProcessId
            PartitionHandleHex = [string]$candidate.PartitionHandleHex
            PartitionId = [uint64]$vidResult.PartitionId
            BootId = [string]$apply.ApplyNonce
            CandidateProbe = $candidate
            VidContext = $vidResult
            CpuidApply = $apply
            GpuPIsolation =
                'DetachedBeforeStartRestoredAfterGuestReadyPause'
            GuestReady = $guestReady
            GuestStabilizationSeconds = $GuestStabilizationSeconds
            GpuPAdapterCount = $adapterCount
            GpuPAdapter = $adapterSnapshot
            StartedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    catch {
        $failure = $_.Exception.Message
        if ($started -or $resumed) {
            try {
                $current = Get-VM -Name $VM.Name -ErrorAction Stop
                if ([string]$current.State -cne 'Off') {
                    Stop-VM -VM $current -TurnOff -Force -Confirm:$false `
                        -ErrorAction Stop
                    [void](Wait-VMateHyperVState -VMName $VM.Name `
                        -State 'Off' -TimeoutSeconds $StartupTimeoutSeconds)
                }
            }
            catch {
                [void]$cleanupFailures.Add(
                    "关闭 VM 失败：$($_.Exception.Message)")
            }
        }
        if ($null -ne $transaction -and
            $null -ne $adapterSnapshot -and
            -not $transactionCommitted) {
            try {
                $current = Get-VM -Name $VM.Name -ErrorAction Stop
                if ([string]$current.State -cne 'Off') {
                    throw "恢复 GPU-P adapter 要求 VM 为 Off；当前 $($current.State)。"
                }
                [void](Add-VMateHyperVGpuPColdStartAdapter `
                        -VM $current -Snapshot $adapterSnapshot)
                Remove-VMateHyperVGpuPColdStartTransaction ([Guid]$VM.Id)
                $transactionCommitted = $true
            }
            catch {
                [void]$cleanupFailures.Add(
                    "恢复 GPU-P adapter 失败：$($_.Exception.Message)")
            }
        }
        if ($cleanupFailures.Count -eq 0) {
            throw ('CPUID 品牌冷启动失败：' + $failure +
                '；本次 VM 已关闭，GPU-P adapter 已恢复。')
        }
        throw ('CPUID 品牌冷启动失败：' + $failure + '；自动回滚不完整：' +
            ($cleanupFailures -join '；'))
    }
    finally {
        if ($null -ne $startJob) {
            Remove-Job -Job $startJob -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $configurationLock) {
            Exit-VMateGpuPConfigurationLock -Mutex $configurationLock
        }
    }
}
