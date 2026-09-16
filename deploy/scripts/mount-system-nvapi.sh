#!/usr/bin/env bash
# Mount an identity update only in the normal, single-vGPU console topology.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vm-storage.sh
source "$here/lib/vm-storage.sh"

if (($# < 2)); then
    echo 'usage: mount-system-nvapi.sh VM_ID PACKAGE.iso [--check-only] [--replace]' >&2
    exit 2
fi
VM_ID=$1
ISO=$2
shift 2
vm_storage_validate_id "$VM_ID"
CHECK_ONLY=0
MOUNT_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=1 ;;
        --replace) MOUNT_ARGS+=( "$arg" ) ;;
        *) echo "不支持的参数: $arg" >&2; exit 2 ;;
    esac
done
vm_storage_init
vm_storage_require_namespace_ready "$VM_ID"
pid_file=$(vm_storage_run_path "$VM_ID" pid)
disk=$(vm_storage_disk_path "$VM_ID")

python3 - "$VM_ID" "$pid_file" "$disk" <<'PY'
import re
import sys
from pathlib import Path

vm_id, pid_path, disk = sys.argv[1:]
def fail(message):
    print(f'[identity-media] VM{vm_id}: {message}', file=sys.stderr)
    raise SystemExit(2)
try:
    path = Path(pid_path)
    if path.is_symlink():
        fail('PID 文件不能是符号链接')
    pid = path.read_text().strip()
    if not re.fullmatch(r'[1-9][0-9]*', pid):
        fail('PID 文件无效')
    argv = [part.decode() for part in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0') if part]
except (OSError, UnicodeError):
    fail('未找到运行中的 VM；请先用 start-vm.sh 正常启动')
def values(flag):
    return [argv[i+1] for i, value in enumerate(argv[:-1]) if value == flag]
if (not argv or Path(argv[0]).name not in ('qemu-system-x86_64', 'qemu-system-x86_64.g11.real')
        or values('-name') != [f'vm{vm_id}']
        or not any(f'file={disk}' in drive.split(',') for drive in values('-drive'))):
    fail('运行进程与当前 VM 名称/系统盘不匹配')
devices = values('-device')
vgpus = [device for device in devices if device.startswith(('vfio-pci,', 'vfio-pci-nohotplug,'))]
temporary = [device for device in devices if re.match(r'(VGA|secondary-vga|qxl(?:-vga)?|virtio-vga(?:-gl)?|virtio-gpu(?:-pci)?|vmware-svga)(?:,|$)', device)]
if (len(vgpus) != 1 or 'display=on' not in vgpus[0].split(',')
        or temporary or values('-vga') != ['none']):
    fail('仍在安全枚举/附加显卡模式，未挂载身份包。请在 Windows 执行 shutdown.exe /s /t 0，'
         '等普通 vGPU 窗口启动后再挂载；不要在 driver-install 窗口安装。')
print(f'[identity-media] VM{vm_id}: 普通 vGPU 模式检查通过')
PY

if ((CHECK_ONLY)); then exit 0; fi
exec "$here/scripts/optical-media.sh" "$VM_ID" mount "$ISO" "${MOUNT_ARGS[@]}"
