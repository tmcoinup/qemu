#!/bin/bash
# 基础镜像克隆前完成可选 VLAN trunk 的一次性宿主初始化。
#
# 该入口只由 VMate 在“基础镜像 + 显式 VLAN”创建路径中使用。克隆本来就需要
# 一次管理员认证，因此把幂等的 VLAN 初始化放进同一个 root 进程，可避免随后
# 启动阶段再次弹出 pkexec 密码框。setup-bridge.sh 仍负责全部网络安全检查、
# 全局锁、helper/sudoers 安装和现有配置冲突判定。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_SCRIPT="$HERE/setup-bridge.sh"
readonly CLONE_SCRIPT="$HERE/clone-from-base.sh"
readonly SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_caller_identity() {
    local resolved_uid

    (( EUID == 0 )) || fail "VLAN + 克隆组合入口必须以 root 运行。"
    [[ "${SUDO_USER:-}" =~ ^[[:alnum:]_.-]+\$?$ \
        && "${SUDO_USER:-}" != "root" ]] \
        || fail "缺少可信的非 root SUDO_USER。"
    [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_UID:-0}" != "0" ]] \
        || fail "缺少可信的非 root SUDO_UID。"
    resolved_uid="$(id -u -- "$SUDO_USER" 2>/dev/null)" \
        || fail "无法从账号数据库复核 SUDO_USER。"
    [[ "$resolved_uid" == "$SUDO_UID" ]] \
        || fail "SUDO_USER 与 SUDO_UID 不一致。"
}

validate_runtime_scripts() {
    [[ -f "$SETUP_SCRIPT" && ! -L "$SETUP_SCRIPT" && -x "$SETUP_SCRIPT" ]] \
        || fail "VLAN 初始化脚本缺失或不可执行: $SETUP_SCRIPT"
    [[ -f "$CLONE_SCRIPT" && ! -L "$CLONE_SCRIPT" && -x "$CLONE_SCRIPT" ]] \
        || fail "基础镜像克隆脚本缺失或不可执行: $CLONE_SCRIPT"
}

validate_caller_identity
validate_runtime_scripts

/usr/bin/env -i \
    "PATH=$SAFE_PATH" \
    HOME=/root \
    USER=root \
    LOGNAME=root \
    LC_ALL=C \
    BR=br0 \
    VLAN_TRUNK=1 \
    VLAN_SETUP_AUTO=1 \
    "VM_USER=$SUDO_USER" \
    "$SETUP_SCRIPT"

# setup 的隔离环境只作用于子进程；当前进程仍保留客户端显式传入的克隆白名单，
# 包括平台、硬件选择、VMS_DIR、QEMU 与调用者身份。
exec /bin/bash "$CLONE_SCRIPT" "$@"
