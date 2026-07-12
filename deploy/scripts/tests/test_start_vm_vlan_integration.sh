#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 单 br0 + 动态 TAP 启动参数隔离集成测试。
#
# user/network/mount namespace 提供一次性 br0、上联、root-owned helper 安装视图。
# 只执行 DRY_RUN：会真实调用 helper 的只读 check，但不得创建 TAP 或改 VLAN 表。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
TAP_SOURCE="$REPO_ROOT/deploy/scripts/host-vlan-tap.sh"
DOWN_SOURCE="$REPO_ROOT/deploy/scripts/host-vlan-down.sh"

for file in "$START_VM" "$TAP_SOURCE" "$DOWN_SOURCE"; do
    [[ -x "$file" ]] || { echo "FAIL: 缺少可执行文件 $file" >&2; exit 1; }
done

if ! command -v unshare >/dev/null 2>&1 || ! unshare -Urnm true 2>/dev/null; then
    echo "SKIP: 当前内核未开放非特权 user/network/mount namespace"
    exit 0
fi

image_root="$(mktemp -d)"
out="$(mktemp)"
err="$(mktemp)"
cleanup() {
    local rc=$?
    if (( rc != 0 )) && [[ -s "$err" ]]; then
        sed -n '1,160p' "$err" >&2
    fi
    rm -rf "$image_root"
    rm -f "$out" "$err"
    return "$rc"
}
trap cleanup EXIT

# shellcheck disable=SC2016
unshare -Urnm bash -euo pipefail -c '
    mount --make-rprivate /
    mount -t tmpfs -o mode=0755 tmpfs /usr/local/libexec
    mount -t tmpfs -o mode=0755 tmpfs /etc/qemu
    mount -t tmpfs -o mode=0755 tmpfs /run
    install -o root -g root -m 0755 "$1" /usr/local/libexec/qemu-stealth-vlan-tap
    install -o root -g root -m 0755 "$2" /usr/local/libexec/qemu-stealth-vlan-down

    # DRY_RUN 的普通 bridge 回归仍需一个“可选择但不会执行”的旧 helper。
    printf "#!/bin/sh\nexit 0\n" >/usr/local/libexec/qemu-bridge-helper
    chmod 4755 /usr/local/libexec/qemu-bridge-helper
    printf "allow br0\n" >/etc/qemu/bridge.conf
    chmod 0644 /etc/qemu/bridge.conf

    printf "%s\n" \
        "VERSION=1" \
        "BRIDGE=br0" \
        "UPLINK=enp5s0" \
        "ALLOWED_UID=0" \
        "ALLOWED_GID=0" >/etc/qemu/stealth-vlan.conf
    chmod 0644 /etc/qemu/stealth-vlan.conf

    ip link add enp5s0 type dummy
    ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 1
    ip link set enp5s0 master br0
    ip link set enp5s0 up
    ip link set br0 up

    common=(--no-sdl --no-fb-shm)
    env IMAGE_ROOT="$3" DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 "$4" 9930 --proxy --vlan-id=11 "${common[@]}" \
        >"$3/vlan11.out"
    env IMAGE_ROOT="$3" DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 "$4" 9931 --bridge=br0 --vlan-id=20 "${common[@]}" \
        >"$3/vlan20.out"

    # 不传 --vlan-id 时必须继续使用旧 bridge backend，不能触碰动态 TAP 路径。
    env IMAGE_ROOT="$3" DRY_RUN=1 TPM=0 HOST_TUNE=0 CPU_ISOLATE=0 \
        QEMU_CAP_CHECK=0 "$4" 9932 --bridge=br0 "${common[@]}" \
        >"$3/default.out"

    ! ip link show svtap9930 >/dev/null 2>&1
    ! ip link show svtap9931 >/dev/null 2>&1
' bash "$TAP_SOURCE" "$DOWN_SOURCE" "$image_root" "$START_VM" >"$out" 2>"$err"

[[ ! -s "$err" ]] || {
    sed -n '1,160p' "$err" >&2
    echo "FAIL: namespace 集成启动产生 stderr" >&2
    exit 1
}

grep -Fx -- "tap,id=net0,ifname=svtap9930,script=no,downscript=/usr/local/libexec/qemu-stealth-vlan-down" \
    "$image_root/vlan11.out" >/dev/null \
    || { echo "FAIL: VLAN 11 未生成 direct TAP argv" >&2; exit 1; }
grep -Fx -- "tap,id=net0,ifname=svtap9931,script=no,downscript=/usr/local/libexec/qemu-stealth-vlan-down" \
    "$image_root/vlan20.out" >/dev/null \
    || { echo "FAIL: --bridge=br0 + VLAN 20 未生成 direct TAP argv" >&2; exit 1; }
grep -Fx -- "unix:/tmp/qemu-stealth-9930.qmp,server=on,wait=off,multi=on" \
    "$image_root/vlan11.out" >/dev/null \
    || { echo "FAIL: --proxy 未保留 QMP multi=on" >&2; exit 1; }
grep -F -- "bridge,id=net0,br=br0,helper=" "$image_root/default.out" >/dev/null \
    || { echo "FAIL: 无 VLAN 未保留原 bridge backend" >&2; exit 1; }
! grep -F -- "svtap" "$image_root/default.out" >/dev/null \
    || { echo "FAIL: 无 VLAN 路径泄漏动态 TAP 参数" >&2; exit 1; }

echo "PASS: 单 br0 VLAN direct TAP argv、proxy 与无 VLAN bridge 兼容路径"
