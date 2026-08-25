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

        [AllowNull()]
        [object]$ExpectedHardwareIdentity = $null,

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
    $monitorModule = Join-Path $PSScriptRoot `
        'VMate.GpuP.GuestMonitorValidation.ps1'
    $d3dModule = Join-Path $PSScriptRoot 'VMate.GpuP.D3DValidation.ps1'
    $identityModule = Join-Path $PSScriptRoot 'VMate.GpuP.GuestIdentity.ps1'
    # GuestValidation dot-sources the production Code Integrity gate. Copy the
    # complete transitive closure into the per-run guest directory; checking
    # only the four direct entry files lets the host-side copy pass but makes
    # the guest fail before any GPU validation runs.
    $codeIntegrityModule = Join-Path $PSScriptRoot `
        'VMate.Windows.CodeIntegrity.ps1'
    $validationFiles = @(
        $entry,
        $module,
        $monitorModule,
        $d3dModule,
        $identityModule,
        $codeIntegrityModule
    )
    foreach ($file in $validationFiles) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "缺少 GPU-P guest 验证文件：$file"
        }
    }
    $sourceHashes = @{}
    foreach ($file in $validationFiles) {
        $sourceHashes[[IO.Path]::GetFileName($file)] =
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    }
    $expectedHardwareJson = if ($null -eq $ExpectedHardwareIdentity) { '' }
    else { $ExpectedHardwareIdentity | ConvertTo-Json -Depth 8 -Compress }

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
        foreach ($file in $validationFiles) {
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
            $RequireNvidiaSmi.IsPresent, $expectedHardwareJson
        ) -ScriptBlock {
            param(
                [string]$Path, [string]$ExpectedVendor,
                [string]$ExpectedName, [string]$ExpectedVersion,
                [bool]$Strict, [bool]$DisableVideo, [bool]$RequireSmi,
                [string]$ExpectedHardwareJson
            )
            $script = Join-Path $Path 'Test-VMateGpuPGuest.ps1'
            $identityScript = Join-Path $Path `
                'VMate.GpuP.GuestIdentity.ps1'
            # PowerShell Direct 会话不继承宿主 powershell.exe 的
            # -ExecutionPolicy。只在该临时进程内允许已做 SHA-256 传输校验的
            # P-11 脚本；会话销毁后自动恢复，不修改 guest 的持久策略。
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass `
                -Force -ErrorAction Stop
            $result = & $script -ExpectedVendor $ExpectedVendor `
                -ExpectedGpuName $ExpectedName `
                -ExpectedDriverVersion $ExpectedVersion -Strict:$Strict `
                -DisableHyperVVideo:$DisableVideo `
                -RequireNvidiaSmi:$RequireSmi -RequireMonitor
            . $identityScript
            $observed = Get-VMateGpuPGuestHardwareIdentitySnapshot
            if (-not [String]::IsNullOrWhiteSpace($ExpectedHardwareJson)) {
                $ExpectedHardware = $ExpectedHardwareJson | ConvertFrom-Json
                $observed = Test-VMateGpuPGuestHardwareIdentityMatch `
                    -Expected $ExpectedHardware -Observed $observed
                if (-not [bool]$observed.Match) {
                    throw ('guest 硬件身份回读不一致：' +
                        (@($observed.Mismatches) -join ', '))
                }
            }
            $result | Add-Member -NotePropertyName HardwareIdentity `
                -NotePropertyValue $observed -Force
            return $result
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
