#!/usr/bin/env bash
# Windows ExtraQemuArgs 必须按 token/backend/property 边界拒绝 POSIX/Linux 宿主能力。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATOR="$REPO_ROOT/deploy/windows/lib/VMate.ExtraArguments.ps1"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"
NSIS="$REPO_ROOT/scripts/nsis.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -F ". (Join-Path \$libraryRoot 'VMate.ExtraArguments.ps1')" \
    "$LAUNCHER" >/dev/null || fail "Windows 启动器未加载 ExtraArguments 模块"
grep -F '"deploy/windows/lib/VMate.ExtraArguments.ps1",' \
    "$NSIS" >/dev/null || fail "NSIS runtime 未包含 ExtraArguments 模块"

shell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$shell_bin" ]]; then
    echo "SKIP: PowerShell not found; static ExtraQemuArgs closure passed"
    exit 0
fi

VMATE_EXTRA_ARGUMENTS="$VALIDATOR" \
    "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
. $env:VMATE_EXTRA_ARGUMENTS

function Assert-Allowed {
    param([string]$Name, [string[]]$Arguments)

    try {
        Assert-VMateExtraArguments -Arguments $Arguments
    } catch {
        throw "合法用例 $Name 被拒绝：$($_.Exception.Message)"
    }
}

function Assert-Denied {
    param([string]$Name, [string[]]$Arguments)

    $failed = $false
    try {
        Assert-VMateExtraArguments -Arguments $Arguments
    } catch {
        $failed = $true
        if ($_.Exception.Message -notmatch "ExtraQemuArgs") {
            throw "拒绝用例 $Name 没有稳定错误边界：$($_.Exception.Message)"
        }
    }
    if (-not $failed) {
        throw "危险用例 $Name 未被拒绝：$($Arguments -join " ")"
    }
}

$allowed = @(
    @{ Name = "相似选项名不触发保留门禁"; Args = @("-machine-readable", "on") },
    @{ Name = "user"; Args = @("-netdev", "user,id=user-extra") },
    @{ Name = "legacy user"; Args = @("-net", "user,name=legacy-user") },
    @{ Name = "socket AF_UNIX"; Args = @(
            "-netdev", "socket,id=legacy,listen=/tmp/kvm-vfio.sock"
        ) },
    @{ Name = "stream AF_UNIX"; Args = @(
            "-netdev", "stream,id=stream0,addr.type=unix,addr.path=/tmp/io_uring.sock"
        ) },
    @{ Name = "dgram AF_UNIX"; Args = @(
            "-netdev", "dgram,id=dgram0,remote.type=unix,remote.path=/tmp/linux.sock"
        ) },
    @{ Name = "TAP-Win32"; Args = @(
            "-netdev", "tap,id=tap0,ifname=OpenVPN TAP-Windows6"
        ) },
    @{ Name = "socket chardev AF_UNIX"; Args = @(
            "-chardev", "socket,id=control,path=/tmp/vfio-kvm.sock,server=on"
        ) },
    @{ Name = "socket chardev JSON"; Args = @(
            "-chardev",
            "{`"id`":`"control-json`",`"backend`":{`"type`":`"socket`",`"data`":{`"addr`":{`"type`":`"unix`",`"data`":{`"path`":`"/tmp/linux.sock`"}}}}}"
        ) },
    @{ Name = "pipe chardev"; Args = @(
            "-chardev", "pipe,id=pipe0,path=vmate-control"
        ) },
    @{ Name = "Windows serial"; Args = @(
            "-chardev", "serial,id=com0,path=COM3"
        ) },
    @{ Name = "QMP AF_UNIX"; Args = @(
            "-qmp", "unix:/tmp/kvm.sock,server=on,wait=off"
        ) },
    @{ Name = "dsound"; Args = @("-audiodev", "dsound,id=audio0") },
    @{ Name = "SDL audio"; Args = @("-audio", "driver=sdl") },
    @{ Name = "RAM object"; Args = @(
            "-object", "memory-backend-ram,id=ram1,size=1G"
        ) },
    @{ Name = "aio native cache none"; Args = @(
            "-drive", "file=C:\VMs\linux-vfio.qcow2,if=none,aio=native,cache=none"
        ) },
    @{ Name = "aio threads cache none"; Args = @(
            "-drive", "file=C:\VMs\disk.qcow2,if=none,aio=threads,cache=none"
        ) },
    @{ Name = "转义逗号不是属性边界"; Args = @(
            "-drive",
            "file=C:\VMs\disk,,aio=io_uring.qcow2,if=none,aio=threads,cache=none"
        ) },
    @{ Name = "blockdev keyval"; Args = @(
            "-blockdev",
            "driver=qcow2,file.driver=file,file.filename=C:\VMs\disk.qcow2,file.aio=native"
        ) },
    @{ Name = "blockdev JSON"; Args = @(
            "-blockdev",
            "{`"driver`":`"file`",`"filename`":`"C:\\VMs\\disk.raw`",`"aio`":`"threads`"}"
        ) },
    @{ Name = "image shortcuts"; Args = @(
            "-hda", "C:\VMs\disk.qcow2", "-cdrom", "C:\VMs\installer.iso"
        ) },
    @{ Name = "extended image file"; Args = @(
            "-drive", "file=\\?\C:\VMs\disk.qcow2,format=qcow2"
        ) },
    @{ Name = "incoming AF_UNIX"; Args = @(
            "-incoming", "unix:/tmp/linux-kvm.sock"
        ) }
)

foreach ($case in $allowed) {
    Assert-Allowed -Name $case.Name -Arguments $case.Args
}

$denied = @(
    @{ Name = "保留 accel"; Args = @("-accel", "kvm") },
    @{ Name = "保留 cpu inline"; Args = @("--cpu=host") },
    @{ Name = "保留内存"; Args = @("-m", "4096") },
    @{ Name = "保留 vCPU 拓扑"; Args = @("-smp", "2,cores=2") },
    @{ Name = "保留 NUMA 拓扑"; Args = @("-numa", "node,mem=2048") },
    @{ Name = "保留间接属性覆盖"; Args = @(
            "-set", "device.nic0.mac=52:54:00:11:22:33"
        ) },
    @{ Name = "保留大写 M"; Args = @("-M", "q35") },
    @{ Name = "KVM"; Args = @("-enable-kvm") },
    @{ Name = "Xen"; Args = @("-xen-attach") },
    @{ Name = "seccomp"; Args = @("-sandbox", "on") },
    @{ Name = "POSIX lifecycle"; Args = @("-run-with", "exit-with-parent=on") },
    @{ Name = "daemon"; Args = @("-daemonize") },
    @{ Name = "fd injection"; Args = @("-add-fd", "fd=3,set=1") },
    @{ Name = "host RAM path"; Args = @("-mem-path", "/dev/hugepages") },
    @{ Name = "virtfs"; Args = @("-virtfs", "local,path=/tmp/share,mount_tag=x") },
    @{ Name = "TPM backend"; Args = @("-tpmdev", "emulator,id=tpm0") },
    @{ Name = "host plugin"; Args = @("-plugin", "/tmp/plugin.so") },
    @{ Name = "nested config"; Args = @("-readconfig", "/tmp/qemu.conf") },
    @{ Name = "bridge"; Args = @("-netdev", "bridge,id=n0,br=br0") },
    @{ Name = "legacy bridge"; Args = @("-net", "bridge,name=n0,br=br0") },
    @{ Name = "passt"; Args = @("-nic=passt,model=e1000e") },
    @{ Name = "l2tpv3"; Args = @("-netdev", "type=l2tpv3,id=n0") },
    @{ Name = "vde"; Args = @("-netdev", "vde,id=n0") },
    @{ Name = "netmap"; Args = @("-netdev", "netmap,id=n0,ifname=eth0") },
    @{ Name = "AF_XDP"; Args = @("-netdev", "af-xdp,id=n0,ifname=eth0") },
    @{ Name = "vhost user"; Args = @("-netdev", "vhost-user,id=n0,chardev=c0") },
    @{ Name = "vhost vdpa"; Args = @("-netdev", "vhost-vdpa,id=n0,vhostdev=/dev/vhost-vdpa") },
    @{ Name = "vmnet"; Args = @("-netdev", "vmnet-shared,id=n0") },
    @{ Name = "tap script"; Args = @(
            "-netdev", "tap,id=tap0,ifname=tap0,script=/tmp/up.sh"
        ) },
    @{ Name = "tap helper"; Args = @(
            "-netdev", "tap,id=tap0,ifname=tap0,helper=qemu-bridge-helper"
        ) },
    @{ Name = "user smbd"; Args = @(
            "-netdev", "user,id=n0,smb=C:\share"
        ) },
    @{ Name = "PTY chardev"; Args = @("-chardev", "pty,id=console0") },
    @{ Name = "PTY chardev JSON"; Args = @(
            "-chardev",
            "{`"id`":`"console-json`",`"backend`":{`"type`":`"pty`",`"data`":{}}}"
        ) },
    @{ Name = "FD chardev"; Args = @("-chardev", "fd,id=console0,fd=3") },
    @{ Name = "parallel chardev"; Args = @("-chardev", "parallel,id=p0") },
    @{ Name = "file input path"; Args = @(
            "-chardev", "file,id=f0,path=out.log,input-path=in.log"
        ) },
    @{ Name = "legacy PTY"; Args = @("-serial", "pty") },
    @{ Name = "ALSA"; Args = @("-audiodev", "alsa,id=audio0") },
    @{ Name = "PipeWire"; Args = @("-audio=driver=pipewire") },
    @{ Name = "POSIX RNG"; Args = @(
            "-object", "rng-random,id=rng0,filename=/dev/urandom"
        ) },
    @{ Name = "file memory"; Args = @(
            "-object", "memory-backend-file,id=ram0,mem-path=/tmp/ram,size=1G"
        ) },
    @{ Name = "memfd"; Args = @(
            "-object", "memory-backend-memfd,id=ram0,size=1G"
        ) },
    @{ Name = "IOMMUFD"; Args = @("-object", "iommufd,id=iommufd0") },
    @{ Name = "Linux input"; Args = @(
            "-object", "input-linux,id=input0,evdev=/dev/input/event0"
        ) },
    @{ Name = "SocketCAN"; Args = @(
            "-object", "can-host-socketcan,id=can0,if=can0"
        ) },
    @{ Name = "VFIO"; Args = @("-device", "vfio-pci,host=01:00.0") },
    @{ Name = "vhost device"; Args = @("-device", "vhost-vsock-pci") },
    @{ Name = "MTP host export"; Args = @(
            "-device", "usb-mtp,root=/tmp/share"
        ) },
    @{ Name = "io_uring drive"; Args = @(
            "-drive", "file=C:\VMs\disk.qcow2,aio=io_uring,cache=none"
        ) },
    @{ Name = "Linux raw drive"; Args = @("-drive", "file=/dev/nvme0n1") },
    @{ Name = "Linux positional raw drive"; Args = @("-drive", "/dev/sda,format=raw") },
    @{ Name = "Windows raw drive"; Args = @(
            "-drive", "file=\\.\PhysicalDrive0,format=raw"
        ) },
    @{ Name = "Windows positional raw drive"; Args = @(
            "-drive", "\\.\PhysicalDrive1,format=raw"
        ) },
    @{ Name = "Windows drive-letter volume"; Args = @(
            "-drive", "file=\\.\C:,format=raw"
        ) },
    @{ Name = "Windows drive-letter forward slash"; Args = @(
            "-drive=file=//./c:,format=raw"
        ) },
    @{ Name = "CD-ROM physical drive"; Args = @(
            "-cdrom", "\\.\PhysicalDrive0"
        ) },
    @{ Name = "CD-ROM drive letter"; Args = @("-cdrom", "d:") },
    @{ Name = "CD-ROM mixed case forward slash"; Args = @(
            "-cdrom=//./pHySiCaLdRiVe2"
        ) },
    @{ Name = "Volume GUID disk"; Args = @(
            "-hda", "\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}\"
        ) },
    @{ Name = "Volume GUID mixed case forward slash"; Args = @(
            "-hdb", "//?/vOlUmE{01234567-89AB-CDEF-0123-456789ABCDEF}/"
        ) },
    @{ Name = "GLOBALROOT disk"; Args = @(
            "-hdc", "\\.\globalroot\device\harddisk0\partition0"
        ) },
    @{ Name = "floppy raw device"; Args = @("-fda", "//./fLoPpY0") },
    @{ Name = "pflash physical drive"; Args = @(
            "-pflash", "\\?\PHYSICALDRIVE3"
        ) },
    @{ Name = "explicit host_device protocol"; Args = @(
            "-drive", "file=HOST_DEVICE:\\.\PhysicalDrive4,format=raw"
        ) },
    @{ Name = "host_device blockdev"; Args = @(
            "-blockdev", "driver=host_device,filename=/dev/sda"
        ) },
    @{ Name = "nested io_uring JSON"; Args = @(
            "-blockdev",
            "{`"driver`":`"qcow2`",`"file`":{`"driver`":`"file`",`"filename`":`"C:\\VMs\\disk`",`"aio`":`"io_uring`"}}"
        ) },
    @{ Name = "incoming exec"; Args = @("-incoming", "exec:cat state") },
    @{ Name = "incoming fd"; Args = @("-incoming", "fd:3") },
    @{ Name = "incoming RDMA"; Args = @("-incoming", "rdma:host:4444") }
)

foreach ($case in $denied) {
    Assert-Denied -Name $case.Name -Arguments $case.Args
}

Write-Output ("OK: Windows ExtraQemuArgs token-aware checks passed " +
    "(allowed=$($allowed.Count), denied=$($denied.Count))")
' || fail "Windows ExtraQemuArgs 动态测试失败"
