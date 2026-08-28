# Behaviour test for Guest Lite's append-only retired-service migration.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count) {
    throw "cannot parse $ScriptPath"
}
$target = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Restore-RetiredServiceSnapshots'
}, $true)
if ($target.Count -ne 1) {
    throw 'Restore-RetiredServiceSnapshots not found exactly once'
}
Invoke-Expression $target[0].Extent.Text

$RetiredServicePlan = @(
    [pscustomobject]@{ Name = 'CDPSvc'; Purpose = 'Windows Settings compatibility' }
)
$script:restored = New-Object 'System.Collections.Generic.List[object]'

# A mutation which re-samples the live service during migration must fail this
# test. The live value is already tool-modified and is not rollback evidence.
function Get-ServiceSnapshot {
    throw 'LIVE CDPSvc value was sampled -- original rollback would be destroyed'
}
function Restore-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    $script:restored.Add($Snapshot)
}

$original = [pscustomobject]@{
    Name = 'CDPSvc'
    Exists = $true
    StartMode = 'Auto'
    State = 'Running'
    DelayedAutoStart = 1
    Marker = 'ORIGINAL'
}
$state = [pscustomobject]@{ Services = @($original) }
$failures = @(Restore-RetiredServiceSnapshots $state)
if ($failures.Count -ne 0) {
    throw "original CDPSvc restore unexpectedly failed: $($failures -join '; ')"
}
if ($script:restored.Count -ne 1 -or
    -not [object]::ReferenceEquals($script:restored[0], $original) -or
    [string]$script:restored[0].Marker -ne 'ORIGINAL') {
    throw 'ORIGINAL CDPSvc snapshot was not passed through unchanged'
}

# A fresh 2.6.7 baseline does not own CDPSvc. It must leave an existing user or
# OEM service choice untouched instead of inventing a rollback value.
$script:restored.Clear()
$freshState = [pscustomobject]@{ Services = @() }
$freshFailures = @(Restore-RetiredServiceSnapshots $freshState)
if ($freshFailures.Count -ne 0 -or $script:restored.Count -ne 0) {
    throw 'fresh state unexpectedly adopted or modified retired CDPSvc'
}

Write-Host 'OK: retired CDPSvc migration restores only the saved original baseline'
exit 0
