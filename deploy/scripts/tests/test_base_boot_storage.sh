#!/usr/bin/env bash
# 验证 base 生命周期按新版 NVME_POOL 列布局解析，并始终以 BOOT_STORAGE_* 识别
# 系统盘；SATA profile 的 data-only NVME_* 即使容量不同也不能影响复用判断。
# shellcheck disable=SC1091,SC2016,SC2034,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/deploy/scripts/lib/base-boot-storage.sh"
LIFECYCLE="$REPO_ROOT/deploy/scripts/lib/clone-lifecycle.sh"
LOCK_LIB="$REPO_ROOT/deploy/scripts/lib/sv-instance-lock.sh"
SEAL="$REPO_ROOT/deploy/scripts/seal-base.sh"
CLONE="$REPO_ROOT/deploy/scripts/clone-from-base.sh"
CLONE_POSTPROCESS="$REPO_ROOT/deploy/scripts/lib/clone-postprocess.sh"
TMP_DIR="$(mktemp -d)"
TEST_LOCK=""

cleanup() {
    if [[ -n "$TEST_LOCK" && -f "$TEST_LOCK" && ! -L "$TEST_LOCK" ]]; then
        rm -- "$TEST_LOCK"
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=../lib/base-boot-storage.sh
source "$HELPER"
# shellcheck source=../lib/clone-lifecycle.sh
source "$LIFECYCLE"

# 新版 NVME_POOL 的稳定 ID 位于第 1 列，容量位于第 4 列；尾部扩列不应影响解析。
row="samsung-970-pro-512gb|Samsung SSD 970 PRO 512GB|1B2QEXP7|512110190592|0x144D|0xA808|tail"
base_boot_storage_parse_nvme_pool_row "$row"
[[ "$BASE_NVME_COMPONENT_ID" == samsung-970-pro-512gb &&
   "$BASE_NVME_MODEL" == "Samsung SSD 970 PRO 512GB" &&
   "$BASE_NVME_FIRMWARE" == 1B2QEXP7 &&
   "$BASE_NVME_SIZE_BYTES" == 512110190592 ]] ||
    fail "NVME_POOL 前四列解析错位"

if base_boot_storage_parse_nvme_pool_row \
        "samsung-970-pro-512gb|Samsung SSD 970 PRO 512GB|1B2QEXP7" \
        >/dev/null 2>&1; then
    fail "缺少容量列的 NVME_POOL 行被接受"
fi
if base_boot_storage_parse_nvme_pool_row \
        "samsung-970-pro-512gb|Samsung SSD 970 PRO 512GB|1B2QEXP7|not-a-size" \
        >/dev/null 2>&1; then
    fail "非法容量的 NVME_POOL 行被接受"
fi

# SATA/AHCI 启动盘与 data-only NVMe 故意设置为不同容量、不同型号。视图必须只
# 返回 BOOT_STORAGE_*，这是旧主板 profile 能安全复用 base 的关键回归。
PLATFORM_BOOT_STORAGE=sata-ahci
BOOT_STORAGE_MODEL="Samsung SSD 850 PRO 512GB"
BOOT_STORAGE_FIRMWARE=EXM04B6Q
BOOT_STORAGE_SIZE_BYTES=512110190592
NVME_MODEL="Samsung SSD 970 PRO 512GB"
NVME_SIZE_BYTES=1000204886016
base_boot_storage_load_profile_view
[[ "$BASE_BOOT_STORAGE_BUS_LABEL" == SATA/AHCI &&
   "$BASE_BOOT_STORAGE_MODEL" == "$BOOT_STORAGE_MODEL" &&
   "$BASE_BOOT_STORAGE_FIRMWARE" == "$BOOT_STORAGE_FIRMWARE" &&
   "$BASE_BOOT_STORAGE_SIZE_BYTES" == "$BOOT_STORAGE_SIZE_BYTES" &&
   "$BASE_BOOT_STORAGE_SIZE_BYTES" != "$NVME_SIZE_BYTES" ]] ||
    fail "SATA profile 错把 data-only NVMe 当成启动盘"
base_boot_storage_matches_size 512110190592 ||
    fail "容量匹配的 SATA profile 没有被判定为可复用"
if base_boot_storage_matches_size "$NVME_SIZE_BYTES"; then
    fail "SATA profile 复用判断错误读取 data-only NVMe 容量"
fi

PLATFORM_BOOT_STORAGE=nvme
BOOT_STORAGE_MODEL="$NVME_MODEL"
BOOT_STORAGE_FIRMWARE=1B2QEXP7
BOOT_STORAGE_SIZE_BYTES=512110190592
base_boot_storage_load_profile_view
[[ "$BASE_BOOT_STORAGE_BUS_LABEL" == NVMe &&
   "$BASE_BOOT_STORAGE_MODEL" == "$NVME_MODEL" &&
   "$BASE_BOOT_STORAGE_SIZE_BYTES" == 512110190592 ]] ||
    fail "NVMe 启动盘视图错误"

# 即使 component NVMe 命中，SATA compatibility 容量不同也必须让双池护栏失败。
# 这覆盖旧 seal 只查 NVME_POOL、碰巧放过 household 无解 base 的缺陷。
(
    NVME_POOL=(
        "nvme-test|NVMe Test 512GB|FW000001|512110190592|tail"
    )
    stealth_storage_compat_ids() {
        printf '%s\n' sata-test
    }
    stealth_storage_compat_load() {
        BOOT_STORAGE_MODEL="SATA Test 1TB"
        BOOT_STORAGE_SIZE_BYTES=1000204886016
    }
    if base_boot_storage_require_all_pool_matches 512110190592 \
            >"$TMP_DIR/pool-mismatch.log" 2>&1; then
        fail "只命中 NVMe 时双启动池护栏错误放行"
    fi
    grep -F "samsung-sata-pro compatibility" \
            "$TMP_DIR/pool-mismatch.log" >/dev/null ||
        fail "双池失败没有指出 SATA compatibility 容量缺口"
)

# 两个池分别拥有同容量条目时才允许 seal。
(
    NVME_POOL=(
        "nvme-test|NVMe Test 512GB|FW000001|512110190592|tail"
    )
    stealth_storage_compat_ids() {
        printf '%s\n' sata-test
    }
    stealth_storage_compat_load() {
        BOOT_STORAGE_MODEL="SATA Test 512GB"
        BOOT_STORAGE_SIZE_BYTES=512110190592
    }
    base_boot_storage_require_all_pool_matches 512110190592
    [[ "${BASE_BOOT_NVME_MATCHES[*]}" == "NVMe Test 512GB" &&
       "${BASE_BOOT_SATA_MATCHES[*]}" == "SATA Test 512GB" ]] ||
        fail "双启动池同容量候选没有完整返回"
)

# profile 抽签耗尽必须失败，且最后一次错配身份不能保存。故意让 data-only NVMe
# 容量匹配、SATA 启动盘容量始终不匹配，可同时证明耗尽判断仍只看 BOOT_STORAGE_*。
(
    profile="$TMP_DIR/exhausted.profile"
    attempts=0
    saves=0
    stealth_have_profile() {
        [[ -s "$1" ]]
    }
    stealth_load_profile() {
        return 1
    }
    stealth_pick_profile() {
        attempts=$((attempts + 1))
        PLATFORM_BOOT_STORAGE=sata-ahci
        BOOT_STORAGE_MODEL="SATA Wrong Size"
        BOOT_STORAGE_FIRMWARE=BADSIZE1
        BOOT_STORAGE_SIZE_BYTES=1000204886016
        NVME_MODEL="NVMe Matching Size"
        NVME_SIZE_BYTES=512110190592
    }
    stealth_save_profile() {
        saves=$((saves + 1))
        touch "$1"
    }
    if base_boot_storage_prepare_matching_profile \
            "$profile" 512110190592 3 >"$TMP_DIR/exhausted.log" 2>&1; then
        fail "启动盘容量重抽耗尽后错误成功"
    fi
    [[ "$attempts" == 3 ]] || fail "重抽耗尽次数错误: $attempts"
    [[ "$saves" == 0 && ! -e "$profile" ]] ||
        fail "重抽耗尽后留下了错配 profile"
    grep -F "拒绝保存错配 profile" "$TMP_DIR/exhausted.log" >/dev/null ||
        fail "重抽耗尽没有明确 fail-closed 诊断"
)

# 已有 SATA profile 的 BOOT_STORAGE_* 与 base 匹配时应直接复用，不受 data-only
# NVMe 容量影响，也不能触发重抽或改写。
(
    profile="$TMP_DIR/reuse-sata.profile"
    printf 'fixture\n' >"$profile"
    picks=0
    saves=0
    stealth_have_profile() {
        [[ -s "$1" ]]
    }
    stealth_load_profile() {
        PLATFORM_BOOT_STORAGE=sata-ahci
        BOOT_STORAGE_MODEL="Samsung SSD 850 PRO 512GB"
        BOOT_STORAGE_FIRMWARE=EXM04B6Q
        BOOT_STORAGE_SIZE_BYTES=512110190592
        NVME_MODEL="Samsung SSD 970 PRO 1TB"
        NVME_SIZE_BYTES=1000204886016
    }
    stealth_pick_profile() {
        picks=$((picks + 1))
    }
    stealth_save_profile() {
        saves=$((saves + 1))
    }
    original_hash="$(sha256sum "$profile")"
    runtime_checks=0
    validate_runtime() {
        runtime_checks=$((runtime_checks + 1))
    }
    base_boot_storage_prepare_matching_profile \
        "$profile" 512110190592 3 validate_runtime >/dev/null
    [[ "$picks" == 0 && "$saves" == 0 && "$runtime_checks" == 1 &&
       "$original_hash" == "$(sha256sum "$profile")" ]] ||
        fail "匹配的 SATA profile 未被原样复用"
)

# 新抽身份即使容量匹配，也必须先通过创建期 CPU/KVM 回调再原子保存。这里让
# 回调明确失败，证明瞬态 QEMU smoke 失败不会留下稍后才被 start-vm 拒绝的 profile。
(
    profile="$TMP_DIR/runtime-rejected.profile"
    picks=0
    saves=0
    runtime_checks=0
    stealth_have_profile() {
        return 1
    }
    stealth_load_profile() {
        return 1
    }
    stealth_pick_profile() {
        picks=$((picks + 1))
        PLATFORM_BOOT_STORAGE=sata-ahci
        BOOT_STORAGE_MODEL="SATA Matching Size"
        BOOT_STORAGE_FIRMWARE=VALIDFW1
        BOOT_STORAGE_SIZE_BYTES=512110190592
    }
    stealth_save_profile() {
        saves=$((saves + 1))
        touch "$1"
    }
    reject_runtime() {
        runtime_checks=$((runtime_checks + 1))
        return 1
    }
    if base_boot_storage_prepare_matching_profile \
            "$profile" 512110190592 3 reject_runtime \
            >"$TMP_DIR/runtime-rejected.log" 2>&1; then
        fail "CPU/KVM 实现预检失败后仍保存了新 profile"
    fi
    [[ "$picks" == 1 && "$runtime_checks" == 1 &&
       "$saves" == 0 && ! -e "$profile" ]] ||
        fail "运行时回调没有在保存前 fail closed: picks=$picks checks=$runtime_checks saves=$saves"
    grep -F "拒绝保存" "$TMP_DIR/runtime-rejected.log" >/dev/null ||
        fail "运行时拒绝没有说明 profile 未保存"
)

# 已有但容量错配的 profile 必须等新身份全部通过后才原子替换；抽签耗尽时，
# 不能先删除用户/UI 预写的原文件。
(
    profile="$TMP_DIR/preserve-mismatch.profile"
    printf 'original-profile\n' >"$profile"
    original_hash="$(sha256sum "$profile")"
    stealth_have_profile() {
        [[ -s "$1" ]]
    }
    stealth_load_profile() {
        PLATFORM_BOOT_STORAGE=sata-ahci
        BOOT_STORAGE_MODEL="SATA Original Wrong Size"
        BOOT_STORAGE_FIRMWARE=ORIGINAL
        BOOT_STORAGE_SIZE_BYTES=1000204886016
    }
    stealth_pick_profile() {
        PLATFORM_BOOT_STORAGE=sata-ahci
        BOOT_STORAGE_MODEL="SATA New Wrong Size"
        BOOT_STORAGE_FIRMWARE=NEWVALUE
        BOOT_STORAGE_SIZE_BYTES=1000204886016
    }
    stealth_save_profile() {
        fail "容量错配时不应保存 profile"
    }
    if base_boot_storage_prepare_matching_profile \
            "$profile" 512110190592 2 >/dev/null 2>&1; then
        fail "容量持续错配时错误报告成功"
    fi
    [[ "$original_hash" == "$(sha256sum "$profile")" ]] ||
        fail "重抽失败删除或改写了已有 profile"
)

# 两个生产入口必须通过同一 helper 读取这些语义；clone 的容量流程不得直接读取
# NVME_SIZE_BYTES，否则 SATA profile 会再次退化为 data-only NVMe。
# shellcheck disable=SC2016 # 匹配生产脚本中的变量字面量，不在测试内展开。
grep -F 'base_boot_storage_require_all_pool_matches "$BASE_BYTES"' "$SEAL" >/dev/null ||
    fail "seal-base.sh 未校验全部启动盘池"
# shellcheck disable=SC2016 # 匹配生产脚本中的变量字面量，不在测试内展开。
grep -F 'stealth_load_profile "$SOURCE_PROFILE"' "$SEAL" >/dev/null ||
    fail "seal-base.sh 未严格加载源实例 profile"
grep -F 'export STRICT_HARDWARE=1' "$SEAL" >/dev/null ||
    fail "seal-base.sh 未强制开启严格 profile/部件校验"
# shellcheck disable=SC2016 # 匹配生产脚本中的变量字面量，不在测试内展开。
grep -F '"$PROFILE_STAGE" "$BASE_BYTES" 100 _stealth_platform_runtime_preflight' \
        "$CLONE" >/dev/null ||
    fail "clone-from-base.sh 未在 staging profile 上运行 fail-closed 准备事务"
# shellcheck disable=SC2016 # 匹配生产脚本中的变量字面量，不在测试内展开。
grep -F 'source "$SCRIPT_DIR/lib/sv-host-capabilities.sh"' "$CLONE" >/dev/null ||
    fail "clone-from-base.sh 未加载 CPU/KVM 实现预检"
grep -F 'export CPUS QEMU STRICT_HARDWARE' \
        "$CLONE" >/dev/null ||
    fail "clone-from-base.sh 未强制保持严格创建门禁"
grep -F "STABLE_DISPLAY=1 \\" "$LIFECYCLE" >/dev/null ||
    fail "clone QEMU 能力预检未使用默认稳定显示"
grep -F "GPU_ZEROCOPY=0 \\" "$LIFECYCLE" >/dev/null ||
    fail "clone 稳定显示预检仍要求 GL blob/hostmem"
grep -F -- '--allow-platform-compatibility) ALLOW_PLATFORM_COMPATIBILITY=1' \
        "$CLONE" >/dev/null ||
    fail "clone-from-base.sh 未接受 compatibility 创建授权"
# shellcheck disable=SC2016 # 两条启动提示必须复用同一组创建期关键参数。
grep -F 'start_forward_args=("--cpus=$cpus" "--qemu=$qemu")' \
        "$CLONE_POSTPROCESS" >/dev/null ||
    fail "clone-from-base.sh 未把 CPU/QEMU 传播到启动提示"
grep -F 'start_forward_args+=("--allow-platform-compatibility")' \
        "$CLONE_POSTPROCESS" >/dev/null ||
    fail "clone-from-base.sh 未把 compatibility 授权传播到启动提示"
grep -F 'printf '\''  VMS_DIR=%q QEMU_IMG=%q'\'' "$vms_dir" "$qemu_img"' \
        "$CLONE_POSTPROCESS" >/dev/null ||
    fail "clone-from-base.sh 启动提示未安全传播 VMS_DIR/QEMU_IMG"
grep -F '"$vms_dir" "$qemu_img" 0' "$CLONE_POSTPROCESS" >/dev/null ||
    fail "clone finalize 提示未默认保持 HOST_RESERVE_CORES=0"
if grep -F 'STABLE_DISPLAY=%q' "$CLONE_POSTPROCESS" >/dev/null; then
    fail "clone finalize 提示不得把 unset STABLE_DISPLAY 变成显式设置"
fi
# shellcheck disable=SC2016 # finalize --restart 必须转发相同参数数组。
grep -F -- '--restart -- "${start_forward_args[@]}" --proxy' \
        "$CLONE_POSTPROCESS" >/dev/null ||
    fail "clone-from-base.sh finalize --restart 提示未复用启动参数"
if grep -nF 'stealth_save_profile' "$CLONE" >&2; then
    fail "clone-from-base.sh 绕过事务直接保存 profile"
fi
if grep -nE 'NVME_(MODEL|SIZE_BYTES)' "$CLONE" >&2; then
    fail "clone-from-base.sh 仍把 NVME_* 用作启动盘"
fi

# 当前测试进程不是 root，使用受控 sudo fixture 原样执行降权子命令，验证生产 helper
# 确实调用 sv_instance_lock_path、预建当前目标用户 0600 锁，并能由 FD 8 排他持有。
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -u && "${3:-}" == -- ]] || exit 90
[[ "$2" == "${EXPECTED_ORIG_USER:?}" ]] || exit 91
shift 3
exec "$@"
EOF
chmod +x "$FAKE_BIN/sudo"
export EXPECTED_ORIG_USER
EXPECTED_ORIG_USER="$(id -un)"
if PATH="$FAKE_BIN:$PATH" \
        clone_lifecycle_user_lock_path \
        "$EXPECTED_ORIG_USER" "$LOCK_LIB" 0 >/dev/null 2>&1; then
    fail "instance=0 被 clone 生命周期锁接受"
fi
LOCK_INSTANCE="$((9000000000 + ($$ % 999999999)))"
TEST_LOCK="$(
    PATH="$FAKE_BIN:$PATH" \
        clone_lifecycle_user_lock_path \
        "$EXPECTED_ORIG_USER" "$LOCK_LIB" "$LOCK_INSTANCE"
)"
[[ "$TEST_LOCK" == */qemu-stealth/instance-"$LOCK_INSTANCE".lock ]] ||
    fail "clone 锁未复用 sv_instance_lock_path 路径契约: $TEST_LOCK"
[[ -f "$TEST_LOCK" && ! -L "$TEST_LOCK" &&
   "$(stat -c '%u' -- "$TEST_LOCK")" == "$(id -u)" &&
   "$(stat -c '%a' -- "$TEST_LOCK")" == 600 ]] ||
    fail "clone 目标用户锁不是 owner 匹配的 0600 普通文件"
if [[ $UID -ne 0 && "$TEST_LOCK" == /run/user/0/* ]]; then
    fail "非 root 目标用户错误落到 root 生命周期锁"
fi
exec 8<"$TEST_LOCK"
flock -n 8 || fail "测试 FD 8 无法取得 clone 实例锁"
if (
    exec 8<&-
    exec 9<"$TEST_LOCK"
    flock -n 9
); then
    fail "第二个生命周期操作绕过 clone 持有的实例锁"
fi
flock -u 8
exec 8<&-
(
    exec 9<"$TEST_LOCK"
    flock -n 9
) || fail "clone 释放后实例锁仍不可获取"

# VM_DIR 与每个最终文件都必须显式拒绝 dangling symlink；profile 仅允许真实普通
# 文件。该测试专门覆盖 `[[ -e ]]` 对 dangling symlink 返回 false 的历史盲区。
PATH_FIXTURE="$TMP_DIR/path-fixture"
VM_FIXTURE="$PATH_FIXTURE/vm"
mkdir -p "$PATH_FIXTURE"
ln -s "$PATH_FIXTURE/missing-vm" "$VM_FIXTURE"
if clone_lifecycle_validate_instance_paths \
        "$VM_FIXTURE" "$VM_FIXTURE/disk.qcow2" \
        "$VM_FIXTURE/profile" "$VM_FIXTURE/ovmf-vars.fd" >/dev/null 2>&1; then
    fail "dangling VM_DIR symlink 被接受"
fi
rm -- "$VM_FIXTURE"
mkdir -p "$VM_FIXTURE"
for leaf in disk.qcow2 profile ovmf-vars.fd; do
    ln -s "$VM_FIXTURE/missing-$leaf" "$VM_FIXTURE/$leaf"
    if clone_lifecycle_validate_instance_paths \
            "$VM_FIXTURE" "$VM_FIXTURE/disk.qcow2" \
            "$VM_FIXTURE/profile" "$VM_FIXTURE/ovmf-vars.fd" >/dev/null 2>&1; then
        fail "dangling $leaf symlink 被接受"
    fi
    rm -- "$VM_FIXTURE/$leaf"
done
printf 'ui-profile\n' >"$VM_FIXTURE/profile"
clone_lifecycle_validate_instance_paths \
    "$VM_FIXTURE" "$VM_FIXTURE/disk.qcow2" \
    "$VM_FIXTURE/profile" "$VM_FIXTURE/ovmf-vars.fd" ||
    fail "真实 UI profile 被路径门禁错误拒绝"

# hard-link 发布必须拒绝任何已有目录项且不跟随 dangling symlink；成功时目标和
# staging 指向同一 inode，回滚 helper 只删除本次发布的目标。
ATOMIC_DIR="$TMP_DIR/atomic"
mkdir -p "$ATOMIC_DIR"
printf 'prepared-overlay\n' >"$ATOMIC_DIR/disk.tmp"
ln -s "$ATOMIC_DIR/referent-must-not-exist" "$ATOMIC_DIR/disk.qcow2"
if clone_lifecycle_publish_no_replace \
        "$ATOMIC_DIR/disk.tmp" "$ATOMIC_DIR/disk.qcow2" >/dev/null 2>&1; then
    fail "原子发布覆盖了 dangling symlink"
fi
[[ ! -e "$ATOMIC_DIR/referent-must-not-exist" ]] ||
    fail "原子发布跟随 dangling symlink 写入 referent"
rm -- "$ATOMIC_DIR/disk.qcow2"
clone_lifecycle_publish_no_replace \
    "$ATOMIC_DIR/disk.tmp" "$ATOMIC_DIR/disk.qcow2"
[[ "$ATOMIC_DIR/disk.tmp" -ef "$ATOMIC_DIR/disk.qcow2" ]] ||
    fail "overlay 未通过同 inode 原子发布"
clone_lifecycle_remove_published_file \
    "$ATOMIC_DIR/disk.tmp" "$ATOMIC_DIR/disk.qcow2"
[[ ! -e "$ATOMIC_DIR/disk.qcow2" ]] ||
    fail "失败回滚没有清理本次原子发布目标"
mkdir "$ATOMIC_DIR/disk.qcow2"
if clone_lifecycle_publish_no_replace \
        "$ATOMIC_DIR/disk.tmp" "$ATOMIC_DIR/disk.qcow2" >/dev/null 2>&1; then
    fail "clone 原子发布把已有目录当成目标文件"
fi
[[ ! -e "$ATOMIC_DIR/disk.qcow2/disk.tmp" ]] ||
    fail "clone 发布在目标目录内泄漏了 staging hard-link"
rmdir "$ATOMIC_DIR/disk.qcow2"

# 静态顺序契约：root FD 8 必须在第一次 VM_DIR 计算/检查前取得；profile/KVM
# 回调必须在 qemu-img overlay staging 前执行；chown 必须早于事务 commit。
LOCK_LINE="$(grep -nF 'INSTANCE_LOCK="$(clone_lifecycle_user_lock_path' "$CLONE" |
    head -n1 | cut -d: -f1)"
VM_LINE="$(grep -nF 'VM_DIR="$VMS_DIR/${NEW_INSTANCE}"' "$CLONE" |
    head -n1 | cut -d: -f1)"
TRAP_LINE="$(grep -nF 'trap clone_exit_cleanup EXIT' "$CLONE" |
    head -n1 | cut -d: -f1)"
PATH_CHECK_LINE="$(grep -nF 'clone_lifecycle_validate_instance_paths' "$CLONE" |
    head -n1 | cut -d: -f1)"
PROFILE_LINE="$(grep -nF '"$PROFILE_STAGE" "$BASE_BYTES" 100 _stealth_platform_runtime_preflight' \
    "$CLONE" | head -n1 | cut -d: -f1)"
OVERLAY_LINE="$(grep -nF '"$QEMU_IMG" create -f qcow2' "$CLONE" |
    head -n1 | cut -d: -f1)"
CHOWN_LINE="$(grep -nF 'clone_lifecycle_assign_output_ownership' "$CLONE" |
    head -n1 | cut -d: -f1)"
COMMIT_LINE="$(grep -nF 'CLONE_TRANSACTION_COMMITTED=1' "$CLONE" |
    head -n1 | cut -d: -f1)"
[[ -n "$LOCK_LINE" && -n "$VM_LINE" && "$LOCK_LINE" -lt "$VM_LINE" ]] ||
    fail "clone 未在 VM 路径检查前建立原始用户实例锁"
[[ -n "$TRAP_LINE" && -n "$PATH_CHECK_LINE" &&
   "$TRAP_LINE" -lt "$PATH_CHECK_LINE" ]] ||
    fail "clone 未在拿锁后、首次 VM 路径门禁前安装 cleanup trap"
[[ -n "$PROFILE_LINE" && -n "$OVERLAY_LINE" &&
   "$PROFILE_LINE" -lt "$OVERLAY_LINE" ]] ||
    fail "clone 未在 overlay 创建前完成 profile/CPU preflight"
[[ -n "$CHOWN_LINE" && -n "$COMMIT_LINE" && "$CHOWN_LINE" -lt "$COMMIT_LINE" ]] ||
    fail "clone 在 chown 完成前提前提交事务"
if grep -F 'chown -R' "$CLONE" >/dev/null; then
    fail "clone 仍会递归改属已有实例目录"
fi
grep -F 'exec 8<"$INSTANCE_LOCK"' "$CLONE" >/dev/null ||
    fail "clone 未由 root 固定 FD 8 持有实例锁"
grep -F 'if [[ "$ORIG_UID" == 0 ]]' "$CLONE" >/dev/null ||
    fail "clone 没有拒绝与 start/stop 分叉的 root 锁路径"
grep -F 'if ! [[ "$NEW_INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]]' \
        "$CLONE" >/dev/null ||
    fail "clone 没有拒绝 instance=0 或超长实例号"
grep -F 'SV_HOST_CAPABILITIES_USER="$ORIG_USER"' "$CLONE" >/dev/null ||
    fail "clone KVM 能力探测未切换到最终 VM 用户"
grep -F 'SV_CPU_REALIZE_USER="$ORIG_USER"' "$CLONE" >/dev/null ||
    fail "clone QEMU CPU smoke 未切换到最终 VM 用户"
grep -F 'clone_lifecycle_publish_no_replace "$DISK_TMP" "$DISK"' \
        "$CLONE" >/dev/null ||
    fail "clone overlay 未采用原子不覆盖发布"
grep -F 'clone_lifecycle_publish_no_replace "$OVMF_TMP" "$OVMF_VARS"' \
        "$CLONE" >/dev/null ||
    fail "clone OVMF 未采用原子不覆盖发布"
grep -F 'clone_lifecycle_require_qemu_caps' "$CLONE" >/dev/null ||
    fail "clone 未在提交前复用 start 的 patched QEMU 能力门禁"
grep -F 'BASE_BACKING_RELATIVE=' "$CLONE" >/dev/null ||
    fail "clone overlay 仍未使用可迁移的相对 backing 路径"

echo "OK: base boot storage parsing and SATA profile semantics passed"
