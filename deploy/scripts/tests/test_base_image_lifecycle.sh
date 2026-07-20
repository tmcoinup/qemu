#!/usr/bin/env bash
# shellcheck disable=SC2016 # 单引号内容用于匹配生产脚本中的变量字面量。
# seal/clone 共用的 base 镜像格式、原子发布与入口接线回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_LIB="$REPO_ROOT/deploy/scripts/lib/base-image.sh"
PUBLISH_HELPER="$REPO_ROOT/deploy/scripts/lib/seal-base-publish.py"
SEAL="$REPO_ROOT/deploy/scripts/seal-base.sh"
CLONE="$REPO_ROOT/deploy/scripts/clone-from-base.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

QEMU_IMG="$REPO_ROOT/build/qemu-img"
if [[ ! -x "$QEMU_IMG" ]]; then
    QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
fi
[[ -n "$QEMU_IMG" && -x "$QEMU_IMG" ]] ||
    fail "缺少 qemu-img，无法测试 base 生命周期"

# shellcheck source=../lib/base-image.sh
source "$BASE_LIB"

STANDALONE="$TMP_DIR/standalone.qcow2"
CHAINED="$TMP_DIR/chained.qcow2"
RAW="$TMP_DIR/raw.img"
EXTERNAL_DATA="$TMP_DIR/external-data.raw"
EXTERNAL_QCOW="$TMP_DIR/external-data.qcow2"
"$QEMU_IMG" create -q -f qcow2 "$STANDALONE" 1M
base_image_require_standalone_qcow2 "$QEMU_IMG" "$STANDALONE" ||
    fail "独立 qcow2 被错误拒绝"
[[ "$BASE_IMAGE_FORMAT" == qcow2 &&
   "$BASE_IMAGE_VIRTUAL_SIZE" == 1048576 &&
   "$BASE_IMAGE_HAS_BACKING" == 0 &&
   "$BASE_IMAGE_HAS_EXTERNAL_DATA" == 0 ]] ||
    fail "base 元数据解析错误"
chmod 0444 "$STANDALONE"
if base_image_require_trusted_backing_qcow2_fast \
        "$QEMU_IMG" "$STANDALONE" 1048576 \
        >"$TMP_DIR/untrusted-owner.log" 2>&1; then
    fail "普通用户拥有的 0444 base 被运行期 backing 门禁接受"
fi
grep -F "root-owned 0444" "$TMP_DIR/untrusted-owner.log" >/dev/null ||
    fail "不可信 backing owner/mode 没有明确诊断"
base_image_require_trusted_backing_qcow2_fast \
    "$QEMU_IMG" "$STANDALONE" 1048576 1 ||
    fail "legacy 普通用户 0444 base 无法兼容启动"

"$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$STANDALONE" "$CHAINED"
if base_image_require_standalone_qcow2 \
        "$QEMU_IMG" "$CHAINED" >"$TMP_DIR/chained.log" 2>&1; then
    fail "带 backing file 的链式 base 被接受"
fi
grep -F "不是独立密封镜像" "$TMP_DIR/chained.log" >/dev/null ||
    fail "链式 base 拒绝原因不明确"

"$QEMU_IMG" create -q -f raw "$RAW" 1M
if base_image_require_standalone_qcow2 \
        "$QEMU_IMG" "$RAW" >"$TMP_DIR/raw.log" 2>&1; then
    fail "raw 镜像被当作 qcow2 base 接受"
fi
grep -F "base 必须是 qcow2" "$TMP_DIR/raw.log" >/dev/null ||
    fail "raw base 拒绝原因不明确"

"$QEMU_IMG" create -q -f raw "$EXTERNAL_DATA" 1M
"$QEMU_IMG" create -q -f qcow2 \
    -o "data_file=$EXTERNAL_DATA" "$EXTERNAL_QCOW" 1M
if base_image_require_standalone_qcow2 \
        "$QEMU_IMG" "$EXTERNAL_QCOW" >"$TMP_DIR/external.log" 2>&1; then
    fail "依赖 external data file 的 qcow2 被当作独立 base"
fi
grep -F "external data file" "$TMP_DIR/external.log" >/dev/null ||
    fail "external data base 拒绝原因不明确"

# overlay 可以记录相对 backing，但完整解析路径、容量和格式必须仍精确匹配 base。
OVERLAY_DIR="$TMP_DIR/instance"
OVERLAY="$OVERLAY_DIR/disk.qcow2"
mkdir -p "$OVERLAY_DIR"
(
    cd "$OVERLAY_DIR"
    "$QEMU_IMG" create -q -f qcow2 -F qcow2 \
        -b ../standalone.qcow2 disk.qcow2
)
base_image_require_overlay_qcow2 \
    "$QEMU_IMG" "$OVERLAY" "$STANDALONE" 1048576 ||
    fail "合法相对 backing overlay 被错误拒绝"
if base_image_require_overlay_qcow2 \
        "$QEMU_IMG" "$OVERLAY" "$EXTERNAL_QCOW" 1048576 \
        >"$TMP_DIR/wrong-backing.log" 2>&1; then
    fail "overlay 的错误 expected base 被接受"
fi
BAD_BACKING_FORMAT="$OVERLAY_DIR/bad-backing-format.qcow2"
(
    cd "$OVERLAY_DIR"
    "$QEMU_IMG" create -q -f qcow2 -F raw \
        -b ../standalone.qcow2 "$(basename "$BAD_BACKING_FORMAT")"
)
if base_image_require_overlay_qcow2 \
        "$QEMU_IMG" "$BAD_BACKING_FORMAT" "$STANDALONE" 1048576 \
        >"$TMP_DIR/bad-backing-format.log" 2>&1; then
    fail "声明为 raw 的 qcow2 backing 被 overlay 校验接受"
fi

# hard-link 发布必须 no-replace，且回滚只能删除仍与 staging 同 inode 的目标。
STAGING="$TMP_DIR/.base.seal.tmp"
TARGET="$TMP_DIR/base.qcow2"
cp -- "$STANDALONE" "$STAGING"
base_image_publish_no_replace "$STAGING" "$TARGET" ||
    fail "完整 staging 无法原子发布"
[[ "$STAGING" -ef "$TARGET" ]] || fail "发布结果没有保持同一 inode"
if base_image_publish_no_replace \
        "$STAGING" "$TARGET" >"$TMP_DIR/existing.log" 2>&1; then
    fail "原子发布覆盖了已有目标"
fi
base_image_remove_published_file "$STAGING" "$TARGET"
[[ ! -e "$TARGET" ]] || fail "本次发布目标无法安全回滚"

ln -s "$TMP_DIR/missing" "$TARGET"
if base_image_publish_no_replace \
        "$STAGING" "$TARGET" >"$TMP_DIR/symlink.log" 2>&1; then
    fail "原子发布覆盖了 dangling symlink"
fi
[[ ! -e "$TMP_DIR/missing" ]] || fail "原子发布跟随了 dangling symlink"
rm -- "$TARGET"
mkdir "$TARGET"
if base_image_publish_no_replace \
        "$STAGING" "$TARGET" >"$TMP_DIR/directory.log" 2>&1; then
    fail "原子发布把已有目录当成目标文件"
fi
[[ ! -e "$TARGET/$(basename "$STAGING")" ]] ||
    fail "目录竞争导致 staging 硬链接泄漏到目标目录"
rmdir "$TARGET"

# 实例内 hard-link pin 必须保留原 inode；仓库目录项被换名后不能让既有 overlay
# 静默改指向同名新文件。
PIN_SOURCE="$TMP_DIR/pin-source.qcow2"
PIN_TARGET="$OVERLAY_DIR/.base.qcow2"
cp -- "$STANDALONE" "$PIN_SOURCE"
ln -- "$PIN_SOURCE" "$PIN_TARGET"
mv -- "$PIN_SOURCE" "$TMP_DIR/pin-source.old"
printf 'replacement\n' >"$PIN_SOURCE"
[[ "$PIN_TARGET" -ef "$TMP_DIR/pin-source.old" &&
   ! "$PIN_TARGET" -ef "$PIN_SOURCE" ]] ||
    fail "实例 base pin 没有隔离仓库目录项替换"

# seal 默认会原地清理源盘，因此必须在任何 profile/QEMU 操作前拒绝多链接 inode。
if (( EUID != 0 )); then
    HARDLINK_VMS="$TMP_DIR/hardlink-vms"
    mkdir -p "$HARDLINK_VMS/9"
    "$QEMU_IMG" create -q -f qcow2 "$HARDLINK_VMS/9/disk.qcow2" 1M
    ln "$HARDLINK_VMS/9/disk.qcow2" "$TMP_DIR/source-alias.qcow2"
    printf 'placeholder-profile\n' >"$HARDLINK_VMS/9/profile"
    if "$SEAL" 9 hardlink-base --no-clean \
            --vms-dir="$HARDLINK_VMS" --qemu-img="$QEMU_IMG" \
            >"$TMP_DIR/hardlink-source.log" 2>&1; then
        fail "seal 接受了存在其它硬链接的源 disk"
    fi
    grep -F "源 disk 存在其它硬链接" "$TMP_DIR/hardlink-source.log" >/dev/null ||
        fail "seal 的源 disk 硬链接拒绝原因不明确"
fi

# 两个入口必须接入同一契约；seal 还必须先持实例锁，再检查/转换源盘。
grep -F 'source "$SCRIPT_DIR/lib/base-image.sh"' "$SEAL" >/dev/null ||
    fail "seal 未加载 base 镜像共享库"
grep -F 'source "$SCRIPT_DIR/lib/base-image.sh"' "$CLONE" >/dev/null ||
    fail "clone 未加载 base 镜像共享库"
grep -F 'exec 8>"$INSTANCE_LOCK"' "$SEAL" >/dev/null ||
    fail "seal 未持有 start/stop 共用的实例锁"
grep -F 'sudo python3 "$BASE_PUBLISH_HELPER" publish' "$SEAL" >/dev/null ||
    fail "seal 未通过稳定 FD root helper 发布独立 base inode"
grep -F 'base_image_remove_published_fingerprint' "$SEAL" >/dev/null ||
    fail "seal 回滚仍依赖可置换的 staging 路径"
[[ -f "$PUBLISH_HELPER" ]] || fail "seal root 发布 helper 缺失"
if grep -F '"$QEMU_IMG" convert -p -O qcow2 -c "$SRC_DISK" "$BASE_FILE"' \
        "$SEAL" >/dev/null; then
    fail "seal 仍直接把 convert 输出写到最终路径"
fi
grep -F 'base_image_require_standalone_qcow2 "$QEMU_IMG" "$BASE_FILE"' \
        "$CLONE" >/dev/null ||
    fail "clone 未拒绝损坏、非 qcow2 或链式 base"
grep -F 'base_image_require_overlay_qcow2' "$CLONE" >/dev/null ||
    fail "clone 未在发布前后验证 overlay backing 契约"
grep -F 'clone_lifecycle_prepare_base_pin' "$CLONE" >/dev/null ||
    fail "clone 未在实例目录固定 base backing inode"
grep -F '"$QEMU_IMG" "$DISK" "$BASE_PIN" "$BASE_BYTES"' "$CLONE" >/dev/null ||
    fail "clone 提交校验仍引用可替换的 base 仓库目录项"
grep -F 'base_image_require_trusted_backing_qcow2_fast' \
        "$REPO_ROOT/deploy/scripts/lib/sv-disk.sh" >/dev/null ||
    fail "start 磁盘路径未快速复核 root-owned backing"
if grep -F 'command -v qemu-img' "$SEAL" "$CLONE" >/dev/null; then
    fail "显式/默认 qemu-img 错误仍会静默回退系统工具"
fi
if grep -F 'command -v qemu-system-x86_64' "$CLONE" >/dev/null; then
    fail "clone 仍会静默回退 stock qemu-system-x86_64"
fi
grep -F 'if [[ "$TARGET_BYTES" != "$BASE_BYTES" ]]' "$CLONE" >/dev/null ||
    fail "clone 未在发布前 fail-closed 校验启动盘容量"

LOCK_LINE="$(grep -nF 'exec 8>"$INSTANCE_LOCK"' "$SEAL" | head -n1 | cut -d: -f1)"
PROCESS_LINE="$(grep -nF 'sv_qemu_instance_pids "$SRC_INSTANCE"' "$SEAL" |
    head -n1 | cut -d: -f1)"
CONVERT_LINE="$(grep -nF '"$QEMU_IMG" convert -p -O qcow2' "$SEAL" |
    head -n1 | cut -d: -f1)"
[[ -n "$LOCK_LINE" && -n "$PROCESS_LINE" && -n "$CONVERT_LINE" &&
   "$LOCK_LINE" -lt "$PROCESS_LINE" && "$LOCK_LINE" -lt "$CONVERT_LINE" ]] ||
    fail "seal 没有在停机检查与 convert 前持有生命周期锁"

echo "OK: base image validation, locking and atomic publish passed"
