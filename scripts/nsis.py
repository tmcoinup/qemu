#!/usr/bin/env python3
#
# Copyright (C) 2020 Red Hat, Inc.
#
# SPDX-License-Identifier: GPL-2.0-or-later

import argparse
import glob
import os
import shutil
import subprocess
import tempfile


VMATE_RUNTIME_FILES = (
    "deploy/windows/start-vm.ps1",
    "deploy/windows/stop-vm.ps1",
    "deploy/windows/stream-fb-shm.ps1",
    "deploy/windows/collect-hardware-snapshot.ps1",
    "deploy/windows/lib/VMate.ProcessEvidence.ps1",
    "deploy/windows/lib/VMate.FileEvidence.ps1",
    "deploy/windows/lib/VMate.Common.ps1",
    "deploy/windows/lib/VMate.Json.ps1",
    "deploy/windows/lib/VMate.ComponentPolicy.ps1",
    "deploy/windows/lib/VMate.StoragePolicy.ps1",
    "deploy/windows/lib/VMate.ComponentRuntime.ps1",
    "deploy/windows/lib/VMate.ComponentSelection.ps1",
    "deploy/windows/lib/VMate.Components.ps1",
    "deploy/windows/lib/VMate.Display.ps1",
    "deploy/windows/lib/VMate.Gpu.Contracts.ps1",
    "deploy/windows/lib/VMate.Gpu.ps1",
    "deploy/windows/lib/VMate.Preflight.ps1",
    "deploy/windows/lib/VMate.Manifest.ps1",
    "deploy/windows/lib/VMate.Manifest.Validation.ps1",
    "deploy/windows/lib/VMate.Memory.ps1",
    "deploy/windows/lib/VMate.MemoryBinding.ps1",
    "deploy/windows/lib/VMate.BoardIdentity.ps1",
    "deploy/windows/lib/VMate.ProfileStore.ps1",
    "deploy/windows/lib/VMate.Profile.ps1",
    "deploy/windows/lib/VMate.Compatibility.ps1",
    "deploy/windows/lib/VMate.Arguments.ps1",
    "deploy/windows/lib/VMate.ExtraArguments.Device.ps1",
    "deploy/windows/lib/VMate.ExtraArguments.ps1",
    "deploy/windows/gpup/VMate.GpuP.Common.ps1",
    "deploy/windows/gpup/VMate.GpuP.VMConfiguration.ps1",
    "deploy/windows/gpup/VMate.GpuP.QuotaProfile.ps1",
    "deploy/windows/gpup/VMate.GpuP.Host.ps1",
    "deploy/windows/gpup/VMate.GpuP.Partition.ps1",
    "deploy/windows/gpup/VMate.GpuP.DriverDiscovery.ps1",
    "deploy/windows/gpup/VMate.GpuP.DriverStore.ps1",
    "deploy/windows/gpup/VMate.GpuP.WindowsImage.ps1",
    "deploy/windows/gpup/VMate.GpuP.Display.ps1",
    "deploy/windows/gpup/VMate.GpuP.Identity.ps1",
    "deploy/windows/gpup/VMate.GpuP.BaseImage.ps1",
    "deploy/windows/gpup/VMate.GpuP.HardwareCatalog.ps1",
    "deploy/windows/gpup/VMate.GpuP.HardwareProfile.ps1",
    "deploy/windows/gpup/VMate.GpuP.CpuidProfile.ps1",
    "deploy/windows/gpup/VMate.GpuP.HardwareReprofile.ps1",
    "deploy/windows/gpup/VMate.GpuP.DetectionParity.ps1",
    "deploy/windows/gpup/VMate.HyperV.FirmwareIdentity.ps1",
    "deploy/windows/gpup/VMate.HyperV.NetworkIdentity.ps1",
    "deploy/windows/gpup/VMate.HyperV.ComputeProfile.ps1",
    "deploy/windows/gpup/VMate.HyperV.ConsoleProfile.ps1",
    "deploy/windows/gpup/VMate.HyperV.EnhancedSession.ps1",
    "deploy/windows/gpup/VMate.HyperV.DisplayTopology.ps1",
    "deploy/windows/gpup/VMate.HyperV.MetadataExchange.ps1",
    "deploy/windows/gpup/VMate.HyperV.Input.ps1",
    "deploy/windows/gpup/VMate.HyperV.InputBridge.ps1",
    "deploy/windows/gpup/VMate.HyperV.IdentityBoot.ps1",
    "deploy/windows/gpup/VMate.HyperV.IdentityBoot.Support.ps1",
    "deploy/windows/gpup/VMate.HyperV.HostIdentityExtension.ps1",
    "deploy/windows/gpup/VMate.HyperV.HostIdentityRuntime.ps1",
    "deploy/windows/gpup/VMate.HyperV.CpuidColdStart.ps1",
    "deploy/windows/gpup/firmware/bin/VMateIdentityBoot.efi",
    "deploy/windows/gpup/firmware/bin/VMateIdentityBoot.efi.sha256",
    "deploy/windows/gpup/native/bin/VMateVidPartitionProbe.exe",
    "deploy/windows/gpup/native/bin/VMateVidContextProbe.sys",
    "deploy/windows/gpup/native/bin/VMateCpuidBrandExtension.sys",
    "deploy/windows/gpup/native/bin/VMateCpuidProbe.exe",
    "deploy/windows/gpup/native/bin/VMateHdvPeerProbe.exe",
    "deploy/windows/gpup/native/bin/VMateGuestMonitorProvisioner.exe",
    "deploy/windows/gpup/VMate.GpuP.HardwareIdentity.ps1",
    "deploy/windows/gpup/VMate.GpuP.GuestIdentity.ps1",
    "deploy/windows/gpup/VMate.GpuP.Lifecycle.ps1",
    "deploy/windows/gpup/VMate.GpuP.Guest.ps1",
    "deploy/windows/gpup/VMate.GpuP.GuestMonitor.ps1",
    "deploy/windows/gpup/VMate.GpuP.GuestMonitorValidation.ps1",
    "deploy/windows/gpup/VMate.GpuP.GuestValidation.ps1",
    "deploy/windows/gpup/VMate.GpuP.D3DValidation.ps1",
    "deploy/windows/gpup/VMate.Windows.CodeIntegrity.ps1",
    "deploy/windows/gpup/New-VMateGpuPVM.ps1",
    "deploy/windows/gpup/Enable-VMateGpuP.ps1",
    "deploy/windows/gpup/Update-VMateGpuPDriver.ps1",
    "deploy/windows/gpup/Disable-VMateGpuP.ps1",
    "deploy/windows/gpup/Get-VMateGpuPStatus.ps1",
    "deploy/windows/gpup/Test-VMateGpuPGuest.ps1",
    "deploy/windows/gpup/Set-VMateGpuPComputeProfile.ps1",
    "deploy/windows/gpup/Invoke-VMateVidContextProbe.ps1",
    "deploy/windows/gpup/Invoke-VMateCpuidBrandExtension.ps1",
    "deploy/windows/gpup/Start-VMateGpuPVM.ps1",
    "deploy/windows/gpup/Confirm-VMateGpuPVMIdentity.ps1",
    "deploy/windows/gpup/Get-VMateHyperVIdentityEvidence.ps1",
    "deploy/windows/gpup/Set-VMateGpuPHardwareProfile.ps1",
    "deploy/windows/gpup/Enable-VMateHyperVEnhancedSession.ps1",
    "deploy/windows/gpup/Connect-VMateGpuPVM.ps1",
    "deploy/windows/gpup/Set-VMateGpuPDisplayTopology.ps1",
    "deploy/windows/gpup/Restore-VMateGpuPDisplayTopology.ps1",
    "deploy/windows/gpup/Disable-VMateGpuPMetadataExchange.ps1",
    "deploy/windows/gpup/Restore-VMateGpuPMetadataExchange.ps1",
    "deploy/windows/gpup/Start-VMateHyperVInputBridge.ps1",
    "deploy/windows/gpup/Detect-VGpuP.ps1",
    "deploy/windows/gpup/Compare-VMateGpuPDetection.ps1",
    "deploy/hardware/p11-platforms.json",
    "deploy/hardware/platforms.json",
    "deploy/hardware/household-compatibility.json",
    "deploy/hardware/host-compatibility.json",
    "deploy/hardware/components.json",
    "deploy/hardware/gpu-boards.json",
    "deploy/hardware/storage.json",
    "deploy/hardware/memory.json",
    "deploy/hardware/board-vendors.json",
    "deploy/firmware/OVMF_CODE_4M_stealth.fd",
    "deploy/docs/WINDOWS-PACKAGING.md",
    "deploy/docs/HYPERV-GPU-P.md",
)

VMATE_RUNTIME_BINARIES = (
    "qemu-system-x86_64.exe",
    "qemu-img.exe",
    "qemu-fb-shm-stream.exe",
)

# 严格闭包检查只能跳过 Windows 自带的 DLL。其余依赖必须能在 staging 根目录
# 或 MinGW sysroot 中解析，否则安装后的程序可能在进入 main() 前就加载失败。
WINDOWS_SYSTEM_DLLS = frozenset({
    "advapi32.dll",
    "bcrypt.dll",
    "cfgmgr32.dll",
    "comctl32.dll",
    "comdlg32.dll",
    "crypt32.dll",
    "dnsapi.dll",
    "dwmapi.dll",
    "dwrite.dll",
    "gdi32.dll",
    "hid.dll",
    "imm32.dll",
    "iphlpapi.dll",
    "kernel32.dll",
    "msimg32.dll",
    "msvcrt.dll",
    "ncrypt.dll",
    "netapi32.dll",
    "ntdll.dll",
    "ole32.dll",
    "oleaut32.dll",
    "opengl32.dll",
    "pdh.dll",
    "powrprof.dll",
    "psapi.dll",
    "rpcrt4.dll",
    "secur32.dll",
    "setupapi.dll",
    "shell32.dll",
    "shlwapi.dll",
    "user32.dll",
    "userenv.dll",
    "uxtheme.dll",
    "version.dll",
    "wininet.dll",
    "winmm.dll",
    "winspool.drv",
    "wldap32.dll",
    "ws2_32.dll",
    "wtsapi32.dll",
})


def validate_vmate_runtime_binaries(install_root):
    """拒绝缺少启动器必需原生程序的 VMate staging。"""
    missing = [
        name for name in VMATE_RUNTIME_BINARIES
        if not os.path.isfile(os.path.join(install_root, name))
    ]
    if missing:
        raise RuntimeError(
            "incomplete VMate Windows binaries: missing " + ", ".join(missing)
        )


def write_system_emulation_sections(executables, nsh, muinsh, vmate_runtime):
    """生成 system emulator sections，并固定 VMate 的 x86_64 主程序。"""
    for path in sorted(executables):
        exe = os.path.basename(path)
        arch = exe[12:-4]
        nsh.write(
            '\n                Section "{0}" Section_{0}\n'.format(arch)
        )
        if vmate_runtime and arch == "x86_64":
            # VMate launcher 固定查找 console 版 x86_64 主程序；下游安装包不能
            # 允许用户取消该 section 后留下只有脚本、没有 QEMU 的半套 runtime。
            nsh.write("                SectionIn RO\n")
        nsh.write(
            '                SetOutPath "$INSTDIR"\n'
            '                File "${BINDIR}\\%s"\n'
            "                SectionEnd\n" % exe
        )
        if arch.endswith("w"):
            desc = arch[:-1] + " emulation (GUI)."
        else:
            desc = arch + " emulation."
        muinsh.write(
            "\n                !insertmacro MUI_DESCRIPTION_TEXT "
            "${Section_%s} \"%s\"\n" % (arch, desc)
        )


def signcode(path):
    cmd = os.environ.get("SIGNCODE")
    if not cmd:
        return
    subprocess.run([cmd, path], check=True)


def validate_installer_version(outfile, srcdir):
    """拒绝用旧 Meson 配置生成错误版本号的 Windows 安装包。

    Windows 交叉构建目录可能长期复用；源码从 9.2 升级到 11.0.2 后，如果没有
    重新 configure，旧 build.ninja 仍会请求 qemu-setup-9.2.0.exe。安装包内部
    二进制和文件名由此分叉。这里以源码 VERSION 为唯一事实源，尽早失败并要求
    重新配置，而不是继续发布一个无法追溯的产物。
    """
    version_path = os.path.join(srcdir, "VERSION")
    with open(version_path, encoding="utf-8") as version_file:
        version = version_file.read().strip()
    expected = "qemu-setup-%s.exe" % version
    actual = os.path.basename(outfile)
    if actual != expected:
        raise RuntimeError(
            "stale Windows build configuration: expected %s, got %s; "
            "delete/reconfigure the build directory" % (expected, actual)
        )


def stage_vmate_runtime(srcdir, install_root):
    """把 VMate Windows 运行资产按仓库相对路径放入 NSIS staging 目录。

    普通上游源码没有 deploy/windows/start-vm.ps1，此时直接返回 False，完全沿用
    原安装包内容。只要检测到下游入口，就要求整套脚本、manifest 和文档齐全；
    半套 runtime 会让安装后的默认路径失效，因此必须在打包阶段失败。
    """
    marker = os.path.join(srcdir, "deploy", "windows", "start-vm.ps1")
    if not os.path.isfile(marker):
        return False

    missing = [
        relative for relative in VMATE_RUNTIME_FILES
        if not os.path.isfile(os.path.join(srcdir, relative))
    ]
    if missing:
        raise RuntimeError(
            "incomplete VMate Windows runtime: missing " + ", ".join(missing)
        )

    for relative in VMATE_RUNTIME_FILES:
        source = os.path.join(srcdir, relative)
        destination = os.path.join(install_root, relative)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copy2(source, destination)
    return True


def build_dependency_index(search_paths):
    """按 Windows 大小写规则索引多个 DLL 搜索目录。

    Meson fallback 子项目会把 DLL（例如 libslirp-0.dll）安装到 staging 根
    目录，而 MinGW 发行版 DLL 位于单独 sysroot。staging 放在前面，使实际随
    本次构建安装的库优先于同名的系统副本。
    """
    dependency_index = {}
    for search_path in search_paths:
        for entry in os.scandir(search_path):
            name = entry.name.casefold()
            if entry.is_file() and name.endswith(".dll"):
                dependency_index.setdefault(name, entry.path)
    return dependency_index


def is_windows_system_dependency(dependency):
    """判断未随包分发的依赖是否由受支持 Windows 系统提供。"""
    normalized = dependency.casefold()
    return (
        normalized in WINDOWS_SYSTEM_DLLS
        or normalized.startswith("api-ms-win-")
        or normalized.startswith("ext-ms-win-")
    )


def find_deps(exe_or_dll, dependency_index, analyzed_deps, strict=False):
    deps = [exe_or_dll]
    output = subprocess.check_output(["objdump", "-p", exe_or_dll], text=True)
    output = output.split("\n")
    for line in output:
        if not line.lstrip().startswith("DLL Name: "):
            continue

        dep = line.split("DLL Name: ")[1].strip()
        normalized = dep.casefold()
        if normalized in analyzed_deps:
            continue

        dll = dependency_index.get(normalized)
        if dll is None:
            analyzed_deps.add(normalized)
            if strict and not is_windows_system_dependency(dep):
                raise RuntimeError(
                    "unresolved Windows DLL dependency '%s' required by '%s'"
                    % (dep, os.path.basename(exe_or_dll))
                )
            # 上游通用安装包保持兼容；VMate runtime 则只允许明确的系统 DLL。
            continue

        analyzed_deps.add(normalized)
        # locate the dll dependencies recursively
        analyzed_deps, rdeps = find_deps(
            dll, dependency_index, analyzed_deps, strict
        )
        deps.extend(rdeps)

    return analyzed_deps, deps


def main():
    parser = argparse.ArgumentParser(description="QEMU NSIS build helper.")
    parser.add_argument("outfile")
    parser.add_argument("prefix")
    parser.add_argument("srcdir")
    parser.add_argument("dlldir")
    parser.add_argument("cpu")
    parser.add_argument("nsisargs", nargs="*")
    args = parser.parse_args()

    validate_installer_version(args.outfile, args.srcdir)

    # canonicalize the Windows native prefix path
    prefix = os.path.splitdrive(args.prefix)[1]
    destdir = tempfile.mkdtemp()
    try:
        subprocess.run(["make", "install", "DESTDIR=" + destdir], check=True)
        install_root = destdir + prefix
        vmate_runtime = False
        if args.cpu == "x86_64":
            vmate_runtime = stage_vmate_runtime(args.srcdir, install_root)
        if vmate_runtime:
            validate_vmate_runtime_binaries(install_root)
        with open(
            os.path.join(destdir + prefix, "system-emulations.nsh"),
            "w",
            encoding="utf-8",
        ) as nsh, open(
            os.path.join(destdir + prefix, "system-mui-text.nsh"),
            "w",
            encoding="utf-8",
        ) as muinsh:
            write_system_emulation_sections(
                glob.glob(os.path.join(
                    destdir + prefix, "qemu-system-*.exe"
                )),
                nsh,
                muinsh,
                vmate_runtime,
            )

        search_paths = (install_root, args.dlldir)
        print(
            "Searching '%s' for the dependent dlls ..."
            % "', '".join(search_paths)
        )
        dependency_index = build_dependency_index(search_paths)
        dlldir = os.path.join(destdir + prefix, "dll")
        os.mkdir(dlldir)

        analyzed_deps = set()
        for exe in glob.glob(os.path.join(destdir + prefix, "*.exe")):
            signcode(exe)

            # find all dll dependencies
            analyzed_deps, deps = find_deps(
                exe, dependency_index, analyzed_deps, strict=vmate_runtime
            )
            deps = set(deps)
            deps.remove(exe)

            # copy all dlls to the DLLDIR
            for dep in deps:
                dllfile = os.path.join(dlldir, os.path.basename(dep))
                print("Copying '%s' to '%s'" % (dep, dllfile))
                shutil.copy(dep, dllfile)

        makensis = [
            "makensis",
            "-V2",
            "-NOCD",
            "-DSRCDIR=" + args.srcdir,
            "-DBINDIR=" + destdir + prefix,
        ]
        if args.cpu == "aarch64" or args.cpu == "x86_64":
            makensis += ["-DW64"]
        if vmate_runtime:
            makensis += ["-DCONFIG_VMATE_RUNTIME=y"]
        makensis += ["-DDLLDIR=" + dlldir]

        makensis += ["-DOUTFILE=" + args.outfile] + args.nsisargs
        subprocess.run(makensis, check=True)
        signcode(args.outfile)
    finally:
        shutil.rmtree(destdir)


if __name__ == "__main__":
    main()
