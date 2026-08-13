#!/bin/bash
# shellcheck shell=bash
# host-cpu-isolate 的 root-owned 运行库装载器；主 helper 提供路径、ABI 与 _die。

# shellcheck disable=SC2154
_load_trusted_library() {
    local library="$1" metadata uid gid mode links
    [[ -f "$library" && ! -L "$library" ]] \
        || _die "CPU isolate library 不是普通文件: $library"
    metadata="$(stat -Lc '%u %g %a %h' -- "$library" 2>/dev/null)" \
        || _die "无法读取 CPU isolate library 元数据"
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid:$mode:$links" == "0:0:755:1" ]] \
        || _die "CPU isolate library 必须为 root:root 0755 且只有一个硬链接"
    # shellcheck disable=SC1090
    source "$library"
}

_load_runtime_libraries() {
    local metadata uid gid mode parent
    parent="${RUNTIME_LIB%/*}"
    [[ -d "$parent" && ! -L "$parent" ]] \
        || _die "CPU isolate libexec 不是普通目录: $parent"
    metadata="$(stat -Lc '%u %g %a' -- "$parent" 2>/dev/null)" \
        || _die "无法读取 CPU isolate libexec 元数据"
    read -r uid gid mode <<<"$metadata"
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] \
        || _die "CPU isolate libexec owner/mode 非法"
    (( (8#$mode & 8#022) == 0 )) \
        || _die "CPU isolate libexec 不得由 group/other 写入"
    [[ "${CGROUP_LIB%/*}" == "$parent" && "${TRUST_LIB%/*}" == "$parent" ]] \
        || _die "CPU isolate library 目录不一致"
    _load_trusted_library "$TRUST_LIB"
    _load_trusted_library "$RUNTIME_LIB"
    _load_trusted_library "$CGROUP_LIB"
    [[ "${VMATE_QEMU_TRUST_ABI:-}" == "$QEMU_TRUST_ABI" ]] \
        || _die "CPU isolate main/QEMU trust ABI 不匹配"
    [[ "${VMATE_CPU_ISOLATE_RUNTIME_ABI:-}" == "$CPU_ISOLATE_RUNTIME_ABI" ]] \
        || _die "CPU isolate main/runtime ABI 不匹配"
    [[ "${VMATE_CPU_ISOLATE_CGROUP_ABI:-}" == "$CPU_ISOLATE_CGROUP_ABI" ]] \
        || _die "CPU isolate main/cgroup ABI 不匹配"
    declare -F _validate_qemu_target _apply_transaction_begin \
        _apply_transaction_exit _verify_vmiso_cpu_grant \
        _strict_cpu_list_intersection_csv _caller_uid _proc_start_time \
        _proc_generation_is_live _scan_vmiso_children _collect_instance_allocations \
        _select_instance_cpus _validate_recorded_topology _activate_instance_cpuset \
        _localize_instance_memory _release_instance_cpuset \
        _status_instance_cpusets _validate_memory_locality_tool >/dev/null \
        || _die "CPU isolate runtime 接口不完整"
}
