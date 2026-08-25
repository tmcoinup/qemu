[CmdletBinding()]
param(
    [string]$VMName = 'pc01',
    [string]$OutputRoot = 'C:\VMateLab\sample-boot-evidence-pc01',
    [string]$ResultPath = 'C:\VMateLab\sample-boot-evidence-pc01.json'
)

$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$result = [ordered]@{
    VMName = $VMName
    StartedAt = (Get-Date).ToString('o')
    InitialState = $null
    VhdPath = $null
    ShutdownServiceInitiallyEnabled = $null
    GracefulShutdown = $false
    EfiFiles = @()
    CopiedFiles = @()
    StartupFiles = @()
    ProgramDataTools = @()
    Restarted = $false
    ServiceStateRestored = $false
    Error = $null
}

$mounted = $false
$wasRunning = $false
$shutdownService = $null
$vhdPath = $null

function Get-VMateFileEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $signature = try {
        Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    } catch { $null }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject][ordered]@{
        RelativePath = $RelativePath
        Size = [uint64]$item.Length
        Sha256 = [string](Get-FileHash -LiteralPath $Path `
            -Algorithm SHA256 -ErrorAction Stop).Hash
        SignatureStatus = if ($null -eq $signature) { '' } else {
            [string]$signature.Status
        }
        Signer = if ($null -eq $signature -or
            $null -eq $signature.SignerCertificate) { '' } else {
            [string]$signature.SignerCertificate.Subject
        }
        FileVersion = [string]$item.VersionInfo.FileVersion
    }
}

try {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $result.InitialState = [string]$vm.State
    $wasRunning = $vm.State -eq 'Running'
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
        Where-Object Path)
    if ($drives.Count -ne 1) {
        throw "Expected one attached VHD for $VMName, found $($drives.Count)."
    }
    $vhdPath = [string]$drives[0].Path
    $result.VhdPath = $vhdPath

    $shutdownService = @(Get-VMIntegrationService -VM $vm |
        Where-Object {
            [string]$_.Id -match
                '(?i)9F8233AC-BE49-4C79-8EE3-E7E1985B2077$'
        } | Select-Object -First 1)
    if ($shutdownService.Count -ne 1) {
        throw 'Could not resolve the Hyper-V shutdown integration service.'
    }
    $shutdownService = $shutdownService[0]
    $result.ShutdownServiceInitiallyEnabled = [bool]$shutdownService.Enabled
    if (-not $shutdownService.Enabled) {
        Enable-VMIntegrationService -VM $vm -Name $shutdownService.Name `
            -ErrorAction Stop
    }

    if ($vm.State -ne 'Off') {
        $computerSystem = Get-CimInstance -Namespace 'root/virtualization/v2' `
            -ClassName Msvm_ComputerSystem |
            Where-Object ElementName -eq $VMName | Select-Object -First 1
        $shutdown = Invoke-CimMethod -InputObject $computerSystem `
            -MethodName RequestStateChange `
            -Arguments @{ RequestedState = [uint16]4 }
        if ($shutdown.ReturnValue -notin 0, 4096) {
            throw "Graceful shutdown request returned $($shutdown.ReturnValue)."
        }
        $deadline = (Get-Date).AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 500
            $vm = Get-VM -Name $VMName
        } while ($vm.State -ne 'Off' -and (Get-Date) -lt $deadline)
        if ($vm.State -ne 'Off') {
            throw 'Guest did not complete the graceful shutdown within 90 seconds.'
        }
        $result.GracefulShutdown = $true
    }

    Mount-VHD -Path $vhdPath -ReadOnly -ErrorAction Stop | Out-Null
    $mounted = $true
    $disk = Get-DiskImage -ImagePath $vhdPath | Get-Disk
    $efiRoot = $null
    $windowsRoot = $null
    foreach ($partition in @($disk | Get-Partition)) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if ($null -eq $volume -or [String]::IsNullOrWhiteSpace(
                [string]$volume.Path)) { continue }
        $root = [string]$volume.Path
        if (Test-Path -LiteralPath (Join-Path $root 'EFI\Microsoft\Boot')) {
            $efiRoot = $root
        }
        if (Test-Path -LiteralPath (Join-Path $root 'Windows\System32')) {
            $windowsRoot = $root
        }
    }
    if (-not $efiRoot -or -not $windowsRoot) {
        throw 'Could not resolve both EFI and Windows volumes.'
    }

    $efiBase = Join-Path $efiRoot 'EFI'
    $result.EfiFiles = @(Get-ChildItem -LiteralPath $efiBase -File `
            -Recurse -ErrorAction Stop | ForEach-Object {
        $relative = $_.FullName.Substring($efiBase.Length).TrimStart('\')
        Get-VMateFileEvidence $_.FullName ("EFI\$relative")
    })

    $targets = [ordered]@{
        'efi-microsoft-bootmgfw.efi' = Join-Path $efiRoot `
            'EFI\Microsoft\Boot\bootmgfw.efi'
        'efi-boot-bootx64.efi' = Join-Path $efiRoot `
            'EFI\Boot\bootx64.efi'
        'windows-bootmgfw.efi' = Join-Path $windowsRoot `
            'Windows\Boot\EFI\bootmgfw.efi'
        'windows-winload.efi' = Join-Path $windowsRoot `
            'Windows\System32\winload.efi'
        'windows-ntoskrnl.exe' = Join-Path $windowsRoot `
            'Windows\System32\ntoskrnl.exe'
        'windows-mssmbios.sys' = Join-Path $windowsRoot `
            'Windows\System32\drivers\mssmbios.sys'
    }
    foreach ($name in $targets.Keys) {
        $source = [string]$targets[$name]
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $destination = Join-Path $OutputRoot $name
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $result.CopiedFiles += Get-VMateFileEvidence $destination $name
    }

    $startup = Join-Path $windowsRoot `
        'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
    if (Test-Path -LiteralPath $startup) {
        $result.StartupFiles = @(Get-ChildItem -LiteralPath $startup -File `
            -ErrorAction Stop | ForEach-Object {
                Get-VMateFileEvidence $_.FullName $_.Name
            })
    }
    $tools = Join-Path $windowsRoot 'ProgramData\tools'
    if (Test-Path -LiteralPath $tools) {
        $result.ProgramDataTools = @(Get-ChildItem -LiteralPath $tools -File `
            -Recurse -ErrorAction Stop | ForEach-Object {
                $relative = $_.FullName.Substring($tools.Length).TrimStart('\')
                Get-VMateFileEvidence $_.FullName $relative
            })
    }
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    if ($mounted) {
        Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    }
    if ($wasRunning) {
        try {
            if ((Get-VM -Name $VMName).State -eq 'Off') {
                Start-VM -Name $VMName -ErrorAction Stop | Out-Null
            }
            $result.Restarted = (Get-VM -Name $VMName).State -eq 'Running'
        }
        catch {
            if (-not $result.Error) {
                $result.Error = "Failed to restart guest: $($_.Exception.Message)"
            }
        }
    }
    try {
        if ($null -ne $shutdownService -and
            -not $result.ShutdownServiceInitiallyEnabled) {
            Disable-VMIntegrationService -VMName $VMName `
                -Name $shutdownService.Name -ErrorAction Stop
        }
        $current = @(Get-VMIntegrationService -VMName $VMName |
            Where-Object {
                [string]$_.Id -match
                    '(?i)9F8233AC-BE49-4C79-8EE3-E7E1985B2077$'
            } | Select-Object -First 1)
        $result.ServiceStateRestored = $current.Count -eq 1 -and
            [bool]$current[0].Enabled -eq
                [bool]$result.ShutdownServiceInitiallyEnabled
    }
    catch {
        if (-not $result.Error) {
            $result.Error = "Failed to restore shutdown service: $($_.Exception.Message)"
        }
    }
    $result.FinishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if ($result.Error) { exit 1 }
