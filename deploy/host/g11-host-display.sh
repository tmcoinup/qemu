#!/usr/bin/env bash
# Keep the G-11 host desktop on its AMD DRM GPU when NVIDIA is vGPU-only.
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

readonly MANAGED_MARKER='Managed by deploy/host/g11-host-display.sh'
readonly INSTALLED_DROPIN_NAME='90-g11-host-display.conf'

TEST_MODE=0
if [[ "${G11_HOST_DISPLAY_TEST_MODE:-0}" == 1 ]]; then
    TEST_MODE=1
fi

if ((TEST_MODE)); then
    SYS_ROOT=${G11_HOST_DISPLAY_SYS_ROOT:?test sys root is required}
    ETC_ROOT=${G11_HOST_DISPLAY_ETC_ROOT:?test etc root is required}
    RUN_ROOT=${G11_HOST_DISPLAY_RUN_ROOT:?test run root is required}
    JOURNAL_FILE=${G11_HOST_DISPLAY_JOURNAL_FILE:-}
else
    SYS_ROOT=/sys
    ETC_ROOT=/etc
    RUN_ROOT=/run
    JOURNAL_FILE=
fi

DROPIN_DIR="$ETC_ROOT/systemd/system/gdm.service.d"
DROPIN_FILE="$DROPIN_DIR/$INSTALLED_DROPIN_NAME"
RUNTIME_CONFIG="$RUN_ROOT/gdm3/custom.conf"
RUNTIME_HELPER=/usr/libexec/gdm-runtime-config

DISPLAY_BDF=
DISPLAY_DRIVER=
DISPLAY_VENDOR=
DISPLAY_DEVICE=
DISPLAY_BOOT_VGA=
VGPU_BDF=
VGPU_DRIVER=
VGPU_VENDOR=
VGPU_DEVICE=
VGPU_BOOT_VGA=
AUDIT_READY=no

log() { printf '[g11-host-display] %s\n' "$*"; }
warn() { printf '[g11-host-display] WARN: %s\n' "$*" >&2; }
die() { printf '[g11-host-display] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：
  ./deploy/host/g11-host-display.sh audit
  ./deploy/host/g11-host-display.sh status --json
  sudo ./deploy/host/g11-host-display.sh apply
  ./deploy/host/g11-host-display.sh check
  sudo ./deploy/host/g11-host-display.sh rollback

audit     只读显示 AMD 宿主显示卡、NVIDIA vGPU 卡、GDM 选择和本次启动失败数
status    与 audit 相同；加 --json 输出供 VMate 修复中心使用的 schema=1 状态
apply     安装 GDM 启动前的 AMD/Wayland 首选项；不重启 GDM，完成后需重启宿主
check     重启后验收；只有配置、GDM 首选项和本次启动日志都正常才返回成功
rollback  只删除本脚本安装的 drop-in；不重启 GDM，完成后需重启宿主

此封装不修改 BCD/GRUB/内核参数，不安装或替换驱动，不改 guest，也不保存凭据。
EOF
}

read_one_line() {
    local path=$1 value
    [[ -r "$path" ]] || return 1
    IFS= read -r value <"$path" || return 1
    [[ "$value" != *$'\t'* && "$value" != *$'\r'* && "$value" != *$'\n'* ]] ||
        return 1
    printf '%s\n' "$value"
}

driver_for_device() {
    local device_path=$1 target
    target=$(readlink -f -- "$device_path/driver" 2>/dev/null) || return 1
    [[ -n "$target" ]] || return 1
    basename -- "$target"
}

has_drm_card() {
    local device_path=$1 node name
    for node in "$device_path"/drm/card[0-9]*; do
        [[ -e "$node" ]] || continue
        name=${node##*/}
        [[ "$name" =~ ^card[0-9]+$ ]] && return 0
    done
    return 1
}

discover_topology() {
    local device_path class vendor driver bdf
    local -a display_candidates=() vgpu_candidates=()

    for device_path in "$SYS_ROOT"/bus/pci/devices/*; do
        [[ -d "$device_path" ]] || continue
        class=$(read_one_line "$device_path/class" 2>/dev/null || true)
        [[ "$class" == 0x03* ]] || continue
        vendor=$(read_one_line "$device_path/vendor" 2>/dev/null || true)
        driver=$(driver_for_device "$device_path" 2>/dev/null || true)
        bdf=${device_path##*/}
        [[ "$bdf" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]] ||
            continue

        if [[ "$vendor" == 0x1002 && "$driver" =~ ^(amdgpu|radeon)$ ]] &&
                has_drm_card "$device_path"; then
            display_candidates+=("$bdf")
        elif [[ "$vendor" == 0x10de && "$driver" == nvidia ]] &&
                ! has_drm_card "$device_path"; then
            vgpu_candidates+=("$bdf")
        fi
    done

    if ((${#display_candidates[@]} != 1 || ${#vgpu_candidates[@]} != 1)); then
        warn "需要恰好 1 张 AMD DRM 宿主卡和 1 张无 DRM 节点的 NVIDIA vGPU 卡；当前分别为 ${#display_candidates[@]}/${#vgpu_candidates[@]}"
        return 1
    fi

    DISPLAY_BDF=${display_candidates[0]}
    VGPU_BDF=${vgpu_candidates[0]}
    device_path="$SYS_ROOT/bus/pci/devices/$DISPLAY_BDF"
    DISPLAY_DRIVER=$(driver_for_device "$device_path")
    DISPLAY_VENDOR=$(read_one_line "$device_path/vendor")
    DISPLAY_DEVICE=$(read_one_line "$device_path/device")
    DISPLAY_BOOT_VGA=$(read_one_line "$device_path/boot_vga" 2>/dev/null || echo unknown)
    device_path="$SYS_ROOT/bus/pci/devices/$VGPU_BDF"
    VGPU_DRIVER=$(driver_for_device "$device_path")
    VGPU_VENDOR=$(read_one_line "$device_path/vendor")
    VGPU_DEVICE=$(read_one_line "$device_path/device")
    VGPU_BOOT_VGA=$(read_one_line "$device_path/boot_vga" 2>/dev/null || echo unknown)
}

expected_dropin() {
    cat <<EOF
# $MANAGED_MARKER
# Host DRM GPU: $DISPLAY_BDF $DISPLAY_VENDOR:$DISPLAY_DEVICE ($DISPLAY_DRIVER)
# vGPU-only GPU: $VGPU_BDF $VGPU_VENDOR:$VGPU_DEVICE ($VGPU_DRIVER)
[Service]
ExecStartPre=$RUNTIME_HELPER set daemon WaylandEnable true
ExecStartPre=$RUNTIME_HELPER set daemon PreferredDisplayServer wayland
EOF
}

dropin_state() {
    if [[ -L "$DROPIN_FILE" ]]; then
        printf 'unsafe-symlink\n'
    elif [[ ! -e "$DROPIN_FILE" ]]; then
        printf 'absent\n'
    elif [[ ! -f "$DROPIN_FILE" ]]; then
        printf 'unsafe-type\n'
    elif ! grep -Fqx -- "# $MANAGED_MARKER" "$DROPIN_FILE" 2>/dev/null; then
        printf 'foreign\n'
    elif cmp -s -- "$DROPIN_FILE" <(expected_dropin); then
        printf 'exact\n'
    else
        printf 'stale\n'
    fi
}

runtime_value() {
    local wanted=$1
    [[ -r "$RUNTIME_CONFIG" ]] || return 1
    awk -v wanted="$wanted" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*\[/ {
            section=$0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
            next
        }
        section == "daemon" {
            equals=index($0, "=")
            if (!equals) next
            key=trim(substr($0, 1, equals - 1))
            value=trim(substr($0, equals + 1))
            if (key == wanted) {
                answer=value
                found=1
            }
        }
        END {
            if (!found) exit 1
            print answer
        }
    ' "$RUNTIME_CONFIG"
}

xorg_failure_count() {
    local pattern='Cannot run in framebuffer mode. Please specify busIDs' journal
    if ((TEST_MODE)); then
        if [[ -n "$JOURNAL_FILE" && -r "$JOURNAL_FILE" ]]; then
            awk -v pattern="$pattern" 'index($0, pattern) { count++ } END { print count + 0 }' \
                "$JOURNAL_FILE"
        else
            printf 'unknown\n'
        fi
        return
    fi
    if command -v journalctl >/dev/null 2>&1; then
        if journal=$(journalctl -b --no-pager -o cat 2>/dev/null); then
            awk -v pattern="$pattern" 'index($0, pattern) { count++ } END { print count + 0 }' \
                <<<"$journal"
        else
            printf 'unknown\n'
        fi
    else
        printf 'unknown\n'
    fi
}

firmware_primary() {
    if [[ "$DISPLAY_BOOT_VGA" == 1 && "$VGPU_BOOT_VGA" == 0 ]]; then
        printf 'display\n'
    elif [[ "$DISPLAY_BOOT_VGA" == 0 && "$VGPU_BOOT_VGA" == 1 ]]; then
        printf 'vgpu\n'
    else
        printf 'unknown\n'
    fi
}

audit_display() {
    local installed preferred wayland failures primary

    AUDIT_READY=no
    if ! discover_topology; then
        printf 'g11-host-display: ready=no topology=unsupported\n'
        return 1
    fi
    installed=$(dropin_state)
    preferred=$(runtime_value PreferredDisplayServer 2>/dev/null || echo missing)
    wayland=$(runtime_value WaylandEnable 2>/dev/null || echo default)
    failures=$(xorg_failure_count)
    primary=$(firmware_primary)

    printf '宿主显示卡: %s %s:%s driver=%s DRM=yes boot_vga=%s\n' \
        "$DISPLAY_BDF" "$DISPLAY_VENDOR" "$DISPLAY_DEVICE" \
        "$DISPLAY_DRIVER" "$DISPLAY_BOOT_VGA"
    printf 'vGPU 专用卡: %s %s:%s driver=%s DRM=no boot_vga=%s\n' \
        "$VGPU_BDF" "$VGPU_VENDOR" "$VGPU_DEVICE" \
        "$VGPU_DRIVER" "$VGPU_BOOT_VGA"
    printf 'GDM: dropin=%s preferred=%s wayland=%s xorg_boot_failures=%s\n' \
        "$installed" "$preferred" "$wayland" "$failures"

    if [[ "$installed" == exact && "$preferred" == wayland &&
          "$wayland" != false && "$failures" == 0 ]]; then
        AUDIT_READY=yes
    fi
    printf 'g11-host-display: ready=%s topology=supported display=%s vgpu=%s firmware_primary=%s dropin=%s preferred=%s wayland=%s xorg_boot_failures=%s\n' \
        "$AUDIT_READY" "$DISPLAY_BDF" "$VGPU_BDF" "$primary" "$installed" \
        "$preferred" "$wayland" "$failures"

    if [[ "$primary" == vgpu ]]; then
        warn '固件仍把 NVIDIA vGPU 卡标为启动主卡；软件封装会消除 GDM 重试，固件阶段若仍花屏请在 BIOS 把 AMD 插槽设为 Primary Display'
    fi
}

status_json() {
    local installed preferred wayland failures primary recommendation
    local applicable=true managed=false ready=false reboot_required=false failures_json

    if ! discover_topology 2>/dev/null; then
        printf '%s\n' '{"schema":1,"applicable":false,"display_bdf":"","vgpu_bdf":"","firmware_primary":"unknown","config":"absent","preferred":"missing","wayland":"default","xorg_boot_failures":null,"recommendation":"not-applicable","managed":false,"ready":false,"reboot_required":false}'
        return 0
    fi
    if ((!TEST_MODE)) && [[ ! -x "$RUNTIME_HELPER" ]]; then
        printf '%s\n' '{"schema":1,"applicable":false,"display_bdf":"","vgpu_bdf":"","firmware_primary":"unknown","config":"absent","preferred":"missing","wayland":"default","xorg_boot_failures":null,"recommendation":"not-applicable","managed":false,"ready":false,"reboot_required":false}'
        return 0
    fi

    installed=$(dropin_state)
    preferred=$(runtime_value PreferredDisplayServer 2>/dev/null || echo missing)
    case "$preferred" in
        xorg|wayland|missing) ;;
        *) preferred=other ;;
    esac
    wayland=$(runtime_value WaylandEnable 2>/dev/null || echo default)
    case "$wayland" in
        true|false|default) ;;
        *) wayland=other ;;
    esac
    failures=$(xorg_failure_count)
    primary=$(firmware_primary)
    [[ "$failures" =~ ^[0-9]+$ ]] && failures_json=$failures || failures_json=null
    [[ "$installed" == exact || "$installed" == stale ]] && managed=true

    case "$installed" in
        exact)
            if [[ "$preferred" == wayland && "$wayland" != false && "$failures" == 0 ]]; then
                recommendation=ready
                ready=true
            elif [[ "$failures" == unknown ]]; then
                recommendation=unknown
            else
                recommendation=reboot
                reboot_required=true
            fi
            ;;
        stale)
            recommendation=apply
            ;;
        absent)
            if [[ "$failures" =~ ^[0-9]+$ ]] && ((failures > 0)); then
                recommendation=apply
            elif [[ "$failures" == unknown && "$primary" == vgpu &&
                    "$preferred" == xorg ]]; then
                recommendation=unknown
            else
                recommendation=not-applicable
            fi
            ;;
        foreign|unsafe-symlink|unsafe-type)
            recommendation=conflict
            ;;
        *)
            recommendation=unknown
            ;;
    esac

    printf '{"schema":1,"applicable":%s,"display_bdf":"%s","vgpu_bdf":"%s","firmware_primary":"%s","config":"%s","preferred":"%s","wayland":"%s","xorg_boot_failures":%s,"recommendation":"%s","managed":%s,"ready":%s,"reboot_required":%s}\n' \
        "$applicable" "$DISPLAY_BDF" "$VGPU_BDF" "$primary" "$installed" \
        "$preferred" "$wayland" "$failures_json" "$recommendation" "$managed" \
        "$ready" "$reboot_required"
}

require_root() {
    ((EUID == 0 || TEST_MODE == 1)) || die '写操作必须使用 sudo'
}

reload_systemd() {
    ((TEST_MODE)) && return 0
    systemctl daemon-reload
}

apply_fix() {
    local state temp changed=1

    require_root
    discover_topology || die '当前宿主拓扑不符合 G-11 AMD 显示 + NVIDIA vGPU-only 合同'
    ((TEST_MODE)) || [[ -x "$RUNTIME_HELPER" ]] ||
        die "缺少 GDM runtime helper: $RUNTIME_HELPER"

    state=$(dropin_state)
    case "$state" in
        exact) changed=0 ;;
        absent|stale) ;;
        foreign) die "目标已有非本脚本管理的配置，拒绝覆盖: $DROPIN_FILE" ;;
        unsafe-*) die "目标类型不安全，拒绝覆盖: $DROPIN_FILE" ;;
        *) die "未知 drop-in 状态: $state" ;;
    esac

    if ((changed)); then
        [[ -d "$ETC_ROOT" && ! -L "$ETC_ROOT" ]] ||
            die "etc 根目录不安全: $ETC_ROOT"
        mkdir -p -- "$DROPIN_DIR"
        [[ -d "$DROPIN_DIR" && ! -L "$DROPIN_DIR" ]] ||
            die "GDM drop-in 目录不安全: $DROPIN_DIR"
        temp=$(mktemp "$DROPIN_DIR/.${INSTALLED_DROPIN_NAME}.XXXXXXXX")
        trap 'rm -f -- "${temp:-}"' EXIT
        expected_dropin >"$temp"
        chmod 0644 -- "$temp"
        if ((!TEST_MODE)); then
            chown root:root -- "$temp"
        fi
        mv -fT -- "$temp" "$DROPIN_FILE"
        temp=
        trap - EXIT
        reload_systemd || die 'systemd daemon-reload 失败；配置已写入，请先运行 rollback'
        log "已安装: $DROPIN_FILE"
    else
        log '配置已是目标状态，无需重复写入'
    fi

    if [[ "$(firmware_primary)" == vgpu ]]; then
        warn 'BIOS/UEFI 仍把 NVIDIA 设为 Primary Display；若厂商 Logo 到 Linux 接管前也花屏，请把 Primary Display 改为 AMD 所在插槽'
    fi
    log '未重启 GDM，当前桌面不会中断。请保存工作后重启宿主，再运行 check。'
}

rollback_fix() {
    local state

    require_root
    if discover_topology 2>/dev/null; then
        state=$(dropin_state)
    elif [[ -L "$DROPIN_FILE" ]]; then
        state=unsafe-symlink
    elif [[ ! -e "$DROPIN_FILE" ]]; then
        state=absent
    elif [[ -f "$DROPIN_FILE" ]] &&
            grep -Fqx -- "# $MANAGED_MARKER" "$DROPIN_FILE" 2>/dev/null; then
        state=stale
    else
        state=foreign
    fi

    case "$state" in
        absent)
            log '没有已安装的宿主显示修复，无需回滚'
            return 0
            ;;
        exact|stale)
            rm -f -- "$DROPIN_FILE"
            rmdir -- "$DROPIN_DIR" 2>/dev/null || true
            reload_systemd
            log '已删除本脚本管理的 GDM drop-in；可随时再次运行 apply 恢复'
            log '未重启 GDM，当前桌面不会中断。请保存工作后重启宿主。'
            ;;
        foreign) die "拒绝删除非本脚本管理的配置: $DROPIN_FILE" ;;
        unsafe-*) die "拒绝删除类型不安全的目标: $DROPIN_FILE" ;;
        *) die "未知 drop-in 状态: $state" ;;
    esac
}

command_name=${1:-audit}
shift || true
case "$command_name" in
    audit)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        audit_display
        ;;
    status)
        if [[ $# == 1 && "$1" == --json ]]; then
            status_json
        elif [[ $# == 0 ]]; then
            audit_display
        else
            usage >&2
            exit 2
        fi
        ;;
    check)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        audit_display
        [[ "$AUDIT_READY" == yes ]] ||
            die '验收未通过：确认已重启，再检查上面的 drop-in、GDM 和 Xorg 失败数'
        ;;
    apply)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        apply_fix
        ;;
    rollback|restore)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        rollback_fix
        ;;
    -h|--help|help)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        usage
        ;;
    *) usage >&2; exit 2 ;;
esac
