#!/usr/bin/env bash
# 验证 Linux 首次 profile 的显式部件选择、512G 过滤和已有 profile 断言。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# verify-stealth 会按验收阶段重复加载总入口；新增只读常量也必须保持可重入。
# shellcheck source=/dev/null
source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"

export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=5000
export STEALTH_REQUIRED_TSC_MHZ=3600
export CPUS=4

clear_requests() {
    export STEALTH_MEMORY_ID=
    export STEALTH_STORAGE_ID=
    export STEALTH_GPU_ID=
    export STEALTH_MONITOR_ID=
}

clear_requests
export STEALTH_MEMORY_ID=samsung-m378a5244cb0-crc-ddr4-4g
export STEALTH_STORAGE_ID=samsung-970-pro-512gb
export STEALTH_GPU_ID=asus-ph-gtx1050ti-4g
export STEALTH_MONITOR_ID=aoc-24b2xh
stealth_pick_profile

[[ "$MEM_MODULE_ID" == "$STEALTH_MEMORY_ID" ]] \
    || fail "显式 memory module ID 未生效"
[[ "$NVME_COMPONENT_ID|$NVME_SIZE_BYTES" == \
   "$STEALTH_STORAGE_ID|512110190592" ]] \
    || fail "显式 storage ID 未绑定统一 512G 候选"
[[ "$GPU_COMPONENT_ID|$GPU_BOARD_PARTNER|$GPU_PART_NUMBER|$GPU_NAME|$GPU_PCI_VEN|$GPU_PCI_DEV|$GPU_SUBSYS_VEN|$GPU_SUBSYS_DEV|$GPU_CARRIER_VEN|$GPU_CARRIER_DEV" == \
   "asus-ph-gtx1050ti-4g|ASUS|PH-GTX1050TI-4G|NVIDIA GeForce GTX 1050 Ti (ASUS Phoenix)|0x10DE|0x1C82|0x1043|0x8613|0x1AF4|0xA101" ]] \
    || fail "显式 GPU stable ID 未绑定完整 AIB 目录行"
[[ "$EDID_COMPONENT_ID" == "$STEALTH_MONITOR_ID" ]] \
    || fail "显式 monitor ID 未生效"
[[ "$EDID_BINARY_SERIAL" == "$(
        stealth_component_monitor_binary_serial \
            "$EDID_COMPONENT_ID" "$EDID_SERIAL"
    )" && "$EDID_REVISION" == "$(
        stealth_component_monitor_revision "$EDID_COMPONENT_ID"
    )" ]] || fail "显式 monitor 未绑定 binary serial/revision"
[[ "$EDID_SECONDARY_PIXEL_CLOCK_KHZ|$EDID_SECONDARY_HFRONT|$EDID_SECONDARY_HSYNC|$EDID_SECONDARY_HBLANK|$EDID_SECONDARY_VFRONT|$EDID_SECONDARY_VSYNC|$EDID_SECONDARY_VBLANK|$EDID_SECONDARY_HSYNC_POSITIVE|$EDID_SECONDARY_VSYNC_POSITIVE|$EDID_SECONDARY_WIDTH_MM|$EDID_SECONDARY_HEIGHT_MM" == \
   "$(stealth_component_monitor_secondary_detail "$EDID_COMPONENT_ID")" ]] \
    || fail "显式 monitor 未绑定完整次要 DTD"

profile="$TMP_DIR/profile"
stealth_save_profile "$profile"
STRICT_HARDWARE=1 stealth_load_profile "$profile" \
    || fail "已有 profile 与四项显式选择一致时被拒绝"

expect_loaded_profile_rejects() {
    local variable="$1" value="$2" expected="$3" log="$TMP_DIR/reject.log"

    clear_requests
    export "$variable=$value"
    if STRICT_HARDWARE=1 stealth_load_profile "$profile" >"$log" 2>&1; then
        fail "已有 profile 静默接受 $variable=$value"
    fi
    grep -F "$expected" "$log" >/dev/null \
        || fail "$variable 不一致缺少准确诊断"
}

expect_loaded_profile_rejects \
    STEALTH_MEMORY_ID crucial-ct4g4dfs824a-ddr4-4g \
    "已有 profile 的内存 ID"
expect_loaded_profile_rejects \
    STEALTH_STORAGE_ID removed-non-512gb-storage \
    "不是当前统一 512G 候选"
expect_loaded_profile_rejects \
    STEALTH_GPU_ID colorful-igame-gtx1050ti-u-4gd5 \
    "已有 profile 的 GPU bundle"
expect_loaded_profile_rejects \
    STEALTH_MONITOR_ID lenovo-l24e-30 \
    "已有 profile 的显示器 ID"

expect_new_profile_rejects() {
    local variable="$1" value="$2" expected="$3" log="$TMP_DIR/new-reject.log"

    clear_requests
    export "$variable=$value"
    if stealth_pick_profile >"$log" 2>&1; then
        fail "首次 profile 接受非法候选 $variable=$value"
    fi
    grep -F "$expected" "$log" >/dev/null \
        || fail "$variable 非法候选缺少准确诊断"
}

expect_new_profile_rejects \
    STEALTH_MEMORY_ID kingston-kvr16n11s8-4-ddr3-4g \
    "未在当前合法候选中唯一命中"
expect_new_profile_rejects \
    STEALTH_STORAGE_ID removed-non-512gb-storage \
    "未在当前合法候选中唯一命中"
expect_new_profile_rejects \
    STEALTH_GPU_ID 10de-1c82 \
    "未在当前合法候选中唯一命中"
expect_new_profile_rejects \
    STEALTH_MONITOR_ID unknown-monitor \
    "未在当前合法候选中唯一命中"

# 四项空值必须保持目录权重随机；无论 seed 如何，当前产品的存储仍只能是
# raw_bytes 精确等于 512110190592 的候选。
clear_requests
for seed in 3 7 11 19 31; do
    STEALTH_SEED="$seed" stealth_pick_profile
    [[ "$NVME_SIZE_BYTES" == 512110190592 ]] \
        || fail "空 storage ID 的权重随机泄漏了非 512G 候选"
done
STRICT_HARDWARE=1 stealth_load_profile "$profile" \
    || fail "四项空请求没有保持原有 profile 复用语义"

# CLI 与 clone 必须映射到同一组环境变量；clone 完成提示还要把非空选择继续
# 传给后续 start/finalize 命令，避免首次 clone 生成后丢失一致性断言。
# shellcheck disable=SC2016 # 下列内容是待匹配的 CLI 解析源码字面量。
for mapping in \
    '--memory-id=*)  STEALTH_MEMORY_ID="${1#*=}"' \
    '--storage-id=*) STEALTH_STORAGE_ID="${1#*=}"' \
    '--gpu-id=*)     STEALTH_GPU_ID="${1#*=}"' \
    '--monitor-id=*) STEALTH_MONITOR_ID="${1#*=}"'; do
    grep -F -- "$mapping" "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh" >/dev/null \
        || fail "start-vm 缺少 CLI 映射: $mapping"
    grep -F -- "$mapping" "$REPO_ROOT/deploy/scripts/clone-from-base.sh" >/dev/null \
        || fail "clone 缺少 CLI 映射: $mapping"
done

# shellcheck disable=SC2034,SC2329 # source 片段通过共享 shell 间接消费变量/_usage。
parsed="$(
    (
        _usage() { exit "${1:-2}"; }
        set -- 77 --memory-id=mem-cli --storage-id=storage-cli \
            --gpu-id=gpu-cli --monitor-id=monitor-cli
        DRY_RUN=1 NO_BRIDGE=1 HEADLESS=1 SDL=0 FB_SHM=0
        HOST_TUNE=0 CPU_ISOLATE=0
        IMAGE_ROOT="$TMP_DIR/cli-root"
        # shellcheck source=/dev/null
        source "$REPO_ROOT/deploy/scripts/lib/sv-cli.sh"
        printf '%s|%s|%s|%s|%s\n' "$INSTANCE" "$STEALTH_MEMORY_ID" \
            "$STEALTH_STORAGE_ID" "$STEALTH_GPU_ID" "$STEALTH_MONITOR_ID"
    )
)"
[[ "$parsed" == "77|mem-cli|storage-cli|gpu-cli|monitor-cli" ]] \
    || fail "start-vm CLI 没有按契约映射四项选择: $parsed"

# shellcheck source=/dev/null
source "$REPO_ROOT/deploy/scripts/lib/clone-postprocess.sh"
export STEALTH_MEMORY_ID=samsung-m378a5244cb0-crc-ddr4-4g
export STEALTH_STORAGE_ID=samsung-970-pro-512gb
export STEALTH_GPU_ID=asus-ph-gtx1050ti-4g
export STEALTH_MONITOR_ID=aoc-24b2xh
completion="$(
    clone_print_completion 9 /tmp/disk.qcow2 base 512110190592 \
        /tmp/vms "$REPO_ROOT/deploy/scripts" 4 /tmp/qemu /tmp/qemu-img \
        0 0 supported 0
)"
for forwarded in \
    "--memory-id=$STEALTH_MEMORY_ID" \
    "--storage-id=$STEALTH_STORAGE_ID" \
    "--gpu-id=$STEALTH_GPU_ID" \
    "--monitor-id=$STEALTH_MONITOR_ID"; do
    grep -F -- "$forwarded" <<<"$completion" >/dev/null \
        || fail "clone 完成命令未传播 $forwarded"
done

PRINT_HELPER="$REPO_ROOT/deploy/scripts/lib/stealth-print.sh"
grep -F 'PCI=1AF4:1050 / SUBSYS_${gpu_carrier_subsys}（单一 virtio display，无直通）' \
    "$PRINT_HELPER" >/dev/null \
    || fail "启动摘要没有明确单一物理 GPU PCI 身份"
if grep -F 'logical_gpu_id' "$PRINT_HELPER" >/dev/null; then
    fail "启动摘要仍并排打印第二套逻辑 GPU PCI ID"
fi

echo "OK: Linux component selection contract passed"
