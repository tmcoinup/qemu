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

# root helper 会被 sudoers 免密放行，因此参数必须在任何写 sysfs 之前完整校验。
# 第一个参数是频率上限（0=不封顶），第二个是 halt poll ns，第三个是
# split-lock mitigation 目标值（0=取消故意降速，1=保留内核防护）。拒绝额外参数与环境注入。
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

if [[ $EUID -ne 0 ]]; then
    echo "rerunning with sudo..."
    # 直接以脚本路径(非 'bash 脚本')重入 sudo，命令名=脚本本身，匹配
    # /etc/sudoers.d/qemu-vmate-host 的固定 helper NOPASSWD 规则；参数原样带过去。
    exec sudo -- "$0" "$@"
fi

# power-profiles-daemon 会在首次启动时按自己的持久状态重新应用 governor/EPP。
# 如果本 helper 先写 sysfs、daemon 稍后才由桌面会话拉起，刚设置的 performance
# 就会被覆盖回 balanced/powersave。先启动 daemon 并通过它的公开 CLI 选择
# performance，再执行下方原有的 sysfs 写入，保证两套控制面顺序一致。
#
# 没有 PPD 的服务器、精简发行版和容器仍走原 sysfs 路径；PPD 启动或切换失败也只
# 清晰告警并返回成功，让既有 governor/frequency fallback 继续执行，不扩大 helper
# 在不同发行版上的硬依赖。
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

    echo ">> power profile: performance（daemon 已同步）"
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

# 1) CPU governor -> performance：固定高频，消除 vm-exit 间降频导致的服务延迟
#    忽高忽低（计时抖动的头号来源）。
_gov_changed=0
for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$p" ]] || continue
    if [[ "$(cat "$p")" != "performance" ]]; then echo performance > "$p"; _gov_changed=1; fi
done
echo ">> governor   : performance$([[ $_gov_changed == 0 ]] && echo '（本就是）')"

# 1b) (可选) 按伪装 CPU 的上限频率封顶 scaling_max_freq。
#     host(Ryzen7 5800) boost 4.6GHz 会远超伪装的 Ryzen3-1200 3.4GHz——guest 在
#     固定 tsc-freq(3.1GHz) 下实测吞吐就会超过它自报的 SMBIOS Type4 max-speed，
#     等于「单位时钟干的活比这颗 CPU 该有的多」= 变速器 / 计时异常(13-131130-8)
#     的破绽。把 scaling_max_freq 压到伪装 CPU 上限后，guest 再也跑不出超规格的
#     速度；governor=performance 下这也就是实际钉死频率，顺带压平频率波动抖动。
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
