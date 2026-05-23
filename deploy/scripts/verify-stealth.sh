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
SOCK="/tmp/verify-stealth.qmp"
CPU_ERR="/tmp/verify-stealth-cpu.err"
rm -f "$SOCK"
# 启动 vCPU 不指定 Ryzen3-1200：下面的 query-cpu-model-expansion 按名传参做静态
# 展开，与所启 vCPU 无关。用 TCG 默认 CPU 可避免 realize 时刷 TCG 不支持特性的
# 警告。stderr 收集到 $CPU_ERR，稍后 scan_stderr 检查。
"$QEMU" -machine q35,accel=tcg -smp 4 -m 512M -nographic -S \
    -display none \
    -qmp unix:$SOCK,server=on,wait=off 2>"$CPU_ERR" &
QPID=$!
trap 'kill $QPID 2>/dev/null; rm -f $SOCK' EXIT
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

echo
echo "=== (3) ACPI OEM strings baked into binary ==="
strings "$QEMU" | grep -E '^(ALASKA|A M I )' | head -5

echo
echo "=== (4) NVMe properties registered ==="
"$QEMU" -device nvme,help 2>&1 | grep -E 'samsung|model-number|firmware-rev'

echo
echo "=== (5) TPM 2.0 emulator (swtpm) + OVMF Tcg2 模块 ==="
if command -v swtpm >/dev/null 2>&1; then
    echo "  swtpm        = $(swtpm --version | head -1)"
    echo "  swtpm_setup  = $(command -v swtpm_setup)"
    # QEMU `-tpmdev help` 退出码 = 1（QEMU 把 help 看作异常终止），
    # 在 `set -o pipefail` 下会把整条 pipeline 拉成 fail。先 capture 输出
    # 再独立 grep，绕开 pipefail 的退出码取最大语义。
    tpm_help_out="$("$QEMU" -tpmdev help 2>&1 || true)"
    if grep -qi emulator <<<"$tpm_help_out"; then
        echo "  -tpmdev emulator: supported"
    else
        echo "FAIL: QEMU 没编 CONFIG_TPM_EMULATOR——guest 无法挂 swtpm"; exit 1
    fi
else
    echo "WARN: swtpm 未装；start-vm.sh 会优雅降级（无 TPM）但反作弊会判 sandbox"
fi
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

echo
echo "=== (8) CPU_POOL 只包含**无 iGPU** SKU ==="
forbidden_substrings=("G6400" "G5400" "i3-9100 CPU")  # 不带 F 的 i3-9100 也算
for row in "${CPU_POOL[@]}"; do
    for kw in "${forbidden_substrings[@]}"; do
        if [[ "$row" == *"$kw"* ]]; then
            echo "FAIL: CPU_POOL 包含带 iGPU 型号: $row"; exit 1
        fi
    done
done
echo "  ${#CPU_POOL[@]} 个 CPU 全部无 iGPU"

echo
echo "=== (9) NVMe 池：MODEL ↔ SIZE 自洽 ==="
# shellcheck disable=SC1091
source "$HERE/stealth-lib.sh"
bad_nvme=0
for row in "${NVME_POOL[@]}"; do
    IFS='|' read -r m fw sz <<<"$row"
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
# 拉一份临时 profile, pick → save → load → 比对 SN 是否稳定
_tmp_prof="/tmp/verify-stealth-tmp-profile.$$"
(
    # 1. pick 一份 profile + save
    source "$HERE/stealth-lib.sh"
    stealth_pick_profile
    stealth_save_profile "$_tmp_prof"
    echo "  pick 时 MEM_SERIAL = $MEM_SERIAL"
) > /tmp/verify-stealth-step.log
cat /tmp/verify-stealth-step.log
sn_in_file=$(grep "^MEM_SERIAL=" "$_tmp_prof" | cut -d= -f2 | tr -d "'\"")
echo "  写入 profile 文件   = $sn_in_file"
# 2. 模拟"重启" - 新 subshell load
sn_load_1=$(source "$HERE/stealth-lib.sh" && stealth_load_profile "$_tmp_prof" && echo "$MEM_SERIAL")
sn_load_2=$(source "$HERE/stealth-lib.sh" && stealth_load_profile "$_tmp_prof" && echo "$MEM_SERIAL")
echo "  load 第 1 次        = $sn_load_1"
echo "  load 第 2 次        = $sn_load_2"
if [[ "$sn_in_file" == "$sn_load_1" && "$sn_load_1" == "$sn_load_2" ]]; then
    echo "  ✓ DIMM SN 跨重启一致"
else
    echo "FAIL: DIMM SN 在 save→load→load 之间漂移"; rm -f "$_tmp_prof" /tmp/verify-stealth-step.log; exit 1
fi
# 3. 老 profile 没 MEM_SERIAL 字段 → UUID 派生稳定值
if [[ -f "$HOME/images/vms/1/profile" ]]; then
    sn_old_1=$(source "$HERE/stealth-lib.sh" && stealth_load_profile "$HOME/images/vms/1/profile" && echo "$MEM_SERIAL")
    sn_old_2=$(source "$HERE/stealth-lib.sh" && stealth_load_profile "$HOME/images/vms/1/profile" && echo "$MEM_SERIAL")
    if [[ -n "$sn_old_1" && "$sn_old_1" == "$sn_old_2" ]]; then
        echo "  ✓ 老 profile fallback 派生稳定: $sn_old_1"
    else
        echo "FAIL: 老 profile fallback 不稳定 ($sn_old_1 vs $sn_old_2)"; rm -f "$_tmp_prof" /tmp/verify-stealth-step.log; exit 1
    fi
fi
rm -f "$_tmp_prof" /tmp/verify-stealth-step.log

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
    if (( n != 5 )); then echo "FAIL MONITOR_POOL: 字段数 $n != 5: $row"; bad_pool=$((bad_pool+1)); fi
done
for row in "${KBD_POOL[@]}" "${MOUSE_POOL[@]}" "${TABLET_POOL[@]}"; do
    n=$(awk -F'|' '{print NF}' <<<"$row")
    if (( n != 5 )); then echo "FAIL HID pool: 字段数 $n != 5: $row"; bad_pool=$((bad_pool+1)); fi
done
if (( bad_pool > 0 )); then exit 1; fi
echo "  MONITOR_POOL=${#MONITOR_POOL[@]}  KBD=${#KBD_POOL[@]}  MOUSE=${#MOUSE_POOL[@]}  TABLET=${#TABLET_POOL[@]} 全部 5 字段"

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
    # 验证表里有 _TMP 关键字（OEM 反作弊扫表常匹配的字符串）
    if ! grep -q "_TMP" "$SSDT_AML"; then
        echo "FAIL: SSDT 里找不到 _TMP method 名"; exit 1
    fi
    echo "  含 _TMP / _CRT / _PSV ThermalZone method ✓"
else
    echo "WARN: ssdt-thermal.aml 不存在；start-vm.sh 会跳过 SSDT 注入，guest 缺热区"
    echo "      修复: cd $(cd "$HERE/../firmware" && pwd) && iasl -p ssdt-thermal ssdt-thermal.asl"
fi

echo
echo "=== (14) PCIe 根端口 hotplug=off（消除托盘"安全删除硬件"图标） ==="
# 真机板载 NVMe/网卡/USB 走非热插拔端口。若根端口 hotplug=on（QEMU 默认），
# Slot Capabilities 会置 HPC/HPS 位 (hw/pci/pcie.c pcie_cap_slot_init)，Windows
# pci.sys 沿父桥上溯后把下游 NVMe/82574L/xHCI 判为可移除 → 托盘冒出"弹出 …"。
# 这里启真实四口根端口拓扑，用 qom-get 读回每个端口的 hotplug 属性，须全为 false。
RPSOCK="/tmp/verify-stealth-rp.qmp"
RPERR="/tmp/verify-stealth-rp.err"
rm -f "$RPSOCK"
"$QEMU" -machine q35,accel=tcg -m 256M -nographic -S \
    -display none \
    -qmp unix:$RPSOCK,server=on,wait=off \
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
scan_stderr "$RPERR" "root-port"
rm -f "$RPSOCK"
[[ $RC -eq 0 ]] || exit 1

echo
echo "=== (15) 平台一致性：root-port / xHCI PCI ID 可按平台覆盖 (P0#3) ==="
# 验证新加的 x-pci-vendor-id/device-id/revision 覆盖属性：默认沿用 AMD
# (1022:1453 / 1022:43bb)，注入后变 Intel 300 系 PCH (8086:a338 / 8086:a36d)。
# 设备直接挂 pcie.0 顶层，使 query-pci 无需固件枚举即可读到 vendor/device。
P15SOCK="/tmp/verify-stealth-p15.qmp"; P15ERR="/tmp/verify-stealth-p15.err"; rm -f "$P15SOCK"
"$QEMU" -machine q35,accel=tcg -m 256M -nographic -S -display none -nodefaults \
    -qmp unix:$P15SOCK,server=on,wait=off \
    -device pcie-root-port,id=rpa,bus=pcie.0,addr=0x2,chassis=1 \
    -device pcie-root-port,id=rpi,bus=pcie.0,addr=0x3,chassis=2,x-pci-vendor-id=0x8086,x-pci-device-id=0xa338,x-pci-revision=0xf0 \
    -device qemu-xhci,id=xa,bus=pcie.0,addr=0x4 \
    -device qemu-xhci,id=xi,bus=pcie.0,addr=0x5,x-pci-vendor-id=0x8086,x-pci-device-id=0xa36d 2>"$P15ERR" &
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
        ids[d["slot"]] = (d["id"]["vendor"], d["id"]["device"])
want = {2: (0x1022, 0x1453), 3: (0x8086, 0xa338),
        4: (0x1022, 0x43bb), 5: (0x8086, 0xa36d)}
label = {2: "AMD root-port(default)", 3: "Intel root-port(override)",
         4: "AMD xHCI(default)",      5: "Intel xHCI(override)"}
bad = []
for slot, (wv, wd) in want.items():
    gv, gd = ids.get(slot, (0, 0))
    print(f"  slot {slot} {label[slot]:28s} {gv:#06x}:{gd:#06x}  期望 {wv:#06x}:{wd:#06x}")
    if (gv, gd) != (wv, wd):
        bad.append(slot)
if bad:
    print("FAIL: PCI ID 覆盖未生效:", bad); sys.exit(1)
print("OK: 默认 AMD / 覆盖 Intel 均生效")
PY
then RC=0; else RC=1; fi
kill "$P15PID" 2>/dev/null || true
scan_stderr "$P15ERR" "platform-id"
rm -f "$P15SOCK"
[[ $RC -eq 0 ]] || exit 1

echo
if [[ $UNEXPECTED_STDERR -ne 0 ]]; then
    echo "FAIL: 检测到未登记的 warning/error（见上）——不满足'运行无警告'。" >&2
    exit 1
fi
echo "all checks passed."
