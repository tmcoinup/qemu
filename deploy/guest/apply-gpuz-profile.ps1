#requires -Version 5.1
<#
.SYNOPSIS
  Apply and verify one HTTP-free, app-local GPU-Z identity bundle.

.DESCRIPTION
  This entry point accepts only the three audited 2 GB catalog identities.
  It verifies every bundle asset before mutation, checks the VM UUID, active
  display count, driver health/signature and BCD integrity policy, applies the
  per-VM registry profile, atomically publishes the manifest-bound GPU-Z
  2.70.0 image under protected ProgramData, and installs the x86 shim only
  beside that persistent executable.  BCD, the Driver Store, display-driver
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
    [switch]$NoLaunch
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
$PublicSignerCache = @{}

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
        'manifest.schemaVersion' 1 2
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
    } else {
        throw 'Unsupported manifest schema.'
    }
    $files = @(Get-RequiredProperty $manifest 'files' 'manifest')
    if ($files.Count -lt 8 -or $files.Count -gt 32) {
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
    $allowedRootNames = @('READY', 'bundle-manifest.json') + @($seen.Keys)
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
    Write-Pass "all $($files.Count) HTTP-free bundle assets match the manifest."
    return $manifest
}

function Read-And-ValidatePortableContract {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$RawContract
    )
    Assert-AllowedProperties $Manifest @(
        'schemaVersion', 'bindingMode', 'files'
    ) 'portable manifest'
    if ([int](Get-RequiredProperty $Manifest 'schemaVersion' 'manifest') -ne 2 -or
        [string](Get-RequiredProperty $Manifest 'bindingMode' 'manifest') -cne
            'portable-auto') {
        throw 'Portable contract requires the portable-auto manifest schema.'
    }

    Assert-AllowedProperties $RawContract @(
        'schemaVersion', 'bindingMode', 'spoofMode', 'catalogSha256',
        'expectedPnpId', 'expectedDriverVersion', 'profiles', 'gpuz',
        'appLocal'
    ) 'contract'
    if ((ConvertTo-StrictInt `
            (Get-RequiredProperty $RawContract 'schemaVersion' 'contract') `
            'contract.schemaVersion' 3 3) -ne 3) {
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
    if ($gpuzName -cne 'GPU-Z.exe' -or $gpuzBytes -ne 11642144 -or
        $gpuzVersion -cne '2.70.0' -or
        $gpuzSha256 -cne
            '6CB0EF29682452DE81A9576808881685161411A1FAD00938BA04131159979C29') {
        throw 'Portable contract does not select the audited GPU-Z 2.70 image.'
    }
    $manifestGpuZ = @($manifestFiles | Where-Object {
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
        'contract.schemaVersion' 2 3
    if ($contractSchema -eq 3) {
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
        Assert-AllowedProperties $raw @(
            'schemaVersion', 'bindingMode', 'gpu'
        ) 'profile'
        if ([int]$raw.schemaVersion -ne 1 -or
            [string]$raw.bindingMode -cne 'portable-auto') {
            throw 'Selected profile is not a portable-auto catalog asset.'
        }
    } else {
        Assert-AllowedProperties $raw @(
            'schemaVersion', 'vmId', 'vmUuid', 'spoofMode', 'gpu', 'monitor'
        ) 'profile'
        if ([int]$raw.schemaVersion -ne 1 -or
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
        'implementation', 'chipRevision', 'pcieWidth', 'vbiosVersion'
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
        vramMB = @(2048, 2048)
        memoryType = @(8, 8)
        memoryMaker = @(1, 1)
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
    if ([int64]$gpu.memoryType -ne 8 -or [int64]$gpu.memoryMaker -ne 1) {
        throw 'Only the audited GDDR5(8)/Samsung(1) profile contract is accepted.'
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
    if ([string]$Contract.BindingMode -ceq 'portable-auto') {
        $selected = @($Contract.Profiles | Where-Object {
            [string]$_.Key -ceq [string]$Contract.GpuProfile
        })
        if ($selected.Count -ne 1 -or
            [string]$gpu.name -cne
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
    param([Parameter(Mandatory = $true)][object]$SignedDriver)
    $infName = [string]$SignedDriver.InfName
    if ($infName -notmatch '\A[A-Za-z0-9_.-]+\.inf\z' -or
        $infName.Contains('..')) {
        throw "The active PnP package has an unsafe INF name: '$infName'."
    }
    if (-not (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
        throw 'Get-WindowsDriver is required to authenticate the DriverStore catalog.'
    }
    $packages = @(Get-WindowsDriver -Online -All -ErrorAction Stop |
        Where-Object { [string]$_.Driver -ieq $infName })
    if ($packages.Count -ne 1) {
        throw "Expected one DriverStore package for $infName; observed $($packages.Count)."
    }
    $package = $packages[0]
    # The package-level `-All` row is the canonical package record.  On the
    # target Win10 DISM build, querying the same NVIDIA oemN.inf again with
    # `-Driver` expands it to 1750 model rows, so Count==1 is not a valid
    # package-integrity assertion.
    if ([string]$package.Driver -ine $infName -or
        [string]$package.ProviderName -notmatch `
            '\ANVIDIA(?: Corporation)?\z' -or
        [string]$package.Version -cne [string]$SignedDriver.DriverVersion) {
        throw "DriverStore metadata does not match active package $infName."
    }

    $infItem = Assert-RegularLocalPath `
        ([string]$package.OriginalFileName) 'DriverStore INF'
    $driverStoreRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository')
    ).TrimEnd('\') + '\'
    if (-not $infItem.FullName.StartsWith(
            $driverStoreRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Published INF is outside DriverStore FileRepository: $($infItem.FullName)"
    }
    $infText = [IO.File]::ReadAllText($infItem.FullName)
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

    $signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object {
            [string]$_.DeviceID -ieq [string]$controllers[0].PNPDeviceID
        })
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
    $driverPackage = Get-ValidatedDriverCatalog $signedDrivers[0]

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
        [Parameter(Mandatory = $true)][string]$Context
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
    Assert-UsersReadExecuteAccess $item.FullName $Context
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

function Install-ProtectedGpuZ {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $source = Assert-RegularLocalPath $Contract.GpuZSourcePath `
        'manifest-bound GPU-Z bundle asset'
    if ($source.Name -cne $Contract.GpuZName -or
        [int64]$source.Length -ne [int64]$Contract.GpuZBytes -or
        (Get-Sha256 $source.FullName) -cne $Contract.GpuZSha256) {
        throw 'The manifest-bound GPU-Z source changed before publication.'
    }

    $targetDirectory = $Contract.GpuZApplicationDirectory
    if (Test-Path -LiteralPath $targetDirectory) {
        $evidence = Get-ValidatedGpuZ $Contract
        Write-Pass 'the exact protected GPU-Z application already exists; reusing it.'
        return $evidence
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

    $nvapiKey = 'HKLM\SOFTWARE\NVIDIA Corporation\Global\NvAPI'
    & $SystemReg query $nvapiKey *> $null
    if ($LASTEXITCODE -eq 0) {
        & $SystemReg export $nvapiKey `
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
    Copy-Item -LiteralPath (Join-Path $BundleRoot 'patch-grid-strings.ps1') `
        -Destination $versionPatch
    Copy-Item -LiteralPath $Contract.ProfilePath -Destination $versionProfile
    if ((Get-Sha256 $versionPatch) -cne
            (Get-Sha256 (Join-Path $BundleRoot 'patch-grid-strings.ps1')) -or
        (Get-Sha256 $versionProfile) -cne (Get-Sha256 $Contract.ProfilePath)) {
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
        Invoke-ProfilePatch $Gpu $versionPatch -NativeBOnly
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
        [Parameter(Mandatory = $true)][string]$ApplicationExe
    )
    if ((Get-Sha256 $Contract.ShimPath) -cne $Contract.ShimSha256 -or
        (Get-Sha256 $Contract.ProbePath) -cne $Contract.ProbeSha256) {
        throw 'App-local asset hash differs from the contract.'
    }
    $null = Assert-AppLocalShimImage $Contract.ShimPath $Contract.ShimSha256

    $applicationDirectory = Split-Path -Parent $ApplicationExe
    Assert-OutsideWindowsTree $applicationDirectory `
        'GPU-Z app-local installation directory'
    $target = Join-Path $applicationDirectory 'nvapi.dll'
    $original = Join-Path $applicationDirectory 'nvapi_orig.dll'
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
    $temporaryOriginal = Join-Path $applicationDirectory `
        ('.qemu-nvapi-original-' + $nonce + '.tmp')
    $temporaryShim = Join-Path $applicationDirectory `
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
    Write-Pass 'hash-pinned x86 NVAPI shim installed only beside GPU-Z.'
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
        [Parameter(Mandatory = $true)][string]$ApplicationExe
    )
    $applicationDirectory = Split-Path -Parent $ApplicationExe
    Assert-OutsideWindowsTree $applicationDirectory `
        'GPU-Z app-local probe directory'
    $target = Join-Path $applicationDirectory 'nvapi.dll'
    $original = Join-Path $applicationDirectory 'nvapi_orig.dll'
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

    $probeTarget = Join-Path $applicationDirectory 'nvapi_profile_probe32.exe'
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

function Invoke-Main {
    Assert-Administrator
    $manifest = Read-And-VerifyBundle
    $contract = Read-And-ValidateContract $manifest
    $gpu = Read-And-ValidateProfile $contract
    Assert-GuestUuid $contract
    Assert-NormalCodeIntegrityBoot
    $displayState = Get-HealthyDisplayState $contract
    $systemNvapi = Get-SystemNvapiReceipt

    if ($VerifyOnly) {
        # Verification is bound only to the deterministic protected installed
        # target.  It never publishes/replaces GPU-Z from the bundle.
        $gpuZEvidence = Get-ValidatedGpuZ $contract
        $applicationExe = [string]$gpuZEvidence.path
        $null = Invoke-AppLocalProbe $contract $gpu $applicationExe
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

    Initialize-ProtectedState
    $backup = New-GuestBackup $contract $displayState $systemNvapi
    Install-Profile $contract $gpu
    $gpuZEvidence = Install-ProtectedGpuZ $contract
    $applicationExe = [string]$gpuZEvidence.path
    Install-AppLocalShim $contract $applicationExe
    $probeOutput = Invoke-AppLocalProbe $contract $gpu $applicationExe
    Assert-SystemNvapiUnchanged $systemNvapi
    Assert-NormalCodeIntegrityBoot
    $finalDisplayState = Get-HealthyDisplayState $contract
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

    $result = [ordered]@{
        receiptType = if ([string]$contract.BindingMode -ceq 'portable-auto') {
            'gpuz-portable-final'
        } else {
            'gpuz-vm-bound-final'
        }
        schemaVersion = 1
        completedUtc = [DateTime]::UtcNow.ToString('o')
        bindingMode = [string]$contract.BindingMode
        observedVmUuid = $contract.VmUuid
        gpuProfile = $contract.GpuProfile
        gpuName = [string]$gpu.name
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
