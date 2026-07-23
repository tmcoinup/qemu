#Requires -Version 5.1

<#
.SYNOPSIS
    严格解析 ExtraQemuArgs 的 QEMU -device driver selector。

.DESCRIPTION
    QEMU keyval 同时支持首个 positional driver 和 driver/type/qom-type 键。
    多个 selector 会产生解析顺序依赖，因此在显示设备策略判断前统一拒绝。
#>
function Get-VMateQemuDeviceDriver {
    param([string]$Value)

    $json = ConvertFrom-VMateQemuJsonValue -Value $Value -OptionName 'device'
    if ($null -ne $json) {
        return Get-VMateQemuBackendName -Value $Value `
            -JsonPropertyNames @('driver')
    }

    $segments = @(Split-VMateQemuOptionList -Value $Value)
    if ($segments.Count -eq 0) {
        return ''
    }
    $hasPositional = $segments[0].IndexOf('=') -lt 0
    $selectors = [System.Collections.Generic.List[object]]::new()
    foreach ($segment in $segments) {
        $equalsIndex = $segment.IndexOf('=')
        if ($equalsIndex -le 0) {
            continue
        }
        $key = $segment.Substring(0, $equalsIndex).Trim().ToLowerInvariant()
        if ($key -in @('driver', 'type', 'qom-type')) {
            $selectors.Add([pscustomobject]@{
                    Key = $key
                    Value = $segment.Substring($equalsIndex + 1).Trim()
                })
        }
    }
    if ($hasPositional -and $selectors.Count -gt 0) {
        throw 'ExtraQemuArgs 的 -device 不能同时使用 positional driver 和 driver/type/qom-type。'
    }
    if ($selectors.Count -gt 1) {
        $keys = @($selectors | ForEach-Object { $_.Key }) -join ','
        throw "ExtraQemuArgs 的 -device 含重复或冲突的 driver selector：$keys"
    }
    if ($hasPositional) {
        return $segments[0].Trim().ToLowerInvariant()
    }
    if ($selectors.Count -eq 1) {
        return ([string]$selectors[0].Value).ToLowerInvariant()
    }
    return ''
}
