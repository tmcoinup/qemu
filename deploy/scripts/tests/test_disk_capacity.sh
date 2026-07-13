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
NVME_MODEL="Samsung SSD 970 PRO 512GB"
NVME_SIZE_BYTES=512110190592
BASE_IMAGE=
DRY_RUN=0

# 首次创建必须把清单中的精确十进制容量交给 qemu-img，并回读相同 virtual-size。
DISK="$TMP_DIR/correct.qcow2"
sv_prepare_disk >/dev/null
[[ "$DISK_VIRTUAL_SIZE" == "$NVME_SIZE_BYTES" ]] \
    || fail "创建后的 virtual-size 未与组件清单一致"
[[ "$DISK_HOST_ALLOCATED_BYTES" =~ ^[0-9]+$ ]] \
    || fail "未输出可解析的宿主分配量"

# 历史磁盘即使文件存在，只要 guest 可见容量不同就必须拒绝启动。
DISK="$TMP_DIR/mismatch.qcow2"
printf '%s' 500107862016 >"$DISK"
if sv_prepare_disk >"$TMP_DIR/mismatch.out" 2>&1; then
    fail "容量不一致的历史磁盘被放行"
fi
grep -F "磁盘虚拟容量与硬件 profile 不一致" "$TMP_DIR/mismatch.out" >/dev/null \
    || fail "容量拒绝没有给出明确原因"

# 外部工具返回损坏 JSON 时不能把空容量当成成功结果。
DISK="$TMP_DIR/invalid-json.qcow2"
printf '%s' "$NVME_SIZE_BYTES" >"$DISK"
if VMATE_QEMU_IMG_MODE=invalid-json sv_prepare_disk >"$TMP_DIR/json.out" 2>&1; then
    fail "损坏的 qemu-img JSON 被放行"
fi
grep -F "无法解析的 JSON" "$TMP_DIR/json.out" >/dev/null \
    || fail "JSON 解析失败没有给出明确原因"

# DRY_RUN 首次生成不能创建目录或镜像，但必须留下明确的未校验状态供输出层使用。
DRY_RUN=1
DISK="$TMP_DIR/not-created/new.qcow2"
sv_prepare_disk >/dev/null
[[ ! -e "$DISK" && "$DISK_VIRTUAL_SIZE" == "DRY_RUN-not-created" ]] \
    || fail "DRY_RUN 产生了磁盘副作用或状态错误"

echo "OK: disk virtual capacity is bound to the component profile"
