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
# shellcheck source=stealth-storage-identity.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-storage-identity.sh"
# shellcheck source=stealth-tpm-profile.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-tpm-profile.sh"
# shellcheck source=stealth-identity-verify.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-identity-verify.sh"
# shellcheck source=stealth-memory-profile.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-memory-profile.sh"

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
    GPU_COMPONENT_ID GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    GPU_MEMORY_TYPE GPU_MEMORY_BUS_WIDTH_BITS GPU_BASE_CLOCK_KHZ GPU_BOOST_CLOCK_KHZ GPU_MEMORY_CLOCK_KHZ GPU_SLI_SUPPORTED
    GPU_BOARD_PARTNER GPU_PART_NUMBER GPU_SUBSYS_VEN GPU_SUBSYS_DEV
    GPU_CARRIER_VEN GPU_CARRIER_DEV GPU_IDENTITY_FIDELITY
    NVME_COMPONENT_ID NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES NVME_PCI_VEN NVME_PCI_DEV NVME_SUBSYS_VEN NVME_SUBSYS_DEV NVME_SUBNQN_TEMPLATE NVME_SUBNQN
    BOOT_STORAGE_CATALOG_REVISION BOOT_STORAGE_COMPONENT_ID BOOT_STORAGE_MANUFACTURER
    BOOT_STORAGE_MODEL BOOT_STORAGE_PART_NUMBER BOOT_STORAGE_FIRMWARE
    BOOT_STORAGE_SIZE_BYTES BOOT_STORAGE_INTERFACE BOOT_STORAGE_SERIAL
    MEM_FAMILY_ID MEM_MODULE_ID MEM_SELECTED_MODULE_MB MEM_MODULE_COUNT MEM_SPD_EE1004
    MEM_MFR MEM_PART_2G MEM_PART_4G MEM_RATED MEM_RATED_MTS MEM_CONFIGURED_MTS MEM_SERIAL MEM_TOTAL_MB MEM_TYPE MEM_CHANNELS MEM_MAX_MTS MEM_ALLOWED_MTS
    MEM_VOLTAGE_MV MEM_RANK MEM_RANK_2G MEM_DEVICE_WIDTH_2G MEM_RANK_4G MEM_DEVICE_WIDTH_4G
    MEM_MODULE_MB MEM_ALLOWED_TOTAL_MB MEM_MAX_CAPACITY_MB
    EDID_COMPONENT_ID EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL EDID_BINARY_SERIAL EDID_REVISION EDID_PRODUCT_ID EDID_MANUFACTURE_WEEK EDID_MANUFACTURE_YEAR EDID_VIDEO_INPUT
    EDID_MIN_VFREQ_HZ EDID_MAX_VFREQ_HZ EDID_MIN_HFREQ_KHZ EDID_MAX_HFREQ_KHZ EDID_MAX_PIXEL_CLOCK_MHZ EDID_SECONDARY_XRES EDID_SECONDARY_YRES EDID_SECONDARY_REFRESH_RATE
    EDID_SECONDARY_PIXEL_CLOCK_KHZ EDID_SECONDARY_HFRONT EDID_SECONDARY_HSYNC EDID_SECONDARY_HBLANK EDID_SECONDARY_VFRONT EDID_SECONDARY_VSYNC EDID_SECONDARY_VBLANK
    EDID_SECONDARY_HSYNC_POSITIVE EDID_SECONDARY_VSYNC_POSITIVE
    EDID_SECONDARY_WIDTH_MM EDID_SECONDARY_HEIGHT_MM
    KBD_COMPONENT_ID KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL KBD_BCD_DEVICE KBD_DESCRIPTOR_FIDELITY
    MOUSE_COMPONENT_ID MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL MOUSE_BCD_DEVICE MOUSE_DESCRIPTOR_FIDELITY
    TABLET_COMPONENT_ID TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL TABLET_BCD_DEVICE TABLET_DESCRIPTOR_FIDELITY
)

_STEALTH_PROFILE_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stealth-profile-save.sh
source "$_STEALTH_PROFILE_IO_DIR/stealth-profile-save.sh"

# “是否存在 profile 节点”与“内容是否有效”必须分开。空文件、目录、断裂链接
# 都不是首次创建：调用方应进入严格 load 并失败，不能把异常节点当成不存在后
# 自动生成一套新身份。
stealth_have_profile() {
    [[ -e "$1" || -L "$1" ]]
}

_stealth_is_profile_key() {
    local k="$1" w
    for w in "${_STEALTH_PROFILE_VARS[@]}"; do
        [[ "$k" == "$w" ]] && return 0
    done
    return 1
}

# 扫描完整文件后才返回单字段，确保调用方不会看到“前一个值”，而完整 loader
# 又看到“后一个值”。重复检查覆盖所有白名单 key，而不只覆盖本次请求的 key：
# 只要 profile 内任一受控事实重复，整个单字段读取也必须 fail-closed。
_stealth_profile_scan_unique_key() {
    local path="$1" want="${2:-}" line key rawval value found=0
    local -A seen=()

    [[ -r "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        _stealth_is_profile_key "$key" || continue
        if [[ -n "${seen[$key]:-}" ]]; then
            echo "ERROR: profile 含重复白名单 key: $key" >&2
            return 1
        fi
        seen["$key"]=1
        [[ -n "$want" && "$key" == "$want" ]] || continue

        rawval="${line#*=}"
        # shellcheck disable=SC2016 # 单引号内容是要识别的危险字面量，不应展开。
        if [[ "$rawval" == *'$('* || "$rawval" == *'`'* || "$rawval" == *'${'* ]]; then
            return 1
        fi
        if [[ "$rawval" == "''" ]]; then
            value=""
        else
            value="$(printf '%s' "$rawval" | sed -E 's/\\(.)/\1/g')" ||
                return 1
        fi
        found=1
    done < "$path"

    [[ -z "$want" ]] && return 0
    (( found == 1 )) || return 1
    printf '%s' "$value"
}

# 安全读取 profile 单个字段（P1#2）：供只取少数字段的 host 工具用，替代
# `source`/`eval grep`。命中且安全则打印值并 return 0；未登记 key / 文件不可读 /
# 未找到 / 值含命令替换·反引号·参数展开 / 任一白名单 key 重复则 return 1
# （绝不执行 profile 内代码）。
stealth_profile_get() {
    local want="$1" path="$2"
    _stealth_is_profile_key "$want" || return 1
    _stealth_profile_scan_unique_key "$path" "$want"
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

_stealth_stable_monitor_serial() {
    local component_id="$1" key="$2" spec kind length serial decimal
    local letters digit alnum
    spec="$(stealth_component_monitor_serial_spec "$component_id")" || return 1
    IFS='|' read -r kind length <<<"$spec"
    case "$kind" in
        samsung_h4zmc_decimal5)
            printf -v decimal '%05d' \
                "$(_stealth_stable_dec_range "$key-decimal" 0 99999)"
            serial="H4ZMC${decimal}"
            ;;
        aoc_upper_alnum7_decimal6)
            printf -v decimal '%06d' \
                "$(_stealth_stable_dec_range "$key-decimal" 0 999999)"
            letters="$(_stealth_stable_hex "$key-letters" 4 |
                tr '0123456789ABCDEF' 'GHIJKLMNOPABCDEF')"
            digit="$(_stealth_stable_dec_range "$key-digit" 0 9)"
            alnum="$(_stealth_stable_hex "$key-alnum" 1)"
            serial="${letters}${digit}${alnum}A${decimal}"
            ;;
        xiaomi_29200_label_slash_removed_decimal)
            printf -v decimal '%08d' \
                "$(_stealth_stable_dec_range "$key-decimal" 0 99999999)"
            serial="29200${decimal}"
            ;;
        lenovo_urb_upper_alnum)
            serial="URB$(_stealth_stable_hex "$key" 5)"
            ;;
        *)
            echo "ERROR: 未知显示器序列号策略: $kind" >&2
            return 1
            ;;
    esac
    [[ ${#serial} -eq length ]] || return 1
    printf '%s\n' "$serial"
}

_stealth_stable_uuid() {
    local key="$1" h
    h="$(_stealth_stable_hex "$key" 32 | tr '[:upper:]' '[:lower:]')"
    echo "${h:0:8}-${h:8:4}-4${h:12:3}-8${h:16:3}-${h:20:12}"
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
    local _profile_hash_before _profile_hash_after
    _STEALTH_MEMORY_PROFILE_MIGRATION_KIND=none
    _STEALTH_STORAGE_PROFILE_MIGRATION_KIND=none
    _STEALTH_LOADED_PROFILE_HASH=
    _STEALTH_LOADED_PROFILE_PATH=

    case "${ALLOW_STORAGE_PROFILE_MIGRATION:-0}" in
        0|1) ;;
        *)
            echo "ERROR: ALLOW_STORAGE_PROFILE_MIGRATION 必须是 0 或 1" >&2
            return 1
            ;;
    esac

    [[ -f "$path" && ! -L "$path" ]] || {
        echo "ERROR: profile 必须是普通文件且不能是符号链接: $path" >&2
        return 1
    }
    _profile_hash_before="$(stealth_profile_sha256 "$path")" || {
        echo "ERROR: 无法计算 profile 加载摘要: $path" >&2
        return 1
    }
    # 必须在赋值任何全局 profile 变量前完成重复 key 门禁。这样失败既不会出现
    # first-wins/last-wins 分叉，也不会把重复项之前的部分事实泄漏给调用方。
    _stealth_profile_scan_unique_key "$path" "" || return 1

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
    _profile_hash_after="$(stealth_profile_sha256 "$path")" || {
        echo "ERROR: profile 解析期间不可读或被替换: $path" >&2
        return 1
    }
    if [[ "$_profile_hash_after" != "$_profile_hash_before" ]]; then
        echo "ERROR: profile 在解析期间发生变化，拒绝使用不一致快照" >&2
        return 1
    fi

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
            LGA2011) CPU_SMBIOS_UPGRADE=0x26 ;;
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
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" ]]; then
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
    if [[ "$_boot_storage_migration_kind" == samsung-970-pro-catalog-v2 ||
          "$_boot_storage_migration_kind" == legacy-nvme-v2 ||
          "$_boot_storage_migration_kind" == legacy-sata-v2 ]]; then
        # 保留旧序列的全部 14 个字符，只从稳定 UUID 派生一个附加字符；相比重抽
        # 整个序列，这会把必要的 Guest 身份变化压缩到真实规格要求的最小范围。
        local _old_nvme_serial="${_legacy_boot_storage_serial:-$NVME_SERIAL}"
        NVME_SERIAL="${_old_nvme_serial}$(
            _stealth_stable_hex "$_identity_key-samsung-serial-v2" 1
        )"
        NVME_PCI_DEV=0xA808
    elif [[ "$_boot_storage_migration_kind" == legacy-nvme-v1 ||
            "$_boot_storage_migration_kind" == legacy-sata-v1 ]]; then
        # v1 的十二字符序列稍后会由当前品牌生成器规范化；PCI device 同样必须
        # 从历史错误 A804 切到真实 970 PRO A808，才能进入当前原子目录校验。
        NVME_PCI_DEV=0xA808
    fi
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

    if ! stealth_board_serial_is_compatible \
            "${BOARD_MFR:-ASUSTeK COMPUTER INC.}" "${BOARD_SERIAL:-}"; then
        BOARD_SERIAL="$(_stealth_stable_board_serial \
            "${BOARD_MFR:-ASUSTeK COMPUTER INC.}" "$_identity_key-board")" ||
            return 1
    fi
    if ! [[ "${BOARD_ASSET:-}" =~ ^[0-9]{10}$ ]]; then
        BOARD_ASSET="$(_stealth_stable_dec_range "$_identity_key-board-asset" 1000000000 9999999999)"
    fi
    if ! stealth_board_serial_is_compatible \
            "${SYSTEM_MFR:-${BOARD_MFR:-ASUSTeK COMPUTER INC.}}" \
            "${SYSTEM_SERIAL:-}"; then
        SYSTEM_SERIAL="$(_stealth_stable_board_serial \
            "${SYSTEM_MFR:-${BOARD_MFR:-ASUSTeK COMPUTER INC.}}" \
            "$_identity_key-system")" || return 1
    fi
    if ! [[ "${SYSTEM_SKU:-}" =~ ^SKU[0-9]{6}$ ]]; then
        SYSTEM_SKU="SKU$(_stealth_stable_dec_range "$_identity_key-sku" 100000 999999)"
    fi
    if ! stealth_board_serial_is_compatible \
            "${BOARD_MFR:-ASUSTeK COMPUTER INC.}" \
            "${CHASSIS_SERIAL:-}"; then
        CHASSIS_SERIAL="$(_stealth_stable_board_serial \
            "${BOARD_MFR:-ASUSTeK COMPUTER INC.}" \
            "$_identity_key-chassis")" || return 1
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
    stealth_fill_legacy_gpu_spec_defaults || return 1
    : "${GPU_IDENTITY_FIDELITY:=label_only_out_of_scope}"

    : "${NVME_COMPONENT_ID:=samsung-970-pro-512gb}"
    : "${NVME_MODEL:=Samsung SSD 970 PRO 512GB}"
    : "${NVME_FIRMWARE:=1B2QEXP7}"
    if ! stealth_component_storage_serial_is_valid \
            "$NVME_COMPONENT_ID" "${NVME_SERIAL:-}" >/dev/null 2>&1; then
        NVME_SERIAL="$(stealth_stable_nvme_serial \
            "$NVME_COMPONENT_ID" "$_identity_key-nvme")" || return 1
    fi

    # 当前目录只允许 exact 512GB；旧 profile 缺容量时也只补这一精确字节数。
    : "${NVME_SIZE_BYTES:=512110190592}"
    : "${NVME_PCI_VEN:=0x144D}"
    : "${NVME_PCI_DEV:=0xA808}"
    : "${NVME_SUBSYS_VEN:=0x144D}"
    : "${NVME_SUBSYS_DEV:=0xA801}"
    if [[ "$_boot_storage_migration_kind" == legacy-nvme-v1 ||
          "$_boot_storage_migration_kind" == legacy-sata-v1 ]]; then
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

    # 当前 C 层只接受目录中已审核的原子画像，不能把其它型号套在已知控制器上。
    local _current_nvme_row _catalog_nvme_id _catalog_nvme_model
    local _catalog_nvme_firmware _catalog_nvme_size
    _current_nvme_row="$(stealth_component_storage_row \
        "$NVME_COMPONENT_ID")" || return 1
    IFS='|' read -r _catalog_nvme_id _catalog_nvme_model \
        _catalog_nvme_firmware _catalog_nvme_size _ <<<"$_current_nvme_row"
    if [[ "$NVME_COMPONENT_ID|$NVME_MODEL|$NVME_FIRMWARE|$NVME_SIZE_BYTES" != \
          "$_catalog_nvme_id|$_catalog_nvme_model|$_catalog_nvme_firmware|$_catalog_nvme_size" ]]; then
        echo "ERROR: profile 使用未实现的 NVMe bundle: $NVME_MODEL / $NVME_FIRMWARE / $NVME_SIZE_BYTES" >&2
        echo "       请备份后显式 reroll，并确认磁盘虚拟容量。" >&2
        return 1
    fi

    stealth_apply_boot_storage_profile_migration \
        _stealth_present_keys "$_boot_storage_migration_kind" \
        "$_legacy_boot_storage_serial" || return 1
    _STEALTH_STORAGE_PROFILE_MIGRATION_KIND="$_boot_storage_migration_kind"
    if [[ "${STRICT_HARDWARE:-0}" == "1" &&
          "$PLATFORM_SCHEMA_VERSION" == "1" &&
          "$_boot_storage_migration_kind" != none ]]; then
        # legacy-v1 只在原始输入校验阶段获得窄例外；规范化后的 NVMe 身份必须
        # 再按当前规则验证，随后仍会进入完整 platform/component binding。
        stealth_verify_profile_identity_inputs _stealth_present_keys || return 1
    fi

    # 内存目录现在按实际安装 module ID 绑定；历史成对料号只作为受控迁移输入。
    # 解析函数只更新当前进程，真正写回仍延迟到所有启动门禁通过之后。
    stealth_resolve_loaded_memory_profile _stealth_present_keys || return 1

    # MEM_SERIAL 老 profile 没这字段：用 UUID 派生 8 字符十六进制，
    # 保证**同一 VM 跨重启 SN 不变**（即便没 reroll，老 VM 也不再每次启动漂移）。
    # 不用纯随机回填——那会让升级后第一次启动仍然换 SN，与"持久化"语义不符。
    # 用 UUID 的 sha256 前 8 字符做确定性派生：UUID 跨 VM 唯一，SN 自然也唯一。
    if ! [[ "${MEM_SERIAL:-}" =~ ^[0-9A-F]{8}$ ]] \
        || [[ "${MEM_SERIAL:-}" == "00000000" || "${MEM_SERIAL:-}" == "00000001" ]]; then
        MEM_SERIAL="$(_stealth_stable_hex "$_identity_key-mem" 8)"
    fi

    # 显示器 / 键盘 / 鼠标 / 数位板：缺失字段只补当前受控目录默认值。
    : "${EDID_COMPONENT_ID:=samsung-s24f350}"
    : "${EDID_VENDOR:=SAM}"
    : "${EDID_NAME:=S24F350}"
    : "${EDID_WIDTH_MM:=521}"
    : "${EDID_HEIGHT_MM:=293}"
    if ! stealth_component_monitor_serial_is_valid \
            "$EDID_COMPONENT_ID" "${EDID_SERIAL:-}" >/dev/null 2>&1; then
        local _edid_attempt
        for ((_edid_attempt = 0; _edid_attempt < 32; _edid_attempt++)); do
            EDID_SERIAL="$(_stealth_stable_monitor_serial \
                "$EDID_COMPONENT_ID" \
                "$_identity_key-edid-$_edid_attempt")" || return 1
            stealth_component_monitor_serial_is_valid \
                "$EDID_COMPONENT_ID" "$EDID_SERIAL" >/dev/null 2>&1 && break
        done
        stealth_component_monitor_serial_is_valid \
            "$EDID_COMPONENT_ID" "$EDID_SERIAL" >/dev/null 2>&1 || return 1
    fi
    if [[ -z "${EDID_BINARY_SERIAL:-}" ]]; then
        EDID_BINARY_SERIAL="$(
            stealth_component_monitor_binary_serial \
                "$EDID_COMPONENT_ID" "$EDID_SERIAL"
        )" || return 1
    fi
    if [[ -z "${EDID_REVISION:-}" ]]; then
        EDID_REVISION="$(
            stealth_component_monitor_revision "$EDID_COMPONENT_ID"
        )" || return 1
    fi
    : "${EDID_PRODUCT_ID:=0x0D20}"
    : "${EDID_MANUFACTURE_WEEK:=49}"
    : "${EDID_MANUFACTURE_YEAR:=2019}"
    : "${EDID_VIDEO_INPUT:=0x80}"
    : "${EDID_MIN_VFREQ_HZ:=50}"
    : "${EDID_MAX_VFREQ_HZ:=75}"
    : "${EDID_MIN_HFREQ_KHZ:=30}"
    : "${EDID_MAX_HFREQ_KHZ:=81}"
    : "${EDID_MAX_PIXEL_CLOCK_MHZ:=170}"
    : "${EDID_SECONDARY_XRES:=1280}"
    : "${EDID_SECONDARY_YRES:=720}"
    : "${EDID_SECONDARY_REFRESH_RATE:=50000}"
    local _edid_secondary_defaults _edid_default_clock
    local _edid_default_hfront _edid_default_hsync _edid_default_hblank
    local _edid_default_vfront _edid_default_vsync _edid_default_vblank
    local _edid_default_hsync_positive _edid_default_vsync_positive
    local _edid_default_width_mm _edid_default_height_mm
    _edid_secondary_defaults="$(
        stealth_component_monitor_secondary_detail "$EDID_COMPONENT_ID"
    )" || return 1
    IFS='|' read -r _edid_default_clock _edid_default_hfront \
        _edid_default_hsync _edid_default_hblank _edid_default_vfront \
        _edid_default_vsync _edid_default_vblank \
        _edid_default_hsync_positive _edid_default_vsync_positive \
        _edid_default_width_mm _edid_default_height_mm \
        <<<"$_edid_secondary_defaults"
    : "${EDID_SECONDARY_PIXEL_CLOCK_KHZ:=$_edid_default_clock}"
    : "${EDID_SECONDARY_HFRONT:=$_edid_default_hfront}"
    : "${EDID_SECONDARY_HSYNC:=$_edid_default_hsync}"
    : "${EDID_SECONDARY_HBLANK:=$_edid_default_hblank}"
    : "${EDID_SECONDARY_VFRONT:=$_edid_default_vfront}"
    : "${EDID_SECONDARY_VSYNC:=$_edid_default_vsync}"
    : "${EDID_SECONDARY_VBLANK:=$_edid_default_vblank}"
    : "${EDID_SECONDARY_HSYNC_POSITIVE:=$_edid_default_hsync_positive}"
    : "${EDID_SECONDARY_VSYNC_POSITIVE:=$_edid_default_vsync_positive}"
    : "${EDID_SECONDARY_WIDTH_MM:=$_edid_default_width_mm}"
    : "${EDID_SECONDARY_HEIGHT_MM:=$_edid_default_height_mm}"

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
    if [[ "$PLATFORM_SCHEMA_VERSION" == "1" ]] \
        && ! stealth_verify_profile_component_binding \
            _stealth_present_keys _stealth_explicit_empty_keys \
            "$_boot_storage_migration_kind" "$_legacy_boot_storage_serial"; then
        echo "       profile 的可更换部件事实已缺失或被篡改；请显式 reroll 整套身份。" >&2
        return 1
    fi
    # 非空部件请求在已有 profile 上只做一致性断言，绝不触发静默重抽。
    stealth_assert_requested_component_profile || return 1

    _STEALTH_LOADED_PROFILE_HASH="$_profile_hash_before"
    _STEALTH_LOADED_PROFILE_PATH="$path"
    local v
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        # shellcheck disable=SC2163 # v 的值才是白名单变量名，需要间接 export。
        export "$v"
    done
}
