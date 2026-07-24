# 开发与跨平台验证依赖

本文档是 VMate 在 Ubuntu 开发宿主上的依赖事实源。运行虚拟机、构建 Linux
QEMU、重建固件、执行完整回归和生成 Windows 安装包是五种不同工作负载；按需安装
对应组即可，普通 VM 启动不要求安装全部开发工具。

## 1. Linux 运行与宿主网络

```bash
sudo apt update
sudo apt install -y \
  python3 ovmf swtpm swtpm-tools jq socat \
  iproute2 kmod util-linux procps psmisc sudo libcap2-bin \
  qemu-system-common qemu-utils ntfs-3g python3-hivex \
  lsof rsync
```

`qemu-system-common` 在 Ubuntu 上把 helper 安装到
`/usr/lib/qemu/qemu-bridge-helper`，它不一定出现在 `PATH`。项目的 bridge 安装器会
识别该标准路径，不要因为 `command -v qemu-bridge-helper` 无输出而重复安装包。

`qemu-utils` 在这里提供离线处理所需的 `qemu-nbd`，运行 VM 仍使用仓库构建的
patched `qemu-system-x86_64`/`qemu-img`。`seal-base.sh` 的占用检查需要 `lsof`；
默认 base 清理及 clone 的离线注入需要 `ntfs-3g` 与 `python3-hivex`。

持久化 `br0` 时还需要当前网络由 NetworkManager 管理。Ubuntu Server 若使用
systemd-networkd，应先准备本地或带外控制台，再决定是否安装 `network-manager`
并切换 netplan renderer。

## 2. Linux QEMU 源码构建

```bash
sudo apt install -y \
  git build-essential bzip2 ninja-build meson pkg-config \
  python3 python3-venv python3-pip python3-setuptools python3-wheel \
  zlib1g-dev libglib2.0-dev libpixman-1-dev \
  libslirp-dev libseccomp-dev libaio-dev liburing-dev \
  libsdl2-dev libepoxy-dev libvirglrenderer-dev libspice-server-dev
```

`deploy/tools/build.sh` 的 `INSTALL_BUILD_DEPS=auto` 是默认值。在 Debian/Ubuntu
本地前台终端发现缺项时，脚本会执行一次 `apt-get update`，再只安装缺失能力对应
的包；普通用户通过 `sudo` 获取权限，可以正常输入一次密码。安装结束后会重新执行
完整能力检查，仍有缺项就会在 configure 前失败。

CI、容器、后台任务和非 Debian 系统默认不隐式修改宿主。受控无人值守环境可使用
`--install-build-deps`（非交互时只尝试 root 或 `sudo -n`）；离线镜像或禁止系统
修改的环境使用 `--no-install-build-deps`，但该选项不会绕过依赖门禁。依赖安装与
构建后的 `--install-host-helpers` 是两套独立策略。

自动安装只覆盖本节的 Linux QEMU 源码构建组，不会安装 VM 运行/bridge、OVMF
重建、完整回归或 Windows 交叉打包依赖。上面的固定清单仍是 CI 镜像、离线主机和
受管环境应预置的事实源。
`libfdt-dev` 是可选的系统提供者；缺失时 QEMU 使用源码树的 internal dtc。

`python3-wheel` 提供 Python 模块，不保证安装名为 `wheel` 的命令。应使用
`python3 -c 'import wheel'` 验证，不要把 `command -v wheel` 当作缺包依据。
`libaio-dev` 与 `liburing-dev` 是启动盘自动选择 `native`/`io_uring` 的构建
契约；缺失时本地前台默认自动补齐，其它环境保持 fail closed。

## 3. 固件与 UEFI 镜像重建

重建 stealth OVMF：

```bash
sudo apt install -y nasm acpica-tools uuid-runtime
EDK2=$HOME/src/edk2 deploy/tools/build-ovmf.sh
```

重建 UEFI chainload FAT 镜像：

```bash
sudo apt install -y mtools dosfstools
```

`acpica-tools` 提供 `iasl`，`mtools` 提供 `mcopy`，`dosfstools` 提供
`mkfs.fat`。

## 4. 完整回归与 Windows 工件

Linux 上的 PowerShell AST、MinGW 语法、NSIS 语法和 Windows 工件静态测试需要：

```bash
sudo apt install -y \
  shellcheck mingw-w64 llvm xxd file ripgrep nsis 7zip imagemagick podman
```

Ubuntu 的 `mingw-w64` 元包同时安装两种线程模型。当前仓库内双架构 NVAPI/ADL
发布物使用 x86 `win32` 与 x64 `posix` 工具链；若系统 alternative 被新装元包改写，
用以下设置恢复可复现构建：

```bash
sudo update-alternatives --set \
  i686-w64-mingw32-gcc /usr/bin/i686-w64-mingw32-gcc-win32
sudo update-alternatives --set \
  i686-w64-mingw32-g++ /usr/bin/i686-w64-mingw32-g++-win32
sudo update-alternatives --set \
  x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
sudo update-alternatives --set \
  x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
```

各包的主要验收入口如下：

| 包 | 关键命令或用途 |
|---|---|
| `mingw-w64` | `x86_64-w64-mingw32-gcc`，编译 Windows 原生工具和做语法检查 |
| `nsis` | `makensis`，验证并生成 NSIS installer |
| `7zip` | `7z`，解包 NSIS 并核验 PE/DLL 导入闭包 |
| `podman` | 构建仓库的 Fedora win64 cross 镜像 |
| `shellcheck` | Shell 静态检查 |
| `llvm` | LLVM/Clang 相关构建与检查 |
| `ripgrep` | `rg`，测试和维护脚本使用的稳定系统命令 |
| `imagemagick` | `magick`（新版本）或 `convert`（兼容版本），图像工件检查 |

PowerShell 测试还要求 `pwsh`。Ubuntu 默认源不提供当前 PowerShell 包；按
[Microsoft 官方 Ubuntu 安装说明](https://learn.microsoft.com/powershell/scripting/install/install-ubuntu)
安装 PowerShell 7。Windows 目标机运行启动器只需要系统自带的 Windows
PowerShell 5.1，不需要 Python 或 PowerShell 7。

完整 Windows QEMU/NSIS 工件使用仓库维护的 Fedora cross 容器。镜像提供 MinGW
版 GLib、Pixman、SDL2 和 NSIS；slirp 由仓库锁定的 `subprojects/slirp.wrap`
在 configure 时获取并构建：

```bash
podman build \
  --build-arg USER="$USER" --build-arg UID="$(id -u)" \
  -t qemu-win64-cross \
  -f tests/docker/dockerfiles/fedora-win64-cross.docker .
podman run --rm -it --userns=keep-id \
  --user "$USER" -v "$PWD:/work" -w /work qemu-win64-cross bash
```

在启用 SELinux 的开发宿主上，将 bind mount 改为
`-v "$PWD:/work:Z"`；`:Z` 会设置该容器专用标签，不应同时把同一目录挂给其它
容器。容器退出后，`build-win64-vmate` 仍保留在宿主工作树。

因此第一次 configure 仍需要网络。离线构建应事先通过 Meson 下载缓存准备
`subprojects/packagecache`；仅有容器镜像并不构成 slirp 的离线闭包。

若内核禁用了 unprivileged user namespace，rootless Podman 会失败。该限制不影响
Linux/KVM 运行或静态回归；需要构建 cross 镜像时可在受控开发机启用 rootless
前提，或显式使用 `sudo podman ...`。

## 5. 安装后自检

以下检查只验证依赖是否齐全，不会修改网络、启动 VM 或创建安装包：

```bash
for tool in \
  git gcc g++ make bzip2 ninja meson pkg-config python3 \
  swtpm swtpm_setup swtpm_localca jq socat ip bridge flock lsof \
  qemu-nbd ntfsfix rsync \
  nasm iasl uuidgen mcopy mkfs.fat mkfs.vfat \
  shellcheck i686-w64-mingw32-gcc i686-w64-mingw32-g++ \
  x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ \
  i686-w64-mingw32-objdump x86_64-w64-mingw32-objdump \
  x86_64-w64-mingw32-windres llvm-config llvm-readobj \
  xxd file rg makensis 7z pwsh podman
do
  command -v "$tool" >/dev/null || {
    printf 'missing command: %s\n' "$tool" >&2
    exit 1
  }
done

command -v magick >/dev/null || command -v convert >/dev/null
test "$(readlink -f "$(command -v i686-w64-mingw32-gcc)")" = \
  /usr/bin/i686-w64-mingw32-gcc-win32
test "$(readlink -f "$(command -v i686-w64-mingw32-g++)")" = \
  /usr/bin/i686-w64-mingw32-g++-win32
test "$(readlink -f "$(command -v x86_64-w64-mingw32-gcc)")" = \
  /usr/bin/x86_64-w64-mingw32-gcc-posix
test "$(readlink -f "$(command -v x86_64-w64-mingw32-g++)")" = \
  /usr/bin/x86_64-w64-mingw32-g++-posix
test -x /usr/lib/qemu/qemu-bridge-helper
python3 -c 'import wheel, setuptools, venv'
python3 -c 'import hivex'
pkg-config --exists \
  zlib glib-2.0 pixman-1 sdl2 epoxy virglrenderer spice-server slirp libseccomp \
  liburing
test -r /usr/include/libaio.h || pkg-config --exists libaio
```

宿主运行能力另行验证：

```bash
test -r /dev/kvm && test -w /dev/kvm
test -c /dev/net/tun
stat -fc %T /sys/fs/cgroup
grep -w cpuset /sys/fs/cgroup/cgroup.controllers
python3 deploy/scripts/kvm-capabilities.py --format json
```

安装依赖后先跑跨平台快速回归：

```bash
python3 deploy/scripts/tests/run-vmate-tests.py --mode quick --jobs 4
```

发布前再串行执行完整集：

```bash
python3 deploy/scripts/tests/run-vmate-tests.py --mode full
```

Linux 上通过 PowerShell DryRun、MinGW/NSIS 编译和静态测试，只证明 Windows
代码与打包输入闭合；它不能替代真实 Windows 10/11 宿主上的 WHPX 启动、重启、
编码器回退和长稳验收。
