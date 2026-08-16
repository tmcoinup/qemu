#requires -Version 5.1
<#
.SYNOPSIS
    为 Windows guest 快照采集器提供只读的进程、模块和驱动文件证据。
.NOTES
    本文件只读取 CIM、进程模块、签名、哈希和 SetupAPI 日志；不采集进程内存内容，
    不停止进程，也不安装、卸载或修改驱动。
#>

$fileEvidenceModule = Join-Path $PSScriptRoot 'VMate.FileEvidence.ps1'
if (-not (Test-Path -LiteralPath $fileEvidenceModule -PathType Leaf)) {
    throw "缺少文件证据模块: $fileEvidenceModule"
}
. $fileEvidenceModule

function Test-VMateLiveProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$CimProcess)

    $result = [ordered]@{ validated = $false; process = $null; error = $null }
    try {
        $live = Get-Process -Id ([uint32]$CimProcess.ProcessId) -ErrorAction Stop
        $expectedBaseName = [IO.Path]::GetFileNameWithoutExtension(
            [string]$CimProcess.Name)
        if ($live.ProcessName -ine $expectedBaseName) {
            throw "PID 已复用: CIM=$expectedBaseName live=$($live.ProcessName)"
        }
        if ($null -eq $CimProcess.CreationDate) {
            throw 'CIM 未返回 CreationDate，无法排除 PID 复用'
        }
        $created = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
        $delta = [Math]::Abs(
            ($live.StartTime.ToUniversalTime() - $created).TotalSeconds)
        if ($delta -gt 3) {
            throw "PID 启动时间不匹配: delta=${delta}s"
        }
        $result.validated = $true
        $result.process = $live
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Test-VMateParentTimeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$ParentProcess,
        [Parameter(Mandatory)] [object]$ChildProcess
    )

    if ($null -eq $ParentProcess.CreationDate -or
        $null -eq $ChildProcess.CreationDate) {
        return $false
    }
    try {
        return ([DateTime]$ParentProcess.CreationDate -le
            [DateTime]$ChildProcess.CreationDate)
    } catch {
        return $false
    }
}

function Get-VMateProcessEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]]$RequestedNames)

    $targets = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($requested in $RequestedNames) {
        if ([string]::IsNullOrWhiteSpace($requested)) { continue }
        $leaf = [IO.Path]::GetFileName($requested.Trim().Trim('"'))
        if ([string]::IsNullOrWhiteSpace([IO.Path]::GetExtension($leaf))) {
            $leaf = "$leaf.exe"
        }
        [void]$targets.Add($leaf)
    }

    $errors = [Collections.Generic.List[string]]::new()
    if ($targets.Count -eq 0) {
        $errors.Add('没有有效的进程映像名')
    }
    if ([Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess) {
        $errors.Add('采集器运行在 32 位 PowerShell；64 位进程的模块列表可能不完整')
    }

    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $byPid = @{}
    $selectedPids = [Collections.Generic.HashSet[uint32]]::new()
    foreach ($candidate in $allProcesses) {
        $byPid[[uint32]$candidate.ProcessId] = $candidate
        if ($targets.Contains([string]$candidate.Name)) {
            [void]$selectedPids.Add([uint32]$candidate.ProcessId)
        }
    }
    $targetCount = $selectedPids.Count
    do {
        $addedDescendant = $false
        foreach ($candidate in $allProcesses) {
            $candidateParent = $byPid[[uint32]$candidate.ParentProcessId]
            $timelineValid = $false
            if ($null -ne $candidateParent) {
                $timelineValid = Test-VMateParentTimeline -ParentProcess $candidateParent -ChildProcess $candidate
            }
            if ($null -ne $candidateParent -and $timelineValid -and
                $selectedPids.Contains([uint32]$candidate.ParentProcessId) -and
                $selectedPids.Add([uint32]$candidate.ProcessId)) {
                $addedDescendant = $true
            }
        }
    } while ($addedDescendant)
    if ($targetCount -eq 0) {
        $errors.Add("未找到请求的进程: $(@($targets) -join ', ')")
    }

    $selectedProcesses = @($allProcesses | Where-Object {
            $selectedPids.Contains([uint32]$_.ProcessId)
        } | Sort-Object CreationDate, ProcessId)
    $processSnapshot = @($selectedProcesses | ForEach-Object {
            $parent = $byPid[[uint32]$_.ParentProcessId]
            [pscustomobject][ordered]@{
                requested_match = $targets.Contains([string]$_.Name)
                name = $_.Name
                process_id = [uint32]$_.ProcessId
                parent_process_id = [uint32]$_.ParentProcessId
                parent_name = if ($null -ne $parent) { $parent.Name } else { $null }
                parent_relation_timeline_valid = if ($null -ne $parent) {
                    Test-VMateParentTimeline -ParentProcess $parent -ChildProcess $_
                } else { $null }
                executable_path = $_.ExecutablePath
                command_line = $_.CommandLine
                creation_date = $_.CreationDate
            }
        })
    # 先流式返回轻量快照；即使后续模块签名或哈希超时，PID/命令行证据仍会保留。
    [pscustomobject][ordered]@{
        record_type = 'metadata'
        requested = @($targets)
        target_found = $targetCount
        process_tree_count = $selectedProcesses.Count
        collector_is_64bit_process = [Environment]::Is64BitProcess
        loader_enumeration_only = $true
        contains_sensitive_data = $true
        process_snapshot = $processSnapshot
        collection_errors = @($errors)
    }

    $fileCache = @{}
    foreach ($process in $selectedProcesses) {
        $recordErrors = [Collections.Generic.List[string]]::new()
        $isRequested = $targets.Contains([string]$process.Name)
        $identity = Test-VMateLiveProcessIdentity -CimProcess $process
        $liveProcess = if ($identity.validated) { $identity.process } else { $null }
        if (-not $identity.validated) {
            $message = "PID $($process.ProcessId) 运行态核对失败: $($identity.error)"
            $recordErrors.Add($message)
        }

        $parent = $byPid[[uint32]$process.ParentProcessId]
        $parentInstanceLive = $null
        $parentTimelineValid = $null
        $parentValidationError = $null
        if ($null -ne $parent) {
            $parentIdentity = Test-VMateLiveProcessIdentity -CimProcess $parent
            $parentInstanceLive = $parentIdentity.validated
            $parentTimelineValid = Test-VMateParentTimeline -ParentProcess $parent -ChildProcess $process
            $parentValidationError = $parentIdentity.error
        }
        if ($isRequested) {
            if ($null -eq $parent) {
                $recordErrors.Add('目标进程的父进程实例不在 CIM 快照中')
            } elseif (-not $parentInstanceLive -or -not $parentTimelineValid) {
                $recordErrors.Add('目标进程的父进程实例或 PPID 时间线无法验证')
            }
        }

        $executablePath = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($executablePath) -and $null -ne $liveProcess) {
            try { $executablePath = $liveProcess.Path } catch { }
        }
        if ($isRequested -and [string]::IsNullOrWhiteSpace($executablePath)) {
            $recordErrors.Add('目标进程缺少可验证的映像路径')
        }
        if ($isRequested -and
            [string]::IsNullOrWhiteSpace([string]$process.CommandLine)) {
            $recordErrors.Add('目标进程缺少命令行；请使用管理员权限重新采集')
        }
        $executable = $null
        if (-not [string]::IsNullOrWhiteSpace($executablePath)) {
            $cacheKey = $executablePath.ToUpperInvariant()
            if (-not $fileCache.ContainsKey($cacheKey)) {
                $fileCache[$cacheKey] = Get-VMateFileEvidence -LiteralPath $executablePath
            }
            $executable = $fileCache[$cacheKey]
            foreach ($fileError in @($executable.collection_errors)) {
                $message = "$executablePath`: $fileError"
                $recordErrors.Add($message)
            }
        }

        $modules = @()
        if ($null -ne $liveProcess) {
            try {
                $modulePaths = @($liveProcess.Modules | ForEach-Object FileName |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Sort-Object -Unique)
                $modules = @($modulePaths | ForEach-Object {
                        $cacheKey = $_.ToUpperInvariant()
                        if (-not $fileCache.ContainsKey($cacheKey)) {
                            $fileCache[$cacheKey] = Get-VMateFileEvidence -LiteralPath $_
                        }
                        $fileCache[$cacheKey]
                    })
                foreach ($module in $modules) {
                    foreach ($fileError in @($module.collection_errors)) {
                        $message = "$($module.path)`: $fileError"
                        $recordErrors.Add($message)
                    }
                }
            } catch {
                $message = "PID $($process.ProcessId) 模块枚举失败: $($_.Exception.Message)"
                $recordErrors.Add($message)
            }
        }

        [pscustomobject][ordered]@{
            record_type = 'process'
            requested_match = $isRequested
            name = $process.Name
            process_id = [uint32]$process.ProcessId
            identity_validated = $identity.validated
            parent_process_id = [uint32]$process.ParentProcessId
            parent_name = if ($null -ne $parent) { $parent.Name } else { $null }
            parent_executable_path = if ($null -ne $parent) {
                $parent.ExecutablePath
            } else { $null }
            parent_creation_date = if ($null -ne $parent) {
                $parent.CreationDate
            } else { $null }
            parent_instance_live = $parentInstanceLive
            parent_relation_timeline_valid = $parentTimelineValid
            parent_identity_error = $parentValidationError
            executable_path = $executablePath
            command_line = $process.CommandLine
            creation_date = $process.CreationDate
            executable = $executable
            modules = $modules
            collection_errors = @($recordErrors)
        }
    }

}
