#Requires -Version 5.1

param([string]$OutputPath = 'C:\VMateLab\hyperv-integrity.json')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-VMateFileRecord {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Path = $Path
            Present = $false
        }
    }
    $item = Get-Item -LiteralPath $Path -Force
    $signatureError = ''
    $signature = try {
        Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        $signatureError = $_.Exception.Message
        $null
    }
    $hashError = ''
    $sha256 = try {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 `
            -ErrorAction Stop).Hash
    }
    catch {
        $hashError = $_.Exception.Message
        ''
    }
    $hardLinks = try { @(& fsutil.exe hardlink list $Path 2>&1) }
    catch { @($_.Exception.Message) }
    $versionInfo = try { $item.VersionInfo } catch { $null }
    return [pscustomobject][ordered]@{
        Path = $item.FullName
        Present = $true
        Length = [uint64]$item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        Sha256 = $sha256
        HashError = $hashError
        FileVersion = if ($null -eq $versionInfo) { '' } else {
            [string]$versionInfo.FileVersion
        }
        ProductVersion = if ($null -eq $versionInfo) { '' } else {
            [string]$versionInfo.ProductVersion
        }
        SignatureStatus = if ($null -eq $signature) { '' } else {
            [string]$signature.Status
        }
        SignatureError = $signatureError
        Signer = if ($null -eq $signature -or
            $null -eq $signature.SignerCertificate) { '' } else {
            [string]$signature.SignerCertificate.Subject
        }
        HardLinks = $hardLinks
    }
}

function Resolve-VMateDriverPath {
    param([AllowNull()][string]$Value)

    if ([String]::IsNullOrWhiteSpace($Value)) { return '' }
    $path = $Value.Trim()
    if ($path.StartsWith('"')) {
        $end = $path.IndexOf('"', 1)
        if ($end -gt 1) { $path = $path.Substring(1, $end - 1) }
    }
    else {
        $match = [regex]::Match($path, '^(.*?\.(?:sys|exe|dll))(?=\s|$)',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) { $path = $match.Groups[1].Value }
    }
    $path = [regex]::Replace($path, '^(?i)\\SystemRoot', $env:SystemRoot)
    $path = [regex]::Replace($path, '^(?i)System32',
        (Join-Path $env:SystemRoot 'System32'))
    if (-not [IO.Path]::IsPathRooted($path)) { return '' }
    return [IO.Path]::GetFullPath($path)
}

$relativeFiles = @(
    'System32\vmwp.exe',
    'System32\vmms.exe',
    'System32\vmcompute.exe',
    'System32\vmchipset.dll',
    'System32\vmbusvdev.dll',
    'System32\vmdevicehost.dll',
    'System32\vmrdvcore.dll',
    'System32\vmrdv.dll',
    'System32\vid.dll',
    'System32\WinHvPlatform.dll',
    'System32\hvloader.dll',
    'System32\hvix64.exe',
    'System32\hvax64.exe',
    'System32\drivers\winhv.sys',
    'System32\drivers\vmbus.sys',
    'System32\drivers\vmswitch.sys',
    'System32\drivers\vid.sys',
    'System32\drivers\storvsp.sys',
    'System32\drivers\netvsp.sys',
    'System32\drivers\vmgid.sys',
    'System32\drivers\vms3cap.sys',
    'System32\Boot\winload.efi',
    'System32\winload.efi'
)
$fileRecords = foreach ($relative in $relativeFiles) {
    Get-VMateFileRecord (Join-Path $env:SystemRoot $relative)
}

$verification = foreach ($record in @($fileRecords | Where-Object Present)) {
    if ([string]$record.Path -notmatch '(?i)\\(vmwp\.exe|vmms\.exe|vmchipset\.dll|vmbusvdev\.dll|winhv\.sys|hvix64\.exe|winload\.efi)$') {
        continue
    }
    $output = try { @(& sfc.exe "/verifyfile=$($record.Path)" 2>&1) }
    catch { @($_.Exception.Message) }
    [pscustomobject][ordered]@{
        Path = [string]$record.Path
        ExitCode = [int]$LASTEXITCODE
        Output = $output
    }
}

$loadedModules = [Collections.Generic.List[object]]::new()
foreach ($process in @(Get-Process vmwp -ErrorAction SilentlyContinue)) {
    foreach ($module in @($process.Modules)) {
        if ([string]$module.ModuleName -notmatch '(?i)(vm|hv|vid|vmbus|dxg)') {
            continue
        }
        [void]$loadedModules.Add([pscustomobject][ordered]@{
                ProcessId = [int]$process.Id
                ModuleName = [string]$module.ModuleName
                FileName = [string]$module.FileName
                BaseAddress = ('0x{0:X}' -f [uint64]$module.BaseAddress.ToInt64())
                ModuleMemorySize = [uint64]$module.ModuleMemorySize
                FileVersion = [string]$module.FileVersionInfo.FileVersion
            })
    }
}

$drivers = [Collections.Generic.List[object]]::new()
foreach ($driver in @(Get-CimInstance Win32_SystemDriver | Where-Object {
            $_.State -eq 'Running'
        })) {
    $path = Resolve-VMateDriverPath ([string]$driver.PathName)
    $signature = if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        Get-AuthenticodeSignature -LiteralPath $path
    } else { $null }
    $signer = if ($null -eq $signature -or
        $null -eq $signature.SignerCertificate) { '' } else {
        [string]$signature.SignerCertificate.Subject
    }
    if ($signer -match '(?i)Microsoft Windows|Microsoft Corporation' -and
        [string]$driver.Name -notmatch '(?i)winring|vbox|usbip|vmspoofer') {
        continue
    }
    [void]$drivers.Add([pscustomobject][ordered]@{
            Name = [string]$driver.Name
            DisplayName = [string]$driver.DisplayName
            State = [string]$driver.State
            StartMode = [string]$driver.StartMode
            PathName = [string]$driver.PathName
            ResolvedPath = $path
            SignatureStatus = if ($null -eq $signature) { '' } else {
                [string]$signature.Status
            }
            Signer = $signer
        })
}

$vmConfigurationFiles = @()
$vmRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Hyper-V'
if (Test-Path -LiteralPath $vmRoot -PathType Container) {
    $vmConfigurationFiles = @(Get-ChildItem -LiteralPath $vmRoot -Recurse -Force `
            -ErrorAction SilentlyContinue | Where-Object {
                -not $_.PSIsContainer -and $_.Extension -in @('.vmcx', '.vmrs')
            } | ForEach-Object { Get-VMateFileRecord $_.FullName })
}

[pscustomobject][ordered]@{
    SchemaVersion = 1
    CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    OperatingSystem = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object ProductName, DisplayVersion, CurrentBuild, UBR, BuildLabEx
    Files = @($fileRecords)
    SfcVerification = @($verification)
    LoadedVmwpModules = @($loadedModules)
    NonMicrosoftOrRelevantRunningDrivers = @($drivers)
    VmConfigurationFiles = $vmConfigurationFiles
    BootConfiguration = @(& bcdedit.exe /enum all 2>&1)
} | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

[pscustomobject][ordered]@{
    OutputPath = $OutputPath
    PresentFiles = @($fileRecords | Where-Object Present).Count
    SfcChecks = @($verification).Count
    LoadedModuleRows = @($loadedModules).Count
    DriverRows = @($drivers).Count
    VmConfigurationFiles = @($vmConfigurationFiles).Count
} | ConvertTo-Json -Compress
