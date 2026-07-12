#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# root VLAN TAP helper 的隔离网络集成测试。
#
# 所有 /etc、/run、/usr/local 安装视图及接口都位于一次性 user/mount/network
# namespace；测试结束由内核整体销毁，不会触碰宿主 br0、上联或 sudoers。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER_SOURCE="$REPO_ROOT/deploy/scripts/host-vlan-tap.sh"
DOWN_SOURCE="$REPO_ROOT/deploy/scripts/host-vlan-down.sh"

[[ -x "$HELPER_SOURCE" && -x "$DOWN_SOURCE" ]] || {
    echo "FAIL: VLAN helper/downscript 源文件缺失或不可执行" >&2
    exit 1
}

if ! command -v unshare >/dev/null 2>&1 || ! unshare -Urnm true 2>/dev/null; then
    echo "SKIP: 当前内核未开放非特权 user/network/mount namespace"
    exit 0
fi

# shellcheck disable=SC2016
unshare -Urnm bash -euo pipefail -c '
    helper_source="$1"
    down_source="$2"
    helper=/usr/local/libexec/qemu-stealth-vlan-tap
    down=/usr/local/libexec/qemu-stealth-vlan-down

    fail() {
        echo "FAIL: $*" >&2
        exit 1
    }

    vlan_output() {
        bridge vlan show dev "$1"
    }

    assert_access() {
        local device="$1" vid="$2" output
        output="$(vlan_output "$device")"
        grep -Eq "(^|[[:space:]])${vid}[[:space:]]+PVID[[:space:]]+Egress[[:space:]]+Untagged" \
            <<<"$output" || fail "$device 不是 VLAN $vid access/PVID/untagged"
        [[ "$(awk -v dev="$device" '"'"'NR > 1 { if ($1 == dev) token=$2; else token=$1; if (token ~ /^[0-9]+(-[0-9]+)?$/) count++ } END { print count+0 }'"'"' <<<"$output")" == "1" ]] \
            || fail "$device 含有多余 VLAN membership"
    }

    assert_tagged() {
        local device="$1" vid="$2" line
        line="$(vlan_output "$device" | awk -v wanted="$vid" '"'"'
            NR > 1 {
                token = ($1 ~ /^[0-9]/) ? $1 : $2
                if (token == wanted) print
            }'"'"')"
        [[ -n "$line" ]] || fail "$device 缺少 tagged VLAN $vid"
        ! grep -Eq "PVID|Egress|Untagged" <<<"$line" \
            || fail "$device 的业务 VLAN $vid 错误带有 native flags"
    }

    mount --make-rprivate /
    mount -t sysfs sysfs /sys
    mount -t tmpfs -o mode=0755 tmpfs /etc/qemu
    mount -t tmpfs -o mode=0755 tmpfs /usr/local/libexec
    mount -t tmpfs -o mode=0755 tmpfs /run
    # Ubuntu 常见 /run/lock=1777；helper 锁位于 root-only /run，不能受其影响。
    mkdir -m 1777 /run/lock
    install -o root -g root -m 0755 "$helper_source" "$helper"
    install -o root -g root -m 0755 "$down_source" "$down"
    printf "%s\n" VERSION=1 BRIDGE=br0 UPLINK=enp5s0 \
        ALLOWED_UID=0 ALLOWED_GID=0 >/etc/qemu/stealth-vlan.conf
    chmod 0644 /etc/qemu/stealth-vlan.conf

    ip link add enp5s0 type dummy
    ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 1
    ip link set enp5s0 master br0
    ip link set enp5s0 up
    ip link set br0 up

    # check 必须纯只读：新 VID 尚未加入也成功，且不能创建 lock/state/TAP。
    [[ "$("$helper" check 1 11)" == svtap1 ]] || fail "check 返回 TAP 名错误"
    [[ ! -e /run/qemu-stealth-vlan.lock && ! -e /run/qemu-stealth-vlan ]] \
        || fail "check 产生了 /run 副作用"
    ! ip link show svtap1 >/dev/null 2>&1 || fail "check 错误创建 TAP"
    ! vlan_output enp5s0 | grep -Eq "(^|[[:space:]])11([[:space:]]|$)" \
        || fail "check 错误修改 uplink VLAN 表"

    # prepare 自动把任意新业务 VID tagged 加入上联，并创建 guest access TAP。
    [[ "$("$helper" prepare 1 11)" == svtap1 ]] || fail "prepare VLAN 11 失败"
    [[ "$("$helper" prepare 2 20)" == svtap2 ]] || fail "prepare VLAN 20 失败"
    [[ "$("$helper" prepare 6 1)" == svtap6 ]] || fail "prepare native VLAN 1 失败"
    assert_tagged enp5s0 11
    assert_tagged enp5s0 20
    assert_access svtap1 11
    assert_access svtap2 20
    assert_access svtap6 1
    [[ "$("$helper" prepare 1 11)" == svtap1 ]] || fail "同配置 prepare 不幂等"
    if "$helper" prepare 1 12 >/dev/null 2>&1; then
        fail "同实例不同 VID 未被状态校验拒绝"
    fi
    ! vlan_output enp5s0 | grep -Eq "(^|[[:space:]])12([[:space:]]|$)" \
        || fail "失败的冲突请求仍向 uplink 残留 VLAN 12"

    # 模拟 helper 在 state 提交后被 SIGKILL：半配置 TAP 或 TAP 消失都应由下一次
    # prepare 依据可信 intent state 自动回收/重建，而不是永久卡死实例。
    [[ "$("$helper" prepare 7 70)" == svtap7 ]] || fail "prepare VLAN 70 失败"
    bridge vlan del dev svtap7 vid 70
    bridge vlan add dev svtap7 vid 71 pvid untagged
    [[ "$("$helper" check 7 70)" == svtap7 ]] || fail "check 拒绝可信半成品 TAP"
    [[ "$("$helper" prepare 7 70)" == svtap7 ]] || fail "未恢复半配置 TAP"
    assert_access svtap7 70
    "$helper" cleanup-instance 7

    [[ "$("$helper" prepare 8 80)" == svtap8 ]] || fail "prepare VLAN 80 失败"
    ip tuntap del dev svtap8 mode tap
    [[ "$("$helper" prepare 8 80)" == svtap8 ]] || fail "未从仅剩 state 的状态恢复"
    "$helper" cleanup-instance 8

    # 清理一个 TAP 不得影响另一个实例，也保留动态加入的 uplink tagged VID。
    "$helper" cleanup-instance 1
    ! ip link show svtap1 >/dev/null 2>&1 || fail "cleanup 未删除 svtap1"
    ip link show svtap2 >/dev/null 2>&1 || fail "cleanup 误删 svtap2"
    assert_tagged enp5s0 11
    assert_tagged enp5s0 20

    # 无 root state 的同名接口不属于 helper，cleanup 必须幂等返回但拒绝删除。
    ip tuntap add dev svtap3 mode tap user 0 group 0
    "$helper" cleanup-instance 3
    ip link show svtap3 >/dev/null 2>&1 || fail "无 state 的 TAP 被越权删除"
    ip tuntap del dev svtap3 mode tap

    # downscript 正常清理；即使 helper 暂时失败，合法参数也保持 0 交给 watchdog。
    [[ "$("$helper" prepare 4 40)" == svtap4 ]] || fail "prepare VLAN 40 失败"
    "$down" svtap4
    ! ip link show svtap4 >/dev/null 2>&1 || fail "downscript 未清理 svtap4"
    chmod 0666 /etc/qemu/stealth-vlan.conf
    "$down" svtap999
    chmod 0644 /etc/qemu/stealth-vlan.conf
    if "$down" unsafe0 >/dev/null 2>&1; then
        fail "downscript 接受了非保留接口名"
    fi

    # 已有错误 untagged flags 不能被 helper 静默改写；非法 VID/实例同样拒绝。
    bridge vlan add dev enp5s0 vid 30 untagged
    if "$helper" check 5 30 >/dev/null 2>&1; then
        fail "check 接受了业务 VLAN 的 untagged uplink"
    fi
    for args in "check 0 11" "check 1 0" "prepare 1 4095" \
                "cleanup-ifname eth0"; do
        # shellcheck disable=SC2086
        if "$helper" $args >/dev/null 2>&1; then
            fail "非法参数未被拒绝: $args"
        fi
    done

    # VID1 只能是唯一 native；发现旧 VID100 native 时必须拒绝而不是改写 PVID。
    bridge vlan del dev enp5s0 vid 1
    bridge vlan add dev enp5s0 vid 100 pvid untagged
    if "$helper" check 9 1 >/dev/null 2>&1; then
        fail "helper 接受了非 VID1 的既有 native VLAN"
    fi

    # 纯数字接口名是合法边界输入；续行 VLAN 11 不能被误当成端口首列。
    ip link add 11 type dummy
    ip link set 11 master br0
    ip link set 11 up
    bridge vlan add dev 11 vid 11
    sed -i "s/^UPLINK=.*/UPLINK=11/" /etc/qemu/stealth-vlan.conf
    [[ "$("$helper" check 9 11)" == svtap9 ]] || fail "纯数字 uplink 的 check 解析错误"
    [[ "$("$helper" prepare 9 11)" == svtap9 ]] || fail "纯数字 uplink 的 prepare 失败"
    assert_access svtap9 11
    "$helper" cleanup-instance 9

    "$helper" cleanup-instance 2
    ! ip link show svtap2 >/dev/null 2>&1 || fail "最终 cleanup 未删除 svtap2"
    "$helper" cleanup-instance 6
    ! ip link show svtap6 >/dev/null 2>&1 || fail "最终 cleanup 未删除 svtap6"
' bash "$HELPER_SOURCE" "$DOWN_SOURCE"

echo "PASS: root helper 动态 tagged uplink、access TAP、安全状态与幂等清理"
