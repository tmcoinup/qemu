param(
    [string]$Subkey = "",
    [switch]$ListOnly,
    [switch]$SkipTask     # skip the scheduled-task install step
)

# apply-gpu-spoof.ps1 - run INSIDE the Win10 guest, as Administrator.
#
# One-shot installer for the NVIDIA GTX 1050 spoof:
#
#   1) Class\{4d36e968-...}\NNNN        -> WMI VideoProcessor / AdapterRAM /
#                                           DriverDesc / HardwareInformation.*
#
#   2) Enum\PCI\VEN_...&DEV_...\<inst>  -> FriendlyName + DeviceDesc
#      (this is what Device Manager and Win32_VideoController.Name read)
#
#   3) C:\ProgramData\StealthGPU\refresh-gpu-name.ps1
#      + scheduled task "StealthGPU-RefreshName" (AtStartup + AtLogOn, SYSTEM,
#      highest privs). Windows' built-in BasicDisplay driver overwrites
#      DeviceDesc from display.inf on every init, so we re-apply the spoof
#      strings a couple of seconds after every boot. Pass -SkipTask to omit.
#
# Usage (PowerShell as Admin):
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -ListOnly
#   powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -SkipTask

$spoofName = 'NVIDIA GeForce GTX 1050'
$classGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $classGuid
$enumRoot  = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'

# Chinese localized needles built from char codes - keeps the source ASCII
# so Windows PowerShell 5.1 parses it correctly regardless of codepage.
$zhBasicDisplay = [string]::new([char[]](0x57fa,0x672c,0x663e,0x793a))
$zhStandardVGA1 = [string]::new([char[]](0x6807,0x51c6,0x0020,0x0056,0x0047,0x0041))
$zhStandardVGA2 = [string]::new([char[]](0x6807,0x51c6,0x0056,0x0047,0x0041))

$fakeNeedles = @(
    'virtio', 'Red Hat', 'Microsoft Basic', 'Standard VGA', 'QXL', 'Cirrus',
    $zhBasicDisplay, $zhStandardVGA1, $zhStandardVGA2
) -join '|'

# ---- list ------------------------------------------------------------------
Write-Host ("Adapters under " + $classRoot + " :") -ForegroundColor Cyan
Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $d = (Get-ItemProperty -Path $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
        Write-Host ("  {0}  -  {1}" -f $_.PSChildName, $d)
    }
Write-Host ""

if ($ListOnly) {
    Write-Host "ListOnly mode - exiting without changes." -ForegroundColor Yellow
    exit 0
}

# ---- pick class subkey(s) --------------------------------------------------
if ($Subkey) {
    $p = Join-Path $classRoot $Subkey
    if (-not (Test-Path $p)) {
        Write-Host ("ERROR: subkey '" + $Subkey + "' does not exist") -ForegroundColor Red
        exit 1
    }
    $dd = (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
    $targets = @([pscustomobject]@{ Path=$p; Desc=$dd; Sub=$Subkey })
} else {
    $targets = Get-ChildItem $classRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            $p  = $_.PSPath
            $dd = (Get-ItemProperty -Path $p -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
            if ($dd -and ($dd -match $fakeNeedles -or $dd -eq $spoofName)) {
                [pscustomobject]@{ Path=$p; Desc=$dd; Sub=$_.PSChildName }
            }
        }
}

if (-not $targets) {
    Write-Host "No fake adapter auto-detected. Use one of the subkeys above:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\apply-gpu-spoof.ps1 -Subkey 0001" -ForegroundColor Yellow
    exit 1
}

# ---- patch class subkey(s) -------------------------------------------------
foreach ($t in $targets) {
    Write-Host ""
    Write-Host ("Patching class " + $t.Sub + " (was: " + $t.Desc + ")") -ForegroundColor Cyan
    Set-ItemProperty -Path $t.Path -Name "DriverDesc"   -Type String -Value $spoofName
    Set-ItemProperty -Path $t.Path -Name "ProviderName" -Type String -Value "NVIDIA"
    Set-ItemProperty -Path $t.Path -Name "MatchingDeviceId" -Type String -Value "PCI\VEN_10DE&DEV_1C81"
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.AdapterString" -Type String -Value $spoofName
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.ChipType"      -Type String -Value "GeForce GTX 1050"
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.DacType"       -Type String -Value "Integrated RAMDAC"
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.BiosString"    -Type String -Value "Version 86.07.48.00.38"
    Set-ItemProperty -Path $t.Path -Name "HardwareInformation.MemorySize" -Type Binary -Value ([byte[]](0x00,0x00,0x00,0x80))
    if (Get-ItemProperty -Path $t.Path -Name "HardwareInformation.qwMemorySize" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $t.Path -Name "HardwareInformation.qwMemorySize"
    }
    New-ItemProperty -Path $t.Path -Name "HardwareInformation.qwMemorySize" -PropertyType QWord -Value 0x80000000 | Out-Null
    Write-Host ("  -> DriverDesc now: " + (Get-ItemProperty -Path $t.Path -Name DriverDesc).DriverDesc) -ForegroundColor Green
}

# ---- patch Enum\PCI FriendlyName + DeviceDesc ------------------------------
$targetSubs = $targets | ForEach-Object { $_.Sub }
Write-Host ""
Write-Host "Scanning Enum\PCI for nodes bound to the patched class subkey(s)..." -ForegroundColor Cyan
$matchedEnum = @()
Get-ChildItem $enumRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $venDev = $_
    Get-ChildItem $venDev.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $inst = $_
        $drv = (Get-ItemProperty -Path $inst.PSPath -Name Driver -ErrorAction SilentlyContinue).Driver
        if ($drv) {
            foreach ($s in $targetSubs) {
                $needle = $classGuid + '\' + $s
                if ($drv -like ("*" + $needle + "*")) {
                    $matchedEnum += [pscustomobject]@{
                        Path = $inst.PSPath
                        Short = ($venDev.PSChildName + '\' + $inst.PSChildName)
                    }
                }
            }
        }
    }
}

if (-not $matchedEnum) {
    Write-Host "  (no matching Enum\PCI node found)" -ForegroundColor Yellow
} else {
    foreach ($m in $matchedEnum) {
        Set-ItemProperty -Path $m.Path -Name FriendlyName -Type String -Value $spoofName
        Set-ItemProperty -Path $m.Path -Name DeviceDesc   -Type String -Value $spoofName
        Write-Host ("  " + $m.Short + " -> " + $spoofName) -ForegroundColor Green
    }
}

# ---- install boot-time refresh task ----------------------------------------
if (-not $SkipTask) {
    Write-Host ""
    Write-Host "Installing boot-time refresh task (defeats BasicDisplay clobber)..." -ForegroundColor Cyan

    $taskName  = 'StealthGPU-RefreshName'
    $scriptDir = 'C:\ProgramData\StealthGPU'
    $scriptPath = Join-Path $scriptDir 'refresh-gpu-name.ps1'
    New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null

    $body = @'
$ErrorActionPreference = 'SilentlyContinue'
$spoofName = 'NVIDIA GeForce GTX 1050'
$classGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
$classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $classGuid
$enumRoot  = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'

foreach ($ven in Get-ChildItem $enumRoot) {
    if ($ven.PSChildName -notlike 'VEN_1AF4*' -and
        $ven.PSChildName -notlike 'VEN_1B36*' -and
        $ven.PSChildName -notlike 'VEN_1234*') { continue }
    foreach ($inst in Get-ChildItem $ven.PSPath) {
        $drv = (Get-ItemProperty -Path $inst.PSPath -Name Driver).Driver
        if ($drv -like ('*' + $classGuid + '*')) {
            Set-ItemProperty -Path $inst.PSPath -Name FriendlyName -Type String -Value $spoofName
            Set-ItemProperty -Path $inst.PSPath -Name DeviceDesc   -Type String -Value $spoofName
        }
    }
}

foreach ($sub in Get-ChildItem $classRoot) {
    if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
    $p  = $sub.PSPath
    $dd = (Get-ItemProperty -Path $p -Name DriverDesc).DriverDesc
    if ($dd) {
        Set-ItemProperty -Path $p -Name DriverDesc   -Type String -Value $spoofName
        Set-ItemProperty -Path $p -Name ProviderName -Type String -Value 'NVIDIA'
        Set-ItemProperty -Path $p -Name 'HardwareInformation.AdapterString' -Type String -Value $spoofName
        Set-ItemProperty -Path $p -Name 'HardwareInformation.ChipType'      -Type String -Value 'GeForce GTX 1050'
        Set-ItemProperty -Path $p -Name 'HardwareInformation.DacType'       -Type String -Value 'Integrated RAMDAC'
        Set-ItemProperty -Path $p -Name 'HardwareInformation.BiosString'    -Type String -Value 'Version 86.07.48.00.38'
        Set-ItemProperty -Path $p -Name 'HardwareInformation.MemorySize' -Type Binary -Value ([byte[]](0x00,0x00,0x00,0x80))
    }
}
'@
    # Write refresh script as UTF-8 with BOM so PS 5.1 on any codepage parses it
    $bom   = [byte[]](0xEF,0xBB,0xBF)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    [System.IO.File]::WriteAllBytes($scriptPath, $bom + $bytes)

    schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"')
    $trigBoot  = New-ScheduledTaskTrigger -AtStartup
    $trigLogon = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable
    $task = New-ScheduledTask -Action $action -Trigger @($trigBoot, $trigLogon) `
        -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

    Write-Host ("  -> installed " + $scriptPath) -ForegroundColor Green
    Write-Host ("  -> task '" + $taskName + "' registered (AtStartup + AtLogOn, SYSTEM)") -ForegroundColor Green
}

# ---- verify ----------------------------------------------------------------
Write-Host ""
Write-Host "Verifying via WMI..." -ForegroundColor Cyan
Get-WmiObject Win32_VideoController | Select-Object Name, VideoProcessor, AdapterRAM, DriverVersion | Format-List

Write-Host "Done. The scheduled task re-applies the spoof within ~2s of every boot," -ForegroundColor Yellow
Write-Host "so Device Manager and WMI stay NVIDIA even after reboot."                  -ForegroundColor Yellow
