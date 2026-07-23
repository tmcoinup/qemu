#Requires -Version 5.1

<#
.SYNOPSIS
    提供不依赖 PowerShell 版本行为的严格 JSON property 唯一性检查。

.DESCRIPTION
    Windows PowerShell 5.1 与 PowerShell 7 对重复 JSON property 的处理并不完全
    一致。本模块在 ConvertFrom-Json 前按 JSON 结构遍历任意深度的 object，并对
    解码后的 property 名执行 Ordinal 唯一性检查。
#>

function Assert-VMateJsonNoDuplicateProperties {
    param(
        [string]$Json,
        [string]$Label
    )

    # 状态放入引用对象，使递归 scriptblock 在子作用域中仍能推进同一游标。
    $state = [pscustomobject]@{ Text = $Json; Index = 0; Length = $Json.Length }
    $skipWhitespace = {
        while ($state.Index -lt $state.Length -and
            [char]::IsWhiteSpace($state.Text[$state.Index])) {
            $state.Index++
        }
    }
    $readString = {
        & $skipWhitespace
        if ($state.Index -ge $state.Length -or
            $state.Text[$state.Index] -ne '"') {
            throw "$Label 的 JSON object key 必须是字符串。"
        }
        $start = $state.Index
        $state.Index++
        while ($state.Index -lt $state.Length) {
            $character = $state.Text[$state.Index]
            if ($character -eq '\') {
                $state.Index += 2
                if ($state.Index -gt $state.Length) {
                    throw "$Label 的 JSON 字符串转义不完整。"
                }
                continue
            }
            $state.Index++
            if ($character -eq '"') {
                $raw = $state.Text.Substring($start, $state.Index - $start)
                return ConvertFrom-Json -InputObject $raw -ErrorAction Stop
            }
            if ([int]$character -lt 0x20) {
                throw "$Label 的 JSON 字符串含未转义控制字符。"
            }
        }
        throw "$Label 的 JSON 字符串未闭合。"
    }

    $parseValue = $null
    $parseObject = $null
    $parseArray = $null
    $parseValue = {
        & $skipWhitespace
        if ($state.Index -ge $state.Length) {
            throw "$Label 的 JSON 值不完整。"
        }
        switch ($state.Text[$state.Index]) {
            '{' { & $parseObject; return }
            '[' { & $parseArray; return }
            '"' { [void](& $readString); return }
        }
        $start = $state.Index
        while ($state.Index -lt $state.Length -and
            $state.Text[$state.Index] -notin @(',', '}', ']') -and
            -not [char]::IsWhiteSpace($state.Text[$state.Index])) {
            $state.Index++
        }
        if ($state.Index -eq $start) {
            throw "$Label 的 JSON 值无效。"
        }
    }
    $parseObject = {
        $state.Index++
        $names = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal)
        & $skipWhitespace
        if ($state.Index -lt $state.Length -and
            $state.Text[$state.Index] -eq '}') {
            $state.Index++
            return
        }
        while ($true) {
            $name = & $readString
            if (-not $names.Add([string]$name)) {
                throw "$Label 含重复 JSON property：$name"
            }
            & $skipWhitespace
            if ($state.Index -ge $state.Length -or
                $state.Text[$state.Index] -ne ':') {
                throw "$Label 的 JSON property '$name' 缺少冒号。"
            }
            $state.Index++
            & $parseValue
            & $skipWhitespace
            if ($state.Index -lt $state.Length -and
                $state.Text[$state.Index] -eq ',') {
                $state.Index++
                continue
            }
            if ($state.Index -lt $state.Length -and
                $state.Text[$state.Index] -eq '}') {
                $state.Index++
                return
            }
            throw "$Label 的 JSON object 分隔符无效。"
        }
    }
    $parseArray = {
        $state.Index++
        & $skipWhitespace
        if ($state.Index -lt $state.Length -and
            $state.Text[$state.Index] -eq ']') {
            $state.Index++
            return
        }
        while ($true) {
            & $parseValue
            & $skipWhitespace
            if ($state.Index -lt $state.Length -and
                $state.Text[$state.Index] -eq ',') {
                $state.Index++
                continue
            }
            if ($state.Index -lt $state.Length -and
                $state.Text[$state.Index] -eq ']') {
                $state.Index++
                return
            }
            throw "$Label 的 JSON array 分隔符无效。"
        }
    }

    & $parseValue
    & $skipWhitespace
    if ($state.Index -ne $state.Length) {
        throw "$Label 的 JSON 根值后含额外内容。"
    }
}
