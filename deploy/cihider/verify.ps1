# verify.ps1 -- check that CiHider did its job.
#
# Reads SystemCodeIntegrityInformation via NtQuerySystemInformation and
# prints the bitmask + decoded flags.  Run after boot (elevation not
# strictly required).

$code = @"
using System;
using System.Runtime.InteropServices;

public static class Ci {
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int NtQuerySystemInformation(
        int  SystemInformationClass,
        IntPtr SystemInformation,
        int  SystemInformationLength,
        out int ReturnLength);

    public const int SystemCodeIntegrityInformation = 103;

    public static uint GetOptions() {
        int sz = 8;
        IntPtr buf = Marshal.AllocHGlobal(sz);
        try {
            Marshal.WriteInt32(buf, 0, sz);
            Marshal.WriteInt32(buf, 4, 0);
            int ret;
            int st = NtQuerySystemInformation(
                SystemCodeIntegrityInformation, buf, sz, out ret);
            if (st != 0) {
                throw new Exception(
                    String.Format("NtQuerySystemInformation = 0x{0:x}", st));
            }
            return (uint)Marshal.ReadInt32(buf, 4);
        } finally {
            Marshal.FreeHGlobal(buf);
        }
    }
}
"@

Add-Type -TypeDefinition $code -Language CSharp

$flags = [Ci]::GetOptions()

Write-Host ("g_CiOptions = 0x{0:X8}" -f $flags)
Write-Host ""
$map = @(
    @(0x001,'ENABLED'),
    @(0x002,'TESTSIGN'),
    @(0x004,'UMCI_ENABLED'),
    @(0x008,'UMCI_AUDITMODE'),
    @(0x010,'UMCI_EXCLUSIONPATHS'),
    @(0x020,'TEST_BUILD'),
    @(0x040,'PREPRODUCTION'),
    @(0x080,'DEBUGMODE'),
    @(0x100,'FLIGHT_BUILD'),
    @(0x200,'FLIGHTING_ENABLED'),
    @(0x400,'HVCI_KMCI_ENABLED'),
    @(0x800,'HVCI_KMCI_AUDITMODE')
)
foreach ($e in $map) {
    $bit  = $e[0]
    $name = $e[1]
    $on   = ($flags -band $bit) -ne 0
    Write-Host ("  [{0}] 0x{1:X3}  {2}" -f ($(if ($on) {'x'} else {' '})), $bit, $name)
}

Write-Host ""
$testsign = ($flags -band 0x002) -ne 0
if ($testsign) {
    Write-Host "FAIL: TESTSIGN bit is set.  CiHider did not run or pattern mismatch." -ForegroundColor Red
} else {
    Write-Host "PASS: TESTSIGN bit is clear." -ForegroundColor Green
}

Write-Host ""
Write-Host "--- service state ---"
$svc = Get-CimInstance Win32_SystemDriver -Filter "Name='CiHider'" -ErrorAction SilentlyContinue
if ($svc) {
    $svc | Format-List Name,State,StartMode,Status,PathName
} else {
    Write-Host "CiHider service not registered." -ForegroundColor Yellow
}
