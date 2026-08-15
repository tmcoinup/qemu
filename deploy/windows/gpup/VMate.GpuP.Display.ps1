#Requires -Version 5.1

<#
.SYNOPSIS
    盘点宿主显示设备，并为外部宿主 IDD 安装包提供签名门禁。

.DESCRIPTION
    本模块不会携带、下载或自动安装任何虚拟显示驱动。显示盘点是只读操作；
    安装函数只接受调用者显式提供、位于仓库外且 Authenticode 有效的 EXE/MSI，
    并强制使用无交互参数。所有安装能力都拒绝在 Hyper-V guest 中运行。
#>

function Assert-VMateGpuPHostContext {
    param(
        [switch]$RequireHyperV,
        [switch]$RequireAdministrator
    )

    if ($env:OS -cne 'Windows_NT') {
        throw 'GPU-P 宿主显示操作只支持 Windows。'
    }
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem `
        -ErrorAction Stop
    $manufacturer = [string]$computer.Manufacturer
    $model = [string]$computer.Model
    if ($manufacturer -match '(?i)^Microsoft Corporation$' -and
        $model -match '(?i)Virtual Machine') {
        throw '拒绝在 Hyper-V guest 中执行宿主 IDD 操作。'
    }
    if ($RequireHyperV -and
        -not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
        throw '当前系统未提供 Hyper-V PowerShell 模块，不能作为 GPU-P 宿主安装 IDD。'
    }
    if ($RequireAdministrator) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $role = [Security.Principal.WindowsBuiltInRole]::Administrator
        if (-not $principal.IsInRole($role)) {
            throw '安装宿主 IDD 必须使用管理员 PowerShell。'
        }
    }
    return $computer
}

function ConvertTo-VMateGpuPDriverFilePath {
    param([AllowEmptyString()][string]$PathName)

    if ([string]::IsNullOrWhiteSpace($PathName)) {
        return ''
    }
    $candidate = $PathName.Trim()
    if ($candidate -match '^"(?<Path>[^"]+)"') {
        $candidate = $Matches.Path
    } elseif ($candidate -match '^(?<Path>\S+?\.sys)(?:\s|$)') {
        $candidate = $Matches.Path
    }
    if ($candidate -match '^(?i)\\SystemRoot\\') {
        $candidate = Join-Path $env:windir $candidate.Substring(12)
    } elseif ($candidate -match '^(?i)System32\\') {
        $candidate = Join-Path $env:windir $candidate
    }
    return $candidate
}

function Get-VMateGpuPDisplayDriverFiles {
    param(
        [AllowNull()][object]$SignedDriver,
        [AllowEmptyString()][string]$Service
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $SignedDriver) {
        try {
            $files = @(Get-CimAssociatedInstance -InputObject $SignedDriver `
                    -Association Win32_PnPSignedDriverCIMDataFile `
                    -ErrorAction Stop)
            foreach ($file in $files) {
                $path = ConvertTo-VMateGpuPDriverFilePath ([string]$file.Name)
                if ($path -and -not $paths.Contains($path)) {
                    [void]$paths.Add($path)
                }
            }
        } catch {
            Write-Verbose "未能枚举 PnP driver files：$($_.Exception.Message)"
        }
    }
    if ($Service) {
        try {
            $escapedService = $Service.Replace("'", "''")
            $systemDriver = Get-CimInstance -ClassName Win32_SystemDriver `
                -Filter "Name='$escapedService'" -ErrorAction Stop
            foreach ($entry in @($systemDriver)) {
                $path = ConvertTo-VMateGpuPDriverFilePath `
                    ([string]$entry.PathName)
                if ($path -and -not $paths.Contains($path)) {
                    [void]$paths.Add($path)
                }
            }
        } catch {
            Write-Verbose "未能读取显示服务 $Service：$($_.Exception.Message)"
        }
    }
    return @($paths)
}

function Get-VMateGpuPHostDisplayInventory {
    [CmdletBinding()]
    param()

    [void](Assert-VMateGpuPHostContext)
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity `
            -ErrorAction Stop | Where-Object { $_.PNPClass -ceq 'Display' })
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop | Where-Object { $_.DeviceClass -ceq 'DISPLAY' })
    $driverById = @{}
    foreach ($driver in $drivers) {
        $deviceId = [string]$driver.DeviceID
        if ($deviceId) {
            $driverById[$deviceId] = $driver
        }
    }

    foreach ($entity in $entities) {
        $instanceId = [string]$entity.PNPDeviceID
        $service = [string]$entity.Service
        $driver = $null
        if ($driverById.ContainsKey($instanceId)) {
            $driver = $driverById[$instanceId]
        }
        $files = @(Get-VMateGpuPDisplayDriverFiles -SignedDriver $driver `
                -Service $service)
        $evidence = [System.Collections.Generic.List[string]]::new()
        $isPhysicalPci = $instanceId -match '(?i)^PCI\\VEN_[0-9A-F]{4}&DEV_'
        if (-not $isPhysicalPci) {
            [void]$evidence.Add('InstanceId 不是物理 PCI display 路径')
        }
        $iddPattern = '(?i)(GameViewer|Indirect|IddCx|IddSample|\bIDD\b|' +
            'Virtual\s*Display|DisplayLink|spacedesk|usbmmidd|MttVDD)'
        if ($service -match $iddPattern) {
            [void]$evidence.Add("Service=$service 命中 IDD/虚拟显示特征")
        }
        $matchedFiles = @($files | Where-Object {
                ([IO.Path]::GetFileName($_) -match $iddPattern) -or
                ($_ -match $iddPattern)
            })
        foreach ($matchedFile in $matchedFiles) {
            [void]$evidence.Add(
                "DriverFile=$matchedFile 命中 IDD/虚拟显示特征")
        }
        $isIndirect = ($service -match $iddPattern) -or
            $matchedFiles.Count -gt 0

        [pscustomobject][ordered]@{
            Name = [string]$entity.Name
            InstanceId = $instanceId
            Status = [string]$entity.Status
            Present = [bool]$entity.Present
            Service = $service
            Provider = if ($null -ne $driver) {
                [string]$driver.DriverProviderName
            } else { '' }
            DriverVersion = if ($null -ne $driver) {
                [string]$driver.DriverVersion
            } else { '' }
            InfName = if ($null -ne $driver) {
                [string]$driver.InfName
            } else { '' }
            DriverFiles = $files
            IsPhysicalPci = $isPhysicalPci
            IsNonPhysical = -not $isPhysicalPci
            IsIndirectDisplay = $isIndirect
            Evidence = @($evidence)
        }
    }
}

function Get-VMateGpuPHostIndirectDisplayAdapter {
    [CmdletBinding()]
    param()

    return @(Get-VMateGpuPHostDisplayInventory | Where-Object {
            $_.IsNonPhysical -or $_.IsIndirectDisplay
        })
}

function Get-VMateGpuPHostIddInstallerTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPublisher
    )

    [void](Assert-VMateGpuPHostContext)
    if ([string]::IsNullOrWhiteSpace($ExpectedPublisher)) {
        throw 'ExpectedPublisher 不能为空；必须由调用者固定外部 IDD 供应商。'
    }
    $item = Get-Item -LiteralPath $InstallerPath -ErrorAction Stop
    if ($item.PSIsContainer -or @('.exe', '.msi') -cnotcontains
        $item.Extension.ToLowerInvariant()) {
        throw '宿主 IDD 安装包必须是一个 EXE 或 MSI 文件。'
    }
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $repoPrefix = $repoRoot.TrimEnd([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)) +
        [IO.Path]::DirectorySeparatorChar
    $fullPath = [IO.Path]::GetFullPath($item.FullName)
    if ($fullPath.StartsWith($repoPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'IDD 安装包必须由调用者从仓库外部提供；禁止在项目中捆绑私有驱动。'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath `
        -ErrorAction Stop
    $certificate = $signature.SignerCertificate
    $publisher = if ($null -ne $certificate) {
        [string]$certificate.Subject
    } else { '' }
    if ([string]$signature.Status -cne 'Valid' -or
        [string]::IsNullOrWhiteSpace($publisher)) {
        throw "IDD 安装包 Authenticode 无效或 Publisher 为空：$fullPath"
    }
    if ($publisher.IndexOf($ExpectedPublisher,
            [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "IDD 安装包 Publisher 不匹配：$publisher"
    }
    $hash = Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 `
        -ErrorAction Stop
    return [pscustomobject][ordered]@{
        Path = $fullPath
        Extension = $item.Extension.ToLowerInvariant()
        Publisher = $publisher
        Thumbprint = [string]$certificate.Thumbprint
        Sha256 = [string]$hash.Hash
        AuthenticodeStatus = [string]$signature.Status
    }
}

function Test-VMateSignedHostIddInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPublisher
    )

    try {
        [void](Get-VMateGpuPHostIddInstallerTrust `
                -InstallerPath $InstallerPath `
                -ExpectedPublisher $ExpectedPublisher)
        return $true
    } catch {
        Write-Verbose $_.Exception.Message
        return $false
    }
}

function Invoke-VMateSignedHostIddInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPublisher,
        [string[]]$SilentArgument = @()
    )

    [void](Assert-VMateGpuPHostContext -RequireHyperV -RequireAdministrator)
    $trust = Get-VMateGpuPHostIddInstallerTrust `
        -InstallerPath $InstallerPath -ExpectedPublisher $ExpectedPublisher
    if ($trust.Extension -ceq '.msi') {
        if ($SilentArgument.Count -gt 0) {
            throw 'MSI 的静默参数由 VMate 固定，不能追加供应商参数。'
        }
        $filePath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $arguments = @('/i', ('"{0}"' -f $trust.Path), '/qn', '/norestart')
    } else {
        $joined = $SilentArgument -join ' '
        if (-not $SilentArgument -or
            $joined -notmatch '(?i)(^|\s)(/S|/quiet|--quiet|--silent)(\s|$)') {
            throw 'EXE 安装包必须显式提供 /S、/quiet、--quiet 或 --silent。'
        }
        if ($joined -match '(?i)(prompt|interactive|/passive)') {
            throw 'IDD 安装参数不得启用 prompt、interactive 或 passive UI。'
        }
        $filePath = $trust.Path
        $arguments = @($SilentArgument)
    }

    # 在启动前重新计算摘要，缩小签名校验与执行之间的替换窗口。
    $currentHash = Get-FileHash -LiteralPath $trust.Path -Algorithm SHA256 `
        -ErrorAction Stop
    if ([string]$currentHash.Hash -cne $trust.Sha256) {
        throw 'IDD 安装包在签名校验后发生变化，已拒绝执行。'
    }
    $process = Start-Process -FilePath $filePath -ArgumentList $arguments `
        -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    if ($process.ExitCode -ne 0) {
        throw "宿主 IDD 安装失败，退出码：$($process.ExitCode)"
    }
    return [pscustomobject][ordered]@{
        Path = $trust.Path
        Publisher = $trust.Publisher
        Sha256 = $trust.Sha256
        ExitCode = $process.ExitCode
        HostOnly = $true
    }
}
