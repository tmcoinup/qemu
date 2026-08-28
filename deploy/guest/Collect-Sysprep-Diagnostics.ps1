# Read-only Sysprep failure collector for the G-11 template kit.
# Windows PowerShell 5.1 compatible. This script never removes Appx packages,
# changes Sysprep registry state, modifies BCD, or installs a driver.
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Sysprep-Diagnostics.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = New-Object 'System.Collections.Generic.List[string]'
function Add-Line {
    param([AllowEmptyString()][string]$Text = '')
    $lines.Add($Text)
}

function Add-LogTail {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Title,
        [int]$Count = 120
    )

    Add-Line ''
    Add-Line "===== $Title ====="
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Line "MISSING: $Path"
        return
    }
    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -Tail $Count `
                -ErrorAction Stop)) {
            Add-Line ([string]$line)
        }
    } catch {
        Add-Line "READ ERROR: $($_.Exception.Message)"
    }
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputParent = [IO.Path]::GetDirectoryName($outputFullPath)
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Diagnostic output directory does not exist: $outputParent"
}
$parentItem = Get-Item -LiteralPath $outputParent -Force
if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Diagnostic output directory cannot be a reparse point: $outputParent"
}

$panther = Join-Path $env:WINDIR 'System32\Sysprep\Panther'
$setupErr = Join-Path $panther 'setuperr.log'
$setupAct = Join-Path $panther 'setupact.log'

Add-Line 'VMate G-11 Sysprep diagnostic report'
Add-Line ('CollectedUtc={0}' -f [DateTime]::UtcNow.ToString('o'))
Add-Line ('ComputerName={0}' -f $env:COMPUTERNAME)
Add-Line ('WindowsDirectory={0}' -f $env:WINDIR)
Add-Line 'ReadOnlyCollector=true'
Add-Line 'BCDChanged=false'
Add-Line 'DriverChanged=false'
try {
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15
    Add-Line ('OS={0}' -f [string]$os.Caption)
    Add-Line ('Version={0}' -f [string]$os.Version)
    Add-Line ('BuildNumber={0}' -f [string]$os.BuildNumber)
} catch {
    Add-Line ('OS query failed: {0}' -f $_.Exception.Message)
}
try {
    $imageState = [string](Get-ItemProperty -LiteralPath `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
        -Name ImageState -ErrorAction Stop).ImageState
    Add-Line ('ImageState={0}' -f $imageState)
} catch {
    Add-Line ('ImageState query failed: {0}' -f $_.Exception.Message)
}

$cbsPending = Test-Path -LiteralPath `
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wuPending = Test-Path -LiteralPath `
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$pendingRename = $false
try {
    $pendingRenameValue = (Get-ItemProperty -LiteralPath `
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
    $pendingRename = @($pendingRenameValue).Count -gt 0
} catch [System.Management.Automation.ItemNotFoundException] {
    $pendingRename = $false
} catch [System.Management.Automation.PSArgumentException] {
    $pendingRename = $false
} catch {
    Add-Line ('PendingFileRename query failed: {0}' -f $_.Exception.Message)
}
Add-Line ('CbsRebootPending={0}' -f $cbsPending.ToString().ToLowerInvariant())
Add-Line ('WindowsUpdateRebootPending={0}' -f $wuPending.ToString().ToLowerInvariant())
Add-Line ('PendingFileRename={0}' -f $pendingRename.ToString().ToLowerInvariant())
Add-Line ''
Add-Line '===== DISM reserved-storage state (read-only query) ====='
try {
    $dismOutput = @(& "$env:SystemRoot\System32\dism.exe" /Online `
        /Get-ReservedStorageState 2>&1)
    $dismExitCode = $LASTEXITCODE
    foreach ($line in $dismOutput) { Add-Line ([string]$line) }
    Add-Line ('DismExitCode={0}' -f $dismExitCode)
} catch {
    Add-Line ('DISM reserved-storage query failed: {0}' -f $_.Exception.Message)
}

$relevantLines = New-Object 'System.Collections.Generic.List[string]'
$packageNames = New-Object 'System.Collections.Generic.List[string]'
foreach ($logPath in @($setupErr, $setupAct)) {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { continue }
    try {
        $matches = @(Select-String -LiteralPath $logPath -Pattern `
            'SYSPRP.*(?:Error|fail|0x[0-9A-Fa-f]{4,})' -ErrorAction Stop |
            Select-Object -Last 160)
        foreach ($match in $matches) {
            $relevantLines.Add(([string]$match.Line))
        }
        $packageMatches = @(Select-String -LiteralPath $logPath -Pattern `
            'SYSPRP Package (?<Package>\S+) was installed for a user, but not provisioned for all users' `
            -AllMatches -ErrorAction Stop)
        foreach ($packageMatch in $packageMatches) {
            foreach ($regexMatch in $packageMatch.Matches) {
                $name = [string]$regexMatch.Groups['Package'].Value
                if (-not [string]::IsNullOrWhiteSpace($name) -and
                    -not $packageNames.Contains($name)) {
                    $packageNames.Add($name)
                }
            }
        }
    } catch {
        $relevantLines.Add("Could not scan $logPath`: $($_.Exception.Message)")
    }
}

Add-Line ''
Add-Line '===== Relevant SYSPRP errors (latest 160 per log) ====='
if ($relevantLines.Count -eq 0) {
    Add-Line 'No matching SYSPRP error line was found. Inspect the raw tails below.'
} else {
    foreach ($line in $relevantLines) { Add-Line $line }
}

Add-Line ''
Add-Line '===== Detected Appx provisioning mismatch ====='
if ($packageNames.Count -eq 0) {
    Add-Line 'None detected from the standard Sysprep error text.'
} else {
    foreach ($packageName in $packageNames) {
        Add-Line ("PackageFullName={0}" -f $packageName)
        try {
            $installedMatches = @(Get-AppxPackage -AllUsers -ErrorAction Stop |
                Where-Object { [string]$_.PackageFullName -ceq $packageName })
            if ($installedMatches.Count -eq 0) {
                Add-Line '  InstalledRegistration=not-found'
            }
            foreach ($installed in $installedMatches) {
                Add-Line ('  Name={0}' -f [string]$installed.Name)
                foreach ($userInfo in @($installed.PackageUserInformation)) {
                    Add-Line ('  User={0}; InstallState={1}' -f `
                        [string]$userInfo.UserSecurityId,
                        [string]$userInfo.InstallState)
                }
            }
        } catch {
            Add-Line ('  Installed package query failed: {0}' -f $_.Exception.Message)
        }
        try {
            $displayName = ($packageName -split '_', 2)[0]
            $provisionedMatches = @(Get-AppxProvisionedPackage -Online `
                -ErrorAction Stop | Where-Object {
                    [string]$_.PackageName -ceq $packageName -or
                    [string]$_.DisplayName -ceq $displayName
                })
            if ($provisionedMatches.Count -eq 0) {
                Add-Line '  Provisioning=not-found'
            }
            foreach ($provisioned in $provisionedMatches) {
                Add-Line ('  ProvisionedPackageName={0}' -f `
                    [string]$provisioned.PackageName)
            }
        } catch {
            Add-Line ('  Provisioned package query failed: {0}' -f $_.Exception.Message)
        }
    }
    Add-Line ''
    Add-Line 'LikelyCause=Appx package registration/provisioning mismatch (0x80073cf2)'
    Add-Line 'Do not run a remove-all-Appx script. Remove only each package named above,'
    Add-Line 'from the owning reference-image user, and reconcile that exact package provisioning.'
}

$reservedStorageBlocked = @($relevantLines | Where-Object {
        $_ -match '(?i)0x800F0975|reserved storage is in use|reserved storage.*servicing'
    }).Count -gt 0
Add-Line ''
Add-Line '===== Detected reserved-storage servicing block ====='
if ($reservedStorageBlocked) {
    Add-Line 'Detected=true'
    Add-Line 'LikelyCause=Windows Update or component servicing is using Reserved Storage (0x800F0975)'
} else {
    Add-Line 'Detected=false'
}

Add-Line ''
Add-Line '===== Safe next action ====='
if ($reservedStorageBlocked) {
    Add-Line 'Open Windows Update, install every available update, and restart normally.'
    Add-Line 'Repeat Check for updates + restart until no update or restart is pending.'
    Add-Line 'Then run Seal-G11-Template.cmd again. Do not edit ReserveManager or Sysprep registry state.'
} elseif ($cbsPending -or $wuPending -or $pendingRename) {
    Add-Line 'A reboot-pending signal exists. Finish Windows servicing, reboot normally,'
    Add-Line 'sign in to the template, and run Seal-G11-Template.cmd again.'
}
if ($packageNames.Count -gt 0) {
    Add-Line 'Send this report for an exact per-package repair command. Microsoft requires'
    Add-Line 'the affected user registration and provisioning to be handled consistently.'
} else {
    Add-Line 'Send this report, especially the relevant SYSPRP errors and raw log tails.'
}
Add-Line 'Do not edit Sysprep status registry keys, delete Panther logs, change BCD,'
Add-Line 'enable testsigning/nointegritychecks, or install a replacement kernel driver.'

Add-LogTail -Path $setupErr -Title 'setuperr.log tail' -Count 160
Add-LogTail -Path $setupAct -Title 'setupact.log tail' -Count 240

$temporary = "$outputFullPath.new.$PID"
try {
    [IO.File]::WriteAllLines($temporary, $lines,
        (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $outputFullPath -Force
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
Write-Host "[PASS] Sysprep diagnostic report: $outputFullPath"
