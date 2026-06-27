# ---------------------------------------------------------------------------
# sv-cpupin.sh —— (默认开) 起 VM 后把 vCPU 钉进 cgroup cpuset 独占分区, 与宿主机
# 负载(尤其 cargo/rust 这类吃满全核的编译)在调度层隔离。提供函数
# sv_cpu_isolate_launch, 由 sv-assemble.sh 在 launching 段(QEMU 即将 exec 前)调用。
#
# 为什么放后台: start-vm 最终 exec 进 QEMU, 本函数无法在同进程里等 QEMU 起来;
# 真正的绑核要等 QMP 能查到 vCPU 线程号, 所以 fork 一个后台 pinner(与 ISO
# auto-key / hotkey-capture 同款 `&` 模式), 它轮询 QMP 拿到 vCPU tid 后再调
# host-cpu-isolate.sh(sudo NOPASSWD) 做 cpuset 分区 + 1:1 绑核。若启动时传
# QEMU_SERVICE_CPUS / QEMU_SVC_CPUS / --svc-cpus=N，则额外给 QEMU 非 vCPU 辅助线程
# 分配专用逻辑 CPU，避免 fb-shm/SDL/IO 路径和满载 vCPU 抢调度。
#
# 关 / 调: CPU_ISOLATE=0 或 --no-cpu-isolate。DRY_RUN 下不会被调用(sv-assemble 在
# DRY_RUN 早退), 这里再做一层防御式 no-op。失败一律 `|| true`, 绝不阻断 VM。
# ---------------------------------------------------------------------------

sv_cpu_isolate_launch() {
    [[ "${CPU_ISOLATE:-1}" == "1" ]] || return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    local _helper="$HERE/host-cpu-isolate.sh"
    [[ -x "$_helper" ]] || { echo ">> CPU 隔离:   ⚠ 找不到 $_helper, 跳过" >&2; return 0; }

    echo ">> CPU 隔离:   后台 pinner 已起 — 等 vCPU 线程就绪后钉进 cpuset 独占分区(与宿主机编译隔离)"

    # 后台 pinner: 轮询 QMP 拿 vCPU 线程号 → 算 VM 专属物理核 → 调 root 助手。
    # exec 后它成为 QEMU 的子进程, 共享同一终端 stdout(与现有后台守护一致); 一次性,
    # 钉完即退。所有失败都打到 stderr 且不影响 QEMU。
    python3 - "$INSTANCE" "${CPUS:-4}" "$QMP_SOCK" "$_helper" "${QEMU_SERVICE_CPUS:-0}" <<'PY' &
import json, os, socket, subprocess, sys, time

instance, cpus, qmp_sock, helper = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
try:
    service_cpus_arg = max(0, int(sys.argv[5] if len(sys.argv) > 5 else "0"))
except ValueError:
    service_cpus_arg = 0

def log(msg):
    print(f">> CPU 隔离:   {msg}", flush=True)

def expand_list(s):
    """'4,12' or '4-5,8' -> sorted [int,...]"""
    out = []
    for part in s.strip().split(','):
        if not part:
            continue
        if '-' in part:
            a, b = part.split('-', 1)
            out += list(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))

def host_topology():
    """返回按主逻辑核升序的物理核列表: [(primary, [siblings...]), ...]"""
    cores = {}  # key=兄弟集合签名 -> [siblings]
    base = "/sys/devices/system/cpu"
    for name in os.listdir(base):
        f = os.path.join(base, name, "topology", "thread_siblings_list")
        try:
            with open(f) as fh:
                sibs = tuple(expand_list(fh.read()))
        except OSError:
            continue
        if sibs:
            cores[sibs] = list(sibs)
    ordered = sorted(cores.values(), key=lambda s: s[0])  # 按主(最小)逻辑核排
    return ordered

def read_mems():
    for p in ("/sys/fs/cgroup/cpuset.mems.effective", "/sys/fs/cgroup/cpuset.mems"):
        try:
            with open(p) as fh:
                v = fh.read().strip()
                if v:
                    return v
        except OSError:
            pass
    return "0"

def query_vcpus(sock_path, timeout=90):
    """轮询 QMP query-cpus-fast, 拿到 [(cpu-index, thread-id), ...]。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(5)
            s.connect(sock_path)
            f = s.makefile("rw")
            json.loads(f.readline())  # greeting
            f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
            json.loads(f.readline())
            f.write(json.dumps({"execute": "query-cpus-fast"}) + "\n"); f.flush()
            resp = json.loads(f.readline())
            s.close()
            ret = resp.get("return")
            if ret:
                vcpus = [(c["cpu-index"], c["thread-id"]) for c in ret if "thread-id" in c]
                if vcpus:
                    return sorted(vcpus)
        except Exception:
            pass
        time.sleep(1)
    return []

def tgid_of(tid):
    try:
        with open(f"/proc/{tid}/status") as fh:
            for line in fh:
                if line.startswith("Tgid:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None

def read_cgroup_cpu_set(name):
    """读取 vmiso 当前 effective CPU 集合；缺失时返回空集，表示无法判定完整分区。"""
    path = f"/sys/fs/cgroup/{name}/cpuset.cpus.effective"
    try:
        with open(path) as fh:
            value = fh.read().strip()
    except OSError:
        return set()
    return set(expand_list(value)) if value else set()

def read_held_isolated_cpus(current_pid=None):
    """读取已被其它 VM 显式 taskset 收窄过的 CPU。

    旧版只有 vCPU 单核绑定；启用 QEMU_SERVICE_CPUS 后，辅助线程会被绑到
    1 个或多个专用 CPU。这里把“严格小于整个 vmiso 分区”的 affinity 都视为
    已占用；而旧版 QEMU main/worker 的完整分区 affinity 会被忽略，避免把
    整个分区误判为已占满。
    """
    held = set()
    name = os.environ.get("VMISO_NAME", "vmiso") or "vmiso"
    cgroup_cpus = read_cgroup_cpu_set(name)
    procs = f"/sys/fs/cgroup/{name}/cgroup.procs"
    try:
        with open(procs) as fh:
            pids = [line.strip() for line in fh if line.strip()]
    except OSError:
        return held
    for pid_text in pids:
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if current_pid is not None and pid == current_pid:
            continue
        task_dir = f"/proc/{pid}/task"
        try:
            tids = os.listdir(task_dir)
        except OSError:
            continue
        for tid in tids:
            status = os.path.join(task_dir, tid, "status")
            try:
                with open(status) as fh:
                    for line in fh:
                        if line.startswith("Cpus_allowed_list:"):
                            allowed = line.split()[1]
                            allowed_set = set(expand_list(allowed))
                            if allowed_set and (not cgroup_cpus or allowed_set != cgroup_cpus):
                                held.update(allowed_set)
                            break
            except OSError:
                continue
    return held

topo = host_topology()
total_phys = len(topo)
if total_phys < 2:
    log(f"⚠ 物理核数={total_phys}, 太少无法隔离, 跳过")
    sys.exit(0)

vcpus = query_vcpus(qmp_sock)
if not vcpus:
    log("⚠ 等不到 vCPU 线程(QMP 无响应/超时), 跳过绑核")
    sys.exit(0)

pid = tgid_of(vcpus[0][1])
if not pid:
    log("⚠ 取 QEMU pid 失败, 跳过")
    sys.exit(0)

# 线程级隔离: VM 的每个 vCPU 只吃 1 个逻辑线程(不是整颗物理核)。一台 4vCPU 的 VM
# 只占 4 个逻辑核, 宿主机保留其余 12 个(含这 4 核的 SMT 兄弟)。代价: 宿主机用到
# 那些兄弟线程时与 vCPU 共享物理核执行单元(SMT 争用, 只掉吞吐不掉调度)——但 vCPU
# 仍独占自己的逻辑线程、永不被宿主机抢占, 卡顿/掉帧问题照样解决。
#
# 分配优先序(pref): 先遍历所有可用物理核的第一个逻辑线程，只有这些主线程全部
# 被在跑 VM 占完后，才开始使用 SMT 兄弟线程。这样双开/多开时会先横向铺到不同
# 物理核心上，避免 VM2 抢 VM1 的同核 sibling 导致 DNF 帧率从 60Hz 掉到 20~30Hz。
# 默认给宿主机预留一小段物理核心，避免桌面、VMate、OCR、日志和管理任务与 VM
# 抢同一批核心。规则：至少 2 个物理核心，约等于总物理核心的 12.5%。
# 如果当前多开需求已超过预留后的物理核心数，自动缩小预留，优先保证 VM 横向铺到
# 不同物理核心；需要硬保留时显式设置 HOST_RESERVE_CORES=N。
reserve_default = min(max(2, (total_phys + 7) // 8), total_phys - 1)
reserve_raw = os.environ.get("HOST_RESERVE_CORES")
service_cpus = service_cpus_arg
held_cpus = read_held_isolated_cpus(pid)
demand = len(held_cpus) + len(vcpus) + service_cpus

def pool_size_after_reserve(reserve_count):
    """reserve_count 是物理核数；返回剩余物理核包含的逻辑 CPU 数。"""
    return sum(len(core) for core in topo[reserve_count:])

if reserve_raw is None or reserve_raw.strip() == "" or reserve_raw.strip().lower() == "auto":
    reserve = reserve_default
    while reserve > 0 and pool_size_after_reserve(reserve) < demand:
        reserve -= 1
else:
    try:
        reserve = max(0, min(int(reserve_raw), total_phys - 1))
    except ValueError:
        reserve = reserve_default
        while reserve > 0 and pool_size_after_reserve(reserve) < demand:
            reserve -= 1
eligible = topo[reserve:]                         # 砍掉最低 reserve 颗核(永久留宿主机)
if not eligible:
    log(f"⚠ 物理核全保留给宿主机(reserve={reserve}), 跳过隔离")
    sys.exit(0)
pref = ([c[0] for c in eligible]                  # tier1: 所有可用物理核的主线程
        + [s for c in eligible for s in c[1:]])   # tier2: 主线程耗尽后才使用 SMT 兄弟
pref_str = ",".join(str(x) for x in pref)
mems = read_mems()

tids_str = ",".join(str(tid) for _idx, tid in vcpus)

service_note = f", QEMU 辅助线程预留 {service_cpus} 个逻辑 CPU" if service_cpus else ""
total_logical = sum(len(core) for core in topo)
log(f"vCPU 线程就绪(pid={pid}, {len(vcpus)} vCPU); 线程级隔离: 本台 vCPU 占 {len(vcpus)} 个逻辑线程"
    f"{service_note}, 当前隔离需求 {demand}/{total_logical} 逻辑 CPU, 预留 {reserve} 颗物理核, "
    f"分配池 {len(pref)} 个逻辑 CPU")

try:
    r = subprocess.run(["sudo", "-n", helper, "apply", mems, str(pid), pref_str, tids_str, str(service_cpus)],
                       capture_output=True, text=True, timeout=30)
    for line in (r.stdout or "").splitlines():
        line = line.strip()
        if line:
            print(line, flush=True)
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        log(f"⚠ root 助手返回 {r.returncode}: {err[:200]}")
        log("   (若是免密 sudo 未配: 见 /etc/sudoers.d/qemu-cpuiso; 或 CPU_ISOLATE=0 关)")
except Exception as e:
    log(f"⚠ 调 root 助手异常: {e}")
PY
    return 0
}
