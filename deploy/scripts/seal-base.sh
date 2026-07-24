#!/usr/bin/env bash
# seal-base.sh —— 把指定 instance 的 disk.qcow2 转成只读基础镜像，供后续克隆。
#
# 用法：
#   deploy/scripts/seal-base.sh <SRC_INSTANCE> <BASE_NAME>
#       [--no-clean] [--allow-platform-compatibility]
#       [--migrate-storage-profile] [--compression=none|zlib]
#       [--image-root=PATH|--vms-dir=PATH|--base-dir=PATH] [--qemu-img=PATH]
#
# 例：
#   deploy/scripts/seal-base.sh 2 win10-ltsc-shallow
#       -> /home/ubuntu/images/vms/_base/win10-ltsc-shallow.qcow2
#
# 推荐流程：装好 1 个 VM（autounattend + shallow-stealth），关机后用本脚本固化为
# base，再用 clone-from-base.sh 克隆给后续 instance。新 instance 只存增量。
#
# 注意：
#   - 源 VM 必须先关机（lsof 检查）
#   - sysprep / 清掉 SID 等是 Windows 侧的事，本脚本不做 — 如果不 sysprep，
#     克隆出的 VM 会复用 SID/MachineGUID。仅做单机用途时可以忽略。
#   - **默认会先清理源 disk 的/WeGame 设备身份**（qimei / 登录态 / SDK 缓存 +
#     注册表 Tencent 键，见 host-clean-tencent.sh），避免所有 clone 共享同一个
#     qimei 被 ACE 判同机/多开。这一步会改源 disk（清空其 WeGame 登录态 —— base
#     本该如此）。需要保留源 disk 原样请加 --no-clean。
#   - convert 后另存一份到 _base/，源 disk 仅被上面的清理改动、不被 convert 改。
#     可选随后 rm 源 disk 腾空间，再用 clone-from-base.sh 重建该 instance 即可。

set -euo pipefail

CLEAN=1
CLI_IMAGE_ROOT=""
CLI_VMS_DIR=""
CLI_BASE_DIR=""
CLI_QEMU_IMG=""
ALLOW_COMPATIBILITY="${ALLOW_PLATFORM_COMPATIBILITY:-0}"
ALLOW_STORAGE_MIGRATION="${ALLOW_STORAGE_PROFILE_MIGRATION:-0}"
COMPRESSION="${BASE_COMPRESSION:-none}"
POS=()
for a in "$@"; do
    case "$a" in
        --no-clean) CLEAN=0 ;;
        --image-root=*) CLI_IMAGE_ROOT="${a#*=}" ;;
        --vms-dir=*) CLI_VMS_DIR="${a#*=}" ;;
        --base-dir=*) CLI_BASE_DIR="${a#*=}" ;;
        --qemu-img=*) CLI_QEMU_IMG="${a#*=}" ;;
        --allow-platform-compatibility) ALLOW_COMPATIBILITY=1 ;;
        --migrate-storage-profile) ALLOW_STORAGE_MIGRATION=1 ;;
        --compression=*) COMPRESSION="${a#*=}" ;;
        --*) echo "ERROR: 未知 flag '$a'" >&2; exit 2 ;;
        *) POS+=("$a") ;;
    esac
done
SRC_INSTANCE="${POS[0]:-}"
BASE_NAME="${POS[1]:-}"

if [[ -z "$SRC_INSTANCE" || -z "$BASE_NAME" ]]; then
    echo "usage: $0 <SRC_INSTANCE> <BASE_NAME> [--no-clean]" >&2
    echo "       [--allow-platform-compatibility] [--migrate-storage-profile]" >&2
    echo "       [--compression=none|zlib]  # 默认 none，优先降低随机读尾延迟" >&2
    echo "       [--image-root=PATH] [--vms-dir=PATH] [--base-dir=PATH] [--qemu-img=PATH]" >&2
    exit 2
fi
if (( ${#POS[@]} > 2 )); then
    echo "ERROR: 参数过多: ${POS[*]:2}" >&2
    exit 2
fi
if [[ "$ALLOW_COMPATIBILITY" != 0 && "$ALLOW_COMPATIBILITY" != 1 ]]; then
    echo "ERROR: ALLOW_PLATFORM_COMPATIBILITY 必须是 0 或 1" >&2
    exit 2
fi
if [[ "$ALLOW_STORAGE_MIGRATION" != 0 && "$ALLOW_STORAGE_MIGRATION" != 1 ]]; then
    echo "ERROR: ALLOW_STORAGE_PROFILE_MIGRATION 必须是 0 或 1" >&2
    exit 2
fi
if [[ "$COMPRESSION" != none && "$COMPRESSION" != zlib ]]; then
    echo "ERROR: compression 只支持 none 或 zlib (实际: '$COMPRESSION')" >&2
    exit 2
fi
if ! [[ "$SRC_INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]]; then
    echo "ERROR: SRC_INSTANCE 必须是 1..9999999999 的正整数" >&2
    exit 2
fi
if [[ ! "$BASE_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: BASE_NAME 只能用字母/数字/下划线/短横线" >&2
    exit 2
fi

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: seal-base.sh 必须由实际 VM 用户运行；需要挂盘时脚本会单独调用 sudo" >&2
    exit 1
fi
command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: seal 需要 sudo 把最终 base 交给 root 并锁定为只读" >&2
    exit 1
}

IMAGE_ROOT="${CLI_IMAGE_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}}"
IMAGE_ROOT="${IMAGE_ROOT%/}"
[[ -n "$IMAGE_ROOT" ]] || IMAGE_ROOT="/"
VMS_DIR="${CLI_VMS_DIR:-${VMS_DIR:-$IMAGE_ROOT/vms}}"
VMS_DIR="${VMS_DIR%/}"
[[ -n "$VMS_DIR" ]] || VMS_DIR="/"
BASE_DIR="${CLI_BASE_DIR:-${BASE_DIR:-$VMS_DIR/_base}}"
VM_DIR="$VMS_DIR/${SRC_INSTANCE}"
SRC_DISK="$VM_DIR/disk.qcow2"
SOURCE_PROFILE="$VM_DIR/profile"
BASE_FILE="$BASE_DIR/${BASE_NAME}.qcow2"

if [[ ! -f "$SRC_DISK" || -L "$SRC_DISK" ]]; then
    echo "ERROR: 源 disk 必须是普通文件且不能是符号链接: $SRC_DISK" >&2
    exit 1
fi
if [[ "$(stat -c '%h' -- "$SRC_DISK")" != 1 ]]; then
    echo "ERROR: 源 disk 存在其它硬链接，默认清理可能改写其它镜像: $SRC_DISK" >&2
    exit 1
fi
SOURCE_DEVICE_INODE="$(stat -c '%d:%i' -- "$SRC_DISK")"
seal_require_same_source_disk() {
    [[ -f "$SRC_DISK" && ! -L "$SRC_DISK" &&
       "$(stat -c '%h' -- "$SRC_DISK")" == 1 &&
       "$(stat -c '%d:%i' -- "$SRC_DISK")" == "$SOURCE_DEVICE_INODE" ]] || {
        echo "ERROR: 源 disk 在 seal 期间被替换或新增硬链接: $SRC_DISK" >&2
        return 1
    }
}
if [[ ! -s "$SOURCE_PROFILE" || -L "$SOURCE_PROFILE" ]]; then
    echo "ERROR: 源实例缺少非空硬件 profile: $SOURCE_PROFILE" >&2
    echo "       无法证明源系统盘的 Guest 型号、总线与容量，拒绝 seal。" >&2
    exit 1
fi
if [[ -e "$BASE_FILE" || -L "$BASE_FILE" ]]; then
    echo "ERROR: $BASE_FILE 已存在 —— 拒绝覆盖" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/sv-instance-lock.sh
source "$SCRIPT_DIR/lib/sv-instance-lock.sh"
# shellcheck source=lib/sv-qemu-process.sh
source "$SCRIPT_DIR/lib/sv-qemu-process.sh"
# shellcheck source=lib/base-image.sh
source "$SCRIPT_DIR/lib/base-image.sh"
# shellcheck source=lib/sv-sudo-session.sh
source "$SCRIPT_DIR/lib/sv-sudo-session.sh"

# 与 start/stop 共用实例锁，消除“检查完停机状态后 VM 又启动”的 TOCTOU 窗口。
command -v flock >/dev/null 2>&1 || {
    echo "ERROR: seal 需要 util-linux 的 flock" >&2
    exit 1
}
if ! INSTANCE_LOCK="$(sv_instance_lock_path "$SRC_INSTANCE")"; then
    echo "ERROR: 无法创建当前用户的私有实例锁目录" >&2
    exit 1
fi
exec 8>"$INSTANCE_LOCK"
if ! flock -n 8; then
    echo "ERROR: instance $SRC_INSTANCE 正在启动、运行、停止或执行其他生命周期操作" >&2
    exit 1
fi

# 生命周期锁阻止新的 start/stop 并发进入；公共 argv 解析器继续识别持锁机制引入
# 前启动的旧 QEMU，避免用宽泛 pgrep 误报相邻实例，也不受 stale QMP socket 影响。
if sv_qemu_instance_pids "$SRC_INSTANCE" >/dev/null 2>&1; then
    echo "ERROR: instance $SRC_INSTANCE 还在运行" >&2
    echo "  先优雅关机：deploy/scripts/stop-vm.sh $SRC_INSTANCE" >&2
    echo "  或在 guest 内执行 shutdown /s /t 0 并等待 QEMU 进程退出" >&2
    exit 1
fi
# 额外保险：检查 qcow2 是否被任何进程持有
command -v lsof >/dev/null 2>&1 || {
    echo "ERROR: seal 需要 lsof 检查源盘占用状态" >&2
    exit 1
}
LSOF_OUTPUT="$(lsof "$SRC_DISK" 2>/dev/null || true)"
if [[ -n "$LSOF_OUTPUT" ]]; then
    echo "ERROR: $SRC_DISK 被进程持有；seal 会做出不一致 base" >&2
    while IFS= read -r line; do
        printf '    %s\n' "$line" >&2
    done <<<"$LSOF_OUTPUT"
    exit 1
fi

mkdir -p "$BASE_DIR"
if [[ ! -d "$BASE_DIR" || -L "$BASE_DIR" ]]; then
    echo "ERROR: base 目录必须是真实目录: $BASE_DIR" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_IMG="${CLI_QEMU_IMG:-${QEMU_IMG:-$REPO_ROOT/build/qemu-img}}"
if [[ "$QEMU_IMG" != */* ]]; then
    QEMU_IMG="$(command -v -- "$QEMU_IMG" 2>/dev/null || true)"
fi
if [[ -z "$QEMU_IMG" || ! -f "$QEMU_IMG" || ! -x "$QEMU_IMG" ]]; then
    echo "ERROR: 找不到指定的 qemu-img；请构建仓库工具或显式传 --qemu-img=PATH" >&2
    exit 1
fi
QEMU_IMG="$(readlink -e -- "$QEMU_IMG")"
BASE_PUBLISH_HELPER="$SCRIPT_DIR/lib/seal-base-publish.py"
IMAGE_METRICS_HELPER="$SCRIPT_DIR/lib/qemu-image-metrics.py"
[[ -f "$IMAGE_METRICS_HELPER" ]] || {
    echo "ERROR: 缺少 qemu-img JSON 指标解析器: $IMAGE_METRICS_HELPER" >&2
    exit 1
}

seal_read_qcow2_layout() {
    local image="$1" parsed extra

    if ! parsed="$(
        "$QEMU_IMG" check --output=json "$image" |
            python3 "$IMAGE_METRICS_HELPER" check -
    )"; then
        echo "ERROR: qcow2 布局检查失败: $image" >&2
        return 1
    fi
    read -r SEAL_COMPRESSED_CLUSTERS SEAL_ALLOCATED_CLUSTERS \
        SEAL_FRAGMENTED_CLUSTERS SEAL_TOTAL_CLUSTERS extra <<<"$parsed"
    [[ -z "${extra:-}" && "$SEAL_COMPRESSED_CLUSTERS" =~ ^[0-9]+$ ]] || {
        echo "ERROR: qcow2 布局解析结果不完整: $image" >&2
        return 1
    }
}

# ----------------------------------------------------------------------
# 启动盘容量护栏（封 base 时 fail-fast，而不是等克隆才 WARN）
#
# clone-from-base.sh 要求克隆出的 profile.BOOT_STORAGE_SIZE_BYTES **字节级精确等于** base
# 虚拟容量（base 的 NTFS 只覆盖 base 容量，clone 盘大了尾段没分区 / 小了越界）。
# seal 必须同时证明：
#   1. 源实例严格 profile 声明的实际启动盘容量就是源 disk 容量；
#   2. component NVMe 与 household SATA compatibility 两个启动池各自至少存在
#      一个同容量候选。否则 E5 household 即使碰巧通过 NVMe 护栏，重抽 SATA
#      profile 仍会无解。
# ----------------------------------------------------------------------
source "$SCRIPT_DIR/stealth-lib.sh"
# shellcheck source=lib/base-boot-storage.sh
source "$SCRIPT_DIR/lib/base-boot-storage.sh"
export ALLOW_PLATFORM_COMPATIBILITY="$ALLOW_COMPATIBILITY"
export ALLOW_STORAGE_PROFILE_MIGRATION="$ALLOW_STORAGE_MIGRATION"
export STRICT_HARDWARE=1
echo ">> 严格校验源 profile: $SOURCE_PROFILE"
stealth_load_profile "$SOURCE_PROFILE"
base_boot_storage_load_profile_view

base_image_load_metadata "$QEMU_IMG" "$SRC_DISK"
if [[ "$BASE_IMAGE_FORMAT" != qcow2 ]]; then
    echo "ERROR: 源 disk 必须是 qcow2，实际格式为 $BASE_IMAGE_FORMAT" >&2
    exit 1
fi
BASE_BYTES="$BASE_IMAGE_VIRTUAL_SIZE"
echo ">> base 虚拟容量: $BASE_BYTES bytes ($(numfmt --to=iec --suffix=B "$BASE_BYTES"))"
if [[ "$BASE_BOOT_STORAGE_SIZE_BYTES" != "$BASE_BYTES" ]]; then
    echo "ERROR: 源实例启动盘身份与 disk 虚拟容量不一致，拒绝 seal。" >&2
    echo "       profile $BASE_BOOT_STORAGE_BUS_LABEL $BASE_BOOT_STORAGE_MODEL" >&2
    echo "       BOOT_STORAGE_SIZE_BYTES=$BASE_BOOT_STORAGE_SIZE_BYTES disk=$BASE_BYTES" >&2
    exit 1
fi
echo ">> 源 profile ✓ $BASE_BOOT_STORAGE_BUS_LABEL $BASE_BOOT_STORAGE_MODEL" \
     "($BASE_BOOT_STORAGE_SIZE_BYTES bytes)"

if ! base_boot_storage_require_all_pool_matches "$BASE_BYTES"; then
    echo "ERROR: base 容量没有同时覆盖 NVMe 与 SATA 两类启动池，拒绝 seal。" >&2
    echo "       请把 base 重建为两个已审计目录共同支持的容量后重试。" >&2
    exit 1
fi
echo ">> NVMe 启动池 ✓ ${#BASE_BOOT_NVME_MATCHES[@]} 个同容量型号: ${BASE_BOOT_NVME_MATCHES[*]}"
echo ">> SATA 启动池 ✓ ${#BASE_BOOT_SATA_MATCHES[@]} 个同容量型号: ${BASE_BOOT_SATA_MATCHES[*]}"

seal_require_same_source_disk
if ! "$QEMU_IMG" check -q "$SRC_DISK"; then
    echo "ERROR: 源 disk 在清理前未通过 qemu-img check，拒绝 seal" >&2
    exit 1
fi

BASE_TMP=""
BASE_PUBLISHED=0
BASE_COMMITTED=0
BASE_PUBLISHED_FINGERPRINT=""
BASE_FD_OPEN=0
BASE_FD_PATH="/proc/$$/fd/9"
BASE_PUBLISH_RESULT_TMP=""
seal_cleanup() {
    local status=$?

    trap - EXIT HUP INT TERM
    set +e
    sv_sudo_session_close
    if [[ "$BASE_PUBLISHED" == 1 && "$BASE_COMMITTED" != 1 ]]; then
        base_image_remove_published_fingerprint \
            "$BASE_PUBLISH_HELPER" "$BASE_PUBLISHED_FINGERPRINT" "$BASE_FILE"
    fi
    if [[ -n "$BASE_TMP" && ( -e "$BASE_TMP" || -L "$BASE_TMP" ) ]]; then
        if [[ "$BASE_FD_OPEN" == 0 || "$BASE_TMP" -ef "$BASE_FD_PATH" ]]; then
            rm -f -- "$BASE_TMP"
        else
            echo "WARN: seal staging 路径已被替换，保留未知目录项: $BASE_TMP" >&2
        fi
    fi
    if [[ -n "$BASE_PUBLISH_RESULT_TMP" &&
          ( -e "$BASE_PUBLISH_RESULT_TMP" || -L "$BASE_PUBLISH_RESULT_TMP" ) ]]; then
        rm -f -- "$BASE_PUBLISH_RESULT_TMP"
    fi
    [[ "$BASE_FD_OPEN" == 1 ]] && exec 9<&-
    flock -u 8 2>/dev/null || true
    exec 8>&-
    exit "$status"
}
trap seal_cleanup EXIT
seal_signal_exit() {
    local exit_status="${1:-1}"

    trap - HUP INT TERM
    exit "$exit_status"
}
trap 'seal_signal_exit 129' HUP
trap 'seal_signal_exit 130' INT
trap 'seal_signal_exit 143' TERM

# 先清/WeGame 设备身份，再 convert；base 的压缩布局由显式策略决定。
# 失败就 abort：宁可不出 base，也不出一个所有 clone 共享同一 qimei 的"漏指纹" base。
seal_require_same_source_disk
if (( CLEAN )); then
    echo ">> sudo 授权（整个 seal 过程至多输入一次密码）..."
    sv_sudo_session_open
    echo ">> 清理源 disk 的/WeGame 设备身份（qimei / 登录态 / SDK 缓存 + 注册表）..."
    if ! sv_sudo_session_run_supervised \
            "$SCRIPT_DIR/host-clean-tencent.sh" "$SRC_INSTANCE" --disk "$SRC_DISK" \
            > >(sed 's/^/    /') 2>&1; then
        echo "ERROR: 身份清理失败 —— 拒绝产出可能泄露 qimei 的 base" >&2
        echo "  排查 host-clean-tencent.sh 后重跑；确认无需清理时加 --no-clean" >&2
        exit 1
    fi
else
    echo ">> --no-clean：跳过身份清理（源 disk 原样固化为 base）"
fi

if ! sv_sudo_session_supervise "$QEMU_IMG" check -q "$SRC_DISK"; then
    echo "ERROR: 源 disk 未通过 qemu-img check，拒绝 seal" >&2
    exit 1
fi

if ! MEASURE_FIELDS="$(
    "$QEMU_IMG" measure --output=json -O qcow2 "$SRC_DISK" |
        python3 "$IMAGE_METRICS_HELPER" measure -
)"; then
    echo "ERROR: 无法计算 base convert 的空间上界" >&2
    exit 1
fi
read -r CONVERT_REQUIRED CONVERT_FULLY_ALLOCATED MEASURE_EXTRA <<<"$MEASURE_FIELDS"
if [[ -n "${MEASURE_EXTRA:-}" || ! "$CONVERT_REQUIRED" =~ ^[1-9][0-9]*$ ||
      ! "$CONVERT_FULLY_ALLOCATED" =~ ^[1-9][0-9]*$ ||
      "$CONVERT_REQUIRED" -gt 4611686018427387903 ]]; then
    echo "ERROR: qemu-img measure 返回了不可安全计算的容量" >&2
    exit 1
fi
read -r FS_TOTAL FS_AVAILABLE < <(
    LC_ALL=C df -B1 --output=size,avail -- "$BASE_DIR" | tail -n 1
)
if [[ ! "$FS_TOTAL" =~ ^[1-9][0-9]*$ || ! "$FS_AVAILABLE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: 无法读取 base 目标文件系统可用空间: $BASE_DIR" >&2
    exit 1
fi
SPACE_RESERVE=$((4 * 1024 * 1024 * 1024))
(( FS_TOTAL / 100 > SPACE_RESERVE )) && SPACE_RESERVE=$((FS_TOTAL / 100))
(( CONVERT_REQUIRED / 10 > SPACE_RESERVE )) &&
    SPACE_RESERVE=$((CONVERT_REQUIRED / 10))
SPACE_NEEDED=$((CONVERT_REQUIRED * 2 + SPACE_RESERVE))
if (( FS_AVAILABLE < SPACE_NEEDED )); then
    echo "ERROR: base convert 空间不足；staging+原子发布峰值需要安全余量" >&2
    echo "       可用=$FS_AVAILABLE bytes，至少需要=$SPACE_NEEDED bytes" >&2
    exit 1
fi

echo ">> 源 disk: $SRC_DISK ($(numfmt --to=iec --suffix=B "$(stat -c%s "$SRC_DISK")"))"
echo ">> 目标 base: $BASE_FILE"
echo ">> convert 布局: compression=$COMPRESSION；空间门禁 $(numfmt --to=iec "$SPACE_NEEDED") / 可用 $(numfmt --to=iec "$FS_AVAILABLE")"
COMPRESS_ARGS=()
if [[ "$COMPRESSION" == zlib ]]; then
    COMPRESS_ARGS=(-c -o compression_type=zlib)
fi
BASE_TMP="$(mktemp -- "$BASE_DIR/.${BASE_NAME}.qcow2.seal.XXXXXX")"
sv_sudo_session_supervise \
    "$QEMU_IMG" convert -p -O qcow2 "${COMPRESS_ARGS[@]}" "$SRC_DISK" "$BASE_TMP"
exec 9<"$BASE_TMP"
BASE_FD_OPEN=1
BASE_VALIDATED_FINGERPRINT="$(
    python3 "$BASE_PUBLISH_HELPER" fingerprint "$BASE_FD_PATH"
)"
base_image_require_standalone_qcow2 "$QEMU_IMG" "$BASE_FD_PATH"
seal_read_qcow2_layout "$BASE_FD_PATH"
if [[ "$COMPRESSION" == none && "$SEAL_COMPRESSED_CLUSTERS" != 0 ]]; then
    echo "ERROR: 未压缩策略仍产出了 $SEAL_COMPRESSED_CLUSTERS 个 compressed cluster" >&2
    exit 1
fi
if [[ "$BASE_VALIDATED_FINGERPRINT" != "$(
        python3 "$BASE_PUBLISH_HELPER" fingerprint "$BASE_FD_PATH"
    )" ]]; then
    echo "ERROR: convert staging 在 qcow2 校验期间发生变化" >&2
    exit 1
fi
if [[ "$BASE_IMAGE_VIRTUAL_SIZE" != "$BASE_BYTES" ]]; then
    echo "ERROR: convert 后 base 虚拟容量变化，拒绝发布" >&2
    exit 1
fi
chmod 0444 "$BASE_FD_PATH"
PUBLISH_SOURCE_FINGERPRINT="$(
    python3 "$BASE_PUBLISH_HELPER" fingerprint "$BASE_FD_PATH"
)"
if (( ! CLEAN )); then
    echo ">> sudo 授权（整个 seal 过程至多输入一次密码）..."
    sv_sudo_session_open
else
    sv_sudo_session_refresh
fi
BASE_PUBLISH_RESULT_TMP="$(
    mktemp -- "$BASE_DIR/.${BASE_NAME}.publish-result.XXXXXX"
)"
BASE_PUBLISHED=1
sv_sudo_session_run_supervised \
    python3 "$BASE_PUBLISH_HELPER" publish \
    "$BASE_FD_PATH" "$BASE_FILE" "$PUBLISH_SOURCE_FINGERPRINT" \
    >"$BASE_PUBLISH_RESULT_TMP"
mapfile -t BASE_PUBLISH_RESULT_LINES <"$BASE_PUBLISH_RESULT_TMP"
if (( ${#BASE_PUBLISH_RESULT_LINES[@]} != 1 )) ||
   [[ -z "${BASE_PUBLISH_RESULT_LINES[0]}" ]]; then
    echo "ERROR: base 发布 helper 未返回唯一 fingerprint" >&2
    exit 1
fi
BASE_PUBLISHED_FINGERPRINT="${BASE_PUBLISH_RESULT_LINES[0]}"
rm -f -- "$BASE_PUBLISH_RESULT_TMP"
BASE_PUBLISH_RESULT_TMP=""
sv_sudo_session_close
base_image_require_standalone_qcow2 "$QEMU_IMG" "$BASE_FILE"
seal_read_qcow2_layout "$BASE_FILE"
if [[ "$COMPRESSION" == none && "$SEAL_COMPRESSED_CLUSTERS" != 0 ]]; then
    echo "ERROR: 最终 base 不符合未压缩布局策略" >&2
    exit 1
fi
if [[ "$BASE_IMAGE_VIRTUAL_SIZE" != "$BASE_BYTES" ||
      "$(stat -c '%u:%a' -- "$BASE_FILE")" != 0:444 ||
      "$BASE_PUBLISHED_FINGERPRINT" != "$(
          python3 "$BASE_PUBLISH_HELPER" fingerprint "$BASE_FILE"
      )" ]]; then
    echo "ERROR: 无法把最终 base 密封为 root-owned 0444: $BASE_FILE" >&2
    exit 1
fi
rm -f -- "$BASE_TMP"
BASE_TMP=""
exec 9<&-
BASE_FD_OPEN=0
BASE_COMMITTED=1

echo ""
echo "=== Done ==="
echo "  base 镜像: $BASE_FILE"
echo "  size:     $(numfmt --to=iec --suffix=B "$(stat -c%s "$BASE_FILE")")"
printf '  layout:   compression=%s compressed=%s allocated=%s fragmented=%s total=%s\n' \
    "$COMPRESSION" "$SEAL_COMPRESSED_CLUSTERS" "$SEAL_ALLOCATED_CLUSTERS" \
    "$SEAL_FRAGMENTED_CLUSTERS" "$SEAL_TOTAL_CLUSTERS"
echo ""
echo "下一步 — 用 clone-from-base.sh 创建新 instance:"
NEXT_CLONE_FLAGS=("--vms-dir=$VMS_DIR" "--qemu-img=$QEMU_IMG")
if [[ "$ALLOW_COMPATIBILITY" == 1 ||
      "${PLATFORM_STATUS:-}" == compatibility ]]; then
    NEXT_CLONE_FLAGS+=("--allow-platform-compatibility")
fi
if [[ "$ALLOW_STORAGE_MIGRATION" == 1 ]]; then
    NEXT_CLONE_FLAGS+=("--migrate-storage-profile")
fi
printf '  sudo %q %q <NEW_INSTANCE>' "$SCRIPT_DIR/clone-from-base.sh" "$BASE_FILE"
printf ' %q' "${NEXT_CLONE_FLAGS[@]}"
printf '\n'
