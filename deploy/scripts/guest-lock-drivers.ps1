# guest-lock-drivers.ps1 - run INSIDE Win10 guest, as Administrator.
#
# Purpose: lock the *display* driver binding (viogpudo) against Windows Update
# churn without disabling WU/WaaS services (doing so is itself a virtualization
# fingerprint).  After this runs:
#
#   - PnP no longer searches Windows Update for any driver
#   - Policy blocks *new* driver installs for device class Display
#     (GUID {4d36e968-...}).  Existing viogpudo binding is preserved.
#   - Device Metadata Framework no longer hits the network for product names
#   - WU quality updates exclude driver packages
#
# wuauserv / UsoSvc / WaaSMedicSvc are left at their default start modes so a
# fingerprint scan sees a normal-looking Win10 box.
#
# Reversible.  Pass -Unlock to restore the policy keys to defaults.

param(
    [switch]$Unlock,
    [switch]$Quiet
)

$DisplayClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'

function Ensure-Key($path) {
    if (-not (Test-Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
}

function Write-Dword($path, $name, $value) {
    Ensure-Key $path
    New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $value -Force | Out-Null
    if (-not $Quiet) { Write-Host ("  set {0}\{1} = {2}" -f $path, $name, $value) }
}

function Write-String($path, $name, $value) {
    Ensure-Key $path
    New-ItemProperty -Path $path -Name $name -PropertyType String -Value $value -Force | Out-Null
    if (-not $Quiet) { Write-Host ("  set {0}\{1} = `"{2}`"" -f $path, $name, $value) }
}

function Remove-Prop($path, $name) {
    if (Test-Path $path) {
        Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
    }
}

if ($Unlock) {
    Write-Host "=== UNLOCK driver policies ===" -ForegroundColor Yellow
    Remove-Prop 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig'
    Remove-Prop 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' 'DenyDeviceClasses'
    Remove-Prop 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' 'DenyDeviceClassesRetroactive'
    Remove-Item  'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceClasses' -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Prop 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' 'PreventDeviceMetadataFromNetwork'
    Remove-Prop 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate'
    Write-Host "unlocked. run 'gpupdate /force' or reboot to apply." -ForegroundColor Yellow
    exit 0
}

Write-Host "=== LOCK display-class driver updates ===" -ForegroundColor Cyan

# --- L1: PnP never searches Windows Update for drivers ---------------------
# 0 = Do not search Windows Update (supported Win10 option, shows up as
# "Device installation settings -> No" in the Control Panel UI)
Write-Host "[L1] PnP driver search order"
Write-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' `
            'SearchOrderConfig' 0

# --- L2: block *new* driver installs for Display class ---------------------
Write-Host "[L2] DeviceInstall policy: deny Display class"
$restr = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
Write-Dword $restr 'DenyDeviceClasses'           1
Write-Dword $restr 'DenyDeviceClassesRetroactive' 0  # keep existing viogpudo binding
$list = Join-Path $restr 'DenyDeviceClasses'
Write-String $list '1' $DisplayClassGuid

# --- L3: no DMF network lookup ---------------------------------------------
Write-Host "[L3] Device Metadata Framework: no network"
Write-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' `
            'PreventDeviceMetadataFromNetwork' 1

# --- L4: WU quality updates exclude driver packages ------------------------
Write-Host "[L4] Windows Update: exclude drivers from quality updates"
Write-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            'ExcludeWUDriversInQualityUpdate' 1

# --- trigger policy refresh -------------------------------------------------
Write-Host ""
Write-Host "gpupdate /force (silent)..."
& gpupdate.exe /force /wait:30 2>&1 | Out-Null

# --- show resulting state ---------------------------------------------------
Write-Host ""
Write-Host "=== current state ===" -ForegroundColor Cyan
$dump = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching\SearchOrderConfig',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceClasses',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceClassesRetroactive',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceClasses\1',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata\PreventDeviceMetadataFromNetwork',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\ExcludeWUDriversInQualityUpdate'
)
foreach ($full in $dump) {
    $key  = Split-Path $full -Parent
    $name = Split-Path $full -Leaf
    $val  = (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $val) { $val = '<missing>' }
    Write-Host ("  {0} = {1}" -f $full, $val)
}

Write-Host ""
Write-Host "Services (left at defaults, not disabled):"
Get-Service wuauserv, UsoSvc, WaaSMedicSvc -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table -AutoSize

Write-Host "done. to undo: powershell -File guest-lock-drivers.ps1 -Unlock" -ForegroundColor Yellow
