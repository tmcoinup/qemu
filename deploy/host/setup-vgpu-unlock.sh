#!/usr/bin/env bash
# setup-vgpu-unlock.sh — 构建 vgpu_unlock-rs 并接入 NVIDIA vGPU 守护进程
#
# 自动处理:
#   * rust/cargo 缺失时用 rustup 装到用户级 ($HOME/.cargo)
#   * cargo build 以普通用户身份跑（不污染 root 的 ~/.cargo）
#   * 构建产物 install 到 /opt/vgpu_unlock/ 并注入 systemd LD_PRELOAD
#
# 要求:
#   * NVIDIA vGPU R535 host driver 已安装；RM FB 身份补丁对其他主版本 fail-closed
#   * 物理 GPU 在 vfio/mdev 框架下 (mdev_supported_types 出现)

set -euo pipefail

REPO=${REPO:-https://github.com/mbilker/vgpu_unlock-rs}
INSTALL_DIR=${INSTALL_DIR:-/opt/vgpu_unlock}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_COMMIT=${UPSTREAM_COMMIT:-71ec870d4b456c9a8013c114a57372b1a60d36ca}
G11_PATCH=${G11_PATCH:-$here/patches/vgpu-unlock-rs-g11.patch}
MDEV_ADMIN_INSTALLER=${MDEV_ADMIN_INSTALLER:-$here/install-vgpu-mdev-admin.sh}
MDEV_ADMIN_USER=${VGPU_MDEV_ADMIN_USER:-${SUDO_USER:-$(id -un)}}
RESTART_MANAGER=0
INSTALL_TRANSACTION_ACTIVE=0
LIB_PREEXISTED=0
PROFILE_PREEXISTED=0
DROPIN_PREEXISTED=0
MANAGER_RESTART_ATTEMPTED=0
TMP=

usage() {
    cat <<'EOF'
用法: setup-vgpu-unlock.sh [--restart-manager]

默认只构建、测试、备份并安装，不打断正在运行的 vGPU。
--restart-manager 仅在没有 QEMU 占用 mdev 时重启 nvidia-vgpu-mgr。
EOF
}

while (($#)); do
    case "$1" in
        --restart-manager) RESTART_MANAGER=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# sudo wrapper：优先用已激活 ticket，其次 SUDO_PASSWORD 环境变量。
sudo_run() {
    if sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@"
    else
        echo "需要 sudo 权限: 先 'sudo -v' 或设 SUDO_PASSWORD=xxx 再跑" >&2
        return 1
    fi
}

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
if ! command -v cargo >/dev/null 2>&1; then
    echo "[pre] 未检测到 cargo，安装 rustup 到 \$HOME/.cargo"
    if ! command -v curl >/dev/null; then
        sudo_run apt-get update -qq
        sudo_run apt-get install -yqq curl
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --profile minimal --default-toolchain stable
fi
# 让当前 shell 也能找到 cargo
export PATH="$HOME/.cargo/bin:$PATH"
# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
command -v cargo >/dev/null || { echo "cargo 仍不可用，装 rustup 后退出重开 shell 再跑本脚本" >&2; exit 1; }

[[ -f "$G11_PATCH" && ! -L "$G11_PATCH" ]] || {
    echo "G-11 vgpu_unlock patch 缺失或不安全: $G11_PATCH" >&2
    exit 1
}
[[ -x "$MDEV_ADMIN_INSTALLER" && ! -L "$MDEV_ADMIN_INSTALLER" ]] || {
    echo "G-11 mdev admin installer 缺失或不安全: $MDEV_ADMIN_INSTALLER" >&2
    exit 1
}

echo "[1/6] 准备固定上游 $UPSTREAM_COMMIT: $REPO → $BUILD_DIR"
mkdir -p "$(dirname "$BUILD_DIR")"
if [[ ! -d "$BUILD_DIR/.git" ]]; then
    git clone "$REPO" "$BUILD_DIR"
    git -C "$BUILD_DIR" checkout --detach "$UPSTREAM_COMMIT"
fi
[[ "$(git -C "$BUILD_DIR" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || {
    echo "拒绝在非固定上游上构建: $(git -C "$BUILD_DIR" rev-parse HEAD)" >&2
    echo "期望: $UPSTREAM_COMMIT；请另设空 BUILD_DIR，现有源码不会被覆盖。" >&2
    exit 1
}

if git -C "$BUILD_DIR" apply --reverse --check "$G11_PATCH" >/dev/null 2>&1; then
    expected_patch_sha=$(sha256sum "$G11_PATCH" | awk '{print $1}')
    actual_patch_sha=$(git -C "$BUILD_DIR" diff -- src/lib.rs | sha256sum | awk '{print $1}')
    [[ "$actual_patch_sha" == "$expected_patch_sha" ]] || {
        echo "源码含 G-11 patch 之外的改动，拒绝覆盖: $BUILD_DIR" >&2
        exit 1
    }
    echo "[1/6] G-11 patch 已存在且内容精确匹配"
else
    git -C "$BUILD_DIR" diff --quiet -- &&
        git -C "$BUILD_DIR" diff --cached --quiet -- || {
        echo "源码工作树不干净，拒绝覆盖: $BUILD_DIR" >&2
        exit 1
    }
    git -C "$BUILD_DIR" apply --check "$G11_PATCH"
    git -C "$BUILD_DIR" apply "$G11_PATCH"
fi
git -C "$BUILD_DIR" diff --check

echo "[2/6] cargo fmt/test/build（用户身份）"
( cd "$BUILD_DIR" && cargo fmt -- --check && cargo test && cargo build --release )

LIB_SRC="$BUILD_DIR/target/release/libvgpu_unlock_rs.so"
LIB_DST="$INSTALL_DIR/libvgpu_unlock_rs.so"
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
INSTALL_TRANSACTION_ACTIVE=0

cat <<EOF

✅ vgpu_unlock-rs 已就绪:
    lib        = $LIB_DST
    override   = /etc/vgpu_unlock/profile_override.toml
    mdev admin = /usr/local/libexec/qemu-vgpu-mdev-admin
    systemd d  = /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
    backup     = $BACKUP_DIR

下一步:
    关闭所有 vGPU VM 后运行：$0 --restart-manager
    sudo journalctl -fu nvidia-vgpu-mgr    # 有 'Applying profile override' 行就是成功
EOF
