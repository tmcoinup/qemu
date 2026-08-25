#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VMateWindowsCodeIntegrityStatus {
    [CmdletBinding()]
    param()
    if (-not ('VMateWindowsCodeIntegrity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VMateWindowsCodeIntegrity {
    [StructLayout(LayoutKind.Sequential)]
    public struct Information {
        public UInt32 Length;
        public UInt32 CodeIntegrityOptions;
    }
    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(
        int informationClass, ref Information information,
        int informationLength, IntPtr returnLength);
}
'@
    }
    $information = New-Object VMateWindowsCodeIntegrity+Information
    $information.Length = [Runtime.InteropServices.Marshal]::SizeOf($information)
    $ntStatus = [VMateWindowsCodeIntegrity]::NtQuerySystemInformation(
        103, [ref]$information, $information.Length, [IntPtr]::Zero)
    if ($ntStatus -ne 0) {
        throw ('无法读取 Code Integrity 运行态：NTSTATUS=0x{0:X8}' -f
            ([uint32]$ntStatus))
    }
    $bcd = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "无法读取当前 BCD：$bcd" }
    $configuredTestSigning = $bcd -match '(?im)^testsigning\s+Yes\s*$'
    $activeTestSigning = ($information.CodeIntegrityOptions -band 0x2) -ne 0
    $hypervisorLaunchType = if ($bcd -match
        '(?im)^hypervisorlaunchtype\s+(?<value>\S+)\s*$') {
        [string]$Matches.value
    }
    else { 'Auto' }
    return [pscustomobject][ordered]@{
        Options = [uint32]$information.CodeIntegrityOptions
        OptionsHex = ('0x{0:X8}' -f $information.CodeIntegrityOptions)
        Enabled = ($information.CodeIntegrityOptions -band 0x1) -ne 0
        TestSigningConfigured = $configuredTestSigning
        TestSigningActive = $activeTestSigning
        DebugModeActive = ($information.CodeIntegrityOptions -band 0x80) -ne 0
        NoIntegrityChecksConfigured = $bcd -match
            '(?im)^nointegritychecks\s+Yes\s*$'
        HypervisorLaunchType = $hypervisorLaunchType
        RebootRequiredForTestSigning =
            $configuredTestSigning -ne $activeTestSigning
    }
}

function Assert-VMateWindowsProductionCodeIntegrity {
    [CmdletBinding()]
    param([string]$Label = 'Windows guest')
    $status = Get-VMateWindowsCodeIntegrityStatus
    if (-not $status.Enabled -or $status.TestSigningActive -or
        $status.DebugModeActive -or $status.TestSigningConfigured -or
        $status.NoIntegrityChecksConfigured) {
        throw ("$Label 必须保持生产 Code Integrity：" +
            "Options=$($status.OptionsHex)，TestSigning=" +
            "$($status.TestSigningActive)，Debug=$($status.DebugModeActive)，" +
            "BCD testsigning=$($status.TestSigningConfigured)，" +
            "nointegritychecks=$($status.NoIntegrityChecksConfigured)")
    }
    return $status
}
