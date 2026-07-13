# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 启动异步 NUMA-aware vCPU pinner。复杂的 sysfs/QMP/放置算法位于可单测的
# vm-cpu-pinner.py；本文件只维护启动器生命周期和安全 root helper 边界。
# ---------------------------------------------------------------------------

sv_cpu_isolate_preflight() {
    [[ "${CPU_ISOLATE:-1}" == "1" ]] || return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    local pinner="$HERE/vm-cpu-pinner.py"
    if [[ ! -x "$helper" ]]; then
        echo "ERROR: CPU 隔离缺少安全的 root-owned helper: $helper" >&2
        echo "       请在仓库根目录重新运行: deploy/tools/build.sh --install-host-helpers" >&2
        return 1
    fi
    if declare -F _sv_root_helper_is_safe >/dev/null \
        && ! _sv_root_helper_is_safe "$helper"; then
        echo "ERROR: CPU 隔离 helper 的 owner/mode 不符合安全要求: $helper" >&2
        return 1
    fi
    if [[ ! -x "$pinner" ]]; then
        echo "ERROR: 找不到 NUMA pinner: $pinner" >&2
        return 1
    fi
    # 同步确认 sudoers、cgroup v2 与 cpuset controller。这样常见部署错误不会等到
    # QEMU 已启动后才由异步 pinner 发现；输出仅在失败时展示，正常启动保持简洁。
    if ! sudo -n "$helper" preflight >/dev/null; then
        echo "ERROR: CPU 隔离 preflight 失败（sudo/cgroup v2/cpuset 不可用）" >&2
        echo "       可诊断运行: sudo $HERE/setup-host-helpers.sh check" >&2
        return 1
    fi
}

# source 阶段就完成同步检查，避免 profile、磁盘、TPM、TAP 或 watchdog 产生后才发现
# 默认严格隔离根本不可用。兼容模式只告警；严格模式在任何持久化副作用前退出。
if ! sv_cpu_isolate_preflight; then
    if [[ "${STRICT_HARDWARE:-1}" == "1" ]]; then
        exit 1
    fi
    echo ">> CPU 隔离:   兼容模式继续运行，不计入严格性能支持" >&2
fi

sv_cpu_isolate_launch() {
    [[ "${CPU_ISOLATE:-1}" == "1" ]] || return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    local pinner="$HERE/vm-cpu-pinner.py"
    sv_cpu_isolate_preflight || return 1

    echo ">> CPU 隔离:   后台 NUMA pinner 已启动，等待 QMP vCPU 线程"
    # FD8 是实例生命周期锁；后台短任务必须关闭它，避免 pinner 超时延长锁占用。
    local strict_args=()
    if [[ "${STRICT_HARDWARE:-1}" == "1" ]]; then
        strict_args+=(--abort-on-failure)
    fi
    python3 8>&- "$pinner" \
        "$INSTANCE" "${CPUS:-4}" "$QMP_SOCK" "$helper" \
        "${QEMU_SERVICE_CPUS:-0}" "${strict_args[@]}" &
    return 0
}
