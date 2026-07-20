#!/usr/bin/env bash
# clone-from-base.sh —— 用 _base/ 里的某个基础镜像快速创建一个新 instance。
#
# 用法：
#   deploy/scripts/clone-from-base.sh <BASE_NAME|BASE_QCOW2> <NEW_INSTANCE>
#       [--allow-platform-compatibility] [--qemu=PATH] [--cpus=2|4]
#       [--migrate-storage-profile]
#       [--image-root=PATH|--vms-dir=PATH|--base-dir=PATH] [--qemu-img=PATH]
#
# 例：
#   deploy/scripts/clone-from-base.sh win10-ltsc-shallow 4
#       -> $VMS_DIR/4/disk.qcow2 (qcow2 backed by base)
#       -> $VMS_DIR/4/profile (重新随机硬件身份)
#
# 工作机制：
#   - qcow2 backing-file: 新 disk 只存增量，base 共享只读
#   - 合法的 UI 预置 profile 会复用，否则随机生成新的完整硬件身份
#   - OVMF NVRAM 也是从 /usr/share/OVMF/OVMF_VARS_4M.fd 重新拷贝
#
# 之后启动：
#   DISPLAY=:1 deploy/scripts/start-vm.sh <NEW_INSTANCE>

set -euo pipefail

# 必须 root：脚本最后两步 (host-fix-gpu-devpkey / host-inject-unattend) 要挂 NTFS。
# 没 root 跑完后用户得手动补跑这两步，容易漏；改成强制提示。
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: 必须以 root 运行（脚本末尾要挂 NTFS 写 hive）" >&2
    echo "" >&2
    printf '  sudo %q' "$0" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    echo "" >&2
    exit 1
fi

CLI_IMAGE_ROOT=""
CLI_VMS_DIR=""
CLI_BASE_DIR=""
CLI_QEMU_IMG=""
CLI_QEMU=""
CLI_CPUS=""
ALLOW_PLATFORM_COMPATIBILITY="${ALLOW_PLATFORM_COMPATIBILITY:-0}"
ALLOW_STORAGE_MIGRATION="${ALLOW_STORAGE_PROFILE_MIGRATION:-0}"
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-root=*) CLI_IMAGE_ROOT="${1#*=}" ;;
        --vms-dir=*)    CLI_VMS_DIR="${1#*=}" ;;
        --base-dir=*)   CLI_BASE_DIR="${1#*=}" ;;
        --qemu-img=*)   CLI_QEMU_IMG="${1#*=}" ;;
        --qemu=*)       CLI_QEMU="${1#*=}" ;;
        --cpus=*)       CLI_CPUS="${1#*=}" ;;
        --allow-platform-compatibility) ALLOW_PLATFORM_COMPATIBILITY=1 ;;
        --migrate-storage-profile) ALLOW_STORAGE_MIGRATION=1 ;;
        --*) echo "ERROR: 未知 flag: $1" >&2; exit 2 ;;
        *) POS+=("$1") ;;
    esac
    shift
done

BASE_ARG="${POS[0]:-}"
NEW_INSTANCE="${POS[1]:-}"
if (( ${#POS[@]} > 2 )); then
    echo "ERROR: 参数过多: ${POS[*]:2}" >&2
    exit 2
fi

IMAGE_ROOT="${CLI_IMAGE_ROOT:-${IMAGE_ROOT:-/home/ubuntu/images}}"
IMAGE_ROOT="${IMAGE_ROOT%/}"
[[ -n "$IMAGE_ROOT" ]] || IMAGE_ROOT="/"
VMS_DIR="${CLI_VMS_DIR:-${VMS_DIR:-$IMAGE_ROOT/vms}}"
VMS_DIR="${VMS_DIR%/}"
[[ -n "$VMS_DIR" ]] || VMS_DIR="/"
BASE_DIR="${CLI_BASE_DIR:-${BASE_DIR:-$VMS_DIR/_base}}"

if [[ -z "$BASE_ARG" || -z "$NEW_INSTANCE" ]]; then
    echo "usage: $0 <BASE_NAME|BASE_QCOW2> <NEW_INSTANCE> [--cpus=2|4] [--qemu=PATH]" >&2
    echo "       [--allow-platform-compatibility] [--migrate-storage-profile]" >&2
    echo "       [--image-root=PATH] [--vms-dir=PATH] [--base-dir=PATH] [--qemu-img=PATH]" >&2
    echo "" >&2
    echo "可用 base:" >&2
    find "$BASE_DIR" -maxdepth 1 -type f -name '*.qcow2' -printf '%f\n' \
        2>/dev/null | sed 's|\.qcow2$||;s|^|  - |' >&2
    exit 2
fi
if ! [[ "$NEW_INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]]; then
    echo "ERROR: NEW_INSTANCE 必须是 1..9999999999 的正整数" >&2
    exit 2
fi
case "$ALLOW_PLATFORM_COMPATIBILITY" in
    0|1) ;;
    *)
        echo "ERROR: ALLOW_PLATFORM_COMPATIBILITY 必须是 0 或 1" >&2
        exit 2
        ;;
esac
case "$ALLOW_STORAGE_MIGRATION" in
    0|1) ;;
    *)
        echo "ERROR: ALLOW_STORAGE_PROFILE_MIGRATION 必须是 0 或 1" >&2
        exit 2
        ;;
esac
CPUS="${CLI_CPUS:-${CPUS:-4}}"
case "$CPUS" in
    2|4) ;;
    *)
        echo "ERROR: clone --cpus 只支持完整家用 SKU 的 2 或 4 线程" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clone-lifecycle.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/base-image.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/clone-postprocess.sh"

if [[ "$BASE_ARG" == */* || "$BASE_ARG" == *.qcow2 ]]; then
    BASE_FILE="$BASE_ARG"
    BASE_NAME="$(basename "$BASE_FILE")"
    BASE_NAME="${BASE_NAME%.qcow2}"
else
    if [[ ! "$BASE_ARG" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: BASE_NAME 只能用字母/数字/下划线/短横线" >&2
        exit 2
    fi
    BASE_NAME="$BASE_ARG"
    BASE_FILE="$BASE_DIR/${BASE_NAME}.qcow2"
fi
if [[ ! -f "$BASE_FILE" ]]; then
    echo "ERROR: $BASE_FILE 不存在" >&2
    exit 1
fi
if ! BASE_FILE="$(readlink -e -- "$BASE_FILE")" || [[ ! -f "$BASE_FILE" ]]; then
    echo "ERROR: 无法解析 base 的真实普通文件路径: $BASE_FILE" >&2
    exit 1
fi
BASE_MODE="$(stat -c '%a' -- "$BASE_FILE")"
BASE_OWNER="$(stat -c '%u' -- "$BASE_FILE")"
if [[ "$BASE_OWNER" != 0 || "$BASE_MODE" != 444 ]]; then
    echo "ERROR: base 必须由 seal-base.sh 密封为 root-owned 0444: $BASE_FILE" >&2
    echo "       actual owner=$BASE_OWNER mode=$BASE_MODE" >&2
    echo "       旧 base 请先停止所有引用它的 VM，确认无进程持有后执行：" >&2
    printf '       sudo chown root:root -- %q && sudo chmod 0444 -- %q\n' \
        "$BASE_FILE" "$BASE_FILE" >&2
    exit 1
fi
BASE_FINGERPRINT="$(stat -c '%d:%i:%s:%y' -- "$BASE_FILE")"

if [[ -n "$CLI_QEMU_IMG" ]]; then
    QEMU_IMG="$CLI_QEMU_IMG"
fi
: "${QEMU_IMG:=$REPO_ROOT/build/qemu-img}"
if [[ "$QEMU_IMG" != */* ]]; then
    QEMU_IMG="$(command -v -- "$QEMU_IMG" 2>/dev/null || true)"
fi
if [[ -z "$QEMU_IMG" || ! -f "$QEMU_IMG" || ! -x "$QEMU_IMG" ]]; then
    echo "ERROR: 找不到指定的 qemu-img；请构建仓库工具或显式传 --qemu-img=PATH" >&2
    exit 1
fi
QEMU_IMG="$(readlink -e -- "$QEMU_IMG")"
base_image_require_standalone_qcow2 "$QEMU_IMG" "$BASE_FILE"
BASE_BYTES="$BASE_IMAGE_VIRTUAL_SIZE"
OVMF_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
if [[ ! -r "$OVMF_TEMPLATE" ]]; then
    echo "ERROR: 缺少可读的 OVMF NVRAM 模板: $OVMF_TEMPLATE" >&2
    exit 1
fi

# clone 与 start-vm 必须使用同一份只读宿主能力和真实 vCPU realize 门禁。
# 先加载 KVM 能力，再创建增量盘；具体候选的 realize 会在 pick/save 事务内完成，
# 因而无法实现的 CPU 不会落成 profile。
if [[ -n "$CLI_QEMU" ]]; then
    QEMU="$CLI_QEMU"
fi
if [[ -n "${QEMU:-}" ]]; then
    :
else
    QEMU="$REPO_ROOT/build/qemu-system-x86_64"
fi
if [[ "$QEMU" != */* ]]; then
    QEMU="$(command -v -- "$QEMU" 2>/dev/null || true)"
fi
if [[ -z "$QEMU" || ! -f "$QEMU" || ! -x "$QEMU" ]]; then
    echo "ERROR: 找不到指定的 patched qemu-system-x86_64" >&2
    echo "       请先构建仓库 QEMU，或显式传 --qemu=PATH" >&2
    exit 1
fi
QEMU="$(readlink -e -- "$QEMU")"

# 所有创建期能力判断必须使用最终启动 VM 的普通用户视角。先解析 sudo/pkexec 的
# 原始 UID，并明确拒绝 root 路径；随后 KVM 探测与每个 QEMU CPU smoke 都通过
# 该用户执行，避免 root-only /dev/kvm 或仅 root 可执行的自定义 QEMU 假通过。
ORIG_USER="${SUDO_USER:-}"
if [[ -z "$ORIG_USER" && -n "${PKEXEC_UID:-}" ]]; then
    ORIG_USER="$(id -nu "$PKEXEC_UID" 2>/dev/null || true)"
fi
if [[ -z "$ORIG_USER" ]]; then
    echo "ERROR: 无法识别实际 VM 用户；请由该用户通过 sudo 调用 clone" >&2
    exit 1
fi
if ! ORIG_UID="$(id -u "$ORIG_USER" 2>/dev/null)"; then
    echo "ERROR: 无法解析 clone 原始用户: $ORIG_USER" >&2
    exit 1
fi
if [[ "$ORIG_UID" == 0 ]]; then
    echo "ERROR: clone 生命周期锁不能使用 root 路径；请从实际 VM 用户执行 sudo" >&2
    exit 1
fi
if ! ORIG_GROUP="$(id -gn "$ORIG_USER" 2>/dev/null)"; then
    echo "ERROR: 无法解析 clone 原始用户组: $ORIG_USER" >&2
    exit 1
fi
if ! ORIG_GID="$(id -g "$ORIG_USER" 2>/dev/null)"; then
    echo "ERROR: 无法解析 clone 原始用户组 ID: $ORIG_USER" >&2
    exit 1
fi

# clone 只产出后续可按严格启动链使用的身份；环境变量不能把创建期 KVM 门禁降级。
STRICT_HARDWARE=1
ALLOW_STORAGE_PROFILE_MIGRATION="$ALLOW_STORAGE_MIGRATION"
export ALLOW_PLATFORM_COMPATIBILITY ALLOW_STORAGE_PROFILE_MIGRATION
export CPUS QEMU STRICT_HARDWARE
clone_lifecycle_require_qemu_caps \
    "$ORIG_USER" "$QEMU" "$QEMU_IMG" "$SCRIPT_DIR/lib/sv-portability.sh"
# shellcheck disable=SC2034 # 由随后加载的宿主能力模块按约定读取。
HERE="$SCRIPT_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/stealth-lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/base-boot-storage.sh"
# 不接受 root 调用方注入的 KVM 结果；创建必须重新证明普通用户能打开真实设备。
unset STEALTH_KVM_AVAILABLE STEALTH_KVM_TSC_CONTROL
unset STEALTH_KVM_GET_TSC_KHZ STEALTH_KVM_TSC_KHZ STEALTH_KVM_ERROR
unset STEALTH_HOST_CPU_PHYS_BITS
SV_HOST_CAPABILITIES_USER="$ORIG_USER"
SV_CPU_REALIZE_USER="$ORIG_USER"
export SV_HOST_CAPABILITIES_USER SV_CPU_REALIZE_USER
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/sv-host-capabilities.sh"
if ! sudo -u "$ORIG_USER" -- test -r "$BASE_FILE"; then
    echo "ERROR: 最终 VM 用户无法读取 base: $BASE_FILE" >&2
    exit 1
fi
if sudo -u "$ORIG_USER" -- test -w "$BASE_FILE"; then
    echo "ERROR: base 对最终 VM 用户仍可写；请先 chmod 0444: $BASE_FILE" >&2
    exit 1
fi

# clone 以 root 离线写盘，但必须与原始用户启动/停止 VM 共用同一把实例锁。
# 先由 ORIG_USER 调用 sv_instance_lock_path 并预建 0600 文件，再由 root 的 FD 8
# 非阻塞持锁。此后才允许检查任何目标 VM 路径，锁一直保留到 EXIT trap 完成 chown。
command -v flock >/dev/null 2>&1 || {
    echo "ERROR: clone 需要 util-linux 的 flock" >&2
    exit 1
}
if ! INSTANCE_LOCK="$(clone_lifecycle_user_lock_path \
        "$ORIG_USER" "$SCRIPT_DIR/lib/sv-instance-lock.sh" "$NEW_INSTANCE")"; then
    echo "ERROR: 无法建立 $ORIG_USER 的实例生命周期锁" >&2
    exit 1
fi
if [[ ! -f "$INSTANCE_LOCK" || -L "$INSTANCE_LOCK" ||
      "$(stat -c '%u' -- "$INSTANCE_LOCK" 2>/dev/null)" != "$ORIG_UID" ||
      "$(stat -c '%a' -- "$INSTANCE_LOCK" 2>/dev/null)" != 600 ]]; then
    echo "ERROR: 原始用户实例锁 owner/type/mode 校验失败: $INSTANCE_LOCK" >&2
    exit 1
fi
exec 8<"$INSTANCE_LOCK"
if [[ ! "$INSTANCE_LOCK" -ef "/proc/$$/fd/8" ||
      "$(stat -Lc '%u' -- "/proc/$$/fd/8" 2>/dev/null)" != "$ORIG_UID" ||
      "$(stat -Lc '%a' -- "/proc/$$/fd/8" 2>/dev/null)" != 600 ]]; then
    echo "ERROR: 实例锁在打开期间被替换或属性变化: $INSTANCE_LOCK" >&2
    exit 1
fi
if ! flock -n 8; then
    echo "ERROR: instance $NEW_INSTANCE 正在启动、运行、停止或克隆" >&2
    exit 1
fi

VM_DIR="$VMS_DIR/${NEW_INSTANCE}"
DISK="$VM_DIR/disk.qcow2"
PROFILE="$VM_DIR/profile"
OVMF_VARS="$VM_DIR/ovmf-vars.fd"
BASE_PIN="$VM_DIR/.base.qcow2"
DISK_TMP=""
OVMF_TMP=""
PROFILE_STAGE=""
PROFILE_BACKUP=""
CLONE_LIFECYCLE_BASE_PIN_TMP=""
CLONE_LIFECYCLE_BASE_PIN_PUBLISHED=0
PROFILE_PUBLISH_MODE="none"
DISK_PUBLISHED=0
OVMF_PUBLISHED=0
CLONE_TRANSACTION_COMMITTED=0
VM_DIR_CREATED=0

# 所有临时文件都位于 VM_DIR，与最终目标同文件系统。失败先回滚本次发布，再清理
# staging，最后 chown；FD 8 在这些动作全部完成后才释放，避免 start/stop 看到
# 半提交状态。成功路径也由同一 trap 保证普通用户可以读取 profile 和写 OVMF。
clone_exit_cleanup() {
    local status=$?
    local temporary

    trap - EXIT
    set +e
    if [[ "$CLONE_TRANSACTION_COMMITTED" != 1 ]]; then
        [[ "$DISK_PUBLISHED" == 1 ]] &&
            clone_lifecycle_remove_published_file "$DISK_TMP" "$DISK"
        [[ "$OVMF_PUBLISHED" == 1 ]] &&
            clone_lifecycle_remove_published_file "$OVMF_TMP" "$OVMF_VARS"
        [[ "$CLONE_LIFECYCLE_BASE_PIN_PUBLISHED" == 1 ]] &&
            clone_lifecycle_remove_published_file \
                "$CLONE_LIFECYCLE_BASE_PIN_TMP" "$BASE_PIN"
        case "$PROFILE_PUBLISH_MODE" in
            created)
                clone_lifecycle_remove_published_file "$PROFILE_STAGE" "$PROFILE"
                ;;
            replaced)
                if [[ -f "$PROFILE_BACKUP" && ! -L "$PROFILE_BACKUP" ]]; then
                    mv -fT -- "$PROFILE_BACKUP" "$PROFILE" || \
                        echo "ERROR: clone 失败后无法恢复原 profile" >&2
                    PROFILE_BACKUP=""
                fi
                ;;
        esac
    fi
    for temporary in \
        "$DISK_TMP" "$OVMF_TMP" "$PROFILE_STAGE" "$PROFILE_BACKUP" \
        "$CLONE_LIFECYCLE_BASE_PIN_TMP"; do
        if [[ -n "$temporary" && ( -e "$temporary" || -L "$temporary" ) ]]; then
            rm -- "$temporary" || \
                echo "WARN: 无法清理 clone 临时文件: $temporary" >&2
        fi
    done
    if [[ "$CLONE_TRANSACTION_COMMITTED" != 1 &&
          "$VM_DIR_CREATED" == 1 &&
          -d "$VM_DIR" && ! -L "$VM_DIR" ]]; then
        if ! rmdir -- "$VM_DIR" 2>/dev/null; then
            echo "WARN: clone 失败后实例目录非空，保留并仅归还目录所有权: $VM_DIR" >&2
            chmod 0700 -- "$VM_DIR" 2>/dev/null || true
            chown -- "$ORIG_UID:$ORIG_GID" "$VM_DIR" 2>/dev/null || true
        fi
    fi
    flock -u 8 2>/dev/null || true
    exec 8<&-
    exit "$status"
}
trap clone_exit_cleanup EXIT

# 一个 VMS_DIR 只允许由同一 VM 用户拥有，确保按 UID 建立的 start/stop 锁不会在
# 多用户间分叉。最终目录不存在时原子创建叶子，竞争创建直接失败，不复用未知目录。
if ! clone_lifecycle_prepare_instance_dir \
        "$ORIG_USER" "$ORIG_UID" "$ORIG_GID" \
        "$VMS_DIR" "$VM_DIR" "$DISK" "$PROFILE" "$OVMF_VARS"; then
    VM_DIR_CREATED="${CLONE_LIFECYCLE_VM_DIR_CREATED:-0}"
    exit 1
fi
VM_DIR_CREATED="$CLONE_LIFECYCLE_VM_DIR_CREATED"

echo ">> base:        $BASE_FILE"
clone_lifecycle_prepare_base_pin \
    "$ORIG_USER" "$BASE_FILE" "$VM_DIR" "$BASE_PIN" "$BASE_FINGERPRINT"
echo ">> base pin:    $BASE_PIN"

# 重新随机 stealth 身份（保证 multi-clone 之间硬件 fingerprint 不同）。
# 如果上层（例如 VMate UI）已经预写了 profile，则优先复用；只有实际启动盘容量
# 跟 base 不一致时才重抽，避免做出 disk size / model size 矛盾的克隆。
echo ">> 准备 stealth profile..."

# 先读 base 容量，让 pick_profile 重抽整机直到选定启动盘容量 = base 容量。
# 原因：base 的 NTFS 只覆盖 base 容量；clone 时 qcow2 resize 比 base 大，
# 多出的尾段没分区 → Win 启动看见 "Preparing Automatic Repair"（disk size
# vs partition layout 不一致）。
# 同样地 clone 容量 < base 也不行（NTFS 会指向越界扇区）。所以严格要 ==。
echo ">> base 容量: $BASE_BYTES bytes ($(numfmt --to=iec --suffix=B "$BASE_BYTES"))"

# profile 先在同目录 staging 上运行完整容量/CPU/KVM 事务。这样 qemu-img 失败也
# 不会改写 UI 预写的最终 profile；只有全部 clone 文件准备好后才统一提交。
PROFILE_STAGE="$(mktemp -- "$VM_DIR/.profile.clone.XXXXXX")"
if [[ -f "$PROFILE" ]]; then
    cp -- "$PROFILE" "$PROFILE_STAGE"
fi
if ! base_boot_storage_prepare_matching_profile \
        "$PROFILE_STAGE" "$BASE_BYTES" 100 _stealth_platform_runtime_preflight; then
    echo "ERROR: 无法为 base 生成容量一致的启动盘 profile，clone 已中止。" >&2
    echo "       未创建增量盘；最终 profile 与已有实例文件保持不变。" >&2
    echo "       请检查启动盘目录、宿主 KVM 能力或 CPU 候选后重试。" >&2
    exit 1
fi
TARGET_BYTES="$BASE_BOOT_STORAGE_SIZE_BYTES"
if [[ "$TARGET_BYTES" != "$BASE_BYTES" ]]; then
    echo "ERROR: profile 启动盘容量与 base 不一致，拒绝发布 clone" >&2
    exit 1
fi
echo ">> profile -> $PROFILE"
stealth_print_profile 2>&1
# pick 已经 export 全部字段；后续容量只读取实际启动盘的 BOOT_STORAGE_*。

# 通过预创建的 0600 同目录临时文件准备 overlay；qemu-img 可以安全重写该普通
# 文件。最终 disk 仍不存在，因此这一步或此前任一预检失败都不会留下 overlay。
DISK_TMP="$(mktemp -- "$VM_DIR/.disk.qcow2.clone.XXXXXX")"
echo ">> 准备增量盘:  $DISK"
BASE_BACKING_RELATIVE="$(realpath --relative-to="$VM_DIR" -- "$BASE_PIN")"
if ! (
    cd "$VM_DIR"
    "$QEMU_IMG" create -f qcow2 -F qcow2 \
        -b "$BASE_BACKING_RELATIVE" "$(basename "$DISK_TMP")" >/dev/null
); then
    echo "ERROR: qemu-img 创建增量盘失败；最终 overlay 未发布" >&2
    exit 1
fi
if [[ "$(stat -c '%d:%i:%s:%y' -- "$BASE_PIN")" != "$BASE_FINGERPRINT" ]]; then
    echo "ERROR: base 在 clone 创建期间被替换或修改，拒绝发布 overlay" >&2
    exit 1
fi
base_image_require_overlay_qcow2 \
    "$QEMU_IMG" "$DISK_TMP" "$BASE_PIN" "$BASE_BYTES"

# 从 stock OVMF 模板准备一份新 NVRAM，同样只写同目录临时普通文件。
OVMF_TMP="$(mktemp -- "$VM_DIR/.ovmf-vars.fd.clone.XXXXXX")"
cp -- "$OVMF_TEMPLATE" "$OVMF_TMP"

# 提交顺序把 disk 放在最后：profile/OVMF 发布失败时没有 overlay；disk 的
# 原子 link 若失败，EXIT trap 会恢复原 profile 并删除本次 OVMF。正常生命周期
# 工具均被 FD 8 串行化，因此成功返回前不会观察到半提交状态。
clone_lifecycle_validate_instance_paths \
    "$VM_DIR" "$DISK" "$PROFILE" "$OVMF_VARS"
if [[ -f "$PROFILE" ]] && cmp -s -- "$PROFILE_STAGE" "$PROFILE"; then
    rm -- "$PROFILE_STAGE"
    PROFILE_STAGE=""
elif [[ -f "$PROFILE" ]]; then
    PROFILE_BACKUP="$(mktemp -- "$VM_DIR/.profile.backup.XXXXXX")"
    cp -p -- "$PROFILE" "$PROFILE_BACKUP"
    PROFILE_PUBLISH_MODE="replaced"
    mv -fT -- "$PROFILE_STAGE" "$PROFILE"
    PROFILE_STAGE=""
else
    PROFILE_PUBLISH_MODE="created"
    clone_lifecycle_publish_no_replace "$PROFILE_STAGE" "$PROFILE"
fi
if [[ -n "$OVMF_TMP" ]]; then
    OVMF_PUBLISHED=1
    clone_lifecycle_publish_no_replace "$OVMF_TMP" "$OVMF_VARS"
fi
DISK_PUBLISHED=1
clone_lifecycle_publish_no_replace "$DISK_TMP" "$DISK"

# 离线修改、二次镜像校验和精确 chown 都属于事务；任一步中断都会由 EXIT trap
# 删除本次 overlay/OVMF，并恢复已有 profile。两个离线步骤失败仍按既有策略降级
# 为带警告的可启动 clone，但不会再伪装成无警告成功。
clone_postprocess_guest "$SCRIPT_DIR" "$VMS_DIR" "$DISK" "$NEW_INSTANCE"
if [[ "$(stat -c '%d:%i:%s:%y' -- "$BASE_PIN")" != "$BASE_FINGERPRINT" ]]; then
    echo "ERROR: base 在 clone 收尾期间被替换或修改，拒绝提交" >&2
    exit 1
fi
base_image_require_overlay_qcow2 \
    "$QEMU_IMG" "$DISK" "$BASE_PIN" "$BASE_BYTES"
clone_lifecycle_validate_base_pin "$BASE_PIN" "$BASE_FINGERPRINT"
clone_lifecycle_assign_output_ownership \
    "$ORIG_UID" "$ORIG_GID" "$VM_DIR_CREATED" "$PROFILE_PUBLISH_MODE" \
    "$VM_DIR" "$DISK" "$PROFILE" "$OVMF_VARS"
echo ">> 输出所有权 -> ${ORIG_USER}:${ORIG_GROUP}"
CLONE_TRANSACTION_COMMITTED=1

# 目录项与所有权均已提交；删除 staging hard-link 不影响最终 inode。
for temporary in \
    "$DISK_TMP" "$OVMF_TMP" "$PROFILE_STAGE" "$PROFILE_BACKUP" \
    "$CLONE_LIFECYCLE_BASE_PIN_TMP"; do
    if [[ -n "$temporary" && ( -e "$temporary" || -L "$temporary" ) ]]; then
        rm -- "$temporary"
    fi
done
DISK_TMP=""
OVMF_TMP=""
PROFILE_STAGE=""
PROFILE_BACKUP=""
CLONE_LIFECYCLE_BASE_PIN_TMP=""
ls -la "$DISK"
if [[ -f "$OVMF_VARS" ]]; then
    echo ">> OVMF NVRAM -> $OVMF_VARS"
fi

clone_print_completion \
    "$NEW_INSTANCE" "$DISK" "$BASE_NAME" "$TARGET_BYTES" \
    "$VMS_DIR" "$SCRIPT_DIR" "$CPUS" "$QEMU" "$QEMU_IMG" \
    "$ALLOW_PLATFORM_COMPATIBILITY" "$ALLOW_STORAGE_MIGRATION" \
    "${PLATFORM_STATUS:-}" "${CLONE_POSTPROCESS_WARNINGS:-0}"
