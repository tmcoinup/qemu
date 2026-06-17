#!/bin/bash
# ---------------------------------------------------------------------------
# host-cpu-isolate.sh —— 把一台隐身 VM 的 QEMU 进程钉进一个 cgroup v2 cpuset
# 「独占分区」, 让 vCPU 拥有专属物理核, 与宿主机其它负载(尤其是 rust/cargo 这类
# 吃满全核的编译)在调度层面彻底隔离。需要 root(走 start-vm 的 sudo NOPASSWD)。
#
# 背景 / 为什么需要它:
#   start-vm 原先的 host 调优(host-performance.sh)只做了 governor / 频率封顶 /
#   halt_poll / THP / irqbalance —— 全是「单位时间跑多快」与「时钟抖动」的旋钮,
#   **没有任何一项把 vCPU 钉在独占核上**。所以宿主机一跑满 CPU(cargo build 默认
#   nproc 个并行任务塞满全部 16 个逻辑核), QEMU 的 4 个 vCPU 线程只是普通 CFS
#   线程, 要和几十个 rustc 线程抢同一批核 → guest 该跑时抢不到核 → 卡顿、掉帧、
#   鼠标延迟、ACE「游戏计时异常」。频率封顶不但治不了这个, 反而把宿主机算力也压
#   低了。真正的解法是 CPU 亲和隔离: 给 VM 划一组专属物理核, 把宿主机其它进程挤
#   出去。
#
# 做法 (cgroup v2 cpuset partition, 纯运行态, 不动内核启动参数、不重启、可逆):
#   1) 建 /sys/fs/cgroup/<VMISO>, 写 cpuset.cpus = VM 专属逻辑核集合;
#   2) cpuset.cpus.partition = root  → 这些核从 root cgroup 的 effective 里**被
#      独占摘走**, 于是宿主机所有其它进程(桌面/shell/编译)自动被内核迁出这些核,
#      只能用剩下的核 —— 无需逐个去改 system.slice/user.slice;
#   3) 把 QEMU 整个进程(连同全部线程)move 进该 cgroup → 被限制在 VM 核集合内;
#   4) 再对每个 vCPU 线程做 1:1 taskset, 钉到各自的物理核(主 SMT 兄弟), QEMU 的
#      I/O / 主循环 / SDL 等辅助线程则落在空闲的兄弟超线程上, 不与 vCPU 争抢。
#
# 多 VM 共存: 所有实例共用同一个 VMISO 分区(宿主机 8 核物理上容不下多台 4vCPU
# 各占独立核), 第二台起来时分区已在, 只把自己 move 进去; 它们彼此在分区内由内核
# 均衡, 但仍与宿主机编译隔离。release 只在分区内最后一个进程退出后才拆分区还核。
#
# 子命令:
#   apply  <vm_cpus> <mems> <pid> <tid:cpu,tid:cpu,...>
#   release [instance]            # 分区空了才真正还核; 否则保留给其它在跑的 VM
#   status                        # 打印当前分区状态(供 verify / 排查)
#
# 取 root: 已 root 直接跑; 否则 exec sudo "$0"(命令名=脚本路径, 匹配
# /etc/sudoers.d/qemu-cpuiso 的 NOPASSWD 规则)。失败一律不阻断 VM。
# ---------------------------------------------------------------------------
set -uo pipefail

CG_ROOT="/sys/fs/cgroup"
VMISO_NAME="${VMISO_NAME:-vmiso}"
VMISO="$CG_ROOT/$VMISO_NAME"
LOCK="/tmp/qemu-cpuiso.lock"   # 串行化并发 apply(同时起两台 VM 时抢空闲核)

_die() { echo "host-cpu-isolate: $*" >&2; exit 1; }
_warn() { echo "host-cpu-isolate: $*" >&2; }

# cgroup v2 + cpuset controller 预检。返回非零表示环境不支持, 调用方应优雅跳过。
_precheck() {
    [[ "$(stat -fc %T "$CG_ROOT" 2>/dev/null)" == "cgroup2fs" ]] || {
        _warn "不是 cgroup v2 (cgroup2fs), 跳过 CPU 隔离"; return 1; }
    grep -qw cpuset "$CG_ROOT/cgroup.controllers" 2>/dev/null || {
        _warn "root cgroup 无 cpuset controller, 跳过"; return 1; }
    # cpuset 必须在 root 的 subtree_control 里(子 cgroup 才能用 cpuset.*)。
    if ! grep -qw cpuset "$CG_ROOT/cgroup.subtree_control" 2>/dev/null; then
        echo +cpuset > "$CG_ROOT/cgroup.subtree_control" 2>/dev/null \
            || { _warn "无法在 root 启用 +cpuset, 跳过"; return 1; }
    fi
    return 0
}

# 取 root（与 host-performance.sh 同款: 以脚本路径重入 sudo, 匹配 NOPASSWD 规则）。
if [[ $EUID -ne 0 ]]; then
    exec sudo -n "$0" "$@" 2>/dev/null || { _warn "需要 root 但无免密 sudo, 跳过"; exit 0; }
fi

CMD="${1:-}"; shift || true

case "$CMD" in
# -------------------------------------------------------------------- apply
apply)
    MEMS="${1:-0}"; PID="${2:-}"; PREF="${3:-}"; TIDS="${4:-}"
    [[ -n "$PID" && -n "$PREF" && -n "$TIDS" ]] || _die "用法: apply <mems> <pid> <pref_order> <tids>"
    [[ "$PID" =~ ^[0-9]+$ && -d "/proc/$PID" ]] || _die "pid 非法/不存在: $PID"
    [[ "$MEMS" =~ ^[0-9,\-]+$ ]] || MEMS=0

    _precheck || exit 0

    # 串行化: 同时起两台 VM 时, 各自的 apply 要按「已被占走的线程」错开分配, 否则会
    # 双双算出同一批空闲线程。flock 保证发现-分配原子, 拿不到锁也最多退化(不致命)。
    exec 9>"$LOCK" 2>/dev/null || true
    flock -w 10 9 2>/dev/null || _warn "flock 超时, 尽力继续"

    # 1) 其它在跑 VM 已单核绑定的逻辑线程 = held(它们的 vCPU 各自钉死的那个核)。
    declare -A _held=()
    if [[ -d "$VMISO" && -r "$VMISO/cgroup.procs" ]]; then
        while read -r _op; do
            [[ -n "$_op" && "$_op" != "$PID" && -d "/proc/$_op" ]] || continue
            for _st in /proc/"$_op"/task/*/status; do
                _al=$(awk '/^Cpus_allowed_list:/{print $2}' "$_st" 2>/dev/null)
                [[ "$_al" =~ ^[0-9]+$ ]] && _held[$_al]=1   # 仅单核绑定算「已占」
            done
        done < "$VMISO/cgroup.procs"
    fi

    # 2) 按 PREF 跳过 held, 给本台分配恰好 len(TIDS) 个空闲逻辑线程(线程级, 不吃整核)。
    IFS=',' read -ra _pref <<< "$PREF"
    IFS=',' read -ra _tids <<< "$TIDS"
    _mine=()
    for _c in "${_pref[@]}"; do
        (( ${#_mine[@]} < ${#_tids[@]} )) || break
        [[ "$_c" =~ ^[0-9]+$ && -z "${_held[$_c]:-}" ]] || continue
        _mine+=("$_c")
    done
    [[ ${#_mine[@]} -gt 0 ]] || _die "无空闲逻辑线程可分配(VM 过多?)"

    # 3) vmiso.cpus = held ∪ mine —— 分区恰好等于「所有在跑 VM 实占的线程」, 随 VM
    #    增减动态伸缩(单台=4 线程, 两台=8 线程), 绝不多锁宿主机的线程。
    _all_csv=$( { for _k in "${!_held[@]}"; do echo "$_k"; done; printf '%s\n' "${_mine[@]}"; } \
                | sort -n -u | paste -sd, - )

    mkdir -p "$VMISO" 2>/dev/null || _die "建 $VMISO 失败"
    echo "$_all_csv" > "$VMISO/cpuset.cpus" 2>/dev/null || _warn "写 cpuset.cpus 失败"
    echo "$MEMS"     > "$VMISO/cpuset.mems" 2>/dev/null || _warn "写 cpuset.mems 失败"

    # 切独占分区根: 这些线程从 root effective 摘走, 宿主机进程被挤到其余线程。
    _part_state="member"
    if echo root > "$VMISO/cpuset.cpus.partition" 2>/dev/null; then
        _part_state="$(cat "$VMISO/cpuset.cpus.partition" 2>/dev/null || echo '?')"
    fi
    case "$_part_state" in
        root)            echo ">> cpuset     : 独占分区 cpus=$_all_csv (这些逻辑线程已从宿主机摘走)" ;;
        "root invalid"*) _warn "分区未独占($_part_state)"; echo ">> cpuset     : 非独占 cpus=$_all_csv (隔离强度降低)" ;;
        *)               echo ">> cpuset     : cpus=$_all_csv (partition=$_part_state)" ;;
    esac

    # 4) move QEMU 进分区(写 leader pid 即迁全部线程) + 逐 vCPU 1:1 钉死。
    echo "$PID" > "$VMISO/cgroup.procs" 2>/dev/null \
        && echo ">> move       : QEMU pid=$PID → $VMISO_NAME" \
        || _warn "move pid=$PID 失败(可能已在别 cpuset), 继续 taskset"
    _pinned=""
    for _i in "${!_mine[@]}"; do
        _tid="${_tids[$_i]}"; _cpu="${_mine[$_i]}"
        [[ "$_tid" =~ ^[0-9]+$ && -d "/proc/$PID/task/$_tid" ]] || continue
        taskset -pc "$_cpu" "$_tid" >/dev/null 2>&1 && _pinned="$_pinned vcpu→cpu$_cpu"
    done
    [[ -n "$_pinned" ]] && echo ">> vcpu pin   :$_pinned (1:1 钉死, 已避让其它 VM)"
    (( ${#_mine[@]} < ${#_tids[@]} )) && \
        echo ">> vcpu pin   : 另 $(( ${#_tids[@]} - ${#_mine[@]} )) 个 vCPU 无空闲线程(VM 过多), 留 cgroup 均衡"
    echo "cpu-isolate applied."
    ;;

# ------------------------------------------------------------------ release
release)
    INST="${1:-}"
    exec 9>"$LOCK" 2>/dev/null || true
    flock -w 10 9 2>/dev/null || true
    [[ -d "$VMISO" ]] || { echo ">> cpuset     : 无分区, 无需释放"; exit 0; }

    # 扫分区内活进程 + 它们仍单核绑定的线程 = remaining(还在跑的 VM 的 vCPU 占用)。
    declare -A _rem=()
    _live=0
    if [[ -r "$VMISO/cgroup.procs" ]]; then
        while read -r _p; do
            [[ -n "$_p" && -d "/proc/$_p" ]] || continue
            _live=$((_live+1))
            for _st in /proc/"$_p"/task/*/status; do
                _al=$(awk '/^Cpus_allowed_list:/{print $2}' "$_st" 2>/dev/null)
                [[ "$_al" =~ ^[0-9]+$ ]] && _rem[$_al]=1
            done
        done < "$VMISO/cgroup.procs"
    fi

    if (( _live == 0 )); then
        # 空了: 切回 member(线程立刻还给 root), 再删目录。
        echo member > "$VMISO/cpuset.cpus.partition" 2>/dev/null || true
        rmdir "$VMISO" 2>/dev/null \
            && echo ">> cpuset     : 分区已拆除, ${INST:+实例 $INST }专属线程已全部还给宿主机" \
            || _warn "rmdir $VMISO 失败(可能仍有残留), 已切回 member"
    else
        # 还有别的 VM: 把分区收缩到「剩余在跑 VM 的线程」, 已退 VM 的线程还给宿主机。
        _rem_csv=$( for _k in "${!_rem[@]}"; do echo "$_k"; done | sort -n -u | paste -sd, - )
        if [[ -n "$_rem_csv" ]]; then
            echo "$_rem_csv" > "$VMISO/cpuset.cpus" 2>/dev/null || true
            echo ">> cpuset     : 仍有 $_live 个 VM 在跑, 分区收缩到 cpus=$_rem_csv (已退 VM 线程已还宿主机)"
        else
            echo ">> cpuset     : 仍有 $_live 个进程但无单核绑定, 分区暂不变"
        fi
    fi
    ;;

# ------------------------------------------------------------------- status
status)
    if [[ ! -d "$VMISO" ]]; then
        echo "cpu-isolate: 无分区(未隔离)"; exit 0
    fi
    echo "cpu-isolate: 分区 $VMISO"
    echo "  cpuset.cpus           = $(cat "$VMISO/cpuset.cpus" 2>/dev/null)"
    echo "  cpuset.cpus.effective = $(cat "$VMISO/cpuset.cpus.effective" 2>/dev/null)"
    echo "  cpuset.cpus.partition = $(cat "$VMISO/cpuset.cpus.partition" 2>/dev/null)"
    echo "  root effective cpus   = $(cat "$CG_ROOT/cpuset.cpus.effective" 2>/dev/null)  (宿主机其它进程可用核)"
    _n=0; while read -r _p; do [[ -n "$_p" ]] && _n=$((_n+1)); done < "$VMISO/cgroup.procs" 2>/dev/null
    echo "  分区内进程数          = $_n"
    ;;

*)
    _die "未知子命令: '$CMD' (apply|release|status)"
    ;;
esac
