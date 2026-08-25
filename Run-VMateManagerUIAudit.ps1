#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$AuditScriptPath = 'C:\VMateLab\Inspect-VMateManagerUI.ps1',
    [string]$OutputPath = 'C:\VMateLab\vmspoofer-ui-audit.json',
    [string]$ScreenshotPath = 'C:\VMateLab\vmspoofer-ui.png',
    [string]$InteractiveUser = 'panma'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'VMate-Sample-Manager-UI-Audit'
$arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-File "' + $AuditScriptPath + '" -OutputPath "' + $OutputPath +
    '" -ScreenshotPath "' + $ScreenshotPath + '"'

try {
    Remove-Item -LiteralPath $OutputPath, $ScreenshotPath -Force `
        -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId $InteractiveUser `
        -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
    } while (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and
        [DateTime]::UtcNow -lt $deadline)
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        $task = Get-ScheduledTaskInfo -TaskName $taskName
        throw "UI audit timed out; task result $($task.LastTaskResult)."
    }
    $document = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    [pscustomobject][ordered]@{
        OutputPath = $OutputPath
        ScreenshotCaptured = [bool]$document.ScreenshotCaptured
        ScreenshotPath = [string]$document.ScreenshotPath
        ControlCount = [int]$document.ControlCount
    } | ConvertTo-Json -Compress
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
        -ErrorAction SilentlyContinue
}
