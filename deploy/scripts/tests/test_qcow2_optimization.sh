#!/usr/bin/env bash
# qcow2 性能布局、带 backing/独立盘转换与生命周期锁回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPTIMIZER="$REPO_ROOT/deploy/scripts/optimize-qcow2.sh"
POLICY="$REPO_ROOT/deploy/scripts/lib/qcow2-performance.sh"
STORAGE="$REPO_ROOT/deploy/scripts/lib/stealth-storage.sh"
QEMU_IMG="$REPO_ROOT/build/qemu-img"
QEMU_IO="$REPO_ROOT/build/qemu-io"
FAULT_QEMU_IMG="$SCRIPT_DIR/fixtures/qemu-img-fail-third-check.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -x "$QEMU_IMG" && -x "$QEMU_IO" ]] || \
    fail "缺少已构建的 qemu-img/qemu-io"
# shellcheck source=../lib/qcow2-performance.sh
source "$POLICY"

expected_coverage=$((512 * 1024 * 1024 * 1024))
[[ "$(vmate_qcow2_l2_coverage_bytes)" == "$expected_coverage" ]] || \
    fail "L2 cache 未精确覆盖 512 GiB"
[[ "$(vmate_qcow2_refcount_coverage_bytes)" == "$expected_coverage" ]] || \
    fail "refcount cache 未精确覆盖 512 GiB"
[[ "$VMATE_QCOW2_CREATE_OPTIONS" == *"cluster_size=131072"* &&
   "$VMATE_QCOW2_CREATE_OPTIONS" == *"extended_l2=on"* &&
   "$VMATE_QCOW2_CREATE_OPTIONS" == *"preallocation=metadata"* &&
   "$VMATE_QCOW2_CREATE_OPTIONS" == *"lazy_refcounts=off"* ]] || \
    fail "qcow2 创建性能契约不完整"
grep -F 'discard=unmap,detect-zeroes=unmap,${VMATE_QCOW2_RUNTIME_OPTIONS}' \
        "$STORAGE" >/dev/null || \
    fail "启动盘未消费 qcow2 运行时性能契约"
[[ "$VMATE_QCOW2_RUNTIME_OPTIONS" == *"discard-no-unref=on"* &&
   "$VMATE_QCOW2_RUNTIME_OPTIONS" == *"cache-clean-interval=0"* ]] || \
    fail "qcow2 运行时抗碎片/缓存策略不完整"

instance=$((800000000 + $$ % 10000000))
standalone_instance=$((instance + 1))
vm_dir="$TMP_DIR/$instance"
standalone_dir="$TMP_DIR/$standalone_instance"
mkdir -p "$vm_dir" "$standalone_dir"
chmod 0700 "$vm_dir" "$standalone_dir"

"$QEMU_IMG" create -q -f qcow2 -o compat=1.1,cluster_size=65536 \
    "$vm_dir/.base.qcow2" 256M
"$QEMU_IO" -f qcow2 \
    -c 'write -P 0x11 0 8M' -c 'write -P 0x22 128M 8M' \
    "$vm_dir/.base.qcow2" >/dev/null
(
    cd "$vm_dir"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 -b .base.qcow2 disk.qcow2
)
"$QEMU_IO" -f qcow2 \
    -c 'write -P 0x33 512K 3M' -c 'write -P 0x44 200M 2M' \
    "$vm_dir/disk.qcow2" >/dev/null
cp --sparse=always "$vm_dir/disk.qcow2" "$vm_dir/reference.qcow2"

VMS_DIR="$TMP_DIR" QEMU_IMG="$QEMU_IMG" \
    "$OPTIMIZER" "$instance" >"$TMP_DIR/overlay.out"
grep -F "实例 $instance: 结构检查与逻辑内容对比均通过" \
        "$TMP_DIR/overlay.out" >/dev/null || \
    fail "backing overlay 优化未报告完整验证"
if compgen -G "$vm_dir/disk.qcow2.preopt-*" >/dev/null; then
    fail "默认优化成功后遗留了双倍占用的回滚盘"
fi
"$QEMU_IMG" compare -q -f qcow2 -F qcow2 \
    "$vm_dir/reference.qcow2" "$vm_dir/disk.qcow2" || \
    fail "backing overlay 优化后逻辑内容改变"
overlay_info="$("$QEMU_IMG" info --output=json "$vm_dir/disk.qcow2")"
printf '%s' "$overlay_info" >"$TMP_DIR/overlay-info.json"
python3 - "$vm_dir/.base.qcow2" "$TMP_DIR/overlay-info.json" <<'PY' || \
    fail "backing overlay 优化布局或 backing 不正确"
import json
import os
import sys

with open(sys.argv[2], encoding="utf-8") as stream:
    info = json.load(stream)
data = info["format-specific"]["data"]
assert info["cluster-size"] == 131072
assert data["extended-l2"] is True
assert data["lazy-refcounts"] is False
assert os.path.realpath(info["full-backing-filename"]) == os.path.realpath(sys.argv[1])
PY

"$QEMU_IMG" create -q -f qcow2 -o compat=1.1,cluster_size=65536 \
    "$standalone_dir/disk.qcow2" 256M
"$QEMU_IO" -f qcow2 \
    -c 'write -P 0x55 4M 6M' -c 'write -P 0x66 220M 2M' \
    "$standalone_dir/disk.qcow2" >/dev/null
cp --sparse=always "$standalone_dir/disk.qcow2" \
    "$standalone_dir/reference.qcow2"
VMS_DIR="$TMP_DIR" QEMU_IMG="$QEMU_IMG" \
    "$OPTIMIZER" "$standalone_instance" --keep-backup \
    >"$TMP_DIR/standalone.out"
mapfile -t backups < <(
    compgen -G "$standalone_dir/disk.qcow2.preopt-*" || true
)
(( ${#backups[@]} == 1 )) || fail "--keep-backup 没有精确保留一份原盘"
"$QEMU_IMG" compare -q -f qcow2 -F qcow2 \
    "$standalone_dir/reference.qcow2" "$standalone_dir/disk.qcow2" || \
    fail "独立盘优化后逻辑内容改变"
"$QEMU_IMG" compare -q -f qcow2 -F qcow2 \
    "$standalone_dir/reference.qcow2" "${backups[0]}" || \
    fail "--keep-backup 保留的不是原盘"
standalone_info="$("$QEMU_IMG" info --output=json \
    "$standalone_dir/disk.qcow2")"
printf '%s' "$standalone_info" >"$TMP_DIR/standalone-info.json"
python3 - "$TMP_DIR/standalone-info.json" <<'PY' || \
    fail "独立盘优化后意外带 backing 或布局错误"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    info = json.load(stream)
assert info["cluster-size"] == 131072
assert info["format-specific"]["data"]["extended-l2"] is True
assert not info.get("backing-filename")
PY

# 发布后复检失败必须把原 inode 放回 disk.qcow2，并清理本次临时链接/镜像。
before_failure_inode="$(stat -c '%d:%i' -- "$standalone_dir/disk.qcow2")"
real_qemu_img="$QEMU_IMG"
mapfile -t backups_before_failure < <(
    compgen -G "$standalone_dir/disk.qcow2.preopt-*" || true
)
if VMATE_REAL_QEMU_IMG="$real_qemu_img" \
        VMATE_QEMU_IMG_CHECK_STATE="$TMP_DIR/check-count" \
        VMS_DIR="$TMP_DIR" QEMU_IMG="$FAULT_QEMU_IMG" \
        "$OPTIMIZER" "$standalone_instance" \
        >"$TMP_DIR/fault.out" 2>&1; then
    fail "发布后复检失败时优化器错误地返回成功"
fi
[[ "$(stat -c '%d:%i' -- "$standalone_dir/disk.qcow2")" == \
   "$before_failure_inode" ]] || fail "发布后复检失败没有恢复原盘 inode"
mapfile -t backups_after_failure < <(
    compgen -G "$standalone_dir/disk.qcow2.preopt-*" || true
)
(( ${#backups_after_failure[@]} == ${#backups_before_failure[@]} )) || \
    fail "事务回滚后遗留了额外 preopt 链接"
if compgen -G "$standalone_dir/.disk.qcow2.optimize.*" >/dev/null; then
    fail "事务回滚后遗留了 staging 镜像"
fi
grep -F "优化事务中断，正在恢复原镜像" "$TMP_DIR/fault.out" \
        >/dev/null || fail "发布后失败没有报告自动回滚"

# 优化器必须与 start/stop 共用同一把锁；持锁时不得再读写镜像。
# shellcheck source=../lib/sv-instance-lock.sh
source "$REPO_ROOT/deploy/scripts/lib/sv-instance-lock.sh"
lock_path="$(sv_instance_lock_path "$standalone_instance")"
exec 9>"$lock_path"
flock -n 9 || fail "测试无法预持有实例锁"
if VMS_DIR="$TMP_DIR" QEMU_IMG="$QEMU_IMG" \
        "$OPTIMIZER" "$standalone_instance" \
        >"$TMP_DIR/locked.out" 2>&1; then
    fail "实例锁被占用时优化器仍读写镜像"
fi
grep -F "实例 $standalone_instance 正在启动、运行、停止" \
        "$TMP_DIR/locked.out" >/dev/null || \
    fail "锁冲突诊断不明确"
flock -u 9
exec 9>&-

echo "PASS: qcow2 offline optimization and runtime performance policy"
