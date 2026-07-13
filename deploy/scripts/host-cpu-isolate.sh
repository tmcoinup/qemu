#!/bin/bash
# ---------------------------------------------------------------------------
# host-cpu-isolate.sh —— 把一台隐身 VM 的 QEMU 进程钉进一个 cgroup v2 cpuset
# 「独占分区」, 让每个 vCPU 拥有专属逻辑 CPU, 与宿主机其它负载(尤其是 rust/cargo 这类
# 吃满全核的编译)在调度层面彻底隔离。需要 root(走 start-vm 的 sudo NOPASSWD)。
#
# 背景 / 为什么需要它:
#   start-vm 原先的 host 调优(host-performance.sh)只做了 governor / 频率封顶 /
#   halt_poll / THP / irqbalance —— 全是「单位时间跑多快」与「时钟抖动」的旋钮,
#   **没有任何一项把 vCPU 钉在独占核上**。所以宿主机一跑满 CPU(cargo build 默认
#   nproc 个并行任务塞满全部 16 个逻辑核), QEMU 的 4 个 vCPU 线程只是普通 CFS
#   线程, 要和几十个 rustc 线程抢同一批核 → guest 该跑时抢不到核 → 卡顿、掉帧、
#   鼠标延迟、ACE「游戏计时异常」。频率封顶不但治不了这个, 反而把宿主机算力也压
#   低了。真正的解法是 CPU 亲和隔离: 给 VM 划一组专属逻辑 CPU, 把宿主机其它进程挤
#   出去；上层分配器会优先选择不同物理核心的逻辑 CPU，主线程耗尽后才使用 SMT 兄弟。
#
# 做法 (cgroup v2 cpuset partition, 纯运行态, 不动内核启动参数、不重启、可逆):
#   1) 建 /sys/fs/cgroup/<VMISO>, 写 cpuset.cpus = VM 专属逻辑核集合;
#   2) cpuset.cpus.partition = root  → 这些核从 root cgroup 的 effective 里**被
#      独占摘走**, 于是宿主机所有其它进程(桌面/shell/编译)自动被内核迁出这些核,
#      只能用剩下的核 —— 无需逐个去改 system.slice/user.slice;
#   3) 把 QEMU 整个进程(连同全部线程)move 进该 cgroup → 被限制在 VM 核集合内;
#   4) 再对每个 vCPU 线程做 1:1 taskset, 钉到各自的逻辑 CPU；
#   5) 如果 start-vm 传入 QEMU_SERVICE_CPUS>0，则额外分配一组 service CPU，
#      并把 QEMU main / IO / SDL / fb-shm worker 等非 vCPU 线程收窄到这组 CPU，
#      避免显示/IO 线程和 100% 满载 vCPU 抢同一条调度队列。
#
# 多 VM 共存: 所有实例共用同一个 VMISO 分区；每次 apply 都会读取现有 vCPU 单核
# 绑定，按上层偏好顺序跳过已占逻辑 CPU。release 只在分区内最后一个进程退出后
# 才拆分区还核。
#
# 子命令:
#   preflight                    # 验证 cgroup v2/cpuset 与当前 sudo 授权
#   apply  <instance> <mems> <pid> <pref_order> <tids> [service_cpu_count]
#   release <instance>             # 分区空了才真正还核; 否则保留给其它在跑的 VM
#   status                        # 打印当前分区状态(供 verify / 排查)
#
# 取 root: 已 root 直接跑; 否则 exec sudo "$0"(命令名=脚本路径, 匹配
# /etc/sudoers.d/qemu-vmate-host 的 NOPASSWD 规则)。失败返回非零，由启动器的
# 严格/兼容策略决定终止客机还是仅告警，helper 自身不能把失败伪装成成功。
# ---------------------------------------------------------------------------
set -uo pipefail

# 这是一个可由 sudoers 免密调用的 root helper。不能继承调用者可控 PATH，也不能
# 允许环境变量改变 cgroup 或锁文件位置；否则 NOSETENV 之外的 sudo 配置差异会变成
# 提权边界。所有外部命令只从系统管理目录解析，运行时状态固定放在 root 私有 /run。
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
readonly CG_ROOT="/sys/fs/cgroup"
readonly VMISO_NAME="vmiso"
readonly VMISO="$CG_ROOT/$VMISO_NAME"
readonly RUNTIME_DIR="/run/qemu-vmate-cpu-isolate"
readonly INSTANCE_DIR="$RUNTIME_DIR/instances"
readonly LOCK="$RUNTIME_DIR/global.lock"
# ABI 路径带版本号：installer 可以先发布新 runtime、最后原子切换主 helper；已经
# 通过 sudo 启动的旧 main 仍引用自己的旧 ABI 文件，不会在部署窗口混载新函数。
readonly CPU_ISOLATE_RUNTIME_ABI="1"
readonly RUNTIME_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v1.sh"
# 该变量由固定运行库消费；shellcheck 单文件分析看不到跨文件引用。
# shellcheck disable=SC2034
readonly TRUST_MANIFEST="/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf"

_die() { echo "host-cpu-isolate: $*" >&2; exit 1; }
_warn() { echo "host-cpu-isolate: $*" >&2; }

# 创建/验证 root 私有运行时目录。旧实现把锁放在 world-writable /tmp，并在 root
# 权限下用 `>` 打开，普通用户可预置指向 /etc/sudoers 的 symlink 造成任意文件截断。
# /run 的固定 0700 目录阻断普通用户置换目录项；仍逐项拒绝 symlink、错误 owner/mode，
# 避免管理员误建或其它 root 进程留下异常对象时继续运行。
_ensure_private_dir() {
    local path="$1" metadata uid gid mode

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        (umask 077; mkdir -- "$path") 2>/dev/null || true
    fi
    [[ -d "$path" && ! -L "$path" ]] || _die "运行时目录不是普通目录: $path"
    metadata="$(stat -Lc '%u %g %a' -- "$path" 2>/dev/null)" \
        || _die "无法读取运行时目录元数据: $path"
    read -r uid gid mode <<<"$metadata"
    [[ "$uid:$gid:$mode" == "0:0:700" ]] \
        || _die "运行时目录必须为 root:root 0700: $path ($uid:$gid:$mode)"
}

_prepare_runtime() {
    _ensure_private_dir "$RUNTIME_DIR"
    _ensure_private_dir "$INSTANCE_DIR"
}

_validate_vmiso_dir() {
    local metadata uid gid mode
    [[ -d "$VMISO" && ! -L "$VMISO" ]] || _die "vmiso 不是 cgroup 普通目录"
    metadata="$(stat -Lc '%u %g %a' -- "$VMISO" 2>/dev/null)" \
        || _die "无法读取 vmiso cgroup 元数据"
    read -r uid gid mode <<<"$metadata"
    [[ "$uid" == "0" && "$gid" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] \
        || _die "vmiso cgroup owner/mode 非法: $uid:$gid:$mode"
    (( (8#$mode & 8#022) == 0 )) \
        || _die "vmiso cgroup 不得由 group/other 写入: mode=$mode"
}

# 以 no-clobber 创建锁，随后在打开前、打开后分别核验类型/owner/mode/link count，
# 并比对路径与 fd 的 device:inode。目录仅 root 可写使两次校验之间不存在非特权竞态；
# inode 比对则继续防御 root 侧误操作或异常替换。
_open_global_lock() {
    local metadata uid gid mode links path_inode fd_inode

    _prepare_runtime
    if [[ ! -e "$LOCK" && ! -L "$LOCK" ]]; then
        (umask 077; set -o noclobber; : > "$LOCK") 2>/dev/null || true
    fi
    [[ -f "$LOCK" && ! -L "$LOCK" ]] || _die "全局锁不是普通文件: $LOCK"
    metadata="$(stat -Lc '%u %g %a %h' -- "$LOCK" 2>/dev/null)" \
        || _die "无法读取全局锁元数据"
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid:$mode:$links" == "0:0:600:1" ]] \
        || _die "全局锁必须为 root:root 0600 且只有一个硬链接"
    path_inode="$(stat -Lc '%d:%i' -- "$LOCK")" || _die "无法读取锁 inode"
    exec 9<>"$LOCK" || _die "无法安全打开全局锁"
    fd_inode="$(stat -Lc '%d:%i' -- "/proc/$$/fd/9" 2>/dev/null)" \
        || _die "无法校验锁 fd"
    [[ "$fd_inode" == "$path_inode" ]] || _die "全局锁在打开期间被替换"
    flock -x -w 10 9 || _die "flock 超时，拒绝并发修改 CPU 分配"
}

_instance_state_path() {
    printf '%s/%s.state\n' "$INSTANCE_DIR" "$1"
}

_validate_state_file() {
    local path="$1" metadata uid gid mode links
    [[ -f "$path" && ! -L "$path" ]] || _die "实例状态不是普通文件: $path"
    metadata="$(stat -Lc '%u %g %a %h' -- "$path" 2>/dev/null)" \
        || _die "无法读取实例状态元数据: $path"
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid:$mode:$links" == "0:0:600:1" ]] \
        || _die "实例状态必须为 root:root 0600 且只有一个硬链接: $path"
}

_read_instance_state() {
    local path="$1" line key value
    STATE_INSTANCE=""; STATE_PID=""; STATE_START=""; STATE_CALLER_UID=""; STATE_CPUS=""
    _validate_state_file "$path"
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$line" == *"="* ]] || _die "实例状态行格式错误: $path"
        case "$key" in
            instance) STATE_INSTANCE="$value" ;;
            pid) STATE_PID="$value" ;;
            start_time) STATE_START="$value" ;;
            caller_uid) STATE_CALLER_UID="$value" ;;
            cpus) STATE_CPUS="$value" ;;
            *) _die "实例状态含未知字段: $key" ;;
        esac
    done < "$path"
    [[ "$STATE_INSTANCE" =~ ^[1-9][0-9]{0,9}$ &&
       "$STATE_PID" =~ ^[0-9]+$ && "$STATE_START" =~ ^[0-9]+$ &&
       "$STATE_CALLER_UID" =~ ^[0-9]+$ &&
       "$STATE_CPUS" =~ ^[0-9]+(,[0-9]+)*$ ]] \
        || _die "实例状态字段非法: $path"
}

_write_instance_state() {
    local instance="$1" pid="$2" start_time="$3" caller="$4" cpus="$5"
    local path tmp
    path="$(_instance_state_path "$instance")"
    tmp="$(mktemp "$INSTANCE_DIR/.${instance}.XXXXXX")" \
        || _die "无法创建实例状态临时文件"
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; _die "无法设置实例状态权限"; }
    {
        printf 'instance=%s\n' "$instance"
        printf 'pid=%s\n' "$pid"
        printf 'start_time=%s\n' "$start_time"
        printf 'caller_uid=%s\n' "$caller"
        printf 'cpus=%s\n' "$cpus"
    } > "$tmp" || { rm -f -- "$tmp"; _die "无法写实例状态"; }
    mv -fT -- "$tmp" "$path" || { rm -f -- "$tmp"; _die "无法原子登记实例状态"; }
}

_cpu_list_to_lines() {
    local list="$1" part start end cpu
    local -a _parts
    [[ -n "$list" ]] || return 0
    IFS=',' read -ra _parts <<< "$list"
    for part in "${_parts[@]}"; do
        [[ -n "$part" ]] || continue
        if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
            start="${part%-*}"
            end="${part#*-}"
            for (( cpu=start; cpu<=end; cpu++ )); do
                echo "$cpu"
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            echo "$part"
        fi
    done | sort -n -u
}

_cpu_list_to_csv() {
    _cpu_list_to_lines "$1" | paste -sd, -
}

_csv_from_lines() {
    sort -n -u | paste -sd, -
}

# 该文件作为 NOPASSWD root helper 安装，必须在提权前后都拒绝多余或非数字参数。
# CPU/NUMA 列表只允许内核 cpulist 语法中的数字、逗号和短横线。
_validate_cli() {
    local command="${1:-}"
    case "$command" in
        preflight)
            (( $# == 1 )) || _die "preflight 不接受额外参数"
            ;;
        apply)
            (( $# == 6 || $# == 7 )) \
                || _die "用法: apply <instance> <mems> <pid> <pref_order> <tids> [service_cpu_count]"
            [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] || _die "instance 非法: $2"
            [[ "$3" =~ ^[0-9]+([,-][0-9]+)*$ ]] || _die "mems 非法: $3"
            [[ "$4" =~ ^[0-9]+$ ]] || _die "pid 非法: $4"
            [[ "$5" =~ ^[0-9]+(,[0-9]+)*$ ]] || _die "pref_order 非法: $5"
            [[ "$6" =~ ^[0-9]+(,[0-9]+)*$ ]] || _die "tids 非法: $6"
            if (( $# == 7 )); then
                [[ "$7" =~ ^[0-9]+$ ]] || _die "service_cpu_count 非法: $7"
                (( 10#$7 <= 8 )) || _die "service_cpu_count 超过安全上限 8: $7"
            fi
            ;;
        release)
            (( $# == 2 )) || _die "用法: release <instance>"
            [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] || _die "instance 非法: $2"
            ;;
        status)
            (( $# == 1 )) || _die "status 不接受额外参数"
            ;;
        *) _die "未知子命令: '$command' (preflight|apply|release|status)" ;;
    esac
}

_validate_cli "$@"

# 提权后只加载 installer 放置的 root-owned 固定运行库。校验 regular/no-symlink、
# owner、精确 mode 和 link count，避免 NOPASSWD main 通过用户可写 source 获得 root。
_load_runtime_library() {
    local metadata uid gid mode links parent
    parent="${RUNTIME_LIB%/*}"
    [[ -d "$parent" && ! -L "$parent" ]] \
        || _die "CPU isolate libexec 不是普通目录: $parent"
    metadata="$(stat -Lc '%u %g %a' -- "$parent" 2>/dev/null)" \
        || _die "无法读取 CPU isolate libexec 元数据"
    read -r uid gid mode <<<"$metadata"
    [[ "$uid" == "0" && "$gid" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] \
        || _die "CPU isolate libexec owner/mode 非法"
    (( (8#$mode & 8#022) == 0 )) \
        || _die "CPU isolate libexec 不得由 group/other 写入"
    [[ -f "$RUNTIME_LIB" && ! -L "$RUNTIME_LIB" ]] \
        || _die "CPU isolate runtime 不是普通文件: $RUNTIME_LIB"
    metadata="$(stat -Lc '%u %g %a %h' -- "$RUNTIME_LIB" 2>/dev/null)" \
        || _die "无法读取 CPU isolate runtime 元数据"
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid:$mode:$links" == "0:0:755:1" ]] \
        || _die "CPU isolate runtime 必须为 root:root 0755 且只有一个硬链接"
    # shellcheck disable=SC1090
    source "$RUNTIME_LIB"
    [[ "${VMATE_CPU_ISOLATE_RUNTIME_ABI:-}" == "$CPU_ISOLATE_RUNTIME_ABI" ]] \
        || _die "CPU isolate main/runtime ABI 不匹配"
    declare -F _validate_qemu_target _apply_transaction_begin \
        _apply_transaction_exit _caller_uid _proc_start_time >/dev/null \
        || _die "CPU isolate runtime 接口不完整"
}

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
    exec sudo -n -- "$0" "$@" 2>/dev/null || { _warn "需要 root 但无免密 sudo"; exit 1; }
fi

_load_runtime_library

CMD="${1:-}"; shift || true

case "$CMD" in
# --------------------------------------------------------------- preflight
preflight)
    _validate_trust_manifest
    _prepare_runtime
    _precheck || exit 1
    echo "cpu-isolate preflight passed."
    ;;

# -------------------------------------------------------------------- apply
apply)
    INST="${1:-}"; MEMS="${2:-0}"; PID="${3:-}"; PREF="${4:-}"; TIDS="${5:-}"; SERVICE_CPUS="${6:-0}"
    [[ -n "$PID" && -n "$PREF" && -n "$TIDS" ]] \
        || _die "用法: apply <instance> <mems> <pid> <pref_order> <tids>"
    # 参数已在提权前后由 _validate_cli 严格验证，这里不再静默改写非法输入。

    _validate_trust_manifest
    _precheck || exit 1
    _validate_qemu_target "$PID" "$TIDS"

    # 串行化: 同时起两台 VM 时, 各自的 apply 要按「已被占走的线程」错开分配, 否则会
    # 双双算出同一批空闲线程。root 私有锁保证“发现→分配→登记”是一个原子事务。
    _open_global_lock
    _validate_target_unchanged "$PID"
    if [[ -e "$VMISO" || -L "$VMISO" ]]; then
        _validate_vmiso_dir
    fi
    _apply_transaction_begin

    _state_path="$(_instance_state_path "$INST")"
    if [[ -e "$_state_path" || -L "$_state_path" ]]; then
        _read_instance_state "$_state_path"
        [[ "$STATE_INSTANCE" == "$INST" ]] || _die "实例状态 ID 不一致"
        if [[ -d "/proc/$STATE_PID" ]] \
            && [[ "$(_proc_start_time "$STATE_PID" 2>/dev/null || true)" == "$STATE_START" ]]; then
            _die "实例 $INST 已有活动 CPU 隔离登记 (pid=$STATE_PID)"
        fi
        # 只清理由同一授权用户遗留的已退出登记；不同 UID 的状态即使 stale 也保留，
        # 要求管理员审计，避免一个 sudo 用户借实例号覆盖另一个用户的记录。
        [[ "$STATE_CALLER_UID" == "$TARGET_CALLER_UID" ]] \
            || _die "实例 $INST 的遗留登记属于另一 UID=$STATE_CALLER_UID"
        rm -f -- "$_state_path" || _die "无法清理实例 $INST 的遗留登记"
    fi

    # 1) 其它在跑 VM 已被显式 taskset 收窄的逻辑 CPU = held。
    #    旧版只有 vCPU 单核绑定；启用 service CPU 后，辅助线程可能是 1 个或多个 CPU。
    #    但旧版 QEMU main/worker 往往还是完整 vmiso 分区 affinity，不能把这种完整
    #    分区误判为“所有 CPU 都被占用”，否则后续 VM 会分不到核。
    declare -A _held=()
    _vmiso_effective=""
    _vmiso_effective_norm=""
    [[ -r "$VMISO/cpuset.cpus.effective" ]] && _vmiso_effective="$(cat "$VMISO/cpuset.cpus.effective" 2>/dev/null || true)"
    [[ -n "$_vmiso_effective" ]] && _vmiso_effective_norm="$(_cpu_list_to_csv "$_vmiso_effective")"
    if [[ -d "$VMISO" && -r "$VMISO/cgroup.procs" ]]; then
        while read -r _op; do
            [[ -n "$_op" && "$_op" != "$PID" && -d "/proc/$_op" ]] || continue
            for _st in /proc/"$_op"/task/*/status; do
                _al=$(awk '/^Cpus_allowed_list:/{print $2}' "$_st" 2>/dev/null)
                [[ -n "$_al" ]] || continue
                _al_norm="$(_cpu_list_to_csv "$_al")"
                [[ -n "$_al_norm" ]] || continue
                [[ -n "$_vmiso_effective_norm" && "$_al_norm" == "$_vmiso_effective_norm" ]] && continue
                while read -r _cpu; do
                    [[ -n "$_cpu" ]] && _held[$_cpu]=1
                done < <(_cpu_list_to_lines "$_al")
            done
        done < "$VMISO/cgroup.procs"
    fi

    # 2) 按 PREF 跳过 held，先给 vCPU 分配 CPU，再按需给 QEMU 辅助线程分配 service CPU。
    #    service CPU 是显式开关：默认 0 保持旧行为；启用后优先保障 vCPU，剩余 CPU 才
    #    分给 main loop / IO / SDL / fb-shm worker。
    IFS=',' read -ra _pref <<< "$PREF"
    IFS=',' read -ra _tids <<< "$TIDS"
    _mine=()
    declare -A _candidate_seen=()
    _need=$(( ${#_tids[@]} + SERVICE_CPUS ))
    for _c in "${_pref[@]}"; do
        (( ${#_mine[@]} < _need )) || break
        [[ "$_c" =~ ^[0-9]+$ && -z "${_held[$_c]:-}" \
           && -z "${_candidate_seen[$_c]:-}" ]] || continue
        _candidate_seen[$_c]=1
        [[ -d "/sys/devices/system/cpu/cpu$_c" ]] || _die "候选 CPU 不存在: $_c"
        if [[ -r "/sys/devices/system/cpu/cpu$_c/online" ]]; then
            [[ "$(<"/sys/devices/system/cpu/cpu$_c/online")" == "1" ]] \
                || _die "候选 CPU 未在线: $_c"
        fi
        _mine+=("$_c")
    done
    (( ${#_mine[@]} == _need )) \
        || _die "空闲逻辑线程不足: 需要 $_need，只有 ${#_mine[@]}"
    _vcpu_mine=()
    _service_mine=()
    for _i in "${!_mine[@]}"; do
        if (( _i < ${#_tids[@]} )); then
            _vcpu_mine+=("${_mine[$_i]}")
        else
            _service_mine+=("${_mine[$_i]}")
        fi
    done

    # 3) vmiso.cpus = held ∪ 本台(vCPU + service) —— 分区恰好等于「所有在跑 VM 实占
    #    的逻辑 CPU」，随 VM 增减动态伸缩，绝不多锁宿主机线程。
    _all_csv=$( { for _k in "${!_held[@]}"; do echo "$_k"; done; printf '%s\n' "${_mine[@]}"; } | _csv_from_lines )
    _online_list="$(cat /sys/devices/system/cpu/online 2>/dev/null || true)"
    _online_count="$(_cpu_list_to_lines "$_online_list" | wc -l)"
    _allocated_count="$(_cpu_list_to_lines "$_all_csv" | wc -l)"
    [[ "$_online_count" =~ ^[0-9]+$ && "$_allocated_count" =~ ^[0-9]+$ ]] \
        || _die "无法统计在线/隔离 CPU"
    (( _online_count >= 3 && _allocated_count <= _online_count - 2 )) \
        || _die "隔离后必须至少给宿主保留 2 个在线 CPU（online=$_online_count allocated=$_allocated_count）"

    # 以下事务标志由固定运行库的 EXIT 回滚处理器消费。
    # shellcheck disable=SC2034
    APPLY_VMISO_TOUCHED=1
    # sudo 可能保留调用者的 0002 umask；显式用 0022 创建，保证随后 root-only
    # owner/mode 校验不会因开发组默认 umask 偶发失败。
    (umask 022; mkdir -p "$VMISO") 2>/dev/null || _die "建 $VMISO 失败"
    _validate_vmiso_dir
    echo "$_all_csv" > "$VMISO/cpuset.cpus" 2>/dev/null || _die "写 cpuset.cpus 失败"
    echo "$MEMS"     > "$VMISO/cpuset.mems" 2>/dev/null || _die "写 cpuset.mems 失败"

    # 切独占分区根: 这些线程从 root effective 摘走, 宿主机进程被挤到其余线程。
    _part_state="member"
    if echo root > "$VMISO/cpuset.cpus.partition" 2>/dev/null; then
        _part_state="$(cat "$VMISO/cpuset.cpus.partition" 2>/dev/null || echo '?')"
    fi
    case "$_part_state" in
        root)            echo ">> cpuset     : 独占分区 cpus=$_all_csv (这些逻辑线程已从宿主机摘走)" ;;
        "root invalid"*) _die "分区未进入独占状态: $_part_state" ;;
        *)               _die "cpuset partition 状态不是 root: $_part_state" ;;
    esac

    # 4) move QEMU 进分区(写 leader pid 即迁全部线程) + 逐 vCPU 1:1 钉死。
    # QEMU 已停止并完成完整身份复核；在唯一的 root PID 写入前后都核对
    # starttime。后续 affinity 全部降为调用者权限，不再以 root 操作裸 TID。
    _validate_target_unchanged "$PID"
    echo "$PID" > "$VMISO/cgroup.procs" 2>/dev/null \
        || _die "move pid=$PID 到 $VMISO_NAME 失败"
    # shellcheck disable=SC2034
    APPLY_MOVED=1
    _validate_target_unchanged "$PID"
    echo ">> move       : QEMU pid=$PID → $VMISO_NAME"
    _pinned=""
    _pinned_count=0
    for _i in "${!_vcpu_mine[@]}"; do
        _tid="${_tids[$_i]}"; _cpu="${_vcpu_mine[$_i]}"
        [[ "$_tid" =~ ^[0-9]+$ && -d "/proc/$PID/task/$_tid" ]] \
            || _die "vCPU TID 已消失或非法: $_tid"
        _run_as_caller "$TASKSET" -pc "$_cpu" "$_tid" >/dev/null 2>&1 \
            || _die "taskset vCPU tid=$_tid cpu=$_cpu 失败"
        _pinned="$_pinned vcpu→cpu$_cpu"
        _pinned_count=$((_pinned_count + 1))
    done
    (( _pinned_count == ${#_tids[@]} )) || _die "并非所有 vCPU 都完成 1:1 绑核"
    echo ">> vcpu pin   :$_pinned (1:1 钉死, 已避让其它 VM)"

    # 5) 可选：把 QEMU 非 vCPU 线程单独绑到 service CPU。
    #    这里必须排除 vCPU TID，避免覆盖上面的 1:1 pin；其它已存在 worker 逐个收窄，
    #    leader/main 被收窄后，后续由 main 创建的新线程也会继承这组 CPU。
    if (( SERVICE_CPUS > 0 )); then
        if (( ${#_service_mine[@]} == SERVICE_CPUS )); then
            _service_csv="$(printf '%s\n' "${_service_mine[@]}" | _csv_from_lines)"
            declare -A _vcpu_tids=()
            for _tid in "${_tids[@]}"; do
                _vcpu_tids[$_tid]=1
            done
            _service_count=0
            for _task in /proc/"$PID"/task/*; do
                _tid="${_task##*/}"
                [[ -n "${_vcpu_tids[$_tid]:-}" ]] && continue
                if _run_as_caller "$TASKSET" -pc "$_service_csv" "$_tid" \
                        >/dev/null 2>&1; then
                    _service_count=$((_service_count + 1))
                elif [[ -d "/proc/$PID/task/$_tid" ]]; then
                    _die "taskset service tid=$_tid cpus=$_service_csv 失败"
                fi
            done
            echo ">> qemu svc   : non-vCPU threads → cpus=$_service_csv (${_service_count} threads, 可配置开关)"
        else
            _die "service CPU 分配不足: 需要 $SERVICE_CPUS，只有 ${#_service_mine[@]}"
        fi
    fi
    _write_instance_state "$INST" "$PID" "$TARGET_START_TIME" \
        "$TARGET_CALLER_UID" "$(printf '%s\n' "${_mine[@]}" | _csv_from_lines)"
    # shellcheck disable=SC2034
    APPLY_STATE_WRITTEN=1
    _run_as_caller "$KILL" -CONT "$PID" || _die "无法恢复 QEMU 运行"
    # shellcheck disable=SC2034
    APPLY_STOPPED=0
    # shellcheck disable=SC2034
    APPLY_SUCCESS=1
    trap - EXIT HUP INT TERM
    echo "cpu-isolate applied."
    ;;

# ------------------------------------------------------------------ release
release)
    INST="${1:-}"
    _open_global_lock
    _state_path="$(_instance_state_path "$INST")"
    _state_present=0
    if [[ -e "$_state_path" || -L "$_state_path" ]]; then
        _read_instance_state "$_state_path"
        [[ "$STATE_INSTANCE" == "$INST" ]] || _die "实例状态 ID 不一致"
        [[ "$STATE_CALLER_UID" == "$(_caller_uid)" ]] \
            || _die "实例 $INST 的隔离登记属于另一 UID=$STATE_CALLER_UID"
        if [[ -d "/proc/$STATE_PID" ]] \
            && [[ "$(_proc_start_time "$STATE_PID" 2>/dev/null || true)" == "$STATE_START" ]]; then
            _die "实例 $INST 的 QEMU 仍在运行，拒绝提前释放 CPU"
        fi
        _state_present=1
    fi
    if [[ ! -d "$VMISO" ]]; then
        (( _state_present == 0 )) || rm -f -- "$_state_path" \
            || _die "无法删除实例 $INST 的隔离登记"
        echo ">> cpuset     : 无分区, 无需释放"
        exit 0
    fi
    _validate_vmiso_dir

    # 扫分区内活进程 + 它们显式 taskset 收窄的线程 = remaining。
    # service CPU 可能是多 CPU 列表，所以这里和 apply 一样展开 Cpus_allowed_list。
    declare -A _rem=()
    _live=0
    _vmiso_effective=""
    _vmiso_effective_norm=""
    [[ -r "$VMISO/cpuset.cpus.effective" ]] && _vmiso_effective="$(cat "$VMISO/cpuset.cpus.effective" 2>/dev/null || true)"
    [[ -n "$_vmiso_effective" ]] && _vmiso_effective_norm="$(_cpu_list_to_csv "$_vmiso_effective")"
    if [[ -r "$VMISO/cgroup.procs" ]]; then
        while read -r _p; do
            [[ -n "$_p" && -d "/proc/$_p" ]] || continue
            _live=$((_live+1))
            for _st in /proc/"$_p"/task/*/status; do
                _al=$(awk '/^Cpus_allowed_list:/{print $2}' "$_st" 2>/dev/null)
                [[ -n "$_al" ]] || continue
                _al_norm="$(_cpu_list_to_csv "$_al")"
                [[ -n "$_al_norm" ]] || continue
                [[ -n "$_vmiso_effective_norm" && "$_al_norm" == "$_vmiso_effective_norm" ]] && continue
                while read -r _cpu; do
                    [[ -n "$_cpu" ]] && _rem[$_cpu]=1
                done < <(_cpu_list_to_lines "$_al")
            done
        done < "$VMISO/cgroup.procs"
    fi

    if (( _live == 0 )); then
        # 空了: 切回 member(线程立刻还给 root), 再删目录。
        echo member > "$VMISO/cpuset.cpus.partition" 2>/dev/null || true
        if rmdir "$VMISO" 2>/dev/null; then
            echo ">> cpuset     : 分区已拆除, ${INST:+实例 $INST }专属线程已全部还给宿主机"
        else
            _warn "rmdir $VMISO 失败(可能仍有残留), 已切回 member"
        fi
    else
        (( _state_present == 1 )) \
            || _die "实例 $INST 没有可信隔离登记，且分区仍有其它进程；拒绝收缩"
        # 还有别的 VM: 把分区收缩到「剩余在跑 VM 的显式绑定 CPU」, 已退 VM 的线程
        # 还给宿主机。完整 vmiso affinity 仍视为旧式辅助线程均衡，不参与占用统计。
        _rem_csv=$( for _k in "${!_rem[@]}"; do echo "$_k"; done | sort -n -u | paste -sd, - )
        if [[ -n "$_rem_csv" ]]; then
            echo "$_rem_csv" > "$VMISO/cpuset.cpus" 2>/dev/null || true
            echo ">> cpuset     : 仍有 $_live 个 VM 在跑, 分区收缩到 cpus=$_rem_csv (已退 VM 线程已还宿主机)"
        else
            echo ">> cpuset     : 仍有 $_live 个进程但无单核绑定, 分区暂不变"
        fi
    fi
    if (( _state_present == 1 )); then
        rm -f -- "$_state_path" || _die "无法删除实例 $INST 的隔离登记"
    fi
    ;;

# ------------------------------------------------------------------- status
status)
    if [[ ! -d "$VMISO" ]]; then
        echo "cpu-isolate: 无分区(未隔离)"; exit 0
    fi
    _validate_vmiso_dir
    echo "cpu-isolate: 分区 $VMISO"
    echo "  cpuset.cpus           = $(cat "$VMISO/cpuset.cpus" 2>/dev/null)"
    echo "  cpuset.cpus.effective = $(cat "$VMISO/cpuset.cpus.effective" 2>/dev/null)"
    echo "  cpuset.cpus.partition = $(cat "$VMISO/cpuset.cpus.partition" 2>/dev/null)"
    echo "  root effective cpus   = $(cat "$CG_ROOT/cpuset.cpus.effective" 2>/dev/null)  (宿主机其它进程可用核)"
    _n=0; while read -r _p; do [[ -n "$_p" ]] && _n=$((_n+1)); done < "$VMISO/cgroup.procs" 2>/dev/null
    echo "  分区内进程数          = $_n"
    ;;

*)
    _die "未知子命令: '$CMD' (preflight|apply|release|status)"
    ;;
esac
