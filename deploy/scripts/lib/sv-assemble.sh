# -------------------------------------------------------------------
# Assemble the command line
# -------------------------------------------------------------------
QMP_ARGS=(-qmp "unix:$QMP_SOCK,server=on,wait=off")
if [[ "$PROXY" == "1" ]]; then
    # --proxy 现在映射到 QEMU 原生 QMP multi-client listener：
    # 同一路径可被 dgame / image-search / 临时 socat 同时连接。保留 -qmp
    # shorthand，memflow 仍能从 QEMU argv 里识别 QMP socket。
    QMP_ARGS=(-qmp "unix:$QMP_SOCK,server=on,wait=off,multi=on")
fi

# QEMU 文档说明 cpu-pm=on 会把 host CPU power management 能力交给 guest：
# 这可能降低单 VM worst-case latency，但会让宿主调度/统计更难预测。默认关闭，
# 保持和 QEMU 上游一致，也方便后续迁移到 E5/多开场景时统一按宿主策略分配。
# 只有明确做单机低延迟实验时，才用 QEMU_CPU_PM=1 显式打开。
CPU_PM_ARG=off
if [[ "${QEMU_CPU_PM:-0}" =~ ^(1|on|true|yes)$ ]]; then
    CPU_PM_ARG=on
fi

# shellcheck source=stealth-storage.sh
source "$HERE/lib/stealth-storage.sh"
stealth_build_boot_storage_args || exit 2

# QEMU 的 machine/drive/device option 是逗号分隔的单个 argv；数组中的每个配置串
# 都有意保持为一个元素，并非用逗号分隔 shell 数组成员。
# shellcheck disable=SC2054
CMD=(
    "$QEMU"

    # --- Machine / firmware ---
    # ACPI OEM IDs default to "ALASKA"/"A M I   " from our aml-build.h patch;
    # no need to pass x-oem-id on the cmdline. smm=on is required for OVMF S3.
    #
    # **2026-05 改名**：原来 "win10-ryzen3-${INSTANCE}" host `ps` 一眼能看出
    # stealth 设计；改成中性的 "win10-${INSTANCE}" 减少 host 端无意暴露
    # （不影响 guest——guest 看不到 QEMU 进程名）。debug-threads 仍开。
    -name "win10-${INSTANCE},debug-threads=on"
    -machine "q35,accel=kvm,vmport=off,smm=on,hpet=off,kernel-irqchip=split"
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"

    # --- CPU: hidden hypervisor, hidden KVM, invtsc ---
    # CPU 完整 -cpu 串由 stealth_qemu_cpu_arg 拼出（包含 family/model/stepping、
    # tsc-freq 和 vendor）。默认只有 manifest 中 enabled 且通过宿主 KVM 探测的
    # 整机 bundle 可进入新 profile；compatibility 还须独立 allow 授权并保留警告。
    -cpu "$(stealth_qemu_cpu_arg)"
    # 完整 SKU 的核心/线程拓扑来自 platform manifest。选择阶段已经要求 CPUS 等于
    # CPU_THREADS；这里再次用整数除法构造 threads-per-core，不能把 2C/4T CPU 写成 4C。
    -smp "cpus=$CPUS,cores=${CPU_CORES},threads=$(( CPU_THREADS / CPU_CORES )),sockets=1,maxcpus=$CPUS"

    # --- Memory: backed by memfd, 拓扑由 MEMORY_ARGS 数组动态决定 ---
    # share=on（关键）：让 host 进程地址空间和 KVM 给 guest 的 page 是同一份。
    # 原本写 share=off 会触发 KVM 的 COW 路径，host 进程读到的是初始 prealloc 零页，
    # 与 guest 实际 RAM 分叉——VMI（memflow / LibVMI）会读到全零，无法工作。
    # share=on 对 guest 完全不可见（仿真机看不到任何差别），是 VMI 必须的前提。
    #
    # MEMORY_ARGS 始终使用一个 guest NUMA node；DIMM/双通道只由 SMBIOS/SPD 表达。
    "${MEMORY_ARGS[@]}"

    # --- Random identifiers ---
    -uuid "$UUID"
    # **2026-05 改 clock=vm**：原来 clock=host 让 guest RTC = host monotonic，
    # 配合 +invtsc + 钉死 tsc-freq 后，RDTSC 和 wall-clock 完美 ppm 级对齐，
    # 反而是 VM 特征（裸金属晶振温漂总有几十 ppm 偏移）。clock=vm 让 RTC 走
    # guest 自己的 TSC 计数器自然产生微漂移；driftfix=slew 仍保证 Windows
    # 时间服务能拉回 NTP 不出问题。
    -rtc base=localtime,clock=vm,driftfix=slew
    -global kvm-pit.lost_tick_policy=delay
    -boot "$BOOT_ORDER"
    -no-user-config
    -nodefaults

    # --- SMBIOS / DMI override ---
    "${SMBIOS_ARGS[@]}"

    # --- ACPI 补丁表（伪 BGRT，让 ACPI 表树看起来像真 OEM 机器） ---
    "${ACPI_ARGS[@]}"

    # --- PCI root complex (pcie-pci-bridge hidden; default q35) ---
    # hotplug=off：清掉 Slot Capabilities 的 HPC/HPS 位 (见 hw/pci/pcie.c
    # pcie_cap_slot_init)。否则根端口默认 hotplug=on → Windows pci.sys 把挂在
    # 端口下的 NVMe/网卡/xHCI 判为"可热插拔",托盘冒出"安全删除硬件"图标
    # (弹出 Samsung SSD / NVMe 控制器 / 82574L / USB3.0)——真实板载设备走的是
    # 非热插拔端口,不会出现该图标。冷插(开机即在)的设备不受影响,USB 设备热插拔
    # 走 usb 总线也不受影响,纯去指纹。
    # PCI ID 按平台注入 (见上方 ROOT_PORT_ARGS / PLATFORM_VENDOR)。
    "${CHIPSET_GLOBAL_ARGS[@]}"
    "${ROOT_PORT_ARGS[@]}"

    # --- TPM（swtpm emulator；版本和 TIS/CRB 前端由整机 profile 决定）---
    # 空数组时（swtpm 不可用）此处展开为零参数，不影响。
    "${TPM_ARGS[@]}"

    # --- AMD Zen Data Fabric PCI stubs at 00:18.0-7 (only for AMD CPUs) ---
    # Real Zen silicon exposes 8 DF config functions; HWiNFO/CPU-Z use these
    # to identify the CPU codename and derive channel topology. Intel CPUs
    # 不放 DF stub —— 否则会出现 "Intel CPU 但有 AMD DF" 的矛盾。
    "${AMD_DF_ARGS[@]}"

    # --- Storage: 平台能力决定 NVMe boot 或 SATA/AHCI boot ---
    # bootindex=3：安装时让位给 helper image=1 / Windows ISO=2；安装完成后由
    # OVMF NVRAM 中的 Windows Boot Manager 决定优先级。
    "${BOOT_STORAGE_ARGS[@]}"

    "${CDROM_ARGS[@]}"

    # --- Network: e1000e emulation (Intel 82574L) w/ random MAC ---
    "${NET_ARGS[@]}"
    -device "e1000e,netdev=net0,mac=${MAC_OVERRIDE},bus=rp2,subsys_ven=${NIC_SUBSYSTEM_VEN},subsys=${NIC_SUBSYSTEM_DEV}"

    # --- USB: xHCI + 键盘 + 鼠标 ---
    # usb-kbd: DirectInput/Raw Input 兼容 (DNF/仿真机只读 USB HID, 不读 PS/2).
    # USB_RELATIVE_MOUSE=1: usb-mouse (相对坐标，更像真鼠标，仿真机友好；
    #   SDL 抓鼠标，Ctrl+Shift+G 释放)
    # 默认 usb-tablet (绝对坐标，鼠标可自由出入 SDL 窗口)
    # 经 patch 0010 后 vendorid/productid/manufacturer/product 从 profile 的
    # KBD/MOUSE/TABLET 字段注入；品牌、VID/PID、bcdDevice 必须来自同一组件条目。
    # serial 不传：当前核验的 OEM 鼠键 descriptor 的 iSerialNumber=0。
    -device "qemu-xhci,id=xhci,bus=rp3,${XHCI_ID}"
    "${KBD_DEVICE_ARG[@]}"
    "${POINTER_DEVICE_ARG[@]}"

    # --- Audio: ICH9 HDA (looks like Realtek ALC). Use 'none' backend
    # unconditionally -- passes driver probe in guest without requiring
    # ALSA/PipeWire on the host. ---
    -audiodev none,id=aud0
    -device "ich9-intel-hda,id=hda0,x-pci-vendor-id=${AUDIO_CONTROLLER_PCI_VEN},x-pci-device-id=${AUDIO_CONTROLLER_PCI_DEV},x-pci-revision=${AUDIO_CONTROLLER_REV:-$LPC_REV},x-pci-sub-vendor-id=${BOARD_SUBSYS_VEN},x-pci-sub-device-id=${BOARD_SUBSYS_DEV}"
    -device "hda-duplex,bus=hda0.0,cad=0,audiodev=aud0,x-identity-compat=on,x-codec-id=${AUDIO_CODEC_ID},x-codec-revision=${AUDIO_CODEC_REVISION},x-codec-subsystem-id=${AUDIO_CODEC_SUBSYSTEM_ID}"

    # --- Display ---
    "${DISP_ARGS[@]}"

    # --- Control: QMP + HMP sockets for API access ---
    # 用 -qmp shorthand 而不是 -chardev/-mon：等价语义，但 memflow 的命令行解析
    # 只认 -qmp 这种 flag。这样 dgame 调试器用 memflow 直读时能找到 socket。
    "${QMP_ARGS[@]}"
    -chardev "socket,id=mon0,path=$MON_SOCK,server=on,wait=off"
    -mon chardev=mon0,mode=readline

    # --- Misc anti-detection knobs ---
    -msg timestamp=off
    -overcommit "mem-lock=off,cpu-pm=${CPU_PM_ARG}"
)

# 到这里，CPU realize、宿主约束、磁盘容量、所请求 TPM、内存拓扑、设备参数和
# 完整 QEMU argv 都已成功生成。此时在真正启动 QEMU 前原子提交首次/--reroll
# 候选；若前面任一门禁失败，旧 profile 的内容和哈希都保持不变。DRY_RUN 只报告
# 候选，绝不写入。
if (( ${_profile_needs_save:-0} )); then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ">> profile:     [DRY_RUN] 生成内存身份，未落盘 $PROFILE_FILE"
    else
        if ! stealth_save_profile "$PROFILE_FILE"; then
            echo "ERROR: 无法原子提交硬件 profile: $PROFILE_FILE" >&2
            # swtpm daemon 已通过 TPM 门禁后启动。profile 写盘若失败，QEMU 不会
            # 启动，必须精确回收本实例 daemon；失败时保留 runtime 登记供 stop
            # 重试，绝不按宽泛进程名误杀其它实例。
            if (( ${#TPM_ARGS[@]} > 0 )) && [[ -n "${TPM_STATE_DIR:-}" ]]; then
                if sv_swtpm_stop_instance "$INSTANCE" "$TPM_STATE_DIR"; then
                    rm -f -- "${TPM_SOCK:-}"
                else
                    echo "WARN: profile 提交失败后 swtpm 未完全退出；请运行 stop-vm.sh $INSTANCE" >&2
                fi
            fi
            exit 1
        fi
        echo ">> profile:     NEW identity saved to $PROFILE_FILE"
    fi
fi
unset _profile_needs_save

# 回归/调试出参：DRY_RUN=1 时打印完整 QEMU argv（每行一个）后退出，不启动任何
# 后台守护、不 exec。用于重构前后逐字节比对生成的命令行，确保去虚拟化参数不被
# 改动。仅在 DRY_RUN=1 时生效，正常启动路径完全不变。
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '__DRY_RUN_ARGV__\n'
    printf '%s\n' "${CMD[@]}"
    exit 0
fi

# 显式 VLAN 到这里才产生宿主网络副作用：CMD 已完整生成，且 DRY_RUN 已经退出。
# prepare 完成后立即启动异步 watchdog；若 watchdog 自身无法启动，则先回收 TAP
# 再中止，不能留下一个没有生命周期所有者的 persistent 接口。
if [[ -n "${VLAN_ID:-}" ]]; then
    sv_vlan_prepare
fi
if ! sv_instance_watchdog_launch; then
    if [[ -n "${VLAN_ID:-}" ]]; then
        sv_vlan_cleanup_instance "$INSTANCE" >/dev/null 2>&1 || true
    fi
    exit 1
fi

echo ">> instance:    $INSTANCE"
echo ">> VM 目录:     $VM_DIR"
echo ">> QMP socket:  $QMP_SOCK"
if [[ "$PROXY" == "1" ]]; then
    QMP_PROXY_SOCK="${QMP_SOCK}.proxy"
    echo ">> QMP multi:   native multi-client on $QMP_SOCK"
    echo ">> QMP alias:   $QMP_PROXY_SOCK (compat symlink for old tool configs)"
fi
echo ">> HMP socket:  $MON_SOCK"
# 显示通道
if [[ "$HEADLESS" == "1" ]]; then
    echo ">> GUI:         VNC 127.0.0.1:$((5900+VNC_DISPLAY)) (display :$VNC_DISPLAY)"
elif [[ "${GPU_DISPLAY:-sdl}" == "egl-headless" ]]; then
    echo ">> GUI:         EGL headless GPU (rendernode=${GPU_RENDERNODE:-auto})"
elif [[ "$SDL" == "1" ]]; then
    if [[ "$STABLE_DISPLAY" == "1" ]]; then
        echo ">> GUI:         SDL 窗口 (DISPLAY=${DISPLAY:-未设}) stable"
    elif [[ "${GPU_DISPLAY:-sdl}" == "sdl-egl" ]]; then
        # 中文注释：sdl-egl 是兼容模式名；实际 EGL 能力由 QEMU 11 SDL 后端
        # 自行探测，启动器不再导出私有开关或创建额外 X11 子窗口。
        echo ">> GUI:         SDL/GL 窗口 (QEMU 11 自动探测 EGL，兼容模式 sdl-egl)"
    else
        echo ">> GUI:         SDL/GL 窗口 (DISPLAY=${DISPLAY:-未设})"
    fi
else
    echo ">> GUI:         无（纯 fb-shm 推流模式）"
fi
if [[ "$FB_SHM" == "1" ]]; then
    echo ">> fb-shm sock: $FB_SHM_SOCK (configured=${FB_SHM_RATE} Hz${FB_SHM_ROI:+, ROI=$FB_SHM_ROI})"
    # 中文注释：QEMU 启动日志中的 1Hz 是无 consumer 时的有效 DCL 节流值，
    # 不是 -object rate 丢失；连接 consumer 后会按配置值或 SET_RATE 请求恢复。
    echo ">>   rate 说明: 无 consumer 时 effective 可降至 1 Hz；连接后使用 configured/consumer target"
    if [[ "${GPU_GL_DISPLAY:-0}" == "1" && "${GPU_ZEROCOPY:-0}" == "1" ]]; then
        echo ">>   GPU handoff: 优先 GPU handle (blob=true,hostmem=${GPU_HOSTMEM});不可用自动 SHM fallback"
    elif [[ "${GPU_GL_DISPLAY:-0}" == "1" ]]; then
        echo ">>   GPU handoff: blob/hostmem 偏好已关闭；renderer 仍可导出 texture handle，失败才回退 SHM"
    else
        echo ">>   GPU handoff: 当前为非 GL 显示路径；使用 SHM fallback"
    fi
    echo ">>   接消费端: scripts/qemu-fb-shm-stream.py --sock $FB_SHM_SOCK --output ..."
fi
echo ">> SSH/RDP fwd: 127.0.0.1:$SSH_FWD_PORT / 127.0.0.1:$RDP_FWD_PORT"
echo ">> boot mode:   $BOOT"
if [[ "$BOOT" == "iso" ]]; then
    # **ISO 装系统手动操作提示**：
    # Windows ISO 的 El Torito UEFI image 描述 Ldsiz=1 sector，OVMF auto-boot
    # 直接掉 UEFI Shell；ISO9660 主表也不含 \EFI\BOOT\BOOTX64.EFI（在 Joliet/
    # UDF 扩展里），所以即使 chainload helper 加了 startup.nsh 也偶尔 miss。
    # 手动路径最稳：OVMF splash 倒数 5 秒内按 ESC → Boot Manager →
    # "UEFI QEMU DVD-ROM" → Setup 起来后按空格过 "Press any key to boot from
    # CD or DVD"。SDL 窗口里直接键盘操作即可。
    echo ">>"
    echo ">> ============ 装系统手动步骤 ============"
    echo ">>   1. SDL 窗口里, OVMF 倒数 5 秒内按 ESC 进 Boot Manager"
    echo ">>   2. 选 'UEFI QEMU DVD-ROM QEMU DVD-ROM' → 回车 boot"
    echo ">>   3. Setup 起来后按空格过 'Press any key to boot from CD'"
    echo ">>   4. 进 Windows Setup 后正常装"
    echo ">> 若 chainload helper 自动 work, 上面步骤可跳, 直接进 Setup。"
    echo ">> ======================================="
fi
# 磁盘信息：qemu-img virtual-size 已在持久化副作用前校验；宿主分配量只用于
# 运维观察，不能拿 qcow2 容器的 stat 大小冒充 guest 可见容量。
echo ">> disk:        $DISK"
echo ">>   virtual   : ${DISK_VIRTUAL_SIZE:-?} bytes (guest-visible, profile verified)"
echo ">>   allocated : ${DISK_HOST_ALLOCATED_BYTES:-?} bytes (sparse on-host)"
echo ">>   identity  : ${BOOT_STORAGE_SIZE_BYTES:-?} bytes = ${BOOT_STORAGE_MODEL:-?}"
# 内存信息：总量 + DIMM 拓扑 (1 单通道 / 2 双通道) + 厂商 + part number + memfd backend。
# memfd 是 share=on 让 VMI（memflow）能 mmap 同一份物理页。消费级单路平台始终
# 只有一个 guest NUMA node；DIMM 数只通过 SMBIOS/SPD 表达，不能伪造 NUMA 节点。
# 主板物理 2 卡槽（T16_NUM_DEVICES=2）始终不变，4GB 时一个槽空。
if (( PER_DIMM_MB >= 4096 )); then
    _mem_part_used="$MEM_PART_4G"
else
    _mem_part_used="$MEM_PART_2G"
fi
if (( NUM_DIMMS == 1 )); then
    echo ">> 内存:        ${RAM} MiB 单通道 (1× ${PER_DIMM_MB} MiB DIMM, 1 memfd, NUMA 1 node)"
    echo ">>   卡槽布局 : 2 卡槽 / 占用 1 / 空 1"
else
    echo ">> 内存:        ${RAM} MiB 双通道 (2× ${PER_DIMM_MB} MiB DIMM, 1 memfd, NUMA 1 node)"
    echo ">>   卡槽布局 : 2 卡槽 / 全部占用"
fi
echo ">>   DIMM 厂商 : ${MEM_MFR:-?}"
echo ">>   part 号   : ${_mem_part_used:-?}"
if (( NUM_DIMMS == 2 )); then
    # 双通道：每条 DIMM 各自唯一 SN（第 2 条由 MEM_SERIAL 确定性派生），核对用
    _mem_sn2="$(_stealth_memory_slot_serial "$MEM_SERIAL" 2)" || {
        echo "ERROR: 无法派生合法的第二条 DIMM 序列号" >&2
        exit 1
    }
    echo ">>   SN        : ${MEM_SERIAL:-?} (DIMM_A2) / ${_mem_sn2} (DIMM_B2)  ← 两条各自唯一"
else
    echo ">>   SN        : ${MEM_SERIAL:-?}"
fi
# CPU 信息：profile 选定的型号 + 实际给 guest 的 vCPU 拓扑
echo ">> CPU:         ${CPU_NAME:-?}"
echo ">>   QEMU 串   : $(stealth_qemu_cpu_arg)"
echo ">>   拓扑      : ${CPUS} vCPU (cores=${CPU_CORES}, threads=$(( CPU_THREADS / CPU_CORES )), sockets=1, maxcpus=${CPUS})"

# 整份 stealth profile（含 CPU / 主板 / GPU / NVMe / 内存 / 网卡 / 声卡 /
# 键鼠 / 显示器 / UUID 等）。这里才打，因为 VGA_DEV、USB_RELATIVE_MOUSE、
# NUM_DIMMS、PER_DIMM_MB 都已就绪，print_profile 能反映真实运行参数。
stealth_print_profile

echo ">> --- launching ---"

# QMP multi-client alias: 旧工具可能已经写死 .qmp.proxy；现在不再起 Python
# 中转进程，而是让 .qmp.proxy 指向原生 multi=on 的 QMP socket。Unix socket
# connect 会跟随 symlink，因此两条路径等价；失败只影响兼容别名，不影响 QMP 本体。
if [[ "$PROXY" == "1" ]]; then
    rm -f "$QMP_PROXY_SOCK"
    if ln -s "$QMP_SOCK" "$QMP_PROXY_SOCK" 2>/dev/null; then
        echo ">> QMP alias:   $QMP_PROXY_SOCK -> $QMP_SOCK"
    else
        echo ">> WARN: QMP alias 创建失败: $QMP_PROXY_SOCK"
    fi
fi

# ISO 装系统：BOOTX64.EFI 启动后会显示 "Press any key to boot from CD or DVD"
# prompt 5 秒。SDL 后端在 virtio-vga 切 mode 时偶发 "Display output is not
# active" 占位字遮住 prompt，用户来不及按键。后台 daemon 在启动后 18-60 秒
# 持续 QMP send-key spc 几次，确保 prompt 被吃掉、Setup 自动进入。Setup 进
# graphics 模式后 spc 不响应（Setup UI 不绑定 spc），无副作用。
if [[ "$BOOT" == "iso" ]]; then
    (
        # 等 OVMF + chainload 跑到 BOOTX64.EFI 大约要 15-18 秒
        sleep 16
        # 每 2 秒 send 一次, 共 ~22 次 = 44 秒，覆盖 BOOTX64.EFI 5 秒 prompt
        # 窗口的多个 retry。Setup 真正起来后 spc 也是 noop。
        for _i in $(seq 1 22); do
            [[ -S "$QMP_SOCK" ]] || break
            printf '{"execute":"qmp_capabilities"}{"execute":"human-monitor-command","arguments":{"command-line":"sendkey spc"}}\n' \
                | timeout 2 socat - UNIX-CONNECT:"$QMP_SOCK" >/dev/null 2>&1 || true
            sleep 2
        done
    ) 8>&- &
    _AUTO_KEY_PID=$!
    echo ">> auto-key:    后台 daemon (pid=$_AUTO_KEY_PID) 跨过 BOOTX64.EFI 'Press any key' prompt"
fi

# CPU 亲和隔离(默认开): 后台 pinner 等 QEMU/QMP 起来后, 把 vCPU 钉进 cgroup cpuset
# 独占分区, 与宿主机其它负载(尤其 cargo/rust 编译吃满全核)在调度层隔离, 治宿主机满
# 载时 VM 卡顿/掉帧/ACE 计时异常。必须在 exec QEMU 前 fork(否则本进程已被替换);
# 同步前置条件已在加载 sv-cpupin.sh 时验证；严格模式的后台 pinner 若仍在 QMP、
# cgroup 或 taskset 阶段失败，会主动请求 QMP quit，不能静默以未隔离状态继续。
sv_cpu_isolate_launch

# QEMU's `-rtc base=localtime` calls libc localtime() which honours $TZ.
# Pin to Asia/Shanghai so the VM RTC reflects Beijing time regardless of
# what the host's /etc/timezone is set to. Without this an LA-host gives
# the guest LA wall-clock and Windows (set to CST) shows it 15h off.
export TZ="${TZ:-Asia/Shanghai}"
echo ">> RTC TZ:       $TZ"

# SDL 窗口模式需要同步管理 xset/GNOME/systemd inhibit；独立模块会在确实修改
# 宿主显示状态时保留轻量父 shell，确保 QEMU 正常退出、ABRT 或收到信号后都能
# 还原。其它模式仍在函数内直接 exec，不额外增加常驻进程。
sv_display_guard_launch "${CMD[@]}" || exit $?
