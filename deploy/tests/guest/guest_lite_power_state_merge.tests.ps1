# Behaviour tests for Guest Lite's append-only per-plan power-setting merge.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count) {
    throw "cannot parse $ScriptPath"
}
$target = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Merge-PowerSettingSnapshots'
}, $true)
if ($target.Count -ne 1) {
    throw 'Merge-PowerSettingSnapshots not found exactly once'
}
Invoke-Expression $target[0].Extent.Text

$videoSubgroup = '7516b95f-f776-4464-8c53-06167f40cc99'
$videoSetting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
$sleepSubgroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$sleepSetting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
$highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

function New-Snapshot {
    param(
        [string]$Scheme,
        [string]$Name,
        [uint32]$AC,
        [uint32]$DC
    )
    $isVideo = $Name -eq 'VIDEOIDLE'
    return [pscustomobject]@{
        SchemeGuid = $Scheme
        SubgroupGuid = if ($isVideo) { $videoSubgroup } else { $sleepSubgroup }
        SettingGuid = if ($isVideo) { $videoSetting } else { $sleepSetting }
        Name = $Name
        Exists = $true
        ACValue = $AC
        DCValue = $DC
    }
}

$current = @(
    (New-Snapshot $highPerformance 'VIDEOIDLE' 0 0),
    (New-Snapshot $highPerformance 'STANDBYIDLE' 0 0),
    (New-Snapshot $balanced 'VIDEOIDLE' 900 900),
    (New-Snapshot $balanced 'STANDBYIDLE' 1800 1800)
)

$fresh = Merge-PowerSettingSnapshots -Existing @() -Current $current
Assert-True ([bool]$fresh.Changed) 'fresh state was not marked changed'
Assert-True (@($fresh.Snapshots).Count -eq 4) `
    'fresh state did not capture every (plan, setting) pair'

# An old baseline recorded the real High-performance values before an older
# optimizer forced them to zero. The merge must keep those originals and only
# append the previously unrecorded Balanced pairs.
$existing = @(
    (New-Snapshot $highPerformance 'VIDEOIDLE' 900 900),
    (New-Snapshot $highPerformance 'STANDBYIDLE' 1800 1800)
)
$upgraded = Merge-PowerSettingSnapshots -Existing $existing -Current $current
$rows = @($upgraded.Snapshots)
Assert-True ($rows.Count -eq 4) 'upgrade did not append the Balanced pairs'
$savedHighVideo = @($rows | Where-Object {
    $_.SchemeGuid -eq $highPerformance -and $_.Name -eq 'VIDEOIDLE'
})
Assert-True ($savedHighVideo.Count -eq 1) `
    'upgrade duplicated the High-performance VIDEOIDLE pair'
Assert-True ([uint32]$savedHighVideo[0].ACValue -eq 900) `
    'ORIGINAL high-perf value was overwritten -- rollback would be destroyed'

# Legacy state used Exists=false when a setting inherited its scheme default.
# That absence is itself the rollback value: an upgrade must not replace it
# with a tool-created zero override.
$inherited = New-Snapshot $highPerformance 'VIDEOIDLE' 600 600
$inherited.Exists = $false
$inherited.ACValue = $null
$inherited.DCValue = $null
$forced = New-Snapshot $highPerformance 'VIDEOIDLE' 0 0
$inheritedMerge = Merge-PowerSettingSnapshots `
    -Existing @($inherited) -Current @($forced)
$savedInherited = @($inheritedMerge.Snapshots)[0]
Assert-True (-not [bool]$inheritedMerge.Changed) `
    'an inherited baseline was unexpectedly rewritten'
Assert-True (-not [bool]$savedInherited.Exists -and
    $null -eq $savedInherited.ACValue -and
    $null -eq $savedInherited.DCValue) `
    'INHERITED original was overwritten -- rollback would be destroyed'

$unchanged = Merge-PowerSettingSnapshots -Existing $rows -Current $current
Assert-True (-not [bool]$unchanged.Changed) `
    'a complete rollback baseline was unexpectedly rewritten'

$withNewPlan = @($current) + @(
    (New-Snapshot $ultimate 'VIDEOIDLE' 600 600),
    (New-Snapshot $ultimate 'STANDBYIDLE' 1200 1200)
)
$extended = Merge-PowerSettingSnapshots -Existing $rows -Current $withNewPlan
Assert-True ([bool]$extended.Changed) 'a newly installed plan was not detected'
Assert-True (@($extended.Snapshots).Count -eq 6) `
    'new plan/setting pairs were not appended exactly once'

if ($failures.Count) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'OK: Guest Lite power-setting merge preserves original values'
exit 0
