#Requires -Version 5.1

<#
.SYNOPSIS
    校验 Windows 启动器的额外 QEMU 参数。

.DESCRIPTION
    ExtraQemuArgs 是已经分词的原生命令行数组。本文件只在对应 QEMU 选项的
    backend、driver 或属性位置检查宿主能力边界，不扫描任意字符串中的关键词。
    因此 Windows AF_UNIX 路径、镜像文件名和设备 ID 可以合法包含 linux、kvm、
    vfio 等文本，同时明确的 POSIX/Linux backend 会在调用 QEMU 前 fail closed。
#>

function Get-VMateExtraOptionToken {
    param([AllowEmptyString()][string]$Token)

    $prefixLength = 0
    if ($Token.StartsWith('--', [StringComparison]::Ordinal)) {
        $prefixLength = 2
    } elseif ($Token.StartsWith('-', [StringComparison]::Ordinal)) {
        $prefixLength = 1
    } else {
        return $null
    }
    if ($Token.Length -le $prefixLength) {
        return $null
    }

    $optionText = $Token.Substring($prefixLength)
    $equalsIndex = $optionText.IndexOf('=')
    $hasInlineValue = $equalsIndex -ge 0
    if ($hasInlineValue) {
        $name = $optionText.Substring(0, $equalsIndex)
        $inlineValue = $optionText.Substring($equalsIndex + 1)
    } else {
        $name = $optionText
        $inlineValue = $null
    }
    return [pscustomobject]@{
        Name = $name
        CanonicalName = $name.ToLowerInvariant()
        PrefixLength = $prefixLength
        HasInlineValue = $hasInlineValue
        InlineValue = $inlineValue
    }
}

function Get-VMateExtraOptionValue {
    param(
        [string[]]$Arguments,
        [int]$Index,
        [object]$Option
    )

    if ($Option.HasInlineValue) {
        return [string]$Option.InlineValue
    }
    if ($Index + 1 -ge $Arguments.Count) {
        throw "ExtraQemuArgs 选项 '-$($Option.Name)' 缺少值。"
    }
    return [string]$Arguments[$Index + 1]
}

function Split-VMateQemuOptionList {
    param([AllowEmptyString()][string]$Value)

    # QEMU keyval 用连续两个逗号表示值中的字面逗号。只有未转义逗号才是属性
    # 边界，否则文件名 `disk,,aio=io_uring.qcow2` 会被误判成 aio 属性。
    $segments = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Value.Length) {
        $character = $Value[$index]
        if ($character -eq ',' -and $index + 1 -lt $Value.Length -and
            $Value[$index + 1] -eq ',') {
            [void]$current.Append(',')
            $index += 2
            continue
        }
        if ($character -eq ',') {
            $segments.Add($current.ToString())
            [void]$current.Clear()
        } else {
            [void]$current.Append($character)
        }
        $index++
    }
    $segments.Add($current.ToString())
    return @($segments)
}

function ConvertFrom-VMateQemuJsonValue {
    param(
        [string]$Value,
        [string]$OptionName
    )

    $trimmed = $Value.Trim()
    if (-not $trimmed.StartsWith('{', [StringComparison]::Ordinal)) {
        return $null
    }
    try {
        return $trimmed | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "ExtraQemuArgs 的 -$OptionName JSON 无法解析：$($_.Exception.Message)"
    }
}

function Get-VMateQemuBackendName {
    param(
        [string]$Value,
        [string[]]$JsonPropertyNames = @('type', 'driver', 'qom-type')
    )

    $json = ConvertFrom-VMateQemuJsonValue -Value $Value -OptionName 'backend'
    if ($null -ne $json) {
        foreach ($propertyName in $JsonPropertyNames) {
            $property = $json.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                return ([string]$property.Value).ToLowerInvariant()
            }
        }
        # Chardev 的 QAPI JSON 把类型放在 backend.type；其余被校验选项使用
        # 顶层 type/driver/qom-type。只支持这两个已知形状，未知 JSON 不能静默
        # 绕过 backend 门禁。
        $backendProperty = $json.PSObject.Properties['backend']
        if ($null -ne $backendProperty -and $null -ne $backendProperty.Value) {
            if ($backendProperty.Value -is [string]) {
                return ([string]$backendProperty.Value).ToLowerInvariant()
            }
            foreach ($propertyName in @('type', 'driver')) {
                $property =
                    $backendProperty.Value.PSObject.Properties[$propertyName]
                if ($null -ne $property -and $null -ne $property.Value) {
                    return ([string]$property.Value).ToLowerInvariant()
                }
            }
        }
        throw 'ExtraQemuArgs 的 backend JSON 缺少可验证的 type/driver。'
    }

    $segments = @(Split-VMateQemuOptionList -Value $Value)
    if ($segments.Count -eq 0) {
        return ''
    }
    $firstEquals = $segments[0].IndexOf('=')
    if ($firstEquals -lt 0) {
        return $segments[0].Trim().ToLowerInvariant()
    }
    foreach ($segment in $segments) {
        $equalsIndex = $segment.IndexOf('=')
        if ($equalsIndex -le 0) {
            continue
        }
        $key = $segment.Substring(0, $equalsIndex).Trim().ToLowerInvariant()
        if ($key -in $JsonPropertyNames) {
            return $segment.Substring($equalsIndex + 1).Trim().ToLowerInvariant()
        }
    }
    return ''
}

function Test-VMateJsonNodeHasKey {
    param(
        [object]$Node,
        [string[]]$Keys
    )

    if ($null -eq $Node -or $Node -is [string] -or
        $Node -is [ValueType]) {
        return $false
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $properties = @($Node.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value }
            })
    } elseif ($Node -is [System.Collections.IEnumerable] -and
        -not ($Node -is [pscustomobject])) {
        foreach ($item in $Node) {
            if (Test-VMateJsonNodeHasKey -Node $item -Keys $Keys) {
                return $true
            }
        }
        return $false
    } else {
        $properties = @($Node.PSObject.Properties)
    }
    foreach ($property in $properties) {
        if ($property.Name.ToLowerInvariant() -in $Keys -or
            (Test-VMateJsonNodeHasKey -Node $property.Value -Keys $Keys)) {
            return $true
        }
    }
    return $false
}

function Test-VMateQemuValueHasKey {
    param(
        [string]$Value,
        [string[]]$Keys
    )

    $json = ConvertFrom-VMateQemuJsonValue -Value $Value -OptionName 'backend'
    if ($null -ne $json) {
        return Test-VMateJsonNodeHasKey -Node $json -Keys $Keys
    }
    foreach ($segment in @(Split-VMateQemuOptionList -Value $Value)) {
        $equalsIndex = $segment.IndexOf('=')
        if ($equalsIndex -gt 0 -and
            $segment.Substring(0, $equalsIndex).Trim().ToLowerInvariant() -in
            $Keys) {
            return $true
        }
    }
    return $false
}

function Test-VMateRawHostDevicePath {
    param([AllowEmptyString()][string]$Value)

    $path = $Value.Trim().Trim('"').Trim("'")
    if ($path -match '^[A-Za-z]:$' -or
        $path.StartsWith('host_device:', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    foreach ($prefix in @('/dev/', '/proc/', '/sys/')) {
        if ($path.StartsWith($prefix, [StringComparison]::Ordinal)) {
            return $true
        }
    }
    $normalized = $path.Replace('/', '\')
    # QEMU 的 Windows host_device probe 把任意 \\.\ / //./ 路径当作
    # 宿主设备；不能只拦 PhysicalDrive 而放过盘符、CDROM 或其它 DOS device。
    if ($normalized.StartsWith('\\.\', [StringComparison]::Ordinal)) {
        return $true
    }
    if (-not $normalized.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        return $false
    }
    $deviceName = $normalized.Substring(4)
    foreach ($prefix in @(
            'PhysicalDrive', 'Harddisk', 'GLOBALROOT\Device\',
            'CdRom', 'Floppy', 'Tape'
        )) {
        if ($deviceName.StartsWith(
                $prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    # Volume GUID 根与盘符根会把整块 volume 暴露给 QEMU；带后续文件名的
    # \\?\C:\images\disk.qcow2 仍是合法 extended-length 普通文件。
    return ($deviceName -match '^(?i:Volume\{[^\\}]+\})(?:\\)?$' -or
        $deviceName -match '^[A-Za-z]:(?:\\)?$')
}

function Assert-VMateBlockJsonNode {
    param(
        [object]$Node,
        [string]$OptionName
    )

    if ($null -eq $Node -or $Node -is [string] -or
        $Node -is [ValueType]) {
        return
    }
    if ($Node -is [System.Collections.IEnumerable] -and
        -not ($Node -is [System.Collections.IDictionary]) -and
        -not ($Node -is [pscustomobject])) {
        foreach ($item in $Node) {
            Assert-VMateBlockJsonNode -Node $item -OptionName $OptionName
        }
        return
    }

    if ($Node -is [System.Collections.IDictionary]) {
        $properties = @($Node.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value }
            })
    } else {
        $properties = @($Node.PSObject.Properties)
    }
    foreach ($property in $properties) {
        $key = $property.Name.ToLowerInvariant()
        $text = [string]$property.Value
        if ($key -eq 'driver' -and
            $text.ToLowerInvariant() -in @('host_device', 'nvme')) {
            throw "ExtraQemuArgs 的 -$OptionName 使用了 Windows 禁止的块后端：$text"
        }
        if ($key -eq 'aio' -and $text.ToLowerInvariant() -eq 'io_uring') {
            throw "ExtraQemuArgs 的 -$OptionName 使用了 Linux-only aio=io_uring。"
        }
        if ($key -in @('file', 'filename') -and
            (Test-VMateRawHostDevicePath -Value $text)) {
            throw "ExtraQemuArgs 的 -$OptionName 不允许直连宿主原始设备：$text"
        }
        Assert-VMateBlockJsonNode -Node $property.Value -OptionName $OptionName
    }
}

function Assert-VMateBlockValue {
    param(
        [string]$Value,
        [string]$OptionName
    )

    $json = ConvertFrom-VMateQemuJsonValue -Value $Value -OptionName $OptionName
    if ($null -ne $json) {
        Assert-VMateBlockJsonNode -Node $json -OptionName $OptionName
        return
    }
    $segments = @(Split-VMateQemuOptionList -Value $Value)
    if ($OptionName -eq 'drive' -and $segments.Count -gt 0 -and
        $segments[0].IndexOf('=') -lt 0 -and
        (Test-VMateRawHostDevicePath -Value $segments[0])) {
        throw "ExtraQemuArgs 的 -$OptionName 不允许直连宿主原始设备：$($segments[0])"
    }
    foreach ($segment in $segments) {
        $equalsIndex = $segment.IndexOf('=')
        if ($equalsIndex -le 0) {
            continue
        }
        $key = $segment.Substring(0, $equalsIndex).Trim().ToLowerInvariant()
        $leafKey = $key.Substring($key.LastIndexOf('.') + 1)
        $propertyValue = $segment.Substring($equalsIndex + 1).Trim()
        $normalizedValue = $propertyValue.ToLowerInvariant()
        if ($leafKey -eq 'driver' -and
            $normalizedValue -in @('host_device', 'nvme')) {
            throw "ExtraQemuArgs 的 -$OptionName 使用了 Windows 禁止的块后端：$propertyValue"
        }
        if ($leafKey -eq 'aio' -and $normalizedValue -eq 'io_uring') {
            throw "ExtraQemuArgs 的 -$OptionName 使用了 Linux-only aio=io_uring。"
        }
        if ($leafKey -in @('file', 'filename') -and
            (Test-VMateRawHostDevicePath -Value $propertyValue)) {
            throw "ExtraQemuArgs 的 -$OptionName 不允许直连宿主原始设备：$propertyValue"
        }
    }
}

function Assert-VMateBackendAllowed {
    param(
        [string]$OptionName,
        [string]$Value,
        [string[]]$DeniedBackends,
        [string[]]$JsonPropertyNames = @('type', 'driver', 'qom-type')
    )

    $backend = Get-VMateQemuBackendName -Value $Value `
        -JsonPropertyNames $JsonPropertyNames
    if ($backend -in $DeniedBackends) {
        throw "ExtraQemuArgs 的 -$OptionName backend '$backend' 不支持 Windows。"
    }
}

function Assert-VMateExtraArguments {
    param([string[]]$Arguments)

    $reserved = @(
        'accel', 'cpu', 'uuid', 'smbios', 'rtc', 'machine', 'global',
        'm', 'memory', 'smp', 'numa', 'set'
    )
    $directDenied = @(
        'enable-kvm', 'xen-domid', 'xen-attach', 'xen-domid-restrict',
        'daemonize', 'run-with', 'sandbox', 'add-fd', 'remove-fd',
        'mem-path', 'mem-prealloc', 'fsdev', 'virtfs', 'tpmdev',
        'overcommit', 'plugin', 'readconfig'
    )
    $networkDenied = @(
        'bridge', 'passt', 'l2tpv3', 'vde', 'netmap', 'af-xdp',
        'vhost-user', 'vhost-vdpa',
        'vmnet-host', 'vmnet-shared', 'vmnet-bridged'
    )
    $objectDenied = @(
        'rng-random', 'memory-backend-file', 'memory-backend-shm',
        'memory-backend-memfd', 'memory-backend-epc', 'iommufd',
        'secret_keyring', 'cryptodev-vhost-user', 'vhost-user-backend',
        'input-linux', 'can-host-socketcan', 'pr-manager-helper',
        'sev-guest', 'sev-snp-guest', 'tdx-guest'
    )
    $audioDenied = @('alsa', 'oss', 'pa', 'pulseaudio', 'pipewire',
        'sndio', 'coreaudio')

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        $option = Get-VMateExtraOptionToken -Token $argument
        if ($null -eq $option) {
            continue
        }
        $name = [string]$option.CanonicalName

        # 内存/vCPU 拓扑同样来自持久 profile；允许末尾的 -m/-smp 覆盖会让
        # profile 与客体实际硬件分叉。相似前缀仍不是保留选项。
        if ($name -in $reserved -or
            ($option.PrefixLength -eq 1 -and $option.Name -ceq 'M')) {
            throw "ExtraQemuArgs 不允许覆盖保留参数：$argument"
        }
        if ($name -in $directDenied) {
            throw "ExtraQemuArgs 的宿主选项不支持 Windows：$argument"
        }

        switch ($name) {
            { $_ -in @('netdev', 'nic', 'net') } {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                Assert-VMateBackendAllowed -OptionName $name -Value $value `
                    -DeniedBackends $networkDenied
                $backend = Get-VMateQemuBackendName -Value $value
                if ($backend -eq 'tap' -and
                    (Test-VMateQemuValueHasKey -Value $value -Keys @(
                            'fd', 'fds', 'script', 'downscript', 'br', 'helper',
                            'vnet_hdr', 'vhost', 'vhostfd', 'vhostfds',
                            'vhostforce', 'queues', 'poll-us'
                        ))) {
                    throw 'ExtraQemuArgs 的 Windows TAP-Win32 只允许 ifname 等原生属性。'
                }
                if ($backend -eq 'user' -and
                    (Test-VMateQemuValueHasKey -Value $value -Keys @('smb'))) {
                    throw 'ExtraQemuArgs 的 Windows user 网络不支持宿主 smbd。'
                }
                break
            }
            'chardev' {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                Assert-VMateBackendAllowed -OptionName $name -Value $value `
                    -DeniedBackends @('pty', 'parallel', 'fd')
                $backend = Get-VMateQemuBackendName -Value $value
                if ($backend -eq 'file' -and
                    (Test-VMateQemuValueHasKey -Value $value `
                        -Keys @('input-path'))) {
                    throw 'ExtraQemuArgs 的 Windows file chardev 不支持 input-path。'
                }
                break
            }
            { $_ -in @('serial', 'parallel', 'monitor', 'qmp') } {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                $backend = ($value.Split(':', 2)[0]).ToLowerInvariant()
                if ($backend -in @('pty', 'parport', 'fd')) {
                    throw "ExtraQemuArgs 的 -$name backend '$backend' 不支持 Windows。"
                }
                break
            }
            { $_ -in @('audiodev', 'audio') } {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                Assert-VMateBackendAllowed -OptionName $name -Value $value `
                    -DeniedBackends $audioDenied
                break
            }
            'object' {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                Assert-VMateBackendAllowed -OptionName $name -Value $value `
                    -DeniedBackends $objectDenied
                break
            }
            'device' {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                $device = Get-VMateQemuBackendName -Value $value `
                    -JsonPropertyNames @('driver')
                if ($device.StartsWith('vfio-', [StringComparison]::Ordinal) -or
                    $device.StartsWith('vhost-', [StringComparison]::Ordinal) -or
                    $device -in @('pci-assign', 'kvm-pci-assign',
                        'virtio-blk-vhost-vdpa', 'vdpa-dev',
                        'usb-mtp', 'u2f-passthru')) {
                    throw "ExtraQemuArgs 的 -device '$device' 不支持 Windows。"
                }
                break
            }
            { $_ -in @('drive', 'blockdev') } {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                Assert-VMateBlockValue -Value $value -OptionName $name
                break
            }
            { $_ -in @(
                    'fda', 'fdb', 'hda', 'hdb', 'hdc', 'hdd',
                    'cdrom', 'pflash'
                ) } {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                if (Test-VMateRawHostDevicePath -Value $value) {
                    throw "ExtraQemuArgs 的 -$name 不允许直连宿主原始设备：$value"
                }
                break
            }
            'incoming' {
                $value = Get-VMateExtraOptionValue $Arguments $index $option
                $transport = ($value.Split(':', 2)[0]).ToLowerInvariant()
                if ($transport -in @('exec', 'fd', 'rdma')) {
                    throw "ExtraQemuArgs 的 -incoming transport '$transport' 不支持 Windows。"
                }
                break
            }
        }
    }
}
