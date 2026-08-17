#!/usr/bin/env bash
# Product-scoped QEMU CPU isolation helper.
#
# The only production target is:
#   /sys/fs/cgroup/qemu-vm-isolation/vm<id>
#
# apply is intentionally strict because this script is suitable for a narrow
# sudoers NOPASSWD rule.  It accepts only numeric VM/PID/TID/CPU arguments,
# verifies every TID belongs to the named qemu-system-x86_64 process, and never
# mutates a cgroup outside the fixed product partition.
set -uo pipefail

TEST_MODE=${CPU_ISO_TEST_MODE:-0}
if [[ "$TEST_MODE" == 1 ]]; then
    CG_ROOT=${CPU_ISO_CGROUP_ROOT:?CPU_ISO_CGROUP_ROOT is required in test mode}
    PROC_ROOT=${CPU_ISO_PROC_ROOT:?CPU_ISO_PROC_ROOT is required in test mode}
    SYS_CPU_ROOT=${CPU_ISO_SYS_CPU_ROOT:?CPU_ISO_SYS_CPU_ROOT is required in test mode}
    LOCK_FILE=${CPU_ISO_LOCK_FILE:?CPU_ISO_LOCK_FILE is required in test mode}
    TASKSET_BIN=${CPU_ISO_TASKSET_BIN:-taskset}
else
    CG_ROOT=/sys/fs/cgroup
    PROC_ROOT=/proc
    SYS_CPU_ROOT=/sys/devices/system/cpu
    LOCK_FILE=/run/lock/qemu-cpu-isolation.lock
    TASKSET_BIN=taskset
fi
PARTITION="$CG_ROOT/qemu-vm-isolation"

warn() { echo "cpu-isolate: $*" >&2; }
die() { warn "$*"; exit 1; }
unsupported() { warn "$*"; exit 3; }

valid_vm_id() {
    [[ "$1" =~ ^[1-9][0-9]{0,18}$ ]]
}

cpu_list_lines() {
    local value=$1 part first last cpu
    local -a parts=()

    [[ "$value" =~ ^[0-9,-]+$ ]] || return 1
    IFS=, read -r -a parts <<<"$value"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            echo "$part"
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            first=${BASH_REMATCH[1]}
            last=${BASH_REMATCH[2]}
            (( first <= last && last - first <= 4096 )) || return 1
            for ((cpu=first; cpu<=last; cpu++)); do
                echo "$cpu"
            done
        else
            return 1
        fi
    done | sort -n -u
}

cpu_list_csv() {
    cpu_list_lines "$1" | paste -sd, -
}

csv_from_lines() {
    sort -n -u | paste -sd, -
}

test_populate_cgroup() {
    local dir=$1
    [[ "$TEST_MODE" == 1 ]] || return 0
    : >"$dir/cgroup.procs"
    : >"$dir/cgroup.subtree_control"
    : >"$dir/cpuset.cpus"
    : >"$dir/cpuset.cpus.effective"
    : >"$dir/cpuset.mems"
    : >"$dir/cpuset.mems.effective"
    printf 'member\n' >"$dir/cpuset.cpus.partition"
}

test_remove_cgroup_files() {
    local dir=$1
    [[ "$TEST_MODE" == 1 ]] || return 0
    rm -f -- "$dir/cgroup.procs" "$dir/cgroup.subtree_control" \
        "$dir/cpuset.cpus" "$dir/cpuset.cpus.effective" \
        "$dir/cpuset.mems" "$dir/cpuset.mems.effective" \
        "$dir/cpuset.cpus.partition"
}

cgroup_has_procs() {
    [[ -n "$(head -n 1 "$1/cgroup.procs" 2>/dev/null)" ]]
}

enable_cpuset() {
    local dir=$1
    if ! grep -qw cpuset "$dir/cgroup.subtree_control" 2>/dev/null; then
        printf '+cpuset\n' >"$dir/cgroup.subtree_control" 2>/dev/null ||
            return 1
        if [[ "$TEST_MODE" == 1 ]]; then
            printf 'cpuset\n' >"$dir/cgroup.subtree_control"
        fi
    fi
}

precheck() {
    if [[ "$TEST_MODE" != 1 ]] &&
            [[ "$(stat -fc %T "$CG_ROOT" 2>/dev/null)" != cgroup2fs ]]; then
        unsupported "cgroup v2 不可用，跳过 CPU 隔离"
    fi
    [[ -r "$CG_ROOT/cgroup.controllers" ]] ||
        unsupported "无法读取 cgroup v2 controllers"
    grep -qw cpuset "$CG_ROOT/cgroup.controllers" ||
        unsupported "cgroup v2 cpuset controller 不可用"
    # cpuset.cpus.partition exists only on non-root cgroups; the cgroup v2
    # root is implicitly a partition root and deliberately has no such file.
    # The newly created product child is checked when "root" is written.
    [[ -n "$(cat "$CG_ROOT/cpuset.cpus.effective" 2>/dev/null)" ]] ||
        unsupported "root cpuset.cpus.effective 为空"
    [[ -n "$(cat "$CG_ROOT/cpuset.mems.effective" 2>/dev/null)" ]] ||
        unsupported "root cpuset.mems.effective 为空"
    command -v "$TASKSET_BIN" >/dev/null 2>&1 ||
        unsupported "缺少 taskset"
    enable_cpuset "$CG_ROOT" ||
        unsupported "无法在 root cgroup 启用 cpuset controller"
}

verify_qemu_process() {
    local vm_id=$1 pid=$2 exe arg expect_name=0 found_name=0

    [[ "$pid" =~ ^[1-9][0-9]*$ && -d "$PROC_ROOT/$pid/task" ]] ||
        die "QEMU pid 不存在: $pid"
    exe=$(readlink -f "$PROC_ROOT/$pid/exe" 2>/dev/null || true)
    [[ "${exe##*/}" == qemu-system-x86_64 ]] ||
        die "pid=$pid 不是 qemu-system-x86_64"
    while IFS= read -r arg; do
        if (( expect_name )); then
            [[ "$arg" == "vm${vm_id}" || "$arg" == "vm${vm_id},"* ]] &&
                found_name=1
            expect_name=0
        elif [[ "$arg" == -name ]]; then
            expect_name=1
        fi
    done < <(tr '\0' '\n' <"$PROC_ROOT/$pid/cmdline")
    (( found_name )) || die "pid=$pid 的 -name 与 vm${vm_id} 不匹配"
}

process_starttime() {
    local pid=$1 stat_line tail
    local -a fields=()

    [[ -r "$PROC_ROOT/$pid/stat" ]] || return 1
    IFS= read -r stat_line <"$PROC_ROOT/$pid/stat" || return 1
    [[ "$stat_line" == *") "* ]] || return 1
    # Everything after the final ") " starts at proc stat field 3.  The comm
    # field itself may contain spaces or parentheses, so a plain awk field
    # split is not generation-safe.
    tail=${stat_line##*) }
    read -r -a fields <<<"$tail"
    ((${#fields[@]} >= 20)) || return 1
    [[ "${fields[0]}" != Z && "${fields[0]}" != X &&
       "${fields[19]}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

verify_launcher_process() {
    local vm_id=$1 pid=$2 expected_start=$3 actual_start uid_line real_uid
    local arg previous="" found=0

    [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_start" =~ ^[1-9][0-9]*$ ]] ||
        die "OOM 保护的 pid/starttime 非法"
    actual_start=$(process_starttime "$pid") ||
        die "无法核验启动器 pid=$pid 的进程代际"
    [[ "$actual_start" == "$expected_start" ]] ||
        die "启动器 pid=$pid 已换代，拒绝修改 OOM 分数"

    if [[ "$TEST_MODE" != 1 ]]; then
        uid_line=$(awk '/^Uid:/{print $2; exit}' "$PROC_ROOT/$pid/status" 2>/dev/null)
        [[ "$uid_line" =~ ^[0-9]+$ ]] || die "无法确认启动器 UID"
        if [[ -n "${SUDO_UID:-}" ]]; then
            real_uid=$SUDO_UID
        else
            real_uid=$EUID
        fi
        [[ "$real_uid" =~ ^[0-9]+$ && "$uid_line" == "$real_uid" ]] ||
            die "只能保护当前调用用户的启动器"
    fi

    while IFS= read -r arg; do
        if [[ "${previous##*/}" == start-vm.sh && "$arg" == "$vm_id" ]]; then
            found=1
            break
        fi
        previous=$arg
    done < <(tr '\0' '\n' <"$PROC_ROOT/$pid/cmdline")
    ((found)) || die "pid=$pid 不是 vm${vm_id} 的 start-vm.sh 启动器"
}

protect_launcher_oom() {
    local vm_id=$1 pid=$2 expected_start=$3 score_path current target=-500

    valid_vm_id "$vm_id" || die "VM id 非法"
    verify_launcher_process "$vm_id" "$pid" "$expected_start"
    score_path="$PROC_ROOT/$pid/oom_score_adj"
    [[ -f "$score_path" && ! -L "$score_path" ]] ||
        die "启动器 oom_score_adj 不可用"
    IFS= read -r current <"$score_path" || die "无法读取 oom_score_adj"
    [[ "$current" =~ ^-?[0-9]+$ && "$current" -ge -1000 &&
       "$current" -le 1000 ]] || die "oom_score_adj 当前值非法"
    # Never weaken a stronger policy inherited from a trusted parent.
    if ((current < target)); then
        target=$current
    fi
    printf '%s\n' "$target" >"$score_path" || die "无法写入 oom_score_adj"
    [[ "$(cat "$score_path" 2>/dev/null)" == "$target" ]] ||
        die "oom_score_adj 写入后复核失败"
    printf 'host-oom-protect: policy=oom-score-v1 score=%s pid=%s\n' \
        "$target" "$pid"
}

verify_vcpu_tids() {
    local pid=$1 tids_csv=$2 tid tgid
    local -A seen=()
    local -a tids=()

    [[ "$tids_csv" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] ||
        die "vCPU TID 列表非法"
    IFS=, read -r -a tids <<<"$tids_csv"
    ((${#tids[@]} > 0 && ${#tids[@]} <= 256)) ||
        die "vCPU TID 数量非法"
    for tid in "${tids[@]}"; do
        [[ -z "${seen[$tid]:-}" ]] || die "重复 vCPU TID: $tid"
        seen[$tid]=1
        [[ -r "$PROC_ROOT/$pid/task/$tid/status" ]] ||
            die "vCPU TID 不属于 pid=$pid: $tid"
        tgid=$(awk '/^Tgid:/{print $2; exit}' \
            "$PROC_ROOT/$pid/task/$tid/status" 2>/dev/null)
        [[ "$tgid" == "$pid" ]] ||
            die "vCPU TID=$tid 的 Tgid=$tgid，不属于 pid=$pid"
    done
}

original_cgroup_dir() {
    local pid=$1 rel
    rel=$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' \
        "$PROC_ROOT/$pid/cgroup" 2>/dev/null)
    [[ "$rel" == /* && "$rel" != *..* ]] || return 1
    printf '%s%s\n' "$CG_ROOT" "$rel"
}

mems_for_cpus() {
    local cpus=$1 cpu node path
    local -a nodes=()

    while read -r cpu; do
        for path in "$SYS_CPU_ROOT/cpu${cpu}"/node[0-9]*; do
            [[ -e "$path" ]] || continue
            node=${path##*/node}
            [[ "$node" =~ ^[0-9]+$ ]] && nodes+=("$node")
        done
    done < <(cpu_list_lines "$cpus")
    if ((${#nodes[@]})); then
        printf '%s\n' "${nodes[@]}" | csv_from_lines
    else
        # Architectures without cpuN/nodeN links use the host's effective
        # memory nodes.  Never guess or hard-code node 0.
        cat "$CG_ROOT/cpuset.mems.effective"
    fi
}

remove_empty_vm_cgroup() {
    local dir=$1
    [[ -d "$dir" ]] || return 0
    ! cgroup_has_procs "$dir" || return 1
    test_remove_cgroup_files "$dir"
    rmdir -- "$dir" 2>/dev/null
}

shrink_or_remove_partition() {
    local dir cpus
    local -a held=()

    [[ -d "$PARTITION" ]] || return 0
    for dir in "$PARTITION"/vm[1-9]*; do
        [[ -d "$dir" ]] || continue
        if cgroup_has_procs "$dir"; then
            cpus=$(cat "$dir/cpuset.cpus" 2>/dev/null || true)
            [[ -n "$cpus" ]] && held+=("$cpus")
        else
            remove_empty_vm_cgroup "$dir" || true
        fi
    done
    if ((${#held[@]})); then
        cpus=$(printf '%s\n' "${held[@]}" |
            while read -r value; do cpu_list_lines "$value"; done |
            csv_from_lines)
        printf '%s\n' "$cpus" >"$PARTITION/cpuset.cpus"
        [[ "$TEST_MODE" != 1 ]] ||
            printf '%s\n' "$cpus" >"$PARTITION/cpuset.cpus.effective"
        return 0
    fi
    printf 'member\n' >"$PARTITION/cpuset.cpus.partition" 2>/dev/null || true
    test_remove_cgroup_files "$PARTITION"
    rmdir -- "$PARTITION" 2>/dev/null || true
}

apply_isolation() {
    local vm_id=$1 pid=$2 pref_csv=$3 tids_csv=$4 service_count=$5
    local vm_cgroup="$PARTITION/vm${vm_id}"
    local root_cpus root_cpu original_dir parent_existed=0
    local old_parent_cpus="" old_parent_mems="" old_partition="member"
    local cpu tid task tgid selected_csv vcpu_csv service_csv all_cpus mems all_mems
    local required_count original_affinity failure=""
    local -a pref=() tids=() selected=() vcpu_cpus=() service_cpus=()
    local -a held_lines=() all_task_ids=()
    local -A available=() held=() vcpu_tid=() old_affinity=()

    valid_vm_id "$vm_id" || die "VM id 非法"
    [[ "$service_count" =~ ^[0-9]+$ && "$service_count" -le 64 ]] ||
        die "service CPU 数量非法"
    [[ "$pref_csv" =~ ^[0-9]+(,[0-9]+)*$ && ${#pref_csv} -le 16384 ]] ||
        die "CPU 偏好列表非法"
    verify_qemu_process "$vm_id" "$pid"
    verify_vcpu_tids "$pid" "$tids_csv"
    precheck

    original_dir=$(original_cgroup_dir "$pid") ||
        die "无法确定 pid=$pid 的原 cgroup，拒绝不可回滚操作"
    [[ "$original_dir" == "$CG_ROOT" || "$original_dir" == "$CG_ROOT/"* ]] ||
        die "原 cgroup 越界"
    [[ -w "$original_dir/cgroup.procs" ]] ||
        die "原 cgroup 不可写，拒绝不可回滚操作"

    exec 9>"$LOCK_FILE" || die "无法打开 CPU 隔离锁"
    flock -w 15 9 || die "CPU 隔离锁超时"

    root_cpus=$(cat "$CG_ROOT/cpuset.cpus.effective")
    while read -r root_cpu; do available[$root_cpu]=1; done \
        < <(cpu_list_lines "$root_cpus")

    if [[ -d "$vm_cgroup" ]]; then
        ! cgroup_has_procs "$vm_cgroup" ||
            die "vm${vm_id} CPU cgroup 已有活动进程"
        remove_empty_vm_cgroup "$vm_cgroup" ||
            die "无法清理 vm${vm_id} 的空 cgroup"
    fi

    if [[ -d "$PARTITION" ]]; then
        parent_existed=1
        old_parent_cpus=$(cat "$PARTITION/cpuset.cpus" 2>/dev/null || true)
        old_parent_mems=$(cat "$PARTITION/cpuset.mems" 2>/dev/null || true)
        old_partition=$(cat "$PARTITION/cpuset.cpus.partition" 2>/dev/null ||
            echo member)
        for task in "$PARTITION"/vm[1-9]*; do
            [[ -d "$task" ]] && cgroup_has_procs "$task" || continue
            while read -r cpu; do held[$cpu]=1; held_lines+=("$cpu"); done \
                < <(cpu_list_lines "$(cat "$task/cpuset.cpus")")
        done
    fi

    IFS=, read -r -a tids <<<"$tids_csv"
    IFS=, read -r -a pref <<<"$pref_csv"
    required_count=$((${#tids[@]} + service_count))
    for cpu in "${pref[@]}"; do
        ((${#selected[@]} < required_count)) || break
        [[ -n "${available[$cpu]:-}" && -z "${held[$cpu]:-}" ]] || continue
        selected+=("$cpu")
        held[$cpu]=1
    done
    ((${#selected[@]} == required_count)) ||
        die "可用隔离 CPU 不足：需要 $required_count，得到 ${#selected[@]}"

    vcpu_cpus=("${selected[@]:0:${#tids[@]}}")
    if ((service_count)); then
        service_cpus=("${selected[@]:${#tids[@]}:service_count}")
    fi
    selected_csv=$(printf '%s\n' "${selected[@]}" | csv_from_lines)
    vcpu_csv=$(printf '%s\n' "${vcpu_cpus[@]}" | paste -sd, -)
    service_csv=$(printf '%s\n' "${service_cpus[@]}" | paste -sd, -)
    all_cpus=$(printf '%s\n' "${held_lines[@]}" "${selected[@]}" |
        sed '/^$/d' | csv_from_lines)

    # Keep at least one logical CPU outside the product partition.
    if [[ "$(cpu_list_csv "$root_cpus")" == "$(cpu_list_csv "$all_cpus")" ]]; then
        die "CPU 隔离会占用全部宿主 CPU，已拒绝"
    fi
    mems=$(mems_for_cpus "$selected_csv")
    [[ -n "$mems" ]] || die "无法从所选 CPU 推导 cpuset.mems"
    all_mems=$mems
    if [[ -n "$old_parent_mems" ]]; then
        all_mems=$(
            {
                cpu_list_lines "$old_parent_mems"
                cpu_list_lines "$mems"
            } | csv_from_lines
        )
    fi

    if [[ ! -d "$PARTITION" ]]; then
        mkdir -- "$PARTITION" || die "无法创建产品 CPU 分区"
        test_populate_cgroup "$PARTITION"
    fi
    printf '%s\n' "$all_mems" >"$PARTITION/cpuset.mems" || failure="写父 cpuset.mems 失败"
    [[ -n "$failure" ]] ||
        printf '%s\n' "$all_cpus" >"$PARTITION/cpuset.cpus" ||
        failure="写父 cpuset.cpus 失败"
    if [[ "$TEST_MODE" == 1 && -z "$failure" ]]; then
        printf '%s\n' "$all_mems" >"$PARTITION/cpuset.mems.effective"
        printf '%s\n' "$all_cpus" >"$PARTITION/cpuset.cpus.effective"
    fi
    [[ -n "$failure" ]] || enable_cpuset "$PARTITION" ||
        failure="无法在产品分区启用 cpuset"
    [[ -n "$failure" ]] ||
        printf 'root\n' >"$PARTITION/cpuset.cpus.partition" ||
        failure="无法启用独占 partition root"
    if [[ -z "$failure" &&
          "$(cat "$PARTITION/cpuset.cpus.partition" 2>/dev/null)" != root ]]; then
        failure="cpuset partition root 未生效"
    fi
    if [[ -z "$failure" ]]; then
        mkdir -- "$vm_cgroup" || failure="无法创建 vm${vm_id} 子 cgroup"
    fi
    if [[ -z "$failure" ]]; then
        test_populate_cgroup "$vm_cgroup"
        printf '%s\n' "$mems" >"$vm_cgroup/cpuset.mems" &&
            printf '%s\n' "$selected_csv" >"$vm_cgroup/cpuset.cpus" ||
            failure="写 vm${vm_id} cpuset 失败"
        if [[ "$TEST_MODE" == 1 ]]; then
            printf '%s\n' "$mems" >"$vm_cgroup/cpuset.mems.effective"
            printf '%s\n' "$selected_csv" >"$vm_cgroup/cpuset.cpus.effective"
        fi
    fi

    mapfile -t all_task_ids < <(
        for task in "$PROC_ROOT/$pid"/task/[0-9]*; do
            [[ -d "$task" ]] && echo "${task##*/}"
        done | sort -n
    )
    for tid in "${all_task_ids[@]}"; do
        original_affinity=$(awk '/^Cpus_allowed_list:/{print $2; exit}' \
            "$PROC_ROOT/$pid/task/$tid/status" 2>/dev/null)
        [[ -n "$original_affinity" ]] && old_affinity[$tid]=$original_affinity
    done

    [[ -n "$failure" ]] ||
        printf '%s\n' "$pid" >"$vm_cgroup/cgroup.procs" ||
        failure="无法移动 QEMU 到 vm${vm_id} cgroup"
    for tid in "${tids[@]}"; do vcpu_tid[$tid]=1; done
    if [[ -z "$failure" ]]; then
        for cpu in "${!tids[@]}"; do
            "$TASKSET_BIN" -pc "${vcpu_cpus[$cpu]}" "${tids[$cpu]}" \
                >/dev/null 2>&1 ||
                { failure="vCPU TID=${tids[$cpu]} 绑核失败"; break; }
        done
    fi
    if [[ -z "$failure" && -n "$service_csv" ]]; then
        for tid in "${all_task_ids[@]}"; do
            [[ -n "${vcpu_tid[$tid]:-}" ]] && continue
            "$TASKSET_BIN" -pc "$service_csv" "$tid" >/dev/null 2>&1 ||
                { failure="service TID=$tid 绑核失败"; break; }
        done
    fi

    if [[ -n "$failure" ]]; then
        warn "$failure；回滚本次 CPU 隔离"
        printf '%s\n' "$pid" >"$original_dir/cgroup.procs" 2>/dev/null || true
        if [[ "$TEST_MODE" == 1 ]]; then : >"$vm_cgroup/cgroup.procs" 2>/dev/null || true; fi
        for tid in "${!old_affinity[@]}"; do
            "$TASKSET_BIN" -pc "${old_affinity[$tid]}" "$tid" >/dev/null 2>&1 ||
                true
        done
        remove_empty_vm_cgroup "$vm_cgroup" || true
        if ((parent_existed)); then
            printf '%s\n' "$old_parent_mems" >"$PARTITION/cpuset.mems" 2>/dev/null ||
                true
            printf '%s\n' "$old_parent_cpus" >"$PARTITION/cpuset.cpus" 2>/dev/null ||
                true
            printf '%s\n' "$old_partition" >"$PARTITION/cpuset.cpus.partition" \
                2>/dev/null || true
        else
            shrink_or_remove_partition
        fi
        return 1
    fi

    echo "cpu-isolate: vm${vm_id} applied: vcpu=${vcpu_csv} service=${service_csv:-none} mems=${mems}"
}

release_isolation() {
    local vm_id=$1 vm_cgroup
    valid_vm_id "$vm_id" || die "VM id 非法"
    vm_cgroup="$PARTITION/vm${vm_id}"

    [[ -d "$PARTITION" ]] || return 0
    exec 9>"$LOCK_FILE" || die "无法打开 CPU 隔离锁"
    flock -w 15 9 || die "CPU 隔离锁超时"
    [[ -d "$vm_cgroup" ]] || { shrink_or_remove_partition; return 0; }
    ! cgroup_has_procs "$vm_cgroup" ||
        die "vm${vm_id} cgroup 仍有活动进程，拒绝释放"
    remove_empty_vm_cgroup "$vm_cgroup" ||
        die "无法删除 vm${vm_id} CPU cgroup"
    shrink_or_remove_partition
    echo "cpu-isolate: vm${vm_id} released"
}

status_isolation() {
    local vm_id=${1:-} dir
    if [[ -n "$vm_id" ]]; then
        valid_vm_id "$vm_id" || die "VM id 非法"
        dir="$PARTITION/vm${vm_id}"
    else
        dir="$PARTITION"
    fi
    [[ -d "$dir" ]] || { echo "cpu-isolate: inactive"; return 0; }
    echo "cpu-isolate: $dir"
    echo "  cpus=$(cat "$dir/cpuset.cpus" 2>/dev/null)"
    echo "  mems=$(cat "$dir/cpuset.mems" 2>/dev/null)"
    echo "  partition=$(cat "$dir/cpuset.cpus.partition" 2>/dev/null)"
    echo "  procs=$(tr '\n' ',' <"$dir/cgroup.procs" 2>/dev/null | sed 's/,$//')"
}

cmd=${1:-}
shift || true

if [[ "$cmd" != status && "$EUID" -ne 0 && "$TEST_MODE" != 1 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        sudo -n -- "$0" "$cmd" "$@"
        rc=$?
        ((rc == 0)) && exit 0
        warn "需要 root；sudo -n 不可用或 helper 失败"
        exit "$rc"
    fi
    unsupported "需要 root，且系统没有 sudo"
fi

case "$cmd" in
    apply)
        (($# == 5)) || die "用法: apply <vm_id> <pid> <cpu_pref> <vcpu_tids> <service_count>"
        apply_isolation "$@"
        ;;
    release)
        (($# == 1)) || die "用法: release <vm_id>"
        release_isolation "$1"
        ;;
    oom-protect)
        (($# == 3)) || die "用法: oom-protect <vm_id> <launcher_pid> <starttime>"
        protect_launcher_oom "$@"
        ;;
    status)
        (($# <= 1)) || die "用法: status [vm_id]"
        status_isolation "${1:-}"
        ;;
    *)
        die "用法: $0 apply|release|oom-protect|status ..."
        ;;
esac
