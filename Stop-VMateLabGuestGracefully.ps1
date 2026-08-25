#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off) {
    [pscustomobject][ordered]@{
        VMName = $VMName
        Requested = $false
        FinalState = [string]$vm.State
    } | ConvertTo-Json -Compress
    return
}
if ($vm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
    throw "VM '$VMName' must be Running or Off; current state is $($vm.State)."
}

$vmId = [string]$vm.Id.Guid
$computerSystem = Get-CimInstance -Namespace 'root/virtualization/v2' `
    -ClassName Msvm_ComputerSystem `
    -Filter "Name = '$vmId'" | Select-Object -First 1
if ($null -eq $computerSystem) {
    throw "unable to resolve the Hyper-V computer system for '$VMName'."
}
$shutdown = Get-CimAssociatedInstance -InputObject $computerSystem `
    -ResultClassName Msvm_ShutdownComponent | Select-Object -First 1
if ($null -eq $shutdown) {
    throw "guest shutdown integration is unavailable for '$VMName'."
}
$result = Invoke-CimMethod -InputObject $shutdown `
    -MethodName InitiateShutdown `
    -Arguments @{ Force = $false; Reason = 'VMate offline profile inspection' }
if ([uint32]$result.ReturnValue -notin @(0, 4096)) {
    throw "guest shutdown request failed with code $($result.ReturnValue)."
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Milliseconds 500
    $vm = Get-VM -Name $VMName -ErrorAction Stop
} while ($vm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Off -and
    [DateTime]::UtcNow -lt $deadline)
if ($vm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Off) {
    throw "guest shutdown timed out; '$VMName' is still $($vm.State)."
}

[pscustomobject][ordered]@{
    VMName = $VMName
    Requested = $true
    ReturnValue = [uint32]$result.ReturnValue
    FinalState = [string]$vm.State
} | ConvertTo-Json -Compress
