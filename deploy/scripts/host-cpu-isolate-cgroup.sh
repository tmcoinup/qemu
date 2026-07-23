#!/bin/bash
# shellcheck shell=bash
# ABI5：每台 QEMU 使用 1:1 logical exact child，并保持单 NUMA/package 域。
# shellcheck disable=SC2034
readonly VMATE_CPU_ISOLATE_CGROUP_ABI="5"
readonly VMISO_CHILD_PREFIX="vm-"
_instance_cgroup_path() {
    local instance="$1"
    [[ "$instance" =~ ^[1-9][0-9]{0,9}$ ]] || _die "instance 非法: $instance"
    printf '%s/%s%s\n' "$VMISO" "$VMISO_CHILD_PREFIX" "$instance"
}
_validate_instance_cgroup() {
    local path="$1" metadata uid gid mode name
    name="${path##*/}"
    [[ "$name" =~ ^${VMISO_CHILD_PREFIX}[1-9][0-9]{0,9}$ ]] || _die "实例 cgroup 名称非法: $name"
    [[ -d "$path" && ! -L "$path" ]] || _die "实例 cgroup 不是普通目录: $path"
    metadata="$(stat -Lc '%u %g %a' -- "$path" 2>/dev/null)" || _die "无法读取实例 cgroup 元数据: $path"
    read -r uid gid mode <<< "$metadata"
    [[ "$uid" == "0" && "$gid" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || _die "实例 cgroup owner/mode 非法: $path ($uid:$gid:$mode)"
    (( (8#$mode & 8#022) == 0 )) || _die "实例 cgroup 不得由 group/other 写入: $path"
}
# 枚举含隐藏项的直接 child；目录、symlink 和 vm-* 命名空间严格 fail-closed。
_scan_vmiso_children() {
    local entry name nullglob_was_set=0 dotglob_was_set=0
    local -a entries=()
    declare -ga ISO_CHILD_PATHS=()
    shopt -q nullglob && nullglob_was_set=1
    shopt -q dotglob && dotglob_was_set=1
    shopt -s nullglob dotglob
    entries=("$VMISO"/*)
    (( nullglob_was_set )) || shopt -u nullglob
    (( dotglob_was_set )) || shopt -u dotglob
    for entry in "${entries[@]}"; do
        name="${entry##*/}"
        [[ ! -L "$entry" ]] || _die "vmiso 不得包含 symlink: $name"
        if [[ -d "$entry" ]]; then
            [[ "$name" =~ ^${VMISO_CHILD_PREFIX}[1-9][0-9]{0,9}$ ]] || _die "实例 cgroup 名称非法: $name"
            ISO_CHILD_PATHS+=("$entry")
        elif [[ "$name" == "$VMISO_CHILD_PREFIX"* ]]; then
            _die "实例 cgroup 命名空间被非目录占用: $name"
        fi
    done
}
_cpu_is_online() {
    local cpu="$1" online_file
    online_file="/sys/devices/system/cpu/cpu${cpu}/online"
    [[ -d "/sys/devices/system/cpu/cpu${cpu}" ]] || return 1
    [[ ! -r "$online_file" || "$(<"$online_file")" == "1" ]]
}
_cpu_package() {
    local cpu="$1" value path
    path="/sys/devices/system/cpu/cpu${cpu}/topology/physical_package_id"; [[ -r "$path" ]] || _die "CPU $cpu 缺少 package 拓扑"
    value="$(<"$path")" || _die "无法读取 CPU $cpu 的 package"
    [[ "$value" =~ ^[0-9]+$ ]] || _die "CPU $cpu 的 package 非法: $value"
    printf '%s\n' "$value"
}
_cpu_numa_node() {
    local cpu="$1" entry suffix found=""
    local -a matches=()
    for entry in /sys/devices/system/cpu/cpu"$cpu"/node[0-9]*; do
        [[ -e "$entry" ]] || continue
        suffix="${entry##*/node}"
        [[ "$suffix" =~ ^[0-9]+$ ]] && matches+=("$suffix")
    done
    if (( ${#matches[@]} == 0 )); then
        for entry in /sys/devices/system/node/node[0-9]*; do
            [[ -e "$entry/cpu$cpu" ]] || continue
            suffix="${entry##*/node}"
            [[ "$suffix" =~ ^[0-9]+$ ]] && matches+=("$suffix")
        done
    fi
    if (( ${#matches[@]} == 1 )); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    if (( ${#matches[@]} > 1 )); then
        _die "CPU $cpu 同时属于多个 NUMA node"
    fi
    for entry in /sys/devices/system/node/node[0-9]*; do
        [[ -e "$entry" ]] || continue
        suffix="${entry##*/node}"
        [[ "$suffix" =~ ^[0-9]+$ ]] && found="${found:+$found,}$suffix"
    done
    [[ "$found" == "0" || -z "$found" ]] \
        || _die "多 NUMA 主机无法确定 CPU $cpu 的节点"
    printf '0\n'
}
_host_core_key() {
    local cpu="$1" siblings key
    siblings="$(<"/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list")" \
        || _die "CPU $cpu 缺少 SMT 拓扑"
    key="$(_strict_cpu_list_to_csv "$siblings")" \
        || _die "CPU $cpu 的 SMT 拓扑非法: $siblings"
    case ",$key," in
        *",$cpu,"*) printf '%s\n' "$key" ;;
        *) _die "CPU $cpu 的 SMT 拓扑不包含自身" ;;
    esac
}
_validate_smt2_core() {
    local key="$1" require_online="${2:-0}" cpu; local -a siblings=()
    mapfile -t siblings < <(_strict_cpu_list_to_lines "$key")
    (( ${#siblings[@]} == 2 )) || _die "host 物理核必须精确为 SMT2: $key"
    (( require_online == 0 )) && return 0
    for cpu in "${siblings[@]}"; do
        _cpu_is_online "$cpu" || _die "host SMT2 同胞 CPU $cpu 已 offline"
    done
}
_validate_host_locality_visibility() {
    local entry suffix cpu package node_count=0 package_count=0
    local -A packages=()
    for entry in /sys/devices/system/node/node[0-9]*; do
        [[ -e "$entry" ]] || continue
        suffix="${entry##*/node}"
        [[ "$suffix" =~ ^[0-9]+$ ]] && node_count=$((node_count + 1))
    done
    while IFS= read -r cpu; do
        package="$(_cpu_package "$cpu")"; packages[$package]=1
    done < <(_strict_cpu_list_to_lines "$(< /sys/devices/system/cpu/online)")
    package_count=${#packages[@]}
    (( package_count <= 1 || node_count > 1 )) || _die \
        "检测到多 socket 但内核只暴露一个 NUMA node；严格模式无法证明内存本地性"
}
# 扫描 exact child 重建资源并集；父级直属进程代表不可在线升级的旧 ABI。
_collect_instance_allocations() {
    local verify_parent="${1:-1}" direct child name instance cpus mems cpu node
    local state_path parent_cpus parent_mems; local -a preparing_children=()
    declare -gA ISO_HELD=()
    declare -g ISO_CHILD_COUNT=0 ISO_PARENT_CPUS="" ISO_PARENT_MEMS=""
    [[ -d "$VMISO" ]] || return 0
    _validate_vmiso_dir
    if [[ -r "$VMISO/cgroup.procs" ]]; then
        while IFS= read -r direct; do
            [[ -z "$direct" ]] || _die \
                "检测到旧 ABI 的父级直属进程 pid=$direct；请先安全关闭旧 VM 再升级"
        done < "$VMISO/cgroup.procs"
    fi
    _scan_vmiso_children
    for child in "${ISO_CHILD_PATHS[@]}"; do
        _validate_instance_cgroup "$child"
        name="${child##*/}"; instance="${name#"${VMISO_CHILD_PREFIX}"}"
        cpus="$(<"$child/cpuset.cpus")" || _die "无法读取 $name cpuset.cpus"
        cpus="$(_strict_cpu_list_to_csv "$cpus")" || _die "$name cpuset.cpus 非法"
        mems="$(<"$child/cpuset.mems")" || _die "无法读取 $name cpuset.mems"
        mems="$(_strict_cpu_list_to_csv "$mems")" || _die "$name cpuset.mems 非法"
        state_path="$(_instance_state_path "$instance")"
        [[ -e "$state_path" && ! -L "$state_path" ]] \
            || _die "$name 缺少可信实例登记"
        _read_instance_state "$state_path"
        [[ "$STATE_INSTANCE" == "$instance" && "$STATE_CPUS" == "$cpus" ]] \
            || _die "$name 与实例登记不一致"
        _validate_recorded_topology "$STATE_VCPU_CPUS" "$STATE_GUEST_TPC" \
            "$STATE_HOST_TPC" "$STATE_SERVICE_CPUS" "$STATE_DOMAIN" "$STATE_CPUS"
        if [[ "$STATE_PHASE" == "active" ]]; then
            [[ "$STATE_MEMS" == "$mems" ]] || _die "$name 的 NUMA 登记不一致"
            (( verify_parent == 0 )) || _verify_instance_cpu_grant "$cpus" "$STATE_MEMS" "$child"
        else
            case ",$mems," in
                *",$STATE_MEMS,"*) ;;
                *) _die "$name preparing NUMA 集合不包含目标 node" ;;
            esac
            [[ "$STATE_PHASE" != "preparing" ]] || preparing_children+=("$child")
            [[ "$STATE_PHASE" != "releasing" || "$verify_parent" == "0" ]] \
                || _verify_instance_cpu_grant "$cpus" "$mems" "$child"
        fi
        while IFS= read -r cpu; do
            [[ -z "${ISO_HELD[$cpu]:-}" ]] || _die "实例 cpuset 重叠: CPU $cpu"
            ISO_HELD[$cpu]=1
        done < <(_strict_cpu_list_to_lines "$cpus")
        while IFS= read -r node; do
            ISO_PARENT_MEMS="${ISO_PARENT_MEMS:+$ISO_PARENT_MEMS,}$node"
        done < <(_strict_cpu_list_to_lines "$mems")
        ISO_CHILD_COUNT=$((ISO_CHILD_COUNT + 1))
    done
    ISO_PARENT_CPUS="$(for cpu in "${!ISO_HELD[@]}"; do printf '%s\n' "$cpu"; done \
        | sort -n -u | paste -sd, -)"
    [[ -z "$ISO_PARENT_MEMS" ]] || ISO_PARENT_MEMS="$(_strict_cpu_list_to_csv "$ISO_PARENT_MEMS")"
    if (( verify_parent && ISO_CHILD_COUNT > 0 )); then
        for child in "${preparing_children[@]}"; do
            cpus="$(_strict_cpu_list_to_csv "$(<"$child/cpuset.cpus")")"; _verify_instance_cpu_grant "$cpus" "$ISO_PARENT_MEMS" "$child"
        done
        parent_cpus="$(<"$VMISO/cpuset.cpus")" || _die "无法读取父 cpuset.cpus"
        parent_mems="$(<"$VMISO/cpuset.mems")" || _die "无法读取父 cpuset.mems"
        parent_cpus="$(_strict_cpu_list_to_csv "$parent_cpus")" || _die "父 cpuset.cpus 非法"
        parent_mems="$(_strict_cpu_list_to_csv "$parent_mems")" || _die "父 cpuset.mems 非法"
        [[ "$parent_cpus" == "$ISO_PARENT_CPUS" && "$parent_mems" == "$ISO_PARENT_MEMS" ]] \
            || _die "父 cpuset 与实例并集不一致，拒绝继续分配"
        _verify_vmiso_cpu_grant "$ISO_PARENT_CPUS"
        _verify_parent_memory_grant "$ISO_PARENT_MEMS"
    fi
}
# PREF 按 host threads-per-core 分组；TPC1 允许同核 sibling 作为并发后备候选。
_select_instance_cpus() {
    local pref="$1" mem_order="$2" vcpu_count="$3" service="$4" guest_tpc="$5"
    local host_tpc="$6"
    local need start offset cpu first key core_key node package domain group_ok selected_domain="" selected_node=""
    local full_left remainder pass count candidate_domain sibling all_online
    local -a pref_cpus=() ordered_nodes=() domains=() available=() vcpu_selected=() service_selected=() service_cores=() core_free=()
    local -A candidate_seen=() domain_seen=() domain_cpus=() domain_node=()
    local -A chosen_core=() service_core_seen=() service_by_core=()
    _validate_topology_policy "$vcpu_count" "$guest_tpc" "$host_tpc"; _validate_host_locality_visibility
    (( guest_tpc >= 1 && host_tpc >= 1 && vcpu_count >= 1 &&
       vcpu_count % guest_tpc == 0 && vcpu_count % host_tpc == 0 )) \
        || _die "来宾 core/thread 拓扑非法"
    need=$((vcpu_count + service)); IFS=',' read -ra pref_cpus <<< "$pref"
    mapfile -t ordered_nodes < <(_strict_cpu_list_to_lines "$mem_order")
    (( ${#pref_cpus[@]} >= need && ${#pref_cpus[@]} % host_tpc == 0 )) \
        || _die "CPU 候选不能按宿主 packing threads-per-core 完整分组"
    for ((start=0; start<${#pref_cpus[@]}; start+=host_tpc)); do
        first="${pref_cpus[$start]}"
        [[ "$first" =~ ^[0-9]+$ && -z "${candidate_seen[$first]:-}" ]] \
            || _die "CPU 候选重复或非法: $first"
        key="$(_host_core_key "$first")"; node="$(_cpu_numa_node "$first")"
        _validate_smt2_core "$key" 0
        package="$(_cpu_package "$first")"; domain="$node:$package"; group_ok=1
        for ((offset=0; offset<host_tpc; offset++)); do
            cpu="${pref_cpus[$((start + offset))]}"
            [[ "$cpu" =~ ^[0-9]+$ && -z "${candidate_seen[$cpu]:-}" ]] \
                || _die "CPU 候选重复或非法: $cpu"
            candidate_seen[$cpu]=1
            core_key="$(_host_core_key "$cpu")"
            [[ "$core_key" == "$key" && "$(_cpu_numa_node "$cpu"):$(_cpu_package "$cpu")" == "$domain" ]] \
                || _die "来宾同一核心的候选跨 host 物理核或 locality domain"
            [[ -z "${ISO_HELD[$cpu]:-}" ]] || group_ok=0
            _cpu_is_online "$cpu" || group_ok=0
        done
        (( group_ok )) || continue
        if [[ -z "${domain_seen[$domain]:-}" ]]; then domain_seen[$domain]=1; domains+=("$domain"); domain_node[$domain]="$node"; fi
        for ((offset=0; offset<host_tpc; offset++)); do
            cpu="${pref_cpus[$((start + offset))]}"
            domain_cpus[$domain]="${domain_cpus[$domain]:+${domain_cpus[$domain]},}$cpu"
        done
    done
    for node in "${ordered_nodes[@]}"; do
        for domain in "${domains[@]}"; do
            [[ "${domain_node[$domain]}" == "$node" ]] || continue
            IFS=',' read -ra available <<< "${domain_cpus[$domain]}"
            vcpu_selected=(); service_selected=(); chosen_core=()
            for ((start=0; start<${#available[@]}; start+=host_tpc)); do
                (( ${#vcpu_selected[@]} < vcpu_count )) || break
                first="${available[$start]}"; key="$(_host_core_key "$first")"
                [[ -z "${chosen_core[$key]:-}" ]] || continue
                chosen_core[$key]=1
                for ((offset=0; offset<host_tpc; offset++)); do
                    cpu="${available[$((start + offset))]}"
                    vcpu_selected+=("$cpu")
                done
            done
            (( ${#vcpu_selected[@]} == vcpu_count )) || continue
            # service 只占 exact logical CPU；TPC2 奇数余量优先复用其它实例留下的半空 SMT 核。
            service_cores=(); service_core_seen=(); service_by_core=()
            for cpu in "${pref_cpus[@]}"; do
                [[ -z "${ISO_HELD[$cpu]:-}" ]] || continue
                _cpu_is_online "$cpu" || continue
                candidate_domain="$(_cpu_numa_node "$cpu"):$(_cpu_package "$cpu")"
                [[ "$candidate_domain" == "$domain" ]] || continue
                key="$(_host_core_key "$cpu")"
                [[ -z "${chosen_core[$key]:-}" ]] || continue
                if (( host_tpc == 2 )); then
                    all_online=1; IFS=',' read -ra core_free <<< "$key"
                    for sibling in "${core_free[@]}"; do _cpu_is_online "$sibling" || all_online=0; done
                    (( all_online )) || continue
                fi
                if [[ -z "${service_core_seen[$key]:-}" ]]; then
                    service_core_seen[$key]=1; service_cores+=("$key")
                fi
                service_by_core[$key]="${service_by_core[$key]:+${service_by_core[$key]},}$cpu"
            done
            full_left=$((service / host_tpc))
            for key in "${service_cores[@]}"; do
                (( full_left > 0 )) || break
                IFS=',' read -ra core_free <<< "${service_by_core[$key]}"
                (( ${#core_free[@]} >= host_tpc )) || continue
                chosen_core[$key]=1
                for ((offset=0; offset<host_tpc; offset++)); do service_selected+=("${core_free[$offset]}"); done
                full_left=$((full_left - 1))
            done
            (( full_left == 0 )) || continue
            remainder=$((service % host_tpc))
            for pass in 1 2; do
                (( remainder > 0 )) || break
                for key in "${service_cores[@]}"; do
                    [[ -z "${chosen_core[$key]:-}" ]] || continue
                    IFS=',' read -ra core_free <<< "${service_by_core[$key]}"; count=${#core_free[@]}
                    if (( pass == 1 )); then (( count == remainder )) || continue; else (( count >= remainder )) || continue; fi
                    chosen_core[$key]=1
                    for ((offset=0; offset<remainder; offset++)); do service_selected+=("${core_free[$offset]}"); done
                    remainder=0; break
                done
            done
            (( remainder == 0 )) || continue
            (( ${#service_selected[@]} == service )) || continue
            selected_domain="$domain"; selected_node="$node"; break 2
        done
    done
    [[ -n "$selected_domain" ]] || _die \
        "没有单一 NUMA/package 域能满足 1:1 逻辑 CPU 拓扑（需求 $need）"
    declare -ga _vcpu_mine=("${vcpu_selected[@]}") _service_mine=("${service_selected[@]}") _mine=("${vcpu_selected[@]}" "${service_selected[@]}")
    declare -g _selected_node="$selected_node" _selected_domain="$selected_domain"
    declare -g _instance_cpus_csv _vcpu_cpus_csv
    _instance_cpus_csv="$(printf '%s\n' "${_mine[@]}" | sort -n -u | paste -sd, -)" || _die "无法生成实例 exact 逻辑 CPU cpuset"
    _vcpu_cpus_csv="$(printf '%s\n' "${_vcpu_mine[@]}" | paste -sd, -)"
}
_validate_recorded_topology() {
    local csv="$1" guest_tpc="$2" host_tpc="$3" service="$4" domain="$5" exact="$6" require_online="${7:-1}"
    local start offset cpu key first_key expected_service_cores
    local -a vcpus=()
    local -A exact_set=() seen_core=() seen_cpu=() service_core=()
    IFS=',' read -ra vcpus <<< "$csv"
    (( guest_tpc >= 1 && host_tpc >= 1 && service >= 0 && service <= 8 && ${#vcpus[@]} >= 1 &&
       ${#vcpus[@]} % guest_tpc == 0 && ${#vcpus[@]} % host_tpc == 0 )) \
        || _die "实例登记的 guest/host core-thread 数量非法"
    while IFS= read -r cpu; do exact_set[$cpu]=1; done < <(_strict_cpu_list_to_lines "$exact")
    (( ${#exact_set[@]} == ${#vcpus[@]} + service )) \
        || _die "实例 exact cpuset 数量不等于 vCPU+service 的 1:1 预算"
    for cpu in "${!exact_set[@]}"; do
        key="$(_host_core_key "$cpu")"; _validate_smt2_core "$key" 0
        [[ "$(_cpu_numa_node "$cpu"):$(_cpu_package "$cpu")" == "$domain" ]] \
            || _die "实例 exact cpuset 跨 locality domain"
        (( require_online == 0 )) || _cpu_is_online "$cpu" \
            || _die "实例正在使用 offline CPU $cpu"
    done
    for ((start=0; start<${#vcpus[@]}; start+=host_tpc)); do
        first_key="$(_host_core_key "${vcpus[$start]}")"
        [[ -z "${seen_core[$first_key]:-}" ]] || _die "多个 host packing 组复用了物理核"
        seen_core[$first_key]=1
        for ((offset=0; offset<host_tpc; offset++)); do
            cpu="${vcpus[$((start + offset))]}"; key="$(_host_core_key "$cpu")"
            [[ "$key" == "$first_key" && -n "${exact_set[$cpu]:-}" \
               && -z "${seen_cpu[$cpu]:-}" ]] || _die "实例 vCPU 映射不再满足完整拓扑"
            seen_cpu[$cpu]=1
        done
    done
    for cpu in "${!exact_set[@]}"; do
        [[ -z "${seen_cpu[$cpu]:-}" ]] || continue
        key="$(_host_core_key "$cpu")"
        [[ -z "${seen_core[$key]:-}" ]] || _die "service CPU 与 vCPU 复用物理核"
        service_core[$key]=1
    done
    expected_service_cores=$(((service + host_tpc - 1) / host_tpc))
    (( ${#service_core[@]} == expected_service_cores )) \
        || _die "service CPU 未按独立 host packing 核分配"
}
_verify_instance_cpu_grant() {
    local expected_cpus="$1" expected_mems="$2" requested effective expected_online
    local requested_mems effective_mems path="${3:-$_instance_path}"
    requested="$(<"$path/cpuset.cpus")" || _die "无法读回实例 cpuset.cpus"
    requested="$(_strict_cpu_list_to_csv "$requested")" || _die "实例 cpuset.cpus 非法"
    [[ "$requested" == "$expected_cpus" ]] || _die "实例 cpuset.cpus 未达到请求值"
    expected_online="$(_strict_cpu_list_intersection_csv \
        "$expected_cpus" "$(< /sys/devices/system/cpu/online)")" \
        || _die "无法计算实例在线 CPU"
    effective="$(<"$path/cpuset.cpus.effective")" \
        || _die "无法读取实例 cpuset.cpus.effective"
    effective="$(_strict_cpu_list_to_csv "$effective")" || _die "实例 effective CPU 非法"
    [[ "$effective" == "$expected_online" ]] || _die "实例 effective CPU 不完整"
    if [[ -n "$expected_mems" ]]; then
        requested_mems="$(<"$path/cpuset.mems")" || _die "无法读回实例 mems"
        effective_mems="$(<"$path/cpuset.mems.effective")" \
            || _die "无法读取实例 effective mems"
        requested_mems="$(_strict_cpu_list_to_csv "$requested_mems")"
        effective_mems="$(_strict_cpu_list_to_csv "$effective_mems")"
        [[ "$requested_mems" == "$expected_mems" && "$effective_mems" == "$expected_mems" ]] \
            || _die "实例没有获得精确 NUMA node=$expected_mems"
    fi
}
_verify_parent_memory_grant() {
    local expected="$1" requested effective
    requested="$(<"$VMISO/cpuset.mems")" || _die "无法读回父 cpuset.mems"
    effective="$(<"$VMISO/cpuset.mems.effective")" \
        || _die "无法读取父 cpuset.mems.effective"
    requested="$(_strict_cpu_list_to_csv "$requested")" || _die "父 requested mems 非法"
    effective="$(_strict_cpu_list_to_csv "$effective")" || _die "父 effective mems 非法"
    [[ "$requested" == "$expected" && "$effective" == "$expected" ]] \
        || _die "父 cpuset 没有获得完整 NUMA 并集"
}
_activate_instance_cpuset() {
    local parent_cpus parent_mems free_cores part direct
    parent_cpus="$({ for direct in "${!ISO_HELD[@]}"; do printf '%s\n' "$direct"; done
        _strict_cpu_list_to_lines "$_instance_cpus_csv"; } | sort -n -u | paste -sd, -)"
    parent_mems="${ISO_PARENT_MEMS:+$ISO_PARENT_MEMS,}$_selected_node"
    parent_mems="$(_strict_cpu_list_to_csv "$parent_mems")" || _die "无法生成父 NUMA 并集"
    free_cores="$(_count_host_free_physical_cores "$parent_cpus")" \
        || _die "无法统计宿主剩余物理核"
    (( free_cores >= 2 )) || _die "隔离后必须至少给宿主保留 2 个完整物理核"
    APPLY_VMISO_TOUCHED=1
    (umask 022; mkdir -p "$VMISO") 2>/dev/null || _die "建 $VMISO 失败"
    _validate_vmiso_dir
    printf '%s\n' "$parent_mems" > "$VMISO/cpuset.mems" \
        || _die "写父 cpuset.mems 失败"
    printf '%s\n' "$parent_cpus" > "$VMISO/cpuset.cpus" \
        || _die "写父 cpuset.cpus 失败"
    printf 'root\n' > "$VMISO/cpuset.cpus.partition" \
        || _die "父 cpuset 无法进入独占 partition"
    part="$(<"$VMISO/cpuset.cpus.partition")"
    [[ "$part" == "root" ]] || _die "父 partition 状态不是 root: $part"
    _verify_vmiso_cpu_grant "$parent_cpus"
    _verify_parent_memory_grant "$parent_mems"
    if ! grep -qw cpuset "$VMISO/cgroup.subtree_control" 2>/dev/null; then
        printf '+cpuset\n' > "$VMISO/cgroup.subtree_control" \
            || _die "无法在父 partition 启用子 cpuset controller"
    fi
    _instance_path="$(_instance_cgroup_path "$INST")"
    [[ ! -e "$_instance_path" && ! -L "$_instance_path" ]] \
        || _die "实例 cgroup 已存在: $_instance_path"
    (umask 022; mkdir "$_instance_path") || _die "无法创建实例 cgroup"
    APPLY_INSTANCE_CREATED=1
    _validate_instance_cgroup "$_instance_path"
    printf '%s\n' "$_instance_cpus_csv" > "$_instance_path/cpuset.cpus" \
        || _die "写实例 cpuset.cpus 失败"
    printf '%s\n' "$parent_mems" > "$_instance_path/cpuset.mems" \
        || _die "初始化实例 cpuset.mems 失败"
    _verify_instance_cpu_grant "$_instance_cpus_csv" ""
}
_localize_instance_memory() {
    local node_count
    node_count="$(_host_numa_node_count)"
    if (( node_count > 1 )); then
        [[ -x "$MIGRATEPAGES" && -x "$TIMEOUT" ]] || _die "缺少 NUMA 迁移工具"
        "$TIMEOUT" --signal=TERM --kill-after=5s 120s \
            "$MIGRATEPAGES" "$PID" all "$_selected_node" >/dev/null 2>&1 \
            || _die "无法把 QEMU 既有页面完整迁移到 NUMA node=$_selected_node"
    fi
    printf '%s\n' "$_selected_node" > "$_instance_path/cpuset.mems" \
        || _die "收窄实例 cpuset.mems 失败"
    _verify_instance_cpu_grant "$_instance_cpus_csv" "$_selected_node"
}
_release_instance_cpuset() {
    local instance="$1" state_path child cpus mems event part subtree
    state_path="$(_instance_state_path "$instance")"; child="$(_instance_cgroup_path "$instance")"
    if [[ ! -e "$state_path" && ! -L "$state_path" ]]; then
        [[ ! -e "$child" && ! -L "$child" ]] || _die "实例 child 存在但缺少可信登记"
        echo ">> cpuset     : 实例 $instance 无隔离登记, 无需释放"
        return 0
    fi
    _read_instance_state "$state_path"
    [[ "$STATE_INSTANCE" == "$instance" && "$STATE_CALLER_UID" == "$(_caller_uid)" ]] \
        || _die "实例 $instance 的隔离登记身份不匹配"
    if _proc_generation_is_live "$STATE_PID" "$STATE_START"; then
        _die "实例 $instance 的 QEMU 仍在运行，拒绝提前释放 CPU"
    fi
    if [[ ! -d "$VMISO" ]]; then
        rm -f -- "$state_path" || _die "无法删除已失效实例登记"
        echo ">> cpuset     : 父分区已不存在, 已清理实例登记"
        return 0
    fi
    if [[ -d "$child" ]]; then
        _validate_instance_cgroup "$child"
        cpus="$(_strict_cpu_list_to_csv "$(<"$child/cpuset.cpus")")"
        mems="$(_strict_cpu_list_to_csv "$(<"$child/cpuset.mems")")"
        [[ "$cpus" == "$STATE_CPUS" ]] || _die "实例 child CPU 与登记不一致"
        if [[ "$STATE_PHASE" == "active" ]]; then
            [[ "$mems" == "$STATE_MEMS" ]] || _die "实例 child NUMA 与登记不一致"
        else
            case ",$mems," in
                *",$STATE_MEMS,"*) ;;
                *) _die "实例 child NUMA 不包含登记目标" ;;
            esac
        fi
        if [[ -r "$child/cgroup.events" ]]; then
            event="$(awk '$1 == "populated" {print $2}' "$child/cgroup.events")"
            [[ "$event" == "0" ]] || _die "实例 child 仍 populated"
        elif [[ -s "$child/cgroup.procs" ]]; then
            _die "实例 child 仍有进程"
        fi
        _validate_recorded_topology "$STATE_VCPU_CPUS" "$STATE_GUEST_TPC" \
            "$STATE_HOST_TPC" "$STATE_SERVICE_CPUS" "$STATE_DOMAIN" "$cpus" 0
        _write_instance_state "$STATE_INSTANCE" "$STATE_PID" "$STATE_START" \
            "$STATE_CALLER_UID" "$STATE_CPUS" "$STATE_VCPU_CPUS" \
            "$STATE_MEMS" "$STATE_SERVICE_CPUS" "$STATE_GUEST_TPC" "$STATE_HOST_TPC" \
            "$STATE_DOMAIN" releasing
        "$RMDIR" "$child" || _die "无法删除实例 child；保留登记供重试"
    elif [[ "$STATE_PHASE" == "active" ]]; then
        _die "active 实例登记对应的 child 不存在"
    fi
    _collect_instance_allocations 0
    if (( ISO_CHILD_COUNT == 0 )); then
        if grep -qw cpuset "$VMISO/cgroup.subtree_control" 2>/dev/null; then
            printf '%s\n' '-cpuset' > "$VMISO/cgroup.subtree_control" \
                || _die "无法停用空父级 cpuset controller"
            subtree="$(<"$VMISO/cgroup.subtree_control")"
            grep -qw cpuset <<< "$subtree" \
                && _die "空父级 cpuset controller 未停用"
        fi
        printf 'member\n' > "$VMISO/cpuset.cpus.partition" \
            || _die "无法把空父分区切回 member；保留实例登记"
        part="$(<"$VMISO/cpuset.cpus.partition")"
        [[ "$part" == "member" ]] || _die "空父分区未退出 root: $part"
        "$RMDIR" "$VMISO" || _die "无法删除空父分区；保留实例登记"
        echo ">> cpuset     : 最后一台 VM 已退出，独占分区已拆除"
    else
        printf '%s\n' "$ISO_PARENT_MEMS" > "$VMISO/cpuset.mems" \
            || _die "收缩父 cpuset.mems 失败；保留实例登记"
        printf '%s\n' "$ISO_PARENT_CPUS" > "$VMISO/cpuset.cpus" \
            || _die "收缩父 cpuset.cpus 失败；保留实例登记"
        _verify_vmiso_cpu_grant "$ISO_PARENT_CPUS"
        _verify_parent_memory_grant "$ISO_PARENT_MEMS"
        echo ">> cpuset     : 已释放实例 $instance，父分区保留 $ISO_CHILD_COUNT 台 VM"
    fi
    rm -f -- "$state_path" || _die "无法删除实例 $instance 的隔离登记"
}
