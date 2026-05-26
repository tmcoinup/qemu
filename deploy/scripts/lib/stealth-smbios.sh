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

_min() { if (( ${1:-0} < ${2:-0} )); then echo "${1:-0}"; else echo "${2:-0}"; fi; }

# CPU 平台官方支持的最大内存速率 (MT/s)。报告速率取 min(颗粒额定, 本值)，保证
# "CPU/主板/内存频率配套"——不会出现 i3 报超 2400、或 2400 颗粒报 2666 的破绽。
#   Ryzen 3 1200(Zen1)=2667；2300X(Zen+)=2933；Coffee Lake i3=2400(B360/H310 锁)；
#   Coffee i5/i7=2666；其它 Ryzen 兜 2933。(Haswell/DDR3 等留 DDR3 批次再加。)
_cpu_max_mem() {
    case "${CPU_NAME:-}${CPU_MODEL:-}" in
        *2300X*)     echo 2933 ;;
        *1200*)      echo 2667 ;;
        *i3-*)       echo 2400 ;;
        *i5-*|*i7-*) echo 2666 ;;
        *Ryzen*)     echo 2933 ;;
        *)           echo 2666 ;;
    esac
}

# ------------------------------------------------------------------
# SMBIOS 参数构造器，每行一个完整 -smbios option (commas 已转义)
# ------------------------------------------------------------------
stealth_smbios_args() {
    local t0 t1 t2 t3 t4 t11 t16 t17
    local mem_per_dimm_mb="${MEM_PER_DIMM_MB:-2048}"
    # 报告速率：显式 MEM_SPEED 优先；否则 min(颗粒额定 MEM_RATED, CPU 平台上限)。
    local mem_speed
    if [[ -n "${MEM_SPEED:-}" ]]; then
        mem_speed="$MEM_SPEED"
    else
        mem_speed="$(_min "${MEM_RATED:-2666}" "$(_cpu_max_mem)")"
    fi
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
    # MEM_SERIAL 已经从 profile load 出来（持久化），不再用 _rand 每启动随机。
    # asset 留 9876543210 不动——消费级 DIMM 的 asset tag 真实世界里就是这种
    # 厂商占位字符串或空（Win10 dmidecode 也常报 9876543210 / "Not Specified"）。
    #
    # 每条 DIMM 必须有唯一序列号：真实主板两条内存 SN 必不同。QEMU 单条 type=17
    # 模板原本对所有 DIMM instance 套同一 serial → 双通道时"两条内存同 SN"，是
    # 一眼假的 SMBIOS 伪造特征（Win32_PhysicalMemory.SerialNumber 重复）。已给
    # smbios.c 打补丁：serial 支持 '|' 分隔的 per-DIMM 列表，loc_pfx 支持 %C 通道
    # 替换。第 2 条 SN 由 MEM_SERIAL 确定性派生（sha256 前 8 hex、大写），跨重启
    # 稳定、跨 VM 唯一，无需再往 profile 多存字段；单条 DIMM 时 QEMU 只取 SN1。
    local mem_serial2
    mem_serial2=$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')
    # loc_pfx=DIMM_%C2 → DIMM_A2 / DIMM_B2（ASUS/AMI 双通道槽位命名）；bank %C → CHANNEL A/B。
    t17="type=17,loc_pfx=DIMM_%C2,bank=P0 CHANNEL %C,manufacturer=$(_e "$MEM_MFR"),serial=${MEM_SERIAL}|${mem_serial2},asset=9876543210,part=$(_e "$mem_part"),speed=$mem_speed"
    t16="type=16,max-capacity=${T16_MAX_CAPACITY:-64G},num-devices=${T16_NUM_DEVICES:-2}"
    printf '%s\n' "$t0" "$t1" "$t2" "$t3" "$t4" "$t11" "$t16" "$t17"
}
