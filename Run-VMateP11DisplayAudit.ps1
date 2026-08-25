#Requires -Version 5.1

param(
    [string]$AuditScriptPath = 'C:\VMateLab\Audit-VMateGuestDisplayStack.ps1',
    [string]$OutputPath = 'C:\VMateLab\display-stack-P11-Lab.json'
)

$ErrorActionPreference = 'Stop'
$lines = Get-Content -LiteralPath 'C:\VMateLab\Probe-VMateP11Guest.ps1' `
    -Encoding UTF8
$code = ($lines[3..4] -join [Environment]::NewLine) +
    [Environment]::NewLine + 'return $credential'
$credential = & ([scriptblock]::Create($code))
$session = $null
$guestRoot = 'C:\Windows\Temp\VMateDisplayAudit'
try {
    $session = New-PSSession -VMName 'P11-Lab' -Credential $credential `
        -ErrorAction Stop
    Invoke-Command -Session $session -ScriptBlock {
        param($Path)
        [IO.Directory]::CreateDirectory($Path) | Out-Null
    } -ArgumentList $guestRoot
    $guestScript = Join-Path $guestRoot 'Audit-VMateGuestDisplayStack.ps1'
    $guestOutput = Join-Path $guestRoot 'display-stack.json'
    Copy-Item -LiteralPath $AuditScriptPath -Destination $guestScript `
        -ToSession $session -Force
    Invoke-Command -Session $session -ScriptBlock {
        param($ScriptPath, $ResultPath)
        & powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $ScriptPath -OutputPath $ResultPath
        if ($LASTEXITCODE -ne 0) {
            throw "来宾显示栈审计退出码：$LASTEXITCODE"
        }
    } -ArgumentList $guestScript, $guestOutput
    Copy-Item -LiteralPath $guestOutput -Destination $OutputPath `
        -FromSession $session -Force
}
finally {
    if ($null -ne $session) {
        Invoke-Command -Session $session -ScriptBlock {
            param($Path)
            Remove-Item -LiteralPath $Path -Recurse -Force `
                -ErrorAction SilentlyContinue
        } -ArgumentList $guestRoot -ErrorAction SilentlyContinue
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}
