#!/usr/bin/env bash
# 把 guest 侧 DNF Microsoft 运行库安装脚本封装成独立 Windows PE64 EXE。
set -euo pipefail

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
if ! [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SOURCE_DATE_EPOCH 必须是非负整数" >&2
    exit 1
fi
export SOURCE_DATE_EPOCH TZ=UTC LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="$HERE/launcher"
COMMON="$REPO_ROOT/deploy/guest-launcher-common"
PS1_SRC="$REPO_ROOT/deploy/scripts/guest/dnf-fix-deps.ps1"
INSTALLERS_PS1_SRC="$REPO_ROOT/deploy/scripts/guest/dnf-fix-installers.ps1"
DIRECTX_PS1_SRC="$REPO_ROOT/deploy/scripts/guest/dnf-fix-directx.ps1"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/guest-dnf-deps-exe}"
OUT_DIR="${OUT_DIR:-$HERE/dist}"
OUT_EXE="$OUT_DIR/dnf-fix-deps.exe"

need_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: 缺少构建工具: $1" >&2
        exit 1
    }
}

for tool in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-windres \
        x86_64-w64-mingw32-objdump xxd convert file llvm-readobj sha256sum \
        awk mktemp; do
    need_tool "$tool"
done

for source in \
        "$PS1_SRC" \
        "$INSTALLERS_PS1_SRC" \
        "$DIRECTX_PS1_SRC" \
        "$LAUNCHER/dnf-fix-deps-launcher.c" \
        "$LAUNCHER/launcher-arguments.c" \
        "$LAUNCHER/dnf-fix-deps.exe.manifest" \
        "$COMMON/payload-security.c" \
        "$COMMON/payload-environment.c"; do
    [[ -f "$source" ]] || {
        echo "ERROR: 找不到构建输入: $source" >&2
        exit 1
    }
done

case "$BUILD_DIR" in
    ""|/|.) echo "ERROR: BUILD_DIR 不能是空值、/ 或当前目录" >&2; exit 1 ;;
esac
if [[ -L "$BUILD_DIR" ]]; then
    echo "ERROR: BUILD_DIR 不能是符号链接" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$OUT_DIR"
WORK_DIR="$(mktemp -d "$BUILD_DIR/.dnf-fix-deps-build.XXXXXXXX")"
cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

# 只嵌入 PowerShell 安装逻辑；Microsoft 安装器仍在运行时下载并验签。
xxd -i -n payload_dnf_fix_deps_ps1 "$PS1_SRC" \
    >"$WORK_DIR/payload_dnf_fix_deps_ps1.h"
xxd -i -n payload_dnf_fix_installers_ps1 "$INSTALLERS_PS1_SRC" \
    >"$WORK_DIR/payload_dnf_fix_installers_ps1.h"
xxd -i -n payload_dnf_fix_directx_ps1 "$DIRECTX_PS1_SRC" \
    >"$WORK_DIR/payload_dnf_fix_directx_ps1.h"

make_icon_png() {
    local size="$1"
    local output="$2"
    local center=$((size / 2))
    local radius=$((size * 43 / 100))
    local bar=$((size / 9))
    local inset=$((size / 4))

    [[ "$bar" -lt 2 ]] && bar=2
    convert -size "${size}x${size}" xc:none \
        -fill '#0b5cad' \
        -draw "circle ${center},${center} ${center},$((center-radius))" \
        -fill '#ffffff' \
        -draw "roundrectangle ${inset},$((center-bar/2)) $((size-inset)),$((center+bar/2)) $bar,$bar" \
        -draw "roundrectangle $((center-bar/2)),${inset} $((center+bar/2)),$((size-inset)) $bar,$bar" \
        -fill '#f5c542' \
        -draw "circle $((size*73/100)),$((size*27/100)) $((size*73/100)),$((size*18/100))" \
        -strip "$output"
}

for size in 16 32 48 64 128 256; do
    make_icon_png "$size" "$WORK_DIR/icon-${size}.png"
done
convert "$WORK_DIR"/icon-*.png -strip "$WORK_DIR/dnf-fix-deps.ico"

cat >"$WORK_DIR/dnf-fix-deps.generated.rc" <<EOF
#define CREATEPROCESS_MANIFEST_RESOURCE_ID 1
#define RT_MANIFEST 24
#define IDI_APP_ICON 101

IDI_APP_ICON ICON "$WORK_DIR/dnf-fix-deps.ico"
CREATEPROCESS_MANIFEST_RESOURCE_ID RT_MANIFEST "$LAUNCHER/dnf-fix-deps.exe.manifest"
EOF

x86_64-w64-mingw32-windres \
    -I "$LAUNCHER" \
    -I "$WORK_DIR" \
    -O coff \
    "$WORK_DIR/dnf-fix-deps.generated.rc" \
    "$WORK_DIR/dnf-fix-deps.res"

x86_64-w64-mingw32-gcc \
    -std=c11 -Wall -Wextra -Werror -O2 \
    -municode -mconsole -static -static-libgcc \
    -Wl,--no-insert-timestamp \
    -I "$WORK_DIR" -I "$LAUNCHER" -I "$COMMON" \
    "$LAUNCHER/dnf-fix-deps-launcher.c" \
    "$LAUNCHER/launcher-arguments.c" \
    "$COMMON/payload-security.c" \
    "$COMMON/payload-environment.c" \
    "$WORK_DIR/dnf-fix-deps.res" \
    -lshell32 -ladvapi32 -luser32 \
    -o "$OUT_EXE"

file "$OUT_EXE" | grep -F 'PE32+ executable' >/dev/null || {
    echo "ERROR: 输出不是 Windows PE64 EXE" >&2
    exit 1
}
llvm-readobj --file-headers "$OUT_EXE" \
    | grep -F 'TimeDateStamp: 1970-01-01 00:00:00 (0x0)' >/dev/null || {
    echo "ERROR: PE/COFF 时间戳不是 0" >&2
    exit 1
}
x86_64-w64-mingw32-objdump -x "$OUT_EXE" >"$WORK_DIR/objdump.txt"
awk '
    /Entry: ID: 0x000018,/ {
        getline
        getline
        if ($0 ~ /Entry: ID: 0x000001,/) {
            found = 1
        }
    }
    END { exit found ? 0 : 1 }
' "$WORK_DIR/objdump.txt" || {
    echo "ERROR: EXE 缺少 UAC manifest id 1 资源" >&2
    exit 1
}

echo ">> 已生成独立 DNF 依赖安装器: $OUT_EXE"
echo ">> SHA-256: $(sha256sum "$OUT_EXE" | awk '{print $1}')"
