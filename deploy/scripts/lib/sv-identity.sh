# -------------------------------------------------------------------
# Boot source:
#   --iso=<path>  -> boot from that ISO (install media)
#   (no flag)     -> boot from the qcow2 disk
# -------------------------------------------------------------------
if [[ -n "$_cli_iso" ]]; then
    BOOT="iso"
else
    BOOT="disk"
fi

# -------------------------------------------------------------------
# Hardware identity — random on creation, stable afterwards.
#
# First launch (profile file missing) or --reroll: randomize + save.
# Subsequent launches: source the saved profile. This is what keeps
# Windows from re-activating every boot and what stops XignCode3 from
# noticing the motherboard serial flipping between sessions.
#
# **重要顺序**：profile 必须在磁盘创建**之前**加载，因为 qcow2 虚拟容量
# 要与 component manifest 中核验过的 NVME_SIZE_BYTES 完全相等。不能只看
# qcow2 容器文件的宿主逻辑大小；稀疏文件的容器大小与 guest 可见容量不是一回事。
# -------------------------------------------------------------------
_profile_needs_save=0
if (( _cli_reroll )); then
    # 不能先删旧 profile：目标 CPU 若无法在当前宿主 realize，旧 VM 身份仍应保持
    # 可恢复。新身份先只存在当前进程内存，完成严格 smoke 后再原子替换。
    echo ">> --reroll: preparing replacement hardware identity for instance $INSTANCE"
    stealth_pick_profile
    _profile_needs_save=1
elif stealth_have_profile "$PROFILE_FILE"; then
    stealth_load_profile "$PROFILE_FILE"
    echo ">> profile:     loaded from $PROFILE_FILE"
else
    stealth_pick_profile
    _profile_needs_save=1
fi

# 显式平台 ID 在已有实例上是“断言”，不是偷偷改身份。若 profile 已固定为另一套
# CPU/主板，调用方必须使用 --reroll 走先烟测、后原子替换的安全迁移路径；不能仅
# 因命令行多了一个 ID 就让 Windows 在下次启动看到整机突变。
if [[ -n "${STEALTH_PLATFORM_ID:-}" &&
      "${PLATFORM_ID:-}" != "$STEALTH_PLATFORM_ID" ]]; then
    echo "ERROR: 实例 $INSTANCE 的 profile 平台为 ${PLATFORM_ID:-unknown}，与指定平台 $STEALTH_PLATFORM_ID 不一致" >&2
    echo "       如确需更换整机身份，请备份后显式追加 --reroll。" >&2
    exit 1
fi

# 首次选择与已有 profile 复用必须走同一套宿主约束；不能只依赖后面的 QEMU
# realize，因为测试替身或 accelerator 默认属性未必能识别跨厂商/低频画像。
stealth_validate_platform_host_constraints

# profile 只描述目标整机；最终还必须由当前宿主真实创建同型号 vCPU。该检查发生在
# qcow2、OVMF VARS、socket 等任何持久化写入之前，失败不会留下半初始化实例。
sv_validate_cpu_phys_bits
sv_validate_cpu_realize

# 此处只保留内存中的候选身份，不再立刻覆盖 profile。后续磁盘容量、所请求 TPM、
# 内存、设备参数和完整 CMD 任一门禁仍可能失败；真正提交被延迟到 sv-assemble.sh
# 完成参数组装之后、启动 QEMU 之前，避免 1TB 旧盘 reroll 到 512GB 模板时先丢
# 旧身份、再报容量错。

# -------------------------------------------------------------------
# RAM 解析（必须在 profile 加载之后）。优先级：
#   1. 显式 --ram=N / 环境 RAM=N    ← 命令行最高优先级（本次启动临时覆盖）
#   2. profile.MEM_TOTAL_MB         ← 持久化值，跨重启稳定（推荐，扩容走这里）
#   3. 4096                         ← 都没有时的历史兜底（老 profile 缺字段）
# 把内存总量当硬件身份的一部分钉在 profile 里，避免"忘带 --ram → 4GB↔8GB 漂移"
# 被反作弊当成硬件指纹变化。要把某台 VM 扩到 8GB：在它的 profile 写 MEM_TOTAL_MB=8192
# （8192=2×4GB 双通道，两条 DIMM SN 各自唯一）。
# -------------------------------------------------------------------
if [[ -z "${RAM:-}" && -n "${MEM_TOTAL_MB:-}" ]]; then
    RAM="$MEM_TOTAL_MB"
fi
: "${RAM:=4096}"

# stealth_print_profile 移到 "--- launching ---" 前，那时 VGA_DEV /
# USB_RELATIVE_MOUSE / NUM_DIMMS / PER_DIMM_MB 都已就绪，print 能反映
# 真实运行参数（不是默认 fallback）。

# -------------------------------------------------------------------
# Per-instance disk creation —— qcow2 大小**对齐 profile.NVME_SIZE_BYTES**。
# 组件目录当前只允许 C 层完整实现过的 970 PRO 512GB 组合；以后扩目录时，
# 同一个校验会继续阻止型号、固件、PCI 身份和 guest 可见容量互相矛盾。
#
# qcow2 是 thin/sparse 的，创建时只占少量宿主空间，guest 写入后才按需分配。
#
# BASE_IMAGE 克隆模式：从 base 镜像派生增量层，虚拟容量继承 base。创建后仍会
# 用 qemu-img info 做 fail-closed 校验，容量不符就拒绝启动，不能由调用者自负。
# -------------------------------------------------------------------
sv_prepare_disk

# -------------------------------------------------------------------
# Port/socket allocation (offset by INSTANCE)
# -------------------------------------------------------------------
QMP_SOCK="/tmp/qemu-stealth-${INSTANCE}.qmp"
MON_SOCK="/tmp/qemu-stealth-${INSTANCE}.mon"
: "${VNC_DISPLAY:=$(( INSTANCE - 1 ))}"      # VNC port 5900 + display (env-overridable)
SPICE_PORT=$(( 5930 + INSTANCE ))
SSH_FWD_PORT=$(( 10022 + INSTANCE ))
RDP_FWD_PORT=$(( 13389 + INSTANCE ))
# MAC: use the NIC_MAC already picked by stealth_pick_profile (Realtek/Intel/ASUS
# OUI pool). Do NOT reuse the 52:54:00 QEMU/KVM OUI — that's a one-line tell.
MAC_OVERRIDE="$NIC_MAC"

# DRY_RUN 时不删 QMP/MON socket（P1：它们可能属于正在运行的实例，删了会断控制面）。
[[ "${DRY_RUN:-0}" == "1" ]] || rm -f "$QMP_SOCK" "$MON_SOCK"

# -------------------------------------------------------------------
# OVMF firmware (UEFI SecureBoot-capable -> looks like modern PC).
# Per-instance VARS copy so each VM has its own NVRAM.
#
# Stealth build: the custom OVMF_CODE_4M_stealth.fd at deploy/firmware/
# adds PCI VEN_10DE:DEV_1C81 to QemuVideoDxe's whitelist so UEFI boot
# display still works when virtio-vga is spoofed as NVIDIA GTX 1050
# (GPU_SELFSIGNED=1 path). Without it OVMF can't find a matching GOP
# driver and you stare at "Display output is not active" until
# viogpudo.sys loads inside Windows. Falls back to Ubuntu's stock
# OVMF_CODE_4M.fd if the stealth build is missing.
# -------------------------------------------------------------------
STEALTH_OVMF="$(dirname "$0")/../firmware/OVMF_CODE_4M_stealth.fd"
# OVMF_CODE 可被 env 覆盖：
#   OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd ./start-vm.sh 3 --iso=...
#
# **ISO 装系统模式强制走 stock OVMF**：deploy/firmware/OVMF_CODE_4M_stealth.fd
# (EDK2 master build with TPM2_ENABLE + NVIDIA-1c81 GOP whitelist) 的 ISO9660
# driver 在 Windows ISO（UDF/ISO9660 hybrid，主表只含 README.TXT）上的行为
# 退化：`if exist FS0:\sources\install.wim` 始终 false，导致 chainload 失败。
# stock Ubuntu OVMF 2.70 同样 build with TPM2_ENABLE，且没那个 ISO9660 退化，
# 装系统过得去。装好系统后 (BOOT=disk) 再用 stealth fd 也无所谓——OVMF NVRAM
# 里的 Boot#### 已指向 Windows Boot Manager，BdsDxe 不再 walk ISO9660。
if [[ -z "${OVMF_CODE:-}" ]]; then
    if [[ "$BOOT" == "iso" ]]; then
        OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
    elif [[ -f "$STEALTH_OVMF" ]]; then
        OVMF_CODE="$(readlink -f "$STEALTH_OVMF")"
    else
        OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi

# -------------------------------------------------------------------
# 伪 BGRT (Boot Graphics Resource Table)
#
# 裸金属 PC 出厂都有 BGRT（厂商启动 logo 位图描述符），反作弊扫 ACPI 表树
# 发现没有 BGRT 是弱信号"这台机器不是真 OEM"。OVMF 不提供 BGRT，所以我们
# 用 -acpitable 注入一个 status=migrated 的 20 字节末态 BGRT，OEMID 对齐
# 主板 BIOS 的 "ALASKA / A M I  "（与 aml-build.h 一致）。
#
# 注意：BGRT body 仅 20 字节，不含 logo bitmap——OS 接管后地址清零是真实
# 末态，反作弊只看 BGRT **存在**且 OEMID 一致，不会去 deref Image Address。
# 文件不存在时 ACPI_ARGS 为空数组，cmdline 拼出来等于零参数，不影响其它路径。
# -------------------------------------------------------------------
BGRT_BIN="$(dirname "$0")/../firmware/bgrt.bin"
SSDT_THERMAL_AML="$(dirname "$0")/../firmware/ssdt-thermal.aml"
ACPI_ARGS=()
if [[ -f "$BGRT_BIN" ]]; then
    ACPI_ARGS+=(
        -acpitable "sig=BGRT,rev=1,oem_id=ALASKA,oem_table_id=A M I   ,data=$BGRT_BIN"
    )
fi
# 伪 SSDT：注入一个 \_SB.TZQE 热区 + \_SB.FANE 风扇，让裸金属画像完整。
# 文件不存在时跳过；不致命（仅意味着 guest 内 Win32_TemperatureProbe 空）。
# 用 `-acpitable file=` 形式——iasl 编译出来的 AML 已含完整 SSDT 表头 +
# checksum，QEMU 直接挂上去即可，不需要重算 header。
if [[ -f "$SSDT_THERMAL_AML" ]]; then
    ACPI_ARGS+=(
        -acpitable "file=$SSDT_THERMAL_AML"
    )
fi
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
OVMF_VARS="$VM_DIR/ovmf-vars.fd"
if [[ ! -f "$OVMF_VARS" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ">> ovmf-vars:   [DRY_RUN] 跳过拷贝 $OVMF_VARS"
    else
        cp "$OVMF_VARS_SRC" "$OVMF_VARS"
    fi
fi
