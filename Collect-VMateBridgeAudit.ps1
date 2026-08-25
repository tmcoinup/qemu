#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$VMName = 'P11-Lab',
    [string]$OutputPath = 'C:\VMateLab\p11-bridge-audit.txt'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Off') { throw "VM must be Off; state=$($vm.State)." }
$drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
    Where-Object ControllerLocation -eq 0)
if ($drives.Count -ne 1) { throw 'Expected one system VHD.' }
$mounted = $false
try {
    $image = Mount-VHD -Path $drives[0].Path -ReadOnly -Passthru `
        -ErrorAction Stop
    $mounted = $true
    $disk = $image | Get-Disk -ErrorAction Stop
    $matches = @()
    foreach ($partition in @($disk | Get-Partition -ErrorAction Stop)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.Path)) { continue }
        $candidate = Join-Path ([string]$volume.Path) `
            'EFI\VMate\bridge-audit.txt'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $matches += $candidate
        }
    }
    if ($matches.Count -ne 1) {
        throw "Expected one bridge audit file, found $($matches.Count)."
    }
    Copy-Item -LiteralPath $matches[0] -Destination $OutputPath -Force
    Get-Content -LiteralPath $OutputPath -Raw -Encoding ASCII
}
finally {
    if ($mounted) {
        Dismount-VHD -Path $drives[0].Path -ErrorAction Stop
    }
}
