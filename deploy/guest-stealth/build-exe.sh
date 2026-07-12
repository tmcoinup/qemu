#!/usr/bin/env bash
# build-exe.sh —— 把 guest-stealth 本地重对齐流程打成单文件 Windows EXE。
#
# 设计目标：
#   1. 用户只需要把 respawn-stealth.exe 拷进 guest，不能再要求旁边带 .ps1/.bat。
#   2. EXE 带 requireAdministrator manifest，双击时由 Windows 直接弹 UAC。
#   3. PowerShell payload 从仓库真源即时嵌入，避免 dist 里的脚本副本长期漂移。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="$HERE/launcher"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/guest-stealth-exe}"
OUT_DIR="${OUT_DIR:-$HERE/dist}"
OUT_EXE="$OUT_DIR/respawn-stealth.exe"

RESPAWN_SRC="$HERE/respawn-stealth-local.ps1"
SPOOF_SRC="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
SRC="$LAUNCHER/respawn-stealth-launcher.c"
MANIFEST="$LAUNCHER/respawn-stealth.exe.manifest"

need_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: 缺少构建工具: $1" >&2
        exit 1
    }
}

need_tool x86_64-w64-mingw32-gcc
need_tool x86_64-w64-mingw32-windres
need_tool xxd
need_tool convert

[[ -f "$RESPAWN_SRC" ]] || { echo "ERROR: 找不到 $RESPAWN_SRC" >&2; exit 1; }
[[ -f "$SPOOF_SRC" ]]   || { echo "ERROR: 找不到 $SPOOF_SRC" >&2; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

# 生成一个自带盾牌的 EXE 图标。Windows 的 UAC overlay 在内置 Administrator /
# UAC 关闭 / 图标缓存未刷新时可能不显示，所以发布物直接内嵌盾牌图标。
make_icon_png() {
    local size="$1"
    local out="$2"
    local cx=$((size / 2))
    local top=$((size * 7 / 100))
    local left=$((size * 18 / 100))
    local right=$((size * 82 / 100))
    local shoulder_y=$((size * 20 / 100))
    local mid_y=$((size * 56 / 100))
    local bottom=$((size * 91 / 100))
    local stroke=$((size / 18))
    local inset=$((size / 9))

    [[ "$stroke" -lt 2 ]] && stroke=2

    convert -size "${size}x${size}" xc:none \
        -fill '#101820' \
        -draw "polygon ${cx},${top} ${right},${shoulder_y} $((right-inset/2)),${mid_y} ${cx},${bottom} $((left+inset/2)),${mid_y} ${left},${shoulder_y}" \
        -fill '#1f6feb' \
        -draw "polygon ${cx},$((top+stroke)) $((right-stroke)),$((shoulder_y+stroke)) ${cx},$((mid_y-stroke/2)) ${cx},$((top+stroke))" \
        -fill '#f5c542' \
        -draw "polygon $((left+stroke)),$((shoulder_y+stroke)) ${cx},$((top+stroke)) ${cx},$((mid_y-stroke/2)) $((left+inset)),$((mid_y-stroke))" \
        -fill '#f5c542' \
        -draw "polygon ${cx},$((mid_y+stroke/2)) $((right-inset)),$((mid_y-stroke)) $((right-inset)),${mid_y} ${cx},$((bottom-stroke))" \
        -fill '#1f6feb' \
        -draw "polygon $((left+inset)),${mid_y} ${cx},$((mid_y+stroke/2)) ${cx},$((bottom-stroke)) $((left+inset)),$((mid_y-stroke))" \
        -fill 'rgba(255,255,255,0.72)' \
        -draw "rectangle $((cx-stroke/2)),$((top+stroke*2)) $((cx+stroke/2)),$((bottom-stroke*3))" \
        -draw "rectangle $((left+inset)),$((mid_y-stroke/2)) $((right-inset)),$((mid_y+stroke/2))" \
        "$out"
}

for size in 16 32 48 64 128 256; do
    make_icon_png "$size" "$BUILD_DIR/icon-${size}.png"
done
convert "$BUILD_DIR"/icon-*.png "$BUILD_DIR/respawn-stealth.ico"

# xxd 生成 C header，保留原始 UTF-8/BOM 字节；EXE 运行时原样释放脚本。
xxd -i -n payload_respawn_ps1 "$RESPAWN_SRC" \
    > "$BUILD_DIR/payload_respawn_ps1.h"
xxd -i -n payload_apply_gpu_spoof_ps1 "$SPOOF_SRC" \
    > "$BUILD_DIR/payload_apply_gpu_spoof_ps1.h"

# Windows 资源里嵌入 UAC manifest；windres 的相对路径以 launcher 目录为基准。
cat > "$BUILD_DIR/respawn-stealth.generated.rc" <<EOF
#define CREATEPROCESS_MANIFEST_RESOURCE_ID 1
#define RT_MANIFEST 24
#define IDI_APP_ICON 101

IDI_APP_ICON ICON "$BUILD_DIR/respawn-stealth.ico"
CREATEPROCESS_MANIFEST_RESOURCE_ID RT_MANIFEST "$MANIFEST"
EOF

x86_64-w64-mingw32-windres \
    -I "$LAUNCHER" \
    -I "$BUILD_DIR" \
    -O coff \
    "$BUILD_DIR/respawn-stealth.generated.rc" \
    "$BUILD_DIR/respawn-stealth.res"

x86_64-w64-mingw32-gcc \
    -std=c11 \
    -Wall -Wextra -Werror \
    -O2 \
    -municode \
    -mconsole \
    -static \
    -static-libgcc \
    -I "$BUILD_DIR" \
    "$SRC" \
    "$BUILD_DIR/respawn-stealth.res" \
    -lshell32 -ladvapi32 -luser32 \
    -o "$OUT_EXE"

echo ">> 已生成单文件 guest 入口: $OUT_EXE"
