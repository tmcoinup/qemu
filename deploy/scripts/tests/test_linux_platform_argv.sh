#!/usr/bin/env bash
# 端到端验证 Linux 启动器把同一份平台/组件清单完整投影到 QEMU argv。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
MANIFEST="$REPO_ROOT/deploy/hardware/platforms.json"
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
cpu_arg="$(awk '$0 == "-cpu" { getline; print; exit }' "$TMP_DIR/argv")"
topology="$(
    python3 - "$MANIFEST" "$cpu_arg" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    platforms = json.load(stream)["platforms"]
matches = [
    item["cpu"] for item in platforms
    if sys.argv[2].startswith(item["cpu"]["qemu_arg"] + ",")
]
if len(matches) != 1:
    raise SystemExit(f"effective -cpu 未唯一匹配 manifest: {len(matches)}")
print(f"{matches[0]['cores']}:{matches[0]['threads']}")
PY
)" || fail "无法从所选 manifest bundle 解析 CPU 拓扑"
IFS=: read -r cpu_cores cpu_threads <<<"$topology"
assert_fixed "cpus=4,cores=${cpu_cores},threads=$((cpu_threads / cpu_cores)),sockets=1,maxcpus=4"
assert_fixed "memory-backend-memfd,id=mem0,size=8192M,share=on,prealloc=off"
assert_fixed "node,nodeid=0,memdev=mem0,cpus=0-3"
[[ "$(grep -Fc -- 'node,nodeid=' "$TMP_DIR/argv")" == 1 ]] \
    || fail "消费级单路平台必须且只能生成一个 guest NUMA node"
if grep -E -- 'release=5\.14|^type=3,.*asset=|^type=17,.*asset=9876543210' "$TMP_DIR/argv" >/dev/null; then
    fail "SMBIOS 注入了无清单证据的 BIOS release 或重复 asset 占位值"
fi

# MCH 保留 Q35 原生 8086:29c0。覆盖其 device ID 会让 EDK2 在 PlatformPei
# CpuDeadLoop，连 helper/ISO 都不会读取；PCH 三项仍由 Intel platform bundle 投影。
if grep -F -- "q35-pcihost.x-pci-mch-" "$TMP_DIR/argv" >/dev/null; then
    fail "Linux 启动参数不得覆盖 OVMF 用于识别 Q35 machine 的 MCH identity"
fi
assert_fixed "ICH9-LPC.x-pci-vendor-id=0x8086"
assert_fixed "ICH9-SMB.x-pci-vendor-id=0x8086"
assert_fixed "ich9-ahci.x-pci-vendor-id=0x8086"
[[ "$(grep -Fc -- 'pcie-root-port,id=rp' "$TMP_DIR/argv")" == 4 ]] \
    || fail "平台必须生成四个经过清单约束的 root port"

# 可更换件必须是 components.json 唯一启用的原子 bundle；这里同时核对深层字段，
# 防止只改显示名称却保留错误固件、subsystem、NQN、EDID 或 USB VID/PID。
nvme_line="$(grep -F -- 'nvme,id=nvmectl0' "$TMP_DIR/argv")"
uuid="$(awk '$0 == "-uuid" { getline; print; exit }' "$TMP_DIR/argv")"
[[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
    || fail "QEMU argv 缺少规范的 UUID v4: $uuid"
[[ "$nvme_line" == *"model-number=Samsung SSD 970 PRO 512GB"* \
    && "$nvme_line" == *"firmware-rev=1B2QEXP7"* \
    && "$nvme_line" == *"subsys-vendor-id=0x144D"* \
    && "$nvme_line" == *"subsys-id=0xA801"* \
    && "$nvme_line" == *"subnqn=nqn.2014-08.org.nvmexpress:uuid:$uuid"* ]] \
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
assert_fixed "edid-min-vfreq-hz=56,edid-max-vfreq-hz=75"
assert_fixed "edid-secondary-xres=1600,edid-secondary-yres=900,edid-secondary-refresh-rate=60000"
grep -F -- "'edid-fixed-native='" \
    "$REPO_ROOT/deploy/scripts/lib/sv-portability.sh" >/dev/null \
    || fail "Linux QEMU 能力门禁没有检查固定 EDID native mode 属性"
type17_line="$(grep -F -- 'type=17,loc_pfx=DIMM_%C2' "$TMP_DIR/argv")"
[[ "$type17_line" =~ device-width=(8|16) ]] \
    || fail "Type 17 没有投影硬件目录核验后的 DRAM 位宽: $type17_line"
[[ "$type17_line" == *"spd-ee1004=on"* ]] \
    || fail "DDR4 Type 17 没有启用完整 EE1004 SPD 身份页: $type17_line"
if grep -Fx -- 'ICH9-LPC.x-pci-device-id=0xA303' "$TMP_DIR/argv" >/dev/null; then
    [[ "$type17_line" =~ speed=(2400|2666),configured-speed=2400 ]] \
        || fail "H310 必须使用 2400MT/s 配置速率: $type17_line"
else
    [[ "$type17_line" =~ speed=(2400|2666),configured-speed=2133 ]] \
        || fail "H110 必须使用 2133MT/s 配置速率: $type17_line"
fi

[[ ! -e "$TMP_DIR/images/vms" ]] || fail "DRY_RUN 写入了实例目录"
echo "OK: Linux argv is an end-to-end projection of audited manifests"
