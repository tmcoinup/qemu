#Requires -Version 5.1

<#
.SYNOPSIS
    事务化配置并严格回读 Hyper-V VMConnect 控制台分辨率。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-VMateHyperVConsoleProfile {
    [CmdletBinding()]
    param(
        [ValidateSet('Default', 'Maximum', 'Single')]
        [string]$ResolutionType = 'Default',
        [ValidateRange(640, 8192)][int]$HorizontalResolution = 1920,
        [ValidateRange(480, 8192)][int]$VerticalResolution = 1200
    )

    return [pscustomobject][ordered]@{
        ResolutionType = $ResolutionType
        HorizontalResolution = $HorizontalResolution
        VerticalResolution = $VerticalResolution
    }
}

function Get-VMateHyperVConsoleSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$VM)

    $rows = @(Get-VMVideo -VM $VM -ErrorAction Stop)
    if ($rows.Count -ne 1) {
        throw "Hyper-V VM [$($VM.Name)] 的 VMVideo 必须恰好一条，实际 $($rows.Count)。"
    }
    return [pscustomobject][ordered]@{
        ResolutionType = [string]$rows[0].ResolutionType
        HorizontalResolution = [int]$rows[0].HorizontalResolution
        VerticalResolution = [int]$rows[0].VerticalResolution
    }
}

function Test-VMateHyperVConsoleProfileMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Profile
    )

    return [string]$Snapshot.ResolutionType -ceq
            [string]$Profile.ResolutionType -and
        [int]$Snapshot.HorizontalResolution -eq
            [int]$Profile.HorizontalResolution -and
        [int]$Snapshot.VerticalResolution -eq
            [int]$Profile.VerticalResolution
}

function Set-VMateHyperVConsoleProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$VM,
        [Parameter(Mandatory = $true)][object]$Profile,
        [switch]$DryRun
    )

    if ([string]$VM.State -cne 'Off') {
        throw "VMConnect 控制台配置要求 VM 完全关机，当前状态：$($VM.State)"
    }
    $desired = New-VMateHyperVConsoleProfile `
        -ResolutionType ([string]$Profile.ResolutionType) `
        -HorizontalResolution ([int]$Profile.HorizontalResolution) `
        -VerticalResolution ([int]$Profile.VerticalResolution)
    $before = Get-VMateHyperVConsoleSnapshot -VM $VM
    $changeRequired = -not (Test-VMateHyperVConsoleProfileMatch $before $desired)
    if ($DryRun -or -not $changeRequired) {
        return [pscustomobject][ordered]@{
            Changed = $false; ChangeRequired = $changeRequired
            Before = $before; Applied = $before; Desired = $desired
        }
    }

    try {
        Set-VMVideo -VM $VM -ResolutionType $desired.ResolutionType `
            -HorizontalResolution $desired.HorizontalResolution `
            -VerticalResolution $desired.VerticalResolution -Confirm:$false `
            -ErrorAction Stop
        $applied = Get-VMateHyperVConsoleSnapshot -VM $VM
        if (-not (Test-VMateHyperVConsoleProfileMatch $applied $desired)) {
            throw 'VMConnect 控制台配置写入后回读不一致。'
        }
    }
    catch {
        $primary = $_.Exception.Message
        try {
            Set-VMVideo -VM $VM -ResolutionType $before.ResolutionType `
                -HorizontalResolution $before.HorizontalResolution `
                -VerticalResolution $before.VerticalResolution -Confirm:$false `
                -ErrorAction Stop
            $restored = Get-VMateHyperVConsoleSnapshot -VM $VM
            if (-not (Test-VMateHyperVConsoleProfileMatch $restored $before)) {
                throw '回滚后回读不一致。'
            }
        }
        catch {
            throw "VMConnect 控制台配置失败：$primary；回滚失败：$($_.Exception.Message)"
        }
        throw "VMConnect 控制台配置失败：$primary；已恢复原配置。"
    }
    return [pscustomobject][ordered]@{
        Changed = $true; ChangeRequired = $true
        Before = $before; Applied = $applied; Desired = $desired
    }
}
