#!/usr/bin/env bash
# Install the exact vGPU 16.4 R535 host stack for a supported Tesla V100.
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

readonly DRIVER_VERSION=535.161.05
readonly DRIVER_PACKAGE=nvidia-vgpu-ubuntu-535
readonly DRIVER_BASENAME=nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb
readonly DRIVER_SHA256=2786430d32b6894f360ce0c249b29f849ae963c186840547151ed00d0feaebb9
readonly MANAGED_ASSET_DIR=/var/lib/vmate/assets/vgpu16.4
readonly STATE_FILE=/etc/vmate/g11-v100-r535.state
readonly DKMS_NO_SIGN_FILE=/run/vmate-dkms-module-signing-disabled
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PATCHER="$here/patch-nvidia-vgpu-r535-linux68.py"

die() {
    echo "[V100/R535] $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
用法：install-v100-r535-host.sh --bdf DDDD:BB:SS.F --driver-deb /绝对路径/官方.deb

只接受 vGPU 16.4 的 535.161.05 官方 amd64 DEB 和 Ubuntu GA 6.8。
不会卸载运行中的驱动，不会创建/注册 MOK，也不会安装自签名模块。
EOF
    exit 2
}

assert_no_module_signing_override() {
    [[ ! -e "$DKMS_NO_SIGN_FILE" ]] \
        || die "DKMS 禁签占位路径不应存在：$DKMS_NO_SIGN_FILE"
    if grep -REqs \
            '^[[:space:]]*(export[[:space:]]+)?sign_file[[:space:]]*=' \
            /etc/dkms/framework.conf /etc/dkms/framework.conf.d 2>/dev/null; then
        die "DKMS 已配置自定义 sign_file；不会覆盖或使用未知签名策略"
    fi
}

dkms_unsigned() {
    assert_no_module_signing_override
    env sign_file="$DKMS_NO_SIGN_FILE" dkms "$@"
}

validate_driver_deb() {
    local path=$1 actual package version architecture
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* \
        && -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
    actual=$(sha256sum -- "$path" | awk '{print $1}')
    package=$(dpkg-deb -f "$path" Package 2>/dev/null || true)
    version=$(dpkg-deb -f "$path" Version 2>/dev/null || true)
    architecture=$(dpkg-deb -f "$path" Architecture 2>/dev/null || true)
    [[ "$actual" == "$DRIVER_SHA256" && "$package" == "$DRIVER_PACKAGE" \
        && "$version" == "$DRIVER_VERSION" && "$architecture" == amd64 ]]
}

secure_boot_disabled() {
    local state
    if [[ ! -d /sys/firmware/efi ]]; then
        echo "[V100/R535] Legacy BIOS 启动；Secure Boot 不适用"
        return
    fi
    command -v mokutil >/dev/null 2>&1 \
        || die "EFI 主机缺少 mokutil，无法可信确认 Secure Boot"
    state=$(mokutil --sb-state 2>&1 || true)
    if grep -Eqi 'SecureBoot disabled|Secure Boot disabled' <<<"$state"; then
        echo "[V100/R535] Secure Boot 已关闭；不使用 MOK 或自签名模块"
    elif grep -Fqi "doesn't support Secure Boot" <<<"$state"; then
        echo "[V100/R535] 固件不支持 Secure Boot；不使用 MOK 或自签名模块"
    else
        die "Secure Boot 未确认关闭：${state:-无输出}；请在 BIOS/UEFI 手工关闭"
    fi
}

require_unsigned_module() {
    local kernel=$1 name=$2 path signer version
    path=$(modinfo -k "$kernel" -n "$name" 2>/dev/null || true)
    [[ -f "$path" && ! -L "$path" ]] \
        || die "找不到 $kernel 的 $name 模块"
    signer=$(modinfo -k "$kernel" -F signer "$name" 2>/dev/null | sed -n '1p')
    [[ -z "$signer" ]] \
        || die "$name 被签名为 ${signer}；拒绝安装测试签名/自签名模块"
    version=$(modinfo -k "$kernel" -F version "$name" 2>/dev/null | sed -n '1p')
    [[ "$version" == "$DRIVER_VERSION" ]] \
        || die "$name 版本不是 $DRIVER_VERSION：${version:-missing}"
}

write_state() {
    local phase=$1 kernel=$2 temporary
    install -d -o root -g root -m 0755 /etc/vmate
    temporary=$(mktemp /etc/vmate/.g11-v100-r535.XXXXXX)
    {
        echo 'schema=1'
        printf 'phase=%s\n' "$phase"
        printf 'kernel=%s\n' "$kernel"
        printf 'target_bdf=%s\n' "$target_bdf"
        printf 'driver_version=%s\n' "$DRIVER_VERSION"
        printf 'driver_sha256=%s\n' "$DRIVER_SHA256"
        printf 'patcher_sha256=%s\n' "$(sha256sum "$PATCHER" | awk '{print $1}')"
    } >"$temporary"
    chmod 0644 "$temporary"
    chown root:root "$temporary"
    mv -fT -- "$temporary" "$STATE_FILE"
}

(( EUID == 0 )) || die "必须以 root 执行"
target_bdf=
driver_deb=
while (($#)); do
    case "$1" in
        --bdf)
            (($# >= 2)) || usage
            target_bdf=${2,,}
            shift 2
            ;;
        --driver-deb)
            (($# >= 2)) || usage
            driver_deb=$2
            shift 2
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[[ "$target_bdf" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ \
    && -n "$driver_deb" ]] || usage
validate_driver_deb "$driver_deb" \
    || die "驱动不是锁定的 $DRIVER_BASENAME（SHA256=$DRIVER_SHA256）"
[[ -f "$PATCHER" && ! -L "$PATCHER" && -x "$PATCHER" ]] \
    || die "R535 Linux 6.8 patcher 缺失或不可信：$PATCHER"

target_sysfs="/sys/bus/pci/devices/$target_bdf"
[[ -d "$target_sysfs" && ! -L "$target_sysfs/vendor" \
    && "$(tr 'A-F' 'a-f' <"$target_sysfs/vendor")" == 0x10de ]] \
    || die "目标不是可读取的 NVIDIA PCI 设备：$target_bdf"
device_id=$(tr 'A-F' 'a-f' <"$target_sysfs/device")
device_id=${device_id#0x}
[[ "$device_id" =~ ^(1db[1-8]|1df[56])$ ]] \
    || die "目标 PCI ID $device_id 不是已审核 Tesla V100"
[[ "$(cat "$target_sysfs/boot_vga" 2>/dev/null || true)" != 1 ]] \
    || die "V100 是 boot_vga；请先把宿主显示固定到另一张显卡"
if find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -print -quit \
        2>/dev/null | grep -q .; then
    die "检测到活动 mdev；请先正常关闭全部 vGPU VM"
fi

kernel=$(uname -r)
[[ "$kernel" == 6.8.*-generic ]] \
    || die "只验证了 Ubuntu GA 6.8 generic；当前 $kernel"
[[ -d "/lib/modules/$kernel/build" ]] \
    || die "缺少当前内核 headers：/lib/modules/$kernel/build"
secure_boot_disabled
assert_no_module_signing_override

loaded=$(cat /sys/module/nvidia/version 2>/dev/null || true)
if [[ -n "$loaded" && "$loaded" != "$DRIVER_VERSION" ]]; then
    die "当前已加载 NVIDIA $loaded；不会在线卸载或跨分支覆盖"
fi
if [[ "$loaded" == "$DRIVER_VERSION" ]]; then
    [[ "$(modinfo -F license nvidia 2>/dev/null | sed -n '1p')" == NVIDIA ]] \
        || die "当前 R535 不是官方闭源 RM"
    require_unsigned_module "$kernel" nvidia
    require_unsigned_module "$kernel" nvidia-vgpu-vfio
    write_state ready "$kernel"
    echo "[V100/R535] 当前 535.161.05 闭源、未签名模块已经就绪；未改运行态"
    exit 0
fi

installed_r580=$(dpkg-query -W -f='${Version}' nvidia-vgpu-ubuntu-580 2>/dev/null || true)
[[ -z "$installed_r580" ]] \
    || die "磁盘已安装 R580 $installed_r580；不会自动跨分支覆盖"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends --no-upgrade \
    dkms build-essential "linux-headers-$kernel" kmod mokutil python3

install -d -o root -g root -m 0755 /var/lib/vmate/assets "$MANAGED_ASSET_DIR"
managed_deb="$MANAGED_ASSET_DIR/$DRIVER_BASENAME"
if [[ ! -e "$managed_deb" ]]; then
    temporary=$(mktemp "$MANAGED_ASSET_DIR/.r535-deb.XXXXXX")
    install -o root -g root -m 0644 "$driver_deb" "$temporary"
    validate_driver_deb "$temporary" || {
        rm -f -- "$temporary"
        die "驱动复制到受管目录后校验失败"
    }
    mv -fT -- "$temporary" "$managed_deb"
fi
validate_driver_deb "$managed_deb" || die "受管 R535 DEB 校验失败：$managed_deb"

echo "[V100/R535] 解包官方 $DRIVER_VERSION 源码（尚不加载模块）"
env sign_file="$DKMS_NO_SIGN_FILE" dpkg --unpack "$managed_deb"
source_root="/usr/src/nvidia-$DRIVER_VERSION"
[[ -d "$source_root" && ! -L "$source_root" ]] \
    || die "官方包没有生成预期源码目录：$source_root"
"$PATCHER" "$source_root"

if ! dkms status -m nvidia -v "$DRIVER_VERSION" 2>/dev/null \
        | grep -Fq "nvidia/$DRIVER_VERSION"; then
    dkms_unsigned add -m nvidia -v "$DRIVER_VERSION"
fi
if ! dkms status -m nvidia -v "$DRIVER_VERSION" -k "$kernel" 2>/dev/null \
        | grep -Fq ': installed'; then
    echo "[V100/R535] 为 $kernel 编译正式 R535 闭源模块"
    IGNORE_CC_MISMATCH=1 dkms_unsigned install \
        -m nvidia -v "$DRIVER_VERSION" -k "$kernel"
fi
env sign_file="$DKMS_NO_SIGN_FILE" dpkg --configure "$DRIVER_PACKAGE"
depmod -a "$kernel"
require_unsigned_module "$kernel" nvidia
require_unsigned_module "$kernel" nvidia-vgpu-vfio
[[ "$(modinfo -k "$kernel" -F license nvidia 2>/dev/null | sed -n '1p')" == NVIDIA ]] \
    || die "构建结果不是官方闭源 RM"
update-initramfs -u -k "$kernel"
write_state installed-reboot-required "$kernel"

# 新主机可以直接加载；任何失败都保留已验证的磁盘模块并要求正常重启，绝不
# 在线卸载其它模块或强制重绑显示设备。
modprobe nvidia || true
modprobe nvidia-vgpu-vfio || true
loaded=$(cat /sys/module/nvidia/version 2>/dev/null || true)
if [[ "$loaded" == "$DRIVER_VERSION" ]]; then
    systemctl daemon-reload
    systemctl enable --now nvidia-vgpu-mgr.service >/dev/null
    systemctl is-active --quiet nvidia-vgpu-mgr.service \
        || die "R535 已加载，但 nvidia-vgpu-mgr.service 未运行"
    write_state ready "$kernel"
    echo "[V100/R535] 正式 R535 host driver 已安装、加载并通过未签名闭源 RM 复检"
else
    echo "[V100/R535] 磁盘模块已就绪；请正常重启到 $kernel 后再次运行 VMate 自动修复"
fi
