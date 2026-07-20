#requires -Version 5.1
<#
.SYNOPSIS
  Migrate one legacy consumer-ID vGPU to the original GRID 538.33 package.

.DESCRIPTION
  First run (legacy A/consumer PCI identity):
    * reads, but never writes, every BCD entry;
    * verifies the exact locked original NVIDIA archive, INF and catalog;
    * validates the vendor catalog against the unmodified payload;
    * adds the original package to DriverStore without binding the active A
      device;
    * installs a SYSTEM startup continuation, writes a staged receipt and
      performs a full shutdown.

  After the host has verified that stopped-disk receipt and switched the VM to
  B/native DEV_1E30, the startup continuation forces that one device to the
  exact original INF.  It keeps the legacy package until a post-reboot proof
  confirms one Code-0 display, the exact original INF/CAT hashes and the
  NVIDIA/Microsoft public production chain.  Only then does it apply the
  app-local GPU-Z profile and remove clearly identified legacy self-signed
  packages/certificates.

  There is no BCD write operation, certificate import, INF modification,
  catalog generation, or catalog signing in this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ContractPath,
    [string]$DriverZip = '',
    [Parameter(Mandatory = $true)][string]$GpuZProfileExe,
    [switch]$Installed,
    [switch]$ShutdownWhenStaged
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$LockedArchiveSha256 =
    'A3D7AD8B8082D6AC6214565B4766B5190A819BC9B7574765B14897E0DB809690'
$LockedArchiveBytes = [int64]860703853
$LockedInfSha256 =
    '67A240E1D464CF97DABFEC1A7CECF000EAA9DDFD702F32BA2C8771F17905DC2B'
$LockedCatalogSha256 =
    '56B07BD93280BBDA761CB5C9A3A13262C3605320D7286953989E2A5B16D5EC6F'
$LockedCatalogSignerThumbprint =
    '1935420A805A0CEFEBECDBE59A391A69DB32EAB3'
$LockedDriverVersion = '31.0.15.3833'
$LockedGpuZName = 'GPU-Z.exe'
$LockedGpuZBytes = [int64]11642144
$LockedGpuZSha256 =
    '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29'
$LockedGpuZProductVersion = '2.70.0'
$TaskName = 'QemuVgpuProductionMigration'
$StateRoot = Join-Path $env:ProgramData 'QemuVgpuProductionMigration'
$VersionsRoot = Join-Path $StateRoot 'versions'
$ReceiptsRoot = Join-Path $StateRoot 'receipts'
$DiagnosticsRoot = Join-Path $StateRoot 'diagnostics'
$GpuZProfileStateRoot = Join-Path $env:ProgramData 'QemuGpuZProfile'
$GpuZApplicationsRoot = Join-Path $GpuZProfileStateRoot 'applications'
$GpuZProfileReceiptPath = Join-Path $GpuZProfileStateRoot 'last-result.json'
$SystemBcdEdit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
$SystemPnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$SystemPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not ([System.Management.Automation.PSTypeName]'QemuVgpuNewDev').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class QemuVgpuNewDev
{
    [DllImport("newdev.dll", CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateDriverForPlugAndPlayDevicesW(
        IntPtr hwndParent,
        string hardwareId,
        string fullInfPath,
        uint installFlags,
        out bool rebootRequired);

    public static bool ForceUpdate(
        string hardwareId, string fullInfPath)
    {
        const uint INSTALLFLAG_FORCE = 0x00000001;
        const uint INSTALLFLAG_NONINTERACTIVE = 0x00000004;
        bool rebootRequired;
        if (!UpdateDriverForPlugAndPlayDevicesW(
                IntPtr.Zero, hardwareId, fullInfPath,
                INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE,
                out rebootRequired)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return rebootRequired;
    }
}
'@
}

if (-not ([System.Management.Automation.PSTypeName]'QemuVgpuShutdown').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class QemuVgpuShutdown
{
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_NOT_ALL_ASSIGNED = 1300;

    private const uint SHUTDOWN_FORCE_OTHERS = 0x00000001;
    private const uint SHUTDOWN_FORCE_SELF = 0x00000002;
    private const uint SHUTDOWN_RESTART = 0x00000004;
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
            LUID shutdownLuid;
            if (!LookupPrivilegeValueW(
                    null, "SeShutdownPrivilege", out shutdownLuid)) {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "LookupPrivilegeValueW failed for SeShutdownPrivilege.");
            }
            TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
            privileges.PrivilegeCount = 1;
            privileges.Luid = shutdownLuid;
            privileges.Attributes = SE_PRIVILEGE_ENABLED;

            SetLastError(ERROR_SUCCESS);
            bool adjusted = AdjustTokenPrivileges(
                token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero);
            int adjustmentStatus = Marshal.GetLastWin32Error();
            if (adjustmentStatus == ERROR_NOT_ALL_ASSIGNED) {
                throw new Win32Exception(
                    ERROR_NOT_ALL_ASSIGNED,
                    "SeShutdownPrivilege is not assigned to this token.");
            }
            if (!adjusted || adjustmentStatus != ERROR_SUCCESS) {
                throw new Win32Exception(
                    adjustmentStatus,
                    "AdjustTokenPrivileges failed for SeShutdownPrivilege.");
            }
        } finally {
            CloseHandle(token);
        }
    }

    public static void Schedule(bool restart)
    {
        EnableShutdownPrivilege();
        uint flags = SHUTDOWN_FORCE_OTHERS | SHUTDOWN_FORCE_SELF |
            (restart ? SHUTDOWN_RESTART : SHUTDOWN_POWEROFF);
        uint reason = SHTDN_REASON_MAJOR_SOFTWARE |
            SHTDN_REASON_MINOR_MAINTENANCE | SHTDN_REASON_FLAG_PLANNED;
        uint shutdownStatus = InitiateShutdownW(
            null,
            "QEMU vGPU production-driver migration",
            GRACE_SECONDS,
            flags,
            reason);
        if (shutdownStatus != ERROR_SUCCESS) {
            throw new Win32Exception(
                (int)shutdownStatus,
                "InitiateShutdownW rejected the requested system transition.");
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

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the migration EXE as Administrator.'
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $algorithm.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest) -replace '-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function Get-NormalBcdSnapshot {
    $output = (& $SystemBcdEdit /enum all 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read all BCD entries: $output"
    }
    foreach ($flag in @('testsigning', 'nointegritychecks')) {
        $lines = @($output -split "`r?`n" |
            Where-Object { $_ -match "^\s*$flag\s+" })
        foreach ($line in $lines) {
            if ($line -notmatch '(?i)\b(no|off|false|0)\s*$') {
                throw "$flag is enabled or unknown. This tool will not change BCD."
            }
        }
    }
    $normalized = (($output -replace "`r`n", "`n") -replace "`r", "`n")
    $normalized = $normalized.TrimEnd() + "`n"
    Write-Pass 'testsigning/nointegritychecks are not enabled; read-only BCD snapshot captured.'
    return [pscustomobject]@{
        Sha256 = Get-TextSha256 $normalized
    }
}

function Assert-BcdUnchanged {
    param([Parameter(Mandatory = $true)]$Before)
    $after = Get-NormalBcdSnapshot
    if ([string]$Before.Sha256 -cne [string]$after.Sha256) {
        throw 'Normalized bcdedit /enum all output changed during this phase.'
    }
    return $after
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

function Test-JsonInteger {
    param($Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64])
}

function Get-RegularFileBelowRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith(
            $rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context is outside its required root: $pathFull"
    }

    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    if ($rootItem -isnot [IO.DirectoryInfo] -or
        ($rootItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context root must be a real, non-reparse directory: $rootFull"
    }
    $item = Get-Item -LiteralPath $pathFull -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular, non-reparse file: $pathFull"
    }

    $cursor = $item.Directory
    while ($null -ne $cursor) {
        $cursorFull = [IO.Path]::GetFullPath($cursor.FullName).TrimEnd('\')
        if ($cursor -isnot [IO.DirectoryInfo] -or
            ($cursor.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context has a reparse/non-directory ancestor: $cursorFull"
        }
        if ($cursorFull.Equals(
                $rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $item
        }
        if (-not $cursorFull.StartsWith(
                $rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $cursor.Parent
    }
    throw "$Context ancestry did not terminate at its required root."
}

function Remove-RegularFileIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return
    }
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context is not a safe regular file: $Path"
    }
    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
    $remaining = $null
    try {
        $remaining = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {}
    if ($null -ne $remaining) {
        throw "$Context remained after safe deletion: $Path"
    }
}

function Start-GpuZProfileReceiptWindow {
    $rootItem = $null
    try {
        $rootItem = Get-Item -LiteralPath $GpuZProfileStateRoot -Force `
            -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {}
    if ($null -ne $rootItem) {
        if ($rootItem -isnot [IO.DirectoryInfo] -or
            ($rootItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'GPU-Z profile state root is not a real directory.'
        }
    }
    Remove-RegularFileIfPresent $GpuZProfileReceiptPath `
        'stale nested GPU-Z receipt'
    return [DateTime]::UtcNow
}

function Get-NestedProcessDiagnosticTail {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $results = @()
    try {
        $results = @(Get-RegularFileBelowRoot `
            $Path $DiagnosticsRoot $Context)
    } catch [System.Management.Automation.ItemNotFoundException] {
        return ''
    }
    if ($results.Count -ne 1 -or $results[0] -isnot [IO.FileInfo]) {
        throw "$Context resolver returned an unexpected result shape."
    }
    $item = $results[0]
    $lines = @(Get-Content -LiteralPath $item.FullName -Tail 200 `
        -ErrorAction Stop)
    $text = ($lines -join [Environment]::NewLine).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }
    if ($lines.Count -ge 200) {
        return "[last 200 lines]$([Environment]::NewLine)$text"
    }
    return $text
}

function Invoke-NestedGpuZProfileVerifier {
    param([Parameter(Mandatory = $true)][IO.FileInfo]$GpuZItem)

    New-ProtectedDirectory $StateRoot
    New-ProtectedDirectory $DiagnosticsRoot
    $runId = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $DiagnosticsRoot `
        "gpuz-profile-$runId.stdout.log"
    $stderrPath = Join-Path $DiagnosticsRoot `
        "gpuz-profile-$runId.stderr.log"
    $process = $null
    try {
        $process = Start-Process -FilePath $GpuZItem.FullName `
            -ArgumentList '/no-launch' `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -Wait -PassThru -ErrorAction Stop
    } catch {
        $stdout = Get-NestedProcessDiagnosticTail $stdoutPath `
            'nested GPU-Z stdout log'
        $stderr = Get-NestedProcessDiagnosticTail $stderrPath `
            'nested GPU-Z stderr log'
        $detail = @(
            "GPU-Z profile final verifier could not be started or observed: $($_.Exception.Message)"
            "Protected stdout log: $stdoutPath"
            "Protected stderr log: $stderrPath"
        )
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $detail += "Nested stdout:$([Environment]::NewLine)$stdout"
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $detail += "Nested stderr:$([Environment]::NewLine)$stderr"
        }
        throw ($detail -join [Environment]::NewLine)
    }

    $stdout = Get-NestedProcessDiagnosticTail $stdoutPath `
        'nested GPU-Z stdout log'
    $stderr = Get-NestedProcessDiagnosticTail $stderrPath `
        'nested GPU-Z stderr log'
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Host "Nested GPU-Z stdout:"
        Write-Host $stdout
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-Host "Nested GPU-Z stderr:"
        Write-Host $stderr
    }
    if ($process.ExitCode -ne 0) {
        $detail = @(
            "GPU-Z profile final verifier failed: exit $($process.ExitCode)."
            "Protected stdout log: $stdoutPath"
            "Protected stderr log: $stderrPath"
        )
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $detail += "Nested stdout:$([Environment]::NewLine)$stdout"
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $detail += "Nested stderr:$([Environment]::NewLine)$stderr"
        }
        throw ($detail -join [Environment]::NewLine)
    }

    Remove-RegularFileIfPresent $stdoutPath `
        'successful nested GPU-Z stdout log'
    Remove-RegularFileIfPresent $stderrPath `
        'successful nested GPU-Z stderr log'
}

function Get-GpuZProfileProof {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)]$Display,
        [Parameter(Mandatory = $true)]$Controller,
        [Parameter(Mandatory = $true)][DateTime]$StartedUtc
    )
    $receiptItem = Get-RegularFileBelowRoot $GpuZProfileReceiptPath `
        $GpuZProfileStateRoot 'nested GPU-Z receipt'
    if ($receiptItem.LastWriteTimeUtc -lt $StartedUtc) {
        throw 'Nested GPU-Z receipt file predates this /no-launch run.'
    }
    $receiptSha256 = Get-Sha256 $receiptItem.FullName
    try {
        $receipt = Get-Content -LiteralPath $receiptItem.FullName -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Nested GPU-Z receipt is invalid JSON: $($_.Exception.Message)"
    }
    Assert-ExactProperties $receipt @(
        'completedUtc', 'vmId', 'vmUuid', 'gpuProfile', 'gpuName',
        'pnpDeviceId', 'driverVersion', 'displayCount', 'parentId',
        'gpuZExe', 'gpuZ', 'gpuZShortcut', 'shimSha256',
        'systemNvapiSha256', 'backup', 'probe', 'testsigning',
        'nointegritychecks', 'systemNvapiChanged'
    ) 'nested GPU-Z receipt'
    Assert-ExactProperties $receipt.gpuZ @(
        'path', 'name', 'bytes', 'sha256', 'productVersion',
        'fileVersion', 'companyName', 'signatureStatus',
        'signerSubject', 'signerIssuer', 'signerThumbprint'
    ) 'nested GPU-Z receipt.gpuZ'
    Assert-ExactProperties $receipt.gpuZShortcut @(
        'path', 'targetPath', 'workingDirectory', 'arguments'
    ) 'nested GPU-Z receipt.gpuZShortcut'
    $systemNvapiPaths = @(
        (Join-Path $env:SystemRoot 'System32\nvapi64.dll'),
        (Join-Path $env:SystemRoot 'SysWOW64\nvapi.dll')
    )
    Assert-ExactProperties $receipt.systemNvapiSha256 $systemNvapiPaths `
        'nested GPU-Z receipt.systemNvapiSha256'
    foreach ($systemNvapiPath in $systemNvapiPaths) {
        $systemNvapiProperty =
            $receipt.systemNvapiSha256.PSObject.Properties[$systemNvapiPath]
        $systemNvapiHash = $systemNvapiProperty.Value
        if ($systemNvapiHash -isnot [string] -or
            [string]$systemNvapiHash -cnotmatch '^[0-9A-F]{64}$') {
            throw 'Nested GPU-Z receipt has invalid system NVAPI hash evidence.'
        }
    }
    if ($receipt.shimSha256 -isnot [string] -or
        [string]$receipt.shimSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        $receipt.backup -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$receipt.backup) -or
        $receipt.probe -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$receipt.probe)) {
        throw 'Nested GPU-Z receipt has invalid shim/backup/probe evidence.'
    }

    $completedUtc = [DateTime]::MinValue
    if ($receipt.completedUtc -isnot [string] -or
        -not [DateTime]::TryParseExact(
            [string]$receipt.completedUtc,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$completedUtc
        ) -or
        $completedUtc.Kind -ne [DateTimeKind]::Utc -or
        $completedUtc -lt $StartedUtc -or
        $completedUtc -gt [DateTime]::UtcNow.AddSeconds(5) -or
        $completedUtc -gt $receiptItem.LastWriteTimeUtc.AddSeconds(5)) {
        throw 'Nested GPU-Z receipt completedUtc is stale, non-UTC or implausible.'
    }
    if (-not (Test-JsonInteger $receipt.vmId) -or
        [int64]$receipt.vmId -ne [int64]$Contract.vmId -or
        $receipt.vmUuid -isnot [string] -or
        [string]$receipt.vmUuid -cnotmatch `
            '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' -or
        [Guid]$receipt.vmUuid -ne [Guid]$Contract.vmUuid -or
        $receipt.gpuProfile -isnot [string] -or
        [string]$receipt.gpuProfile -cne [string]$Contract.gpuProfile -or
        $receipt.gpuName -isnot [string] -or
        [string]$receipt.gpuName -cne [string]$Contract.gpuName -or
        [string]$receipt.gpuName -cne [string]$Controller.Name -or
        $receipt.pnpDeviceId -isnot [string] -or
        [string]$receipt.pnpDeviceId -ine [string]$Display.InstanceId -or
        [string]$receipt.pnpDeviceId -ine [string]$Controller.PNPDeviceID -or
        $receipt.driverVersion -isnot [string] -or
        [string]$receipt.driverVersion -cne $LockedDriverVersion -or
        [string]$receipt.driverVersion -cne
            [string]$Controller.DriverVersion -or
        -not (Test-JsonInteger $receipt.displayCount) -or
        [int64]$receipt.displayCount -ne 1) {
        throw 'Nested GPU-Z receipt identity/hardware fields do not match this migration.'
    }
    foreach ($flag in @(
            'testsigning', 'nointegritychecks', 'systemNvapiChanged')) {
        $value = $receipt.PSObject.Properties[$flag].Value
        if ($value -isnot [bool] -or $value) {
            throw "Nested GPU-Z receipt requires Boolean false for $flag."
        }
    }

    $parentProperty = Get-PnpDeviceProperty `
        -InstanceId ([string]$Display.InstanceId) `
        -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
    $parentId = [string]$parentProperty.Data
    $parents = @(Get-PnpDevice -InstanceId $parentId -PresentOnly `
        -ErrorAction Stop)
    if ($parents.Count -ne 1 -or
        [string]$parents[0].Class -ine 'System' -or
        $parentId -notmatch `
            '(?i)^PCI\\VEN_(?!10DE)[0-9A-F]{4}&DEV_[0-9A-F]{4}' -or
        $receipt.parentId -isnot [string] -or
        [string]$receipt.parentId -ine $parentId) {
        throw 'Nested GPU-Z receipt does not bind the current non-GPU PCI parent.'
    }

    $gpuZ = $receipt.gpuZ
    if ($gpuZ.path -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$gpuZ.path) -or
        $gpuZ.name -isnot [string] -or
        [string]$gpuZ.name -cne $LockedGpuZName -or
        -not (Test-JsonInteger $gpuZ.bytes) -or
        [int64]$gpuZ.bytes -ne $LockedGpuZBytes -or
        $gpuZ.sha256 -isnot [string] -or
        [string]$gpuZ.sha256 -cne $LockedGpuZSha256 -or
        $gpuZ.productVersion -isnot [string] -or
        [string]$gpuZ.productVersion -cnotmatch (
            '^' + [regex]::Escape($LockedGpuZProductVersion) +
            '(?:\.[0-9]+)?$'
        ) -or
        $gpuZ.fileVersion -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$gpuZ.fileVersion) -or
        $gpuZ.companyName -isnot [string] -or
        [string]$gpuZ.companyName -cnotmatch `
            '\ATechPowerUp(?:\s|\(|$)' -or
        $gpuZ.signatureStatus -isnot [string] -or
        [string]$gpuZ.signatureStatus -cne 'Valid' -or
        $gpuZ.signerSubject -isnot [string] -or
        [string]$gpuZ.signerSubject -cnotmatch `
            '(?:\A|,\s*)CN=TechPowerUp(?: LLC)?(?:,|\z)' -or
        $gpuZ.signerIssuer -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$gpuZ.signerIssuer) -or
        [string]$gpuZ.signerSubject -ceq [string]$gpuZ.signerIssuer -or
        $gpuZ.signerThumbprint -isnot [string] -or
        [string]$gpuZ.signerThumbprint -cnotmatch '^[0-9A-F]{40,64}$') {
        throw 'Nested receipt does not describe the locked production-signed GPU-Z 2.70.0 image.'
    }
    if ($receipt.gpuZExe -isnot [string] -or
        [string]$receipt.gpuZExe -ine [string]$gpuZ.path) {
        throw 'Nested gpuZExe and gpuZ.path disagree.'
    }

    $gpuZItem = Get-RegularFileBelowRoot ([string]$gpuZ.path) `
        $GpuZApplicationsRoot 'installed GPU-Z executable'
    if ($gpuZItem.Name -cne $LockedGpuZName -or
        [int64]$gpuZItem.Length -ne $LockedGpuZBytes -or
        (Get-Sha256 $gpuZItem.FullName) -cne $LockedGpuZSha256) {
        throw 'Installed GPU-Z bytes do not match the locked 2.70.0 image.'
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo(
        $gpuZItem.FullName
    )
    if ([string]$version.ProductVersion -cne
            [string]$gpuZ.productVersion -or
        [string]$version.FileVersion -cne [string]$gpuZ.fileVersion -or
        [string]$version.CompanyName -cne [string]$gpuZ.companyName) {
        throw 'Installed GPU-Z version metadata changed after the nested receipt.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $gpuZItem.FullName
    $certificate = $signature.SignerCertificate
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $certificate -or
        [string]$certificate.Subject -cnotmatch `
            '(?:\A|,\s*)CN=TechPowerUp(?: LLC)?(?:,|\z)' -or
        [string]$certificate.Subject -ceq [string]$certificate.Issuer -or
        [string]$certificate.Subject -cne [string]$gpuZ.signerSubject -or
        [string]$certificate.Issuer -cne [string]$gpuZ.signerIssuer -or
        ([string]$certificate.Thumbprint).ToUpperInvariant() -cne
            [string]$gpuZ.signerThumbprint) {
        throw 'Installed GPU-Z Authenticode evidence no longer matches the nested receipt.'
    }

    $commonDesktop = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonDesktopDirectory
    )
    $desktopItem = Get-Item -LiteralPath $commonDesktop -Force `
        -ErrorAction Stop
    if ($desktopItem -isnot [IO.DirectoryInfo] -or
        ($desktopItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Public Desktop must be a real, non-reparse directory.'
    }
    $expectedShortcut = [IO.Path]::GetFullPath(
        (Join-Path $desktopItem.FullName 'GPU-Z (vGPU profile).lnk')
    )
    if ($receipt.gpuZShortcut.path -isnot [string] -or
        -not ([IO.Path]::GetFullPath(
                [string]$receipt.gpuZShortcut.path
            )).Equals(
                $expectedShortcut,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
        $receipt.gpuZShortcut.targetPath -isnot [string] -or
        -not ([IO.Path]::GetFullPath(
                [string]$receipt.gpuZShortcut.targetPath
            )).Equals(
                $gpuZItem.FullName,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
        $receipt.gpuZShortcut.workingDirectory -isnot [string] -or
        -not ([IO.Path]::GetFullPath(
                [string]$receipt.gpuZShortcut.workingDirectory
            )).Equals(
                $gpuZItem.Directory.FullName,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
        $receipt.gpuZShortcut.arguments -isnot [string] -or
        [string]$receipt.gpuZShortcut.arguments -cne '') {
        throw 'Nested GPU-Z shortcut evidence does not select the installed image.'
    }
    $shortcutItem = Get-Item -LiteralPath $expectedShortcut -Force `
        -ErrorAction Stop
    if ($shortcutItem -isnot [IO.FileInfo] -or
        ($shortcutItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'GPU-Z Public Desktop shortcut is not a regular file.'
    }
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutItem.FullName)
        if (-not ([IO.Path]::GetFullPath(
                    [string]$shortcut.TargetPath
                )).Equals(
                    $gpuZItem.FullName,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
            -not ([IO.Path]::GetFullPath(
                    [string]$shortcut.WorkingDirectory
                )).Equals(
                    $gpuZItem.Directory.FullName,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
            -not [string]::IsNullOrEmpty([string]$shortcut.Arguments)) {
            throw 'Installed GPU-Z shortcut target changed after publication.'
        }
    } finally {
        if ($null -ne $shortcut -and
            [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shortcut
            )
        }
        if ($null -ne $shell -and
            [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shell
            )
        }
    }

    if ((Get-Sha256 $receiptItem.FullName) -cne $receiptSha256) {
        throw 'Nested GPU-Z receipt changed while its evidence was verified.'
    }
    return [pscustomobject][ordered]@{
        ReceiptPath = $receiptItem.FullName
        ReceiptSha256 = $receiptSha256
        Receipt = $receipt
        CompletedUtc = $completedUtc.ToString('o')
        ParentId = $parentId
        GpuZ = [pscustomobject][ordered]@{
            path = $gpuZItem.FullName
            name = $gpuZItem.Name
            bytes = [int64]$gpuZItem.Length
            sha256 = Get-Sha256 $gpuZItem.FullName
            productVersion = [string]$version.ProductVersion
            fileVersion = [string]$version.FileVersion
            companyName = [string]$version.CompanyName
            signatureStatus = [string]$signature.Status
            signerSubject = [string]$certificate.Subject
            signerIssuer = [string]$certificate.Issuer
            signerThumbprint =
                ([string]$certificate.Thumbprint).ToUpperInvariant()
        }
        Shortcut = [pscustomobject][ordered]@{
            path = $shortcutItem.FullName
            targetPath = $gpuZItem.FullName
            workingDirectory = $gpuZItem.Directory.FullName
            arguments = ''
        }
    }
}

function Read-Contract {
    $item = Get-Item -LiteralPath $ContractPath -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Migration contract must be a regular non-reparse file.'
    }
    try {
        $raw = Get-Content -LiteralPath $item.FullName -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Migration contract is invalid JSON: $($_.Exception.Message)"
    }
    Assert-ExactProperties $raw @(
        'schemaVersion', 'migrationId', 'vmId', 'vmUuid', 'gpuProfile',
        'gpuName', 'legacyPnpId', 'nativePnpId', 'driver', 'gpuz'
    ) 'contract'
    Assert-ExactProperties $raw.driver @(
        'archiveName', 'archiveBytes', 'archiveSha256',
        'infRelativePath', 'infSha256', 'catalogRelativePath',
        'catalogSha256', 'driverVersion'
    ) 'contract.driver'
    Assert-ExactProperties $raw.gpuz @('name', 'sha256') 'contract.gpuz'
    if ([int]$raw.schemaVersion -ne 1 -or
        [int64]$raw.vmId -lt 1 -or [int64]$raw.vmId -gt 2147483647 -or
        [string]$raw.migrationId -cnotmatch '^[0-9A-F]{32}$' -or
        [string]$raw.vmUuid -cnotmatch `
            '^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$' -or
        [string]$raw.gpuProfile -cnotmatch '^[a-z0-9][a-z0-9_]{0,63}$' -or
        [string]$raw.gpuName -cnotmatch '^NVIDIA [ -~]{1,23}$' -or
        [string]$raw.legacyPnpId -cnotmatch `
            '^PCI\\VEN_10DE&DEV_[0-9A-F]{4}(&SUBSYS_[0-9A-F]{8})?$' -or
        [string]$raw.nativePnpId -cne 'PCI\VEN_10DE&DEV_1E30') {
        throw 'Migration contract identity fields are invalid.'
    }
    if ([string]$raw.driver.archiveName -cne '538.33-display-driver.zip' -or
        [int64]$raw.driver.archiveBytes -ne $LockedArchiveBytes -or
        [string]$raw.driver.archiveSha256 -cne $LockedArchiveSha256 -or
        [string]$raw.driver.infRelativePath -cne 'Display.Driver/nvgridsw.inf' -or
        [string]$raw.driver.infSha256 -cne $LockedInfSha256 -or
        [string]$raw.driver.catalogRelativePath -cne `
            'Display.Driver/nvgridsw.cat' -or
        [string]$raw.driver.catalogSha256 -cne $LockedCatalogSha256 -or
        [string]$raw.driver.driverVersion -cne $LockedDriverVersion -or
        [string]$raw.gpuz.name -cne 'GpuZProfile.exe' -or
        [string]$raw.gpuz.sha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Contract does not select the locked original 538.33 package.'
    }
    return $raw
}

function Assert-GuestUuid {
    param([Parameter(Mandatory = $true)]$Contract)
    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1 -or
        [Guid]$products[0].UUID -ne [Guid]$Contract.vmUuid) {
        throw "This EXE is not for this VM UUID ($($Contract.vmUuid))."
    }
    Write-Pass "guest UUID matches vm$($Contract.vmId)."
}

function Test-PnpPrefix {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    $actualUpper = $Actual.Trim().ToUpperInvariant()
    $expectedUpper = $Expected.Trim().ToUpperInvariant()
    return $actualUpper -eq $expectedUpper -or
        $actualUpper.StartsWith($expectedUpper + '&',
            [StringComparison]::Ordinal) -or
        $actualUpper.StartsWith($expectedUpper + '\',
            [StringComparison]::Ordinal)
}

function Get-OneDisplay {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        throw 'Get-PnpDevice is required.'
    }
    $displays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    if ($displays.Count -ne 1) {
        throw "Exactly one present Display is required; found $($displays.Count). Disconnect RDP first."
    }
    return $displays[0]
}

function Wait-OneDisplay {
    param([int]$Seconds = 300)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        try {
            return Get-OneDisplay
        } catch {
            if ((Get-Date) -ge $deadline) { throw }
            Start-Sleep -Seconds 5
        }
    } while ($true)
}

function New-ProtectedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = New-Item -Path $Path -ItemType Directory -Force
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.DirectoryInfo] -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected state path must be a real, non-reparse directory: $Path"
    }
    $administrators = New-Object `
        -TypeName Security.Principal.SecurityIdentifier `
        -ArgumentList 'S-1-5-32-544'
    $system = New-Object `
        -TypeName Security.Principal.SecurityIdentifier `
        -ArgumentList 'S-1-5-18'
    $security = New-Object `
        -TypeName Security.AccessControl.DirectorySecurity
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagate = [Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @($administrators, $system)) {
        $arguments = @(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            $propagate,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $rule = New-Object `
            -TypeName Security.AccessControl.FileSystemAccessRule `
            -ArgumentList $arguments
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Assert-CatalogSignature {
    param([Parameter(Mandatory = $true)][string]$CatalogPath)
    $signature = Get-AuthenticodeSignature -LiteralPath $CatalogPath
    $subject = if ($null -ne $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    } else { '' }
    $thumbprint = if ($null -ne $signature.SignerCertificate) {
        ([string]$signature.SignerCertificate.Thumbprint).ToUpperInvariant()
    } else { '' }
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $subject -ceq [string]$signature.SignerCertificate.Issuer -or
        $subject -notmatch `
            '\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)' -or
        $thumbprint -cne $LockedCatalogSignerThumbprint) {
        throw "Catalog is not the locked Microsoft WHCP production signature: $CatalogPath"
    }
    return [pscustomobject]@{
        Subject = $subject
        Issuer = [string]$signature.SignerCertificate.Issuer
        Thumbprint = $thumbprint
    }
}

function Get-CatalogNameFromInf {
    param([Parameter(Mandatory = $true)][string]$InfPath)
    $text = [IO.File]::ReadAllText($InfPath)
    $matches = [regex]::Matches(
        $text,
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

function Get-OriginalDriverPackages {
    $packages = @()
    foreach ($driver in @(Get-WindowsDriver -Online -All -ErrorAction Stop)) {
        if ([string]$driver.Driver -notmatch '^oem[0-9]+\.inf$' -or
            [string]$driver.ProviderName -notmatch '\ANVIDIA(?: Corporation)?\z' -or
            [string]$driver.Version -cne $LockedDriverVersion) {
            continue
        }
        # `Get-WindowsDriver -Online -Driver oemN.inf` is not a package
        # lookup on the target Win10 DISM build: NVIDIA's single display INF
        # expands to one row per model and returned 1750 rows for this exact
        # package.  The package-level `-All` row already carries the canonical
        # DriverStore OriginalFileName, so use that one path and prove its
        # bytes below instead of incorrectly requiring one expanded model row.
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
        $signer = Assert-CatalogSignature $catalogPath
        $packages += [pscustomobject]@{
            InfName = [string]$driver.Driver
            InfPath = $infPath
            CatalogPath = $catalogPath
            CatalogSigner = $signer.Subject
            CatalogSignerThumbprint = $signer.Thumbprint
        }
    }
    return @($packages)
}

function Assert-OriginalSourceAndStage {
    param([Parameter(Mandatory = $true)]$Contract)
    if ([string]::IsNullOrWhiteSpace($DriverZip)) {
        throw 'The first/A-phase run requires the embedded original driver ZIP.'
    }
    $zipItem = Get-Item -LiteralPath $DriverZip -Force -ErrorAction Stop
    if ($zipItem -isnot [IO.FileInfo] -or
        ($zipItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $zipItem.Length -ne $LockedArchiveBytes -or
        (Get-Sha256 $zipItem.FullName) -cne $LockedArchiveSha256) {
        throw 'Embedded GRID archive size/SHA-256 does not match the locked original.'
    }
    $extractRoot = Join-Path $env:TEMP (
        'original-grid-' + [Guid]::NewGuid().ToString('N')
    )
    New-ProtectedDirectory $extractRoot
    try {
        Expand-Archive -LiteralPath $zipItem.FullName `
            -DestinationPath $extractRoot -Force
        $driverRoot = Join-Path $extractRoot 'Display.Driver'
        $infPath = Join-Path $driverRoot 'nvgridsw.inf'
        $catalogPath = Join-Path $driverRoot 'nvgridsw.cat'
        if ((Get-Sha256 $infPath) -cne $LockedInfSha256 -or
            (Get-Sha256 $catalogPath) -cne $LockedCatalogSha256) {
            throw 'Extracted original INF/catalog hashes changed.'
        }
        $infText = [IO.File]::ReadAllText($infPath)
        if ($infText -notmatch `
                '(?im)^\s*DriverVer\s*=\s*01/25/2024,\s*31\.0\.15\.3833\s*$' -or
            $infText -notmatch `
                '(?im)^\s*CatalogFile\s*=\s*nvgridsw\.CAT\s*$' -or
            $infText -notmatch `
                '(?im)PCI\\VEN_10DE&DEV_1E30&SUBSYS_[0-9A-F]{8}') {
            throw 'Original INF metadata/native DEV_1E30 coverage is missing.'
        }
        # Test-FileCatalog validates PowerShell/New-FileCatalog catalogs and
        # cannot open this Windows driver catalog on the target Win10 build.
        # Do not weaken the package proof to a best-effort cmdlet call:
        #   * the complete vendor ZIP, source INF and source CAT are all pinned
        #     to their independently audited byte hashes above;
        #   * the CAT's Authenticode chain is validated below; and
        #   * pnputil /add-driver is the authoritative SetupAPI catalog-member
        #     gate.  After that succeeds, the published DriverStore INF/CAT
        #     are located dynamically and required to have the same fixed
        #     hashes before a staged receipt can be written.
        $sourceSigner = Assert-CatalogSignature $catalogPath
        Write-Pass 'original archive, INF, catalog and signer bytes validated.'

        $beforeDisplay = Get-OneDisplay
        $beforeActive =
            Get-ActiveSignedDriver ([string]$beforeDisplay.InstanceId)
        $output = (& $SystemPnpUtil /add-driver $infPath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not add the original INF to DriverStore: $output"
        }
        $afterDisplay = Get-OneDisplay
        $afterActive =
            Get-ActiveSignedDriver ([string]$afterDisplay.InstanceId)
        if ([string]$beforeDisplay.InstanceId -ine
                [string]$afterDisplay.InstanceId -or
            [string]$beforeActive.InfName -ine
                [string]$afterActive.InfName) {
            throw 'The active A-phase display/INF changed during add-only staging.'
        }
        $packages = @(Get-OriginalDriverPackages)
        if ($packages.Count -ne 1) {
            throw "Expected one exact original package after staging; found $($packages.Count)."
        }
        Write-Pass "original package staged add-only as $($packages[0].InfName)."
        return [pscustomobject]@{
            Package = $packages[0]
            SourceSigner = $sourceSigner
            DisplayInstance = [string]$afterDisplay.InstanceId
            ActiveInfBefore = [string]$beforeActive.InfName
            ActiveInfAfter = [string]$afterActive.InfName
        }
    } finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}

function Install-Continuation {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)][string]$ContractHash
    )
    New-ProtectedDirectory $StateRoot
    New-ProtectedDirectory $VersionsRoot
    New-ProtectedDirectory $ReceiptsRoot
    $versionRoot = Join-Path $VersionsRoot ([string]$Contract.migrationId)
    New-ProtectedDirectory $versionRoot
    $installedScript = Join-Path $versionRoot `
        'migrate-vgpu-production-driver.ps1'
    $installedContract = Join-Path $versionRoot 'migration-contract.json'
    $installedGpuZ = Join-Path $versionRoot 'GpuZProfile.exe'
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
    Copy-Item -LiteralPath $ContractPath -Destination $installedContract -Force
    Copy-Item -LiteralPath $GpuZProfileExe -Destination $installedGpuZ -Force
    if ((Get-Sha256 $installedScript) -cne (Get-Sha256 $PSCommandPath) -or
        (Get-Sha256 $installedContract) -cne $ContractHash -or
        (Get-Sha256 $installedGpuZ) -cne [string]$Contract.gpuz.sha256) {
        throw 'Installed continuation assets failed post-copy verification.'
    }
    $arguments = '-NoLogo -NoProfile -NonInteractive ' +
        '-ExecutionPolicy Bypass -File "' + $installedScript + '" ' +
        '-ContractPath "' + $installedContract + '" ' +
        '-GpuZProfileExe "' + $installedGpuZ + '" -Installed'
    $action = New-ScheduledTaskAction -Execute $SystemPowerShell `
        -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM `
        -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(45)) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(2))
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Pass 'protected SYSTEM startup continuation installed.'
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

function Get-ActiveSignedDriver {
    param([Parameter(Mandatory = $true)][string]$DeviceId)
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { [string]$_.DeviceID -ieq $DeviceId })
    if ($drivers.Count -ne 1 -or
        [string]$drivers[0].InfName -notmatch '^oem[0-9]+\.inf$') {
        throw 'The display does not have exactly one published signed driver.'
    }
    return $drivers[0]
}

function Get-HardwareId {
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
    $ids = @($property.Data | Where-Object {
        [string]$_ -match '(?i)^PCI\\VEN_10DE&DEV_1E30'
    })
    if ($ids.Count -lt 1) {
        throw 'Native display has no DEV_1E30 hardware ID.'
    }
    $subsystemIds = @($ids | Where-Object {
        [string]$_ -match `
            '(?i)^PCI\\VEN_10DE&DEV_1E30&SUBSYS_[0-9A-F]{8}$'
    } | Sort-Object -Unique)
    if ($subsystemIds.Count -gt 1) {
        throw 'Native display exposes more than one exact SUBSYS hardware ID.'
    }
    if ($subsystemIds.Count -eq 1) {
        return [string]$subsystemIds[0]
    }
    $genericIds = @($ids | Where-Object {
        [string]$_ -match '(?i)^PCI\\VEN_10DE&DEV_1E30$'
    } | Sort-Object -Unique)
    if ($genericIds.Count -ne 1) {
        throw 'Native display has no unique exact hardware ID for INF binding.'
    }
    return [string]$genericIds[0]
}

function Export-OriginalPackageForBinding {
    param([Parameter(Mandatory = $true)]$Package)
    $exportRoot = Join-Path $StateRoot (
        'bind-source-' + [Guid]::NewGuid().ToString('N')
    )
    New-ProtectedDirectory $exportRoot
    try {
        $output =
            (& $SystemPnpUtil /export-driver $Package.InfName `
                $exportRoot 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not export $($Package.InfName): $output"
        }
        $matchingInfs = @(Get-ChildItem -LiteralPath $exportRoot `
            -Filter '*.inf' -File -Recurse -Force -ErrorAction Stop |
            Where-Object {
                ($_.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                (Get-Sha256 $_.FullName) -ceq $LockedInfSha256
            })
        if ($matchingInfs.Count -ne 1) {
            throw "Exported package has $($matchingInfs.Count) exact original INFs."
        }
        $infPath = $matchingInfs[0].FullName
        $catalogPath = Join-Path (Split-Path -Parent $infPath) `
            (Get-CatalogNameFromInf $infPath)
        $catalogItem = Get-Item -LiteralPath $catalogPath -Force `
            -ErrorAction Stop
        if ($catalogItem -isnot [IO.FileInfo] -or
            ($catalogItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-Sha256 $catalogItem.FullName) -cne $LockedCatalogSha256) {
            throw 'Exported package catalog is not the exact original.'
        }
        $null = Assert-CatalogSignature $catalogItem.FullName
        return [pscustomobject]@{
            Root = $exportRoot
            InfPath = $infPath
            CatalogPath = $catalogItem.FullName
        }
    } catch {
        Remove-Item -LiteralPath $exportRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}

function Test-ActiveOriginalPackage {
    param(
        [Parameter(Mandatory = $true)]$Display,
        [Parameter(Mandatory = $true)]$Package
    )
    # A native device may initially be on Microsoft Basic Display
    # (basicdisplay.inf), or on the legacy oemN package.  Both are valid inputs
    # to the exact FORCE binding below; only the final acceptance gate requires
    # one published signed oemN package.
    $signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object {
            [string]$_.DeviceID -ieq [string]$Display.InstanceId
        })
    return ($signed.Count -eq 1 -and
        [string]$signed[0].InfName -ieq [string]$Package.InfName)
}

function Test-ProvenLegacySigner {
    param($Certificate)
    if ($null -eq $Certificate) { return $false }
    $subject = [string]$Certificate.Subject
    return ($subject -ceq [string]$Certificate.Issuer -and
        $subject -match `
            '(?i)^CN=(VM3 vGPU Test Driver Signing|QEMU vGPU Guest Driver Signing)(?:,|$)')
}

function Remove-ProvenLegacySelfSignedAssets {
    param([Parameter(Mandatory = $true)][string]$ActiveInf)
    $removedSignerThumbprints = @()
    $boundInfs = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        ForEach-Object { [string]$_.InfName } |
        Where-Object { $_ -match '^oem[0-9]+\.inf$' } |
        Sort-Object -Unique)
    foreach ($driver in @(Get-WindowsDriver -Online -All -ErrorAction Stop)) {
        $infName = [string]$driver.Driver
        if ($infName -notmatch '^oem[0-9]+\.inf$' -or
            $infName -ieq $ActiveInf -or $boundInfs -icontains $infName -or
            [string]$driver.ProviderName -notmatch '\ANVIDIA(?: Corporation)?\z') {
            continue
        }
        $infPath = [string]$driver.OriginalFileName
        try {
            $catalogPath = Join-Path (Split-Path -Parent $infPath) `
                (Get-CatalogNameFromInf $infPath)
            $signature = Get-AuthenticodeSignature -LiteralPath $catalogPath
            $certificate = $signature.SignerCertificate
            if (Test-ProvenLegacySigner $certificate) {
                $thumbprint =
                    ([string]$certificate.Thumbprint).ToUpperInvariant()
                if ($thumbprint -cnotmatch '^[0-9A-F]{40,64}$') {
                    throw "Legacy signer thumbprint is invalid for $infName."
                }
                $deleteOutput =
                    (& $SystemPnpUtil /delete-driver $infName 2>&1 | Out-String)
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not remove inactive legacy $infName`: $deleteOutput"
                }
                $removedSignerThumbprints += $thumbprint
                Write-Pass "removed inactive legacy self-signed package $infName."
            }
        } catch {
            throw "Legacy package cleanup stopped safely at $infName`: $($_.Exception.Message)"
        }
    }

    $removedSignerThumbprints =
        @($removedSignerThumbprints | Sort-Object -Unique)
    if ($removedSignerThumbprints.Count -eq 0) {
        return
    }

    # A certificate is deletable only when no remaining oemN package from any
    # provider references that exact thumbprint.  If even one package cannot
    # be inspected, keep every candidate certificate.
    $referencedSignerThumbprints = @()
    try {
        foreach ($driver in @(
                Get-WindowsDriver -Online -All -ErrorAction Stop)) {
            $infName = [string]$driver.Driver
            if ($infName -notmatch '^oem[0-9]+\.inf$') { continue }
            $infPath = [string]$driver.OriginalFileName
            $catalogPath = Join-Path (Split-Path -Parent $infPath) `
                (Get-CatalogNameFromInf $infPath)
            $signature = Get-AuthenticodeSignature -LiteralPath $catalogPath
            $certificate = $signature.SignerCertificate
            if ($null -eq $certificate) { continue }
            $thumbprint =
                ([string]$certificate.Thumbprint).ToUpperInvariant()
            if ($removedSignerThumbprints -ccontains $thumbprint) {
                $referencedSignerThumbprints += $thumbprint
            }
        }
    } catch {
        Write-Warning (
            'Legacy private certificates were retained because not every ' +
            "remaining DriverStore catalog could be inspected: $($_.Exception.Message)"
        )
        return
    }
    $referencedSignerThumbprints =
        @($referencedSignerThumbprints | Sort-Object -Unique)
    $deletableSignerThumbprints = @($removedSignerThumbprints |
        Where-Object {
            $referencedSignerThumbprints -cnotcontains $_
        })
    if ($referencedSignerThumbprints.Count -ne 0) {
        Write-Warning (
            'Legacy certificate thumbprints still referenced by DriverStore ' +
            "were retained: $($referencedSignerThumbprints -join ', ')"
        )
    }
    foreach ($store in @('My', 'Root', 'TrustedPublisher')) {
        Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction Stop |
            Where-Object {
                $thumbprint = ([string]$_.Thumbprint).ToUpperInvariant()
                (Test-ProvenLegacySigner $_) -and
                    $deletableSignerThumbprints -ccontains $thumbprint
            } | ForEach-Object {
                Remove-Item -LiteralPath $_.PSPath -Force
                Write-Pass "removed legacy private certificate $($_.Thumbprint) from $store."
            }
    }
}

function Invoke-StagingPhase {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)]$Display,
        [Parameter(Mandatory = $true)][string]$ContractHash,
        [Parameter(Mandatory = $true)]$EntryBcd
    )
    $stage = Assert-OriginalSourceAndStage $Contract
    Install-Continuation $Contract $ContractHash
    $exitBcd = Assert-BcdUnchanged $EntryBcd
    $receipt = [ordered]@{
        schemaVersion = 1
        phase = 'staged'
        migrationId = [string]$Contract.migrationId
        vmId = [int]$Contract.vmId
        vmUuid = ([Guid]$Contract.vmUuid).ToString().ToLowerInvariant()
        gpuProfile = [string]$Contract.gpuProfile
        gpuName = [string]$Contract.gpuName
        displayInstanceBefore = [string]$stage.DisplayInstance
        activeInfBefore = [string]$stage.ActiveInfBefore
        activeInfAfter = [string]$stage.ActiveInfAfter
        nextHostMode = 'B'
        nativePnpId = [string]$Contract.nativePnpId
        driverVersion = $LockedDriverVersion
        archiveBytes = $LockedArchiveBytes
        archiveSha256 = $LockedArchiveSha256
        sourceInfSha256 = $LockedInfSha256
        sourceCatalogSha256 = $LockedCatalogSha256
        publishedInf = [string]$stage.Package.InfName
        driverStoreInfSha256 = Get-Sha256 $stage.Package.InfPath
        driverStoreCatalogSha256 = Get-Sha256 $stage.Package.CatalogPath
        catalogSigner = [string]$stage.Package.CatalogSigner
        catalogSignerThumbprint =
            [string]$stage.Package.CatalogSignerThumbprint
        testsigning = $false
        nointegritychecks = $false
        activeDriverChanged = $false
        bcdBeforeSha256 = [string]$EntryBcd.Sha256
        bcdAfterSha256 = [string]$exitBcd.Sha256
        bcdChanged = $false
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receiptName = "vm$($Contract.vmId)-$($Contract.migrationId)-staged.json"
    $path = Write-JsonReceipt $receiptName $receipt
    Write-Pass "staged receipt committed: $path"
    if ($ShutdownWhenStaged) {
        Write-Host 'Original package is staged. Windows will fully shut down now.' `
            -ForegroundColor Cyan
        [QemuVgpuShutdown]::Schedule($false)
    }
}

function Invoke-NativeFinalPhase {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)]$Display,
        [Parameter(Mandatory = $true)]$EntryBcd
    )
    $packages = @(Get-OriginalDriverPackages)
    if ($packages.Count -ne 1) {
        throw "Expected one exact original DriverStore package; found $($packages.Count)."
    }
    $package = $packages[0]
    if (-not (Test-ActiveOriginalPackage $Display $package)) {
        $hardwareId = Get-HardwareId ([string]$Display.InstanceId)
        Write-Host "Binding exact original package $($package.InfName)..." `
            -ForegroundColor Cyan
        $bindingSource = Export-OriginalPackageForBinding $package
        try {
            $infText = [IO.File]::ReadAllText($bindingSource.InfPath)
            $modelPattern = '(?im),\s*' +
                [regex]::Escape($hardwareId) + '\s*(?:;.*)?$'
            if ($infText -notmatch $modelPattern) {
                throw "Exact original INF does not contain hardware ID $hardwareId."
            }
            $rebootRequired = [QemuVgpuNewDev]::ForceUpdate(
                $hardwareId, $bindingSource.InfPath)
        } finally {
            Remove-Item -LiteralPath $bindingSource.Root -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
        $activeNow = Test-ActiveOriginalPackage $Display $package
        if ($rebootRequired -or -not $activeNow) {
            $exitBcd = Assert-BcdUnchanged $EntryBcd
            $pending = [ordered]@{
                schemaVersion = 1
                phase = 'binding-pending-reboot'
                migrationId = [string]$Contract.migrationId
                vmId = [int]$Contract.vmId
                vmUuid = ([Guid]$Contract.vmUuid).ToString().ToLowerInvariant()
                publishedInf = [string]$package.InfName
                sourceInfSha256 = $LockedInfSha256
                sourceCatalogSha256 = $LockedCatalogSha256
                testsigning = $false
                nointegritychecks = $false
                bcdBeforeSha256 = [string]$EntryBcd.Sha256
                bcdAfterSha256 = [string]$exitBcd.Sha256
                bcdChanged = $false
                completedUtc = [DateTime]::UtcNow.ToString('o')
            }
            $null = Write-JsonReceipt `
                "vm$($Contract.vmId)-$($Contract.migrationId)-binding.json" `
                $pending
            Write-Host 'Exact production INF selected; rebooting for binding proof.' `
                -ForegroundColor Cyan
            [QemuVgpuShutdown]::Schedule($true)
            return
        }
    }

    Start-Sleep -Seconds 3
    $display = Wait-OneDisplay
    if (-not (Test-PnpPrefix ([string]$display.InstanceId) `
            ([string]$Contract.nativePnpId))) {
        throw 'Post-bind display no longer has native DEV_1E30 identity.'
    }
    $controller = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object {
            [string]$_.PNPDeviceID -ieq [string]$display.InstanceId
        })
    if ($controller.Count -ne 1 -or
        [int]$controller[0].ConfigManagerErrorCode -ne 0 -or
        [string]$controller[0].DriverVersion -cne $LockedDriverVersion) {
        throw 'Post-reboot production device is not one Code-0 538.33 controller.'
    }
    $active = Get-ActiveSignedDriver ([string]$display.InstanceId)
    if ([string]$active.InfName -ine [string]$package.InfName) {
        throw "Active INF is $($active.InfName), not exact original $($package.InfName)."
    }
    $null = Assert-BcdUnchanged $EntryBcd

    $gpuzItem = Get-Item -LiteralPath $GpuZProfileExe -Force `
        -ErrorAction Stop
    if ($gpuzItem -isnot [IO.FileInfo] -or
        ($gpuzItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-Sha256 $gpuzItem.FullName) -cne [string]$Contract.gpuz.sha256) {
        throw 'Installed GPU-Z profile EXE hash does not match the contract.'
    }
    $profileStartedUtc = Start-GpuZProfileReceiptWindow
    Invoke-NestedGpuZProfileVerifier $gpuzItem

    $display = Get-OneDisplay
    $controller = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object {
            [string]$_.PNPDeviceID -ieq [string]$display.InstanceId
        })
    $active = Get-ActiveSignedDriver ([string]$display.InstanceId)
    if ($controller.Count -ne 1 -or
        [string]$controller[0].Name -cne [string]$Contract.gpuName -or
        [int]$controller[0].ConfigManagerErrorCode -ne 0 -or
        [string]$active.InfName -ine [string]$package.InfName -or
        (Get-Sha256 $package.InfPath) -cne $LockedInfSha256 -or
        (Get-Sha256 $package.CatalogPath) -cne $LockedCatalogSha256) {
        throw 'Final name/Code-0/active-original-package acceptance failed.'
    }
    $profileProof = Get-GpuZProfileProof $Contract $display `
        $controller[0] $profileStartedUtc

    # The legacy recovery package remains untouched until every production
    # binding/signature/GPU-Z gate above has passed.
    Remove-ProvenLegacySelfSignedAssets ([string]$active.InfName)
    $display = Get-OneDisplay
    $active = Get-ActiveSignedDriver ([string]$display.InstanceId)
    $controller = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object {
            [string]$_.PNPDeviceID -ieq [string]$display.InstanceId
        })
    if ([string]$active.InfName -ine [string]$package.InfName -or
        $controller.Count -ne 1 -or
        [string]$controller[0].Name -cne [string]$Contract.gpuName -or
        [int]$controller[0].ConfigManagerErrorCode -ne 0 -or
        [string]$controller[0].DriverVersion -cne $LockedDriverVersion) {
        throw 'Production name/Code-0/original package changed during legacy cleanup.'
    }
    $finalProfileProof = Get-GpuZProfileProof $Contract $display `
        $controller[0] $profileStartedUtc
    if ([string]$finalProfileProof.ReceiptSha256 -cne
            [string]$profileProof.ReceiptSha256 -or
        [string]$finalProfileProof.GpuZ.sha256 -cne
            [string]$profileProof.GpuZ.sha256) {
        throw 'Nested GPU-Z proof changed during production-driver cleanup.'
    }
    $profileProof = $finalProfileProof
    $exitBcd = Assert-BcdUnchanged $EntryBcd
    Remove-RegularFileIfPresent (Join-Path $StateRoot 'last-error.txt') `
        'stale migration error record'
    $final = [ordered]@{
        schemaVersion = 1
        phase = 'final'
        migrationId = [string]$Contract.migrationId
        vmId = [int]$Contract.vmId
        vmUuid = ([Guid]$Contract.vmUuid).ToString().ToLowerInvariant()
        gpuProfile = [string]$Contract.gpuProfile
        gpuName = [string]$controller[0].Name
        pnpDeviceId = [string]$display.InstanceId
        displayCount = 1
        configManagerErrorCode = 0
        driverVersion = [string]$controller[0].DriverVersion
        activeInf = [string]$active.InfName
        activeInfSha256 = Get-Sha256 $package.InfPath
        activeCatalogSha256 = Get-Sha256 $package.CatalogPath
        activeCatalogSigner = [string]$package.CatalogSigner
        activeCatalogSignerThumbprint =
            [string]$package.CatalogSignerThumbprint
        gpuzProfileExeSha256 = Get-Sha256 $gpuzItem.FullName
        gpuzProfileReceiptPath = [string]$profileProof.ReceiptPath
        gpuzProfileReceiptSha256 = [string]$profileProof.ReceiptSha256
        gpuzProfileReceipt = $profileProof.Receipt
        gpuZ = $profileProof.GpuZ
        gpuZShortcut = $profileProof.Shortcut
        testsigning = $false
        nointegritychecks = $false
        bcdBeforeSha256 = [string]$EntryBcd.Sha256
        bcdAfterSha256 = [string]$exitBcd.Sha256
        bcdChanged = $false
        legacyCleanupAfterProductionProof = $true
        completedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $path = Write-JsonReceipt `
        "vm$($Contract.vmId)-$($Contract.migrationId)-final.json" $final
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -Confirm:$false -ErrorAction Stop
    $taskStillPresent = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue
    if ($null -ne $taskStillPresent) {
        throw 'FINAL receipt exists, but the startup continuation did not unregister.'
    }
    Write-Host ''
    Write-Host '[vGPU production migration] FINAL PASS' `
        -ForegroundColor Green
    Write-Host "  GPU:       $($final.gpuName)"
    Write-Host "  PnP:       $($final.pnpDeviceId)"
    Write-Host "  Driver:    $($final.driverVersion) / $($final.activeInf) / Code 0"
    Write-Host "  INF SHA:   $($final.activeInfSha256)"
    Write-Host "  CAT SHA:   $($final.activeCatalogSha256)"
    Write-Host "  Signer:    $($final.activeCatalogSigner)"
    Write-Host "  Receipt:   $path"
    Write-Host '  BCD:       untouched; testsigning/nointegritychecks are off'
}

function Invoke-Main {
    Assert-Administrator
    $contract = Read-Contract
    $contractHash = Get-Sha256 $ContractPath
    Assert-GuestUuid $contract
    $entryBcd = Get-NormalBcdSnapshot
    if ((Get-Sha256 $GpuZProfileExe) -cne [string]$contract.gpuz.sha256) {
        throw 'GPU-Z profile EXE hash does not match the migration contract.'
    }
    $display = if ($Installed) {
        Wait-OneDisplay
    } else {
        Get-OneDisplay
    }
    if (Test-PnpPrefix ([string]$display.InstanceId) `
            ([string]$contract.nativePnpId)) {
        Invoke-NativeFinalPhase $contract $display $entryBcd
    } elseif (Test-PnpPrefix ([string]$display.InstanceId) `
            ([string]$contract.legacyPnpId)) {
        if ($Installed) {
            # Host has not consumed the receipt/switched to B yet.  A startup
            # continuation may safely run again, but it must not touch the
            # active legacy device or overwrite the completed staged receipt.
            Write-Host 'Waiting for the host to verify the staged receipt and switch to B.' `
                -ForegroundColor Yellow
            $null = Assert-BcdUnchanged $entryBcd
            return
        }
        Invoke-StagingPhase $contract $display $contractHash $entryBcd
    } else {
        throw "Unexpected display identity: $($display.InstanceId)"
    }
}

try {
    Invoke-Main
    exit 0
} catch {
    try {
        New-ProtectedDirectory $StateRoot
        $_ | Out-String |
            Set-Content -LiteralPath (Join-Path $StateRoot 'last-error.txt') `
                -Encoding UTF8
    } catch {}
    Write-Error $_
    exit 1
}
