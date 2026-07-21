#Requires -Version 5.1

<#
.SYNOPSIS
  原子发布或移除 Windows 双架构系统目录中的独立 AMD ADL 身份读取层。

.DESCRIPTION
  同一份 x86 实现同时发布为 SysWOW64\atiadlxy.dll 与 atiadlxx.dll，覆盖不同
  硬件检测工具采用的经典 ADL 优先名称；x64 实现发布为 System32\atiadlxx.dll。
  三个目标共用一张 durable receipt，任一提交失败都会按相反顺序回滚。

  DesiredState=Absent 不依赖 payload，只会移除已登记的项目投影；
  移除同样使用先收据、后 write-through Move 到同目录 backup 的事务边界。

  目标只允许不存在、当前固定摘要或明确登记的历史项目摘要。真实 AMD 驱动和任何未知
  DLL 都会 fail-closed；脚本不修改目标 ACL、owner、驱动或签名策略。
#>

[CmdletBinding()]
param(
    [string]$PayloadDir = '',
    [ValidateSet('Preflight', 'Install', 'Recover', 'Finalize', 'Rollback')]
    [string]$Action = 'Install',
    [string]$TransactionId = '',
    [ValidateSet('Present', 'Absent')]
    [string]$DesiredState = 'Present',
    [switch]$DeferFinalize
)

$ErrorActionPreference = 'Stop'
$DesiredState = if ($DesiredState -eq 'Absent') { 'Absent' } else { 'Present' }
# 当前构建的固定摘要；历史列表只含本项目已发布的独立 ADL 读取层，不能放行第三方 DLL。
$ExpectedX86Hash = '86aca99433da976135f68b4b2904c04eaee370d97104b5a1622ad59f8731b1dd'
$ExpectedX64Hash = '99b7e84b404bfa5140218549b4a49d68ebdfddb181ad9fdd72dcac296d799a62'
$HistoricalX86Hashes = @(
    'baacab32f579313757ef29ec00b80002ef824846f8ea80128a6ea0c2f0cdab90'
)
$HistoricalX64Hashes = @(
    'b44b814dcc4dfa411b7a4e4e5fe38248e319cbbcc9143e5bf525b84313ddfd68'
)

function Get-LowerSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Initialize-PlainDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = [IO.Directory]::CreateDirectory($Path)
    }
    Assert-PlainDirectory -Path $Path
}

function Get-PeMetadata {
    # 仅解析固定 PE 头，不加载或执行待发布 DLL。
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

function Assert-AdlBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][int]$ExpectedMachine,
        [Parameter(Mandatory = $true)][int]$ExpectedMagic
    )
    if ($ExpectedHash -cnotmatch '\A[0-9a-f]{64}\z') {
        throw ('ADL 构建摘要尚未注入：' + $ExpectedHash)
    }
    $item = Assert-PlainFile -Path $Path
    if ($item.Length -lt 4096 -or $item.Length -gt 4MB) {
        throw ('ADL 文件大小越界：' + $Path)
    }
    $actualHash = Get-LowerSha256 -Path $Path
    if ($actualHash -cne $ExpectedHash) {
        throw ('ADL SHA-256 不匹配：' + $Path + '，actual=' + $actualHash)
    }
    $pe = Get-PeMetadata -Path $Path
    if (-not $pe.IsDll -or $pe.Machine -ne $ExpectedMachine -or
        $pe.OptionalMagic -ne $ExpectedMagic) {
        throw ('ADL PE 架构错误：{0}，Machine=0x{1:X4}，Magic=0x{2:X3}' -f
            $Path, $pe.Machine, $pe.OptionalMagic)
    }
}

function Test-HashInAllowList {
    param(
        [Parameter(Mandatory = $true)][string]$Hash,
        [AllowEmptyCollection()][string[]]$AllowedHashes = @()
    )
    foreach ($allowed in $AllowedHashes) {
        if ($Hash -ceq $allowed) { return $true }
    }
    return $false
}

function Get-AdlProjectionSnapshot {
    # 只接受当前或显式历史项目摘要；真实 AMD ADL 与未知同名文件一律拒绝覆盖。
    param([Parameter(Mandatory = $true)]$Entry)
    if (-not (Test-Path -LiteralPath $Entry.Target)) {
        return [pscustomobject]@{ State='Absent'; Hash='' }
    }
    $null = Assert-PlainFile -Path $Entry.Target
    $hash = Get-LowerSha256 -Path $Entry.Target
    if ($hash -ceq $Entry.ExpectedHash) {
        return [pscustomobject]@{ State='Current'; Hash=$hash }
    }
    if (Test-HashInAllowList $hash $Entry.HistoricalHashes) {
        return [pscustomobject]@{ State='ManagedHistorical'; Hash=$hash }
    }
    throw ('拒绝覆盖未知或真实 AMD ADL DLL：' + $Entry.Target +
        '，SHA-256=' + $hash)
}

function Remove-TransactionFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) { return }
    $null = Assert-PlainFile -Path $Path
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

$transactionHelper = Join-Path $PSScriptRoot 'adl-system-transaction.ps1'
if (-not (Test-Path -LiteralPath $transactionHelper -PathType Leaf)) {
    throw ('缺少 ADL durable transaction helper：' + $transactionHelper)
}
. $transactionHelper

function Move-VerifiedAdlTarget {
    # 预检后先原子分离目标，再对实际被移动实体复算摘要，关闭检查/替换竞态。
    param([Parameter(Mandatory = $true)]$Entry)
    Move-AdlFileWriteThrough $Entry.Target $Entry.Backup
    try {
        $null = Assert-PlainFile -Path $Entry.Backup
        if ((Get-LowerSha256 $Entry.Backup) -cne $Entry.ObservedHash) {
            throw ('ADL 目标在预检后发生变化：' + $Entry.Target)
        }
    } catch {
        $moveError = $_.Exception
        if ((Test-Path -LiteralPath $Entry.Backup) -and
            -not (Test-Path -LiteralPath $Entry.Target)) {
            Move-AdlFileWriteThrough $Entry.Backup $Entry.Target
        }
        throw $moveError
    }
}

function Publish-AdlProjection {
    param([object[]]$Entries, [string]$ReceiptPath, [string]$ReceiptId)
    # 先完成全部目标分类，任一未知/真实 ADL 都会在 receipt 和
    # 系统目录写入之前拒绝，不会出现只移除一半的交叉状态。
    foreach ($entry in $Entries) {
        $snapshot = Get-AdlProjectionSnapshot $entry
        $entry.State = $snapshot.State
        $entry.ObservedHash = $snapshot.Hash
        if ($entry.DesiredState -ceq 'Absent') {
            if ($entry.State -eq 'Absent') {
                $entry.CommitAction = 'UnchangedAbsent'
            } else {
                $entry.CommitAction = 'Removed'
                $entry.Backup = Join-Path $entry.Directory `
                    ('.' + $entry.FileName + '.vmate-backup-' + [Guid]::NewGuid().ToString('N'))
            }
            continue
        }
        if ($entry.State -eq 'Current') { continue }
        $suffix = [Guid]::NewGuid().ToString('N')
        $entry.Stage = Join-Path $entry.Directory `
            ('.' + $entry.FileName + '.vmate-stage-' + $suffix)
        $entry.Discard = Join-Path $entry.Directory `
            ('.' + $entry.FileName + '.vmate-rollback-' + [Guid]::NewGuid().ToString('N'))
        if ($entry.State -eq 'Absent') {
            $entry.CommitAction = 'Created'
        } else {
            $entry.CommitAction = 'Replaced'
            $entry.Backup = Join-Path $entry.Directory `
                ('.' + $entry.FileName + '.vmate-backup-' + [Guid]::NewGuid().ToString('N'))
        }
    }

    # receipt 成功落盘之前，禁止向任一系统目录复制或改名。
    Write-AdlProjectionReceipt $Entries $ReceiptPath $ReceiptId
    try {
        foreach ($entry in $Entries) {
            if ($entry.DesiredState -ceq 'Absent') { continue }
            if ($entry.State -eq 'Current') { continue }
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Stage -ErrorAction Stop
            Assert-AdlBinary $entry.Stage $entry.ExpectedHash $entry.Machine $entry.Magic
            Sync-AdlFileData $entry.Stage
        }
        foreach ($entry in $Entries) {
            if ($entry.DesiredState -ceq 'Absent') {
                if ($entry.CommitAction -ceq 'Removed') {
                    Move-VerifiedAdlTarget $entry
                }
                continue
            }
            if ($entry.State -eq 'Current') { continue }
            if ($entry.State -eq 'Absent') {
                Move-AdlFileWriteThrough $entry.Stage $entry.Target
            } else {
                Move-VerifiedAdlTarget $entry
                try {
                    Move-AdlFileWriteThrough $entry.Stage $entry.Target
                } catch {
                    $replaceError = $_.Exception
                    if ((Test-Path -LiteralPath $entry.Backup) -and
                        -not (Test-Path -LiteralPath $entry.Target)) {
                        Move-AdlFileWriteThrough $entry.Backup $entry.Target
                    }
                    throw $replaceError
                }
            }
            Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
        }
        foreach ($entry in $Entries) {
            if ($entry.DesiredState -ceq 'Absent') {
                if (Test-Path -LiteralPath $entry.Target) {
                    throw ('ADL 目标未按事务要求移除：' + $entry.Target)
                }
            } else {
                Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
            }
        }
    } catch {
        $commitError = $_.Exception
        try {
            Rollback-AdlProjectionReceipt $Entries $ReceiptPath $ReceiptId
        } catch {
            throw ('ADL 三目标提交失败：' + $commitError.Message +
                '；回滚也失败：' + $_.Exception.Message)
        }
        throw $commitError
    } finally {
        foreach ($entry in $Entries) { Remove-TransactionFile $entry.Stage }
    }
}

function Get-CurrentGpuIdentityToken {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey('SOFTWARE\StealthGPU', $false)
        if ($null -eq $key -or -not (@($key.GetValueNames()) -ccontains 'CurrentIdentity')) {
            return ''
        }
        if ($key.GetValueKind('CurrentIdentity') -ne
            [Microsoft.Win32.RegistryValueKind]::String) {
            throw 'CurrentIdentity 注册表类型非法'
        }
        $value = [string]$key.GetValue('CurrentIdentity', $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Assert-AdlTransactionId $value
        return $value
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function New-AdlProjectionEntries {
    param([string]$PayloadRoot, [string]$SystemX86, [string]$System64,
        [ValidateSet('Present', 'Absent')][string]$ProjectionState)

    return @(
        [pscustomobject]@{
            Label='x86 atiadlxy'; FileName='atiadlxy.dll'
            Source=(Join-Path $PayloadRoot 'atiadlxy.dll')
            Directory=$SystemX86; Target=(Join-Path $SystemX86 'atiadlxy.dll')
            ExpectedHash=$ExpectedX86Hash; HistoricalHashes=$HistoricalX86Hashes
            Machine=0x014C; Magic=0x010B; State=''; ObservedHash=''
            DesiredState=$ProjectionState
            Stage=''; Backup=''; Discard=''; CommitAction=''
        },
        [pscustomobject]@{
            Label='x86 atiadlxx'; FileName='atiadlxx.dll'
            Source=(Join-Path $PayloadRoot 'atiadlxx32.dll')
            Directory=$SystemX86; Target=(Join-Path $SystemX86 'atiadlxx.dll')
            ExpectedHash=$ExpectedX86Hash; HistoricalHashes=$HistoricalX86Hashes
            Machine=0x014C; Magic=0x010B; State=''; ObservedHash=''
            DesiredState=$ProjectionState
            Stage=''; Backup=''; Discard=''; CommitAction=''
        },
        [pscustomobject]@{
            Label='x64 atiadlxx'; FileName='atiadlxx.dll'
            Source=(Join-Path $PayloadRoot 'atiadlxx.dll')
            Directory=$System64; Target=(Join-Path $System64 'atiadlxx.dll')
            ExpectedHash=$ExpectedX64Hash; HistoricalHashes=$HistoricalX64Hashes
            Machine=0x8664; Magic=0x020B; State=''; ObservedHash=''
            DesiredState=$ProjectionState
            Stage=''; Backup=''; Discard=''; CommitAction=''
        }
    )
}

if ($Action -ne 'Install' -and $DeferFinalize) {
    throw '-DeferFinalize 只允许与 -Action Install 一起使用'
}
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '发布系统 ADL 投影需要管理员权限'
}
if (-not [Environment]::Is64BitOperatingSystem -or
    -not [Environment]::Is64BitProcess) {
    throw 'ADL 发布只支持由 64 位 PowerShell 在 64 位 Windows 上运行'
}

$windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$system64 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
$systemX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::SystemX86)
if ([string]::IsNullOrWhiteSpace($windowsRoot) -or
    [string]::IsNullOrWhiteSpace($system64) -or
    [string]::IsNullOrWhiteSpace($systemX86)) {
    throw 'Windows Known Folder API 没有返回完整系统目录'
}
if ([IO.Path]::GetFullPath($system64).TrimEnd('\') -ine
        [IO.Path]::GetFullPath((Join-Path $windowsRoot 'System32')).TrimEnd('\') -or
    [IO.Path]::GetFullPath($systemX86).TrimEnd('\') -ine
        [IO.Path]::GetFullPath((Join-Path $windowsRoot 'SysWOW64')).TrimEnd('\')) {
    throw 'Known Folder 系统目录与 Windows 根目录不一致，拒绝发布'
}
Assert-PlainDirectory $windowsRoot
Assert-PlainDirectory $system64
Assert-PlainDirectory $systemX86

$needsPayload = ($Action -eq 'Install' -or $Action -eq 'Preflight') -and
    $DesiredState -ceq 'Present'
$payloadRoot = if ($needsPayload) {
    if ([string]::IsNullOrWhiteSpace($PayloadDir)) { throw ($Action + ' 缺少 -PayloadDir') }
    [IO.Path]::GetFullPath($PayloadDir)
} else { $PSScriptRoot }
if ($needsPayload) {
    Assert-PlainDirectory $payloadRoot
}
$entries = @(New-AdlProjectionEntries $payloadRoot $systemX86 $system64 $DesiredState)

if ($Action -eq 'Preflight') {
    # 只读路径：不创建 ProgramData 目录、lock、receipt 或 staging 文件。
    foreach ($entry in $entries) {
        if ($entry.DesiredState -ceq 'Present') {
            Assert-AdlBinary $entry.Source $entry.ExpectedHash $entry.Machine $entry.Magic
        }
        $snapshot = Get-AdlProjectionSnapshot $entry
        Write-Host ('ADL preflight {0} -> {1}: {2}' -f
            $entry.Label, $entry.DesiredState, $snapshot.State)
    }
    Write-Host ('ADL 三目标只读预检通过，期望状态：' + $DesiredState) `
        -ForegroundColor Green
    return
}

$programData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($programData)) { throw 'Known Folder ProgramData 为空' }
Assert-PlainDirectory $programData
$stealthDataRoot = Join-Path $programData 'StealthGPU'
Initialize-PlainDirectory $stealthDataRoot
$receiptRoot = Join-Path $stealthDataRoot 'AdlTransactions'
Initialize-PlainDirectory $receiptRoot
$lockPath = Join-Path $receiptRoot '.projection.lock'
try {
    $projectionLock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
    throw ('另一个 ADL 系统投影事务正在运行：' + $_.Exception.Message)
}

try {
    if ($Action -eq 'Recover' -or $Action -eq 'Install') {
        Resolve-PendingAdlReceipts $entries $receiptRoot (Get-CurrentGpuIdentityToken)
        if ($Action -eq 'Recover') {
            Write-Host 'ADL durable journal recovery completed.' -ForegroundColor Green
            return
        }
        $entries = @(New-AdlProjectionEntries $payloadRoot $systemX86 $system64 $DesiredState)
    }
    if ($Action -eq 'Install') {
        if ($DesiredState -ceq 'Present') {
            foreach ($entry in $entries) {
                Assert-AdlBinary $entry.Source $entry.ExpectedHash $entry.Machine $entry.Magic
            }
        }
        if ([string]::IsNullOrWhiteSpace($TransactionId)) {
            if ($DeferFinalize) { throw 'deferred ADL Install 必须复用 identity TransactionId' }
            $TransactionId = [Guid]::NewGuid().ToString('N').ToUpperInvariant()
        }
        Assert-AdlTransactionId $TransactionId
        $receiptPath = Join-Path $receiptRoot ($TransactionId + '.json')
        Publish-AdlProjection $entries $receiptPath $TransactionId
        if ($DeferFinalize) {
            Write-Host ('ADL 三目标发布已准备，等待 identity Finalize：' +
                $TransactionId) -ForegroundColor Green
            return
        }
        Finalize-AdlProjectionReceipt $entries $receiptPath $TransactionId
    } else {
        Assert-AdlTransactionId $TransactionId
        $receiptPath = Join-Path $receiptRoot ($TransactionId + '.json')
        if (Test-Path -LiteralPath $receiptPath) {
            if ($Action -eq 'Finalize') {
                Finalize-AdlProjectionReceipt $entries $receiptPath $TransactionId
            } else {
                Rollback-AdlProjectionReceipt $entries $receiptPath $TransactionId
            }
        } elseif ($Action -eq 'Finalize') {
            foreach ($entry in $entries) {
                if ($entry.DesiredState -ceq 'Present') {
                    Assert-AdlBinary $entry.Target $entry.ExpectedHash $entry.Machine $entry.Magic
                } elseif (Test-Path -LiteralPath $entry.Target) {
                    # 只拒绝并保留重新出现的 DLL，不扩大事务的删除权限。
                    throw ('ADL 目标应为 Absent：' + $entry.Target)
                }
            }
        } else {
            # receipt 是任何系统 Move 的先决条件；不存在即表示从未写入或已经回滚完成。
            Write-Host ('ADL rollback 收据已不存在，按无写入幂等收口：' +
                $TransactionId) -ForegroundColor Yellow
        }
    }

    if ($Action -eq 'Rollback') {
        Write-Host ('ADL 三目标 rollback 已收口：' + $TransactionId) `
            -ForegroundColor Green
    } else {
        if ($DesiredState -ceq 'Absent') {
            foreach ($entry in $entries) {
                Write-Host ('系统 ADL {0} 已移除：{1}' -f
                    $entry.Label, $entry.Target) -ForegroundColor Green
            }
        } else {
            foreach ($entry in $entries) {
                Write-Host ('系统 ADL {0} 已就绪：{1}  SHA-256={2}' -f
                    $entry.Label, $entry.Target, $entry.ExpectedHash) -ForegroundColor Green
            }
        }
    }
} finally {
    $projectionLock.Dispose()
}
