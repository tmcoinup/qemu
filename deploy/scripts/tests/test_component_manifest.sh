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

[[ "$(stealth_component_validate)" == 2026-07-13.1 ]] \
    || fail "component catalog revision 错误"
(( ${#NVME_POOL[@]} == 1 && ${#MONITOR_POOL[@]} == 1 )) \
    || fail "严格 SSD/显示器目录没有收敛为唯一深层模板"
(( ${#KBD_POOL[@]} == 1 && ${#MOUSE_POOL[@]} == 1 && ${#TABLET_POOL[@]} == 1 )) \
    || fail "HID 目录仍包含 C descriptor 无法表达的品牌"

# 用确定的 Intel/TSC 宿主视图生成 schema 1 profile，不依赖执行测试的物理机。
# 这些值由已加载的选择器按变量名读取；导出也确保子进程测试看到同一宿主视图。
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000
export STEALTH_REQUIRED_TSC_MHZ=3600
export CPUS=4
stealth_pick_profile

[[ "$NVME_MODEL|$NVME_FIRMWARE|$NVME_PCI_DEV|$NVME_SUBSYS_DEV" == \
   "Samsung SSD 970 PRO 512GB|1B2QEXP7|0xA804|0xA801" ]] \
    || fail "NVMe bundle 与官方 970 PRO 控制器规格不符"
[[ "$NVME_SUBNQN" == *":$NVME_SERIAL" ]] || fail "subnqn 未绑定 NVMe serial"
[[ "$EDID_VENDOR|$EDID_PRODUCT_ID|$EDID_NAME" == "SAM|0x0F65|S24F350" ]] \
    || fail "EDID 深层模板不一致"
[[ "$KBD_VID:$KBD_PID:$KBD_BCD_DEVICE" == "0x045E:0x0750:0x0163" ]] \
    || fail "键盘 descriptor 不一致"
[[ "$MOUSE_VID:$MOUSE_PID:$MOUSE_BCD_DEVICE" == "0x045E:0x00CB:0x0163" ]] \
    || fail "鼠标 descriptor 不一致"
[[ "$TABLET_DESCRIPTOR_FIDELITY" == generic_virtual_only ]] \
    || fail "通用 tablet 被误标为品牌硬件"
[[ "$GPU_IDENTITY_FIDELITY" == label_only_out_of_scope ]] \
    || fail "GPU 未明确标记为本分支范围外"
[[ "$GPU_MEMORY_TYPE" == GDDR5 && "$GPU_MEMORY_BUS_WIDTH_BITS" =~ ^(64|128)$ ]] \
    || fail "GPU 显存类型/位宽未从 GPU_POOL 完整投影"
(( GPU_BASE_CLOCK_KHZ > 0 && GPU_BOOST_CLOCK_KHZ >= GPU_BASE_CLOCK_KHZ &&
   GPU_MEMORY_CLOCK_KHZ > 0 && (GPU_SLI_SUPPORTED == 0 || GPU_SLI_SUPPORTED == 1) )) \
    || fail "GPU 时钟/SLI 字段不满足基本约束"

profile="$TMP_DIR/profile"
stealth_save_profile "$profile"
STRICT_HARDWARE=1 stealth_load_profile "$profile" \
    || fail "未篡改 component profile 无法严格重载"

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
assert_tamper_fails EDID_PRODUCT_ID 0x0001
assert_tamper_fails KBD_VID 0x046D
assert_tamper_fails TABLET_DESCRIPTOR_FIDELITY branded
assert_tamper_fails GPU_MEMORY_BUS_WIDTH_BITS 256
assert_tamper_fails GPU_BOOST_CLOCK_KHZ 9999999

# 严格 profile 必须在磁盘上真实携带 schema-2 guest 所需全部规格；
# loader 为旧 profile 生成的诊断默认不能绕过 present-keys 门禁。
missing_gpu_specs="$TMP_DIR/profile-missing-gpu-specs"
grep -Ev '^GPU_(MEMORY_TYPE|MEMORY_BUS_WIDTH_BITS|BASE_CLOCK_KHZ|BOOST_CLOCK_KHZ|MEMORY_CLOCK_KHZ|SLI_SUPPORTED)=' \
    "$profile" >"$missing_gpu_specs"
if STRICT_HARDWARE=1 stealth_load_profile "$missing_gpu_specs" >/dev/null 2>&1; then
    fail "严格 profile 缺少 GPU 规格字段时未拒绝"
fi

# 未知 schema 必须拒绝，不能让脚本猜测新目录语义。
bad_manifest="$TMP_DIR/components-bad.json"
sed 's/"schema_version": 1/"schema_version": 99/' \
    "$REPO_ROOT/deploy/hardware/components.json" >"$bad_manifest"
if STEALTH_COMPONENT_MANIFEST="$bad_manifest" \
    bash -c 'source "$1"; stealth_component_validate' _ \
    "$REPO_ROOT/deploy/scripts/lib/stealth-components.sh" >/dev/null 2>&1; then
    fail "未知 component schema 未被拒绝"
fi

echo "OK: component manifest and strict profile checks passed"
