#!/usr/bin/env bash
# 验证 guest-stealth 单文件 EXE 可在当前 host 上交叉编译，并带上必要 payload。
# shellcheck disable=SC2016
# 单引号中的 PowerShell `$` 是待匹配源码，不能由 Bash 提前展开。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OUT_DIR="$TMP_DIR/out"
BUILD_DIR="$TMP_DIR/build"

OUT_DIR="$OUT_DIR" \
BUILD_DIR="$BUILD_DIR" \
    "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" >/dev/null

EXE="$OUT_DIR/respawn-stealth.exe"
PAYLOAD_SECURITY="$REPO_ROOT/deploy/guest-stealth/launcher/payload-security.c"
PAYLOAD_ENVIRONMENT="$REPO_ROOT/deploy/guest-stealth/launcher/payload-environment.c"
LAUNCHER_ARGUMENTS="$REPO_ROOT/deploy/guest-stealth/launcher/launcher-arguments.c"
MANUFACTURER_HELPER="$REPO_ROOT/deploy/scripts/gpu-manufacturer-projection.ps1"
MANUFACTURER_PROJECTOR_SOURCE="$REPO_ROOT/deploy/guest-stealth/launcher/gpu-manufacturer-projector.c"
MANUFACTURER_PROJECTOR_EXE="$BUILD_DIR/gpu-manufacturer-projector.exe"
[[ -s "$EXE" ]] || fail "未生成 respawn-stealth.exe"
[[ -s "$MANUFACTURER_PROJECTOR_EXE" ]] \
    || fail "未生成 gpu-manufacturer-projector.exe"

file "$EXE" | grep -F 'PE32+ executable' >/dev/null \
    || fail "输出不是 Windows PE64 EXE: $(file "$EXE")"
llvm-readobj --file-headers "$EXE" | grep -F 'TimeDateStamp: 1970-01-01 00:00:00 (0x0)' >/dev/null \
    || fail "EXE 的 PE/COFF 时间戳不是可复现构建要求的 0"
file "$MANUFACTURER_PROJECTOR_EXE" | grep -F 'PE32+ executable' >/dev/null \
    || fail "厂商投影器不是 Windows PE64 EXE: $(file "$MANUFACTURER_PROJECTOR_EXE")"
llvm-readobj --file-headers "$MANUFACTURER_PROJECTOR_EXE" \
    | grep -F 'TimeDateStamp: 1970-01-01 00:00:00 (0x0)' >/dev/null \
    || fail "厂商投影器的 PE/COFF 时间戳不是可复现构建要求的 0"
for projector_api in SetupDiGetClassDevsW CM_Set_DevNode_PropertyW; do
    strings -a "$MANUFACTURER_PROJECTOR_EXE" | grep -F "$projector_api" >/dev/null \
        || fail "厂商投影器缺少 Windows API 导入: $projector_api"
done

strings -a "$EXE" | grep -F 'requireAdministrator' >/dev/null \
    || fail "EXE 未嵌入 requireAdministrator manifest"
x86_64-w64-mingw32-objdump -x "$EXE" | grep -F 'Entry: ID: 0x000018' >/dev/null \
    || fail "EXE 资源表缺少 RT_MANIFEST(type 24)"
x86_64-w64-mingw32-objdump -x "$EXE" | grep -F 'Entry: ID: 0x000001' >/dev/null \
    || fail "EXE 资源表缺少 manifest id 1"
strings -a "$EXE" | grep -F 'respawn-stealth-local.ps1' >/dev/null \
    || fail "EXE 未包含 respawn payload 文件名"
strings -a -el "$EXE" | grep -F 'configure-power-policy.ps1' >/dev/null \
    || fail "EXE launcher 未包含电源策略 payload 文件名"
strings -a "$EXE" | grep -F 'apply-gpu-spoof.ps1' >/dev/null \
    || fail "EXE 未包含 apply-gpu-spoof payload 文件名"
for manufacturer_payload in gpu-manufacturer-projection.ps1 \
        gpu-manufacturer-projector.exe; do
    strings -a -el "$EXE" | grep -F "$manufacturer_payload" >/dev/null \
        || fail "EXE launcher 未包含厂商投影 payload 文件名: $manufacturer_payload"
done
for helper_file in persist-gpu-profile.ps1 gpu-profile-transaction.ps1 \
        gpu-profile-registry-core.ps1 refresh-gpu-name.ps1 \
        gpu-hardware-id-plan.ps1 project-gpu-hardware-id.ps1 \
        force-displayfreq.ps1 respawn-restart-state.ps1; do
    strings -a "$EXE" | grep -F "$helper_file" >/dev/null \
        || fail "EXE 未包含独立 helper 文件名: $helper_file"
done
strings -a "$EXE" | grep -F 'install-display-driver.ps1' >/dev/null \
    || fail "EXE 未包含离线显示驱动安装 payload 文件名"
strings -a "$EXE" | grep -F 'display-driver-trust.ps1' >/dev/null \
    || fail "EXE 未包含显示驱动信任 helper 文件名"
strings -a "$EXE" | grep -F 'install-chipset-device.ps1' >/dev/null \
    || fail "EXE 未包含芯片组识别 INF 安装 payload 文件名"
strings -a "$EXE" | grep -F 'install-nvapi-system.ps1' >/dev/null \
    || fail "EXE 未包含双架构系统 NVAPI 安装 payload 文件名"
strings -a "$EXE" | grep -F 'nvapi-system-transaction.ps1' >/dev/null \
    || fail "EXE 未包含 NVAPI durable transaction helper 文件名"
if strings -a "$EXE" | grep -F 'launch-nvapi-tool.ps1' >&2; then
    fail "EXE 仍包含已移除的 app-local GPU-Z 启动入口"
fi
for driver_file in viogpudo.sys viogpudo.cat viogpudo.inf; do
    strings -a "$EXE" | grep -F "$driver_file" >/dev/null \
        || fail "EXE 未包含内嵌驱动文件名: $driver_file"
done
for chipset_file in CannonLake-HSystem.inf cannonlake-h.cat \
        SunrisePoint-HSystem.inf sunrisepoint-h.cat; do
    strings -a "$EXE" | grep -F "$chipset_file" >/dev/null \
        || fail "EXE 未包含芯片组 payload 文件名: $chipset_file"
done
for nvapi_file in nvapi.dll nvapi64.dll; do
    strings -a "$EXE" | grep -F "$nvapi_file" >/dev/null \
        || fail "EXE 未包含 NVAPI payload 文件名: $nvapi_file"
done
strings -a "$EXE" | grep -F 'MessageBoxW' >/dev/null \
    || fail "EXE 未导入运行前确认弹窗"
strings -a -el "$EXE" | grep -F -- '--firstlogon' >/dev/null \
    || fail "EXE 缺少 FirstLogon 无人值守参数"
strings -a -el "$EXE" | grep -F -- '--no-confirm' >/dev/null \
    || fail "EXE 缺少跳过确认弹窗参数"
strings -a "$EXE" | grep -F 'Enable-RespawnDisplayDevices' >/dev/null \
    || fail "EXE 未包含 Code 22 外层启用兜底"
strings -a "$EXE" | grep -F 'Enable-StealthDisplayDevices' >/dev/null \
    || fail "EXE 未包含 Code 22 apply 启用兜底"
strings -a -el "$EXE" | grep -F -- '-FirstLogon' >/dev/null \
    || fail "EXE 未把 FirstLogon 模式传给内嵌脚本"
strings -a -el "$EXE" | grep -F -- '-Unattended' >/dev/null \
    || fail "EXE 自动模式未禁止 guest 错误路径交互等待"
strings -a "$EXE" | grep -F -- '-SkipTask' >/dev/null \
    || fail "EXE 内嵌脚本 FirstLogon 模式未跳过交互式显示任务"
strings -a "$EXE" | grep -F 'StealthGPU-RefreshName' >/dev/null \
    || fail "EXE 内嵌脚本缺少持久名称刷新任务"
strings -a "$EXE" | grep -F 'StealthGPU-ProjectHardwareId' >/dev/null \
    || fail "EXE 未包含正式 HardwareID 投影任务"
if strings -a "$EXE" | grep -F 'live-vm2-e2e' >&2; then
    fail "EXE 不得包含 VM2/HTTP/GPU-Z 专用现场调试脚本"
fi

# 提权 launcher 会在可预测 ProgramData 目录执行脚本，因此必须固定可信 Owner/DACL、
# 拒绝 reparse point、持有根目录独占锁，并先完成整个 staging 再发布和执行。
grep -F 'payload_secure_directory(root_dir)' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有保护 ProgramData payload 根目录"

# Windows 的 Common AppData Known Folder 可以被管理员重定向到非 C: 卷。生产脚本
# 必须沿用 launcher 已验证的 PSScriptRoot 父目录，不能重新硬编码 C:\ProgramData，
# 否则日志和计划任务 helper 会离开受保护 DACL 根。
grep -F '$logDir = Split-Path -Parent $PSScriptRoot' \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" >/dev/null \
    || fail "respawn 日志目录没有绑定到受保护 payload 根"
grep -F '$scriptDir = Split-Path -Parent $PSScriptRoot' \
    "$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1" >/dev/null \
    || fail "apply 持久化 helper 目录没有绑定到受保护 payload 根"
if grep -F -e "'C:\\ProgramData\\StealthGPU'" -e '"C:\\ProgramData\\StealthGPU"' \
        "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" \
        "$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1" >&2; then
    fail "生产 PowerShell 仍硬编码 Common AppData 的默认 C: 路径"
fi
grep -F 'SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 仍可能信任调用用户提供的 ProgramData 环境变量"
if grep -F 'GetEnvironmentVariableW(L"ProgramData"' \
        "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >&2; then
    fail "提权 launcher 不应从继承环境读取 ProgramData"
fi
grep -F 'payload_acquire_lock(root_dir)' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有防止并发 payload 混版"
grep -F "[IO.FileShare]::None" \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" >/dev/null \
    || fail "重启恢复任务没有与 launcher 共用 payload 独占锁"
grep -F "'.payload.lock'" \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" >/dev/null \
    || fail "重启恢复任务没有锁定受保护 payload 根"
if grep -F -- "-Execute 'powershell.exe'" \
        "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1" \
        "$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1" >&2; then
    fail "高权限计划任务仍通过可被环境影响的裸 powershell.exe 启动"
fi
grep -F 'payload_publish_bundle(root_dir, work_dir' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有以完整目录为单位发布 payload"
grep -F '#include "payload_configure_power_policy_ps1.h"' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有编译电源策略 payload 数组"
grep -F '{ L"configure-power-policy.ps1", payload_configure_power_policy_ps1,' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有把电源策略 helper 加入实际释放表"
grep -F '#include "payload_respawn_restart_state_ps1.h"' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有编译重启状态 helper"
grep -F '{ L"respawn-restart-state.ps1", payload_respawn_restart_state_ps1,' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有释放重启状态 helper"
grep -F '#include "payload_gpu_manufacturer_projection_ps1.h"' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有编译厂商投影 PowerShell payload"
grep -F '{ L"gpu-manufacturer-projection.ps1", payload_gpu_manufacturer_projection_ps1,' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有释放厂商投影 PowerShell helper"
grep -F '#include "payload_gpu_manufacturer_projector_exe.h"' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有编译厂商投影器 payload"
grep -F '{ L"gpu-manufacturer-projector.exe", payload_gpu_manufacturer_projector_exe,' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有释放厂商投影器"
grep -F 'O:BAD:P' "$PAYLOAD_SECURITY" >/dev/null \
    || fail "payload 安全描述符没有固定 Administrators Owner"
grep -F 'OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION' \
    "$PAYLOAD_SECURITY" >/dev/null \
    || fail "既有 payload 目录没有同时收紧 Owner 与 DACL"
grep -F 'check_directory_owner(path, security.owner, 0)' \
    "$PAYLOAD_SECURITY" >/dev/null \
    || fail "既有 payload 目录没有在接管前拒绝普通用户 Owner"
grep -F 'check_directory_owner(path, security->owner, 1)' \
    "$PAYLOAD_SECURITY" >/dev/null \
    || fail "payload 目录设置后没有复核 Administrators Owner"
grep -F 'PROTECTED_DACL_SECURITY_INFORMATION' "$PAYLOAD_SECURITY" >/dev/null \
    || fail "payload 目录 DACL 仍会继承潜在宽权限"
grep -F 'FILE_ATTRIBUTE_REPARSE_POINT' "$PAYLOAD_SECURITY" >/dev/null \
    || fail "payload 路径没有拒绝重解析点"
grep -F 'create_unique_staging' "$PAYLOAD_SECURITY" >/dev/null \
    || fail "payload 没有先写唯一 staging 目录"
grep -F 'MoveFileExW(staging, work_dir, MOVEFILE_WRITE_THROUGH)' \
    "$PAYLOAD_SECURITY" >/dev/null || fail "完整 staging 没有原子发布"
grep -F 'CREATE_NEW' "$PAYLOAD_SECURITY" >/dev/null \
    || fail "staging 文件没有拒绝覆盖既有路径"
if grep -F 'CREATE_ALWAYS' "$PAYLOAD_SECURITY" >&2; then
    fail "payload 安全模块重新使用可被并发观察的 CREATE_ALWAYS"
fi
if grep -F 'wcscpy(out, L"powershell.exe")' \
        "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >&2; then
    fail "提权 launcher 仍会从当前目录或 PATH 搜索裸 powershell.exe"
fi

# 第一跳固定 System32 仍不够：管理员 PowerShell 不能继承非提权调用者的 PATH、
# PSModulePath 或 .NET profiler 变量。最小环境只允许系统命令/系统模块，并把临时
# 目录放到受保护 work_dir；CreateProcess 必须显式使用这个 Unicode 环境块。
grep -F 'payload_build_environment(root_dir, work_dir)' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "launcher 没有构造管理员子进程最小环境"
grep -F 'CREATE_UNICODE_ENVIRONMENT, environment, work_dir' \
    "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" >/dev/null \
    || fail "CreateProcess 仍继承调用用户环境"
for contract in 'L"PATH", safe_path' 'L"PSModulePath", module_path' \
        'L"TEMP", work_dir' 'L"PROGRAMDATA", program_data'; do
    grep -F "$contract" "$PAYLOAD_ENVIRONMENT" >/dev/null \
        || fail "最小环境缺少受控项: $contract"
done
grep -F 'COMPLUS_*' "$PAYLOAD_ENVIRONMENT" >/dev/null \
    || fail "最小环境没有记录拒绝 .NET profiler 注入变量"

for c_source in \
        "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" \
        "$PAYLOAD_SECURITY" "$PAYLOAD_ENVIRONMENT" "$LAUNCHER_ARGUMENTS" \
        "$MANUFACTURER_PROJECTOR_SOURCE"; do
    [[ "$(wc -l < "$c_source")" -le 500 ]] \
        || fail "$c_source 超过 500 行"
done

# --no-confirm/--auto 只控制确认框，不能意外触发 -FirstLogon/-SkipTask 清理。
cc -std=c11 -Wall -Wextra -Werror \
    -I "$REPO_ROOT/deploy/guest-stealth/launcher" \
    "$LAUNCHER_ARGUMENTS" \
    "$REPO_ROOT/deploy/guest-stealth/launcher/test-launcher-arguments.c" \
    -o "$TMP_DIR/test-launcher-arguments"
"$TMP_DIR/test-launcher-arguments"

# NumLock 已迁移到 QEMU host 的 usb-kbd LED 状态机。发布 EXE 内若再次出现
# 注册表键名或 WinAPI toggle 标记，就说明有人误把旧 guest 方案打包了回来。
if strings -a "$EXE" | grep -Ei \
        'InitialKeyboardIndicators|keybd_event|VK_NUMLOCK|host-fix-numlock' >&2; then
    fail "EXE 仍包含旧 guest NumLock 注册表/按键更新逻辑"
fi

# C 编译器应把每个数组原样放进 PE。直接查找完整二进制子串，比只看文件名更能
# 防止 build 脚本漏掉或截断 SYS/CAT/INF；三者原始字节不变也是签名有效的前提。
python3 - "$EXE" "$REPO_ROOT" "$MANUFACTURER_PROJECTOR_EXE" <<'PY'
from pathlib import Path
import sys

exe_path = Path(sys.argv[1])
root = Path(sys.argv[2])
manufacturer_projector_path = Path(sys.argv[3])
exe = exe_path.read_bytes()
payloads = (
    root / "deploy/guest-stealth/respawn-stealth-local.ps1",
    root / "deploy/guest-stealth/respawn-restart-state.ps1",
    root / "deploy/guest-stealth/configure-power-policy.ps1",
    root / "deploy/guest-stealth/install-display-driver.ps1",
    root / "deploy/guest-stealth/display-driver-trust.ps1",
    root / "deploy/guest-stealth/install-chipset-device.ps1",
    root / "deploy/guest-stealth/install-nvapi-system.ps1",
    root / "deploy/guest-stealth/nvapi-system-transaction.ps1",
    root / "deploy/scripts/apply-gpu-spoof.ps1",
    root / "deploy/scripts/persist-gpu-profile.ps1",
    root / "deploy/scripts/gpu-profile-transaction.ps1",
    root / "deploy/scripts/gpu-profile-registry-core.ps1",
    root / "deploy/scripts/refresh-gpu-name.ps1",
    root / "deploy/scripts/gpu-manufacturer-projection.ps1",
    manufacturer_projector_path,
    root / "deploy/scripts/gpu-hardware-id-plan.ps1",
    root / "deploy/scripts/project-gpu-hardware-id.ps1",
    root / "deploy/scripts/force-displayfreq.ps1",
    root / "deploy/scripts/stock-viogpudo/viogpudo.sys",
    root / "deploy/scripts/stock-viogpudo/viogpudo.cat",
    root / "deploy/scripts/stock-viogpudo/viogpudo.inf",
    root / "deploy/scripts/stock-intel-chipset-inf/CannonLake-HSystem.inf",
    root / "deploy/scripts/stock-intel-chipset-inf/cannonlake-h.cat",
    root / "deploy/scripts/stock-intel-chipset-inf/SunrisePoint-HSystem.inf",
    root / "deploy/scripts/stock-intel-chipset-inf/sunrisepoint-h.cat",
    root / "deploy/nvapi-shim/nvapi.dll",
    root / "deploy/nvapi-shim/nvapi64.dll",
)
for payload_path in payloads:
    payload = payload_path.read_bytes()
    if payload not in exe:
        raise SystemExit(f"FAIL: EXE 中找不到完整原始 payload: {payload_path.name}")
PY

# legacy 调试发布仍应平铺全部 helper；默认发布继续只有一个 EXE。
for helper_name in persist-gpu-profile.ps1 gpu-profile-transaction.ps1 \
        gpu-profile-registry-core.ps1 refresh-gpu-name.ps1 \
        gpu-manufacturer-projection.ps1 gpu-manufacturer-projector.exe \
        gpu-hardware-id-plan.ps1 project-gpu-hardware-id.ps1 \
        force-displayfreq.ps1 configure-power-policy.ps1 \
        display-driver-trust.ps1 respawn-restart-state.ps1 \
        install-chipset-device.ps1 CannonLake-HSystem.inf cannonlake-h.cat \
        SunrisePoint-HSystem.inf sunrisepoint-h.cat \
        install-nvapi-system.ps1 nvapi-system-transaction.ps1 \
        nvapi.dll nvapi64.dll; do
    grep -F "$helper_name" "$REPO_ROOT/deploy/guest-stealth/package.sh" >/dev/null \
        || fail "legacy package 路径缺少 $helper_name"
done

if strings -a "$EXE" | grep -F 'http://192.168.30.33:8765' >&2; then
    fail "EXE 重新引入了旧 host HTTP 安装依赖"
fi

# package.sh 是用户最终生成“傻瓜单文件”的正式入口。用隔离仓库副本运行真实构建，
# 并故意注入六个错误目录变量，证明它不会把 EXE 写到调用者指定的旁路目录，也不会
# 从旁路驱动/芯片组/NVAPI/ADL 目录取输入。测试副本的四个只读输入目录链接回真源，
# 所有 dist/build 写入仍限制在 mktemp 下，不污染并行测试共享的正式发布目录。
PACKAGE_REPO="$TMP_DIR/package-repo"
mkdir -p "$PACKAGE_REPO/deploy"
cp -a "$REPO_ROOT/deploy/guest-stealth" "$PACKAGE_REPO/deploy/guest-stealth"
rm -rf "$PACKAGE_REPO/deploy/guest-stealth/dist"
ln -s "$REPO_ROOT/deploy/scripts" "$PACKAGE_REPO/deploy/scripts"
ln -s "$REPO_ROOT/deploy/nvapi-shim" "$PACKAGE_REPO/deploy/nvapi-shim"
ln -s "$REPO_ROOT/deploy/adl-shim" "$PACKAGE_REPO/deploy/adl-shim"
poison_out="$TMP_DIR/poison-out"
poison_build="$TMP_DIR/poison-build"
env -u INCLUDE_LEGACY_SCRIPTS \
    OUT_DIR="$poison_out" \
    BUILD_DIR="$poison_build" \
    DRIVER_SRC_DIR="$TMP_DIR/missing-driver" \
    CHIPSET_INF_SRC_DIR="$TMP_DIR/missing-chipset" \
    NVAPI_SRC_DIR="$TMP_DIR/missing-nvapi" \
    ADL_SRC_DIR="$TMP_DIR/missing-adl" \
    "$PACKAGE_REPO/deploy/guest-stealth/package.sh" >/dev/null

PACKAGE_DIST="$PACKAGE_REPO/deploy/guest-stealth/dist"
PACKAGE_BUILD="$PACKAGE_REPO/build/guest-stealth-exe"
mapfile -d '' -t package_entries < <(find "$PACKAGE_DIST" -mindepth 1 -maxdepth 1 -print0)
[[ "${#package_entries[@]}" -eq 1 &&
   "${package_entries[0]}" == "$PACKAGE_DIST/respawn-stealth.exe" &&
   -s "$PACKAGE_DIST/respawn-stealth.exe" ]] \
    || fail "污染环境下 package.sh 没有生成严格单 EXE dist"
[[ ! -e "$poison_out" && ! -e "$poison_build" ]] \
    || fail "package.sh 仍继承了调用者的 OUT_DIR/BUILD_DIR"

# 前面的直接构建与这里的 package.sh 构建使用不同绝对源码目录、BUILD_DIR 和 OUT_DIR，
# 但输入文件逐字节相同。复用这两次既有构建做可复现性断言，不额外再编译第三次；
# cmp 保证整份 PE 相同，摘要同时让失败日志能直接指出两份发布物的差异。
PACKAGE_EXE="$PACKAGE_DIST/respawn-stealth.exe"
direct_hash="$(sha256sum "$EXE" | awk '{print $1}')"
package_hash="$(sha256sum "$PACKAGE_EXE" | awk '{print $1}')"
if ! cmp -s "$EXE" "$PACKAGE_EXE"; then
    fail "相同源码连续构建结果不一致: direct=$direct_hash package=$package_hash"
fi
[[ "$direct_hash" == "$package_hash" ]] \
    || fail "逐字节相同但 SHA-256 异常不一致: direct=$direct_hash package=$package_hash"
cmp -s "$MANUFACTURER_PROJECTOR_EXE" \
    "$PACKAGE_BUILD/gpu-manufacturer-projector.exe" \
    || fail "相同源码连续构建的厂商投影器不一致"

# 显式 legacy 模式只供调试，但也必须平铺与 EXE 完全相同的 helper 和投影器；仅
# grep package.sh 中的文件名不足以证明 cp 真正执行，因此运行一次并逐字节比较。
INCLUDE_LEGACY_SCRIPTS=1 \
    "$PACKAGE_REPO/deploy/guest-stealth/package.sh" >/dev/null
cmp -s "$REPO_ROOT/deploy/guest-stealth/configure-power-policy.ps1" \
    "$PACKAGE_DIST/configure-power-policy.ps1" \
    || fail "legacy 调试包的电源 helper 与正式源不一致"
cmp -s "$REPO_ROOT/deploy/guest-stealth/respawn-restart-state.ps1" \
    "$PACKAGE_DIST/respawn-restart-state.ps1" \
    || fail "legacy 调试包的重启状态 helper 与正式源不一致"
cmp -s "$MANUFACTURER_HELPER" \
    "$PACKAGE_DIST/gpu-manufacturer-projection.ps1" \
    || fail "legacy 调试包的厂商投影 helper 与正式源不一致"
cmp -s "$PACKAGE_BUILD/gpu-manufacturer-projector.exe" \
    "$PACKAGE_DIST/gpu-manufacturer-projector.exe" \
    || fail "legacy 调试包的厂商投影器与本次受控构建不一致"
file "$PACKAGE_DIST/gpu-manufacturer-projector.exe" | grep -F 'PE32+ executable' >/dev/null \
    || fail "legacy 调试包的厂商投影器不是 Windows PE64 EXE"

# 非 0/1 的调试开关属于环境污染而不是显式授权，必须在清空上次正式 dist 之前失败。
# 失败后再次复核原 EXE 仍在，避免用户因一个拼写错误丢掉已验证发布物。
if INCLUDE_LEGACY_SCRIPTS=unexpected \
        "$PACKAGE_REPO/deploy/guest-stealth/package.sh" >/dev/null 2>&1; then
    fail "package.sh 错误接受了非法 INCLUDE_LEGACY_SCRIPTS"
fi
[[ -s "$PACKAGE_DIST/respawn-stealth.exe" ]] \
    || fail "非法调试开关在拒绝前破坏了既有正式 EXE"

# 构建器必须在编译前拒绝被改动的驱动，避免错误 CAT/SYS 组合进入发布物。
BAD_DRIVER_DIR="$TMP_DIR/tampered-driver"
cp -a "$REPO_ROOT/deploy/scripts/stock-viogpudo" "$BAD_DRIVER_DIR"
printf '\0' >> "$BAD_DRIVER_DIR/viogpudo.sys"
if DRIVER_SRC_DIR="$BAD_DRIVER_DIR" \
   OUT_DIR="$TMP_DIR/bad-out" \
   BUILD_DIR="$TMP_DIR/bad-build" \
       "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" >/dev/null 2>&1; then
    fail "构建器没有拒绝 SHA-256 不匹配的 viogpudo.sys"
fi

# 芯片组 INF/CAT 同样是签名闭包；任一原始字节变化都必须在 C 编译前失败。
BAD_CHIPSET_DIR="$TMP_DIR/tampered-chipset"
cp -a "$REPO_ROOT/deploy/scripts/stock-intel-chipset-inf" "$BAD_CHIPSET_DIR"
printf '\0' >> "$BAD_CHIPSET_DIR/CannonLake-HSystem.inf"
if CHIPSET_INF_SRC_DIR="$BAD_CHIPSET_DIR" \
   OUT_DIR="$TMP_DIR/bad-chipset-out" \
   BUILD_DIR="$TMP_DIR/bad-chipset-build" \
       "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" >/dev/null 2>&1; then
    fail "构建器没有拒绝 SHA-256 不匹配的 CannonLake-HSystem.inf"
fi

# 两种架构的 shim 都是完整发布输入；任一文件被改动时，构建器必须在生成 EXE
# 之前拒绝，不能只保护 64 位版本而让 32 位 GPU 工具加载未审计字节。
BAD_NVAPI_DIR="$TMP_DIR/tampered-nvapi"
cp -a "$REPO_ROOT/deploy/nvapi-shim" "$BAD_NVAPI_DIR"
printf '\0' >> "$BAD_NVAPI_DIR/nvapi.dll"
if NVAPI_SRC_DIR="$BAD_NVAPI_DIR" \
   OUT_DIR="$TMP_DIR/bad-nvapi-out" \
   BUILD_DIR="$TMP_DIR/bad-nvapi-build" \
       "$REPO_ROOT/deploy/guest-stealth/build-exe.sh" >/dev/null 2>&1; then
    fail "构建器没有拒绝 SHA-256 不匹配的 nvapi.dll"
fi

for source_file in \
        "$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c" \
        "$PAYLOAD_SECURITY" "$MANUFACTURER_HELPER" \
        "$MANUFACTURER_PROJECTOR_SOURCE"; do
    [[ "$(wc -l < "$source_file")" -le 500 ]] \
        || fail "生产源单文件超过 500 行: $source_file"
done

echo "OK: guest-stealth single EXE build checks passed"
