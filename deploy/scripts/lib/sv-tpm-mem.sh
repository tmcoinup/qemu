# shellcheck shell=bash disable=SC2034,SC2054
# 中文注释：本文件由 start-vm source，数组会在后续组装片段中消费；QEMU
# 参数中的逗号是同一个 argv 元素的一部分，不是 shell 数组分隔符。
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
# 缺 swtpm/swtpm-tools 时：兼容模式告警并跳过；STRICT_HARDWARE=1 默认直接拒绝，
# 不能把请求了 TPM 的 profile 静默启动成无 TPM 客机。
# -------------------------------------------------------------------
# TPM 默认启用（2026-05 stealth OVMF 已加 -D TPM2_ENABLE=TRUE 重 build，
# Tcg2Dxe / Tcg2Pei / Tcg2ConfigDxe / Tcg2PlatformDxe 模块全在）。
# guest 看到 tpm-crb 设备，Win 加载 TPM 驱动 + tpm.msc / Get-Tpm 全部正常。
# 设 TPM=0 显式关掉（如果 OVMF 切回不支持 TPM 的旧 fd，或者想模拟"用户没在
# BIOS 启用 fTPM"的状态——B350 / H310 / H410 入门主板出厂默认就是关的）。
# -------------------------------------------------------------------
# 中文注释：本文件由 start-vm source，HERE 在入口脚本中解析为绝对目录。
# shellcheck disable=SC1091
source "$HERE/lib/sv-swtpm-lifecycle.sh"
# shellcheck source=sv-tpm-private-ca.sh
source "$HERE/lib/sv-tpm-private-ca.sh"

# 内存 preflight 护栏（防 OOM-kill 连锁）—— 必须在起 swtpm daemon 之前，
# 否则拒绝启动时会漏一个 swtpm 孤儿（见 project_swtpm_orphan_lock）。
# prealloc 已关→VM 按需吃内存，但最坏仍会摸满 -m=${RAM}M。起 QEMU 前估算
# 可用物理(MemAvailable)+空闲 swap 能否再容下本 VM：
#   · 够          → 放行
#   · 紧(吃 host 余量) → WARN 但继续
#   · 连 RAM+swap 都装不下 → 拒绝（OOM-kill 会随机杀进程，可能杀掉别的 VM）
# 旁路：MEM_GUARD=0 整体关闭；MEM_FORCE=1 越过硬拒绝。
# -------------------------------------------------------------------
if [[ "${DRY_RUN:-0}" != "1" && "${MEM_GUARD:-1}" != "0" && "${RAM:-0}" -gt 0 ]]; then
    _avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    _swapfree_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    _req_kb=$(( RAM * 1024 ))
    _margin_kb=$(( 2 * 1024 * 1024 ))           # 2 GiB host 余量
    _have_kb=$(( _avail_kb + _swapfree_kb ))
    if (( _have_kb < _req_kb + _margin_kb )); then
        _running=$(pgrep -af 'qemu-system-x86_64 -name win10' 2>/dev/null \
                   | grep -v inhibit | grep -oE 'win10-[0-9]+' | sort -u | tr '\n' ' ' || true)
        echo ">> ⚠ 内存护栏: 可用 $(( _have_kb/1024 )) MiB (物理 $(( _avail_kb/1024 )) + swapFree $(( _swapfree_kb/1024 ))) < 需求 ${RAM} + 余量 2048 MiB" >&2
        echo ">>   已在跑: ${_running:-（无）}；再起本台有 OOM 风险（OOM-kill 随机杀进程，含别的 VM）" >&2
        if (( _have_kb < _req_kb )); then
            if [[ "${MEM_FORCE:-0}" == "1" ]]; then
                echo ">>   MEM_FORCE=1 → 强行继续（风险自负）" >&2
            else
                echo ">> ✗ 物理内存+swap 都装不下 ${RAM}M，拒绝启动以保护正在运行的 VM。" >&2
                echo ">>   先 ./stop-vm.sh <N> 停一台，或 MEM_FORCE=1 覆盖后重试。" >&2
                exit 1
            fi
        fi
    else
        echo ">> 内存护栏:   可用 $(( _have_kb/1024 )) MiB ≥ 需求 ${RAM}+2048 MiB，放行"
    fi
fi

TPM_ARGS=()
if [[ "${TPM:-1}" == "0" ]]; then
    : # 显式禁用
elif command -v swtpm >/dev/null 2>&1 \
    && command -v swtpm_setup >/dev/null 2>&1 \
    && command -v swtpm_localca >/dev/null 2>&1; then
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
    # state、CA 与配置全部限制在当前实例。系统级 /var/lib/swtpm-localca 保持
    # root/tss 所有，绝不递归 chown 给启动 VM 的普通用户。
    if ! sv_tpm_prepare_private_ca "$VM_DIR"; then
        echo "ERROR: 无法准备每实例 swtpm 私有 CA" >&2
        exit 1
    fi
    # 启动参数、runtime 登记和 stop/reaper 必须共享同一个规范化 state 路径。
    # 这里同时验证 VM_DIR/state 的 owner、权限和符号链接，避免 daemon 在校验
    # 路径与实际写入路径之间产生别名。
    if ! TPM_STATE_DIR="$(sv_swtpm_prepare_state_dir "$VM_DIR/tpm-state")"; then
        echo "ERROR: TPM state 目录不是当前用户的私有规范目录: $VM_DIR/tpm-state" >&2
        exit 1
    fi
    if ! TPM_SOCK="$(sv_swtpm_peer_path "$VM_DIR/tpm-sock" "$TPM_STATE_DIR" tpm-sock)" \
        || ! TPM_LOG="$(sv_swtpm_peer_path "$VM_DIR/tpm.log" "$TPM_STATE_DIR" tpm.log)"; then
        echo "ERROR: TPM socket/log 必须位于经过校验的 VM_DIR 内且不能是符号链接" >&2
        exit 1
    fi
    TPM_SETUP_CONFIG="$VM_DIR/tpm-config/swtpm_setup.conf"
    TPM_CA_DIR="$VM_DIR/tpm-ca"

    # --- 清理上一轮被 SIGKILL 留下的孤儿 swtpm（关键护栏）---
    # QEMU 被强杀(KILL)时它的 swtpm daemon 不会被回收，会继续持有本实例
    # tpm-state 的 NVRAM flock。下次启动时新 swtpm 能应答控制通道（打印
    # "ready"），但 QEMU 发 CMD_INIT 抢不到锁 → tpm.log "Could not lock
    # access to lockfile" → "TPM result for CMD_INIT: 0x9 operation failed"，
    # QEMU 秒退（exit status 1）；每次重试还会再叠加一个孤儿。
    # 这里在起 daemon 前按 runtime 登记的 canonical state 精确清理。登记可能
    # 指向上一轮使用的另一个自定义 VM_DIR，因此不能只检查本轮目标目录。
    _registered_tpm_state=""
    _tpm_runtime_file="$(sv_swtpm_runtime_state_file "$INSTANCE")" || {
        echo "ERROR: 无法解析 swtpm 私有 runtime 状态文件" >&2
        exit 1
    }
    if [[ -e "$_tpm_runtime_file" || -L "$_tpm_runtime_file" ]]; then
        if ! _registered_tpm_state="$(sv_swtpm_read_registered_state_dir "$INSTANCE")"; then
            echo "ERROR: swtpm runtime 状态文件类型、权限或路径校验失败: $_tpm_runtime_file" >&2
            exit 1
        fi
    fi
    _tpm_state_candidates=("$TPM_STATE_DIR")
    if [[ -n "$_registered_tpm_state" && "$_registered_tpm_state" != "$TPM_STATE_DIR" ]]; then
        _tpm_state_candidates+=("$_registered_tpm_state")
    fi
    for _candidate_state in "${_tpm_state_candidates[@]}"; do
        _candidate_sock="${_candidate_state%/*}/tpm-sock"
        if pgrep -af 'qemu-system' 2>/dev/null | grep -qF -- "path=$_candidate_sock"; then
            continue
        fi
        _tpm_orphans=()
        mapfile -t _tpm_orphans < <(
            sv_swtpm_instance_pids "$INSTANCE" "$_candidate_state"
        )
        if (( ${#_tpm_orphans[@]} > 0 )); then
            echo ">> swtpm:       清理孤儿 swtpm（state=$_candidate_state）: ${_tpm_orphans[*]}"
            sv_swtpm_stop_pids "$INSTANCE" "$_candidate_state" "${_tpm_orphans[@]}"
        fi
    done

    # 首次启动 / state 不完整时初始化 TPM 2.0 state（manufacturer info、EK 证书）。
    # 完整初始化产出 ~6KB permall（含 RSA EK + ECC EK + Platform cert + sha256 PCR banks）；
    # 1.5KB 左右的"空 init"代表证书创建阶段失败；Windows 加载 TPM 驱动时
    # 找不到 EK 会报无兼容 TPM，因此必须重建并在严格模式验证完整产物。
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
        echo ">> swtpm:       初始化 TPM 2.0 state at $TPM_STATE_DIR"
        if ! swtpm_setup --tpm2 --tpmstate "$TPM_STATE_DIR" \
                --config "$TPM_SETUP_CONFIG" \
                --create-ek-cert --create-platform-cert --lock-nvram \
                --overwrite 2>&1 | tail -5; then
            echo ">> WARN: swtpm_setup 失败；guest 将无法获得完整 TPM" >&2
            if [[ "${STRICT_HARDWARE:-0}" == "1" ]]; then
                echo "ERROR: 严格模式拒绝无完整 EK/Platform certificate 的 TPM" >&2
                exit 1
            fi
        fi
        # 二次确认大小：成功 init 应该 > 3KB
        if [[ -f "$TPM_STATE_DIR/tpm2-00.permall" ]]; then
            _sz=$(stat -c%s "$TPM_STATE_DIR/tpm2-00.permall")
            echo ">> swtpm:       permall=${_sz} bytes (含 EK + Platform cert 应 > 3000)"
        fi
        if [[ ! -f "$TPM_STATE_DIR/tpm2-00.permall" ]] \
            || (( $(stat -c%s "$TPM_STATE_DIR/tpm2-00.permall" 2>/dev/null || echo 0) < 3000 )); then
            echo "ERROR: swtpm 初始化未生成完整 EK/Platform certificate state" >&2
            if [[ "${STRICT_HARDWARE:-0}" == "1" ]]; then
                exit 1
            fi
        fi
        # swtpm_localca 生成的公开证书可能遵循系统 umask；目录本身已是 0700，
        # 再统一去掉 group/other 位，确保备份或目录迁移后仍保持最小权限。
        chmod -R go-rwx "$TPM_STATE_DIR" "$TPM_CA_DIR" "$VM_DIR/tpm-config"
    fi

    # 启动 swtpm daemon；clear-socket 避免 stale unix socket 残留
    rm -f "$TPM_SOCK"
    if ! sv_swtpm_start_daemon "$INSTANCE" "$TPM_STATE_DIR" "$TPM_SOCK" "$TPM_LOG"; then
        echo "ERROR: swtpm daemon 启动或 runtime state 登记失败" >&2
        exit 1
    fi
    # 等 socket 出现（最多 2 秒）
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -S "$TPM_SOCK" ]] && break
        sleep 0.2
    done
    if [[ ! -S "$TPM_SOCK" ]]; then
        echo ">> WARN: swtpm 启动超时（2s），跳过 TPM——guest 将看不到 TPM 设备" >&2
        _tpm_failed_pids=()
        mapfile -t _tpm_failed_pids < <(
            sv_swtpm_instance_pids "$INSTANCE" "$TPM_STATE_DIR"
        )
        sv_swtpm_stop_pids "$INSTANCE" "$TPM_STATE_DIR" "${_tpm_failed_pids[@]}"
        sv_swtpm_unregister_state_dir "$INSTANCE" "$TPM_STATE_DIR" || true
        if [[ "${STRICT_HARDWARE:-0}" == "1" ]]; then
            echo "ERROR: 严格模式拒绝 TPM daemon 启动失败" >&2
            exit 1
        fi
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
    echo ">> WARN: swtpm/swtpm-tools 未完整安装，guest 将无 TPM 2.0。建议：" >&2
    echo ">>       sudo apt install swtpm swtpm-tools && 重启此脚本" >&2
    if [[ "${STRICT_HARDWARE:-0}" == "1" ]]; then
        echo "ERROR: 严格模式且 TPM=1，不能静默跳过 TPM" >&2
        exit 1
    fi
fi

# DIMM 拓扑与合法容量由可单测的 manifest 解析器统一计算。
# shellcheck source=stealth-memory-topology.sh
source "$HERE/lib/stealth-memory-topology.sh"
stealth_resolve_memory_topology

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
