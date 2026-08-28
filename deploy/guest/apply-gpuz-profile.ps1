#requires -Version 5.1
<#
.SYNOPSIS
  Apply and verify one HTTP-free vGPU identity bundle, with optional GPU-Z.

.DESCRIPTION
  This entry point accepts every audited B/native catalog identity.
  It verifies every bundle asset before mutation, checks the VM UUID, active
  display count, driver health/signature and BCD integrity policy, applies the
  per-VM registry profile, publishes the identity query and x86 app-local shim
  under protected ProgramData, and optionally imports the contract-bound
  GPU-Z 2.70.0 image only when -InstallGpuZ is explicitly supplied.  BCD, the
  Driver Store, display-driver
  binaries and System32/SysWOW64 NVAPI images are never modified.  Windows
  Task Scheduler still persists the protected offline registry-refresh task
  in its normal system-managed task store.

  The shim is a hash-pinned unsigned user-mode DLL, not a driver and not a
  self-signed image.  The original app-local sibling must come from a valid,
  non-self-issued NVIDIA or Microsoft WHCP signed system NVAPI image.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [switch]$NoLaunch,
    [switch]$InstallGpuZ
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$ReadyPath = Join-Path $BundleRoot 'READY'
$ManifestPath = Join-Path $BundleRoot 'bundle-manifest.json'
$ContractPath = Join-Path $BundleRoot 'gpuz-contract.json'
$InstallRoot = Join-Path $env:ProgramData 'QemuGpuZProfile'
$BackupRoot = Join-Path $InstallRoot 'backups'
$VersionRoot = Join-Path $InstallRoot 'versions'
$ApplicationsRoot = Join-Path $InstallRoot 'applications'
$RefreshTaskName = 'RefreshGridNames'
$SystemPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$SystemBcdEdit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
$SystemReg = Join-Path $env:SystemRoot 'System32\reg.exe'
$SystemPowerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$PublicSignerCache = @{}

if ($VerifyOnly -and $InstallGpuZ) {
    throw '-VerifyOnly and -InstallGpuZ cannot be combined.'
}

if (-not ([System.Management.Automation.PSTypeName]'QemuGpuZNativeSecurity').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;

public static class QemuGpuZNativeSecurity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct CERT_CHAIN_POLICY_PARA
    {
        public uint cbSize;
        public uint dwFlags;
        public IntPtr pvExtraPolicyPara;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CERT_CHAIN_POLICY_STATUS
    {
        public uint cbSize;
        public uint dwError;
        public int lChainIndex;
        public int lElementIndex;
        public IntPtr pvExtraPolicyStatus;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SSL_F12_EXTRA_CERT_CHAIN_POLICY_STATUS
    {
        public uint cbSize;
        public uint dwErrorLevel;
        public uint dwErrorCategory;
        public uint dwReserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string wszErrorText;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CERT_CONTEXT
    {
        public uint dwCertEncodingType;
        public IntPtr pbCertEncoded;
        public uint cbCertEncoded;
        public IntPtr pCertInfo;
        public IntPtr hCertStore;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CERT_ENHKEY_USAGE
    {
        public uint cUsageIdentifier;
        public IntPtr rgpszUsageIdentifier;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CERT_USAGE_MATCH
    {
        public uint dwType;
        public CERT_ENHKEY_USAGE Usage;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CERT_CHAIN_PARA
    {
        public uint cbSize;
        public CERT_USAGE_MATCH RequestedUsage;
        public CERT_USAGE_MATCH RequestedIssuancePolicy;
        public uint dwUrlRetrievalTimeout;
        public int fCheckRevocationFreshnessTime;
        public uint dwRevocationFreshnessTime;
        public IntPtr pftCacheResync;
        public IntPtr pStrongSignPara;
        public uint dwStrongSignFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertVerifyCertificateChainPolicy(
        IntPtr pszPolicyOID,
        IntPtr pChainContext,
        ref CERT_CHAIN_POLICY_PARA pPolicyPara,
        ref CERT_CHAIN_POLICY_STATUS pPolicyStatus);

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode,
        ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptQueryObject(
        uint dwObjectType,
        [MarshalAs(UnmanagedType.LPWStr)] string pvObject,
        uint dwExpectedContentTypeFlags,
        uint dwExpectedFormatTypeFlags,
        uint dwFlags,
        out uint pdwMsgAndCertEncodingType,
        out uint pdwContentType,
        out uint pdwFormatType,
        out IntPtr phCertStore,
        out IntPtr phMsg,
        IntPtr ppvContext);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CertEnumCertificatesInStore(
        IntPtr hCertStore, IntPtr pPrevCertContext);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertFreeCertificateContext(
        IntPtr pCertContext);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertCloseStore(
        IntPtr hCertStore, uint dwFlags);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgClose(IntPtr hCryptMsg);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CertOpenStore(
        IntPtr lpszStoreProvider,
        uint dwMsgAndCertEncodingType,
        IntPtr hCryptProv,
        uint dwFlags,
        IntPtr pvPara);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertAddEncodedCertificateToStore(
        IntPtr hCertStore,
        uint dwCertEncodingType,
        byte[] pbCertEncoded,
        uint cbCertEncoded,
        uint dwAddDisposition,
        IntPtr ppCertContext);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertGetCertificateChain(
        IntPtr hChainEngine,
        IntPtr pCertContext,
        ref FILETIME pTime,
        IntPtr hAdditionalStore,
        ref CERT_CHAIN_PARA pChainPara,
        uint dwFlags,
        IntPtr pvReserved,
        out IntPtr ppChainContext);

    [DllImport("crypt32.dll", ExactSpelling = true)]
    private static extern void CertFreeCertificateChain(
        IntPtr pChainContext);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
        ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
        ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        IntPtr hFile,
        StringBuilder lpszFilePath,
        uint cchFilePath,
        uint dwFlags);

    [DllImport("kernel32.dll", ExactSpelling = true,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", ExactSpelling = true,
        SetLastError = true)]
    private static extern uint GetSystemFirmwareTable(
        uint firmwareTableProviderSignature,
        uint firmwareTableId,
        byte[] firmwareTableBuffer,
        uint bufferSize);

    private static bool SatisfiesSimpleChainPolicy(
        IntPtr chainContext, int policyIdentifier, uint flags)
    {
        if (chainContext == IntPtr.Zero) {
            return false;
        }
        CERT_CHAIN_POLICY_PARA policy = new CERT_CHAIN_POLICY_PARA();
        policy.cbSize = (uint)Marshal.SizeOf(typeof(CERT_CHAIN_POLICY_PARA));
        policy.dwFlags = flags;
        CERT_CHAIN_POLICY_STATUS status = new CERT_CHAIN_POLICY_STATUS();
        status.cbSize =
            (uint)Marshal.SizeOf(typeof(CERT_CHAIN_POLICY_STATUS));
        bool checkedPolicy = CertVerifyCertificateChainPolicy(
            new IntPtr(policyIdentifier), chainContext, ref policy, ref status);
        return checkedPolicy && status.dwError == 0;
    }

    private static bool CompliesWithMicrosoftRootProgram(
        IntPtr chainContext)
    {
        if (chainContext == IntPtr.Zero) {
            return false;
        }
        CERT_CHAIN_POLICY_PARA policy = new CERT_CHAIN_POLICY_PARA();
        policy.cbSize = (uint)Marshal.SizeOf(typeof(CERT_CHAIN_POLICY_PARA));
        SSL_F12_EXTRA_CERT_CHAIN_POLICY_STATUS extra =
            new SSL_F12_EXTRA_CERT_CHAIN_POLICY_STATUS();
        extra.cbSize = (uint)Marshal.SizeOf(
            typeof(SSL_F12_EXTRA_CERT_CHAIN_POLICY_STATUS));
        extra.wszErrorText = String.Empty;
        IntPtr extraPointer = Marshal.AllocHGlobal((int)extra.cbSize);
        try {
            Marshal.StructureToPtr(extra, extraPointer, false);
            CERT_CHAIN_POLICY_STATUS status =
                new CERT_CHAIN_POLICY_STATUS();
            status.cbSize =
                (uint)Marshal.SizeOf(typeof(CERT_CHAIN_POLICY_STATUS));
            status.pvExtraPolicyStatus = extraPointer;
            // CERT_CHAIN_POLICY_SSL_F12 == (LPCSTR)9.  It rejects weak
            // chains and third-party roots outside the Microsoft Root
            // Program rather than trusting an arbitrary local ROOT entry.
            bool checkedPolicy = CertVerifyCertificateChainPolicy(
                new IntPtr(9), chainContext, ref policy, ref status);
            extra = (SSL_F12_EXTRA_CERT_CHAIN_POLICY_STATUS)
                Marshal.PtrToStructure(
                    extraPointer,
                    typeof(SSL_F12_EXTRA_CERT_CHAIN_POLICY_STATUS));
            return checkedPolicy && status.dwError == 0 &&
                extra.dwErrorLevel == 0 && extra.dwErrorCategory == 0;
        } finally {
            Marshal.FreeHGlobal(extraPointer);
        }
    }

    public static X509Certificate2[] GetEmbeddedCertificates(string path)
    {
        const uint CERT_QUERY_OBJECT_FILE = 1;
        const uint CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED = 1u << 8;
        const uint CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED = 1u << 10;
        const uint CERT_QUERY_FORMAT_FLAG_BINARY = 1u << 1;
        uint encoding;
        uint content;
        uint format;
        IntPtr store;
        IntPtr message;
        if (!CryptQueryObject(
                CERT_QUERY_OBJECT_FILE, path,
                CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED |
                    CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                CERT_QUERY_FORMAT_FLAG_BINARY, 0,
                out encoding, out content, out format,
                out store, out message, IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        List<X509Certificate2> certificates =
            new List<X509Certificate2>();
        IntPtr current = IntPtr.Zero;
        try {
            while ((current =
                    CertEnumCertificatesInStore(store, current)) !=
                    IntPtr.Zero) {
                CERT_CONTEXT context = (CERT_CONTEXT)
                    Marshal.PtrToStructure(current, typeof(CERT_CONTEXT));
                if (context.cbCertEncoded == 0 ||
                    context.cbCertEncoded > 1024 * 1024 ||
                    certificates.Count >= 128) {
                    throw new InvalidOperationException(
                        "The embedded certificate set is invalid.");
                }
                byte[] encoded = new byte[(int)context.cbCertEncoded];
                Marshal.Copy(
                    context.pbCertEncoded, encoded, 0, encoded.Length);
                certificates.Add(new X509Certificate2(encoded));
            }
        } catch {
            if (current != IntPtr.Zero) {
                CertFreeCertificateContext(current);
                current = IntPtr.Zero;
            }
            foreach (X509Certificate2 certificate in certificates) {
                certificate.Dispose();
            }
            throw;
        } finally {
            if (message != IntPtr.Zero) {
                CryptMsgClose(message);
            }
            if (store != IntPtr.Zero) {
                CertCloseStore(store, 0);
            }
        }
        if (certificates.Count == 0) {
            throw new InvalidOperationException(
                "No embedded signing certificates were found.");
        }
        return certificates.ToArray();
    }

    public static int ValidatePublicProductionCodeSigningChain(
        X509Certificate2 certificate,
        X509Certificate2[] embeddedCertificates,
        DateTime verificationTime)
    {
        if (certificate == null || embeddedCertificates == null) {
            return 0;
        }
        const uint X509_ASN_ENCODING = 0x00000001;
        const uint PKCS_7_ASN_ENCODING = 0x00010000;
        const uint CERT_STORE_ADD_ALWAYS = 4;
        const uint CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL = 0x00000004;
        const uint CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE = 0x00000100;
        const uint CERT_CHAIN_DISABLE_AIA = 0x00002000;
        const uint MICROSOFT_ROOT_DISABLE_FLIGHT_ROOT = 0x00040000;
        const string CODE_SIGNING_OID = "1.3.6.1.5.5.7.3.3";

        // CERT_STORE_PROV_MEMORY == (LPCSTR)2.  The file's PKCS#7
        // intermediates are supplied explicitly so the second, stricter
        // chain build is deterministic and does not perform AIA/HTTP fetches.
        IntPtr additionalStore = CertOpenStore(
            new IntPtr(2), 0, IntPtr.Zero, 0, IntPtr.Zero);
        if (additionalStore == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        IntPtr oid = IntPtr.Zero;
        IntPtr oidArray = IntPtr.Zero;
        IntPtr chainContext = IntPtr.Zero;
        try {
            foreach (X509Certificate2 embedded in embeddedCertificates) {
                byte[] raw = embedded.RawData;
                if (!CertAddEncodedCertificateToStore(
                        additionalStore,
                        X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                        raw, (uint)raw.Length, CERT_STORE_ADD_ALWAYS,
                        IntPtr.Zero)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }

            oid = Marshal.StringToHGlobalAnsi(CODE_SIGNING_OID);
            oidArray = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(oidArray, oid);
            CERT_CHAIN_PARA chainParameters = new CERT_CHAIN_PARA();
            chainParameters.cbSize =
                (uint)Marshal.SizeOf(typeof(CERT_CHAIN_PARA));
            chainParameters.RequestedUsage.dwType = 0;
            chainParameters.RequestedUsage.Usage.cUsageIdentifier = 1;
            chainParameters.RequestedUsage.Usage.rgpszUsageIdentifier =
                oidArray;

            long fileTimeValue =
                verificationTime.ToUniversalTime().ToFileTimeUtc();
            FILETIME fileTime = new FILETIME();
            fileTime.dwLowDateTime =
                (uint)(fileTimeValue & 0xffffffffL);
            fileTime.dwHighDateTime =
                (uint)((ulong)fileTimeValue >> 32);
            uint chainFlags =
                CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL |
                CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE |
                CERT_CHAIN_DISABLE_AIA;
            // HCCE_LOCAL_MACHINE == (HCERTCHAINENGINE)1.
            if (!CertGetCertificateChain(
                    new IntPtr(1), certificate.Handle, ref fileTime,
                    additionalStore, ref chainParameters, chainFlags,
                    IntPtr.Zero, out chainContext)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            // Policy 1 is the fail-closed base chain validation.
            if (!SatisfiesSimpleChainPolicy(chainContext, 1, 0)) {
                return 0;
            }
            // Policy 7 recognizes Microsoft roots.  Test roots are never
            // enabled, and the explicit 0x40000 flag also excludes Flight.
            if (SatisfiesSimpleChainPolicy(
                    chainContext, 7,
                    MICROSOFT_ROOT_DISABLE_FLIGHT_ROOT)) {
                return 1;
            }
            // Policy 11 is the positive Third Party Root membership gate.
            // Only after it succeeds may policy 9 be interpreted as Root
            // Program/weak-crypto compliance.
            if (!SatisfiesSimpleChainPolicy(chainContext, 11, 0) ||
                !CompliesWithMicrosoftRootProgram(chainContext)) {
                return 0;
            }
            return 2;
        } finally {
            if (chainContext != IntPtr.Zero) {
                CertFreeCertificateChain(chainContext);
            }
            if (oidArray != IntPtr.Zero) {
                Marshal.FreeHGlobal(oidArray);
            }
            if (oid != IntPtr.Zero) {
                Marshal.FreeHGlobal(oid);
            }
            CertCloseStore(additionalStore, 0);
        }
    }

    public static string GetFinalLocalPath(string path)
    {
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint FILE_SHARE_DELETE = 0x00000004;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        IntPtr handle = CreateFileW(
            path, 0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS,
            IntPtr.Zero);
        if (handle == new IntPtr(-1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            StringBuilder result = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(
                handle, result, (uint)result.Capacity, 0);
            if (length == 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (length >= result.Capacity) {
                result = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandleW(
                    handle, result, (uint)result.Capacity, 0);
                if (length == 0 || length >= result.Capacity) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            return result.ToString();
        } finally {
            CloseHandle(handle);
        }
    }

    public static byte[] GetRawSmbios()
    {
        // MAKEFOURCC('R','S','M','B') as required by
        // GetSystemFirmwareTable.  The returned buffer begins with the
        // 8-byte RawSMBIOSData header followed by the structure table.
        const uint RSMB = 0x52534D42;
        uint size = GetSystemFirmwareTable(RSMB, 0, null, 0);
        if (size < 8 || size > 16 * 1024 * 1024) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        byte[] data = new byte[size];
        uint actual = GetSystemFirmwareTable(
            RSMB, 0, data, (uint)data.Length);
        if (actual != size) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return data;
    }
}
'@
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this bundle as Administrator.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run the 64-bit Windows PowerShell executable.'
    }
    $null = Assert-RegularLocalPath $SystemPowerShell 'system Windows PowerShell'
    $null = Assert-RegularLocalPath $SystemBcdEdit 'system BCD reader'
    $null = Assert-RegularLocalPath $SystemReg 'system registry tool'
    $null = Assert-RegularLocalPath $SystemPowerCfg 'system power configuration tool'
}

function Assert-AllowedProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        throw "$Context must be a JSON object."
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($Allowed -notcontains [string]$property.Name) {
            throw "Unknown $Context property '$($property.Name)'."
        }
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $properties = @($Object.PSObject.Properties |
        Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1 -or $null -eq $properties[0].Value) {
        throw "Missing required $Context property '$Name'."
    }
    return $properties[0].Value
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function ConvertTo-StrictInt {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int64]$Minimum,
        [int64]$Maximum
    )
    $parsed = 0L
    if (-not [int64]::TryParse(
            [string]$Value,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        ) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "Invalid $Name value '$Value' (expected $Minimum..$Maximum)."
    }
    return $parsed
}

function ConvertTo-StrictString {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Maximum = 256,
        [string]$Pattern = '^[\x20-\x7e]+$'
    )
    $text = [string]$Value
    if ($text.Length -lt 1 -or $text.Length -gt $Maximum -or
        $text -notmatch $Pattern) {
        throw "Invalid $Name value '$text'."
    }
    return $text
}

function Assert-RegularLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "$Context must be copied to a local drive before execution."
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSProvider.Name -cne 'FileSystem' -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context must be a regular local file: $Path"
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($item.FullName))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "$Context must be on a fixed local disk: $Path"
    }
    $directory = $item.Directory
    while ($null -ne $directory) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context is below a reparse-point directory: $Path"
        }
        $directory = $directory.Parent
    }
    return $item
}

function Get-FinalLocalPathIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    try {
        $finalPath = [QemuGpuZNativeSecurity]::GetFinalLocalPath($Path)
    } catch {
        throw "Cannot resolve the final filesystem identity of $Context '$Path': " +
            $_.Exception.Message
    }
    if ($finalPath.StartsWith(
            '\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context resolves to a network path: $finalPath"
    }
    if (-not $finalPath.StartsWith(
            '\\?\', [StringComparison]::Ordinal)) {
        throw "$Context has an unsupported final path identity: $finalPath"
    }
    return $finalPath.TrimEnd('\')
}

function Resolve-FinalRegularLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $identity = Get-FinalLocalPathIdentity $Path $Context
    if ($identity.Length -lt 7 -or
        -not [char]::IsLetter($identity[4]) -or
        $identity[5] -ne ':' -or $identity[6] -ne '\' -or
        -not $identity.StartsWith(
            '\\?\', [StringComparison]::Ordinal)) {
        throw "$Context does not resolve to an ordinary fixed-drive DOS path: $identity"
    }
    $resolvedPath = [IO.Path]::GetFullPath($identity.Substring(4))
    $item = Assert-RegularLocalPath $resolvedPath $Context
    $confirmedIdentity =
        Get-FinalLocalPathIdentity $item.FullName "$Context resolved path"
    if (-not $identity.Equals(
            $confirmedIdentity, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context changed while its final path was being resolved."
    }
    return $item
}

function Assert-OutsideWindowsTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $candidateIdentity = Get-FinalLocalPathIdentity $Path $Context
    $windowsIdentity = Get-FinalLocalPathIdentity $env:SystemRoot `
        'Windows system directory'
    if ($candidateIdentity.Equals(
            $windowsIdentity, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateIdentity.StartsWith(
            $windowsIdentity + '\',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context resolves inside the Windows system directory: $Path"
    }
}

function Assert-TrustedGpuZWriteBoundary {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$GpuZItem,
        [string]$Context = 'GPU-Z executable'
    )

    # A valid signature can still be replaced after validation when the file
    # or its directory is writable by a standard user.  Treat only SYSTEM,
    # Administrators and Windows Modules Installer as trusted writers/owners.
    $trustedSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $inheritOnly = [Security.AccessControl.PropagationFlags]::InheritOnly
    $directWriteMask = [int64](
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $ancestorControlMask = [int64](
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )

    $boundaries = @(
        [pscustomobject]@{
            Path = $GpuZItem.FullName
            Mask = $directWriteMask
            Context = $Context
        },
        [pscustomobject]@{
            Path = $GpuZItem.Directory.FullName
            Mask = $directWriteMask
            Context = "$Context directory"
        }
    )
    $ancestor = $GpuZItem.Directory.Parent
    while ($null -ne $ancestor) {
        $boundaries += [pscustomobject]@{
            Path = $ancestor.FullName
            Mask = $ancestorControlMask
            Context = "$Context ancestor directory"
        }
        $ancestor = $ancestor.Parent
    }

    foreach ($boundary in $boundaries) {
        $acl = Get-Acl -LiteralPath $boundary.Path -ErrorAction Stop
        try {
            $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
        } catch {
            try {
                $ownerSid = ([Security.Principal.SecurityIdentifier]$acl.Owner).Value
            } catch {
                throw "Cannot resolve the owner of $($boundary.Context): $($boundary.Path)"
            }
        }
        if ($trustedSids -notcontains $ownerSid) {
            throw "$($boundary.Context) has an untrusted owner '$ownerSid': $($boundary.Path)"
        }
        $accessRules = @($acl.GetAccessRules(
            $true, $true, [Security.Principal.SecurityIdentifier]
        ))
        foreach ($rule in $accessRules) {
            # An INHERIT_ONLY ACE is a template for descendants and has no
            # effect on this boundary object.  Ignore it here regardless of
            # SID, then inspect the effective ACEs again at every descendant
            # boundary (file, containing directory, and each ancestor).
            $ineffectiveAtThisBoundary =
                (($rule.PropagationFlags -band $inheritOnly) -ne 0)
            if ($rule.AccessControlType -ne $allow -or
                $trustedSids -contains $rule.IdentityReference.Value -or
                $ineffectiveAtThisBoundary) {
                continue
            }
            if (([int64]$rule.FileSystemRights -band [int64]$boundary.Mask) -ne 0) {
                throw "$($boundary.Context) permits untrusted write/delete/control " +
                    "to '$($rule.IdentityReference.Value)': $($boundary.Path)"
            }
        }
    }
    Write-Pass 'GPU-Z file/path owners and ACLs prevent untrusted replacement.'
}

function Assert-UsersReadExecuteAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $usersSid = 'S-1-5-32-545'
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $inheritOnly = [Security.AccessControl.PropagationFlags]::InheritOnly
    $readExecute = [int64](
        [Security.AccessControl.FileSystemRights]::ReadAndExecute
    )
    $effectiveRights = 0L
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in @($acl.GetAccessRules(
                $true, $true, [Security.Principal.SecurityIdentifier]
            ))) {
        if ($rule.AccessControlType -eq $allow -and
            $rule.IdentityReference.Value -ceq $usersSid -and
            ($rule.PropagationFlags -band $inheritOnly) -eq 0) {
            $effectiveRights = $effectiveRights -bor
                [int64]$rule.FileSystemRights
        }
    }
    if (($effectiveRights -band $readExecute) -ne $readExecute) {
        throw "$Context lacks effective BUILTIN\Users ReadAndExecute access: $Path"
    }
    Write-Pass "$Context grants BUILTIN\Users ReadAndExecute without write access."
}

function Set-AdminSystemUsersReadExecuteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $item = Assert-RegularLocalPath $Path $Context
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $adminsSid =
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $usersSid =
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $noneInheritance = [Security.AccessControl.InheritanceFlags]::None
    $nonePropagation = [Security.AccessControl.PropagationFlags]::None
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($adminsSid)
    foreach ($trustedSid in @($systemSid, $adminsSid)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $trustedSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $noneInheritance,
            $nonePropagation,
            $allow
        ))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $usersSid,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $noneInheritance,
        $nonePropagation,
        $allow
    ))
    Set-Acl -LiteralPath $item.FullName -AclObject $acl -ErrorAction Stop
    $verifiedItem = Assert-RegularLocalPath $item.FullName $Context
    Assert-TrustedGpuZWriteBoundary $verifiedItem $Context
    Assert-UsersReadExecuteAccess $verifiedItem.FullName $Context
    return $verifiedItem
}

function Initialize-AdminSystemDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowUsersReadExecute
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $programData = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if (-not $fullPath.StartsWith(
            $programData + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Protected state directory must be below ProgramData: $fullPath"
    }
    $programDataItem = Get-Item -LiteralPath $programData -Force -ErrorAction Stop
    if (-not $programDataItem.PSIsContainer -or
        ($programDataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ProgramData is not a safe local directory: $programData"
    }
    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Protected state path is not a regular directory: $fullPath"
        }
    } else {
        New-Item -Path $fullPath -ItemType Directory -ErrorAction Stop | Out-Null
    }

    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $adminsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($adminsSid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $systemSid, $rights, $inheritance, $propagation, $allow
    ))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $adminsSid, $rights, $inheritance, $propagation, $allow
    ))
    if ($AllowUsersReadExecute) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $usersSid,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance, $propagation, $allow
        ))
    }
    Set-Acl -LiteralPath $fullPath -AclObject $acl -ErrorAction Stop

    $verifiedItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    $verifiedAcl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
    if (($verifiedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not $verifiedAcl.AreAccessRulesProtected) {
        throw "Protected state ACL/reparse verification failed: $fullPath"
    }
    $allowedSids = @($systemSid.Value, $adminsSid.Value)
    if ($AllowUsersReadExecute) {
        $allowedSids += $usersSid.Value
    }
    $dangerousRights = [int64](
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $usersHaveReadExecute = $false
    $rules = @($verifiedAcl.GetAccessRules(
        $true, $true, [Security.Principal.SecurityIdentifier]
    ))
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq $allow -and
            $allowedSids -notcontains $rule.IdentityReference.Value) {
            throw "Unexpected allow ACE remains on protected state directory: $fullPath"
        }
        if ($rule.AccessControlType -eq $allow -and
            $rule.IdentityReference.Value -ceq $usersSid.Value) {
            if (([int64]$rule.FileSystemRights -band $dangerousRights) -ne 0) {
                throw "Users retain write/delete/control rights on protected application directory: $fullPath"
            }
            if (([int64]$rule.FileSystemRights -band
                    [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq
                    [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute) {
                $usersHaveReadExecute = $true
            }
        }
    }
    if ($AllowUsersReadExecute -and -not $usersHaveReadExecute) {
        throw "Users ReadAndExecute ACL is missing from protected application directory: $fullPath"
    }
    return $fullPath
}

function Assert-ProtectedAdminSystemDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AllowUsersReadExecute
    )
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $programData = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if (-not $fullPath.StartsWith(
            $programData + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must be below ProgramData: $fullPath"
    }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context is not a regular directory: $fullPath"
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($item.FullName))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
        throw "$Context is not on a fixed local disk: $fullPath"
    }
    $ancestor = $item
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context is below a reparse-point directory: $fullPath"
        }
        $ancestor = $ancestor.Parent
    }

    $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) {
        throw "$Context does not protect its ACL from inheritance: $fullPath"
    }
    $usersSid = 'S-1-5-32-545'
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    if ($AllowUsersReadExecute) {
        $allowedSids += $usersSid
    }
    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        try {
            $ownerSid =
                ([Security.Principal.SecurityIdentifier]$acl.Owner).Value
        } catch {
            throw "Cannot resolve the owner of ${Context}: $fullPath"
        }
    }
    if ($allowedSids -notcontains $ownerSid) {
        throw "$Context has an untrusted owner '$ownerSid': $fullPath"
    }
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $dangerousRights = [int64](
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $usersHaveReadExecute = $false
    $rules = @($acl.GetAccessRules(
        $true, $true, [Security.Principal.SecurityIdentifier]
    ))
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq $allow -and
            $allowedSids -notcontains $rule.IdentityReference.Value) {
            throw "$Context has an unexpected allow ACE for " +
                "'$($rule.IdentityReference.Value)': $fullPath"
        }
        if ($rule.AccessControlType -eq $allow -and
            $rule.IdentityReference.Value -ceq $usersSid) {
            if (([int64]$rule.FileSystemRights -band $dangerousRights) -ne 0) {
                throw "$Context grants Users write/delete/control rights: $fullPath"
            }
            if (([int64]$rule.FileSystemRights -band
                    [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq
                    [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute) {
                $usersHaveReadExecute = $true
            }
        }
    }
    if ($AllowUsersReadExecute -and -not $usersHaveReadExecute) {
        throw "$Context lacks explicit Users ReadAndExecute rights: $fullPath"
    }
    Write-Pass "$Context is a protected non-reparse ProgramData directory."
    return $item.FullName
}

function Initialize-ProtectedState {
    $vmProfileRoot = Join-Path $env:ProgramData 'QemuVmProfile'
    foreach ($path in @(
        $InstallRoot,
        $BackupRoot,
        $VersionRoot,
        $vmProfileRoot,
        (Join-Path $vmProfileRoot 'versions')
    )) {
        $null = Initialize-AdminSystemDirectory $path
    }
    $null = Initialize-AdminSystemDirectory $ApplicationsRoot `
        -AllowUsersReadExecute
    foreach ($root in @($InstallRoot, $vmProfileRoot)) {
        $reparse = @(Get-ChildItem -LiteralPath $root -Force -Recurse `
            -ErrorAction Stop | Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            })
        if ($reparse.Count -ne 0) {
            throw "Protected task state contains a reparse point: $($reparse[0].FullName)"
        }
    }
    Write-Pass 'ProgramData task state is non-reparse and writable only by SYSTEM/Administrators.'
}

function Read-And-VerifyBundle {
    foreach ($required in @($ReadyPath, $ManifestPath, $ContractPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Bundle asset is missing: $required"
        }
        $null = Assert-RegularLocalPath $required 'bundle asset'
    }

    $readyLines = @(Get-Content -LiteralPath $ReadyPath -ErrorAction Stop)
    if ($readyLines.Count -ne 2 -or
        $readyLines[0] -cne 'schema_version=1' -or
        $readyLines[1] -notmatch '^manifest_sha256=([0-9A-F]{64})$') {
        throw 'READY is malformed or uses an unsupported schema.'
    }
    $expectedManifestHash = $Matches[1]
    $actualManifestHash = Get-Sha256 $ManifestPath
    if ($actualManifestHash -cne $expectedManifestHash) {
        throw "Bundle manifest hash mismatch: $actualManifestHash != $expectedManifestHash"
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Bundle manifest is not valid JSON: $($_.Exception.Message)"
    }
    $manifestSchema = ConvertTo-StrictInt `
        (Get-RequiredProperty $manifest 'schemaVersion' 'manifest') `
        'manifest.schemaVersion' 1 4
    if ($manifestSchema -eq 1) {
        Assert-AllowedProperties $manifest @(
            'schemaVersion', 'vmId', 'files'
        ) 'manifest'
        $null = ConvertTo-StrictInt `
            (Get-RequiredProperty $manifest 'vmId' 'manifest') `
            'manifest.vmId' 1 2147483647
    } elseif ($manifestSchema -eq 2) {
        Assert-AllowedProperties $manifest @(
            'schemaVersion', 'bindingMode', 'files'
        ) 'manifest'
        $bindingMode = ConvertTo-StrictString `
            (Get-RequiredProperty $manifest 'bindingMode' 'manifest') `
            'manifest.bindingMode' 13 '^portable-auto$'
        if ($bindingMode -cne 'portable-auto') {
            throw 'Portable manifest binding mode is not canonical.'
        }
    } elseif ($manifestSchema -eq 3) {
        Assert-AllowedProperties $manifest @(
            'schemaVersion', 'bindingMode', 'files', 'externalFiles'
        ) 'manifest'
        $bindingMode = ConvertTo-StrictString `
            (Get-RequiredProperty $manifest 'bindingMode' 'manifest') `
            'manifest.bindingMode' 13 '^portable-auto$'
        if ($bindingMode -cne 'portable-auto') {
            throw 'External-sibling manifest binding mode is not canonical.'
        }
    } elseif ($manifestSchema -eq 4) {
        Assert-AllowedProperties $manifest @(
            'schemaVersion', 'bindingMode', 'files',
            'optionalExternalFiles'
        ) 'manifest'
        $bindingMode = ConvertTo-StrictString `
            (Get-RequiredProperty $manifest 'bindingMode' 'manifest') `
            'manifest.bindingMode' 13 '^portable-auto$'
        if ($bindingMode -cne 'portable-auto') {
            throw 'Optional-GPU-Z manifest binding mode is not canonical.'
        }
    } else {
        throw 'Unsupported manifest schema.'
    }
    $files = @(Get-RequiredProperty $manifest 'files' 'manifest')
    if ($files.Count -lt 8 -or $files.Count -gt 64) {
        throw "Unexpected manifest file count: $($files.Count)"
    }
    $seen = @{}
    foreach ($file in $files) {
        Assert-AllowedProperties $file @('name', 'sha256', 'bytes') 'manifest.files[]'
        $name = ConvertTo-StrictString `
            (Get-RequiredProperty $file 'name' 'manifest.files[]') `
            'manifest.files[].name' 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        if ($name.Contains('..') -or $seen.ContainsKey($name)) {
            throw "Unsafe or duplicate manifest file name: $name"
        }
        $seen[$name] = $true
        $expectedHash = ConvertTo-StrictString `
            (Get-RequiredProperty $file 'sha256' 'manifest.files[]') `
            'manifest.files[].sha256' 64 '^[0-9A-F]{64}$'
        $expectedBytes = ConvertTo-StrictInt `
            (Get-RequiredProperty $file 'bytes' 'manifest.files[]') `
            'manifest.files[].bytes' 1 268435456
        $path = Join-Path $BundleRoot $name
        $item = Assert-RegularLocalPath $path "manifest asset '$name'"
        if ([int64]$item.Length -ne $expectedBytes) {
            throw "Bundle asset size mismatch for $name."
        }
        $actualHash = Get-Sha256 $path
        if ($actualHash -cne $expectedHash) {
            throw "Bundle asset SHA256 mismatch for $name."
        }
    }
    $externalFiles = @()
    if ($manifestSchema -eq 3 -or $manifestSchema -eq 4) {
        $externalProperty = if ($manifestSchema -eq 4) {
            'optionalExternalFiles'
        } else {
            'externalFiles'
        }
        $externalContext = "manifest.$externalProperty[]"
        $externalFiles = @(
            Get-RequiredProperty $manifest $externalProperty 'manifest'
        )
        if ($externalFiles.Count -ne 1) {
            throw 'Portable manifest must declare exactly one GPU-Z sibling.'
        }
        foreach ($file in $externalFiles) {
            Assert-AllowedProperties $file @('name', 'sha256', 'bytes') `
                $externalContext
            $name = ConvertTo-StrictString `
                (Get-RequiredProperty $file 'name' `
                    $externalContext) `
                "$externalContext.name" 128 `
                '^[A-Za-z0-9][A-Za-z0-9._-]*$'
            if ($name.Contains('..') -or $seen.ContainsKey($name)) {
                throw "Unsafe or duplicate external file name: $name"
            }
            $seen[$name] = $true
            $expectedHash = ConvertTo-StrictString `
                (Get-RequiredProperty $file 'sha256' `
                    $externalContext) `
                "$externalContext.sha256" 64 '^[0-9A-F]{64}$'
            $expectedBytes = ConvertTo-StrictInt `
                (Get-RequiredProperty $file 'bytes' `
                    $externalContext) `
                "$externalContext.bytes" 1 268435456
            if ($name -cne 'GPU-Z.exe' -or $expectedBytes -ne 11642144 -or
                $expectedHash -cne
                    '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29') {
                throw 'The declared optional sibling is not the audited GPU-Z 2.70 image.'
            }
            $path = Join-Path $BundleRoot $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Assert-RegularLocalPath $path `
                    "protected external snapshot '$name'"
                if ([int64]$item.Length -ne $expectedBytes -or
                    (Get-Sha256 $path) -cne $expectedHash) {
                    throw "External snapshot size/SHA256 mismatch for $name."
                }
            }
        }
    }
    foreach ($requiredName in @(
        'apply-vm-profile.ps1', 'patch-grid-strings.ps1',
        'apply-gpuz-profile.ps1',
        'nvapi.dll', 'nvapi_profile_probe32.exe', 'gpuz-contract.json',
        'GPU-Z.exe'
    )) {
        if (-not $seen.ContainsKey($requiredName)) {
            throw "Required asset is not covered by the manifest: $requiredName"
        }
    }
    $allowedRootNames = @('READY', 'bundle-manifest.json') +
        @($files | ForEach-Object { [string]$_.name })
    foreach ($externalFile in $externalFiles) {
        $externalName = [string]$externalFile.name
        if (Test-Path -LiteralPath (Join-Path $BundleRoot $externalName) `
                -PathType Leaf) {
            $allowedRootNames += $externalName
        }
    }
    $rootItems = @(Get-ChildItem -LiteralPath $BundleRoot -Force -ErrorAction Stop)
    if ($rootItems.Count -ne $allowedRootNames.Count) {
        throw 'Bundle root contains an unmanifested file or directory.'
    }
    foreach ($rootItem in $rootItems) {
        if ($rootItem.PSIsContainer -or
            $allowedRootNames -cnotcontains [string]$rootItem.Name) {
            throw "Bundle root contains a forbidden entry: $($rootItem.Name)"
        }
    }
    Write-Pass (("all {0} embedded assets and {1} declared GPU-Z " +
        "asset(s) match the manifest.") -f $files.Count, $externalFiles.Count)
    return $manifest
}

function Read-And-ValidatePortableContract {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$RawContract
    )
    $rawContractSchema = ConvertTo-StrictInt `
        (Get-RequiredProperty $RawContract 'schemaVersion' 'contract') `
        'contract.schemaVersion' 3 4
    $expectedManifestSchema = if ($rawContractSchema -eq 4) { 3 } else { 2 }
    $allowedManifestProperties = @('schemaVersion', 'bindingMode', 'files')
    if ($expectedManifestSchema -eq 3) {
        $allowedManifestProperties += 'externalFiles'
    }
    Assert-AllowedProperties $Manifest $allowedManifestProperties `
        'portable manifest'
    if ([int](Get-RequiredProperty $Manifest 'schemaVersion' 'manifest') -ne
            $expectedManifestSchema -or
        [string](Get-RequiredProperty $Manifest 'bindingMode' 'manifest') -cne
            'portable-auto') {
        throw 'Portable contract requires the portable-auto manifest schema.'
    }

    Assert-AllowedProperties $RawContract @(
        'schemaVersion', 'bindingMode', 'spoofMode', 'catalogSha256',
        'expectedPnpId', 'expectedDriverVersion', 'profiles', 'gpuz',
        'appLocal'
    ) 'contract'
    if ($rawContractSchema -ne 3 -and $rawContractSchema -ne 4) {
        throw 'Unsupported portable contract schema.'
    }
    $bindingMode = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'bindingMode' 'contract') `
        'contract.bindingMode' 13 '^portable-auto$'
    $mode = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'spoofMode' 'contract') `
        'contract.spoofMode' 1 '^B$'
    if ($bindingMode -cne 'portable-auto' -or $mode -cne 'B') {
        throw 'The portable contract is restricted to B/native mode.'
    }
    $catalogSha256 = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'catalogSha256' 'contract') `
        'contract.catalogSha256' 64 '^[0-9A-F]{64}$'
    $expectedPnp = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'expectedPnpId' 'contract') `
        'contract.expectedPnpId' 64 '^PCI\\VEN_10DE&DEV_1E30$'
    $driverVersion = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'expectedDriverVersion' 'contract') `
        'contract.expectedDriverVersion' 32 '^[0-9]+(\.[0-9]+){3}$'
    if ($expectedPnp -cne 'PCI\VEN_10DE&DEV_1E30' -or
        $driverVersion -cne '31.0.15.3833') {
        throw 'Portable mode accepts only native DEV_1E30 / GRID 538.33.'
    }

    $expectedProfiles = [ordered]@{
        gtx750ti_2gb = 'NVIDIA GeForce GTX 750 Ti'
        gt1030_2gb = 'NVIDIA GeForce GT 1030'
        gtx1050_2gb = 'NVIDIA GeForce GTX 1050'
    }
    $rawProfiles = @(Get-RequiredProperty $RawContract 'profiles' 'contract')
    if ($rawProfiles.Count -ne $expectedProfiles.Count) {
        throw "Portable contract must contain exactly $($expectedProfiles.Count) profiles."
    }
    $profiles = @()
    $seenKeys = @{}
    $seenNames = @{}
    $seenAssets = @{}
    $manifestFiles = @(Get-RequiredProperty $Manifest 'files' 'manifest')
    foreach ($rawProfile in $rawProfiles) {
        Assert-AllowedProperties $rawProfile @(
            'key', 'canonicalDisplayName', 'asset'
        ) 'contract.profiles[]'
        $key = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'key' 'contract.profiles[]') `
            'contract.profiles[].key' 64 '^[a-z0-9][a-z0-9_]*$'
        $canonicalName = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'canonicalDisplayName' `
                'contract.profiles[]') `
            'contract.profiles[].canonicalDisplayName' 31 `
            '^NVIDIA [A-Za-z0-9][\x20-\x7E]{0,22}$'
        if (-not $expectedProfiles.Contains($key) -or
            $key -cne ([string]$key).ToLowerInvariant() -or
            $canonicalName -cne [string]$expectedProfiles[$key]) {
            throw "Unknown or non-canonical portable profile '$key' / '$canonicalName'."
        }
        if ($seenKeys.ContainsKey($key) -or
            $seenNames.ContainsKey($canonicalName)) {
            throw 'Portable profile keys and display names must be unique.'
        }
        $seenKeys[$key] = $true
        $seenNames[$canonicalName] = $true

        $asset = Get-RequiredProperty $rawProfile 'asset' 'contract.profiles[]'
        Assert-AllowedProperties $asset @('name', 'sha256') `
            'contract.profiles[].asset'
        $assetName = ConvertTo-StrictString `
            (Get-RequiredProperty $asset 'name' 'contract.profiles[].asset') `
            'contract.profiles[].asset.name' 128 `
            '^profile-[a-z0-9_]+\.json$'
        $assetHash = ConvertTo-StrictString `
            (Get-RequiredProperty $asset 'sha256' 'contract.profiles[].asset') `
            'contract.profiles[].asset.sha256' 64 '^[0-9A-F]{64}$'
        if ($assetName -cne "profile-$key.json" -or
            $seenAssets.ContainsKey($assetName)) {
            throw "Portable profile asset name is ambiguous: $assetName"
        }
        $seenAssets[$assetName] = $true
        $profilePath = Join-Path $BundleRoot $assetName
        if ((Get-Sha256 $profilePath) -cne $assetHash) {
            throw "Portable profile hash mismatch: $assetName"
        }
        $manifestRows = @($manifestFiles | Where-Object {
            [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') -ceq
                $assetName
        })
        if ($manifestRows.Count -ne 1 -or
            [string](Get-RequiredProperty $manifestRows[0] 'sha256' `
                'manifest.files[]') -cne $assetHash) {
            throw "Manifest does not uniquely bind portable profile $assetName."
        }
        $profiles += [pscustomobject]@{
            Key = $key
            CanonicalDisplayName = $canonicalName
            Path = $profilePath
            Sha256 = $assetHash
        }
    }
    foreach ($expectedKey in $expectedProfiles.Keys) {
        if (-not $seenKeys.ContainsKey($expectedKey)) {
            throw "Portable contract is missing profile '$expectedKey'."
        }
    }

    $gpuz = Get-RequiredProperty $RawContract 'gpuz' 'contract'
    $allowedGpuZProperties = @('name', 'bytes', 'productVersion', 'sha256')
    if ($rawContractSchema -eq 4) {
        $allowedGpuZProperties += 'delivery'
    }
    Assert-AllowedProperties $gpuz $allowedGpuZProperties 'contract.gpuz'
    $gpuzName = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'name' 'contract.gpuz') `
        'contract.gpuz.name' 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    $gpuzBytes = ConvertTo-StrictInt `
        (Get-RequiredProperty $gpuz 'bytes' 'contract.gpuz') `
        'contract.gpuz.bytes' 1 268435456
    $gpuzVersion = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'productVersion' 'contract.gpuz') `
        'contract.gpuz.productVersion' 32 '^[0-9]+(\.[0-9]+){2}$'
    $gpuzSha256 = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'sha256' 'contract.gpuz') `
        'contract.gpuz.sha256' 64 '^[0-9A-F]{64}$'
    if ($gpuzName -cne 'GPU-Z.exe' -or $gpuzBytes -ne 11642144 -or
        $gpuzVersion -cne '2.70.0' -or
        $gpuzSha256 -cne
            '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29') {
        throw 'Portable contract does not select the audited GPU-Z 2.70 image.'
    }
    $gpuzDelivery = 'embedded'
    $gpuZManifestSource = $manifestFiles
    if ($rawContractSchema -eq 4) {
        $gpuzDelivery = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuz 'delivery' 'contract.gpuz') `
            'contract.gpuz.delivery' 32 '^external-sibling$'
        if ($gpuzDelivery -cne 'external-sibling') {
            throw 'Portable GPU-Z delivery mode is not external-sibling.'
        }
        $gpuZManifestSource = @(
            Get-RequiredProperty $Manifest 'externalFiles' 'manifest'
        )
        if (@($manifestFiles | Where-Object {
                [string](Get-RequiredProperty $_ 'name' `
                    'manifest.files[]') -ceq $gpuzName
            }).Count -ne 0) {
            throw 'External GPU-Z must not also be embedded in manifest.files.'
        }
    }
    $manifestGpuZ = @($gpuZManifestSource | Where-Object {
        [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') -ceq
            $gpuzName
    })
    if ($manifestGpuZ.Count -ne 1 -or
        [string](Get-RequiredProperty $manifestGpuZ[0] 'sha256' `
            'manifest.files[]') -cne $gpuzSha256 -or
        [int64](Get-RequiredProperty $manifestGpuZ[0] 'bytes' `
            'manifest.files[]') -ne $gpuzBytes) {
        throw 'Manifest GPU-Z metadata does not match the portable contract.'
    }

    $appLocal = Get-RequiredProperty $RawContract 'appLocal' 'contract'
    Assert-AllowedProperties $appLocal @(
        'shimName', 'shimSha256', 'probeName', 'probeSha256'
    ) 'contract.appLocal'
    foreach ($nameProperty in @('shimName', 'probeName')) {
        $value = ConvertTo-StrictString `
            (Get-RequiredProperty $appLocal $nameProperty 'contract.appLocal') `
            "contract.appLocal.$nameProperty" 128 `
            '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        if ($value.Contains('..')) {
            throw "Unsafe app-local asset name: $value"
        }
    }
    foreach ($hashProperty in @('shimSha256', 'probeSha256')) {
        $null = ConvertTo-StrictString `
            (Get-RequiredProperty $appLocal $hashProperty 'contract.appLocal') `
            "contract.appLocal.$hashProperty" 64 '^[0-9A-F]{64}$'
    }

    return [pscustomobject]@{
        BindingMode = 'portable-auto'
        VmId = $null
        VmUuid = $null
        SpoofMode = 'B'
        GpuProfile = $null
        CatalogSha256 = $catalogSha256
        Profiles = $profiles
        ProfilePath = $null
        ExpectedPnpId = $expectedPnp
        ExpectedDriverVersion = $driverVersion
        FirmwareClaim = $null
        FirmwareClaimSha256 = $null
        GpuZName = $gpuzName
        GpuZBytes = [int64]$gpuzBytes
        GpuZProductVersion = $gpuzVersion
        GpuZSha256 = $gpuzSha256
        GpuZDelivery = $gpuzDelivery
        GpuZSourcePath = Join-Path $BundleRoot $gpuzName
        GpuZApplicationDirectory = Join-Path $ApplicationsRoot (
            '{0}-{1}' -f $gpuzVersion, $gpuzSha256.Substring(0, 16)
        )
        ShimPath = Join-Path $BundleRoot ([string]$appLocal.shimName)
        ShimSha256 = [string]$appLocal.shimSha256
        ProbePath = Join-Path $BundleRoot ([string]$appLocal.probeName)
        ProbeSha256 = [string]$appLocal.probeSha256
    }
}

function Read-And-ValidatePortableIdentityContract {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$RawContract
    )
    $identitySchema = ConvertTo-StrictInt `
        (Get-RequiredProperty $RawContract 'schemaVersion' 'contract') `
        'contract.schemaVersion' 5 7
    $expectedManifestSchema = if ($identitySchema -ge 6) { 4 } else { 3 }
    $externalProperty = if ($identitySchema -ge 6) {
        'optionalExternalFiles'
    } else {
        'externalFiles'
    }
    Assert-AllowedProperties $Manifest @(
        'schemaVersion', 'bindingMode', 'files', $externalProperty
    ) 'portable identity manifest'
    if ([int](Get-RequiredProperty $Manifest 'schemaVersion' 'manifest') -ne
            $expectedManifestSchema -or
        [string](Get-RequiredProperty $Manifest 'bindingMode' 'manifest') -cne
            'portable-auto') {
        throw "Schema-$identitySchema identity contract requires portable manifest schema $expectedManifestSchema."
    }
    $allowedContractProperties = @(
        'schemaVersion', 'bindingMode', 'spoofMode', 'catalogSha256',
        'expectedPnpId', 'expectedDriverVersion', 'catalog', 'profiles',
        'gpuz', 'appLocal'
    )
    if ($identitySchema -eq 7) {
        $allowedContractProperties += 'licenseToken'
    }
    Assert-AllowedProperties $RawContract $allowedContractProperties `
        'identity contract'
    if ([string](Get-RequiredProperty $RawContract 'bindingMode' 'contract') -cne
            'portable-auto' -or
        [string](Get-RequiredProperty $RawContract 'spoofMode' 'contract') -cne 'B') {
        throw "Unsupported schema-$identitySchema portable identity contract header."
    }
    $catalogSha256 = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'catalogSha256' 'contract') `
        'contract.catalogSha256' 64 '^[0-9A-F]{64}$'
    $expectedPnp = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'expectedPnpId' 'contract') `
        'contract.expectedPnpId' 64 '^PCI\\VEN_10DE&DEV_1E30$'
    $driverVersion = ConvertTo-StrictString `
        (Get-RequiredProperty $RawContract 'expectedDriverVersion' 'contract') `
        'contract.expectedDriverVersion' 32 '^[0-9]+(\.[0-9]+){3}$'
    if ($expectedPnp -cne 'PCI\VEN_10DE&DEV_1E30' -or
        $driverVersion -cne '31.0.15.3833') {
        throw 'Portable identity mode accepts only native DEV_1E30 / GRID 538.33.'
    }

    $manifestFiles = @(Get-RequiredProperty $Manifest 'files' 'manifest')
    $catalogAsset = Get-RequiredProperty $RawContract 'catalog' 'contract'
    Assert-AllowedProperties $catalogAsset @('name', 'sha256', 'bytes') `
        'contract.catalog'
    $catalogName = ConvertTo-StrictString `
        (Get-RequiredProperty $catalogAsset 'name' 'contract.catalog') `
        'contract.catalog.name' 128 '^vgpu-profile-catalog\.json$'
    $catalogAssetSha256 = ConvertTo-StrictString `
        (Get-RequiredProperty $catalogAsset 'sha256' 'contract.catalog') `
        'contract.catalog.sha256' 64 '^[0-9A-F]{64}$'
    $catalogBytes = ConvertTo-StrictInt `
        (Get-RequiredProperty $catalogAsset 'bytes' 'contract.catalog') `
        'contract.catalog.bytes' 1 1048576
    $catalogPath = Join-Path $BundleRoot $catalogName
    $catalogItem = Assert-RegularLocalPath $catalogPath 'schema-2 identity catalog'
    if ([int64]$catalogItem.Length -ne $catalogBytes -or
        (Get-Sha256 $catalogPath) -cne $catalogAssetSha256) {
        throw 'Schema-2 identity catalog size/hash mismatch.'
    }
    $catalogManifestRows = @($manifestFiles | Where-Object {
        [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') -ceq
            $catalogName
    })
    if ($catalogManifestRows.Count -ne 1 -or
        [string](Get-RequiredProperty $catalogManifestRows[0] 'sha256' `
            'manifest.files[]') -cne $catalogAssetSha256 -or
        [int64](Get-RequiredProperty $catalogManifestRows[0] 'bytes' `
            'manifest.files[]') -ne $catalogBytes) {
        throw 'Manifest does not uniquely bind the schema-2 identity catalog.'
    }
    try {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Schema-2 identity catalog is invalid JSON: $($_.Exception.Message)"
    }
    Assert-AllowedProperties $catalog @(
        'schemaVersion', 'catalogSha256', 'identityMode', 'transportPnpId',
        'profiles'
    ) 'identity catalog'
    if ([int]$catalog.schemaVersion -ne 2 -or
        [string]$catalog.catalogSha256 -cne $catalogSha256 -or
        [string]$catalog.identityMode -cne 'protected-user-mode' -or
        [string]$catalog.transportPnpId -cne $expectedPnp) {
        throw 'Identity catalog header conflicts with the portable/firmware contract.'
    }

    $catalogProfiles = @($catalog.profiles)
    $rawProfiles = @(Get-RequiredProperty $RawContract 'profiles' 'contract')
    if ($catalogProfiles.Count -lt 1 -or $catalogProfiles.Count -gt 64 -or
        $rawProfiles.Count -ne $catalogProfiles.Count) {
        throw 'Portable identity contract and schema-2 catalog profile counts differ.'
    }
    $profiles = @()
    $seenKeys = @{}
    $seenAssets = @{}
    foreach ($rawProfile in $rawProfiles) {
        Assert-AllowedProperties $rawProfile @(
            'key', 'canonicalDisplayName', 'boardBrand', 'boardModel',
            'memoryMakerName', 'asset'
        ) 'contract.profiles[]'
        $key = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'key' 'contract.profiles[]') `
            'contract.profiles[].key' 64 '^[a-z0-9][a-z0-9_]*$'
        $canonicalName = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'canonicalDisplayName' `
                'contract.profiles[]') `
            'contract.profiles[].canonicalDisplayName' 31 `
            '^NVIDIA [A-Za-z0-9][\x20-\x7E]{0,22}$'
        $boardBrand = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'boardBrand' `
                'contract.profiles[]') `
            'contract.profiles[].boardBrand' 31 `
            '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,30}$'
        $boardModel = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'boardModel' `
                'contract.profiles[]') `
            'contract.profiles[].boardModel' 31 `
            '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,30}$'
        $memoryMakerName = ConvertTo-StrictString `
            (Get-RequiredProperty $rawProfile 'memoryMakerName' `
                'contract.profiles[]') `
            'contract.profiles[].memoryMakerName' 31 `
            '^(Samsung|Elpida|SK hynix|Micron)$'
        $matches = @($catalogProfiles | Where-Object {
            [string]$_.profile -ceq $key
        })
        if ($matches.Count -ne 1 -or
            [string]$matches[0].name -cne $canonicalName -or
            [string]$matches[0].boardBrand -cne $boardBrand -or
            [string]$matches[0].boardModel -cne $boardModel -or
            [string]$matches[0].memoryMakerName -cne $memoryMakerName -or
            $seenKeys.ContainsKey($key)) {
            throw "Portable identity '$key' is missing, duplicated, or split across rows."
        }
        $seenKeys[$key] = $true

        $asset = Get-RequiredProperty $rawProfile 'asset' 'contract.profiles[]'
        Assert-AllowedProperties $asset @('name', 'sha256') `
            'contract.profiles[].asset'
        $assetName = ConvertTo-StrictString `
            (Get-RequiredProperty $asset 'name' 'contract.profiles[].asset') `
            'contract.profiles[].asset.name' 128 `
            '^profile-[a-z0-9_]+\.json$'
        $assetHash = ConvertTo-StrictString `
            (Get-RequiredProperty $asset 'sha256' 'contract.profiles[].asset') `
            'contract.profiles[].asset.sha256' 64 '^[0-9A-F]{64}$'
        if ($assetName -cne "profile-$key.json" -or
            $seenAssets.ContainsKey($assetName)) {
            throw "Portable profile asset name is ambiguous: $assetName"
        }
        $seenAssets[$assetName] = $true
        $profilePath = Join-Path $BundleRoot $assetName
        if ((Get-Sha256 $profilePath) -cne $assetHash) {
            throw "Portable profile hash mismatch: $assetName"
        }
        $manifestRows = @($manifestFiles | Where-Object {
            [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') -ceq
                $assetName
        })
        if ($manifestRows.Count -ne 1 -or
            [string](Get-RequiredProperty $manifestRows[0] 'sha256' `
                'manifest.files[]') -cne $assetHash) {
            throw "Manifest does not uniquely bind portable profile $assetName."
        }
        $profiles += [pscustomobject]@{
            Key = $key
            CanonicalDisplayName = $canonicalName
            BoardBrand = $boardBrand
            BoardModel = $boardModel
            MemoryMakerName = $memoryMakerName
            CatalogGpu = $matches[0]
            Path = $profilePath
            Sha256 = $assetHash
        }
    }
    foreach ($catalogGpu in $catalogProfiles) {
        if (-not $seenKeys.ContainsKey([string]$catalogGpu.profile)) {
            throw "Portable contract omits catalog profile '$($catalogGpu.profile)'."
        }
    }

    $gpuz = Get-RequiredProperty $RawContract 'gpuz' 'contract'
    Assert-AllowedProperties $gpuz @(
        'name', 'bytes', 'productVersion', 'sha256', 'delivery'
    ) 'contract.gpuz'
    $gpuzName = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'name' 'contract.gpuz') `
        'contract.gpuz.name' 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    $gpuzBytes = ConvertTo-StrictInt `
        (Get-RequiredProperty $gpuz 'bytes' 'contract.gpuz') `
        'contract.gpuz.bytes' 1 268435456
    $gpuzVersion = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'productVersion' 'contract.gpuz') `
        'contract.gpuz.productVersion' 32 '^[0-9]+(\.[0-9]+){2}$'
    $gpuzSha256 = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'sha256' 'contract.gpuz') `
        'contract.gpuz.sha256' 64 '^[0-9A-F]{64}$'
    $expectedGpuZDelivery = if ($identitySchema -ge 6) {
        'optional-explicit-sibling'
    } else {
        'external-sibling'
    }
    if ($gpuzName -cne 'GPU-Z.exe' -or $gpuzBytes -ne 11642144 -or
        $gpuzVersion -cne '2.70.0' -or
        $gpuzSha256 -cne
            '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29' -or
        [string](Get-RequiredProperty $gpuz 'delivery' 'contract.gpuz') -cne
            $expectedGpuZDelivery) {
        throw "Schema-$identitySchema contract does not declare the audited optional GPU-Z 2.70 image."
    }
    $externalContext = "manifest.$externalProperty[]"
    $externalFiles = @(
        Get-RequiredProperty $Manifest $externalProperty 'manifest'
    )
    $manifestGpuZ = @($externalFiles | Where-Object {
        [string](Get-RequiredProperty $_ 'name' $externalContext) -ceq
            $gpuzName
    })
    if ($manifestGpuZ.Count -ne 1 -or
        [string](Get-RequiredProperty $manifestGpuZ[0] 'sha256' `
            $externalContext) -cne $gpuzSha256 -or
        [int64](Get-RequiredProperty $manifestGpuZ[0] 'bytes' `
            $externalContext) -ne $gpuzBytes) {
        throw "Manifest GPU-Z metadata does not match the schema-$identitySchema contract."
    }

    $licenseTokenPath = $null
    $licenseTokenSha256 = $null
    $licenseTokenBytes = 0L
    $licenseTokenDelivery = $null
    $licenseInstallerPath = $null
    if ($identitySchema -eq 7) {
        $licenseToken = Get-RequiredProperty $RawContract 'licenseToken' `
            'contract'
        Assert-AllowedProperties $licenseToken @(
            'name', 'sha256', 'bytes', 'delivery'
        ) 'contract.licenseToken'
        $licenseTokenName = ConvertTo-StrictString `
            (Get-RequiredProperty $licenseToken 'name' `
                'contract.licenseToken') `
            'contract.licenseToken.name' 64 `
            '^client_configuration_token\.tok$'
        $licenseTokenSha256 = ConvertTo-StrictString `
            (Get-RequiredProperty $licenseToken 'sha256' `
                'contract.licenseToken') `
            'contract.licenseToken.sha256' 64 '^[0-9A-F]{64}$'
        $licenseTokenBytes = ConvertTo-StrictInt `
            (Get-RequiredProperty $licenseToken 'bytes' `
                'contract.licenseToken') `
            'contract.licenseToken.bytes' 1024 1048576
        $licenseTokenDelivery = ConvertTo-StrictString `
            (Get-RequiredProperty $licenseToken 'delivery' `
                'contract.licenseToken') `
            'contract.licenseToken.delivery' 32 '^embedded-private$'
        $licenseTokenPath = Join-Path $BundleRoot $licenseTokenName
        $licenseTokenItem = Assert-RegularLocalPath $licenseTokenPath `
            'embedded private vGPU license token'
        if ([int64]$licenseTokenItem.Length -ne $licenseTokenBytes -or
            (Get-Sha256 $licenseTokenItem.FullName) -cne
                $licenseTokenSha256) {
            throw 'Embedded private vGPU license token size/hash mismatch.'
        }
        $tokenPrefixBytes = @(Get-Content -LiteralPath `
            $licenseTokenItem.FullName -Encoding Byte -TotalCount 256)
        $tokenPrefix = [Text.Encoding]::ASCII.GetString(
            [byte[]]$tokenPrefixBytes
        )
        if ($tokenPrefix -match '(?i)<\s*(?:!doctype\s+html|html)') {
            throw 'Embedded private vGPU license token is an HTML error page.'
        }
        $tokenRows = @($manifestFiles | Where-Object {
            [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') -ceq
                $licenseTokenName
        })
        if ($tokenRows.Count -ne 1 -or
            [string](Get-RequiredProperty $tokenRows[0] 'sha256' `
                'manifest.files[]') -cne $licenseTokenSha256 -or
            [int64](Get-RequiredProperty $tokenRows[0] 'bytes' `
                'manifest.files[]') -ne $licenseTokenBytes) {
            throw 'Manifest does not uniquely bind the private vGPU license token.'
        }

        $licenseInstallerName = 'install-vgpu-license.ps1'
        $licenseInstallerPath = Join-Path $BundleRoot $licenseInstallerName
        $null = Assert-RegularLocalPath $licenseInstallerPath `
            'embedded private vGPU license installer'
        $installerRows = @($manifestFiles | Where-Object {
            [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') -ceq
                $licenseInstallerName
        })
        if ($installerRows.Count -ne 1) {
            throw 'Manifest does not uniquely bind the private vGPU license installer.'
        }
    }

    $appLocal = Get-RequiredProperty $RawContract 'appLocal' 'contract'
    Assert-AllowedProperties $appLocal @(
        'shimName', 'shimSha256', 'probeName', 'probeSha256',
        'queryName', 'querySha256'
    ) 'contract.appLocal'
    foreach ($nameProperty in @('shimName', 'probeName', 'queryName')) {
        $value = ConvertTo-StrictString `
            (Get-RequiredProperty $appLocal $nameProperty 'contract.appLocal') `
            "contract.appLocal.$nameProperty" 128 `
            '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        if ($value.Contains('..')) {
            throw "Unsafe app-local asset name: $value"
        }
    }
    if ([string]$appLocal.queryName -cne 'VgpuIdentityQuery.exe') {
        throw 'The identity contract does not select the authoritative query image.'
    }
    foreach ($hashProperty in @(
        'shimSha256', 'probeSha256', 'querySha256'
    )) {
        $null = ConvertTo-StrictString `
            (Get-RequiredProperty $appLocal $hashProperty 'contract.appLocal') `
            "contract.appLocal.$hashProperty" 64 '^[0-9A-F]{64}$'
    }
    # Schemas 6/7 install the identity runtime without requiring GPU-Z. Keep a
    # deterministic protected generation that also includes the optional
    # audited GPU-Z hash, so a future reviewed version cannot collide with it.
    $applicationGeneration = if ($identitySchema -ge 6) {
        'identity-{0}-{1}-{2}-{3}' -f `
            $catalogSha256.Substring(0, 16), `
            ([string]$appLocal.shimSha256).Substring(0, 16), `
            ([string]$appLocal.querySha256).Substring(0, 16), `
            $gpuzSha256.Substring(0, 16)
    } else {
        '{0}-{1}-{2}-{3}' -f `
            $gpuzVersion, $gpuzSha256.Substring(0, 16), `
            ([string]$appLocal.shimSha256).Substring(0, 16), `
            ([string]$appLocal.querySha256).Substring(0, 16)
    }
    $applicationDirectory = Join-Path $ApplicationsRoot $applicationGeneration

    return [pscustomobject]@{
        ContractSchemaVersion = $identitySchema
        BindingMode = 'portable-auto'
        VmId = $null
        VmUuid = $null
        SpoofMode = 'B'
        GpuProfile = $null
        CatalogSha256 = $catalogSha256
        CatalogPath = $catalogPath
        CatalogAssetSha256 = $catalogAssetSha256
        Profiles = $profiles
        ProfilePath = $null
        ExpectedPnpId = $expectedPnp
        ExpectedDriverVersion = $driverVersion
        FirmwareClaim = $null
        FirmwareClaimSha256 = $null
        GpuZName = $gpuzName
        GpuZBytes = [int64]$gpuzBytes
        GpuZProductVersion = $gpuzVersion
        GpuZSha256 = $gpuzSha256
        GpuZDelivery = $expectedGpuZDelivery
        GpuZSourcePath = Join-Path $BundleRoot $gpuzName
        IdentityApplicationDirectory = $applicationDirectory
        GpuZApplicationDirectory = $applicationDirectory
        ShimPath = Join-Path $BundleRoot ([string]$appLocal.shimName)
        ShimSha256 = [string]$appLocal.shimSha256
        ProbePath = Join-Path $BundleRoot ([string]$appLocal.probeName)
        ProbeSha256 = [string]$appLocal.probeSha256
        QueryPath = Join-Path $BundleRoot ([string]$appLocal.queryName)
        QuerySha256 = [string]$appLocal.querySha256
        LicenseTokenPath = $licenseTokenPath
        LicenseTokenSha256 = $licenseTokenSha256
        LicenseTokenBytes = [int64]$licenseTokenBytes
        LicenseTokenDelivery = $licenseTokenDelivery
        LicenseInstallerPath = $licenseInstallerPath
    }
}

function Read-And-ValidateContract {
    param([Parameter(Mandatory = $true)][object]$Manifest)
    try {
        $contract = Get-Content -LiteralPath $ContractPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "GPU-Z contract is not valid JSON: $($_.Exception.Message)"
    }
    $contractSchema = ConvertTo-StrictInt `
        (Get-RequiredProperty $contract 'schemaVersion' 'contract') `
        'contract.schemaVersion' 2 7
    if ($contractSchema -in @(5, 6, 7)) {
        return Read-And-ValidatePortableIdentityContract $Manifest $contract
    }
    if ($contractSchema -eq 3 -or $contractSchema -eq 4) {
        return Read-And-ValidatePortableContract $Manifest $contract
    }
    Assert-AllowedProperties $contract @(
        'schemaVersion', 'vmId', 'vmUuid', 'spoofMode', 'gpuProfile',
        'expectedPnpId', 'expectedDriverVersion', 'gpuz', 'profile',
        'appLocal'
    ) 'contract'
    $schema = ConvertTo-StrictInt `
        (Get-RequiredProperty $contract 'schemaVersion' 'contract') `
        'contract.schemaVersion' 2 2
    $vmId = ConvertTo-StrictInt `
        (Get-RequiredProperty $contract 'vmId' 'contract') `
        'contract.vmId' 1 2147483647
    $manifestVmId = ConvertTo-StrictInt `
        (Get-RequiredProperty $Manifest 'vmId' 'manifest') `
        'manifest.vmId' 1 2147483647
    if ($schema -ne 2 -or $vmId -ne $manifestVmId) {
        throw 'Manifest and contract VM/schema do not match.'
    }
    $vmUuid = ConvertTo-StrictString `
        (Get-RequiredProperty $contract 'vmUuid' 'contract') `
        'contract.vmUuid' 36 `
        '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
    $mode = ConvertTo-StrictString `
        (Get-RequiredProperty $contract 'spoofMode' 'contract') `
        'contract.spoofMode' 1 '^[AB]$'
    $profileKey = ConvertTo-StrictString `
        (Get-RequiredProperty $contract 'gpuProfile' 'contract') `
        'contract.gpuProfile' 64 '^[a-z0-9][a-z0-9_]*$'
    $expectedPnp = ConvertTo-StrictString `
        (Get-RequiredProperty $contract 'expectedPnpId' 'contract') `
        'contract.expectedPnpId' 88 `
        '^PCI\\VEN_10DE&DEV_[0-9A-F]{4}(&SUBSYS_[0-9A-F]{8})?(&REV_[0-9A-F]{2})?$'
    $driverVersion = ConvertTo-StrictString `
        (Get-RequiredProperty $contract 'expectedDriverVersion' 'contract') `
        'contract.expectedDriverVersion' 32 '^[0-9]+(\.[0-9]+){3}$'
    $gpuz = Get-RequiredProperty $contract 'gpuz' 'contract'
    Assert-AllowedProperties $gpuz @(
        'name', 'bytes', 'productVersion', 'sha256'
    ) 'contract.gpuz'
    $gpuzName = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'name' 'contract.gpuz') `
        'contract.gpuz.name' 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    $gpuzBytes = ConvertTo-StrictInt `
        (Get-RequiredProperty $gpuz 'bytes' 'contract.gpuz') `
        'contract.gpuz.bytes' 1 268435456
    $gpuzVersion = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'productVersion' 'contract.gpuz') `
        'contract.gpuz.productVersion' 32 '^[0-9]+(\.[0-9]+){2}$'
    $gpuzSha256 = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuz 'sha256' 'contract.gpuz') `
        'contract.gpuz.sha256' 64 '^[0-9A-F]{64}$'
    if ($gpuzName -cne 'GPU-Z.exe' -or
        $gpuzBytes -ne 11642144 -or
        $gpuzVersion -cne '2.70.0' -or
        $gpuzSha256 -cne `
            '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29') {
        throw 'The contract does not select the statically audited standard GPU-Z 2.70.0 image.'
    }
    $manifestGpuZ = @(
        @(Get-RequiredProperty $Manifest 'files' 'manifest') |
            Where-Object {
                [string](Get-RequiredProperty $_ 'name' 'manifest.files[]') `
                    -ceq $gpuzName
            }
    )
    if ($manifestGpuZ.Count -ne 1) {
        throw 'The manifest must bind exactly one contract GPU-Z asset.'
    }
    $manifestGpuZHash = ConvertTo-StrictString `
        (Get-RequiredProperty $manifestGpuZ[0] 'sha256' 'manifest.files[]') `
        'manifest.files[].sha256' 64 '^[0-9A-F]{64}$'
    $manifestGpuZBytes = ConvertTo-StrictInt `
        (Get-RequiredProperty $manifestGpuZ[0] 'bytes' 'manifest.files[]') `
        'manifest.files[].bytes' 1 268435456
    if ($manifestGpuZHash -cne $gpuzSha256 -or
        $manifestGpuZBytes -ne $gpuzBytes) {
        throw 'The manifest GPU-Z metadata does not match contract.gpuz.'
    }
    $profileAsset = Get-RequiredProperty $contract 'profile' 'contract'
    Assert-AllowedProperties $profileAsset @('name', 'sha256') 'contract.profile'
    $profileName = ConvertTo-StrictString `
        (Get-RequiredProperty $profileAsset 'name' 'contract.profile') `
        'contract.profile.name' 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    $profileHash = ConvertTo-StrictString `
        (Get-RequiredProperty $profileAsset 'sha256' 'contract.profile') `
        'contract.profile.sha256' 64 '^[0-9A-F]{64}$'
    $profilePath = Join-Path $BundleRoot $profileName
    if ((Get-Sha256 $profilePath) -cne $profileHash) {
        throw 'Profile hash does not match the contract.'
    }

    $appLocal = Get-RequiredProperty $contract 'appLocal' 'contract'
    Assert-AllowedProperties $appLocal @(
        'shimName', 'shimSha256', 'probeName', 'probeSha256'
    ) 'contract.appLocal'
    foreach ($nameProperty in @('shimName', 'probeName')) {
        $value = ConvertTo-StrictString `
            (Get-RequiredProperty $appLocal $nameProperty 'contract.appLocal') `
            "contract.appLocal.$nameProperty" 128 '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        if ($value.Contains('..')) {
            throw "Unsafe app-local asset name: $value"
        }
    }
    foreach ($hashProperty in @('shimSha256', 'probeSha256')) {
        $null = ConvertTo-StrictString `
            (Get-RequiredProperty $appLocal $hashProperty 'contract.appLocal') `
            "contract.appLocal.$hashProperty" 64 '^[0-9A-F]{64}$'
    }

    return [pscustomobject]@{
        BindingMode = 'vm-bound'
        VmId = [int]$vmId
        VmUuid = $vmUuid
        SpoofMode = $mode
        GpuProfile = $profileKey
        CatalogSha256 = $null
        Profiles = @()
        FirmwareClaim = $null
        FirmwareClaimSha256 = $null
        ExpectedPnpId = $expectedPnp
        ExpectedDriverVersion = $driverVersion
        GpuZName = $gpuzName
        GpuZBytes = [int64]$gpuzBytes
        GpuZProductVersion = $gpuzVersion
        GpuZSha256 = $gpuzSha256
        GpuZSourcePath = Join-Path $BundleRoot $gpuzName
        GpuZApplicationDirectory = Join-Path $ApplicationsRoot (
            '{0}-{1}' -f $gpuzVersion, $gpuzSha256.Substring(0, 16)
        )
        ProfilePath = $profilePath
        ShimPath = Join-Path $BundleRoot ([string]$appLocal.shimName)
        ShimSha256 = [string]$appLocal.shimSha256
        ProbePath = Join-Path $BundleRoot ([string]$appLocal.probeName)
        ProbeSha256 = [string]$appLocal.probeSha256
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString(
            $sha.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SmbiosOemStrings {
    [byte[]]$raw = [QemuGpuZNativeSecurity]::GetRawSmbios()
    if ($raw.Length -lt 8) {
        throw 'Raw SMBIOS firmware table is truncated.'
    }
    $tableBytes = [BitConverter]::ToUInt32($raw, 4)
    if ($tableBytes -lt 6 -or $tableBytes -gt $raw.Length - 8) {
        throw 'Raw SMBIOS firmware table length is invalid.'
    }
    $cursor = 8
    $end = 8 + [int]$tableBytes
    $values = @()
    while ($cursor + 4 -le $end) {
        $type = [int]$raw[$cursor]
        $length = [int]$raw[$cursor + 1]
        if ($length -lt 4 -or $cursor + $length -gt $end) {
            throw 'SMBIOS contains a malformed structure header.'
        }
        $strings = $cursor + $length
        $terminator = $strings
        while ($terminator + 1 -lt $end -and
            -not ($raw[$terminator] -eq 0 -and
                $raw[$terminator + 1] -eq 0)) {
            $terminator++
        }
        if ($terminator + 1 -ge $end) {
            throw 'SMBIOS structure has no double-NUL terminator.'
        }
        if ($type -eq 11) {
            if ($length -lt 5) {
                throw 'SMBIOS Type 11 structure is truncated.'
            }
            $count = [int]$raw[$cursor + 4]
            $valueOffset = $strings
            for ($index = 0; $index -lt $count; $index++) {
                if ($valueOffset -ge $terminator -or
                    $raw[$valueOffset] -eq 0) {
                    throw 'SMBIOS Type 11 string count is inconsistent.'
                }
                $nul = $valueOffset
                while ($nul -lt $terminator -and $raw[$nul] -ne 0) {
                    $nul++
                }
                $lengthBytes = $nul - $valueOffset
                if ($lengthBytes -lt 1 -or $lengthBytes -gt 255) {
                    throw 'SMBIOS Type 11 string length is invalid.'
                }
                foreach ($byte in $raw[$valueOffset..($nul - 1)]) {
                    if ($byte -lt 0x20 -or $byte -gt 0x7e) {
                        throw 'SMBIOS Type 11 contains non-printable data.'
                    }
                }
                $values += [Text.Encoding]::ASCII.GetString(
                    $raw, $valueOffset, $lengthBytes)
                $valueOffset = $nul + 1
            }
        }
        $cursor = $terminator + 2
        if ($type -eq 127) {
            break
        }
    }
    return @($values)
}

function Select-PortableProfile {
    param([Parameter(Mandatory = $true)][object]$Contract)
    if ([string]$Contract.BindingMode -cne 'portable-auto') {
        return
    }
    $prefix = 'G11_VGPU_PROFILE_V1|'
    $claims = @(Get-SmbiosOemStrings | Where-Object {
        ([string]$_).StartsWith($prefix, [StringComparison]::Ordinal)
    })
    if ($claims.Count -ne 1) {
        throw "Expected exactly one read-only portable profile claim; observed $($claims.Count). This EXE supports only a normal B/native start."
    }
    $claim = [string]$claims[0]
    $parts = @($claim -split '\|')
    if ($parts.Count -ne 6 -or
        $parts[0] -cne 'G11_VGPU_PROFILE_V1' -or
        $parts[1] -notmatch '^[a-z0-9][a-z0-9_]*$' -or
        $parts[2] -notmatch `
            '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $parts[3] -notmatch '^[0-9A-F]{64}$' -or
        $parts[4] -cne '10DE:1E30' -or
        $parts[5] -cne '31.0.15.3833') {
        throw 'The read-only portable profile claim is malformed.'
    }
    if ($parts[3] -cne [string]$Contract.CatalogSha256) {
        throw 'Host firmware and this EXE use different GPU profile catalogs.'
    }
    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$products[0].UUID)) {
        throw "Expected one SMBIOS system UUID; observed $($products.Count)."
    }
    try {
        $observedUuid = [Guid]([string]$products[0].UUID)
        $claimedUuid = [Guid]$parts[2]
    } catch {
        throw "Could not parse runtime/claimed SMBIOS UUID: $($_.Exception.Message)"
    }
    if ($observedUuid -ne $claimedUuid) {
        throw "Firmware profile claim UUID $claimedUuid does not match this guest UUID $observedUuid."
    }
    $selected = @($Contract.Profiles | Where-Object {
        [string]$_.Key -ceq $parts[1]
    })
    if ($selected.Count -ne 1) {
        throw "Firmware selected unknown or ambiguous GPU profile '$($parts[1])'."
    }
    $Contract.VmUuid = $observedUuid.ToString().ToLowerInvariant()
    $Contract.GpuProfile = [string]$selected[0].Key
    $Contract.ProfilePath = [string]$selected[0].Path
    $Contract.FirmwareClaim = $claim
    $Contract.FirmwareClaimSha256 = Get-TextSha256 $claim
    Write-Pass "firmware selected '$($Contract.GpuProfile)' for runtime UUID $($Contract.VmUuid)."
}

function Read-And-ValidateProfile {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $hasIdentitySchema = $Contract.PSObject.Properties.Name -contains `
        'ContractSchemaVersion'
    $portableSchema5 = [string]$Contract.BindingMode -ceq 'portable-auto' -and
        $hasIdentitySchema -and
        [int]$Contract.ContractSchemaVersion -in @(5, 6, 7)
    $atomicSchema2 = $portableSchema5
    if ([string]$Contract.BindingMode -ceq 'portable-auto') {
        Select-PortableProfile $Contract
    }
    try {
        $raw = Get-Content -LiteralPath $Contract.ProfilePath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "VM profile is not valid JSON: $($_.Exception.Message)"
    }
    if ([string]$Contract.BindingMode -ceq 'portable-auto') {
        if ($portableSchema5) {
            Assert-AllowedProperties $raw @(
                'schemaVersion', 'bindingMode', 'catalogSha256', 'gpu'
            ) 'profile'
            if ([int]$raw.schemaVersion -ne 2 -or
                [string]$raw.bindingMode -cne 'portable-auto' -or
                [string]$raw.catalogSha256 -cne
                    [string]$Contract.CatalogSha256) {
                throw 'Selected profile is not a schema-2 catalog-bound portable asset.'
            }
        } else {
            Assert-AllowedProperties $raw @(
                'schemaVersion', 'bindingMode', 'gpu'
            ) 'profile'
            if ([int]$raw.schemaVersion -ne 1 -or
                [string]$raw.bindingMode -cne 'portable-auto') {
                throw 'Selected profile is not a portable-auto catalog asset.'
            }
        }
    } else {
        if ([int]$raw.schemaVersion -eq 2) {
            Assert-AllowedProperties $raw @(
                'schemaVersion', 'catalogSha256', 'vmId', 'vmUuid',
                'spoofMode', 'gpu', 'monitor'
            ) 'profile'
            $atomicSchema2 = $true
            $profileCatalogSha256 = ConvertTo-StrictString `
                (Get-RequiredProperty $raw 'catalogSha256' 'profile') `
                'profile.catalogSha256' 64 '^[0-9A-F]{64}$'
        } else {
            Assert-AllowedProperties $raw @(
                'schemaVersion', 'vmId', 'vmUuid', 'spoofMode', 'gpu',
                'monitor'
            ) 'profile'
        }
        if ([int]$raw.schemaVersion -notin @(1, 2) -or
            [int]$raw.vmId -ne $Contract.VmId -or
            [string]$raw.vmUuid -ine $Contract.VmUuid -or
            [string]$raw.spoofMode -cne 'B') {
            throw 'The staged whitelist does not match the bundle VM or B transport schema.'
        }
    }
    $gpuRaw = Get-RequiredProperty $raw 'gpu' 'profile'
    Assert-AllowedProperties $gpuRaw @(
        'profile', 'name', 'expectedPnpId', 'coreClockMHz',
        'boostClockMHz', 'memoryClockMHz', 'memoryBusBits',
        'memoryBandwidthMBps', 'vramMB', 'memoryType', 'memoryMaker',
        'nvapiPciVendorId', 'nvapiPciDeviceId', 'nvapiPciSubVendorId',
        'nvapiPciSubDeviceId', 'nvapiPciRevisionId',
        'cudaCores', 'shaderSubPipes', 'ropCount', 'tmuCount', 'architecture',
        'implementation', 'chipRevision', 'pcieWidth', 'vbiosVersion',
        'boardBrand', 'boardModel', 'boardIdentity', 'serialPolicy',
        'identityScope', 'memoryTypeName', 'memoryMakerName',
        'memoryMakerNvapiName'
    ) 'profile.gpu'

    $profileKey = ConvertTo-StrictString `
        (Get-RequiredProperty $gpuRaw 'profile' 'profile.gpu') `
        'profile.gpu.profile' 64 '^[a-z0-9][a-z0-9_]*$'
    if ($profileKey -cne $Contract.GpuProfile) {
        throw 'Profile key does not match the bundle contract.'
    }
    $validated = [ordered]@{
        profile = $profileKey
        name = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'name' 'profile.gpu') `
            'profile.gpu.name' 31 '^NVIDIA [A-Za-z0-9][\x20-\x7E]{0,22}$'
        expectedPnpId = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'expectedPnpId' 'profile.gpu') `
            'profile.gpu.expectedPnpId' 64 '^PCI\\VEN_10DE&DEV_1E30$'
        vbiosVersion = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'vbiosVersion' 'profile.gpu') `
            'profile.gpu.vbiosVersion' 64 `
            '^[0-9A-Fa-f]{2}(\.[0-9A-Fa-f]{2}){4}$'
    }
    if ($atomicSchema2) {
        $validated['boardBrand'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'boardBrand' 'profile.gpu') `
            'profile.gpu.boardBrand' 31 `
            '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,30}$'
        $validated['boardModel'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'boardModel' 'profile.gpu') `
            'profile.gpu.boardModel' 31 `
            '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,30}$'
        $validated['boardIdentity'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'boardIdentity' 'profile.gpu') `
            'profile.gpu.boardIdentity' 64 `
            '^subsystem=0x[0-9A-F]{4}:0x[0-9A-F]{4}$'
        $validated['serialPolicy'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'serialPolicy' 'profile.gpu') `
            'profile.gpu.serialPolicy' 32 '^not-exposed$'
        $validated['identityScope'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'identityScope' 'profile.gpu') `
            'profile.gpu.identityScope' 96 `
            '^B:system-pci=host-mdev,catalog=protected-user-mode$'
        $validated['memoryTypeName'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'memoryTypeName' 'profile.gpu') `
            'profile.gpu.memoryTypeName' 16 '^GDDR5$'
        $validated['memoryMakerName'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'memoryMakerName' 'profile.gpu') `
            'profile.gpu.memoryMakerName' 31 `
            '^(Samsung|Elpida|SK hynix|Micron)$'
        $validated['memoryMakerNvapiName'] = ConvertTo-StrictString `
            (Get-RequiredProperty $gpuRaw 'memoryMakerNvapiName' 'profile.gpu') `
            'profile.gpu.memoryMakerNvapiName' 31 `
            '^(Samsung|Elpida|Hynix|Micron)$'
    }
    $integerRanges = [ordered]@{
        nvapiPciVendorId = @(1, 65535)
        nvapiPciDeviceId = @(1, 65535)
        nvapiPciSubVendorId = @(1, 65535)
        nvapiPciSubDeviceId = @(1, 65535)
        nvapiPciRevisionId = @(0, 255)
        coreClockMHz = @(1, 10000)
        boostClockMHz = @(1, 10000)
        memoryClockMHz = @(1, 10000)
        memoryBusBits = @(1, 1024)
        memoryBandwidthMBps = @(1, 1000000)
        vramMB = @(1024, 2048)
        memoryType = @(8, 8)
        memoryMaker = @(1, 10)
        cudaCores = @(1, 1000000)
        shaderSubPipes = @(1, 65535)
        ropCount = @(1, 65535)
        tmuCount = @(1, 1000000)
        architecture = @(1, 65535)
        implementation = @(1, 65535)
        chipRevision = @(0, 65535)
        pcieWidth = @(1, 32)
    }
    foreach ($item in $integerRanges.GetEnumerator()) {
        $validated[$item.Key] = ConvertTo-StrictInt `
            (Get-RequiredProperty $gpuRaw $item.Key 'profile.gpu') `
            "profile.gpu.$($item.Key)" `
            ([int64]$item.Value[0]) ([int64]$item.Value[1])
    }
    $gpu = [pscustomobject]$validated
    if ([int64]$gpu.boostClockMHz -lt [int64]$gpu.coreClockMHz) {
        throw 'profile.gpu.boostClockMHz must not be lower than coreClockMHz.'
    }
    if (@(1024, 2048) -notcontains [int]$gpu.vramMB) {
        throw 'profile.gpu.vramMB must be one audited catalog size (1024 or 2048).'
    }
    $memoryMakerContract = switch ([int]$gpu.memoryMaker) {
        1 { @('Samsung', 'Samsung') }
        3 { @('Elpida', 'Elpida') }
        6 { @('SK hynix', 'Hynix') }
        10 { @('Micron', 'Micron') }
        default { $null }
    }
    if ([int64]$gpu.memoryType -ne 8 -or
        $null -eq $memoryMakerContract) {
        throw 'Only cataloged GDDR5 with Samsung(1), Elpida(3), Hynix(6), or Micron(10) is accepted.'
    }
    if ($atomicSchema2 -and
        ([string]$gpu.memoryTypeName -cne 'GDDR5' -or
         [string]$gpu.memoryMakerName -cne $memoryMakerContract[0] -or
         [string]$gpu.memoryMakerNvapiName -cne $memoryMakerContract[1])) {
        throw 'The VRAM maker enum and human-readable names are not one atomic mapping.'
    }
    if (@(1, 2, 4, 8, 16, 32) -notcontains [int]$gpu.pcieWidth) {
        throw 'profile.gpu.pcieWidth must be one of 1/2/4/8/16/32.'
    }
    if ([int64]$gpu.tmuCount -ne [int64]$gpu.shaderSubPipes * 8) {
        throw 'profile.gpu.tmuCount must equal shaderSubPipes * 8.'
    }
    $rawMemoryKHz = [int64]$gpu.memoryClockMHz * 2000
    $derivedBandwidthMBps = [int64](
        $rawMemoryKHz * 2 * [int64]$gpu.memoryBusBits / 8000
    )
    $bandwidthDifference = [Math]::Abs(
        $derivedBandwidthMBps - [int64]$gpu.memoryBandwidthMBps
    )
    if ($bandwidthDifference * 100 -gt [int64]$gpu.memoryBandwidthMBps) {
        throw 'Profile memory clock/bus/bandwidth exceeds the audited GDDR5 1% tolerance.'
    }
    if ([string]$gpu.expectedPnpId -cne 'PCI\VEN_10DE&DEV_1E30') {
        throw 'The stage-vm-profile transport whitelist has an unexpected PnP ID.'
    }
    if ($Contract.SpoofMode -eq 'A') {
        if ($Contract.GpuProfile -cne 'gtx1050_2gb' -or
            $Contract.ExpectedPnpId -cne `
                'PCI\VEN_10DE&DEV_1C81&SUBSYS_11C01028&REV_A1') {
            throw 'A mode is accepted only for the audited GTX 1050 tuple.'
        }
        # Strict A is retained only as a verification boundary for a future
        # exact production-signed package.  Unlike B, it cannot accept a new
        # catalog row without an explicit system-PnP review here.
        $strictA = [ordered]@{
            name='NVIDIA GeForce GTX 1050'; coreClockMHz=1354;
            nvapiPciVendorId=0x10DE; nvapiPciDeviceId=0x1C81;
            nvapiPciSubVendorId=0x1028; nvapiPciSubDeviceId=0x11C0;
            nvapiPciRevisionId=0xA1;
            boostClockMHz=1455; memoryClockMHz=1752; memoryBusBits=128;
            memoryBandwidthMBps=112000; vramMB=2048; memoryType=8;
            memoryMaker=1; cudaCores=640; shaderSubPipes=5; ropCount=32;
            tmuCount=40; architecture=0x130; implementation=7;
            chipRevision=0x11; pcieWidth=16;
            vbiosVersion='86.07.39.40.F4'
        }
        foreach ($item in $strictA.GetEnumerator()) {
            if ($item.Value -is [string]) {
                if ([string]$gpu.($item.Key) -cne [string]$item.Value) {
                    throw "profile.gpu.$($item.Key) conflicts with strict-A."
                }
            } elseif ([int64]$gpu.($item.Key) -ne [int64]$item.Value) {
                throw "profile.gpu.$($item.Key) conflicts with strict-A."
            }
        }
    } elseif ($Contract.ExpectedPnpId -cne 'PCI\VEN_10DE&DEV_1E30') {
        throw 'B mode must retain the native DEV_1E30 PnP identity.'
    }
    if ($atomicSchema2) {
        if ($portableSchema5) {
            $selected = @($Contract.Profiles | Where-Object {
                [string]$_.Key -ceq [string]$Contract.GpuProfile
            })
            if ($selected.Count -ne 1) {
                throw 'Portable profile does not select exactly one catalog entry.'
            }
            $catalogGpu = $selected[0].CatalogGpu
        } else {
            $catalogPath = Join-Path $BundleRoot 'vgpu-profile-catalog.json'
            try {
                $catalog = Get-Content -LiteralPath $catalogPath -Raw |
                    ConvertFrom-Json -ErrorAction Stop
            } catch {
                throw "VM-bound schema-2 identity catalog is unavailable or invalid: $($_.Exception.Message)"
            }
            if ([int]$catalog.schemaVersion -ne 2 -or
                [string]$catalog.catalogSha256 -cne
                    [string]$profileCatalogSha256 -or
                [string]$catalog.identityMode -cne 'protected-user-mode' -or
                [string]$catalog.transportPnpId -cne
                    'PCI\VEN_10DE&DEV_1E30') {
                throw 'VM-bound schema-2 identity catalog header is inconsistent.'
            }
            $catalogRows = @($catalog.profiles | Where-Object {
                [string]$_.profile -ceq [string]$Contract.GpuProfile
            })
            if ($catalogRows.Count -ne 1) {
                throw 'VM-bound profile does not select one schema-2 catalog row.'
            }
            $catalogGpu = $catalogRows[0]
        }
        foreach ($property in @(
            'profile', 'name', 'expectedPnpId', 'boardBrand', 'boardModel',
            'boardIdentity', 'serialPolicy', 'identityScope', 'memoryTypeName',
            'memoryMakerName', 'memoryMakerNvapiName', 'vbiosVersion'
        )) {
            if ([string]$gpu.$property -cne [string]$catalogGpu.$property) {
                throw "Portable profile field '$property' is split from its catalog row."
            }
        }
        foreach ($property in @(
            'coreClockMHz', 'boostClockMHz', 'memoryClockMHz',
            'memoryBusBits', 'memoryBandwidthMBps', 'vramMB', 'memoryType',
            'memoryMaker', 'nvapiPciVendorId', 'nvapiPciDeviceId',
            'nvapiPciSubVendorId', 'nvapiPciSubDeviceId',
            'nvapiPciRevisionId', 'cudaCores', 'shaderSubPipes', 'ropCount',
            'tmuCount', 'architecture', 'implementation', 'chipRevision',
            'pcieWidth'
        )) {
            if ([int64]$gpu.$property -ne [int64]$catalogGpu.$property) {
                throw "Portable profile field '$property' is split from its catalog row."
            }
        }
    } elseif ([string]$Contract.BindingMode -ceq 'portable-auto') {
        $selected = @($Contract.Profiles | Where-Object {
            [string]$_.Key -ceq [string]$Contract.GpuProfile
        })
        if ($selected.Count -ne 1 -or [string]$gpu.name -cne
            [string]$selected[0].CanonicalDisplayName) {
            throw 'Portable profile name does not match its canonical catalog entry.'
        }
    }
    Write-Pass "profile '$($Contract.GpuProfile)' matches the hash-pinned host catalog contract."
    return $gpu
}

function Assert-GuestUuid {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $products = @(Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($products.Count -ne 1) {
        throw "Expected one Win32_ComputerSystemProduct; observed $($products.Count)."
    }
    if ([Guid]$products[0].UUID -ne [Guid]$Contract.VmUuid) {
        throw "Bundle UUID $($Contract.VmUuid) does not match this guest."
    }
    if ([string]$Contract.BindingMode -ceq 'portable-auto') {
        Write-Pass 'guest UUID matches the read-only runtime firmware claim.'
    } else {
        Write-Pass 'guest UUID matches the bundle.'
    }
}

function Assert-NormalCodeIntegrityBoot {
    $bcdOutput = (& $SystemBcdEdit /enum all 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read all BCD entries and inherited settings: $bcdOutput"
    }
    foreach ($flag in @('testsigning', 'nointegritychecks')) {
        $lines = @($bcdOutput -split "`r?`n" |
            Where-Object { $_ -match "^\s*$flag\s+" })
        foreach ($line in $lines) {
            if ($line -notmatch '(?i)\b(no|off|false|0)\s*$') {
                throw "$flag is enabled or has an unknown value. This bundle will not change BCD."
            }
        }
    }
    Write-Pass 'no BCD entry enables testsigning/nointegritychecks; BCD was not changed.'
}

function Test-PnpPrefix {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
    $actualUpper = $Actual.Trim().ToUpperInvariant()
    $expectedUpper = $Expected.Trim().ToUpperInvariant()
    return $actualUpper -eq $expectedUpper -or
        $actualUpper.StartsWith($expectedUpper + '&', [StringComparison]::Ordinal) -or
        $actualUpper.StartsWith($expectedUpper + '\', [StringComparison]::Ordinal)
}

function Test-TrustedNvidiaWhcpSubject {
    param([string]$Subject)
    if ([string]::IsNullOrWhiteSpace($Subject)) { return $false }
    return $Subject -match '\ACN=NVIDIA(?: Corporation)?(?:,|$)' -or
        $Subject -match `
            '\ACN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)'
}

function Assert-MicrosoftRootProgramCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $thumbprint = ([string]$Certificate.Thumbprint).ToUpperInvariant()
    if ($PublicSignerCache.ContainsKey($thumbprint)) {
        return
    }

    $codeSigningOid = '1.3.6.1.5.5.7.3.3'
    $hasCodeSigningEku = $false
    foreach ($extension in $Certificate.Extensions) {
        if ($extension -is
            [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            foreach ($usage in $extension.EnhancedKeyUsages) {
                if ([string]$usage.Value -ceq $codeSigningOid) {
                    $hasCodeSigningEku = $true
                }
            }
        }
    }
    if (-not $hasCodeSigningEku) {
        throw "$Context signer does not contain the Code Signing EKU."
    }

    $embeddedCertificates = @(
        [QemuGpuZNativeSecurity]::GetEmbeddedCertificates($SourcePath)
    )
    try {
        # Get-AuthenticodeSignature already validated timestamp semantics.
        # Rebuild at a point inside the leaf validity period using the
        # PKCS#7-embedded intermediates.  The native helper disables AIA,
        # network retrieval and AuthRoot auto-update for this second gate.
        $rootClass =
            [QemuGpuZNativeSecurity]::ValidatePublicProductionCodeSigningChain(
                $Certificate,
                ([Security.Cryptography.X509Certificates.X509Certificate2[]]$embeddedCertificates),
                $Certificate.NotBefore.AddMinutes(1)
            )
        if ($rootClass -notin @(1, 2)) {
            throw "$Context signer chains only to a locally trusted/private root, " +
                'not a non-Flight Microsoft production root or a positively ' +
                'identified Microsoft Third Party Root Program CA.'
        }
    } finally {
        foreach ($embeddedCertificate in $embeddedCertificates) {
            $embeddedCertificate.Dispose()
        }
    }
    $PublicSignerCache[$thumbprint] = $true
}

function Get-ValidatedDriverCatalog {
    param(
        [Parameter(Mandatory = $true)][object]$SignedDriver,
        [Parameter(Mandatory = $true)][IO.FileInfo]$LoadedDriver
    )
    $infName = [string]$SignedDriver.InfName
    if ($infName -notmatch '\A[A-Za-z0-9_.-]+\.inf\z' -or
        $infName.Contains('..')) {
        throw "The active PnP package has an unsafe INF name: '$infName'."
    }
    $driverStoreRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository')
    ).TrimEnd('\') + '\'
    $loadedDirectory = [IO.Path]::GetFullPath(
        $LoadedDriver.DirectoryName
    ).TrimEnd('\')
    if (-not ($loadedDirectory + '\').StartsWith(
            $driverStoreRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The active NVIDIA kernel image is not loaded from DriverStore.'
    }
    $packageDirectoryName = $loadedDirectory.Substring($driverStoreRoot.Length)
    if ([string]::IsNullOrWhiteSpace($packageDirectoryName) -or
        $packageDirectoryName.Contains('\') -or
        $packageDirectoryName -notmatch
            '\Anvgridsw\.inf_amd64_[0-9a-f]{16}\z') {
        throw "The loaded NVIDIA package directory is unexpected: $loadedDirectory"
    }

    # Win32_PnPSignedDriver binds the active device to its published oemN.inf;
    # the running nvlddmkm service binds it to one exact FileRepository
    # directory. Comparing those two INF copies avoids a multi-minute full
    # full online DISM driver-store scan while retaining a fail-closed link
    # between the active PnP package, loaded kernel image, INF and catalog.
    $publishedInfItem = Assert-RegularLocalPath `
        (Join-Path (Join-Path $env:SystemRoot 'INF') $infName) `
        'published active PnP INF'
    $infItem = Assert-RegularLocalPath `
        (Join-Path $loadedDirectory 'nvgridsw.inf') 'loaded DriverStore INF'
    $publishedInfHash = (Get-FileHash -LiteralPath $publishedInfItem.FullName `
        -Algorithm SHA256 -ErrorAction Stop).Hash
    $driverStoreInfHash = (Get-FileHash -LiteralPath $infItem.FullName `
        -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($publishedInfHash -cne $driverStoreInfHash) {
        throw "The active published INF does not match loaded DriverStore package $packageDirectoryName."
    }
    $infText = [IO.File]::ReadAllText($infItem.FullName)
    $driverVersionMatches = [regex]::Matches(
        $infText,
        '(?im)^\s*DriverVer\s*=\s*[^,\r\n]+,\s*([0-9.]+)\s*(?:;.*)?$'
    )
    $infDriverVersions = @($driverVersionMatches | ForEach-Object {
        [string]$_.Groups[1].Value.Trim()
    } | Sort-Object -Unique)
    if ($infDriverVersions.Count -ne 1 -or
        $infDriverVersions[0] -cne [string]$SignedDriver.DriverVersion) {
        throw "Loaded DriverStore INF version does not match active package $infName."
    }
    $catalogMatches = [regex]::Matches(
        $infText,
        '(?im)^\s*CatalogFile(?:\.[A-Za-z0-9_.-]+)?\s*=\s*"?([^";\r\n]+?)"?\s*(?:;.*)?$'
    )
    $catalogNames = @($catalogMatches | ForEach-Object {
        [string]$_.Groups[1].Value.Trim()
    } | Sort-Object -Unique)
    if ($catalogNames.Count -ne 1 -or
        [IO.Path]::GetFileName($catalogNames[0]) -cne $catalogNames[0] -or
        [IO.Path]::GetExtension($catalogNames[0]) -ine '.cat') {
        throw "DriverStore INF must resolve to one unambiguous local catalog: $infName"
    }
    $catalogPath = Join-Path $infItem.DirectoryName $catalogNames[0]
    $catalogItem = Assert-RegularLocalPath $catalogPath 'DriverStore catalog'
    $catalogSignature = Get-AuthenticodeSignature -LiteralPath $catalogItem.FullName
    $catalogSubject = if ($null -ne $catalogSignature.SignerCertificate) {
        [string]$catalogSignature.SignerCertificate.Subject
    } else {
        ''
    }
    if ([string]$catalogSignature.Status -cne 'Valid' -or
        $null -eq $catalogSignature.SignerCertificate -or
        $catalogSubject -ceq
            [string]$catalogSignature.SignerCertificate.Issuer -or
        -not (Test-TrustedNvidiaWhcpSubject $catalogSubject)) {
        throw "DriverStore catalog is not validly NVIDIA/WHCP signed: $catalogPath"
    }
    Assert-MicrosoftRootProgramCertificate `
        $catalogSignature.SignerCertificate $catalogItem.FullName `
        'DriverStore catalog'
    return [pscustomobject]@{
        InfPath = $infItem.FullName
        CatalogPath = $catalogItem.FullName
        CatalogSigner = $catalogSubject
    }
}

function Get-HealthyDisplayState {
    param([Parameter(Mandatory = $true)][object]$Contract)
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        throw 'Get-PnpDevice is required for the one-display acceptance check.'
    }
    $presentDisplays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    if ($presentDisplays.Count -ne 1) {
        $observed = @($presentDisplays | ForEach-Object {
            "$($_.FriendlyName) [$($_.InstanceId)]"
        }) -join '; '
        throw "Expected exactly one present Display device; observed $($presentDisplays.Count): $observed"
    }
    $display = $presentDisplays[0]
    if (-not (Test-PnpPrefix ([string]$display.InstanceId) $Contract.ExpectedPnpId)) {
        throw "The only display '$($display.InstanceId)' does not match '$($Contract.ExpectedPnpId)'."
    }
    $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
        Where-Object {
            Test-PnpPrefix ([string]$_.PNPDeviceID) $Contract.ExpectedPnpId
        })
    if ($controllers.Count -ne 1 -or
        [int]$controllers[0].ConfigManagerErrorCode -ne 0) {
        throw "Expected one matching Code 0 video controller; observed $($controllers.Count)."
    }
    if ([string]$controllers[0].DriverVersion -cne $Contract.ExpectedDriverVersion) {
        throw "Driver version '$($controllers[0].DriverVersion)' does not match '$($Contract.ExpectedDriverVersion)'."
    }

    $parentProperty = Get-PnpDeviceProperty -InstanceId $display.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
    $parentId = [string]$parentProperty.Data
    $parents = @(Get-PnpDevice -InstanceId $parentId -PresentOnly -ErrorAction Stop)
    if ($parents.Count -ne 1 -or [string]$parents[0].Class -ine 'System' -or
        $parentId -notmatch '(?i)^PCI\\VEN_(?!10DE)[0-9A-F]{4}&DEV_[0-9A-F]{4}') {
        throw "GPU parent must be one System-class PCI bridge, not a second GPU: $parentId"
    }

    $escapedPnpDeviceId = ([string]$controllers[0].PNPDeviceID).Replace(
        '\', '\\'
    ).Replace("'", "\'")
    $signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver `
        -Filter "DeviceID='$escapedPnpDeviceId'" -ErrorAction Stop)
    if ($signedDrivers.Count -ne 1 -or -not [bool]$signedDrivers[0].IsSigned -or
        [string]$signedDrivers[0].DriverVersion -cne $Contract.ExpectedDriverVersion -or
        [string]$signedDrivers[0].DriverProviderName -notmatch `
            '\ANVIDIA(?: Corporation)?\z') {
        throw 'The active display does not have one signed matching PnP driver package.'
    }
    $pnpSigner = [string]$signedDrivers[0].Signer
    $trustedPnpSigner = $pnpSigner -match '\ANVIDIA(?: Corporation)?\z' -or
        $pnpSigner -ceq 'Microsoft Windows Hardware Compatibility Publisher'
    if ([string]::IsNullOrWhiteSpace($pnpSigner) -or -not $trustedPnpSigner) {
        throw "The active PnP package signer is not NVIDIA/WHCP: '$pnpSigner'."
    }
    $kernelDrivers = @(Get-CimInstance Win32_SystemDriver -Filter `
        "Name='nvlddmkm'" -ErrorAction Stop)
    if ($kernelDrivers.Count -ne 1) {
        throw "Expected one nvlddmkm kernel service; observed $($kernelDrivers.Count)."
    }
    if ([string]$kernelDrivers[0].State -cne 'Running') {
        throw 'The nvlddmkm kernel service is not running.'
    }
    $driverPath = [string]$kernelDrivers[0].PathName
    $driverPath = $driverPath.Trim().Trim('"')
    if ($driverPath.StartsWith('\??\', [StringComparison]::Ordinal)) {
        $driverPath = $driverPath.Substring(4)
    }
    if ($driverPath.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $driverPath = Join-Path $env:SystemRoot $driverPath.Substring(12)
    }
    $driverItem = Assert-RegularLocalPath $driverPath 'loaded NVIDIA kernel driver'
    if ($driverItem.Name -ine 'nvlddmkm.sys') {
        throw "The nvlddmkm service points at an unexpected file: $driverPath"
    }
    $driverStorePrefix = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository')
    ).TrimEnd('\') + '\'
    $systemDriversPrefix = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\drivers')
    ).TrimEnd('\') + '\'
    if (-not $driverItem.FullName.StartsWith(
            $driverStorePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        -not $driverItem.FullName.StartsWith(
            $systemDriversPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The loaded NVIDIA kernel driver is outside approved Windows roots: $driverPath"
    }
    # The catalog carries the package's PKCS#7 intermediate certificates.
    # Validate that identity-bound production chain first, then require the
    # loaded SYS to use the same already-approved leaf certificate below.
    $driverPackage = Get-ValidatedDriverCatalog `
        -SignedDriver $signedDrivers[0] -LoadedDriver $driverItem
    $driverVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($driverPath)
    $kernelFileVersion = '{0}.{1}.{2}.{3}' -f
        $driverVersion.FileMajorPart, $driverVersion.FileMinorPart,
        $driverVersion.FileBuildPart, $driverVersion.FilePrivatePart
    $driverSignature = Get-AuthenticodeSignature -LiteralPath $driverPath
    $driverSignerSubject = if ($null -ne $driverSignature.SignerCertificate) {
        [string]$driverSignature.SignerCertificate.Subject
    } else {
        ''
    }
    $trustedDriverSigner = Test-TrustedNvidiaWhcpSubject $driverSignerSubject
    if ([string]$driverSignature.Status -cne 'Valid' -or
        $null -eq $driverSignature.SignerCertificate -or
        $kernelFileVersion -cne $Contract.ExpectedDriverVersion -or
        $driverVersion.CompanyName -notmatch '\ANVIDIA(?: Corporation)?\z' -or
        $driverSignerSubject -ceq
            [string]$driverSignature.SignerCertificate.Issuer -or
        -not $trustedDriverSigner) {
        throw "The loaded NVIDIA kernel driver is not validly production-signed: $driverPath"
    }
    Assert-MicrosoftRootProgramCertificate `
        $driverSignature.SignerCertificate $driverPath `
        'loaded NVIDIA kernel driver'

    Write-Pass "one present NVIDIA Display is Code 0; parent '$parentId' is not a GPU."
    Write-Pass 'active DriverStore catalog and kernel image are validly NVIDIA/WHCP signed.'
    return [pscustomobject]@{
        Display = $display
        Controller = $controllers[0]
        ParentId = $parentId
        ParentClass = [string]$parents[0].Class
        KernelDriverPath = $driverPath
        DriverInfPath = $driverPackage.InfPath
        DriverCatalogPath = $driverPackage.CatalogPath
    }
}

function Get-HealthyDisplayStateWithRetry {
    param([Parameter(Mandatory = $true)][object]$Contract)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            return Get-HealthyDisplayState $Contract
        } catch {
            # PnP/driver signature providers can briefly surface the Win32
            # sharing-violation HRESULT while Windows refreshes device state.
            # Retry only that precise transient; all policy/topology failures
            # remain fail-closed on their first occurrence.
            $win32Code = ([int64]$_.Exception.HResult) -band 0xFFFF
            if ($win32Code -ne 32 -or $attempt -eq 5) {
                throw
            }
            Start-Sleep -Seconds 2
        }
    }
    throw 'The display state retry loop ended unexpectedly.'
}

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Not a PE image: $Path"
    }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0x40 -or $offset + 6 -gt $bytes.Length -or
        $bytes[$offset] -ne 0x50 -or $bytes[$offset + 1] -ne 0x45) {
        throw "Invalid PE header: $Path"
    }
    return [int][BitConverter]::ToUInt16($bytes, $offset + 4)
}

function Assert-NvidiaProductionImage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ExpectedMachine,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $item = Assert-RegularLocalPath $Path $Context
    if ((Get-PeMachine $item.FullName) -ne $ExpectedMachine) {
        throw "$Context has the wrong PE architecture: $Path"
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $signerSubject = if ($null -ne $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    } else {
        ''
    }
    $trustedSigner = Test-TrustedNvidiaWhcpSubject $signerSubject
    if ($version.CompanyName -notmatch '\ANVIDIA(?: Corporation)?\z' -or
        [string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $signerSubject -ceq [string]$signature.SignerCertificate.Issuer -or
        -not $trustedSigner) {
        throw "$Context is not a valid NVIDIA/WHCP non-self-issued image: $Path"
    }
    Assert-MicrosoftRootProgramCertificate `
        $signature.SignerCertificate $item.FullName $Context
    return $item
}

function Get-GpuZRawEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AdminOnlySourceSnapshot
    )
    $item = Assert-RegularLocalPath $Path $Context
    # A SUBST/DOS-device alias can hide a low-privilege writable real parent.
    # From here onward, version/signature/ACL/install/launch operations all use
    # the handle-resolved fixed-drive path and traverse its true ancestry.
    $item = Resolve-FinalRegularLocalPath $item.FullName $Context
    if ($item.Name -cne $Contract.GpuZName) {
        throw "$Context must retain the exact basename $($Contract.GpuZName)."
    }
    if ([int64]$item.Length -ne [int64]$Contract.GpuZBytes) {
        throw "$Context byte length does not match contract.gpuz."
    }
    $sha256 = Get-Sha256 $item.FullName
    if ($sha256 -cne $Contract.GpuZSha256) {
        throw 'GPU-Z SHA-256 does not match the statically audited standard 2.70.0 image.'
    }
    $windowsRoot = [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\') + '\'
    if ($item.FullName.StartsWith(
            $windowsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GPU-Z must not be installed below the Windows system directory.'
    }
    Assert-OutsideWindowsTree $item.FullName $Context
    Assert-OutsideWindowsTree $item.Directory.FullName `
        "$Context application directory"
    Assert-TrustedGpuZWriteBoundary $item $Context
    if (-not $AdminOnlySourceSnapshot) {
        Assert-UsersReadExecuteAccess $item.FullName $Context
    }
    if ($item.Extension -ine '.exe' -or (Get-PeMachine $item.FullName) -ne 0x014c) {
        throw 'The accepted GPU-Z 2.70.0 build must be a 32-bit PE executable.'
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
    $rawProductVersion = [string]$version.ProductVersion
    if ($rawProductVersion -cne $Contract.GpuZProductVersion -and
        -not $rawProductVersion.StartsWith(
            $Contract.GpuZProductVersion + '.',
            [StringComparison]::Ordinal
        )) {
        throw "GPU-Z ProductVersion does not match $($Contract.GpuZProductVersion)."
    }
    if ([string]$version.CompanyName -notmatch 'TechPowerUp') {
        throw "GPU-Z must be the accepted TechPowerUp $($Contract.GpuZProductVersion) build."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $gpuZSubject = if ($null -ne $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    } else {
        ''
    }
    # EV/organization-validated certificates may place jurisdiction OIDs
    # before the CN in the RFC2253 subject.  Match the exact comma-delimited
    # CN instead of assuming it is the first RDN.
    if ([string]$signature.Status -cne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $gpuZSubject -notmatch `
            '(?:\A|,\s*)CN=TechPowerUp(?: LLC)?(?:,|\z)' -or
        $gpuZSubject -ceq
            [string]$signature.SignerCertificate.Issuer) {
        throw 'GPU-Z must have a valid, non-self-issued TechPowerUp Authenticode signature.'
    }
    Assert-MicrosoftRootProgramCertificate `
        $signature.SignerCertificate $item.FullName $Context
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $processPath = [string]$process.Path
            if ([string]::IsNullOrWhiteSpace($processPath)) {
                continue
            }
            # Kernel/system pseudo paths such as \SystemRoot\... are not DOS
            # paths accepted by GetFullPath.  They cannot identify this
            # fixed-drive GPU-Z image and must not abort the whole scan.
            $processFullPath = [IO.Path]::GetFullPath($processPath)
            if ([string]::Equals(
                    $processFullPath,
                    $item.FullName,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'Close GPU-Z before installing or verifying its app-local files.'
            }
        } catch [System.ComponentModel.Win32Exception] {
            continue
        } catch [ArgumentException] {
            continue
        } catch [NotSupportedException] {
            continue
        } catch [InvalidOperationException] {
            continue
        }
    }
    Write-Pass "GPU-Z $($version.ProductVersion) has a valid non-self-issued TechPowerUp signature."
    return [pscustomobject][ordered]@{
        path = $item.FullName
        name = $item.Name
        bytes = [int64]$item.Length
        sha256 = $sha256
        productVersion = $rawProductVersion
        fileVersion = [string]$version.FileVersion
        companyName = [string]$version.CompanyName
        signatureStatus = [string]$signature.Status
        signerSubject = [string]$signature.SignerCertificate.Subject
        signerIssuer = [string]$signature.SignerCertificate.Issuer
        signerThumbprint =
            ([string]$signature.SignerCertificate.Thumbprint).ToUpperInvariant()
    }
}

function Get-ValidatedGpuZ {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $expectedPath = Join-Path $Contract.GpuZApplicationDirectory `
        $Contract.GpuZName
    $null = Assert-ProtectedAdminSystemDirectory $ApplicationsRoot `
        'GPU-Z applications root' -AllowUsersReadExecute
    $null = Assert-ProtectedAdminSystemDirectory `
        $Contract.GpuZApplicationDirectory `
        'GPU-Z persistent application directory' -AllowUsersReadExecute
    $evidence = Get-GpuZRawEvidence $Contract $expectedPath `
        'installed GPU-Z executable'
    $expectedFullPath = [IO.Path]::GetFullPath($expectedPath)
    if (-not ([string]$evidence.path).Equals(
            $expectedFullPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installed GPU-Z resolved outside its contract-derived persistent path.'
    }
    return $evidence
}

function Initialize-ProtectedIdentityApplication {
    param([Parameter(Mandatory = $true)][object]$Contract)
    if ([int]$Contract.ContractSchemaVersion -notin @(6, 7)) {
        throw 'Identity application initialization requires contract schema 6 or 7.'
    }
    $directory = Initialize-AdminSystemDirectory `
        $Contract.IdentityApplicationDirectory -AllowUsersReadExecute
    $null = Assert-ProtectedAdminSystemDirectory $directory `
        'vGPU identity application directory' -AllowUsersReadExecute
    Assert-OutsideWindowsTree $directory 'vGPU identity application directory'
    return $directory
}

function Get-OptionalValidatedGpuZ {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $path = Join-Path $Contract.GpuZApplicationDirectory $Contract.GpuZName
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The optional protected GPU-Z path is not a regular file: $path"
    }
    return Get-ValidatedGpuZ $Contract
}

function Install-OptionalProtectedGpuZ {
    param([Parameter(Mandatory = $true)][object]$Contract)
    if ([int]$Contract.ContractSchemaVersion -notin @(6, 7)) {
        throw 'Optional GPU-Z installation requires contract schema 6 or 7.'
    }
    $existing = Get-OptionalValidatedGpuZ $Contract
    if ($null -ne $existing) {
        Write-Pass 'the exact optional protected GPU-Z image already exists; reusing it.'
        return $existing
    }

    $null = Assert-ProtectedAdminSystemDirectory `
        $Contract.IdentityApplicationDirectory `
        'vGPU identity application directory' -AllowUsersReadExecute
    $source = Assert-RegularLocalPath $Contract.GpuZSourcePath `
        'explicit optional GPU-Z source snapshot'
    $null = Get-GpuZRawEvidence $Contract $source.FullName `
        'explicit optional GPU-Z source snapshot' -AdminOnlySourceSnapshot

    $stagingDirectory = Join-Path $ApplicationsRoot (
        '.optional-gpuz.{0}.tmp' -f [Guid]::NewGuid().ToString('N')
    )
    $stagedPath = Join-Path $stagingDirectory $Contract.GpuZName
    $targetPath = Join-Path $Contract.GpuZApplicationDirectory `
        $Contract.GpuZName
    try {
        $null = Initialize-AdminSystemDirectory $stagingDirectory `
            -AllowUsersReadExecute
        Copy-Item -LiteralPath $source.FullName -Destination $stagedPath `
            -ErrorAction Stop
        $null = Set-AdminSystemUsersReadExecuteFile $stagedPath `
            'staged optional GPU-Z executable'
        $null = Get-GpuZRawEvidence $Contract $stagedPath `
            'staged optional GPU-Z executable'
        try {
            Move-Item -LiteralPath $stagedPath -Destination $targetPath `
                -ErrorAction Stop
        } catch [IO.IOException] {
            # Another elevated instance may have won the no-replace publish.
            $null = Get-ValidatedGpuZ $Contract
        }
    } finally {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
    $evidence = Get-ValidatedGpuZ $Contract
    Write-Pass 'optional GPU-Z was explicitly installed and reverified in protected ProgramData.'
    return $evidence
}

function Install-ProtectedGpuZ {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $targetDirectory = $Contract.GpuZApplicationDirectory
    if (Test-Path -LiteralPath $targetDirectory) {
        $evidence = Get-ValidatedGpuZ $Contract
        Write-Pass 'the exact protected GPU-Z application already exists; reusing it.'
        return $evidence
    }

    $source = Assert-RegularLocalPath $Contract.GpuZSourcePath `
        'contract-bound protected GPU-Z source snapshot'
    if ($source.Name -cne $Contract.GpuZName -or
        [int64]$source.Length -ne [int64]$Contract.GpuZBytes -or
        (Get-Sha256 $source.FullName) -cne $Contract.GpuZSha256) {
        throw 'The protected GPU-Z source snapshot changed before publication.'
    }

    $versionName = Split-Path -Leaf $targetDirectory
    $stagingDirectory = Join-Path $ApplicationsRoot (
        '.{0}.{1}.tmp' -f $versionName, [Guid]::NewGuid().ToString('N')
    )
    $stagedPath = Join-Path $stagingDirectory $Contract.GpuZName
    $published = $false
    try {
        $null = Initialize-AdminSystemDirectory $stagingDirectory `
            -AllowUsersReadExecute
        Copy-Item -LiteralPath $source.FullName -Destination $stagedPath `
            -ErrorAction Stop
        $null = Get-GpuZRawEvidence $Contract $stagedPath `
            'staged persistent GPU-Z executable'
        try {
            # Directory.Move is a same-volume, no-replace directory rename.
            # It either publishes the fully verified tree atomically or fails.
            [IO.Directory]::Move($stagingDirectory, $targetDirectory)
            $published = $true
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $targetDirectory `
                    -PathType Container)) {
                throw
            }
            # A concurrent elevated installer won the deterministic name.
            # Reuse it only after the complete installed-target validation.
            $evidence = Get-ValidatedGpuZ $Contract
            Write-Pass 'a concurrent exact protected GPU-Z publication was reused.'
            return $evidence
        }
    } finally {
        if (-not $published -and
            (Test-Path -LiteralPath $stagingDirectory)) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $evidence = Get-ValidatedGpuZ $Contract
    Write-Pass 'GPU-Z was reverified and atomically published into protected ProgramData.'
    return $evidence
}

function Get-ValidatedGpuZShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$ApplicationExe
    )
    $item = Assert-RegularLocalPath $ShortcutPath `
        'public GPU-Z profile shortcut'
    Assert-TrustedGpuZWriteBoundary $item `
        'public GPU-Z profile shortcut'
    $applicationDirectory = Split-Path -Parent $ApplicationExe
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($item.FullName)
        $targetPath = [IO.Path]::GetFullPath([string]$shortcut.TargetPath)
        $workingDirectory =
            [IO.Path]::GetFullPath([string]$shortcut.WorkingDirectory)
        if (-not $targetPath.Equals(
                [IO.Path]::GetFullPath($ApplicationExe),
                [StringComparison]::OrdinalIgnoreCase) -or
            -not $workingDirectory.Equals(
                [IO.Path]::GetFullPath($applicationDirectory),
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::IsNullOrWhiteSpace([string]$shortcut.Arguments)) {
            throw 'The public GPU-Z profile shortcut does not match its installed target.'
        }
        return [pscustomobject][ordered]@{
            path = $item.FullName
            targetPath = $targetPath
            workingDirectory = $workingDirectory
            arguments = [string]$shortcut.Arguments
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
}

function Install-PublicGpuZShortcut {
    param([Parameter(Mandatory = $true)][string]$ApplicationExe)
    $desktop = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonDesktopDirectory
    )
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        throw 'Windows did not provide the Public Desktop directory.'
    }
    $desktopItem = Get-Item -LiteralPath $desktop -Force -ErrorAction Stop
    if (-not $desktopItem.PSIsContainer -or
        ($desktopItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Public Desktop is not a regular directory: $desktop"
    }
    $desktopIdentity = Get-FinalLocalPathIdentity $desktopItem.FullName `
        'Public Desktop directory'
    $expectedDesktopIdentity = '\\?\' +
        [IO.Path]::GetFullPath($desktopItem.FullName).TrimEnd('\')
    if (-not $desktopIdentity.Equals(
            $expectedDesktopIdentity,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Public Desktop resolves through an unexpected filesystem alias.'
    }

    $shortcutName = 'GPU-Z (vGPU profile).lnk'
    $shortcutPath = Join-Path $desktopItem.FullName $shortcutName
    if (Test-Path -LiteralPath $shortcutPath) {
        $existing = Get-Item -LiteralPath $shortcutPath -Force `
            -ErrorAction Stop
        if ($existing.PSIsContainer -or
            ($existing.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The owned Public Desktop shortcut path is unsafe: $shortcutPath"
        }
    }

    $temporaryPath = Join-Path $desktopItem.FullName (
        '.GPU-Z-vGPU-{0}.tmp.lnk' -f [Guid]::NewGuid().ToString('N')
    )
    $shell = $null
    $shortcut = $null
    try {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($temporaryPath)
            $shortcut.TargetPath = $ApplicationExe
            $shortcut.WorkingDirectory = Split-Path -Parent $ApplicationExe
            $shortcut.Description = 'GPU-Z with the installed vGPU profile'
            $shortcut.IconLocation = $ApplicationExe + ',0'
            $shortcut.Save()
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
        $null = Set-AdminSystemUsersReadExecuteFile $temporaryPath `
            'public GPU-Z profile shortcut'
        $null = Get-ValidatedGpuZShortcut $temporaryPath $ApplicationExe
        # The temporary shortcut and destination share one directory, so this
        # is one atomic replacement of only our fixed, namespaced shortcut.
        Move-Item -LiteralPath $temporaryPath -Destination $shortcutPath `
            -Force -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
    }
    $evidence = Get-ValidatedGpuZShortcut $shortcutPath $ApplicationExe
    Write-Pass "Public Desktop shortcut installed at $shortcutPath."
    return $evidence
}

function Get-ValidatedIdentityQueryShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$QueryPath
    )
    $item = Assert-RegularLocalPath $ShortcutPath `
        'public vGPU identity query shortcut'
    Assert-TrustedGpuZWriteBoundary $item `
        'public vGPU identity query shortcut'
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($item.FullName)
        $targetPath = [IO.Path]::GetFullPath([string]$shortcut.TargetPath)
        $workingDirectory = [IO.Path]::GetFullPath(
            [string]$shortcut.WorkingDirectory
        )
        if (-not $targetPath.Equals(
                [IO.Path]::GetFullPath($QueryPath),
                [StringComparison]::OrdinalIgnoreCase) -or
            -not $workingDirectory.Equals(
                [IO.Path]::GetFullPath((Split-Path -Parent $QueryPath)),
                [StringComparison]::OrdinalIgnoreCase) -or
            [string]$shortcut.Arguments -cne '--pause') {
            throw 'The public vGPU identity query shortcut is not canonical.'
        }
        return [pscustomobject][ordered]@{
            path = $item.FullName
            targetPath = $targetPath
            workingDirectory = $workingDirectory
            arguments = [string]$shortcut.Arguments
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
}

function Install-PublicIdentityQueryShortcut {
    param([Parameter(Mandatory = $true)][string]$QueryPath)
    $desktop = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonDesktopDirectory
    )
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        throw 'Windows did not provide the Public Desktop directory.'
    }
    $desktopItem = Get-Item -LiteralPath $desktop -Force -ErrorAction Stop
    if (-not $desktopItem.PSIsContainer -or
        ($desktopItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Public Desktop is not a regular directory: $desktop"
    }
    $shortcutPath = Join-Path $desktopItem.FullName `
        'vGPU Identity Query.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        $existing = Get-Item -LiteralPath $shortcutPath -Force `
            -ErrorAction Stop
        if ($existing.PSIsContainer -or
            ($existing.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The owned Public Desktop query shortcut is unsafe: $shortcutPath"
        }
    }
    $temporaryPath = Join-Path $desktopItem.FullName (
        '.vGPU-Identity-Query-{0}.tmp.lnk' -f
            [Guid]::NewGuid().ToString('N')
    )
    $shell = $null
    $shortcut = $null
    try {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($temporaryPath)
            $shortcut.TargetPath = $QueryPath
            $shortcut.Arguments = '--pause'
            $shortcut.WorkingDirectory = Split-Path -Parent $QueryPath
            $shortcut.Description = `
                'Verify native transport and projected vGPU board/VRAM identity'
            $shortcut.IconLocation = $QueryPath + ',0'
            $shortcut.Save()
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
        $null = Set-AdminSystemUsersReadExecuteFile $temporaryPath `
            'public vGPU identity query shortcut'
        $null = Get-ValidatedIdentityQueryShortcut $temporaryPath $QueryPath
        Move-Item -LiteralPath $temporaryPath -Destination $shortcutPath `
            -Force -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
    }
    $evidence = Get-ValidatedIdentityQueryShortcut $shortcutPath $QueryPath
    Write-Pass "Public Desktop identity-query shortcut installed at $shortcutPath."
    return $evidence
}

function Write-AtomicProtectedJson {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    $directory = Split-Path -Parent $destinationFullPath
    $null = Assert-ProtectedAdminSystemDirectory $directory `
        'protected receipt directory'
    if (Test-Path -LiteralPath $destinationFullPath) {
        $existing = Get-Item -LiteralPath $destinationFullPath -Force `
            -ErrorAction Stop
        if ($existing.PSIsContainer -or
            ($existing.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Protected receipt destination is unsafe: $destinationFullPath"
        }
    }
    $temporaryPath = Join-Path $directory (
        '.last-result.{0}.new' -f [Guid]::NewGuid().ToString('N')
    )
    try {
        $Value | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8 `
                -ErrorAction Stop
        $temporaryItem = Assert-RegularLocalPath $temporaryPath `
            'temporary GPU-Z receipt'
        Assert-TrustedGpuZWriteBoundary $temporaryItem `
            'temporary GPU-Z receipt'
        $expectedHash = Get-Sha256 $temporaryItem.FullName
        Move-Item -LiteralPath $temporaryItem.FullName `
            -Destination $destinationFullPath -Force -ErrorAction Stop
        $publishedItem = Assert-RegularLocalPath $destinationFullPath `
            'published GPU-Z receipt'
        Assert-TrustedGpuZWriteBoundary $publishedItem `
            'published GPU-Z receipt'
        if ((Get-Sha256 $publishedItem.FullName) -cne $expectedHash) {
            throw 'Published GPU-Z receipt changed during atomic replacement.'
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
    }
    Write-Pass "atomic GPU-Z receipt published at $destinationFullPath."
}

function Get-SystemNvapiReceipt {
    $images = @(
        @((Join-Path $env:SystemRoot 'System32\nvapi64.dll'), 0x8664),
        @((Join-Path $env:SystemRoot 'SysWOW64\nvapi.dll'), 0x014c)
    )
    $receipt = [ordered]@{}
    foreach ($image in $images) {
        $path = [string]$image[0]
        $machine = [int]$image[1]
        $null = Assert-NvidiaProductionImage $path $machine 'system NVAPI source'
        $receipt[$path] = Get-Sha256 $path
    }
    Write-Pass 'system NVAPI sources are valid NVIDIA/WHCP images.'
    return $receipt
}

function Assert-SystemNvapiUnchanged {
    param([Parameter(Mandatory = $true)][object]$Before)
    foreach ($item in $Before.GetEnumerator()) {
        $after = Get-Sha256 ([string]$item.Key)
        if ($after -cne [string]$item.Value) {
            throw "System NVAPI changed unexpectedly: $($item.Key)"
        }
    }
    Write-Pass 'System32 and SysWOW64 NVAPI hashes are unchanged.'
}

function Test-HklmRegistrySubKeyExists {
    param([Parameter(Mandatory = $true)][string]$SubKey)

    # Do not probe optional keys with reg.exe.  On Windows PowerShell 5.1 a
    # missing key writes a NativeCommandError record; with this installer's
    # fail-closed ErrorActionPreference that expected absence becomes a
    # terminating error before $LASTEXITCODE can be inspected.
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($SubKey, $false)
        return $null -ne $key
    } finally {
        if ($null -ne $key) {
            $key.Dispose()
        }
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }
}

function New-GuestBackup {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$DisplayState,
        [Parameter(Mandatory = $true)][object]$SystemNvapi
    )
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    $bindingLabel = if ([string]$Contract.BindingMode -ceq 'portable-auto') {
        'portable-{0}-{1}' -f $Contract.GpuProfile,
            ([string]$Contract.VmUuid).Replace('-', '').Substring(0, 12)
    } else {
        "vm$($Contract.VmId)"
    }
    $name = '{0}-{1}-{2}' -f $bindingLabel,
        [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'),
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $root = Join-Path $BackupRoot $name
    New-Item -Path $root -ItemType Directory -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $ContractPath -Destination `
        (Join-Path $root 'gpuz-contract.json')

    $inventory = [ordered]@{
        createdUtc = [DateTime]::UtcNow.ToString('o')
        display = @(
            Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
                Select-Object Status, Class, FriendlyName, InstanceId, Present
        )
        activeController = $DisplayState.Controller
        parentId = $DisplayState.ParentId
        kernelDriverPath = $DisplayState.KernelDriverPath
        driverInfPath = $DisplayState.DriverInfPath
        driverCatalogPath = $DisplayState.DriverCatalogPath
        systemNvapiSha256 = $SystemNvapi
    }
    $inventory | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $root 'inventory.json') -Encoding UTF8

    $nvapiSubKey = 'SOFTWARE\NVIDIA Corporation\Global\NvAPI'
    if (Test-HklmRegistrySubKeyExists $nvapiSubKey) {
        & $SystemReg export ("HKLM\{0}" -f $nvapiSubKey) `
            (Join-Path $root 'nvapi-before.reg') /y *> $null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not export the existing NVAPI identity registry key.'
        }
    } else {
        'ABSENT' | Set-Content -LiteralPath `
            (Join-Path $root 'nvapi-before.absent.txt') -Encoding ASCII
    }
    $oldTask = Get-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue
    if ($null -ne $oldTask) {
        Export-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' |
            Set-Content -LiteralPath (Join-Path $root 'RefreshGridNames-before.xml') `
                -Encoding Unicode
    }
    Write-Pass "guest pre-change receipt saved at $root."
    return $root
}

function Invoke-ProfilePatch {
    param(
        [Parameter(Mandatory = $true)][object]$Gpu,
        [Parameter(Mandatory = $true)][string]$PatchPath,
        [string]$CatalogPath = '',
        [string]$CatalogSha256 = '',
        [switch]$NativeBOnly
    )
    $arguments = @{
        ProfileKey = [string]$Gpu.profile
        TargetName = [string]$Gpu.name
        NvapiPciVendorId = [int]$Gpu.nvapiPciVendorId
        NvapiPciDeviceId = [int]$Gpu.nvapiPciDeviceId
        NvapiPciSubVendorId = [int]$Gpu.nvapiPciSubVendorId
        NvapiPciSubDeviceId = [int]$Gpu.nvapiPciSubDeviceId
        NvapiPciRevisionId = [int]$Gpu.nvapiPciRevisionId
        CoreClockMHz = [int]$Gpu.coreClockMHz
        BoostClockMHz = [int]$Gpu.boostClockMHz
        MemoryClockMHz = [int]$Gpu.memoryClockMHz
        MemoryBusBits = [int]$Gpu.memoryBusBits
        MemoryBandwidthMBps = [int]$Gpu.memoryBandwidthMBps
        VramMB = [int]$Gpu.vramMB
        MemoryType = [int]$Gpu.memoryType
        MemoryMaker = [int]$Gpu.memoryMaker
        CudaCores = [int]$Gpu.cudaCores
        ShaderSubPipes = [int]$Gpu.shaderSubPipes
        RopCount = [int]$Gpu.ropCount
        TmuCount = [int]$Gpu.tmuCount
        Architecture = [int]$Gpu.architecture
        Implementation = [int]$Gpu.implementation
        ChipRevision = [int]$Gpu.chipRevision
        PcieWidth = [int]$Gpu.pcieWidth
        VbiosVersion = [string]$Gpu.vbiosVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($CatalogPath)) {
        $arguments.CatalogPath = $CatalogPath
    }
    if (-not [string]::IsNullOrWhiteSpace($CatalogSha256)) {
        $arguments.CatalogSha256 = $CatalogSha256
    }
    if ($NativeBOnly) {
        $arguments.DeviceIdMatch = @('VEN_10DE&DEV_1E30')
    }
    & $PatchPath @arguments
}

function Install-AuditedAProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$Gpu
    )
    if ($Contract.GpuProfile -cne 'gtx1050_2gb' -or
        $Contract.SpoofMode -cne 'A') {
        throw 'Internal error: strict-A installer was selected for an unsupported profile.'
    }
    New-Item -Path $VersionRoot -ItemType Directory -Force | Out-Null
    $version = Join-Path $VersionRoot (
        'vm{0}-{1}-{2}' -f $Contract.VmId,
        [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'),
        [Guid]::NewGuid().ToString('N').Substring(0, 12)
    )
    New-Item -Path $version -ItemType Directory -ErrorAction Stop | Out-Null
    $versionPatch = Join-Path $version 'patch-grid-strings.ps1'
    $versionProfile = Join-Path $version 'profile.json'
    Copy-Item -LiteralPath (Join-Path $BundleRoot 'patch-grid-strings.ps1') `
        -Destination $versionPatch
    Copy-Item -LiteralPath $Contract.ProfilePath -Destination $versionProfile
    if ((Get-Sha256 $versionPatch) -cne
            (Get-Sha256 (Join-Path $BundleRoot 'patch-grid-strings.ps1')) -or
        (Get-Sha256 $versionProfile) -cne (Get-Sha256 $Contract.ProfilePath)) {
        throw 'Protected strict-A task assets failed post-copy hash verification.'
    }

    $oldTask = Get-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue
    $oldXml = if ($null -ne $oldTask) {
        Export-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\'
    } else {
        $null
    }
    try {
        Invoke-ProfilePatch $Gpu $versionPatch
        $argumentText = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ' +
            '-File "' + $versionPatch + '" ' +
            '-ProfileKey "' + [string]$Gpu.profile + '" ' +
            '-TargetName "' + [string]$Gpu.name + '" ' +
            '-NvapiPciVendorId ' + [int]$Gpu.nvapiPciVendorId + ' ' +
            '-NvapiPciDeviceId ' + [int]$Gpu.nvapiPciDeviceId + ' ' +
            '-NvapiPciSubVendorId ' + [int]$Gpu.nvapiPciSubVendorId + ' ' +
            '-NvapiPciSubDeviceId ' + [int]$Gpu.nvapiPciSubDeviceId + ' ' +
            '-NvapiPciRevisionId ' + [int]$Gpu.nvapiPciRevisionId + ' ' +
            '-CoreClockMHz ' + [int]$Gpu.coreClockMHz + ' ' +
            '-BoostClockMHz ' + [int]$Gpu.boostClockMHz + ' ' +
            '-MemoryClockMHz ' + [int]$Gpu.memoryClockMHz + ' ' +
            '-MemoryBusBits ' + [int]$Gpu.memoryBusBits + ' ' +
            '-MemoryBandwidthMBps ' + [int]$Gpu.memoryBandwidthMBps + ' ' +
            '-VramMB ' + [int]$Gpu.vramMB + ' ' +
            '-MemoryType ' + [int]$Gpu.memoryType + ' ' +
            '-MemoryMaker ' + [int]$Gpu.memoryMaker + ' ' +
            '-CudaCores ' + [int]$Gpu.cudaCores + ' ' +
            '-ShaderSubPipes ' + [int]$Gpu.shaderSubPipes + ' ' +
            '-RopCount ' + [int]$Gpu.ropCount + ' ' +
            '-TmuCount ' + [int]$Gpu.tmuCount + ' ' +
            '-Architecture ' + [int]$Gpu.architecture + ' ' +
            '-Implementation ' + [int]$Gpu.implementation + ' ' +
            '-ChipRevision ' + [int]$Gpu.chipRevision + ' ' +
            '-PcieWidth ' + [int]$Gpu.pcieWidth + ' ' +
            '-VbiosVersion "' + [string]$Gpu.vbiosVersion + '"'
        $action = New-ScheduledTaskAction -Execute $SystemPowerShell `
            -Argument $argumentText
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId SYSTEM `
            -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) `
            -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
            -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Force | Out-Null
    } catch {
        $installError = $_
        try {
            if ($null -ne $oldXml) {
                Register-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
                    -Xml $oldXml -Force | Out-Null
            } else {
                Unregister-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
                    -Confirm:$false -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $version -Recurse -Force `
                -ErrorAction SilentlyContinue
        } catch {
            throw "Strict-A profile failed ($($installError.Exception.Message)); task rollback also failed: $($_.Exception.Message)"
        }
        throw $installError
    }
    Write-Pass 'audited GTX 1050 A profile and offline startup refresh were installed.'
}

function Install-PortableBProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$Gpu
    )
    if ([string]$Contract.BindingMode -cne 'portable-auto' -or
        $Contract.SpoofMode -cne 'B' -or
        $Contract.ExpectedPnpId -cne 'PCI\VEN_10DE&DEV_1E30') {
        throw 'Internal error: portable installer was selected outside B/native mode.'
    }
    New-Item -Path $VersionRoot -ItemType Directory -Force | Out-Null
    $uuidToken = ([string]$Contract.VmUuid).Replace('-', '').Substring(0, 12)
    $version = Join-Path $VersionRoot (
        'portable-{0}-{1}-{2}-{3}' -f $Contract.GpuProfile, $uuidToken,
        [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'),
        [Guid]::NewGuid().ToString('N').Substring(0, 12)
    )
    New-Item -Path $version -ItemType Directory -ErrorAction Stop | Out-Null
    $versionPatch = Join-Path $version 'patch-grid-strings.ps1'
    $versionProfile = Join-Path $version 'profile.json'
    $versionCatalog = Join-Path $version 'vgpu-profile-catalog.json'
    Copy-Item -LiteralPath (Join-Path $BundleRoot 'patch-grid-strings.ps1') `
        -Destination $versionPatch
    Copy-Item -LiteralPath $Contract.ProfilePath -Destination $versionProfile
    Copy-Item -LiteralPath $Contract.CatalogPath -Destination $versionCatalog
    if ((Get-Sha256 $versionPatch) -cne
            (Get-Sha256 (Join-Path $BundleRoot 'patch-grid-strings.ps1')) -or
        (Get-Sha256 $versionProfile) -cne (Get-Sha256 $Contract.ProfilePath) -or
        (Get-Sha256 $versionCatalog) -cne $Contract.CatalogAssetSha256) {
        throw 'Protected portable task assets failed post-copy hash verification.'
    }

    $oldTask = Get-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
        -ErrorAction SilentlyContinue
    $oldXml = if ($null -ne $oldTask) {
        Export-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\'
    } else {
        $null
    }
    try {
        Invoke-ProfilePatch $Gpu $versionPatch `
            -CatalogPath $versionCatalog `
            -CatalogSha256 $Contract.CatalogSha256 -NativeBOnly
        $argumentText = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ' +
            '-File "' + $versionPatch + '" ' +
            '-CatalogPath "' + $versionCatalog + '" ' +
            '-CatalogSha256 "' + [string]$Contract.CatalogSha256 + '" ' +
            '-ProfileKey "' + [string]$Gpu.profile + '" ' +
            '-TargetName "' + [string]$Gpu.name + '" ' +
            '-NvapiPciVendorId ' + [int]$Gpu.nvapiPciVendorId + ' ' +
            '-NvapiPciDeviceId ' + [int]$Gpu.nvapiPciDeviceId + ' ' +
            '-NvapiPciSubVendorId ' + [int]$Gpu.nvapiPciSubVendorId + ' ' +
            '-NvapiPciSubDeviceId ' + [int]$Gpu.nvapiPciSubDeviceId + ' ' +
            '-NvapiPciRevisionId ' + [int]$Gpu.nvapiPciRevisionId + ' ' +
            '-CoreClockMHz ' + [int]$Gpu.coreClockMHz + ' ' +
            '-BoostClockMHz ' + [int]$Gpu.boostClockMHz + ' ' +
            '-MemoryClockMHz ' + [int]$Gpu.memoryClockMHz + ' ' +
            '-MemoryBusBits ' + [int]$Gpu.memoryBusBits + ' ' +
            '-MemoryBandwidthMBps ' + [int]$Gpu.memoryBandwidthMBps + ' ' +
            '-VramMB ' + [int]$Gpu.vramMB + ' ' +
            '-MemoryType ' + [int]$Gpu.memoryType + ' ' +
            '-MemoryMaker ' + [int]$Gpu.memoryMaker + ' ' +
            '-CudaCores ' + [int]$Gpu.cudaCores + ' ' +
            '-ShaderSubPipes ' + [int]$Gpu.shaderSubPipes + ' ' +
            '-RopCount ' + [int]$Gpu.ropCount + ' ' +
            '-TmuCount ' + [int]$Gpu.tmuCount + ' ' +
            '-Architecture ' + [int]$Gpu.architecture + ' ' +
            '-Implementation ' + [int]$Gpu.implementation + ' ' +
            '-ChipRevision ' + [int]$Gpu.chipRevision + ' ' +
            '-PcieWidth ' + [int]$Gpu.pcieWidth + ' ' +
            '-VbiosVersion "' + [string]$Gpu.vbiosVersion + '" ' +
            '-DeviceIdMatch "VEN_10DE&DEV_1E30"'
        $action = New-ScheduledTaskAction -Execute $SystemPowerShell `
            -Argument $argumentText
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId SYSTEM `
            -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) `
            -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
            -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Force | Out-Null
    } catch {
        $installError = $_
        try {
            if ($null -ne $oldXml) {
                Register-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
                    -Xml $oldXml -Force | Out-Null
            } else {
                Unregister-ScheduledTask -TaskName $RefreshTaskName -TaskPath '\' `
                    -Confirm:$false -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $version -Recurse -Force `
                -ErrorAction SilentlyContinue
        } catch {
            throw "Portable profile failed ($($installError.Exception.Message)); task rollback also failed: $($_.Exception.Message)"
        }
        throw $installError
    }
    Write-Pass "portable B/native profile '$($Contract.GpuProfile)' and offline startup refresh were installed."
}

function Install-Profile {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$Gpu
    )
    if ([string]$Contract.BindingMode -ceq 'portable-auto') {
        Install-PortableBProfile $Contract $Gpu
    } elseif ($Contract.SpoofMode -eq 'B') {
        $apply = Join-Path $BundleRoot 'apply-vm-profile.ps1'
        & $SystemPowerShell -NoProfile -ExecutionPolicy Bypass `
            -File $apply -ConfigPath $Contract.ProfilePath
        if ($LASTEXITCODE -ne 0) {
            throw "apply-vm-profile.ps1 failed with exit code $LASTEXITCODE."
        }
        Write-Pass 'B-mode whitelist profile and offline startup refresh were installed.'
    } else {
        Install-AuditedAProfile $Contract $Gpu
    }
}

function Assert-AppLocalShimImage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    $item = Assert-RegularLocalPath $Path 'app-local NVAPI shim'
    if ((Get-PeMachine $item.FullName) -ne 0x014c -or
        (Get-Sha256 $item.FullName) -cne $ExpectedSha256) {
        throw 'The app-local x86 NVAPI shim does not match its manifest hash.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName
    $unsigned = [string]$signature.Status -ceq 'NotSigned' -and
        $null -eq $signature.SignerCertificate
    $normallySigned = [string]$signature.Status -ceq 'Valid' -and
        $null -ne $signature.SignerCertificate -and
        [string]$signature.SignerCertificate.Subject -cne
            [string]$signature.SignerCertificate.Issuer
    if (-not $unsigned -and -not $normallySigned) {
        throw 'The manifest-pinned user-mode shim is neither unsigned nor validly non-self-issued.'
    }
    if ($normallySigned) {
        Assert-MicrosoftRootProgramCertificate `
            $signature.SignerCertificate $item.FullName `
            'app-local NVAPI shim'
    }
    return $item
}

function Install-AppLocalShim {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][string]$ApplicationDirectory
    )
    if ((Get-Sha256 $Contract.ShimPath) -cne $Contract.ShimSha256 -or
        (Get-Sha256 $Contract.ProbePath) -cne $Contract.ProbeSha256) {
        throw 'App-local asset hash differs from the contract.'
    }
    $null = Assert-AppLocalShimImage $Contract.ShimPath $Contract.ShimSha256

    Assert-OutsideWindowsTree $ApplicationDirectory `
        'vGPU identity app-local installation directory'
    $target = Join-Path $ApplicationDirectory 'nvapi.dll'
    $original = Join-Path $ApplicationDirectory 'nvapi_orig.dll'
    $targetExists = Test-Path -LiteralPath $target -PathType Leaf
    $originalExists = Test-Path -LiteralPath $original -PathType Leaf
    if ($targetExists -xor $originalExists) {
        throw 'Refusing an incomplete pre-existing app-local NVAPI pair.'
    }
    if ($targetExists) {
        $targetItem = Assert-AppLocalShimImage $target $Contract.ShimSha256
        $originalItem = Assert-NvidiaProductionImage $original 0x014c `
            'app-local nvapi_orig.dll'
        Assert-TrustedGpuZWriteBoundary $targetItem 'app-local nvapi.dll'
        Assert-TrustedGpuZWriteBoundary $originalItem 'app-local nvapi_orig.dll'
        Assert-UsersReadExecuteAccess $targetItem.FullName `
            'app-local nvapi.dll'
        Assert-UsersReadExecuteAccess $originalItem.FullName `
            'app-local nvapi_orig.dll'
        Write-Pass 'the existing app-local NVAPI pair already matches this bundle.'
        return
    }

    $systemOriginal = Join-Path $env:SystemRoot 'SysWOW64\nvapi.dll'
    $null = Assert-NvidiaProductionImage $systemOriginal 0x014c `
        'system x86 NVAPI source'
    $nonce = [Guid]::NewGuid().ToString('N')
    $temporaryOriginal = Join-Path $ApplicationDirectory `
        ('.qemu-nvapi-original-' + $nonce + '.tmp')
    $temporaryShim = Join-Path $ApplicationDirectory `
        ('.qemu-nvapi-shim-' + $nonce + '.tmp')
    $createdOriginal = $false
    $createdTarget = $false
    try {
        Copy-Item -LiteralPath $systemOriginal -Destination $temporaryOriginal `
            -ErrorAction Stop
        Copy-Item -LiteralPath $Contract.ShimPath -Destination $temporaryShim `
            -ErrorAction Stop
        $null = Assert-NvidiaProductionImage $temporaryOriginal 0x014c `
            'staged app-local nvapi_orig.dll'
        $null = Assert-AppLocalShimImage $temporaryShim $Contract.ShimSha256
        Move-Item -LiteralPath $temporaryOriginal -Destination $original `
            -ErrorAction Stop
        $createdOriginal = $true
        Move-Item -LiteralPath $temporaryShim -Destination $target `
            -ErrorAction Stop
        $createdTarget = $true
        $originalItem = Assert-NvidiaProductionImage $original 0x014c `
            'installed app-local nvapi_orig.dll'
        $targetItem = Assert-AppLocalShimImage $target $Contract.ShimSha256
        Assert-TrustedGpuZWriteBoundary $originalItem 'app-local nvapi_orig.dll'
        Assert-TrustedGpuZWriteBoundary $targetItem 'app-local nvapi.dll'
        Assert-UsersReadExecuteAccess $originalItem.FullName `
            'app-local nvapi_orig.dll'
        Assert-UsersReadExecuteAccess $targetItem.FullName `
            'app-local nvapi.dll'
    } catch {
        $installError = $_
        if ($createdTarget) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
        if ($createdOriginal) {
            Remove-Item -LiteralPath $original -Force -ErrorAction SilentlyContinue
        }
        throw $installError
    } finally {
        Remove-Item -LiteralPath $temporaryOriginal -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryShim -Force `
            -ErrorAction SilentlyContinue
    }
    Write-Pass 'hash-pinned x86 NVAPI shim installed only in the protected identity application directory.'
}

function Get-ValidatedIdentityQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    $item = Assert-RegularLocalPath $Path 'authoritative vGPU identity query'
    if ((Get-PeMachine $item.FullName) -ne 0x014c -or
        (Get-Sha256 $item.FullName) -cne $ExpectedSha256) {
        throw 'The vGPU identity query does not match its x86 manifest image.'
    }
    Assert-TrustedGpuZWriteBoundary $item 'authoritative vGPU identity query'
    Assert-UsersReadExecuteAccess $item.FullName `
        'authoritative vGPU identity query'
    return $item
}

function Install-IdentityQuery {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][string]$ApplicationDirectory
    )
    if ([int]$Contract.ContractSchemaVersion -notin @(5, 6, 7)) {
        return $null
    }
    if ((Get-Sha256 $Contract.QueryPath) -cne $Contract.QuerySha256 -or
        (Get-PeMachine $Contract.QueryPath) -ne 0x014c) {
        throw 'The bundled authoritative query asset failed hash/PE validation.'
    }
    Assert-OutsideWindowsTree $ApplicationDirectory `
        'vGPU identity query installation directory'
    $target = Join-Path $ApplicationDirectory 'VgpuIdentityQuery.exe'
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        try {
            return (Get-ValidatedIdentityQuery $target $Contract.QuerySha256)
        } catch {
            # A prior owned query generation may be replaced atomically below.
        }
    } elseif (Test-Path -LiteralPath $target) {
        throw "The owned vGPU identity query path is not a regular file: $target"
    }
    $temporary = Join-Path $ApplicationDirectory (
        '.VgpuIdentityQuery.{0}.new' -f [Guid]::NewGuid().ToString('N')
    )
    try {
        Copy-Item -LiteralPath $Contract.QueryPath -Destination $temporary `
            -ErrorAction Stop
        $null = Set-AdminSystemUsersReadExecuteFile $temporary `
            'staged authoritative vGPU identity query'
        $temporaryItem = Assert-RegularLocalPath $temporary `
            'staged authoritative vGPU identity query'
        if ((Get-PeMachine $temporaryItem.FullName) -ne 0x014c -or
            (Get-Sha256 $temporaryItem.FullName) -cne $Contract.QuerySha256) {
            throw 'Staged authoritative query changed before publication.'
        }
        Move-Item -LiteralPath $temporary -Destination $target -Force `
            -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
    }
    $item = Get-ValidatedIdentityQuery $target $Contract.QuerySha256
    Write-Pass 'authoritative native/projected vGPU identity query installed.'
    return $item
}

function Invoke-IdentityQuery {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][string]$QueryPath
    )
    $null = Get-ValidatedIdentityQuery $QueryPath $Contract.QuerySha256
    $output = (& $QueryPath 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '(?m)^VERIFY PASS\s*$') {
        throw "Authoritative vGPU identity query failed.`n$output"
    }
    Write-Pass 'authoritative query separates native DEV_1E30 transport from the exact projected board/VRAM row.'
    return $output
}

function Assert-OutputMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Output -notmatch $Pattern) {
        throw "NVAPI probe mismatch for $Label."
    }
}

function Invoke-AppLocalProbe {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$Gpu,
        [Parameter(Mandatory = $true)][string]$ApplicationDirectory
    )
    Assert-OutsideWindowsTree $ApplicationDirectory `
        'vGPU identity app-local probe directory'
    $target = Join-Path $ApplicationDirectory 'nvapi.dll'
    $original = Join-Path $ApplicationDirectory 'nvapi_orig.dll'
    if ((Get-Sha256 $target) -cne $Contract.ShimSha256) {
        throw 'Installed app-local nvapi.dll hash is incorrect.'
    }
    $originalItem = Assert-NvidiaProductionImage $original 0x014c `
        'app-local nvapi_orig.dll'
    $targetItem = Assert-AppLocalShimImage $target $Contract.ShimSha256
    Assert-TrustedGpuZWriteBoundary $originalItem 'app-local nvapi_orig.dll'
    Assert-TrustedGpuZWriteBoundary $targetItem 'app-local nvapi.dll'
    Assert-UsersReadExecuteAccess $originalItem.FullName `
        'app-local nvapi_orig.dll'
    Assert-UsersReadExecuteAccess $targetItem.FullName `
        'app-local nvapi.dll'

    $probeTarget = Join-Path $ApplicationDirectory 'nvapi_profile_probe32.exe'
    if (Test-Path -LiteralPath $probeTarget) {
        throw "Close/remove the conflicting test probe before verification: $probeTarget"
    }
    try {
        Copy-Item -LiteralPath $Contract.ProbePath -Destination $probeTarget
        if ((Get-Sha256 $probeTarget) -cne $Contract.ProbeSha256) {
            throw 'Temporary probe copy failed hash verification.'
        }
        $probeItem = Assert-RegularLocalPath $probeTarget `
            'temporary app-local NVAPI probe'
        Assert-TrustedGpuZWriteBoundary $probeItem `
            'temporary app-local NVAPI probe'
        $probeOutput = (& $probeTarget 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "NVAPI probe failed with exit code $LASTEXITCODE.`n$probeOutput"
        }
    } finally {
        Remove-Item -LiteralPath $probeTarget -Force -ErrorAction SilentlyContinue
    }

    $escapedName = [regex]::Escape([string]$Gpu.name)
    $escapedVbios = [regex]::Escape([string]$Gpu.vbiosVersion)
    $coreKHz = [int64]$Gpu.coreClockMHz * 1000
    $boostKHz = [int64]$Gpu.boostClockMHz * 1000
    $memoryRawKHz = [int64]$Gpu.memoryClockMHz * 2000
    $derivedBandwidth = [int64](
        $memoryRawKHz * 2 * [int64]$Gpu.memoryBusBits / 8000
    )
    $archHex = '{0:X8}' -f [int64]$Gpu.architecture
    $implHex = '{0:X8}' -f [int64]$Gpu.implementation
    $revHex = '{0:X8}' -f [int64]$Gpu.chipRevision
    $pciDeviceHex = '{0:X8}' -f (
        ([int64]$Gpu.nvapiPciDeviceId -shl 16) -bor
        [int64]$Gpu.nvapiPciVendorId
    )
    $pciSubsystemHex = '{0:X8}' -f (
        ([int64]$Gpu.nvapiPciSubDeviceId -shl 16) -bor
        [int64]$Gpu.nvapiPciSubVendorId
    )
    $pciRevisionHex = '{0:X2}' -f [int64]$Gpu.nvapiPciRevisionId
    $pciExternalHex = '{0:X4}' -f [int64]$Gpu.nvapiPciDeviceId

    Assert-OutputMatch $probeOutput `
        '(?m)^EnumPhysicalGPUs\s+status=0 count=1\s*$' 'one NVAPI GPU'
    Assert-OutputMatch $probeOutput `
        "(?m)^Full name\s+status=0 value=$escapedName\s*$" 'full name'
    Assert-OutputMatch $probeOutput `
        "(?m)^VBIOS\s+status=0 value=$escapedVbios\s*$" 'VBIOS'
    Assert-OutputMatch $probeOutput `
        ("(?m)^PCI identifiers\s+status=0 device=0x{0} subsystem=0x{1} revision=0x{2} external=0x{3}\s*$" -f
            $pciDeviceHex, $pciSubsystemHex, $pciRevisionHex,
            $pciExternalHex) 'app-local PCI identifiers'
    foreach ($check in @(
        @('CUDA cores', [int64]$Gpu.cudaCores),
        @('Shader subpipes', [int64]$Gpu.shaderSubPipes),
        @('ROP count', [int64]$Gpu.ropCount),
        @('TMU count', [int64]$Gpu.tmuCount),
        @('RAM maker', [int64]$Gpu.memoryMaker),
        @('RAM type', [int64]$Gpu.memoryType),
        @('RAM bus width', [int64]$Gpu.memoryBusBits),
        @('PCIe width', [int64]$Gpu.pcieWidth)
    )) {
        Assert-OutputMatch $probeOutput `
            ("(?m)^{0}\s+status=0 value={1}(?:\s|\()" -f
                [regex]::Escape([string]$check[0]), [int64]$check[1]) `
            ([string]$check[0])
    }
    Assert-OutputMatch $probeOutput `
        ("(?m)^GetPerfClocks\s+status=0 .*core_cur={0} core_def={0} memory_cur={1} memory_def={1}\s*$" -f
            $coreKHz, $memoryRawKHz) 'GPU-Z private clocks'
    Assert-OutputMatch $probeOutput `
        ("(?m)^GetPstates20\s+status=0 .*base={0} boost={1} memory_raw={2}\s*$" -f
            $coreKHz, $boostKHz, $memoryRawKHz) 'Pstates20 clocks'
    Assert-OutputMatch $probeOutput `
        ("(?m)^Memory bandwidth\s+raw_xfers=2 derived={0} MB/s" -f
            $derivedBandwidth) 'derived bandwidth'
    Assert-OutputMatch $probeOutput `
        ("(?m)^Architecture\s+status=0 arch=0x{0} impl=0x{1} rev=0x{2}\s*$" -f
            $archHex, $implHex, $revHex) 'architecture'
    Assert-OutputMatch $probeOutput `
        '(?m)^GPU info\s+status=0 RT=0 Tensor=0\s*$' `
        'zero hardware RT/Tensor cores'
    Write-Pass 'x86 app-local NVAPI probe reports one GPU and every catalog field.'
    return $probeOutput
}

function Get-NvidiaSmiPath {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Assert-RegularLocalPath $candidate 'NVIDIA SMI query').FullName
        }
    }
    $command = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command -and
        -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return (Assert-RegularLocalPath ([string]$command.Source) `
            'NVIDIA SMI query').FullName
    }
    throw 'nvidia-smi.exe was not found; install GRID 538.33 first.'
}

function Get-PrivateLicenseEvidence {
    param([Parameter(Mandatory = $true)][object]$Contract)
    if ([int]$Contract.ContractSchemaVersion -ne 7) {
        throw 'Private license verification requires contract schema 7.'
    }
    $tokenDirectory = Join-Path $env:ProgramFiles `
        'NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
    $tokenPath = Join-Path $tokenDirectory `
        'client_configuration_token.tok'
    $tokenItem = Assert-RegularLocalPath $tokenPath `
        'installed private vGPU license token'
    if ([int64]$tokenItem.Length -ne [int64]$Contract.LicenseTokenBytes -or
        (Get-Sha256 $tokenItem.FullName) -cne
            [string]$Contract.LicenseTokenSha256) {
        throw 'Installed vGPU license token does not match the private package.'
    }
    $service = Get-Service -Name 'NVDisplay.ContainerLocalSystem' `
        -ErrorAction Stop
    if ($service.Status -ne
        [System.ServiceProcess.ServiceControllerStatus]::Running) {
        throw 'NVDisplay.ContainerLocalSystem is not running.'
    }
    $nvidiaSmi = Get-NvidiaSmiPath
    $queryLines = @(& $nvidiaSmi '-q' 2>&1)
    $queryExitCode = $LASTEXITCODE
    $query = $queryLines -join [Environment]::NewLine
    if ($queryExitCode -ne 0) {
        throw "nvidia-smi -q failed with exit code $queryExitCode."
    }
    if ($query -notmatch
        '(?im)^\s*License Status\s*:\s*Licensed(?:\s+\([^\r\n]*\))?\s*$') {
        throw 'NVIDIA license status is not Licensed.'
    }
    Write-Pass 'the exact token is installed and NVIDIA reports Licensed.'
    return [pscustomobject]@{
        tokenPath = $tokenItem.FullName
        tokenSha256 = [string]$Contract.LicenseTokenSha256
        tokenBytes = [int64]$tokenItem.Length
        service = [string]$service.Status
        licenseStatus = 'Licensed'
    }
}

function Install-PrivateLicenseToken {
    param([Parameter(Mandatory = $true)][object]$Contract)
    if ([int]$Contract.ContractSchemaVersion -ne 7) {
        throw 'Private license installation requires contract schema 7.'
    }
    $null = Assert-RegularLocalPath $Contract.LicenseInstallerPath `
        'embedded private vGPU license installer'
    $source = Assert-RegularLocalPath $Contract.LicenseTokenPath `
        'embedded private vGPU license token'
    if ([int64]$source.Length -ne [int64]$Contract.LicenseTokenBytes -or
        (Get-Sha256 $source.FullName) -cne
            [string]$Contract.LicenseTokenSha256) {
        throw 'Private token changed after contract validation.'
    }

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', [string]$Contract.LicenseInstallerPath,
        '-TokenFile', $source.FullName,
        '-ExpectedTokenSha256', [string]$Contract.LicenseTokenSha256
    )
    $licenseOutput = @(& $SystemPowerShell @arguments 2>&1)
    $licenseExitCode = $LASTEXITCODE
    foreach ($line in $licenseOutput) {
        Write-Host ([string]$line)
    }
    if ($licenseExitCode -ne 0) {
        $detail = ($licenseOutput | Out-String).Trim()
        throw "Private vGPU license installation failed (exit $licenseExitCode): $detail"
    }
    return Get-PrivateLicenseEvidence $Contract
}

function Assert-HibernationAndFastStartupDisabled {
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $settings = Get-ItemProperty -LiteralPath $powerKey `
        -Name HiberbootEnabled -ErrorAction Stop
    $hiberboot = [int]$settings.HiberbootEnabled
    $hiberfile = Join-Path $env:SystemDrive 'hiberfil.sys'
    $hiberfilePresent = Test-Path -LiteralPath $hiberfile
    if ($hiberboot -ne 0 -or $hiberfilePresent) {
        throw ('Hibernation/Fast Startup is still enabled ' +
            "(HiberbootEnabled=$hiberboot, hiberfil.sys=$hiberfilePresent).")
    }
    Write-Pass 'hibernation and Fast Startup are disabled.'
    return [pscustomobject]@{
        hibernationDisabled = $true
        fastStartupDisabled = $true
        hiberbootEnabled = $hiberboot
        hiberfilePresent = $hiberfilePresent
    }
}

function Disable-HibernationAndFastStartup {
    # This intentionally changes only the supported powercfg/registry state;
    # it never changes BCD integrity policy.
    $powerOutput = @(& $SystemPowerCfg '/hibernate' 'off' 2>&1)
    $powerExitCode = $LASTEXITCODE
    if ($powerExitCode -ne 0) {
        $detail = ($powerOutput | Out-String).Trim()
        throw "powercfg /hibernate off failed (exit $powerExitCode): $detail"
    }
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    New-ItemProperty -Path $powerKey -Name HiberbootEnabled `
        -PropertyType DWord -Value 0 -Force | Out-Null
    return Assert-HibernationAndFastStartupDisabled
}

function Invoke-RecommendGuestPerformance {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Apply', 'Verify')]
        [string]$Mode
    )

    $optimizerPath = Join-Path $BundleRoot 'Optimize-Guest.ps1'
    $optimizer = Assert-RegularLocalPath $optimizerPath `
        'embedded G-11 guest performance optimizer'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $optimizer.FullName,
        '-Mode', $Mode,
        '-StartupDelayMs', '0'
    )
    Write-Host "[vGPU portable] Guest performance $Mode..." `
        -ForegroundColor Cyan
    $performanceOutput = @(& $SystemPowerShell @arguments 2>&1)
    $performanceExitCode = $LASTEXITCODE
    foreach ($line in $performanceOutput) {
        Write-Host ([string]$line)
    }
    $marker = if ($Mode -eq 'Apply') {
        'APPLY PASS: recommended native-display tuning is installed.'
    } else {
        'VERIFY PASS: tuning is active and no owned legacy display helper is running.'
    }
    $outputText = ($performanceOutput | Out-String)
    if ($performanceExitCode -ne 0 -or $outputText -notmatch `
            ('(?m)^' + [regex]::Escape($marker) + '\s*$')) {
        $detail = $outputText.Trim()
        throw "Embedded guest performance $Mode failed (exit $performanceExitCode): $detail"
    }
    return [pscustomobject]@{
        mode = $Mode
        status = 'PASS'
        profile = 'recommended-native-v1'
        stateRoot = (Join-Path $env:ProgramData 'G11GuestPerformance')
    }
}

function Invoke-PortableIdentityMain {
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$Gpu,
        [Parameter(Mandatory = $true)][object]$DisplayState,
        [Parameter(Mandatory = $true)][object]$SystemNvapi
    )
    $applicationDirectory = $Contract.IdentityApplicationDirectory
    $queryPath = Join-Path $applicationDirectory 'VgpuIdentityQuery.exe'

    if ($VerifyOnly) {
        $null = Assert-ProtectedAdminSystemDirectory $ApplicationsRoot `
            'vGPU identity applications root' -AllowUsersReadExecute
        $null = Assert-ProtectedAdminSystemDirectory $applicationDirectory `
            'vGPU identity application directory' -AllowUsersReadExecute
        $null = Invoke-AppLocalProbe $Contract $Gpu $applicationDirectory
        $null = Invoke-IdentityQuery $Contract $queryPath
        $gpuZEvidence = Get-OptionalValidatedGpuZ $Contract
        $licenseEvidence = $null
        $powerEvidence = $null
        if ([int]$Contract.ContractSchemaVersion -eq 7) {
            $licenseEvidence = Get-PrivateLicenseEvidence $Contract
            $powerEvidence = Assert-HibernationAndFastStartupDisabled
        }
        $performanceEvidence = Invoke-RecommendGuestPerformance -Mode Verify
        Assert-SystemNvapiUnchanged $SystemNvapi
        Write-Host ''
        Write-Host '[vGPU identity] VERIFY PASS; no changes were made.' `
            -ForegroundColor Green
        Write-Host ('  GPU-Z:     ' + $(if ($null -eq $gpuZEvidence) {
            'not installed (optional)'
        } else {
            'installed and verified'
        }))
        if ([int]$Contract.ContractSchemaVersion -eq 7) {
            Write-Host "  License:   $($licenseEvidence.licenseStatus)"
            Write-Host '  Power:     hibernation/Fast Startup disabled'
        }
        Write-Host "  Guest:     $($performanceEvidence.profile) verified"
        return
    }

    # Optional GPU-Z is intentionally outside the default dependency graph.
    # Only the explicit switch makes its source a pre-mutation requirement.
    $existingGpuZ = Get-OptionalValidatedGpuZ $Contract
    if ($InstallGpuZ) {
        if (-not (Test-Path -LiteralPath $Contract.GpuZSourcePath `
                -PathType Leaf)) {
            throw ('-InstallGpuZ requires the audited official GPU-Z.exe ' +
                'to be imported beside VgpuPortable.exe.')
        }
        $null = Get-GpuZRawEvidence $Contract $Contract.GpuZSourcePath `
            'explicit optional GPU-Z source snapshot' `
            -AdminOnlySourceSnapshot
    } else {
        Write-Pass 'GPU-Z was not selected; identity installation/query continues without it.'
    }

    Initialize-ProtectedState
    $backup = New-GuestBackup $Contract $DisplayState $SystemNvapi
    Install-Profile $Contract $Gpu
    $applicationDirectory = Initialize-ProtectedIdentityApplication $Contract
    Install-AppLocalShim $Contract $applicationDirectory
    $queryItem = Install-IdentityQuery $Contract $applicationDirectory
    if ($null -eq $queryItem) {
        throw 'Schema-6/7 identity installation did not publish its query executable.'
    }
    $queryOutput = Invoke-IdentityQuery $Contract $queryItem.FullName
    $probeOutput = Invoke-AppLocalProbe $Contract $Gpu $applicationDirectory
    $gpuZEvidence = if ($InstallGpuZ) {
        Install-OptionalProtectedGpuZ $Contract
    } else {
        $existingGpuZ
    }
    $licenseEvidence = $null
    $powerEvidence = $null
    if ([int]$Contract.ContractSchemaVersion -eq 7) {
        $licenseEvidence = Install-PrivateLicenseToken $Contract
        $powerEvidence = Disable-HibernationAndFastStartup
    }

    Assert-SystemNvapiUnchanged $SystemNvapi
    Assert-NormalCodeIntegrityBoot
    # The complete PnP topology, loaded kernel image, INF/catalog signature and
    # parent checks already ran before any mutation.  Repeating that full scan
    # here can block forever inside the Windows PnP/signature providers.  The
    # installer changes only owned profile/identity state, so finish with one
    # bounded live controller query plus the independent BCD/system-NVAPI and
    # native app-local probes above.
    $finalDisplayState = $DisplayState
    $postDisplays = @($DisplayState.Display)
    $postController = @(Get-CimInstance Win32_VideoController `
        -OperationTimeoutSec 15 -ErrorAction Stop |
        Where-Object {
            (Test-PnpPrefix ([string]$_.PNPDeviceID) `
                $Contract.ExpectedPnpId) -and
            [int]$_.ConfigManagerErrorCode -eq 0
        })
    if ($postController.Count -ne 1 -or
        [string]$postController[0].Name -cne [string]$Gpu.name -or
        [int]$postController[0].ConfigManagerErrorCode -ne 0) {
        throw 'Final WMI GPU name/PnP/Code 0 acceptance failed.'
    }
    Write-Pass 'bounded final WMI query still reports the accepted GPU name/PnP/Code 0.'

    $null = Get-ValidatedIdentityQuery $queryItem.FullName $Contract.QuerySha256
    if ($null -ne $gpuZEvidence) {
        $gpuZEvidence = Get-ValidatedGpuZ $Contract
    }
    $queryShortcutEvidence = Install-PublicIdentityQueryShortcut `
        $queryItem.FullName
    $gpuZShortcutEvidence = if ($null -ne $gpuZEvidence) {
        Install-PublicGpuZShortcut ([string]$gpuZEvidence.path)
    } else {
        $null
    }
    $performanceEvidence = Invoke-RecommendGuestPerformance -Mode Apply

    $result = [ordered]@{
        receiptType = 'vgpu-identity-portable-final'
        schemaVersion = if ([int]$Contract.ContractSchemaVersion -eq 7) {
            4
        } else {
            3
        }
        completedUtc = [DateTime]::UtcNow.ToString('o')
        bindingMode = [string]$Contract.BindingMode
        observedVmUuid = $Contract.VmUuid
        gpuProfile = $Contract.GpuProfile
        gpuName = [string]$Gpu.name
        gpuBoardBrand = [string]$Gpu.boardBrand
        gpuBoardModel = [string]$Gpu.boardModel
        memoryTypeName = [string]$Gpu.memoryTypeName
        memoryMaker = [int]$Gpu.memoryMaker
        memoryMakerName = [string]$Gpu.memoryMakerName
        memoryMakerNvapiName = [string]$Gpu.memoryMakerNvapiName
        identityScope = [string]$Gpu.identityScope
        identityApplicationDirectory = $applicationDirectory
        pnpDeviceId = [string]$postController[0].PNPDeviceID
        driverVersion = [string]$postController[0].DriverVersion
        displayCount = $postDisplays.Count
        parentId = $finalDisplayState.ParentId
        parentClass = $finalDisplayState.ParentClass
        kernelDriverPath = $finalDisplayState.KernelDriverPath
        driverInfPath = $finalDisplayState.DriverInfPath
        driverCatalogPath = $finalDisplayState.DriverCatalogPath
        gpuZDelivery = [string]$Contract.GpuZDelivery
        gpuZRequested = [bool]$InstallGpuZ
        gpuZInstalled = [bool]($null -ne $gpuZEvidence)
        gpuZExe = if ($null -ne $gpuZEvidence) {
            [string]$gpuZEvidence.path
        } else {
            $null
        }
        gpuZ = $gpuZEvidence
        gpuZShortcut = $gpuZShortcutEvidence
        privateLicensedFinalizer = [bool]([int]$Contract.ContractSchemaVersion -eq 7)
        licenseTokenDelivery = $Contract.LicenseTokenDelivery
        licenseTokenSha256 = $Contract.LicenseTokenSha256
        licenseTokenBytes = [int64]$Contract.LicenseTokenBytes
        license = $licenseEvidence
        power = $powerEvidence
        guestPerformance = $performanceEvidence
        identityQueryExe = $queryItem.FullName
        identityQuerySha256 = $Contract.QuerySha256
        identityQueryShortcut = $queryShortcutEvidence
        identityQuery = $queryOutput
        shimSha256 = $Contract.ShimSha256
        systemNvapiSha256 = $SystemNvapi
        backup = $backup
        probe = $probeOutput
        catalogSha256 = $Contract.CatalogSha256
        profileClaimSource = 'SMBIOS-Type11-read-only'
        profileClaimSha256 = $Contract.FirmwareClaimSha256
        testsigning = $false
        nointegritychecks = $false
        systemNvapiChanged = $false
        hostCommitEligible = $false
    }
    Write-AtomicProtectedJson $result `
        (Join-Path $InstallRoot 'last-result.json')

    Write-Host ''
    Write-Host '[vGPU identity] INSTALL PASS' -ForegroundColor Green
    Write-Host "  GPU:       $($Gpu.name)"
    Write-Host "  Board:     $($Gpu.boardBrand) $($Gpu.boardModel)"
    Write-Host "  VRAM:      $($Gpu.memoryTypeName) / $($Gpu.memoryMakerName) (NVAPI $($Gpu.memoryMakerNvapiName)=$($Gpu.memoryMaker))"
    Write-Host "  PnP:       $($postController[0].PNPDeviceID)"
    Write-Host "  Driver:    $($postController[0].DriverVersion) / Code 0"
    Write-Host "  Query:     $($queryItem.FullName)"
    Write-Host ('  GPU-Z:     ' + $(if ($null -eq $gpuZEvidence) {
        'not installed (optional)'
    } else {
        'installed and verified'
    }))
    Write-Host "  Backup:    $backup"
    Write-Host '  BCD:       testsigning=False, nointegritychecks=False'
    Write-Host '  NVAPI:     app-local only; system DLL hashes unchanged'
    Write-Host "  Guest:     $($performanceEvidence.profile) applied"
    if ([int]$Contract.ContractSchemaVersion -eq 7) {
        Write-Host "  License:   $($licenseEvidence.licenseStatus)"
        Write-Host '  Power:     hibernation/Fast Startup disabled'
        Write-Host '  Next:      fully shut down Windows, then cold-start normally'
    }

    if (-not $NoLaunch) {
        if ($InstallGpuZ) {
            $null = Get-ValidatedGpuZ $Contract
            Start-Process -FilePath ([string]$gpuZEvidence.path) `
                -WorkingDirectory $applicationDirectory | Out-Null
        } else {
            Start-Process -FilePath $queryItem.FullName `
                -ArgumentList '--pause' `
                -WorkingDirectory $applicationDirectory | Out-Null
        }
    }
}

function Invoke-Main {
    Assert-Administrator
    $manifest = Read-And-VerifyBundle
    $contract = Read-And-ValidateContract $manifest
    $gpu = Read-And-ValidateProfile $contract
    Assert-GuestUuid $contract
    Assert-NormalCodeIntegrityBoot
    $displayState = Get-HealthyDisplayStateWithRetry $contract
    $systemNvapi = Get-SystemNvapiReceipt

    $hasIdentitySchema = $contract.PSObject.Properties.Name -contains `
        'ContractSchemaVersion'
    if ($hasIdentitySchema -and
        [int]$contract.ContractSchemaVersion -in @(6, 7)) {
        Invoke-PortableIdentityMain $contract $gpu $displayState $systemNvapi
        return
    }
    if ($InstallGpuZ) {
        throw '-InstallGpuZ is accepted only by the schema-6/7 optional GPU-Z package.'
    }

    if ($VerifyOnly) {
        # Verification is bound only to the deterministic protected installed
        # target.  It never publishes/replaces GPU-Z from the bundle.
        $gpuZEvidence = Get-ValidatedGpuZ $contract
        $applicationExe = [string]$gpuZEvidence.path
        $applicationDirectory = Split-Path -Parent $applicationExe
        $null = Invoke-AppLocalProbe $contract $gpu $applicationDirectory
        if ($hasIdentitySchema -and
            [int]$contract.ContractSchemaVersion -eq 5) {
            $queryPath = Join-Path (Split-Path -Parent $applicationExe) `
                'VgpuIdentityQuery.exe'
            $null = Invoke-IdentityQuery $contract $queryPath
        }
        $verifiedGpuZ = Get-ValidatedGpuZ $contract
        if ([string]$verifiedGpuZ.path -ine [string]$gpuZEvidence.path -or
            [string]$verifiedGpuZ.sha256 -cne [string]$gpuZEvidence.sha256 -or
            [int64]$verifiedGpuZ.bytes -ne [int64]$gpuZEvidence.bytes) {
            throw 'The protected installed GPU-Z target changed during verification.'
        }
        Assert-SystemNvapiUnchanged $systemNvapi
        Write-Host ''
        Write-Host '[GPU-Z profile] VERIFY PASS; no changes were made.' `
            -ForegroundColor Green
        return
    }

    # The external image must pass all content, PE, version and public
    # TechPowerUp signature gates before any profile/registry mutation.  A
    # rerun may omit the sibling only when the deterministic protected target
    # already passes the same complete validation.
    if (Test-Path -LiteralPath $contract.GpuZSourcePath -PathType Leaf) {
        $null = Get-GpuZRawEvidence $contract $contract.GpuZSourcePath `
            'protected external GPU-Z source snapshot' `
            -AdminOnlySourceSnapshot
    } else {
        try {
            $null = Get-ValidatedGpuZ $contract
        } catch {
            if ([string]$contract.GpuZDelivery -ceq 'external-sibling') {
                throw ('The same-directory GPU-Z.exe is missing and no ' +
                    'complete protected GPU-Z 2.70 installation can be reused.')
            }
            throw
        }
        Write-Pass 'no external sibling was supplied; the existing protected exact GPU-Z image will be reused.'
    }

    Initialize-ProtectedState
    $backup = New-GuestBackup $contract $displayState $systemNvapi
    Install-Profile $contract $gpu
    $gpuZEvidence = Install-ProtectedGpuZ $contract
    $applicationExe = [string]$gpuZEvidence.path
    $applicationDirectory = Split-Path -Parent $applicationExe
    Install-AppLocalShim $contract $applicationDirectory
    $queryItem = Install-IdentityQuery $contract $applicationDirectory
    $queryOutput = if ($null -ne $queryItem) {
        Invoke-IdentityQuery $contract $queryItem.FullName
    } else {
        $null
    }
    $probeOutput = Invoke-AppLocalProbe $contract $gpu $applicationDirectory
    Assert-SystemNvapiUnchanged $systemNvapi
    Assert-NormalCodeIntegrityBoot
    $finalDisplayState = Get-HealthyDisplayStateWithRetry $contract
    if ([string]$finalDisplayState.Display.InstanceId -ine
            [string]$displayState.Display.InstanceId -or
        [string]$finalDisplayState.ParentId -ine [string]$displayState.ParentId) {
        throw 'The accepted GPU or its PCI parent changed during installation.'
    }

    $postDisplays = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)
    if ($postDisplays.Count -ne 1) {
        throw "Final present Display count is $($postDisplays.Count), expected one."
    }
    $postController = @(Get-CimInstance Win32_VideoController |
        Where-Object {
            Test-PnpPrefix ([string]$_.PNPDeviceID) $contract.ExpectedPnpId
        })
    if ($postController.Count -ne 1 -or
        [string]$postController[0].Name -cne [string]$gpu.name -or
        [int]$postController[0].ConfigManagerErrorCode -ne 0) {
        throw 'Final WMI GPU name/PnP/Code 0 acceptance failed.'
    }
    # Capture the receipt from the final persistent bytes, after all app-local
    # work and hardware acceptance gates have completed.
    $gpuZEvidence = Get-ValidatedGpuZ $contract
    $applicationExe = [string]$gpuZEvidence.path
    $shortcutEvidence = Install-PublicGpuZShortcut $applicationExe
    $queryShortcutEvidence = if ($null -ne $queryItem) {
        Install-PublicIdentityQueryShortcut $queryItem.FullName
    } else {
        $null
    }

    $result = [ordered]@{
        receiptType = if ([string]$contract.BindingMode -ceq 'portable-auto') {
            'gpuz-portable-final'
        } else {
            'gpuz-vm-bound-final'
        }
        schemaVersion = 2
        completedUtc = [DateTime]::UtcNow.ToString('o')
        bindingMode = [string]$contract.BindingMode
        observedVmUuid = $contract.VmUuid
        gpuProfile = $contract.GpuProfile
        gpuName = [string]$gpu.name
        gpuBoardBrand = [string]$gpu.boardBrand
        gpuBoardModel = [string]$gpu.boardModel
        memoryTypeName = [string]$gpu.memoryTypeName
        memoryMaker = [int]$gpu.memoryMaker
        memoryMakerName = [string]$gpu.memoryMakerName
        memoryMakerNvapiName = [string]$gpu.memoryMakerNvapiName
        identityScope = [string]$gpu.identityScope
        pnpDeviceId = [string]$postController[0].PNPDeviceID
        driverVersion = [string]$postController[0].DriverVersion
        displayCount = $postDisplays.Count
        parentId = $finalDisplayState.ParentId
        parentClass = $finalDisplayState.ParentClass
        kernelDriverPath = $finalDisplayState.KernelDriverPath
        driverInfPath = $finalDisplayState.DriverInfPath
        driverCatalogPath = $finalDisplayState.DriverCatalogPath
        gpuZExe = $applicationExe
        gpuZ = $gpuZEvidence
        gpuZShortcut = $shortcutEvidence
        identityQueryExe = if ($null -ne $queryItem) {
            $queryItem.FullName
        } else {
            $null
        }
        identityQuerySha256 = if ($null -ne $queryItem) {
            $contract.QuerySha256
        } else {
            $null
        }
        identityQueryShortcut = $queryShortcutEvidence
        identityQuery = $queryOutput
        shimSha256 = $contract.ShimSha256
        systemNvapiSha256 = $systemNvapi
        backup = $backup
        probe = $probeOutput
        testsigning = $false
        nointegritychecks = $false
        systemNvapiChanged = $false
        hostCommitEligible = $false
    }
    if ([string]$contract.BindingMode -ceq 'portable-auto') {
        $result['catalogSha256'] = $contract.CatalogSha256
        $result['profileClaimSource'] = 'SMBIOS-Type11-read-only'
        $result['profileClaimSha256'] = $contract.FirmwareClaimSha256
    } else {
        $result['vmId'] = $contract.VmId
        $result['vmUuid'] = $contract.VmUuid
    }
    Write-AtomicProtectedJson $result `
        (Join-Path $InstallRoot 'last-result.json')

    Write-Host ''
    Write-Host '[GPU-Z profile] INSTALL PASS' -ForegroundColor Green
    Write-Host "  GPU:       $($gpu.name)"
    if (-not [string]::IsNullOrWhiteSpace([string]$gpu.boardBrand)) {
        Write-Host "  Board:     $($gpu.boardBrand) $($gpu.boardModel)"
        Write-Host "  VRAM:      $($gpu.memoryTypeName) / $($gpu.memoryMakerName) (NVAPI $($gpu.memoryMakerNvapiName)=$($gpu.memoryMaker))"
        Write-Host "  Scope:     $($gpu.identityScope)"
    }
    Write-Host "  PnP:       $($postController[0].PNPDeviceID)"
    Write-Host "  Driver:    $($postController[0].DriverVersion) / Code 0"
    Write-Host "  Displays:  1 (parent class '$($finalDisplayState.ParentClass)' is not Display)"
    Write-Host "  Backup:    $backup"
    Write-Host '  BCD:       testsigning=False, nointegritychecks=False'
    Write-Host '  NVAPI:     app-local only; system DLL hashes unchanged'

    if (-not $NoLaunch) {
        $launchTarget = Assert-AppLocalShimImage `
            (Join-Path (Split-Path -Parent $applicationExe) 'nvapi.dll') `
            $contract.ShimSha256
        $launchOriginal = Assert-NvidiaProductionImage `
            (Join-Path (Split-Path -Parent $applicationExe) 'nvapi_orig.dll') `
            0x014c 'app-local nvapi_orig.dll before GPU-Z launch'
        Assert-TrustedGpuZWriteBoundary $launchTarget `
            'app-local nvapi.dll before GPU-Z launch'
        Assert-TrustedGpuZWriteBoundary $launchOriginal `
            'app-local nvapi_orig.dll before GPU-Z launch'
        Assert-UsersReadExecuteAccess $launchTarget.FullName `
            'app-local nvapi.dll before GPU-Z launch'
        Assert-UsersReadExecuteAccess $launchOriginal.FullName `
            'app-local nvapi_orig.dll before GPU-Z launch'
        $null = Get-ValidatedGpuZ $contract
        Start-Process -FilePath $applicationExe -WorkingDirectory `
            (Split-Path -Parent $applicationExe) | Out-Null
    }
}

try {
    Invoke-Main
    exit 0
} catch {
    Write-Host ''
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}
