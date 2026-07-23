# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 启动 NUMA-aware vCPU pinner。兼容模式保持异步；严格模式由显示/进程监督父 shell
# 在 QEMU -S 进程组创建后执行 ARMED→RUNNING 管道握手。
# ---------------------------------------------------------------------------

SV_CPU_STRICT_SUPERVISION_READY=0

sv_cpu_isolate_preflight() {
    [[ "${CPU_ISOLATE:-1}" == "1" ]] || return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    local repo_root
    local group_guard="${SV_STRICT_GROUP_GUARD:-$HERE/lib/vm-strict-group-guard.py}"
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
    if [[ "${STRICT_HARDWARE:-1}" == "1" ]]; then
        if [[ ! -x "$group_guard" ]] || ! "$group_guard" check >/dev/null 2>&1; then
            echo "ERROR: 严格 CPU 隔离缺少 pidfd/setsid 进程组守护能力" >&2
            return 1
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1 \
        || ! python3 "$pinner" --help >/dev/null 2>&1; then
        echo "ERROR: NUMA pinner 的 Python/import 预检失败" >&2
        return 1
    fi
    # 同步确认 sudoers、cgroup v2 与 cpuset controller。这样常见部署错误不会等到
    # QEMU 已启动后才由异步 pinner 发现；输出仅在失败时展示，正常启动保持简洁。
    local preflight_output
    if ! preflight_output="$(sudo -n "$helper" preflight 2>&1)"; then
        echo "ERROR: CPU 隔离 preflight 失败（sudo/cgroup/cpuset 或 QEMU 信任清单无效）" >&2
        echo "       构建已变化时请在仓库根目录运行: deploy/tools/build.sh --install-host-helpers" >&2
        echo "       仅诊断运行: sudo $HERE/setup-host-helpers.sh check" >&2
        return 1
    fi
    if [[ "$preflight_output" != *"abi=5"* ||
          "$preflight_output" != *"policy=logical-1to1-v1"* ]]; then
        echo "ERROR: CPU 隔离 helper ABI/绑核策略过旧；请先安全关闭旧 VM，再重新安装 host helpers" >&2
        repo_root="$(cd "$HERE/../.." && pwd -P)" || repo_root="<仓库根目录>"
        printf '       安装命令: cd %q && ./deploy/tools/build.sh --install-host-helpers\n' \
            "$repo_root" >&2
        printf '       安装后验证（可选）: sudo -n %q preflight\n' "$helper" >&2
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

SV_CPU_PINNER_PID=""
SV_CPU_PINNER_START=""
SV_CPU_PINNER_ABORT=0

# Guest topology 是对外身份，宿主按相同的每核线程数放置 vCPU：
# 2C2T/4C4T 各 vCPU 使用不同物理核，2C4T 才使用同核 SMT sibling。
sv_cpu_host_threads_per_core() {
    printf '%s\n' "$(( CPU_THREADS / CPU_CORES ))"
}

# 兼容模式不使用 -S，保留原来的直接 exec 与异步 pinner 行为。
sv_cpu_isolate_launch() {
    [[ "${CPU_ISOLATE:-1}" == "1" ]] || return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    local pinner="$HERE/vm-cpu-pinner.py"
    local launcher_pid launcher_state launcher_start
    local pinner_pid
    sv_cpu_isolate_preflight || return 1
    [[ "${STRICT_HARDWARE:-1}" != "1" ]] || {
        echo "ERROR: 严格 CPU pinner 必须由 QEMU 进程组监督器启动" >&2
        return 1
    }

    echo ">> CPU 隔离:   后台 NUMA pinner 已启动，等待 QMP vCPU 线程"
    # pinner 必须继承 FD8 到 QEMU 退出并完成 helper release。这样旧代即使在 cont
    # 响应或收尾期间遇到延迟，同实例的新启动器也无法复用固定 QMP 路径插进来。
    launcher_pid="$BASHPID"
    read -r launcher_state launcher_start \
        < <(sv_proc_state_starttime "$launcher_pid") || launcher_start=""
    [[ "$launcher_state" != "Z" && "$launcher_state" != "z" \
       && "$launcher_state" != "X" && "$launcher_state" != "x" \
       && "$launcher_start" =~ ^[0-9]+$ ]] || {
        echo "ERROR: 无法绑定 CPU pinner 的启动器代际" >&2
        return 1
    }
    python3 "$pinner" \
        "$INSTANCE" "${CPUS:-4}" "$QMP_SOCK" "$helper" \
        "${QEMU_SERVICE_CPUS:-0}" \
        "$(( CPU_THREADS / CPU_CORES ))" \
        "$(sv_cpu_host_threads_per_core)" \
        --launcher-pid "$launcher_pid" --launcher-starttime "$launcher_start" &
    pinner_pid=$!
    [[ "$pinner_pid" =~ ^[0-9]+$ ]] || return 1
    return 0
}

# QEMU 已在独立 setsid 进程组内以 -S 暂停。父 shell 从只有 pinner 持写端的管道
# 接收两阶段状态；RUNNING 前任何 EOF/FAIL/非法顺序都交给父 shell 终止整个进程组。
sv_cpu_isolate_supervise() {
    local launcher_pid="$1" launcher_start="$2" launcher_pgid="$3"
    local helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    local pinner="$HERE/vm-cpu-pinner.py" status_fd kind value1 value2 extra
    local pinner_state attempt

    [[ "$launcher_pid" =~ ^[0-9]+$ && "$launcher_start" =~ ^[0-9]+$ \
       && "$launcher_pgid" == "$launcher_pid" ]] || return 1
    SV_CPU_PINNER_ABORT=0
    exec {status_fd}< <(
        exec python3 "$pinner" \
            "$INSTANCE" "${CPUS:-4}" "$QMP_SOCK" "$helper" \
            "${QEMU_SERVICE_CPUS:-0}" "$(( CPU_THREADS / CPU_CORES ))" \
            "$(sv_cpu_host_threads_per_core)" \
            --launcher-pid "$launcher_pid" --launcher-starttime "$launcher_start" \
            --launcher-pgid "$launcher_pgid" --status-fd 1 --abort-on-failure
    )
    SV_CPU_PINNER_PID=$!
    SV_CPU_PINNER_START=""
    for ((attempt=0; attempt<50; attempt++)); do
        if read -r pinner_state SV_CPU_PINNER_START \
                < <(sv_proc_state_starttime "$SV_CPU_PINNER_PID") \
            && [[ "$SV_CPU_PINNER_START" =~ ^[0-9]+$ ]]; then
            break
        fi
        SV_CPU_PINNER_START=""
        sleep 0.01
    done
    echo ">> CPU 隔离:   严格监督 pinner pid=$SV_CPU_PINNER_PID，等待 ARMED"
    if ! IFS=' ' read -r -t 10 kind value1 value2 extra <&"$status_fd"; then
        echo "ERROR: CPU pinner 未在拓扑预检后进入 ARMED" >&2
        SV_CPU_PINNER_ABORT=1
        exec {status_fd}<&-
        return 1
    fi
    if [[ "$kind" != "ARMED" || -n "$value1$value2$extra" ]]; then
        echo "ERROR: CPU pinner ARMED 前返回非法状态: $kind" >&2
        # 明确 FAIL 由 pinner 自己收尾；其它状态说明初始化协议损坏，此时尚未
        # 进入 QMP/helper 阶段，父 shell 可在停 guest 后安全收割 pinner。
        [[ "$kind" == "FAIL" ]] || SV_CPU_PINNER_ABORT=1
        exec {status_fd}<&-
        return 1
    fi
    if ! IFS=' ' read -r -t 1200 kind value1 value2 extra <&"$status_fd" \
        || [[ "$kind" != "RUNNING" || ! "$value1" =~ ^[0-9]+$ \
              || ! "$value2" =~ ^[0-9]+$ || -n "$extra" ]] \
        || ! sv_proc_generation_is_live "$value1" "$value2" \
        || [[ "$(sv_proc_pgid "$value1" 2>/dev/null || true)" != "$launcher_pgid" ]]; then
        echo "ERROR: CPU pinner 未完成 RUNNING 握手，正在终止暂停态 QEMU" >&2
        # ARMED 后可能已有 root helper 正在 apply/回滚，不能 SIGKILL pinner 留下
        # 孤儿提权子进程；先停进程组，finish 等其自然收尾后再幂等 release。
        SV_CPU_PINNER_ABORT=0
        exec {status_fd}<&-
        return 1
    fi
    exec {status_fd}<&-
    echo ">> CPU 隔离:   RUNNING 已确认（qemu pid=$value1, pgid=$launcher_pgid）"
    return 0
}

# QEMU 消失后先收割/必要时终止本 shell 创建的 pinner，再做一次幂等 release。
# release 与仍在结束的 root apply 共用全局锁，因此不会抢先归还活动 CPU。
sv_cpu_isolate_finish() {
    local helper="${SV_CPU_ISO_HELPER:-/usr/local/libexec/qemu-vmate-cpu-isolate}"
    local group_guard="${SV_STRICT_GROUP_GUARD:-$HERE/lib/vm-strict-group-guard.py}"
    local pinner_state="" pinner_start="" finish_status=0
    if [[ "${SV_CPU_PINNER_PID:-}" =~ ^[0-9]+$ \
       && "${SV_CPU_PINNER_START:-}" =~ ^[0-9]+$ ]]; then
        read -r pinner_state pinner_start \
            < <(sv_proc_state_starttime "$SV_CPU_PINNER_PID") || pinner_start=""
        if [[ "${SV_CPU_PINNER_ABORT:-0}" == "1" \
           && "$pinner_start" == "$SV_CPU_PINNER_START" \
           && ! "$pinner_state" =~ ^[XxZz]$ ]]; then
            if [[ ! -x "$group_guard" ]] || ! "$group_guard" signal \
                    "$SV_CPU_PINNER_PID" "$SV_CPU_PINNER_START" KILL; then
                echo "WARN: 无法用 pidfd 收割预 ARMED pinner" >&2
                finish_status=1
            fi
        fi
        if (( finish_status == 0 )) \
            && [[ -z "$pinner_start" || "$pinner_start" == "$SV_CPU_PINNER_START" ]]; then
            wait "$SV_CPU_PINNER_PID" 2>/dev/null || true
        fi
    fi
    SV_CPU_PINNER_PID=""
    SV_CPU_PINNER_START=""
    SV_CPU_PINNER_ABORT=0
    if ! sudo -n "$helper" release "$INSTANCE" >/dev/null 2>&1; then
        echo "WARN: CPU 隔离兜底 release 失败；stop-vm 将继续重试" >&2
        return 1
    fi
    return "$finish_status"
}

# display guard 只有在本模块完整加载、严格监督函数均已定义后才能接管 -S QEMU。
# shellcheck disable=SC2034  # 由后续 source 的 sv-display-guard.sh 消费。
SV_CPU_STRICT_SUPERVISION_READY=1
