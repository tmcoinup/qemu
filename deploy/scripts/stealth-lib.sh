#!/bin/bash
# stealth-lib.sh —— 共享的 SMBIOS / 磁盘 / MAC / GPU 随机化库，被 start-vm.sh
# 等启动脚本 source。
#
# 使用：source 之后调用：
#   stealth_pick_profile        生成一份新身份并 export 全部字段
#   stealth_load_profile <path> 从文件载入并 export
#   stealth_save_profile <path> 持久化到文件
#   stealth_print_profile       打印身份
#   stealth_smbios_args         输出 -smbios 行（每行一条，commas 已转义）
#   stealth_qemu_cpu_arg        输出 -cpu 后的完整字符串

# ------------------------------------------------------------------
# PRNG helpers. STEALTH_SEED=integer 可启用确定性重放。
# ------------------------------------------------------------------
_rng_init() {
    if [[ -n "${STEALTH_SEED:-}" ]]; then
        RANDOM="$STEALTH_SEED"
    fi
}
_rand() {
    local lo=$1 hi=$2
    echo $(( (RANDOM * 32768 + RANDOM) % (hi - lo + 1) + lo ))
}
_pick_array() {
    # _pick_array <array_name>  从 array 里随机取一个元素，stdout 输出
    local -n _arr=$1
    local n=${#_arr[@]}
    local i=$(( (RANDOM * 32768 + RANDOM) % n ))
    echo "${_arr[$i]}"
}
_hex() {
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
# CPU 池
#
# 每条格式：
#   QEMU_CPU_ARG|VENDOR|DISPLAY_NAME|MAX_MHZ|CUR_MHZ|PART|PROC_FAMILY|SOCKET
#
# - QEMU_CPU_ARG: 给 -cpu 用的"型号 + family/model/stepping/model-id 覆盖"，
#   常用旁路 (kvm=off,hypervisor=off,+invtsc 等) 不在此处；由 stealth_qemu_cpu_arg 拼接。
# - VENDOR: AuthenticAMD / GenuineIntel
# - SOCKET: AM4 / LGA1151 / LGA1200，board 池据此对齐
# - PROC_FAMILY: SMBIOS Type 4 processor-family，0x139=Zen，0xCD=Intel Core i3 9th+
# - 全部为低端 4C/4T (无 HT) 配置
# ------------------------------------------------------------------
CPU_POOL=(
    # AMD AM4 — Zen 1 / Zen+
    "Ryzen3-1200|AuthenticAMD|AMD Ryzen 3 1200 Quad-Core Processor|3400|3100|YD1200BBM4KAE|0x139|AM4"
    "Ryzen3-2300X|AuthenticAMD|AMD Ryzen 3 2300X Quad-Core Processor|4000|3500|YD230XBBM4KAF|0x139|AM4"
    # Intel LGA1151 v2 — Coffee Lake / Coffee Lake R, 4C/4T no-HT
    "Skylake-Client-IBRS,family=6,model=158,stepping=10,model-id=Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz|GenuineIntel|Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz|4200|3600|GX80684I39100F|0xCD|LGA1151"
    "Skylake-Client-IBRS,family=6,model=158,stepping=10,model-id=Intel(R) Core(TM) i3-9100 CPU @ 3.60GHz|GenuineIntel|Intel(R) Core(TM) i3-9100 CPU @ 3.60GHz|4200|3600|BX80684I39100|0xCD|LGA1151"
    # Intel LGA1200 — Comet Lake，2C/4T 与 4C/4T 入门
    "Skylake-Client-IBRS,family=6,model=165,stepping=2,model-id=Intel(R) Pentium(R) Gold G6400 CPU @ 4.00GHz|GenuineIntel|Intel(R) Pentium(R) Gold G6400 CPU @ 4.00GHz|4000|4000|BX80701G6400|0xCD|LGA1200"
    "Skylake-Client-IBRS,family=6,model=158,stepping=12,model-id=Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz|GenuineIntel|Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz|3700|3700|BX80684G5400|0xCD|LGA1151"
)

# ------------------------------------------------------------------
# 主板池 —— 按 SOCKET 字段过滤匹配 CPU 平台。低端 H/B 系芯片组为主。
# 格式：SOCKET|MFR|PRODUCT|FAMILY|VERSION|SERIAL_FN
# ------------------------------------------------------------------
BOARD_POOL=(
    # AM4 (B350/X370/B450 主流入门)
    "AM4|ASUSTeK COMPUTER INC.|PRIME B350-PLUS|PRIME|Rev X.0x|_serial_asus"
    "AM4|ASUSTeK COMPUTER INC.|ROG STRIX B350-F GAMING|ROG STRIX|Rev X.0x|_serial_asus"
    "AM4|ASUSTeK COMPUTER INC.|PRIME X370-PRO|PRIME|Rev X.0x|_serial_asus"
    "AM4|ASUSTeK COMPUTER INC.|PRIME B450M-A|PRIME|Rev X.0x|_serial_asus"
    "AM4|Micro-Star International Co., Ltd.|B350 TOMAHAWK (MS-7A34)|MSI|3.0|_serial_msi"
    "AM4|Micro-Star International Co., Ltd.|X370 GAMING PRO CARBON (MS-7A32)|MSI|2.0|_serial_msi"
    "AM4|Gigabyte Technology Co., Ltd.|GA-AB350-Gaming 3|X.x|Default string|_serial_giga"
    "AM4|Gigabyte Technology Co., Ltd.|B450 AORUS M|B450 AORUS M|x.x|_serial_giga"
    "AM4|ASRock|AB350 Pro4|AB350 Pro4|Default string|_serial_asr"
    "AM4|ASRock|X370 Taichi|X370 Taichi|Default string|_serial_asr"
    # LGA1151 v2 (H310/B360/H370 入门)
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME H310M-K|PRIME|Rev 1.xx|_serial_asus"
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME B360M-A|PRIME|Rev 1.xx|_serial_asus"
    "LGA1151|ASUSTeK COMPUTER INC.|PRIME H370-A|PRIME|Rev 1.xx|_serial_asus"
    "LGA1151|Micro-Star International Co., Ltd.|H310M PRO-VL (MS-7B24)|MSI|1.0|_serial_msi"
    "LGA1151|Micro-Star International Co., Ltd.|B360M PRO-VH (MS-7B49)|MSI|1.0|_serial_msi"
    "LGA1151|Gigabyte Technology Co., Ltd.|H310M S2H|H310M|x.x|_serial_giga"
    "LGA1151|Gigabyte Technology Co., Ltd.|B360M D2V|B360M|x.x|_serial_giga"
    "LGA1151|ASRock|B360M Pro4|B360M Pro4|Default string|_serial_asr"
    "LGA1151|ASRock|H310CM-HDV|H310CM-HDV|Default string|_serial_asr"
    # LGA1200 (H410/B460/H470 入门)
    "LGA1200|ASUSTeK COMPUTER INC.|PRIME H410M-A|PRIME|Rev 1.xx|_serial_asus"
    "LGA1200|ASUSTeK COMPUTER INC.|PRIME B460M-A|PRIME|Rev 1.xx|_serial_asus"
    "LGA1200|Micro-Star International Co., Ltd.|H410M PRO (MS-7C95)|MSI|1.0|_serial_msi"
    "LGA1200|Micro-Star International Co., Ltd.|B460M PRO-VDH (MS-7C82)|MSI|1.0|_serial_msi"
    "LGA1200|Gigabyte Technology Co., Ltd.|H410M S2H|H410M|x.x|_serial_giga"
    "LGA1200|Gigabyte Technology Co., Ltd.|B460M DS3H|B460M|x.x|_serial_giga"
    "LGA1200|ASRock|H410M-HDV|H410M-HDV|Default string|_serial_asr"
    "LGA1200|ASRock|B460M Pro4|B460M Pro4|Default string|_serial_asr"
)

# ------------------------------------------------------------------
# GPU 池 —— 低端入门为主，NVIDIA + AMD 都覆盖。
# 格式：VENDOR|NAME|PCI_VEN|PCI_DEV|RAM_MB|BIOS_STRING|REV
# ------------------------------------------------------------------
GPU_POOL=(
    # NVIDIA (Pascal/Maxwell 低端)
    "NVIDIA|NVIDIA GeForce GTX 750 Ti|0x10DE|0x1380|2048|Version 82.07.41.00.32|0xA2"
    "NVIDIA|NVIDIA GeForce GT 1030|0x10DE|0x1D01|2048|Version 86.08.46.00.81|0xA1"
    "NVIDIA|NVIDIA GeForce GTX 1050|0x10DE|0x1C81|2048|Version 86.07.48.00.38|0xA1"
    "NVIDIA|NVIDIA GeForce GTX 1050 Ti|0x10DE|0x1C82|4096|Version 86.07.48.00.A0|0xA1"
    # AMD Polaris 低端
    "AMD|AMD Radeon RX 550|0x1002|0x699F|2048|016.011.000.029.000000|0xCF"
    "AMD|AMD Radeon RX 560|0x1002|0x67FF|4096|016.011.000.029.000000|0xCF"
)

# ------------------------------------------------------------------
# NVMe 池 —— 全部 Samsung 系列，搭配 use-samsung-id=on 保证 IEEE OUI 一致。
# 格式：MODEL|FIRMWARE
# ------------------------------------------------------------------
NVME_POOL=(
    "Samsung SSD 970 PRO 512GB|1B2QEXM7"
    "Samsung SSD 970 EVO Plus 500GB|2B2QEXM7"
    "Samsung SSD 980 PRO 500GB|5B2QGXA7"
    "Samsung SSD 980 1TB|3B4QFXO7"
    "Samsung SSD 990 PRO 1TB|3B2QJXD7"
)

# ------------------------------------------------------------------
# 内存 part / 厂商池 —— 低端 4G 总量典型搭配。
# Format: MFR|PART_2G|PART_4G
# ------------------------------------------------------------------
MEM_POOL=(
    "Kingston|KVR26N19S6/2|HX426C16FB3A/4"
    "Crucial|CT2G4DFS6266|CT4G4DFS8266"
    "Samsung|M378A5644EB0-CRC|M378A5244CB0-CRC"
    "SK hynix|HMA425S6BJR8N-V8|HMA851S6CJR6N-VK"
)

# BIOS / Chassis 池
BIOS_VENDOR="American Megatrends Inc."
BIOS_VERSION_POOL=("6203" "6204" "6301" "6042" "5601" "5406" "4012" "3805" "2401")
BIOS_DATE_POOL=("11/23/2020" "03/17/2021" "08/04/2021" "12/09/2021" "06/22/2022" "01/14/2023")
CHASSIS_POOL=("Desktop" "Tower" "Mini Tower")
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

# Samsung NVMe serial: S<10 hex>N
_nvme_serial() { echo "S$(printf '%010X' $((RANDOM * RANDOM)))N"; }

# NIC OUI 池：Intel/Realtek/ASUS。永不用 52:54:00（QEMU/KVM 注册块）。
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
# 公开：随机生成一份完整 profile 并 export
# ------------------------------------------------------------------
stealth_pick_profile() {
    _rng_init

    # 1. 先选 CPU
    local cpu_n=${#CPU_POOL[@]}
    local cpu_i=$(( (RANDOM * 32768 + RANDOM) % cpu_n ))
    IFS='|' read -r CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET <<<"${CPU_POOL[$cpu_i]}"
    # 兼容老 profile 的 CPU_MODEL 字段：保留它指向 QEMU 模型主名（不带 family/model 覆盖）
    CPU_MODEL="${CPU_QEMU_ARG%%,*}"

    # 2. 主板：从 BOARD_POOL 里挑 socket 匹配的
    local matched=()
    local entry
    for entry in "${BOARD_POOL[@]}"; do
        local sock="${entry%%|*}"
        if [[ "$sock" == "$CPU_SOCKET" ]]; then
            matched+=("$entry")
        fi
    done
    if (( ${#matched[@]} == 0 )); then
        echo "ERROR: 没有 socket=$CPU_SOCKET 的主板可选" >&2
        return 1
    fi
    local b_i=$(( (RANDOM * 32768 + RANDOM) % ${#matched[@]} ))
    IFS='|' read -r _ BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION SERIAL_FN <<<"${matched[$b_i]}"
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
    UUID="$(_gen_uuid)"
    CPU_SERIAL="$(_rand 1000000000 9999999999)"

    # 3. GPU
    local gpu_n=${#GPU_POOL[@]}
    local gpu_i=$(( (RANDOM * 32768 + RANDOM) % gpu_n ))
    IFS='|' read -r GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV <<<"${GPU_POOL[$gpu_i]}"

    # 4. NVMe
    local nv_n=${#NVME_POOL[@]}
    local nv_i=$(( (RANDOM * 32768 + RANDOM) % nv_n ))
    IFS='|' read -r NVME_MODEL NVME_FIRMWARE <<<"${NVME_POOL[$nv_i]}"
    NVME_SERIAL="$(_nvme_serial)"

    # 5. 内存厂家 / part
    local mp_n=${#MEM_POOL[@]}
    local mp_i=$(( (RANDOM * 32768 + RANDOM) % mp_n ))
    IFS='|' read -r MEM_MFR MEM_PART_2G MEM_PART_4G <<<"${MEM_POOL[$mp_i]}"

    export CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL
    export BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET
    export SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    export BIOS_VENDOR BIOS_VERSION BIOS_DATE
    export CHASSIS_TYPE CHASSIS_SERIAL
    export NIC_MAC UUID
    export GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    export NVME_MODEL NVME_FIRMWARE NVME_SERIAL
    export MEM_MFR MEM_PART_2G MEM_PART_4G
}

# ------------------------------------------------------------------
# 持久化 / 载入
# ------------------------------------------------------------------
_STEALTH_PROFILE_VARS=(
    CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL
    BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET
    SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    BIOS_VENDOR BIOS_VERSION BIOS_DATE
    CHASSIS_TYPE CHASSIS_SERIAL
    NIC_MAC UUID
    GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    NVME_MODEL NVME_FIRMWARE NVME_SERIAL
    MEM_MFR MEM_PART_2G MEM_PART_4G
)

stealth_have_profile() { [[ -s "$1" ]]; }

stealth_save_profile() {
    local path="$1"
    local tmp="${path}.tmp.$$"
    mkdir -p "$(dirname "$path")"
    {
        echo "# stealth hardware profile — generated $(date -Iseconds)"
        echo "# 删除此文件 (或运行 reroll-identity.sh) 重新随机化"
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

    # 老 profile 兼容：缺字段补默认（AMD Ryzen3-1200 + GTX 1050 + Samsung 970 PRO）
    : "${CPU_QEMU_ARG:=Ryzen3-1200}"
    : "${CPU_VENDOR:=AuthenticAMD}"
    : "${CPU_NAME:=AMD Ryzen 3 1200 Quad-Core Processor}"
    : "${CPU_MAX_MHZ:=3400}"
    : "${CPU_CUR_MHZ:=3100}"
    : "${CPU_PART:=YD1200BBM4KAE}"
    : "${CPU_PROC_FAMILY:=0x139}"
    : "${CPU_SOCKET:=AM4}"
    : "${CPU_MODEL:=Ryzen3-1200}"

    : "${GPU_VENDOR:=NVIDIA}"
    : "${GPU_NAME:=NVIDIA GeForce GTX 1050}"
    : "${GPU_PCI_VEN:=0x10DE}"
    : "${GPU_PCI_DEV:=0x1C81}"
    : "${GPU_RAM_MB:=2048}"
    : "${GPU_BIOS:=Version 86.07.48.00.38}"
    : "${GPU_REV:=0xA1}"

    : "${NVME_MODEL:=Samsung SSD 970 PRO 512GB}"
    : "${NVME_FIRMWARE:=1B2QEXM7}"

    : "${MEM_MFR:=Kingston}"
    : "${MEM_PART_2G:=KVR26N19S6/2}"
    : "${MEM_PART_4G:=HX426C16FB3A/4}"

    local v
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        export "$v"
    done
}

stealth_print_profile() {
    cat >&2 <<EOF
=== stealth profile ===
  CPU      : $CPU_NAME ($CPU_VENDOR, socket $CPU_SOCKET, QEMU=$CPU_QEMU_ARG)
  Board    : $BOARD_MFR / $BOARD_PRODUCT ($BOARD_VERSION)
  Board SN : $BOARD_SERIAL
  System   : $SYSTEM_MFR / $SYSTEM_PRODUCT / $SYSTEM_FAMILY
  System SN: $SYSTEM_SERIAL   SKU=$SYSTEM_SKU
  BIOS     : $BIOS_VENDOR $BIOS_VERSION ($BIOS_DATE)
  Chassis  : $CHASSIS_TYPE  SN=$CHASSIS_SERIAL
  GPU      : $GPU_NAME ($GPU_VENDOR, ${GPU_PCI_VEN}:${GPU_PCI_DEV}, ${GPU_RAM_MB}MB, BIOS $GPU_BIOS)
  NVMe     : $NVME_MODEL  fw=$NVME_FIRMWARE  SN=$NVME_SERIAL
  Memory   : $MEM_MFR
  NIC MAC  : $NIC_MAC
  UUID     : $UUID
=======================
EOF
}

# 给 -cpu 拼出完整字符串（含 stealth 共用旁路 + tsc-freq + vendor）
stealth_qemu_cpu_arg() {
    local tsc_hz=$(( CPU_CUR_MHZ * 1000000 ))
    local extras="kvm=off,hypervisor=off,+invtsc,+tsc-deadline,enforce=off,host-phys-bits=on,tsc-freq=${tsc_hz},vendor=${CPU_VENDOR}"
    # +topoext 是 AMD 专属（CPUID leaf 0x8000001E），Intel 不能加
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        extras="${extras},+topoext"
    fi
    echo "${CPU_QEMU_ARG},${extras}"
}

# Escape commas in SMBIOS string values (QEMU uses ',,' to encode a literal ','
# inside option values).
_e() { echo "${1//,/,,}"; }

# ------------------------------------------------------------------
# SMBIOS 参数构造器，每行一个完整 -smbios option (commas 已转义)
# ------------------------------------------------------------------
stealth_smbios_args() {
    local t0 t1 t2 t3 t4 t11 t16 t17
    local mem_per_dimm_mb="${MEM_PER_DIMM_MB:-2048}"
    local mem_speed="${MEM_SPEED:-2666}"
    local mem_part="$MEM_PART_2G"
    (( mem_per_dimm_mb >= 4096 )) && mem_part="$MEM_PART_4G"

    t0="type=0,vendor=$(_e "$BIOS_VENDOR"),version=$(_e "$BIOS_VERSION"),date=$(_e "$BIOS_DATE"),release=5.14,uefi=on"
    t1="type=1,manufacturer=$(_e "$SYSTEM_MFR"),product=$(_e "$SYSTEM_PRODUCT"),version=$(_e "$SYSTEM_VERSION"),serial=$(_e "$SYSTEM_SERIAL"),uuid=$UUID,sku=$(_e "$SYSTEM_SKU"),family=$(_e "$SYSTEM_FAMILY")"
    t2="type=2,manufacturer=$(_e "$BOARD_MFR"),product=$(_e "$BOARD_PRODUCT"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$BOARD_SERIAL"),asset=$BOARD_ASSET,location=Default string"
    t3="type=3,manufacturer=$(_e "$BOARD_MFR"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$CHASSIS_SERIAL"),asset=$BOARD_ASSET,sku=$(_e "$SYSTEM_SKU")"

    # processor manufacturer 跟 CPU vendor 走
    local cpu_smbios_mfr
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        cpu_smbios_mfr="Advanced Micro Devices Inc."
    else
        cpu_smbios_mfr="Intel(R) Corporation"
    fi

    t4="type=4,sock_pfx=${CPU_SOCKET},manufacturer=$(_e "$cpu_smbios_mfr"),version=$(_e "$CPU_NAME"),serial=$CPU_SERIAL,asset=$(_rand 1000 9999),part=$CPU_PART,max-speed=$CPU_MAX_MHZ,current-speed=$CPU_CUR_MHZ,processor-family=$CPU_PROC_FAMILY"

    case "$BOARD_MFR" in
        ASUS*|*ASUSTeK*)
            local cpu_oem_tag="AMD_Ryzen"
            [[ "$CPU_VENDOR" == "GenuineIntel" ]] && cpu_oem_tag="Intel_Core"
            t11="type=11,value=Default string,value=ASUS_MB_RSVD,value=ASUS_MB_CPU=${cpu_oem_tag},value=ASUS_MB_LINK_URL=http://www.asus.com" ;;
        *Micro-Star*|*MSI*)
            t11="type=11,value=Default string,value=MSI_A_1,value=MSI_OEM_A,value=MSI_OEM_B" ;;
        *Gigabyte*)
            t11="type=11,value=Default string,value=Gigabyte Technology Co.,,Ltd.,value=GBT_OEM_A" ;;
        ASRock*)
            t11="type=11,value=Default string,value=ASRock_Default,value=ASRockName" ;;
        *)
            t11="type=11,value=Default string,value=OEM_Default" ;;
    esac
    t17="type=17,loc_pfx=DIMM_A,bank=P0 CHANNEL %C,manufacturer=$(_e "$MEM_MFR"),serial=$(_rand 10000000 99999999),asset=9876543210,part=$(_e "$mem_part"),speed=$mem_speed"
    t16="type=16,max-capacity=${T16_MAX_CAPACITY:-64G},num-devices=${T16_NUM_DEVICES:-4}"
    printf '%s\n' "$t0" "$t1" "$t2" "$t3" "$t4" "$t11" "$t16" "$t17"
}
