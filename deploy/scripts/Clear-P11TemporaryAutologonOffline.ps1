[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string]$VhdPath = 'C:\VMateLab\P11-Lab\P11-Lab.vhdx',
    [string]$ResultPath = 'C:\VMateLab\P11-autologon-cleanup.json'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$result = [ordered]@{
    VMName                  = $VMName
    StartedAt               = (Get-Date).ToString('o')
    InitialState            = $null
    GracefulShutdown        = $false
    DefaultPasswordWasSet   = $false
    AutoAdminLogonWasSet    = $false
    AutoLogonCountWasSet    = $false
    TemporaryIdentityCleared = $false
    ConsoleTaskFilePresent  = $false
    ConsoleLogCopied        = $false
    CleanupSucceeded        = $false
    Restarted               = $false
    Error                   = $null
}

$mounted = $false
$hiveLoaded = $false
$driveRoot = $null
$hiveName = 'VMateP11OfflineSoftware'
$hiveRoot = "Registry::HKEY_LOCAL_MACHINE\$hiveName"

try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $result.InitialState = [string]$vm.State

    if ($vm.State -ne 'Off') {
        $computerSystem = Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName 'Msvm_ComputerSystem' |
            Where-Object ElementName -eq $VMName |
            Select-Object -First 1
        if (-not $computerSystem) {
            throw "Could not resolve the Hyper-V computer system for '$VMName'."
        }

        $shutdownResult = Invoke-CimMethod -InputObject $computerSystem -MethodName 'RequestStateChange' -Arguments @{ RequestedState = [uint16]4 }
        if ($shutdownResult.ReturnValue -notin 0, 4096) {
            throw "Hyper-V rejected the graceful shutdown request with code $($shutdownResult.ReturnValue)."
        }
        $deadline = (Get-Date).AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 500
            $vm = Get-VM -Name $VMName
        } while ($vm.State -ne 'Off' -and (Get-Date) -lt $deadline)

        if ($vm.State -ne 'Off') {
            throw "Guest did not complete a graceful shutdown within 90 seconds."
        }
        $result.GracefulShutdown = $true
    }

    Mount-VHD -Path $VhdPath -ErrorAction Stop | Out-Null
    $mounted = $true

    $disk = Get-DiskImage -ImagePath $VhdPath | Get-Disk
    foreach ($volume in ($disk | Get-Partition | Get-Volume | Where-Object DriveLetter)) {
        $candidate = "{0}:\" -f $volume.DriveLetter
        if (Test-Path (Join-Path $candidate 'Windows\System32\Config\SOFTWARE')) {
            $driveRoot = $candidate
            break
        }
    }
    if (-not $driveRoot) {
        throw 'Could not locate the Windows volume in the mounted VHD.'
    }

    $softwareHive = Join-Path $driveRoot 'Windows\System32\Config\SOFTWARE'
    & reg.exe load "HKLM\$hiveName" $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe load failed with exit code $LASTEXITCODE."
    }
    $hiveLoaded = $true

    $winlogon = Join-Path $hiveRoot 'Microsoft\Windows NT\CurrentVersion\Winlogon'
    $properties = Get-ItemProperty -LiteralPath $winlogon
    $result.DefaultPasswordWasSet = $null -ne $properties.PSObject.Properties['DefaultPassword']
    $result.AutoAdminLogonWasSet = [string]$properties.AutoAdminLogon -eq '1'
    $result.AutoLogonCountWasSet = $null -ne $properties.PSObject.Properties['AutoLogonCount']

    Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Type String -Value '0'
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue

    $updated = Get-ItemProperty -LiteralPath $winlogon
    if ([string]$updated.DefaultUserName -eq 'VMateLab') {
        Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultUserName' -ErrorAction SilentlyContinue
        $result.TemporaryIdentityCleared = $true
    }
    if ([string]$updated.DefaultDomainName -eq 'P11-LAB') {
        Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultDomainName' -ErrorAction SilentlyContinue
        $result.TemporaryIdentityCleared = $true
    }

    $taskFile = Join-Path $driveRoot 'Windows\System32\Tasks\VMate-P11-Console60Hz'
    $result.ConsoleTaskFilePresent = Test-Path -LiteralPath $taskFile

    $consoleLog = Join-Path $driveRoot 'ProgramData\VMate\P11Console\force-displayfreq.log'
    if (Test-Path -LiteralPath $consoleLog) {
        Copy-Item -LiteralPath $consoleLog -Destination 'C:\VMateLab\P11-console60hz.log' -Force
        $result.ConsoleLogCopied = $true
    }

    $remaining = Get-ItemProperty -LiteralPath $winlogon
    if ($null -ne $remaining.PSObject.Properties['DefaultPassword']) {
        throw 'DefaultPassword remained present after cleanup.'
    }
    if ([string]$remaining.AutoAdminLogon -eq '1') {
        throw 'AutoAdminLogon remained enabled after cleanup.'
    }

    $result.CleanupSucceeded = $true
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    if ($hiveLoaded) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$hiveName" | Out-Null
        if ($LASTEXITCODE -ne 0 -and -not $result.Error) {
            $result.Error = "reg.exe unload failed with exit code $LASTEXITCODE."
            $result.CleanupSucceeded = $false
        }
    }

    if ($mounted) {
        Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
    }

    try {
        if ((Get-VM -Name $VMName -ErrorAction Stop).State -eq 'Off') {
            Start-VM -Name $VMName -ErrorAction Stop | Out-Null
        }
        $result.Restarted = (Get-VM -Name $VMName).State -eq 'Running'
    }
    catch {
        if (-not $result.Error) {
            $result.Error = "Failed to restore VM state: $($_.Exception.Message)"
        }
    }

    $result.FinishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if (-not $result.CleanupSucceeded) {
    exit 1
}
