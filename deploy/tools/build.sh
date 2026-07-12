#!/bin/bash
# build.sh - 配置并构建基于 QEMU 11.0.2 的 vmate 源码树。
#
# 默认构建启用编译器警告即错误（--enable-werror）。如确需追加实验性
# configure 参数，继续使用既有 EXTRA_CONFIGURE 环境变量即可。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
EXPECTED_QEMU_VERSION="11.0.2"

CLEAN="${CLEAN:-0}"
RECONFIG="${RECONFIG:-0}"
DEBUG="${DEBUG:-0}"
JOBS="${JOBS:-$(nproc)}"
VERIFY="${VERIFY:-0}"

usage() {
    cat <<'EOF'
用法: deploy/tools/build.sh [选项]

选项（均保留对应环境变量用法）:
  --clean        / CLEAN=1       先删除 build/，执行全新构建
  --reconfig     / RECONFIG=1    保留 build/，但强制重跑 configure
  --debug        / DEBUG=1       启用调试信息并禁止 strip
  --jobs N       / JOBS=N        设置 ninja 并行度（默认 nproc）
  --verify       / VERIFY=1      构建后运行 verify-stealth.sh
  -h, --help                    显示本帮助

额外 configure 参数:
  EXTRA_CONFIGURE="--enable-foo" deploy/tools/build.sh
EOF
}

while (( $# )); do
    case "$1" in
        --clean)    CLEAN=1 ;;
        --reconfig) RECONFIG=1 ;;
        --debug)    DEBUG=1 ;;
        --verify)   VERIFY=1 ;;
        --jobs)     JOBS="$2"; shift ;;
        --jobs=*)   JOBS="${1#*=}" ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

cd "$REPO_ROOT"

# ---------- 源码版本预检 ----------
# 中文注释：构建脚本与定制设备参数以 11.0.2 为基线。这里显式拒绝其他源码
# 版本，避免误用旧 checkout 或把旧 build/ 产物当成升级后的 vmate。
source_version="$(tr -d '[:space:]' < VERSION)"
if [[ "$source_version" != "$EXPECTED_QEMU_VERSION" ]]; then
    echo "FAIL: 源码 VERSION=$source_version，期望 $EXPECTED_QEMU_VERSION" >&2
    echo "      请切换到正确的 vmate 分支后重新执行。" >&2
    exit 1
fi

# ---------- 基础依赖预检 ----------
missing_bin=()
for tool in ninja pkg-config python3; do
    command -v "$tool" >/dev/null 2>&1 || missing_bin+=("$tool")
done
missing_pkg=()
for pkg in glib-2.0 pixman-1; do
    pkg-config --exists "$pkg" 2>/dev/null || missing_pkg+=("$pkg")
done
if (( ${#missing_bin[@]} + ${#missing_pkg[@]} )); then
    echo "FAIL: 缺少依赖"
    (( ${#missing_bin[@]} )) && echo "  可执行文件: ${missing_bin[*]}"
    (( ${#missing_pkg[@]} )) && echo "  pkg-config: ${missing_pkg[*]}"
    echo "  修复: sudo apt install build-essential ninja-build pkg-config \\"
    echo "         python3-venv python3-pip libglib2.0-dev libpixman-1-dev \\"
    echo "         libsdl2-dev libspice-server-dev libvirglrenderer-dev libepoxy-dev \\"
    echo "         libslirp-dev libseccomp-dev ovmf"
    exit 1
fi

# ---------- QEMU 11 Python 构建依赖预检 ----------
# 中文注释：QEMU 11 configure 会创建 build/pyvenv，并从 pythondeps.toml
# 安装 qemu.qmp 等工具。venv/ensurepip 缺失会让虚拟环境创建失败；而
# setuptools 与 wheel 是 tooling 组的显式依赖，源码树没有内置这两个 wheel。
if ! python3 - <<'PY'
import importlib.util
import re
import sys
from importlib import metadata


def version_tuple(raw_version):
    """把常见发行版版本字符串转换为可比较的三段整数。"""
    parts = [int(item) for item in re.findall(r"\d+", raw_version)[:3]]
    return tuple((parts + [0, 0, 0])[:3])


errors = []
if importlib.util.find_spec("venv") is None:
    errors.append("缺少 Python venv 模块")
if (importlib.util.find_spec("ensurepip") is None and
        importlib.util.find_spec("pip") is None):
    errors.append("ensurepip 与 pip 均不可用，无法初始化构建虚拟环境")

requirements = {
    "setuptools": (44, 1, 1),
    "wheel": (0, 34, 2),
}
for package, minimum in requirements.items():
    try:
        installed = metadata.version(package)
    except metadata.PackageNotFoundError:
        errors.append(f"缺少 Python 包 {package}")
        continue
    if version_tuple(installed) < minimum:
        expected = ".".join(str(item) for item in minimum)
        errors.append(f"Python 包 {package}={installed}，最低要求 {expected}")

if errors:
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)
PY
then
    echo "FAIL: QEMU 11 Python 构建依赖不完整" >&2
    echo "  修复: sudo apt install python3-venv python3-pip \\" >&2
    echo "         python3-setuptools python3-wheel" >&2
    exit 1
fi

# ---------- vmate 定制状态提示（不强制） ----------
if ! grep -q 'Ryzen3-1200' target/i386/cpu.c 2>/dev/null; then
    echo ">> NOTE: 当前 11.0.2 源码未检测到 vmate Ryzen3-1200 定制。"
    echo ">>       历史 9.2 补丁不能直接重放；请切换到完整 vmate 分支。"
    echo ""
fi

# ---------- 构建目录 ----------
if (( CLEAN )); then
    echo ">> clean build/"
    rm -rf build
fi
mkdir -p build
cd build

CFG_FLAGS=(
    --target-list=x86_64-softmmu
    --enable-kvm
    --enable-slirp
    --enable-virtfs
    --enable-spice
    --enable-virglrenderer
    --enable-opengl
    --enable-sdl
    --enable-vnc
    --enable-werror
    --disable-docs
)
if (( DEBUG )); then
    CFG_FLAGS+=(--enable-debug --disable-strip)
fi
if [[ -n "${EXTRA_CONFIGURE:-}" ]]; then
    # 中文注释：保持历史接口的按空白拆分语义；额外参数放在默认参数之后，
    # 便于调用方覆盖非安全关键的 configure 选项。
    # shellcheck disable=SC2206
    CFG_FLAGS+=($EXTRA_CONFIGURE)
fi

if (( RECONFIG )) || [[ ! -f build.ninja ]]; then
    echo ">> configure ${CFG_FLAGS[*]}"
    ../configure "${CFG_FLAGS[@]}"
fi

echo ">> ninja -j$JOBS"
ninja -j"$JOBS"

BIN="$REPO_ROOT/build/qemu-system-x86_64"
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: $BIN 未生成" >&2
    exit 1
fi

echo
echo "=== build complete ==="
printf "  binary : %s\n"   "$BIN"
printf "  size   : %s\n"   "$(stat -c%s "$BIN" | numfmt --to=iec)"
printf "  sha256 : %s\n"   "$(sha256sum "$BIN" | awk '{print $1}')"
printf "  mtime  : %s\n"   "$(stat -c%y "$BIN")"

if (( VERIFY )); then
    echo
    echo "=== running verify-stealth.sh ==="
    "$HERE/../scripts/verify-stealth.sh"
fi
