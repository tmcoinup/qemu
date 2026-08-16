#!/usr/bin/env bash
# 验证 Linux/Windows 客体硬件快照工具的语法、并发机制和关键证据覆盖面。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LINUX_COLLECTOR="$REPO_ROOT/deploy/scripts/guest/collect-hardware-snapshot.sh"
WINDOWS_COLLECTOR="$REPO_ROOT/deploy/windows/collect-hardware-snapshot.ps1"
WINDOWS_EVIDENCE_HELPER="$REPO_ROOT/deploy/windows/lib/VMate.ProcessEvidence.ps1"
WINDOWS_FILE_EVIDENCE_HELPER="$REPO_ROOT/deploy/windows/lib/VMate.FileEvidence.ps1"
WINDOWS_PACKAGER="$REPO_ROOT/scripts/nsis.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_text() {
    local needle="$1" file="$2"
    grep -F -- "$needle" "$file" >/dev/null || fail "$file 缺少: $needle"
}

require_utf8_bom() {
    local file="$1" prefix
    prefix="$(od -An -tx1 -N3 "$file" | tr -d '[:space:]')"
    [[ "$prefix" == "efbbbf" ]] || fail "$file 必须使用 UTF-8 BOM 兼容 Windows PowerShell 5.1"
}

bash -n "$LINUX_COLLECTOR"
for marker in 'wait_for_slot' 'dmidecode --type' 'lspci -nnvv' 'nvme id-ctrl' \
              'tpm2_getcap properties-fixed' 'edid-decode' 'dmesg --level='; do
    require_text "$marker" "$LINUX_COLLECTOR"
done

require_utf8_bom "$WINDOWS_COLLECTOR"
require_utf8_bom "$WINDOWS_EVIDENCE_HELPER"
require_utf8_bom "$WINDOWS_FILE_EVIDENCE_HELPER"
require_text '"deploy/windows/lib/VMate.ProcessEvidence.ps1",' "$WINDOWS_PACKAGER"
require_text '"deploy/windows/lib/VMate.FileEvidence.ps1",' "$WINDOWS_PACKAGER"

for marker in 'Start-Job' 'Win32_Processor' 'Win32_PhysicalMemory' 'Get-PnpDevice' \
              'Get-PhysicalDisk' 'Get-Tpm' 'Get-WinEvent' 'Win32_SystemDriver' \
              "Name = 'ProcessEvidence'" "Name = 'SetupApiDevLog'" \
              "Name = 'SystemDriverFiles'" \
              "PnpDriverStore = @('pnputil.exe', '/enum-drivers')" 'dxdiag.exe'; do
    require_text "$marker" "$WINDOWS_COLLECTOR"
done

# shellcheck disable=SC2016 # 这些是需要按字面匹配的 PowerShell 变量名。
for marker in 'Win32_Process' '$targets.Contains([string]$candidate.Name)' \
              'ParentProcessId' 'CommandLine' '$liveProcess.Modules' \
              'Is64BitProcess' 'contains_sensitive_data' \
              'Test-VMateParentTimeline' 'VMate.FileEvidence.ps1'; do
    require_text "$marker" "$WINDOWS_EVIDENCE_HELPER"
done

for marker in 'Get-AuthenticodeSignature' 'Get-FileHash' 'SHA256' \
              'changed_during_collection' 'Win32_SystemDriver' \
              'setupapi.dev.log' 'contains_sensitive_data' \
              'Resolve-VMateSafeLocalFile' 'ReparsePoint'; do
    require_text "$marker" "$WINDOWS_FILE_EVIDENCE_HELPER"
done

if grep -E -- 'MiniDumpWriteDump|ReadProcessMemory|Stop-Process|Suspend-Process|taskkill|/delete-driver|DiInstallDevice|SetupUninstallOEMInf' \
        "$WINDOWS_COLLECTOR" "$WINDOWS_EVIDENCE_HELPER" \
        "$WINDOWS_FILE_EVIDENCE_HELPER" >/dev/null; then
    fail "Windows 只读采集器包含禁止的内存、进程或驱动修改操作"
fi

POWERSHELL_BIN=""
if command -v powershell.exe >/dev/null 2>&1; then
    POWERSHELL_BIN="$(command -v powershell.exe)"
elif command -v pwsh >/dev/null 2>&1; then
    POWERSHELL_BIN="$(command -v pwsh)"
fi
if [[ -n "$POWERSHELL_BIN" ]]; then
    # shellcheck disable=SC2016 # PowerShell 代码必须由 PowerShell 自身展开变量。
    for powershell_file in "$WINDOWS_COLLECTOR" "$WINDOWS_EVIDENCE_HELPER" \
            "$WINDOWS_FILE_EVIDENCE_HELPER"; do
        WINDOWS_PS_FILE="$powershell_file" "$POWERSHELL_BIN" \
            -NoLogo -NoProfile -NonInteractive -Command '
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile(
                    $env:WINDOWS_PS_FILE, [ref]$null, [ref]$errors)
                if ($errors.Count -gt 0) {
                    $errors | ForEach-Object { Write-Error $_.Message }
                    exit 1
                }
            '
    done
    # shellcheck disable=SC2016 # 单引号块必须交给 PowerShell 展开。
    WINDOWS_PS_FILE="$WINDOWS_EVIDENCE_HELPER" \
        WINDOWS_COLLECTOR="$WINDOWS_COLLECTOR" "$POWERSHELL_BIN" \
        -NoLogo -NoProfile -NonInteractive -Command '
            . $env:WINDOWS_PS_FILE
            $global:MockCreationDate = Get-Date
            function global:Get-CimInstance {
                [CmdletBinding()]
                param(
                    [Parameter(Position = 0)] [string]$ClassName,
                    [string]$Filter
                )
                if ($ClassName -ne "Win32_Process") { throw "unexpected CIM class" }
                [pscustomobject]@{
                    Name = "97385.exe"; ProcessId = 10; ParentProcessId = 1
                    ExecutablePath = $null; CommandLine = "97385.exe"
                    CreationDate = $global:MockCreationDate
                }
                [pscustomobject]@{
                    Name = "97385.com"; ProcessId = 11; ParentProcessId = 1
                    ExecutablePath = $null; CommandLine = "97385.com"
                    CreationDate = $global:MockCreationDate
                }
                [pscustomobject]@{
                    Name = "stale-child.exe"; ProcessId = 12; ParentProcessId = 10
                    ExecutablePath = $null; CommandLine = "stale-child.exe"
                    CreationDate = $global:MockCreationDate.AddMinutes(-1)
                }
                [pscustomobject]@{
                    Name = "valid-child.exe"; ProcessId = 13; ParentProcessId = 10
                    ExecutablePath = $null; CommandLine = "valid-child.exe"
                    CreationDate = $global:MockCreationDate.AddSeconds(1)
                }
            }
            function global:Get-Process {
                [CmdletBinding()]
                param([Parameter(Mandatory)] [int]$Id)
                $processName = if ($Id -eq 13) { "valid-child" } else { "97385" }
                $startTime = if ($Id -eq 13) {
                    $global:MockCreationDate.AddSeconds(1)
                } else { $global:MockCreationDate }
                [pscustomobject]@{
                    ProcessName = $processName; StartTime = $startTime
                    Path = $null; Modules = @()
                }
            }
            $result = Get-VMateProcessEvidence -RequestedNames "97385.exe"
            $metadata = @($result | Where-Object record_type -eq "metadata")[0]
            if ($metadata.target_found -ne 1 -or $metadata.process_tree_count -ne 2) {
                throw "完整映像名/子树回归: target=$($metadata.target_found) tree=$($metadata.process_tree_count)"
            }
            $snapshotNames = @($metadata.process_snapshot.name)
            if ($snapshotNames -contains "stale-child.exe" -or
                $snapshotNames -notcontains "valid-child.exe") {
                throw "PPID 时间线未正确筛选子进程"
            }
            $unsafe = Resolve-VMateSafeLocalFile -LiteralPath "\\server\share\evil.sys"
            if ($unsafe.safe -or $unsafe.error -notmatch "拒绝") {
                throw "UNC 路径未在文件系统访问前被拒绝"
            }
            function global:Get-CimInstance {
                [CmdletBinding()]
                param(
                    [Parameter(Position = 0)] [string]$ClassName,
                    [string]$Filter
                )
                if ($ClassName -eq "Win32_LogicalDisk") {
                    return [pscustomobject]@{ DeviceID = "C:" }
                }
                if ($ClassName -eq "Win32_SystemDriver") {
                    return [pscustomobject]@{
                        Name = "unsafe"; DisplayName = "unsafe"
                        State = "Stopped"; Started = $false; StartMode = "Manual"
                        ServiceType = "Kernel Driver"
                        PathName = "\\server\share\evil.sys"
                    }
                }
                throw "unexpected CIM class"
            }
            $driverRecord = @(Get-VMateSystemDriverEvidence |
                Where-Object record_type -eq "driver")[0]
            if (@($driverRecord.collection_errors).Count -eq 0) {
                throw "被拒绝的驱动路径未写入 collection_errors"
            }
            $context = [pscustomobject]@{ HelperPath = $env:WINDOWS_PS_FILE }
            $parameters = @{
                ScriptBlock = {
                    param($Context)
                    . ([string]$Context.HelperPath)
                    (Get-Command Get-VMateProcessEvidence).Name
                }
                ArgumentList = @($context)
            }
            $job = Start-Job @parameters
            [void](Wait-Job -Job $job -Timeout 15)
            $jobResult = Receive-Job -Job $job
            Remove-Job -Job $job -Force
            if ($jobResult -ne "Get-VMateProcessEvidence") {
                throw "Start-Job 无法加载进程证据模块"
            }
            $tokens = $null
            $parseErrors = $null
            $collectorAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $env:WINDOWS_COLLECTOR, [ref]$tokens, [ref]$parseErrors)
            $driverPair = $null
            $tables = $collectorAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.HashtableAst]
                }, $true)
            foreach ($table in $tables) {
                foreach ($pair in $table.KeyValuePairs) {
                    if ($pair.Item1.Extent.Text -eq "DriverInstallEvents") {
                        $driverPair = $pair
                    }
                }
            }
            $probeText = $driverPair.Item2.Extent.Text
            function global:Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable, [int]$MaxEvents)
                if ($global:WinEventMode -eq "success") {
                    return [pscustomobject]@{
                        TimeCreated = Get-Date; Id = 1; LevelDisplayName = "Info"
                        ProviderName = "mock"; Message = "ok"
                    }
                }
                if ($global:WinEventMode -eq "empty") {
                    $record = [System.Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new("none"),
                        "NoMatchingEventsFound",
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $null)
                    $PSCmdlet.ThrowTerminatingError($record)
                }
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [UnauthorizedAccessException]::new("denied"),
                    "AccessDenied",
                    [System.Management.Automation.ErrorCategory]::PermissionDenied,
                    $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            $global:WinEventMode = "success"
            $driverProbe = & ([scriptblock]::Create($probeText))
            $eventResult = & $driverProbe
            if ($eventResult.events.Count -ne 4 -or
                $eventResult.collection_errors.Count -ne 0) {
                throw "DriverInstallEvents 成功分支回归"
            }
            $global:WinEventMode = "empty"
            $driverProbe = & ([scriptblock]::Create($probeText))
            $eventResult = & $driverProbe
            if ($eventResult.events.Count -ne 0 -or
                $eventResult.collection_errors.Count -ne 0) {
                throw "DriverInstallEvents 零命中分支回归"
            }
            $global:WinEventMode = "failure"
            $driverProbe = & ([scriptblock]::Create($probeText))
            $eventResult = & $driverProbe
            if ($eventResult.collection_errors.Count -ne 4) {
                throw "DriverInstallEvents 查询失败分支未汇总"
            }
        '
fi

echo "OK: guest hardware snapshot static checks passed"
