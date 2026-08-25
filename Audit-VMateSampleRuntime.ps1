param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$taskName = 'VMate-Sample-Audit-Launch'
$samplePath = 'C:\Users\panma\Desktop\VMSpoofer\VMSpoofer\VMSpoofer.exe'
$sampleDir = Split-Path -Parent $samplePath
$launchedForAudit = $false

try {
    $sample = Get-CimInstance Win32_Process -Filter "Name='VMSpoofer.exe'" |
        Where-Object { [int]$_.SessionId -ne 0 } |
        Select-Object -First 1
    if ($null -eq $sample) {
        $action = New-ScheduledTaskAction -Execute $samplePath `
            -WorkingDirectory $sampleDir
        $principal = New-ScheduledTaskPrincipal -UserId 'panma' `
            -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $launchedForAudit = $true
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $sample = Get-CimInstance Win32_Process -Filter "Name='VMSpoofer.exe'" |
                Where-Object { [int]$_.SessionId -ne 0 } |
                Select-Object -First 1
        } while ($null -eq $sample -and [DateTime]::UtcNow -lt $deadline)
    }

    $sampleProcesses = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and (
                $_.ExecutablePath.StartsWith($sampleDir,
                    [StringComparison]::OrdinalIgnoreCase) -or
                $_.Name -in @('VMSpoofer.exe', 'monitor.exe', 'GuestCtrl.exe')
            )
        } | Select-Object Name, ProcessId, ParentProcessId, SessionId,
            ExecutablePath, CommandLine)
    $samplePids = @($sampleProcesses | ForEach-Object { [int]$_.ProcessId })
    $connections = if ($samplePids.Count -eq 0) { @() } else {
        @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {
                $samplePids -contains [int]$_.OwningProcess
            } | Select-Object State, LocalAddress, LocalPort, RemoteAddress,
                RemotePort, OwningProcess)
    }
    $drivers = @(Get-CimInstance Win32_SystemDriver | Where-Object {
            $_.PathName -match '(?i)VMSpoofer|WinRing|VBoxUSB|\\ude\\|usbip|vhci'
        } | Select-Object Name, DisplayName, State, StartMode, PathName)
    $integration = foreach ($vmName in @('pc01', 'pc02')) {
        [pscustomobject][ordered]@{
            VMName = $vmName
            State = [string](Get-VM -Name $vmName -ErrorAction Stop).State
            Services = @(Get-VMIntegrationService -VMName $vmName |
                Select-Object Name, Enabled, PrimaryStatusDescription,
                    SecondaryStatusDescription)
        }
    }
    [pscustomobject][ordered]@{
        Status = if ($null -eq $sample) { 'Unavailable' } else { 'Ready' }
        LaunchedForAudit = $launchedForAudit
        Processes = $sampleProcesses
        Connections = $connections
        Drivers = $drivers
        Integration = @($integration)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath `
        -Encoding UTF8
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}
