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
    IFS='|' read -r _ BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION SERIAL_FN BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV <<<"${matched[$b_i]}"
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
    IFS='|' read -r NVME_MODEL NVME_FIRMWARE NVME_SIZE_BYTES <<<"${NVME_POOL[$nv_i]}"
    NVME_SERIAL="$(_nvme_serial)"

    # 5. 内存厂家 / part / 持久化序列号
    local mp_n=${#MEM_POOL[@]}
    local mp_i=$(( (RANDOM * 32768 + RANDOM) % mp_n ))
    IFS='|' read -r MEM_MFR MEM_PART_2G MEM_PART_4G <<<"${MEM_POOL[$mp_i]}"
    # DIMM serial 在 pick 阶段一次性生成，写到 profile 持久化——避免之前每次
    # 启动 stealth_smbios_args 里 _rand 一遍导致 Win32_PhysicalMemory.SerialNumber
    # 重启就变（反作弊"硬件指纹漂移"检测的明显信号）。
    MEM_SERIAL="$(_mem_serial)"

    # 内存总量 (MiB) 也钉进 profile，跟其它硬件身份一样跨重启稳定——否则启动时
    # 忘了带 --ram 就回退脚本默认值，"内存 4GB↔8GB 来回漂移"本身就是反作弊判定
    # 硬件指纹变化的信号。新 VM 默认 8192 (8GB 双通道 2×4GB)——start-vm.sh 见
    # RAM>4096 自动拆成 2 条 4GB DIMM 走双通道，两条 SN 各自唯一。老 profile 缺
    # 字段仍退回 4096 (见 stealth_load_profile)，不擅自升级既有 VM 的硬件画像；
    # 个别 VM 要改容量：deploy/scripts/set-vm-memory.sh <N> <size>，启动命令不变。
    MEM_TOTAL_MB="${MEM_TOTAL_MB:-8192}"

    # 6. 显示器（EDID）
    local mo_n=${#MONITOR_POOL[@]}
    local mo_i=$(( (RANDOM * 32768 + RANDOM) % mo_n ))
    local mo_prefix
    IFS='|' read -r EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM mo_prefix <<<"${MONITOR_POOL[$mo_i]}"
    EDID_SERIAL="$(_monitor_serial "$mo_prefix")"

    # 7. 键盘 USB HID
    local kbd_n=${#KBD_POOL[@]}
    local kbd_i=$(( (RANDOM * 32768 + RANDOM) % kbd_n ))
    local kbd_prefix
    IFS='|' read -r KBD_VID KBD_PID KBD_MFR KBD_PRODUCT kbd_prefix <<<"${KBD_POOL[$kbd_i]}"
    KBD_SERIAL="$(_usb_hid_serial "$kbd_prefix")"

    # 8. 鼠标 USB HID（相对坐标场景）
    local mou_n=${#MOUSE_POOL[@]}
    local mou_i=$(( (RANDOM * 32768 + RANDOM) % mou_n ))
    local mou_prefix
    IFS='|' read -r MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT mou_prefix <<<"${MOUSE_POOL[$mou_i]}"
    MOUSE_SERIAL="$(_usb_hid_serial "$mou_prefix")"

    # 9. 数位板 USB HID（绝对坐标场景，自动化默认）
    local tab_n=${#TABLET_POOL[@]}
    local tab_i=$(( (RANDOM * 32768 + RANDOM) % tab_n ))
    local tab_prefix
    IFS='|' read -r TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT tab_prefix <<<"${TABLET_POOL[$tab_i]}"
    TABLET_SERIAL="$(_usb_hid_serial "$tab_prefix")"

    export CPU_QEMU_ARG CPU_VENDOR CPU_NAME CPU_MAX_MHZ CPU_CUR_MHZ CPU_PART CPU_PROC_FAMILY CPU_SOCKET CPU_MODEL CPU_SERIAL
    export BOARD_MFR BOARD_PRODUCT BOARD_FAMILY BOARD_VERSION BOARD_SERIAL BOARD_ASSET BOARD_SUBSYS_VEN BOARD_SUBSYS_DEV
    export SYSTEM_MFR SYSTEM_PRODUCT SYSTEM_FAMILY SYSTEM_VERSION SYSTEM_SERIAL SYSTEM_SKU
    export BIOS_VENDOR BIOS_VERSION BIOS_DATE
    export CHASSIS_TYPE CHASSIS_SERIAL
    export NIC_MAC UUID
    export GPU_VENDOR GPU_NAME GPU_PCI_VEN GPU_PCI_DEV GPU_RAM_MB GPU_BIOS GPU_REV
    export NVME_MODEL NVME_FIRMWARE NVME_SERIAL NVME_SIZE_BYTES
    export MEM_MFR MEM_PART_2G MEM_PART_4G MEM_SERIAL MEM_TOTAL_MB
    export EDID_VENDOR EDID_NAME EDID_WIDTH_MM EDID_HEIGHT_MM EDID_SERIAL
    export KBD_VID KBD_PID KBD_MFR KBD_PRODUCT KBD_SERIAL
    export MOUSE_VID MOUSE_PID MOUSE_MFR MOUSE_PRODUCT MOUSE_SERIAL
    export TABLET_VID TABLET_PID TABLET_MFR TABLET_PRODUCT TABLET_SERIAL
}

