#Requires -Version 5.1

<#
.SYNOPSIS
    事务化管理 Hyper-V KVP host metadata exchange。

.DESCRIPTION
    MinimalHostMetadata 模式通过官方 Hyper-V integration-service cmdlet 禁用
    Key-Value Pair Exchange，并在服务停止后清理 guest 中已经遗留的宿主名称
    Parameters 键。PowerShell Direct、Heartbeat、Shutdown、Enhanced Session 和
    GPU-P 服务不在修改范围内。每次变更前都写入可恢复 receipt。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VMateKvpComponentGuid =
    '2A34B1C2-FD73-4043-8A5B-DD2159BC743F'
$script:VMateMetadataExchangeContract =
    'vmate-hyperv-minimal-host-metadata-v1'

function Get-VMateHyperVKvpIntegrationService {
    param([Parameter(Mandatory = $true)][object]$VM)

    $pattern = '(?i)\\' + [Regex]::Escape(
        $script:VMateKvpComponentGuid) + '$'
    $services = @(Get-VMIntegrationService -VM $VM -ErrorAction Stop |
        Where-Object { [string]$_.Id -match $pattern })
    if ($services.Count -ne 1) {
        throw "Hyper-V KVP integration service 必须恰好一条，实际 $($services.Count)。"
    }
    return $services[0]
}

function Get-VMateHyperVMetadataExchangeHostSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VMName)

    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $service = Get-VMateHyperVKvpIntegrationService -VM $vm
    return [pscustomobject][ordered]@{
        VMName = [string]$vm.Name
        VMId = ([Guid]$vm.Id).ToString('D')
        VMState = [string]$vm.State
        IntegrationServiceName = [string]$service.Name
        IntegrationServiceId = [string]$service.Id
        IntegrationServiceEnabled = [bool]$service.Enabled
        PrimaryStatusDescription =
            [string]$service.PrimaryStatusDescription
        Mode = if ([bool]$service.Enabled) {
            'HostMetadataExchangeEnabled'
        } else { 'MinimalHostMetadata' }
    }
}

function Get-VMateHyperVMetadataExchangeGuestSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
    )

    return Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop -ScriptBlock {
        $path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\' +
            'Virtual Machine\Guest\Parameters'
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        $values = if ($null -eq $key) { @() } else {
            @($key.GetValueNames() | Sort-Object | ForEach-Object {
                $name = [string]$_
                $kind = [string]$key.GetValueKind($name)
                $raw = $key.GetValue($name, $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $value = switch ($kind) {
                    'Binary' { [Convert]::ToBase64String([byte[]]$raw) }
                    'MultiString' { @([string[]]$raw) }
                    'DWord' { [int]$raw }
                    'QWord' { [long]$raw }
                    default { [string]$raw }
                }
                [pscustomobject][ordered]@{
                    Name = $name
                    Kind = $kind
                    Value = $value
                }
            })
        }
        $service = Get-CimInstance Win32_Service `
            -Filter "Name='vmickvpexchange'" -ErrorAction Stop
        return [pscustomobject][ordered]@{
            ComputerName = $env:COMPUTERNAME
            ParametersPath = $path
            ParametersKeyExists = $null -ne $key
            Parameters = $values
            GuestServiceName = [string]$service.Name
            GuestServiceState = [string]$service.State
            GuestServiceStartMode = [string]$service.StartMode
            GuestServiceProcessId = [uint32]$service.ProcessId
        }
    }
}

function Remove-VMateHyperVGuestHostMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential
    )

    return Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop -ScriptBlock {
        $path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\' +
            'Virtual Machine\Guest\Parameters'
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force `
                -ErrorAction Stop
        }
        [pscustomobject][ordered]@{
            ParametersKeyExists = Test-Path -LiteralPath $path
            PowerShellDirectReady = $true
        }
    }
}

function Restore-VMateHyperVGuestHostMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    return Invoke-Command -VMName $VMName -Credential $GuestCredential `
        -ArgumentList $Snapshot -ErrorAction Stop -ScriptBlock {
        param($Before)
        $path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\' +
            'Virtual Machine\Guest\Parameters'
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force `
                -ErrorAction Stop
        }
        if ([bool]$Before.ParametersKeyExists) {
            $subkey = 'SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
            $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey(
                $subkey, $true)
            if ($null -eq $key) {
                throw '无法恢复 Hyper-V guest Parameters 注册表键。'
            }
            try {
                foreach ($entry in @($Before.Parameters)) {
                    $kind = [Enum]::Parse(
                        [Microsoft.Win32.RegistryValueKind],
                        [string]$entry.Kind)
                    $value = switch ([string]$entry.Kind) {
                        'Binary' {
                            [Convert]::FromBase64String([string]$entry.Value)
                        }
                        'MultiString' { [string[]]@($entry.Value) }
                        'DWord' { [int]$entry.Value }
                        'QWord' { [long]$entry.Value }
                        default { [string]$entry.Value }
                    }
                    $key.SetValue([string]$entry.Name, $value, $kind)
                }
            }
            finally { $key.Dispose() }
        }
        return [pscustomobject][ordered]@{
            ParametersKeyExists = Test-Path -LiteralPath $path
            PowerShellDirectReady = $true
        }
    }
}

function Write-VMateHyperVMetadataExchangeReceipt {
    param(
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $temporary = "$fullPath.$PID.tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Receipt | ConvertTo-Json -Depth 10),
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force `
            -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    return $fullPath
}

function Read-VMateHyperVMetadataExchangeReceipt {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "metadata exchange receipt 不存在：$fullPath"
    }
    try {
        $receipt = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 `
            -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "metadata exchange receipt 无效：$($_.Exception.Message)" }
    if ([int]$receipt.SchemaVersion -ne 1 -or
        [string]$receipt.ContractId -cne
            $script:VMateMetadataExchangeContract) {
        throw 'metadata exchange receipt schema/contract 不受支持。'
    }
    return $receipt
}

function Wait-VMateHyperVKvpGuestServiceState {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Running', 'Stopped')][string]$State,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $snapshot = Get-VMateHyperVMetadataExchangeGuestSnapshot `
            -VMName $VMName -GuestCredential $GuestCredential
        if ([string]$snapshot.GuestServiceState -ceq $State) {
            return $snapshot
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "vmickvpexchange 未在 $TimeoutSeconds 秒内进入 $State。"
}

function Set-VMateHyperVKvpHostEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $service = Get-VMateHyperVKvpIntegrationService -VM $vm
    if ([bool]$service.Enabled -ne $Enabled) {
        if ($Enabled) {
            Enable-VMIntegrationService -VMIntegrationService $service `
                -Confirm:$false -ErrorAction Stop
        }
        else {
            Disable-VMIntegrationService -VMIntegrationService $service `
                -Confirm:$false -ErrorAction Stop
        }
    }
    $after = Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
    if ([bool]$after.IntegrationServiceEnabled -ne $Enabled) {
        throw 'KVP integration service 写入后回读不一致。'
    }
    return $after
}

function Restore-VMateHyperVMetadataExchangeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [Parameter(Mandatory = $true)][object]$Before
    )

    [void](Set-VMateHyperVKvpHostEnabled -VMName $VMName `
            -Enabled ([bool]$Before.Host.IntegrationServiceEnabled))
    if ([bool]$Before.Host.IntegrationServiceEnabled) {
        [void](Wait-VMateHyperVKvpGuestServiceState -VMName $VMName `
                -GuestCredential $GuestCredential -State Running)
    }
    [void](Restore-VMateHyperVGuestHostMetadata -VMName $VMName `
            -GuestCredential $GuestCredential -Snapshot $Before.Guest)
}

function Disable-VMateHyperVMetadataExchange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [switch]$DryRun
    )

    $hostBefore = Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
    if ([string]$hostBefore.VMState -cne 'Running') {
        throw 'MinimalHostMetadata 配置要求 VM 为 Running，以便事务化备份 guest 键。'
    }
    $guestBefore = Get-VMateHyperVMetadataExchangeGuestSnapshot `
        -VMName $VMName -GuestCredential $GuestCredential
    $before = [pscustomobject][ordered]@{
        Host = $hostBefore
        Guest = $guestBefore
    }
    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ContractId = $script:VMateMetadataExchangeContract
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        VMName = [string]$hostBefore.VMName
        VMId = [string]$hostBefore.VMId
        Mode = 'MinimalHostMetadata'
        Status = if ($DryRun) { 'DryRun' } else { 'Prepared' }
        Before = $before
        CredentialPersisted = $false
        UnchangedServices = @(
            'vmicvmsession', 'vmicrdv', 'vmicheartbeat',
            'vmicshutdown', 'vmictimesync', 'vmicvss')
    }
    if ($DryRun) { return $receipt }

    $receiptFile = Write-VMateHyperVMetadataExchangeReceipt `
        -Receipt $receipt -Path $ReceiptPath
    try {
        [void](Set-VMateHyperVKvpHostEnabled -VMName $VMName -Enabled $false)
        [void](Wait-VMateHyperVKvpGuestServiceState -VMName $VMName `
                -GuestCredential $GuestCredential -State Stopped)
        [void](Remove-VMateHyperVGuestHostMetadata -VMName $VMName `
                -GuestCredential $GuestCredential)
        $hostAfter = Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
        $guestAfter = Get-VMateHyperVMetadataExchangeGuestSnapshot `
            -VMName $VMName -GuestCredential $GuestCredential
        if ([bool]$hostAfter.IntegrationServiceEnabled -or
            [bool]$guestAfter.ParametersKeyExists -or
            [string]$guestAfter.GuestServiceState -cne 'Stopped') {
            throw 'MinimalHostMetadata 写入后回读不一致。'
        }
        $receipt.Status = 'Applied'
        $receipt | Add-Member -NotePropertyName AppliedAtUtc `
            -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $receipt | Add-Member -NotePropertyName After `
            -NotePropertyValue ([pscustomobject][ordered]@{
                Host = $hostAfter; Guest = $guestAfter
            }) -Force
        [void](Write-VMateHyperVMetadataExchangeReceipt `
                -Receipt $receipt -Path $receiptFile)
    }
    catch {
        $primary = $_.Exception.Message
        try {
            Restore-VMateHyperVMetadataExchangeSnapshot -VMName $VMName `
                -GuestCredential $GuestCredential -Before $before
            $receipt.Status = 'RolledBack'
            [void](Write-VMateHyperVMetadataExchangeReceipt `
                    -Receipt $receipt -Path $receiptFile)
        }
        catch {
            throw "MinimalHostMetadata 失败：$primary；自动恢复失败：$($_.Exception.Message)"
        }
        throw "MinimalHostMetadata 失败：$primary；已自动恢复。"
    }
    return $receipt
}

function Restore-VMateHyperVMetadataExchange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][PSCredential]$GuestCredential,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    $receipt = Read-VMateHyperVMetadataExchangeReceipt -Path $ReceiptPath
    $hostSnapshot = Get-VMateHyperVMetadataExchangeHostSnapshot `
        -VMName $VMName
    if ([string]$hostSnapshot.VMState -cne 'Running') {
        throw 'metadata exchange 恢复要求 VM 为 Running。'
    }
    if ([string]$receipt.VMName -cne [string]$hostSnapshot.VMName -or
        [string]$receipt.VMId -cne [string]$hostSnapshot.VMId) {
        throw 'metadata exchange receipt 与目标 VM 不匹配。'
    }
    Restore-VMateHyperVMetadataExchangeSnapshot -VMName $VMName `
        -GuestCredential $GuestCredential -Before $receipt.Before
    $afterHost = Get-VMateHyperVMetadataExchangeHostSnapshot -VMName $VMName
    $afterGuest = Get-VMateHyperVMetadataExchangeGuestSnapshot `
        -VMName $VMName -GuestCredential $GuestCredential
    if ([bool]$afterHost.IntegrationServiceEnabled -ne
            [bool]$receipt.Before.Host.IntegrationServiceEnabled -or
        [bool]$afterGuest.ParametersKeyExists -ne
            [bool]$receipt.Before.Guest.ParametersKeyExists) {
        throw 'metadata exchange 恢复后回读不一致。'
    }
    $receipt.Status = 'Restored'
    $receipt | Add-Member -NotePropertyName RestoredAtUtc `
        -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $receipt | Add-Member -NotePropertyName Restored `
        -NotePropertyValue ([pscustomobject][ordered]@{
            Host = $afterHost; Guest = $afterGuest
        }) -Force
    [void](Write-VMateHyperVMetadataExchangeReceipt `
            -Receipt $receipt -Path $ReceiptPath)
    return $receipt
}
