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
# **重要顺序**：profile 必须在磁盘创建**之前**加载，因为 qcow2 大小
# 要按 profile.NVME_SIZE_BYTES 来——profile 抽到 "Samsung 980 1TB"
# 就建 1TB qcow2、抽到 "970 PRO 512GB" 就建 512GB，Win32_DiskDrive
# Model 和 Size 才会自洽。历史上这俩 block 顺序反了，profile 1TB +
# 实盘 512GB 的反作弊指纹隐患由此而来。
# -------------------------------------------------------------------
if (( _cli_reroll )); then
    echo ">> --reroll: regenerating hardware identity for instance $INSTANCE"
    rm -f "$PROFILE_FILE"
fi

if stealth_have_profile "$PROFILE_FILE"; then
    stealth_load_profile "$PROFILE_FILE"
    echo ">> profile:     loaded from $PROFILE_FILE"
else
    stealth_pick_profile
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ">> profile:     [DRY_RUN] 生成内存身份，未落盘 $PROFILE_FILE"
    else
        stealth_save_profile "$PROFILE_FILE"
        echo ">> profile:     NEW identity saved to $PROFILE_FILE"
    fi
fi

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
# 之前硬编码 512000000000（512 GB），但 profile 抽到 "Samsung 980 1TB" 时
# Windows WMI 看 Model=1TB / Size=476 GiB 跨向量矛盾。现在按 profile 字段建。
#
# qcow2 是 thin/sparse 的——1TB 镜像首次只占 ~200KB host 空间，guest 写多少
# 实际才占多少；不必担心 1TB 镜像吃光物理盘。
#
# BASE_IMAGE 克隆模式：从 base 镜像派生增量层，size 跟 base 一致，与
# NVME_SIZE_BYTES 无关（克隆场景下用户自负 size 一致性）。
# -------------------------------------------------------------------
if [[ ! -f "$DISK" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ">> disk:        [DRY_RUN] 跳过创建 $DISK"
    elif [[ -n "${BASE_IMAGE:-}" ]]; then
        if [[ ! -f "$BASE_IMAGE" ]]; then
            echo "ERROR: BASE_IMAGE='$BASE_IMAGE' 不存在" >&2
            exit 1
        fi
        echo ">> 从 base 镜像克隆: $BASE_IMAGE"
        echo ">>   -> $DISK (qcow2 增量层)"
        "$QEMU_IMG" create -f qcow2 \
            -F qcow2 -b "$BASE_IMAGE" "$DISK" >/dev/null
    else
        # 此时 profile 已加载，NVME_SIZE_BYTES 一定有值（pick_profile 写、
        # 或 load_profile 按 NVME_MODEL 兜底推导）。再加 : 兜底防御退化路径。
        : "${NVME_SIZE_BYTES:=512000000000}"
        size_gib=$(( NVME_SIZE_BYTES / 1024 / 1024 / 1024 ))
        echo ">> creating fresh qcow2 at $DISK"
        echo ">>   model     : ${NVME_MODEL:-unknown}"
        echo ">>   raw bytes : $NVME_SIZE_BYTES  (~${size_gib} GiB Windows-side)"
        "$QEMU_IMG" create -f qcow2 -o preallocation=off,cluster_size=65536 \
            "$DISK" "$NVME_SIZE_BYTES"
    fi
fi

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
