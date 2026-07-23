#!/usr/bin/env bash
# shellcheck disable=SC2034 # 本文件导出字段供后续已 source 模块和启动器使用。

# ------------------------------------------------------------------
# host-aware 选择助手：VM 伪装 CPU 要贴合**宿主机**真实能力。
#   _host_cpu_vendor   -> AuthenticAMD / GenuineIntel（读 /proc/cpuinfo）
#   _host_cpu_max_mhz  -> 宿主机单核可达上限 MHz（cpuinfo_max_freq；裸 VM 无 cpufreq
#                         时从 model name "@ X.XGHz" 估；都拿不到给大数=不按频率过滤）
# ------------------------------------------------------------------
_host_cpu_vendor() {
    local v
    if [[ -n "${STEALTH_HOST_CPU_VENDOR:-}" ]]; then
        printf '%s\n' "$STEALTH_HOST_CPU_VENDOR"
        return
    fi
    v="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    case "$v" in
        GenuineIntel) echo GenuineIntel ;;
        AuthenticAMD) echo AuthenticAMD ;;
        *)            echo "${v:-unknown}" ;;
    esac
}
_host_cpu_max_mhz() {
    local khz mhz
    if [[ "${STEALTH_HOST_CPU_MAX_MHZ:-}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$STEALTH_HOST_CPU_MAX_MHZ"
        return
    fi
    khz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo '')"
    if [[ "$khz" =~ ^[0-9]+$ ]]; then echo $(( khz / 1000 )); return; fi
    mhz="$(awk -F'@ ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null \
           | grep -oE '[0-9.]+GHz' | grep -oE '[0-9.]+')"
    if [[ -n "$mhz" ]]; then awk -v g="$mhz" 'BEGIN{printf "%d", g*1000}'; return; fi
    echo 99999
}

_host_required_tsc_mhz() {
    # 宿主预检确认没有 VMX TSC scaling 时，通过该变量传入实际 invariant TSC。
    # 空值代表硬件可以缩放或尚未要求精确匹配；非法值必须立即失败，不能忽略后
    # 继续选择一个必然无法启动的 profile。
    if [[ -z "${STEALTH_REQUIRED_TSC_MHZ:-}" ]]; then
        return 0
    fi
    if ! [[ "$STEALTH_REQUIRED_TSC_MHZ" =~ ^[0-9]+$ ]] || (( STEALTH_REQUIRED_TSC_MHZ <= 0 )); then
        echo "ERROR: STEALTH_REQUIRED_TSC_MHZ 必须是正整数 MHz" >&2
        return 1
    fi
    printf '%s\n' "$STEALTH_REQUIRED_TSC_MHZ"
}

# 判断显式平台 ID 是否来自已经加载并校验过的 manifest 投影视图。该函数只读，
# 用于 CLI 在接触已有 profile 前区分“目录里不存在”与“实例已绑定另一平台”。
stealth_platform_id_known() {
    stealth_platform_registry_is_id "$1"
}

# Guest CPU 类别是独立于“宿主能否实现”的硬门禁。E5/EPYC 宿主可以承载
# 家用命名模型，但不能因为 compatibility 或 host-passthrough 把服务器品牌串
# 暴露给 Guest。显式检查 CPU_NAME 与完整 QEMU 串，可同时挡住清单篡改和
# `-cpu host` 错接；严格 profile 还会在后续做目录逐字段绑定。
stealth_validate_guest_cpu_class() {
    local identity="${CPU_NAME:-}|${CPU_QEMU_ARG:-}"
    local lowered="${identity,,}"
    local qemu_base="${CPU_QEMU_ARG%%,*}"

    if [[ "$lowered" =~ (xeon|epyc|opteron|threadripper) ]] ||
       [[ "$lowered" =~ (^|[^[:alnum:]])e(3|5|7)[-[:space:]]*[0-9]{3,} ]] ||
       [[ "$lowered" =~ (^|[^[:alnum:]])e-[0-9]{4,5}[[:alnum:]]* ]]; then
        echo "ERROR: Guest CPU 只允许家用型号，拒绝服务器/E 系列: ${CPU_NAME:-unknown}" >&2
        return 1
    fi
    case "${CPU_VENDOR:-}" in
        GenuineIntel)
            [[ "$lowered" =~ (core|pentium|celeron|atom|processor[[:space:]][nu][0-9]) ]] \
                || {
                    echo "ERROR: 无法证明 Intel Guest CPU 属于家用系列: ${CPU_NAME:-unknown}" >&2
                    return 1
                }
            ;;
        AuthenticAMD)
            [[ "$lowered" =~ (ryzen|athlon|phenom|sempron|amd[[:space:]]fx|a[0-9]+-) ]] \
                || {
                    echo "ERROR: 无法证明 AMD Guest CPU 属于家用系列: ${CPU_NAME:-unknown}" >&2
                    return 1
                }
            ;;
        *)
            echo "ERROR: Guest CPU 厂商不受支持: ${CPU_VENDOR:-unknown}" >&2
            return 1
            ;;
    esac
    case "${qemu_base,,}" in
        host)
            if [[ "${CPU_QEMU_ARG:-}" != host ||
                  "${PLATFORM_CPU_SOURCE:-}" != host-passthrough ]]; then
                echo "ERROR: 非受控平台或附加属性不得使用 -cpu host" >&2
                return 1
            fi
            if ! declare -F stealth_host_platform_binding_is_current \
                    >/dev/null 2>&1 ||
               ! stealth_host_platform_binding_is_current; then
                echo "ERROR: -cpu host 只允许显式授权且经 registry 绑定的 schema-1 家用宿主模板" >&2
                return 1
            fi
            ;;
        max)
            echo "ERROR: Guest 家用 CPU 不得使用通用 -cpu max 基型" >&2
            return 1
            ;;
        sandybridge-ibrs|ivybridge-ibrs|haswell-v4|skylake-client-ibrs|phenom|ryzen3-1200)
            ;;
        *)
            echo "ERROR: Guest CPU 未使用已审计家用 QEMU named-model: ${qemu_base:-empty}" >&2
            return 1
            ;;
    esac

    # 本分支没有 Intel/AMD 物理 iGPU 设备模型，也不做 GPU 直通。带核显 SKU
    # 只能采用“固件中禁用”的完整平台状态，使 Windows 设备管理器不枚举一块
    # 仅改 PCI ID 的假核显；无核显和受控 host 模板分别使用 absent/not_exposed。
    case "${CPU_IGPU_PRESENT:-}" in
        1)
            [[ "${CPU_IGPU_STATE:-}" == disabled_in_bios &&
               -n "${CPU_IGPU_MODEL:-}" && "${CPU_IGPU_MODEL:-}" != none ]] || {
                echo "ERROR: 带核显家用 CPU 必须使用 disabled_in_bios 设备策略" >&2
                return 1
            }
            ;;
        0)
            [[ "${CPU_IGPU_STATE:-}" == absent ||
               "${CPU_IGPU_STATE:-}" == fused_off ||
               "${CPU_IGPU_STATE:-}" == not_exposed ]] || {
                echo "ERROR: 无核显 CPU 的设备状态非法: ${CPU_IGPU_STATE:-unknown}" >&2
                return 1
            }
            ;;
        *)
            echo "ERROR: CPU_IGPU_PRESENT 必须是 0 或 1" >&2
            return 1
            ;;
    esac
}

# 对已经选出或从 profile 重载的整机统一执行宿主约束。历史实现只在首次随机时
# 过滤，导致持久化的 AMD profile 可以在伪造的 Intel/低频宿主视图下跳过厂商、
# 线程和频率检查。现在每次启动都调用本函数，compatibility 也不能绕过这些事实。
stealth_validate_platform_host_constraints() {
    local host_vendor host_max_mhz required_tsc requested_cpus
    requested_cpus="${CPUS:-4}"
    host_vendor="$(_host_cpu_vendor)"
    host_max_mhz="$(_host_cpu_max_mhz)"
    required_tsc="$(_host_required_tsc_mhz)" || return 1

    stealth_validate_guest_cpu_class || return 1
    if ! [[ "$requested_cpus" =~ ^[0-9]+$ ]] || (( requested_cpus <= 0 )); then
        echo "ERROR: CPUS 必须是正整数" >&2
        return 1
    fi
    if ! [[ "${CPU_CORES:-}" =~ ^[0-9]+$ &&
            "${CPU_THREADS:-}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: profile CPU 核心/线程字段必须是正整数" >&2
        return 1
    fi
    case "${CPU_CORES}:${CPU_THREADS}" in
        2:2|2:4|4:4)
            ;;
        *)
            echo "ERROR: Guest CPU 拓扑只允许 2C2T、2C4T 或 4C4T；当前 ${CPU_CORES}C${CPU_THREADS}T" >&2
            return 1
            ;;
    esac
    if [[ "${CPU_VENDOR:-}" != "$host_vendor" ]]; then
        echo "ERROR: profile CPU 厂商与宿主不一致: platform=${CPU_VENDOR:-unknown} host=$host_vendor" >&2
        return 1
    fi
    if [[ "${PLATFORM_CPU_SOURCE:-}" == named-household-compatibility ]] &&
       ! stealth_household_compat_host_class_consistent; then
        echo "ERROR: household CPU 池与当前宿主 CPUID 代际不匹配: ${PLATFORM_HOST_CLASSES:-unknown}" >&2
        return 1
    fi
    if ! [[ "${CPU_THREADS:-}" =~ ^[0-9]+$ ]] || (( CPU_THREADS != requested_cpus )); then
        echo "ERROR: profile 要求完整 ${CPU_THREADS:-unknown} 线程，当前 CPUS=$requested_cpus" >&2
        return 1
    fi
    if ! [[ "${CPU_MAX_MHZ:-}" =~ ^[0-9]+$ && "$host_max_mhz" =~ ^[0-9]+$ ]] ||
       (( CPU_MAX_MHZ > host_max_mhz )); then
        if declare -F _stealth_household_runtime_variance_allowed >/dev/null 2>&1 &&
           _stealth_household_runtime_variance_allowed &&
           [[ "${CPU_MAX_MHZ:-}" =~ ^[0-9]+$ && "$host_max_mhz" =~ ^[0-9]+$ ]]; then
            if [[ "${_STEALTH_FREQ_COMPAT_WARNED:-0}" != 1 ]]; then
                echo ">> WARN: 家用 CPU 型号上限 ${CPU_MAX_MHZ}MHz 高于宿主 ${host_max_mhz}MHz；Guest 保留型号信息，执行性能受宿主限制" >&2
                _STEALTH_FREQ_COMPAT_WARNED=1
            fi
        else
            echo "ERROR: profile 最大频率 ${CPU_MAX_MHZ:-unknown}MHz 超过宿主可达 ${host_max_mhz:-unknown}MHz" >&2
            return 1
        fi
    fi
    if [[ -n "$required_tsc" ]] &&
       { ! [[ "${CPU_TSC_MHZ:-}" =~ ^[0-9]+$ ]] || (( CPU_TSC_MHZ != required_tsc )); }; then
        case "${STEALTH_TSC_POLICY:-auto}" in
            host|omit)
                ;;
            auto)
                if declare -F _stealth_household_unscaled_tsc_allowed >/dev/null 2>&1 &&
                   _stealth_household_unscaled_tsc_allowed; then
                    if [[ "${_STEALTH_TSC_COMPAT_WARNED:-0}" != 1 ]]; then
                        echo ">> WARN: 家用 CPU 的 TSC 无法在当前宿主缩放；Guest 将沿用宿主 ${required_tsc}MHz TSC" >&2
                        _STEALTH_TSC_COMPAT_WARNED=1
                    fi
                else
                    echo "ERROR: profile TSC=${CPU_TSC_MHZ:-unknown}MHz 与宿主必需 ${required_tsc}MHz 不一致" >&2
                    return 1
                fi
                ;;
            *)
                echo "ERROR: profile TSC=${CPU_TSC_MHZ:-unknown}MHz 与宿主必需 ${required_tsc}MHz 不一致" >&2
                return 1
                ;;
        esac
    fi
}

_gen_platform_nic_mac() {
    # 板载网卡型号已经由平台清单绑定，MAC OUI 必须来自同一个供应商。此前从混合
    # OUI 池随机会产生“Realtek RTL8111H 使用 Intel OUI”的跨字段矛盾。
    if ! [[ "${NIC_MAC_OUI:-}" =~ ^([0-9a-f]{2}:){2}[0-9a-f]{2}$ ]]; then
        echo "ERROR: 平台网卡没有受审计 OUI: ${NIC_MAC_OUI:-empty}" >&2
        return 1
    fi
    local suffix
    while :; do
        suffix="$(_hex 6)"
        [[ "$suffix" != "000000" && "$suffix" != "ffffff" ]] && break
    done
    printf '%s:%s:%s:%s\n' "$NIC_MAC_OUI" \
        "${suffix:0:2}" "${suffix:2:2}" "${suffix:4:2}"
}

# ------------------------------------------------------------------
# 公开：随机生成一份完整 profile 并 export
# ------------------------------------------------------------------
stealth_pick_profile() {
    _rng_init

    # 1. 按完整整机 bundle 选择。E5 v3/v4 先使用专属正常家用 CPU 池，
    #    其它宿主再走普通物理 supported；显式 compatibility 才加入其余家用
    #    型号和受限 host 模板。每层都逐个执行真实 KVM realize。
    local _requested_cpus="${CPUS:-4}"
    if [[ "$_requested_cpus" != 2 && "$_requested_cpus" != 4 ]]; then
        echo "ERROR: 家用 Guest 的 CPUS 只允许 2 或 4（2C2T/2C4T/4C4T）" >&2
        return 1
    fi
    case "${ALLOW_PLATFORM_COMPATIBILITY:-0}" in
        0|1) ;;
        *)
            echo "ERROR: ALLOW_PLATFORM_COMPATIBILITY 必须是 0 或 1" >&2
            return 1
            ;;
    esac
    stealth_select_platform_bundle || return 1

    # 平台事实来自 manifest；这里只生成每台 VM 唯一、且之后会持久化的序列号。
    BOARD_SERIAL="$($SERIAL_FN)"
    BOARD_ASSET="$(_rand 1000000000 9999999999)"

    SYSTEM_MFR="$BOARD_MFR"
    SYSTEM_VERSION="$BOARD_VERSION"
    SYSTEM_SERIAL="$($SERIAL_FN)"
    SYSTEM_SKU="SKU$(_rand 100000 999999)"

    # SMBIOS Type 3 是整机身份，不再从全局机箱池独立抽签。当前 schema
    # 只允许 DMTF Desktop(0x03)；保留历史文本值以兼容 SMBIOS 参数生成器。
    case "$SYSTEM_CHASSIS_TYPE" in
        0x03) CHASSIS_TYPE="Desktop" ;;
        *)
            echo "ERROR: 平台 $PLATFORM_ID 包含不支持的 chassis type: $SYSTEM_CHASSIS_TYPE" >&2
            return 1 ;;
    esac
    CHASSIS_SERIAL="$($SERIAL_FN)"

    NIC_MAC="$(_gen_platform_nic_mac)" || return 1
    UUID="$(_gen_uuid)"
    CPU_SERIAL="$(_rand 1000000000 9999999999)"
    # CPU asset tag 会进入 SMBIOS Type 4；和 CPU_SERIAL 一起持久化，避免每次启动变化。
    CPU_ASSET="$(_rand 1000 9999)"

    # 3. GPU
    local gpu_row
    gpu_row="$(stealth_select_gpu_component_row)" || return 1
    stealth_assign_gpu_profile_row "$gpu_row"

    # 4. NVMe
    local nvme_row
    local nvme_manufacturer nvme_part_number nvme_identity_profile
    local nvme_serial_kind nvme_serial_pattern nvme_serial_length nvme_weight
    nvme_row="$(stealth_select_storage_component_row)" || return 1
    IFS='|' read -r NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE NVME_SIZE_BYTES \
        NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN NVME_SUBSYS_DEV \
        NVME_SUBNQN_TEMPLATE nvme_manufacturer nvme_part_number \
        nvme_identity_profile nvme_serial_kind nvme_serial_pattern \
        nvme_serial_length nvme_weight <<<"$nvme_row"
    [[ "$NVME_COMPONENT_ID" == "$nvme_identity_profile" ]] || return 1
    NVME_SERIAL="$(_nvme_serial "$NVME_COMPONENT_ID")" || return 1
    stealth_component_storage_serial_is_valid \
        "$NVME_COMPONENT_ID" "$NVME_SERIAL" >/dev/null || return 1
    NVME_SUBNQN="${NVME_SUBNQN_TEMPLATE//\{uuid\}/$UUID}"

    # 启动盘是独立部件身份：NVMe 平台镜像实际 NVMe component；老式主板则从
    # 独立消费级 SATA 目录抽取 840/850/860 PRO 完整组合。这里只抽签一次，
    # BOOT_STORAGE_COMPONENT_ID 及所有 Guest 可见字段随后写入 profile。
    case "${PLATFORM_BOOT_STORAGE:-}" in
        nvme)
            [[ "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" == component-nvme ]] || {
                echo "ERROR: NVMe 平台没有绑定 component-nvme 启动盘池" >&2
                return 1
            }
            BOOT_STORAGE_CATALOG_REVISION="$COMPONENT_CATALOG_REVISION"
            BOOT_STORAGE_COMPONENT_ID="$NVME_COMPONENT_ID"
            BOOT_STORAGE_MANUFACTURER="$nvme_manufacturer"
            BOOT_STORAGE_MODEL="$NVME_MODEL"
            BOOT_STORAGE_PART_NUMBER="$nvme_part_number"
            BOOT_STORAGE_FIRMWARE="$NVME_FIRMWARE"
            BOOT_STORAGE_SIZE_BYTES="$NVME_SIZE_BYTES"
            BOOT_STORAGE_INTERFACE=nvme
            BOOT_STORAGE_SERIAL="$NVME_SERIAL"
            ;;
        sata-ahci)
            [[ "${PLATFORM_BOOT_STORAGE_POOL_ID:-}" == samsung-sata-pro-512gb ]] || {
                echo "ERROR: SATA 平台没有绑定 samsung-sata-pro-512gb 启动盘池" >&2
                return 1
            }
            local boot_storage_id
            boot_storage_id="$(stealth_storage_compat_pick_id)" || return 1
            stealth_storage_compat_load "$boot_storage_id" || return 1
            BOOT_STORAGE_SERIAL="$(_boot_storage_serial)"
            ;;
        *)
            echo "ERROR: 无法为未知启动总线选择启动盘: ${PLATFORM_BOOT_STORAGE:-empty}" >&2
            return 1
            ;;
    esac

    # 5. 内存厂家 / part / 持久化序列号
    # 先固定总容量，再由共享目录同时校验 DDR 代际、socket、通道、电压、
    # 插槽数、模块容量和训练频率。选择权威是实际安装的 module ID；family
    # 不再被要求伪造一个并不存在的 2GiB/4GiB 配对 SKU。
    MEM_TOTAL_MB="${MEM_TOTAL_MB:-$PLATFORM_DEFAULT_MEMORY_MIB}"
    if [[ ",$MEM_ALLOWED_TOTAL_MB," != *",$MEM_TOTAL_MB,"* ]]; then
        echo "ERROR: 平台 $PLATFORM_ID 不允许 ${MEM_TOTAL_MB}MiB；允许值=$MEM_ALLOWED_TOTAL_MB" >&2
        return 1
    fi
    local memory_socket="$CPU_SOCKET"
    [[ "${PLATFORM_CPU_SOURCE:-}" == host-passthrough ]] && memory_socket="*"
    local memory_candidates=()
    mapfile -t memory_candidates < <(
        stealth_memory_platform_module_plan_rows \
            "$MEM_TYPE" "$memory_socket" "$MEM_CHANNELS" "$MEM_VOLTAGE_MV" \
            "$BOARD_DIMM_SLOTS" "$MEM_TOTAL_MB" "$MEM_MODULE_MB" \
            "$MEM_ALLOWED_MTS" "$MEM_MAX_MTS"
    )
    if (( ${#memory_candidates[@]} == 0 )); then
        echo "ERROR: 没有适配 platform=$PLATFORM_ID、${MEM_TOTAL_MB}MiB 的内存物料" >&2
        return 1
    fi
    local memory_row
    memory_row="$(stealth_select_memory_module_row memory_candidates)" || return 1
    local MEM_SOCKETS MEM_SELECTION_WEIGHT
    local _selected_part _selected_rank _selected_device_width
    IFS='|' read -r MEM_FAMILY_ID MEM_MODULE_ID MEM_MFR MEM_TYPE \
        _selected_part MEM_RATED_MTS MEM_CONFIGURED_MTS MEM_VOLTAGE_MV \
        MEM_SOCKETS _selected_rank _selected_device_width \
        MEM_SELECTED_MODULE_MB MEM_MODULE_COUNT MEM_SELECTION_WEIGHT \
        MEM_SPD_EE1004 <<<"$memory_row"

    # 完整 family 继续保存旧的双容量兼容视图；singleton family 则把不存在的
    # 槽位明确记为空/0。Guest 实际参数始终由上面的 MEM_MODULE_ID 决定。
    MEM_PART_2G=""
    MEM_PART_4G=""
    MEM_RANK_2G=0
    MEM_DEVICE_WIDTH_2G=0
    MEM_RANK_4G=0
    MEM_DEVICE_WIDTH_4G=0
    local _legacy_memory_row
    while IFS= read -r _legacy_memory_row; do
        [[ "$_legacy_memory_row" == "$MEM_FAMILY_ID|"* ]] || continue
        IFS='|' read -r _ _ _ _ MEM_PART_2G MEM_PART_4G _ _ _ _ \
            MEM_RANK_2G MEM_DEVICE_WIDTH_2G \
            MEM_RANK_4G MEM_DEVICE_WIDTH_4G _ <<<"$_legacy_memory_row"
        break
    done < <(stealth_memory_platform_candidate_rows \
        "$MEM_TYPE" "$memory_socket" "$MEM_CHANNELS" "$MEM_VOLTAGE_MV" \
        "$BOARD_DIMM_SLOTS" "$MEM_TOTAL_MB" "$MEM_MODULE_MB" \
        "$MEM_ALLOWED_MTS" "$MEM_MAX_MTS")
    if [[ -z "$MEM_PART_2G" && -z "$MEM_PART_4G" ]]; then
        case "$MEM_SELECTED_MODULE_MB" in
            2048)
                MEM_PART_2G="$_selected_part"
                MEM_RANK_2G="$_selected_rank"
                MEM_DEVICE_WIDTH_2G="$_selected_device_width"
                ;;
            4096)
                MEM_PART_4G="$_selected_part"
                MEM_RANK_4G="$_selected_rank"
                MEM_DEVICE_WIDTH_4G="$_selected_device_width"
                ;;
            *)
                echo "ERROR: 共享目录返回不受支持的 DIMM 容量" >&2
                return 1
                ;;
        esac
    fi
    MEM_RATED="$MEM_RATED_MTS"
    # DIMM serial 在 pick 阶段一次性生成，写到 profile 持久化——避免之前每次
    # 启动 stealth_smbios_args 里 _rand 一遍导致 Win32_PhysicalMemory.SerialNumber
    # 重启就变（仿真机"硬件指纹漂移"检测的明显信号）。
    MEM_SERIAL="$(_mem_serial)"

    # 6. 显示器（EDID）
    local monitor_row _mo_serial_prefix
    monitor_row="$(stealth_select_monitor_component_row)" || return 1
    IFS='|' read -r EDID_COMPONENT_ID EDID_VENDOR EDID_NAME EDID_WIDTH_MM \
        EDID_HEIGHT_MM _mo_serial_prefix EDID_PRODUCT_ID EDID_MANUFACTURE_WEEK \
        EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT EDID_MIN_VFREQ_HZ \
        EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ EDID_MAX_HFREQ_KHZ \
        EDID_MAX_PIXEL_CLOCK_MHZ EDID_SECONDARY_XRES EDID_SECONDARY_YRES \
        EDID_SECONDARY_REFRESH_RATE <<<"$monitor_row"
    EDID_SERIAL="$(_monitor_serial "$EDID_COMPONENT_ID")" || return 1
    EDID_BINARY_SERIAL="$(
        stealth_component_monitor_binary_serial \
            "$EDID_COMPONENT_ID" "$EDID_SERIAL"
    )" || return 1
    EDID_REVISION="$(stealth_component_monitor_revision \
        "$EDID_COMPONENT_ID")" || return 1
    local monitor_secondary_detail
    monitor_secondary_detail="$(
        stealth_component_monitor_secondary_detail "$EDID_COMPONENT_ID"
    )" || return 1
    IFS='|' read -r EDID_SECONDARY_PIXEL_CLOCK_KHZ \
        EDID_SECONDARY_HFRONT EDID_SECONDARY_HSYNC EDID_SECONDARY_HBLANK \
        EDID_SECONDARY_VFRONT EDID_SECONDARY_VSYNC EDID_SECONDARY_VBLANK \
        EDID_SECONDARY_HSYNC_POSITIVE EDID_SECONDARY_VSYNC_POSITIVE \
        EDID_SECONDARY_WIDTH_MM EDID_SECONDARY_HEIGHT_MM \
        <<<"$monitor_secondary_detail"

    # 7. 键盘 USB HID
    local kbd_n=${#KBD_POOL[@]}
    local kbd_i
    kbd_i="$(_rand 0 "$((kbd_n - 1))")" || return 1
    IFS='|' read -r KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_COMPONENT_ID \
        KBD_BCD_DEVICE KBD_DESCRIPTOR_FIDELITY <<<"${KBD_POOL[$kbd_i]}"
    KBD_SERIAL="$(_usb_hid_serial "$KBD_COMPONENT_ID")"

    # 8. 鼠标 USB HID（相对坐标场景）
    local mou_n=${#MOUSE_POOL[@]}
    local mou_i
    mou_i="$(_rand 0 "$((mou_n - 1))")" || return 1
    IFS='|' read -r MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT \
        MOUSE_COMPONENT_ID MOUSE_BCD_DEVICE MOUSE_DESCRIPTOR_FIDELITY \
        <<<"${MOUSE_POOL[$mou_i]}"
    MOUSE_SERIAL="$(_usb_hid_serial "$MOUSE_COMPONENT_ID")"

    # 9. 数位板 USB HID（绝对坐标场景，自动化默认）
    local tab_n=${#TABLET_POOL[@]}
    local tab_i
    tab_i="$(_rand 0 "$((tab_n - 1))")" || return 1
    IFS='|' read -r TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT \
        TABLET_COMPONENT_ID TABLET_BCD_DEVICE TABLET_DESCRIPTOR_FIDELITY \
        <<<"${TABLET_POOL[$tab_i]}"
    TABLET_SERIAL="$(_usb_hid_serial "$TABLET_COMPONENT_ID")"

    export PLATFORM_SCHEMA_VERSION PLATFORM_CATALOG_REVISION PLATFORM_ID PLATFORM_STATUS PLATFORM_RELEASE_YEAR
    export TPM_CAPABILITY TPM_SUPPORTED TPM_IMPLEMENTATION TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS
    export COMPONENT_SCHEMA_VERSION COMPONENT_CATALOG_REVISION
    export CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_TSC_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL CPU_ASSET
    export CPU_CORES CPU_THREADS CPU_PHYS_BITS CPU_FEATURES CPU_SMBIOS_UPGRADE CPU_SMBIOS_VOLTAGE CPU_SMBIOS_EXT_CLOCK CPU_SMBIOS_CHARACTERISTICS
    export CPU_IGPU_PRESENT CPU_IGPU_STATE CPU_IGPU_MODEL
    export BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV
    export BOARD_DIMM_SLOTS BOARD_MAX_MEMORY_GIB PCH_MODEL PCIE_GENERATION
    export SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_CHASSIS_TYPE SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    export BIOS_VENDOR BIOS_VERSION BIOS_DATE
    export CHASSIS_TYPE CHASSIS_SERIAL
    export NIC_MAC UUID
    stealth_export_gpu_profile
    export NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN NVME_SUBSYS_DEV NVME_SUBNQN_TEMPLATE NVME_SUBNQN
    export BOOT_STORAGE_CATALOG_REVISION BOOT_STORAGE_COMPONENT_ID
    export BOOT_STORAGE_MANUFACTURER BOOT_STORAGE_MODEL BOOT_STORAGE_PART_NUMBER
    export BOOT_STORAGE_FIRMWARE BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE
    export BOOT_STORAGE_SERIAL
    export MEM_FAMILY_ID MEM_MODULE_ID MEM_SELECTED_MODULE_MB MEM_MODULE_COUNT MEM_SPD_EE1004
    export MEM_MFR MEM_PART_2G MEM_PART_4G MEM_RATED MEM_RATED_MTS MEM_CONFIGURED_MTS MEM_SERIAL MEM_TOTAL_MB MEM_TYPE MEM_CHANNELS MEM_MAX_MTS MEM_ALLOWED_MTS
    export MEM_VOLTAGE_MV MEM_RANK MEM_MODULE_MB MEM_ALLOWED_TOTAL_MB MEM_MAX_CAPACITY_MB
    export MEM_RANK_2G MEM_DEVICE_WIDTH_2G MEM_RANK_4G MEM_DEVICE_WIDTH_4G
    export ROOT_PORT_PCI_VEN ROOT_PORT_PCI_DEV ROOT_PORT_REV XHCI_PCI_VEN XHCI_PCI_DEV XHCI_REV
    export MCH_PCI_VEN MCH_PCI_DEV MCH_REV LPC_PCI_VEN LPC_PCI_DEV LPC_REV SMBUS_PCI_VEN SMBUS_PCI_DEV SMBUS_REV AHCI_PCI_VEN AHCI_PCI_DEV AHCI_REV
    export NIC_VENDOR NIC_MODEL NIC_PCI_VEN NIC_PCI_DEV NIC_SUBSYSTEM_VEN NIC_SUBSYSTEM_DEV NIC_MAC_OUI NIC_ATTACHMENT BOARD_NIC_STATE
    export AUDIO_VENDOR AUDIO_CODEC AUDIO_CODEC_ID AUDIO_CODEC_REVISION AUDIO_CODEC_SUBSYSTEM_ID AUDIO_IDENTITY_FIDELITY AUDIO_CONTROLLER_PCI_VEN AUDIO_CONTROLLER_PCI_DEV
    export EDID_COMPONENT_ID EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL EDID_BINARY_SERIAL EDID_REVISION EDID_PRODUCT_ID EDID_MANUFACTURE_WEEK EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT
    export EDID_MIN_VFREQ_HZ EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ EDID_MAX_HFREQ_KHZ EDID_MAX_PIXEL_CLOCK_MHZ EDID_SECONDARY_XRES EDID_SECONDARY_YRES EDID_SECONDARY_REFRESH_RATE
    export EDID_SECONDARY_PIXEL_CLOCK_KHZ EDID_SECONDARY_HFRONT EDID_SECONDARY_HSYNC EDID_SECONDARY_HBLANK EDID_SECONDARY_VFRONT EDID_SECONDARY_VSYNC EDID_SECONDARY_VBLANK
    export EDID_SECONDARY_HSYNC_POSITIVE EDID_SECONDARY_VSYNC_POSITIVE
    export EDID_SECONDARY_WIDTH_MM EDID_SECONDARY_HEIGHT_MM
    export KBD_COMPONENT_ID KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL KBD_BCD_DEVICE KBD_DESCRIPTOR_FIDELITY
    export MOUSE_COMPONENT_ID MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL MOUSE_BCD_DEVICE MOUSE_DESCRIPTOR_FIDELITY
    export TABLET_COMPONENT_ID TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL TABLET_BCD_DEVICE TABLET_DESCRIPTOR_FIDELITY
}
