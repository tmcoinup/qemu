#!/usr/bin/env bash
# package.sh —— 在 host 上打一个**完全自带依赖**的发布目录，供拷进客机后
# 不依赖 C:\stealth 就能跑。
#
# 产物：deploy/guest-stealth/dist/
#   respawn-stealth.bat
#   respawn-stealth-local.ps1
#   apply-gpu-spoof.ps1        <- 从 deploy/scripts/ 拷进来（保持单一真源，不在仓库里留副本）
#
# 用法：
#   bash deploy/guest-stealth/package.sh
#   -> 把 dist/ 整个目录拷进客机任意位置，双击 respawn-stealth.bat 即可。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
DIST="$HERE/dist"

SPOOF_SRC="$SCRIPTS/apply-gpu-spoof.ps1"
[[ -f "$SPOOF_SRC" ]] || { echo "ERROR: 找不到 $SPOOF_SRC" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
cp "$HERE/respawn-stealth.bat"        "$DIST/"
cp "$HERE/respawn-stealth-local.ps1"  "$DIST/"
cp "$SPOOF_SRC"                       "$DIST/"

echo ">> 已生成自带依赖的发布目录: $DIST"
ls -la "$DIST"
echo ""
echo "下一步：把 $DIST 整个拷进客机（scp / 9p / 封 base 前放好），双击 respawn-stealth.bat。"
