#!/usr/bin/env bash
# setup-vgpu-unlock.sh — 构建 vgpu_unlock-rs 并接入 NVIDIA vGPU 守护进程
#
# 自动处理:
#   * rust/cargo 缺失时用 rustup 装到用户级 ($HOME/.cargo)
#   * cargo build 以普通用户身份跑（不污染 root 的 ~/.cargo）
#   * 构建产物 install 到 /opt/vgpu_unlock/ 并注入 systemd LD_PRELOAD
#
# 要求:
#   * NVIDIA vGPU host driver (本项目 17.6 = 550.163.02) 已安装
#   * 物理 GPU 在 vfio/mdev 框架下 (mdev_supported_types 出现)

set -euo pipefail

REPO=${REPO:-https://github.com/mbilker/vgpu_unlock-rs}
INSTALL_DIR=${INSTALL_DIR:-/opt/vgpu_unlock}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo "[1/4] clone / update $REPO → $BUILD_DIR"
mkdir -p "$(dirname "$BUILD_DIR")"
if [[ ! -d "$BUILD_DIR/.git" ]]; then
    git clone "$REPO" "$BUILD_DIR"
else
    git -C "$BUILD_DIR" pull --ff-only
fi

echo "[2/4] cargo build --release （用户身份）"
( cd "$BUILD_DIR" && cargo build --release )

LIB_SRC="$BUILD_DIR/target/release/libvgpu_unlock_rs.so"
LIB_DST="$INSTALL_DIR/libvgpu_unlock_rs.so"
[[ -f "$LIB_SRC" ]] || { echo "产物缺失: $LIB_SRC" >&2; exit 1; }

echo "[3/4] 安装产物与 profile_override.toml 到 $INSTALL_DIR / /etc/vgpu_unlock/"
sudo_run install -d -m 0755 "$INSTALL_DIR" /etc/vgpu_unlock
sudo_run install -m 0644 "$LIB_SRC" "$LIB_DST"
sudo_run install -m 0644 "$here/profile_override.toml" /etc/vgpu_unlock/profile_override.toml

echo "[4/4] 注入 LD_PRELOAD 到 nvidia-vgpu-mgr.service"
sudo_run install -d -m 0755 /etc/systemd/system/nvidia-vgpu-mgr.service.d
TMP=$(mktemp)
cat > "$TMP" <<EOF
[Service]
Environment=LD_PRELOAD=$LIB_DST
Environment=RUST_BACKTRACE=1
EOF
sudo_run install -m 0644 "$TMP" /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
rm -f "$TMP"
sudo_run systemctl daemon-reload

cat <<EOF

✅ vgpu_unlock-rs 已就绪:
    lib        = $LIB_DST
    override   = /etc/vgpu_unlock/profile_override.toml
    systemd d  = /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf

下一步:
    sudo systemctl restart nvidia-vgpu-mgr
    sudo journalctl -fu nvidia-vgpu-mgr    # 有 'Applying profile override' 行就是成功
EOF
