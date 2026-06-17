# ---------------------------------------------------------------------------
# sv-cpupin.sh —— (默认开) 起 VM 后把 vCPU 钉进 cgroup cpuset 独占分区, 与宿主机
# 负载(尤其 cargo/rust 这类吃满全核的编译)在调度层隔离。提供函数
# sv_cpu_isolate_launch, 由 sv-assemble.sh 在 launching 段(QEMU 即将 exec 前)调用。
#
# 为什么放后台: start-vm 最终 exec 进 QEMU, 本函数无法在同进程里等 QEMU 起来;
# 真正的绑核要等 QMP 能查到 vCPU 线程号, 所以 fork 一个后台 pinner(与 ISO
# auto-key / hotkey-capture 同款 `&` 模式), 它轮询 QMP 拿到 vCPU tid 后再调
# host-cpu-isolate.sh(sudo NOPASSWD) 做 cpuset 分区 + 1:1 绑核。
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
    python3 - "$INSTANCE" "${CPUS:-4}" "$QMP_SOCK" "$_helper" <<'PY' &
import json, os, socket, subprocess, sys, time

instance, cpus, qmp_sock, helper = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

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

topo = host_topology()
total_phys = len(topo)
if total_phys < 2:
    log(f"⚠ 物理核数={total_phys}, 太少无法隔离, 跳过")
    sys.exit(0)

# 线程级隔离: VM 的每个 vCPU 只吃 1 个逻辑线程(不是整颗物理核)。一台 4vCPU 的 VM
# 只占 4 个逻辑核, 宿主机保留其余 12 个(含这 4 核的 SMT 兄弟)。代价: 宿主机用到
# 那些兄弟线程时与 vCPU 共享物理核执行单元(SMT 争用, 只掉吞吐不掉调度)——但 vCPU
# 仍独占自己的逻辑线程、永不被宿主机抢占, 卡顿/掉帧问题照样解决。
#
# 分配优先序(pref): 先「最高的 cpus 颗物理核的主线程」(让单台 VM 落在各不相同的
# 物理核上, 自身无 SMT 争用) → 再这些核的兄弟线程(给第二台 VM) → 再往下一档物理核。
# 宿主机至少保留 HOST_RESERVE_CORES(默认 2) 颗最低编号物理核, 任何情况下不被 VM 吃。
reserve = 2
try:
    reserve = max(0, min(int(os.environ.get("HOST_RESERVE_CORES", "2") or 2), total_phys - 1))
except ValueError:
    reserve = 2
eligible = topo[reserve:]                         # 砍掉最低 reserve 颗核(永久留宿主机)
if not eligible:
    log(f"⚠ 物理核全保留给宿主机(reserve={reserve}), 跳过隔离")
    sys.exit(0)
g = min(cpus, len(eligible))                      # 优先用作「各不同物理核」的核数
top_cores  = eligible[-g:]                        # 最高的 g 颗 → 主线程优先池
rest_cores = eligible[:-g]
pref = ([c[0] for c in top_cores]                 # tier1: top 核主线程(单台落各异物理核)
        + [s for c in top_cores  for s in c[1:]]  # tier2: top 核兄弟线程(第二台落这)
        + [c[0] for c in rest_cores]              # tier3: 下一档核主线程
        + [s for c in rest_cores for s in c[1:]]) # tier4: 下一档核兄弟线程
pref_str = ",".join(str(x) for x in pref)
mems = read_mems()

vcpus = query_vcpus(qmp_sock)
if not vcpus:
    log("⚠ 等不到 vCPU 线程(QMP 无响应/超时), 跳过绑核")
    sys.exit(0)

pid = tgid_of(vcpus[0][1])
if not pid:
    log("⚠ 取 QEMU pid 失败, 跳过")
    sys.exit(0)

tids_str = ",".join(str(tid) for _idx, tid in vcpus)

log(f"vCPU 线程就绪(pid={pid}, {len(vcpus)} vCPU); 线程级隔离: 本台只占 {len(vcpus)} 个逻辑线程, "
    f"宿主机保留其余 {total_phys * 2 - len(vcpus)} 个(含 SMT 兄弟), 永久保留 {reserve} 颗物理核")

try:
    r = subprocess.run(["sudo", "-n", helper, "apply", mems, str(pid), pref_str, tids_str],
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
