#!/usr/bin/env bash
# G-11 host vGPU branch switcher.
#
# RTX 2080 keeps the reviewed R535 <-> R570 path plus R580 staging.  The
# validated Tesla V100 SXM2 16GB path is deliberately narrower: R535 equal
# 1Q <-> vGPU 18.4/R570 mixed 1Q+2Q.  Hardware-specific Hook and framebuffer
# policies are selected here rather than left to operator environment values.
#
# The R535 seed is host-local because it contains NVIDIA proprietary files and
# kernel-specific, locally adapted modules.  Nothing from that seed belongs in
# Git or in a VMate package.
set -euo pipefail
shopt -s nullglob
# System tools invoked below create module indexes and DKMS metadata that must
# remain readable by normal diagnostic tools.  Sensitive cache/seed files are
# independently installed with explicit 0600 modes.
umask 022

readonly R535_VERSION=535.161.05
readonly R570_VERSION=570.172.07
readonly R580_VERSION=580.159.01
readonly R535_PACKAGE=nvidia-vgpu-ubuntu-535
readonly R570_PACKAGE=nvidia-vgpu-ubuntu-570
readonly R580_PACKAGE=nvidia-vgpu-ubuntu-580
readonly R535_DEB_SHA256=2786430d32b6894f360ce0c249b29f849ae963c186840547151ed00d0feaebb9
readonly R570_DEB_SHA256=37e13ef147fe97f77be44736fb4b9996f67355c1f19ef3da7be48a9a4af34fe9
readonly R580_DEB_SHA256=033d2aec703ea366f35cade25207ab30a279b8076eb7382daa31e9649bf3f246
readonly RTX2080_VENDOR_DEVICE=10de:1e82
readonly V100_SXM2_16GB_VENDOR_DEVICE=10de:1db1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly UNLOCK_SETUP="$SCRIPT_DIR/setup-vgpu-unlock.sh"
readonly STATE_ROOT=/var/lib/vmate/g11-vgpu-branch-switch
readonly PACKAGE_CACHE="$STATE_ROOT/packages"
readonly SEED_META="$STATE_ROOT/r535-seed.state"
readonly BRANCH_STATE="$STATE_ROOT/current.state"
readonly GLOBAL_LOCK=/opt/nvidia-modes/state/current
readonly PENDING_STATE="$STATE_ROOT/pending-reboot.state"
readonly DEFAULT_R535_DEB=/home/ubuntu/Downloads/vGPU16.4/Host_Drivers/nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb
readonly DEFAULT_R570_DEB=/home/ubuntu/Downloads/vGPU18.4/Host_Drivers/nvidia-vgpu-ubuntu-570_570.172.07_amd64.deb
readonly DEFAULT_R580_DEB=/home/ubuntu/Downloads/vGPU19.5/Host_Drivers/nvidia-vgpu-ubuntu-580_580.159.01_amd64.deb
readonly CACHED_R535_DEB="$PACKAGE_CACHE/nvidia-vgpu-ubuntu-535_535.161.05_amd64.deb"
readonly CACHED_R570_DEB="$PACKAGE_CACHE/nvidia-vgpu-ubuntu-570_570.172.07_amd64.deb"
readonly CACHED_R580_DEB="$PACKAGE_CACHE/nvidia-vgpu-ubuntu-580_580.159.01_amd64.deb"
# Ubuntu DKMS otherwise signs every locally built module with its generated
# MOK even when Secure Boot is disabled.  Passing an intentionally absent
# signer executable is DKMS' documented control path for leaving modules
# unsigned; the result is verified before any NVIDIA module is loaded.
readonly DKMS_NO_SIGN_FILE=/run/vmate-dkms-module-signing-disabled
readonly POSTBOOT_HELPER_SOURCE="$SCRIPT_DIR/verify-g11-vgpu-branch-postboot.sh"
readonly POSTBOOT_UNIT_SOURCE="$SCRIPT_DIR/vmate-g11-vgpu-branch-verify.service"
readonly V100_R535_INSTALLER="$SCRIPT_DIR/install-v100-r535-host.sh"
readonly HOST_CONFIGURATOR="$SCRIPT_DIR/../configure-g11-vgpu-host.sh"
readonly MIXED_MODE_INSTALLER="$SCRIPT_DIR/install-vgpu-mixed-mode.sh"
readonly POSTBOOT_HELPER=/usr/local/libexec/vmate-g11-vgpu-branch-verify
readonly POSTBOOT_UNIT=/etc/systemd/system/vmate-g11-vgpu-branch-verify.service
readonly QEMU_GATE_DIR=/etc/systemd/system/qemu-vm-server.service.d
readonly QEMU_GATE_FILE="$QEMU_GATE_DIR/20-vmate-g11-vgpu-branch-verify.conf"

COMMAND=status
R535_DEB=
R570_DEB=
R580_DEB=
NO_REBOOT=0
FORCE=0
GPU_BDF=
GPU_KIND=
GPU_VENDOR_DEVICE=
GPU_LABEL=
GPU_PRESET=
KVER="$(uname -r)"
TARGET_REQUEST=
MUTATION_STARTED=0
ROLLBACK_RUNNING=0
REBOOT_REQUIRED=0
GLOBAL_LOCK_HELD=0

log() { printf '[g11-driver-switch] %s\n' "$*" >&2; }
warn() { printf '[g11-driver-switch] WARN: %s\n' "$*" >&2; }
die() { printf '[g11-driver-switch] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
G-11 vGPU 宿主驱动分支切换（RTX 2080 / Tesla V100 SXM2 16GB）

用法：
  switch-g11-vgpu-branch.sh status
  sudo switch-g11-vgpu-branch.sh init-r535 [--r535-deb FILE] [--r570-deb FILE] [--r580-deb FILE]
  sudo switch-g11-vgpu-branch.sh bootstrap-v100-r535 [--r535-deb FILE] [--r570-deb FILE] [--no-reboot]
  sudo switch-g11-vgpu-branch.sh r570 [--r570-deb FILE] [--no-reboot]
  sudo switch-g11-vgpu-branch.sh r580-lab [--r580-deb FILE] [--no-reboot]
  sudo switch-g11-vgpu-branch.sh r535 [--r535-deb FILE] [--no-reboot]
  switch-g11-vgpu-branch.sh doctor

命令：
  status      只读显示当前驱动、RM、包、Hook 和 R535 恢复种子状态。
  init-r535   在当前健康 R535 上建立内核绑定、root-only 的恢复种子。
  bootstrap-v100-r535
              仅用于当前健康 R570/V100 且尚无 R535 种子的首次统一：安装
              R535、发布 equal 1Q 策略、建立恢复种子并进入冷启动验收。
  r570        切到 vGPU 18.4/R570.172.07 闭源 RM；RTX 使用 capability Hook，
              V100 保持 native capability 并启用 mixed 1Q+2Q。
              切换后必须通过自动冷启动验收，才会解除 VM 启动门禁。
  r580-lab    切到 R580.159.01 闭源 RM + RTX capability Hook。
              只供 Guest 582.53 母盘预装/暂存；不能作为生产稳定性证明。
  r535        恢复已验证的 R535.161.05；RTX 稳定档、V100 默认全 1Q 档。
  doctor      输出只读诊断信息。

选项：
  --r535-deb FILE  指定官方 R535.161.05 amd64 DEB 的绝对路径。
  --r570-deb FILE  指定官方 R570.172.07 amd64 DEB 的绝对路径。
  --r580-deb FILE  指定官方 R580.159.01 amd64 DEB 的绝对路径。
  --no-reboot      工程验证用；切换完成后不自动重启。
  --force          仅 init-r535：重建已有的 R535 恢复种子。

硬约束：
  * 不改 Windows BCD，不开启 testsigning/nointegritychecks。
  * 不安装测试签名或自签名内核模块；Secure Boot 开启时直接拒绝。
  * 切换前必须正常关闭全部 QEMU VM，并释放全部 mdev。
  * R535 恢复种子只适用于创建它时的精确内核。
  * V100 只允许 R535/equal-1Q 与 R570/mixed-1Q+2Q；不开放 R580。
EOF
}

parse_args() {
    if (($#)); then
        COMMAND=$1
        shift
    fi
    while (($#)); do
        case "$1" in
            --r535-deb)
                (($# >= 2)) || die '--r535-deb 缺少路径'
                R535_DEB=$2
                shift 2
                ;;
            --r570-deb)
                (($# >= 2)) || die '--r570-deb 缺少路径'
                R570_DEB=$2
                shift 2
                ;;
            --r580-deb)
                (($# >= 2)) || die '--r580-deb 缺少路径'
                R580_DEB=$2
                shift 2
                ;;
            --no-reboot) NO_REBOOT=1; shift ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数：$1" ;;
        esac
    done
    case "$COMMAND" in
        status|init-r535|bootstrap-v100-r535|r535|r570|r580-lab|doctor) ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage >&2; die "未知命令：$COMMAND" ;;
    esac
    if [[ "$COMMAND" != init-r535 && $FORCE == 1 ]]; then
        die '--force 只能与 init-r535 一起使用'
    fi
}

require_root() {
    ((EUID == 0)) || die "该命令需要 root：sudo $0 $COMMAND"
}

require_commands() {
    local command_name
    for command_name in apt-mark awk date depmod dkms dpkg dpkg-deb dpkg-query \
        find flock grep install lspci lsmod modinfo modprobe mokutil nvidia-smi \
        pgrep ps readlink rmdir rmmod sha256sum sleep systemctl tar \
        stat update-initramfs zstd; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少依赖命令：$command_name"
    done
    [[ -d "/lib/modules/$KVER/build" ]] || \
        die "缺少当前内核头文件：/lib/modules/$KVER/build"
    [[ -x "$UNLOCK_SETUP" && ! -L "$UNLOCK_SETUP" ]] || \
        die "Hook 安装器缺失或不安全：$UNLOCK_SETUP"
    [[ -x "$POSTBOOT_HELPER_SOURCE" && ! -L "$POSTBOOT_HELPER_SOURCE" ]] || \
        die "冷启动验收器缺失或不安全：$POSTBOOT_HELPER_SOURCE"
    [[ -f "$POSTBOOT_UNIT_SOURCE" && ! -L "$POSTBOOT_UNIT_SOURCE" ]] || \
        die "冷启动验收 unit 缺失或不安全：$POSTBOOT_UNIT_SOURCE"
    [[ -x "$V100_R535_INSTALLER" && ! -L "$V100_R535_INSTALLER" ]] || \
        die "V100 R535 安装封装缺失或不安全：$V100_R535_INSTALLER"
    [[ -x "$HOST_CONFIGURATOR" && ! -L "$HOST_CONFIGURATOR" ]] || \
        die "宿主策略生成器缺失或不安全：$HOST_CONFIGURATOR"
    [[ -x "$MIXED_MODE_INSTALLER" && ! -L "$MIXED_MODE_INSTALLER" ]] || \
        die "V100 mixed-mode 封装缺失或不安全：$MIXED_MODE_INSTALLER"
}

secure_boot_must_be_disabled() {
    local state
    state=$(mokutil --sb-state 2>&1 || true)
    if grep -Fqi 'SecureBoot disabled' <<<"$state"; then
        return 0
    fi
    if grep -Fqi 'EFI variables are not supported' <<<"$state"; then
        log '当前不是可用的 UEFI Secure Boot 环境；无需模块签名'
        return 0
    fi
    if grep -Fqi "doesn't support Secure Boot" <<<"$state"; then
        log '固件不支持 Secure Boot；无需模块签名'
        return 0
    fi
    printf '%s\n' "$state" >&2
    die 'Secure Boot 未确认关闭；脚本不会安装自签名模块或修改启动策略'
}

detect_supported_gpu() {
    local device_dir vendor device class bdf
    local -a matches=()
    for device_dir in /sys/bus/pci/devices/*; do
        [[ -r "$device_dir/vendor" && -r "$device_dir/device" && \
           -r "$device_dir/class" ]] || continue
        read -r vendor <"$device_dir/vendor"
        [[ "${vendor,,}" == 0x10de ]] || continue
        read -r class <"$device_dir/class"
        case "${class,,}" in 0x030000|0x030200) ;; *) continue ;; esac
        read -r device <"$device_dir/device"
        bdf=${device_dir##*/}
        matches+=("$bdf:${device#0x}")
    done
    ((${#matches[@]} == 1)) || {
        printf '检测到的 NVIDIA 显示设备：%s\n' "${matches[*]:-(none)}" >&2
        die '该封装要求恰好一张已审核的 NVIDIA RTX 2080 或 Tesla V100 显示设备'
    }
    GPU_BDF=${matches[0]%:*}
    local device_id=${matches[0]##*:}
    GPU_VENDOR_DEVICE="10de:${device_id,,}"
    case "$GPU_VENDOR_DEVICE" in
        "$RTX2080_VENDOR_DEVICE")
            GPU_KIND=rtx2080
            GPU_LABEL='RTX 2080'
            GPU_PRESET=rtx2080-16gb
            ;;
        "$V100_SXM2_16GB_VENDOR_DEVICE")
            GPU_KIND=v100
            GPU_LABEL='Tesla V100 SXM2 16GB'
            GPU_PRESET=v100-sxm2-16gb
            ;;
        *)
            lspci -Dnns "$GPU_BDF" >&2 || true
            die "GPU 不是已验证的 $RTX2080_VENDOR_DEVICE 或 $V100_SXM2_16GB_VENDOR_DEVICE"
            ;;
    esac
}

expected_hook_policy() {
    local branch=$1
    case "$branch:$GPU_KIND" in
        r535:rtx2080|r535:v100) printf 'r535_unlock_policy=consumer\n' ;;
        r570:rtx2080) printf 'r570_unlock_policy=consumer\n' ;;
        r570:v100) printf 'r570_unlock_policy=native\n' ;;
        r580-lab:rtx2080) printf 'r580_unlock_policy=consumer-lab\n' ;;
        *) die "硬件 $GPU_LABEL 不支持分支 $branch" ;;
    esac
}

expected_hook_label() {
    local branch=$1
    case "$branch:$GPU_KIND" in
        r535:rtx2080|r535:v100) printf 'r535-consumer\n' ;;
        r570:rtx2080) printf 'r570-consumer\n' ;;
        r570:v100) printf 'r570-native\n' ;;
        r580-lab:rtx2080) printf 'r580-consumer-lab\n' ;;
        *) die "硬件 $GPU_LABEL 不支持分支 $branch" ;;
    esac
}

state_value() {
    local file=$1 key=$2
    [[ -r "$file" && ! -L "$file" ]] || return 1
    awk -F= -v wanted="$key" '$1 == wanted {value=substr($0, index($0, "=")+1); count++} END {if (count == 1) print value; else exit 1}' "$file"
}

package_status() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true
}

package_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

loaded_version() {
    cat /sys/module/nvidia/version 2>/dev/null || true
}

module_license() {
    modinfo -F license nvidia 2>/dev/null | head -n 1 || true
}

module_signer() {
    modinfo -F signer nvidia 2>/dev/null | head -n 1 || true
}

assert_dkms_no_sign_environment() {
    [[ ! -e "$DKMS_NO_SIGN_FILE" ]] || \
        die "DKMS 禁签占位路径不应存在：$DKMS_NO_SIGN_FILE"
    if grep -REqs \
            '^[[:space:]]*(export[[:space:]]+)?sign_file[[:space:]]*=' \
            /etc/dkms/framework.conf /etc/dkms/framework.conf.d \
            2>/dev/null; then
        grep -REn \
            '^[[:space:]]*(export[[:space:]]+)?sign_file[[:space:]]*=' \
            /etc/dkms/framework.conf /etc/dkms/framework.conf.d \
            2>/dev/null >&2 || true
        die 'DKMS 已配置自定义 sign_file；为避免覆盖本机策略，拒绝继续'
    fi
}

dpkg_without_module_signing() {
    assert_dkms_no_sign_environment
    env DEBIAN_FRONTEND=noninteractive sign_file="$DKMS_NO_SIGN_FILE" dpkg "$@"
}

dkms_without_module_signing() {
    assert_dkms_no_sign_environment
    env sign_file="$DKMS_NO_SIGN_FILE" dkms "$@"
}

assert_nvidia_modules_unsigned() {
    local module signer
    local -i found=0
    for module in "/lib/modules/$KVER/updates/dkms/"nvidia*.ko*; do
        [[ -f "$module" && ! -L "$module" ]] || continue
        found+=1
        signer=$(modinfo -F signer "$module" 2>/dev/null || true)
        [[ -z "$signer" ]] || \
            die "检测到签名内核模块（signer=$signer）：$module"
    done
    ((found >= 2)) || die "当前内核的 NVIDIA 模块不完整：$KVER"
}

assert_module_index_readable() {
    local index="/lib/modules/$KVER/modules.dep" mode
    [[ -f "$index" && ! -L "$index" ]] || die "模块索引缺失：$index"
    mode=$(stat -c '%a' "$index")
    (((8#$mode & 0044) == 0044)) || \
        die "模块索引必须可供普通诊断读取（当前 mode=$mode）：$index"
}

hook_policy() {
    local state=/etc/vgpu_unlock/g11-hook.state
    if [[ ! -r "$state" ]]; then
        printf 'missing\n'
    elif grep -Fxq 'r535_unlock_policy=consumer' "$state"; then
        printf 'r535-consumer\n'
    elif grep -Fxq 'r570_unlock_policy=consumer' "$state"; then
        printf 'r570-consumer\n'
    elif grep -Fxq 'r570_unlock_policy=native' "$state"; then
        printf 'r570-native\n'
    elif grep -Fxq 'r580_unlock_policy=consumer-lab' "$state"; then
        printf 'r580-consumer-lab\n'
    elif grep -Fxq 'r580_unlock_policy=native' "$state"; then
        printf 'r580-native\n'
    else
        printf 'unknown\n'
    fi
}

show_host_fb_policy() {
    local config=/etc/vmate/g11-vgpu-host.conf
    if [[ ! -r "$config" || -L "$config" ]]; then
        config="$SCRIPT_DIR/vgpu-host.conf"
    fi
    if [[ ! -r "$config" || -L "$config" ]]; then
        printf '宿主 FB 策略 : 未在 %s 找到（驱动切换不修改它）\n' "$config"
        return
    fi
    local mode tier
    mode=$(state_value "$config" VGPU_HOST_FB_MODE || true)
    tier=$(state_value "$config" VGPU_HOST_FB_TIER_MB || true)
    printf '宿主 FB 策略 : %s%s (%s)\n' \
        "${mode:-unknown}" "${tier:+/${tier}MB}" "$config"
}

cmd_status() {
    detect_supported_gpu || true
    local version license signer seed_kernel seed_archive branch branch_status
    local package535 package570 package580
    version=$(loaded_version)
    license=$(module_license)
    signer=$(module_signer)
    seed_kernel=$(state_value "$SEED_META" kernel || true)
    seed_archive=$(state_value "$SEED_META" archive || true)
    branch=$(state_value "$BRANCH_STATE" branch || true)
    branch_status=$(state_value "$BRANCH_STATE" status || true)
    package535="$(package_status "$R535_PACKAGE")/$(package_version "$R535_PACKAGE")"
    package570="$(package_status "$R570_PACKAGE")/$(package_version "$R570_PACKAGE")"
    package580="$(package_status "$R580_PACKAGE")/$(package_version "$R580_PACKAGE")"
    printf 'GPU            : %s (%s%s)\n' "${GPU_BDF:-未唯一识别}" \
        "${GPU_VENDOR_DEVICE:-unknown}" "${GPU_LABEL:+ / $GPU_LABEL}"
    printf '当前内核       : %s\n' "$KVER"
    printf '已加载驱动     : %s\n' "${version:-none}"
    printf '内核 RM        : %s\n' "${license:-none}"
    printf '模块签名者     : %s\n' "${signer:-none（未签名）}"
    printf '脚本记录分支   : %s/%s\n' "${branch:-unknown}" "${branch_status:-unknown}"
    printf 'Hook 策略      : %s\n' "$(hook_policy)"
    printf 'R535 dpkg      : %s\n' "$package535"
    printf 'R570 dpkg      : %s\n' "$package570"
    printf 'R580 dpkg      : %s\n' "$package580"
    if [[ -n "$seed_kernel" && -n "$seed_archive" ]]; then
        printf 'R535 恢复种子  : ready (kernel=%s, archive=%s)\n' \
            "$seed_kernel" "$seed_archive"
    else
        printf 'R535 恢复种子  : missing（先 sudo %s init-r535）\n' "$0"
    fi
    show_host_fb_policy
    if [[ "$version" == "$R580_VERSION" ]]; then
        printf '稳定性结论     : R580/RTX 仅限母盘暂存；已观察到 XID 43/TDR\n'
    elif [[ "$version" == "$R570_VERSION" && "$GPU_KIND" == v100 ]]; then
        printf '稳定性结论     : V100 vGPU 18.4；已审核 mixed 1Q+2Q 分支\n'
    elif [[ "$version" == "$R570_VERSION" ]]; then
        printf '稳定性结论     : R570/RTX 分支；以本次冷启动/Guest 快速验收状态为准\n'
    elif [[ "$version" == "$R535_VERSION" && "$GPU_KIND" == v100 ]]; then
        printf '稳定性结论     : V100 R535 兼容分支；固定 equal 1Q\n'
    elif [[ "$version" == "$R535_VERSION" ]]; then
        printf '稳定性结论     : R535 本机生产分支\n'
    fi
}

validate_deb() {
    local path=$1 expected_package=$2 expected_version=$3 expected_sha=$4
    [[ "$path" == /* ]] || die "DEB 必须使用绝对路径：$path"
    [[ -f "$path" && ! -L "$path" ]] || die "DEB 缺失或是链接：$path"
    [[ "$(dpkg-deb -f "$path" Package)" == "$expected_package" ]] || \
        die "DEB 包名不匹配：$path"
    [[ "$(dpkg-deb -f "$path" Version)" == "$expected_version" ]] || \
        die "DEB 版本不是 $expected_version：$path"
    [[ "$(dpkg-deb -f "$path" Architecture)" == amd64 ]] || \
        die "DEB 架构不是 amd64：$path"
    local actual_sha
    actual_sha=$(sha256sum "$path" | awk '{print $1}')
    [[ "$actual_sha" == "$expected_sha" ]] || {
        printf '实际 SHA256: %s\n期望 SHA256: %s\n' "$actual_sha" "$expected_sha" >&2
        die "官方 DEB 哈希不匹配：$path"
    }
}

select_deb() {
    local requested=$1 cached=$2 fallback=$3 package=$4 version=$5 sha=$6
    local selected
    if [[ -n "$requested" ]]; then
        selected=$requested
    elif [[ -f "$cached" && ! -L "$cached" ]]; then
        selected=$cached
    else
        selected=$fallback
    fi
    validate_deb "$selected" "$package" "$version" "$sha"
    printf '%s\n' "$selected"
}

cache_deb() {
    local source=$1 destination=$2
    install -d -o root -g root -m 0755 "$STATE_ROOT"
    install -d -o root -g root -m 0700 "$PACKAGE_CACHE"
    if [[ "$source" != "$destination" ]]; then
        install -o root -g root -m 0600 "$source" "$destination"
    else
        chmod 0600 "$destination"
    fi
}

seed_archive_path() {
    printf '%s/r535-%s.tar.zst\n' "$STATE_ROOT" "$KVER"
}

write_seed_meta() {
    local archive=$1 archive_sha=$2 temp
    temp=$(mktemp "$STATE_ROOT/.r535-seed.state.XXXXXXXX")
    {
        echo 'schema=1'
        printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'kernel=%s\n' "$KVER"
        printf 'gpu=%s\n' "$GPU_BDF"
        printf 'gpu_vendor_device=%s\n' "$GPU_VENDOR_DEVICE"
        printf 'driver_version=%s\n' "$R535_VERSION"
        echo 'module_license=NVIDIA'
        echo 'module_signature=none'
        printf 'r535_deb_sha256=%s\n' "$R535_DEB_SHA256"
        printf 'archive=%s\n' "$archive"
        printf 'archive_sha256=%s\n' "$archive_sha"
    } >"$temp"
    install -o root -g root -m 0644 "$temp" "$SEED_META"
    rm -f -- "$temp"
}

verify_r535_seed() {
    [[ -f "$SEED_META" && ! -L "$SEED_META" ]] || \
        die "R535 恢复种子缺失；健康 R535 用 init-r535，健康 V100/R570 首次用 bootstrap-v100-r535"
    local seed_kernel seed_gpu_id seed_version seed_license seed_signature archive expected actual
    seed_kernel=$(state_value "$SEED_META" kernel) || die 'R535 种子缺少 kernel'
    seed_gpu_id=$(state_value "$SEED_META" gpu_vendor_device) || die 'R535 种子缺少 GPU ID'
    seed_version=$(state_value "$SEED_META" driver_version) || die 'R535 种子缺少驱动版本'
    seed_license=$(state_value "$SEED_META" module_license) || die 'R535 种子缺少 RM 类型'
    seed_signature=$(state_value "$SEED_META" module_signature) || \
        die 'R535 种子缺少 module_signature；请在未签名 R535 上用 --force 重建'
    archive=$(state_value "$SEED_META" archive) || die 'R535 种子缺少 archive'
    expected=$(state_value "$SEED_META" archive_sha256) || die 'R535 种子缺少 archive SHA256'
    [[ "$seed_kernel" == "$KVER" ]] || \
        die "R535 种子绑定内核 $seed_kernel，当前是 $KVER；禁止跨内核恢复"
    [[ "$seed_gpu_id" == "$GPU_VENDOR_DEVICE" && \
       "$seed_version" == "$R535_VERSION" && "$seed_license" == NVIDIA && \
       "$seed_signature" == none ]] || \
        die 'R535 种子身份与当前已验证分支不匹配'
    [[ "$archive" == "$STATE_ROOT"/* && -f "$archive" && ! -L "$archive" ]] || \
        die "R535 种子归档路径不安全：$archive"
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || die 'R535 种子归档 SHA256 复验失败'
    validate_deb "$CACHED_R535_DEB" "$R535_PACKAGE" "$R535_VERSION" "$R535_DEB_SHA256"
}

cmd_init_r535() {
    require_root
    require_commands
    secure_boot_must_be_disabled
    detect_supported_gpu
    [[ "$(loaded_version)" == "$R535_VERSION" ]] || \
        die "init-r535 必须在已加载 $R535_VERSION 时执行"
    [[ "$(module_license)" == NVIDIA ]] || \
        die '当前不是 NVIDIA 闭源 RM；拒绝建立恢复种子'
    [[ "$(package_status "$R535_PACKAGE")" == installed && \
       "$(package_version "$R535_PACKAGE")" == "$R535_VERSION" ]] || \
        die "dpkg 中没有完整安装 $R535_PACKAGE/$R535_VERSION"
    [[ -d "/usr/src/nvidia-$R535_VERSION" && \
       ! -L "/usr/src/nvidia-$R535_VERSION" ]] || \
        die 'R535 已适配 DKMS 源码树缺失或不安全'
    [[ -d /usr/share/nvidia/vgpu && ! -L /usr/share/nvidia/vgpu ]] || \
        die 'R535 vGPU 数据目录缺失或不安全'

    local selected535 selected570 selected580 archive temp_archive archive_sha module
    local -a modules=()
    selected535=$(select_deb "$R535_DEB" "$CACHED_R535_DEB" "$DEFAULT_R535_DEB" \
        "$R535_PACKAGE" "$R535_VERSION" "$R535_DEB_SHA256")
    for module in "/lib/modules/$KVER/updates/dkms/"nvidia*.ko*; do
        [[ -f "$module" && ! -L "$module" ]] || continue
        modules+=("${module#/}")
    done
    ((${#modules[@]} >= 2)) || die '当前内核的 R535 NVIDIA 模块不完整'
    modinfo -k "$KVER" -F version nvidia | grep -Fxq "$R535_VERSION" || \
        die '磁盘上的 nvidia.ko 版本不是 R535.161.05'
    modinfo -k "$KVER" -F license nvidia | grep -Fxq NVIDIA || \
        die '磁盘上的 nvidia.ko 不是 NVIDIA 闭源 RM'
    assert_nvidia_modules_unsigned

    install -d -o root -g root -m 0755 "$STATE_ROOT"
    install -d -o root -g root -m 0700 "$PACKAGE_CACHE"
    archive=$(seed_archive_path)
    if [[ -e "$SEED_META" || -e "$archive" ]]; then
        ((FORCE)) || die 'R535 种子已存在；确认当前 R535 健康后用 --force 重建'
    fi
    cache_deb "$selected535" "$CACHED_R535_DEB"
    if selected570=$(select_deb "$R570_DEB" "$CACHED_R570_DEB" "$DEFAULT_R570_DEB" \
            "$R570_PACKAGE" "$R570_VERSION" "$R570_DEB_SHA256" 2>/dev/null); then
        cache_deb "$selected570" "$CACHED_R570_DEB"
        log '已同时缓存并校验官方 R570.172.07 DEB'
    else
        warn '未缓存 R570 DEB；首次切换时用 --r570-deb 指定'
    fi
    if [[ "$GPU_KIND" == rtx2080 ]]; then
        if selected580=$(select_deb "$R580_DEB" "$CACHED_R580_DEB" "$DEFAULT_R580_DEB" \
                "$R580_PACKAGE" "$R580_VERSION" "$R580_DEB_SHA256" 2>/dev/null); then
            cache_deb "$selected580" "$CACHED_R580_DEB"
            log '已同时缓存并校验官方 R580.159.01 DEB'
        else
            warn '未缓存 R580 DEB；首次切换时用 --r580-deb 指定'
        fi
    fi

    temp_archive=$(mktemp "$STATE_ROOT/.r535-$KVER.XXXXXXXX.tar.zst")
    log "建立 R535 内核绑定恢复种子：$archive"
    tar --zstd --xattrs --acls --numeric-owner -C / -cpf "$temp_archive" \
        "usr/src/nvidia-$R535_VERSION" \
        usr/share/nvidia/vgpu \
        "${modules[@]}"
    tar --zstd -tf "$temp_archive" >/dev/null
    install -o root -g root -m 0600 "$temp_archive" "$archive"
    rm -f -- "$temp_archive"
    archive_sha=$(sha256sum "$archive" | awk '{print $1}')
    write_seed_meta "$archive" "$archive_sha"
    log 'R535 恢复种子创建并复验完成'
    cmd_status
}

acquire_global_lock() {
    [[ -f "$GLOBAL_LOCK" && ! -L "$GLOBAL_LOCK" && -r "$GLOBAL_LOCK" ]] || \
        die "vGPU 全局锁缺失或不安全：$GLOBAL_LOCK"
    exec 9<"$GLOBAL_LOCK"
    flock -n 9 || die 'GPU mode、mdev 分配或另一个驱动切换正在运行'
    GLOBAL_LOCK_HELD=1
}

assert_no_vm_or_mdev() {
    local exe executable pid
    local -a qemu_pids=()
    # /proc/PID/stat comm is limited to 15 bytes, so `pgrep -x
    # qemu-system-x86_64` silently misses the real process.  Resolve the
    # executable symlink instead and do not depend on argv text.
    for exe in /proc/[0-9]*/exe; do
        [[ -L "$exe" ]] || continue
        executable=$(readlink -- "$exe" 2>/dev/null || true)
        executable=${executable% (deleted)}
        case "${executable##*/}" in
            qemu-system-x86_64|qemu-system-x86_64.g11.real) ;;
            *) continue ;;
        esac
        pid=${exe#/proc/}
        qemu_pids+=("${pid%/exe}")
    done
    if ((${#qemu_pids[@]})); then
        ps -fp "$(IFS=,; echo "${qemu_pids[*]}")" >&2 || true
        die '仍有 QEMU VM；请先用 stop-vm.sh 正常关机，脚本不会强杀 Guest'
    fi
    if find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -print -quit \
            2>/dev/null | grep -q .; then
        find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -printf '%f\n' >&2
        die '仍有活动 mdev；先正常关闭全部 vGPU VM'
    fi
}

stop_driver_stack() {
    log '停止 vGPU 服务并卸载 NVIDIA 模块'
    # NVIDIA's DEB postinst calls `systemctl reenable`; a runtime mask makes
    # that package transaction fail.  Stop services here, then stop them again
    # immediately after each dpkg transaction instead of masking their units.
    systemctl unmask --runtime nvidia-vgpu-mgr.service nvidia-vgpud.service \
        >/dev/null 2>&1 || true
    systemctl stop nvidia-vgpu-mgr.service nvidia-vgpud.service \
        nvidia-persistenced.service 2>/dev/null || true
    local module
    for module in nvidia_vgpu_vfio nvidia_drm nvidia_modeset nvidia_uvm \
        nvidia_peermem nvidia; do
        if lsmod | awk '{print $1}' | grep -Fxq "$module"; then
            rmmod "$module" || {
                command -v lsof >/dev/null 2>&1 && \
                    lsof /dev/nvidiactl /dev/nvidia* 2>/dev/null | head -n 30 >&2 || true
                die "无法卸载 $module；仍有进程占用 NVIDIA GPU"
            }
        fi
    done
}

unmask_driver_services() {
    systemctl unmask --runtime nvidia-vgpu-mgr.service nvidia-vgpud.service \
        >/dev/null 2>&1 || true
    systemctl daemon-reload || true
}

purge_vgpu_package() {
    local package=$1 version=$2
    apt-mark unhold "$package" >/dev/null 2>&1 || true
    if [[ -n "$(package_status "$package")" ]]; then
        log "移除 $package（$version）"
        DEBIAN_FRONTEND=noninteractive dpkg --purge "$package"
    fi
    dkms remove -m nvidia -v "$version" --all >/dev/null 2>&1 || true
    dkms remove -m nvidia -v "$version-open" --all >/dev/null 2>&1 || true
}

remove_exact_source_tree() {
    local path=$1 expected=$2
    [[ "$path" == "/usr/src/nvidia-$expected" && -d "$path" && ! -L "$path" ]] || return 0
    find -P "$path" -depth -mindepth 1 -delete
    rmdir -- "$path"
}

run_unlock_setup() {
    local branch=$1
    local -a environment=() setup_args=(--restart-manager --no-tests)
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root && \
          "$SUDO_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        environment+=("G11_BUILD_USER=$SUDO_USER")
    fi
    case "$branch" in
        r570)
            [[ "$GPU_KIND" == v100 ]] || setup_args+=(--r570-consumer)
            ;;
        r580-lab) setup_args+=(--r580-consumer-lab) ;;
    esac
    env "${environment[@]}" "$UNLOCK_SETUP" "${setup_args[@]}"
}

release_global_lock() {
    ((GLOBAL_LOCK_HELD)) || return 0
    flock -u 9 2>/dev/null || true
    exec 9<&-
    GLOBAL_LOCK_HELD=0
}

publish_v100_branch_policy() {
    local branch=$1 mode tier owner group destination_temp
    local -a args
    [[ "$GPU_KIND" == v100 ]] || return 0

    # Both the mixed helper and the policy generator take the same persistent
    # host lock.  The branch mutation is complete and the postboot VM gate is
    # already pending before this function is called, so hand the lock to
    # those reviewed publishers instead of recursively deadlocking on it.
    release_global_lock
    case "$branch" in
        r535)
            "$MIXED_MODE_INSTALLER" --remove
            mode=equal
            tier=1024
            ;;
        r570)
            "$MIXED_MODE_INSTALLER" --bdf "$GPU_BDF"
            mode=mixed
            tier=
            ;;
        *) die "V100 不支持宿主策略分支：$branch" ;;
    esac

    args=(--preset "$GPU_PRESET" --fb-mode "$mode" --gpu "$GPU_BDF"
          --output /etc/vmate/g11-vgpu-host.conf --force)
    [[ -z "$tier" ]] || args+=(--tier "$tier")
    "$HOST_CONFIGURATOR" "${args[@]}"

    # CLI vmctl defaults to the repository-local ignored copy while VMate uses
    # /etc.  Publish the exact same non-secret policy atomically to both so a
    # branch switch cannot leave two contradictory framebuffer contracts.
    [[ ! -L "$SCRIPT_DIR/vgpu-host.conf" ]] || \
        die "拒绝覆盖符号链接：$SCRIPT_DIR/vgpu-host.conf"
    owner=$(stat -c '%u' "$SCRIPT_DIR")
    group=$(stat -c '%g' "$SCRIPT_DIR")
    destination_temp=$(mktemp "$SCRIPT_DIR/.vgpu-host.conf.XXXXXXXX")
    install -o "$owner" -g "$group" -m 0644 \
        /etc/vmate/g11-vgpu-host.conf "$destination_temp"
    mv -fT -- "$destination_temp" "$SCRIPT_DIR/vgpu-host.conf"
}

wait_for_mdev_types() {
    local types_dir="/sys/bus/pci/devices/$GPU_BDF/mdev_supported_types"
    local -i attempts_left=20
    while ((attempts_left-- > 0)); do
        if [[ -d "$types_dir" ]] && \
                find "$types_dir" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then
            return 0
        fi
        sleep 1
    done
    die "20 秒内未发布 mdev types：$types_dir"
}

validate_runtime() {
    local expected_version=$1 expected_policy=$2
    depmod -a "$KVER"
    assert_module_index_readable
    [[ "$(modinfo -k "$KVER" -F version nvidia 2>/dev/null || true)" == \
        "$expected_version" ]] || die 'modules.dep 中的 NVIDIA 版本不匹配'
    [[ "$(loaded_version)" == "$expected_version" ]] || \
        die "加载的 NVIDIA 版本不是 $expected_version"
    [[ "$(module_license)" == NVIDIA ]] || \
        die '加载的不是 NVIDIA 闭源 RM'
    assert_nvidia_modules_unsigned
    [[ -z "$(module_signer)" ]] || \
        die "加载模块带签名，拒绝继续：$(module_signer)"
    systemctl is-active --quiet nvidia-vgpu-mgr.service || \
        die 'nvidia-vgpu-mgr 未运行'
    grep -Fxq "$expected_policy" /etc/vgpu_unlock/g11-hook.state || \
        die "Hook 策略未达到预期：$expected_policy"
    wait_for_mdev_types
    nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader
}

validate_runtime_before_reboot() {
    local expected_version=$1 expected_policy=$2
    depmod -a "$KVER"
    assert_module_index_readable
    [[ "$(modinfo -k "$KVER" -F version nvidia 2>/dev/null || true)" == \
        "$expected_version" ]] || die 'modules.dep 中的 NVIDIA 版本不匹配'
    [[ "$(loaded_version)" == "$expected_version" ]] || \
        die "加载的 NVIDIA 版本不是 $expected_version"
    [[ "$(module_license)" == NVIDIA ]] || die '加载的不是 NVIDIA 闭源 RM'
    assert_nvidia_modules_unsigned
    [[ -z "$(module_signer)" ]] || die "加载模块带签名，拒绝继续：$(module_signer)"
    systemctl is-active --quiet nvidia-vgpu-mgr.service || \
        die 'nvidia-vgpu-mgr 未运行'
    grep -Fxq "$expected_policy" /etc/vgpu_unlock/g11-hook.state || \
        die "Hook 策略未达到预期：$expected_policy"
    nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader
}

write_branch_state() {
    local branch=$1 status=$2 temp
    install -d -o root -g root -m 0755 "$STATE_ROOT"
    temp=$(mktemp "$STATE_ROOT/.current.state.XXXXXXXX")
    {
        echo 'schema=1'
        printf 'updated_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'branch=%s\n' "$branch"
        printf 'status=%s\n' "$status"
        printf 'kernel=%s\n' "$KVER"
        printf 'gpu=%s\n' "$GPU_BDF"
    } >"$temp"
    install -o root -g root -m 0644 "$temp" "$BRANCH_STATE"
    rm -f -- "$temp"
}

install_postboot_verifier() {
    local gate_tmp
    install -d -o root -g root -m 0755 /usr/local/libexec /etc/systemd/system \
        "$QEMU_GATE_DIR"
    install -o root -g root -m 0755 "$POSTBOOT_HELPER_SOURCE" "$POSTBOOT_HELPER"
    install -o root -g root -m 0644 "$POSTBOOT_UNIT_SOURCE" "$POSTBOOT_UNIT"
    gate_tmp=$(mktemp)
    cat >"$gate_tmp" <<'EOF'
[Unit]
After=vmate-g11-vgpu-branch-verify.service

[Service]
# Ordering alone does not make a failed oneshot block this service.  The same
# verifier is therefore an ExecStartPre gate; without a pending state it is a
# cheap no-op, and with one it must clear that state successfully.
ExecStartPre=/usr/local/libexec/vmate-g11-vgpu-branch-verify
EOF
    install -o root -g root -m 0644 "$gate_tmp" "$QEMU_GATE_FILE"
    rm -f -- "$gate_tmp"
    systemctl daemon-reload
    systemctl enable vmate-g11-vgpu-branch-verify.service >/dev/null
}

queue_postboot_validation() {
    local branch=$1 temp
    install_postboot_verifier
    install -d -o root -g root -m 0755 "$STATE_ROOT"
    temp=$(mktemp "$STATE_ROOT/.pending-reboot.state.XXXXXXXX")
    {
        echo 'schema=1'
        printf 'requested_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'branch=%s\n' "$branch"
        printf 'kernel=%s\n' "$KVER"
        printf 'gpu=%s\n' "$GPU_BDF"
        printf 'gpu_vendor_device=%s\n' "$GPU_VENDOR_DEVICE"
    } >"$temp"
    install -o root -g root -m 0644 "$temp" "$PENDING_STATE"
    rm -f -- "$temp"
    write_branch_state "$branch" pending-reboot
    REBOOT_REQUIRED=1
}

restore_r535_core() {
    local archive selected535
    verify_r535_seed
    selected535=$(select_deb "$R535_DEB" "$CACHED_R535_DEB" "$CACHED_R535_DEB" \
        "$R535_PACKAGE" "$R535_VERSION" "$R535_DEB_SHA256")
    cache_deb "$selected535" "$CACHED_R535_DEB"
    archive=$(state_value "$SEED_META" archive)

    stop_driver_stack
    purge_vgpu_package "$R570_PACKAGE" "$R570_VERSION"
    purge_vgpu_package "$R580_PACKAGE" "$R580_VERSION"
    purge_vgpu_package "$R535_PACKAGE" "$R535_VERSION"
    MUTATION_STARTED=1

    log '解包官方 R535，再覆盖本机已适配的 DKMS 源码'
    dpkg_without_module_signing --unpack "$CACHED_R535_DEB"
    remove_exact_source_tree "/usr/src/nvidia-$R535_VERSION" "$R535_VERSION"
    tar --zstd --xattrs --acls --numeric-owner -xpf "$archive" -C / \
        "usr/src/nvidia-$R535_VERSION"
    dpkg_without_module_signing --configure "$R535_PACKAGE"
    systemctl stop nvidia-vgpu-mgr.service nvidia-vgpud.service 2>/dev/null || true

    # Restore profile data only.  Older seeds may contain modules that Ubuntu
    # DKMS automatically MOK-signed; never copy those back over this unsigned
    # build.  A new seed is captured after the first clean migration.
    tar --zstd --xattrs --acls --numeric-owner -xpf "$archive" -C / \
        usr/share/nvidia/vgpu
    depmod -a "$KVER"
    assert_nvidia_modules_unsigned
    modprobe nvidia
    modprobe nvidia_vgpu_vfio
    unmask_driver_services
    run_unlock_setup r535
    apt-mark hold "$R535_PACKAGE" >/dev/null
    update-initramfs -u -k "$KVER"
    validate_runtime_before_reboot "$R535_VERSION" \
        "$(expected_hook_policy r535)"
    queue_postboot_validation r535
}

switch_to_r570() {
    local selected570
    verify_r535_seed
    selected570=$(select_deb "$R570_DEB" "$CACHED_R570_DEB" "$DEFAULT_R570_DEB" \
        "$R570_PACKAGE" "$R570_VERSION" "$R570_DEB_SHA256")
    cache_deb "$selected570" "$CACHED_R570_DEB"

    stop_driver_stack
    MUTATION_STARTED=1
    purge_vgpu_package "$R535_PACKAGE" "$R535_VERSION"
    purge_vgpu_package "$R570_PACKAGE" "$R570_VERSION"
    purge_vgpu_package "$R580_PACKAGE" "$R580_VERSION"
    log '安装官方 R570.172.07 host 包（随后强制改为闭源 RM）'
    dpkg_without_module_signing -i "$CACHED_R570_DEB"

    # RTX 2080 is selected for open RM by NVIDIA's postinst.  The reviewed
    # vGPU path needs the proprietary RM tree shipped in the same package.
    stop_driver_stack
    dkms remove -m nvidia -v "$R570_VERSION-open" --all >/dev/null 2>&1 || true
    dkms remove -m nvidia -v "$R570_VERSION" --all >/dev/null 2>&1 || true
    [[ -d "/usr/src/nvidia-$R570_VERSION" && \
       ! -L "/usr/src/nvidia-$R570_VERSION" ]] || \
        die '官方 R570 闭源 DKMS 源码树缺失'
    dkms_without_module_signing add -m nvidia -v "$R570_VERSION"
    IGNORE_CC_MISMATCH=1 dkms_without_module_signing \
        install -m nvidia -v "$R570_VERSION" -k "$KVER"
    depmod -a "$KVER"
    modinfo -k "$KVER" -F version nvidia | grep -Fxq "$R570_VERSION" || \
        die 'R570 闭源模块版本复验失败'
    modinfo -k "$KVER" -F license nvidia | grep -Fxq NVIDIA || \
        die 'R570 模块仍是 open RM，拒绝继续'
    assert_nvidia_modules_unsigned
    modprobe nvidia
    modprobe nvidia_vgpu_vfio
    unmask_driver_services
    run_unlock_setup r570
    apt-mark hold "$R570_PACKAGE" >/dev/null
    update-initramfs -u -k "$KVER"
    validate_runtime_before_reboot "$R570_VERSION" \
        "$(expected_hook_policy r570)"
    queue_postboot_validation r570
}

bootstrap_v100_r535_core() {
    local selected535 selected570
    [[ "$GPU_KIND" == v100 ]] || \
        die 'bootstrap-v100-r535 只允许已审核的 Tesla V100'
    [[ ! -e "$SEED_META" ]] || \
        die 'R535 恢复种子已存在；请直接运行 r535'
    [[ "$(loaded_version)" == "$R570_VERSION" && \
       "$(module_license)" == NVIDIA && \
       "$(hook_policy)" == r570-native ]] || \
        die '首次 V100 统一必须从健康的 R570/native 分支执行'
    [[ "$(package_status "$R570_PACKAGE")" == installed && \
       "$(package_version "$R570_PACKAGE")" == "$R570_VERSION" ]] || \
        die "dpkg 中没有完整安装 $R570_PACKAGE/$R570_VERSION"
    validate_runtime "$R570_VERSION" "$(expected_hook_policy r570)"

    selected535=$(select_deb "$R535_DEB" "$CACHED_R535_DEB" "$DEFAULT_R535_DEB" \
        "$R535_PACKAGE" "$R535_VERSION" "$R535_DEB_SHA256")
    selected570=$(select_deb "$R570_DEB" "$CACHED_R570_DEB" "$DEFAULT_R570_DEB" \
        "$R570_PACKAGE" "$R570_VERSION" "$R570_DEB_SHA256")
    cache_deb "$selected535" "$CACHED_R535_DEB"
    cache_deb "$selected570" "$CACHED_R570_DEB"

    # Stop the retry timer before unloading R570 so it cannot race the package
    # transaction.  --remove keeps a timestamped backup and retains the helper.
    "$MIXED_MODE_INSTALLER" --remove
    stop_driver_stack
    MUTATION_STARTED=1
    purge_vgpu_package "$R570_PACKAGE" "$R570_VERSION"
    purge_vgpu_package "$R580_PACKAGE" "$R580_VERSION"
    purge_vgpu_package "$R535_PACKAGE" "$R535_VERSION"

    "$V100_R535_INSTALLER" --bdf "$GPU_BDF" \
        --driver-deb "$CACHED_R535_DEB"
    run_unlock_setup r535
    apt-mark hold "$R535_PACKAGE" >/dev/null
    update-initramfs -u -k "$KVER"
    validate_runtime_before_reboot "$R535_VERSION" \
        "$(expected_hook_policy r535)"

    # The freshly built, unsigned closed-RM modules are now the exact healthy
    # source for the kernel-bound recovery seed used by all later switches.
    cmd_init_r535
    queue_postboot_validation r535
}

switch_to_r580() {
    local selected580
    verify_r535_seed
    selected580=$(select_deb "$R580_DEB" "$CACHED_R580_DEB" "$DEFAULT_R580_DEB" \
        "$R580_PACKAGE" "$R580_VERSION" "$R580_DEB_SHA256")
    cache_deb "$selected580" "$CACHED_R580_DEB"

    stop_driver_stack
    MUTATION_STARTED=1
    purge_vgpu_package "$R535_PACKAGE" "$R535_VERSION"
    purge_vgpu_package "$R570_PACKAGE" "$R570_VERSION"
    purge_vgpu_package "$R580_PACKAGE" "$R580_VERSION"
    log '安装官方 R580.159.01 host 包（随后强制改为闭源 RM）'
    dpkg_without_module_signing -i "$CACHED_R580_DEB"

    # RTX 2080 is selected for open RM by NVIDIA's package postinst.  The vGPU
    # path was validated only with the closed source tree shipped in the same
    # official package, so remove the open DKMS result and build that tree.
    stop_driver_stack
    dkms remove -m nvidia -v "$R580_VERSION-open" --all >/dev/null 2>&1 || true
    dkms remove -m nvidia -v "$R580_VERSION" --all >/dev/null 2>&1 || true
    [[ -d "/usr/src/nvidia-$R580_VERSION" && \
       ! -L "/usr/src/nvidia-$R580_VERSION" ]] || \
        die '官方 R580 闭源 DKMS 源码树缺失'
    dkms_without_module_signing add -m nvidia -v "$R580_VERSION"
    IGNORE_CC_MISMATCH=1 dkms_without_module_signing \
        install -m nvidia -v "$R580_VERSION" -k "$KVER"
    depmod -a "$KVER"
    modinfo -k "$KVER" -F version nvidia | grep -Fxq "$R580_VERSION" || \
        die 'R580 闭源模块版本复验失败'
    modinfo -k "$KVER" -F license nvidia | grep -Fxq NVIDIA || \
        die 'R580 模块仍是 open RM，拒绝继续'
    assert_nvidia_modules_unsigned
    modprobe nvidia
    modprobe nvidia_vgpu_vfio
    unmask_driver_services
    run_unlock_setup r580-lab
    apt-mark hold "$R580_PACKAGE" >/dev/null
    update-initramfs -u -k "$KVER"
    validate_runtime_before_reboot "$R580_VERSION" 'r580_unlock_policy=consumer-lab'
    queue_postboot_validation r580-lab
}

switch_failure() {
    local rc=$?
    trap - EXIT
    unmask_driver_services
    ((rc != 0)) || return 0
    [[ -n "$GPU_BDF" ]] && write_branch_state "${TARGET_REQUEST:-unknown}" incomplete || true
    if [[ "$TARGET_REQUEST" =~ ^r(570|580-lab)$ && $MUTATION_STARTED == 1 && \
          $ROLLBACK_RUNNING == 0 ]]; then
        ROLLBACK_RUNNING=1
        warn "$TARGET_REQUEST 切换失败（exit=$rc），开始自动恢复 R535"
        set +e
        ( set -e
          if ((GLOBAL_LOCK_HELD == 0)); then
              acquire_global_lock
              assert_no_vm_or_mdev
          fi
          restore_r535_core
          publish_v100_branch_policy r535
        )
        local rollback_rc=$?
        set -e
        if ((rollback_rc == 0)); then
            warn "已自动恢复并验证 R535；$TARGET_REQUEST 命令仍以失败返回，请查看上方原始错误"
        else
            warn "R535 自动恢复也失败（exit=$rollback_rc）；重新运行 sudo $0 r535"
        fi
    fi
    exit "$rc"
}

maybe_reboot() {
    if ((REBOOT_REQUIRED == 0)); then
        log '当前分支已完成冷启动验收；无需重启'
        return
    fi
    if ((NO_REBOOT)); then
        warn '已按 --no-reboot 保持当前会话；状态为 pending-reboot，禁止启动 VM'
        return
    fi
    log '切换与运行时复验完成，正在重启宿主机'
    systemctl reboot
}

cmd_switch() {
    local target=$1 current
    require_root
    require_commands
    secure_boot_must_be_disabled
    detect_supported_gpu
    if [[ "$GPU_KIND" == v100 && "$target" == r580-lab ]]; then
        die 'V100 不开放 R580；只允许 r535 或 vGPU 18.4/r570'
    fi
    acquire_global_lock
    assert_no_vm_or_mdev
    verify_r535_seed
    TARGET_REQUEST=$target
    trap switch_failure EXIT

    current=$(loaded_version)
    if [[ "$target" == r535 && "$current" == "$R535_VERSION" && \
          "$(module_license)" == NVIDIA && "$(hook_policy)" == r535-consumer ]]; then
        log '当前已经是健康 R535 分支，无需重装'
        install_postboot_verifier
        validate_runtime "$R535_VERSION" 'r535_unlock_policy=consumer'
        write_branch_state r535 ready
        rm -f -- "$PENDING_STATE"
    elif [[ "$target" == r580-lab && "$current" == "$R580_VERSION" && \
          "$(module_license)" == NVIDIA && "$(hook_policy)" == r580-consumer-lab ]]; then
        log '当前已经是健康 R580 实验分支，无需重装'
        install_postboot_verifier
        validate_runtime "$R580_VERSION" 'r580_unlock_policy=consumer-lab'
        write_branch_state r580-lab ready
        rm -f -- "$PENDING_STATE"
    elif [[ "$target" == r570 && "$current" == "$R570_VERSION" && \
          "$(module_license)" == NVIDIA && \
          "$(hook_policy)" == "$(expected_hook_label r570)" ]]; then
        log '当前已经是健康 R570 分支，无需重装'
        install_postboot_verifier
        validate_runtime "$R570_VERSION" "$(expected_hook_policy r570)"
        write_branch_state r570 ready
        rm -f -- "$PENDING_STATE"
    elif [[ "$target" == r535 ]]; then
        restore_r535_core
    elif [[ "$target" == r570 ]]; then
        switch_to_r570
    else
        warn 'R580/RTX 仅限 Guest 582.53 母盘暂存；本机曾出现 XID 43/TDR/SDL 黑屏'
        switch_to_r580
    fi
    publish_v100_branch_policy "$target"
    trap - EXIT
    unmask_driver_services
    cmd_status
    maybe_reboot
}

cmd_bootstrap_v100_r535() {
    require_root
    require_commands
    secure_boot_must_be_disabled
    detect_supported_gpu
    [[ "$GPU_KIND" == v100 ]] || \
        die 'bootstrap-v100-r535 只适用于 Tesla V100 SXM2 16GB'
    acquire_global_lock
    assert_no_vm_or_mdev
    TARGET_REQUEST=bootstrap-v100-r535
    trap switch_failure EXIT
    bootstrap_v100_r535_core
    publish_v100_branch_policy r535
    trap - EXIT
    unmask_driver_services
    cmd_status
    maybe_reboot
}

cmd_doctor() {
    cmd_status
    printf '\n--- Secure Boot ---\n'
    mokutil --sb-state 2>&1 || true
    printf '\n--- NVIDIA PCI ---\n'
    lspci -Dnns "${GPU_BDF:-}" 2>/dev/null || lspci -Dnnd 10de: || true
    printf '\n--- DKMS ---\n'
    dkms status 2>/dev/null || true
    printf '\n--- NVIDIA modules ---\n'
    lsmod | awk '/^nvidia/ {print}'
    printf '\n--- vGPU services ---\n'
    systemctl --no-pager --full status nvidia-vgpu-mgr.service \
        nvidia-vgpud.service 2>/dev/null || true
    printf '\n--- mdev ---\n'
    find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true
    printf '\n--- QEMU ---\n'
    pgrep -fa qemu-system-x86_64 || true
}

main() {
    parse_args "$@"
    case "$COMMAND" in
        status) cmd_status ;;
        init-r535) cmd_init_r535 ;;
        bootstrap-v100-r535) cmd_bootstrap_v100_r535 ;;
        r535) cmd_switch r535 ;;
        r570) cmd_switch r570 ;;
        r580-lab) cmd_switch r580-lab ;;
        doctor) cmd_doctor ;;
    esac
}

main "$@"
