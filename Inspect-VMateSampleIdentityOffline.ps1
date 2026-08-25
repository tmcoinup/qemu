[CmdletBinding()]
param(
    [string]$VMName = 'pc01',
    [string]$ResultPath = 'C:\VMateLab\sample-identity-offline-pc01.json'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$result = [ordered]@{
    VMName = $VMName
    StartedAt = (Get-Date).ToString('o')
    InitialState = $null
    GracefulShutdown = $false
    SystemInformation = $null
    HardwareConfig = @()
    OemInformation = $null
    IdentityServices = @()
    WmiRepository = @()
    WmiStringHits = @()
    Bcd = @()
    Restarted = $false
    ShutdownServiceRestored = $false
    Error = $null
}

$mounted = $false
$systemLoaded = $false
$softwareLoaded = $false
$wasRunning = $false
$shutdownService = $null
$shutdownInitiallyEnabled = $false
$vhdPath = $null
$systemHiveName = 'VMateSampleIdentitySystem'
$softwareHiveName = 'VMateSampleIdentitySoftware'

function ConvertTo-VMateRegistrySnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path
    $values = [ordered]@{}
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -like 'PS*') { continue }
        $value = $property.Value
        $values[$property.Name] = if ($value -is [byte[]]) {
            [pscustomobject]@{
                Type = 'ByteArray'; Length = $value.Length
                Sha256 = [BitConverter]::ToString(
                    [Security.Cryptography.SHA256]::Create().ComputeHash($value)
                ).Replace('-', '')
            }
        } else { $value }
    }
    return [pscustomobject][ordered]@{ Path = $Path; Values = $values }
}

try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $result.InitialState = [string]$vm.State
    $wasRunning = $vm.State -eq 'Running'
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object Path)
    if ($drives.Count -ne 1) { throw 'Expected exactly one guest VHD.' }
    $vhdPath = [string]$drives[0].Path

    $shutdownService = @(Get-VMIntegrationService -VM $vm |
        Where-Object {
            [string]$_.Id -match
                '(?i)9F8233AC-BE49-4C79-8EE3-E7E1985B2077$'
        } | Select-Object -First 1)
    if ($shutdownService.Count -ne 1) {
        throw 'Could not resolve shutdown integration service.'
    }
    $shutdownService = $shutdownService[0]
    $shutdownInitiallyEnabled = [bool]$shutdownService.Enabled
    if (-not $shutdownInitiallyEnabled) {
        Enable-VMIntegrationService -VM $vm -Name $shutdownService.Name
    }

    if ($vm.State -ne 'Off') {
        $computerSystem = Get-CimInstance -Namespace 'root/virtualization/v2' `
            -ClassName Msvm_ComputerSystem |
            Where-Object ElementName -eq $VMName | Select-Object -First 1
        $shutdown = Invoke-CimMethod -InputObject $computerSystem `
            -MethodName RequestStateChange `
            -Arguments @{ RequestedState = [uint16]4 }
        if ($shutdown.ReturnValue -notin 0, 4096) {
            throw "Graceful shutdown request returned $($shutdown.ReturnValue)."
        }
        $deadline = (Get-Date).AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 500
            $vm = Get-VM -Name $VMName
        } while ($vm.State -ne 'Off' -and (Get-Date) -lt $deadline)
        if ($vm.State -ne 'Off') {
            throw 'Guest did not shut down gracefully within 90 seconds.'
        }
        $result.GracefulShutdown = $true
    }

    Mount-VHD -Path $vhdPath -ReadOnly -ErrorAction Stop | Out-Null
    $mounted = $true
    $disk = Get-DiskImage -ImagePath $vhdPath | Get-Disk
    $windowsRoot = $null
    $efiRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or [String]::IsNullOrWhiteSpace(
                [string]$volume.Path)) { continue }
        $root = [string]$volume.Path
        if (Test-Path -LiteralPath (Join-Path $root 'Windows\System32')) {
            $windowsRoot = $root
        }
        if (Test-Path -LiteralPath (Join-Path $root 'EFI\Microsoft\Boot')) {
            $efiRoot = $root
        }
    }
    if (-not $windowsRoot -or -not $efiRoot) {
        throw 'Could not locate Windows and EFI volumes.'
    }

    $systemHive = Join-Path $windowsRoot 'Windows\System32\config\SYSTEM'
    $softwareHive = Join-Path $windowsRoot 'Windows\System32\config\SOFTWARE'
    & reg.exe load "HKLM\$systemHiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to load offline SYSTEM hive.' }
    $systemLoaded = $true
    & reg.exe load "HKLM\$softwareHiveName" $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to load offline SOFTWARE hive.' }
    $softwareLoaded = $true

    $systemRoot = "Registry::HKEY_LOCAL_MACHINE\$systemHiveName"
    $softwareRoot = "Registry::HKEY_LOCAL_MACHINE\$softwareHiveName"
    $result.SystemInformation = ConvertTo-VMateRegistrySnapshot `
        (Join-Path $systemRoot 'ControlSet001\Control\SystemInformation')
    $hardwareRoot = Join-Path $systemRoot 'HardwareConfig'
    if (Test-Path -LiteralPath $hardwareRoot) {
        $result.HardwareConfig = @(Get-ChildItem -LiteralPath $hardwareRoot |
            ForEach-Object {
                ConvertTo-VMateRegistrySnapshot $_.PSPath
            })
    }
    $result.OemInformation = ConvertTo-VMateRegistrySnapshot `
        (Join-Path $softwareRoot `
            'Microsoft\Windows\CurrentVersion\OEMInformation')

    $servicesRoot = Join-Path $systemRoot 'ControlSet001\Services'
    $result.IdentityServices = @(Get-ChildItem -LiteralPath $servicesRoot |
        ForEach-Object {
            $service = Get-ItemProperty -LiteralPath $_.PSPath
            $facts = @($_.PSChildName, [string]$service.DisplayName,
                [string]$service.ImagePath) -join '|'
            if ($facts -match
                '(?i)(spoof|guestctrl|voyager|winring|smbios|hwid|hyperhide|ets\.exe)') {
                [pscustomobject][ordered]@{
                    Name = $_.PSChildName
                    DisplayName = [string]$service.DisplayName
                    ImagePath = [string]$service.ImagePath
                    Start = $service.Start
                    Type = $service.Type
                }
            }
        } | Where-Object { $null -ne $_ })

    $repositoryRoot = Join-Path $windowsRoot 'Windows\System32\wbem\Repository'
    $repositoryFiles = if (Test-Path -LiteralPath $repositoryRoot) {
        @(Get-ChildItem -LiteralPath $repositoryRoot -File -Recurse)
    } else { @() }
    $result.WmiRepository = @($repositoryFiles | ForEach-Object {
        [pscustomobject][ordered]@{
            RelativePath = $_.FullName.Substring(
                $repositoryRoot.Length).TrimStart('\')
            Size = [uint64]$_.Length
            LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            Sha256 = [string](Get-FileHash -LiteralPath $_.FullName `
                -Algorithm SHA256).Hash
        }
    })
    $objectsData = $repositoryFiles | Where-Object Name -eq 'OBJECTS.DATA' |
        Select-Object -First 1
    if ($null -ne $objectsData -and $objectsData.Length -le 256MB) {
        $bytes = [IO.File]::ReadAllBytes($objectsData.FullName)
        $unicode = [Text.Encoding]::Unicode.GetString($bytes)
        $latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        foreach ($needle in @('Galaxy Microsystems', 'GALAX B760',
                '13th Gen Intel', 'i5-13600KF', 'Microsoft Corporation',
                'Virtual Machine', 'Default string')) {
            $result.WmiStringHits += [pscustomobject][ordered]@{
                Value = $needle
                Unicode = $unicode.IndexOf($needle,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0
                ByteString = $latin.IndexOf($needle,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        }
    }

    $bcdPath = Join-Path $efiRoot 'EFI\Microsoft\Boot\BCD'
    if (Test-Path -LiteralPath $bcdPath) {
        $result.Bcd = @(& bcdedit.exe /store $bcdPath /enum all 2>&1 |
            ForEach-Object { [string]$_ })
    }
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    if ($softwareLoaded) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$softwareHiveName" | Out-Null
    }
    if ($systemLoaded) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$systemHiveName" | Out-Null
    }
    if ($mounted) {
        Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    }
    if ($wasRunning) {
        try {
            if ((Get-VM -Name $VMName).State -eq 'Off') {
                Start-VM -Name $VMName -ErrorAction Stop | Out-Null
            }
            $result.Restarted = (Get-VM -Name $VMName).State -eq 'Running'
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to restart guest: $($_.Exception.Message)"
            }
        }
    }
    try {
        if ($null -ne $shutdownService -and -not $shutdownInitiallyEnabled) {
            Disable-VMIntegrationService -VMName $VMName `
                -Name $shutdownService.Name -ErrorAction Stop
        }
        $current = @(Get-VMIntegrationService -VMName $VMName |
            Where-Object {
                [string]$_.Id -match
                    '(?i)9F8233AC-BE49-4C79-8EE3-E7E1985B2077$'
            } | Select-Object -First 1)
        $result.ShutdownServiceRestored = $current.Count -eq 1 -and
            [bool]$current[0].Enabled -eq $shutdownInitiallyEnabled
    }
    catch {
        if (-not $result.Error) {
            $result.Error = "Failed to restore shutdown service: $($_.Exception.Message)"
        }
    }
    $result.FinishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 9 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if ($result.Error) { exit 1 }
