#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PipeName = 'VMateP11KeyAudit',
    [string]$OutputPath = 'C:\VMateLab\p11-serial-key-audit.json',
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = [byte[]](0x56, 0x4D, 0x4B, 0x31)
$captured = [Collections.Generic.List[byte]]::new()
$pipe = [IO.Pipes.NamedPipeClientStream]::new(
    '.',
    $PipeName,
    [IO.Pipes.PipeDirection]::In,
    [IO.Pipes.PipeOptions]::Asynchronous
)
$result = [ordered]@{
    SchemaVersion = 1
    PipeName = $PipeName
    Status = 'Waiting'
    Connected = $false
    MarkerOffset = -1
    KeyHex = ''
    CapturedHex = ''
    Error = $null
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    FinishedAtUtc = $null
}

try {
    $pipe.Connect($TimeoutSeconds * 1000)
    $result.Connected = $true
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $buffer = New-Object byte[] 512
    $pending = $null
    $markerOffset = -1
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -eq $pending) {
            $pending = $pipe.ReadAsync($buffer, 0, $buffer.Length)
        }
        if (-not $pending.Wait(250)) { continue }
        $count = [int]$pending.Result
        $pending = $null
        if ($count -eq 0) { break }
        for ($index = 0; $index -lt $count; ++$index) {
            [void]$captured.Add($buffer[$index])
        }
        if ($markerOffset -lt 0 -and $captured.Count -ge $marker.Length) {
            for ($offset = 0; $offset -le
                    $captured.Count - $marker.Length; ++$offset) {
                $match = $true
                for ($markerIndex = 0; $markerIndex -lt
                        $marker.Length; ++$markerIndex) {
                    if ($captured[$offset + $markerIndex] -ne
                        $marker[$markerIndex]) {
                        $match = $false
                        break
                    }
                }
                if ($match) {
                    $markerOffset = $offset
                    break
                }
            }
        }
        if ($markerOffset -ge 0 -and
            $captured.Count -ge $markerOffset + $marker.Length + 36) {
            $key = New-Object byte[] 36
            for ($index = 0; $index -lt $key.Length; ++$index) {
                $key[$index] = $captured[
                    $markerOffset + $marker.Length + $index]
            }
            $result.MarkerOffset = $markerOffset
            $result.KeyHex = ([BitConverter]::ToString($key)).Replace('-', '')
            $result.Status = 'Ready'
            break
        }
    }
    if ($result.Status -cne 'Ready') {
        $result.Status = 'Timeout'
        $result.Error = 'Serial marker and 36-byte key were not received.'
    }
}
catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
}
finally {
    if ($captured.Count -gt 0) {
        $result.CapturedHex = ([BitConverter]::ToString(
                $captured.ToArray())).Replace('-', '')
    }
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $directory = Split-Path -Parent $OutputPath
    if ($directory) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText(
        $OutputPath,
        ([pscustomobject]$result | ConvertTo-Json -Depth 5),
        (New-Object Text.UTF8Encoding($false))
    )
    $pipe.Dispose()
}

if ($result.Status -cne 'Ready') { exit 1 }
