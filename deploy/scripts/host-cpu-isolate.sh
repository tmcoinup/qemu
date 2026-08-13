#!/bin/bash
# shellcheck disable=SC2034
# ---------------------------------------------------------------------------
# host-cpu-isolate.sh —— 把一台隐身 VM 的 QEMU 进程钉进一个 cgroup v2 cpuset
# 「独占分区」, 让每个 vCPU 拥有唯一宿主逻辑 CPU，不与其它 VM/宿主线程超分同一
# logical CPU。SMT sibling 仍可能共享物理执行资源。需要 root(走 sudo NOPASSWD)。
#
# 背景 / 为什么需要它:
#   start-vm 原先的 host 调优(host-performance.sh)只做了 governor / 频率封顶 /
#   halt_poll / THP / irqbalance —— 全是「单位时间跑多快」与「时钟抖动」的旋钮,
#   **没有任何一项把 vCPU 钉在独占核上**。所以宿主机一跑满 CPU(cargo build 默认
#   nproc 个并行任务塞满全部 16 个逻辑核), QEMU 的 4 个 vCPU 线程只是普通 CFS
#   线程, 要和几十个 rustc 线程抢同一批核 → guest 该跑时抢不到核 → 卡顿、掉帧、
#   鼠标延迟、ACE「游戏计时异常」。频率封顶不但治不了这个, 反而把宿主机算力也压
#   低了。当前策略给 VM 划分与 vCPU 数量 1:1 的专属逻辑 CPU，把宿主其它进程挤出
#   这些调度队列；未被选中的 SMT sibling 不额外圈占，可供宿主或其它 VM 使用。
#
# 做法 (cgroup v2 cpuset partition, 纯运行态, 不动内核启动参数、不重启、可逆):
#   1) 建父 /sys/fs/cgroup/<VMISO> 保存所有 VM 的 CPU union，再为每个实例建立
#      exact child vm-N，只把该实例实际选中的 vCPU/service 逻辑 CPU 写进 child;
#   2) 父层 cpuset.cpus.partition = root → union 中的核从宿主 effective 里**被
#      独占摘走**, 于是宿主机所有其它进程(桌面/shell/编译)自动被内核迁出这些核,
#      只能用剩下的核 —— 无需逐个去改 system.slice/user.slice;
#   3) 把 QEMU 整个进程(连同全部线程)move 进 vm-N → 仅能使用本实例 CPU 集合;
#   4) 再对每个 vCPU 线程做 1:1 taskset, 钉到各自的逻辑 CPU；
#   5) 如果 start-vm 传入 QEMU_SERVICE_CPUS>0，则额外分配一组 service CPU，
#      并把 QEMU main / IO / SDL / fb-shm worker 等非 vCPU 线程收窄到这组 CPU，
#      避免显示/IO 线程和 100% 满载 vCPU 抢同一条调度队列。
#
# 多 VM 共存: 所有实例共用父 VMISO 分区；apply 在全局锁内读取全部 exact child
# cpuset 并排除已占逻辑 CPU。release 只删除目标空 child，再缩减父 union；最后一个
# child 消失时才拆父分区还核。
#
# 子命令:
#   preflight                    # 验证 cgroup v2/cpuset 与当前 sudo 授权
#   apply <instance> <mems> <pid> <pref> <tids> <service> <guest_tpc> <host_tpc>
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
readonly CPU_ISOLATE_RUNTIME_ABI="5" CPU_ISOLATE_PACKING_POLICY="logical-1to1-v1"
readonly CPU_ISOLATE_CGROUP_ABI="5"
readonly RUNTIME_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-runtime-v5.sh"
readonly CGROUP_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-cgroup-v5.sh"
readonly TRUST_LIB="/usr/local/libexec/qemu-vmate-qemu-trust-v1.sh"
readonly LOADER_LIB="/usr/local/libexec/qemu-vmate-cpu-isolate-loader-v1.sh"
readonly QEMU_TRUST_ABI="1"
# 该变量由固定运行库消费；shellcheck 单文件分析看不到跨文件引用。
readonly TRUST_MANIFEST="/usr/local/libexec/qemu-vmate-cpu-isolate-qemu.conf"
_die() { echo "host-cpu-isolate: $*" >&2; exit 1; }
_warn() { echo "host-cpu-isolate: $*" >&2; }
_validate_topology_policy() {
    case "$1:$2:$3" in 2:1:1|4:2:2|4:1:1) return 0 ;; *) _die "不支持的 vCPU/guest_tpc/host_tpc 组合: $1/$2/$3" ;; esac
}
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
    flock -x 9 || _die "无法取得 CPU 分配全局锁"
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
    local path="$1" line key value; local -a state_vcpus=()
    STATE_INSTANCE=""; STATE_PID=""; STATE_START=""; STATE_CALLER_UID=""
    STATE_CPUS=""; STATE_VCPU_CPUS=""; STATE_MEMS=""; STATE_PHASE=""
    STATE_GUEST_TPC=""; STATE_HOST_TPC=""; STATE_SERVICE_CPUS=""; STATE_DOMAIN=""; STATE_ABI=""
    _validate_state_file "$path"
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$line" == *"="* ]] || _die "实例状态行格式错误: $path"
        case "$key" in
            abi) STATE_ABI="$value" ;;
            instance) STATE_INSTANCE="$value" ;;
            pid) STATE_PID="$value" ;;
            start_time) STATE_START="$value" ;;
            caller_uid) STATE_CALLER_UID="$value" ;;
            cpus) STATE_CPUS="$value" ;;
            vcpu_cpus) STATE_VCPU_CPUS="$value" ;;
            mems) STATE_MEMS="$value" ;;
            service_cpu_count) STATE_SERVICE_CPUS="$value" ;;
            guest_threads_per_core) STATE_GUEST_TPC="$value" ;;
            host_threads_per_core) STATE_HOST_TPC="$value" ;;
            domain) STATE_DOMAIN="$value" ;;
            phase) STATE_PHASE="$value" ;;
            *) _die "实例状态含未知字段: $key" ;;
        esac
    done < "$path"
    [[ "$STATE_ABI" == "5" && "$STATE_INSTANCE" =~ ^[1-9][0-9]{0,9}$ &&
       "$STATE_PID" =~ ^[0-9]+$ && "$STATE_START" =~ ^[0-9]+$ &&
       "$STATE_CALLER_UID" =~ ^[0-9]+$ &&
       "$STATE_CPUS" =~ ^[0-9]+(,[0-9]+)*$ &&
       "$STATE_VCPU_CPUS" =~ ^[0-9]+(,[0-9]+)*$ &&
       "$STATE_MEMS" =~ ^[0-9]+(,[0-9]+)*$ &&
       "$STATE_SERVICE_CPUS" =~ ^[0-8]$ &&
       "$STATE_GUEST_TPC" =~ ^[1-8]$ &&
       "$STATE_HOST_TPC" =~ ^[1-8]$ &&
       "$STATE_DOMAIN" =~ ^[0-9]+:[0-9]+$ &&
       "$STATE_PHASE" =~ ^(preparing|active|releasing)$ ]] \
        || _die "实例状态字段非法: $path"
    IFS=',' read -ra state_vcpus <<< "$STATE_VCPU_CPUS"
    _validate_topology_policy "${#state_vcpus[@]}" "$STATE_GUEST_TPC" "$STATE_HOST_TPC"
}
_write_instance_state() {
    local instance="$1" pid="$2" start_time="$3" caller="$4" cpus="$5"
    local vcpu_cpus="$6" mems="$7" service="$8" guest_tpc="$9"
    local host_tpc="${10}" domain="${11}" phase="${12}"
    local path tmp
    path="$(_instance_state_path "$instance")"
    tmp="$(mktemp "$INSTANCE_DIR/.${instance}.XXXXXX")" \
        || _die "无法创建实例状态临时文件"
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; _die "无法设置实例状态权限"; }
    {
        printf 'abi=5\ninstance=%s\n' "$instance"
        printf 'pid=%s\n' "$pid"
        printf 'start_time=%s\n' "$start_time"
        printf 'caller_uid=%s\n' "$caller"
        printf 'cpus=%s\n' "$cpus"
        printf 'vcpu_cpus=%s\n' "$vcpu_cpus"
        printf 'mems=%s\n' "$mems"
        printf 'service_cpu_count=%s\n' "$service"
        printf 'guest_threads_per_core=%s\n' "$guest_tpc"
        printf 'host_threads_per_core=%s\n' "$host_tpc"
        printf 'domain=%s\n' "$domain"
        printf 'phase=%s\n' "$phase"
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
    local command="${1:-}"; local -a cli_tids=()
    case "$command" in
        preflight)
            (( $# <= 2 )) || _die "用法: preflight [--qemu=/canonical/path]"
            if (( $# == 2 )); then
                [[ "$2" == --qemu=/* && -n "${2#--qemu=}" && ${#2} -le 4103 &&
                   "$2" != *$'\r'* && "$2" != *$'\n'* ]] \
                    || _die "preflight --qemu 路径非法"
            fi
            ;;
        apply)
            (( $# == 9 )) \
                || _die "用法: apply <instance> <mems> <pid> <pref> <tids> <service> <guest_tpc> <host_tpc>"
            [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] || _die "instance 非法: $2"
            [[ "$3" =~ ^[0-9]+([,-][0-9]+)*$ ]] || _die "mems 非法: $3"
            [[ "$4" =~ ^[0-9]+$ ]] || _die "pid 非法: $4"
            [[ "$5" =~ ^[0-9]+(,[0-9]+)*$ ]] || _die "pref_order 非法: $5"
            [[ "$6" =~ ^[0-9]+(,[0-9]+)*$ ]] || _die "tids 非法: $6"
            [[ "$7" =~ ^[0-8]$ ]] || _die "service_cpu_count 必须为单字符 0..8: $7"
            [[ "$8" =~ ^[1-8]$ ]] || _die "guest_threads_per_core 必须为 1..8: $8"
            [[ "$9" =~ ^[1-8]$ ]] || _die "host_threads_per_core 必须为 1..8: $9"
            IFS=',' read -ra cli_tids <<< "$6"
            _validate_topology_policy "${#cli_tids[@]}" "$8" "$9"
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

# status 的展示属于 CLI 主程序；资源枚举只复用 cgroup 库已经验证并返回的数组，
# 不再维护第二套较弱的 glob 规则。
_status_instance_cpusets() {
    local child name cpu online status=0
    [[ -d "$VMISO" ]] || { echo "cpu-isolate: 无分区(未隔离)"; return 0; }
    _collect_instance_allocations
    echo "cpu-isolate: 父分区 $VMISO, 实例数=$ISO_CHILD_COUNT"
    echo "  cpuset.cpus           = $(<"$VMISO/cpuset.cpus")"
    echo "  cpuset.cpus.effective = $(<"$VMISO/cpuset.cpus.effective")"
    online="$(< /sys/devices/system/cpu/online)"
    for child in "${ISO_CHILD_PATHS[@]}"; do
        name="${child##*/}"; _read_instance_state \
            "$(_instance_state_path "${name#"${VMISO_CHILD_PREFIX}"}")"
        while IFS= read -r cpu; do
            case ",$(_strict_cpu_list_to_csv "$online")," in
                *",$cpu,"*) ;;
                *) echo "  ERROR $name: vCPU $cpu 已 offline" >&2; status=1 ;;
            esac
        done < <(_strict_cpu_list_to_lines "$STATE_VCPU_CPUS")
        echo "  $name: node=$STATE_MEMS cpus=$STATE_CPUS vcpus=$STATE_VCPU_CPUS service=$STATE_SERVICE_CPUS guest_tpc=$STATE_GUEST_TPC host_tpc=$STATE_HOST_TPC phase=$STATE_PHASE"
    done
    return "$status"
}

# 取 root（与 host-performance.sh 同款: 以脚本路径重入 sudo, 匹配 NOPASSWD 规则）。
if [[ $EUID -ne 0 ]]; then
    exec sudo -n -- "$0" "$@" 2>/dev/null || { _warn "需要 root 但无免密 sudo"; exit 1; }
fi

# 在 source 之前先锁定父目录信任边界；loader 内会再次核验并装载其余 ABI 库。
_loader_parent="${LOADER_LIB%/*}"
[[ -d "$_loader_parent" && ! -L "$_loader_parent" ]] \
    || _die "CPU isolate loader 目录不可信"
_loader_meta="$(stat -Lc '%u:%g:%a' -- "$_loader_parent" 2>/dev/null)" \
    || _die "无法读取 CPU isolate loader 目录元数据"
IFS=: read -r _loader_uid _loader_gid _loader_mode <<<"$_loader_meta"
[[ "$_loader_uid:$_loader_gid" == "0:0" && "$_loader_mode" =~ ^[0-7]{3,4}$ ]] \
    && (( (8#$_loader_mode & 8#022) == 0 )) \
    || _die "CPU isolate loader 目录 owner/mode 不可信"
[[ -f "$LOADER_LIB" && ! -L "$LOADER_LIB" &&
   "$(stat -Lc '%u:%g:%a:%h' -- "$LOADER_LIB" 2>/dev/null)" == "0:0:755:1" ]] \
    || _die "CPU isolate loader 文件不可信"
# shellcheck disable=SC1090
source "$LOADER_LIB"
_load_runtime_libraries

CMD="${1:-}"; shift || true

# 主 helper 与两个 root-owned ABI 库通过受控全局变量交换事务状态和分配结果。
# shellcheck disable=SC2034,SC2154
case "$CMD" in
# --------------------------------------------------------------- preflight
preflight)
    _preflight_qemu="${1:-}"
    _prepare_runtime
    _precheck || exit 1
    _validate_memory_locality_tool
    _open_global_lock
    _validate_trust_manifest "${_preflight_qemu#--qemu=}"
    [[ ! -d "$VMISO" ]] || _collect_instance_allocations
    echo "cpu-isolate preflight passed (abi=5 policy=$CPU_ISOLATE_PACKING_POLICY)."
    ;;

# -------------------------------------------------------------------- apply
apply)
    INST="${1:-}"; MEMS="${2:-0}"; PID="${3:-}"; PREF="${4:-}"; TIDS="${5:-}"
    SERVICE_CPUS="${6:-0}"; GUEST_THREADS_PER_CORE="${7:-1}"
    HOST_THREADS_PER_CORE="${8:-1}"
    [[ -n "$PID" && -n "$PREF" && -n "$TIDS" ]] \
        || _die "用法: apply <instance> <mems> <pid> <pref> <tids> <service> <guest_tpc> <host_tpc>"
    # 参数已在提权前后由 _validate_cli 严格验证，这里不再静默改写非法输入。

    _precheck || exit 1
    _open_global_lock
    _validate_trust_manifest
    _validate_qemu_target "$PID" "$TIDS"

    # 串行化后的 helper 才是最终 NUMA/CPU 分配者。锁内逐台排除已占 logical CPU。
    _validate_target_unchanged "$PID"
    _state_path="$(_instance_state_path "$INST")"
    if [[ -e "$_state_path" || -L "$_state_path" ]]; then
        _read_instance_state "$_state_path"
        [[ "$STATE_INSTANCE" == "$INST" ]] || _die "实例状态 ID 不一致"
        if _proc_generation_is_live "$STATE_PID" "$STATE_START"; then
            _die "实例 $INST 已有活动 CPU 隔离登记 (pid=$STATE_PID)"
        fi
        [[ "$STATE_CALLER_UID" == "$TARGET_CALLER_UID" ]] \
            || _die "实例 $INST 的遗留登记属于另一 UID=$STATE_CALLER_UID"
        _release_instance_cpuset "$INST"
    fi
    _collect_instance_allocations
    IFS=',' read -ra _tids <<< "$TIDS"
    (( ${#_tids[@]} % GUEST_THREADS_PER_CORE == 0 )) \
        || _die "vCPU TID 数与来宾 threads-per-core 不整除"
    (( ${#_tids[@]} % HOST_THREADS_PER_CORE == 0 )) \
        || _die "vCPU TID 数与宿主 packing threads-per-core 不整除"
    _instance_path="$(_instance_cgroup_path "$INST")"
    _apply_transaction_begin
    _select_instance_cpus "$PREF" "$MEMS" "${#_tids[@]}" \
        "$SERVICE_CPUS" "$GUEST_THREADS_PER_CORE" "$HOST_THREADS_PER_CORE"
    _write_instance_state "$INST" "$PID" "$TARGET_START_TIME" \
        "$TARGET_CALLER_UID" "$_instance_cpus_csv" "$_vcpu_cpus_csv" \
        "$_selected_node" "$SERVICE_CPUS" "$GUEST_THREADS_PER_CORE" "$HOST_THREADS_PER_CORE" \
        "$_selected_domain" preparing
    APPLY_STATE_WRITTEN=1
    _activate_instance_cpuset

    # 父分区不放进程；QEMU 整体进入 exact child，service=0 时辅助线程与 vCPU
    # 共享本实例的 2/4/4 条逻辑 CPU。完成内存收窄和 vCPU 绑核后才 QMP cont。
    _validate_target_unchanged "$PID"
    echo "$PID" > "$_instance_path/cgroup.procs" 2>/dev/null \
        || _die "move pid=$PID 到实例 child 失败"
    APPLY_MOVED=1
    _validate_target_unchanged "$PID"
    _localize_instance_memory
    echo ">> move       : QEMU pid=$PID → ${_instance_path##*/} ($_selected_domain)"
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

    # 可选：把 QEMU 非 vCPU 线程单独绑到 service CPU。
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
    _validate_recorded_topology "$_vcpu_cpus_csv" "$GUEST_THREADS_PER_CORE" \
        "$HOST_THREADS_PER_CORE" "$SERVICE_CPUS" "$_selected_domain" "$_instance_cpus_csv" 1
    _write_instance_state "$INST" "$PID" "$TARGET_START_TIME" \
        "$TARGET_CALLER_UID" "$_instance_cpus_csv" "$_vcpu_cpus_csv" \
        "$_selected_node" "$SERVICE_CPUS" "$GUEST_THREADS_PER_CORE" "$HOST_THREADS_PER_CORE" \
        "$_selected_domain" active
    _run_as_caller "$KILL" -CONT "$PID" || _die "无法恢复 QEMU 运行"
    APPLY_STOPPED=0
    APPLY_SUCCESS=1
    trap - EXIT HUP INT TERM
    echo "cpu-isolate applied."
    ;;
# ------------------------------------------------------------------ release
release)
    INST="${1:-}"
    _open_global_lock
    _release_instance_cpuset "$INST"
    ;;

# ------------------------------------------------------------------- status
status)
    _open_global_lock
    _status_instance_cpusets
    ;;

*)
    _die "未知子命令: '$CMD' (preflight|apply|release|status)"
    ;;
esac
