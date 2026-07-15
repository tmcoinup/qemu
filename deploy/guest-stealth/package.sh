#!/usr/bin/env bash
# package.sh —— 在 host 上打一个**单 EXE**发布目录，供拷进客机后直接双击运行。
#
# 产物：deploy/guest-stealth/dist/
#   respawn-stealth.exe        <- 内嵌显示驱动、双架构系统 NVAPI + 初始化脚本
#
# 用法：
#   bash deploy/guest-stealth/package.sh
#   -> 把 dist/respawn-stealth.exe 拷进客机任意位置，双击即可。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
DIST="$HERE/dist"
CONTROLLED_BUILD_DIR="$REPO_ROOT/build/guest-stealth-exe"
POWER_POLICY_SRC="$HERE/configure-power-policy.ps1"

SPOOF_SRC="$SCRIPTS/apply-gpu-spoof.ps1"
PROFILE_HELPER_SRC="$SCRIPTS/persist-gpu-profile.ps1"
TRANSACTION_HELPER_SRC="$SCRIPTS/gpu-profile-transaction.ps1"
REFRESH_HELPER_SRC="$SCRIPTS/refresh-gpu-name.ps1"
HARDWARE_ID_PLAN_SRC="$SCRIPTS/gpu-hardware-id-plan.ps1"
HARDWARE_ID_PROJECTOR_SRC="$SCRIPTS/project-gpu-hardware-id.ps1"
DISPLAY_HELPER_SRC="$SCRIPTS/force-displayfreq.ps1"
DRIVER_SRC="$SCRIPTS/stock-viogpudo"
NVAPI_SRC="$HERE/../nvapi-shim"
[[ -f "$POWER_POLICY_SRC" ]] || { echo "ERROR: 找不到 $POWER_POLICY_SRC" >&2; exit 1; }
[[ -f "$SPOOF_SRC" ]] || { echo "ERROR: 找不到 $SPOOF_SRC" >&2; exit 1; }
[[ -f "$PROFILE_HELPER_SRC" ]] || { echo "ERROR: 找不到 $PROFILE_HELPER_SRC" >&2; exit 1; }
[[ -f "$TRANSACTION_HELPER_SRC" ]] || { echo "ERROR: 找不到 $TRANSACTION_HELPER_SRC" >&2; exit 1; }
[[ -f "$REFRESH_HELPER_SRC" ]] || { echo "ERROR: 找不到 $REFRESH_HELPER_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_PLAN_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_PLAN_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_PROJECTOR_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_PROJECTOR_SRC" >&2; exit 1; }
[[ -f "$DISPLAY_HELPER_SRC" ]] || { echo "ERROR: 找不到 $DISPLAY_HELPER_SRC" >&2; exit 1; }
[[ -d "$DRIVER_SRC" ]] || { echo "ERROR: 找不到 $DRIVER_SRC" >&2; exit 1; }
[[ -f "$NVAPI_SRC/nvapi.dll" ]] || { echo "ERROR: 找不到 $NVAPI_SRC/nvapi.dll" >&2; exit 1; }
[[ -f "$NVAPI_SRC/nvapi64.dll" ]] || { echo "ERROR: 找不到 $NVAPI_SRC/nvapi64.dll" >&2; exit 1; }

include_legacy_scripts="${INCLUDE_LEGACY_SCRIPTS:-0}"
case "$include_legacy_scripts" in
    0|1) ;;
    *)
        # 在清空既有 dist 之前拒绝拼写错误，避免一次错误的调试开关毁掉上次
        # 已验证正式包。只有精确的 1 才表示调用者明确要求生成平铺调试包。
        echo "ERROR: INCLUDE_LEGACY_SCRIPTS 只能是 0（正式单文件）或 1（显式调试包）" >&2
        exit 1
        ;;
esac

rm -rf "$DIST"
mkdir -p "$DIST"

# 正式发布不能继承调用终端里的 OUT_DIR/BUILD_DIR/NVAPI_SRC_DIR/DRIVER_SRC_DIR。
# 否则一个无关的旧环境变量就可能让 EXE 写到别处、让 dist 保持为空，package.sh
# 却仍打印“发布成功”；BUILD_DIR 还是 build-exe.sh 的 rm -rf 目标，更不能接受任意
# 外部路径。这里把四个目录全部钉到仓库受控位置，正式产物始终只落入本目录的 dist。
OUT_DIR="$DIST" \
BUILD_DIR="$CONTROLLED_BUILD_DIR" \
DRIVER_SRC_DIR="$DRIVER_SRC" \
NVAPI_SRC_DIR="$NVAPI_SRC" \
    "$HERE/build-exe.sh"

if [[ "$include_legacy_scripts" == "1" ]]; then
    # 该分支仅供源码调试，不是正式 guest 交付物。必须由调用者显式选择 1；默认值
    # 永远是 0，避免把 PowerShell、驱动或 DLL 平铺副本误交给正式 guest。
    cp "$HERE/respawn-stealth-local.ps1"  "$DIST/"
    cp "$POWER_POLICY_SRC"                "$DIST/"
    cp "$HERE/install-display-driver.ps1" "$DIST/"
    cp "$HERE/install-nvapi-system.ps1"    "$DIST/"
    cp "$HERE/nvapi-system-transaction.ps1" "$DIST/"
    cp "$SPOOF_SRC"                       "$DIST/"
    cp "$PROFILE_HELPER_SRC"               "$DIST/"
    cp "$TRANSACTION_HELPER_SRC"           "$DIST/"
    cp "$REFRESH_HELPER_SRC"               "$DIST/"
    cp "$HARDWARE_ID_PLAN_SRC"             "$DIST/"
    cp "$HARDWARE_ID_PROJECTOR_SRC"        "$DIST/"
    cp "$DISPLAY_HELPER_SRC"               "$DIST/"
    cp "$DRIVER_SRC"/viogpudo.{sys,cat,inf} "$DIST/"
    cp "$NVAPI_SRC"/nvapi{,64}.dll          "$DIST/"
else
    # “构建器退出 0”不等于“正式目录正确”。最后按实际目录内容做封闭式验收：只允许
    # 一个非空、名称精确的 EXE；任何旧脚本、调试 DLL、子目录或额外文件都让打包失败。
    mapfile -d '' -t release_entries < <(find "$DIST" -mindepth 1 -maxdepth 1 -print0)
    if [[ "${#release_entries[@]}" -ne 1 ||
          "${release_entries[0]}" != "$DIST/respawn-stealth.exe" ||
          ! -f "$DIST/respawn-stealth.exe" ||
          -L "$DIST/respawn-stealth.exe" ||
          ! -s "$DIST/respawn-stealth.exe" ]]; then
        echo "ERROR: 正式 dist 必须且只能包含一个非空 respawn-stealth.exe" >&2
        find "$DIST" -mindepth 1 -maxdepth 1 -printf '  %f\n' >&2 || true
        exit 1
    fi
fi

echo ">> 已生成自带依赖的发布目录: $DIST"
ls -la "$DIST"
echo ""
echo "下一步：把 $DIST/respawn-stealth.exe 拷进客机（scp / 9p / 封 base 前放好），双击运行。"
