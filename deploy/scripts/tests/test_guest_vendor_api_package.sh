#!/usr/bin/env bash
# 验证单 EXE/legacy 发布同时携带 NVIDIA+AMD 五个系统目标的可信源 payload。
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
PACKAGE="$REPO_ROOT/deploy/guest-stealth/package.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
NVAPI_DIR="$REPO_ROOT/deploy/nvapi-shim"
ADL_DIR="$REPO_ROOT/deploy/adl-shim"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$BUILD_SCRIPT" "$PACKAGE" "$LAUNCHER" \
        "$NVAPI_DIR/nvapi.dll" "$NVAPI_DIR/nvapi64.dll" \
        "$ADL_DIR/atiadlxy.dll" "$ADL_DIR/atiadlxx.dll"; do
    [[ -f "$path" ]] || fail "缺少统一厂商 API package 文件：$path"
done

for helper in install-nvapi-system.ps1 nvapi-system-transaction.ps1 \
        install-adl-system.ps1 adl-system-transaction.ps1 \
        install-gpu-api-system.ps1; do
    grep -F "$helper" "$BUILD_SCRIPT" >/dev/null \
        || fail "build-exe 未嵌入 helper：$helper"
    grep -F "$helper" "$LAUNCHER" >/dev/null \
        || fail "launcher 未发布 helper：$helper"
    grep -F "$helper" "$PACKAGE" >/dev/null \
        || fail "legacy package 未平铺 helper：$helper"
done

# 五个系统目标源名称必须全部进入 launcher 表；两个 AMD x86 别名刻意复用同一
# 已验摘要数组，不能在 package 阶段复制出未验证的第三份源。
for payload in nvapi.dll nvapi64.dll atiadlxy.dll atiadlxx32.dll atiadlxx.dll; do
    [[ "$(grep -Fc "L\"$payload\"" "$LAUNCHER")" -eq 1 ]] \
        || fail "launcher 的系统目标 payload 不唯一：$payload"
    grep -F "$payload" "$PACKAGE" >/dev/null \
        || fail "legacy package 缺少系统目标源：$payload"
done
grep -F '{ L"atiadlxy.dll", payload_adl_x86_dll,' "$LAUNCHER" >/dev/null \
    || fail "atiadlxy 没有绑定受验 x86 ADL 数组"
grep -F '{ L"atiadlxx32.dll", payload_adl_x86_dll,' "$LAUNCHER" >/dev/null \
    || fail "atiadlxx32 没有复用受验 x86 ADL 数组"
grep -F '{ L"atiadlxx.dll", payload_adl_x64_dll,' "$LAUNCHER" >/dev/null \
    || fail "atiadlxx 没有绑定受验 x64 ADL 数组"

grep -F 'ADL_SRC_DIR="${ADL_SRC_DIR:-$REPO_ROOT/deploy/adl-shim}"' \
    "$BUILD_SCRIPT" >/dev/null || fail "独立 build 没有正式 ADL 默认真源"
grep -F 'ADL_SRC="$HERE/../adl-shim"' "$PACKAGE" >/dev/null \
    || fail "package 没有从仓库相对路径解析 ADL 真源"
grep -F 'ADL_SRC_DIR="$ADL_SRC"' "$PACKAGE" >/dev/null \
    || fail "正式 package 没有覆盖外部 ADL_SRC_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 在隔离仓库副本走正式 package 入口，并故意污染 ADL_SRC_DIR。正式脚本必须覆盖
# 外部变量、从仓库相对真源构建，且不在 poison 目录留下任何旁路产物。
PACKAGE_REPO="$TMP_DIR/package-repo"
mkdir -p "$PACKAGE_REPO/deploy"
cp -a "$REPO_ROOT/deploy/guest-stealth" "$PACKAGE_REPO/deploy/guest-stealth"
rm -rf "$PACKAGE_REPO/deploy/guest-stealth/dist"
ln -s "$REPO_ROOT/deploy/scripts" "$PACKAGE_REPO/deploy/scripts"
ln -s "$NVAPI_DIR" "$PACKAGE_REPO/deploy/nvapi-shim"
ln -s "$ADL_DIR" "$PACKAGE_REPO/deploy/adl-shim"
ADL_SRC_DIR="$TMP_DIR/poison-adl" \
OUT_DIR="$TMP_DIR/poison-out" BUILD_DIR="$TMP_DIR/poison-build" \
    "$PACKAGE_REPO/deploy/guest-stealth/package.sh" >/dev/null
EXE="$PACKAGE_REPO/deploy/guest-stealth/dist/respawn-stealth.exe"
mapfile -d '' -t release_entries < <(
    find "$(dirname "$EXE")" -mindepth 1 -maxdepth 1 -print0
)
[[ "${#release_entries[@]}" -eq 1 && "${release_entries[0]}" == "$EXE" &&
   -s "$EXE" ]] || fail "正式 package 没有生成严格单 EXE"
[[ ! -e "$TMP_DIR/poison-adl" && ! -e "$TMP_DIR/poison-out" &&
   ! -e "$TMP_DIR/poison-build" ]] \
    || fail "正式 package 继承了外部 ADL/输出目录"

for helper in install-nvapi-system.ps1 nvapi-system-transaction.ps1 \
        install-adl-system.ps1 adl-system-transaction.ps1 \
        install-gpu-api-system.ps1; do
    strings -a "$EXE" | grep -F "$helper" >/dev/null \
        || fail "EXE 没有实际包含 helper 文件名：$helper"
done
for payload in nvapi.dll nvapi64.dll atiadlxy.dll atiadlxx32.dll atiadlxx.dll; do
    strings -a -el "$EXE" | grep -F "$payload" >/dev/null \
        || fail "EXE launcher 没有实际包含目标名：$payload"
done

# 文件名只能证明释放表存在；完整原始 DLL 字节作为 PE 子串才证明 xxd/编译链没有
# 截断、转码或从环境污染目录读取另一份二进制。
python3 - "$EXE" "$NVAPI_DIR" "$ADL_DIR" \
    "$REPO_ROOT/deploy/guest-stealth" <<'PY'
from pathlib import Path
import sys

exe = Path(sys.argv[1]).read_bytes()
payloads = (
    Path(sys.argv[2]) / "nvapi.dll",
    Path(sys.argv[2]) / "nvapi64.dll",
    Path(sys.argv[3]) / "atiadlxy.dll",
    Path(sys.argv[3]) / "atiadlxx.dll",
    Path(sys.argv[4]) / "install-nvapi-system.ps1",
    Path(sys.argv[4]) / "nvapi-system-transaction.ps1",
    Path(sys.argv[4]) / "install-adl-system.ps1",
    Path(sys.argv[4]) / "adl-system-transaction.ps1",
    Path(sys.argv[4]) / "install-gpu-api-system.ps1",
)
for path in payloads:
    raw = path.read_bytes()
    if exe.count(raw) != 1:
        raise SystemExit(
            f"FAIL: EXE 中原始厂商 API payload 出现次数不是 1：{path.name}"
        )
PY

echo "OK: unified vendor API build, launcher and package payload closure passed"
