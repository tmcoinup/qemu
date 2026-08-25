#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 18082,
    [ValidateRange(1, 300)][int]$RequestTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'VMate.HyperV.InputBridge.ps1')
Start-VMateHyperVInputBridge -Port $Port `
    -RequestTimeoutSeconds $RequestTimeoutSeconds
