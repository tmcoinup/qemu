#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateSet('Stage', 'Collect')]
    [string]$Mode = 'Stage',

    [string]$VMName = 'pc01',

    [string]$ToolPath = 'C:\VMateLab\VMateGuestBridgeAudit.exe',

    [string]$OutputPath = 'C:\VMateLab\sample-bridge-audit.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$serviceName = 'VMateBridgeAudit'
$hiveName = 'VMateSampleBridgeAuditSystem'
$expectedImagePath = '%SystemDrive%\VMateAudit\VMateGuestBridgeAudit.exe'
$result = [ordered]@{
    SchemaVersion = 1
    Mode = $Mode
    VMName = $VMName
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    VhdPath = ''
    ToolSha256 = ''
    GuestResult = $null
    ServiceRemoved = $false
    ToolRemoved = $false
    Error = $null
    ErrorType = $null
    ErrorLine = $null
    ErrorStack = $null
    FinishedAtUtc = $null
}
$mounted = $false
$hiveLoaded = $false
$stageCreatedService = $false
$stageCopiedTool = $false
$guestTool = $null
$guestOutput = $null
$servicePath = $null

try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ([string]$vm.State -cne 'Off') {
        throw "VM must be Off for offline bridge audit: $($vm.State)"
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object ControllerLocation -eq 0)
    if ($drives.Count -ne 1) {
        throw "Unable to resolve one system VHD for $VMName."
    }
    $vhdPath = [string]$drives[0].Path
    $result.VhdPath = $vhdPath
    $disk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $mounted = $true
    Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
    Set-Disk -Number $disk.DiskNumber -IsReadOnly $false -ErrorAction Stop

    $windowsRoots = @()
    foreach ($partition in @(Get-Partition -DiskNumber $disk.DiskNumber)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or [String]::IsNullOrWhiteSpace(
                [string]$volume.Path)) { continue }
        $candidate = if (-not [String]::IsNullOrWhiteSpace(
                [string]$volume.DriveLetter)) {
            ([string]$volume.DriveLetter) + ':\'
        }
        else {
            [string]$volume.Path
        }
        if (Test-Path -LiteralPath (Join-Path $candidate `
                    'Windows\System32\Config\SYSTEM') -PathType Leaf) {
            $windowsRoots += $candidate
        }
    }
    if ($windowsRoots.Count -ne 1) {
        throw "Unable to resolve one Windows volume: $($windowsRoots.Count)"
    }
    $windowsRoot = [string]$windowsRoots[0]
    $systemHive = Join-Path $windowsRoot 'Windows\System32\Config\SYSTEM'
    $guestDirectory = Join-Path $windowsRoot 'VMateAudit'
    $guestTool = Join-Path $guestDirectory 'VMateGuestBridgeAudit.exe'
    $guestOutput = Join-Path $guestDirectory 'bridge-audit.json'

    & reg.exe load "HKLM\$hiveName" $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'reg load SYSTEM failed.' }
    $hiveLoaded = $true
    $hiveRoot = "Registry::HKEY_LOCAL_MACHINE\$hiveName"
    $current = [int](Get-ItemPropertyValue -LiteralPath `
            (Join-Path $hiveRoot 'Select') -Name Current -ErrorAction Stop)
    $controlSet = 'ControlSet{0:D3}' -f $current
    $servicePath = Join-Path $hiveRoot `
        (Join-Path $controlSet "Services\$serviceName")

    if ($Mode -ceq 'Stage') {
        if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) {
            throw "Audit tool was not found: $ToolPath"
        }
        if (Test-Path -LiteralPath $servicePath) {
            throw "Refusing to overwrite existing guest service: $serviceName"
        }
        if ((Test-Path -LiteralPath $guestTool -PathType Leaf) -or
            (Test-Path -LiteralPath $guestOutput -PathType Leaf)) {
            throw 'Refusing to overwrite an existing guest audit artifact.'
        }
        [void](New-Item -ItemType Directory -Path $guestDirectory -Force)
        Copy-Item -LiteralPath $ToolPath -Destination $guestTool `
            -ErrorAction Stop
        $stageCopiedTool = $true
        $result.ToolSha256 = (Get-FileHash -LiteralPath $guestTool `
                -Algorithm SHA256).Hash

        [void](New-Item -Path $servicePath -Force -ErrorAction Stop)
        $stageCreatedService = $true
        New-ItemProperty -LiteralPath $servicePath -Name 'DisplayName' `
            -Value 'VMate one-time bridge audit' -PropertyType String `
            -Force | Out-Null
        New-ItemProperty -LiteralPath $servicePath -Name 'ImagePath' `
            -Value $expectedImagePath -PropertyType ExpandString `
            -Force | Out-Null
        New-ItemProperty -LiteralPath $servicePath -Name 'ObjectName' `
            -Value 'LocalSystem' -PropertyType String -Force | Out-Null
        foreach ($entry in @(
                @{ Name = 'ErrorControl'; Value = 1 },
                @{ Name = 'Start'; Value = 2 },
                @{ Name = 'Type'; Value = 16 }
            )) {
            New-ItemProperty -LiteralPath $servicePath -Name $entry.Name `
                -Value $entry.Value -PropertyType DWord -Force | Out-Null
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $servicePath -PathType Container)) {
            throw "Expected audit service is missing: $serviceName"
        }
        $imagePath = [string](Get-ItemPropertyValue -LiteralPath `
                $servicePath -Name ImagePath -ErrorAction Stop)
        $allowedImagePaths = @(
            $expectedImagePath,
            'C:\VMateAudit\VMateGuestBridgeAudit.exe'
        )
        if ($imagePath -cnotin $allowedImagePaths) {
            throw "Audit service ImagePath mismatch: $imagePath"
        }
        if (-not (Test-Path -LiteralPath $guestOutput -PathType Leaf)) {
            throw 'Guest bridge audit result is missing.'
        }
        $result.GuestResult = Get-Content -LiteralPath $guestOutput -Raw |
            ConvertFrom-Json -ErrorAction Stop
        if (Test-Path -LiteralPath $guestTool -PathType Leaf) {
            $result.ToolSha256 = (Get-FileHash -LiteralPath $guestTool `
                    -Algorithm SHA256).Hash
        }

        Remove-Item -LiteralPath $servicePath -Recurse -Force `
            -ErrorAction Stop
        $result.ServiceRemoved = $true
        if (Test-Path -LiteralPath $guestTool -PathType Leaf) {
            Remove-Item -LiteralPath $guestTool -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $guestOutput -PathType Leaf) {
            Remove-Item -LiteralPath $guestOutput -Force -ErrorAction Stop
        }
        if ((Test-Path -LiteralPath $guestDirectory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $guestDirectory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $guestDirectory -Force -ErrorAction Stop
        }
        $result.ToolRemoved = -not (Test-Path -LiteralPath $guestTool)
    }
}
catch {
    $result.Error = $_.Exception.Message
    $result.ErrorType = $_.Exception.GetType().FullName
    $result.ErrorLine = $_.InvocationInfo.ScriptLineNumber
    $result.ErrorStack = $_.ScriptStackTrace
    if ($Mode -ceq 'Stage') {
        if ($stageCreatedService -and $null -ne $servicePath) {
            Remove-Item -LiteralPath $servicePath -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
        if ($stageCopiedTool -and $null -ne $guestTool) {
            Remove-Item -LiteralPath $guestTool -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($hiveLoaded) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$hiveName" | Out-Null
        if ($LASTEXITCODE -ne 0 -and $null -eq $result.Error) {
            $result.Error = 'reg unload SYSTEM failed.'
        }
    }
    if ($mounted) {
        try { Dismount-VHD -Path $result.VhdPath -ErrorAction Stop }
        catch {
            if ($null -eq $result.Error) {
                $result.Error = "Dismount-VHD failed: $($_.Exception.Message)"
            }
        }
    }
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $directory = Split-Path -Parent $OutputPath
    if ($directory) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText(
        $OutputPath,
        ([pscustomobject]$result | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false))
    )
}

$output = [pscustomobject]$result
$output
if ($null -ne $output.Error) { exit 1 }
