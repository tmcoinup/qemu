#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/deploy/lib/bridge-network.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/sys/enp7s0/device" \
    "$TMP_DIR/conf" "$TMP_DIR/helper" "$TMP_DIR/qemu"
printf '1\n' >"$TMP_DIR/sys/enp7s0/type"
printf '1\n' >"$TMP_DIR/sys/enp7s0/carrier"

cat >"$TMP_DIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
scenario=${SCENARIO:-healthy}
if [[ "$args" == *" -o link show master br0 "* ]]; then
    [[ "$scenario" == noport ]] && exit 0
    printf '2: enp7s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state UP\n'
elif [[ "$args" == *" -d -o link show dev br0 "* ]]; then
    case "$scenario" in
        nonbridge) printf '14: br0: <UP,LOWER_UP> mtu 1500 dummy state UP\n' ;;
        down) printf '14: br0: <BROADCAST,MULTICAST> mtu 1500 bridge forward_delay 0 state DOWN\n' ;;
        nolower) printf '14: br0: <BROADCAST,MULTICAST,UP> mtu 1500 bridge forward_delay 0 state DOWN\n' ;;
        vlan) printf '14: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 bridge forward_delay 0 vlan_filtering 1 state UP\n' ;;
        *) printf '14: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 bridge forward_delay 0 state UP\n' ;;
    esac
elif [[ "$args" == *" -d -o link show dev enp7s0 "* ]]; then
    case "$scenario" in
        notmaster) printf '2: enp7s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\n' ;;
        uplinkdown) printf '2: enp7s0: <BROADCAST,MULTICAST> mtu 1500 master br0 state DOWN\n' ;;
        *) printf '2: enp7s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state UP\n' ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$TMP_DIR/bin/ip"

cat >"$TMP_DIR/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
    %u) printf '0\n' ;;
    %a)
        if [[ -d "${4:-}" ]]; then
            printf '755\n'
        elif [[ -x "${4:-}" ]]; then
            printf '%s\n' "${HELPER_MODE:-750}"
        else
            printf '644\n'
        fi
        ;;
    %d:%i) /usr/bin/stat "$@" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/stat"
cat >"$TMP_DIR/bin/getcap" <<'EOF'
#!/usr/bin/env bash
printf '%s cap_net_admin=ep\n' "${@: -1}"
EOF
chmod +x "$TMP_DIR/bin/getcap"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_DIR/helper/qemu-g11-bridge-helper"
chmod +x "$TMP_DIR/helper/qemu-g11-bridge-helper"
printf 'allow br0\n' >"$TMP_DIR/qemu/bridge.conf"
touch "$TMP_DIR/network.lock"

cat >"$TMP_DIR/bin/bridge" <<'EOF'
#!/usr/bin/env bash
printf 'port              vlan-id\nenp7s0           1 PVID Egress Untagged\n'
EOF
chmod +x "$TMP_DIR/bin/bridge"

cat >"$TMP_DIR/conf/g11-bridge.conf" <<'EOF'
VERSION=1
BRIDGE=br0
UPLINK=enp7s0
MODE=access
UPLINK_MAC=00:e0:27:6c:70:5e
EOF

export PATH="$TMP_DIR/bin:/usr/bin:/bin"
export G11_BRIDGE_SYS_CLASS_NET="$TMP_DIR/sys"
export G11_NETWORK_LOCK="$TMP_DIR/network.lock"
# shellcheck source=../../lib/bridge-network.sh
source "$LIB"

run_gate() {
    local scenario=$1 config=${2:-/missing-g11-bridge.conf}

    SCENARIO=$scenario g11_bridge_uplink_preflight \
        br0 "$config" "$G11_BRIDGE_SYS_CLASS_NET" \
        "$TMP_DIR/helper/qemu-g11-bridge-helper" \
        "$TMP_DIR/qemu/bridge.conf"
}

run_gate healthy >/dev/null || fail "healthy bridge was rejected"
run_gate healthy "$TMP_DIR/conf/g11-bridge.conf" >/dev/null || \
    fail "trusted setup facts were rejected"

if run_gate noport >"$TMP_DIR/noport.out" 2>"$TMP_DIR/noport.err"; then
    fail "noport bridge was accepted"
fi
grep -Fq 'VM 未启动' "$TMP_DIR/noport.err" || \
    fail "noport did not produce actionable failure"

for scenario in nonbridge down nolower notmaster uplinkdown; do
    if run_gate "$scenario" "$TMP_DIR/conf/g11-bridge.conf" \
        >"$TMP_DIR/$scenario.out" 2>"$TMP_DIR/$scenario.err"; then
        fail "$scenario bridge was accepted"
    fi
    grep -Fq 'VM 未启动' "$TMP_DIR/$scenario.err" || \
        fail "$scenario did not produce actionable failure"
done

printf '0\n' >"$TMP_DIR/sys/enp7s0/carrier"
if run_gate healthy "$TMP_DIR/conf/g11-bridge.conf" >/dev/null 2>&1; then
    fail "carrier=0 uplink was accepted"
fi
printf '1\n' >"$TMP_DIR/sys/enp7s0/carrier"

sed 's/^MODE=access$/MODE=vlan-aware/' \
    "$TMP_DIR/conf/g11-bridge.conf" >"$TMP_DIR/conf/bad.conf"
if run_gate healthy "$TMP_DIR/conf/bad.conf" >/dev/null 2>&1; then
    fail "vlan-aware contract without vlan_filtering was accepted"
fi
run_gate vlan "$TMP_DIR/conf/bad.conf" >/dev/null || \
    fail "healthy vlan-aware bridge was rejected"

printf 'allow all\n' >"$TMP_DIR/qemu/bridge.conf"
if run_gate healthy "$TMP_DIR/conf/g11-bridge.conf" >/dev/null 2>&1; then
    fail "broad bridge helper ACL was accepted"
fi
printf 'allow br0\n' >"$TMP_DIR/qemu/bridge.conf"

if HELPER_MODE=755 run_gate healthy "$TMP_DIR/conf/g11-bridge.conf" \
        >/dev/null 2>&1; then
    fail "world-executable privileged bridge helper was accepted"
fi

BRIDGE_UPLINK_CHECK=off run_gate noport >/dev/null 2>&1 || \
    fail "explicit isolated-bridge opt-out did not work"

echo "PASS: G-11 bridge preflight fails closed on empty/broken uplinks"
