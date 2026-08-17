#requires -Version 5.1
<#
.SYNOPSIS
  Stage and validate the unmodified NVIDIA desktop 537.58 WHQL package in an
  isolated G-11 clone.

.DESCRIPTION
  Phase 1 runs only while the clone is still B/native DEV_1E30 with the known
  GRID 538.33 baseline. It verifies every packaged byte, adds nvddig.inf to
  DriverStore without /install, proves that the active display/INF did not
  change, installs a protected SYSTEM startup continuation, writes a receipt,
  and requests a full power-off.

  Phase 2 is the startup continuation. After the host presents the canonical
  tuple selected by the audited contract, it requires one Display, the exact
  PnP hardware ID, Code 0,
  31.0.15.3758, the exact original DriverStore INF/catalog and loaded
  nvlddmkm.sys, valid public production signatures, and normal BCD integrity
  flags. It writes a pass/fail receipt and requests another full power-off.

  This script never writes BCD, imports a certificate, modifies INF/CAT/SYS,
  deletes a driver, or asks pnputil to install/bind a device.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ContractPath,
    [string]$DriverRoot = '',
    [string]$ManifestPath = '',
    [switch]$Installed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$LockedInstallerBytes = [int64]675738080
$LockedInstallerSha256 =
    'D6345ABE590E151796ABC424D6661508735AB86CFF58FB644F23D270E89DCB93'
$LockedDriverKey = ''
$LockedGpuProfile = ''
$LockedInfName = ''
$LockedInfSha256 = ''
$LockedInfModelLine = ''
$LockedInfHardwareId = ''
$LockedCatalogName = 'nv_disp.cat'
$LockedCatalogSha256 =
    '08AD09F3B13E78D40B674914178B51090EABF99DF3FD1571C7DCBB367D8B430B'
$LockedKernelName = 'nvlddmkm.sys'
$LockedKernelSha256 =
    '19DBE8ED10DA6052EBFF22B70F51B710C8233ABB237BD544163025B1313EB5F2'
$LockedCatalogSignerThumbprint =
    'B878D8EB696CF3D4505E2F6641C57AF9062EC51A'
$LockedKernelSignerThumbprint =
    '01DF5BFEFA251B27AC1933E4E4CB61F21C44D57B'
$LockedDriverVersion = '31.0.15.3758'
$LockedBaselineDriverVersion = '31.0.15.3833'
$LockedBaselinePnpId = 'PCI\VEN_10DE&DEV_1E30'
$LockedTargetPnpId = ''
$LockedTargetName = ''
$TaskName = 'QemuNvidia53758IsolatedExperiment'
$StateRoot = Join-Path $env:ProgramData 'QemuNvidia53758Experiment'
$VersionsRoot = Join-Path $StateRoot 'versions'
$ReceiptsRoot = Join-Path $StateRoot 'receipts'
$SystemBcdEdit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
$SystemPnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$SystemPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$script:LoadedContract = $null
$script:EntryBcd = $null
$script:ContinuationInstalled = $false

if (-not ('QemuNvidia53758Shutdown' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class QemuNvidia53758Shutdown
{
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_NOT_ALL_ASSIGNED = 1300;
    private const uint SHUTDOWN_FORCE_OTHERS = 0x00000001;
    private const uint SHUTDOWN_FORCE_SELF = 0x00000002;
    private const uint SHUTDOWN_POWEROFF = 0x00000008;
    private const uint SHTDN_REASON_MAJOR_SOFTWARE = 0x00030000;
    private const uint SHTDN_REASON_MINOR_MAINTENANCE = 0x00000001;
    private const uint SHTDN_REASON_FLAG_PLANNED = 0x80000000;
    private const uint GRACE_SECONDS = 30;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID Luid;
        public uint Attributes;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern void SetLastError(uint error);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", EntryPoint = "LookupPrivilegeValueW",
        CharSet = CharSet.Unicode, ExactSpelling = true,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LookupPrivilegeValueW(
        string systemName, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr tokenHandle,
        [MarshalAs(UnmanagedType.Bool)] bool disableAllPrivileges,
        ref TOKEN_PRIVILEGES newState,
        uint bufferLength,
        IntPtr previousState,
        IntPtr returnLength);

    [DllImport("advapi32.dll", EntryPoint = "InitiateShutdownW",
        CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint InitiateShutdownW(
        string machineName,
        string message,
        uint gracePeriod,
        uint shutdownFlags,
        uint reason);

    private static void EnableShutdownPrivilege()
    {
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                out token)) {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "OpenProcessToken failed while enabling SeShutdownPrivilege.");
        }
        try {
            LUID luid;
            if (!LookupPrivilegeValueW(null, "SeShutdownPrivilege", out luid)) {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "LookupPrivilegeValueW failed for SeShutdownPrivilege.");
            }
            TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
            privileges.PrivilegeCount = 1;
            privileges.Luid = luid;
            privileges.Attributes = SE_PRIVILEGE_ENABLED;
            SetLastError(ERROR_SUCCESS);
            bool adjusted = AdjustTokenPrivileges(
                token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero);
            int status = Marshal.GetLastWin32Error();
            if (status == ERROR_NOT_ALL_ASSIGNED) {
                throw new Win32Exception(
                    ERROR_NOT_ALL_ASSIGNED,
                    "SeShutdownPrivilege is not assigned to this token.");
            }
            if (!adjusted || status != ERROR_SUCCESS) {
                throw new Win32Exception(
                    status,
                    "AdjustTokenPrivileges failed for SeShutdownPrivilege.");
            }
        } finally {
            CloseHandle(token);
        }
    }

    public static void SchedulePowerOff()
    {
        EnableShutdownPrivilege();
        uint flags = SHUTDOWN_FORCE_OTHERS | SHUTDOWN_FORCE_SELF |
            SHUTDOWN_POWEROFF;
        uint reason = SHTDN_REASON_MAJOR_SOFTWARE |
            SHTDN_REASON_MINOR_MAINTENANCE | SHTDN_REASON_FLAG_PLANNED;
        uint status = InitiateShutdownW(
            null,
            "QEMU isolated NVIDIA 537.58 experiment",
            GRACE_SECONDS,
            flags,
            reason);
        if (status != ERROR_SUCCESS) {
            throw new Win32Exception(
                (int)status,
                "InitiateShutdownW rejected the full power-off request.");
        }
    }
}
'@
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash($bytes)) -replace '-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run Run-Phase1.cmd as Administrator.'
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (@(Compare-Object $expected $actual).Count -ne 0) {
        throw "$Context has missing or unexpected fields."
    }
}

function Get-NormalBcdSnapshot {
    $output = (& $SystemBcdEdit /enum all 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read all BCD entries: $output"
    }
    foreach ($flag in @('testsigning', 'nointegritychecks')) {
        foreach ($line in @($output -split "`r?`n" |
                Where-Object { $_ -match "^\s*$flag\s+" })) {
            if ($line -notmatch '(?i)\b(no|off|false|0)\s*$') {
                throw "$flag is enabled or unknown. This experiment will not change BCD."
            }
        }
    }
    $normalized = (($output -replace "`r`n", "`n") -replace "`r", "`n")
    $normalized = $normalized.TrimEnd() + "`n"
    Write-Pass 'testsigning/nointegritychecks are off; read-only BCD snapshot captured.'
    return [pscustomobject]@{ Sha256 = Get-TextSha256 $normalized }
}

function Assert-BcdUnchanged {
    param([Parameter(Mandatory = $true)]$Before)
    $after = Get-NormalBcdSnapshot
    if ([string]$before.Sha256 -cne [string]$after.Sha256) {
        throw 'Normalized bcdedit /enum all output changed during this phase.'
    }
    return $after
}

function New-ProtectedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = New-Item -Path $Path -ItemType Directory -Force
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected path must be a real directory: $Path"
    }
    $administrators = New-Object Security.Principal.SecurityIdentifier `
        -ArgumentList 'S-1-5-32-544'
    $system = New-Object Security.Principal.SecurityIdentifier `
        -ArgumentList 'S-1-5-18'
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = (
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    )
    foreach ($sid in @($administrators, $system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule `
            -ArgumentList @(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inherit,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-RegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse file: $Path"
    }
    return $item
}

function Test-PnpPrefix {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    $actualUpper = $Actual.Trim().ToUpperInvariant()
    $expectedUpper = $Expected.Trim().ToUpperInvariant()
    return $actualUpper -eq $expectedUpper -or
        $actualUpper.StartsWith(
            $expectedUpper + '&', [StringComparison]::Ordinal) -or
        $actualUpper.StartsWith(
            $expectedUpper + '\', [StringComparison]::Ordinal)
}

function Select-LockedDriverRow {
    param([Parameter(Mandatory = $true)]$Contract)
    $key = [string]$Contract.driverKey
    switch -CaseSensitive ($key) {
        'nvidia-53758-dch-whql-gtx1050-dell' {
            $script:LockedDriverKey = $key
            $script:LockedGpuProfile = 'gtx1050_2gb'
            $script:LockedInfName = 'nvddig.inf'
            $script:LockedInfSha256 =
                'C2860E03D30F7BA610F9726765354E75CABB624791AECEA61478066D9EAD50F1'
            $script:LockedInfModelLine =
                '%NVIDIA_DEV.1C81.11C0.1028% = Section029, PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
            $script:LockedInfHardwareId =
                'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
            $script:LockedTargetPnpId =
                'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028'
            $script:LockedTargetName = 'NVIDIA GeForce GTX 1050'
        }
        'nvidia-53758-dch-whql-gtx750ti-asus' {
            $script:LockedDriverKey = $key
            $script:LockedGpuProfile = 'gtx750ti_asus_2gb'
            $script:LockedInfName = 'nv_dispig.inf'
            $script:LockedInfSha256 =
                '1B7B9F3A5A13A4FEC0074BCEA8A1DD64336CEF228041B1124B8E31D41CDED957'
            $script:LockedInfModelLine =
                '%NVIDIA_DEV.1380%           = Section010, PCI\VEN_10DE&DEV_1380'
            $script:LockedInfHardwareId = 'PCI\VEN_10DE&DEV_1380'
            $script:LockedTargetPnpId =
                'PCI\VEN_10DE&DEV_1380&SUBSYS_84BB1043'
            $script:LockedTargetName = 'NVIDIA GeForce GTX 750 Ti'
        }
        default {
            throw "The guest validator does not allow driver row $key."
        }
    }
    if ([string]$Contract.gpuProfile -cne $LockedGpuProfile -or
        [string]$Contract.targetPnpId -cne $LockedTargetPnpId -or
        [string]$Contract.targetGpuName -cne $LockedTargetName) {
        throw "Contract identity does not match locked driver row $LockedDriverKey."
    }
}

function Read-Contract {
    $item = Get-RegularFile $ContractPath 'experiment contract'
    try {
        $contract = Get-Content -LiteralPath $item.FullName -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Experiment contract is invalid JSON: $($_.Exception.Message)"
    }
    Assert-ExactProperties $contract @(
        'schemaVersion', 'experimentId', 'vmId', 'vmUuid',
        'sourceHostMode', 'gpuProfile', 'profileSha256', 'driverKey',
        'qualificationId', 'qualificationSha256', 'deploymentIntent',
        'baselinePnpId', 'targetPnpId', 'targetGpuName', 'driver', 'payload'
    ) 'contract'
    Assert-ExactProperties $contract.driver @(
        'installerName', 'installerBytes', 'installerSha256',
        'infName', 'infSha256', 'infModelLine', 'catalogName', 'catalogSha256',
        'catalogSignerThumbprint', 'kernelName', 'kernelSha256',
        'kernelSignerThumbprint', 'driverVersion', 'baselineDriverVersion'
    ) 'contract.driver'
    Assert-ExactProperties $contract.payload @(
        'manifestName', 'manifestSha256', 'fileCount', 'bytes'
    ) 'contract.payload'
    if ([int]$contract.schemaVersion -ne 2 -or
        [string]$contract.experimentId -cnotmatch '^[0-9A-F]{32}$' -or
        [int64]$contract.vmId -lt 1 -or
        [int64]$contract.vmId -gt 2147483647 -or
        [string]$contract.vmUuid -cnotmatch
            '^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$' -or
        [string]$contract.sourceHostMode -cne 'B' -or
        [string]$contract.baselinePnpId -cne $LockedBaselinePnpId -or
        [string]$contract.gpuProfile -cnotmatch '^[a-z0-9_]+$' -or
        [string]$contract.profileSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        [string]$contract.driverKey -cnotmatch '^[a-z0-9-]+$' -or
        [string]$contract.targetPnpId -cnotmatch
            '^PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}&SUBSYS_[0-9A-F]{8}$' -or
        [string]::IsNullOrWhiteSpace([string]$contract.targetGpuName) -or
        [string]$contract.deploymentIntent -notin @(
            'disposable-experiment', 'qualified-production-staging')) {
        throw 'Experiment contract identity fields are invalid.'
    }
    if ([string]$contract.deploymentIntent -ceq
            'qualified-production-staging') {
        if ([string]$contract.qualificationId -cnotmatch '^[0-9A-F]{64}$' -or
            [string]$contract.qualificationSha256 -cnotmatch
                '^[0-9A-F]{64}$') {
            throw 'Production staging requires one content-addressed qualification.'
        }
    } elseif ([string]$contract.qualificationId -cne '' -or
        [string]$contract.qualificationSha256 -cne '') {
        throw 'Disposable qualification staging may not claim a prior qualification.'
    }
    Select-LockedDriverRow $contract
    if ([string]$contract.driver.installerName -cne
            '537.58-desktop-win10-win11-64bit-international-dch-whql.exe' -or
        [int64]$contract.driver.installerBytes -ne $LockedInstallerBytes -or
        [string]$contract.driver.installerSha256 -cne
            $LockedInstallerSha256 -or
        [string]$contract.driver.infName -cne $LockedInfName -or
        [string]$contract.driver.infSha256 -cne $LockedInfSha256 -or
        [string]$contract.driver.infModelLine -cne $LockedInfModelLine -or
        [string]$contract.driver.catalogName -cne $LockedCatalogName -or
        [string]$contract.driver.catalogSha256 -cne $LockedCatalogSha256 -or
        [string]$contract.driver.catalogSignerThumbprint -cne
            $LockedCatalogSignerThumbprint -or
        [string]$contract.driver.kernelName -cne $LockedKernelName -or
        [string]$contract.driver.kernelSha256 -cne $LockedKernelSha256 -or
        [string]$contract.driver.kernelSignerThumbprint -cne
            $LockedKernelSignerThumbprint -or
        [string]$contract.driver.driverVersion -cne $LockedDriverVersion -or
        [string]$contract.driver.baselineDriverVersion -cne
            $LockedBaselineDriverVersion -or
        [string]$contract.payload.manifestName -cne
            'payload-manifest.sha256' -or
        [string]$contract.payload.manifestSha256 -cnotmatch
            '^[0-9A-F]{64}$' -or
        [int64]$contract.payload.fileCount -lt 1 -or
        [int64]$contract.payload.bytes -lt 1) {
        throw 'Contract does not select the locked original 537.58 payload.'
    }
    return $contract
}

function Assert-GuestUuid {
    param([Parameter(Mandatory = $true)]$Contract)
    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1 -or
        [Guid]$products[0].UUID -ne [Guid]$Contract.vmUuid) {
        throw "This package is not for vm$($Contract.vmId) UUID $($Contract.vmUuid)."
    }
    Write-Pass "guest UUID matches vm$($Contract.vmId)."
}

function Get-OneDisplay {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        throw 'Get-PnpDevice is required.'
    }
    $displays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    if ($displays.Count -ne 1) {
        throw "Exactly one present Display is required; found $($displays.Count)."
    }
    return $displays[0]
}

function Get-ControllerForDisplay {
    param([Parameter(Mandatory = $true)]$Display)
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object {
            [string]$_.PNPDeviceID -ieq [string]$Display.InstanceId
        })
    if ($controllers.Count -ne 1) {
        throw "Expected one video controller for $($Display.InstanceId); found $($controllers.Count)."
    }
    return $controllers[0]
}

function Get-ActiveSignedDriver {
    param([Parameter(Mandatory = $true)][string]$DeviceId)
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { [string]$_.DeviceID -ieq $DeviceId })
    if ($drivers.Count -ne 1 -or
        [string]$drivers[0].InfName -notmatch '^oem[0-9]+\.inf$') {
        throw 'The display does not have exactly one published PnP driver.'
    }
    return $drivers[0]
}

function Assert-CatalogSignature {
    param([Parameter(Mandatory = $true)][string]$CatalogPath)
    $signature = Get-AuthenticodeSignature -LiteralPath $CatalogPath
    $certificate = $signature.SignerCertificate
    $subject = if ($null -ne $certificate) {
        [string]$certificate.Subject
    } else { '' }
    $thumbprint = if ($null -ne $certificate) {
        ([string]$certificate.Thumbprint).ToUpperInvariant()
    } else { '' }
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $certificate -or
        $subject -ceq [string]$certificate.Issuer -or
        $subject -notmatch
            '\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)' -or
        $thumbprint -cne $LockedCatalogSignerThumbprint) {
        throw "Catalog is not the locked Microsoft WHCP production signature: $CatalogPath"
    }
    return [pscustomobject]@{
        Subject = $subject
        Issuer = [string]$certificate.Issuer
        Thumbprint = $thumbprint
    }
}

function Assert-KernelSignature {
    param([Parameter(Mandatory = $true)][string]$KernelPath)
    $signature = Get-AuthenticodeSignature -LiteralPath $KernelPath
    $certificate = $signature.SignerCertificate
    $subject = if ($null -ne $certificate) {
        [string]$certificate.Subject
    } else { '' }
    $thumbprint = if ($null -ne $certificate) {
        ([string]$certificate.Thumbprint).ToUpperInvariant()
    } else { '' }
    $isNvidiaEmbedded = (
        $subject -match '(?:\A|,\s*)CN=NVIDIA Corporation(?:,|$)' -and
        $thumbprint -ceq $LockedKernelSignerThumbprint
    )
    # Once the exact file is published into DriverStore, Windows may resolve
    # Get-AuthenticodeSignature through its associated WHCP catalog instead of
    # returning the PE's embedded NVIDIA signature.  Both paths are pinned:
    # the caller has already proved the SYS hash, and this alternative must be
    # the same locked Microsoft catalog signer accepted for nv_disp.cat.
    $isMicrosoftCatalog = (
        $subject -match
            '\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)' -and
        $thumbprint -ceq $LockedCatalogSignerThumbprint
    )
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $certificate -or
        $subject -ceq [string]$certificate.Issuer -or
        (-not $isNvidiaEmbedded -and -not $isMicrosoftCatalog)) {
        throw "Kernel image is not covered by the locked NVIDIA embedded or Microsoft WHCP production signature: $KernelPath"
    }
    if ($isNvidiaEmbedded) {
        $signaturePath = 'nvidia-embedded'
    } else {
        $signaturePath = 'microsoft-whcp-catalog'
    }
    return [pscustomobject]@{
        Subject = $subject
        Issuer = [string]$certificate.Issuer
        Thumbprint = $thumbprint
        SignaturePath = $signaturePath
    }
}

function Get-CatalogNameFromInf {
    param([Parameter(Mandatory = $true)][string]$InfPath)
    $matches = [regex]::Matches(
        [IO.File]::ReadAllText($InfPath),
        '(?im)^\s*CatalogFile(?:\.[A-Za-z0-9_.-]+)?\s*=\s*"?([^";\r\n]+?)"?\s*(?:;.*)?$'
    )
    $names = @($matches | ForEach-Object {
        [string]$_.Groups[1].Value.Trim()
    } | Sort-Object -Unique)
    if ($names.Count -ne 1 -or
        [IO.Path]::GetFileName($names[0]) -cne $names[0] -or
        [IO.Path]::GetExtension($names[0]) -ine '.cat') {
        throw "INF does not select exactly one local catalog: $InfPath"
    }
    return $names[0]
}

function Assert-PayloadManifest {
    param([Parameter(Mandatory = $true)]$Contract)
    if ([string]::IsNullOrWhiteSpace($DriverRoot) -or
        [string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw 'Phase 1 requires DriverRoot and ManifestPath.'
    }
    $rootItem = Get-Item -LiteralPath $DriverRoot -Force -ErrorAction Stop
    if ($rootItem -isnot [IO.DirectoryInfo] -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Display.Driver payload root must be a real, non-reparse directory.'
    }
    $manifestItem = Get-RegularFile $ManifestPath 'payload manifest'
    if ((Get-Sha256 $manifestItem.FullName) -cne
        [string]$Contract.payload.manifestSha256) {
        throw 'Payload manifest SHA-256 does not match the contract.'
    }

    $rootFull = [IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\')
    $actual = @{}
    $queue = New-Object 'Collections.Generic.Queue[IO.DirectoryInfo]'
    $queue.Enqueue($rootItem)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName `
                -Force -ErrorAction Stop)) {
            if (($child.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Payload contains a reparse point: $($child.FullName)"
            }
            if ($child -is [IO.DirectoryInfo]) {
                $queue.Enqueue($child)
                continue
            }
            if ($child -isnot [IO.FileInfo]) {
                throw "Payload contains an unsupported object: $($child.FullName)"
            }
            $full = [IO.Path]::GetFullPath($child.FullName)
            if (-not $full.StartsWith(
                    $rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Payload file escaped Display.Driver: $full"
            }
            $relative = $full.Substring($rootFull.Length + 1).Replace('\', '/')
            if ($actual.ContainsKey($relative.ToLowerInvariant())) {
                throw "Payload has a duplicate case-insensitive path: $relative"
            }
            $actual[$relative.ToLowerInvariant()] = [pscustomobject]@{
                Relative = $relative
                Item = $child
            }
        }
    }

    $seen = @{}
    [int64]$bytes = 0
    [int64]$count = 0
    foreach ($line in @(Get-Content -LiteralPath $manifestItem.FullName `
            -ErrorAction Stop)) {
        if ($line -cnotmatch '^([0-9A-F]{64})  (.+)$') {
            throw "Malformed payload manifest row: $line"
        }
        $expectedHash = [string]$Matches[1]
        $relative = ([string]$Matches[2]).Replace('\', '/')
        if ($relative.StartsWith('/') -or $relative.EndsWith('/') -or
            $relative.Contains(':') -or
            @($relative.Split('/') | Where-Object {
                $_ -eq '' -or $_ -eq '.' -or $_ -eq '..'
            }).Count -ne 0) {
            throw "Unsafe relative path in payload manifest: $relative"
        }
        $key = $relative.ToLowerInvariant()
        if ($seen.ContainsKey($key) -or -not $actual.ContainsKey($key)) {
            throw "Missing, duplicate, or mismatched payload path: $relative"
        }
        $entry = $actual[$key]
        if ([string]$entry.Relative -cne $relative -or
            (Get-Sha256 $entry.Item.FullName) -cne $expectedHash) {
            throw "Payload bytes changed: $relative"
        }
        $seen[$key] = $true
        $count += 1
        $bytes += [int64]$entry.Item.Length
    }
    if ($seen.Count -ne $actual.Count -or
        $count -ne [int64]$Contract.payload.fileCount -or
        $bytes -ne [int64]$Contract.payload.bytes) {
        throw 'Payload file count/byte count differs from the contract.'
    }

    $inf = Get-RegularFile (Join-Path $rootFull $LockedInfName) `
        'locked source INF'
    $catalog = Get-RegularFile (Join-Path $rootFull $LockedCatalogName) `
        'locked source catalog'
    $kernel = Get-RegularFile (Join-Path $rootFull $LockedKernelName) `
        'locked source kernel image'
    if ((Get-Sha256 $inf.FullName) -cne $LockedInfSha256 -or
        (Get-Sha256 $catalog.FullName) -cne $LockedCatalogSha256 -or
        (Get-Sha256 $kernel.FullName) -cne $LockedKernelSha256) {
        throw 'Locked source INF/CAT/SYS hashes changed.'
    }
    $infText = [IO.File]::ReadAllText($inf.FullName)
    $modelLines = @([IO.File]::ReadAllLines($inf.FullName) |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -ceq [string]$Contract.driver.infModelLine })
    if ($infText -notmatch
            '(?im)^\s*DriverVer\s*=\s*10/04/2023,\s*31\.0\.15\.3758\s*$' -or
        $infText -notmatch
            '(?im)^\s*CatalogFile\s*=\s*NV_DISP\.CAT\s*$' -or
        $modelLines.Count -ne 1 -or
        -not (Test-PnpPrefix ([string]$Contract.targetPnpId) `
            $LockedInfHardwareId)) {
        throw 'Source INF no longer contains the one audited model row selected by the contract.'
    }
    $sourceSigner = Assert-CatalogSignature $catalog.FullName
    $sourceKernelSigner = Assert-KernelSignature $kernel.FullName
    Write-Pass 'full payload manifest and locked original INF/CAT/SYS validated.'
    return [pscustomobject]@{
        InfPath = $inf.FullName
        CatalogPath = $catalog.FullName
        KernelPath = $kernel.FullName
        CatalogSigner = $sourceSigner
        KernelSigner = $sourceKernelSigner
    }
}

function Get-LockedDriverStorePackages {
    $packages = @()
    foreach ($driver in @(Get-WindowsDriver -Online -All -ErrorAction Stop)) {
        if ([string]$driver.Driver -notmatch '^oem[0-9]+\.inf$' -or
            [string]$driver.ProviderName -notmatch '\ANVIDIA(?: Corporation)?\z' -or
            [string]$driver.Version -cne $LockedDriverVersion) {
            continue
        }
        $infPath = [string]$driver.OriginalFileName
        if (-not (Test-Path -LiteralPath $infPath -PathType Leaf) -or
            (Get-Sha256 $infPath) -cne $LockedInfSha256) {
            continue
        }
        $catalogPath = Join-Path (Split-Path -Parent $infPath) `
            (Get-CatalogNameFromInf $infPath)
        if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf) -or
            (Get-Sha256 $catalogPath) -cne $LockedCatalogSha256) {
            continue
        }
        $kernelPath = Join-Path (Split-Path -Parent $infPath) $LockedKernelName
        if (-not (Test-Path -LiteralPath $kernelPath -PathType Leaf) -or
            (Get-Sha256 $kernelPath) -cne $LockedKernelSha256) {
            continue
        }
        $catalogSigner = Assert-CatalogSignature $catalogPath
        $kernelSigner = Assert-KernelSignature $kernelPath
        $packages += [pscustomobject]@{
            InfName = [string]$driver.Driver
            InfPath = $infPath
            CatalogPath = $catalogPath
            KernelPath = $kernelPath
            CatalogSigner = $catalogSigner
            KernelSigner = $kernelSigner
        }
    }
    return @($packages)
}

function Assert-BaselineState {
    $display = Get-OneDisplay
    if (-not (Test-PnpPrefix ([string]$display.InstanceId) `
            $LockedBaselinePnpId)) {
        throw "Phase 1 requires B/native $LockedBaselinePnpId; observed $($display.InstanceId)."
    }
    $controller = Get-ControllerForDisplay $display
    if ([int]$controller.ConfigManagerErrorCode -ne 0 -or
        [string]$controller.DriverVersion -cne
            $LockedBaselineDriverVersion) {
        throw 'Phase 1 requires the known Code-0 GRID 538.33 baseline.'
    }
    $active = Get-ActiveSignedDriver ([string]$display.InstanceId)
    if (-not [bool]$active.IsSigned -or
        [string]$active.DriverProviderName -notmatch
            '\ANVIDIA(?: Corporation)?\z' -or
        [string]$active.DriverVersion -cne $LockedBaselineDriverVersion) {
        throw 'Baseline display does not have one signed NVIDIA 538.33 package.'
    }
    return [pscustomobject]@{
        Display = $display
        Controller = $controller
        Active = $active
    }
}

function Install-Continuation {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)][string]$ContractHash
    )
    if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' `
            -ErrorAction SilentlyContinue)) {
        throw "Scheduled task $TaskName already exists; use a clean disposable clone."
    }
    New-ProtectedDirectory $StateRoot
    New-ProtectedDirectory $VersionsRoot
    New-ProtectedDirectory $ReceiptsRoot
    $versionRoot = Join-Path $VersionsRoot ([string]$Contract.experimentId)
    New-ProtectedDirectory $versionRoot
    $installedScript = Join-Path $versionRoot `
        'nvidia-53758-isolated-experiment.ps1'
    $installedContract = Join-Path $versionRoot 'experiment-contract.json'
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
    Copy-Item -LiteralPath $ContractPath -Destination $installedContract -Force
    if ((Get-Sha256 $installedScript) -cne (Get-Sha256 $PSCommandPath) -or
        (Get-Sha256 $installedContract) -cne $ContractHash) {
        throw 'Installed continuation assets failed post-copy verification.'
    }
    $arguments = '-NoLogo -NoProfile -NonInteractive ' +
        '-ExecutionPolicy Bypass -File "' + $installedScript + '" ' +
        '-ContractPath "' + $installedContract + '" -Installed'
    $action = New-ScheduledTaskAction -Execute $SystemPowerShell `
        -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM `
        -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(15)) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -ErrorAction Stop | Out-Null
    $script:ContinuationInstalled = $true
    Write-Pass 'protected SYSTEM startup validator installed.'
}

function Unregister-Continuation {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' `
            -Confirm:$false -ErrorAction Stop
    }
    if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' `
            -ErrorAction SilentlyContinue)) {
        throw "Scheduled task $TaskName remained registered."
    }
    $script:ContinuationInstalled = $false
}

function Write-JsonReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )
    New-ProtectedDirectory $ReceiptsRoot
    $target = Join-Path $ReceiptsRoot $Name
    $temporary = "$target.new.$([Guid]::NewGuid().ToString('N'))"
    $Value | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $target -Force
    return $target
}

function Invoke-StagingPhase {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)]$EntryBcd
    )
    $baselineBefore = Assert-BaselineState
    $payload = Assert-PayloadManifest $Contract
    $output = (& $SystemPnpUtil /add-driver $payload.InfPath 2>&1 |
        Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "DriverStore rejected the original 537.58 package: $output"
    }
    $baselineAfter = Assert-BaselineState
    if ([string]$baselineAfter.Display.InstanceId -ine
            [string]$baselineBefore.Display.InstanceId -or
        [string]$baselineAfter.Active.InfName -ine
            [string]$baselineBefore.Active.InfName) {
        throw 'Active B/native display or INF changed during add-only staging.'
    }
    $packages = @(Get-LockedDriverStorePackages)
    if ($packages.Count -ne 1) {
        throw "Expected one exact 537.58 DriverStore package; found $($packages.Count)."
    }
    $package = $packages[0]
    Install-Continuation $Contract (Get-Sha256 $ContractPath)
    $exitBcd = Assert-BcdUnchanged $EntryBcd
    $receipt = [ordered]@{
        schemaVersion = 1
        phase = 'staged'
        result = 'pass'
        experimentId = [string]$Contract.experimentId
        vmId = [int]$Contract.vmId
        vmUuid = ([Guid]$Contract.vmUuid).ToString().ToLowerInvariant()
        baselinePnpId = [string]$baselineAfter.Display.InstanceId
        baselineDriverVersion = [string]$baselineAfter.Controller.DriverVersion
        activeInfBefore = [string]$baselineBefore.Active.InfName
        activeInfAfter = [string]$baselineAfter.Active.InfName
        activeDriverChanged = $false
        targetPnpId = $LockedTargetPnpId
        targetDriverVersion = $LockedDriverVersion
        publishedInf = [string]$package.InfName
        driverStoreInfSha256 = Get-Sha256 $package.InfPath
        driverStoreCatalogSha256 = Get-Sha256 $package.CatalogPath
        driverStoreKernelSha256 = Get-Sha256 $package.KernelPath
        catalogSigner = [string]$package.CatalogSigner.Subject
        catalogSignerThumbprint = [string]$package.CatalogSigner.Thumbprint
        kernelSigner = [string]$package.KernelSigner.Subject
        kernelSignerThumbprint = [string]$package.KernelSigner.Thumbprint
        payloadManifestSha256 = [string]$Contract.payload.manifestSha256
        contractSha256 = Get-Sha256 $ContractPath
        scriptSha256 = Get-Sha256 $PSCommandPath
        testsigning = $false
        nointegritychecks = $false
        bcdBeforeSha256 = [string]$EntryBcd.Sha256
        bcdAfterSha256 = [string]$exitBcd.Sha256
        bcdChanged = $false
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $name = "vm$($Contract.vmId)-$($Contract.experimentId)-staged.json"
    $path = Write-JsonReceipt $name $receipt
    Write-Pass "add-only staged receipt committed: $path"
    Write-Host 'Windows will fully power off. Change PCI identity only after inspecting this receipt.' `
        -ForegroundColor Cyan
    [QemuNvidia53758Shutdown]::SchedulePowerOff()
}

function Resolve-LoadedKernelPath {
    $drivers = @(Get-CimInstance Win32_SystemDriver -Filter `
        "Name='nvlddmkm'" -ErrorAction Stop)
    if ($drivers.Count -ne 1 -or
        [string]$drivers[0].State -cne 'Running') {
        throw 'Expected one running nvlddmkm kernel service.'
    }
    $path = ([string]$drivers[0].PathName).Trim().Trim('"')
    if ($path.StartsWith('\??\', [StringComparison]::Ordinal)) {
        $path = $path.Substring(4)
    }
    if ($path.StartsWith(
            '\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $path = Join-Path $env:SystemRoot $path.Substring(12)
    }
    $item = Get-RegularFile $path 'loaded NVIDIA kernel image'
    if ($item.Name -ine $LockedKernelName) {
        throw "nvlddmkm service points to an unexpected image: $path"
    }
    $driverStorePrefix = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository')
    ).TrimEnd('\') + '\'
    $systemDriversPrefix = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\drivers')
    ).TrimEnd('\') + '\'
    if (-not $item.FullName.StartsWith(
            $driverStorePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        -not $item.FullName.StartsWith(
            $systemDriversPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Loaded NVIDIA image is outside approved Windows roots: $path"
    }
    return $item
}

function Wait-TargetDisplay {
    param([int]$Seconds = 300)
    $deadline = (Get-Date).AddSeconds($Seconds)
    $last = ''
    do {
        try {
            $display = Get-OneDisplay
            if (Test-PnpPrefix ([string]$display.InstanceId) `
                    $LockedBaselinePnpId) {
                return [pscustomobject]@{
                    Mode = 'baseline'
                    Display = $display
                }
            }
            if (-not (Test-PnpPrefix ([string]$display.InstanceId) `
                    $LockedTargetPnpId)) {
                throw "Unexpected Display identity: $($display.InstanceId)"
            }
            $controller = Get-ControllerForDisplay $display
            if ([int]$controller.ConfigManagerErrorCode -eq 0 -and
                [string]$controller.DriverVersion -cne $LockedDriverVersion) {
                $last = "target Code 0 has version $($controller.DriverVersion)"
            } elseif ([int]$controller.ConfigManagerErrorCode -eq 0) {
                return [pscustomobject]@{
                    Mode = 'target'
                    Display = $display
                    Controller = $controller
                }
            } else {
                $last = "target currently reports Code $($controller.ConfigManagerErrorCode)"
            }
        } catch {
            $last = $_.Exception.Message
        }
        if ((Get-Date) -ge $deadline) {
            throw "Target display did not reach Code 0 / 31.0.15.3758 within $Seconds seconds: $last"
        }
        Start-Sleep -Seconds 5
    } while ($true)
}

function Get-ValidatedTargetState {
    param(
        [Parameter(Mandatory = $true)]$Display,
        [Parameter(Mandatory = $true)]$Controller
    )
    $displays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    if ($displays.Count -ne 1 -or
        [string]$displays[0].InstanceId -ine [string]$Display.InstanceId) {
        throw 'Present Display set changed during target validation.'
    }
    if (-not (Test-PnpPrefix ([string]$Display.InstanceId) `
            $LockedTargetPnpId) -or
        [string]$Controller.PNPDeviceID -ine [string]$Display.InstanceId -or
        [int]$Controller.ConfigManagerErrorCode -ne 0 -or
        [string]$Controller.DriverVersion -cne $LockedDriverVersion -or
        [string]$Controller.Name -cne $LockedTargetName) {
        throw "Target is not the exact contract profile with Code 0 / $LockedDriverVersion."
    }
    $hardwareProperty = Get-PnpDeviceProperty `
        -InstanceId ([string]$Display.InstanceId) `
        -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
    $hardwareIds = @($hardwareProperty.Data | ForEach-Object {
        ([string]$_).Trim().ToUpperInvariant()
    } | Sort-Object -Unique)
    if ($hardwareIds -notcontains $LockedTargetPnpId) {
        throw "HardwareIds do not contain exact $LockedTargetPnpId."
    }
    $active = Get-ActiveSignedDriver ([string]$Display.InstanceId)
    if (-not [bool]$active.IsSigned -or
        [string]$active.DriverVersion -cne $LockedDriverVersion -or
        [string]$active.DriverProviderName -notmatch
            '\ANVIDIA(?: Corporation)?\z') {
        throw 'Target does not have one signed NVIDIA 537.58 PnP package.'
    }
    $packages = @(Get-LockedDriverStorePackages)
    if ($packages.Count -ne 1 -or
        [string]$active.InfName -ine [string]$packages[0].InfName) {
        throw 'Active target INF is not the unique locked 537.58 package.'
    }
    $kernelItem = Resolve-LoadedKernelPath
    if ((Get-Sha256 $kernelItem.FullName) -cne $LockedKernelSha256) {
        throw 'Loaded nvlddmkm.sys bytes differ from original desktop 537.58.'
    }
    $kernelVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo(
        $kernelItem.FullName)
    $kernelFileVersion = '{0}.{1}.{2}.{3}' -f
        $kernelVersion.FileMajorPart, $kernelVersion.FileMinorPart,
        $kernelVersion.FileBuildPart, $kernelVersion.FilePrivatePart
    if ($kernelFileVersion -cne $LockedDriverVersion -or
        [string]$kernelVersion.CompanyName -notmatch
            '\ANVIDIA(?: Corporation)?\z') {
        throw 'Loaded nvlddmkm.sys version/vendor metadata is not locked 537.58.'
    }
    $loadedKernelSigner = Assert-KernelSignature $kernelItem.FullName
    Write-Pass 'one exact target Display is Code 0 on original production-signed 537.58.'
    return [pscustomobject]@{
        Display = $Display
        Controller = $Controller
        Active = $active
        Package = $packages[0]
        HardwareIds = $hardwareIds
        LoadedKernelPath = $kernelItem.FullName
        LoadedKernelSigner = $loadedKernelSigner
    }
}

function Invoke-TargetValidationPhase {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)]$EntryBcd
    )
    $wait = Wait-TargetDisplay
    if ([string]$wait.Mode -ceq 'baseline') {
        Write-Host 'Still B/native DEV_1E30; no device or driver was changed. The validator will retry at the next boot.' `
            -ForegroundColor Yellow
        $null = Assert-BcdUnchanged $EntryBcd
        return
    }
    $state = Get-ValidatedTargetState $wait.Display $wait.Controller
    $exitBcd = Assert-BcdUnchanged $EntryBcd
    Unregister-Continuation
    $receipt = [ordered]@{
        schemaVersion = 1
        phase = 'validated'
        result = 'pass'
        experimentId = [string]$Contract.experimentId
        vmId = [int]$Contract.vmId
        vmUuid = ([Guid]$Contract.vmUuid).ToString().ToLowerInvariant()
        displayCount = 1
        gpuName = [string]$state.Controller.Name
        pnpDeviceId = [string]$state.Display.InstanceId
        exactHardwareId = $LockedTargetPnpId
        hardwareIds = $state.HardwareIds
        configManagerErrorCode = 0
        driverVersion = [string]$state.Controller.DriverVersion
        activeInf = [string]$state.Active.InfName
        activeInfSha256 = Get-Sha256 $state.Package.InfPath
        activeCatalogSha256 = Get-Sha256 $state.Package.CatalogPath
        activeCatalogSigner = [string]$state.Package.CatalogSigner.Subject
        activeCatalogSignerThumbprint =
            [string]$state.Package.CatalogSigner.Thumbprint
        driverStoreKernelSha256 = Get-Sha256 $state.Package.KernelPath
        loadedKernelPath = [string]$state.LoadedKernelPath
        loadedKernelSha256 = Get-Sha256 $state.LoadedKernelPath
        loadedKernelSigner = [string]$state.LoadedKernelSigner.Subject
        loadedKernelSignerThumbprint =
            [string]$state.LoadedKernelSigner.Thumbprint
        contractSha256 = Get-Sha256 $ContractPath
        scriptSha256 = Get-Sha256 $PSCommandPath
        testsigning = $false
        nointegritychecks = $false
        bcdBeforeSha256 = [string]$EntryBcd.Sha256
        bcdAfterSha256 = [string]$exitBcd.Sha256
        bcdChanged = $false
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $name = "vm$($Contract.vmId)-$($Contract.experimentId)-validated.json"
    $path = Write-JsonReceipt $name $receipt
    Write-Host ''
    Write-Host '[NVIDIA 537.58 isolated experiment] PASS' `
        -ForegroundColor Green
    Write-Host "  PnP:     $($receipt.pnpDeviceId)"
    Write-Host "  Driver:  $($receipt.driverVersion) / $($receipt.activeInf) / Code 0"
    Write-Host "  Receipt: $path"
    Write-Host '  BCD:     untouched; testsigning/nointegritychecks are off'
    [QemuNvidia53758Shutdown]::SchedulePowerOff()
}

function Write-InstalledFailureReceiptAndPowerOff {
    param([Parameter(Mandatory = $true)]$Failure)
    $taskRemoved = $false
    try {
        Unregister-Continuation
        $taskRemoved = $true
    } catch {}
    $contract = $script:LoadedContract
    $experimentId = if ($null -ne $contract) {
        [string]$contract.experimentId
    } else {
        'UNKNOWN'
    }
    $vmId = if ($null -ne $contract) { [int]$contract.vmId } else { 0 }
    $vmUuid = if ($null -ne $contract) {
        ([Guid]$contract.vmUuid).ToString().ToLowerInvariant()
    } else { '' }
    $displays = @()
    try {
        $displays = @(Get-PnpDevice -Class Display -PresentOnly `
            -ErrorAction Stop | ForEach-Object {
                [ordered]@{
                    instanceId = [string]$_.InstanceId
                    friendlyName = [string]$_.FriendlyName
                    status = [string]$_.Status
                }
            })
    } catch {}
    $receipt = [ordered]@{
        schemaVersion = 1
        phase = 'validated'
        result = 'fail'
        experimentId = $experimentId
        vmId = $vmId
        vmUuid = $vmUuid
        expectedPnpId = $LockedTargetPnpId
        expectedDriverVersion = $LockedDriverVersion
        displays = $displays
        error = ($Failure | Out-String).Trim()
        scheduledTaskRemoved = $taskRemoved
        testsigningExpected = $false
        nointegritychecksExpected = $false
        bcdEntrySha256 = if ($null -ne $script:EntryBcd) {
            [string]$script:EntryBcd.Sha256
        } else { '' }
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        $name = if ($vmId -gt 0 -and $experimentId -ne 'UNKNOWN') {
            "vm$vmId-$experimentId-failed.json"
        } else {
            "unknown-$([Guid]::NewGuid().ToString('N'))-failed.json"
        }
        $path = Write-JsonReceipt $name $receipt
        Write-Host "Failure receipt: $path" -ForegroundColor Yellow
    } catch {}
    try {
        [QemuNvidia53758Shutdown]::SchedulePowerOff()
    } catch {
        Write-Error "The experiment failed and automatic power-off also failed: $($_.Exception.Message)"
    }
}

function Invoke-Main {
    Assert-Administrator
    $script:LoadedContract = Read-Contract
    Assert-GuestUuid $script:LoadedContract
    $script:EntryBcd = Get-NormalBcdSnapshot
    if ($Installed) {
        Invoke-TargetValidationPhase $script:LoadedContract $script:EntryBcd
    } else {
        Invoke-StagingPhase $script:LoadedContract $script:EntryBcd
    }
}

try {
    Invoke-Main
    exit 0
} catch {
    $failure = $_
    if ($Installed) {
        Write-InstalledFailureReceiptAndPowerOff $failure
    } elseif ($script:ContinuationInstalled) {
        try { Unregister-Continuation } catch {}
    }
    try {
        New-ProtectedDirectory $StateRoot
        $failure | Out-String |
            Set-Content -LiteralPath (Join-Path $StateRoot 'last-error.txt') `
                -Encoding UTF8
    } catch {}
    Write-Error $failure
    exit 1
}
