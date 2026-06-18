# nbd-lock.sh —— host-*.sh 离线 NBD 工具共享的并发安全层（审计 P2）。
# 被 source（非执行）；调用方通常已 set -e。source 即：
#   1) 取一把全局 flock，串行化所有用 /dev/nbdN 的离线工具，杜绝并发抢占
#      同一 NBD 设备造成的误连接 / 误断开 / qcow2 双挂损坏；锁随脚本退出释放。
# 另提供两个函数（按需调用）：
#   nbd_pick_free   —— 打印首个未连接后端的 /dev/nbdN（无则返回 1）。
#   nbd_guard_disk <qcow2> —— 连接前确认镜像未被任何进程（尤其运行中的 QEMU）
#                   打开；被持有则 fail-fast 退出（双挂 qcow2 必损坏）。

# --- 全局串行锁（fd 随脚本进程存活而持有，退出自动释放）---
_NBD_LOCKFILE="${NBD_LOCKFILE:-/run/lock/qemu-stealth-nbd.lock}"
if ! { exec {_NBD_LOCK_FD}>"$_NBD_LOCKFILE"; } 2>/dev/null; then
    _NBD_LOCKFILE="/tmp/qemu-stealth-nbd.lock"
    exec {_NBD_LOCK_FD}>"$_NBD_LOCKFILE"
fi
flock "$_NBD_LOCK_FD"

# 首个未连接后端的 /dev/nbdN（/sys/block/nbdN/size==0 即空闲）。
nbd_pick_free() {
    local d name
    for d in /dev/nbd{0..15}; do
        [[ -b "$d" ]] || continue
        name="$(basename "$d")"
        if [[ "$(cat "/sys/block/$name/size" 2>/dev/null || echo 1)" == "0" ]]; then
            printf '%s\n' "$d"; return 0
        fi
    done
    return 1
}

# 连接前断言目标 /dev/nbdN 空闲（size==0）。busy 则 fail-fast，**绝不主动
# disconnect**——强断可能踢掉外部进程（或别的 VM 工具）的连接。busy 时给出空闲
# 设备建议，让用户改用 NBD=/dev/nbdM 或自行清理本项目残留。
nbd_assert_device_free() {
    local dev="$1" name sz free
    [[ -n "$dev" ]] || return 0
    name="$(basename "$dev")"
    sz="$(cat "/sys/block/$name/size" 2>/dev/null || echo 0)"
    if [[ "$sz" != "0" ]]; then
        free="$(nbd_pick_free 2>/dev/null || true)"
        echo "ERROR: $dev 已被占用 (size=$sz)，拒绝连接（不会强断，以免踢掉外部连接）。" >&2
        [[ -n "$free" ]] && echo "       可改用空闲设备：NBD=$free 重跑。" >&2
        echo "       若确认是本项目残留连接：先手动 qemu-nbd --disconnect $dev 再重跑。" >&2
        exit 1
    fi
}

# 连接前确认磁盘镜像没被任何进程打开——双挂 qcow2 会损坏数据。
nbd_guard_disk() {
    local disk="$1" holders=""
    [[ -n "$disk" && -e "$disk" ]] || return 0
    # lsof / fuser 在“文件没有任何进程持有”时 exit 非零。
    # 这恰是正常情况。调用方普遍 set -euo pipefail，
    # 所以命令替换失败会经 pipefail 上抛，
    # 被 set -e 当致命错误。
    # 实测 clone-from-base.sh 的 devpkey 步
    # 会在 attach nbd 后 rc=1 退出，
    # 连分区都没扫到，进而跳过 unattend 注入和 chown。
    # 每个赋值补 || true：只取输出，退出码不参与 set -e。
    if command -v lsof >/dev/null 2>&1; then
        holders="$(
            lsof -- "$disk" 2>/dev/null |
                awk 'NR>1{print $1"(pid "$2")"}' |
                sort -u |
                tr '\n' ' '
        )" || true
    elif command -v fuser >/dev/null 2>&1; then
        holders="$(fuser "$disk" 2>/dev/null | tr -s ' ')" || true
    fi
    if [[ -n "$holders" ]]; then
        echo "ERROR: 磁盘 $disk 正被进程持有: $holders" >&2
        echo "       拒绝挂载（双挂 qcow2 会损坏）。请先 stop-vm.sh 停掉对应 VM 再试。" >&2
        exit 1
    fi
}

# --- 连接 / 断开（P0：cleanup 只断本脚本自己建立的连接）---
_NBD_CONNECTED=0     # 仅 nbd_connect 成功后置 1；cleanup 据此判断是否 disconnect
_NBD_DEV=""          # 本脚本实际连上的设备（可能被自动选盘改过）

_nbd_dev_is_free() {
    local name; name="$(basename "$1")"
    [[ "$(cat "/sys/block/$name/size" 2>/dev/null || echo 0)" == "0" ]]
}

# 连接 qcow2 到 NBD。用法: nbd_connect NBD_VARNAME "$DISK"
#   · 先 nbd_guard_disk（防镜像被 QEMU 双挂损坏）。
#   · 目标设备 busy 时：调用方显式传了 NBD= (_NBD_PINNED=1) → fail-fast，**绝不强断**；
#     否则自动 nbd_pick_free 选空闲盘，并经 nameref **就地更新**调用方 NBD（下游
#     ${NBD}pN 分区引用依赖它）。
#   · 仅 connect 成功才置 _NBD_CONNECTED=1 + 记 _NBD_DEV —— 这样即便 busy fail-fast
#     退出触发 EXIT trap，nbd_disconnect_if_owned 也不会去断别人的连接。
nbd_connect() {
    local _vn="$1" disk="$2"
    local -n _dev="$_vn"
    nbd_guard_disk "$disk"
    if ! _nbd_dev_is_free "$_dev"; then
        if [[ "${_NBD_PINNED:-}" == "1" ]]; then
            echo "ERROR: $_dev 已被占用，且你显式指定了 NBD= —— 拒绝改盘/强断（以免踢掉外部连接）。" >&2
            echo "       确认是本项目残留则先 qemu-nbd --disconnect $_dev，或换 NBD=/dev/nbdM 重跑。" >&2
            exit 1
        fi
        local _free
        _free="$(nbd_pick_free)" || { echo "ERROR: 无空闲 /dev/nbdN 可用" >&2; exit 1; }
        echo ">> nbd: 默认 $_dev 忙，自动改用空闲设备 $_free" >&2
        _dev="$_free"
    fi
    qemu-nbd --connect="$_dev" --format=qcow2 "$disk"
    _NBD_CONNECTED=1
    _NBD_DEV="$_dev"
}

# cleanup 调用：仅断开本脚本成功 connect 的设备（外部连接绝不碰）。
nbd_disconnect_if_owned() {
    [[ "${_NBD_CONNECTED:-0}" == "1" && -n "$_NBD_DEV" ]] || return 0
    qemu-nbd --disconnect "$_NBD_DEV" 2>/dev/null || true
    _NBD_CONNECTED=0
}
