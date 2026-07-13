_host_cpu_flags_for_qemu_arg() {
    if [[ -n "${STEALTH_HOST_CPU_FLAGS+x}" ]]; then
        printf '%s\n' "$STEALTH_HOST_CPU_FLAGS"
        return
    fi
    awk -F': ' '/^flags[[:space:]]*:/{print $2; exit}' /proc/cpuinfo 2>/dev/null
}

_host_has_cpu_flag_for_qemu_arg() {
    local flag="$1"
    local flags
    flags="$(_host_cpu_flags_for_qemu_arg)"
    [[ " $flags " == *" $flag "* ]]
}

_cpu_arg_with_host_feature_mask() {
    local cpu_arg="$1"

    # 中文注释：QEMU 的 phenom 模型默认带 3DNow!/3DNow!Ext；新 AMD 宿主
    # 通常已经移除这两个 KVM 可透传特性。若不显式关掉，QEMU 会每个 vCPU
    # 打一组 host doesn't support requested feature warning，且 guest 实际也
    # 拿不到稳定的 3DNow 表面。只在宿主缺特性时按需追加禁用项，避免影响
    # 能真实透传 3DNow 的老宿主。
    if [[ "$CPU_VENDOR" == "AuthenticAMD" && "$cpu_arg" == phenom* ]]; then
        if ! _host_has_cpu_flag_for_qemu_arg "3dnow"; then
            [[ ",$cpu_arg," == *",-3dnow,"* ]] || cpu_arg="${cpu_arg},-3dnow"
        fi
        if ! _host_has_cpu_flag_for_qemu_arg "3dnowext"; then
            [[ ",$cpu_arg," == *",-3dnowext,"* ]] || cpu_arg="${cpu_arg},-3dnowext"
        fi
    fi

    printf '%s\n' "$cpu_arg"
}

# 判断两个 TSC 频率是否处于 QEMU/KVM 允许的 250ppm 校正范围内。
# 使用整数乘法，避免 shell 浮点依赖和不同 locale 的小数解析差异。
_tsc_frequency_within_250ppm() {
    local current_khz="$1"
    local requested_khz="$2"
    local delta

    (( current_khz > 0 && requested_khz > 0 )) || return 1
    if (( current_khz >= requested_khz )); then
        delta=$(( current_khz - requested_khz ))
    else
        delta=$(( requested_khz - current_khz ))
    fi
    (( delta * 1000000 <= current_khz * 250 ))
}

# 根据真实 KVM 能力决定是否追加 tsc-freq。Broadwell-EP/E5 v4 没有硬件 TSC
# scaling；过去无条件写入消费级 CPU 的 3.1~3.6GHz 会让 vCPU 初始化直接失败。
# auto/profile 在严格模式下都拒绝不可能的组合；host/omit 仅作为显式运维选项。
_stealth_tsc_qemu_extra() {
    local policy="${STEALTH_TSC_POLICY:-auto}"
    local profile_mhz="${CPU_TSC_MHZ:-${CPU_CUR_MHZ:-0}}"
    local requested_khz=0
    local host_khz="${STEALTH_KVM_TSC_KHZ:-0}"
    local strict="${STRICT_HARDWARE:-0}"

    if ! [[ "$profile_mhz" =~ ^[0-9]+$ ]] || (( profile_mhz <= 0 )); then
        echo "ERROR: profile 缺少合法 CPU_TSC_MHZ/CPU_CUR_MHZ" >&2
        return 1
    fi
    requested_khz=$(( profile_mhz * 1000 ))

    case "$policy" in
        omit)
            echo ""
            return
            ;;
        host)
            if ! [[ "$host_khz" =~ ^[0-9]+$ ]] || (( host_khz <= 0 )); then
                echo "ERROR: STEALTH_TSC_POLICY=host 但无法读取宿主 KVM TSC" >&2
                return 1
            fi
            echo ",tsc-freq=$(( host_khz * 1000 ))"
            return
            ;;
        auto|profile) ;;
        *)
            echo "ERROR: 未知 STEALTH_TSC_POLICY: $policy" >&2
            return 1
            ;;
    esac

    if [[ "${STEALTH_KVM_TSC_CONTROL:-0}" == "1" ]] || \
       _tsc_frequency_within_250ppm "$host_khz" "$requested_khz"; then
        # QEMU 的 tsc-freq 单位是 Hz，而 KVM 探测值使用 kHz。
        echo ",tsc-freq=$(( requested_khz * 1000 ))"
        return
    fi

    if [[ "$strict" == "1" ]]; then
        echo "ERROR: 当前 profile TSC=${profile_mhz}MHz，宿主 KVM TSC=$(( host_khz / 1000 ))MHz，" >&2
        echo "       且 KVM_CAP_TSC_CONTROL 不可用；该组合在 E5 v4 等平台无法启动。" >&2
        echo "       请选择同 TSC 的 platform bundle，不能静默伪造不可能的 CPU。" >&2
        return 1
    fi

    echo ">> WARN: 宿主不支持目标 TSC 缩放；兼容模式省略 tsc-freq，硬件一致性不达标" >&2
    echo ""
}

# 给 -cpu 拼出完整字符串。CPU 特性、物理地址位数和拓扑全部来自 platform
# manifest；旧 profile 缺字段时保留最小兼容默认值，但不再泄漏宿主 phys-bits。
stealth_qemu_cpu_arg() {
    local cpu_arg
    local enforce="off"
    local phys_bits="${CPU_PHYS_BITS:-40}"
    local features="${CPU_FEATURES:-+invtsc}"
    local tsc_extra

    [[ "${STRICT_HARDWARE:-0}" == "1" ]] && enforce="on"
    if ! [[ "$phys_bits" =~ ^[0-9]+$ ]] || (( phys_bits < 32 || phys_bits > 52 )); then
        echo "ERROR: CPU_PHYS_BITS 超出 [32,52]: $phys_bits" >&2
        return 1
    fi
    tsc_extra="$(_stealth_tsc_qemu_extra)" || return 1

    local extras="kvm=off,hypervisor=off,enforce=${enforce},host-phys-bits=off,phys-bits=${phys_bits},vendor=${CPU_VENDOR}"
    [[ -n "$features" ]] && extras="${extras},${features}"
    extras="${extras}${tsc_extra}"
    cpu_arg="$(_cpu_arg_with_host_feature_mask "$CPU_QEMU_ARG")"
    echo "${cpu_arg},${extras}"
}

# Escape commas in SMBIOS string values (QEMU uses ',,' to encode a literal ','
# inside option values).
_e() { echo "${1//,/,,}"; }

_min() { if (( ${1:-0} < ${2:-0} )); then echo "${1:-0}"; else echo "${2:-0}"; fi; }

# CPU 平台官方支持的最大内存速率 (MT/s)。报告速率取 min(颗粒额定, 本值)，保证
# "CPU/主板/内存频率配套"——不会出现 i3 报超 2400、或 2400 颗粒报 2666 的破绽。
#   Ryzen 3 1200(Zen1)=2667；2300X(Zen+)=2933；Coffee Lake i3=2400(B360/H310 锁)；
#   Coffee i5/i7=2666；DDR3 家用平台按 CPU/芯片组常见上限收敛。
_cpu_max_mem() {
    if [[ "${MEM_MAX_MTS:-}" =~ ^[0-9]+$ ]] && (( MEM_MAX_MTS > 0 )); then
        echo "$MEM_MAX_MTS"
        return
    fi
    case "${CPU_NAME:-}${CPU_MODEL:-}" in
        *Athlon*II*|*Phenom*II*) echo 1333 ;;
        *FX*4100*|*FX*4300*)     echo 1866 ;;
        *Athlon*X4*860K*)        echo 2133 ;;
        *i5-2380P*|*i5-2550K*) echo 1333 ;;
        *i5-3350P*) echo 1600 ;;
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
    local mem_rated_speed="${MEM_RATED_MTS:-${MEM_RATED:-2666}}"
    local mem_configured_speed
    local mem_platform_max
    mem_platform_max="$(_cpu_max_mem)"
    # 中文注释：MEM_SPEED 只保留为非严格兼容入口，语义是 configured speed；
    # 它不能再覆盖 DIMM 的 rated speed 或 Q35 SPD。严格模式不允许它偏离 profile。
    if [[ -n "${MEM_SPEED:-}" ]]; then
        mem_configured_speed="$MEM_SPEED"
        if [[ "${STRICT_HARDWARE:-0}" == "1" &&
              "$mem_configured_speed" != "${MEM_CONFIGURED_MTS:-}" ]]; then
            echo "ERROR: 严格模式拒绝 MEM_SPEED 覆盖持久化配置速率" >&2
            return 1
        fi
    else
        mem_configured_speed="${MEM_CONFIGURED_MTS:-$(_min "$mem_rated_speed" "$mem_platform_max")}"
    fi
    if ! [[ "$mem_rated_speed" =~ ^[0-9]+$ &&
            "$mem_configured_speed" =~ ^[0-9]+$ ]] ||
       (( mem_rated_speed <= 0 || mem_configured_speed <= 0 ||
          mem_configured_speed > mem_rated_speed ||
          mem_configured_speed > mem_platform_max )); then
        echo "ERROR: SMBIOS 内存速率不可能: rated=$mem_rated_speed configured=$mem_configured_speed" >&2
        return 1
    fi
    if [[ -n "${MEM_ALLOWED_MTS:-}" &&
          ",$MEM_ALLOWED_MTS," != *",$mem_configured_speed,"* ]]; then
        echo "ERROR: 配置速率 $mem_configured_speed 不在平台允许集合 $MEM_ALLOWED_MTS" >&2
        return 1
    fi
    local mem_part="$MEM_PART_2G"
    (( mem_per_dimm_mb >= 4096 )) && mem_part="$MEM_PART_4G"

    t0="type=0,vendor=$(_e "$BIOS_VENDOR"),version=$(_e "$BIOS_VERSION"),date=$(_e "$BIOS_DATE"),release=5.14,uefi=on"
    t1="type=1,manufacturer=$(_e "$SYSTEM_MFR"),product=$(_e "$SYSTEM_PRODUCT"),version=$(_e "$SYSTEM_VERSION"),serial=$(_e "$SYSTEM_SERIAL"),uuid=$UUID,sku=$(_e "$SYSTEM_SKU"),family=$(_e "$SYSTEM_FAMILY")"
    t2="type=2,manufacturer=$(_e "$BOARD_MFR"),product=$(_e "$BOARD_PRODUCT"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$BOARD_SERIAL"),asset=$BOARD_ASSET,location=Default string"
    local chassis_type
    case "${CHASSIS_TYPE:-Desktop}" in
        Desktop)    chassis_type="0x03" ;;
        "Mini Tower") chassis_type="0x06" ;;
        Tower)      chassis_type="0x07" ;;
        *) echo "ERROR: 不支持的 CHASSIS_TYPE=${CHASSIS_TYPE:-}" >&2; return 1 ;;
    esac
    t3="type=3,manufacturer=$(_e "$BOARD_MFR"),version=$(_e "$BOARD_VERSION"),serial=$(_e "$CHASSIS_SERIAL"),asset=$BOARD_ASSET,sku=$(_e "$SYSTEM_SKU"),chassis-type=$chassis_type"

    # processor manufacturer 跟 CPU vendor 走
    local cpu_smbios_mfr
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        cpu_smbios_mfr="Advanced Micro Devices Inc."
    else
        cpu_smbios_mfr="Intel(R) Corporation"
    fi
    local cpu_asset="${CPU_ASSET:-}"
    if ! [[ "$cpu_asset" =~ ^[0-9]{4}$ ]]; then
        # 外部调试若绕过 stealth_load_profile，或 profile 被手工写坏，仍按
        # CPU_SERIAL/UUID 稳定派生兜底，保证 SMBIOS Type 4 asset 是四位数字。
        local _cpu_asset_key _cpu_asset_seed
        _cpu_asset_key="${CPU_SERIAL:-${UUID:-cpu}}"
        _cpu_asset_seed="$(printf '%s' "${_cpu_asset_key}-asset" | cksum)"
        _cpu_asset_seed="${_cpu_asset_seed%% *}"
        cpu_asset=$(( 1000 + (_cpu_asset_seed % 9000) ))
    fi

    local cpu_voltage_mv="${CPU_SMBIOS_VOLTAGE:-1200}"
    if ! [[ "$cpu_voltage_mv" =~ ^[0-9]+$ ]] || (( cpu_voltage_mv < 500 || cpu_voltage_mv > 1600 )); then
        echo "ERROR: CPU_SMBIOS_VOLTAGE 超出合理范围: $cpu_voltage_mv" >&2
        return 1
    fi
    # SMBIOS Type4 legacy voltage byte：bit7=1，低7位单位0.1V。
    local cpu_voltage_byte=$(( 0x80 | ((cpu_voltage_mv + 50) / 100) ))
    t4="type=4,sock_pfx=${CPU_SOCKET},manufacturer=$(_e "$cpu_smbios_mfr"),version=$(_e "$CPU_NAME"),serial=$CPU_SERIAL,asset=$cpu_asset,part=$CPU_PART,max-speed=$CPU_MAX_MHZ,current-speed=$CPU_CUR_MHZ,processor-family=$CPU_PROC_FAMILY,voltage=$cpu_voltage_byte,external-clock=${CPU_SMBIOS_EXT_CLOCK:-100},processor-upgrade=${CPU_SMBIOS_UPGRADE:-0x02},processor-characteristics=${CPU_SMBIOS_CHARACTERISTICS:-0x0004}"

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
    local memory_type_enum
    case "${MEM_TYPE:-DDR4}" in
        DDR3) memory_type_enum="0x18" ;;
        DDR4) memory_type_enum="0x1A" ;;
        *) echo "ERROR: 不支持的 MEM_TYPE=${MEM_TYPE:-}" >&2; return 1 ;;
    esac
    t17="type=17,loc_pfx=DIMM_%C2,bank=P0 CHANNEL %C,manufacturer=$(_e "$MEM_MFR"),serial=${MEM_SERIAL}|${mem_serial2},asset=9876543210,part=$(_e "$mem_part"),speed=$mem_rated_speed,configured-speed=$mem_configured_speed,memory-type=$memory_type_enum,type-detail=0x0080,rank=${MEM_RANK:-1},voltage=${MEM_VOLTAGE_MV:-1200}"
    t16="type=16,max-capacity=${T16_MAX_CAPACITY:-64G},num-devices=${T16_NUM_DEVICES:-2}"
    printf '%s\n' "$t0" "$t1" "$t2" "$t3" "$t4" "$t11" "$t16" "$t17"
}
