#!/bin/bash
# Stealth helper library: shared SMBIOS/disk/MAC randomization for Ryzen 3 1200
# bare-metal simulation VMs. Sourced by launch scripts.
#
# Usage: source this file, then call:
#   stealth_pick_profile        -> sets $BOARD_*, $CPU_*, $NIC_*, $NVME_*, $UUID
#   stealth_print_profile       -> prints chosen profile to stderr
#   stealth_smbios_args         -> echoes -smbios ... lines

# ------------------------------------------------------------------
# PRNG helpers. Seed optionally via $STEALTH_SEED (otherwise urandom).
# ------------------------------------------------------------------
_rng_init() {
    # Optional deterministic reseed (STEALTH_SEED=integer). The launcher
    # sources this library under `set -u`, so we must guard the reference
    # with default substitution.
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        RANDOM="$STEALTH_SEED"
    fi
}
_rand() {
    # _rand min max  -> inclusive integer in [min,max]
    local lo=$1 hi=$2
    echo $(( (RANDOM * 32768 + RANDOM) % (hi - lo + 1) + lo ))
}
_pick() {
    # _pick list...  -> prints one random element
    local n=$#
    local i=$(( (RANDOM * 32768 + RANDOM) % n + 1 ))
    echo "${!i}"
}
_hex() {
    # _hex width  -> lowercase hex of given width
    local w=$1 out=""
    while (( ${#out} < w )); do
        out+=$(printf "%04x" $((RANDOM ^ (RANDOM<<8) ^ (RANDOM<<16) )) )
    done
    echo "${out:0:$w}"
}
_serial_asus() { echo "MB-$(_hex 6 | tr a-f A-F)$(_rand 10000 99999)"; }
_serial_msi()  { echo "$(_hex 4 | tr a-f A-F)$(_rand 100000 999999)"; }
_serial_giga() { echo "SN$(_rand 10000000 99999999)"; }
_serial_asr()  { echo "M80-$(_hex 4 | tr a-f A-F)$(_rand 1000 9999)"; }

# ------------------------------------------------------------------
# Profile pools
# ------------------------------------------------------------------
# Each entry: "Manufacturer|Product|Family|Version|SerialFn"
BOARD_POOL=(
    "ASUSTeK COMPUTER INC.|PRIME B350-PLUS|PRIME|Rev X.0x|_serial_asus"
    "ASUSTeK COMPUTER INC.|ROG STRIX B350-F GAMING|ROG STRIX|Rev X.0x|_serial_asus"
    "ASUSTeK COMPUTER INC.|PRIME X370-PRO|PRIME|Rev X.0x|_serial_asus"
    "Micro-Star International Co., Ltd.|B350 TOMAHAWK (MS-7A34)|MSI|3.0|_serial_msi"
    "Micro-Star International Co., Ltd.|X370 GAMING PRO CARBON (MS-7A32)|MSI|2.0|_serial_msi"
    "Gigabyte Technology Co., Ltd.|GA-AB350-Gaming 3|X.x|Default string|_serial_giga"
    "Gigabyte Technology Co., Ltd.|B450 AORUS M|B450 AORUS M|x.x|_serial_giga"
    "ASRock|AB350 Pro4|AB350 Pro4|Default string|_serial_asr"
    "ASRock|X370 Taichi|X370 Taichi|Default string|_serial_asr"
)

# BIOS vendor pool (only AMI is realistic for consumer Ryzen boards)
BIOS_VENDOR="American Megatrends Inc."
BIOS_VERSION_POOL=("6203" "6204" "6301" "6042" "5601" "5406" "4012" "3805" "2401")
BIOS_DATE_POOL=("11/23/2020" "03/17/2021" "08/04/2021" "12/09/2021" "06/22/2022" "01/14/2023")

# Chassis SKUs
CHASSIS_POOL=("Desktop" "Tower" "Mini Tower")

# System model (chassis vendor = board vendor most of the time)
SYSTEM_PRODUCT_POOL=(
    "System Product Name"
    "To Be Filled By O.E.M."
    "Default string"
    "All Series"
)
SYSTEM_FAMILY_POOL=(
    "To be filled by O.E.M."
    "Default string"
    "Desktop"
)

# Samsung 970 PRO 512GB-style serial: 10 hex digits usually
_nvme_serial() { echo "S$(printf '%010X' $((RANDOM * RANDOM)))N"; }

# NIC OUI pool. We run e1000e (Intel 82574L) inside the guest, so Intel OUIs
# are the "perfect" match; Realtek/ASUS OUIs are also common on consumer AM4
# boards that pair an Intel NIC on a Realtek-branded board. NEVER 52:54:00 —
# that block is assigned by IEEE to QEMU/KVM.
#   intel    : 00:1b:21, 00:1e:67, 00:a0:c9, 3c:fd:fe, 54:bf:64, a0:36:9f
#   realtek  : 1c:1b:0d, 00:e0:4c, 4c:cc:6a
#   asustek  : 24:4b:fe, a8:a1:59
_gen_mac() {
    local ouis=(
        "00:1b:21" "00:1e:67" "00:a0:c9" "3c:fd:fe" "54:bf:64" "a0:36:9f"
        "1c:1b:0d" "00:e0:4c" "4c:cc:6a"
        "24:4b:fe" "a8:a1:59"
    )
    local n=${#ouis[@]}
    local i=$(( (RANDOM * 32768 + RANDOM) % n ))
    printf "%s:%02x:%02x:%02x\n" \
        "${ouis[$i]}" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

_gen_uuid() {
    printf '%08x-%04x-%04x-%04x-%04x%08x\n' \
        $((RANDOM * RANDOM)) \
        $((RANDOM & 0xffff)) \
        $(((RANDOM & 0x0fff) | 0x4000)) \
        $(((RANDOM & 0x3fff) | 0x8000)) \
        $((RANDOM & 0xffff)) \
        $((RANDOM * RANDOM))
}

# ------------------------------------------------------------------
# Public: pick and export a profile
# ------------------------------------------------------------------
stealth_pick_profile() {
    _rng_init
    local n=${#BOARD_POOL[@]}
    local i=$(( (RANDOM * 32768 + RANDOM) % n ))
    IFS='|' read -r BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION SERIAL_FN <<<"${BOARD_POOL[$i]}"
    BOARD_SERIAL="$($SERIAL_FN)"
    BOARD_ASSET="$(_rand 1000000000 9999999999)"

    SYSTEM_MFR="$BOARD_MFR"
    local m=${#SYSTEM_PRODUCT_POOL[@]}
    SYSTEM_PRODUCT="${SYSTEM_PRODUCT_POOL[$((RANDOM % m))]}"
    local f=${#SYSTEM_FAMILY_POOL[@]}
    SYSTEM_FAMILY="${SYSTEM_FAMILY_POOL[$((RANDOM % f))]}"
    SYSTEM_VERSION="$BOARD_VERSION"
    SYSTEM_SERIAL="$($SERIAL_FN)"
    SYSTEM_SKU="SKU$(_rand 100000 999999)"

    local v=${#BIOS_VERSION_POOL[@]}
    BIOS_VERSION="${BIOS_VERSION_POOL[$((RANDOM % v))]}"
    local d=${#BIOS_DATE_POOL[@]}
    BIOS_DATE="${BIOS_DATE_POOL[$((RANDOM % d))]}"

    local c=${#CHASSIS_POOL[@]}
    CHASSIS_TYPE="${CHASSIS_POOL[$((RANDOM % c))]}"
    CHASSIS_SERIAL="$($SERIAL_FN)"

    NIC_MAC="$(_gen_mac)"
    NVME_SERIAL="$(_nvme_serial)"
    UUID="$(_gen_uuid)"

    CPU_SERIAL="$(_rand 1000000000 9999999999)"

    # CPU 型号写入 profile，避免每次启动都靠环境变量;
    # 默认 Ryzen3-1200 (Zen1, Win10/11 LTSC 友好);
    # 想换 Pinnacle Ridge / Zen+ 可在生成前先 export CPU_MODEL=Ryzen3-2300X 再 reroll。
    : "${CPU_MODEL:=Ryzen3-1200}"

    export BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET
    export SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    export BIOS_VENDOR BIOS_VERSION BIOS_DATE
    export CHASSIS_TYPE CHASSIS_SERIAL
    export NIC_MAC NVME_SERIAL UUID CPU_SERIAL CPU_MODEL
}

# ------------------------------------------------------------------
# Persist / restore a previously chosen profile.
#
# Identity should be randomized once at VM creation and then remain stable
# across reboots — otherwise Windows sees a "new PC" every launch and either
# re-activates or tripwires the anti-cheat by itself.
#
# stealth_save_profile <path>  — writes every exported identity var
# stealth_load_profile <path>  — sources it back and re-exports
# stealth_have_profile <path>  — 0 if the file exists and is non-empty
# ------------------------------------------------------------------
_STEALTH_PROFILE_VARS=(
    BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET
    SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    BIOS_VENDOR BIOS_VERSION BIOS_DATE
    CHASSIS_TYPE CHASSIS_SERIAL
    NIC_MAC NVME_SERIAL UUID CPU_SERIAL
    CPU_MODEL
)

stealth_have_profile() { [[ -s "$1" ]]; }

stealth_save_profile() {
    local path="$1"
    local tmp="${path}.tmp.$$"
    mkdir -p "$(dirname "$path")"
    {
        echo "# stealth hardware profile — generated $(date -Iseconds)"
        echo "# remove this file (or run reroll-identity.sh) to re-randomize."
        local v
        for v in "${_STEALTH_PROFILE_VARS[@]}"; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$tmp"
    mv -f "$tmp" "$path"
}

stealth_load_profile() {
    local path="$1"
    # shellcheck disable=SC1090
    source "$path"
    # 老 profile 没有 CPU_MODEL 字段：补上默认值，下次 stealth_save_profile 写盘时会持久化
    : "${CPU_MODEL:=Ryzen3-1200}"
    local v
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        export "$v"
    done
}

stealth_print_profile() {
    cat >&2 <<EOF
=== stealth profile ===
  Board    : $BOARD_MFR / $BOARD_PRODUCT ($BOARD_VERSION)
  Board SN : $BOARD_SERIAL
  System   : $SYSTEM_MFR / $SYSTEM_PRODUCT / $SYSTEM_FAMILY
  System SN: $SYSTEM_SERIAL   SKU=$SYSTEM_SKU
  BIOS     : $BIOS_VENDOR $BIOS_VERSION ($BIOS_DATE)
  Chassis  : $CHASSIS_TYPE  SN=$CHASSIS_SERIAL
  NVMe SN  : $NVME_SERIAL
  NIC MAC  : $NIC_MAC
  UUID     : $UUID
  CPU      : $CPU_MODEL
=======================
EOF
}

# Escape commas in SMBIOS string values (QEMU uses ',,' to encode a literal ','
# inside option values).
_e() { echo "${1//,/,,}"; }

# ------------------------------------------------------------------
# SMBIOS argument builder. Emits ONE whole -smbios option per line, with
# commas inside field values pre-escaped.
#
# Types emitted:
#   0   BIOS info
#   1   System info
#   2   Baseboard
#   3   Chassis
#   4   Processor (socket AM4)
#   11  OEM strings — real ASUS/MSI boards always carry these, missing them
#       is itself a flag
#   17  Memory device. With 2 memfd backends QEMU auto-generates two type 17
#       entries; loc_pfx becomes "DIMM_A 0" / "DIMM_A 1". Not a perfect
#       dual-channel bank label (QEMU's CLI can't set per-DIMM bank strings)
#       but WMI sees 2 DIMMs × 4GB × 3200MT/s, which is what dual-channel
#       looks like from Win32_PhysicalMemory.
# ------------------------------------------------------------------
stealth_smbios_args() {
    local t0 t1 t2 t3 t4 t11 t16 t17
    local mem_per_dimm_mb="${MEM_PER_DIMM_MB:-4096}"

    # Ryzen 3 1200 (Summit Ridge) official memory spec: DDR4-2667 JEDEC.
    # We report 2666 (the JEDEC-standard name for 2667 MT/s) so CPU spec
    # and memory match; 3200 would look like overclock and could trip
    # conservative inventory checks.
    local mem_speed="${MEM_SPEED:-2666}"
    local mem_part_4g="HX426C16FB3A/4"  # Kingston HyperX Fury 4GB DDR4-2666
    local mem_part_8g="HX426C16FB3A/8"  # Kingston HyperX Fury 8GB DDR4-2666

    local mem_part="$mem_part_4g"
    (( mem_per_dimm_mb >= 8192 )) && mem_part="$mem_part_8g"

    t0="type=0,vendor=$(_e "$BIOS_VENDOR"),version=$(_e "$BIOS_VERSION"),date=$(_e "$BIOS_DATE"),release=5.14,uefi=on"
    t1="type=1,manufacturer=$(_e "$SYSTEM_MFR"),product=$(_e "$SYSTEM_PRODUCT"),version=$(_e "$SYSTEM_VERSION"),serial=$(_e "$SYSTEM_SERIAL"),uuid=$UUID,sku=$(_e "$SYSTEM_SKU"),family=$(_e "$SYSTEM_FAMILY")"
    t2="type=2,manufacturer=$(_e "$BOARD_MFR"),product=$(_e "$BOARD_PRODUCT"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$BOARD_SERIAL"),asset=$BOARD_ASSET,location=Default string"
    t3="type=3,manufacturer=$(_e "$BOARD_MFR"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$CHASSIS_SERIAL"),asset=$BOARD_ASSET,sku=$(_e "$SYSTEM_SKU")"
    # processor-family=0x139 → SMBIOS 3.6 "Zen" (matches real Ryzen boards).
    # CPU model selection follows the QEMU -cpu argument the launcher built:
    #   Ryzen3-1200  → Summit Ridge / Zen 1   (Win11 ineligible; default)
    #   Ryzen3-2300X → Pinnacle Ridge / Zen+  (Win11 list-eligible)
    # part code is the retail OEM OPN; HWiNFO parses this for 产品单元.
    case "${CPU_MODEL:-Ryzen3-1200}" in
        Ryzen3-2300X)
            local _cpu_ver="AMD Ryzen 3 2300X Quad-Core Processor"
            local _cpu_part="YD230XBBM4KAF"
            local _cpu_max=4000  ; local _cpu_now=3500 ;;
        *)
            local _cpu_ver="AMD Ryzen 3 1200 Quad-Core Processor"
            local _cpu_part="YD1200BBM4KAE"
            local _cpu_max=3400  ; local _cpu_now=3100 ;;
    esac
    t4="type=4,sock_pfx=AM4,manufacturer=Advanced Micro Devices Inc.,version=$_cpu_ver,serial=$CPU_SERIAL,asset=$(_rand 1000 9999),part=$_cpu_part,max-speed=$_cpu_max,current-speed=$_cpu_now,processor-family=0x139"
    # OEM strings — presence matters more than exact content; most
    # detectors just check that type 11 exists. We still vendor-match
    # so an ASRock board doesn't carry ASUS_MB_* strings.
    case "$BOARD_MFR" in
        ASUS*|*ASUSTeK*)
            t11="type=11,value=Default string,value=ASUS_MB_RSVD,value=ASUS_MB_CPU=AMD_Ryzen,value=ASUS_MB_LINK_URL=http://www.asus.com" ;;
        *Micro-Star*|*MSI*)
            t11="type=11,value=Default string,value=MSI_A_1,value=MSI_OEM_A,value=MSI_OEM_B" ;;
        *Gigabyte*)
            t11="type=11,value=Default string,value=Gigabyte Technology Co.,,Ltd.,value=GBT_OEM_A" ;;
        ASRock*)
            t11="type=11,value=Default string,value=ASRock_Default,value=ASRockName" ;;
        *)
            t11="type=11,value=Default string,value=OEM_Default" ;;
    esac
    # bank="P0 CHANNEL %C" + our smbios.c patch → DIMM 0 gets
    # "P0 CHANNEL A", DIMM 1 gets "P0 CHANNEL B". Without the patch QEMU
    # passes "%C" through literally (still uniform across DIMMs, but not
    # a detection red flag — most tools don't parse bank syntax).
    t17="type=17,loc_pfx=DIMM_A,bank=P0 CHANNEL %C,manufacturer=Kingston,serial=$(_rand 10000000 99999999),asset=9876543210,part=$(_e "$mem_part"),speed=$mem_speed"
    # Physical memory array (type 16): advertise 64 GB max capacity and
    # 4 DIMM slots — the real spec for B350-PLUS / typical AM4 ATX board.
    # QEMU's default would set MaxCapacity == installed (8 GB) and slot
    # count == dimm_cnt (2), which is a VM tell: retail boards always
    # have empty slots. Extra slots past dimm_cnt are emitted as Size=0
    # ("No Module Installed") type 17 entries.
    t16="type=16,max-capacity=${T16_MAX_CAPACITY:-64G},num-devices=${T16_NUM_DEVICES:-4}"
    printf '%s\n' "$t0" "$t1" "$t2" "$t3" "$t4" "$t11" "$t16" "$t17"
}
