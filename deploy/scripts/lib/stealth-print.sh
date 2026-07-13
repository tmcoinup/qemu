stealth_print_profile() {
    # ---- 内存 ----
    # 取 NUM_DIMMS / PER_DIMM_MB（由 start-vm.sh 按 "RAM≤4096→1条 / >4096→2条" 决策）。
    # 库独立 source 时退化为列出 2G/4G 候选 part。
    local mem_line
    if [[ -n "${RAM:-}" && -n "${NUM_DIMMS:-}" && -n "${PER_DIMM_MB:-}" ]]; then
        local part_used
        if (( PER_DIMM_MB >= 4096 )); then
            part_used="$MEM_PART_4G"
        else
            part_used="$MEM_PART_2G"
        fi
        local slot_layout
        if (( NUM_DIMMS == 1 )); then
            slot_layout="单通道, 2 卡槽占 1 空 1"
        else
            slot_layout="双通道, 2 卡槽全占"
        fi
        local sn_disp="${MEM_SERIAL:-?}"
        if (( NUM_DIMMS == 2 )); then
            # 双通道时两条 DIMM 各自唯一 SN（第 2 条由 MEM_SERIAL 确定性派生），打印出来便于核对
            sn_disp="${MEM_SERIAL:-?}+$(printf '%s' "${MEM_SERIAL}-dimm2" | sha256sum | head -c 8 | tr '[:lower:]' '[:upper:]')"
        fi
        mem_line="${MEM_MFR}  ${RAM} MiB = ${NUM_DIMMS}× $(( PER_DIMM_MB / 1024 )).$(( (PER_DIMM_MB % 1024) * 10 / 1024 )) GiB  part=${part_used}  SN=${sn_disp}  (${slot_layout})"
    else
        mem_line="${MEM_MFR}  (候选: 2G=${MEM_PART_2G} / 4G=${MEM_PART_4G})  SN=${MEM_SERIAL:-?}"
    fi

    # ---- 显卡 / 显示器 ----
    # 本分支不做 GPU passthrough/vGPU，客体主设备仍是 virtio；GPU_POOL 的名称只为
    # 旧显示标签兼容，不应在摘要中冒充已实现的物理显卡。EDID 则来自完整组件目录。
    local vga_kind
    if [[ "${VGA_DEV:-virtio-vga}" == virtio-vga-gl* ]]; then
        vga_kind="virtio-vga-gl (virgl 3D)"
    else
        vga_kind="virtio-vga (stable, 无 GL)"
    fi
    # 显示器对角线：sqrt(w²+h²) 毫米 → 英寸（÷25.4）
    local diag_inch
    if [[ -n "${EDID_WIDTH_MM:-}" && -n "${EDID_HEIGHT_MM:-}" ]]; then
        diag_inch=$(echo "scale=1; sqrt(${EDID_WIDTH_MM}^2 + ${EDID_HEIGHT_MM}^2) / 25.4" | bc -l 2>/dev/null || echo "?")
    else
        diag_inch="?"
    fi

    # ---- 网卡 / 声卡 ----
    local nic_line="e1000e (Intel 82574L add-in, subsystem ${NIC_SUBSYSTEM_VEN}:${NIC_SUBSYSTEM_DEV})  MAC=${NIC_MAC}"
    local audio_line="${AUDIO_CONTROLLER_PCI_VEN}:${AUDIO_CONTROLLER_PCI_DEV} HDA + ${AUDIO_CODEC} 协议身份（通用 duplex 拓扑）"

    # ---- 键盘 / 鼠标 ----
    # 键鼠目录与 C 内固定 report/config descriptor 一一对应，且 iSerialNumber=0。
    # tablet 明确为 QEMU 通用绝对指针，不能打印历史 HUION profile 字段。
    local kbd_line="usb-kbd → ${KBD_PRODUCT} (USB ${KBD_VID/0x/}:${KBD_PID/0x/}, bcd=${KBD_BCD_DEVICE})"
    local mouse_line
    if [[ "${USB_RELATIVE_MOUSE:-0}" == "1" ]]; then
        mouse_line="usb-mouse → ${MOUSE_PRODUCT} (USB ${MOUSE_VID/0x/}:${MOUSE_PID/0x/}, bcd=${MOUSE_BCD_DEVICE}, 相对坐标)"
    else
        mouse_line="usb-tablet → ${TABLET_PRODUCT} (USB ${TABLET_VID/0x/}:${TABLET_PID/0x/}, 绝对坐标)"
    fi

    cat >&2 <<EOF
=== stealth profile ===
  CPU      : $CPU_NAME ($CPU_VENDOR, socket $CPU_SOCKET, QEMU=$CPU_QEMU_ARG)
  Board    : $BOARD_MFR / $BOARD_PRODUCT ($BOARD_VERSION)
  Board SN : $BOARD_SERIAL
  PCI subs : $BOARD_SUBSYS_VEN:$BOARD_SUBSYS_DEV
  System   : $SYSTEM_MFR / $SYSTEM_PRODUCT / $SYSTEM_FAMILY
  System SN: $SYSTEM_SERIAL   SKU=$SYSTEM_SKU
  BIOS     : $BIOS_VENDOR $BIOS_VERSION ($BIOS_DATE)
  Chassis  : $CHASSIS_TYPE  SN=$CHASSIS_SERIAL
  GPU      : virtio display；旧标签=$GPU_NAME（${GPU_IDENTITY_FIDELITY}，不计真机化）
  Display  : ${vga_kind}, EDID 1920×1080
  显示器   : ${EDID_VENDOR}:${EDID_PRODUCT_ID} ${EDID_NAME}  ~${diag_inch}\" (${EDID_WIDTH_MM}×${EDID_HEIGHT_MM} mm)  SN=${EDID_SERIAL}
  NVMe     : $NVME_MODEL  fw=$NVME_FIRMWARE  PCI=${NVME_PCI_VEN}:${NVME_PCI_DEV}/${NVME_SUBSYS_VEN}:${NVME_SUBSYS_DEV}  SN=$NVME_SERIAL  size=$(printf '%.1f' "$(echo "$NVME_SIZE_BYTES / 1024^3" | bc -l 2>/dev/null || echo 0)") GiB
  Memory   : ${mem_line}
  网卡     : ${nic_line}
  声卡     : ${audio_line}
  键盘     : ${kbd_line}
  鼠标     : ${mouse_line}
  UUID     : $UUID
=======================
EOF
}
