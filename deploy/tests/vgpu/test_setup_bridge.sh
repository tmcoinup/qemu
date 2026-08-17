#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SETUP="$REPO_ROOT/deploy/scripts/setup-bridge.sh"
ROLLBACK="$REPO_ROOT/deploy/scripts/host-bridge-rollback.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/sys/enp7s0/device"
printf '1\n' >"$TMP_DIR/sys/enp7s0/type"
printf '1\n' >"$TMP_DIR/sys/enp7s0/carrier"
printf '00:e0:27:6c:70:5e\n' >"$TMP_DIR/sys/enp7s0/address"

cat >"$TMP_DIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" -d -o link show dev enp7s0 "* ]]; then
    printf '2: enp7s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\n'
elif [[ "$args" == *" -4 route show default dev enp7s0 "* ]]; then
    printf 'default via 192.168.30.1 dev enp7s0 proto dhcp\n'
elif [[ "$args" == *" link show dev br0 "* ]]; then
    exit 1
elif [[ "$args" == *" -4 route show default "* ]]; then
    printf 'default via 192.168.30.1 dev enp7s0 proto dhcp\n'
else
    exit 0
fi
EOF
chmod +x "$TMP_DIR/bin/ip"

cat >"$TMP_DIR/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" -g GENERAL.CONNECTION device show enp7s0 "* ]]; then
    printf 'uplink-connection\n'
elif [[ "$args" == *" -g ipv4.method connection show uplink-connection "* ]]; then
    printf '%s\n' "${NM_IPV4_METHOD:-auto}"
elif [[ "$args" == *" -g ipv6.method connection show uplink-connection "* ]]; then
    printf '%s\n' "${NM_IPV6_METHOD:-disabled}"
elif [[ "$args" == *" -t -f RUNNING general "* ]]; then
    printf 'running\n'
else
    exit 1
fi
EOF
chmod +x "$TMP_DIR/bin/nmcli"

env PATH="$TMP_DIR/bin:/usr/bin:/bin" \
    SETUP_SYS_CLASS_NET="$TMP_DIR/sys" \
    "$SETUP" plan --uplink enp7s0 >"$TMP_DIR/plan"

grep -Fq '# action: plan (read-only)' "$TMP_DIR/plan" || \
    fail "plan is not labelled read-only"
grep -Fq 'macaddress: 00:e0:27:6c:70:5e' "$TMP_DIR/plan" || \
    fail "bridge does not preserve uplink MAC"
grep -A3 '^  ethernets:' "$TMP_DIR/plan" | grep -Fq 'enp7s0:' || \
    fail "candidate does not declare the physical interface"
grep -Fq '      dhcp4: false' "$TMP_DIR/plan" || \
    fail "candidate leaves DHCP on the physical interface"
grep -A10 '^    br0:' "$TMP_DIR/plan" | grep -Fq 'dhcp4: true' || \
    fail "candidate does not move DHCP to br0"
grep -Fq 'bridge.vlan-filtering: "true"' "$TMP_DIR/plan" || \
    fail "default candidate does not persist VLAN filtering in NetworkManager"
grep -Fq '# allowed-vlans: 1-4094' "$TMP_DIR/plan" || \
    fail "first-run one-click allowlist is not explicit"

mkdir -p "$TMP_DIR/root/etc/netplan"
cat >"$TMP_DIR/root/etc/netplan/01-br0.yaml" <<'EOF'
network:
  version: 2
  bridges:
    br0:
      dhcp4: true
      interfaces: [enp7s0]
      parameters:
        stp: false
        forward-delay: 0
EOF
cat >"$TMP_DIR/root/etc/netplan/50-cloud-init.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    enp7s0:
      dhcp4: true
EOF
awk '/^### BEGIN \/etc\/netplan\/00-qemu-g11-uplink.yaml$/{copy=1; next}
     /^### END \/etc\/netplan\/00-qemu-g11-uplink.yaml$/{copy=0}
     copy' "$TMP_DIR/plan" \
    >"$TMP_DIR/root/etc/netplan/00-qemu-g11-uplink.yaml"
awk '/^### BEGIN \/etc\/netplan\/99-qemu-g11-br0.yaml$/{copy=1; next}
     /^### END \/etc\/netplan\/99-qemu-g11-br0.yaml$/{copy=0}
     copy' "$TMP_DIR/plan" \
    >"$TMP_DIR/root/etc/netplan/99-qemu-g11-br0.yaml"
chmod 0600 "$TMP_DIR/root/etc/netplan/"*.yaml
if ! /usr/libexec/netplan/generate --root-dir "$TMP_DIR/root" \
    >"$TMP_DIR/netplan.out" 2>"$TMP_DIR/netplan.err"; then
    sed 's/^/netplan: /' "$TMP_DIR/netplan.err" >&2
    fail "candidate does not merge with the observed split Netplan files"
fi
profile="$TMP_DIR/root/run/NetworkManager/system-connections/netplan-enp7s0.nmconnection"
[[ -f "$profile" ]] || fail "Netplan did not generate an enp7s0 profile"
grep -Eq '^(controller|master)=.*br0|^controller=br0$' "$profile" || \
    fail "generated enp7s0 profile is not a br0 port"
if grep -Fq 'method=auto' "$profile"; then
    fail "generated physical profile still owns DHCP"
fi
bridge_profile="$TMP_DIR/root/run/NetworkManager/system-connections/netplan-br0.nmconnection"
[[ -f "$bridge_profile" ]] || fail "Netplan did not generate a br0 profile"
grep -Fq 'vlan-filtering=true' "$bridge_profile" || \
    fail "generated br0 profile does not enable VLAN filtering"

if env PATH="$TMP_DIR/bin:/usr/bin:/bin" \
    SETUP_SYS_CLASS_NET="$TMP_DIR/sys" \
    "$SETUP" plan --uplink enp7s0 --mode vlan-aware --allowed-vlans= \
    >/dev/null 2>"$TMP_DIR/vlan.err"; then
    fail "vlan-aware plan accepted an explicit empty allowlist"
fi
grep -Fq '不能是空值' "$TMP_DIR/vlan.err" || \
    fail "empty VLAN allowlist failure is unclear"

# The read-only migration contract must reject static IPv4 and active IPv6,
# and the offline validator must never omit symlinked Netplan inputs.
(
    export PATH="$TMP_DIR/bin:/usr/bin:/bin"
    export SETUP_SYS_CLASS_NET="$TMP_DIR/sys"
    # shellcheck source=../../scripts/lib/setup-bridge-runtime.sh
    source "$REPO_ROOT/deploy/scripts/lib/setup-bridge-runtime.sh"
    NM_IPV4_METHOD=auto NM_IPV6_METHOD=disabled \
        setup_validate_supported_ip_contract br0 enp7s0 >/dev/null || \
        fail "supported DHCPv4/IPv6-disabled contract was rejected"
    if NM_IPV4_METHOD=manual NM_IPV6_METHOD=disabled \
            setup_validate_supported_ip_contract br0 enp7s0 \
            >/dev/null 2>&1; then
        fail "static IPv4 contract was accepted"
    fi
    if NM_IPV4_METHOD=auto NM_IPV6_METHOD=auto \
            setup_validate_supported_ip_contract br0 enp7s0 \
            >/dev/null 2>&1; then
        fail "active IPv6 contract was accepted"
    fi

    mkdir -p "$TMP_DIR/netplan-source/etc/netplan"
    printf 'network:\n  version: 2\n' \
        >"$TMP_DIR/netplan-source/etc/netplan/10-local.yaml"
    setup_copy_netplan_sources "$TMP_DIR/netplan-copy" \
        "$TMP_DIR/netplan-source"
    [[ -f "$TMP_DIR/netplan-copy/etc/netplan/10-local.yaml" ]] || \
        fail "ordinary Netplan input was not copied"
    ln -s 10-local.yaml \
        "$TMP_DIR/netplan-source/etc/netplan/20-linked.yaml"
    if setup_copy_netplan_sources "$TMP_DIR/netplan-copy-linked" \
            "$TMP_DIR/netplan-source" >/dev/null 2>&1; then
        fail "symlinked Netplan YAML was silently omitted"
    fi
)

grep -Fq 'ACTION=auto' "$SETUP" || fail "no-argument action is not one-click auto"
grep -Fq 'setup_network_is_busy' "$SETUP" || fail "apply lacks active VM/TAP gate"
grep -Fq 'VLAN intent state' \
    "$REPO_ROOT/deploy/scripts/lib/setup-bridge-runtime.sh" || \
    fail "host migration can strand root-only VLAN intent state"
grep -Fq 'systemd-run' "$SETUP" || fail "apply lacks detached rollback watchdog"
grep -Fq 'rollback-started' "$SETUP" || \
    fail "commit does not reject an already-started rollback"
grep -Fq 'rollback-started' "$ROLLBACK" || \
    fail "rollback helper does not publish an atomic start marker"
grep -Fq 'rollback-failed' "$ROLLBACK" || \
    fail "rollback helper does not retain failed-attempt state"
awk '
    /^auto_readonly_dependency_preflight\(\)/ { in_function=1 }
    in_function && /setup_validate_supported_ip_contract/ { found=1 }
    in_function && /^}/ { exit(found ? 0 : 1) }
    END { if (!in_function) exit 1 }
' "$SETUP" || fail "auto mode can stop VMs before validating the IP contract"
grep -Fq -- '--graceful-only' "$SETUP" || \
    fail "one-click setup can fall back to force-stopping a VM"
grep -Fq '/run/qemu-g11-vlan.lock' "$REPO_ROOT/deploy/scripts/host-vlan-bridge.sh" || \
    fail "bridge and TAP helpers do not share the VLAN lock"
for helper_source in \
        "$REPO_ROOT/deploy/scripts/host-vlan-bridge.sh" \
        "$REPO_ROOT/deploy/scripts/host-vlan-tap.sh"; do
    grep -Fq '/run/qemu-g11-network.lock' "$helper_source" || \
        fail "privileged VLAN helper bypasses the host maintenance lock"
done
grep -Fq '/etc/tmpfiles.d/qemu-g11-network.conf' "$SETUP" || \
    fail "maintenance lock is not recreated after reboot"
grep -Fq 'verify) verify_host_privileged' "$SETUP" || \
    fail "non-root verify does not use the read-only privileged verifier"
grep -Fq 'EUID != 0 && EXISTING_VLAN_CONFIG == 1' "$SETUP" || \
    fail "idempotent auto mode can misread the 0440 sudoers contract"
grep -Fq 'build_privileged_network_command verify-auto-ready command' "$SETUP" || \
    fail "privileged verification is not built from validated network options"
grep -Fq '/usr/bin/sudo -H -u root --' "$SETUP" || \
    fail "privileged verifier does not pin sudo runas to root"
grep -Fq 'verify_rc != AUTO_VERIFY_REPAIR_RC' "$SETUP" || \
    fail "sudo denial/cancellation can be mistaken for a repairable mismatch"
grep -Fq 'return "$AUTO_VERIFY_REPAIR_RC"' "$SETUP" || \
    fail "root verifier does not identify a genuine repairable mismatch"
grep -Fq 'status=privileged-verify-required' "$SETUP" || \
    fail "non-root inspect can mislabel its sudoers read boundary as needs-apply"
release_line="$(grep -nF '        release_network_maintenance_lock' "$SETUP" \
    | head -n1 | cut -d: -f1)"
service_restart_line="$(grep -nF 'systemctl restart qemu-g11-vlan-bridge.service' \
    "$SETUP" | tail -n1 | cut -d: -f1)"
[[ "$release_line" =~ ^[0-9]+$ && "$service_restart_line" =~ ^[0-9]+$ \
    && "$release_line" -lt "$service_restart_line" ]] || \
    fail "setup restarts the VLAN service while retaining its exclusive maintenance lock"
grep -Fq '/usr/local/libexec/qemu-g11-bridge-helper' "$SETUP" || \
    fail "setup does not install a dedicated G-11 bridge helper"
acl_install_line="$(grep -nF 'install -o root -g root -m 0644 "$bridge_tmp" /etc/qemu/bridge.conf' \
    "$SETUP" | head -n1 | cut -d: -f1)"
helper_install_line="$(grep -nF 'install -o root -g "$ALLOWED_GID_VALUE" -m 0750' \
    "$SETUP" | head -n1 | cut -d: -f1)"
[[ "$acl_install_line" =~ ^[0-9]+$ && "$helper_install_line" =~ ^[0-9]+$ \
    && "$acl_install_line" -lt "$helper_install_line" ]] || \
    fail "bridge helper gains privilege before its exact ACL is installed"
grep -Fq 'quarantine_installed_bridge_helper' "$SETUP" || \
    fail "unsafe existing bridge ACL does not quarantine the dedicated helper"
grep -Fq '现有 $MANAGED_NETPLAN_EARLY 无法参与有效回滚' "$SETUP" || \
    fail "recovery rollback can conflict with an existing managed early file"
if grep -Fq 'build/qemu-bridge-helper' "$SETUP"; then
    fail "setup may privilege a user-writable build helper"
fi
if grep -Fq 'SUDO_PASSWORD' "$SETUP" "$ROLLBACK"; then
    fail "bridge scripts mention an inline host credential"
fi
[[ ! -e "$REPO_ROOT/deploy/host/setup-bridge.sh" ]] || \
    fail "removed host setup entry still exists"

echo "PASS: G-11 one-click bridge setup is Netplan-safe, rollback-guarded and VLAN-ready"
