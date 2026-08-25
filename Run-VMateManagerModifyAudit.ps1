#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$AuditScriptPath = 'C:\VMateLab\Capture-VMateManagerModifyDialog.ps1',
    [string]$OutputPath = 'C:\VMateLab\vmspoofer-modify-audit.json',
    [string]$ScreenshotPath = 'C:\VMateLab\vmspoofer-modify.png'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'VMate-Sample-Manager-Modify-Audit'
$arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-File "' + $AuditScriptPath + '" -OutputPath "' + $OutputPath +
    '" -ScreenshotPath "' + $ScreenshotPath + '"'

try {
    Remove-Item -LiteralPath $OutputPath, $ScreenshotPath -Force `
        -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'panma' `
        -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(50)
    do {
        Start-Sleep -Milliseconds 250
    } while (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and
        [DateTime]::UtcNow -lt $deadline)
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        $task = Get-ScheduledTaskInfo -TaskName $taskName
        throw "modify audit timed out; task result $($task.LastTaskResult)."
    }
    $document = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    [pscustomobject][ordered]@{
        OutputPath = $OutputPath
        ScreenshotCaptured = [bool]$document.ScreenshotCaptured
        ScreenshotPath = [string]$document.ScreenshotPath
        DialogCount = [int]$document.DialogCount
        PreparationSeen = [bool]$document.PreparationSeen
        ConfigurationReached = [bool]$document.ConfigurationReached
        DialogTitle = if ($null -eq $document.Dialog) { '' } else {
            [string]$document.Dialog.Title
        }
    } | ConvertTo-Json -Compress
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}
