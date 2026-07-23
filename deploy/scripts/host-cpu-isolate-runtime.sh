#!/bin/bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# host-cpu-isolate 的提权运行时：可信 QEMU 身份校验、降权进程操作和 apply 事务回滚。
#
# 本文件由 setup-host-helpers.sh 以 root:root 0755 安装到固定 libexec 路径。主 helper
# 只在完成 CLI 校验和 sudo 重入后，从该固定路径加载本文件；绝不能从用户可写工作树
# source。这里依赖主 helper 提供的 _die/_warn、CG_ROOT/VMISO、PID/TIDS 等受控变量。
# ---------------------------------------------------------------------------

# 由 source 本文件的 main helper 读取；独立 ShellCheck 看不到跨文件 ABI 握手。
# shellcheck disable=SC2034
readonly VMATE_CPU_ISOLATE_RUNTIME_ABI="5"
readonly SETPRIV="/usr/bin/setpriv"
readonly TASKSET="/usr/bin/taskset"
readonly KILL="/bin/kill"
readonly RMDIR="/usr/bin/rmdir"
readonly MIGRATEPAGES="/usr/bin/migratepages"
readonly TIMEOUT="/usr/bin/timeout"

_proc_start_time() {
    local pid="$1" stat_line rest
    local -a stat_fields=()
    stat_line="$(<"/proc/$pid/stat")" || return 1
    # /proc/PID/stat 的 comm 位于括号内且可能含空格；删除到最后一个 `) ` 后，
    # 剩余数组的第 20 项才是原始结构中的 field 22（进程 starttime）。
    rest="${stat_line##*) }"
    read -ra stat_fields <<<"$rest"
    (( ${#stat_fields[@]} >= 20 )) || return 1
    [[ "${stat_fields[19]}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${stat_fields[19]}"
}

_proc_generation_is_live() {
    local pid="$1" expected="$2" stat_line rest
    local -a fields=()
    stat_line="$(<"/proc/$pid/stat")" || return 1
    rest="${stat_line##*) }"
    read -ra fields <<< "$rest"
    (( ${#fields[@]} >= 20 )) || return 1
    [[ "${fields[0]}" != "Z" && "${fields[0]}" != "z" \
       && "${fields[0]}" != "X" && "${fields[0]}" != "x" \
       && "${fields[19]}" == "$expected" ]]
}

_caller_uid() {
    local uid="${SUDO_UID:-0}"
    [[ "$uid" =~ ^[0-9]+$ ]] || _die "SUDO_UID 非法"
    printf '%s\n' "$uid"
}

_caller_gid() {
    local gid="${SUDO_GID:-0}"
    [[ "$gid" =~ ^[0-9]+$ ]] || _die "SUDO_GID 非法"
    printf '%s\n' "$gid"
}

_validate_trust_manifest() {
    local metadata uid gid mode links line key value device inode digest

    [[ -f "$TRUST_MANIFEST" && ! -L "$TRUST_MANIFEST" ]] \
        || _die "QEMU 信任清单不是普通文件: $TRUST_MANIFEST"
    metadata="$(stat -Lc '%u %g %a %h' -- "$TRUST_MANIFEST" 2>/dev/null)" \
        || _die "无法读取 QEMU 信任清单元数据"
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid:$mode:$links" == "0:0:644:1" ]] \
        || _die "QEMU 信任清单必须为 root:root 0644 且只有一个硬链接"

    TRUSTED_QEMU_PATH=""; TRUSTED_QEMU_SHA256=""
    TRUSTED_QEMU_DEVICE=""; TRUSTED_QEMU_INODE=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || _die "QEMU 信任清单格式错误"
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            path) [[ -z "$TRUSTED_QEMU_PATH" ]] || _die "QEMU 信任清单 path 重复"
                  TRUSTED_QEMU_PATH="$value" ;;
            sha256) [[ -z "$TRUSTED_QEMU_SHA256" ]] || _die "QEMU 信任清单 sha256 重复"
                    TRUSTED_QEMU_SHA256="$value" ;;
            device) [[ -z "$TRUSTED_QEMU_DEVICE" ]] || _die "QEMU 信任清单 device 重复"
                    TRUSTED_QEMU_DEVICE="$value" ;;
            inode) [[ -z "$TRUSTED_QEMU_INODE" ]] || _die "QEMU 信任清单 inode 重复"
                   TRUSTED_QEMU_INODE="$value" ;;
            *) _die "QEMU 信任清单含未知字段: $key" ;;
        esac
    done < "$TRUST_MANIFEST"
    [[ "$TRUSTED_QEMU_PATH" == /* && "$TRUSTED_QEMU_PATH" != *$'\r'* &&
       "$TRUSTED_QEMU_SHA256" =~ ^[0-9a-f]{64}$ &&
       "$TRUSTED_QEMU_DEVICE" =~ ^[0-9]+$ && "$TRUSTED_QEMU_INODE" =~ ^[0-9]+$ ]] \
        || _die "QEMU 信任清单字段非法，请重新安装 host helpers"

    # preflight 必须在 QEMU 启动前发现“重编译后忘记重装清单”，不能只检查配置格式
    # 而把失败推迟到异步 pinner。canonical path 的文件也拒绝被 symlink 替换。
    [[ -f "$TRUSTED_QEMU_PATH" && ! -L "$TRUSTED_QEMU_PATH" &&
       -s "$TRUSTED_QEMU_PATH" && -x "$TRUSTED_QEMU_PATH" ]] \
        || _die "信任清单中的 QEMU 不再是非空可执行普通文件"
    metadata="$(stat -Lc '%d %i' -- "$TRUSTED_QEMU_PATH" 2>/dev/null)" \
        || _die "无法读取信任清单中的 QEMU inode"
    read -r device inode <<<"$metadata"
    [[ "$device:$inode" == "$TRUSTED_QEMU_DEVICE:$TRUSTED_QEMU_INODE" ]] \
        || _die "QEMU 构建 inode 已变化，请重新安装 host helpers"
    digest="$(sha256sum -- "$TRUSTED_QEMU_PATH" 2>/dev/null)" \
        || _die "无法校验信任清单中的 QEMU 摘要"
    digest="${digest%% *}"
    [[ "$digest" == "$TRUSTED_QEMU_SHA256" ]] \
        || _die "QEMU 构建摘要已变化，请重新安装 host helpers"
}

_validate_trusted_executable() {
    local pid="$1" exe metadata device inode digest

    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" \
        || _die "无法读取 pid=$pid 可执行文件"
    [[ "$exe" != *" (deleted)" ]] || _die "QEMU executable 已被替换或删除"
    [[ "$exe" == "$TRUSTED_QEMU_PATH" ]] \
        || _die "QEMU executable 未在 root-owned 信任清单中: $exe"
    metadata="$(stat -Lc '%d %i' -- "/proc/$pid/exe" 2>/dev/null)" \
        || _die "无法读取 QEMU executable inode"
    read -r device inode <<<"$metadata"
    [[ "$device:$inode" == "$TRUSTED_QEMU_DEVICE:$TRUSTED_QEMU_INODE" ]] \
        || _die "QEMU executable inode 已变化，请重新安装 host helpers"
    digest="$(sha256sum "/proc/$pid/exe" 2>/dev/null)" \
        || _die "无法校验 QEMU executable 摘要"
    digest="${digest%% *}"
    [[ "$digest" == "$TRUSTED_QEMU_SHA256" ]] \
        || _die "QEMU executable 摘要不匹配，请重新安装 host helpers"
}

_validate_instance_name() {
    local pid="$1" expected="win10-${INST}," index
    local -a argv=()

    mapfile -d '' -t argv < "/proc/$pid/cmdline" \
        || _die "无法读取 QEMU 命令行"
    for index in "${!argv[@]}"; do
        if [[ "${argv[$index]}" == "-name" &&
              "${argv[$((index + 1))]:-}" == "$expected"* ]]; then
            return 0
        fi
        [[ "${argv[$index]}" == "-name=$expected"* ]] && return 0
    done
    _die "QEMU -name 与实例 $INST 不匹配"
}

# NOPASSWD helper 只接受：调用 UID 自有、安装时登记的精确 executable、实例名匹配，
# 且 TID 全部属于该进程并具有 QEMU vCPU 线程名的目标。仅伪造 basename 已无法取得
# cpuset 分区；每次完整复核还会重新计算摘要，覆盖用户可写开发构建被原地改写的情况。
_validate_qemu_target() {
    local pid="$1" tids_csv="$2" caller owner tid tgid comm
    local -a validate_tids=()
    local -A seen_tids=()

    caller="$(_caller_uid)"
    [[ -d "/proc/$pid" ]] || _die "pid 不存在: $pid"
    owner="$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)"
    [[ "$owner" == "$caller" ]] \
        || _die "只允许操作调用者 UID=$caller 的 QEMU（pid=$pid owner=$owner）"
    _validate_trusted_executable "$pid"
    _validate_instance_name "$pid"

    IFS=',' read -ra validate_tids <<<"$tids_csv"
    (( ${#validate_tids[@]} >= 1 && ${#validate_tids[@]} <= 64 )) \
        || _die "vCPU TID 数必须为 1..64"
    for tid in "${validate_tids[@]}"; do
        [[ -z "${seen_tids[$tid]:-}" ]] || _die "重复 vCPU TID: $tid"
        seen_tids[$tid]=1
        [[ -d "/proc/$pid/task/$tid" ]] || _die "TID 不属于目标 pid: $tid"
        tgid="$(awk '/^Tgid:/{print $2; exit}' "/proc/$pid/task/$tid/status" 2>/dev/null)"
        [[ "$tgid" == "$pid" ]] || _die "TID=$tid 的 Tgid 与 pid=$pid 不一致"
        comm="$(<"/proc/$pid/task/$tid/comm")" || _die "无法读取 TID=$tid 名称"
        [[ "$comm" =~ ^CPU\ [0-9]+/(KVM|TCG)$ ]] \
            || _die "TID=$tid 不是 QEMU vCPU 线程: $comm"
    done
    TARGET_START_TIME="$(_proc_start_time "$pid")" || _die "无法读取 pid starttime"
    TARGET_CALLER_UID="$caller"
}

_validate_target_unchanged() {
    local pid="$1" current
    current="$(_proc_start_time "$pid")" || _die "QEMU 在隔离前已退出"
    [[ "$current" == "$TARGET_START_TIME" ]] || _die "QEMU pid 在隔离前被复用"
}

_revalidate_qemu_target() {
    local pid="$1" tids="$2" expected_start="$TARGET_START_TIME"
    local expected_uid="$TARGET_CALLER_UID" actual_start

    _validate_qemu_target "$pid" "$tids"
    actual_start="$TARGET_START_TIME"
    TARGET_START_TIME="$expected_start"
    TARGET_CALLER_UID="$expected_uid"
    [[ "$actual_start" == "$expected_start" ]] \
        || _die "QEMU pid 在完整身份复核期间被复用"
}

_target_is_unchanged() {
    local current
    current="$(_proc_start_time "$PID" 2>/dev/null)" || return 1
    [[ "$current" == "$TARGET_START_TIME" ]]
}

# affinity 与信号本来就允许进程所有者完成，不能因为 helper 是 root 就扩大权限。
# 清空 capability/附加组后，即使 TID/PID 恰好复用到另一用户，内核也会拒绝操作。
_run_as_caller() {
    "$SETPRIV" --reuid "$TARGET_CALLER_UID" --regid "$TARGET_CALLER_GID" \
        --clear-groups --bounding-set=-all --inh-caps=-all \
        --ambient-caps=-all --no-new-privs -- "$@"
}

# 只用于内核 sysfs/cgroup 输出的严格 cpulist 解析。通用 helper 的旧解析器会忽略
# 非法片段，不适合验证“完整物理核”这种安全不变量；这里遇到空值、倒序范围或任意
# 非标准字符都返回失败。
_strict_cpu_list_to_lines() {
    local list="$1" part start end cpu
    local -a parts=()

    [[ "$list" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
    IFS=',' read -ra parts <<< "$list"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            start=$((10#${part%-*}))
            end=$((10#${part#*-}))
            (( start <= end )) || return 1
            for ((cpu=start; cpu<=end; cpu++)); do
                printf '%s\n' "$cpu"
            done
        else
            printf '%s\n' "$((10#$part))"
        fi
    done
}

_strict_cpu_list_to_csv() {
    local lines
    lines="$(_strict_cpu_list_to_lines "$1")" || return 1
    [[ -n "$lines" ]] || return 1
    printf '%s\n' "$lines" | sort -n -u | paste -sd, -
}

# 返回两个严格 cpulist 的交集。cpuset.cpus 会保留暂时 offline 的 CPU 请求，而
# *.effective 只呈现当前在线且由父级实际授予的部分；核验时必须区分这两层语义。
_strict_cpu_list_intersection_csv() {
    local left="$1" right="$2" cpu left_lines right_lines
    local -A right_set=()

    left_lines="$(_strict_cpu_list_to_lines "$left")" || return 1
    right_lines="$(_strict_cpu_list_to_lines "$right")" || return 1
    while IFS= read -r cpu; do
        [[ -n "$cpu" ]] && right_set[$cpu]=1
    done <<< "$right_lines"
    while IFS= read -r cpu; do
        [[ -n "$cpu" && -n "${right_set[$cpu]:-}" ]] && printf '%s\n' "$cpu"
    done <<< "$left_lines" | sort -n -u | paste -sd, -
}

# 写入 partition 后必须核对内核实际授予的 effective/exclusive 集合。只检查请求值或
# partition 文本会在父级约束、热插拔或兄弟分区冲突时误报成功。
_verify_vmiso_cpu_grant() {
    local expected="$1" expected_norm expected_online online requested
    local effective exclusive partition

    expected_norm="$(_strict_cpu_list_to_csv "$expected")" \
        || _die "期望 cpuset 格式非法: $expected"
    requested="$(<"$VMISO/cpuset.cpus")" || _die "无法读回 cpuset.cpus"
    requested="$(_strict_cpu_list_to_csv "$requested")" \
        || _die "内核返回的 cpuset.cpus 非法"
    [[ "$requested" == "$expected_norm" ]] \
        || _die "cpuset.cpus 未达到请求值: expected=$expected_norm actual=$requested"

    online="$(< /sys/devices/system/cpu/online)" \
        || _die "无法读取在线 CPU 列表"
    expected_online="$(_strict_cpu_list_intersection_csv "$expected_norm" "$online")" \
        || _die "无法计算 requested/online CPU 交集"
    [[ -n "$expected_online" ]] || _die "期望 cpuset 没有在线 CPU"

    effective="$(<"$VMISO/cpuset.cpus.effective")" \
        || _die "无法读取 cpuset.cpus.effective"
    effective="$(_strict_cpu_list_to_csv "$effective")" \
        || _die "cpuset.cpus.effective 为空或非法"
    [[ "$effective" == "$expected_online" ]] \
        || _die "cpuset effective 不完整: expected=$expected_online actual=$effective"

    if [[ -e "$VMISO/cpuset.cpus.exclusive.effective" ]]; then
        [[ -r "$VMISO/cpuset.cpus.exclusive.effective" ]] \
            || _die "cpuset.cpus.exclusive.effective 不可读"
        exclusive="$(<"$VMISO/cpuset.cpus.exclusive.effective")" \
            || _die "无法读取 cpuset.cpus.exclusive.effective"
        exclusive="$(_strict_cpu_list_to_csv "$exclusive")" \
            || _die "cpuset.cpus.exclusive.effective 为空或非法"
        # 内核允许 exclusive.effective 保留 offline CPU；这正是热上线后仍维持独占
        # 边界所需的行为，因此这里核对完整 requested 集，而不是仅核对 online 交集。
        [[ "$exclusive" == "$expected_norm" ]] \
            || _die "cpuset exclusive 不完整: expected=$expected_norm actual=$exclusive"
    fi

    partition="$(<"$VMISO/cpuset.cpus.partition")" \
        || _die "无法读回 cpuset partition"
    [[ "$partition" == "root" ]] || _die "cpuset partition 未保持 root: $partition"
}

# apply 是跨 cgroup、affinity 与状态文件的事务。先以调用者身份 SIGSTOP，使已验证的
# 线程在敏感操作期间保持稳定；保存原 cgroup 和每线程 affinity，任一步失败即回滚。
_apply_transaction_begin() {
    local rel canonical status tid affinity state attempt

    [[ -x "$SETPRIV" && -x "$TASKSET" && -x "$KILL" ]] \
        || _die "缺少 setpriv/taskset/kill，无法建立降权事务"
    TARGET_CALLER_GID="$(_caller_gid)"
    APPLY_SUCCESS=0; APPLY_STOPPED=0; APPLY_MOVED=0
    APPLY_STATE_WRITTEN=0; APPLY_VMISO_TOUCHED=0; APPLY_VMISO_EXISTED=0
    APPLY_INSTANCE_CREATED=0
    APPLY_OLD_CPUS=""; APPLY_OLD_MEMS=""; APPLY_OLD_PARTITION=""
    declare -gA APPLY_AFFINITY=()

    if [[ -d "$VMISO" ]]; then
        APPLY_VMISO_EXISTED=1
        APPLY_OLD_CPUS="$(<"$VMISO/cpuset.cpus")" || _die "无法保存原 cpuset.cpus"
        APPLY_OLD_MEMS="$(<"$VMISO/cpuset.mems")" || _die "无法保存原 cpuset.mems"
        APPLY_OLD_PARTITION="$(<"$VMISO/cpuset.cpus.partition")" \
            || _die "无法保存原 partition 状态"
    fi
    rel="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$PID/cgroup")"
    [[ "$rel" == /* && "$rel" != *$'\n'* && "$rel" != *$'\r'* ]] \
        || _die "无法读取 QEMU 原 cgroup"
    canonical="$(realpath -e -- "$CG_ROOT$rel" 2>/dev/null)" \
        || _die "无法规范化 QEMU 原 cgroup"
    [[ "$canonical" == "$CG_ROOT" || "$canonical" == "$CG_ROOT/"* ]] \
        || _die "QEMU 原 cgroup 越出 cgroup2 根"
    APPLY_ORIGINAL_PROCS="$canonical/cgroup.procs"
    [[ -w "$APPLY_ORIGINAL_PROCS" ]] || _die "QEMU 原 cgroup 不可写"

    trap '_apply_transaction_exit $?' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    _run_as_caller "$KILL" -STOP "$PID" || _die "无法安全暂停 QEMU"
    APPLY_STOPPED=1
    state=""
    for ((attempt=0; attempt<100; attempt++)); do
        state="$(awk '/^State:/{print $2; exit}' "/proc/$PID/status" 2>/dev/null)"
        [[ "$state" == "T" || "$state" == "t" ]] && break
        sleep 0.01
    done
    [[ "$state" == "T" || "$state" == "t" ]] || _die "QEMU 未进入停止态"
    # PID/TIDS 是主 helper 在进入 apply 分支后设置的受校验全局变量。
    # shellcheck disable=SC2153
    _revalidate_qemu_target "$PID" "$TIDS"
    for status in /proc/"$PID"/task/*/status; do
        tid="${status%/status}"; tid="${tid##*/}"
        affinity="$(awk '/^Cpus_allowed_list:/{print $2; exit}' "$status")"
        [[ "$tid" =~ ^[0-9]+$ && "$affinity" =~ ^[0-9]+([,-][0-9]+)*$ ]] \
            || _die "无法保存 QEMU 线程 affinity"
        APPLY_AFFINITY[$tid]="$affinity"
    done
}

_apply_transaction_exit() {
    local status="$1" tid rollback_failed=0 current
    trap - EXIT HUP INT TERM
    set +e
    if (( APPLY_SUCCESS == 0 )); then
        # 先把目标移回原 cgroup；否则旧 affinity 可能不属于当前 cpuset。PID 已退出时
        # 内核会自动把线程移除，可继续恢复分区；PID 被复用则绝不操作新进程。
        if (( APPLY_MOVED )); then
            if _target_is_unchanged; then
                if printf '%s\n' "$PID" > "$APPLY_ORIGINAL_PROCS"; then
                    APPLY_MOVED=0
                else
                    _warn "回滚失败：无法把 pid=$PID 移回原 cgroup"
                    rollback_failed=1
                fi
            elif [[ ! -d "/proc/$PID" ]]; then
                APPLY_MOVED=0
            else
                _warn "回滚失败：pid=$PID 身份已变化，拒绝操作复用 PID"
                rollback_failed=1
            fi
        fi

        if _target_is_unchanged; then
            for tid in "${!APPLY_AFFINITY[@]}"; do
                [[ -d "/proc/$PID/task/$tid" ]] || continue
                if ! _run_as_caller "$TASKSET" -pc "${APPLY_AFFINITY[$tid]}" "$tid" \
                        >/dev/null 2>&1; then
                    _warn "回滚失败：无法恢复 tid=$tid affinity"
                    rollback_failed=1
                fi
            done
        fi

        # exact child 必须先拆除，父 partition 才能安全收回到事务前并集。
        # _instance_path 由 main 在 begin 前按已校验实例号确定。
        # shellcheck disable=SC2154
        if (( APPLY_INSTANCE_CREATED )); then
            if (( APPLY_MOVED )); then
                _warn "回滚失败：QEMU 仍在实例 child，拒绝删除"
                rollback_failed=1
            elif [[ -d "$_instance_path" ]]; then
                if "$RMDIR" "$_instance_path" 2>/dev/null; then
                    APPLY_INSTANCE_CREATED=0
                else
                    _warn "回滚失败：无法删除实例 child $_instance_path"
                    rollback_failed=1
                fi
            else
                APPLY_INSTANCE_CREATED=0
            fi
        fi

        if (( APPLY_VMISO_TOUCHED )); then
            if (( APPLY_MOVED || APPLY_INSTANCE_CREATED )); then
                _warn "回滚失败：实例仍依赖 vmiso，拒绝收缩父 cpuset"
                rollback_failed=1
            elif (( APPLY_VMISO_EXISTED )); then
                if ! printf '%s\n' "$APPLY_OLD_MEMS" > "$VMISO/cpuset.mems" ||
                   ! printf '%s\n' "$APPLY_OLD_CPUS" > "$VMISO/cpuset.cpus" ||
                   ! printf '%s\n' "$APPLY_OLD_PARTITION" > "$VMISO/cpuset.cpus.partition"; then
                    _warn "回滚失败：无法恢复 vmiso cpuset 快照"
                    rollback_failed=1
                else
                    current="$(<"$VMISO/cpuset.cpus.partition")"
                    if [[ "$current" != "$APPLY_OLD_PARTITION" ]]; then
                        _warn "回滚失败：vmiso partition 未恢复为 $APPLY_OLD_PARTITION"
                        rollback_failed=1
                    fi
                fi
            elif [[ -d "$VMISO" ]]; then
                if grep -qw cpuset "$VMISO/cgroup.subtree_control" 2>/dev/null \
                   && ! printf '%s\n' '-cpuset' > "$VMISO/cgroup.subtree_control" 2>/dev/null; then
                    _warn "回滚失败：无法停用父级 cpuset controller"
                    rollback_failed=1
                fi
                if ! printf 'member\n' > "$VMISO/cpuset.cpus.partition" 2>/dev/null ||
                   [[ "$(<"$VMISO/cpuset.cpus.partition")" != "member" ]] ||
                   ! "$RMDIR" "$VMISO" 2>/dev/null; then
                    _warn "回滚失败：无法拆除新建的 $VMISO"
                    rollback_failed=1
                fi
            fi
        fi

        # 实例登记是故障恢复凭据。只有 PID/cgroup/affinity/cpuset 全部恢复后才能删除；
        # 任一步失败都保留它，避免管理员失去当前分配与目标身份记录。
        # shellcheck disable=SC2154
        if (( APPLY_STATE_WRITTEN && rollback_failed == 0 )); then
            if ! rm -f -- "$_state_path"; then
                _warn "回滚失败：无法删除实例登记 $_state_path"
                rollback_failed=1
            fi
        fi
    fi

    if (( APPLY_STOPPED )) && _target_is_unchanged; then
        if (( rollback_failed == 0 )); then
            _run_as_caller "$KILL" -CONT "$PID" >/dev/null 2>&1 \
                || { _warn "无法恢复 pid=$PID，请人工发送 SIGCONT"; rollback_failed=1; }
        else
            _warn "事务回滚不完整，pid=$PID 保持暂停，避免在错误隔离状态下继续运行"
        fi
    fi
    (( status != 0 )) || (( APPLY_SUCCESS == 1 && rollback_failed == 0 )) || status=1
    exit "$status"
}

_host_numa_node_count() {
    local entry suffix count=0
    for entry in /sys/devices/system/node/node[0-9]*; do
        [[ -e "$entry" ]] || continue
        suffix="${entry##*/node}"
        [[ "$suffix" =~ ^[0-9]+$ ]] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}
_validate_memory_locality_tool() {
    local count
    count="$(_host_numa_node_count)"
    (( count <= 1 )) || [[ -x "$MIGRATEPAGES" && -x "$TIMEOUT" ]] \
        || _die "多 NUMA 严格模式缺少 $MIGRATEPAGES，无法迁移既有 QEMU 页面"
}
_count_host_free_physical_cores() {
    local allocated="$1" online cpu key blocked count=0 item
    local -A allocated_set=() core_seen=()
    while IFS= read -r cpu; do allocated_set[$cpu]=1; done \
        < <(_strict_cpu_list_to_lines "$allocated")
    online="$(< /sys/devices/system/cpu/online)" || return 1
    while IFS= read -r cpu; do
        key="$(_host_core_key "$cpu")" || return 1
        [[ -z "${core_seen[$key]:-}" ]] || continue
        core_seen[$key]=1; blocked=0
        while IFS= read -r item; do
            [[ -z "${allocated_set[$item]:-}" ]] || blocked=1
        done < <(_strict_cpu_list_to_lines "$key")
        (( blocked )) || count=$((count + 1))
    done < <(_strict_cpu_list_to_lines "$online")
    printf '%s\n' "$count"
}
