#!/usr/bin/env bash
# 验证 dnf-fix-deps 独立 EXE 的可复现构建、内嵌脚本和安全边界。
# shellcheck disable=SC2016
# 单引号中的 `$` 属于 PowerShell 源码或静态契约，不能由 Bash 展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DNF_DIR="$REPO_ROOT/deploy/guest-dnf-deps"
LAUNCHER="$DNF_DIR/launcher/dnf-fix-deps-launcher.c"
ARGUMENTS="$DNF_DIR/launcher/launcher-arguments.c"
PS1="$REPO_ROOT/deploy/scripts/guest/dnf-fix-deps.ps1"
INSTALLERS_PS1="$REPO_ROOT/deploy/scripts/guest/dnf-fix-installers.ps1"
DIRECTX_PS1="$REPO_ROOT/deploy/scripts/guest/dnf-fix-directx.ps1"
COMMON="$REPO_ROOT/deploy/guest-launcher-common"
HOST_ENTRY="$REPO_ROOT/deploy/scripts/dnf-fix-deps.sh"
PS51_GATE="$SCRIPT_DIR/test_windows_powershell51.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for tool in file llvm-readobj x86_64-w64-mingw32-objdump strings \
        sha256sum cc pwsh; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少测试工具: $tool"
done

mkdir -p "$TMP_DIR/build-one"
touch "$TMP_DIR/build-one/preserve-me"
for build_id in one two; do
    SOURCE_DATE_EPOCH=0 \
    BUILD_DIR="$TMP_DIR/build-$build_id" \
    OUT_DIR="$TMP_DIR/out-$build_id" \
        "$DNF_DIR/build-exe.sh" >/dev/null
done
[[ -f "$TMP_DIR/build-one/preserve-me" ]] \
    || fail "build-exe 删除了调用者已有的 BUILD_DIR 内容"

EXE_ONE="$TMP_DIR/out-one/dnf-fix-deps.exe"
EXE_TWO="$TMP_DIR/out-two/dnf-fix-deps.exe"
[[ -s "$EXE_ONE" && -s "$EXE_TWO" ]] || fail "独立 EXE 构建产物缺失"
cmp -s "$EXE_ONE" "$EXE_TWO" || {
    sha256sum "$EXE_ONE" "$EXE_TWO" >&2
    fail "相同输入的两次构建不一致"
}

file "$EXE_ONE" | grep -F 'PE32+ executable' >/dev/null \
    || fail "输出不是 Windows PE64 EXE"
llvm-readobj --file-headers "$EXE_ONE" \
    | grep -F 'TimeDateStamp: 1970-01-01 00:00:00 (0x0)' >/dev/null \
    || fail "PE/COFF 时间戳不是 0"
llvm-readobj --file-headers "$EXE_ONE" \
    | grep -F 'Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)' >/dev/null \
    || fail "PE 架构不是 AMD64"
x86_64-w64-mingw32-objdump -x "$EXE_ONE" >"$TMP_DIR/objdump.txt"
awk '
    /Entry: ID: 0x000018,/ {
        getline
        getline
        if ($0 ~ /Entry: ID: 0x000001,/) {
            found = 1
        }
    }
    END { exit found ? 0 : 1 }
' "$TMP_DIR/objdump.txt" || fail "资源表缺少 RT_MANIFEST id 1"

strings -a "$EXE_ONE" >"$TMP_DIR/strings-ascii.txt"
strings -a -el "$EXE_ONE" >"$TMP_DIR/strings-wide.txt"
grep -F 'requireAdministrator' "$TMP_DIR/strings-ascii.txt" >/dev/null \
    || fail "EXE 没有请求管理员权限"
grep -F 'uiAccess="false"' "$TMP_DIR/strings-ascii.txt" >/dev/null \
    || fail "EXE manifest 没有关闭 uiAccess"
for payload_name in dnf-fix-deps.ps1 dnf-fix-installers.ps1 \
        dnf-fix-directx.ps1; do
    grep -Fx "$payload_name" "$TMP_DIR/strings-wide.txt" >/dev/null \
        || fail "launcher 没有声明内嵌脚本: $payload_name"
done
grep -Fx -- '--dry-run' "$TMP_DIR/strings-wide.txt" >/dev/null \
    || fail "EXE 缺少 --dry-run 参数"
grep -Fx -- '--no-confirm' "$TMP_DIR/strings-wide.txt" >/dev/null \
    || fail "EXE 缺少 --no-confirm 参数"
grep -Fx -- '-DryRun' "$TMP_DIR/strings-wide.txt" >/dev/null \
    || fail "EXE 没有把 dry-run 映射为 PowerShell 参数"
grep -Fx -- '-LauncherMode' "$TMP_DIR/strings-wide.txt" >/dev/null \
    || fail "EXE 没有注入内嵌脚本启动标记"
grep -F 'VMateDnfDeps' "$TMP_DIR/strings-wide.txt" >/dev/null \
    || fail "EXE 缺少独立 ProgramData 目录"

# 每个原始 PS1（包括 UTF-8 BOM）必须完整且只出现一次。
python3 - "$EXE_ONE" "$PS1" "$INSTALLERS_PS1" "$DIRECTX_PS1" <<'PY'
from pathlib import Path
import sys

exe = Path(sys.argv[1]).read_bytes()
for source in sys.argv[2:]:
    payload = Path(source).read_bytes()
    if not payload.startswith(b"\xef\xbb\xbf"):
        raise SystemExit(f"{source}: PowerShell payload 丢失 UTF-8 BOM")
    count = exe.count(payload)
    if count != 1:
        raise SystemExit(f"{source}: payload 在 EXE 中出现 {count} 次，预期 1 次")
PY

# PowerShell 只做语法解析；测试不会联网，也不会运行任何安装器。
PS_SOURCE="$PS1" INSTALLERS_SOURCE="$INSTALLERS_PS1" \
DIRECTX_SOURCE="$DIRECTX_PS1" PE_SOURCE="$EXE_ONE" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
foreach ($source in $env:PS_SOURCE,$env:INSTALLERS_SOURCE,$env:DIRECTX_SOURCE) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $source, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -ne 0) {
        $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }
        exit 1
    }
}
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:PS_SOURCE, [ref]$tokens, [ref]$errors
)
foreach ($functionName in "Test-LauncherInvocation", "Get-PeMachine", `
        "Test-PackageInstalled", `
        "Get-BlockingMissingPackages") {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    Invoke-Expression $functionAst.Extent.Text
}
$testProgramData = Join-Path ([IO.Path]::GetTempPath()) "program-data"
$testRoot = Join-Path $testProgramData "VMateDnfDeps"
$testPayload = Join-Path $testRoot "payload"
$testCache = Join-Path $testRoot "cache"
$testLog = Join-Path $testRoot "install.log"
if (-not (Test-LauncherInvocation -Enabled -CommonAppData $testProgramData `
        -ScriptRoot $testPayload -CachePath $testCache -LogFile $testLog)) {
    exit 1
}
if (Test-LauncherInvocation -CommonAppData $testProgramData `
        -ScriptRoot $testPayload -CachePath $testCache -LogFile $testLog) {
    exit 1
}
if (Test-LauncherInvocation -Enabled -CommonAppData $testProgramData `
        -ScriptRoot $testPayload -CachePath "$testCache-wrong" `
        -LogFile $testLog) { exit 1 }
$package = @{
    CheckDll = @($env:PE_SOURCE)
    CheckMachine = @(0x8664)
    MinFileVersion = "0.0.0.0"
}
if (-not (Test-PackageInstalled -Pkg $package)) { exit 1 }
$package.CheckMachine = @(0x014C)
if (Test-PackageInstalled -Pkg $package) { exit 1 }
$script:CheckMessages = @()
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $script:CheckMessages += "$Level $Message"
}
$missingPackage = @{
    Id = "missing-test"
    CheckDll = @((Join-Path ([IO.Path]::GetTempPath()) "not-present.dll"))
}
if (Test-PackageInstalled -Pkg $missingPackage -Explain) { exit 1 }
if (($script:CheckMessages -join "`n") -notmatch "文件不存在") { exit 1 }
$blocking = @(
    Get-BlockingMissingPackages -Missing @("restart-id","broken-id") `
        -RestartPending @("restart-id")
)
if ($blocking.Count -ne 1 -or $blocking[0] -ne "broken-id") { exit 1 }
'

# 主脚本必须在任何模块加载、目录创建或日志写入前拒绝 standalone 调用。
standalone_cache="$TMP_DIR/standalone-cache"
standalone_log="$TMP_DIR/standalone-log/install.log"
set +e
pwsh -NoLogo -NoProfile -NonInteractive -File "$PS1" \
    -CacheDir "$standalone_cache" -LogPath "$standalone_log" \
    >"$TMP_DIR/standalone-no-marker.log" 2>&1
standalone_no_marker_status=$?
pwsh -NoLogo -NoProfile -NonInteractive -File "$PS1" -LauncherMode \
    -CacheDir "$standalone_cache" -LogPath "$standalone_log" \
    >"$TMP_DIR/standalone-wrong-path.log" 2>&1
standalone_wrong_path_status=$?
set -e
[[ "$standalone_no_marker_status" -eq 87 ]] \
    || fail "主脚本未拒绝缺少 EXE 标记的 standalone 调用"
[[ "$standalone_wrong_path_status" -eq 87 ]] \
    || fail "主脚本未拒绝错误 ProgramData 路径"
[[ ! -e "$standalone_cache" && ! -e "$(dirname "$standalone_log")" ]] \
    || fail "主脚本在拒绝 standalone 调用前创建了目录"

# DirectSetup/VC++ 退出码、解包流程和清理边界采用无联网模拟单测。
INSTALLERS_SOURCE="$INSTALLERS_PS1" DIRECTX_SOURCE="$DIRECTX_PS1" \
PS_TEST_ROOT="$TMP_DIR/directx-unit" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$script:LogMessages = @()
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $script:LogMessages += "$Level $Message"
}
. $env:INSTALLERS_SOURCE
. $env:DIRECTX_SOURCE
$package = New-DirectXPackage -WindowsDir "/windows" `
    -System32Dir "/windows/System32" -SysWow64Dir "/windows/SysWOW64"
if ($package.InstallKind -ne "DirectXRedist" -or
    -not $package.AlwaysInstall -or
    $package.Sha256 -ne "053F76DCBB28802E23341B6A787E3B0791C0FA5C8D4D011B1044172DBF89C73B") {
    exit 1
}
if ((Get-DirectXExitCodeText -Code 0) -notmatch "DSETUPERR_SUCCESS" -or
    (Get-DirectXExitCodeText -Code 1) -notmatch "SUCCESS_RESTART" -or
    (Get-DirectXExitCodeText -Code -9) -notmatch "0xFFFFFFF7.*DSETUPERR_INTERNAL") {
    exit 1
}
$cache = Join-Path $env:PS_TEST_ROOT "cache"
$inside = Join-Path $cache "directx-extract-test"
$outside = Join-Path $env:PS_TEST_ROOT "outside"
[void][IO.Directory]::CreateDirectory($inside)
[void][IO.Directory]::CreateDirectory($outside)
Remove-DirectXExtractDirectory -ExtractDir $inside -CacheDir $cache
if (Test-Path -LiteralPath $inside) { exit 1 }
Remove-DirectXExtractDirectory -ExtractDir $outside -CacheDir $cache
if (-not (Test-Path -LiteralPath $outside -PathType Container)) { exit 1 }

# 用同名函数覆盖外部命令，仅模拟已验签文件和子进程返回码。
function Test-MicrosoftInstaller { return $true }
function Start-Process {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$WorkingDirectory,
        [switch]$Wait,
        [switch]$PassThru,
        [switch]$NoNewWindow
    )
    if ($ArgumentList -match "^/Q /T:`"(.+)`"$") {
        foreach ($leaf in "DXSETUP.exe","dsetup.dll","dsetup32.dll","dxupdate.cab") {
            [IO.File]::WriteAllText((Join-Path $Matches[1] $leaf), "test")
        }
        return [PSCustomObject]@{ ExitCode = 0 }
    }
    return [PSCustomObject]@{ ExitCode = $script:MockExitCode }
}

$fakeInstaller = Join-Path $cache "directx_Jun2010_redist.exe"
foreach ($case in @(
    @{ Code = 0; Success = $true; Restart = $false },
    @{ Code = 1; Success = $true; Restart = $true },
    @{ Code = -9; Success = $false; Restart = $false }
)) {
    $script:MockExitCode = $case.Code
    $script:RestartRequired = $false
    $script:RestartRequiredPackages = @()
    $script:LogMessages = @()
    $result = Invoke-DirectXRedist -Package $package `
        -ExePath $fakeInstaller -CacheDir $cache
    if ($result -ne $case.Success -or
        $script:RestartRequired -ne $case.Restart) { exit 1 }
    if ($case.Restart -and
        $script:RestartRequiredPackages -notcontains $package.Id) { exit 1 }
    if (Get-ChildItem -LiteralPath $cache -Filter "directx-extract-*") { exit 1 }
    if ($case.Code -eq -9 -and
        ($script:LogMessages -join "`n") -notmatch "DSETUPERR_INTERNAL") { exit 1 }
}

# 安装成功后的防病毒文件占用只能导致清理告警。
function Remove-DirectXExtractDirectory { throw "mock cleanup lock" }
$script:MockExitCode = 0
$script:RestartRequired = $false
$script:RestartRequiredPackages = @()
$script:LogMessages = @()
if (-not (Invoke-DirectXRedist -Package $package `
            -ExePath $fakeInstaller -CacheDir $cache)) { exit 1 }
if (($script:LogMessages -join "`n") -notmatch "临时目录清理失败") { exit 1 }

foreach ($case in @(
    @{ Code = 0; Success = $true; Restart = $false },
    @{ Code = 1638; Success = $true; Restart = $false },
    @{ Code = 1641; Success = $true; Restart = $true },
    @{ Code = 3010; Success = $true; Restart = $true },
    @{ Code = -1; Success = $false; Restart = $false }
)) {
    $script:MockExitCode = $case.Code
    $script:RestartRequired = $false
    $script:RestartRequiredPackages = @()
    $script:RecheckOnlyPackages = @()
    $result = Invoke-Installer -ExePath "vc.exe" -Arguments "/install" `
        -ExpectedOriginalFileName "vc.exe" -PackageId "vc-test"
    if ($result -ne $case.Success -or
        $script:RestartRequired -ne $case.Restart) { exit 1 }
    if ($case.Restart -and
        $script:RestartRequiredPackages -notcontains "vc-test") { exit 1 }
    if ($case.Code -eq 1638 -and
        $script:RecheckOnlyPackages -notcontains "vc-test") { exit 1 }
}
'

# 参数解析器采用 host 原生单测，确保路径覆盖和未知参数不能进入管理员脚本。
cc -std=c11 -Wall -Wextra -Werror \
    -I "$DNF_DIR/launcher" \
    "$ARGUMENTS" \
    "$DNF_DIR/launcher/test-launcher-arguments.c" \
    -o "$TMP_DIR/test-launcher-arguments"
"$TMP_DIR/test-launcher-arguments"

for contract in \
        'SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA' \
        'payload_secure_directory(root)' \
        'payload_secure_directory(cache)' \
        'payload_acquire_lock(root)' \
        'payload_publish_bundle(root, work' \
        'payload_build_environment(root, work)' \
        'CREATE_UNICODE_ENVIRONMENT, environment, work'; do
    grep -F "$contract" "$LAUNCHER" >/dev/null \
        || fail "launcher 缺少安全契约: $contract"
done
if grep -F 'GetEnvironmentVariableW(L"ProgramData"' "$LAUNCHER" >&2; then
    fail "launcher 不应信任继承环境中的 ProgramData"
fi

for contract in \
        'Get-AuthenticodeSignature' \
        "'Microsoft Corporation'" \
        'OriginalFilename' \
        'Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256' \
        '.partial-' \
        'Move-Item -LiteralPath $partial -Destination $Destination -Force' \
        'Test-MicrosoftInstaller -Path $ExePath'; do
    grep -F -- "$contract" "$INSTALLERS_PS1" >/dev/null \
        || fail "安装器模块缺少安全契约: $contract"
done

for contract in \
        'directx_Jun2010_redist.exe' \
        '053F76DCBB28802E23341B6A787E3B0791C0FA5C8D4D011B1044172DBF89C73B' \
        "'/Q /T:\"{0}\"'" \
        "'DXSETUP.exe'" \
        "-ArgumentList '/silent'" \
        'DSETUPERR_SUCCESS_RESTART' \
        'DSETUPERR_INTERNAL' \
        'AlwaysInstall = $true' \
        "MinFileVersion = '9.29.952.3111'" \
        "Join-Path \$WindowsDir 'Logs\\DXError.log'" \
        'Remove-DirectXExtractDirectory -ExtractDir $extractDir'; do
    grep -F -- "$contract" "$DIRECTX_PS1" >/dev/null \
        || fail "DirectX 模块缺少完整包契约: $contract"
done
if grep -F 'dxwebsetup.exe' "$PS1" "$INSTALLERS_PS1" "$DIRECTX_PS1" >&2; then
    fail "PowerShell payload 仍使用不稳定的 DirectX Web 安装器"
fi

for contract in \
        'function Get-PeMachine' \
        '[Parameter(Mandatory)][string]$CacheDir' \
        '[Parameter(Mandatory)][string]$LogPath' \
        '此文件只作为 dnf-fix-deps.exe 的内嵌 payload 运行' \
        'function Test-LauncherInvocation' \
        '[Environment]::Is64BitProcess' \
        'exit 87' \
        "'msvcp100.dll'" \
        "'msvcp120.dll'" \
        "'vcruntime140_1.dll'" \
        "'concrt140.dll'" \
        '$allDllsPresent = $true'; do
    grep -F "$contract" "$PS1" >/dev/null \
        || fail "PowerShell 主流程缺少检测契约: $contract"
done
if grep -F 'C:\dnf-fix' "$PS1" >&2; then
    fail "PowerShell payload 不应保留不受保护的独立运行默认目录"
fi
# vcruntime140_1.dll 是 x64 redist 文件；x86 清单不得再次引入永久假阴性。
python3 - "$PS1" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8-sig")
x86 = source.split("Id        = 'vcredist2015_2022-x86'", 1)[1]
x86, x64 = x86.split("Id        = 'vcredist2015_2022-x64'", 1)
if "vcruntime140_1.dll" in x86:
    raise SystemExit("x86 VC++ 检测错误包含 vcruntime140_1.dll")
if "vcruntime140_1.dll" not in x64:
    raise SystemExit("x64 VC++ 检测缺少 vcruntime140_1.dll")
if x86.count("Join-Path $sysWow64Dir") != x86.count("0x014C"):
    raise SystemExit("x86 VC++ DLL 与 PE 架构清单长度不一致")
if x64.count("Join-Path $system32Dir") != x64.count("0x8664"):
    raise SystemExit("x64 VC++ DLL 与 PE 架构清单长度不一致")
PY
for payload_name in dnf-fix-deps.ps1 dnf-fix-installers.ps1 \
        dnf-fix-directx.ps1; do
    grep -F "'$payload_name'" "$PS51_GATE" >/dev/null \
        || fail "Windows PowerShell 5.1 原生门禁未包含: $payload_name"
done

for contract in \
        'PACKAGE_SCRIPT="deploy/guest-dnf-deps/package.sh"' \
        'EXE_LOCAL="deploy/guest-dnf-deps/dist/dnf-fix-deps.exe"' \
        'dnf-fix-deps.exe --no-confirm'; do
    grep -F "$contract" "$HOST_ENTRY" >/dev/null \
        || fail "host 入口没有使用独立 EXE: $contract"
done
if grep -F 'dnf-fix-deps.ps1' "$HOST_ENTRY" >&2; then
    fail "host 入口仍绕过 EXE 直接执行 PowerShell"
fi

for source in \
        "$LAUNCHER" "$ARGUMENTS" \
        "$DNF_DIR/launcher/launcher-arguments.h" \
        "$DNF_DIR/launcher/test-launcher-arguments.c" \
        "$DNF_DIR/launcher/dnf-fix-deps.exe.manifest" \
        "$COMMON/payload-security.c" "$COMMON/payload-environment.c" \
        "$COMMON/payload-security.h" "$COMMON/payload-environment.h" \
        "$PS1" "$INSTALLERS_PS1" "$DIRECTX_PS1" \
        "$HOST_ENTRY" "$DNF_DIR/README.md" "$DNF_DIR/build-exe.sh" \
        "$DNF_DIR/package.sh" "$PS51_GATE" \
        "$SCRIPT_DIR/$(basename "$0")"; do
    [[ "$(wc -l <"$source")" -le 500 ]] || fail "$source 超过 500 行"
done

# 在隔离仓库运行正式打包入口，既验证路径污染被忽略，也不改动工作区的发布目录。
PACKAGE_REPO="$TMP_DIR/package-repo"
mkdir -p "$PACKAGE_REPO/deploy/scripts/guest"
cp -a "$DNF_DIR" "$PACKAGE_REPO/deploy/guest-dnf-deps"
rm -rf "$PACKAGE_REPO/deploy/guest-dnf-deps/dist"
cp -a "$COMMON" "$PACKAGE_REPO/deploy/guest-launcher-common"
cp -a "$PS1" "$PACKAGE_REPO/deploy/scripts/guest/dnf-fix-deps.ps1"
cp -a "$INSTALLERS_PS1" "$PACKAGE_REPO/deploy/scripts/guest/dnf-fix-installers.ps1"
cp -a "$DIRECTX_PS1" "$PACKAGE_REPO/deploy/scripts/guest/dnf-fix-directx.ps1"
poison_out="$TMP_DIR/poison-out"
poison_build="$TMP_DIR/poison-build"
package_log_one="$TMP_DIR/package-one.log"
package_log_two="$TMP_DIR/package-two.log"
SOURCE_DATE_EPOCH=0 OUT_DIR="$poison_out" BUILD_DIR="$poison_build" \
    "$PACKAGE_REPO/deploy/guest-dnf-deps/package.sh" \
    >"$package_log_one" 2>&1 &
package_pid_one=$!
SOURCE_DATE_EPOCH=0 OUT_DIR="$poison_out" BUILD_DIR="$poison_build" \
    "$PACKAGE_REPO/deploy/guest-dnf-deps/package.sh" \
    >"$package_log_two" 2>&1 &
package_pid_two=$!
package_status=0
wait "$package_pid_one" || package_status=1
wait "$package_pid_two" || package_status=1
if [[ "$package_status" -ne 0 ]]; then
    cat "$package_log_one" "$package_log_two" >&2
    fail "并发 package.sh 执行失败"
fi
[[ ! -e "$poison_out" && ! -e "$poison_build" ]] \
    || fail "正式 package.sh 继承了外部输出路径"

PACKAGE_DIR="$PACKAGE_REPO/deploy/guest-dnf-deps"
DIST_EXE="$PACKAGE_DIR/dist/dnf-fix-deps.exe"
mapfile -d '' -t dist_entries < <(
    find "$PACKAGE_DIR/dist" -mindepth 1 -maxdepth 1 -print0
)
[[ "${#dist_entries[@]}" -eq 1 &&
   "${dist_entries[0]}" == "$DIST_EXE" &&
   -f "$DIST_EXE" && ! -L "$DIST_EXE" && -s "$DIST_EXE" ]] \
    || fail "正式 dist 不是单一 dnf-fix-deps.exe"
cmp -s "$EXE_ONE" "$DIST_EXE" || fail "正式包与已验证的可复现构建不一致"

# 新构建失败时必须保留上一份已经验证的正式 EXE。
verified_hash="$(sha256sum "$DIST_EXE" | awk '{print $1}')"
if SOURCE_DATE_EPOCH=invalid \
        "$PACKAGE_REPO/deploy/guest-dnf-deps/package.sh" >/dev/null 2>&1; then
    fail "package.sh 错误接受了非法 SOURCE_DATE_EPOCH"
fi
[[ "$(sha256sum "$DIST_EXE" | awk '{print $1}')" == "$verified_hash" ]] \
    || fail "构建失败破坏了上一份正式 EXE"

echo "PASS: dnf-fix-deps 独立 EXE 构建、嵌入和安全契约正确"
