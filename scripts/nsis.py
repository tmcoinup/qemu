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
    "deploy/windows/lib/VMate.Common.ps1",
    "deploy/windows/lib/VMate.Components.ps1",
    "deploy/windows/lib/VMate.Preflight.ps1",
    "deploy/windows/lib/VMate.Manifest.ps1",
    "deploy/windows/lib/VMate.Memory.ps1",
    "deploy/windows/lib/VMate.ProfileStore.ps1",
    "deploy/windows/lib/VMate.Profile.ps1",
    "deploy/windows/lib/VMate.Arguments.ps1",
    "deploy/hardware/platforms.json",
    "deploy/hardware/components.json",
    "deploy/docs/WINDOWS-PACKAGING.md",
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


def find_deps(exe_or_dll, search_path, analyzed_deps):
    deps = [exe_or_dll]
    output = subprocess.check_output(["objdump", "-p", exe_or_dll], text=True)
    output = output.split("\n")
    for line in output:
        if not line.lstrip().startswith("DLL Name: "):
            continue

        dep = line.split("DLL Name: ")[1].strip()
        if dep in analyzed_deps:
            continue

        dll = os.path.join(search_path, dep)
        if not os.path.exists(dll):
            # assume it's a Windows provided dll, skip it
            continue

        analyzed_deps.add(dep)
        # locate the dll dependencies recursively
        analyzed_deps, rdeps = find_deps(dll, search_path, analyzed_deps)
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
        if vmate_runtime and not os.path.isfile(
            os.path.join(install_root, "qemu-fb-shm-stream.exe")
        ):
            raise RuntimeError(
                "VMate Runtime requires installed qemu-fb-shm-stream.exe"
            )
        with open(
            os.path.join(destdir + prefix, "system-emulations.nsh"),
            "w",
            encoding="utf-8",
        ) as nsh, open(
            os.path.join(destdir + prefix, "system-mui-text.nsh"),
            "w",
            encoding="utf-8",
        ) as muinsh:
            for exe in sorted(glob.glob(
                os.path.join(destdir + prefix, "qemu-system-*.exe")
            )):
                exe = os.path.basename(exe)
                arch = exe[12:-4]
                nsh.write(
                    """
                Section "{0}" Section_{0}
                SetOutPath "$INSTDIR"
                File "${{BINDIR}}\\{1}"
                SectionEnd
                """.format(
                        arch, exe
                    )
                )
                if arch.endswith('w'):
                    desc = arch[:-1] + " emulation (GUI)."
                else:
                    desc = arch + " emulation."

                muinsh.write(
                    """
                !insertmacro MUI_DESCRIPTION_TEXT ${{Section_{0}}} "{1}"
                """.format(arch, desc))

        search_path = args.dlldir
        print("Searching '%s' for the dependent dlls ..." % search_path)
        dlldir = os.path.join(destdir + prefix, "dll")
        os.mkdir(dlldir)

        analyzed_deps = set()
        for exe in glob.glob(os.path.join(destdir + prefix, "*.exe")):
            signcode(exe)

            # find all dll dependencies
            analyzed_deps, deps = find_deps(exe, search_path, analyzed_deps)
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
