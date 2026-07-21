#Requires -Version 5.1

<#
.SYNOPSIS
  提供 NVAPI 系统投影共用的只读文件、摘要与 PE 校验函数。

.DESCRIPTION
  安装器和 durable transaction helper 共用这些函数。这里仅检查路径与文件字节，
  不加载 DLL，也不执行目标文件中的代码；因此预检和故障恢复可以使用同一套严格
  规则，同时让主安装器保持在单文件 500 行限制以内。
#>

function Get-LowerSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PeMetadata {
    # 只读取固定 PE 头字段，既不加载 DLL，也不会执行目标文件中的任何代码。
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw ('不是有效的 MZ 文件：' + $Path)
        }
        $stream.Position = 0x3C
        $peOffset = [int64]$reader.ReadUInt32()
        if ($peOffset -lt 0x40 -or $peOffset + 24 -gt $stream.Length) {
            throw ('PE 头偏移越界：' + $Path)
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw ('缺少 PE 签名：' + $Path)
        }
        $machine = $reader.ReadUInt16()
        $null = $reader.ReadUInt16()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $optionalSize = $reader.ReadUInt16()
        $characteristics = $reader.ReadUInt16()
        if ($optionalSize -lt 2 -or $stream.Position + $optionalSize -gt $stream.Length) {
            throw ('PE Optional Header 越界：' + $Path)
        }
        $optionalMagic = $reader.ReadUInt16()
        return [pscustomobject]@{
            Machine = [int]$machine
            OptionalMagic = [int]$optionalMagic
            IsDll = (($characteristics -band 0x2000) -ne 0)
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-PlainFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('拒绝目录或重解析点文件：' + $Path)
    }
    return $item
}

function Assert-PlainDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('拒绝非普通目录或重解析点：' + $Path)
    }
}

function Assert-NvapiBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][int]$ExpectedMachine,
        [Parameter(Mandatory = $true)][int]$ExpectedMagic
    )

    $item = Assert-PlainFile -Path $Path
    if ($item.Length -lt 4096 -or $item.Length -gt 4MB) {
        throw ('NVAPI 文件大小越界：' + $Path)
    }
    $actualHash = Get-LowerSha256 -Path $Path
    if ($actualHash -cne $ExpectedHash) {
        throw ('NVAPI SHA-256 不匹配：' + $Path + '，actual=' + $actualHash)
    }
    $pe = Get-PeMetadata -Path $Path
    if (-not $pe.IsDll -or $pe.Machine -ne $ExpectedMachine -or
        $pe.OptionalMagic -ne $ExpectedMagic) {
        throw ('NVAPI PE 架构错误：{0}，Machine=0x{1:X4}，Magic=0x{2:X3}' -f
            $Path, $pe.Machine, $pe.OptionalMagic)
    }
}

function Test-HashInAllowList {
    param(
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string[]]$AllowedHashes
    )

    foreach ($allowed in $AllowedHashes) {
        if ($Hash -ceq $allowed) { return $true }
    }
    return $false
}
