#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-VMateGpuPGuestValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential,

        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,

        [Parameter(Mandatory = $true)]
        [string]$GpuName,

        [Parameter(Mandatory = $true)]
        [string]$DriverVersion,

        [bool]$StrictDisplay = $true,

        [switch]$DisableHyperVVideo,

        [switch]$RequireNvidiaSmi,

        [ValidateRange(10, 300)]
        [int]$TimeoutSeconds = 90
    )

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ([string]$vm.State -cne 'Running') {
        throw "PowerShell Direct 验证要求 VM 正在运行：$VMName"
    }
    if ($Vendor -ieq 'AMD' -and $RequireNvidiaSmi) {
        throw 'AMD guest 不能要求 nvidia-smi。'
    }

    $entry = Join-Path $PSScriptRoot 'Test-VMateGpuPGuest.ps1'
    $module = Join-Path $PSScriptRoot 'VMate.GpuP.GuestValidation.ps1'
    $d3dModule = Join-Path $PSScriptRoot 'VMate.GpuP.D3DValidation.ps1'
    foreach ($file in @($entry, $module, $d3dModule)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "缺少 GPU-P guest 验证文件：$file"
        }
    }
    $sourceHashes = @{}
    foreach ($file in @($entry, $module, $d3dModule)) {
        $sourceHashes[[IO.Path]::GetFileName($file)] =
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $session = $null
    $lastError = ''
    while ($null -eq $session -and [DateTime]::UtcNow -lt $deadline) {
        try {
            $session = New-PSSession -VMName $VMName -Credential $Credential `
                -ErrorAction Stop
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    if ($null -eq $session) {
        throw "PowerShell Direct 在 ${TimeoutSeconds}s 内未就绪：$lastError"
    }

    $guestToken = [Guid]::NewGuid().ToString('N')
    $guestDirectory = ''
    try {
        # guest 的系统盘不保证为 C:，由远端自己解析 CommonApplicationData。
        $guestDirectory = Invoke-Command -Session $session `
            -ArgumentList $guestToken `
            -ScriptBlock {
                param([string]$Token)
                $root = [Environment]::GetFolderPath('CommonApplicationData')
                if ([String]::IsNullOrWhiteSpace($root)) {
                    throw 'guest 无法解析 CommonApplicationData。'
                }
                $Path = Join-Path $root ('VMate\GpuP\verify-' + $Token)
                New-Item -ItemType Directory -Path $Path -Force `
                    -ErrorAction Stop | Out-Null
                return $Path
            } -ErrorAction Stop
        foreach ($file in @($entry, $module, $d3dModule)) {
            Copy-Item -LiteralPath $file -Destination $guestDirectory `
                -ToSession $session -ErrorAction Stop
        }

        $remoteHashes = Invoke-Command -Session $session `
            -ArgumentList $guestDirectory -ScriptBlock {
                param([string]$Path)
                Get-ChildItem -LiteralPath $Path -File | ForEach-Object {
                    [pscustomobject]@{
                        Name = $_.Name
                        SHA256 = (Get-FileHash -LiteralPath $_.FullName `
                            -Algorithm SHA256).Hash
                    }
                }
            } -ErrorAction Stop
        foreach ($remote in @($remoteHashes)) {
            if (-not $sourceHashes.ContainsKey([string]$remote.Name) -or
                [string]$sourceHashes[[string]$remote.Name] -cne
                    [string]$remote.SHA256) {
                throw "guest 验证脚本复制摘要不一致：$($remote.Name)"
            }
        }
        if (@($remoteHashes).Count -ne $sourceHashes.Count) {
            throw 'guest 验证脚本复制数量不一致。'
        }

        return Invoke-Command -Session $session -ArgumentList @(
            $guestDirectory, $Vendor, $GpuName, $DriverVersion,
            $StrictDisplay, $DisableHyperVVideo.IsPresent,
            $RequireNvidiaSmi.IsPresent
        ) -ScriptBlock {
            param(
                [string]$Path, [string]$ExpectedVendor,
                [string]$ExpectedName, [string]$ExpectedVersion,
                [bool]$Strict, [bool]$DisableVideo, [bool]$RequireSmi
            )
            $script = Join-Path $Path 'Test-VMateGpuPGuest.ps1'
            & $script -ExpectedVendor $ExpectedVendor `
                -ExpectedGpuName $ExpectedName `
                -ExpectedDriverVersion $ExpectedVersion -Strict:$Strict `
                -DisableHyperVVideo:$DisableVideo `
                -RequireNvidiaSmi:$RequireSmi
        } -ErrorAction Stop
    }
    finally {
        if ($null -ne $session) {
            if (-not [String]::IsNullOrWhiteSpace($guestDirectory)) {
                Invoke-Command -Session $session -ArgumentList $guestDirectory `
                    -ScriptBlock {
                        param([string]$Path)
                        if (Test-Path -LiteralPath $Path -PathType Container) {
                            Remove-Item -LiteralPath $Path -Recurse -Force `
                                -ErrorAction SilentlyContinue
                        }
                    } -ErrorAction SilentlyContinue
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}
