param([Parameter(Mandatory = $true)][string]$DeployRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Load only the production functions under test; never run the Windows
# coordinator's entry point, registry writes, driver probes or native APIs.
foreach ($source in @(
    @{ Path='guest/install-system-nvapi-projection.ps1'; Names=@(
        'Assert-ExactPropertyNames', 'Get-V11ComputerName',
        'Read-CloneComputerNameState', 'Prepare-V11CloneComputerName',
        'Test-PnpPrefix', 'Get-GuestTransport', 'Publish-GpuPnpFriendlyName') },
    @{ Path='guest/patch-grid-strings.ps1'; Names=@(
        'Convert-ManagedGpuCaption', 'RewriteKey') }
)) {
    $tokens = $null; $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $DeployRoot $source.Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in $source.Names) {
        $functions = @($tree.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object { $_.Name -ceq $name })
        if ($functions.Count -ne 1) { throw "Missing production function: $name" }
        . ([scriptblock]::Create($functions[0].Extent.Text))
    }
}
$script:checks = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw "$Label`: expected=$Expected actual=$Actual" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Label) {
    $failed = $false
    try { $null = & $Action } catch { $failed = $true }
    if (-not $failed) { throw "$Label was unexpectedly accepted" }
    $script:checks++
}

$contract = [pscustomobject]@{
    vmId=7; vmUuid='954af170-2f54-49de-90ac-2d232695bf88'; contractId=('B' * 64)
    transport=[pscustomobject]@{
        targetPnpId='PCI\VEN_10DE&DEV_1E30'; driverVersion='31.0.15.3833'
        gpuName='NVIDIA GeForce GTX 750 Ti'
    }
    profile=[pscustomobject]@{ name='NVIDIA GeForce GTX 750 Ti' }
}
$script:machineUuid = $contract.vmUuid
$script:pnpId = 'PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE&REV_A1\4&TEST&0'
$script:displayCount = 1
$script:controllerName = 'NVIDIA GeForce GTX 750'
$script:driverVersion = '31.0.15.3833'
$script:deviceCode = 0
$script:driverSigned = $true
$script:driverProvider = 'NVIDIA'
$script:published = @()
function Get-PnpDevice {
    [CmdletBinding()]param([string]$Class, [switch]$PresentOnly)
    for ($i=0; $i -lt $script:displayCount; $i++) {
        [pscustomobject]@{ InstanceId=$script:pnpId; FriendlyName=$script:controllerName }
    }
}
function Get-CimInstance {
    [CmdletBinding()]param([string]$ClassName)
    switch ($ClassName) {
        'Win32_ComputerSystemProduct' { [pscustomobject]@{ UUID=$script:machineUuid } }
        'Win32_VideoController' { [pscustomobject]@{
            PNPDeviceID=$script:pnpId; ConfigManagerErrorCode=$script:deviceCode
            DriverVersion=$script:driverVersion; Name=$script:controllerName
        } }
        'Win32_PnPSignedDriver' { [pscustomobject]@{
            DeviceID=$script:pnpId; IsSigned=$script:driverSigned
            DriverProviderName=$script:driverProvider
        } }
        default { throw "Unexpected CIM class: $ClassName" }
    }
}
function Set-DevicePnpFriendlyName([string]$InstanceId, [string]$FriendlyName) {
    $script:published += [pscustomobject]@{ Id=$InstanceId; Name=$FriendlyName }
}

Assert-Rejected { Get-GuestTransport $contract } 'strict verification of old caption'
$result = Get-GuestTransport $contract -AllowIdentityUpdate
Assert-Equal $result.Display.InstanceId $script:pnpId 'upgrade retains new 2Q PnP'
Publish-GpuPnpFriendlyName $contract
Assert-Equal $script:published.Count 1 'single display publication'
Assert-Equal $script:published[0].Id $script:pnpId 'publication targets authenticated PnP'
Assert-Equal $script:published[0].Name $contract.profile.name 'live caption is new model'

foreach ($bad in @(
    @{ Key='machineUuid'; Value='00000000-0000-0000-0000-000000000001' },
    @{ Key='pnpId'; Value='PCI\VEN_10DE&DEV_1E300&SUBSYS_132610DE\4&TEST&0' },
    @{ Key='pnpId'; Value='PCI\VEN_8086&DEV_1234\4&TEST&0' },
    @{ Key='displayCount'; Value=2 },
    @{ Key='displayCount'; Value=0 },
    @{ Key='deviceCode'; Value=43 },
    @{ Key='driverVersion'; Value='31.0.15.0000' },
    @{ Key='driverSigned'; Value=$false },
    @{ Key='driverProvider'; Value='Untrusted vendor' }
)) {
    $old = (Get-Variable -Scope Script -Name $bad.Key).Value
    Set-Variable -Scope Script -Name $bad.Key -Value $bad.Value
    $script:published = @()
    Assert-Rejected { Publish-GpuPnpFriendlyName $contract } "unsafe transport $($bad.Key)"
    Assert-Equal $script:published.Count 0 'failed authentication performs no publication'
    Set-Variable -Scope Script -Name $bad.Key -Value $old
}
$script:controllerName = $contract.profile.name
$null = Get-GuestTransport $contract
$script:checks++

# The caption rewrite must cover the formerly published 1GB model while
# avoiding the GTX 750/GTX 750 Ti substring collision and unrelated values.
$catalog = Get-Content (Join-Path $DeployRoot 'guest/vgpu-profile-catalog.json') -Raw | ConvertFrom-Json
$managedGpuNames = @($catalog.profiles | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
$to = 'NVIDIA GeForce GTX 750 Ti'
$from = @('NVIDIA GRID RTX6000-2Q','GRID RTX6000-2Q')
Assert-Equal (Convert-ManagedGpuCaption 'NVIDIA GeForce GTX 750') $to 'old caption upgrade'
Assert-Equal (Convert-ManagedGpuCaption $to) $to 'repeated update is idempotent'
Assert-Equal (Convert-ManagedGpuCaption 'NVIDIA GeForce GTX 1050') $to 'another managed profile'
Assert-Equal (Convert-ManagedGpuCaption 'NVIDIA GRID RTX6000-2Q') $to 'native 2Q caption'
foreach ($unchanged in @('AMD Radeon RX 6600', $script:pnpId, 'C:\NVIDIA GeForce GTX 750\cache', 'NVIDIA GeForce GTX 750 Ti EXTRA')) {
    Assert-Equal (Convert-ManagedGpuCaption $unchanged) $unchanged 'unrelated value preserved'
}

$script:registryWrites = @()
function W([string]$Message) {}
function Get-ItemProperty {
    [CmdletBinding()]param([string]$Path)
    [pscustomobject]@{ FriendlyName='NVIDIA GeForce GTX 750'; DriverDesc='NVIDIA GeForce GTX 750'; HardwareID=$script:pnpId }
}
function Set-ItemProperty {
    [CmdletBinding()]param([string]$Path,[string]$Name,[string]$Value,[switch]$Force)
    $script:registryWrites += [pscustomobject]@{ Name=$Name; Value=$Value }
}
function Test-Path {
    [CmdletBinding()]param([string]$Path,[string]$LiteralPath,[string]$PathType)
    if ($Path -eq 'TestRegistry') { return $true }
    if ($LiteralPath) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
    return Microsoft.PowerShell.Management\Test-Path $Path
}
RewriteKey 'TestRegistry'
Assert-Equal $script:registryWrites.Count 2 'only old captions are rewritten'
Assert-Equal (@($script:registryWrites | Where-Object Name -eq 'HardwareID').Count) 0 'hardware ID is never rewritten'
foreach ($write in $script:registryWrites) { Assert-Equal $write.Value $to 'new caption value' }

# Clone hostname state may advance to a new GPU contract for the same UUID.
# It must neither permit a different VM nor rename an existing computer.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('g11-gpu-update-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot
$CloneComputerNameState = Join-Path $tempRoot 'computer-name.json'
$oldComputerName = $env:COMPUTERNAME
function Get-RegularFile([string]$Path,[string]$Label) { Get-Item -LiteralPath $Path }
function Test-PayloadRootIsCdRom([string]$Root) { return $false }
function Rename-Computer { throw 'Unexpected rename during GPU update' }
function Write-CloneComputerNameState($Contract,[string]$ComputerName) {
    [ordered]@{ schemaVersion=1; purpose='g11-private-clone-computer-name'; contractId=$Contract.contractId; vmUuid=$Contract.vmUuid; computerName=$ComputerName } |
        ConvertTo-Json | Set-Content -LiteralPath $CloneComputerNameState
}
try {
    $env:COMPUTERNAME = Get-V11ComputerName $contract
    $oldState = [ordered]@{ schemaVersion=1; purpose='g11-private-clone-computer-name'; contractId=('A'*64); vmUuid=$contract.vmUuid; computerName=$env:COMPUTERNAME }
    $oldState | ConvertTo-Json | Set-Content -LiteralPath $CloneComputerNameState
    Assert-Rejected { Read-CloneComputerNameState $contract } 'strict old contract state'
    $null = Read-CloneComputerNameState $contract -AllowContractUpdate
    Prepare-V11CloneComputerName ([pscustomobject]@{ Contract=$contract; Root=$tempRoot })
    $updated = Read-CloneComputerNameState $contract
    Assert-Equal $updated.contractId $contract.contractId 'hostname state advanced'
    Assert-Equal $env:COMPUTERNAME $oldState.computerName 'computer name unchanged'
    foreach ($bad in @(
        @{ Key='vmUuid'; Value='00000000-0000-0000-0000-000000000001' },
        @{ Key='computerName'; Value='ANOTHER-VM' },
        @{ Key='contractId'; Value='bad' }
    )) {
        $copy = [ordered]@{}
        foreach ($key in $oldState.Keys) { $copy[$key]=$oldState[$key] }
        $copy[$bad.Key]=$bad.Value
        $copy | ConvertTo-Json | Set-Content -LiteralPath $CloneComputerNameState
        Assert-Rejected { Read-CloneComputerNameState $contract -AllowContractUpdate } "invalid clone state $($bad.Key)"
    }
    $oldState | ConvertTo-Json | Set-Content -LiteralPath $CloneComputerNameState
    $env:COMPUTERNAME = 'OPERATOR-NAME'
    Assert-Rejected { Prepare-V11CloneComputerName ([pscustomobject]@{ Contract=$contract; Root=$tempRoot }) } 'GPU update cannot rename computer'
} finally {
    $env:COMPUTERNAME = $oldComputerName
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
Write-Host "PASS: $script:checks GPU identity upgrade assertions; no Windows mutations executed"
