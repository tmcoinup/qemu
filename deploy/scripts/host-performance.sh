#!/bin/bash
# ---------------------------------------------------------------------------
# host-performance.sh
#
# Host 侧一次性调优（每次 host 重启后失效，需重跑）。需要 sudo。
#
# 目标：压低 KVM 的调度 / 时钟抖动。ACE「游戏计时异常」(13-131130-8) 这类
# 仿真机时钟检测对 vCPU 服务延迟的方差很敏感——host governor=powersave 让核在
# vm-exit 间降频、halt_poll 太短导致 vCPU 唤醒延迟尖刺、THP 同步整理会把 vCPU
# 冻住几毫秒，split-lock mitigation 还会故意让触发者等待并串行。这些都会被
# 读成「计时异常」或客体卡顿。本脚本只动 host 侧旋钮，guest 看到的 CPUID /
# 品牌串 / tsc-freq / 拓扑全部不变。
#
# start-vm.sh 默认会在起 VM 前自动调用本脚本（HOST_TUNE=1，已调优则跳过）；
# 也可单独手动跑：  sudo deploy/scripts/host-performance.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# sudoers 放行的是固定 root helper；固定 PATH 并只读取位置参数，避免调用者环境中的
# 同名程序或 CPU_MAX_KHZ/KVM_HALT_POLL_NS/SPLIT_LOCK_MITIGATE
# 改变 root 写 sysfs/procfs 的行为。
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# root helper 会被 sudoers 免密放行，因此参数必须在任何写 sysfs/procfs 之前完整
# 校验。默认命令保持原来的三参数调优 ABI；protect-launcher 是独立、固定策略的
# 子命令，只允许保护调用 UID 自己、持有本项目实例生命周期锁的启动进程。
COMMAND="tune"
if [[ "${1:-}" == "protect-launcher" ]]; then
    (( $# == 4 )) || {
        echo "ERROR: 用法: $0 protect-launcher <INSTANCE> <PID> <STARTTIME>" >&2
        exit 2
    }
    COMMAND="$1"
    PROTECT_INSTANCE="$2"
    PROTECT_PID="$3"
    PROTECT_STARTTIME="$4"
    [[ "$PROTECT_INSTANCE" =~ ^[1-9][0-9]{0,9}$ ]] || {
        echo "ERROR: INSTANCE 必须是 1..10 位正整数" >&2
        exit 2
    }
    [[ "$PROTECT_PID" =~ ^[1-9][0-9]{0,9}$ ]] || {
        echo "ERROR: PID 必须是 1..10 位正整数" >&2
        exit 2
    }
    [[ "$PROTECT_STARTTIME" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: STARTTIME 必须是正整数" >&2
        exit 2
    }
else
    (( $# <= 3 )) || {
        echo "ERROR: 用法: $0 [CPU_MAX_KHZ|0] [KVM_HALT_POLL_NS] [SPLIT_LOCK_MITIGATE|0]" >&2
        exit 2
    }
    CPU_MAX_KHZ="${1:-0}"
    KVM_HALT_POLL_NS="${2:-0}"
    SPLIT_LOCK_MITIGATE="${3:-0}"
    if ! [[ "$CPU_MAX_KHZ" =~ ^[0-9]+$ ]] || \
       (( CPU_MAX_KHZ != 0 && (CPU_MAX_KHZ < 100000 || CPU_MAX_KHZ > 10000000) )); then
        echo "ERROR: CPU_MAX_KHZ 必须是 0 或 [100000,10000000] 的整数 kHz" >&2
        exit 2
    fi
    if ! [[ "$KVM_HALT_POLL_NS" =~ ^[0-9]+$ ]] || (( KVM_HALT_POLL_NS > 10000000 )); then
        echo "ERROR: KVM_HALT_POLL_NS 必须是 [0,10000000] 的整数 ns" >&2
        exit 2
    fi
    case "$SPLIT_LOCK_MITIGATE" in
        0|1) ;;
        *)
            echo "ERROR: SPLIT_LOCK_MITIGATE 必须是 0 或 1" >&2
            exit 2
            ;;
    esac
fi

if [[ $EUID -ne 0 ]]; then
    echo "rerunning with sudo..."
    # 直接以脚本路径(非 'bash 脚本')重入 sudo，命令名=脚本本身，匹配
    # /etc/sudoers.d/qemu-vmate-host 的固定 helper NOPASSWD 规则；参数原样带过去。
    exec sudo -- "$0" "$@"
fi

# Linux 的 oom_score_adj 是进程属性，fork/exec 后由后代继承，进程退出即消失。
# -500 会让普通宿主编译/桌面任务先于 VM 成为全局 OOM 候选，但不像 -1000 那样
# 把整棵 VM 树变成不可杀进程。策略值和 proc 根均固定，不能由 NOPASSWD 调用者注入。
# 安装器写入 sudoers 的目标 UID 是资源授权边界：脚本/锁校验用于防止误选和跨实例，
# 不是把该 UID 当成潜在攻击者的加密凭据；此权限只应授予本机 VM 操作者。
readonly HOST_OOM_SCORE_POLICY="-500"
readonly HOST_OOM_POLICY_NAME="oom-score-v1"
readonly PROC_ROOT="/proc"
readonly RUN_USER_ROOT="/run/user"
readonly TMP_ROOT="/tmp"

_vmate_read_proc_generation() {
    local pid="$1" stat_line rest
    local -a fields=()

    [[ -r "$PROC_ROOT/$pid/stat" ]] || return 1
    { stat_line="$(<"$PROC_ROOT/$pid/stat")"; } 2>/dev/null || return 1
    rest="${stat_line##*) }"
    read -ra fields <<<"$rest"
    (( ${#fields[@]} >= 20 )) || return 1
    [[ "${fields[0]}" =~ ^[A-Za-z]$ && "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "${fields[0]}" "${fields[19]}"
}

_vmate_private_dir_owned_by() {
    local directory="$1" expected_uid="$2"
    local owner mode

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    owner="$(stat -Lc '%u' -- "$directory" 2>/dev/null)" || return 1
    mode="$(stat -Lc '%a' -- "$directory" 2>/dev/null)" || return 1
    [[ "$owner" == "$expected_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#077) == 0 ))
}

_vmate_validate_launcher_lock() {
    local pid="$1" instance="$2" expected_uid="$3"
    local fd_path lock_path candidate base parent owner probe_fd=""

    fd_path="$PROC_ROOT/$pid/fd/8"
    [[ -e "$fd_path" ]] || return 1
    lock_path="$(realpath -e -- "$fd_path" 2>/dev/null)" || return 1

    for base in "$RUN_USER_ROOT/$expected_uid" \
            "$TMP_ROOT/qemu-stealth-$expected_uid"; do
        parent="$base/qemu-stealth"
        candidate="$parent/instance-$instance.lock"
        [[ -e "$candidate" ]] || continue
        [[ "$lock_path" == "$(realpath -e -- "$candidate" 2>/dev/null)" ]] || continue
        _vmate_private_dir_owned_by "$base" "$expected_uid" || return 1
        _vmate_private_dir_owned_by "$parent" "$expected_uid" || return 1
        [[ -f "$lock_path" && ! -L "$lock_path" ]] || return 1
        owner="$(stat -Lc '%u' -- "$lock_path" 2>/dev/null)" || return 1
        [[ "$owner" == "$expected_uid" ]] || return 1

        # FD8 指向正确文件还不够；必须已有另一 open-file-description 持有 flock。
        # 若能立即取得锁，说明目标不是已通过 sv-cli 生命周期门禁的启动器。
        exec {probe_fd}<"$lock_path" || return 1
        if flock -n "$probe_fd"; then
            flock -u "$probe_fd" 2>/dev/null || true
            exec {probe_fd}<&-
            return 1
        fi
        exec {probe_fd}<&-
        return 0
    done
    return 1
}

_vmate_validate_launcher_script() {
    local pid="$1" expected_uid="$2"
    local proc_dir exe_path bash_path bash_alt script_arg target_cwd script_path
    local script_owner script_mode fd script_open=0
    local -a argv=()

    proc_dir="$PROC_ROOT/$pid"
    exe_path="$(realpath -e -- "$proc_dir/exe" 2>/dev/null)" || return 1
    bash_path="$(realpath -e -- /bin/bash 2>/dev/null)" || return 1
    bash_alt="$(realpath -e -- /usr/bin/bash 2>/dev/null || true)"
    [[ "$exe_path" == "$bash_path" || ( -n "$bash_alt" && "$exe_path" == "$bash_alt" ) ]] \
        || return 1

    mapfile -d '' -t argv < "$proc_dir/cmdline" || return 1
    (( ${#argv[@]} >= 2 )) || return 1
    [[ "${argv[0]##*/}" == "bash" ]] || return 1
    script_arg="${argv[1]}"
    if [[ "$script_arg" != /* ]]; then
        target_cwd="$(realpath -e -- "$proc_dir/cwd" 2>/dev/null)" || return 1
        script_arg="$target_cwd/$script_arg"
    fi
    script_path="$(realpath -e -- "$script_arg" 2>/dev/null)" || return 1
    [[ "${script_path##*/}" == "start-vm.sh" && -f "$script_path" && -x "$script_path" ]] \
        || return 1
    script_owner="$(stat -Lc '%u' -- "$script_path" 2>/dev/null)" || return 1
    script_mode="$(stat -Lc '%a' -- "$script_path" 2>/dev/null)" || return 1
    # 开发工作区通常属于调用用户；发行版/只读部署也允许 root-owned 启动器。
    [[ "$script_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    if [[ "$script_owner" == "0" ]]; then
        (( (8#$script_mode & 8#022) == 0 )) || return 1
    elif [[ "$script_owner" != "$expected_uid" ]]; then
        return 1
    fi

    # Bash 打开的脚本通常位于 FD255，但不依赖这个实现细节；按 inode 扫描目标
    # 自己的 FD，要求脚本在校验时仍由该进程打开。
    for fd in "$proc_dir"/fd/*; do
        [[ -e "$fd" ]] || continue
        if [[ "$fd" -ef "$script_path" ]]; then
            script_open=1
            break
        fi
    done
    (( script_open == 1 ))
}

_vmate_validate_launcher() {
    local pid="$1" starttime="$2" instance="$3" expected_uid="$4"
    local state actual_start real_uid

    read -r state actual_start < <(_vmate_read_proc_generation "$pid") || return 1
    [[ "$actual_start" == "$starttime" \
       && "$state" != "Z" && "$state" != "z" \
       && "$state" != "X" && "$state" != "x" ]] || return 1
    real_uid="$(awk '$1 == "Uid:" { print $2; exit }' \
        "$PROC_ROOT/$pid/status" 2>/dev/null)" || return 1
    [[ "$real_uid" == "$expected_uid" ]] || return 1
    _vmate_validate_launcher_script "$pid" "$expected_uid" || return 1
    _vmate_validate_launcher_lock "$pid" "$instance" "$expected_uid"
}

_vmate_protect_launcher() {
    local expected_uid="${SUDO_UID:-0}"
    local score_path current_score desired_score actual_score score_fd=""

    [[ "$expected_uid" =~ ^[0-9]{1,10}$ ]] || {
        echo "ERROR: 无法确定 sudo 调用用户 UID" >&2
        return 1
    }
    _vmate_validate_launcher \
        "$PROTECT_PID" "$PROTECT_STARTTIME" "$PROTECT_INSTANCE" "$expected_uid" || {
        echo "ERROR: OOM 保护目标不是当前用户持锁的 start-vm.sh 启动器" >&2
        return 1
    }

    score_path="$PROC_ROOT/$PROTECT_PID/oom_score_adj"
    [[ -f "$score_path" && ! -L "$score_path" && -r "$score_path" && -w "$score_path" ]] || {
        echo "ERROR: 当前 Linux 内核不提供可写 oom_score_adj" >&2
        return 1
    }
    current_score="$(<"$score_path")"
    if ! [[ "$current_score" =~ ^-?[0-9]+$ ]] \
       || (( current_score < -1000 || current_score > 1000 )); then
        echo "ERROR: 目标 oom_score_adj 当前值无效" >&2
        return 1
    fi
    desired_score="$HOST_OOM_SCORE_POLICY"
    (( current_score < desired_score )) && desired_score="$current_score"

    # 先打开旧 generation 的 proc inode，再复核 PID/starttime/脚本/实例锁；即使
    # PID 在两次检查间退出并复用，后续写也不会落到新进程的 proc 文件上。
    exec {score_fd}<>"$score_path" || {
        echo "ERROR: 无法打开目标 oom_score_adj" >&2
        return 1
    }
    if ! _vmate_validate_launcher \
            "$PROTECT_PID" "$PROTECT_STARTTIME" "$PROTECT_INSTANCE" "$expected_uid"; then
        exec {score_fd}>&-
        echo "ERROR: OOM 保护写入前目标 generation 已变化" >&2
        return 1
    fi
    if ! printf '%s\n' "$desired_score" >&"$score_fd"; then
        exec {score_fd}>&-
        echo "ERROR: 写入目标 oom_score_adj 失败" >&2
        return 1
    fi
    exec {score_fd}>&-

    _vmate_validate_launcher \
        "$PROTECT_PID" "$PROTECT_STARTTIME" "$PROTECT_INSTANCE" "$expected_uid" || {
        echo "ERROR: OOM 保护写入后目标 generation 已变化" >&2
        return 1
    }
    actual_score="$(<"$score_path")"
    [[ "$actual_score" == "$desired_score" ]] || {
        echo "ERROR: oom_score_adj 写入后复核失败" >&2
        return 1
    }
    printf 'host-memory-protect: policy=%s score=%s pid=%s\n' \
        "$HOST_OOM_POLICY_NAME" "$desired_score" "$PROTECT_PID"
}

if [[ "$COMMAND" == "protect-launcher" ]]; then
    _vmate_protect_launcher
    exit
fi

# power-profiles-daemon 会在首次启动时按自己的持久状态重新应用 governor/EPP。
# Intel P-State active 模式下，PPD 刻意保持 governor=powersave，再用
# energy_performance_preference=performance 表达性能模式。若随后强写
# governor=performance，内核会拒绝 PPD 写入非零 EPP，导致桌面的均衡/节电模式
# 看似选中、实际立即回滚。先恢复 PPD 所要求的 governor，再通过公开 CLI 选
# performance；成功后不再用 sysfs 覆盖 PPD。
#
# 没有 PPD 的服务器、精简发行版和容器仍走原 sysfs 路径；PPD 启动或切换失败也只
# 清晰告警并返回成功，让既有 governor/frequency fallback 继续执行，不扩大 helper
# 在不同发行版上的硬依赖。
_vmate_prepare_ppd_intel_pstate_governors() {
    local policy_root="${1:-/sys/devices/system/cpu/cpufreq}"
    local policy driver governor current

    for policy in "$policy_root"/policy*; do
        [[ -d "$policy" ]] || continue
        driver="$policy/scaling_driver"
        governor="$policy/scaling_governor"
        [[ -r "$driver" && -e "$policy/energy_performance_preference" ]] || continue
        [[ "$(<"$driver")" == "intel_pstate" ]] || continue
        [[ -w "$governor" ]] || {
            echo ">> power profile: ⚠ 无法写入 ${policy##*/}/scaling_governor" >&2
            return 1
        }
        current="$(<"$governor")"
        if [[ "$current" != "powersave" ]] &&
           ! printf '%s\n' powersave > "$governor"; then
            echo ">> power profile: ⚠ 写入 ${policy##*/}/scaling_governor 失败" >&2
            return 1
        fi
    done
}

_vmate_ppd_controls_cpu=0
_vmate_set_ppd_performance() {
    local current_profile=""

    if ! command -v systemctl >/dev/null 2>&1 ||
       ! command -v powerprofilesctl >/dev/null 2>&1; then
        echo ">> power profile: PPD 工具未安装（继续使用 sysfs governor）"
        return 0
    fi

    if ! systemctl start power-profiles-daemon.service; then
        echo ">> power profile: ⚠ 无法启动 power-profiles-daemon（继续使用 sysfs governor）"
        return 0
    fi
    if ! systemctl is-active --quiet power-profiles-daemon.service; then
        echo ">> power profile: ⚠ power-profiles-daemon 启动后未处于 active（继续使用 sysfs governor）"
        return 0
    fi
    if ! _vmate_prepare_ppd_intel_pstate_governors; then
        echo ">> power profile: ⚠ 无法恢复 PPD 所需的 Intel P-State governor（继续使用 sysfs governor）"
        return 0
    fi
    if ! powerprofilesctl set performance; then
        echo ">> power profile: ⚠ 无法切换到 performance（继续使用 sysfs governor）"
        return 0
    fi
    if ! current_profile="$(powerprofilesctl get)"; then
        echo ">> power profile: ⚠ 无法复核当前 profile（继续使用 sysfs governor）"
        return 0
    fi
    if [[ "$current_profile" != "performance" ]]; then
        echo ">> power profile: ⚠ 切换后仍为 ${current_profile:-<空>}（继续使用 sysfs governor）"
        return 0
    fi

    _vmate_ppd_controls_cpu=1
    echo ">> power profile: performance（daemon 已同步，保留其 governor/EPP 控制）"
}

# 0) x86 split-lock 限速：默认取消内核对触发任务施加的故意等待和单核串行。
#    Windows 驱动、解压或校验路径在 KVM vCPU 中触发 split lock 时，默认值 1
#    会让客体看起来像「磁盘写入卡死」，即使宿主块设备完全空闲。值 0 仍会在
#    kernel log 中警告，但会降低对恶意 split-lock 工作负载的 DoS 防护；需要该防护
#    的多租户宿主可通过第三参数显式设回 1。
_split_lock_path=/proc/sys/kernel/split_lock_mitigate
if [[ -e "$_split_lock_path" ]]; then
    printf '%s\n' "$SPLIT_LOCK_MITIGATE" > "$_split_lock_path"
    _split_lock_actual="$(<"$_split_lock_path")"
    if [[ "$_split_lock_actual" != "$SPLIT_LOCK_MITIGATE" ]]; then
        echo "ERROR: split_lock_mitigate 写入后未达到目标值" >&2
        exit 1
    fi
    echo ">> split lock : mitigate=${SPLIT_LOCK_MITIGATE}$(
        [[ "$SPLIT_LOCK_MITIGATE" == 0 ]] && echo '（取消故意降速）' || echo '（保留内核防护）'
    )"
else
    echo ">> split lock : 当前内核不提供 split_lock_mitigate，跳过"
fi

# PPD 必须先完成启动与 profile 切换；否则它晚于 sysfs 写入启动时会覆盖 governor。
_vmate_set_ppd_performance

# 1) CPU 性能策略：PPD 成功时由其用 governor=powersave + EPP=performance 管理
#    Intel HWP；仅在 PPD 不存在或失败时才回退到传统 performance governor。
if (( _vmate_ppd_controls_cpu )); then
    echo ">> governor   : 由 PPD 管理（Intel P-State: powersave + performance EPP）"
else
    _gov_changed=0
    for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -w "$p" ]] || continue
        if [[ "$(<"$p")" != "performance" ]]; then
            printf '%s\n' performance > "$p"
            _gov_changed=1
        fi
    done
    echo ">> governor   : performance$([[ $_gov_changed == 0 ]] && echo '（本就是）')"
fi

# 1b) (可选) 按伪装 CPU 的上限频率封顶 scaling_max_freq。
#     host(Ryzen7 5800) boost 4.6GHz 会远超伪装的 Ryzen3-1200 3.4GHz——guest 在
#     固定 tsc-freq(3.1GHz) 下实测吞吐就会超过它自报的 SMBIOS Type4 max-speed，
#     等于「单位时钟干的活比这颗 CPU 该有的多」= 变速器 / 计时异常(13-131130-8)
#     的破绽。把 scaling_max_freq 压到伪装 CPU 上限后，guest 再也跑不出超规格的
#     速度；PPD performance EPP 或传统 performance governor 都会积极升频，而该上限
#     保证实际频率不会超过目标规格。
#     CPU_MAX_KHZ 由 start-vm.sh 按当前实例 CPU_MAX_MHZ 传入；留空=不封顶。
if (( CPU_MAX_KHZ > 0 )); then
    _cap="$CPU_MAX_KHZ"
    _hwmin=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo 0)
    _hwmax=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
    (( _hwmax > 0 && _cap > _hwmax )) && _cap=$_hwmax     # clamp 到硬件可达
    (( _hwmin > 0 && _cap < _hwmin )) && _cap=$_hwmin
    for pol in /sys/devices/system/cpu/cpu*/cpufreq; do
        [[ -w "$pol/scaling_max_freq" ]] || continue
        # 目标比当前 min 还低时先放低 min，否则 max 写不进去
        _smin=$(cat "$pol/scaling_min_freq" 2>/dev/null || echo 0)
        if [[ "$_smin" =~ ^[0-9]+$ ]] && (( _smin > _cap && _hwmin > 0 )); then
            echo "$_hwmin" > "$pol/scaling_min_freq" 2>/dev/null || true
        fi
        echo "$_cap" > "$pol/scaling_max_freq" 2>/dev/null || true
    done
    echo ">> freq cap  : scaling_max_freq=$(( _cap/1000 )) MHz (按伪装 CPU 上限封顶, 防超规格)"
else
    echo ">> freq cap  : 不封顶（CPU_MAX_KHZ 未设；满 boost）"
fi

# 2) THP：保留 madvise（memfd 可借 THP 降 TLB miss），但 defrag=never——避免
#    khugepaged / 同步整理 stall 把 vCPU 冻住几毫秒 → 计时尖刺。
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never    > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
echo ">> THP       : enabled=madvise defrag=never"

# 3) KVM halt-poll：默认 0，避免空闲 guest 在宿主侧烧满 vCPU 线程。
#    旧的 500000ns 能降低 HLT 后唤醒尖刺，但代价是空闲 VM 也持续忙等；在
#    cpuset 独占分区已启用时，编译抢核由隔离解决，不再靠 halt-poll 硬扛。
if [[ -w /sys/module/kvm/parameters/halt_poll_ns ]]; then
    if [[ "$KVM_HALT_POLL_NS" =~ ^[0-9]+$ ]]; then
        echo "$KVM_HALT_POLL_NS" > /sys/module/kvm/parameters/halt_poll_ns
        echo ">> halt_poll : ${KVM_HALT_POLL_NS} ns"
    else
        echo ">> halt_poll : 跳过（KVM_HALT_POLL_NS 非数字: $KVM_HALT_POLL_NS）"
    fi
fi

# 4) irqbalance：保持运行。旧实现全局停止服务，会让高核数 E5 的存储/网络 IRQ
# 长期堆在少数 CPU 上。vCPU 隔离由 cpuset 完成；后续需要定向 IRQ 时应给
# irqbalance 配置 banned CPU，而不是关闭整个宿主的负载均衡器。
if systemctl is-active --quiet irqbalance 2>/dev/null; then
    echo ">> irqbalance : active（保留；不做全局停服）"
else
    echo ">> irqbalance : 未运行 / 未安装（不主动改变）"
fi

# 5) NVMe I/O 调度器 -> none：qcow2 I/O 延迟更可预测。
for d in /sys/block/nvme*n*/queue/scheduler; do
    [[ -w "$d" ]] && echo none > "$d"
done
echo ">> nvme sched : none"

# 6) 不预留显式 2MiB hugepage。
#    ⚠ 当前内存后端是 memory-backend-memfd —— 它不使用 /proc/sys/vm 的显式
#    hugepage 池！在这里预留只会把 host 物理内存白白锁走（旧默认 16384*2MiB
#    =32GiB 几乎等于整机内存），直接把刚修好的 OOM 又招回来（还会冲击正在跑的
#    VM）。所以本 helper 固定不预留；只有未来把后端换成 hugetlbfs 并增加管理员
#    侧容量策略后，才应通过另一条受限接口启用。
# 当前启动器固定使用 memfd，显式 hugetlb 池既不会被客体使用，又允许免密调用者
# 大量锁走宿主内存。因此 root helper 不再接受 HUGEPAGES 环境开关；若未来切换到
# hugetlbfs，应设计带容量上限的独立管理员配置，而不是扩张此 sudo 接口。
echo ">> hugepages  : 跳过（memfd 后端不使用显式 hugetlb 池）"

# 注：不在 KVM guest 里关 CPU 漏洞缓解（mitigations）——会让 guest 读 IA32_ARCH_CAP
# 时露馅，增加被识别为「异常裸机」的风险。host 侧缓解保持原样。

echo "host tuned."
