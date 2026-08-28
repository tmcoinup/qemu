# Behaviour tests for Optimize-Guest.ps1's power-setting state merge.
#
# The merge is the one piece where a mistake is unrecoverable: if an upgrade
# re-samples values this tool already forced to 0 and stores them as the
# "original", 04-Rollback.cmd can never restore what the user actually had.
# These tests lift the real function out of the script via its AST -- no copy
# that could drift -- and drive it against stubbed registry access.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

# --- lift the real functions out of the script under test -------------------
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$null, [ref]$errors)
if ($errors -and $errors.Count) {
    throw "cannot parse $ScriptPath"
}
foreach ($functionName in @(
    'Get-AllPowerSettingSnapshots', 'Ensure-PowerSettingState'
)) {
    $target = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }, $true)
    if ($target.Count -ne 1) {
        throw "$functionName not found exactly once"
    }
    Invoke-Expression $target[0].Extent.Text
}

# --- stubs for the Windows-only dependencies --------------------------------
$script:SavedState = $null
function Save-StateAtomically { param($State) $script:SavedState = $State }
function Read-State { return $script:SavedState }

function New-Snapshot {
    param([string]$Scheme, [string]$Name, [uint32]$AC, [uint32]$DC)
    [pscustomobject]@{
        SchemeGuid = $Scheme
        SubgroupGuid = "sub-$Name"
        SettingGuid = "set-$Name"
        Name = $Name
        Exists = $true
        ACValue = $AC
        DCValue = $DC
    }
}

$balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$highperf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

# Exercise the real Cartesian-product enumerator. This catches call sites that
# forget to pass the plan GUID even though the merge test below uses stubs.
$script:SchemeGuids = @($highperf, $balanced)
function Get-PowerSchemeGuids { return $script:SchemeGuids }
function Get-PowerSettingSnapshot {
    param([string]$SchemeGuid, [object]$Entry)
    return (New-Snapshot $SchemeGuid ([string]$Entry.Name) 600 600)
}
$script:PowerSettingPlan = @(
    [pscustomobject]@{ Name = 'VIDEOIDLE' },
    [pscustomobject]@{ Name = 'STANDBYIDLE' }
)
$product = @(Get-AllPowerSettingSnapshots)
Assert-True ($product.Count -eq 4) `
    'enumerator must produce every (plan, setting) pair'
Assert-True (@($product | Where-Object {
    $_.SchemeGuid -eq $balanced -and $_.Name -eq 'VIDEOIDLE'
}).Count -eq 1) 'enumerator omitted the Balanced/VIDEOIDLE pair'

$script:AllSnapshots = @()
Remove-Item Function:Get-AllPowerSettingSnapshots
function Get-AllPowerSettingSnapshots { return $script:AllSnapshots }

# Current machine state: this tool already zeroed High performance; Balanced
# still carries the stock 10-minute blank / 30-minute sleep.
$script:AllSnapshots = @(
    (New-Snapshot $highperf 'VIDEOIDLE' 0 0),
    (New-Snapshot $highperf 'STANDBYIDLE' 0 0),
    (New-Snapshot $balanced 'VIDEOIDLE' 600 600),
    (New-Snapshot $balanced 'STANDBYIDLE' 1800 1800)
)

# --- case 1: schema-2 state with no PowerSettings at all --------------------
$script:SavedState = $null
$state = [pscustomobject]@{ SchemaVersion = 2 }
$result = Ensure-PowerSettingState -State $state
Assert-True ($null -ne $result) 'case1: no state returned'
Assert-True (@($result.PowerSettings).Count -eq 4) `
    'case1: every (plan, setting) pair must be captured'

# --- case 2: upgrade from a High-performance-only backup --------------------
# The recorded originals were 600/1800 before this tool zeroed them.  The
# upgrade must keep those numbers and only append the Balanced pairs.
$script:SavedState = $null
$state = [pscustomobject]@{
    SchemaVersion = 2
    PowerSettings = @(
        (New-Snapshot $highperf 'VIDEOIDLE' 600 600),
        (New-Snapshot $highperf 'STANDBYIDLE' 1800 1800)
    )
}
$result = Ensure-PowerSettingState -State $state
$merged = @($result.PowerSettings)
Assert-True ($merged.Count -eq 4) 'case2: balanced pairs must be appended'

$hpVideo = @($merged | Where-Object {
    $_.SchemeGuid -eq $highperf -and $_.Name -eq 'VIDEOIDLE' })
Assert-True ($hpVideo.Count -eq 1) 'case2: high-perf entry duplicated'
Assert-True ([uint32]$hpVideo[0].ACValue -eq 600) `
    'ORIGINAL high-perf value was overwritten -- rollback would be destroyed'

$balVideo = @($merged | Where-Object {
    $_.SchemeGuid -eq $balanced -and $_.Name -eq 'VIDEOIDLE' })
Assert-True ($balVideo.Count -eq 1) 'case2: balanced entry missing'
Assert-True ([uint32]$balVideo[0].ACValue -eq 600) `
    'case2: balanced original value not captured'

# A legacy Exists=false row means the original scheme inherited its default.
# Preserve that absence even though the current machine now exposes the zero
# override written by an older tool.
$script:SavedState = $null
$legacyInherited = New-Snapshot $highperf 'VIDEOIDLE' 600 600
$legacyInherited.Exists = $false
$legacyInherited.ACValue = $null
$legacyInherited.DCValue = $null
$state = [pscustomobject]@{
    SchemaVersion = 2
    PowerSettings = @($legacyInherited)
}
$result = Ensure-PowerSettingState -State $state
$savedInherited = @($result.PowerSettings | Where-Object {
    $_.SchemeGuid -eq $highperf -and $_.Name -eq 'VIDEOIDLE'
})
Assert-True ($savedInherited.Count -eq 1 -and
    -not [bool]$savedInherited[0].Exists -and
    $null -eq $savedInherited[0].ACValue -and
    $null -eq $savedInherited[0].DCValue) `
    'INHERITED original was overwritten -- rollback would be destroyed'

# --- case 3: already complete state is left alone ---------------------------
$script:SavedState = $null
$state = [pscustomobject]@{
    SchemaVersion = 2
    PowerSettings = @(
        (New-Snapshot $highperf 'VIDEOIDLE' 600 600),
        (New-Snapshot $highperf 'STANDBYIDLE' 1800 1800),
        (New-Snapshot $balanced 'VIDEOIDLE' 600 600),
        (New-Snapshot $balanced 'STANDBYIDLE' 1800 1800)
    )
}
$result = Ensure-PowerSettingState -State $state
Assert-True ($null -eq $script:SavedState) `
    'case3: a complete state must not be rewritten'
Assert-True (@($result.PowerSettings).Count -eq 4) 'case3: state was altered'

# --- case 4: a newly installed plan is picked up on the next run ------------
$ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:AllSnapshots += (New-Snapshot $ultimate 'VIDEOIDLE' 600 600)
$script:SavedState = $null
$result = Ensure-PowerSettingState -State $state
Assert-True (@($result.PowerSettings).Count -eq 5) `
    'case4: a plan added after the first apply must be captured'

if ($failures.Count) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'OK: power-setting state merge preserves originals across upgrades'
exit 0
