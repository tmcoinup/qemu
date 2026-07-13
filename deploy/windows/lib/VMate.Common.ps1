#Requires -Version 5.1

<#
.SYNOPSIS
    Windows 启动脚本共用的路径、参数和 QEMU 字符串工具。

.DESCRIPTION
    这些函数刻意保持无副作用，便于 PowerShell AST 测试和 DryRun 调用。
    入口脚本只负责业务编排，避免路径探测、列表构造在多个文件中漂移。
#>

function Get-VMateRepoRoot {
    # deploy/windows/lib/VMate.Common.ps1 向上三级即仓库根目录。
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

function Find-VMateFirstExisting {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return ''
}

function Add-VMateArgument {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string[]]$Items
    )

    foreach ($item in $Items) {
        [void]$List.Add($item)
    }
}

function ConvertTo-VMateQemuString {
    param([AllowEmptyString()][string]$Value)

    # QEMU keyval 语法用连续两个逗号表示值中的字面逗号。换行会破坏参数边界，
    # 不允许进入命令行；这也阻断手工修改 manifest 后的参数注入。
    if ($Value -match "[`r`n]") {
        throw 'QEMU 字符串字段不能包含换行。'
    }
    return $Value.Replace(',', ',,')
}

function Test-VMateUnsignedInteger {
    param(
        [object]$Value,
        [int64]$Minimum = 0,
        [int64]$Maximum = [int64]::MaxValue
    )

    $parsed = 0L
    return ([int64]::TryParse([string]$Value, [ref]$parsed) -and
        $parsed -ge $Minimum -and $parsed -le $Maximum)
}
