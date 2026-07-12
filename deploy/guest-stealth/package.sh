#!/usr/bin/env bash
# package.sh —— 在 host 上打一个**单 EXE**发布目录，供拷进客机后直接双击运行。
#
# 产物：deploy/guest-stealth/dist/
#   respawn-stealth.exe        <- 内嵌 respawn-stealth-local.ps1 + apply-gpu-spoof.ps1
#
# 用法：
#   bash deploy/guest-stealth/package.sh
#   -> 把 dist/respawn-stealth.exe 拷进客机任意位置，双击即可。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
DIST="$HERE/dist"

SPOOF_SRC="$SCRIPTS/apply-gpu-spoof.ps1"
[[ -f "$SPOOF_SRC" ]] || { echo "ERROR: 找不到 $SPOOF_SRC" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"

# 默认只发布一个 EXE。脚本版入口仍保留在源码目录，调试时可显式带上。
"$HERE/build-exe.sh"

if [[ "${INCLUDE_LEGACY_SCRIPTS:-0}" == "1" ]]; then
    cp "$HERE/respawn-stealth.bat"        "$DIST/"
    cp "$HERE/respawn-stealth-local.ps1"  "$DIST/"
    cp "$SPOOF_SRC"                       "$DIST/"
fi

echo ">> 已生成自带依赖的发布目录: $DIST"
ls -la "$DIST"
echo ""
echo "下一步：把 $DIST/respawn-stealth.exe 拷进客机（scp / 9p / 封 base 前放好），双击运行。"
