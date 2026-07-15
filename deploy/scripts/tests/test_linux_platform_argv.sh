#!/usr/bin/env bash
# 端到端验证 Linux 启动器把同一份平台/组件清单完整投影到 QEMU argv。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_fixed() {
    local needle="$1"
    grep -F -- "$needle" "$TMP_DIR/argv" >/dev/null \
        || fail "启动参数缺少: $needle"
}

# CI 不具备 KVM 和编译产物，因此用显式 compatibility dry-run 验证纯参数投影；
# 严格 KVM realize/TSC 路径分别由独立测试覆盖，生产默认仍为 STRICT_HARDWARE=1。
env \
    IMAGE_ROOT="$TMP_DIR/images" \
    DRY_RUN=1 \
    TPM=0 \
    HOST_TUNE=0 \
    CPU_ISOLATE=0 \
    QEMU_CAP_CHECK=0 \
    STRICT_HARDWARE=0 \
    STEALTH_KVM_AVAILABLE=1 \
    STEALTH_KVM_TSC_CONTROL=1 \
    STEALTH_KVM_GET_TSC_KHZ=1 \
    STEALTH_KVM_TSC_KHZ=3600000 \
    STEALTH_HOST_CPU_VENDOR=GenuineIntel \
    STEALTH_HOST_CPU_MAX_MHZ=5000 \
    CPUS=4 \
    "$START_VM" 9741 --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/argv"

assert_fixed "__DRY_RUN_ARGV__"
assert_fixed "cpus=4,cores=4,threads=1,sockets=1,maxcpus=4"
assert_fixed "memory-backend-memfd,id=mem0,size=8192M,share=on,prealloc=off"
assert_fixed "node,nodeid=0,memdev=mem0,cpus=0-3"
[[ "$(grep -Fc -- 'node,nodeid=' "$TMP_DIR/argv")" == 1 ]] \
    || fail "消费级单路平台必须且只能生成一个 guest NUMA node"

# 北桥、南桥、SMBus、AHCI 由同一个 Intel platform bundle 提供，不能留下 QEMU
# 默认厂商，也不能混入仅用于 compatibility 文档的 AMD 平台。
assert_fixed "q35-pcihost.x-pci-mch-vendor-id=0x8086"
assert_fixed "ICH9-LPC.x-pci-vendor-id=0x8086"
assert_fixed "ICH9-SMB.x-pci-vendor-id=0x8086"
assert_fixed "ich9-ahci.x-pci-vendor-id=0x8086"
[[ "$(grep -Fc -- 'pcie-root-port,id=rp' "$TMP_DIR/argv")" == 4 ]] \
    || fail "平台必须生成四个经过清单约束的 root port"

# 可更换件必须是 components.json 唯一启用的原子 bundle；这里同时核对深层字段，
# 防止只改显示名称却保留错误固件、subsystem、NQN、EDID 或 USB VID/PID。
nvme_line="$(grep -F -- 'nvme,id=nvmectl0' "$TMP_DIR/argv")"
[[ "$nvme_line" == *"model-number=Samsung SSD 970 PRO 512GB"* \
    && "$nvme_line" == *"firmware-rev=1B2QEXP7"* \
    && "$nvme_line" == *"subsys-vendor-id=0x144D"* \
    && "$nvme_line" == *"subsys-id=0xA801"* \
    && "$nvme_line" == *"subnqn=nqn.1994-11.com.samsung:nvme:970-PRO:M.2:S"* ]] \
    || fail "NVMe 参数没有完整绑定 970 PRO bundle"

nic_line="$(grep -F -- 'e1000e,netdev=net0' "$TMP_DIR/argv")"
[[ "$nic_line" == *"mac=3c:fd:fe:"* \
    && "$nic_line" == *"subsys_ven=0x8086"* \
    && "$nic_line" == *"subsys=0xA01F"* ]] \
    || fail "Intel 82574L 的 OUI/subsystem 未绑定平台"

assert_fixed "usb-kbd,id=kbd0,bus=xhci.0,vendorid=0x045E,productid=0x0750,manufacturer=Microsoft,product=Microsoft Wired Keyboard 600,x-force-numlock-on=on"
assert_fixed "usb-tablet,bus=xhci.0"
assert_fixed "ich9-intel-hda,id=hda0,x-pci-vendor-id=0x8086"
assert_fixed "hda-duplex,bus=hda0.0,cad=0,audiodev=aud0,x-identity-compat=on,x-codec-id=0x10ec0887,x-codec-revision=0x00100302,x-codec-subsystem-id=0x104386c7"
assert_fixed "edid-vendor=SAM,edid-name=S24F350"
assert_fixed "edid-fixed-native=on"
assert_fixed "edid-product-id=0x0F65,edid-manufacture-week=32,edid-manufacture-year=2018"
assert_fixed "edid-min-vfreq-hz=50,edid-max-vfreq-hz=75"
assert_fixed "edid-secondary-xres=1600,edid-secondary-yres=900,edid-secondary-refresh-rate=60000"
grep -F -- "'edid-fixed-native='" \
    "$REPO_ROOT/deploy/scripts/lib/sv-portability.sh" >/dev/null \
    || fail "Linux QEMU 能力门禁没有检查固定 EDID native mode 属性"
type17_line="$(grep -F -- 'type=17,loc_pfx=DIMM_%C2' "$TMP_DIR/argv")"
if grep -Fx -- 'ICH9-LPC.x-pci-device-id=0xA303' "$TMP_DIR/argv" >/dev/null; then
    [[ "$type17_line" =~ speed=(2400|2666),configured-speed=2400 ]] \
        || fail "H310 必须使用 2400MT/s 配置速率: $type17_line"
else
    [[ "$type17_line" =~ speed=(2400|2666),configured-speed=2133 ]] \
        || fail "H110 必须使用 2133MT/s 配置速率: $type17_line"
fi

[[ ! -e "$TMP_DIR/images/vms" ]] || fail "DRY_RUN 写入了实例目录"
echo "OK: Linux argv is an end-to-end projection of audited manifests"
