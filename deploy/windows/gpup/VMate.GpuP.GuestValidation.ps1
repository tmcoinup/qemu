#Requires -Version 5.1
# 在 guest 内验证唯一、真实且受信的 GPU-P 显示栈。期望值必须来自宿主已选
# partitionable GPU；不接受投影、VioGpuDod、第三方 IDD 或 NVAPI shim。
function Assert-VMateGpuPGuestContext {
    if ($env:OS -cne 'Windows_NT') {
        throw 'GPU-P guest 验证只支持 Windows。'
    }
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if (-not [Environment]::Is64BitOperatingSystem -or
        $nativeArchitecture -ine 'AMD64') {
        throw 'P-11 GPU-P guest 必须是 x64 Windows。'
    }
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem `
        -ErrorAction Stop
    if ([string]$computer.Manufacturer -notmatch
            '(?i)^Microsoft Corporation$' -or
        [string]$computer.Model -notmatch '(?i)Virtual Machine') {
        throw '当前系统不是可识别的 Hyper-V guest，拒绝执行 guest 显示操作。'
    }
    return $computer
}
function ConvertTo-VMateGpuPGuestDriverPath {
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
        return Join-Path $env:windir $candidate.Substring(12)
    }
    if ($candidate -match '^(?i)System32\\') {
        return Join-Path $env:windir $candidate
    }
    return $candidate
}
function Get-VMateGpuPGuestDriverFiles {
    param([AllowNull()][object]$SignedDriver,
        [AllowEmptyString()][string]$Service)
    $paths = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $SignedDriver) {
        try {
            $files = @(Get-CimAssociatedInstance -InputObject $SignedDriver `
                    -Association Win32_PnPSignedDriverCIMDataFile `
                    -ErrorAction Stop)
            foreach ($file in $files) {
                $path = ConvertTo-VMateGpuPGuestDriverPath ([string]$file.Name)
                if ($path -and -not $paths.Contains($path)) {
                    [void]$paths.Add($path)
                }
            }
        } catch {
            Write-Verbose "无法枚举 guest driver files：$($_.Exception.Message)"
        }
    }
    if ($Service) {
        try {
            $escaped = $Service.Replace("'", "''")
            $services = @(Get-CimInstance -ClassName Win32_SystemDriver `
                    -Filter "Name='$escaped'" -ErrorAction Stop)
            foreach ($entry in $services) {
                $path = ConvertTo-VMateGpuPGuestDriverPath `
                    ([string]$entry.PathName)
                if ($path -and -not $paths.Contains($path)) {
                    [void]$paths.Add($path)
                }
            }
        } catch {
            Write-Verbose "无法读取 guest 显示服务 $Service：$($_.Exception.Message)"
        }
    }
    return @($paths)
}
function Get-VMateGpuPGuestDisplayInventory {
    [CmdletBinding()]
    param()
    $entities = @(Get-CimInstance -ClassName Win32_PnPEntity `
            -ErrorAction Stop | Where-Object { $_.PNPClass -ceq 'Display' })
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop | Where-Object { $_.DeviceClass -ceq 'DISPLAY' })
    $driverById = @{}
    foreach ($driver in $drivers) {
        if ([string]$driver.DeviceID) {
            $driverById[[string]$driver.DeviceID] = $driver
        }
    }
    foreach ($entity in $entities) {
        $instanceId = [string]$entity.PNPDeviceID
        $driver = if ($driverById.ContainsKey($instanceId)) {
            $driverById[$instanceId]
        } else { $null }
        $presentProperty = $entity.PSObject.Properties['Present']
        $present = $null -eq $presentProperty -or [bool]$presentProperty.Value
        $problemProperty = $entity.PSObject.Properties['ConfigManagerErrorCode']
        $problem = if ($null -eq $problemProperty) {
            -1
        } else { [int]$problemProperty.Value }
        $service = [string]$entity.Service
        [pscustomobject][ordered]@{
            Name = [string]$entity.Name
            InstanceId = $instanceId
            HardwareIds = @($entity.HardwareID)
            Manufacturer = [string]$entity.Manufacturer
            Status = [string]$entity.Status
            Present = $present
            ProblemCode = $problem
            Service = $service
            DriverProvider = if ($null -ne $driver) {
                [string]$driver.DriverProviderName
            } else { '' }
            DriverVersion = if ($null -ne $driver) {
                [string]$driver.DriverVersion
            } else { '' }
            InfName = if ($null -ne $driver) {
                [string]$driver.InfName
            } else { '' }
            IsSigned = $null -ne $driver -and $driver.IsSigned -eq $true
            Signer = if ($null -ne $driver) {
                [string]$driver.Signer
            } else { '' }
            DriverFiles = @(Get-VMateGpuPGuestDriverFiles $driver $service)
        }
    }
}
function Test-VMateGpuPHealthyDisplay {
    param([Parameter(Mandatory = $true)][object]$Display)
    return $Display.Present -eq $true -and
        [int]$Display.ProblemCode -eq 0 -and
        [string]$Display.Status -ceq 'OK'
}
function Test-VMateGpuPVersionMatch {
    param([Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][ValidateSet('NVIDIA', 'AMD')][string]$Vendor)
    if ($Actual.Trim().Equals($Expected.Trim(),
            [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($Vendor -ine 'NVIDIA') {
        return $false
    }
    # NVIDIA 的 Windows PnP 版本 32.0.15.7700 与公开版本 577.00 等价。
    $convert = {
        param([string]$Version)
        if ($Version -match '^\d+\.\d+\.(?<Branch>\d+)\.(?<Build>\d{4})$') {
            $digits = (([int]$Matches.Branch % 10).ToString()) +
                ([int]$Matches.Build).ToString('0000')
            return $digits.Insert($digits.Length - 2, '.')
        }
        return $Version.Trim()
    }
    return (& $convert $Actual).Equals((& $convert $Expected),
        [StringComparison]::OrdinalIgnoreCase)
}
function Test-VMateGpuPOfficialDriverPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $windows = [IO.Path]::GetFullPath($env:windir).TrimEnd(
            [char[]]@([IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar))
        $full = [IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    $prefix = $windows + [IO.Path]::DirectorySeparatorChar + 'System32' +
        [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    return $full -notmatch '(?i)[\\/]HostDriverStore[\\/]VMate[\\/]'
}
function Assert-VMateGpuPSignedBinary {
    param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD', 'Microsoft')][string]$Publisher)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-VMateGpuPOfficialDriverPath $Path)) {
        throw "驱动二进制不在受信 Windows 路径中：$Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path `
        -ErrorAction Stop
    $subject = if ($null -ne $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    } else { '' }
    if ([string]$signature.Status -cne 'Valid' -or
        [string]::IsNullOrWhiteSpace($subject)) {
        throw "驱动二进制 Authenticode 无效：$Path"
    }
    $allowed = switch ($Publisher) {
        'NVIDIA' { '(?i)(NVIDIA|Microsoft Windows Hardware Compatibility Publisher)' }
        'AMD' { '(?i)(Advanced Micro Devices|AMD|Microsoft Windows Hardware Compatibility Publisher)' }
        'Microsoft' { '(?i)(Microsoft Corporation|Microsoft Windows)' }
    }
    if ($subject -notmatch $allowed) {
        throw "驱动二进制 Publisher 不属于 $Publisher 官方签名链：$Path；$subject"
    }
    return $subject
}
function Get-VMateGpuPGuestVendorRuntimeFiles {
    param([Parameter(Mandatory = $true)][ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor)
    $names = if ($Vendor -ieq 'NVIDIA') {
        @('nvldumdx.dll', 'nvwgf2umx.dll', 'nvapi64.dll', 'nvcuda.dll')
    } else {
        @('atidxx64.dll', 'amdxx64.dll', 'amdxc64.dll', 'amdocl64.dll')
    }
    $roots = @(
        (Join-Path $env:windir 'System32\HostDriverStore\FileRepository'),
        (Join-Path $env:windir 'System32\DriverStore\FileRepository')
    )
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($name in $names) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter $name `
                        -File -Recurse -ErrorAction SilentlyContinue)) {
                if (-not $result.Contains($file.FullName)) {
                    [void]$result.Add($file.FullName)
                }
            }
        }
    }
    foreach ($name in $names) {
        $direct = Join-Path (Join-Path $env:windir 'System32') $name
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            [void]$result.Add($direct)
        }
    }
    return @($result)
}
function Assert-VMateGpuPDriverStack {
    param([Parameter(Mandatory = $true)][object]$Display,
        [Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [AllowEmptyCollection()][string[]]$RuntimeFiles = @())
    $providerPattern = if ($Vendor -ieq 'NVIDIA') {
        '(?i)^NVIDIA(?: Corporation)?$'
    } else { '(?i)^(AMD|Advanced Micro Devices(?:, Inc\.)?)$' }
    $isVrd = [string]$Display.Service -ieq 'VirtualRender'
    $microsoftProvider = [string]$Display.DriverProvider -match
        '(?i)^Microsoft(?: Corporation)?$'
    if (([string]$Display.DriverProvider -notmatch $providerPattern -and
            (-not $isVrd -or -not $microsoftProvider)) -or
        $Display.IsSigned -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$Display.Signer)) {
        throw "$Vendor GPU-P 设备不是匹配厂商的官方签名 PnP 驱动。"
    }
    $vendorServices = if ($Vendor -ieq 'NVIDIA') {
        @('nvlddmkm')
    } else { @('amdkmdag', 'amdwddmg', 'amdkmdap') }
    if (-not $isVrd -and $vendorServices -inotcontains
        [string]$Display.Service) {
        throw "guest GPU 服务不是 $Vendor KMD 或 Microsoft GPU-P VRD：$($Display.Service)"
    }
    $allFiles = @($Display.DriverFiles) + @($RuntimeFiles) | Select-Object -Unique
    $binaries = @($allFiles | Where-Object { $_ -match '(?i)\.(sys|dll|exe)$' })
    if ($binaries.Count -eq 0) {
        throw 'GPU-P PnP 记录没有可直接验证的驱动二进制。'
    }
    if ($isVrd) {
        $vrd = @($binaries | Where-Object {
                [IO.Path]::GetFileName($_) -ieq 'vrd.sys' -and
                $_ -match '(?i)[\\/]vrd\.inf_[^\\/]+[\\/]vrd\.sys$'
            })
        if ($vrd.Count -ne 1) {
            throw 'VirtualRender 服务没有唯一的 inbox vrd.inf/vrd.sys 路径。'
        }
        [void](Assert-VMateGpuPSignedBinary $vrd[0] Microsoft)
    } else {
        $serviceBinary = if ($Vendor -ieq 'NVIDIA') {
            @($binaries | Where-Object {
                    [IO.Path]::GetFileName($_) -ieq 'nvlddmkm.sys' })
        } else {
            @($binaries | Where-Object {
                    [IO.Path]::GetFileName($_) -match '(?i)^amd.*\.sys$' })
        }
        if ($serviceBinary.Count -eq 0) {
            throw "$Vendor 显示服务缺少对应的官方 KMD 文件。"
        }
        foreach ($file in $serviceBinary) {
            [void](Assert-VMateGpuPSignedBinary $file $Vendor)
        }
    }
    $runtimePattern = if ($Vendor -ieq 'NVIDIA') {
        '(?i)^(nvldumdx|nvwgf2umx|nvapi64|nvcuda)\.dll$'
    } else { '(?i)^(atidxx64|amdxx64|amdxc64|amdocl64)\.dll$' }
    $runtime = @($binaries | Where-Object {
            [IO.Path]::GetFileName($_) -match $runtimePattern })
    if ($runtime.Count -eq 0) {
        throw "$Vendor GPU-P 缺少官方 WDDM/DXGI 用户态驱动。"
    }
    foreach ($file in $runtime) {
        [void](Assert-VMateGpuPSignedBinary $file $Vendor)
    }
    $pnpVersionMatches = Test-VMateGpuPVersionMatch `
        ([string]$Display.DriverVersion) $ExpectedVersion $Vendor
    $runtimeVersionMatches = @($runtime | Where-Object {
            $version = [string](Get-Item -LiteralPath $_ `
                    -ErrorAction Stop).VersionInfo.FileVersion
            $version = ($version -replace '[,\s]', '')
            $version -and (Test-VMateGpuPVersionMatch $version `
                    $ExpectedVersion $Vendor)
        }).Count -gt 0
    if ((-not $isVrd -and -not $pnpVersionMatches) -or
        ($isVrd -and -not $pnpVersionMatches -and
            -not $runtimeVersionMatches)) {
        throw "guest 厂商驱动版本与宿主期望不一致：$($Display.DriverVersion) != $ExpectedVersion"
    }
    return [pscustomobject]@{
        IsVirtualRender = $isVrd
        VersionSource = if ($pnpVersionMatches) { 'PnP' } else { 'VendorUMD' }
        RuntimeFiles = $runtime
    }
}
function Assert-VMateGpuPNoNvapiShim {
    param([Parameter(Mandatory = $true)]
        [ValidateSet('NVIDIA', 'AMD')][string]$Vendor)
    $paths = @(
        (Join-Path $env:windir 'System32\nvapi64.dll'),
        (Join-Path $env:windir 'SysWOW64\nvapi.dll')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if ($Vendor -ieq 'AMD' -and $paths.Count -gt 0) {
        throw 'AMD guest 中发现 NVAPI 文件；拒绝残留或 shim 投影。'
    }
    foreach ($path in $paths) {
        [void](Assert-VMateGpuPSignedBinary $path NVIDIA)
    }
}
function Disable-VMateHyperVVideo {
    [CmdletBinding()]
    param()
    [void](Assert-VMateGpuPGuestContext)
    $targets = @(Get-VMateGpuPGuestDisplayInventory | Where-Object {
            $_.Present -eq $true -and
            [string]$_.Service -ieq 'synthvid' -and
            [string]$_.InstanceId -match '(?i)^VMBUS\\' -and
            [string]$_.DriverProvider -match '(?i)^Microsoft' -and
            ([string]$_.InstanceId -notmatch '(?i)VEN_(10DE|1002)')
        })
    foreach ($target in $targets) {
        Disable-PnpDevice -InstanceId $target.InstanceId -Confirm:$false `
            -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $current = @(Get-VMateGpuPGuestDisplayInventory | Where-Object {
                    [string]$_.InstanceId -ieq [string]$target.InstanceId
                })
            if ($current.Count -eq 0 -or
                [int]$current[0].ProblemCode -eq 22) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($current.Count -ne 0 -and
            [int]$current[0].ProblemCode -ne 22) {
            throw "Microsoft Hyper-V Video 未在等待期内进入 Code 22：$($target.InstanceId)"
        }
    }
    return @($targets)
}
function Test-VMateGpuPGuest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('NVIDIA', 'AMD')]
        [string]$Vendor,
        [Parameter(Mandatory = $true)][string]$GpuName,
        [Parameter(Mandatory = $true)][string]$DriverVersion,
        [bool]$StrictMode = $true,
        [switch]$DisableHyperVVideoAdapter, [switch]$RequireNvidiaSmi)
    [void](Assert-VMateGpuPGuestContext)
    if ([string]::IsNullOrWhiteSpace($GpuName) -or
        [string]::IsNullOrWhiteSpace($DriverVersion)) {
        throw '必须从所选宿主真实 GPU 提供非空型号和驱动版本。'
    }
    if ($Vendor -ieq 'AMD' -and $RequireNvidiaSmi.IsPresent) {
        throw 'AMD GPU-P 验证不能要求 nvidia-smi。'
    }
    if ($DisableHyperVVideoAdapter.IsPresent) {
        [void](Disable-VMateHyperVVideo)
    }
    $displays = @(Get-VMateGpuPGuestDisplayInventory)
    $present = @($displays | Where-Object { $_.Present -eq $true })
    $forbidden = '(?i)(VioGpuDod|viogpudo\.sys|VEN_1AF4|' +
        'GameViewer|IndirectKmd|IddCx|IddSample|\bIDD\b|Virtual\s*Display|' +
        'spacedesk|usbmmidd|MttVDD)'
    foreach ($display in $present) {
        $facts = @($display.Name, $display.InstanceId, $display.Service,
            $display.InfName) + @($display.HardwareIds) + @($display.DriverFiles)
        if (($facts -join '|') -match $forbidden) {
            throw "guest 中发现被禁止的 virtio/IDD 显示节点：$($display.Name) [$($display.InstanceId)]"
        }
    }
    $healthy = @($present | Where-Object { Test-VMateGpuPHealthyDisplay $_ })
    if ($healthy.Count -ne 1) {
        throw "guest 必须只有一张健康 Present 显示设备，实际：$($healthy.Count)"
    }
    $gpu = $healthy[0]
    if (-not ([string]$gpu.Name).Trim().Equals($GpuName.Trim(),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "guest GPU 型号不是所选宿主真实型号：$($gpu.Name) != $GpuName"
    }
    $vendorId = if ($Vendor -ieq 'NVIDIA') { '10DE' } else { '1002' }
    $hardwareFacts = @($gpu.InstanceId) + @($gpu.HardwareIds)
    $isVrd = [string]$gpu.Service -ieq 'VirtualRender'
    if (-not $isVrd -and
        ($hardwareFacts -join '|') -notmatch "(?i)VEN_$vendorId(?=&|\\|$)") {
        throw "guest GPU 没有真实 $Vendor PCI vendor 证据；拒绝名称字符串投影。"
    }
    $extras = @($present | Where-Object {
            [string]$_.InstanceId -cne [string]$gpu.InstanceId })
    if ($StrictMode -and $extras.Count -gt 0) {
        throw ('严格模式要求 guest 设备管理器只有一张 Present 显卡；' +
            '禁用 Microsoft Hyper-V Video 通常只产生 Code 22，devnode 仍 Present，' +
            '这是平台枚举行为，不能用注册表隐藏。额外节点：' +
            (($extras | ForEach-Object { $_.Name }) -join ', '))
    }
    if (-not $StrictMode) {
        $badExtras = @($extras | Where-Object {
                [string]$_.Name -notmatch
                    '(?i)^Microsoft Hyper-V Video(?: Adapter)?$' -or
                [int]$_.ProblemCode -ne 22
            })
        if ($badExtras.Count -gt 0) {
            throw '非严格模式也只允许已禁用(Code 22)的 Microsoft Hyper-V Video。'
        }
    }
    $runtime = @(Get-VMateGpuPGuestVendorRuntimeFiles $Vendor)
    $stack = Assert-VMateGpuPDriverStack $gpu $Vendor $DriverVersion $runtime
    Assert-VMateGpuPVendorApiFiles $Vendor
    $d3d11 = Assert-VMateGpuPD3DLoadedVendorModule `
        (Invoke-VMateGpuPD3D11HardwareProbe) $Vendor $DriverVersion
    $smi = if ($Vendor -ieq 'NVIDIA') {
        Invoke-VMateNvidiaSmiValidation $GpuName $DriverVersion `
            -Required:$RequireNvidiaSmi.IsPresent
    } else { $null }
    return [pscustomobject][ordered]@{
        Passed = $true
        Vendor = $Vendor
        GpuName = [string]$gpu.Name
        DriverVersion = [string]$gpu.DriverVersion
        Service = [string]$gpu.Service
        Stack = $stack
        PresentDisplayCount = $present.Count
        StrictMode = $StrictMode
        D3D11 = $d3d11
        VendorGpuUuid = if ($null -eq $smi) { '' } else { [string]$smi.Uuid }
        NvidiaSmi = $smi
    }
}
