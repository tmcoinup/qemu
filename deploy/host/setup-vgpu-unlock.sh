#!/usr/bin/env bash
# setup-vgpu-unlock.sh — 构建 vgpu_unlock-rs 并接入 NVIDIA vGPU 守护进程
#
# 自动处理:
#   * rust/cargo 缺失时用 rustup 装到用户级 ($HOME/.cargo)
#   * cargo build 以普通用户身份跑（不污染 root 的 ~/.cargo）
#   * 构建产物 install 到 /opt/vgpu_unlock/ 并注入 systemd LD_PRELOAD
#
# 要求:
#   * NVIDIA vGPU R535，或已实机验证的 R580.159.01 host driver
#   * RM FB 身份按 R535(436B)/R580(1028B) 与精确 type-info ABI fail-closed
#   * 物理 GPU 在 vfio/mdev 框架下 (mdev_supported_types 出现)

set -euo pipefail

REPO=${REPO:-https://github.com/mbilker/vgpu_unlock-rs}
INSTALL_DIR=${INSTALL_DIR:-/opt/vgpu_unlock}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_COMMIT=${UPSTREAM_COMMIT:-71ec870d4b456c9a8013c114a57372b1a60d36ca}
G11_PATCH=${G11_PATCH:-$here/patches/vgpu-unlock-rs-g11.patch}
G11_R580_PATCH=${G11_R580_PATCH:-$here/patches/vgpu-unlock-rs-g11-r580.diff}
MDEV_ADMIN_INSTALLER=${MDEV_ADMIN_INSTALLER:-$here/install-vgpu-mdev-admin.sh}
MDEV_ADMIN_USER=${VGPU_MDEV_ADMIN_USER:-${SUDO_USER:-$(id -un)}}
BUILD_USER=${G11_BUILD_USER:-${SUDO_USER:-$(id -un)}}
EXPECTED_CONFIG_RS_SHA256=52737179b0526cb29376ae2d9626a7914d1a6b5e789d5be52b662920d02942a0
EXPECTED_LIB_RS_SHA256=c64a959f100900f6b804cbe9d40370e02b33fe36320161d454955b175369ce57
EXPECTED_CTRLA081_RS_SHA256=052bd4d7ceebea5be3c407ed23b6604200509c9a3bb599dc02a16427e38f0d2f
EXPECTED_CTRLA082_RS_SHA256=466e3507baaf8ca79a6a2d2fcf531a5c813c1d53dbbdec346aed0b697657d1dd
BASE_CONFIG_RS_SHA256=ae1cab431968e031f433f540bf6973b67caa5a8c1c26987abe5af8d11c1c2ed0
BASE_LIB_RS_SHA256=65fafddfbdcdd13a0288ec0c1335598bfff8404afa32e347f4f6ab6aa9fa8e49
BASE_CTRLA081_RS_SHA256=0ca58bcf29dcc6750ed1761d5b94431aa476bcc61381f38ca998b806efab9465
BASE_CTRLA082_RS_SHA256=edf489a8e979a8da348d5070e0a1c67f5612dedef4d2c636492151ea9d5f7ed8
RESTART_MANAGER=0
R580_UNLOCK_MODE=native
INSTALL_TRANSACTION_ACTIVE=0
LIB_PREEXISTED=0
PROFILE_PREEXISTED=0
CONFIG_PREEXISTED=0
STATE_PREEXISTED=0
DROPIN_PREEXISTED=0
MANAGER_RESTART_ATTEMPTED=0
TMP=

usage() {
    cat <<'EOF'
用法: setup-vgpu-unlock.sh [--restart-manager] [--r580-consumer-lab]

默认只构建、测试、备份并安装，不打断正在运行的 vGPU。
--restart-manager 仅在没有 QEMU 占用 mdev 时重启 nvidia-vgpu-mgr。
R580 只用于已经实机验证的 V100/vGPU 19.5 路径，并固定保持原生能力
（unlock=false）。RTX 2080/2080 Ti 生产路径固定使用 R535。
--r580-consumer-lab 只供本机母盘暂存实验；它会启用消费卡 capability Hook，
但该组合已出现 XID 43/TDR，不能作为生产通过证明。
EOF
}

while (($#)); do
    case "$1" in
        --restart-manager) RESTART_MANAGER=1 ;;
        --r580-consumer-lab) R580_UNLOCK_MODE=consumer-lab ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# sudo wrapper：优先用已激活 ticket，其次 SUDO_PASSWORD 环境变量。
sudo_run() {
    if ((EUID == 0)); then
        "$@"
    elif sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@"
    else
        echo "需要 sudo 权限: 先 'sudo -v' 或设 SUDO_PASSWORD=xxx 再跑" >&2
        return 1
    fi
}

if ((EUID == 0)) && [[ "$BUILD_USER" != root ]]; then
    [[ "$BUILD_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
        echo "无效的 Hook 构建用户: $BUILD_USER" >&2
        exit 1
    }
    BUILD_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
    [[ "$BUILD_HOME" == /* && -d "$BUILD_HOME" ]] || {
        echo "无法解析 Hook 构建用户 HOME: $BUILD_USER" >&2
        exit 1
    }
    build_run() {
        sudo -u "$BUILD_USER" env \
            HOME="$BUILD_HOME" USER="$BUILD_USER" LOGNAME="$BUILD_USER" \
            PATH="$BUILD_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
            "$@"
    }
else
    BUILD_HOME=$HOME
    build_run() { "$@"; }
fi

rollback_runtime_install() {
    echo "安装未完成，恢复注入库和 systemd drop-in" >&2
    if ((LIB_PREEXISTED)); then
        sudo_run install -o root -g root -m 0644 \
            "$BACKUP_DIR/libvgpu_unlock_rs.so" "$LIB_DST" || true
    else
        sudo_run rm -f -- "$LIB_DST" || true
    fi
    if ((DROPIN_PREEXISTED)); then
        sudo_run install -o root -g root -m 0644 \
            "$BACKUP_DIR/vgpu_unlock.conf" "$SYSTEMD_DROPIN" || true
    else
        sudo_run rm -f -- "$SYSTEMD_DROPIN" || true
    fi
    ((PROFILE_PREEXISTED)) || \
        sudo_run rm -f -- /etc/vgpu_unlock/profile_override.toml || true
    if ((CONFIG_PREEXISTED)); then
        sudo_run install -o root -g root -m 0644 \
            "$BACKUP_DIR/config.toml" "$CONFIG_DST" || true
    else
        sudo_run rm -f -- "$CONFIG_DST" || true
    fi
    if ((STATE_PREEXISTED)); then
        sudo_run install -o root -g root -m 0644 \
            "$BACKUP_DIR/g11-hook.state" "$STATE_DST" || true
    else
        sudo_run rm -f -- "$STATE_DST" || true
    fi
    sudo_run systemctl daemon-reload || true
    if ((MANAGER_RESTART_ATTEMPTED)); then
        sudo_run systemctl restart nvidia-vgpu-mgr.service || true
    fi
}

setup_exit() {
    local status=$?
    trap - EXIT
    [[ -z "$TMP" ]] || rm -f -- "$TMP"
    if ((status != 0 && INSTALL_TRANSACTION_ACTIVE)); then
        rollback_runtime_install
    fi
    exit "$status"
}

# 优先复用 /opt/vgpu_unlock-rs (若已 chown 到本用户可写)，否则落到 $HOME/src
if [[ -z "${BUILD_DIR:-}" ]]; then
    if [[ -d /opt/vgpu_unlock-rs && -w /opt/vgpu_unlock-rs ]]; then
        BUILD_DIR=/opt/vgpu_unlock-rs
    else
        BUILD_DIR=$HOME/src/vgpu_unlock-rs
    fi
fi

# ─── 装 rust/cargo ─────────────────────────────────────────────────────────
if ! build_run sh -c 'command -v cargo >/dev/null 2>&1'; then
    echo "[pre] 未检测到 cargo，安装 rustup 到 $BUILD_USER 的用户目录"
    if ! command -v curl >/dev/null; then
        sudo_run apt-get update -qq
        sudo_run apt-get install -yqq curl
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        build_run sh -s -- -y --profile minimal --default-toolchain stable
fi
build_run sh -c 'command -v cargo >/dev/null 2>&1' || {
    echo "cargo 对构建用户 $BUILD_USER 仍不可用" >&2
    exit 1
}

[[ -f "$G11_PATCH" && ! -L "$G11_PATCH" ]] || {
    echo "G-11 vgpu_unlock patch 缺失或不安全: $G11_PATCH" >&2
    exit 1
}
[[ -f "$G11_R580_PATCH" && ! -L "$G11_R580_PATCH" ]] || {
    echo "G-11 R580 ABI patch 缺失或不安全: $G11_R580_PATCH" >&2
    exit 1
}
[[ -x "$MDEV_ADMIN_INSTALLER" && ! -L "$MDEV_ADMIN_INSTALLER" ]] || {
    echo "G-11 mdev admin installer 缺失或不安全: $MDEV_ADMIN_INSTALLER" >&2
    exit 1
}

echo "[1/6] 准备固定上游 $UPSTREAM_COMMIT: $REPO → $BUILD_DIR"
build_run mkdir -p "$(dirname "$BUILD_DIR")"
if [[ ! -d "$BUILD_DIR/.git" ]]; then
    build_run git clone "$REPO" "$BUILD_DIR"
    build_run git -C "$BUILD_DIR" checkout --detach "$UPSTREAM_COMMIT"
fi
[[ "$(build_run git -C "$BUILD_DIR" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || {
    echo "拒绝在非固定上游上构建: $(build_run git -C "$BUILD_DIR" rev-parse HEAD)" >&2
    echo "期望: $UPSTREAM_COMMIT；请另设空 BUILD_DIR，现有源码不会被覆盖。" >&2
    exit 1
}

refresh_source_hashes() {
    config_rs_sha=$(sha256sum "$BUILD_DIR/src/config.rs" | awk '{print $1}')
    lib_rs_sha=$(sha256sum "$BUILD_DIR/src/lib.rs" | awk '{print $1}')
    ctrla081_rs_sha=$(sha256sum "$BUILD_DIR/src/nvidia/ctrla081.rs" | awk '{print $1}')
    ctrla082_rs_sha=$(sha256sum "$BUILD_DIR/src/nvidia/ctrla082.rs" | awk '{print $1}')
}

source_hashes_match() {
    [[ "$config_rs_sha" == "$1" && "$lib_rs_sha" == "$2" &&
       "$ctrla081_rs_sha" == "$3" && "$ctrla082_rs_sha" == "$4" ]]
}

source_tree_has_only_reviewed_paths() {
    local changed

    build_run git -C "$BUILD_DIR" diff --cached --quiet -- || return 1
    while IFS= read -r changed; do
        case "$changed" in
            src/config.rs|src/lib.rs|src/nvidia/ctrla081.rs|src/nvidia/ctrla082.rs) ;;
            *) return 1 ;;
        esac
    done < <(build_run git -C "$BUILD_DIR" diff --name-only --)
}

refresh_source_hashes
if source_hashes_match \
        "$EXPECTED_CONFIG_RS_SHA256" "$EXPECTED_LIB_RS_SHA256" \
        "$EXPECTED_CTRLA081_RS_SHA256" "$EXPECTED_CTRLA082_RS_SHA256"; then
    source_tree_has_only_reviewed_paths || {
        echo "源码含审核范围之外的改动，拒绝构建: $BUILD_DIR" >&2
        exit 1
    }
    echo "[1/6] G-11 R535/R580.159 patch 已存在且四文件哈希匹配"
elif source_hashes_match \
        "$BASE_CONFIG_RS_SHA256" "$BASE_LIB_RS_SHA256" \
        "$BASE_CTRLA081_RS_SHA256" "$BASE_CTRLA082_RS_SHA256"; then
    source_tree_has_only_reviewed_paths || {
        echo "旧 R535 G-11 源码含审核范围之外的改动，拒绝升级: $BUILD_DIR" >&2
        exit 1
    }
    build_run git -C "$BUILD_DIR" apply --check "$G11_R580_PATCH"
    build_run git -C "$BUILD_DIR" apply "$G11_R580_PATCH"
    echo "[1/6] 精确识别旧 R535 G-11 源码，已追加 R580.159 ABI/运行时保护"
else
    if ! build_run git -C "$BUILD_DIR" diff --quiet -- ||
            ! build_run git -C "$BUILD_DIR" diff --cached --quiet --; then
        echo "源码工作树不干净，拒绝覆盖: $BUILD_DIR" >&2
        exit 1
    fi
    build_run git -C "$BUILD_DIR" apply --check "$G11_PATCH"
    build_run git -C "$BUILD_DIR" apply "$G11_PATCH"
    build_run git -C "$BUILD_DIR" apply --check "$G11_R580_PATCH"
    build_run git -C "$BUILD_DIR" apply "$G11_R580_PATCH"
fi
refresh_source_hashes
source_hashes_match \
    "$EXPECTED_CONFIG_RS_SHA256" "$EXPECTED_LIB_RS_SHA256" \
    "$EXPECTED_CTRLA081_RS_SHA256" "$EXPECTED_CTRLA082_RS_SHA256" || {
    echo "G-11 三 ABI 源码哈希复检失败，拒绝构建: $BUILD_DIR" >&2
    exit 1
}
build_run git -C "$BUILD_DIR" --no-pager diff --check

DRIVER_VERSION=$(cat /sys/module/nvidia/version 2>/dev/null || true)
case "$DRIVER_VERSION" in
    535.*) DRIVER_FAMILY=r535 ;;
    580.159.01) DRIVER_FAMILY=r580 ;;
    *)
        echo "拒绝注入未经验证的 NVIDIA host driver：${DRIVER_VERSION:-未加载}（仅允许 535.x 或 580.159.01）" >&2
        exit 1
        ;;
esac
DRIVER_LICENSE=$(modinfo -F license nvidia 2>/dev/null | head -n 1 || true)
[[ "$DRIVER_LICENSE" == NVIDIA ]] || {
    echo "拒绝使用 NVIDIA open kernel module（license=${DRIVER_LICENSE:-unknown}）；G-11 vGPU 只验证了官方闭源 RM 模块" >&2
    exit 1
}

echo "[2/6] cargo fmt/test/build（用户身份）"
# The single-quoted program is intentionally expanded by the child shell,
# where G11_BUILD_DIR is present in its environment.
# shellcheck disable=SC2016
build_run env G11_BUILD_DIR="$BUILD_DIR" sh -c '
    cd "$G11_BUILD_DIR" &&
    cargo fmt -- --check && cargo test && cargo build --release
'

LIB_SRC="$BUILD_DIR/target/release/libvgpu_unlock_rs.so"
LIB_DST="$INSTALL_DIR/libvgpu_unlock_rs.so"
CONFIG_DST=/etc/vgpu_unlock/config.toml
STATE_DST=/etc/vgpu_unlock/g11-hook.state
SYSTEMD_DROPIN=/etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
[[ -f "$LIB_SRC" ]] || { echo "产物缺失: $LIB_SRC" >&2; exit 1; }

if (( RESTART_MANAGER )); then
    active_mdev_pids=()
    for cmdline in /proc/[0-9]*/cmdline; do
        [[ -r "$cmdline" ]] || continue
        if grep -aFq -- '/sys/bus/mdev/devices/' "$cmdline" 2>/dev/null; then
            pid=${cmdline#/proc/}
            active_mdev_pids+=("${pid%/cmdline}")
        fi
    done
    ((${#active_mdev_pids[@]} == 0)) || {
        echo "拒绝重启 nvidia-vgpu-mgr：mdev 正被 PID ${active_mdev_pids[*]} 占用" >&2
        echo "请先正常关闭对应 VM，再重跑 --restart-manager。" >&2
        exit 1
    }
    if find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -print -quit \
            2>/dev/null | grep -q .; then
        echo "拒绝重启 nvidia-vgpu-mgr：sysfs 中仍有活动 mdev；请先正常关闭全部 vGPU VM" >&2
        exit 1
    fi
fi

echo "[3/6] 备份并安装 $INSTALL_DIR/libvgpu_unlock_rs.so"
sudo_run install -d -m 0755 "$INSTALL_DIR" /etc/vgpu_unlock
BACKUP_DIR="$INSTALL_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
sudo_run install -d -m 0700 "$INSTALL_DIR/backups" "$BACKUP_DIR"
if sudo_run test -f "$LIB_DST"; then
    sudo_run cp -a -- "$LIB_DST" "$BACKUP_DIR/libvgpu_unlock_rs.so"
    LIB_PREEXISTED=1
fi
if sudo_run test -e /etc/vgpu_unlock/profile_override.toml; then
    PROFILE_PREEXISTED=1
fi
if sudo_run test -f "$CONFIG_DST"; then
    sudo_run cp -a -- "$CONFIG_DST" "$BACKUP_DIR/config.toml"
    CONFIG_PREEXISTED=1
fi
if sudo_run test -f "$STATE_DST"; then
    sudo_run cp -a -- "$STATE_DST" "$BACKUP_DIR/g11-hook.state"
    STATE_PREEXISTED=1
fi
if sudo_run test -f "$SYSTEMD_DROPIN"; then
    sudo_run cp -a -- "$SYSTEMD_DROPIN" "$BACKUP_DIR/vgpu_unlock.conf"
    DROPIN_PREEXISTED=1
fi
INSTALL_TRANSACTION_ACTIVE=1
trap setup_exit EXIT

sudo_run install -m 0644 "$LIB_SRC" "$LIB_DST"
if ((PROFILE_PREEXISTED)); then
    echo "[3/6] preserving existing profile_override.toml (includes runtime per-mdev identities)"
else
    sudo_run install -m 0644 "$here/profile_override.toml" \
        /etc/vgpu_unlock/profile_override.toml
fi
if [[ "$DRIVER_FAMILY" == r580 ]]; then
    TMP=$(mktemp)
    if [[ "$R580_UNLOCK_MODE" == consumer-lab ]]; then
        cat >"$TMP" <<'EOF'
# Managed by G-11 for the explicitly requested RTX R580 staging lab.
# This only exposes consumer vGPU capability for temporary mother-image work.
# Runtime XID 43/TDR was observed; never treat this policy as production-ready.
observe_only = false
unlock = true
unlock_migration = false
EOF
    else
        cat >"$TMP" <<'EOF'
# Managed by G-11 for the exact R580.159.01 V100/vGPU 19.5 path.
# Native V100 capability remains untouched; only reviewed per-mdev RM FB fields
# from profile_override.toml may be changed.
observe_only = false
unlock = false
unlock_migration = false
EOF
    fi
    sudo_run install -o root -g root -m 0644 "$TMP" "$CONFIG_DST"
    rm -f -- "$TMP"
    TMP=
else
    TMP=$(mktemp)
    cat >"$TMP" <<'EOF'
# Managed by G-11 for the R535 RTX unlock path.
observe_only = false
unlock = true
unlock_migration = false
EOF
    sudo_run install -o root -g root -m 0644 "$TMP" "$CONFIG_DST"
    rm -f -- "$TMP"
    TMP=
fi

echo "[4/6] 注入 LD_PRELOAD 到 nvidia-vgpu-mgr.service"
sudo_run install -d -m 0755 /etc/systemd/system/nvidia-vgpu-mgr.service.d
TMP=$(mktemp)
cat > "$TMP" <<EOF
[Service]
Environment=LD_PRELOAD=$LIB_DST
Environment=RUST_BACKTRACE=1
EOF
sudo_run install -m 0644 "$TMP" "$SYSTEMD_DROPIN"
rm -f "$TMP"
TMP=
sudo_run systemctl daemon-reload

if (( RESTART_MANAGER )); then
    echo "[5/6] 重启并验证 nvidia-vgpu-mgr"
    MANAGER_RESTART_ATTEMPTED=1
    if ! sudo_run systemctl restart nvidia-vgpu-mgr.service ||
            ! sudo_run systemctl is-active --quiet nvidia-vgpu-mgr.service; then
        echo "manager 启动失败" >&2
        exit 1
    fi
else
    echo "[5/6] 未重启 manager；当前 VM 不受影响"
fi

echo "[6/6] 安装免弹窗、限参的 mdev lifecycle helper"
sudo_run "$MDEV_ADMIN_INSTALLER" --user "$MDEV_ADMIN_USER"

LIB_SHA256=$(sha256sum "$LIB_SRC" | awk '{print $1}')
G11_PATCH_SHA256=$(sha256sum "$G11_PATCH" | awk '{print $1}')
G11_R580_PATCH_SHA256=$(sha256sum "$G11_R580_PATCH" | awk '{print $1}')
TMP=$(mktemp)
{
    echo 'schema=2'
    printf 'driver_family=%s\n' "$DRIVER_FAMILY"
    printf 'driver_version=%s\n' "$DRIVER_VERSION"
    printf 'upstream_commit=%s\n' "$UPSTREAM_COMMIT"
    printf 'config_rs_sha256=%s\n' "$config_rs_sha"
    printf 'lib_rs_sha256=%s\n' "$lib_rs_sha"
    printf 'ctrla081_rs_sha256=%s\n' "$ctrla081_rs_sha"
    printf 'ctrla082_rs_sha256=%s\n' "$ctrla082_rs_sha"
    printf 'g11_patch_sha256=%s\n' "$G11_PATCH_SHA256"
    printf 'r580_patch_sha256=%s\n' "$G11_R580_PATCH_SHA256"
    echo 'r580_ram_type_policy=exact-1024mb-only'
    if [[ "$DRIVER_FAMILY" == r580 ]]; then
        printf 'r580_unlock_policy=%s\n' "$R580_UNLOCK_MODE"
    else
        echo 'r535_unlock_policy=consumer'
    fi
    printf 'library_sha256=%s\n' "$LIB_SHA256"
} >"$TMP"
sudo_run install -o root -g root -m 0644 "$TMP" "$STATE_DST"
rm -f -- "$TMP"
TMP=
INSTALL_TRANSACTION_ACTIVE=0

cat <<EOF

✅ vgpu_unlock-rs 已就绪:
    lib        = $LIB_DST
    override   = /etc/vgpu_unlock/profile_override.toml
    policy     = $CONFIG_DST ($DRIVER_FAMILY/$DRIVER_VERSION)
    unlock     = $([[ "$DRIVER_FAMILY" == r580 ]] && printf '%s' "$R580_UNLOCK_MODE" || printf 'consumer')
    state      = $STATE_DST
    mdev admin = /usr/local/libexec/qemu-vgpu-mdev-admin
    systemd d  = /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
    backup     = $BACKUP_DIR

下一步:
    关闭所有 vGPU VM 后运行：$0 --restart-manager
    sudo journalctl -fu nvidia-vgpu-mgr    # 有 'Applying profile override' 行就是成功
EOF
