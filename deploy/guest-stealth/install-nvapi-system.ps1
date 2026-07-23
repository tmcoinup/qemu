#Requires -Version 5.1

# 在 Windows 双架构系统目录中发布或移除 VMate NVIDIA NVAPI 投影。
# Present 发布 SysWOW64\nvapi.dll 与 System32\nvapi64.dll；Absent 只移除摘要
# 明确属于 VMate 的投影。真实 NVIDIA 驱动和未知同名 DLL 始终 fail-closed；
# 两个架构共享 durable receipt，任一步失败都恢复到事务前状态。

[CmdletBinding()]
param(
    # 独立运行保持历史接口：只传 -PayloadDir 时安装器会在同一进程内完成发布和清理。
    # 正式 apply 链额外传 DeferFinalize/TransactionId，待 identity Complete 后再清理备份。
    [string]$PayloadDir = '',
    [ValidateSet('Preflight', 'Install', 'Recover', 'Finalize', 'Rollback')]
    [string]$Action = 'Install',
    [ValidateSet('Present', 'Absent')][string]$DesiredState = 'Present',
    [string]$TransactionId = '',
    [switch]$DeferFinalize
)

$ErrorActionPreference = 'Stop'
$DesiredState = if ($DesiredState -ieq 'Absent') { 'Absent' } else { 'Present' }

# 文件、摘要与 PE 校验独立成 helper；正式 EXE 与 legacy 包都会和安装器一起释放。
$validationHelper = Join-Path $PSScriptRoot 'nvapi-system-validation.ps1'
if (-not (Test-Path -LiteralPath $validationHelper -PathType Leaf)) {
    throw ('缺少 NVAPI validation helper：' + $validationHelper)
}
. $validationHelper

$ExpectedX86Hash = '3fe8586ccd9737b5f35f9688af394a117cff2c8e206b6168260d77d9102e7347'
$ExpectedX64Hash = '16ae2b832a3795244c24745ae577aca3697090278b3a91a0e91875884422e6d7'

# 这些值只用于识别仓库历史发布物，不能作为任意第三方 DLL 的放行白名单。
# fa7412... 是早期独立 x64 浅层 shim；其余值覆盖 Git 历史发布版本。
# 它们都可安全替换为当前不依赖真实 NVIDIA 运行时的独立实现。
$HistoricalX86Hashes = @(
    '3405928e9d8fbcc36dc4bb97627b804893bb8f48b16ee8a662ea79346c40b601', 'd2fa115d4ece2da0361106113f0289a5499c6e78d491567bf466b60a3a010f14',
    'a5de31d15ff0f4038ef1b54a75fbac0ab472797d3424e1468f9e6d047cc58139', '79b05e4707fa3b4882279995898ea99e74f584e31d10f9733c24714eb79ea80d',
    '63ecadd497f955a599e8a12ea7f45fd92915a47570be473d166ddbb3d462c13e', '0601d245ca7101b92299e4c2215480fa680554ee400d1a064782319747612ca0',
    '76dffd3513ca90d994c3800c725a6d4f6b5a95bef36f44fd122f123861fd522c', '5ad43a193ccf0c3dacc769f4267d394502708fc1a5191d9b1338ba8485ea9c94',
    '1638720952a6187773372f29837c3bb26804eaeaf00938a8c2f42996bc4dd972',
    'f2207b5e17f1ba31af1b85ed58c5ffc920831b9f66cee8a6a013d55eec693bb9'
)
$HistoricalX64Hashes = @(
    'bc3fce02e8c223e335cb893c7d72db2c43dfa8a378677674854b0a52bf33de2a', 'c0e39803f8484d9dc23559576762564bc84b44fb3c90c7562829e8c96f15a83d',
    '207e41c9eaa7641d3e2af32e99a5f874a87978b310676db325d572f8b954dd72', '8b32d767e69526c535cce361a9d5853fc6f21f7f348600fabfefe7f46db708cc',
    '585ef928f54548ed2ac9eae1dfcdd5b12e4fd8a9ab5f7d94257ca01df68cdf81', 'fa7412b4a96d053e73261a0d43b3286a82c04a4da825bc0c5ec012b628bc590e',
    '6ddae65be9ddaf232064b5e12933b40bbf0f366b52a3b447abf4a15c254d6103', 'f10d14acf39d10c66c38188214c0dc6a4a9dcf66d2993fd82257db7492c7258e',
    '6a46de86e767c08f215cd9526ef5527e536a244eddd78cc7a14fc45cc4f95792', '5a9181a21280eb692651cd6d6530b27124f50fcbb70e2c768427af4dbe6440ff',
    '311b95768f8bbd18fb30f0e1144c9f2c50cc4f8433b870768c4a439f57844f56',
    '1d39f3dada172f62b62f801de434ceda3060caf3b0887381d0b853771f3b97cf',
    '529b06e18e08cf3821778bdce7f485aadeabbafd955374991c8d84cca7bc57be'
)

function Get-SystemProjectionEntryState {
    # 该纯函数只根据目标内容分类，不做写入；测试可用临时目录覆盖所有分支。
    param([Parameter(Mandatory = $true)]$Entry)

    return (Get-SystemProjectionEntrySnapshot -Entry $Entry).State
}

function Get-SystemProjectionEntrySnapshot {
    # 预检不仅记录分类，还记录当时的精确摘要。真正提交时会先把“路径当前指向的
    # 那个文件”原子改名到唯一事务路径，再对被移动的实体重算摘要；只有与该快照
    # 完全相同才发布。这样真实 NVIDIA 安装器即使在两步之间换文件，也不会被覆盖。
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not (Test-Path -LiteralPath $Entry.Target)) {
        return [pscustomobject]@{ State = 'Absent'; Hash = '' }
    }
    $null = Assert-PlainFile -Path $Entry.Target
    $hash = Get-LowerSha256 -Path $Entry.Target
    if ($hash -ceq $Entry.ExpectedHash) {
        return [pscustomobject]@{ State = 'Current'; Hash = $hash }
    }
    if (Test-HashInAllowList -Hash $hash -AllowedHashes $Entry.HistoricalHashes) {
        return [pscustomobject]@{ State = 'ManagedHistorical'; Hash = $hash }
    }
    throw ('拒绝覆盖未知 NVAPI DLL（也不会移除）：' + $Entry.Target +
        '，SHA-256=' + $hash)
}

function Remove-TransactionFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) { return }
    $null = Assert-PlainFile -Path $Path
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Move-VerifiedHistoricalTarget {
    # Move 取得的是路径在该原子操作瞬间指向的实体；后续摘要因此不会再受同一路径
    # 被换名影响。若与预检快照不符，只在目标仍为空时把原实体放回，随后 fail-closed。
    param([Parameter(Mandatory = $true)]$Entry)

    Move-NvapiFileWriteThrough $Entry.Target $Entry.Backup
    try {
        $null = Assert-PlainFile -Path $Entry.Backup
        $movedHash = Get-LowerSha256 -Path $Entry.Backup
        if ($movedHash -cne $Entry.ObservedHash) {
            throw ('NVAPI 目标在预检后发生变化：' + $Entry.Target)
        }
    } catch {
        $moveError = $_.Exception
        if ((Test-Path -LiteralPath $Entry.Backup) -and
            -not (Test-Path -LiteralPath $Entry.Target)) {
            Move-NvapiFileWriteThrough $Entry.Backup $Entry.Target
        }
        throw $moveError
    }
}

# durable receipt/state-machine 独立成文件，避免安装器超过 500 行并让纯文件故障
# 注入测试可以只加载事务层。正式单文件 EXE 会把该 helper 与 installer 同时释放。
$transactionHelper = Join-Path $PSScriptRoot 'nvapi-system-transaction.ps1'
if (-not (Test-Path -LiteralPath $transactionHelper -PathType Leaf)) {
    throw ('缺少 NVAPI durable transaction helper：' + $transactionHelper)
}
. $transactionHelper

function Publish-SystemProjectionEntries {
    # 两个架构先在各自系统目录 staging；只有全部副本再次通过摘要/PE 校验后才提交。
    # 所有 File.Move 都发生在同一卷同一目录，避免 Copy-Item 直接截断活动目标。
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [string]$ReceiptPath = '',
        [string]$TransactionId = ''
    )

    # 第一轮只读完两个目标的状态，保证第二架构若是未知厂商文件，第一架构目录中
    # 连 stage 都不会出现。预检结束后才进入带 finally 清理的 staging 阶段。
    foreach ($entry in $Entries) {
        if (-not ($entry.PSObject.Properties.Name -contains 'DesiredState')) {
            $entry | Add-Member -NotePropertyName DesiredState -NotePropertyValue 'Present'
        } elseif ([string]::IsNullOrWhiteSpace([string]$entry.DesiredState)) {
            $entry.DesiredState = 'Present'
        }
        $snapshot = Get-SystemProjectionEntrySnapshot -Entry $entry
        $entry.State = $snapshot.State
        $entry.ObservedHash = $snapshot.Hash
        if ($entry.DesiredState -ceq 'Absent') {
            if ($entry.State -eq 'Absent') {
                $entry.CommitAction = 'UnchangedAbsent'
                continue
            }
            $entry.CommitAction = 'Removed'
            $entry.Backup = Join-Path $entry.Directory `
                ('.' + $entry.FileName + '.vmate-backup-' + [Guid]::NewGuid().ToString('N'))
            continue
        }
        if ($entry.State -eq 'Current') { continue }
        $entry.Stage = Join-Path $entry.Directory `
            ('.' + $entry.FileName + '.vmate-stage-' + [Guid]::NewGuid().ToString('N'))
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
    $hasJournal = -not [string]::IsNullOrWhiteSpace($ReceiptPath)
    if ($hasJournal -ne (-not [string]::IsNullOrWhiteSpace($TransactionId))) {
        throw 'ReceiptPath 与 TransactionId 必须同时提供'
    }
    # 关键 durable 边界：planned action、旧摘要及三个确定路径必须先落盘；此行
    # 成功之前不允许 Copy/Move 任一系统目录文件。
    if ($hasJournal) { Write-NvapiProjectionReceipt $Entries $ReceiptPath $TransactionId }
    $committed = New-Object Collections.Generic.List[object]
    try {
        foreach ($entry in $Entries) {
            if ($entry.DesiredState -ceq 'Absent' -or $entry.State -eq 'Current') {
                continue
            }
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Stage -ErrorAction Stop
            Assert-NvapiBinary -Path $entry.Stage -ExpectedHash $entry.ExpectedHash `
                -ExpectedMachine $entry.Machine -ExpectedMagic $entry.Magic
            Sync-NvapiFileData -Path $entry.Stage
        }

        foreach ($entry in $Entries) {
            if ($entry.CommitAction -ceq 'UnchangedAbsent' -or
                ($entry.DesiredState -ceq 'Present' -and $entry.State -eq 'Current')) {
                continue
            }
            if ($entry.CommitAction -ceq 'Removed') {
                $committed.Add($entry)
                Move-VerifiedHistoricalTarget -Entry $entry
                continue
            }
            if ($entry.State -eq 'Absent') {
                # Move 在目标已由第三方创建时原子失败，不存在“先检查 absent 再覆盖”的窗口。
                Move-NvapiFileWriteThrough $entry.Stage $entry.Target
            } else {
                # 先把路径此刻指向的实体原子移走，再核对“被移走的实体”与预检摘要。
                # File.Replace 无条件替换路径，会留下 hash-check/replace 的 TOCTOU 窗口，
                # 因此这里有意使用两个同目录 Move，并让中间出现第三方目标时安全失败。
                Move-VerifiedHistoricalTarget -Entry $entry
                try {
                    Move-NvapiFileWriteThrough $entry.Stage $entry.Target
                } catch {
                    $replaceError = $_.Exception
                    if ((Test-Path -LiteralPath $entry.Backup) -and
                        -not (Test-Path -LiteralPath $entry.Target)) {
                        Move-NvapiFileWriteThrough $entry.Backup $entry.Target
                    }
                    throw $replaceError
                }
            }
            $committed.Add($entry)
            Assert-NvapiBinary -Path $entry.Target -ExpectedHash $entry.ExpectedHash `
                -ExpectedMachine $entry.Machine -ExpectedMagic $entry.Magic
        }

        foreach ($entry in $Entries) {
            if ([string]$entry.DesiredState -ceq 'Absent') {
                if (Test-Path -LiteralPath $entry.Target) {
                    throw ('NVAPI 目标应不存在：' + $entry.Target)
                }
            } else {
                Assert-NvapiBinary -Path $entry.Target -ExpectedHash $entry.ExpectedHash `
                    -ExpectedMachine $entry.Machine -ExpectedMagic $entry.Magic
            }
        }
    } catch {
        $commitError = $_.Exception
        $rollbackErrors = New-Object Collections.Generic.List[string]
        if ($hasJournal) {
            try {
                Rollback-NvapiProjectionReceipt $Entries $ReceiptPath $TransactionId
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        } else {
            for ($index = $committed.Count - 1; $index -ge 0; $index--) {
                try { Undo-NvapiProjectionEntry $committed[$index] } catch {
                    $rollbackErrors.Add($_.Exception.Message)
                }
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw ('NVAPI 双架构提交失败：' + $commitError.Message +
                '；回滚也失败：' + ($rollbackErrors -join ' | '))
        }
        throw $commitError
    } finally {
        foreach ($entry in $Entries) {
            Remove-TransactionFile -Path $entry.Stage
        }
    }

    if (-not $hasJournal) {
        foreach ($entry in $Entries) { Remove-TransactionFile -Path $entry.Backup }
    }
}

function Assert-SystemProjectionDesiredState {
    param([Parameter(Mandatory = $true)]$Entry)

    if ($Entry.DesiredState -ceq 'Absent') {
        if (Test-Path -LiteralPath $Entry.Target) {
            throw ('NVAPI 目标应不存在：' + $Entry.Target)
        }
        return
    }
    Assert-NvapiBinary -Path $Entry.Target -ExpectedHash $Entry.ExpectedHash `
        -ExpectedMachine $Entry.Machine -ExpectedMagic $Entry.Magic
}

function Initialize-PlainDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = [IO.Directory]::CreateDirectory($Path)
    }
    Assert-PlainDirectory -Path $Path
}

function Get-CurrentGpuIdentityToken {
    # 崩溃恢复以 durable CurrentIdentity 为裁决点：指向收据事务即 Finalize，
    # 否则 Rollback。严格固定 Registry64，避免 x86 注册表重定向产生错误决策。
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
        Assert-NvapiTransactionId $value
        return $value
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function New-SystemProjectionEntries {
    param([string]$PayloadRoot, [string]$SystemX86, [string]$System64)

    return @(
        [pscustomobject]@{
            Label='x86'; FileName='nvapi.dll'; Source=(Join-Path $PayloadRoot 'nvapi.dll')
            Directory=$SystemX86; Target=(Join-Path $SystemX86 'nvapi.dll')
            ExpectedHash=$ExpectedX86Hash; HistoricalHashes=$HistoricalX86Hashes
            Machine=0x014C; Magic=0x010B; State=''; ObservedHash=''
            DesiredState=$DesiredState
            Stage=''; Backup=''; Discard=''; CommitAction=''
        },
        [pscustomobject]@{
            Label='x64'; FileName='nvapi64.dll'; Source=(Join-Path $PayloadRoot 'nvapi64.dll')
            Directory=$System64; Target=(Join-Path $System64 'nvapi64.dll')
            ExpectedHash=$ExpectedX64Hash; HistoricalHashes=$HistoricalX64Hashes
            Machine=0x8664; Magic=0x020B; State=''; ObservedHash=''
            DesiredState=$DesiredState
            Stage=''; Backup=''; Discard=''; CommitAction=''
        }
    )
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '发布系统 NVAPI 投影需要管理员权限'
}
if (-not [Environment]::Is64BitOperatingSystem -or
    -not [Environment]::Is64BitProcess) {
    throw '当前发布流程只支持由 64 位 PowerShell 在 64 位 Windows 上运行'
}

$windowsRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Windows)
$system64 = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::System)
$systemX86 = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::SystemX86)
if ([string]::IsNullOrWhiteSpace($windowsRoot) -or
    [string]::IsNullOrWhiteSpace($system64) -or
    [string]::IsNullOrWhiteSpace($systemX86)) {
    throw 'Windows Known Folder API 没有返回完整系统目录'
}
$expected64 = Join-Path $windowsRoot 'System32'
$expectedX86 = Join-Path $windowsRoot 'SysWOW64'
if ([IO.Path]::GetFullPath($system64).TrimEnd('\') -ine
        [IO.Path]::GetFullPath($expected64).TrimEnd('\') -or
    [IO.Path]::GetFullPath($systemX86).TrimEnd('\') -ine
        [IO.Path]::GetFullPath($expectedX86).TrimEnd('\')) {
    throw 'Known Folder 系统目录与 Windows 根目录不一致，拒绝发布'
}
Assert-PlainDirectory -Path $windowsRoot
Assert-PlainDirectory -Path $system64
Assert-PlainDirectory -Path $systemX86

if ($Action -ne 'Install' -and $DeferFinalize) {
    throw '-DeferFinalize 只允许与 -Action Install 一起使用'
}
if ($Action -eq 'Preflight') {
    # 协调器必须在任何系统 DLL Move 前完成两个厂商读取层的全量只读预检。
    # 此分支不会创建 ProgramData 目录、lock、receipt、stage 或 backup。
    $preflightPayloadRoot = if ($DesiredState -ceq 'Present') {
        if ([string]::IsNullOrWhiteSpace($PayloadDir)) {
            throw 'Present Preflight 缺少 -PayloadDir'
        }
        [IO.Path]::GetFullPath($PayloadDir)
    } else { $PSScriptRoot }
    if ($DesiredState -ceq 'Present') {
        Assert-PlainDirectory -Path $preflightPayloadRoot
    }
    $preflightEntries = @(New-SystemProjectionEntries `
        $preflightPayloadRoot $systemX86 $system64)
    foreach ($entry in $preflightEntries) {
        if ($DesiredState -ceq 'Present') {
            Assert-NvapiBinary $entry.Source $entry.ExpectedHash $entry.Machine $entry.Magic
        }
        $snapshot = Get-SystemProjectionEntrySnapshot $entry
        Write-Host ('NVAPI preflight {0}: {1} -> {2}' -f
            $entry.Label, $snapshot.State, $DesiredState)
    }
    Write-Host 'NVAPI 双架构只读预检通过。' -ForegroundColor Green
    return
}

$programData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($programData)) { throw 'Known Folder ProgramData 为空' }
Assert-PlainDirectory -Path $programData
$stealthDataRoot = Join-Path $programData 'StealthGPU'
Initialize-PlainDirectory $stealthDataRoot
$receiptRoot = Join-Path $stealthDataRoot 'NvapiTransactions'
Initialize-PlainDirectory $receiptRoot

$lockPath = Join-Path $receiptRoot '.projection.lock'
try {
    # 同一固定普通文件以 FileShare.None 串行化 standalone/apply/recovery，堵住两个
    # installer 在相同系统 DLL 上各自预检旧摘要后交叉 Move 的并发窗口。
    $projectionLock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch { throw ('另一个 NVAPI 系统投影事务正在运行：' + $_.Exception.Message) }
try {
$payloadRoot = if ($Action -eq 'Install' -and $DesiredState -ceq 'Present') {
    if ([string]::IsNullOrWhiteSpace($PayloadDir)) { throw 'Present Install 缺少 -PayloadDir' }
    [IO.Path]::GetFullPath($PayloadDir)
} else { $PSScriptRoot }
if ($Action -eq 'Install' -and $DesiredState -ceq 'Present') {
    Assert-PlainDirectory -Path $payloadRoot
}
$entries = @(New-SystemProjectionEntries $payloadRoot $systemX86 $system64)

if ($Action -eq 'Recover' -or $Action -eq 'Install') {
    # apply 会先恢复 identity durable journal，再调用本恢复动作；CurrentIdentity 因而
    # 是最终裁决：仍指向 receipt ID 就提交清理，否则恢复两个旧 DLL。
    Resolve-PendingNvapiReceipts $entries $receiptRoot (Get-CurrentGpuIdentityToken)
    if ($Action -eq 'Recover') {
        Write-Host 'NVAPI durable journal recovery completed.' -ForegroundColor Green
        return
    }
    # Recover 可能按历史收据改写 entry.ExpectedHash；新安装必须重建当前版本常量。
    $entries = @(New-SystemProjectionEntries $payloadRoot $systemX86 $system64)
}

if ($Action -eq 'Install') {
    if ($DesiredState -ceq 'Present') {
        foreach ($entry in $entries) {
            Assert-NvapiBinary $entry.Source $entry.ExpectedHash $entry.Machine $entry.Magic
        }
    }
    if ([string]::IsNullOrWhiteSpace($TransactionId)) {
        if ($DeferFinalize) { throw 'deferred Install 必须复用 identity TransactionId' }
        $TransactionId = [Guid]::NewGuid().ToString('N').ToUpperInvariant()
    }
    Assert-NvapiTransactionId $TransactionId
    $receiptPath = Join-Path $receiptRoot ($TransactionId + '.json')
    Publish-SystemProjectionEntries $entries $receiptPath $TransactionId
    if ($DeferFinalize) {
        Write-Host ('NVAPI 双架构发布已准备，等待 identity Finalize：' + $TransactionId) `
            -ForegroundColor Green
        return
    }
    Finalize-NvapiProjectionReceipt $entries $receiptPath $TransactionId
} else {
    Assert-NvapiTransactionId $TransactionId
    $receiptPath = Join-Path $receiptRoot ($TransactionId + '.json')
    # Finalize/Rollback 在删除收据后被 kill 时允许幂等重试；不存在即代表上次已收口。
    if (Test-Path -LiteralPath $receiptPath) {
        if ($Action -eq 'Finalize') {
            Finalize-NvapiProjectionReceipt $entries $receiptPath $TransactionId
        } else {
            Rollback-NvapiProjectionReceipt $entries $receiptPath $TransactionId
        }
    } elseif ($Action -eq 'Finalize') {
        foreach ($entry in $entries) { Assert-SystemProjectionDesiredState $entry }
    } else {
        # receipt 在第一个 Move 前落盘；不存在即证明本组件从未写入，或上次已回滚完成。
        Write-Host ('NVAPI rollback 收据已不存在，按无写入幂等收口：' + $TransactionId) `
            -ForegroundColor Yellow
    }
}

if ($Action -eq 'Rollback') {
    Write-Host ('NVAPI 双架构 rollback 已收口：' + $TransactionId) -ForegroundColor Green
} else {
    foreach ($entry in $entries) {
        if ($DesiredState -ceq 'Present') {
            Write-Host ('系统 NVAPI {0} 已就绪：{1}  SHA-256={2}' -f
                $entry.Label, $entry.Target, $entry.ExpectedHash) -ForegroundColor Green
        } else {
            Write-Host ('系统 NVAPI {0} 已移除：{1}' -f $entry.Label, $entry.Target) `
                -ForegroundColor Green
        }
    }
    Write-Host ('系统 NVIDIA NVAPI 目标状态：' + $DesiredState) -ForegroundColor Green
}
} finally { $projectionLock.Dispose() }
