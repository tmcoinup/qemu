#!/bin/bash
# ---------------------------------------------------------------------------
# host-performance.sh
#
# Host 侧一次性调优（每次 host 重启后失效，需重跑）。需要 sudo。
#
# 目标：压低 KVM 的调度 / 时钟抖动。ACE「游戏计时异常」(13-131130-8) 这类
# 反作弊时钟检测对 vCPU 服务延迟的方差很敏感——host governor=powersave 让核在
# vm-exit 间降频、halt_poll 太短导致 vCPU 唤醒延迟尖刺、THP 同步整理会把 vCPU
# 冻住几毫秒，这些都会被读成「计时异常」。本脚本只动 host 侧旋钮，guest 看到的
# CPUID / 品牌串 / tsc-freq / 拓扑全部不变 → 零反检测影响。
#
# start-vm.sh 默认会在起 VM 前自动调用本脚本（HOST_TUNE=1，已调优则跳过）；
# 也可单独手动跑：  sudo deploy/scripts/host-performance.sh
# ---------------------------------------------------------------------------
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "rerunning with sudo..."
    exec sudo -E bash "$0" "$@"
fi

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
if [[ -n "${CPU_MAX_KHZ:-}" && "${CPU_MAX_KHZ}" =~ ^[0-9]+$ ]] && (( CPU_MAX_KHZ > 0 )); then
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

# 3) KVM halt-poll：拉大轮询窗口，更多唤醒落在 poll 内 → 降 vCPU 唤醒延迟尖刺。
if [[ -w /sys/module/kvm/parameters/halt_poll_ns ]]; then
    echo 500000 > /sys/module/kvm/parameters/halt_poll_ns
    echo ">> halt_poll : 500000 ns"
fi

# 4) irqbalance：停掉，避免 IRQ 在核间迁移带来的不确定延迟。
if systemctl stop irqbalance 2>/dev/null; then
    echo ">> irqbalance : stopped"
else
    echo ">> irqbalance : 已停 / 未装"
fi

# 5) NVMe I/O 调度器 -> none：qcow2 I/O 延迟更可预测。
for d in /sys/block/nvme*n*/queue/scheduler; do
    [[ -w "$d" ]] && echo none > "$d"
done
echo ">> nvme sched : none"

# 6) (可选, 默认关) 显式 2MiB hugepage 预留。
#    ⚠ 当前内存后端是 memory-backend-memfd —— 它不使用 /proc/sys/vm 的显式
#    hugepage 池！在这里预留只会把 host 物理内存白白锁走（旧默认 16384*2MiB
#    =32GiB 几乎等于整机内存），直接把刚修好的 OOM 又招回来（还会冲击正在跑的
#    VM）。所以默认 0 = 不预留。仅当你把后端换成 hugetlbfs
#    (mem-path=/dev/hugepages) 时，才显式 HUGEPAGES=<页数> 打开。
if [[ "${HUGEPAGES:-0}" =~ ^[0-9]+$ ]] && (( ${HUGEPAGES:-0} > 0 )); then
    if [[ -w /proc/sys/vm/nr_hugepages ]]; then
        echo "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
        echo ">> hugepages  : reserved $HUGEPAGES x 2MiB ($(( HUGEPAGES*2 )) MiB) —— 务必确保后端走 hugetlbfs!"
    fi
else
    echo ">> hugepages  : 跳过（memfd 后端不用显式池；设 HUGEPAGES=N 且换 hugetlbfs 才开）"
fi

# 注：不在 KVM guest 里关 CPU 漏洞缓解（mitigations）——会让 guest 读 IA32_ARCH_CAP
# 时露馅，增加被识别为「异常裸机」的风险。host 侧缓解保持原样。

echo "host tuned."
