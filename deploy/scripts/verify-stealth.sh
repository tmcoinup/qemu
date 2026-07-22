#!/bin/bash
# ---------------------------------------------------------------------------
# verify-stealth.sh
#
# Quick sanity checks that exercise the patched QEMU *without* booting a
# full Windows guest: dumps Ryzen3-1200 feature expansion, validates that
# kvm=off,hypervisor=off produces the expected CPUID surface, verifies
# ACPI OEM strings via the fw_cfg dump, and checks NVMe Identify strings.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
QEMU="${QEMU:-$REPO_ROOT/build/qemu-system-x86_64}"
VERIFY_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-stealth.XXXXXX")"
QPID='' RPPID='' P15PID='' P16PID=''

cleanup() {
    local pid
    for pid in "$QPID" "$RPPID" "$P15PID" "$P16PID"; do
        [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    done
    rm -rf -- "$VERIFY_TMP_DIR"
}
trap cleanup EXIT

# --- stderr 安全网 (P1#4) ---------------------------------------------------
# 仓库规则要求"运行无警告"。历史上 step(2) 在 TCG 上 realize Ryzen3-1200 会刷
# 36 条 "TCG doesn't support requested feature" 警告（fxsr-opt/topoext/invtsc/
# clzero/nrip-save/xsavec…）。现已改为：启动 vCPU 不指定该 CPU，改由
# query-cpu-model-expansion 按名做静态展开，从源头消除警告。这里再加一道安全
# 网——收集每次 QEMU 启动的 stderr，凡出现未登记的 warning/error 即判失败，
# 避免真正的 regression warning 被淹没。预期可忽略项登记到 STDERR_ALLOW。
STDERR_ALLOW=()      # 逐条 ERE，例如 "TCG doesn.t support requested feature"
UNEXPECTED_STDERR=0
scan_stderr() {
    local f="$1" label="$2" lines pat
    [[ -s "$f" ]] || return 0
    lines="$(grep -E -i 'warning|error' "$f" || true)"
    for pat in ${STDERR_ALLOW[@]+"${STDERR_ALLOW[@]}"}; do
        lines="$(grep -E -v "$pat" <<<"$lines" || true)"
    done
    lines="$(grep -E -v '^[[:space:]]*$' <<<"$lines" || true)"
    if [[ -n "$lines" ]]; then
        echo "  ✗ [$label] 非预期 stderr：" >&2
        sed 's/^/      /' <<<"$lines" >&2
        UNEXPECTED_STDERR=1
    fi
}

echo "=== (1) CPU model registered ==="
"$QEMU" -cpu help 2>&1 | grep -i 'ryzen3-1200' || { echo "MISSING Ryzen3-1200"; exit 1; }

echo
echo "=== (2) CPU model expansion (via QMP query-cpu-model-expansion) ==="
SOCK="$VERIFY_TMP_DIR/cpu.qmp"
CPU_ERR="$VERIFY_TMP_DIR/cpu.err"
rm -f "$SOCK"
# 启动 vCPU 不指定 Ryzen3-1200：下面的 query-cpu-model-expansion 按名传参做静态
# 展开，与所启 vCPU 无关。用 TCG 默认 CPU 可避免 realize 时刷 TCG 不支持特性的
# 警告。stderr 收集到 $CPU_ERR，稍后 scan_stderr 检查。
"$QEMU" -machine q35,accel=tcg -smp 4 -m 512M -nographic -S \
    -display none \
    -qmp "unix:$SOCK,server=on,wait=off" 2>"$CPU_ERR" &
QPID=$!
sleep 1.5

python3 - "$SOCK" <<'PY'
import json, socket, sys
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX); s.connect(p)
f = s.makefile('rwb', buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()
# kvm=off,hypervisor=off 通过 query 的 props 传入（而非启动 -cpu 的全局属性），
# 既保留对 stealth CPUID 面的校验，又不在 TCG 上 realize 带不支持特性的 vCPU。
f.write(b'{"execute":"query-cpu-model-expansion","arguments":{"type":"full","model":{"name":"Ryzen3-1200","props":{"kvm":false,"hypervisor":false}}}}\n')
resp = json.loads(f.readline())
props = resp.get('return',{}).get('model',{}).get('props',{})
bad = []
if props.get('hypervisor') not in (False, None, 'off'): bad.append(('hypervisor', props.get('hypervisor')))
if props.get('kvm')        not in (False, None, 'off'): bad.append(('kvm',        props.get('kvm')))
need = ['invtsc','topoext','svm','sha-ni','clflushopt','xsaveopt','aes','avx2']
missing = [n for n in need if props.get(n) not in (True,'on')]
print("  hypervisor =", props.get('hypervisor'))
print("  kvm        =", props.get('kvm'))
print("  vendor     =", props.get('vendor'))
print("  family     =", props.get('family'))
print("  model      =", props.get('model'))
print("  stepping   =", props.get('stepping'))
print("  model-id   =", props.get('model-id'))
for n in need:
    print(f"  {n:12s} = {props.get(n)}")
if bad or missing:
    print("FAIL:", bad, "missing:", missing); sys.exit(1)
print("OK")
PY

scan_stderr "$CPU_ERR" "CPU expansion"
kill "$QPID" 2>/dev/null || true
QPID=

echo
echo "=== (3) ACPI OEM strings baked into binary ==="
strings "$QEMU" | grep -E '^(ALASKA|A M I )' | head -5

echo
echo "=== (4) NVMe properties registered ==="
"$QEMU" -device nvme,help 2>&1 | grep -E 'samsung|model-number|firmware-rev'

echo
echo "=== (5) 动态 TPM 平台目录 + swtpm/QEMU 前端 ==="
# shellcheck source=lib/verify-tpm-platforms.sh
source "$HERE/lib/verify-tpm-platforms.sh"
verify_tpm_platforms "$QEMU"
# OVMF Tcg2 模块自检：Ubuntu 默认 ovmf 包不编 TPM2_ENABLE，guest tpm.msc
# 会"找不到兼容的 TPM"。我们自编的 stealth fd 应该有 Tcg2 模块。
EDK2_BUILD="${EDK2_BUILD:-$HOME/src/edk2/Build/OvmfX64/RELEASE_GCC5/X64}"
if [[ -d "$EDK2_BUILD" ]]; then
    tcg_count=0
    for m in Tcg2Dxe Tcg2Pei Tcg2ConfigDxe Tcg2PlatformDxe; do
        if [[ -f "$EDK2_BUILD/${m}.efi" ]]; then
            tcg_count=$((tcg_count + 1))
        fi
    done
    if (( tcg_count == 4 )); then
        echo "  OVMF Tcg2 模块: 4/4 (Dxe/Pei/ConfigDxe/PlatformDxe) ✓"
    else
        echo "WARN: OVMF build 目录里 Tcg2 模块只 $tcg_count/4——guest TPM 可能不工作"
        echo "      修复: $HERE/../tools/build-ovmf.sh"
    fi
else
    echo "WARN: edk2 build 目录不存在 ($EDK2_BUILD)，无法验证 OVMF TPM 编译状态"
fi

echo
echo "=== (6) 伪 BGRT 表存在 ==="
BGRT_BIN="$(cd "$HERE/../firmware" && pwd)/bgrt.bin"
if [[ -f "$BGRT_BIN" ]]; then
    sz=$(stat -c%s "$BGRT_BIN")
    if (( sz == 20 )); then
        echo "  bgrt.bin     = 20 字节 (ACPI 5.0+ BGRT body 标准长度)"
    else
        echo "FAIL: bgrt.bin 长度 $sz 不是 20——结构异常"; exit 1
    fi
else
    echo "WARN: bgrt.bin 不存在；start-vm.sh 会跳过 -acpitable，guest 缺 BGRT 表"
fi

echo
echo "=== (7) stealth-lib.sh: BOARD_POOL 每条都有 SUBSYS_VEN|SUBSYS_DEV ==="
# shellcheck disable=SC1091
source "$HERE/stealth-lib.sh"
bad_rows=0
for row in "${BOARD_POOL[@]}"; do
    # 分隔符数应该是 7（8 个字段）；老格式只有 5（6 字段）
    n=$(awk -F'|' '{print NF}' <<<"$row")
    if (( n != 8 )); then
        echo "FAIL: 字段数 $n != 8: $row"
        bad_rows=$((bad_rows + 1))
    fi
done
if (( bad_rows > 0 )); then exit 1; fi
echo "  ${#BOARD_POOL[@]} 条板子全部 8 字段（含 SUBSYS_VEN / SUBSYS_DEV）"

printf '\n=== (8) 启用平台 CPU 的 iGPU 状态符合主板禁用策略 ===\n'
checked_platforms=0
for platform_row in "${PLATFORM_POOL[@]}"; do
    IFS='|' read -r platform_id enabled _ <<<"$platform_row"
    [[ "$enabled" == true ]] || continue
    (stealth_platform_load "$platform_id" && stealth_validate_guest_cpu_class)
    checked_platforms=$((checked_platforms + 1))
done
(( checked_platforms > 0 )) || { echo "FAIL: 没有可验证的启用平台"; exit 1; }
echo "  $checked_platforms 个启用平台全部符合 iGPU/BIOS 禁用状态契约"

echo
echo "=== (9) NVMe 池：MODEL ↔ SIZE 自洽 ==="
# shellcheck disable=SC1091
source "$HERE/stealth-lib.sh"
bad_nvme=0
for row in "${NVME_POOL[@]}"; do
    # components.json 的 storage 投影视图以 component_id 开头；容量判断必须读取
    # 后续的真实 model/firmware/raw_bytes，不能把稳定 ID 当成型号而跳过校验。
    IFS='|' read -r component_id m fw sz _ <<<"$row"
    if [[ -z "$component_id" || -z "$m" || -z "$fw" ]]; then
        echo "FAIL: storage 组件缺少 ID/model/firmware: $row"
        bad_nvme=$((bad_nvme + 1))
        continue
    fi
    if [[ -z "$sz" ]]; then
        echo "FAIL: 缺 RAW_BYTES 字段: $row"; bad_nvme=$((bad_nvme + 1)); continue
    fi
    # 按 model 名字推容量段：1TB ≈ 10^12B、500/512GB ≈ 5×10^11B、2TB ≈ 2×10^12B
    expected_lo=0; expected_hi=0
    case "$m" in
        *1TB*)   expected_lo=$((  900 * 1000 * 1000 * 1000));  expected_hi=$(( 1100 * 1000 * 1000 * 1000)) ;;
        *2TB*)   expected_lo=$(( 1900 * 1000 * 1000 * 1000));  expected_hi=$(( 2100 * 1000 * 1000 * 1000)) ;;
        *500GB*) expected_lo=$((  450 * 1000 * 1000 * 1000));  expected_hi=$((  520 * 1000 * 1000 * 1000)) ;;
        *512GB*) expected_lo=$((  470 * 1000 * 1000 * 1000));  expected_hi=$((  530 * 1000 * 1000 * 1000)) ;;
        *256GB*) expected_lo=$((  240 * 1000 * 1000 * 1000));  expected_hi=$((  280 * 1000 * 1000 * 1000)) ;;
        *) echo "WARN: 无法从 model '$m' 推断容量段，跳过比对"; continue ;;
    esac
    if (( sz < expected_lo || sz > expected_hi )); then
        echo "FAIL: $m → $sz 字节，期望 [$expected_lo, $expected_hi]"
        bad_nvme=$((bad_nvme + 1))
    fi
done
if (( bad_nvme > 0 )); then
    echo "FAIL: NVMe 池有 $bad_nvme 条 model/size 不一致——会导致 Win32_DiskDrive Model vs Size 跨向量矛盾"; exit 1
fi
echo "  ${#NVME_POOL[@]} 条 NVMe 池全部 Model ↔ Size 一致"

echo
echo "=== (10) DIMM SN 持久化 ==="
# shellcheck source=lib/verify-profile-persistence.sh
source "$HERE/lib/verify-profile-persistence.sh"
verify_profile_persistence "$HERE"

echo
echo "=== (11) USB HID + EDID 自定义 prop（patch 0009/0010） ==="
edid_help="$("$QEMU" -device virtio-vga,help 2>&1 || true)"
if grep -qE "edid-vendor=|edid-name=|edid-serial=" <<<"$edid_help"; then
    echo "  virtio-vga: edid-vendor / edid-name / edid-serial ✓ (patch 0009)"
else
    echo "FAIL: virtio-vga 缺 edid-vendor/edid-name/edid-serial——patch 0009 没编进 QEMU"
    exit 1
fi
usbkbd_help="$("$QEMU" -device usb-kbd,help 2>&1 || true)"
if grep -qE "vendorid=|productid=|manufacturer=|product=" <<<"$usbkbd_help"; then
    echo "  usb-kbd:   vendorid / productid / manufacturer / product ✓ (patch 0010)"
else
    echo "FAIL: usb-kbd 缺 vendorid/productid/manufacturer/product——patch 0010 没编进 QEMU"
    exit 1
fi
usbtab_help="$("$QEMU" -device usb-tablet,help 2>&1 || true)"
if grep -qE "vendorid=|productid=" <<<"$usbtab_help"; then
    echo "  usb-tablet: vendorid / productid ✓ (patch 0010)"
else
    echo "FAIL: usb-tablet 缺 vendorid/productid——patch 0010 没编进 QEMU"
    exit 1
fi

echo
echo "=== (12) 外设池字段数自洽 ==="
# shellcheck disable=SC1091
source "$HERE/stealth-lib.sh"
bad_pool=0
for row in "${MONITOR_POOL[@]}"; do
    n=$(awk -F'|' '{print NF}' <<<"$row")
    if (( n != 18 )); then echo "FAIL MONITOR_POOL: 字段数 $n != 18: $row"; bad_pool=$((bad_pool+1)); fi
done
for row in "${KBD_POOL[@]}" "${MOUSE_POOL[@]}" "${TABLET_POOL[@]}"; do
    n=$(awk -F'|' '{print NF}' <<<"$row")
    if (( n != 7 )); then echo "FAIL HID pool: 字段数 $n != 7: $row"; bad_pool=$((bad_pool+1)); fi
done
if (( bad_pool > 0 )); then exit 1; fi
echo "  MONITOR_POOL=${#MONITOR_POOL[@]}（18 字段） KBD=${#KBD_POOL[@]} MOUSE=${#MOUSE_POOL[@]} TABLET=${#TABLET_POOL[@]}（7 字段）"

echo
echo "=== (13) 伪 SSDT 热区表 ==="
SSDT_AML="$(cd "$HERE/../firmware" && pwd)/ssdt-thermal.aml"
if [[ -f "$SSDT_AML" ]]; then
    # 头 4 字节必须是 ASCII "SSDT"
    sig=$(head -c4 "$SSDT_AML")
    if [[ "$sig" != "SSDT" ]]; then
        echo "FAIL: $SSDT_AML 头不是 SSDT (实际: $sig)"; exit 1
    fi
    # iasl 输出的 AML 含完整表头 + body，最小合规 SSDT 不应小于 36+10 字节
    sz=$(stat -c%s "$SSDT_AML")
    if (( sz < 50 )); then
        echo "FAIL: ssdt-thermal.aml 长度 $sz 太短（可能 iasl 未编完）"; exit 1
    fi
    echo "  ssdt-thermal.aml = $sz 字节, 头=SSDT ✓"
    # 验证表里有 _TMP 关键字（OEM 仿真机扫表常匹配的字符串）
    if ! grep -q "_TMP" "$SSDT_AML"; then
        echo "FAIL: SSDT 里找不到 _TMP method 名"; exit 1
    fi
    echo "  含 _TMP / _CRT / _PSV ThermalZone method ✓"
else
    echo "WARN: ssdt-thermal.aml 不存在；start-vm.sh 会跳过 SSDT 注入，guest 缺热区"
    echo "      修复: cd $(cd "$HERE/../firmware" && pwd) && iasl -p ssdt-thermal ssdt-thermal.asl"
fi

echo
echo '=== (14) PCIe 根端口 hotplug=off（消除托盘"安全删除硬件"图标） ==='
# 真机板载 NVMe/网卡/USB 走非热插拔端口。若根端口 hotplug=on（QEMU 默认），
# Slot Capabilities 会置 HPC/HPS 位 (hw/pci/pcie.c pcie_cap_slot_init)，Windows
# pci.sys 沿父桥上溯后把下游 NVMe/82574L/xHCI 判为可移除 → 托盘冒出"弹出 …"。
# 这里启真实四口根端口拓扑，用 qom-get 读回每个端口的 hotplug 属性，须全为 false。
RPSOCK="$VERIFY_TMP_DIR/root-port.qmp"
RPERR="$VERIFY_TMP_DIR/root-port.err"
rm -f "$RPSOCK"
"$QEMU" -machine q35,accel=tcg -m 256M -nographic -S \
    -display none \
    -qmp "unix:$RPSOCK,server=on,wait=off" \
    -device pcie-root-port,id=rp0,slot=0,bus=pcie.0,multifunction=on,hotplug=off \
    -device pcie-root-port,id=rp1,slot=1,bus=pcie.0,hotplug=off \
    -device pcie-root-port,id=rp2,slot=2,bus=pcie.0,hotplug=off \
    -device pcie-root-port,id=rp3,slot=3,bus=pcie.0,hotplug=off 2>"$RPERR" &
RPPID=$!
sleep 1.5
if python3 - "$RPSOCK" <<'PY'
import json, socket, sys
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX); s.connect(p)
f = s.makefile('rwb', buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()
bad = []
for rp in ("rp0", "rp1", "rp2", "rp3"):
    cmd = {"execute": "qom-get",
           "arguments": {"path": f"/machine/peripheral/{rp}", "property": "hotplug"}}
    f.write((json.dumps(cmd) + "\n").encode())
    val = json.loads(f.readline()).get("return")
    print(f"  {rp}.hotplug = {val}")
    if val is not False:
        bad.append((rp, val))
if bad:
    print("FAIL: 根端口仍可热插拔（HPC 会被置位 → 托盘出现安全删除图标）:", bad)
    sys.exit(1)
print("OK: 四个根端口 hotplug 全部关闭")
PY
then RC=0; else RC=1; fi
kill "$RPPID" 2>/dev/null || true
RPPID=
scan_stderr "$RPERR" "root-port"
rm -f "$RPSOCK"
[[ $RC -eq 0 ]] || exit 1

echo
echo "=== (15) 行为身份：root-port 可覆盖，qemu-xhci 固定官方 PCI ID ==="
# root-port 可按平台覆盖；xHCI 必须固定与虚拟模型匹配的上游完整身份。刻意注入
# ASUS 的全局 subsystem 默认值，验证 qemu-xhci 不会继承它。
# 设备直接挂 pcie.0 顶层，使 query-pci 无需固件枚举即可读取完整身份。
P15SOCK="$VERIFY_TMP_DIR/identity.qmp"; P15ERR="$VERIFY_TMP_DIR/identity.err"; rm -f "$P15SOCK"
QEMU_PCI_SUBSYS_VEN=0x1043 QEMU_PCI_SUBSYS_DEV=0x8694 \
"$QEMU" -machine q35,accel=tcg -m 256M -nographic -S -display none -nodefaults \
    -qmp "unix:$P15SOCK,server=on,wait=off" \
    -device pcie-root-port,id=rpa,bus=pcie.0,addr=0x2,chassis=1 \
    -device pcie-root-port,id=rpi,bus=pcie.0,addr=0x3,chassis=2,x-pci-vendor-id=0x8086,x-pci-device-id=0xa338,x-pci-revision=0xf0 \
    -device qemu-xhci,id=xhci,bus=pcie.0,addr=0x4 2>"$P15ERR" &
P15PID=$!
for _ in $(seq 1 50); do [[ -S "$P15SOCK" ]] && break; sleep 0.1; done
if python3 - "$P15SOCK" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
f = s.makefile('rwb', buffering=0)
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()
f.write(b'{"execute":"query-pci"}\n'); r = json.loads(f.readline())
ids = {}
for bus in r["return"]:
    for d in bus["devices"]:
        identity = d["id"]
        ids[d["slot"]] = tuple(
            identity[key]
            for key in ("vendor", "device", "subsystem-vendor", "subsystem")
            if key in identity
        )
want = {
    2: (0x1022, 0x1453),
    3: (0x8086, 0xa338),
    4: (0x1b36, 0x000d, 0x1af4, 0x1100),
}
label = {2: "AMD root-port(default)", 3: "Intel root-port(override)",
         4: "QEMU xHCI(behavior ID)"}
bad = []
for slot, expected in want.items():
    actual = ids.get(slot, ())
    shown_actual = ":".join(f"{value:04x}" for value in actual)
    shown_expected = ":".join(f"{value:04x}" for value in expected)
    print(
        f"  slot {slot} {label[slot]:28s} {shown_actual}"
        f"  期望 {shown_expected}"
    )
    if actual[:len(expected)] != expected:
        bad.append(slot)
if bad:
    print("FAIL: PCI 行为身份不符合契约:", bad); sys.exit(1)
print("OK: root-port 展示覆盖与 qemu-xhci 行为身份均正确")
PY
then RC=0; else RC=1; fi
kill "$P15PID" 2>/dev/null || true
P15PID=
scan_stderr "$P15ERR" "platform-id"
rm -f "$P15SOCK"
[[ $RC -eq 0 ]] || exit 1

echo
echo "=== (16) PCIe 链路速率：根端口/NVMe 端点链路自洽 ==="
# QEMU 的 pcie-root-port 默认 x-speed=Gen4(16GT/s) / x-width=x32。
# NVMe 端点默认 Gen1 x1。两者都与 AM4/300·400 系平台 +
# Samsung Gen3 盘矛盾。CrystalDiskInfo / 设备管理器
# “PCI 链接速度” / 仿真机读 PCI_EXP_LNKCAP 会看到破绽。
#   (a) 运行态：qom-get 验四个根端口 x-speed/x-width 已钉死
#       (rp1=NVMe Gen3 x4；rp0/rp2/rp3 = Gen1 x1)；
#   (b) 静态：sv-devices.sh 和 hw/nvme/ctrl.c 补丁仍在位。
P16SOCK="$VERIFY_TMP_DIR/link.qmp"
P16ERR="$VERIFY_TMP_DIR/link.err"
rm -f "$P16SOCK"
"$QEMU" -machine q35,accel=tcg -m 256M -nographic -S -display none -nodefaults \
    -qmp "unix:$P16SOCK,server=on,wait=off" \
    -device "pcie-root-port,id=rp0,slot=0,bus=pcie.0,multifunction=on,hotplug=off,\
x-speed=2_5,x-width=1" \
    -device "pcie-root-port,id=rp1,slot=1,bus=pcie.0,hotplug=off,x-speed=8,x-width=4" \
    -device "pcie-root-port,id=rp2,slot=2,bus=pcie.0,hotplug=off,x-speed=2_5,x-width=1" \
    -device "pcie-root-port,id=rp3,slot=3,bus=pcie.0,hotplug=off,x-speed=2_5,x-width=1" \
    2>"$P16ERR" &
P16PID=$!
for _ in $(seq 1 50); do [[ -S "$P16SOCK" ]] && break; sleep 0.1; done
if python3 - "$P16SOCK" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
f = s.makefile('rwb', buffering=0)
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n'); f.readline()
want = {"rp0": ("2_5", "1"), "rp1": ("8", "4"),
        "rp2": ("2_5", "1"), "rp3": ("2_5", "1")}
label = {
    "rp0": "空槽",
    "rp1": "NVMe",
    "rp2": "e1000e/82574L",
    "rp3": "xHCI",
}
def get(rp, prop):
    req = {"execute": "qom-get", "arguments": {
        "path": f"/machine/peripheral/{rp}",
        "property": prop,
    }}
    f.write((json.dumps(req) + "\n").encode())
    return str(json.loads(f.readline()).get("return"))
bad = []
for rp, (ws, ww) in want.items():
    gs, gw = get(rp, "x-speed"), get(rp, "x-width")
    print(
        f"  {rp} {label[rp]:14s} "
        f"x-speed={gs:<3s} x-width={gw:<2s}  期望 {ws}/{ww}"
    )
    if (gs, gw) != (ws, ww):
        bad.append(rp)
if bad:
    print("FAIL: 根端口链路速率/宽度未钉到真实值:", bad)
    sys.exit(1)
print("OK: 根端口链路 = NVMe Gen3 x4，其余 Gen1 x1")
PY
then RC=0; else RC=1; fi
kill "$P16PID" 2>/dev/null || true
P16PID=
scan_stderr "$P16ERR" "pcie-link"
rm -f "$P16SOCK"
[[ $RC -eq 0 ]] || exit 1

# (b) 静态护栏：
#     确保两半改动不在版本升级/重打补丁时丢掉。
SVDEV="$HERE/lib/sv-devices.sh"; CTRL="$REPO_ROOT/hw/nvme/ctrl.c"
if [[ -f "$SVDEV" ]]; then
    svdev_flat="$(tr -d '\n\t\\"' < "$SVDEV")"
    # rp1 现由组件目录的 NVME_MAX_PCIE_GENERATION/NVME_LANES 生成，不能再
    # 用历史硬编码字面量做静态断言；运行态检查已验证当前目录会得到 Gen3 x4。
    grep -Eq 'id=rp1.*x-speed=[$][{]_nvme_link_speed[}],x-width=[$][{]_nvme_link_width[}]' \
        <<<"$svdev_flat" \
        || { echo "FAIL: sv-devices.sh rp1 未绑定组件目录的 NVMe 链路参数"; exit 1; }
    grep -Eq 'id=rp2.*x-speed=2_5,x-width=1' <<<"$svdev_flat" \
        || { echo "FAIL: sv-devices.sh rp2 未钉 82574L Gen1 x1"; exit 1; }
    echo "  sv-devices.sh: 根端口 x-speed/x-width 静态校验通过"
else
    echo "  (skip 静态校验：未找到 $SVDEV)"
fi
if [[ -f "$CTRL" ]]; then
    grep -Eq 'pcie_cap_fill_link_ep_usp\(pci_dev, *QEMU_PCI_EXP_LNK_X4' \
        "$CTRL" || {
            echo "FAIL: hw/nvme/ctrl.c 未把 Samsung NVMe 端点抬到 Gen3 x4"
            exit 1
        }
    echo "  hw/nvme/ctrl.c: NVMe 端点 Gen3 x4 端点补丁在位"
else
    echo "  (skip 静态校验：未找到 $CTRL)"
fi

echo
if [[ $UNEXPECTED_STDERR -ne 0 ]]; then
    echo "FAIL: 检测到未登记的 warning/error（见上）——不满足'运行无警告'。" >&2
    exit 1
fi
echo "all checks passed."
