#!/usr/bin/env bash
# G-11 交互延迟调优：宿主全局参数 + 运行中 VM 的 CPU 分区/1:1 HT pin。
#
# 与 g11-performance.sh 的区别：
#   g11-performance.sh 面向"吞吐/通用"，它会把 kvm.halt_poll_ns 设为 0 并
#   使用 schedutil。这两项对**交互式桌面**是反效果：halt polling 关闭后
#   guest 每次 HLT 都要走完整 IPI + CFS 唤醒路径（数十 us），schedutil 对
#   KVM vCPU 线程升频迟钝。本脚本针对 SDL 窗口交互场景覆盖这两项。
#
# 全部改动在线可逆，重复执行幂等。宿主重启后需重跑。
set -uo pipefail

die() { echo "[g11-latency] $*" >&2; exit 1; }
log() { echo "[g11-latency] $*"; }

[[ $EUID -eq 0 ]] || die "需要 root：sudo $0 ${*:-apply}"

CG=/sys/fs/cgroup/qemu-vm-isolation
BACKUP=/run/g11-latency-backup
ACTION=${1:-apply}

# ---------------------------------------------------------------- 全局参数
apply_global() {
    mkdir -p "$BACKUP"
    if [[ ! -f "$BACKUP/.saved" ]]; then
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > "$BACKUP/governor" 2>/dev/null
        cat /sys/module/kvm/parameters/halt_poll_ns > "$BACKUP/halt_poll_ns" 2>/dev/null
        cat /sys/module/kvm/parameters/nx_huge_pages > "$BACKUP/nx_huge_pages" 2>/dev/null
        sysctl -n vm.swappiness > "$BACKUP/swappiness" 2>/dev/null
        sysctl -n vm.watermark_scale_factor > "$BACKUP/watermark" 2>/dev/null
        cat /sys/kernel/mm/transparent_hugepage/shmem_enabled > "$BACKUP/shmem" 2>/dev/null
        touch "$BACKUP/.saved"
        log "已备份原始值到 $BACKUP"
    fi

    local n=0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$g" 2>/dev/null && n=$((n+1))
    done
    log "governor -> performance ($n policies)"

    # 交互场景要开 halt polling：guest 短 idle 后能在 vCPU 线程上原地自旋
    # 等唤醒，省掉一次调度往返。
    echo 200000 > /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null &&
        log "kvm.halt_poll_ns -> 200000"

    # 关闭 iTLB-multihit 的 EPT 大页拆分缓解：kvm-nx-lpage-recovery 会周期性
    # zap 页表，表现为规律性的微卡顿。本地可信 guest 可接受该权衡。
    echo 0 > /sys/module/kvm/parameters/nx_huge_pages 2>/dev/null &&
        log "kvm.nx_huge_pages -> N (停止周期性 EPT zap)"

    # memory-backend-memfd 是 shmem，可被换出；guest 页被换出=数百 ms 停顿。
    sysctl -qw vm.swappiness=1 vm.watermark_scale_factor=200 &&
        log "vm.swappiness -> 1, watermark_scale_factor -> 200"

    echo advise > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null &&
        log "shmem THP -> advise"
    echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
}

# ------------------------------------------------------- VM CPU 分区 + pin
# 按 guest -smp N,cores=C,threads=2 的拓扑把 vCPU 1:1 钉到宿主 HT 兄弟对上，
# 使 guest 看到的"同物理核两个线程"在宿主上也真的是同物理核。
declare -a FREE_PAIRS
build_free_pairs() {
    FREE_PAIRS=()
    local seen=" "
    local c sib
    for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* | sed 's#.*/cpu##' | sort -n); do
        [[ -r /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list ]] || continue
        sib=$(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list)
        [[ "$seen" == *" $sib "* ]] && continue
        seen+="$sib "
        # 跳过 core0/core1：留给宿主的中断、内核线程、合成器
        [[ "$sib" == 0,* || "$sib" == 1,* ]] && continue
        FREE_PAIRS+=("$sib")
    done
}

vm_pids() {
    # 输出 "pid name"，name 取 -name 参数
    local p nm
    for p in $(pgrep -f "qemu-system-x86_64.*-name vm" 2>/dev/null); do
        nm=$(tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null | grep -A0 -x -m1 -e 'vm[0-9]*' | head -1)
        [[ -z "$nm" ]] && nm=$(tr '\0' '\n' < /proc/$p/cmdline | awk '/^-name$/{getline; print; exit}')
        echo "$p ${nm:-vm?}"
    done
}

apply_pin() {
    command -v taskset >/dev/null || die "缺少 taskset"
    [[ -d /sys/fs/cgroup && "$(stat -fc %T /sys/fs/cgroup)" == cgroup2fs ]] ||
        { log "非 cgroup v2，跳过分区"; return 0; }

    build_free_pairs
    mkdir -p "$CG" 2>/dev/null
    grep -qw cpuset "$CG/cgroup.subtree_control" 2>/dev/null ||
        echo '+cpuset' > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
    grep -qw cpuset "$CG/cgroup.subtree_control" 2>/dev/null ||
        echo '+cpuset' > "$CG/cgroup.subtree_control" 2>/dev/null

    local -a all_cpus=()
    local -A plan_set=() plan_vcpu=() plan_svc=()
    local idx=0 pid name nvcpu npair

    while read -r pid name; do
        [[ -n "$pid" ]] || continue
        nvcpu=$(ls /proc/$pid/task/*/comm 2>/dev/null | while read -r f; do
                    [[ "$(cat "$f" 2>/dev/null)" == "CPU "* ]] && echo x; done | wc -l)
        (( nvcpu > 0 )) || { log "$name: 未找到 vCPU 线程，跳过"; continue; }
        npair=$(( (nvcpu + 1) / 2 ))
        (( idx + npair + 1 <= ${#FREE_PAIRS[@]} )) ||
            { log "$name: 空闲物理核不足（需 $((npair+1)) 对），跳过"; continue; }

        # npair 对给 vCPU，额外 1 对给服务线程（SDL 渲染/IO），避免与 vCPU 抢核
        local -a vlist=() set_list=()
        local i pair a b
        for ((i=0; i<npair; i++)); do
            pair=${FREE_PAIRS[$((idx+i))]}; a=${pair%%,*}; b=${pair##*,}
            vlist+=("$a" "$b"); set_list+=("$a" "$b")
        done
        pair=${FREE_PAIRS[$((idx+npair))]}; a=${pair%%,*}; b=${pair##*,}
        local svc="$a,$b"
        set_list+=("$a" "$b")
        idx=$((idx + npair + 1))

        plan_set[$pid]=$(IFS=,; echo "${set_list[*]}")
        plan_vcpu[$pid]=$(IFS=,; echo "${vlist[*]}")
        plan_svc[$pid]=$svc
        all_cpus+=("${set_list[@]}")
        log "$name(pid $pid): ${nvcpu} vCPU -> ${plan_vcpu[$pid]}  服务核 -> $svc"
    done < <(vm_pids)

    (( ${#all_cpus[@]} > 0 )) || { log "没有可分区的 VM"; return 0; }

    local parent_set; parent_set=$(IFS=,; echo "${all_cpus[*]}")
    echo "$parent_set" > "$CG/cpuset.cpus" 2>/dev/null ||
        { log "写父分区 cpuset 失败"; return 1; }
    echo root > "$CG/cpuset.cpus.partition" 2>/dev/null
    log "父分区 cpuset = $(cat "$CG/cpuset.cpus")  partition=$(cat "$CG/cpuset.cpus.partition")"

    for pid in "${!plan_set[@]}"; do
        name=$(tr '\0' '\n' < /proc/$pid/cmdline 2>/dev/null | awk '/^-name$/{getline; print; exit}')
        local dir="$CG/${name:-vm$pid}"
        mkdir -p "$dir"
        echo 0 > "$dir/cpuset.mems" 2>/dev/null
        echo "${plan_set[$pid]}" > "$dir/cpuset.cpus" 2>/dev/null ||
            { log "$name: 写 cpuset 失败"; continue; }
        echo "$pid" > "$dir/cgroup.procs" 2>/dev/null

        # 按 comm "CPU N/KVM" 里的 N 取序号，保证与 guest 拓扑一致
        local -a vmap; IFS=, read -r -a vmap <<<"${plan_vcpu[$pid]}"
        local t tid comm n
        for t in /proc/$pid/task/*; do
            tid=${t##*/}; comm=$(cat "$t/comm" 2>/dev/null)
            if [[ "$comm" == "CPU "* ]]; then
                n=${comm#CPU }; n=${n%%/*}
                [[ -n "${vmap[$n]:-}" ]] && taskset -pc "${vmap[$n]}" "$tid" >/dev/null 2>&1
            else
                taskset -pc "${plan_svc[$pid]}" "$tid" >/dev/null 2>&1
            fi
        done
        log "${name}: pin 完成"
    done
    log "宿主保留核 = $(cat /sys/fs/cgroup/cpuset.cpus.effective)"
}

# ----------------------------------------------------------------- GPU 时钟
# vGPU 低负载时 SM 时钟会掉到最低档，交互场景表现为"动一下才升频"的迟滞。
# 锁定下限让每帧都在高频上渲染；上限保持默认，不改功耗墙。
lock_gpu_clocks() {
    command -v nvidia-smi >/dev/null || { log "无 nvidia-smi，跳过 GPU 锁频"; return 0; }
    local maxsm
    maxsm=$(nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [[ "$maxsm" =~ ^[0-9]+$ ]] || { log "无法读取 GPU 最大 SM 时钟，跳过"; return 0; }
    local minsm=$(( maxsm * 64 / 100 ))
    if nvidia-smi -lgc "${minsm},${maxsm}" >/dev/null 2>&1; then
        log "GPU SM 时钟锁定 -> ${minsm}..${maxsm} MHz"
    else
        log "GPU 锁频失败（非致命）"
    fi
}

unlock_gpu_clocks() {
    command -v nvidia-smi >/dev/null || return 0
    nvidia-smi -rgc >/dev/null 2>&1 && log "GPU 时钟已解锁"
}

reclaim_swap() {
    local avail used
    avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    used=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
    (( used > 0 )) || { log "swap 未使用，跳过回收"; return 0; }
    if (( avail < used + 4096 )); then
        log "可用内存 ${avail}MB 不足以换回 ${used}MB，跳过 swap 回收"; return 0
    fi
    log "回收 swap（${used}MB）..."
    swapoff -a && swapon -a && log "swap 已回收" || log "swap 回收失败"
}

restore() {
    [[ -f "$BACKUP/.saved" ]] || die "没有备份可恢复"
    local v
    v=$(cat "$BACKUP/governor" 2>/dev/null) && [[ -n "$v" ]] &&
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$v" > "$g" 2>/dev/null; done
    v=$(cat "$BACKUP/halt_poll_ns" 2>/dev/null) && [[ -n "$v" ]] && echo "$v" > /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null
    v=$(cat "$BACKUP/nx_huge_pages" 2>/dev/null) && [[ -n "$v" ]] && echo "$v" > /sys/module/kvm/parameters/nx_huge_pages 2>/dev/null
    v=$(cat "$BACKUP/swappiness" 2>/dev/null) && [[ -n "$v" ]] && sysctl -qw vm.swappiness="$v"
    v=$(cat "$BACKUP/watermark" 2>/dev/null) && [[ -n "$v" ]] && sysctl -qw vm.watermark_scale_factor="$v"
    unlock_gpu_clocks
    log "已恢复全局参数（CPU 分区需重启 VM 才完全复位）"
}

audit() {
    echo "governor        = $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    echo "平均频率        = $(grep MHz /proc/cpuinfo | awk '{s+=$4;n++} END{printf "%.0f MHz", s/n}')"
    echo "halt_poll_ns    = $(cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null)"
    echo "nx_huge_pages   = $(cat /sys/module/kvm/parameters/nx_huge_pages 2>/dev/null)"
    echo "swappiness      = $(sysctl -n vm.swappiness 2>/dev/null)"
    echo "swap 已用       = $(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{printf "%d MB", (t-f)/1024}' /proc/meminfo)"
    echo "shmem THP       = $(cat /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null)"
    echo "宿主保留核      = $(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null)"
    command -v nvidia-smi >/dev/null && echo "GPU SM 时钟     = $(nvidia-smi --query-gpu=clocks.sm,clocks.max.sm --format=csv,noheader 2>/dev/null | head -1)"
    local d
    for d in "$CG"/*/; do
        [[ -d "$d" ]] || continue
        echo "分区 $(basename "$d")     = $(cat "$d/cpuset.cpus" 2>/dev/null)"
    done
}

case "$ACTION" in
    apply)   apply_global; apply_pin; lock_gpu_clocks; reclaim_swap; echo; audit ;;
    gpu)     lock_gpu_clocks ;;
    pin)     apply_pin ;;
    swap)    reclaim_swap ;;
    audit)   audit ;;
    restore) restore ;;
    *) die "用法: $0 [apply|pin|gpu|swap|audit|restore]" ;;
esac
