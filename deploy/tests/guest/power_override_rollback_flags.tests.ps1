# Behaviour test for migration from the old single Exists flag to the exact
# key/AC/DC override-presence flags used by current rollback.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$null, [ref]$errors)
if ($errors -and $errors.Count) { throw "cannot parse $ScriptPath" }
$found = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-SavedPowerOverrideFlag'
}, $true)
if ($found.Count -ne 1) {
    throw 'Get-SavedPowerOverrideFlag not found exactly once'
}
Invoke-Expression $found[0].Extent.Text

$legacyInherited = [pscustomobject]@{ Exists = $false }
foreach ($name in @('KeyExisted', 'ACValueExisted', 'DCValueExisted')) {
    if (Get-SavedPowerOverrideFlag -Snapshot $legacyInherited -Name $name) {
        throw "legacy inherited row was treated as an explicit $name override"
    }
}

$legacyExplicit = [pscustomobject]@{ Exists = $true }
foreach ($name in @('KeyExisted', 'ACValueExisted', 'DCValueExisted')) {
    if (-not (Get-SavedPowerOverrideFlag -Snapshot $legacyExplicit -Name $name)) {
        throw "legacy explicit row lost its $name rollback value"
    }
}

$modernPartial = [pscustomobject]@{
    Exists = $false
    KeyExisted = $true
    ACValueExisted = $false
    DCValueExisted = $true
}
if (-not (Get-SavedPowerOverrideFlag -Snapshot $modernPartial -Name 'KeyExisted') -or
    (Get-SavedPowerOverrideFlag -Snapshot $modernPartial -Name 'ACValueExisted') -or
    -not (Get-SavedPowerOverrideFlag -Snapshot $modernPartial -Name 'DCValueExisted')) {
    throw 'modern per-value override-presence flags were collapsed into legacy Exists'
}

Write-Host 'OK: rollback preserves inherited, explicit, and partial override presence'
