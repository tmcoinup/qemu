# GPU durable transaction 的精确注册表读写与 CurrentIdentity CAS 基元。

function Assert-IdentityToken {
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Field = 'IdentityId')
    if ($Value -cnotmatch '^[0-9A-F]{32}$') {
        throw ($Field + ' 必须是 32 位大写十六进制 GUID-N：' + $Value)
    }
}

function Get-ExactRegistryValue {
    param($Key, [string]$Name, [Microsoft.Win32.RegistryValueKind]$Kind)
    if (-not (@($Key.GetValueNames()) -ccontains $Name)) { throw ('缺少注册表值：' + $Name) }
    if ($Key.GetValueKind($Name) -ne $Kind) { throw ('注册表值类型错误：' + $Name) }
    return $Key.GetValue($Name, $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Get-OptionalStringState {
    param($Key, [string]$Name)
    if (-not (@($Key.GetValueNames()) -ccontains $Name)) {
        return [pscustomobject]@{ Present = $false; Value = $null }
    }
    $value = [string](Get-ExactRegistryValue -Key $Key -Name $Name `
        -Kind ([Microsoft.Win32.RegistryValueKind]::String))
    if ([string]::IsNullOrWhiteSpace($value) -or $value.IndexOf([char]0) -ge 0) {
        throw ('注册表字符串为空或含 NUL：' + $Name)
    }
    return [pscustomobject]@{ Present = $true; Value = $value }
}

function Test-RegistryDataEqual {
    param($Left, $Right)
    if ($Left -is [array] -or $Right -is [array]) {
        $a = @($Left); $b = @($Right)
        if ($a.Count -ne $b.Count) { return $false }
        for ($i = 0; $i -lt $a.Count; $i++) {
            if ([string]$a[$i] -cne [string]$b[$i]) { return $false }
        }
        return $true
    }
    if ($Left -is [string] -or $Right -is [string]) {
        return ([string]$Left -ceq [string]$Right)
    }
    return ($Left -eq $Right)
}

function Assert-RegistryState {
    param($Key, [string]$Name, [bool]$Present, $Value,
        [Microsoft.Win32.RegistryValueKind]$Kind)
    $names = @($Key.GetValueNames())
    if (-not $Present) {
        if ($names -ccontains $Name) { throw ('回读发现本应不存在的值：' + $Name) }
        return
    }
    $actual = Get-ExactRegistryValue -Key $Key -Name $Name -Kind $Kind
    if (-not (Test-RegistryDataEqual -Left $actual -Right $Value)) {
        throw ('注册表写后回读不一致：' + $Name)
    }
}

function Set-CurrentIdentityPointer {
    # 命名 mutex 串行化仓库内写者，精确 expected state 拒绝覆盖并发修改。
    param($ConfigKey, $Expected, [bool]$NewPresent, [string]$NewValue)
    $actual = Get-OptionalStringState -Key $ConfigKey -Name 'CurrentIdentity'
    if ($actual.Present -ne $Expected.Present -or
        ($actual.Present -and $actual.Value -cne $Expected.Value)) {
        throw 'CurrentIdentity 已被并发修改，CAS 拒绝覆盖'
    }
    if ($NewPresent) {
        Assert-IdentityToken -Value $NewValue -Field '新 CurrentIdentity'
        $ConfigKey.SetValue('CurrentIdentity', $NewValue,
            [Microsoft.Win32.RegistryValueKind]::String)
    } else {
        $ConfigKey.DeleteValue('CurrentIdentity', $false)
    }
    $ConfigKey.Flush()
    Assert-RegistryState -Key $ConfigKey -Name 'CurrentIdentity' -Present $NewPresent `
        -Value $NewValue -Kind ([Microsoft.Win32.RegistryValueKind]::String)
}
