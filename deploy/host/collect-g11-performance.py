#!/usr/bin/env python3
"""Read-only G-11 host sampling; stdout never includes raw argv, env or paths."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time

PROC = Path('/proc')
SYS = Path('/sys')
HZ = os.sysconf('SC_CLK_TCK')
PAGE_KB = os.sysconf('SC_PAGE_SIZE') // 1024
GROUPS = ('main', 'vcpu', 'other')
ENV_RULES = {
    'CPU_ISOLATION': r'off|auto|required',
    'G11_HOST_PERFORMANCE': r'off|auto|required',
    'QEMU_SERVICE_CPUS': r'auto|[0-9]{1,2}',
    'QEMU_SDL_TARGET_FPS': r'[0-9]{1,4}',
    'QEMU_SDL_BACKGROUND_FPS': r'[0-9]{1,4}',
    'QEMU_SDL_INPUT_POLL_MS': r'[0-9]{1,4}',
    'QEMU_SDL_PRESENT_MODE': r'fixed|dynamic',
    'QEMU_SDL_CURSOR_MODE': r'host|guest|auto',
    'QEMU_SDL_NATIVE_EGL': r'0|1',
    'SDL_VIDEODRIVER': r'x11|wayland|dummy|offscreen',
    'G11_SDL_PROFILE': r'low-latency-v1|ultra-responsive-v1|experimental-120hz-v1|multi-vm-v1',
    'G11_SDL_WINDOW_MODE': r'native-wayland-v1',
}


def timestamp():
    return datetime.now().astimezone().isoformat(timespec='milliseconds')


def read(path, limit=4 * 1024 * 1024):
    try:
        with open(path, 'rb') as stream:
            data = stream.read(limit + 1)
        return data.decode('utf-8', 'replace') if len(data) <= limit else None
    except OSError:
        return None


def safe(value, pattern=r'[A-Za-z0-9_.:+,/-]{1,128}'):
    return value if value is not None and re.fullmatch(pattern, value) else None


def number(value):
    return int(value) if value is not None and re.fullmatch(r'[0-9]{1,20}', value) else None


def integer(path):
    value = read(path, 4096)
    return number(value.strip()) if value is not None else None


def fields(path):
    result = {}
    for line in (read(path) or '').splitlines():
        parts = line.replace(':', ' ').split()
        if len(parts) >= 2:
            result[parts[0]] = number(parts[1])
    return result


def proc_stat(path):
    raw = read(path / 'stat', 16384)
    if raw is None or ')' not in raw:
        return None
    try:
        end = raw.rindex(')')
        values = raw[end + 2:].split()
        return {'comm': raw[raw.index('(') + 1:end], 'start': int(values[19]),
                'ticks': int(values[11]) + int(values[12]),
                'minflt': int(values[7]), 'majflt': int(values[9])}
    except (ValueError, IndexError):
        return None


def identity(pid):
    stat = proc_stat(PROC / str(pid))
    try:
        exe = os.stat(PROC / str(pid) / 'exe')
        name = os.readlink(PROC / str(pid) / 'exe').removesuffix(' (deleted)')
    except OSError:
        return None
    if stat is None or not re.fullmatch(r'qemu-system-[A-Za-z0-9_-]+(?:\.g11\.real)?', Path(name).name):
        return None
    return {'pid': pid, 'start_ticks': stat['start'],
            'exe_device': exe.st_dev, 'exe_inode': exe.st_ino}


def arguments(pid):
    value = read(PROC / str(pid) / 'cmdline')
    return value.split('\0') if value is not None else []


def choose_pid(args):
    if args.pid is not None:
        return args.pid if identity(args.pid) is not None else None
    found = []
    for path in PROC.iterdir():
        if not path.name.isdigit() or identity(int(path.name)) is None:
            continue
        argv = arguments(int(path.name))
        for key, value in zip(argv, argv[1:]):
            if key == '-name' and value.split(',')[0] == 'vm' + str(args.vm):
                found.append(int(path.name))
                break
    return found[0] if len(found) == 1 else None


def digest(path):
    try:
        with open(path, 'rb') as stream:
            before = os.fstat(stream.fileno())
            value = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                value.update(block)
            after = os.fstat(stream.fileno())
        current = os.stat(path)
        stamp = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        return value.hexdigest() if stamp(before) == stamp(after) == stamp(current) else None
    except OSError:
        return None


def config(pid):
    result = {'ram_prealloc': None, 'ram_size': None, 'vcpus': None,
              'display': None, 'gl': None, 'mdev_uuid': None}
    argv = arguments(pid)
    for key, value in zip(argv, argv[1:]):
        parts = value.split(',')
        options = dict(part.split('=', 1) for part in parts if '=' in part)
        if key == '-object' and parts[0] == 'memory-backend-memfd' and options.get('id') == 'ram0':
            result['ram_prealloc'] = safe(options.get('prealloc'), r'on|off')
            result['ram_size'] = safe(options.get('size'), r'[0-9]{1,15}[KMGTkmgt]?')
        elif key == '-smp':
            result['vcpus'] = number(options.get('cpus', parts[0]))
        elif key == '-display':
            result['display'] = safe(parts[0], r'sdl|gtk|egl-headless|none')
            result['gl'] = safe(options.get('gl'), r'on|off|core|es')
        elif key == '-device' and parts[0] in ('vfio-pci', 'vfio-pci-nohotplug'):
            match = re.fullmatch(r'/sys/bus/mdev/devices/([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})', options.get('sysfsdev', ''))
            if match and options.get('display') == 'on':
                result['mdev_uuid'] = match[1]
    raw = read(PROC / str(pid) / 'environ')
    env = dict(item.split('=', 1) for item in (raw or '').split('\0') if '=' in item)
    result['environment'] = {key: safe(env.get(key), rule) for key, rule in ENV_RULES.items()}
    result['environment_readable'] = raw is not None
    try:
        target = os.readlink(PROC / str(pid) / 'exe')
        result['exe_deleted'] = target.endswith(' (deleted)')
        result['running_sha256'] = digest(PROC / str(pid) / 'exe')
        result['disk_sha256'] = digest(target.removesuffix(' (deleted)'))
    except OSError:
        result.update(exe_deleted=None, running_sha256=None, disk_sha256=None)
    hashes = (result['running_sha256'], result['disk_sha256'])
    result['matches_disk_image'] = hashes[0] == hashes[1] if all(hashes) else None
    return result


def selected(path):
    value = read(path, 4096)
    if value is None:
        return None
    match = re.search(r'\[([a-zA-Z0-9_+-]+)\]', value)
    return safe(match[1] if match else value.strip())


def fixed_info(uuid):
    policies = {}
    root = SYS / 'devices/system/cpu/cpufreq'
    for policy in sorted(root.glob('policy[0-9]*')):
        policies[policy.name] = {key: selected(policy / key) for key in
                                ('scaling_governor', 'energy_performance_preference')}
        cpus = read(policy / 'related_cpus', 16384)
        policies[policy.name]['related_cpus'] = safe(cpus.strip(), r'[0-9 ]{1,16384}') if cpus else None
        policies[policy.name].update({key: integer(policy / key) for key in
                                     ('scaling_min_freq', 'scaling_max_freq', 'cpuinfo_min_freq', 'cpuinfo_max_freq', 'scaling_cur_freq')})
    thp = SYS / 'kernel/mm/transparent_hugepage'
    version = read(SYS / 'module/nvidia/version', 4096)
    result = {'cpufreq': policies, 'boost': integer(root / 'boost'),
              'no_turbo': integer(SYS / 'devices/system/cpu/intel_pstate/no_turbo'),
              'max_perf_pct': integer(SYS / 'devices/system/cpu/intel_pstate/max_perf_pct'),
              'cpu_topology': cpu_topology(),
              'thp': {key: selected(thp / key) for key in ('enabled', 'defrag', 'shmem_enabled')},
              'swappiness': integer(PROC / 'sys/vm/swappiness'),
              'schedstats_enabled': integer(PROC / 'sys/kernel/sched_schedstats'),
              'nvidia_driver': safe(version.strip(), r'[0-9.]{1,40}') if version else None,
              'node_cpus': {path.parent.name: selected(path) for path in
                            sorted((SYS / 'devices/system/node').glob('node[0-9]*/cpulist'))},
              'mdev': {'pci': None, 'numa_node': None, 'intervaltime': None,
                       'vgaintervaltime': None, 'frame_rate_limiter': None}}
    if uuid:
        path = SYS / 'bus/mdev/devices' / uuid
        try:
            parent = path.resolve(strict=True).parent
            result['mdev']['pci'] = safe(parent.name, r'[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]')
            result['mdev']['numa_node'] = integer(parent / 'numa_node')
        except OSError:
            pass
        raw = read(path / 'nvidia/vgpu_params', 16384)
        for field in (raw or '').replace('\n', '').split(','):
            key, _, value = field.partition('=')
            if key in ('intervaltime', 'vgaintervaltime', 'frame_rate_limiter'):
                result['mdev'][key] = number(value)
    return result


def cpu_topology():
    """Count online sockets/cores rather than assuming one or two E5 CPUs."""
    root = SYS / 'devices/system/cpu'
    sockets, cores = set(), set()
    threads = 0
    complete = True
    for cpu in root.glob('cpu[0-9]*'):
        if not re.fullmatch(r'cpu[0-9]+', cpu.name):
            continue
        # CPU0 commonly has no online file because it cannot be hot-unplugged.
        if (cpu / 'online').exists() and integer(cpu / 'online') != 1:
            continue
        threads += 1
        socket = integer(cpu / 'topology/physical_package_id')
        core = integer(cpu / 'topology/core_id')
        if socket is None or core is None:
            complete = False
            continue
        sockets.add(socket)
        cores.add((socket, core))
    return {'sockets': len(sockets) if complete and threads else None,
            'physical_cores': len(cores) if complete and threads else None,
            'online_threads': threads or None}


def cgroup_limits(pid):
    """Read cgroup v2 limits at every ancestor; omit application/unit paths."""
    raw = read(PROC / str(pid) / 'cgroup', 16384)
    group = next((line[3:] for line in (raw or '').splitlines()
                  if line.startswith('0::/')), None)
    if group is None or '..' in Path(group).parts:
        return None
    root = SYS / 'fs/cgroup'
    if not (root / 'cgroup.controllers').exists():
        return None
    path = root / group.lstrip('/')
    if not path.is_dir():
        return None
    limits = []
    while True:
        quota = read(path / 'cpu.max', 4096)
        cpus = read(path / 'cpuset.cpus.effective', 16384)
        mems = read(path / 'cpuset.mems.effective', 16384)
        limits.append({
            'ancestor_level': len(limits),
            'cpu_max': safe(quota.strip(), r'(?:max|[0-9]+) [0-9]+') if quota else None,
            'cpu_weight': integer(path / 'cpu.weight'),
            'cpus_effective': safe(cpus.strip(), r'[0-9,-]+') if cpus else None,
            'mems_effective': safe(mems.strip(), r'[0-9,-]+') if mems else None,
            'memory_max': selected(path / 'memory.max'),
            'memory_high': selected(path / 'memory.high'),
        })
        if path == root:
            break
        path = path.parent
    return limits


def memory_detail(pid):
    raw = read(PROC / str(pid) / 'numa_maps', 16 * 1024 * 1024)
    ram = [] if raw is not None else None
    for line in (raw or '').splitlines():
        parts = line.split()
        mapping = next((match[1] for part in parts
                        if (match := re.fullmatch(r'file=/memfd:(ram0|memory-backend-memfd)(?:\\+040\(deleted\))?', part))), None)
        if len(parts) < 2 or mapping is None:
            continue
        nodes = {key: number(value) for part in parts if '=' in part
                 for key, value in [part.split('=', 1)] if re.fullmatch(r'N[0-9]+', key)}
        ram.append({'mapping_name': mapping, 'policy': safe(parts[1]), 'node_pages': nodes,
                    'kernel_page_kb': next((number(part.split('=')[1]) for part in parts
                                           if part.startswith('kernelpagesize_kB=')), None)})
    rollup = fields(PROC / str(pid) / 'smaps_rollup')
    affinity = {}
    try:
        for task in (PROC / str(pid) / 'task').iterdir():
            data = read(task / 'status')
            match = re.search(r'^Cpus_allowed_list:\s*([0-9,-]+)$', data or '', re.M)
            affinity[task.name] = match[1] if match else None
    except OSError:
        affinity = None
    return {'ram0_numa': ram if ram else None, 'numa_maps_readable': raw is not None,
            'thread_allowed_cpus': affinity,
            'cgroup_limits': cgroup_limits(pid),
            'rollup_kb': {key: rollup.get(key) for key in ('Rss', 'Pss', 'Swap', 'SwapPss', 'AnonHugePages', 'ShmemPmdMapped')}}


def snapshot(pid):
    tasks = {}
    schedstats_enabled = integer(PROC / 'sys/kernel/sched_schedstats')
    try:
        for path in (PROC / str(pid) / 'task').iterdir():
            stat = proc_stat(path)
            if stat is None:
                if path.exists():
                    tasks = None
                    break
                continue
            stat['group'] = 'main' if int(path.name) == pid else ('vcpu' if re.fullmatch(r'CPU [0-9]+/(KVM|TCG)', stat['comm']) else 'other')
            stat.pop('comm')
            sched = (read(path / 'schedstat', 4096) or '').split()
            stat['wait_ns'] = number(sched[1]) if len(sched) >= 2 and schedstats_enabled == 1 else None
            tasks[path.name] = stat
    except OSError:
        tasks = None
    pressure = {}
    for kind in ('cpu', 'memory', 'io'):
        raw = read(PROC / 'pressure' / kind, 4096)
        for scope in ('some', 'full'):
            match = re.search(r'^' + scope + r' .*\btotal=([0-9]+)', raw or '', re.M)
            pressure[kind + '_' + scope] = int(match[1]) if match else None
    mem = fields(PROC / 'meminfo')
    vm = fields(PROC / 'vmstat')
    io = fields(PROC / str(pid) / 'io')
    status = fields(PROC / str(pid) / 'status')
    sampled_time = time.monotonic()
    sampled_at = timestamp()
    return {'time': sampled_time, 'timestamp': sampled_at,
            'threads': tasks, 'pressure': pressure,
            'memory_kb': {key: mem.get(key) for key in ('MemAvailable', 'SwapTotal', 'SwapFree')},
            'qemu_memory_kb': {key: status.get(key) for key in ('VmRSS', 'VmSwap')},
            'vmstat': {key: vm.get(key) for key in ('pgfault', 'pgmajfault', 'pswpin', 'pswpout')},
            'io': {key: io.get(key) for key in ('read_bytes', 'write_bytes')}}


def delta(after, before):
    return after - before if after is not None and before is not None and after >= before else None


def total(values):
    return sum(values) if all(value is not None for value in values) else None


def interval(before, after):
    seconds = after['time'] - before['time']
    groups = {group: {key: None for key in ('cpu_pct', 'wait_ms', 'minflt', 'majflt')} for group in GROUPS}
    old, new = before['threads'], after['threads']
    covered = None
    peak_vcpu = None
    if old is not None and new is not None:
        common = [key for key in old.keys() & new.keys() if old[key]['start'] == new[key]['start']]
        covered = len(common) == len(old) == len(new)
        vcpu_ticks = [delta(new[key]['ticks'], old[key]['ticks']) for key in common
                      if new[key]['group'] == 'vcpu']
        peak_vcpu = max((round(value * 100 / HZ / seconds, 3)
                         for value in vcpu_ticks if value is not None), default=None)
        for group in GROUPS:
            keys = [key for key in common if new[key]['group'] == group]
            for field, target, scale in (('ticks', 'cpu_pct', 100 / HZ / seconds),
                                         ('wait_ns', 'wait_ms', 1e-6), ('minflt', 'minflt', 1), ('majflt', 'majflt', 1)):
                value = total([delta(new[key][field], old[key][field]) for key in keys])
                groups[group][target] = round(value * scale, 3) if value is not None else None
    return {'timestamp': after['timestamp'], 'elapsed_seconds': round(seconds, 3),
            'threads_complete': covered, 'groups': groups, 'peak_vcpu_thread_pct': peak_vcpu,
            'io_bytes': {key: delta(after['io'][key], before['io'][key]) for key in after['io']},
            'vmstat': {key: delta(after['vmstat'][key], before['vmstat'][key]) for key in after['vmstat']},
            'psi_stall_us': {key: delta(after['pressure'][key], before['pressure'][key]) for key in after['pressure']},
            'memory_kb': after['memory_kb'], 'qemu_memory_kb': after['qemu_memory_kb']}


def show(value, scale=1):
    if isinstance(value, bool):
        return 'yes' if value else 'no'
    return 'unknown' if value is None else f'{value / scale:.1f}' if isinstance(value, (int, float)) else str(value)


def main():
    parser = argparse.ArgumentParser(description='只读采样 G-11 宿主性能；不改 VM/驱动，不输出原始命令行或环境。')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--vm', type=int, help='唯一运行的 VM 编号')
    group.add_argument('--pid', type=int, help='运行中的 QEMU PID')
    parser.add_argument('--seconds', type=int, default=60, help='采样秒数，1–3600，默认 60')
    parser.add_argument('--output', help='可选 JSON 文件；必须不存在，目录须可写')
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600 or (args.vm or args.pid or 0) <= 0:
        parser.error('VM/PID 必须为正整数，seconds 必须为 1–3600')
    if args.output and os.path.lexists(args.output):
        print('JSON 输出文件已存在；请换一个文件名，未开始采样。', file=sys.stderr)
        return 1
    pid = choose_pid(args)
    original = identity(pid) if pid is not None else None
    if original is None:
        print('无法唯一确认运行中的 QEMU；请检查 VM/PID 或 /proc 读取权限。', file=sys.stderr)
        return 2
    launch = config(pid)
    report = {'schema': 1, 'identity': original, 'config': launch,
              'fixed': fixed_info(launch['mdev_uuid']), 'before': memory_detail(pid),
              'samples': [], 'stop_reason': 'completed'}
    if identity(pid) != original:
        print('准备期间 QEMU 已退出、身份变化或失去读取权限；请重新选择运行中的进程。', file=sys.stderr)
        return 3
    print(f"PID={pid} start_ticks={original['start_ticks']} prealloc={show(launch['ram_prealloc'])} RAM={show(launch['ram_size'])} vCPU={show(launch['vcpus'])} SDL={show(launch['display'])} CPU隔离={show(launch['environment']['CPU_ISOLATION'])}", flush=True)
    print(f"运行映像 SHA256={show(launch['running_sha256'])} 与磁盘一致={show(launch['matches_disk_image'])}", flush=True)
    fixed = report['fixed']
    print('宿主 NVIDIA=' + show(fixed['nvidia_driver']) + ' mdev=' + json.dumps(fixed['mdev'], ensure_ascii=False) + ' THP=' + json.dumps(fixed['thp']) + ' swappiness=' + show(fixed['swappiness']), flush=True)
    print('RAM NUMA=' + json.dumps(report['before']['ram0_numa']) + ' cpufreq策略数=' + str(len(fixed['cpufreq'])) + ' schedstats=' + show(fixed['schedstats_enabled']), flush=True)
    print('宿主 CPU=' + json.dumps(fixed['cpu_topology']) + ' Intel全局上限=' + show(fixed['max_perf_pct']) + '%', flush=True)
    affinities = report['before']['thread_allowed_cpus']
    print('线程可用CPU=' + json.dumps(sorted(set(affinities.values()) - {None}) if affinities else None)
          + ' cgroup限制=' + json.dumps(report['before']['cgroup_limits']), flush=True)
    print('先静止约 10 秒，再重现启动/切画面卡顿，随后重复同一操作。unknown 表示无法读取；采样不证明源画面帧率。', flush=True)
    before = snapshot(pid)
    if identity(pid) != original:
        print('建立基线时 QEMU 身份变化或无法读取，采样已停止。', file=sys.stderr)
        return 3
    started = before['time']
    report['started_at'] = before['timestamp']
    print('采样开始 started_at=' + report['started_at'], flush=True)
    try:
        for count in range(1, args.seconds + 1):
            time.sleep(max(0, started + count - time.monotonic()))
            if identity(pid) != original:
                report['stop_reason'] = 'process_changed_or_unreadable'
                break
            after = snapshot(pid)
            if identity(pid) != original:
                report['stop_reason'] = 'process_changed_or_unreadable'
                break
            row = interval(before, after)
            row['second'] = round(after['time'] - started, 3)
            report['samples'].append(row)
            faults = {key: total([row['groups'][group][key] for group in GROUPS]) for key in ('minflt', 'majflt')}
            cpu = '/'.join(show(row['groups'][group]['cpu_pct']) for group in GROUPS)
            print(f"t={row['second']:.1f}s timestamp={row['timestamp']} CPU主/vCPU/其他={cpu}% 单vCPU峰值={show(row['peak_vcpu_thread_pct'])}% 主线程排队={show(row['groups']['main']['wait_ms'])}ms 缺页minor/major={show(faults['minflt'])}/{show(faults['majflt'])} 读盘={show(row['io_bytes']['read_bytes'], 1048576)}MiB swap入/出={show(row['vmstat']['pswpin'], 1024 / PAGE_KB)}/{show(row['vmstat']['pswpout'], 1024 / PAGE_KB)}MiB CPU/内存/IO停顿={show(row['psi_stall_us']['cpu_some'], 1000)}/{show(row['psi_stall_us']['memory_some'], 1000)}/{show(row['psi_stall_us']['io_some'], 1000)}ms", flush=True)
            before = after
    except KeyboardInterrupt:
        report['stop_reason'] = 'interrupted'
    report['after'] = memory_detail(pid) if identity(pid) == original else None
    if identity(pid) != original:
        report['after'] = None
        report['stop_reason'] = 'process_changed_or_unreadable'
    report['finished_at'] = timestamp()
    rows = report['samples']
    summary = {'samples': len(rows), 'stop_reason': report['stop_reason'],
               'started_at': report['started_at'], 'finished_at': report['finished_at'],
               'ram_prealloc': launch['ram_prealloc'],
               'cpu_isolation': launch['environment']['CPU_ISOLATION'],
               'thread_coverage_complete': all(row['threads_complete'] is True for row in rows) if rows else None,
               'peak_main_cpu_pct': max((row['groups']['main']['cpu_pct'] for row in rows
                                         if row['groups']['main']['cpu_pct'] is not None), default=None),
               'peak_vcpu_thread_pct': max((row['peak_vcpu_thread_pct'] for row in rows
                                            if row['peak_vcpu_thread_pct'] is not None), default=None),
               'cpu_psi_some_us': total([row['psi_stall_us']['cpu_some'] for row in rows]) if rows else None,
               'qemu_read_mib': total([row['io_bytes']['read_bytes'] for row in rows]) if rows else None,
               'swapin_pages': total([row['vmstat']['pswpin'] for row in rows]) if rows else None,
               'minor_faults': total([row['groups'][group]['minflt'] for row in rows for group in GROUPS]) if rows else None,
               'memory_psi_some_us': total([row['psi_stall_us']['memory_some'] for row in rows]) if rows else None,
               'io_psi_some_us': total([row['psi_stall_us']['io_some'] for row in rows]) if rows else None,
               'major_faults': total([row['groups'][group]['majflt'] for row in rows for group in GROUPS]) if rows else None}
    if summary['qemu_read_mib'] is not None:
        summary['qemu_read_mib'] = round(summary['qemu_read_mib'] / 1048576, 3)
    report['summary'] = summary
    print('SUMMARY ' + json.dumps(summary, ensure_ascii=False, allow_nan=False), flush=True)
    if report['stop_reason'] != 'completed':
        print('采样已提前停止；进程退出、身份变化或权限丢失后，不继续归属指标。', flush=True)
    if args.output:
        try:
            fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)
                stream.write('\n')
        except OSError:
            print('无法创建 JSON 文件；文件须不存在且目录可写。终端 SUMMARY 仍可使用。', file=sys.stderr)
            return 1
    return 0 if report['stop_reason'] == 'completed' else 3


if __name__ == '__main__':
    sys.exit(main())
