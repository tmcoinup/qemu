# Behaviour test for the real localized powercfg parser used by both guest
# profiles.  Windows prints min/max/increment values before the current AC/DC
# values, so a parser that takes the first two hex tokens silently corrupts the
# rollback baseline.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$null, [ref]$errors)
if ($errors -and $errors.Count) { throw "cannot parse $ScriptPath" }
foreach ($name in @(
    'Get-PowerSchemeGuids',
    'Get-PowerSettingEffectiveValues'
)) {
    $found = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true)
    if ($found.Count -ne 1) { throw "$name not found exactly once" }
    Invoke-Expression $found[0].Extent.Text
}

$script:PowerCfgExitCode = 0
$script:PowerCfgListOutput = @'
现有电源使用方案 (* 活动)
-----------------------------------
电源使用方案 GUID: 9f10fd46-1aaa-42df-9eee-1234567890ab  (OEM Quiet)
电源使用方案 GUID: 381B4222-F694-41F0-9685-FF5BB260DF2E  (平衡) *
电源使用方案 GUID: a1841308-3541-4fab-bc81-f71556f20b4a  (节能)
'@
$script:PowerCfgQueryOutput = @'
电源使用方案 GUID: 381b4222-f694-41f0-9685-ff5bb260df2e
  电源设置 GUID: 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e
    最小可能设置: 0x00000000
    最大可能设置: 0xffffffff
    可能设置增量: 0x00000001
  当前交流电源设置索引: 0x00000258
  当前直流电源设置索引: 0x0000012c
'@
function powercfg.exe {
    $global:LASTEXITCODE = $script:PowerCfgExitCode
    if ([string]$args[0] -ieq '/List') {
        return $script:PowerCfgListOutput
    }
    return $script:PowerCfgQueryOutput
}

$schemes = @(Get-PowerSchemeGuids)
if ($schemes.Count -ne 3 -or
    $schemes -notcontains '9f10fd46-1aaa-42df-9eee-1234567890ab' -or
    $schemes -notcontains '381b4222-f694-41f0-9685-ff5bb260df2e' -or
    $schemes -notcontains 'a1841308-3541-4fab-bc81-f71556f20b4a') {
    throw "localized powercfg /List did not preserve arbitrary installed plans: $($schemes -join ',')"
}

$entry = [pscustomobject]@{
    SubgroupGuid = '7516b95f-f776-4464-8c53-06167f40cc99'
    SettingGuid = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    Name = 'VIDEOIDLE'
}
$result = Get-PowerSettingEffectiveValues `
    -SchemeGuid '381b4222-f694-41f0-9685-ff5bb260df2e' -Entry $entry
if (-not [bool]$result.Available -or
    [uint32]$result.ACValue -ne 600 -or
    [uint32]$result.DCValue -ne 300) {
    throw "localized powercfg parser selected the wrong AC/DC tokens: AC=$($result.ACValue) DC=$($result.DCValue)"
}

$script:PowerCfgExitCode = 1
$script:PowerCfgQueryOutput = 'query failed'
$missing = Get-PowerSettingEffectiveValues `
    -SchemeGuid '381b4222-f694-41f0-9685-ff5bb260df2e' -Entry $entry
if ([bool]$missing.Available -or [string]::IsNullOrWhiteSpace($missing.Error)) {
    throw 'a failed powercfg query was accepted as an available setting'
}

Write-Host 'OK: real powercfg parser handles localized arbitrary plan lists and final AC/DC indices'
