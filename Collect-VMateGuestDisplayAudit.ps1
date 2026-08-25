#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$VhdPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$vm = Get-VM -Name $VMName -ErrorAction Stop
if ([string]$vm.State -ne 'Off') { throw "VM 必须先关机：$VMName" }
$mounted = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
try {
    $disk = $mounted | Get-Disk
    $windowsRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or
            [String]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) { continue }
        $candidate = ([string]$volume.DriveLetter) + ':\'
        if (Test-Path -LiteralPath (Join-Path $candidate `
                    'Windows\System32\Config\SOFTWARE') -PathType Leaf) {
            $windowsRoot = $candidate
            break
        }
    }
    if ($null -eq $windowsRoot) { throw "找不到 Windows 分区：$VhdPath" }
    $auditRoot = Join-Path $windowsRoot 'VMateAudit'
    $source = Join-Path $auditRoot 'display-stack.json'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "来宾审计输出尚未生成：$source"
    }
    Copy-Item -LiteralPath $source -Destination $OutputPath -Force
    Remove-Item -LiteralPath $auditRoot -Recurse -Force
}
finally {
    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
}
