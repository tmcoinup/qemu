#!/usr/bin/env python3
"""Offline RTX 2080/R535 equal-pool GPU replacement with a reversible journal."""

import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile


DEPLOY = Path(__file__).resolve().parents[1]
GPU_FIELDS = (
    "GPU_PROFILE VGPU_MDEV_PROFILE VGPU_FB_MB GPU_NAME GPU_PCI_VID GPU_PCI_DID "
    "GPU_SUB_VID GPU_SUB_DID GPU_REV GPU_VRAM_MB GPU_VBIOS GPU_CORE_MHZ "
    "GPU_BOOST_MHZ GPU_MEMORY_MHZ GPU_MEMORY_BUS_BITS GPU_MEMORY_BANDWIDTH_MBPS "
    "GPU_MEMORY_TYPE GPU_MEMORY_MAKER GPU_MEMORY_TYPE_NVAPI GPU_MEMORY_MAKER_NVAPI "
    "GPU_CUDA_CORES GPU_SHADER_SUBPIPES GPU_ROP_COUNT GPU_TMU_COUNT "
    "GPU_ARCHITECTURE GPU_IMPLEMENTATION GPU_CHIP_REVISION GPU_PCIE_WIDTH"
).split()
HOST_FIELDS = "VGPU_HOST_FB_TIER_MB VGPU_RESOURCE_PROFILE VGPU_RESOURCE_FB_MB".split()
ASSIGNMENT = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plain(path, directory=False):
    path = Path(path).absolute()
    require(path.resolve(strict=True) == path, f"拒绝符号链接路径: {path}")
    require(path.is_dir() if directory else path.is_file(), f"路径类型错误: {path}")
    return path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse(data):
    values = {}
    for line in data.decode("utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = ASSIGNMENT.fullmatch(line)
        require(match is not None, "配置必须只包含 KEY=literal 赋值及注释")
        key, raw = match.groups()
        require(key not in values, f"配置有重复键: {key}")
        require(not any(char in raw for char in ("$", "`", "\x00")),
                f"配置含动态表达式: {key}")
        words = shlex.split(raw, comments=True)
        require(len(words) == 1, f"配置不是单个字面值: {key}")
        values[key] = words[0]
    return values


def untouched(data, fields):
    return b"".join(line for line in data.splitlines(keepends=True)
                    if line.split(b"=", 1)[0].decode("utf-8") not in fields)


def config_value(value):
    # vm.conf is a restricted literal format, not an arbitrary shell command.
    # The lifecycle parser permits bare tokens and unescaped double quotes;
    # shlex.quote() instead emits single quotes for GPU names and VBIOS strings.
    require(value and value.isprintable()
            and not any(char in value for char in ('"', "\\", "$", "`")),
            "显卡值不能安全表示为 vm.conf 字面值")
    if re.fullmatch(r"[-A-Za-z0-9_./:+,]+", value):
        return value
    return '"' + value + '"'


def replace(data, updates):
    old = parse(data)
    require(updates.keys() <= old.keys(), "配置缺少必要的显卡/宿主档位字段")
    lines = []
    for line in data.decode("utf-8").splitlines(keepends=True):
        key = line.split("=", 1)[0]
        # Also repair legacy single-quoted GPU fields when the selected card
        # is already correct. Other fields and already-valid quoting stay exact.
        legacy_quote = key in GPU_FIELDS and line.startswith(key + "='")
        if key in updates and (old[key] != updates[key] or legacy_quote):
            newline = "\r\n" if line.endswith("\r\n") else "\n"
            line = f"{key}={config_value(updates[key])}{newline}"
        lines.append(line)
    result = "".join(lines).encode("utf-8")
    require(untouched(data, updates) == untouched(result, updates),
            "非显卡内容发生变化，拒绝发布")
    return result


def validate_vm_configs(entries):
    """Use the launcher's actual parser before accepting generated VM files."""
    script = '''set -euo pipefail
source "$1/lib/identity-uniqueness.sh"
shift
declare -A parsed=()
for config in "$@"; do
    if ! _g11_identity_uniqueness_parse_config "$config" parsed; then
        printf '%s\\n' "$G11_IDENTITY_UNIQUENESS_MESSAGE" >&2
        exit 2
    fi
done
'''
    with tempfile.TemporaryDirectory(prefix="g11-gpu-parse-") as folder:
        configs = []
        for index, entry in enumerate(entries):
            if entry["kind"] != "vm":
                continue
            config = Path(folder) / f"vm-{index}.conf"
            config.write_bytes(entry["after"])
            configs.append(str(config))
        result = subprocess.run(["bash", "-c", script, "resize-validate", str(DEPLOY),
                                 *configs], stderr=subprocess.PIPE, text=True)
        require(result.returncode == 0, "配置与启动器不兼容: " + result.stderr.strip())


def normalized_gpu_quotes(data):
    values = parse(data)
    return replace(data, {key: values[key] for key in GPU_FIELDS if key in values})


def profile(key):
    require(re.fullmatch(r"[a-z0-9_]+", key), "显卡 profile 名称非法")
    # Execute only our catalog, never source a VM or host configuration.
    script = '''set -euo pipefail
source "$1/lib/vgpu-profiles.sh"
vgpu_profile_validate_catalog
vgpu_profile_load "$2"
if vgpu_profile_is_legacy "$2"; then exit 2; fi
VGPU_FB_MB=$GPU_VRAM_MB
shift 2
for field in "$@"; do printf '%s\\0' "${!field}"; done
'''
    result = subprocess.run(["bash", "-c", script, "resize-catalog", str(DEPLOY),
                             key, *GPU_FIELDS], check=True, stdout=subprocess.PIPE)
    values = result.stdout.decode().split("\0")[:-1]
    require(len(values) == len(GPU_FIELDS), "显卡目录输出不完整")
    return dict(zip(GPU_FIELDS, values))


def equivalent(actual, expected):
    return actual == expected or (
        actual.lower().startswith("0x") and expected.lower().startswith("0x")
        and actual.lower() == expected.lower())


def change(path, data, kind):
    path = plain(path)
    before = path.read_bytes()
    info = path.stat()
    allowed = GPU_FIELDS if kind == "vm" else HOST_FIELDS
    require(untouched(before, allowed) == untouched(data, allowed),
            f"非显卡字段发生变化: {path}")
    return {"path": str(path), "kind": kind, "before": before, "after": data,
            "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}


def plan(root, targets, hosts):
    root = plain(root, directory=True)
    require(targets and hosts, "必须指定至少一台 --vm 和实际使用的 --host-config")
    selected = {}
    for target in targets:
        vm_id, separator, key = target.partition(":")
        require(separator and re.fullmatch(r"[1-9][0-9]{0,9}", vm_id)
                and int(vm_id) <= 2147483647, "--vm 格式为 ID:PROFILE")
        require(vm_id not in selected, f"VM {vm_id} 重复")
        selected[vm_id] = profile(key)
    tiers = {gpu["GPU_VRAM_MB"] for gpu in selected.values()}
    require(len(tiers) == 1, "equal 池所有目标必须同一显存档")
    tier = tiers.pop()
    resource = {"1024": "nvidia-256", "2048": "nvidia-257"}[tier]
    changes, policies = [], []
    for host in dict.fromkeys(str(Path(p).absolute()) for p in hosts):
        host = plain(host)
        data = host.read_bytes()
        policy = parse(data)
        require(policy.get("VGPU_HOST_FB_MODE") == "equal"
                and policy.get("VGPU_RESOURCE_PROFILE") in ("nvidia-256", "nvidia-257")
                and policy.get("VGPU_HOST_FB_TIER_MB") in ("1024", "2048")
                and policy.get("VGPU_RESOURCE_FB_MB") == policy["VGPU_HOST_FB_TIER_MB"]
                and policy["VGPU_RESOURCE_PROFILE"] ==
                {"1024": "nvidia-256", "2048": "nvidia-257"}[policy["VGPU_HOST_FB_TIER_MB"]]
                and policy.get("SPOOF_MODE") == "B", "仅支持 RTX/R535 的 B/equal 池")
        changes.append(change(host, replace(data, dict(zip(HOST_FIELDS,
                              (tier, resource, tier)))), "host"))
        policies.append(policy)
    bdfs = {p.get("VGPU_MGPU", "") for p in policies}
    require(len({p["VGPU_HOST_FB_TIER_MB"] for p in policies}) == 1,
            "各启动入口的原始显存档不一致，请先核对实际宿主配置")
    require(len(bdfs) == 1 and re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]",
                                         next(iter(bdfs))), "宿主配置指向不同/无效 GPU")
    fleet = sorted(p for p in root.iterdir() if re.fullmatch(r"[1-9][0-9]*", p.name))
    for instance in fleet:
        conf = plain(instance / "vm.conf")
        data = conf.read_bytes()
        values = parse(data)
        require(values.get("VM_ID") == instance.name
                and values.get("G11_HARDWARE_CONTRACT_VERSION") == "3",
                f"VM {instance.name} 不是完整 G-11 配置")
        if instance.name in selected:
            require(values.get("SPOOF_MODE") == "B"
                    and values.get("VGPU_IDENTITY_TARGET") == "name-only"
                    and values.get("VGPU_SIGNED_CONSUMER_STATE", "none") == "none",
                    "仅支持 B/name-only 已有 VM")
            require(not any(k.startswith("GPU_") and k not in GPU_FIELDS for k in values),
                    f"VM {instance.name} 含本封装未审核的额外 GPU 字段")
            old_gpu = profile(values["GPU_PROFILE"])
            require(all(equivalent(values.get(k, ""), v) for k, v in old_gpu.items()),
                    f"VM {instance.name} 原显卡字段不符合完整目录")
            updated = replace(data, selected[instance.name])
            changes.append(change(conf, updated, "vm"))
        else:
            require(values.get("GPU_VRAM_MB") == tier and values.get("VGPU_FB_MB") == tier,
                    f"VM {instance.name} 仍是其它容量；equal 池必须整池同档")
    require(set(selected) <= {p.name for p in fleet}, "指定的 VM 不存在")
    require(all(len(fleet) * int(tier) <= int(p.get("VGPU_TOTAL_FB_MB", "0"))
                for p in policies), "整池目标显存超出宿主配置容量")
    validate_vm_configs(changes)
    return {"root": str(root), "vm_ids": sorted(selected, key=int),
            "bdf": bdfs.pop(), "tier": tier, "resource": resource,
            "count": len(fleet), "changes": changes}


class Runtime:
    """Real host paths; tests inject an isolated Runtime without CLI bypasses."""
    proc = Path("/proc")
    devices = Path("/sys/bus/mdev/devices")
    pci = Path("/sys/bus/pci/devices")
    version = Path("/sys/module/nvidia/version")
    host_lock = Path("/opt/nvidia-modes/state/current")

    def check(self, proposal):
        require(self.version.read_text().strip() == "535.161.05",
                "本封装仅审核 RTX 2080 + host 535.161.05，不用于 V100/R570")
        gpu = self.pci / proposal["bdf"]
        require((gpu / "vendor").read_text().strip() == "0x10de"
                and (gpu / "device").read_text().strip() in ("0x1e82", "0x1e87"),
                "目标物理 GPU 不是 RTX 2080")
        require(not list(self.devices.iterdir()), "有活动 mdev，先正常关闭全部 GPU VM")
        for process in self.proc.glob("[0-9]*/cmdline"):
            try:
                argv = process.read_bytes().split(b"\0")
            except FileNotFoundError:
                continue
            if argv and b"qemu-system-" in argv[0].rsplit(b"/", 1)[-1]:
                raise ValueError(f"QEMU PID {process.parent.name} 尚未退出，拒绝切档")
        mdev = gpu / "mdev_supported_types" / proposal["resource"]
        description = (mdev / "description").read_text()
        require(re.search(r"\bframebuffer=" + proposal["tier"] + r"M\b", description),
                "sysfs 实际 framebuffer 与目标档位不一致")
        require(int((mdev / "available_instances").read_text()) >= proposal["count"],
                "目标 mdev 可用实例数不足")

    @contextlib.contextmanager
    def locks(self, proposal):
        root = Path(proposal["root"])
        paths = [root / "control/.storage.lock", root / "control/.identity.lock"]
        for vm_id in proposal["vm_ids"]:
            paths += [root / vm_id / "run/start.lock", root / vm_id / "run/disk.lock"]
        paths.append(self.host_lock)
        with contextlib.ExitStack() as stack:
            for path in paths:
                stream = stack.enter_context(plain(path).open("rb"))
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as exc:
                    raise ValueError(f"生命周期锁正被占用，请等待正常关机: {path}") from exc
            self.check(proposal)
            yield


def atomic_write(path, data, entry):
    path = plain(path)
    fd, name = tempfile.mkstemp(prefix=".gpu-resize-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            os.fchown(stream.fileno(), entry["uid"], entry["gid"])
            os.fchmod(stream.fileno(), entry["mode"])
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def apply(proposal, runtime, backup_name="gpu-resize-backups"):
    with runtime.locks(proposal):
        validate_vm_configs(proposal["changes"])
        entries = [e for e in proposal["changes"] if e["before"] != e["after"]]
        if not entries:
            print("PASS：所有配置已是目标显卡，无需改动。")
            return None
        # Check the entire transaction before the first write. No partial user/root split.
        for entry in proposal["changes"]:
            path = plain(entry["path"])
            require(path.read_bytes() == entry["before"], f"配置在预检后变化: {path}")
            if entry["before"] != entry["after"]:
                require(os.access(path.parent, os.W_OK), f"需要管理员权限写入: {path}")
        replacements = {e["path"]: e["after"] for e in proposal["changes"]}
        fleet = [p for p in Path(proposal["root"]).iterdir()
                 if re.fullmatch(r"[1-9][0-9]*", p.name)]
        require(len(fleet) == proposal["count"], "预检后 VM 池成员发生变化，请重新预览")
        for instance in fleet:
            conf = plain(instance / "vm.conf")
            values = parse(replacements.get(str(conf), conf.read_bytes()))
            require(values.get("VGPU_FB_MB") == proposal["tier"]
                    and values.get("GPU_VRAM_MB") == proposal["tier"],
                    f"VM {instance.name} 与迁移/回滚目标档位不一致")
        require(backup_name in ("gpu-resize-backups", "gpu-quote-backups"), "备份目录无效")
        backup_parent = Path(proposal["root"]) / "control" / backup_name
        if backup_parent.exists():
            plain(backup_parent, directory=True)
        else:
            backup_parent.mkdir(mode=0o700)
        backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime("%Y%m%d-%H%M%S-"),
                                       dir=backup_parent))
        journal = {k: v for k, v in proposal.items() if k != "changes"}
        journal.update(schema=1, entries=[])
        for index, entry in enumerate(proposal["changes"]):
            record = {k: v for k, v in entry.items() if k not in ("before", "after")}
            for version in ("before", "after"):
                filename = f"{index}-{version}.conf"
                with (backup / filename).open("xb") as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(entry[version])
                    stream.flush()
                    os.fsync(stream.fileno())
                record[version] = filename
                record[version + "_sha256"] = digest(entry[version])
            journal["entries"].append(record)
        with (backup / "journal.json").open("x") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(journal, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        for directory_path in (backup, backup_parent):
            directory_fd = os.open(directory_path, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        print(f"备份及回滚日志：{backup}", flush=True)
        published = []
        try:
            for entry in entries:
                # Include this file before rename: directory-fsync errors also roll it back.
                published.append(entry)
                atomic_write(entry["path"], entry["after"], entry)
            for entry in entries:
                require(Path(entry["path"]).read_bytes() == entry["after"], "发布后回读失败")
        except BaseException:
            for entry in reversed(published):
                atomic_write(entry["path"], entry["before"], entry)
            raise
        print("PASS：目标配置已发布；所有非显卡配置字节保持一致。")
        return backup


def repair_quotes(root, vm_ids, hosts, runtime):
    targets = []
    for vm_id in vm_ids:
        require(re.fullmatch(r"[1-9][0-9]{0,9}", vm_id), "VM ID 必须是正整数")
        values = parse(plain(Path(root) / vm_id / "vm.conf").read_bytes())
        targets.append(vm_id + ":" + values["GPU_PROFILE"])
    proposal = plan(root, targets, hosts)
    require(all(parse(e["before"]) == parse(e["after"]) for e in proposal["changes"]),
            "引号修复不能改变任何配置值或宿主档位")
    backup = apply(proposal, runtime, backup_name="gpu-quote-backups")
    print("PASS：仅修复显卡字段引号；全部字段值及其它硬件身份保持原值。")
    return backup


def restore(backup, runtime):
    backup = plain(backup, directory=True)
    journal = json.loads(plain(backup / "journal.json").read_text())
    require(journal.get("schema") == 1, "不支持的回滚日志")
    entries = []
    for record in journal["entries"]:
        path = Path(record["path"])
        require(record["kind"] in ("vm", "host"), "未知的回滚文件类型")
        if record["kind"] == "vm":
            require(path.parent.name in journal["vm_ids"]
                    and path == Path(journal["root"]) / path.parent.name / "vm.conf",
                    "回滚 VM 路径不属于原迁移池")
        else:
            require(path.name in ("vgpu-host.conf", "g11-vgpu-host.conf"),
                    "回滚宿主配置文件名无效")
        entry = {k: v for k, v in record.items() if k not in ("before", "after")}
        for version in ("before", "after"):
            filename = record[version]
            require(Path(filename).name == filename, "回滚备份文件名不安全")
            data = plain(backup / filename).read_bytes()
            require(digest(data) == record[version + "_sha256"], "回滚备份摘要不匹配")
            entry[version] = data
        fields = GPU_FIELDS if entry["kind"] == "vm" else HOST_FIELDS
        require(untouched(entry["before"], fields) == untouched(entry["after"], fields),
                "回滚日志包含非显卡变更")
        current = plain(entry["path"]).read_bytes()
        # A known formatting-only recovery must not invalidate the original
        # 1GB rollback journal. Never accept arbitrary semantic equivalence.
        repaired_after = (normalized_gpu_quotes(entry["after"])
                          if entry["kind"] == "vm" else entry["after"])
        require(current in (entry["before"], entry["after"], repaired_after),
                f"配置在迁移后另有修改，拒绝覆盖: {entry['path']}")
        entry["after"], entry["before"] = entry["before"], current
        entries.append(entry)
    hosts = [e for e in entries if e["kind"] == "host"]
    require(hosts, "回滚日志缺少宿主策略")
    original = parse(hosts[0]["after"])
    proposal = {k: journal[k] for k in ("root", "vm_ids", "bdf", "count")}
    proposal.update(tier=original["VGPU_HOST_FB_TIER_MB"],
                    resource=original["VGPU_RESOURCE_PROFILE"], changes=entries)
    apply(proposal, runtime)


def main():
    parser = argparse.ArgumentParser(description="RTX 2080/R535 已有 VM 只换显卡；默认只读预览")
    parser.add_argument("--vms-dir", default=os.environ.get("VM_ROOT", "/home/ubuntu/images/vms"))
    parser.add_argument("--vm", action="append", default=[], metavar="ID:PROFILE")
    parser.add_argument("--host-config", action="append", default=[], metavar="FILE",
                        help="可重复；列出该 VM 池所有实际启动入口的宿主配置")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--apply", action="store_true", help="正常关机后备份并应用")
    action.add_argument("--restore", metavar="BACKUP_DIR", help="关闭 VM 后按日志回滚")
    action.add_argument("--repair-quotes", nargs="+", metavar="ID",
                        help="关闭 VM 后修复旧封装的显卡单引号，所有字段值保持原值")
    args = parser.parse_args()
    runtime = Runtime()
    if args.repair_quotes:
        require(not args.vm, "--repair-quotes 使用现有显卡，不能同时指定新 --vm 目标")
        repair_quotes(args.vms_dir, args.repair_quotes,
                      args.host_config or [DEPLOY / "host/vgpu-host.conf"], runtime)
        return
    if args.restore:
        require(not args.vm and not args.host_config, "--restore 不能同时指定新的迁移目标")
        restore(args.restore, runtime)
        return
    proposal = plan(args.vms_dir, args.vm, args.host_config)
    runtime.check(proposal)
    for entry in proposal["changes"]:
        before, after = parse(entry["before"]), parse(entry["after"])
        print(entry["path"])
        for key in before:
            if before[key] != after[key]:
                print(f"  {key}: {before[key]} -> {after[key]}")
        print("  非显卡内容 SHA256：" + digest(untouched(entry["after"],
              GPU_FIELDS if entry["kind"] == "vm" else HOST_FIELDS)))
    print(f"目标：{proposal['count']} 台 × {proposal['tier']} MiB；其余硬件身份保持原值。")
    if args.apply:
        apply(proposal, runtime)
    else:
        print("只读预览完成；确认上述显卡方案后追加 --apply。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"[gpu-resize] ERROR: {error}") from error
