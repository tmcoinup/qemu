# -------------------------------------------------------------------
# TPM 2.0 emulator (swtpm)
#
# 为什么必须装：Win10 21H2+ / Win11 全面铺 TPM 2.0；裸金属 UEFI 都会探到。
# Get-Tpm 返回 "Compatible TPM not found" 或 tpm.msc 空白，配合其它指纹
# 反作弊立刻判 sandbox / VM。
#
# 实现：host 端 swtpm 后台 daemon，per-instance 状态目录在 $VM_DIR/tpm-state，
# 控制 socket 在 $VM_DIR/tpm-sock，QEMU 通过 -tpmdev emulator + -device tpm-crb
# 把 TPM 设备暴露给 guest。SecureBoot + TPM 2.0 → 现代裸金属画像完整。
#
# 缺 swtpm 时优雅降级（不致命）：跳过 TPM 设备，但打 WARN——这时反作弊会判
# "无 TPM"，建议 apt install swtpm swtpm-tools 后再启动。
# -------------------------------------------------------------------
# TPM 默认启用（2026-05 stealth OVMF 已加 -D TPM2_ENABLE=TRUE 重 build，
# Tcg2Dxe / Tcg2Pei / Tcg2ConfigDxe / Tcg2PlatformDxe 模块全在）。
# guest 看到 tpm-crb 设备，Win 加载 TPM 驱动 + tpm.msc / Get-Tpm 全部正常。
# 设 TPM=0 显式关掉（如果 OVMF 切回不支持 TPM 的旧 fd，或者想模拟"用户没在
# BIOS 启用 fTPM"的状态——B350 / H310 / H410 入门主板出厂默认就是关的）。
TPM_ARGS=()
if [[ "${TPM:-1}" == "0" ]]; then
    : # 显式禁用
elif command -v swtpm >/dev/null 2>&1; then
    TPM_STATE_DIR="$VM_DIR/tpm-state"
    TPM_SOCK="$VM_DIR/tpm-sock"
    TPM_LOG="$VM_DIR/tpm.log"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        # dry-run（P1#1）：不初始化 TPM state、不起 swtpm daemon，仍输出 TPM 设备
        # 参数让 argv 完整（不会启动 QEMU，所以 socket 不存在无妨）。
        TPM_ARGS=(
            -chardev "socket,id=chrtpm,path=$TPM_SOCK"
            -tpmdev emulator,id=tpm0,chardev=chrtpm
            -device tpm-crb,tpmdev=tpm0
        )
        echo ">> swtpm:       [DRY_RUN] 跳过 init/daemon，仅输出 TPM 设备参数"
    else
    mkdir -p "$TPM_STATE_DIR"

    # 首次启动 / state 不完整时初始化 TPM 2.0 state（manufacturer info、EK 证书）。
    # 完整初始化产出 ~6KB permall（含 RSA EK + ECC EK + Platform cert + sha256 PCR banks）；
    # 1.5KB 左右的"空 init"代表 swtpm_localca 创证书阶段失败（多半是
    # /var/lib/swtpm-localca/ 只 root 能写）—— Windows 加载 TPM 驱动时找不到 EK
    # 就报 "tpm.msc: 找不到兼容的 TPM"，必须重 init。
    _need_tpm_init=0
    if [[ ! -f "$TPM_STATE_DIR/tpm2-00.permall" ]]; then
        _need_tpm_init=1
    elif (( $(stat -c%s "$TPM_STATE_DIR/tpm2-00.permall") < 3000 )); then
        echo ">> swtpm:       permall < 3KB（空 init），强制重新创建 EK / Platform cert"
        _need_tpm_init=1
        # 备份再清，万一是 stealth 重要数据
        mv "$TPM_STATE_DIR/tpm2-00.permall" "$TPM_STATE_DIR/tpm2-00.permall.empty.bak.$(date +%s)" 2>/dev/null || true
    fi

    if (( _need_tpm_init )); then
        # 防御性：swtpm_localca statedir 默认 0750 swtpm:root；ubuntu 没权限会
        # 静默跳过证书创建。提前修一次（如果是 root 跑的就跳过，sudo 才有意义）。
        if [[ -d /var/lib/swtpm-localca && ! -w /var/lib/swtpm-localca ]]; then
            echo ">> swtpm:       /var/lib/swtpm-localca 不可写，尝试 sudo chown ubuntu"
            if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
                sudo chown -R "$(id -u):$(id -g)" /var/lib/swtpm-localca 2>/dev/null || true
            else
                echo ">> WARN: 没有免密 sudo，跑 'sudo chown -R \$(id -u):\$(id -g) /var/lib/swtpm-localca' 一次后重启"
            fi
        fi

        echo ">> swtpm:       初始化 TPM 2.0 state at $TPM_STATE_DIR"
        if ! swtpm_setup --tpm2 --tpmstate "$TPM_STATE_DIR" \
                --create-ek-cert --create-platform-cert --lock-nvram \
                --overwrite 2>&1 | tail -5; then
            echo ">> WARN: swtpm_setup 失败；guest tpm.msc 会报找不到 TPM"
        fi
        # 二次确认大小：成功 init 应该 > 3KB
        if [[ -f "$TPM_STATE_DIR/tpm2-00.permall" ]]; then
            _sz=$(stat -c%s "$TPM_STATE_DIR/tpm2-00.permall")
            echo ">> swtpm:       permall=${_sz} bytes (含 EK + Platform cert 应 > 3000)"
        fi
    fi

    # 启动 swtpm daemon；clear-socket 避免 stale unix socket 残留
    rm -f "$TPM_SOCK"
    swtpm socket \
        --tpmstate dir="$TPM_STATE_DIR" \
        --ctrl type=unixio,path="$TPM_SOCK" \
        --tpm2 \
        --log file="$TPM_LOG",level=20 \
        --daemon
    # 等 socket 出现（最多 2 秒）
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -S "$TPM_SOCK" ]] && break
        sleep 0.2
    done
    if [[ ! -S "$TPM_SOCK" ]]; then
        echo ">> WARN: swtpm 启动超时（2s），跳过 TPM——guest 将看不到 TPM 设备" >&2
    else
        TPM_ARGS=(
            -chardev "socket,id=chrtpm,path=$TPM_SOCK"
            -tpmdev emulator,id=tpm0,chardev=chrtpm
            -device tpm-crb,tpmdev=tpm0
        )
        echo ">> swtpm:       TPM 2.0 ready (sock=$TPM_SOCK, log=$TPM_LOG)"
    fi
    fi
else
    echo ">> WARN: swtpm 未安装，guest 将无 TPM 2.0；反作弊会判 sandbox。建议：" >&2
    echo ">>       sudo apt install swtpm swtpm-tools && 重启此脚本" >&2
fi

# -------------------------------------------------------------------
# DIMM 拓扑决策（裸金属"双卡槽主板"画像）：
#
# - RAM ≤ 4096 MiB：1 条 DIMM 占满，**1 个卡槽空**（最常见的低端配置）；
# - RAM > 4096 MiB：2 条 DIMM 各占总量一半，双通道。
#
# SMBIOS Type 16 num-devices **固定 2**（主板物理卡槽数不变，跟 BOARD_POOL
# 的 B350/H310 入门主板真实拓扑一致）。Type 17 由 QEMU 按 `-object
# memory-backend-*` 数量自动克隆——1 backend = 1 Type 17 记录 = 1 个
# Win32_PhysicalMemory；空槽不会单独 emit。
#
# MEM_PER_DIMM_MB 影响 stealth_smbios_args 选 2GB/4GB part 号：
#   < 4096 → MEM_PART_2G   ≥ 4096 → MEM_PART_4G
# -------------------------------------------------------------------
if (( RAM <= 4096 )); then
    NUM_DIMMS=1
    PER_DIMM_MB=$RAM
else
    NUM_DIMMS=2
    PER_DIMM_MB=$(( RAM / 2 ))
fi
export MEM_PER_DIMM_MB="$PER_DIMM_MB"
export T16_NUM_DEVICES=2   # 物理双卡槽不变，即便只插 1 条

# Override default PCI subsystem IDs for devices that don't set their own.
# **2026-05 修复**：之前 hardcoded ASUS B350-PLUS (1043:8694) 无视 BOARD_MFR；
# profile 抽到 Gigabyte/MSI/ASRock 时 SMBIOS 报 X 牌但 PCI 桥子系统全报 ASUS，
# 跨表对照即矛盾。现在 stealth_pick_profile 已经把对应板厂的 SUBSYS 写进 profile。
# - ASUS     0x1043 / 0x8694 (B350-PLUS) / 0x86C7 (ROG/X370)
# - MSI      0x1462 / board model 后缀 (7A34/7B49/7C95...)
# - Gigabyte 0x1458 / 0x5001
# - ASRock   0x1849 / 0x1230 / 0x9696
# 老 profile 缺该字段时 stealth_load_profile 会兜底回 ASUS B350-PLUS 默认值。
export QEMU_PCI_SUBSYS_VEN="${QEMU_PCI_SUBSYS_VEN:-$BOARD_SUBSYS_VEN}"
export QEMU_PCI_SUBSYS_DEV="${QEMU_PCI_SUBSYS_DEV:-$BOARD_SUBSYS_DEV}"
SMBIOS_ARGS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    SMBIOS_ARGS+=("-smbios" "$line")
done < <(stealth_smbios_args)

# AMD DF stubs only for AMD CPUs
AMD_DF_ARGS=()
if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    AMD_DF_ARGS=(
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x0,multifunction=on,device-id=0x1460
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x1,device-id=0x1461
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x2,device-id=0x1462
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x3,device-id=0x1463
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x4,device-id=0x1464
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x5,device-id=0x1465
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x6,device-id=0x1466
        -device amd-df-stub,bus=pcie.0,addr=0x18.0x7,device-id=0x1467
    )
fi

