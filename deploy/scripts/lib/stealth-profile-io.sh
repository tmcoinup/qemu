# shellcheck shell=bash
# ------------------------------------------------------------------
# 持久化 / 载入
# ------------------------------------------------------------------
_STEALTH_PROFILE_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_STEALTH_PROFILE_IO_DIR/stealth-profile-verify.sh"
source "$_STEALTH_PROFILE_IO_DIR/stealth-gpu-profile.sh"
source "$_STEALTH_PROFILE_IO_DIR/stealth-component-profile-verify.sh"
# shellcheck source=stealth-storage-profile-migrate.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-storage-profile-migrate.sh"
# shellcheck source=stealth-tpm-profile.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-tpm-profile.sh"
# shellcheck source=stealth-identity-verify.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-identity-verify.sh"

_STEALTH_PROFILE_VARS=(
    PLATFORM_SCHEMA_VERSION PLATFORM_CATALOG_REVISION PLATFORM_ID PLATFORM_STATUS PLATFORM_RELEASE_YEAR
    "${_STEALTH_PLATFORM_METADATA_VARS[@]}"
    TPM_CAPABILITY TPM_SUPPORTED TPM_IMPLEMENTATION TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS
    COMPONENT_SCHEMA_VERSION COMPONENT_CATALOG_REVISION
    CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_TSC_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL CPU_ASSET
    CPU_CORES CPU_THREADS CPU_PHYS_BITS CPU_FEATURES CPU_SMBIOS_UPGRADE CPU_SMBIOS_VOLTAGE CPU_SMBIOS_EXT_CLOCK CPU_SMBIOS_CHARACTERISTICS
    CPU_IGPU_PRESENT CPU_IGPU_STATE CPU_IGPU_MODEL
    "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"
    BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV
    BOARD_DIMM_SLOTS BOARD_MAX_MEMORY_GIB PCH_MODEL PCIE_GENERATION
    SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_CHASSIS_TYPE SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    BIOS_VENDOR BIOS_VERSION BIOS_DATE
    CHASSIS_TYPE CHASSIS_SERIAL
    NIC_MAC NIC_VENDOR NIC_MODEL NIC_PCI_VEN NIC_PCI_DEV NIC_SUBSYSTEM_VEN NIC_SUBSYSTEM_DEV NIC_MAC_OUI NIC_ATTACHMENT BOARD_NIC_STATE UUID
    ROOT_PORT_PCI_VEN ROOT_PORT_PCI_DEV ROOT_PORT_REV XHCI_PCI_VEN XHCI_PCI_DEV XHCI_REV
    MCH_PCI_VEN MCH_PCI_DEV MCH_REV LPC_PCI_VEN LPC_PCI_DEV LPC_REV SMBUS_PCI_VEN SMBUS_PCI_DEV SMBUS_REV AHCI_PCI_VEN AHCI_PCI_DEV AHCI_REV
    AUDIO_VENDOR AUDIO_CODEC AUDIO_CODEC_ID AUDIO_CODEC_REVISION AUDIO_CODEC_SUBSYSTEM_ID AUDIO_IDENTITY_FIDELITY AUDIO_CONTROLLER_PCI_VEN AUDIO_CONTROLLER_PCI_DEV
    NVME_MAX_PCIE_GENERATION NVME_LANES NVME_BOOT_SUPPORTED NVME_ATTACHMENT
    GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV GPU_IDENTITY_FIDELITY
    GPU_MEMORY_TYPE GPU_MEMORY_BUS_WIDTH_BITS GPU_BASE_CLOCK_KHZ GPU_BOOST_CLOCK_KHZ GPU_MEMORY_CLOCK_KHZ GPU_SLI_SUPPORTED
    NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN NVME_SUBSYS_DEV NVME_SUBNQN_TEMPLATE NVME_SUBNQN
    BOOT_STORAGE_CATALOG_REVISION BOOT_STORAGE_COMPONENT_ID BOOT_STORAGE_MANUFACTURER
    BOOT_STORAGE_MODEL BOOT_STORAGE_PART_NUMBER BOOT_STORAGE_FIRMWARE
    BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE BOOT_STORAGE_SERIAL
    MEM_MFR MEM_PART_2G MEM_PART_4G MEM_RATED MEM_RATED_MTS MEM_CONFIGURED_MTS MEM_SERIAL MEM_TOTAL_MB MEM_TYPE MEM_CHANNELS MEM_MAX_MTS MEM_ALLOWED_MTS
    MEM_VOLTAGE_MV MEM_RANK MEM_RANK_2G MEM_DEVICE_WIDTH_2G MEM_RANK_4G MEM_DEVICE_WIDTH_4G
    MEM_MODULE_MB MEM_ALLOWED_TOTAL_MB MEM_MAX_CAPACITY_MB
    EDID_COMPONENT_ID EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL EDID_PRODUCT_ID EDID_MANUFACTURE_WEEK EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT
    EDID_MIN_VFREQ_HZ EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ EDID_MAX_HFREQ_KHZ EDID_MAX_PIXEL_CLOCK_MHZ EDID_SECONDARY_XRES EDID_SECONDARY_YRES EDID_SECONDARY_REFRESH_RATE
    KBD_COMPONENT_ID KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL KBD_BCD_DEVICE KBD_DESCRIPTOR_FIDELITY
    MOUSE_COMPONENT_ID MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL MOUSE_BCD_DEVICE MOUSE_DESCRIPTOR_FIDELITY
    TABLET_COMPONENT_ID TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL TABLET_BCD_DEVICE TABLET_DESCRIPTOR_FIDELITY
)

_STEALTH_PROFILE_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stealth-profile-save.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-profile-save.sh"

stealth_have_profile() { [[ -s "$1" ]]; }

_stealth_is_profile_key() {
    local k="$1" w
    for w in "${_STEALTH_PROFILE_VARS[@]}"; do
        [[ "$k" == "$w" ]] && return 0
    done
    return 1
}

# 安全读取 profile 单个字段（P1#2）：供只取少数字段的 host 工具用，替代
# `source`/`eval grep`。命中且安全则打印值并 return 0；未登记 key / 文件不可读 /
# 未找到 / 值含命令替换·反引号·参数展开 则 return 1（绝不执行 profile 内代码）。
stealth_profile_get() {
    local want="$1" path="$2" line rawval
    _stealth_is_profile_key "$want" || return 1
    [[ -r "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$want="* ]] || continue
        rawval="${line#*=}"
        # shellcheck disable=SC2016 # 单引号内容是要识别的危险字面量，不应展开。
        if [[ "$rawval" == *'$('* || "$rawval" == *'`'* || "$rawval" == *'${'* ]]; then
            return 1
        fi
        printf '%s' "$rawval" | sed -E 's/\\(.)/\1/g'
        return 0
    done < "$path"
    return 1
}

_stealth_stable_hex() {
    local key="$1" width="$2" digest
    digest="$(printf '%s' "$key" | sha256sum | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
    echo "${digest:0:$width}"
}

_stealth_stable_dec_range() {
    local key="$1" lo="$2" hi="$3" hex
    hex="$(_stealth_stable_hex "$key" 12)"
    echo $(( lo + (16#$hex % (hi - lo + 1)) ))
}

_stealth_stable_uuid() {
    local key="$1" h
    h="$(_stealth_stable_hex "$key" 32 | tr '[:upper:]' '[:lower:]')"
    echo "${h:0:8}-${h:8:4}-4${h:12:3}-8${h:16:3}-${h:20:12}"
}

_stealth_stable_board_serial() {
    local mfr="$1" key="$2"
    case "$mfr" in
        *Micro-Star*|*MSI*)
            echo "$(_stealth_stable_hex "$key-msi" 4)$(_stealth_stable_dec_range "$key-msi-num" 100000 999999)" ;;
        *Gigabyte*)
            echo "SN$(_stealth_stable_dec_range "$key-giga" 10000000 99999999)" ;;
        ASRock*)
            echo "M80-$(_stealth_stable_hex "$key-asrock" 4)$(_stealth_stable_dec_range "$key-asrock-num" 1000 9999)" ;;
        *)
            echo "MB-$(_stealth_stable_hex "$key-asus" 6)$(_stealth_stable_dec_range "$key-asus-num" 10000 99999)" ;;
    esac
}

_stealth_stable_mac() {
    local key="$1" oui="$2"
    local b1 b2 b3
    if ! [[ "$oui" =~ ^([0-9a-f]{2}:){2}[0-9a-f]{2}$ ]]; then
        echo "ERROR: 无法为非法 OUI 生成稳定 MAC: $oui" >&2
        return 1
    fi
    b1="$(_stealth_stable_dec_range "$key-b1" 0 255)"
    b2="$(_stealth_stable_dec_range "$key-b2" 0 255)"
    b3="$(_stealth_stable_dec_range "$key-b3" 0 255)"
    if (( b1 == 0 && b2 == 0 && b3 == 0 )); then
        b3=1
    elif (( b1 == 255 && b2 == 255 && b3 == 255 )); then
        b3=254
    fi
    printf '%s:%02x:%02x:%02x\n' "$oui" "$b1" "$b2" "$b3"
}

stealth_load_profile() {
    local path="$1"
    local -A _stealth_present_keys=()
    local -A _stealth_explicit_empty_keys=()
    local _boot_storage_migration_kind=none
    local _legacy_boot_storage_serial=

    case "${ALLOW_STORAGE_PROFILE_MIGRATION:-0}" in
        0|1) ;;
        *)
            echo "ERROR: ALLOW_STORAGE_PROFILE_MIGRATION 必须是 0 或 1" >&2
            return 1
            ;;
    esac

    # 安全解析（P1#6）：绝不 source/eval profile——被篡改的 profile 否则等同
    # 执行任意 shell 代码（多个 root 脚本读 profile 后还会挂 NTFS / 写 hive）。
    # 改为逐行白名单 KEY=VALUE：
    #   · 只接受 _STEALTH_PROFILE_VARS 里登记的 key（合法标识符）；
    #   · VALUE 是 stealth_save_profile 用 %q 写的，按反斜杠转义反转（sed，
    #     不执行任何代码：\X→X，含 \\→\ 、\(→( ）；
    #   · 含命令替换 $(...) / 反引号 / ${...} 的值一律拒绝并跳过（纵深防御，
    #     即便漏过也因为用 printf -v 赋值而非 eval，不会被执行）。
    # 权限校验：profile 不应**他人(world)可写**——那是任意用户篡改身份的入口
    # （root 脚本读 profile 后会挂 NTFS / 写 hive）。组可写(如常见的 664)在单机
    # 自有 group 下基本无害，不报，避免噪音。
    if [[ -e "$path" ]]; then
        local _perm
        _perm="$(stat -c '%a' "$path" 2>/dev/null || echo '')"
        if [[ "$_perm" =~ [2367]$ ]]; then
            echo ">> WARN: profile $path 可被他人(world)写 (mode=$_perm)，存在篡改风险" >&2
        fi
    fi
    local line key rawval val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        rawval="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if ! _stealth_is_profile_key "$key"; then
            echo ">> WARN: profile 跳过未登记 key: $key" >&2
            continue
        fi
        # shellcheck disable=SC2016 # 单引号内容是要识别的危险字面量，不应展开。
        if [[ "$rawval" == *'$('* || "$rawval" == *'`'* || "$rawval" == *'${'* ]]; then
            echo ">> WARN: profile key $key 含命令替换/参数展开构造，已拒绝" >&2
            continue
        fi
        # %q 对空字符串写成两个单引号；它们是编码标记而不是字段内容。其余
        # 值只反转 \X，不经过 shell 解析，避免 eval/source。
        if [[ "$rawval" == "''" ]]; then
            val=""
        else
            val="$(printf '%s' "$rawval" | sed -E 's/\\(.)/\1/g')"
        fi
        printf -v "$key" '%s' "$val"
        _stealth_present_keys["$key"]=1
        if [[ -z "$val" ]]; then
            _stealth_explicit_empty_keys["$key"]=1
        else
            unset '_stealth_explicit_empty_keys[$key]'
        fi
    done < "$path"

    # 老 profile 兼容只补真正“缺失”的 CPU 键。显式空值仍是用户输入，不能
    # 被 := 修复后绕过平台绑定；host-passthrough 也会合法地把未知 part/socket
    # 留空，必须原样保留。
    local _legacy_cpu_field
    local -A _legacy_cpu_defaults=(
        [CPU_QEMU_ARG]=Ryzen3-1200
        [CPU_VENDOR]=AuthenticAMD
        [CPU_NAME]="AMD Ryzen 3 1200 Quad-Core Processor"
        [CPU_MAX_MHZ]=3400
        [CPU_CUR_MHZ]=3100
        [CPU_PART]=YD1200BBM4KAE
        [CPU_PROC_FAMILY]=0x006B
        [CPU_SOCKET]=AM4
        [CPU_MODEL]=Ryzen3-1200
    )
    for _legacy_cpu_field in "${!_legacy_cpu_defaults[@]}"; do
        if [[ -z "${_stealth_present_keys[$_legacy_cpu_field]:-}" ]]; then
            printf -v "$_legacy_cpu_field" '%s' \
                "${_legacy_cpu_defaults[$_legacy_cpu_field]}"
        fi
    done

    # Schema 1 以前的 profile 没有整机平台 ID。继续允许读取是为了不破坏已安装
    # Windows 的身份，但明确标为 legacy；新建 profile 必须由 manifest 生成。
    : "${PLATFORM_SCHEMA_VERSION:=0}"
    : "${PLATFORM_CATALOG_REVISION:=legacy}"
    : "${PLATFORM_ID:=legacy-unversioned}"
    : "${PLATFORM_STATUS:=legacy}"
    : "${PLATFORM_RELEASE_YEAR:=0}"
    : "${COMPONENT_SCHEMA_VERSION:=0}"
    : "${COMPONENT_CATALOG_REVISION:=legacy}"

    # registry 可能为真正旧的 manifest profile 回填 pool ID。迁移 helper 还需
    # 知道该字段在原文件中是否缺失，才能区分旧档与当前 profile 的局部删除。
    local _legacy_boot_pool_id_missing=0
    if [[ -z "${_stealth_present_keys[PLATFORM_BOOT_STORAGE_POOL_ID]:-}" ]]; then
        _legacy_boot_pool_id_missing=1
    fi

    # 统一字段从 host/household compatibility 引入后，旧 schema-1 物理目录
    # profile 尚未持久化这些键。先保证所有白名单变量都有定义，再只对
    # registry kind=manifest 的“缺失键”填入确定性目录默认；显式写入的异常值
    # 不会被修复，稍后的平台绑定会逐字段拒绝。household/host 从不补缺字段。
    local _platform_metadata_field
    for _platform_metadata_field in \
        "${_STEALTH_PLATFORM_METADATA_VARS[@]}" \
        "${_STEALTH_HOST_CPU_BINDING_VARS[@]}"; do
        if ! [[ -v $_platform_metadata_field ]]; then
            printf -v "$_platform_metadata_field" '%s' ""
        fi
    done
    stealth_platform_registry_migrate_profile \
        _stealth_present_keys || return 1
    # 在任何 NVMe 序号/NQN 规范化之前只读识别旧启动盘格式。候选必须同时
    # 满足历史完整元组、按目录 kind 的 cutoff 和显式迁移授权；当前 profile
    # 仅修改可编辑 revision、局部删字段或写空值都不能触发迁移。
    stealth_classify_boot_storage_profile_migration \
        _stealth_present_keys "$_legacy_boot_pool_id_missing" \
        _boot_storage_migration_kind _legacy_boot_storage_serial || return 1

    local _legacy_cpu_topology=4
    [[ "$CPU_NAME" == *Athlon*II*X2* ]] && _legacy_cpu_topology=2
    if [[ -z "${_stealth_present_keys[CPU_CORES]:-}" ]]; then
        CPU_CORES="$_legacy_cpu_topology"
    fi
    if [[ -z "${_stealth_present_keys[CPU_THREADS]:-}" ]]; then
        CPU_THREADS="$_legacy_cpu_topology"
    fi
    if [[ -z "${_stealth_present_keys[CPU_TSC_MHZ]:-}" ]]; then
        CPU_TSC_MHZ="$CPU_CUR_MHZ"
    fi
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        [[ -n "${_stealth_present_keys[CPU_PHYS_BITS]:-}" ]] ||
            CPU_PHYS_BITS=43
        [[ -n "${_stealth_present_keys[CPU_FEATURES]:-}" ]] ||
            CPU_FEATURES=+invtsc,+tsc-deadline,+topoext
    else
        [[ -n "${_stealth_present_keys[CPU_PHYS_BITS]:-}" ]] ||
            CPU_PHYS_BITS=39
        [[ -n "${_stealth_present_keys[CPU_FEATURES]:-}" ]] ||
            CPU_FEATURES=+invtsc,+tsc-deadline
    fi
    if [[ -z "${_stealth_present_keys[CPU_SMBIOS_UPGRADE]:-}" ]]; then
        case "$CPU_SOCKET" in
            AM4)     CPU_SMBIOS_UPGRADE=0x31 ;;
            LGA1151) CPU_SMBIOS_UPGRADE=0x32 ;;
            LGA1155) CPU_SMBIOS_UPGRADE=0x24 ;;
            AM3|AM3+) CPU_SMBIOS_UPGRADE=0x1B ;;
            *)       CPU_SMBIOS_UPGRADE=0x02 ;;
        esac
    fi
    [[ -n "${_stealth_present_keys[CPU_SMBIOS_VOLTAGE]:-}" ]] ||
        CPU_SMBIOS_VOLTAGE=1200
    [[ -n "${_stealth_present_keys[CPU_SMBIOS_EXT_CLOCK]:-}" ]] ||
        CPU_SMBIOS_EXT_CLOCK=100
    [[ -n "${_stealth_present_keys[CPU_SMBIOS_CHARACTERISTICS]:-}" ]] ||
        CPU_SMBIOS_CHARACTERISTICS=0x00EC
    [[ -n "${_stealth_present_keys[CPU_IGPU_PRESENT]:-}" ]] ||
        CPU_IGPU_PRESENT=0
    [[ -n "${_stealth_present_keys[CPU_IGPU_STATE]:-}" ]] ||
        CPU_IGPU_STATE=absent
    [[ -n "${_stealth_present_keys[CPU_IGPU_MODEL]:-}" ]] ||
        CPU_IGPU_MODEL=none
    stealth_fill_profile_tpm_facts _stealth_present_keys || return 1
    if [[ "${STRICT_HARDWARE:-0}" == "1" &&
          "$PLATFORM_SCHEMA_VERSION" == "1" ]]; then
        stealth_verify_profile_identity_inputs \
            _stealth_present_keys "$_boot_storage_migration_kind" || return 1
    fi

    # 老 profile 若缺关键硬件序列号，不能用全 0 / 固定默认值兜底；这里按
    # profile 路径或已有 UUID 稳定派生，保证格式像真实硬件且跨重启不漂移。
    local _identity_key
    if ! [[ "${UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        UUID="$(_stealth_stable_uuid "$path-uuid")"
    fi
    _identity_key="$UUID"
    if ! [[ "${CPU_SERIAL:-}" =~ ^[0-9]{10}$ ]]; then
        CPU_SERIAL="$(_stealth_stable_dec_range "$_identity_key-cpu-serial" 1000000000 9999999999)"
    fi

    # CPU asset tag 也是 SMBIOS Type 4 的 guest 可见字段。老 profile 没有该字段
    # 或被手工改坏时，不再每次启动随机，而是从 CPU_SERIAL/UUID 稳定派生，避免
    # 硬件指纹漂移，也避免把非数字 asset 写进 SMBIOS。
    if ! [[ "${CPU_ASSET:-}" =~ ^[0-9]{4}$ ]]; then
        local _cpu_asset_key _cpu_asset_seed
        _cpu_asset_key="${CPU_SERIAL:-${UUID:-cpu}}"
        _cpu_asset_seed="$(printf '%s' "${_cpu_asset_key}-asset" | cksum)"
        _cpu_asset_seed="${_cpu_asset_seed%% *}"
        CPU_ASSET=$(( 1000 + (_cpu_asset_seed % 9000) ))
    fi

    if ! [[ "${BOARD_SERIAL:-}" =~ ^[A-Z0-9-]{8,20}$ ]]; then
        BOARD_SERIAL="$(_stealth_stable_board_serial "${BOARD_MFR:-ASUSTeK COMPUTER INC.}" "$_identity_key-board")"
    fi
    if ! [[ "${BOARD_ASSET:-}" =~ ^[0-9]{10}$ ]]; then
        BOARD_ASSET="$(_stealth_stable_dec_range "$_identity_key-board-asset" 1000000000 9999999999)"
    fi
    if ! [[ "${SYSTEM_SERIAL:-}" =~ ^[A-Z0-9-]{8,20}$ ]]; then
        SYSTEM_SERIAL="$(_stealth_stable_board_serial "${SYSTEM_MFR:-${BOARD_MFR:-ASUSTeK COMPUTER INC.}}" "$_identity_key-system")"
    fi
    if ! [[ "${SYSTEM_SKU:-}" =~ ^SKU[0-9]{6}$ ]]; then
        SYSTEM_SKU="SKU$(_stealth_stable_dec_range "$_identity_key-sku" 100000 999999)"
    fi
    if ! [[ "${CHASSIS_SERIAL:-}" =~ ^[A-Z0-9-]{8,20}$ ]]; then
        CHASSIS_SERIAL="$(_stealth_stable_board_serial "${BOARD_MFR:-ASUSTeK COMPUTER INC.}" "$_identity_key-chassis")"
    fi
    if ! [[ "${NIC_MAC:-}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || [[ "${NIC_MAC:-}" == 52:54:00:* ]]; then
        NIC_MAC="$(_stealth_stable_mac \
            "$_identity_key-nic" "${NIC_MAC_OUI:-3c:fd:fe}")"
    fi

    # PCI 子系统 ID 老 profile 缺失：按 BOARD_MFR 智能推导每家典型 vendor ID，
    # 避免一律兜回 ASUS 导致"主板是 MSI 但 PCI 子系统报 ASUS"的遗留矛盾。
    # 这样老 VM 不用 reroll 整身份也能修好 PCI 不一致。
    # 新 profile 由 stealth_pick_profile 直接写板厂真实对应值。
    if [[ -z "${BOARD_SUBSYS_VEN:-}" || -z "${BOARD_SUBSYS_DEV:-}" ]]; then
        case "${BOARD_MFR:-}" in
            *Micro-Star*|*MSI*)
                BOARD_SUBSYS_VEN=0x1462; BOARD_SUBSYS_DEV=0x7B49 ;;
            *Gigabyte*)
                BOARD_SUBSYS_VEN=0x1458; BOARD_SUBSYS_DEV=0x5001 ;;
            ASRock*)
                BOARD_SUBSYS_VEN=0x1849; BOARD_SUBSYS_DEV=0x1230 ;;
            *) # ASUS / 未知一律走 ASUS B350-PLUS 默认
                BOARD_SUBSYS_VEN=0x1043; BOARD_SUBSYS_DEV=0x8694 ;;
        esac
    fi

    # 老 profile 只能给出保守兼容值，不能反向声称已经通过 Schema 1 审计。
    : "${BOARD_DIMM_SLOTS:=2}"
    : "${BOARD_MAX_MEMORY_GIB:=32}"
    : "${PCH_MODEL:=legacy-unknown}"
    : "${PCIE_GENERATION:=3}"
    : "${SYSTEM_CHASSIS_TYPE:=0x03}"
    : "${MCH_PCI_VEN:=0x8086}"
    : "${MCH_PCI_DEV:=0x29C0}"
    : "${MCH_REV:=0x02}"
    : "${LPC_PCI_VEN:=0x8086}"
    : "${LPC_PCI_DEV:=0x2918}"
    : "${LPC_REV:=0x02}"
    : "${SMBUS_PCI_VEN:=0x8086}"
    : "${SMBUS_PCI_DEV:=0x2930}"
    : "${SMBUS_REV:=0x02}"
    : "${AHCI_PCI_VEN:=0x8086}"
    : "${AHCI_PCI_DEV:=0x2922}"
    : "${AHCI_REV:=0x02}"
    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        : "${ROOT_PORT_PCI_VEN:=0x8086}"
        : "${ROOT_PORT_PCI_DEV:=0xA338}"
        : "${ROOT_PORT_REV:=0xF0}"
        : "${XHCI_PCI_VEN:=0x8086}"
        : "${XHCI_PCI_DEV:=0xA36D}"
        : "${XHCI_REV:=0x10}"
        : "${AUDIO_CONTROLLER_PCI_VEN:=0x8086}"
        : "${AUDIO_CONTROLLER_PCI_DEV:=0x293E}"
    else
        : "${ROOT_PORT_PCI_VEN:=0x1022}"
        : "${ROOT_PORT_PCI_DEV:=0x1453}"
        : "${ROOT_PORT_REV:=0x00}"
        : "${XHCI_PCI_VEN:=0x1022}"
        : "${XHCI_PCI_DEV:=0x43BB}"
        : "${XHCI_REV:=0x02}"
        : "${AUDIO_CONTROLLER_PCI_VEN:=0x1022}"
        : "${AUDIO_CONTROLLER_PCI_DEV:=0x1457}"
    fi
    : "${NIC_VENDOR:=Intel}"
    : "${NIC_MODEL:=Intel 82574L Gigabit Network Connection}"
    : "${NIC_PCI_VEN:=0x8086}"
    : "${NIC_PCI_DEV:=0x10D3}"
    : "${NIC_SUBSYSTEM_VEN:=0x8086}"
    : "${NIC_SUBSYSTEM_DEV:=0xA01F}"
    : "${NIC_MAC_OUI:=3c:fd:fe}"
    : "${NIC_ATTACHMENT:=add_in}"
    : "${BOARD_NIC_STATE:=disabled_in_bios}"
    : "${AUDIO_VENDOR:=Realtek}"
    : "${AUDIO_CODEC:=ALC887}"
    : "${AUDIO_CODEC_ID:=0x10ec0887}"
    : "${AUDIO_CODEC_REVISION:=0x00100302}"
    : "${AUDIO_CODEC_SUBSYSTEM_ID:=0x104386c7}"
    : "${AUDIO_IDENTITY_FIDELITY:=protocol_identity_only}"
    : "${NVME_MAX_PCIE_GENERATION:=3}"
    : "${NVME_LANES:=4}"
    : "${NVME_BOOT_SUPPORTED:=1}"
    : "${NVME_ATTACHMENT:=legacy-unknown}"

    : "${GPU_VENDOR:=NVIDIA}"
    : "${GPU_NAME:=NVIDIA GeForce GTX 1050}"
    : "${GPU_PCI_VEN:=0x10DE}"
    : "${GPU_PCI_DEV:=0x1C81}"
    : "${GPU_RAM_MB:=2048}"
    : "${GPU_BIOS:=Version 86.07.48.00.38}"
    : "${GPU_REV:=0xA1}"
    : "${GPU_IDENTITY_FIDELITY:=label_only_out_of_scope}"
    stealth_fill_legacy_gpu_spec_defaults || return 1

    : "${NVME_COMPONENT_ID:=samsung-970-pro-512gb}"
    : "${NVME_MODEL:=Samsung SSD 970 PRO 512GB}"
    : "${NVME_FIRMWARE:=1B2QEXP7}"
    if ! [[ "${NVME_SERIAL:-}" =~ ^S[A-Z0-9]{3}N[A-Z0-9]{9}$ ]]; then
        NVME_SERIAL="S$(_stealth_stable_hex "$_identity_key-nvme-prefix" 3)N$(_stealth_stable_hex "$_identity_key-nvme-suffix" 9)"
    fi

    # 老 profile 没 NVME_SIZE_BYTES 字段：按 NVME_MODEL 名字智能推导，
    # 让历史磁盘容量跟广告容量自洽，避免再次出现 1TB 型号 + 512GB 实盘的 stealth 矛盾。
    # 匹配关键词不命中时兜底 512GB（老 start-vm.sh 行为）。
    if [[ -z "${NVME_SIZE_BYTES:-}" ]]; then
        case "$NVME_MODEL" in
            *1TB*)   NVME_SIZE_BYTES=1000204886016 ;;
            *2TB*)   NVME_SIZE_BYTES=2000398934016 ;;
            *500GB*) NVME_SIZE_BYTES=500107862016 ;;
            *512GB*) NVME_SIZE_BYTES=512110190592 ;;
            *256GB*) NVME_SIZE_BYTES=256060514304 ;;
            *)       NVME_SIZE_BYTES=512000000000 ;;
        esac
    fi
    : "${NVME_PCI_VEN:=0x144D}"
    : "${NVME_PCI_DEV:=0xA804}"
    : "${NVME_SUBSYS_VEN:=0x144D}"
    : "${NVME_SUBSYS_DEV:=0xA801}"
    if [[ "$_boot_storage_migration_kind" == legacy-*-v1 ]]; then
        # v1 的厂商域名 NQN 与旧序号已经在迁移前按历史元组验证；显式迁移后
        # 内存态统一转为当前 UUID NQN，再执行无例外的身份和组件绑定。
        NVME_SUBNQN_TEMPLATE="nqn.2014-08.org.nvmexpress:uuid:{uuid}"
    fi
    : "${NVME_SUBNQN_TEMPLATE:=nqn.2014-08.org.nvmexpress:uuid:{uuid}}"
    local _expected_nvme_subnqn
    _expected_nvme_subnqn="${NVME_SUBNQN_TEMPLATE//\{uuid\}/$UUID}"
    if [[ "${NVME_SUBNQN:-}" != "$_expected_nvme_subnqn" ]]; then
        NVME_SUBNQN="$_expected_nvme_subnqn"
    fi

    # 新 C 层只实现这一套已核验的 Samsung 控制器。旧 profile 若声称其它型号，
    # 不能再用 a804 行为强行启动；要求显式 reroll，并在启动器后续检查磁盘虚拟容量。
    if [[ "$NVME_MODEL|$NVME_FIRMWARE|$NVME_SIZE_BYTES" != \
          "Samsung SSD 970 PRO 512GB|1B2QEXP7|512110190592" ]]; then
        echo "ERROR: profile 使用未实现的 NVMe bundle: $NVME_MODEL / $NVME_FIRMWARE / $NVME_SIZE_BYTES" >&2
        echo "       当前仅支持 970 PRO 512GB；请备份后显式 reroll，并确认磁盘虚拟容量。" >&2
        return 1
    fi

    stealth_apply_boot_storage_profile_migration \
        _stealth_present_keys "$_boot_storage_migration_kind" \
        "$_legacy_boot_storage_serial" || return 1
    if [[ "${STRICT_HARDWARE:-0}" == "1" &&
          "$PLATFORM_SCHEMA_VERSION" == "1" &&
          "$_boot_storage_migration_kind" != none ]]; then
        # legacy-v1 只在原始输入校验阶段获得窄例外；规范化后的 NVMe 身份必须
        # 再按当前规则验证，随后仍会进入完整 platform/component binding。
        stealth_verify_profile_identity_inputs _stealth_present_keys || return 1
    fi

    : "${MEM_MFR:=Crucial}"
    : "${MEM_PART_2G:=CT2G4DFS624A}"
    : "${MEM_PART_4G:=CT4G4DFS824A}"
    # 颗粒额定速率：老 profile 缺 → 按 part number 编码推导(26=2666/24=2400/-CRC=2400)，
    # 推不出兜 2666(与默认 Kingston HyperX 2666 一致)。报告速率再 min(CPU 平台上限)。
    if [[ -z "${MEM_RATED:-}" ]]; then
        case "${MEM_PART_4G:-}${MEM_PART_2G:-}" in
            *-CRC*|*24N*|*DFS624*|*DFS824*) MEM_RATED=2400 ;;
            *26N*|*266*|*C16F*)             MEM_RATED=2666 ;;
            *)                              MEM_RATED=2666 ;;
        esac
    fi

    case "$CPU_SOCKET" in
        AM3|AM3+|FM2+|LGA1155)
            : "${MEM_TYPE:=DDR3}"
            : "${MEM_VOLTAGE_MV:=1500}" ;;
        *)
            : "${MEM_TYPE:=DDR4}"
            : "${MEM_VOLTAGE_MV:=1200}" ;;
    esac
    : "${MEM_CHANNELS:=2}"
    : "${MEM_MAX_MTS:=$MEM_RATED}"
    : "${MEM_ALLOWED_MTS:=$MEM_MAX_MTS}"
    # 中文注释：旧 profile 只有 MEM_RATED，兼容读取时可确定性补齐；严格的
    # schema-1 profile 则在末尾要求两个新字段原本就存在，避免篡改后被默认值掩盖。
    : "${MEM_RATED_MTS:=$MEM_RATED}"
    if [[ "$MEM_RATED" != "$MEM_RATED_MTS" ]]; then
        echo "ERROR: profile 的 MEM_RATED 与 MEM_RATED_MTS 自相矛盾" >&2
        return 1
    fi
    if ! [[ "$MEM_RATED_MTS" =~ ^[0-9]+$ && "$MEM_MAX_MTS" =~ ^[0-9]+$ ]] ||
       (( MEM_RATED_MTS <= 0 || MEM_MAX_MTS <= 0 )); then
        echo "ERROR: profile 的内存额定值或平台上限不是正整数" >&2
        return 1
    fi
    if [[ -z "${MEM_CONFIGURED_MTS:-}" ]]; then
        if (( MEM_RATED_MTS < MEM_MAX_MTS )); then
            MEM_CONFIGURED_MTS="$MEM_RATED_MTS"
        else
            MEM_CONFIGURED_MTS="$MEM_MAX_MTS"
        fi
    fi
    if ! [[ "$MEM_CONFIGURED_MTS" =~ ^[0-9]+$ ]] ||
       (( MEM_RATED_MTS <= 0 || MEM_CONFIGURED_MTS <= 0 ||
          MEM_CONFIGURED_MTS > MEM_RATED_MTS ||
          MEM_CONFIGURED_MTS > MEM_MAX_MTS )) ||
       [[ ",$MEM_ALLOWED_MTS," != *",$MEM_CONFIGURED_MTS,"* ]]; then
        echo "ERROR: profile 内存额定/配置速率不可能: rated=$MEM_RATED_MTS configured=$MEM_CONFIGURED_MTS max=$MEM_MAX_MTS allowed=$MEM_ALLOWED_MTS" >&2
        return 1
    fi
    : "${MEM_RANK:=1}"
    local _memory_geometry_key _memory_geometry_key_count=0
    for _memory_geometry_key in \
        MEM_RANK_2G MEM_DEVICE_WIDTH_2G MEM_RANK_4G MEM_DEVICE_WIDTH_4G; do
        [[ -n "${_stealth_present_keys[$_memory_geometry_key]:-}" ]] &&
            ((_memory_geometry_key_count += 1))
    done
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" &&
          "$_memory_geometry_key_count" != 0 &&
          "$_memory_geometry_key_count" != 4 ]]; then
        echo "ERROR: schema-1 profile 的 DIMM 几何字段不完整" >&2
        return 1
    fi
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" &&
          "$_memory_geometry_key_count" == 0 ]] ||
       [[ "$PLATFORM_SCHEMA_VERSION" != "1" &&
          (-z "${MEM_RANK_2G:-}" || -z "${MEM_DEVICE_WIDTH_2G:-}" ||
           -z "${MEM_RANK_4G:-}" || -z "${MEM_DEVICE_WIDTH_4G:-}") ]]; then
        local _memory_geometry
        if _memory_geometry="$(stealth_memory_catalog_geometry \
                "$MEM_MFR" "$MEM_PART_2G" "$MEM_PART_4G" "$MEM_RATED")"; then
            IFS='|' read -r \
                MEM_RANK_2G MEM_DEVICE_WIDTH_2G \
                MEM_RANK_4G MEM_DEVICE_WIDTH_4G <<<"$_memory_geometry"
        elif [[ "$PLATFORM_SCHEMA_VERSION" != "1" ]] &&
             _memory_geometry="$(stealth_memory_legacy_catalog_geometry \
                "$MEM_MFR" "$MEM_PART_2G" "$MEM_PART_4G" "$MEM_RATED")"; then
            IFS='|' read -r \
                MEM_RANK_2G MEM_DEVICE_WIDTH_2G \
                MEM_RANK_4G MEM_DEVICE_WIDTH_4G <<<"$_memory_geometry"
        elif [[ "$PLATFORM_SCHEMA_VERSION" != "1" &&
                "$MEM_PART_2G|$MEM_PART_4G" == \
                "CT2G4DFS6266|CT4G4DFS8266" ]]; then
            # 退役目录中的 2GB 料号不可核验；仅为非严格 legacy 迁移保留
            # 4GB CT4G4DFS8266 几何，schema-1 严格 profile 一律拒绝。
            MEM_RANK_2G=0
            MEM_DEVICE_WIDTH_2G=0
            MEM_RANK_4G=1
            MEM_DEVICE_WIDTH_4G=8
        else
            # 非严格 legacy profile 没有目录证据时沿用历史 x8 回退；
            # schema 1 会在下方精确目录校验中拒绝该组合。
            MEM_RANK_2G="$MEM_RANK"
            MEM_DEVICE_WIDTH_2G=8
            MEM_RANK_4G="$MEM_RANK"
            MEM_DEVICE_WIDTH_4G=8
        fi
    fi
    if ! [[ "$MEM_RANK_2G" =~ ^[0-4]$ &&
            "$MEM_RANK_4G" =~ ^[1-4]$ ]] ||
       [[ "$MEM_RANK_2G" == 0 && "$MEM_DEVICE_WIDTH_2G" != 0 ]] ||
       [[ "$MEM_RANK_2G" != 0 && "$MEM_DEVICE_WIDTH_2G" == 0 ]] ||
       [[ "$MEM_DEVICE_WIDTH_2G" != 0 &&
          "$MEM_DEVICE_WIDTH_2G" != 4 &&
          "$MEM_DEVICE_WIDTH_2G" != 8 &&
          "$MEM_DEVICE_WIDTH_2G" != 16 &&
          "$MEM_DEVICE_WIDTH_2G" != 32 ]] ||
       [[ "$MEM_DEVICE_WIDTH_4G" != 4 &&
          "$MEM_DEVICE_WIDTH_4G" != 8 &&
          "$MEM_DEVICE_WIDTH_4G" != 16 &&
          "$MEM_DEVICE_WIDTH_4G" != 32 ]]; then
        echo "ERROR: profile 的 DIMM rank/device-width 非法" >&2
        return 1
    fi
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" ]] &&
       ! stealth_memory_profile_catalog_contains \
            "$MEM_MFR" "$MEM_PART_2G" "$MEM_PART_4G" "$MEM_RATED" \
            "$MEM_RANK_2G" "$MEM_DEVICE_WIDTH_2G" \
            "$MEM_RANK_4G" "$MEM_DEVICE_WIDTH_4G"; then
        echo "ERROR: profile 的内存料号/几何不在已核验硬件目录中" >&2
        return 1
    fi
    : "${MEM_MODULE_MB:=2048,4096}"
    : "${MEM_ALLOWED_TOTAL_MB:=2048,4096,8192}"
    : "${MEM_MAX_CAPACITY_MB:=$(( BOARD_MAX_MEMORY_GIB * 1024 ))}"

    # MEM_SERIAL 老 profile 没这字段：用 UUID 派生 8 字符十六进制，
    # 保证**同一 VM 跨重启 SN 不变**（即便没 reroll，老 VM 也不再每次启动漂移）。
    # 不用纯随机回填——那会让升级后第一次启动仍然换 SN，与"持久化"语义不符。
    # 用 UUID 的 sha256 前 8 字符做确定性派生：UUID 跨 VM 唯一，SN 自然也唯一。
    if ! [[ "${MEM_SERIAL:-}" =~ ^[0-9A-F]{8}$ ]] \
        || [[ "${MEM_SERIAL:-}" == "00000000" || "${MEM_SERIAL:-}" == "00000001" ]]; then
        MEM_SERIAL="$(_stealth_stable_hex "$_identity_key-mem" 8)"
    fi

    # MEM_TOTAL_MB 老 profile 没有：留空 → start-vm.sh 退回历史默认 4096 MiB。
    # 不擅自把老 VM 升到 8GB（改内存总量 = 改硬件画像，需用户显式 --ram= 或在
    # profile 里写 MEM_TOTAL_MB）。新 profile 由 stealth_pick_profile 写 8192。
    : "${MEM_TOTAL_MB:=}"

    # 显示器 / 键盘 / 鼠标 / 数位板：老 profile 退化为 QEMU patch 历史默认值
    # （Samsung S24F350F / Microsoft Wired Keyboard 600 / Microsoft USB Optical
    # Mouse / HUION PenTablet）。配合 patch 0009/0010 后默认仍然生效。
    : "${EDID_COMPONENT_ID:=samsung-s24f350}"
    : "${EDID_VENDOR:=SAM}"
    : "${EDID_NAME:=S24F350}"
    : "${EDID_WIDTH_MM:=521}"
    : "${EDID_HEIGHT_MM:=293}"
    if ! [[ "${EDID_SERIAL:-}" =~ ^[A-Z0-9]{8,12}$ ]]; then
        EDID_SERIAL="H4ZK$(_stealth_stable_hex "$_identity_key-edid" 8)"
    fi
    : "${EDID_PRODUCT_ID:=0x0F65}"
    : "${EDID_MANUFACTURE_WEEK:=32}"
    : "${EDID_MANUFACTURE_YEAR:=2018}"
    : "${EDID_VIDEO_INPUT:=0xA3}"
    : "${EDID_MIN_VFREQ_HZ:=56}"
    : "${EDID_MAX_VFREQ_HZ:=75}"
    : "${EDID_MIN_HFREQ_KHZ:=30}"
    : "${EDID_MAX_HFREQ_KHZ:=81}"
    : "${EDID_MAX_PIXEL_CLOCK_MHZ:=149}"
    : "${EDID_SECONDARY_XRES:=1600}"
    : "${EDID_SECONDARY_YRES:=900}"
    : "${EDID_SECONDARY_REFRESH_RATE:=60000}"

    : "${KBD_COMPONENT_ID:=microsoft-wired-keyboard-600}"
    : "${KBD_VID:=0x045E}"
    : "${KBD_PID:=0x0750}"
    : "${KBD_MFR:=Microsoft}"
    : "${KBD_PRODUCT:=Microsoft Wired Keyboard 600}"
    if ! [[ "${KBD_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]]; then
        KBD_SERIAL="KB$(_stealth_stable_hex "$_identity_key-kbd" 6)"
    fi
    : "${KBD_BCD_DEVICE:=0x0163}"
    : "${KBD_DESCRIPTOR_FIDELITY:=identity_only_generic_report}"

    : "${MOUSE_COMPONENT_ID:=microsoft-usb-optical-mouse}"
    : "${MOUSE_VID:=0x045E}"
    : "${MOUSE_PID:=0x00CB}"
    : "${MOUSE_MFR:=Microsoft}"
    : "${MOUSE_PRODUCT:=Microsoft USB Optical Mouse}"
    if ! [[ "${MOUSE_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]]; then
        MOUSE_SERIAL="MS$(_stealth_stable_hex "$_identity_key-mouse" 6)"
    fi
    : "${MOUSE_BCD_DEVICE:=0x0163}"
    : "${MOUSE_DESCRIPTOR_FIDELITY:=identity_only_generic_report}"

    : "${TABLET_COMPONENT_ID:=qemu-generic-usb-tablet}"
    : "${TABLET_VID:=0x0627}"
    : "${TABLET_PID:=0x0001}"
    : "${TABLET_MFR:=not_exposed}"
    : "${TABLET_PRODUCT:=QEMU USB Tablet}"
    if ! [[ "${TABLET_SERIAL:-}" =~ ^[A-Z0-9]{4,12}$ ]]; then
        TABLET_SERIAL="TB$(_stealth_stable_hex "$_identity_key-tablet" 6)"
    fi
    : "${TABLET_BCD_DEVICE:=0x0000}"
    : "${TABLET_DESCRIPTOR_FIDELITY:=generic_virtual_only}"

    # profile 可由用户编辑，因此不能用其自报的 PLATFORM_STATUS 决定授权。
    # schema 1 必须从统一 registry 查询物理、household 或 host 目录真值；把
    # compatibility 改写成 supported、改写 ID 或切换目录种类都不能绕过授权。
    local _catalog_platform_status=""
    if [[ "$PLATFORM_SCHEMA_VERSION" != "0" && "$PLATFORM_SCHEMA_VERSION" != "1" ]]; then
        echo "ERROR: profile schema 不受支持: $PLATFORM_SCHEMA_VERSION" >&2
        return 1
    fi
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" ]]; then
        if ! _catalog_platform_status="$(stealth_platform_registry_status "$PLATFORM_ID")"; then
            echo "ERROR: profile 指向 registry 中不存在或不可读取的平台: $PLATFORM_ID" >&2
            return 1
        fi
        if [[ "$PLATFORM_STATUS" != "$_catalog_platform_status" ]]; then
            echo "ERROR: profile 平台状态与 manifest 不一致（由统一 registry 校验）: profile=$PLATFORM_STATUS registry=$_catalog_platform_status" >&2
            return 1
        fi
    elif [[ "$PLATFORM_STATUS" == "supported" || "$PLATFORM_STATUS" == "compatibility" ]]; then
        # 当前受控状态只属于 schema 1。旧 schema 若自报 supported/compatibility，
        # 无论 STRICT_HARDWARE 如何都拒绝，避免同时降级 schema 和伪改状态。
        echo "ERROR: profile 状态 $PLATFORM_STATUS 必须来自 schema 1 manifest" >&2
        return 1
    elif [[ -n "${_stealth_present_keys[PLATFORM_ID]:-}" ]] \
        && stealth_platform_registry_status "$PLATFORM_ID" >/dev/null 2>&1; then
        # 即使攻击者把状态改成 legacy，只要显式 ID 仍命中当前 manifest，也不能
        # 把已绑定身份降级成无绑定旧 profile 后走非严格路径。
        echo "ERROR: profile 平台 $PLATFORM_ID 已由 manifest 管理，不能降级 schema" >&2
        return 1
    fi
    if [[ "$PLATFORM_SCHEMA_VERSION" != "1" \
          && "${STRICT_HARDWARE:-0}" != "1" \
          && "${ALLOW_LEGACY_PROFILE:-0}" != "1" ]]; then
        # 删除全部 PLATFORM_* 元数据后，加载器无法区分真旧文件与被伪降级的
        # compatibility profile。非严格模式因此也必须有独立显式授权，不能只靠
        # STRICT_HARDWARE=0 裸加载任意无绑定身份。
        echo "ERROR: legacy profile 的非严格诊断加载必须显式追加 --allow-legacy-profile" >&2
        return 1
    fi

    # 严格模式默认只接受 supported。compatibility 必须有独立 allow 授权；可选的
    # 平台 ID 只做精确断言，未提供时使用 profile 已持久化的 manifest ID。这只承认
    # Q35 machine 行为边界，不会跳过下方平台/组件事实绑定、KVM、所请求 TPM 或
    # 磁盘检查。旧 profile 即使被兼容默认值补齐也仍须显式 reroll。
    local _profile_platform_status_allowed=0
    if [[ "$_catalog_platform_status" == "supported" ]]; then
        _profile_platform_status_allowed=1
    elif [[ "$_catalog_platform_status" == "compatibility" ]]; then
        # compatibility 是独立授权维度；即使 STRICT_HARDWARE=0 也必须显式 allow，
        # 否则全局诊断开关会意外变成绕过持久化平台授权的后门。
        if [[ "$PLATFORM_SCHEMA_VERSION" != "1" ]]; then
            echo "ERROR: compatibility profile 必须来自 schema 1 manifest" >&2
            return 1
        fi
        if [[ "${ALLOW_PLATFORM_COMPATIBILITY:-0}" != "1" ]]; then
            echo "ERROR: compatibility profile 必须显式追加 --allow-platform-compatibility" >&2
            return 1
        fi
        if [[ -n "${STEALTH_PLATFORM_ID:-}" && "$STEALTH_PLATFORM_ID" != "$PLATFORM_ID" ]]; then
            echo "ERROR: profile 平台 $PLATFORM_ID 与指定平台 $STEALTH_PLATFORM_ID 不一致。" >&2
            echo "       如确需更换整机身份，请备份后显式追加 --reroll。" >&2
            return 1
        fi
        _profile_platform_status_allowed=1
    fi
    if [[ "${STRICT_HARDWARE:-0}" == "1" ]] \
        && { [[ "$PLATFORM_SCHEMA_VERSION" != "1" ]] ||
             [[ "$_profile_platform_status_allowed" != "1" ]]; }; then
        echo "ERROR: 严格模式拒绝 profile 平台状态 schema=$PLATFORM_SCHEMA_VERSION status=$PLATFORM_STATUS" >&2
        echo "       无 TPM state 可备份后用 --reroll；已有 state 请新建 instance 或先迁移密钥。" >&2
        return 1
    fi
    if [[ "${STRICT_HARDWARE:-0}" == "1" ]] && \
       { [[ -z "${_stealth_present_keys[MEM_RATED_MTS]:-}" ]] ||
         [[ -z "${_stealth_present_keys[MEM_CONFIGURED_MTS]:-}" ]] ||
         [[ -n "${_stealth_explicit_empty_keys[MEM_RATED_MTS]:-}" ]] ||
         [[ -n "${_stealth_explicit_empty_keys[MEM_CONFIGURED_MTS]:-}" ]]; }; then
        echo "ERROR: 严格 profile 缺少 MEM_RATED_MTS/MEM_CONFIGURED_MTS；请显式 reroll" >&2
        return 1
    fi
    # schema 1 始终执行完整平台事实绑定；STRICT_HARDWARE=0 只用于旧 profile 诊断，
    # 不能使当前 schema 信任可编辑的 ID/status 或混搭另一平台的 CPU/主板字段。
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" ]] \
        && ! stealth_verify_profile_platform_binding \
            _stealth_present_keys _stealth_explicit_empty_keys; then
        echo "       profile 的平台事实已缺失或被篡改；请核对后显式 reroll 整套身份。" >&2
        return 1
    fi
    if [[ "${STRICT_HARDWARE:-0}" == "1" ]] \
        && ! stealth_verify_profile_component_binding \
            _stealth_present_keys _stealth_explicit_empty_keys \
            "$_boot_storage_migration_kind" "$_legacy_boot_storage_serial"; then
        echo "       profile 的可更换部件事实已缺失或被篡改；请显式 reroll 整套身份。" >&2
        return 1
    fi

    local v
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        # shellcheck disable=SC2163 # v 的值才是白名单变量名，需要间接 export。
        export "$v"
    done
}
