#!/usr/bin/env bash
# 验证 NVMe 型号声明与 qcow2 guest 可见容量是同一个 fail-closed 身份向量。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/lib/sv-disk.sh"
QEMU_IMG="$SCRIPT_DIR/fixtures/qemu-img-capacity-stub.py"
BOOT_STORAGE_MODEL="Samsung SSD 970 PRO 512GB"
BOOT_STORAGE_SIZE_BYTES=512110190592
BASE_IMAGE=
DRY_RUN=0
DISK_GUARD=0

# 稀疏盘必须在启动前检查宿主真实余量；100% 阈值在已有测试文件的文件系统上
# 必然失败，用来覆盖硬拒绝与显式 emergency override，而不依赖 CI 磁盘大小。
DISK="$TMP_DIR"
DISK_GUARD=1
DISK_MIN_FREE_GIB=1
DISK_MIN_FREE_PERCENT=100
DISK_WARN_FREE_PERCENT=100
if sv_disk_host_headroom_guard >"$TMP_DIR/headroom.out" 2>&1; then
    fail "宿主文件系统余量不足时仍允许启动"
fi
grep -F "qcow2 所在文件系统空间不足" "$TMP_DIR/headroom.out" >/dev/null \
    || fail "宿主磁盘余量拒绝没有给出明确原因"
DISK_FORCE=1
sv_disk_host_headroom_guard >"$TMP_DIR/headroom-force.out" 2>&1 \
    || fail "DISK_FORCE=1 没有显式越过磁盘余量门禁"
grep -F "显式越过满盘/ENOSPC 风险" "$TMP_DIR/headroom-force.out" >/dev/null \
    || fail "磁盘余量 override 没有输出风险提示"
DISK_GUARD=0
DISK_FORCE=0
unset DISK_MIN_FREE_GIB DISK_MIN_FREE_PERCENT DISK_WARN_FREE_PERCENT
grep -F 'preallocation=metadata,cluster_size=65536' \
        "$REPO_ROOT/deploy/scripts/lib/sv-disk.sh" >/dev/null \
    || fail "新建独立 qcow2 没有预分配元数据"

# 首次创建必须把清单中的精确十进制容量交给 qemu-img，并回读相同 virtual-size。
DISK="$TMP_DIR/correct.qcow2"
sv_prepare_disk >/dev/null
[[ "$DISK_VIRTUAL_SIZE" == "$BOOT_STORAGE_SIZE_BYTES" ]] \
    || fail "创建后的 virtual-size 未与组件清单一致"
[[ "$DISK_HOST_ALLOCATED_BYTES" =~ ^[0-9]+$ ]] \
    || fail "未输出可解析的宿主分配量"

# 历史磁盘即使文件存在，只要 guest 可见容量不同就必须拒绝启动。
DISK="$TMP_DIR/mismatch.qcow2"
printf '%s' 1000204886016 >"$DISK"
if sv_prepare_disk >"$TMP_DIR/mismatch.out" 2>&1; then
    fail "容量不一致的历史磁盘被放行"
fi
grep -F "磁盘虚拟容量与硬件 profile 不一致" "$TMP_DIR/mismatch.out" >/dev/null \
    || fail "容量拒绝没有给出明确原因"

# 外部工具返回损坏 JSON 时不能把空容量当成成功结果。
DISK="$TMP_DIR/invalid-json.qcow2"
printf '%s' "$BOOT_STORAGE_SIZE_BYTES" >"$DISK"
if VMATE_QEMU_IMG_MODE=invalid-json sv_prepare_disk >"$TMP_DIR/json.out" 2>&1; then
    fail "损坏的 qemu-img JSON 被放行"
fi
grep -F "无法解析的 JSON" "$TMP_DIR/json.out" >/dev/null \
    || fail "JSON 解析失败没有给出明确原因"

# 顶层容器与 backing 声明格式都属于启动契约；实际文件碰巧是 qcow2 也不能接受
# `-F raw`，否则 QEMU 会按 raw 扇区解释 qcow2 header。
DISK="$TMP_DIR/wrong-format.qcow2"
printf '%s' "$BOOT_STORAGE_SIZE_BYTES" >"$DISK"
if VMATE_QEMU_IMG_FORMAT=raw \
        sv_prepare_disk >"$TMP_DIR/wrong-format.out" 2>&1; then
    fail "raw 顶层实例盘被容量门禁接受"
fi
grep -F "实例 disk 必须是 qcow2" "$TMP_DIR/wrong-format.out" >/dev/null \
    || fail "顶层格式拒绝没有明确原因"

BACKING="$TMP_DIR/backing.qcow2"
printf '%s' "$BOOT_STORAGE_SIZE_BYTES" >"$BACKING"
if VMATE_QEMU_IMG_BACKING="$BACKING" \
        VMATE_QEMU_IMG_BACKING_FORMAT=raw \
        sv_prepare_disk >"$TMP_DIR/wrong-backing-format.out" 2>&1; then
    fail "声明为 raw 的 qcow2 backing 被启动门禁接受"
fi
grep -F "backing 声明格式必须是 qcow2" \
        "$TMP_DIR/wrong-backing-format.out" >/dev/null \
    || fail "backing 格式拒绝没有明确原因"

# DRY_RUN 首次生成不能创建目录或镜像，但必须留下明确的未校验状态供输出层使用。
DRY_RUN=1
DISK="$TMP_DIR/not-created/new.qcow2"
sv_prepare_disk >/dev/null
[[ ! -e "$DISK" && "$DISK_VIRTUAL_SIZE" == "DRY_RUN-not-created" ]] \
    || fail "DRY_RUN 产生了磁盘副作用或状态错误"

echo "OK: disk virtual capacity is bound to the component profile"
