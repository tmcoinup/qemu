#Requires -Version 5.1

<#
.SYNOPSIS
    为 Windows 硬件 profile 提供跨进程锁、唯一性检查和原子提交。

.DESCRIPTION
    本模块只处理持久化，不生成硬件身份。调用方必须先在内存中完成全部 QEMU
    参数校验，再提交 profile；命名 Mutex 让同一实例的并发启动串行化，避免
    两个进程分别使用不同身份启动、磁盘最终却只保留其中一个身份。
#>

function Get-VMateProfileFileDigest {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-VMateProfileObjectDigest {
    param([object]$Profile)

    $json = $Profile | ConvertTo-Json -Depth 64 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $digest = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-VMateProfileMutexName {
    param([int]$Instance)

    if ($Instance -lt 1 -or $Instance -gt 1000) {
        throw "实例号超出提交锁范围：$Instance"
    }
    # Global 命名空间可覆盖同一用户的多个 Windows 登录会话；Mutex 不像全局
    # file mapping 那样要求 SeCreateGlobalPrivilege，适合无管理员权限启动器。
    # 锁键必须是全局端口所使用的 Instance，而不能是可由调用方另传的 profile
    # 路径；否则同一 QMP/转发端口可借两条 profile 路径取得两把不同的锁。
    return 'Global\VMate.Instance.' + $Instance.ToString('D4')
}

function Enter-VMateProfileCommitLock {
    param(
        [int]$Instance,
        [int]$TimeoutMilliseconds = 30000
    )

    $name = Get-VMateProfileMutexName -Instance $Instance
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [System.Threading.AbandonedMutexException] {
            # 前一进程异常退出时 CLR 已把所有权转交给当前线程，可安全继续校验。
            $acquired = $true
        }
        if (-not $acquired) {
            throw "等待 VM 实例 $Instance 的生命周期锁超时。"
        }
        return [pscustomobject]@{
            Mutex = $mutex
            Acquired = $true
            Name = $name
            Instance = $Instance
        }
    } catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-VMateProfileCommitLock {
    param([object]$Lock)

    if ($null -eq $Lock -or $Lock.Acquired -ne $true) {
        throw '不能释放未持有的 profile 提交锁。'
    }
    try {
        $Lock.Mutex.ReleaseMutex()
    } finally {
        $Lock.Acquired = $false
        $Lock.Mutex.Dispose()
    }
}

function Test-VMateProfileIdentityUnique {
    param(
        [object]$Profile,
        [string]$Path
    )

    $vmDirectory = Split-Path -Parent $Path
    $registryRoot = Split-Path -Parent $vmDirectory
    if (-not $registryRoot -or -not (Test-Path -LiteralPath $registryRoot)) {
        return $true
    }
    $currentPath = [System.IO.Path]::GetFullPath($Path)
    # 默认布局是 vms/<instance>/hardware-profile.json。只检查一层实例目录，
    # 防止递归进入用户目录里的 junction 或受保护目录。
    $candidatePaths = @(Get-ChildItem -LiteralPath $registryRoot -Directory `
        -ErrorAction Stop | ForEach-Object {
            Join-Path $_.FullName 'hardware-profile.json'
        } | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue
        })
    # 旧 schema 可能没有 monitor_serial；空值不能彼此构成伪冲突，现代 profile
    # 的必填性和品牌格式仍由 Assert-VMateHardwareProfile 单独 fail closed。
    $monitorSerial = [string]$Profile.identity.monitor_serial
    foreach ($candidatePath in $candidatePaths) {
        if ([System.IO.Path]::GetFullPath($candidatePath) -eq $currentPath) {
            continue
        }
        try {
            $other = Get-Content -LiteralPath $candidatePath -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "无法验证相邻 profile 唯一性：$candidatePath；$($_.Exception.Message)"
        }
        if ($null -eq $other.identity) {
            continue
        }
        if ([string]$other.identity.uuid -eq [string]$Profile.identity.uuid -or
            [string]$other.identity.mac -eq [string]$Profile.identity.mac -or
            [string]$other.identity.nvme_serial -eq
                [string]$Profile.identity.nvme_serial -or
            ($monitorSerial.Length -gt 0 -and
             [string]$other.identity.monitor_serial -eq $monitorSerial)) {
            return $false
        }
    }
    return $true
}

function Commit-VMateHardwareProfile {
    param(
        [object]$Selection,
        [string]$Path,
        [object]$Lock
    )

    if ($null -eq $Lock -or $Lock.Acquired -ne $true) {
        throw '提交 profile 前必须持有同实例提交锁。'
    }
    foreach ($field in @('SourceExisted', 'SourceDigest', 'PreparedDigest',
            'RequiresCommit', 'Reroll', 'Profile')) {
        if (-not (Test-VMateJsonProperty $Selection $field)) {
            throw "待提交 profile 缺少事务字段 '$field'。"
        }
    }
    foreach ($field in @('SourceExisted', 'RequiresCommit', 'Reroll')) {
        if ($Selection.$field -isnot [bool]) {
            throw "待提交 profile 的事务字段 '$field' 不是布尔值。"
        }
    }
    if (-not (Test-VMateIntegerValue $Selection.Profile.instance) -or
        [int]$Selection.Profile.instance -ne [int]$Lock.Instance) {
        throw 'profile 实例号与当前生命周期锁不一致。'
    }
    if ([string]$Selection.PreparedDigest -ne
        (Get-VMateProfileObjectDigest -Profile $Selection.Profile)) {
        throw 'profile 在参数验证后被内存代码修改，拒绝提交或启动。'
    }

    $currentExists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($currentExists -ne $Selection.SourceExisted) {
        throw 'profile 在准备与提交之间被另一进程创建或删除，拒绝覆盖。'
    }
    if ($currentExists -and [string]$Selection.SourceDigest -ne
        (Get-VMateProfileFileDigest -Path $Path)) {
        throw 'profile 在准备与提交之间发生变化，拒绝覆盖。'
    }
    if (-not $Selection.RequiresCommit) {
        return [pscustomobject]@{ Committed = $false; BackupPath = '' }
    }

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory `
        ('.profile-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Selection.Profile | ConvertTo-Json -Depth 64
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText(
            $temporary, $json + [Environment]::NewLine, $utf8)
        $backup = ''
        if ($Selection.SourceExisted) {
            if (-not $Selection.Reroll) {
                throw '只有显式 reroll 才能替换已有 profile。'
            }
            $backup = $Path + '.' +
                [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff') + '.' +
                [Guid]::NewGuid().ToString('N') + '.bak'
            # File.Replace 在同一文件系统内原子地完成替换和备份，不会出现先备份、
            # 后验证失败的半事务；GUID 让同一毫秒的并发/连续 reroll 也不撞名。
            [System.IO.File]::Replace($temporary, $Path, $backup)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
        return [pscustomobject]@{
            Committed = $true
            BackupPath = $backup
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}
