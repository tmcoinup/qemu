#!/usr/bin/env bash
# build-exe.sh —— 把 guest-stealth 本地重对齐流程打成单文件 Windows EXE。
#
# 设计目标：
#   1. 用户只需要把 respawn-stealth.exe 拷进 guest，不能再要求旁边带 .ps1/.bat。
#   2. EXE 带 requireAdministrator manifest，双击时由 Windows 直接弹 UAC。
#   3. 脚本与 stock 驱动从仓库真源即时嵌入，避免 dist 副本长期漂移或 CAT/SYS 混版。
set -euo pipefail

# 可复现构建不能继承当前时间、时区或本机语言环境。SOURCE_DATE_EPOCH 允许发布流水线
# 指定自己的纪元；本地直接运行时使用 Unix epoch。最终 PE 仍通过链接器参数把 COFF
# 时间戳写成 0，这个环境变量主要约束 ImageMagick 等可能读取构建时间的辅助工具。
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SOURCE_DATE_EPOCH 必须是非负整数: $SOURCE_DATE_EPOCH" >&2
    exit 1
fi
export SOURCE_DATE_EPOCH
export TZ=UTC
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LAUNCHER="$HERE/launcher"
LAUNCHER_COMMON="$REPO_ROOT/deploy/guest-launcher-common"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/guest-stealth-exe}"
OUT_DIR="${OUT_DIR:-$HERE/dist}"
OUT_EXE="$OUT_DIR/respawn-stealth.exe"

RESPAWN_SRC="$HERE/respawn-stealth-local.ps1"
RESTART_STATE_SRC="$HERE/respawn-restart-state.ps1"
POWER_POLICY_SRC="$HERE/configure-power-policy.ps1"
SPOOF_SRC="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
APPLY_SUPPORT_SRC="$REPO_ROOT/deploy/scripts/gpu-spoof-apply-support.ps1"
PROFILE_HELPER_SRC="$REPO_ROOT/deploy/scripts/persist-gpu-profile.ps1"
TRANSACTION_HELPER_SRC="$REPO_ROOT/deploy/scripts/gpu-profile-transaction.ps1"
REGISTRY_CORE_SRC="$REPO_ROOT/deploy/scripts/gpu-profile-registry-core.ps1"
REFRESH_HELPER_SRC="$REPO_ROOT/deploy/scripts/refresh-gpu-name.ps1"
MANUFACTURER_HELPER_SRC="$REPO_ROOT/deploy/scripts/gpu-manufacturer-projection.ps1"
HARDWARE_ID_PLAN_SRC="$REPO_ROOT/deploy/scripts/gpu-hardware-id-plan.ps1"
HARDWARE_ID_PROJECTOR_SRC="$REPO_ROOT/deploy/scripts/project-gpu-hardware-id.ps1"
DISPLAY_HELPER_SRC="$REPO_ROOT/deploy/scripts/force-displayfreq.ps1"
DRIVER_INSTALL_SRC="$HERE/install-display-driver.ps1"
DRIVER_TRUST_SRC="$HERE/display-driver-trust.ps1"
CHIPSET_INSTALL_SRC="$HERE/install-chipset-device.ps1"
NVAPI_INSTALL_SRC="$HERE/install-nvapi-system.ps1"
NVAPI_VALIDATION_SRC="$HERE/nvapi-system-validation.ps1"
NVAPI_TRANSACTION_SRC="$HERE/nvapi-system-transaction.ps1"
ADL_INSTALL_SRC="$HERE/install-adl-system.ps1"
ADL_TRANSACTION_SRC="$HERE/adl-system-transaction.ps1"
GPU_API_INSTALL_SRC="$HERE/install-gpu-api-system.ps1"
GPU_API_IDENTITY_BINDING_SRC="$HERE/gpu-api-identity-binding.ps1"
DRIVER_SRC_DIR="${DRIVER_SRC_DIR:-$REPO_ROOT/deploy/scripts/stock-viogpudo}"
CHIPSET_INF_SRC_DIR="${CHIPSET_INF_SRC_DIR:-$REPO_ROOT/deploy/scripts/stock-intel-chipset-inf}"
NVAPI_SRC_DIR="${NVAPI_SRC_DIR:-$REPO_ROOT/deploy/nvapi-shim}"
ADL_SRC_DIR="${ADL_SRC_DIR:-$REPO_ROOT/deploy/adl-shim}"
ADL_EXPORTS_SRC="$ADL_SRC_DIR/adl-required-exports.txt"
SRC="$LAUNCHER/respawn-stealth-launcher.c"
PAYLOAD_SECURITY_SRC="$LAUNCHER_COMMON/payload-security.c"
PAYLOAD_ENVIRONMENT_SRC="$LAUNCHER_COMMON/payload-environment.c"
LAUNCHER_ARGUMENTS_SRC="$LAUNCHER/launcher-arguments.c"
MANUFACTURER_PROJECTOR_SRC="$LAUNCHER/gpu-manufacturer-projector.c"
MANIFEST="$LAUNCHER/respawn-stealth.exe.manifest"

NVAPI_X86_SHA256="8ee7248f802b960b971724bdadb789492685b9c76fde0ac99f954768431972af"
NVAPI_X64_SHA256="e5f446439bc8c5a86d3aac13adb1090d4bd74055a4ccd1f884ca631aa56132ab"
ADL_X86_SHA256="86aca99433da976135f68b4b2904c04eaee370d97104b5a1622ad59f8731b1dd"
ADL_X64_SHA256="99b7e84b404bfa5140218549b4a49d68ebdfddb181ad9fdd72dcac296d799a62"

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
need_tool llvm-readobj

[[ -f "$RESPAWN_SRC" ]] || { echo "ERROR: 找不到 $RESPAWN_SRC" >&2; exit 1; }
[[ -f "$RESTART_STATE_SRC" ]] || { echo "ERROR: 找不到 $RESTART_STATE_SRC" >&2; exit 1; }
[[ -f "$POWER_POLICY_SRC" ]] || { echo "ERROR: 找不到 $POWER_POLICY_SRC" >&2; exit 1; }
[[ -f "$SPOOF_SRC" ]]   || { echo "ERROR: 找不到 $SPOOF_SRC" >&2; exit 1; }
[[ -f "$APPLY_SUPPORT_SRC" ]] || { echo "ERROR: 找不到 $APPLY_SUPPORT_SRC" >&2; exit 1; }
[[ -f "$PROFILE_HELPER_SRC" ]] || { echo "ERROR: 找不到 $PROFILE_HELPER_SRC" >&2; exit 1; }
[[ -f "$TRANSACTION_HELPER_SRC" ]] || { echo "ERROR: 找不到 $TRANSACTION_HELPER_SRC" >&2; exit 1; }
[[ -f "$REGISTRY_CORE_SRC" ]] || { echo "ERROR: 找不到 $REGISTRY_CORE_SRC" >&2; exit 1; }
[[ -f "$REFRESH_HELPER_SRC" ]] || { echo "ERROR: 找不到 $REFRESH_HELPER_SRC" >&2; exit 1; }
[[ -f "$MANUFACTURER_HELPER_SRC" ]] || { echo "ERROR: 找不到 $MANUFACTURER_HELPER_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_PLAN_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_PLAN_SRC" >&2; exit 1; }
[[ -f "$HARDWARE_ID_PROJECTOR_SRC" ]] || { echo "ERROR: 找不到 $HARDWARE_ID_PROJECTOR_SRC" >&2; exit 1; }
[[ -f "$DISPLAY_HELPER_SRC" ]] || { echo "ERROR: 找不到 $DISPLAY_HELPER_SRC" >&2; exit 1; }
[[ -f "$DRIVER_INSTALL_SRC" ]] || { echo "ERROR: 找不到 $DRIVER_INSTALL_SRC" >&2; exit 1; }
[[ -f "$DRIVER_TRUST_SRC" ]] || { echo "ERROR: 找不到 $DRIVER_TRUST_SRC" >&2; exit 1; }
[[ -f "$CHIPSET_INSTALL_SRC" ]] || { echo "ERROR: 找不到 $CHIPSET_INSTALL_SRC" >&2; exit 1; }
[[ -f "$NVAPI_INSTALL_SRC" ]] || { echo "ERROR: 找不到 $NVAPI_INSTALL_SRC" >&2; exit 1; }
[[ -f "$NVAPI_VALIDATION_SRC" ]] || { echo "ERROR: 找不到 $NVAPI_VALIDATION_SRC" >&2; exit 1; }
[[ -f "$NVAPI_TRANSACTION_SRC" ]] || { echo "ERROR: 找不到 $NVAPI_TRANSACTION_SRC" >&2; exit 1; }
[[ -f "$ADL_INSTALL_SRC" ]] || { echo "ERROR: 找不到 $ADL_INSTALL_SRC" >&2; exit 1; }
[[ -f "$ADL_TRANSACTION_SRC" ]] || { echo "ERROR: 找不到 $ADL_TRANSACTION_SRC" >&2; exit 1; }
[[ -f "$GPU_API_INSTALL_SRC" ]] || { echo "ERROR: 找不到 $GPU_API_INSTALL_SRC" >&2; exit 1; }
[[ -f "$GPU_API_IDENTITY_BINDING_SRC" ]] || { echo "ERROR: 找不到 $GPU_API_IDENTITY_BINDING_SRC" >&2; exit 1; }
[[ -f "$ADL_EXPORTS_SRC" ]] || { echo "ERROR: 找不到 $ADL_EXPORTS_SRC" >&2; exit 1; }
[[ -f "$PAYLOAD_SECURITY_SRC" ]] || { echo "ERROR: 找不到 $PAYLOAD_SECURITY_SRC" >&2; exit 1; }
[[ -f "$PAYLOAD_ENVIRONMENT_SRC" ]] || { echo "ERROR: 找不到 $PAYLOAD_ENVIRONMENT_SRC" >&2; exit 1; }
[[ -f "$LAUNCHER_ARGUMENTS_SRC" ]] || { echo "ERROR: 找不到 $LAUNCHER_ARGUMENTS_SRC" >&2; exit 1; }
[[ -f "$MANUFACTURER_PROJECTOR_SRC" ]] || { echo "ERROR: 找不到 $MANUFACTURER_PROJECTOR_SRC" >&2; exit 1; }

# stock 驱动的 SYS/CAT/INF 必须来自同一发布包。构建时先锁定三者摘要，既避免
# 误把深层自签版打进浅层 EXE，也能在源文件被截断或 CAT/SYS 混版时立即失败。
verify_driver_file() {
    local file_name="$1"
    local expected_hash="$2"
    local path="$DRIVER_SRC_DIR/$file_name"
    local actual_hash

    [[ -f "$path" ]] || { echo "ERROR: 找不到 $path" >&2; exit 1; }
    actual_hash="$(sha256sum "$path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: $file_name SHA-256 不匹配: $actual_hash" >&2
        exit 1
    fi
}

verify_driver_file viogpudo.sys 04e873ad57387a518ad8ccae5116989c63170503c14b9cca0b2067e63876af89
verify_driver_file viogpudo.cat b5122b2e060ec0c2f0157afcdc64c728ec31646819055c8b79ae3f4227472078
verify_driver_file viogpudo.inf 48abd56644386e1f0d85c54cd64db93e62a4eb33bc7acb2613f237c6e1c6a0ee

# 两套 Intel 芯片组 INF 都是 Microsoft WHCP 签名的 NO_DRV 识别包。正式构建只接受
# Microsoft Update Catalog 锁定版本的原始字节，不能用同名自签包或另一 OEM 版本。
verify_chipset_file() {
    local file_name="$1"
    local expected_hash="$2"
    local path="$CHIPSET_INF_SRC_DIR/$file_name"
    local actual_hash

    [[ -f "$path" ]] || { echo "ERROR: 找不到 $path" >&2; exit 1; }
    actual_hash="$(sha256sum "$path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: $file_name SHA-256 不匹配: $actual_hash" >&2
        exit 1
    fi
}

verify_chipset_file CannonLake-HSystem.inf \
    0793ffcb29ba4dd13e62ec1c406884193cbf893d95e0b49840da609d8447a123
verify_chipset_file cannonlake-h.cat \
    9e457455e44a4215610c1160c6b3cbe345a4ee8e2af621e51ef6d1079870dba2
verify_chipset_file SunrisePoint-HSystem.inf \
    4d931028bc5d6f1d28ec05f80e1b365d42a3d0ff00b0aeebe582c07dc83a1f70
verify_chipset_file sunrisepoint-h.cat \
    d22cdfa1018a00aa0b61172017f7bfb8f58382bfa80545e56b2b7a16c0242b9b

# NVAPI shim 没有厂商签名，固定 SHA-256 就是发布链的信任根。除摘要外还检查
# COFF Machine、DLL flag 与唯一导出名，避免把同名错架构文件打进单 EXE。
verify_nvapi_file() {
    local file_name="$1"
    local expected_hash="$2"
    local expected_machine="$3"
    local path="$NVAPI_SRC_DIR/$file_name"
    local actual_hash metadata export_count all_export_count

    [[ -f "$path" ]] || { echo "ERROR: 找不到 $path" >&2; exit 1; }
    actual_hash="$(sha256sum "$path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: $file_name SHA-256 不匹配: $actual_hash" >&2
        exit 1
    fi

    metadata="$(llvm-readobj --file-headers --coff-exports "$path")"
    grep -F "Machine: $expected_machine" <<<"$metadata" >/dev/null \
        || { echo "ERROR: $file_name PE Machine 不匹配" >&2; exit 1; }
    grep -F 'IMAGE_FILE_DLL (0x2000)' <<<"$metadata" >/dev/null \
        || { echo "ERROR: $file_name 缺少 IMAGE_FILE_DLL" >&2; exit 1; }
    export_count="$(grep -c '^  Name: nvapi_QueryInterface$' <<<"$metadata" || true)"
    all_export_count="$(grep -c '^Export {$' <<<"$metadata" || true)"
    if [[ "$export_count" != 1 || "$all_export_count" != 1 ]]; then
        echo "ERROR: $file_name 必须只导出 nvapi_QueryInterface" >&2
        exit 1
    fi
}

verify_nvapi_file nvapi.dll "$NVAPI_X86_SHA256" 'IMAGE_FILE_MACHINE_I386 (0x14C)'
verify_nvapi_file nvapi64.dll "$NVAPI_X64_SHA256" 'IMAGE_FILE_MACHINE_AMD64 (0x8664)'

# ADL 同样是系统级厂商 API，而不是 GPU-Z 的旁置补丁。构建时除摘要和架构外，
# 逐项核对公开导出清单，防止 32/64 位任一产物漏掉通用检测工具所需的入口。
verify_adl_file() {
    local file_name="$1"
    local expected_hash="$2"
    local expected_machine="$3"
    local path="$ADL_SRC_DIR/$file_name"
    local actual_hash metadata expected_count actual_count symbol

    [[ -f "$path" ]] || { echo "ERROR: 找不到 $path" >&2; exit 1; }
    actual_hash="$(sha256sum "$path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: $file_name SHA-256 不匹配: $actual_hash" >&2
        exit 1
    fi
    metadata="$(llvm-readobj --file-headers --coff-exports "$path")"
    grep -F "Machine: $expected_machine" <<<"$metadata" >/dev/null \
        || { echo "ERROR: $file_name PE Machine 不匹配" >&2; exit 1; }
    grep -F 'IMAGE_FILE_DLL (0x2000)' <<<"$metadata" >/dev/null \
        || { echo "ERROR: $file_name 缺少 IMAGE_FILE_DLL" >&2; exit 1; }

    expected_count=0
    while IFS= read -r symbol; do
        [[ -n "$symbol" && "$symbol" != \#* ]] || continue
        expected_count=$((expected_count + 1))
        [[ "$(grep -Fxc "  Name: $symbol" <<<"$metadata" || true)" -eq 1 ]] \
            || { echo "ERROR: $file_name 缺少唯一 ADL 导出: $symbol" >&2; exit 1; }
    done < "$ADL_EXPORTS_SRC"
    actual_count="$(grep -c '^Export {$' <<<"$metadata" || true)"
    [[ "$actual_count" -eq "$expected_count" ]] \
        || { echo "ERROR: $file_name ADL 导出数量不匹配" >&2; exit 1; }
}

verify_adl_file atiadlxy.dll "$ADL_X86_SHA256" 'IMAGE_FILE_MACHINE_I386 (0x14C)'
verify_adl_file atiadlxx.dll "$ADL_X64_SHA256" 'IMAGE_FILE_MACHINE_AMD64 (0x8664)'

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
        -strip \
        "$out"
}

for size in 16 32 48 64 128 256; do
    make_icon_png "$size" "$BUILD_DIR/icon-${size}.png"
done
# PNG 的像素内容相同时，ImageMagick 默认仍可能写入 date:create/date:modify。
# 上面的 -strip 移除这些动态块；合成 ICO 时再清理一次，避免未来版本继承新元数据。
convert "$BUILD_DIR"/icon-*.png -strip "$BUILD_DIR/respawn-stealth.ico"

# Windows 保留的 Manufacturer 属性只能通过 Config Manager API 设置。先构建一个
# 极小的本地投影器，再把其 PE 原始字节作为 payload 嵌入唯一发布 EXE。
x86_64-w64-mingw32-gcc \
    -std=c11 -Wall -Wextra -Werror -O2 -municode -mconsole \
    -static -static-libgcc -Wl,--no-insert-timestamp \
    "$MANUFACTURER_PROJECTOR_SRC" -lsetupapi -lcfgmgr32 \
    -o "$BUILD_DIR/gpu-manufacturer-projector.exe"

# xxd 生成 C header，保留原始 UTF-8/BOM 字节；EXE 运行时原样释放脚本。
xxd -i -n payload_respawn_ps1 "$RESPAWN_SRC" \
    > "$BUILD_DIR/payload_respawn_ps1.h"
xxd -i -n payload_respawn_restart_state_ps1 "$RESTART_STATE_SRC" \
    > "$BUILD_DIR/payload_respawn_restart_state_ps1.h"
xxd -i -n payload_configure_power_policy_ps1 "$POWER_POLICY_SRC" \
    > "$BUILD_DIR/payload_configure_power_policy_ps1.h"
xxd -i -n payload_apply_gpu_spoof_ps1 "$SPOOF_SRC" \
    > "$BUILD_DIR/payload_apply_gpu_spoof_ps1.h"
xxd -i -n payload_gpu_spoof_apply_support_ps1 "$APPLY_SUPPORT_SRC" \
    > "$BUILD_DIR/payload_gpu_spoof_apply_support_ps1.h"
xxd -i -n payload_persist_gpu_profile_ps1 "$PROFILE_HELPER_SRC" \
    > "$BUILD_DIR/payload_persist_gpu_profile_ps1.h"
xxd -i -n payload_gpu_profile_transaction_ps1 "$TRANSACTION_HELPER_SRC" \
    > "$BUILD_DIR/payload_gpu_profile_transaction_ps1.h"
xxd -i -n payload_gpu_profile_registry_core_ps1 "$REGISTRY_CORE_SRC" \
    > "$BUILD_DIR/payload_gpu_profile_registry_core_ps1.h"
xxd -i -n payload_refresh_gpu_name_ps1 "$REFRESH_HELPER_SRC" \
    > "$BUILD_DIR/payload_refresh_gpu_name_ps1.h"
xxd -i -n payload_gpu_manufacturer_projection_ps1 "$MANUFACTURER_HELPER_SRC" \
    > "$BUILD_DIR/payload_gpu_manufacturer_projection_ps1.h"
xxd -i -n payload_gpu_manufacturer_projector_exe \
    "$BUILD_DIR/gpu-manufacturer-projector.exe" \
    > "$BUILD_DIR/payload_gpu_manufacturer_projector_exe.h"
xxd -i -n payload_gpu_hardware_id_plan_ps1 "$HARDWARE_ID_PLAN_SRC" \
    > "$BUILD_DIR/payload_gpu_hardware_id_plan_ps1.h"
xxd -i -n payload_project_gpu_hardware_id_ps1 "$HARDWARE_ID_PROJECTOR_SRC" \
    > "$BUILD_DIR/payload_project_gpu_hardware_id_ps1.h"
xxd -i -n payload_force_displayfreq_ps1 "$DISPLAY_HELPER_SRC" \
    > "$BUILD_DIR/payload_force_displayfreq_ps1.h"
xxd -i -n payload_install_display_driver_ps1 "$DRIVER_INSTALL_SRC" \
    > "$BUILD_DIR/payload_install_display_driver_ps1.h"
xxd -i -n payload_display_driver_trust_ps1 "$DRIVER_TRUST_SRC" \
    > "$BUILD_DIR/payload_display_driver_trust_ps1.h"
xxd -i -n payload_install_chipset_device_ps1 "$CHIPSET_INSTALL_SRC" \
    > "$BUILD_DIR/payload_install_chipset_device_ps1.h"
xxd -i -n payload_install_nvapi_system_ps1 "$NVAPI_INSTALL_SRC" \
    > "$BUILD_DIR/payload_install_nvapi_system_ps1.h"
xxd -i -n payload_nvapi_system_validation_ps1 "$NVAPI_VALIDATION_SRC" \
    > "$BUILD_DIR/payload_nvapi_system_validation_ps1.h"
xxd -i -n payload_nvapi_system_transaction_ps1 "$NVAPI_TRANSACTION_SRC" \
    > "$BUILD_DIR/payload_nvapi_system_transaction_ps1.h"
xxd -i -n payload_install_adl_system_ps1 "$ADL_INSTALL_SRC" \
    > "$BUILD_DIR/payload_install_adl_system_ps1.h"
xxd -i -n payload_adl_system_transaction_ps1 "$ADL_TRANSACTION_SRC" \
    > "$BUILD_DIR/payload_adl_system_transaction_ps1.h"
xxd -i -n payload_install_gpu_api_system_ps1 "$GPU_API_INSTALL_SRC" \
    > "$BUILD_DIR/payload_install_gpu_api_system_ps1.h"
xxd -i -n payload_gpu_api_identity_binding_ps1 "$GPU_API_IDENTITY_BINDING_SRC" \
    > "$BUILD_DIR/payload_gpu_api_identity_binding_ps1.h"
xxd -i -n payload_viogpudo_sys "$DRIVER_SRC_DIR/viogpudo.sys" \
    > "$BUILD_DIR/payload_viogpudo_sys.h"
xxd -i -n payload_viogpudo_cat "$DRIVER_SRC_DIR/viogpudo.cat" \
    > "$BUILD_DIR/payload_viogpudo_cat.h"
xxd -i -n payload_viogpudo_inf "$DRIVER_SRC_DIR/viogpudo.inf" \
    > "$BUILD_DIR/payload_viogpudo_inf.h"
xxd -i -n payload_cannonlake_hsystem_inf \
    "$CHIPSET_INF_SRC_DIR/CannonLake-HSystem.inf" \
    > "$BUILD_DIR/payload_cannonlake_hsystem_inf.h"
xxd -i -n payload_cannonlake_h_cat "$CHIPSET_INF_SRC_DIR/cannonlake-h.cat" \
    > "$BUILD_DIR/payload_cannonlake_h_cat.h"
xxd -i -n payload_sunrisepoint_hsystem_inf \
    "$CHIPSET_INF_SRC_DIR/SunrisePoint-HSystem.inf" \
    > "$BUILD_DIR/payload_sunrisepoint_hsystem_inf.h"
xxd -i -n payload_sunrisepoint_h_cat "$CHIPSET_INF_SRC_DIR/sunrisepoint-h.cat" \
    > "$BUILD_DIR/payload_sunrisepoint_h_cat.h"
xxd -i -n payload_nvapi_x86_dll "$NVAPI_SRC_DIR/nvapi.dll" \
    > "$BUILD_DIR/payload_nvapi_x86_dll.h"
xxd -i -n payload_nvapi_x64_dll "$NVAPI_SRC_DIR/nvapi64.dll" \
    > "$BUILD_DIR/payload_nvapi_x64_dll.h"
xxd -i -n payload_adl_x86_dll "$ADL_SRC_DIR/atiadlxy.dll" \
    > "$BUILD_DIR/payload_adl_x86_dll.h"
xxd -i -n payload_adl_x64_dll "$ADL_SRC_DIR/atiadlxx.dll" \
    > "$BUILD_DIR/payload_adl_x64_dll.h"

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
    -Wl,--no-insert-timestamp \
    -I "$BUILD_DIR" \
    -I "$LAUNCHER_COMMON" \
    "$SRC" \
    "$PAYLOAD_SECURITY_SRC" \
    "$PAYLOAD_ENVIRONMENT_SRC" \
    "$LAUNCHER_ARGUMENTS_SRC" \
    "$BUILD_DIR/respawn-stealth.res" \
    -lshell32 -ladvapi32 -luser32 \
    -o "$OUT_EXE"

echo ">> 已生成单文件 guest 入口: $OUT_EXE"
