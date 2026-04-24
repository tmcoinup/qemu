#!/usr/bin/env bash
# create-vm.sh — 一次性生成 vm-configs/vmN.conf。
#
#   用法:  ./create-vm.sh <vm_id>          # 1..N
#          ./create-vm.sh <vm_id> --force  # 覆盖已存在配置
#
# 随机挑选一套「平台 (i5-4590 / i5-6500 / i3-8100) + 主板 + 内存 + SSD」，
# 生成 UUID / 各种序列号 / MAC，写入 vm-configs/vmN.conf 后仅作只读。
# start-vm.sh 只读这个文件，确保同一个 VM 每次开机表现一致。

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

VM_ID="${1:-}"
FORCE=0
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=1
done

if [[ -z "$VM_ID" || ! "$VM_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <vm_id> [--force]" >&2
    exit 2
fi

CONF="vm-configs/vm${VM_ID}.conf"
if [[ -f "$CONF" && $FORCE -eq 0 ]]; then
    echo "VM $VM_ID 已存在 ($CONF)，--force 覆盖" >&2
    exit 0
fi

mkdir -p vm-configs

# ─── 平台选择 ────────────────────────────────────────────────────────────────
PLATFORMS=(i5-4590 i5-6500 i3-8100)
PLATFORM=${PLATFORMS[$((RANDOM % ${#PLATFORMS[@]}))]}

# ─── 主板 / 内存池（仅 DDR3/DDR3L/DDR4 合法速率与真实 SPD） ───────────────────
# 每项: vendor|model|bios_ver|bios_date
case $PLATFORM in
  i5-4590)
    BOARDS=(
      "ASUS|H97M-E|2201|04/15/2018"
      "ASUS|H97-PLUS|2601|11/20/2018"
      "ASUS|B85M-G|3003|08/22/2017"
      "MSI|H97 PC Mate|A.70|06/12/2017"
      "MSI|B85-G43 GAMING|V10.7|09/08/2016"
      "Gigabyte|GA-H97M-D3H|F6|03/22/2018"
      "Gigabyte|GA-B85M-DS3H-A|F5|01/14/2017"
      "ASRock|H97M Pro4|2.40|07/14/2017"
      "ASRock|B85M Pro4|2.30|05/20/2016"
    )
    MEMS=(
      "Kingston|KVR16N11S8/8|1600|DDR3|0x18|64"
      "Samsung|M378B1G73DB0-CK0|1600|DDR3|0x18|64"
      "SK Hynix|HMT41GU6BFR8A-PB|1600|DDR3L|0x18|64"
      "Crucial|CT102464BF160B|1600|DDR3L|0x18|64"
      "Corsair|CMV8GX3M1A1600C11|1600|DDR3|0x18|64"
    )
    CPU_MODEL="Core-i5-4590"
    TSC_FREQ=3300000000
    ;;
  i5-6500)
    BOARDS=(
      "ASUS|H110M-K|3805|09/13/2018"
      "ASUS|B150M-A|3401|05/22/2018"
      "MSI|H110M PRO-VD|V3.30|11/07/2017"
      "MSI|B150M BAZOOKA|V3.20|04/25/2018"
      "Gigabyte|GA-H110M-S2H|F22|08/14/2018"
      "Gigabyte|GA-B150M-D3H|F21|05/09/2018"
      "ASRock|H110M-DVS R3.0|4.70|06/18/2018"
      "ASRock|B150M Pro4S|7.40|09/20/2017"
    )
    MEMS=(
      "Kingston|KVR16LS11/8|1600|DDR3L|0x18|64"
      "Samsung|M471B1G73DB0-YK0|1600|DDR3L|0x18|64"
      "SK Hynix|HMT41GS6BFR8A-PB|1600|DDR3L|0x18|64"
      "Crucial|CT102464BF160B|1600|DDR3L|0x18|64"
      "Corsair|CMSO8GX3M1C1600C11|1600|DDR3L|0x18|64"
    )
    CPU_MODEL="Core-i5-6500"
    TSC_FREQ=3200000000
    ;;
  i3-8100)
    BOARDS=(
      "ASUS|PRIME H310M-E|1401|10/11/2019"
      "ASUS|PRIME B360M-A|1801|03/25/2019"
      "MSI|H310M PRO-M2|V1.C0|07/15/2019"
      "MSI|B360M PRO-VD|V1.70|11/22/2018"
      "Gigabyte|H310M S2 2.0|F14|12/20/2019"
      "Gigabyte|B360M DS3H|F13|06/19/2019"
      "ASRock|H310CM-HDV|5.70|09/04/2019"
      "ASRock|B360M Pro4|4.40|03/14/2019"
    )
    MEMS=(
      "Kingston|KVR24N17S8/8|2400|DDR4|0x1A|64"
      "Samsung|M378A1K43CB2-CRC|2400|DDR4|0x1A|64"
      "SK Hynix|HMA81GU6AFR8N-UH|2400|DDR4|0x1A|64"
      "Crucial|CT8G4DFS824A|2400|DDR4|0x1A|64"
      "Corsair|CMK8GX4M1A2400C16|2400|DDR4|0x1A|64"
      "G.Skill|F4-2400C15S-8GVR|2400|DDR4|0x1A|64"
    )
    CPU_MODEL="Core-i3-8100"
    TSC_FREQ=3600000000
    ;;
esac

SSDS=(
  "Samsung|Samsung SSD 860 EVO 512GB"
  "Samsung|Samsung SSD 970 EVO Plus 512GB"
  "Samsung|Samsung SSD 980 PRO 512GB"
  "WDC|WDS512G2B0A-00SM50"
  "WDC|WD Blue SN570 512GB"
  "WDC|WD Black SN850X 512GB"
  "Crucial|CT512MX500SSD1"
  "Crucial|Crucial P3 Plus 512GB"
  "Kingston|KC3000 512GB"
  "Kingston|SKC600/512G"
  "SK Hynix|HFS512GD9TNG-L2B0B"
)

# 真实 Intel 网卡 OUI 前缀 (随机一个)
INTEL_OUIS=(
  "00:1B:21" "00:1E:67" "00:1F:C6" "00:21:6A" "00:22:FA"
  "00:23:14" "00:24:D7" "00:25:64" "8C:8D:28" "A0:36:9F"
  "A4:C3:F0" "1C:69:7A" "18:66:DA"
)

# vGPU profile (两个候选)
GPU_PROFILES=(gtx1050_2gb gt1030_2gb)

gen_id() {
    # tr | head 在 pipefail 下会因 SIGPIPE 失败；先截 urandom 再过滤。
    local n=$1
    LC_ALL=C head -c $((n * 8)) /dev/urandom | LC_ALL=C tr -dc 'A-Z0-9' | head -c "$n"
    echo
}

BOARD=${BOARDS[$((RANDOM % ${#BOARDS[@]}))]}
MEM=${MEMS[$((RANDOM % ${#MEMS[@]}))]}
SSD=${SSDS[$((RANDOM % ${#SSDS[@]}))]}
OUI=${INTEL_OUIS[$((RANDOM % ${#INTEL_OUIS[@]}))]}
GPU_PROFILE=${GPU_PROFILES[$((RANDOM % ${#GPU_PROFILES[@]}))]}

IFS='|' read BOARD_BRAND BOARD_MODEL BIOS_VER BIOS_DATE <<<"$BOARD"
IFS='|' read MEM_BRAND MEM_MODEL MEM_SPEED MEM_FAMILY MEM_TYPE_BYTE MEM_WIDTH <<<"$MEM"
IFS='|' read SSD_BRAND SSD_MODEL <<<"$SSD"

VM_UUID=$(uuidgen)
SYS_SN=$(gen_id 10)
MB_SN=$(gen_id 12)
CHASSIS_SN=$(gen_id 8)
MEM_SN=$(gen_id 12)
SSD_SN=$(gen_id 16)
VM_MAC="${OUI}:$(printf '%02X:%02X:%02X' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"

# GPU ID
case $GPU_PROFILE in
  gtx1050_2gb) GPU_PCI_VID=0x10DE; GPU_PCI_DID=0x1C81; GPU_SUB_VID=0x1028; GPU_SUB_DID=0x086B ;;  # Dell 1050
  gt1030_2gb)  GPU_PCI_VID=0x10DE; GPU_PCI_DID=0x1D01; GPU_SUB_VID=0x1043; GPU_SUB_DID=0x85F9 ;;  # ASUS 1030
esac

cat > "$CONF" <<EOF
# === 自动生成于 $(date -Iseconds) ===
# vm-configs/vm${VM_ID}.conf — 只读，任何时候修改都可能让 guest 内 license/driver
# / Windows 激活等失效。更换硬件指纹请用新 VM_ID + --force。

VM_ID=${VM_ID}
VM_UUID=${VM_UUID}
PLATFORM=${PLATFORM}
CPU_MODEL=${CPU_MODEL}
TSC_FREQ=${TSC_FREQ}

BOARD_BRAND="${BOARD_BRAND}"
BOARD_MODEL="${BOARD_MODEL}"
BIOS_VER="${BIOS_VER}"
BIOS_DATE="${BIOS_DATE}"

SYS_SN="${SYS_SN}"
MB_SN="${MB_SN}"
CHASSIS_SN="${CHASSIS_SN}"

MEM_BRAND="${MEM_BRAND}"
MEM_MODEL="${MEM_MODEL}"
MEM_SPEED=${MEM_SPEED}
MEM_FAMILY=${MEM_FAMILY}
MEM_TYPE_BYTE=${MEM_TYPE_BYTE}
MEM_WIDTH=${MEM_WIDTH}
MEM_SN="${MEM_SN}"

SSD_BRAND="${SSD_BRAND}"
SSD_MODEL="${SSD_MODEL}"
SSD_SN="${SSD_SN}"

GPU_PROFILE=${GPU_PROFILE}
GPU_PCI_VID=${GPU_PCI_VID}
GPU_PCI_DID=${GPU_PCI_DID}
GPU_SUB_VID=${GPU_SUB_VID}
GPU_SUB_DID=${GPU_SUB_DID}
# 运行时由 start-vm.sh 动态分配 MDEV_UUID（mdev 回池）

VM_MAC=${VM_MAC}
EOF
chmod 444 "$CONF"

printf '创建成功: %s\n' "$CONF"
printf '  平台:   %s (CPU %s, TSC %d Hz)\n' "$PLATFORM" "$CPU_MODEL" "$TSC_FREQ"
printf '  主板:   %s %s BIOS %s %s\n' "$BOARD_BRAND" "$BOARD_MODEL" "$BIOS_VER" "$BIOS_DATE"
printf '  内存:   %s %s %s@%dMT/s (%d-bit)\n' "$MEM_BRAND" "$MEM_MODEL" "$MEM_FAMILY" "$MEM_SPEED" "$MEM_WIDTH"
printf '  硬盘:   %s %s\n' "$SSD_BRAND" "$SSD_MODEL"
printf '  显卡:   %s (PCI %s:%s sub %s:%s)\n' "$GPU_PROFILE" "$GPU_PCI_VID" "$GPU_PCI_DID" "$GPU_SUB_VID" "$GPU_SUB_DID"
printf '  MAC:    %s\n' "$VM_MAC"
printf '  UUID:   %s\n' "$VM_UUID"
