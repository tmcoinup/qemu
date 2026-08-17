#!/usr/bin/env bash
# Launcher-side CPU isolation integration.  The pinner waits for QMP
# query-cpus-fast, then delegates the privileged cgroup/taskset transaction to
# deploy/host/cpu-isolate.sh.

CPU_ISOLATION_PINNER_PID=""
CPU_ISOLATION_LAUNCHED=0
CPU_ISOLATION_SYSTEM_HELPER="${CPU_ISOLATION_SYSTEM_HELPER:-/usr/local/libexec/qemu-cpu-isolate}"
CPU_ISOLATION_INSTALLER="${CPU_ISOLATION_INSTALLER:-$here/host/install-cpu-isolation.sh}"
CPU_ISOLATION_AUTO_INSTALL="${CPU_ISOLATION_AUTO_INSTALL:-1}"

cpu_isolation_helper_path() {
    if [[ -n "${CPU_ISOLATION_HELPER:-}" ]]; then
        printf '%s\n' "$CPU_ISOLATION_HELPER"
    elif [[ -x "$CPU_ISOLATION_SYSTEM_HELPER" ]]; then
        printf '%s\n' "$CPU_ISOLATION_SYSTEM_HELPER"
    else
        printf '%s\n' "$here/host/cpu-isolate.sh"
    fi
}

cpu_isolation_dependencies_ready() {
    command -v python3 >/dev/null 2>&1 &&
        command -v taskset >/dev/null 2>&1 &&
        command -v flock >/dev/null 2>&1 &&
        command -v cmp >/dev/null 2>&1
}

cpu_isolation_system_helper_ready() {
    local probe_vm_id=999999999999999999

    [[ -x "$CPU_ISOLATION_SYSTEM_HELPER" ]] || return 1
    cpu_isolation_dependencies_ready || return 1

    # Keep an already-installed root copy in sync with the repository helper.
    # Otherwise a source security fix would not reach the privileged helper.
    if [[ -r "$here/host/cpu-isolate.sh" ]] &&
            ! cmp -s "$here/host/cpu-isolate.sh" \
                "$CPU_ISOLATION_SYSTEM_HELPER"; then
        return 1
    fi

    if ((EUID == 0)); then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || return 1

    # release on a deliberately nonexistent valid VM id is non-mutating.  The
    # outer sudo verifies that the installed NOPASSWD policy is usable.
    sudo -n -- "$CPU_ISOLATION_SYSTEM_HELPER" release \
        "$probe_vm_id" >/dev/null 2>&1
}

cpu_isolation_run_installer() {
    local password=${SUDO_PASSWORD:-}

    [[ -x "$CPU_ISOLATION_INSTALLER" ]] || {
        echo "[cpu-isolate] 自动安装器不存在或不可执行: $CPU_ISOLATION_INSTALLER" >&2
        return 1
    }

    if ((EUID == 0)); then
        "$CPU_ISOLATION_INSTALLER"
        return
    fi
    command -v sudo >/dev/null 2>&1 || {
        echo "[cpu-isolate] 自动安装需要 sudo" >&2
        return 1
    }

    if sudo -n -- "$CPU_ISOLATION_INSTALLER" 2>/dev/null; then
        return 0
    fi
    [[ -n "$password" ]] || {
        echo "[cpu-isolate] 自动安装需要 SUDO_PASSWORD" >&2
        return 1
    }

    # Password is sent only over sudo stdin and is never placed in argv/logs.
    printf '%s\n' "$password" |
        sudo -S -p '' -- "$CPU_ISOLATION_INSTALLER"
}

host_runtime_helper_ensure_ready() {
    local auto_install=${CPU_ISOLATION_AUTO_INSTALL,,}

    [[ "${DRY_RUN:-0}" != 1 ]] || return 0

    # An explicit helper is an advanced/test override; never replace it.
    if [[ -n "${CPU_ISOLATION_HELPER:-}" ]]; then
        if [[ -x "$CPU_ISOLATION_HELPER" ]] &&
                cpu_isolation_dependencies_ready; then
            return 0
        fi
        echo "[host-helper] 显式 CPU_ISOLATION_HELPER 不可用" >&2
    elif cpu_isolation_system_helper_ready; then
        return 0
    else
        case "$auto_install" in
            1|on|yes|true)
                echo "[host-helper] 缺少或需要更新宿主 helper/依赖，开始自动安装"
                if cpu_isolation_run_installer &&
                        cpu_isolation_system_helper_ready; then
                    echo "[host-helper] 宿主 helper/依赖安装完成"
                    return 0
                fi
                echo "[host-helper] 自动安装后 helper 仍不可用" >&2
                ;;
            0|off|no|false)
                echo "[host-helper] helper/依赖不可用，且自动安装已关闭" >&2
                ;;
            *)
                echo "[host-helper] CPU_ISOLATION_AUTO_INSTALL 必须是 0 或 1" >&2
                ;;
        esac
    fi

    return 1
}

cpu_isolation_ensure_ready() {
    [[ "${CPU_ISOLATION:-required}" != off ]] || return 0

    if host_runtime_helper_ensure_ready; then
        return 0
    fi

    if [[ "${CPU_ISOLATION:-required}" == auto ]]; then
        echo "[cpu-isolate] WARN: auto 模式降级为 off" >&2
        CPU_ISOLATION=off
        export CPU_ISOLATION
        return 0
    fi
    return 1
}

host_oom_process_generation() {
    local pid=$1

    python3 - "$pid" <<'PY'
import sys

pid = int(sys.argv[1])
with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
    value = stream.read().strip()
close = value.rfind(") ")
if close < 0:
    raise SystemExit(1)
fields = value[close + 2:].split()
if len(fields) < 20 or fields[0] in {"X", "Z"}:
    raise SystemExit(1)
starttime = fields[19]
if not starttime.isdigit() or int(starttime) <= 0:
    raise SystemExit(1)
print(fields[0], starttime)
PY
}

host_oom_protect_launcher() {
    local vm_id=$1 helper pid state start output score
    local policy=${HOST_OOM_PROTECT:-1}

    case "$policy" in
        0)
            echo "[host-oom] HOST_OOM_PROTECT=0，已显式关闭"
            return 0
            ;;
        1) ;;
        *)
            echo "[host-oom] HOST_OOM_PROTECT 必须是 0 或 1" >&2
            return 2
            ;;
    esac
    [[ "${DRY_RUN:-0}" != 1 ]] || return 0
    host_runtime_helper_ensure_ready || {
        echo "[host-oom] 宿主 helper 不可用，拒绝未保护启动" >&2
        return 1
    }

    helper=$(cpu_isolation_helper_path)
    pid=$BASHPID
    if ! read -r state start < <(host_oom_process_generation "$pid"); then
        echo "[host-oom] 无法读取启动器进程代际" >&2
        return 1
    fi
    if ! output=$("$helper" oom-protect "$vm_id" "$pid" "$start" 2>&1); then
        echo "[host-oom] 无法保护 vm${vm_id} 启动器进程树: $output" >&2
        return 1
    fi
    if [[ "$output" =~ ^host-oom-protect:\ policy=oom-score-v1\ score=(-[0-9]+)\ pid=([0-9]+)$ ]]; then
        score=${BASH_REMATCH[1]}
    else
        echo "[host-oom] helper 返回了未知协议: $output" >&2
        return 1
    fi
    [[ "${BASH_REMATCH[2]}" == "$pid" ]] || {
        echo "[host-oom] helper 返回了错误的进程身份" >&2
        return 1
    }
    ((score >= -1000 && score <= -500)) || {
        echo "[host-oom] helper 返回了越界 OOM 分数: $score" >&2
        return 1
    }
    echo "[host-oom] vm${vm_id} 进程树 oom_score_adj=$score（随 VM 退出失效）"
}

cpu_isolation_normalize_mode() {
    local value=${CPU_ISOLATION:-}

    if [[ -z "$value" && -n "${CPU_ISOLATE:-}" ]]; then
        case "$CPU_ISOLATE" in
            1) value=required ;;
            0) value=off ;;
            *) value=$CPU_ISOLATE ;;
        esac
    fi
    value=${value:-required}
    case "${value,,}" in
        auto|required|off) CPU_ISOLATION=${value,,} ;;
        1|on|yes|true) CPU_ISOLATION=required ;;
        0|off|no|false) CPU_ISOLATION=off ;;
        *) return 2 ;;
    esac
    export CPU_ISOLATION
}

cpu_isolation_print_plan() {
    case "${CPU_ISOLATION:-required}" in
        off)
            echo "  CPU 隔离: off"
            ;;
        *)
            echo "  CPU 隔离: ${CPU_ISOLATION}（vCPU 1:1，service CPUs=${QEMU_SERVICE_CPUS:-auto}，host reserve=${HOST_RESERVE_CORES:-auto}）"
            ;;
    esac
}

cpu_isolation_launch() {
    local vm_id=$1 vcpu_count=$2 qmp_sock=$3 pid_file=$4 state_file=$5
    local helper topology_root cgroup_root
    local timeout=${CPU_ISOLATION_QMP_TIMEOUT:-90}
    helper=$(cpu_isolation_helper_path)
    topology_root=${CPU_ISOLATION_SYS_CPU_ROOT:-/sys/devices/system/cpu}
    cgroup_root=${CPU_ISOLATION_CGROUP_ROOT:-/sys/fs/cgroup}

    [[ "${CPU_ISOLATION:-required}" != off ]] || return 0
    [[ "${DRY_RUN:-0}" != 1 ]] || return 0
    [[ -x "$helper" ]] || {
        echo "[cpu-isolate] helper 不存在或不可执行: $helper" >&2
        [[ "$CPU_ISOLATION" != required ]] || return 1
        return 0
    }

    CPU_ISOLATION_LAUNCHED=1
    printf 'pending\n' >"$state_file" 2>/dev/null || true
    echo "[cpu-isolate] mode=${CPU_ISOLATION}：等待 QMP vCPU TID"

    python3 - "$CPU_ISOLATION" "$vm_id" "$vcpu_count" "$qmp_sock" \
        "$pid_file" "$helper" "${QEMU_SERVICE_CPUS:-auto}" \
        "${HOST_RESERVE_CORES:-auto}" "$timeout" "$state_file" \
        "$topology_root" "$cgroup_root" <<'PY' &
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import time

(mode, vm_id, expected_text, qmp_path, pid_file, helper, service_text,
 reserve_text, timeout_text, state_file, topology_root,
 cgroup_root) = sys.argv[1:]
expected = int(expected_text)
service_auto = service_text.lower() == "auto"
try:
    service_count = 1 if service_auto else int(service_text)
except ValueError:
    raise SystemExit(f"invalid service CPU count: {service_text}")
if not 0 <= service_count <= 64:
    raise SystemExit(f"service CPU count out of range: {service_count}")
timeout = int(timeout_text)

def log(message):
    print(f"[cpu-isolate] {message}", flush=True)

def write_state(value):
    try:
        temp = state_file + f".tmp.{os.getpid()}"
        with open(temp, "w", encoding="utf-8") as stream:
            stream.write(value.rstrip() + "\n")
        os.replace(temp, state_file)
    except OSError:
        pass

def expand_cpu_list(value):
    result = set()
    for item in value.strip().split(","):
        if not item:
            continue
        if "-" in item:
            first, last = item.split("-", 1)
            result.update(range(int(first), int(last) + 1))
        else:
            result.add(int(item))
    return result

def online_cpus():
    try:
        with open(os.path.join(topology_root, "online"), encoding="ascii") as stream:
            return expand_cpu_list(stream.read())
    except OSError:
        return set()

def topology():
    online = online_cpus()
    cores = {}
    pattern = os.path.join(
        topology_root, "cpu[0-9]*", "topology", "thread_siblings_list"
    )
    for path in glob.glob(pattern):
        try:
            with open(path, encoding="ascii") as stream:
                siblings = tuple(sorted(expand_cpu_list(stream.read()) & online))
        except (OSError, ValueError):
            continue
        if siblings:
            cores[siblings] = siblings
    return sorted(cores.values(), key=lambda siblings: siblings[0])

def held_partition_cpus():
    held = set()
    pattern = os.path.join(
        cgroup_root, "qemu-vm-isolation", "vm[1-9]*", "cpuset.cpus"
    )
    for path in glob.glob(pattern):
        try:
            with open(os.path.join(os.path.dirname(path), "cgroup.procs"),
                      encoding="ascii") as stream:
                if not stream.read().strip():
                    continue
            with open(path, encoding="ascii") as stream:
                held.update(expand_cpu_list(stream.read()))
        except (OSError, ValueError):
            continue
    return held

def qmp_command(stream, command, ident):
    request = {"execute": command, "id": ident}
    stream.write((json.dumps(request) + "\r\n").encode())
    while True:
        line = stream.readline()
        if not line:
            raise RuntimeError("QMP closed")
        response = json.loads(line)
        if response.get("id") != ident:
            continue
        if "error" in response:
            raise RuntimeError(response["error"].get("desc", "QMP error"))
        return response.get("return")

def qmp_execute(command, ident):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(qmp_path)
    stream = sock.makefile("rwb", buffering=0)
    while True:
        greeting = json.loads(stream.readline())
        if "QMP" in greeting:
            break
    qmp_command(stream, "qmp_capabilities", ident + "-cap")
    result = qmp_command(stream, command, ident)
    sock.close()
    return result

def query_vcpus():
    deadline = time.monotonic() + timeout
    last_error = "QMP socket not ready"
    while time.monotonic() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(3)
            sock.connect(qmp_path)
            stream = sock.makefile("rwb", buffering=0)
            while True:
                greeting = json.loads(stream.readline())
                if "QMP" in greeting:
                    break
            qmp_command(stream, "qmp_capabilities", "cpu-isolate-cap")
            result = qmp_command(stream, "query-cpus-fast", "cpu-isolate-query")
            sock.close()
            rows = sorted(
                (int(row["cpu-index"]), int(row["thread-id"]))
                for row in result
                if "cpu-index" in row and "thread-id" in row
            )
            if len(rows) == expected:
                return rows
            last_error = f"expected {expected} vCPUs, QMP returned {len(rows)}"
        except Exception as exc:
            last_error = str(exc)
        time.sleep(0.5)
    raise RuntimeError(last_error)

def tgid_for_tid(tid):
    try:
        with open(f"/proc/{tid}/status", encoding="ascii") as stream:
            for line in stream:
                if line.startswith("Tgid:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None

def valid_vm_process(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as stream:
            argv = stream.read().split(b"\0")
        for index, arg in enumerate(argv[:-1]):
            if arg == b"-name":
                value = argv[index + 1]
                name = f"vm{vm_id}".encode()
                if value == name or value.startswith(name + b","):
                    return True
    except OSError:
        pass
    return False

def pid_from_pidfile():
    try:
        with open(pid_file, encoding="ascii") as stream:
            pid = int(stream.read().strip())
        return pid if valid_vm_process(pid) else None
    except (OSError, ValueError):
        return None

def fail_required(reason, pid=None):
    write_state("failed " + reason)
    log("required 失败：" + reason)
    if mode != "required":
        return
    target = pid if pid and valid_vm_process(pid) else pid_from_pidfile()
    if target:
        log(f"required fail-closed：终止未隔离的 vm{vm_id} pid={target}")
        try:
            os.kill(target, signal.SIGTERM)
        except OSError:
            pass

cores = topology()
if len(cores) < 2:
    fail_required(f"宿主物理核不足（{len(cores)}）")
    raise SystemExit(1)

try:
    rows = query_vcpus()
except Exception as exc:
    fail_required(f"QMP query-cpus-fast 超时：{exc}")
    raise SystemExit(1)

pid = tgid_for_tid(rows[0][1])
if not pid or not valid_vm_process(pid):
    fail_required("QMP TID 无法解析到目标 QEMU")
    raise SystemExit(1)
if any(tgid_for_tid(tid) != pid for _, tid in rows):
    fail_required("QMP 返回了跨进程 vCPU TID", pid)
    raise SystemExit(1)

default_reserve = min(max(2, (len(cores) + 7) // 8), len(cores) - 1)
configured_reserve = None
if reserve_text.lower() != "auto":
    try:
        configured_reserve = int(reserve_text)
    except ValueError:
        fail_required(f"HOST_RESERVE_CORES 非法：{reserve_text}", pid)
        raise SystemExit(1)
    if configured_reserve < 0 or configured_reserve >= len(cores):
        fail_required(f"HOST_RESERVE_CORES 超界：{configured_reserve}", pid)
        raise SystemExit(1)

def placement(service_cpus):
    reserve = default_reserve if configured_reserve is None else configured_reserve
    if configured_reserve is None:
        demand = len(rows) + service_cpus
        while reserve > 1 and sum(len(core) for core in cores[reserve:]) < demand:
            reserve -= 1
    eligible = cores[reserve:]
    preference = [core[0] for core in eligible]
    preference.extend(cpu for core in eligible for cpu in core[1:])
    return reserve, preference

held_cpus = held_partition_cpus()

def available_count(preference):
    return sum(cpu not in held_cpus for cpu in preference)

reserve, preference = placement(service_count)
if service_auto:
    if available_count(preference) < len(rows) + service_count:
        service_count = 0
        reserve, preference = placement(service_count)
        log("辅助线程 CPU=auto：当前容量不足，兼容回退为 0")
    else:
        log("辅助线程 CPU=auto：分配 1 个独立逻辑 CPU")
if available_count(preference) < len(rows) + service_count:
    fail_required(
        f"预留 {reserve} 个物理核后 CPU 不足：需要 {len(rows) + service_count}，可用 {available_count(preference)}",
        pid,
    )
    raise SystemExit(1)

command = [
    helper, "apply", vm_id, str(pid),
    ",".join(map(str, preference)),
    ",".join(str(tid) for _, tid in rows),
    str(service_count),
]
try:
    result = subprocess.run(command, text=True, capture_output=True, timeout=45)
except Exception as exc:
    fail_required(f"helper 异常：{exc}", pid)
    raise SystemExit(1)
for line in result.stdout.splitlines():
    if line.strip():
        print(line, flush=True)
if result.returncode != 0:
    detail = result.stderr.strip().splitlines()
    reason = detail[-1] if detail else f"helper rc={result.returncode}"
    fail_required(reason[:300], pid)
    raise SystemExit(1)

if mode == "required":
    try:
        qmp_execute("cont", "cpu-isolate-cont")
    except Exception as exc:
        fail_required(f"隔离成功但无法启动暂停的 VM：{exc}", pid)
        raise SystemExit(1)

write_state(f"applied pid={pid}")
log(f"vm{vm_id} 隔离完成：{len(rows)} vCPU + {service_count} service CPU，host reserve={reserve} cores")
PY
    CPU_ISOLATION_PINNER_PID=$!
    return 0
}

cpu_isolation_release_vm() {
    local vm_id=$1 helper
    helper=$(cpu_isolation_helper_path)
    [[ -x "$helper" ]] || return 0
    "$helper" release "$vm_id"
}

cpu_isolation_cleanup() {
    local vm_id=$1 state_file=${2:-}
    [[ "${CPU_ISOLATION_LAUNCHED:-0}" == 1 ]] || return 0
    CPU_ISOLATION_LAUNCHED=0
    if [[ -n "${CPU_ISOLATION_PINNER_PID:-}" ]]; then
        kill "$CPU_ISOLATION_PINNER_PID" 2>/dev/null || true
        wait "$CPU_ISOLATION_PINNER_PID" 2>/dev/null || true
        CPU_ISOLATION_PINNER_PID=""
    fi
    cpu_isolation_release_vm "$vm_id" ||
        echo "[cpu-isolate] WARN: vm${vm_id} CPU 分区未能回收" >&2
    [[ -z "$state_file" ]] || rm -f -- "$state_file" "$state_file".tmp.* 2>/dev/null || true
}
