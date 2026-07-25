#!/usr/bin/env bash
# package.sh —— 在 host 上生成详细模式和仅进度模式两个单文件 Windows EXE。
#
# 产物：deploy/guest-stealth/dist/
#   respawn-stealth.exe          <- 显示完整控制台输出
#   respawn-stealth-progress.exe <- 仅显示通用进度窗口
#
# 用法：
#   bash deploy/guest-stealth/package.sh
#   -> 按需要把任一 EXE 拷进客机任意位置，双击即可。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
DIST="$HERE/dist"
CONTROLLED_BUILD_DIR="$REPO_ROOT/build/guest-stealth-exe"
POWER_POLICY_SRC="$HERE/configure-power-policy.ps1"
RESTART_STATE_SRC="$HERE/respawn-restart-state.ps1"

SPOOF_SRC="$SCRIPTS/apply-gpu-spoof.ps1"
APPLY_SUPPORT_SRC="$SCRIPTS/gpu-spoof-apply-support.ps1"
BOARD_IDENTITY_CONTRACT_SRC="$SCRIPTS/gpu-board-identity-contract.ps1"
PROFILE_HELPER_SRC="$SCRIPTS/persist-gpu-profile.ps1"
TRANSACTION_HELPER_SRC="$SCRIPTS/gpu-profile-transaction.ps1"
REGISTRY_CORE_SRC="$SCRIPTS/gpu-profile-registry-core.ps1"
REFRESH_HELPER_SRC="$SCRIPTS/refresh-gpu-name.ps1"
MANUFACTURER_HELPER_SRC="$SCRIPTS/gpu-manufacturer-projection.ps1"
HARDWARE_ID_PLAN_SRC="$SCRIPTS/gpu-hardware-id-plan.ps1"
HARDWARE_ID_TRANSACTION_SRC="$SCRIPTS/gpu-hardware-id-transaction.ps1"
HARDWARE_ID_PROJECTOR_SRC="$SCRIPTS/project-gpu-hardware-id.ps1"
DISPLAY_HELPER_SRC="$SCRIPTS/force-displayfreq.ps1"
MONITOR_PROJECT_SRC="$HERE/project-monitor-identity.ps1"
DRIVER_SRC="$SCRIPTS/stock-viogpudo"
CHIPSET_INF_SRC="$SCRIPTS/stock-intel-chipset-inf"
NVAPI_SRC="$HERE/../nvapi-shim"
NVAPI_PROBE_SRC="$HERE/../nvapi-runtime-probe"
ADL_SRC="$HERE/../adl-shim"
[[ -f "$POWER_POLICY_SRC" ]] || { echo "ERROR: 找不到 $POWER_POLICY_SRC" >&2; exit 1; }
[[ -f "$RESTART_STATE_SRC" ]] || { echo "ERROR: 找不到 $RESTART_STATE_SRC" >&2; exit 1; }
[[ -f "$SPOOF_SRC" ]] || { echo "ERROR: 找不到 $SPOOF_SRC" >&2; exit 1; }
[[ -f "$APPLY_SUPPORT_SRC" ]] || { echo "ERROR: 找不到 $APPLY_SUPPORT_SRC" >&2; exit 1; }
[[ -f "$BOARD_IDENTITY_CONTRACT_SRC" ]] || { echo "ERROR: 找不到 $BOARD_IDENTITY_CONTRACT_SRC" >&2; exit 1; }
[[ -f "$PROFILE_HELPER_SRC" ]] || { echo "ERROR: 找不到 $PROFILE_HELPER_SRC" >&2; exit 1; }
[[ -f "$TRANSACTION_HELPER_SRC" ]] || { echo "ERROR: 找不到 $TRANSACTION_HELPER_SRC" >&2; exit 1; }
[[ -f "$REGISTRY_CORE_SRC" ]] || { echo "ERROR: 找不到 $REGISTRY_CORE_SRC" >&2; exit 1; }
[[ -f "$REFRESH_HELPER_SRC" ]] || { echo "ERROR: 找不到 $REFRESH_HELPER_SRC" >&2; exit 1; }
[[ -f "$MANUFACTURER_HELPER_SRC" ]] || { echo "ERROR: 找不到 $MANUFACTURER_HELPER_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_PLAN_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_PLAN_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_TRANSACTION_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_TRANSACTION_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_PROJECTOR_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_PROJECTOR_SRC" >&2; exit 1; }
[[ -f "$DISPLAY_HELPER_SRC" ]] || { echo "ERROR: 找不到 $DISPLAY_HELPER_SRC" >&2; exit 1; }
[[ -f "$MONITOR_PROJECT_SRC" ]] || { echo "ERROR: 找不到 $MONITOR_PROJECT_SRC" >&2; exit 1; }
[[ -d "$DRIVER_SRC" ]] || { echo "ERROR: 找不到 $DRIVER_SRC" >&2; exit 1; }
[[ -d "$CHIPSET_INF_SRC" ]] || { echo "ERROR: 找不到 $CHIPSET_INF_SRC" >&2; exit 1; }
[[ -f "$NVAPI_SRC/nvapi.dll" ]] || { echo "ERROR: 找不到 $NVAPI_SRC/nvapi.dll" >&2; exit 1; }
[[ -f "$NVAPI_SRC/nvapi64.dll" ]] || { echo "ERROR: 找不到 $NVAPI_SRC/nvapi64.dll" >&2; exit 1; }
[[ -f "$ADL_SRC/atiadlxy.dll" ]] || { echo "ERROR: 找不到 $ADL_SRC/atiadlxy.dll" >&2; exit 1; }
[[ -f "$ADL_SRC/atiadlxx.dll" ]] || { echo "ERROR: 找不到 $ADL_SRC/atiadlxx.dll" >&2; exit 1; }

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

# 正式发布不能继承调用终端里的 OUT_DIR/BUILD_DIR、厂商 API 或驱动源目录。
# 否则一个无关的旧环境变量就可能让 EXE 写到别处、让 dist 保持为空，package.sh
# 却仍打印“发布成功”；BUILD_DIR 还是 build-exe.sh 的 rm -rf 目标，更不能接受任意
# 外部路径。这里把四个目录全部钉到仓库受控位置，正式产物始终只落入本目录的 dist。
OUT_DIR="$DIST" \
BUILD_DIR="$CONTROLLED_BUILD_DIR" \
DRIVER_SRC_DIR="$DRIVER_SRC" \
CHIPSET_INF_SRC_DIR="$CHIPSET_INF_SRC" \
NVAPI_SRC_DIR="$NVAPI_SRC" \
NVAPI_PROBE_DIR="$NVAPI_PROBE_SRC" \
ADL_SRC_DIR="$ADL_SRC" \
    "$HERE/build-exe.sh"

if [[ "$include_legacy_scripts" == "1" ]]; then
    # 该分支仅供源码调试，不是正式 guest 交付物。必须由调用者显式选择 1；默认值
    # 永远是 0，避免把 PowerShell、驱动或 DLL 平铺副本误交给正式 guest。
    cp "$HERE/respawn-stealth-local.ps1"  "$DIST/"
    cp "$RESTART_STATE_SRC"               "$DIST/"
    cp "$POWER_POLICY_SRC"                "$DIST/"
    cp "$HERE/install-display-driver.ps1" "$DIST/"
    cp "$HERE/display-driver-trust.ps1" "$DIST/"
    cp "$HERE/install-chipset-device.ps1" "$DIST/"
    cp "$HERE/install-nvapi-system.ps1"    "$DIST/"
    cp "$HERE/nvapi-system-validation.ps1" "$DIST/"
    cp "$HERE/nvapi-system-transaction.ps1" "$DIST/"
    cp "$HERE/install-adl-system.ps1"      "$DIST/"
    cp "$HERE/adl-system-transaction.ps1" "$DIST/"
    cp "$HERE/install-gpu-api-system.ps1" "$DIST/"
    cp "$HERE/gpu-api-identity-binding.ps1" "$DIST/"
    cp "$SPOOF_SRC"                       "$DIST/"
    cp "$APPLY_SUPPORT_SRC"               "$DIST/"
    cp "$BOARD_IDENTITY_CONTRACT_SRC"      "$DIST/"
    cp "$PROFILE_HELPER_SRC"               "$DIST/"
    cp "$TRANSACTION_HELPER_SRC"           "$DIST/"
    cp "$REGISTRY_CORE_SRC"                "$DIST/"
    cp "$REFRESH_HELPER_SRC"               "$DIST/"
    cp "$MANUFACTURER_HELPER_SRC"          "$DIST/"
    cp "$CONTROLLED_BUILD_DIR/gpu-manufacturer-projector.exe" "$DIST/"
    cp "$HARDWARE_ID_PLAN_SRC"             "$DIST/"
    cp "$HARDWARE_ID_TRANSACTION_SRC"      "$DIST/"
    cp "$HARDWARE_ID_PROJECTOR_SRC"        "$DIST/"
    cp "$DISPLAY_HELPER_SRC"               "$DIST/"
    cp "$MONITOR_PROJECT_SRC"               "$DIST/"
    cp "$CONTROLLED_BUILD_DIR/monitor-identities.json" "$DIST/"
    cp "$CONTROLLED_BUILD_DIR/monitor-friendly-name-projector.exe" "$DIST/"
    cp "$DRIVER_SRC"/viogpudo.{sys,cat,inf} "$DIST/"
    chipset_files=(
        CannonLake-HSystem.inf cannonlake-h.cat
        SunrisePoint-HSystem.inf sunrisepoint-h.cat
        CougarPointSystem.inf cougarpoint.cat
        PantherPointSystem.inf pantherpoint.cat
        LynxPointSystem.inf lynxpoint.cat
    )
    for chipset_file in "${chipset_files[@]}"; do
        cp "$CHIPSET_INF_SRC/$chipset_file" "$DIST/"
    done
    cp "$NVAPI_SRC"/nvapi{,64}.dll          "$DIST/"
    cp "$NVAPI_PROBE_SRC"/nvapi-runtime-probe-x86.exe "$NVAPI_PROBE_SRC"/nvapi-runtime-probe-x64.exe "$DIST/"
    cp "$ADL_SRC/atiadlxy.dll"              "$DIST/"
    cp "$ADL_SRC/atiadlxy.dll"              "$DIST/atiadlxx32.dll"
    cp "$ADL_SRC/atiadlxx.dll"              "$DIST/"
else
    # “构建器退出 0”不等于“正式目录正确”。最后按实际目录内容做封闭式验收：只允许
    # 两个非空、名称精确的 EXE；任何旧脚本、调试 DLL、子目录或额外文件都让打包失败。
    mapfile -d '' -t release_entries < <(find "$DIST" -mindepth 1 -maxdepth 1 -print0)
    if [[ "${#release_entries[@]}" -ne 2 ||
          ! -f "$DIST/respawn-stealth.exe" ||
          -L "$DIST/respawn-stealth.exe" ||
          ! -s "$DIST/respawn-stealth.exe" ||
          ! -f "$DIST/respawn-stealth-progress.exe" ||
          -L "$DIST/respawn-stealth-progress.exe" ||
          ! -s "$DIST/respawn-stealth-progress.exe" ]]; then
        echo "ERROR: 正式 dist 必须且只能包含两个指定的非空 EXE" >&2
        find "$DIST" -mindepth 1 -maxdepth 1 -printf '  %f\n' >&2 || true
        exit 1
    fi
fi

echo ">> 已生成自带依赖的发布目录: $DIST"
ls -la "$DIST"
echo ""
echo "下一步：按需要把以下任一文件拷进客机并双击运行："
echo "  详细模式：$DIST/respawn-stealth.exe"
echo "  仅进度模式：$DIST/respawn-stealth-progress.exe"
