<#
.SYNOPSIS
  Patch the already-extracted vGPU 553.74 driver INF files to rewrite the
  DeviceID so Windows recognises the vGPU as GTX 1050 / GT 1030 instead of
  RTX A6000 / RTX 6000.

.DESCRIPTION
  Precondition: GRID 553.74 has been installed via the original .exe
  (i.e. nvidia-smi works). The script:
    1. Backs up every nvdm*.inf as .bak
    2. Appends the new DeviceID entries under [Strings] and
       [NVIDIA_Devices.NTamd64.10.0...]
    3. Uses pnputil to uninstall the existing NVIDIA driver packages and
       reinstall via the patched INF.

.EXAMPLE
  .\inf-patch.ps1 -Profile gtx1050_2gb `
                  -DriverRoot 'C:\NVIDIA\DisplayDriver\553.74\International\Display.Driver'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('gtx1050_2gb','gt1030_2gb')]
    [string]$Profile,
    [Parameter(Mandatory)][string]$DriverRoot,
    [switch]$SkipReinstall
)

if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run as Administrator'
}

$targets = @{
    'gtx1050_2gb' = @{ Hex = '1C81'; Name = 'NVIDIA GeForce GTX 1050' }
    'gt1030_2gb'  = @{ Hex = '1D01'; Name = 'NVIDIA GeForce GT 1030' }
}[$Profile]

$infs = Get-ChildItem -Path $DriverRoot -Filter 'nvdm*.inf' -Recurse
if ($infs.Count -eq 0) { throw "No nvdm*.inf found in $DriverRoot" }

foreach ($inf in $infs) {
    Write-Host "patching $($inf.FullName)" -Fore Cyan
    $bak = "$($inf.FullName).bak"
    if (-not (Test-Path $bak)) { Copy-Item $inf.FullName $bak }

    $text = Get-Content -Raw -LiteralPath $inf.FullName
    $strTag  = "NVIDIA_DEV.$($targets.Hex)"
    $strLine = "$strTag = `"$($targets.Name)`""

    # 1) Append to [Strings]
    if ($text -notmatch [regex]::Escape($strTag)) {
        $text = [regex]::Replace(
            $text, '(\r?\n\[Strings\]\r?\n)',
            "`$1$strLine`r`n", 'IgnoreCase')
    }

    # 2) Append entries under every [NVIDIA_Devices.NTamd64.*] section
    $devBlock = "%NVIDIA_DEV.$($targets.Hex)% = Section400, PCI\VEN_10DE&DEV_$($targets.Hex)"
    $text = [regex]::Replace(
        $text,
        '(\[NVIDIA_Devices\.NTamd64[^\]]*\]\r?\n)',
        { param($m)
          if ($m.Value -match [regex]::Escape("DEV_$($targets.Hex)")) { $m.Value }
          else { $m.Value + $devBlock + "`r`n" }
        })

    Set-Content -LiteralPath $inf.FullName -Value $text -Encoding ASCII -NoNewline
}

if ($SkipReinstall) {
    Write-Host 'SkipReinstall set: stopping before pnputil. Install manually if needed.' -Fore Yellow
    return
}

Write-Host 'Uninstalling current NVIDIA driver packages...' -Fore Cyan
$all = pnputil /enum-drivers
$matches = [regex]::Matches($all, 'Published name\s*:\s*(oem\d+\.inf)[\s\S]*?Provider\s*:\s*NVIDIA')
foreach ($m in $matches) {
    $oem = $m.Groups[1].Value
    Write-Host "  pnputil /delete-driver $oem /uninstall /force" -Fore Yellow
    pnputil /delete-driver $oem /uninstall /force | Out-Null
}

Write-Host 'Installing patched INF(s)...' -Fore Cyan
foreach ($inf in $infs) {
    pnputil /add-driver $inf.FullName /install | Out-Null
}

Write-Host 'Done. Reboot guest to apply the new driver binding.' -Fore Green
