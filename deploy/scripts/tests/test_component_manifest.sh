#!/usr/bin/env bash
# 验证可更换部件目录、随机池投影、profile 持久化及篡改 fail-closed。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"

catalog_revision="$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["catalog_revision"])' \
    "$REPO_ROOT/deploy/hardware/components.json")"
[[ "$catalog_revision" == 2026-07-23.3 &&
   "$(stealth_component_validate)" == "$catalog_revision" ]] \
    || fail "component/GPU/SSD catalog revision 未统一为 2026-07-23.3"
(( ${#GPU_POOL[@]} == 18 && ${#GPU_WEIGHT_ROWS[@]} == 18 &&
   ${#LEGACY_GPU_POOL[@]} == 6 &&
   ${#NVME_POOL[@]} == 4 && ${#MONITOR_POOL[@]} == 4 )) \
    || fail "AIB GPU、新旧 GPU 边界、SSD 或多品牌 1080p 显示器目录数量错误"
(( ${#KBD_POOL[@]} == 1 && ${#MOUSE_POOL[@]} == 1 && ${#TABLET_POOL[@]} == 1 )) \
    || fail "HID 目录仍包含 C descriptor 无法表达的品牌"

# 用确定的 Intel/TSC 宿主视图生成 schema 1 profile，不依赖执行测试的物理机。
# 这些值由已加载的选择器按变量名读取；导出也确保子进程测试看到同一宿主视图。
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000
export STEALTH_REQUIRED_TSC_MHZ=3600
export CPUS=4

declare -A selected_monitor_brands=()
declare -A selected_gpu_partners=()
declare -A catalog_gpu_partners=()
for row in "${GPU_POOL[@]}"; do
    IFS='|' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ board_partner _ <<<"$row"
    catalog_gpu_partners["$board_partner"]=1
done
(( ${#catalog_gpu_partners[@]} == 7 )) \
    || fail "离线 AIB 目录品牌数不是 7"
for seed in $(seq 1 512); do
    export STEALTH_SEED="$seed"
    stealth_pick_profile
    selected_monitor_brands["$EDID_VENDOR"]=1
    selected_gpu_partners["$GPU_BOARD_PARTNER"]=1
    [[ "$NVME_SIZE_BYTES|$BOOT_STORAGE_SIZE_BYTES" == \
       "512110190592|512110190592" ]] \
        || fail "首次 profile 选中了非统一 512G 存储"
    if (( ${#selected_monitor_brands[@]} >= 3 &&
          ${#selected_gpu_partners[@]} == ${#catalog_gpu_partners[@]} )); then
        break
    fi
done
unset STEALTH_SEED
(( ${#selected_monitor_brands[@]} >= 3 )) \
    || fail "多 seed 未覆盖至少三个显示器品牌"
(( ${#selected_gpu_partners[@]} == ${#catalog_gpu_partners[@]} )) \
    || fail "多 seed 未覆盖离线目录中的全部七个 AIB 品牌"
case "$NVME_COMPONENT_ID" in
    samsung-970-pro-512gb|intel-760p-512gb|wd-pc-sn730-512gb|kioxia-xg6-512gb)
        ;;
    *)
        fail "未知或非 512GB 目录条目泄漏到当前统一选择池"
        ;;
esac
[[ "$(printf '%s\n' "${NVME_POOL[@]}")" == \
   "$(stealth_component_rows storage)" ]] \
    || fail "NVME_POOL 仍有 storage.json 之外的第二事实源"

expected_gpu_row='asus-ph-gtx1050ti-4g|NVIDIA|NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)|0x10DE|0x1C82|4096|Version 86.07.42.00.96|0xA1|GDDR5|128|1291000|1392000|3504000|0|ASUS|PH-GTX1050TI-4G|0x1043|0x8613|0x1AF4|0xA101|audited_aib_bundle_shallow_user_projection_no_passthrough'
[[ "$(stealth_component_gpu_row asus-ph-gtx1050ti-4g)" == \
   "$expected_gpu_row" ]] \
    || fail "AIB GPU 稳定 ID 未投影为完整 21 列原子 ABI"
[[ "$(printf '%s\n' "${GPU_POOL[@]}")" == "$(stealth_component_rows gpu)" ]] \
    || fail "GPU_POOL 仍有 gpu-boards.json 之外的第二事实源"
[[ "$(stealth_current_gpu_profile_row)" == \
   "$(stealth_component_gpu_row "$GPU_COMPONENT_ID")" ]] \
    || fail "随机 GPU profile 没有保持所选 21 列 AIB bundle 原子一致"
gpu_device_layer="$REPO_ROOT/deploy/scripts/lib/sv-devices.sh"
# shellcheck disable=SC2016 # 这里验证源文件保留运行时变量引用，不应在测试进程展开。
grep -Fq 'GPU_STEALTH="x-pci-sub-vendor-id=${GPU_CARRIER_VEN},x-pci-sub-device-id=${GPU_CARRIER_DEV},x-pci-revision=${GPU_REV}"' \
    "$gpu_device_layer" \
    || fail "Linux 设备层没有把 AIB 选择限制在 virtio subsystem carrier"
grep -Fq 'VGA_DEV="virtio-vga,edid=on' "$gpu_device_layer" \
    || fail "Linux 稳定显示不再使用物理 1AF4:1050 virtio-vga"
grep -Fq 'VGA_DEV="virtio-vga-gl,edid=on' "$gpu_device_layer" \
    || fail "Linux GL 显示不再使用 virtio-vga-gl 主设备"
if grep -Eq 'x-pci-(vendor|device)-id=.*GPU_PCI_(VEN|DEV)' "$gpu_device_layer"; then
    fail "Linux 设备层把逻辑 GPU 主 ID 错误挂到了物理 virtio 节点"
fi
case "$GPU_VENDOR|$GPU_PCI_VEN|$GPU_CARRIER_VEN" in
    'NVIDIA|0x10DE|0x1AF4'|'AMD|0x1002|0x1AF4') ;;
    *) fail "AIB 厂商/逻辑主 ID/virtio carrier 边界错误" ;;
esac
(( GPU_CARRIER_DEV >= 0xA101 && GPU_CARRIER_DEV <= 0xA112 )) \
    || fail "随机 profile 选择了 A101..A112 之外的 carrier"
[[ -n "${catalog_gpu_partners[$GPU_BOARD_PARTNER]:-}" ]] \
    || fail "随机 profile 选择了离线目录之外的 AIB 品牌"

selected_storage_row="$(stealth_component_storage_row "$NVME_COMPONENT_ID")" \
    || fail "无法按稳定 ID 回查 SSD"
IFS='|' read -r expected_storage_id expected_storage_model \
    expected_storage_firmware expected_storage_size expected_storage_ven \
    expected_storage_dev expected_storage_subven expected_storage_subdev \
    _expected_storage_nqn expected_storage_manufacturer expected_storage_part _ \
    <<<"$selected_storage_row"
[[ "$NVME_COMPONENT_ID|$NVME_MODEL|$NVME_FIRMWARE|$NVME_SIZE_BYTES|$NVME_PCI_VEN|$NVME_PCI_DEV|$NVME_SUBSYS_VEN|$NVME_SUBSYS_DEV" == \
   "$expected_storage_id|$expected_storage_model|$expected_storage_firmware|$expected_storage_size|$expected_storage_ven|$expected_storage_dev|$expected_storage_subven|$expected_storage_subdev" ]] \
    || fail "NVMe 型号/固件/PCI bundle 没有按稳定 ID 原子绑定"
[[ "$BOOT_STORAGE_MANUFACTURER|$BOOT_STORAGE_PART_NUMBER" == \
   "$expected_storage_manufacturer|$expected_storage_part" ]] \
    || fail "NVMe 启动盘品牌/料号未从所选 bundle 投影"
stealth_component_storage_serial_is_valid \
    "$NVME_COMPONENT_ID" "$NVME_SERIAL" >/dev/null 2>&1 \
    || fail "NVMe 序列号没有遵守所选厂商格式"
[[ "$NVME_SUBNQN" == "nqn.2014-08.org.nvmexpress:uuid:$UUID" ]] \
    || fail "subnqn 未使用持久 UUID: $NVME_SUBNQN"
(( ${#NVME_SUBNQN} <= 223 )) || fail "subnqn 超过 NVMe 223 字节上限"
for serial_case in \
    "samsung-970-pro-512gb|S4EVN1234567890" \
    "samsung-970-pro-512gb|SN0NN0000000000" \
    "intel-760p-512gb|BTHH1234ABCD512D" \
    "intel-760p-512gb|BTHHN0000000512D" \
    "wd-pc-sn730-512gb|1839A8012345" \
    "wd-pc-sn730-512gb|N00000000000" \
    "wd-pc-sn730-512gb|NFFFFFFFFFFF" \
    "kioxia-xg6-512gb|69UPA0ABC123" \
    "kioxia-xg6-512gb|N00000000000" \
    "kioxia-xg6-512gb|NFFFFFFFFFFF"; do
    IFS='|' read -r serial_id serial_value <<<"$serial_case"
    stealth_component_storage_serial_is_valid \
        "$serial_id" "$serial_value" >/dev/null 2>&1 \
        || fail "$serial_id 合法序列号被拒绝"
done
for serial_case in \
    "samsung-970-pro-512gb|S4EVN123456789" \
    "samsung-970-pro-512gb|S000N0000000000" \
    "samsung-970-pro-512gb|SFFFNFFFFFFFFFF" \
    "samsung-970-pro-512gb|SNNNNNNNNNNNNNN" \
    "intel-760p-512gb|S4EVN1234567890" \
    "intel-760p-512gb|BTHH123456789ABC" \
    "intel-760p-512gb|BTHH00000000512D" \
    "intel-760p-512gb|BTHHFFFFFFFF512D" \
    "intel-760p-512gb|BTHHNNNNNNNN512D" \
    "wd-pc-sn730-512gb|BTHH123456789ABC" \
    "wd-pc-sn730-512gb|000000000000" \
    "wd-pc-sn730-512gb|FFFFFFFFFFFF" \
    "wd-pc-sn730-512gb|NNNNNNNNNNNN" \
    "kioxia-xg6-512gb|69UPA0ABC12" \
    "kioxia-xg6-512gb|000000000000" \
    "kioxia-xg6-512gb|FFFFFFFFFFFF" \
    "kioxia-xg6-512gb|NNNNNNNNNNNN" \
    "removed-non-512gb-storage|22075N800524"; do
    IFS='|' read -r serial_id serial_value <<<"$serial_case"
    if stealth_component_storage_serial_is_valid \
            "$serial_id" "$serial_value" >/dev/null 2>&1; then
        fail "$serial_id 非法或跨品牌序列号被接受"
    fi
done
selected_monitor_row="$(stealth_component_monitor_row "$EDID_COMPONENT_ID")" \
    || fail "无法按稳定 ID 回查显示器"
IFS='|' read -r expected_monitor_id expected_vendor expected_name expected_width \
    expected_height _ expected_product expected_week expected_year expected_input \
    expected_min_v expected_max_v expected_min_h expected_max_h expected_clock \
    expected_secondary_x expected_secondary_y expected_secondary_refresh \
    <<<"$selected_monitor_row"
[[ "$EDID_COMPONENT_ID|$EDID_VENDOR|$EDID_NAME|$EDID_WIDTH_MM|$EDID_HEIGHT_MM|$EDID_PRODUCT_ID" == \
   "$expected_monitor_id|$expected_vendor|$expected_name|$expected_width|$expected_height|$expected_product" ]] \
    || fail "EDID 身份没有按稳定 ID 绑定"
[[ "$EDID_MANUFACTURE_WEEK|$EDID_MANUFACTURE_YEAR|$EDID_VIDEO_INPUT|$EDID_MIN_VFREQ_HZ|$EDID_MAX_VFREQ_HZ|$EDID_MIN_HFREQ_KHZ|$EDID_MAX_HFREQ_KHZ|$EDID_MAX_PIXEL_CLOCK_MHZ" == \
   "$expected_week|$expected_year|$expected_input|$expected_min_v|$expected_max_v|$expected_min_h|$expected_max_h|$expected_clock" ]] \
    || fail "EDID 型号扫描规格不一致"
[[ "$EDID_SECONDARY_XRES|$EDID_SECONDARY_YRES|$EDID_SECONDARY_REFRESH_RATE" == \
   "$expected_secondary_x|$expected_secondary_y|$expected_secondary_refresh" ]] \
    || fail "EDID 次要 16:9 时序不一致"
stealth_component_monitor_serial_is_valid \
    "$EDID_COMPONENT_ID" "$EDID_SERIAL" >/dev/null 2>&1 \
    || fail "随机显示器序列号没有遵守品牌策略"
[[ "$(stealth_component_monitor_revision "$EDID_COMPONENT_ID")" == 3 ]] \
    || fail "显示器未绑定原始模板的 EDID 1.3 revision"
expected_binary_serial="$(
    stealth_component_monitor_binary_serial \
        "$EDID_COMPONENT_ID" "$EDID_SERIAL"
)"
[[ "$EDID_BINARY_SERIAL" == "$expected_binary_serial" &&
   "$EDID_BINARY_SERIAL" =~ ^0x[0-9A-F]{8}$ &&
   "$EDID_REVISION" == 3 ]] \
    || fail "显示器 binary serial/revision 未作为 profile 事实持久化"
expected_secondary_detail="$(
    stealth_component_monitor_secondary_detail "$EDID_COMPONENT_ID"
)"
[[ "$EDID_SECONDARY_PIXEL_CLOCK_KHZ|$EDID_SECONDARY_HFRONT|$EDID_SECONDARY_HSYNC|$EDID_SECONDARY_HBLANK|$EDID_SECONDARY_VFRONT|$EDID_SECONDARY_VSYNC|$EDID_SECONDARY_VBLANK|$EDID_SECONDARY_HSYNC_POSITIVE|$EDID_SECONDARY_VSYNC_POSITIVE|$EDID_SECONDARY_WIDTH_MM|$EDID_SECONDARY_HEIGHT_MM" == \
   "$expected_secondary_detail" ]] \
    || fail "显示器完整次要 DTD 未作为 profile 事实持久化"

for serial_case in \
    "samsung-s24f350|H4ZMC12345" \
    "aoc-24b2xh|ABCD12A345678" \
    "xiaomi-rmmnt238nf|2920012345678" \
    "lenovo-l24e-30|URB12AB3"; do
    IFS='|' read -r serial_id serial_value <<<"$serial_case"
    stealth_component_monitor_serial_is_valid \
        "$serial_id" "$serial_value" >/dev/null 2>&1 \
        || fail "$serial_id 合法序列号被拒绝"
done
for serial_case in \
    "samsung-s24f350|H4ZMC01676" \
    "aoc-24b2xh|2920112345678" \
    "aoc-24b2xh|ABCD12A000000" \
    "xiaomi-rmmnt238nf|29201/12345678" \
    "lenovo-l24e-30|URB5DT6H"; do
    IFS='|' read -r serial_id serial_value <<<"$serial_case"
    if stealth_component_monitor_serial_is_valid \
            "$serial_id" "$serial_value" >/dev/null 2>&1; then
        fail "$serial_id 非法序列号被接受"
    fi
done
[[ "$KBD_VID:$KBD_PID:$KBD_BCD_DEVICE" == "0x045E:0x0750:0x0163" ]] \
    || fail "键盘 descriptor 不一致"
[[ "$MOUSE_VID:$MOUSE_PID:$MOUSE_BCD_DEVICE" == "0x045E:0x00CB:0x0163" ]] \
    || fail "鼠标 descriptor 不一致"
[[ "$KBD_DESCRIPTOR_FIDELITY|$MOUSE_DESCRIPTOR_FIDELITY" == \
   "identity_only_generic_report|identity_only_generic_report" ]] \
    || fail "键鼠被错误标记成真实 report descriptor"
[[ "$TABLET_DESCRIPTOR_FIDELITY" == generic_virtual_only ]] \
    || fail "通用 tablet 被误标为品牌硬件"
[[ "$GPU_IDENTITY_FIDELITY" == \
   audited_aib_bundle_shallow_user_projection_no_passthrough ]] \
    || fail "新 GPU 未明确标记为已审计 AIB 浅层投影且无直通"
[[ "$GPU_MEMORY_TYPE" == GDDR5 && "$GPU_MEMORY_BUS_WIDTH_BITS" =~ ^(64|128)$ ]] \
    || fail "GPU 显存类型/位宽未从 GPU_POOL 完整投影"
(( GPU_BASE_CLOCK_KHZ > 0 && GPU_BOOST_CLOCK_KHZ >= GPU_BASE_CLOCK_KHZ &&
   GPU_MEMORY_CLOCK_KHZ > 0 && (GPU_SLI_SUPPORTED == 0 || GPU_SLI_SUPPORTED == 1) )) \
    || fail "GPU 时钟/SLI 字段不满足基本约束"

profile="$TMP_DIR/profile"
stealth_save_profile "$profile"
STRICT_HARDWARE=1 stealth_load_profile "$profile" \
    || fail "未篡改 component profile 无法严格重载"

# 目录扩池只改变生成时 revision；旧 profile 仍按稳定 ID 重建原 AIB、Samsung、
# AOC/Xiaomi/Lenovo 条目，不应因为新增候选而失效。
old_revision_profile="$TMP_DIR/profile-old-component-revision"
sed 's/^COMPONENT_CATALOG_REVISION=.*/COMPONENT_CATALOG_REVISION=2026-07-19.3/' \
    "$profile" >"$old_revision_profile"
STRICT_HARDWARE=1 stealth_load_profile "$old_revision_profile" \
    || fail "旧 component revision 的稳定 ID profile 被扩池错误地作废"

assert_tamper_fails() {
    local key="$1" value="$2" bad
    bad="$TMP_DIR/profile-$key"
    cp "$profile" "$bad"
    sed -i "s|^${key}=.*|${key}=${value}|" "$bad"
    if STRICT_HARDWARE=1 stealth_load_profile "$bad" >/dev/null 2>&1; then
        fail "篡改 $key 后严格加载仍成功"
    fi
}

assert_tamper_fails NVME_PCI_DEV 0xA809
assert_tamper_fails COMPONENT_CATALOG_REVISION forged
assert_tamper_fails NVME_SUBNQN nqn.2014-08.org.nvmexpress:uuid:00000000-0000-4000-8000-000000000000
assert_tamper_fails EDID_COMPONENT_ID unknown-monitor
assert_tamper_fails EDID_PRODUCT_ID 0x0001
tampered_binary_serial=0x00000001
[[ "$EDID_BINARY_SERIAL" == "$tampered_binary_serial" ]] &&
    tampered_binary_serial=0x00000002
assert_tamper_fails EDID_BINARY_SERIAL "$tampered_binary_serial"
assert_tamper_fails EDID_REVISION 4
assert_tamper_fails EDID_SECONDARY_PIXEL_CLOCK_KHZ 1
assert_tamper_fails EDID_SECONDARY_HFRONT 1
assert_tamper_fails EDID_SECONDARY_HSYNC_POSITIVE \
    "$((1 - EDID_SECONDARY_HSYNC_POSITIVE))"
assert_tamper_fails EDID_SECONDARY_VSYNC_POSITIVE \
    "$((1 - EDID_SECONDARY_VSYNC_POSITIVE))"
assert_tamper_fails EDID_SECONDARY_WIDTH_MM 999
assert_tamper_fails EDID_SECONDARY_HEIGHT_MM 999
assert_tamper_fails KBD_VID 0x046D
assert_tamper_fails TABLET_DESCRIPTOR_FIDELITY branded
assert_tamper_fails GPU_MEMORY_BUS_WIDTH_BITS 256
assert_tamper_fails GPU_BOOST_CLOCK_KHZ 9999999
assert_tamper_fails GPU_BOARD_PARTNER forged
assert_tamper_fails GPU_SUBSYS_DEV 0xFFFF
assert_tamper_fails GPU_CARRIER_DEV 0xA1FF
assert_tamper_fails NVME_MODEL "''"
assert_tamper_fails EDID_VENDOR "''"
assert_tamper_fails KBD_VID "''"
assert_tamper_fails GPU_IDENTITY_FIDELITY "''"
assert_tamper_fails MEM_RATED_MTS "''"
assert_tamper_fails MEM_CONFIGURED_MTS "''"

# 严格 AIB profile 必须在磁盘上真实携带 schema-2 guest 所需全部规格；
# loader 为旧 profile 生成的诊断默认不能绕过 present-keys 门禁。
missing_gpu_specs="$TMP_DIR/profile-missing-gpu-specs"
grep -Ev '^GPU_(MEMORY_TYPE|MEMORY_BUS_WIDTH_BITS|BASE_CLOCK_KHZ|BOOST_CLOCK_KHZ|MEMORY_CLOCK_KHZ|SLI_SUPPORTED)=' \
    "$profile" >"$missing_gpu_specs"
if STRICT_HARDWARE=1 stealth_load_profile "$missing_gpu_specs" >/dev/null 2>&1; then
    fail "严格 profile 缺少 GPU 规格字段时未拒绝"
fi

missing_edid_detail="$TMP_DIR/profile-missing-edid-detail"
missing_edid_pattern='^EDID_(BINARY_SERIAL|REVISION|SECONDARY_PIXEL_CLOCK_KHZ|'
missing_edid_pattern+='SECONDARY_HFRONT|SECONDARY_HSYNC|SECONDARY_HBLANK|'
missing_edid_pattern+='SECONDARY_VFRONT|SECONDARY_VSYNC|SECONDARY_VBLANK|'
missing_edid_pattern+='SECONDARY_HSYNC_POSITIVE|SECONDARY_VSYNC_POSITIVE|'
missing_edid_pattern+='SECONDARY_WIDTH_MM|SECONDARY_HEIGHT_MM)='
grep -Ev "$missing_edid_pattern" \
    "$profile" >"$missing_edid_detail"
if STRICT_HARDWARE=0 stealth_load_profile "$missing_edid_detail" \
        >/dev/null 2>&1; then
    fail "schema-1 profile 缺少完整 EDID 绑定时在非严格模式下未拒绝"
fi

# 未知 schema 必须拒绝，不能让脚本猜测新目录语义。
bad_manifest="$TMP_DIR/components-bad.json"
sed 's/"schema_version": 1/"schema_version": 99/' \
    "$REPO_ROOT/deploy/hardware/components.json" >"$bad_manifest"
if STEALTH_COMPONENT_MANIFEST="$bad_manifest" \
    STEALTH_GPU_BOARD_MANIFEST="$REPO_ROOT/deploy/hardware/gpu-boards.json" \
    STEALTH_STORAGE_MANIFEST="$REPO_ROOT/deploy/hardware/storage.json" \
    bash -c 'source "$1"; stealth_component_validate' _ \
    "$REPO_ROOT/deploy/scripts/lib/stealth-components.sh" >/dev/null 2>&1; then
    fail "未知 component schema 未被拒绝"
fi

bad_timing_type="$TMP_DIR/components-bad-timing-type.json"
sed '0,/"hsync_positive": true/s//"hsync_positive": 1/' \
    "$REPO_ROOT/deploy/hardware/components.json" >"$bad_timing_type"
if STEALTH_COMPONENT_MANIFEST="$bad_timing_type" \
    STEALTH_GPU_BOARD_MANIFEST="$REPO_ROOT/deploy/hardware/gpu-boards.json" \
    STEALTH_STORAGE_MANIFEST="$REPO_ROOT/deploy/hardware/storage.json" \
    bash -c 'source "$1"; stealth_component_validate' _ \
    "$REPO_ROOT/deploy/scripts/lib/stealth-components.sh" >/dev/null 2>&1; then
    fail "显示器 DTD 极性使用整数冒充布尔值时目录校验仍成功"
fi

bad_gpu_manifest="$TMP_DIR/components-bad-legacy-gpu.json"
sed '0,/label_only_out_of_scope/s//physical_device/' \
    "$REPO_ROOT/deploy/hardware/components.json" >"$bad_gpu_manifest"
if STEALTH_COMPONENT_MANIFEST="$bad_gpu_manifest" \
    STEALTH_GPU_BOARD_MANIFEST="$REPO_ROOT/deploy/hardware/gpu-boards.json" \
    STEALTH_STORAGE_MANIFEST="$REPO_ROOT/deploy/hardware/storage.json" \
    bash -c 'source "$1"; stealth_component_validate' _ \
    "$REPO_ROOT/deploy/scripts/lib/stealth-components.sh" >/dev/null 2>&1; then
    fail "旧 generic GPU 的只读 label 边界被改写后目录校验仍成功"
fi

bad_aib_manifest="$TMP_DIR/gpu-boards.json"
sed '0,/audited_aib_bundle_shallow_user_projection_no_passthrough/s//physical_device/' \
    "$REPO_ROOT/deploy/hardware/gpu-boards.json" >"$bad_aib_manifest"
if STEALTH_GPU_BOARD_MANIFEST="$bad_aib_manifest" \
    bash -c 'source "$1"; stealth_component_validate' _ \
    "$REPO_ROOT/deploy/scripts/lib/stealth-components.sh" >/dev/null 2>&1; then
    fail "新 AIB GPU 的浅层无直通边界被改写后目录校验仍成功"
fi

echo "OK: component manifest and strict profile checks passed"
