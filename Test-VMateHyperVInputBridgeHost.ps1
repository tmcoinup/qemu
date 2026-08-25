$ErrorActionPreference = 'Stop'
. 'C:\VMateLab\VMate.HyperV.Input.ps1'

$session = $null
try {
    $session = New-VMateHyperVInputSession -VMName 'P11-Lab'
    $position = Get-VMateHyperVMousePosition -Session $session
    $resolution = Get-VMateHyperVInputVideoHead -Session $session
    [pscustomobject][ordered]@{
        Passed = $true
        VMName = $session.VMName
        VMId = $session.VMId
        Transport = $session.Transport
        MousePosition = $position
        Resolution = $resolution
        PressedKeyCount = $session.PressedKeys.Count
        PressedButtonCount = $session.PressedButtons.Count
    } | ConvertTo-Json -Depth 5 |
        Set-Content 'C:\VMateLab\p11-input-host-test.json' -Encoding UTF8
}
finally {
    if ($null -ne $session) {
        [void](Close-VMateHyperVInputSession -Session $session)
    }
}
