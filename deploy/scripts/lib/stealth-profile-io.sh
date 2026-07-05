# ------------------------------------------------------------------
# 持久化 / 载入
# ------------------------------------------------------------------
_STEALTH_PROFILE_VARS=(
    CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL CPU_ASSET
    BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV
    SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    BIOS_VENDOR BIOS_VERSION BIOS_DATE
    CHASSIS_TYPE CHASSIS_SERIAL
    NIC_MAC UUID
    GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES
    MEM_MFR MEM_PART_2G MEM_PART_4G MEM_RATED MEM_SERIAL MEM_TOTAL_MB
    EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL
    KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL
    MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL
    TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL
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
    # profile 含 MAC / 序列号等可被用来篡改身份的字段；限制为仅属主可读写。
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$path"
}

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
        if [[ "$rawval" == *'$('* || "$rawval" == *'`'* || "$rawval" == *'${'* ]]; then
            return 1
        fi
        printf '%s' "$rawval" | sed -E 's/\\(.)/\1/g'
        return 0
    done < "$path"
    return 1
}

stealth_load_profile() {
    local path="$1"

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
        if [[ "$rawval" == *'$('* || "$rawval" == *'`'* || "$rawval" == *'${'* ]]; then
            echo ">> WARN: profile key $key 含命令替换/参数展开构造，已拒绝" >&2
            continue
        fi
        # %q 反转义：把每个 \X 还原为 X（不经过 shell 解析，安全）
        val="$(printf '%s' "$rawval" | sed -E 's/\\(.)/\1/g')"
        printf -v "$key" '%s' "$val"
    done < "$path"

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

    : "${GPU_VENDOR:=NVIDIA}"
    : "${GPU_NAME:=NVIDIA GeForce GTX 1050}"
    : "${GPU_PCI_VEN:=0x10DE}"
    : "${GPU_PCI_DEV:=0x1C81}"
    : "${GPU_RAM_MB:=2048}"
    : "${GPU_BIOS:=Version 86.07.48.00.38}"
    : "${GPU_REV:=0xA1}"

    : "${NVME_MODEL:=Samsung SSD 970 PRO 512GB}"
    : "${NVME_FIRMWARE:=1B2QEXM7}"

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

    : "${MEM_MFR:=Kingston}"
    : "${MEM_PART_2G:=KVR26N19S6/2}"
    : "${MEM_PART_4G:=HX426C16FB3A/4}"
    # 颗粒额定速率：老 profile 缺 → 按 part number 编码推导(26=2666/24=2400/-CRC=2400)，
    # 推不出兜 2666(与默认 Kingston HyperX 2666 一致)。报告速率再 min(CPU 平台上限)。
    if [[ -z "${MEM_RATED:-}" ]]; then
        case "${MEM_PART_4G:-}${MEM_PART_2G:-}" in
            *-CRC*|*24N*|*DFS624*|*DFS824*) MEM_RATED=2400 ;;
            *26N*|*266*|*C16F*)             MEM_RATED=2666 ;;
            *)                              MEM_RATED=2666 ;;
        esac
    fi

    # MEM_SERIAL 老 profile 没这字段：用 UUID 派生 8 字符十六进制，
    # 保证**同一 VM 跨重启 SN 不变**（即便没 reroll，老 VM 也不再每次启动漂移）。
    # 不用纯随机回填——那会让升级后第一次启动仍然换 SN，与"持久化"语义不符。
    # 用 UUID 的 sha256 前 8 字符做确定性派生：UUID 跨 VM 唯一，SN 自然也唯一。
    if [[ -z "${MEM_SERIAL:-}" ]]; then
        if [[ -n "${UUID:-}" ]]; then
            MEM_SERIAL=$(printf '%s' "${UUID}-mem" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')
        else
            # UUID 也没——彻底退化（不应该发生，UUID 是必填字段）
            MEM_SERIAL="00000001"
        fi
    fi

    # MEM_TOTAL_MB 老 profile 没有：留空 → start-vm.sh 退回历史默认 4096 MiB。
    # 不擅自把老 VM 升到 8GB（改内存总量 = 改硬件画像，需用户显式 --ram= 或在
    # profile 里写 MEM_TOTAL_MB）。新 profile 由 stealth_pick_profile 写 8192。
    : "${MEM_TOTAL_MB:=}"

    # 显示器 / 键盘 / 鼠标 / 数位板：老 profile 退化为 QEMU patch 历史默认值
    # （Samsung S24F350F / Microsoft Wired Keyboard 600 / Microsoft USB Optical
    # Mouse / HUION PenTablet）。配合 patch 0009/0010 后默认仍然生效。
    : "${EDID_VENDOR:=SAM}"
    : "${EDID_NAME:=S24F350}"
    : "${EDID_WIDTH_MM:=530}"
    : "${EDID_HEIGHT_MM:=300}"
    : "${EDID_SERIAL:=H4ZK500001VL}"

    : "${KBD_VID:=0x045E}"
    : "${KBD_PID:=0x0750}"
    : "${KBD_MFR:=Microsoft}"
    : "${KBD_PRODUCT:=Microsoft Wired Keyboard 600}"
    : "${KBD_SERIAL:=68284}"

    : "${MOUSE_VID:=0x045E}"
    : "${MOUSE_PID:=0x00CB}"
    : "${MOUSE_MFR:=Microsoft}"
    : "${MOUSE_PRODUCT:=Microsoft USB Optical Mouse}"
    : "${MOUSE_SERIAL:=42}"

    : "${TABLET_VID:=0x256C}"
    : "${TABLET_PID:=0x006D}"
    : "${TABLET_MFR:=HUION}"
    : "${TABLET_PRODUCT:=HUION PenTablet}"
    : "${TABLET_SERIAL:=HU000001}"

    local v
    for v in "${_STEALTH_PROFILE_VARS[@]}"; do
        export "$v"
    done
}
