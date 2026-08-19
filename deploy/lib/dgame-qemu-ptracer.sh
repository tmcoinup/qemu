#!/usr/bin/env bash
# Build wrapper -> exec QEMU as the final process leaf.  The exception is
# per-process and survives execve; this module never changes ptrace_scope.

DGAME_QEMU_LEAF_CMD=()
DGAME_QEMU_PTRACER_PREFIX=()
DGAME_QEMU_PTRACER_DESCRIPTION=""
DGAME_QEMU_PTRACER_READY=0
DGAME_QEMU_YAMA_SCOPE=""

dgame_qemu_ptracer_reset() {
    DGAME_QEMU_LEAF_CMD=()
    DGAME_QEMU_PTRACER_PREFIX=()
    DGAME_QEMU_PTRACER_DESCRIPTION=""
    DGAME_QEMU_PTRACER_READY=0
    DGAME_QEMU_YAMA_SCOPE=""
}

dgame_qemu_ptracer_resolve_command() {
    local requested=$1 resolved=""

    if [[ "$requested" == */* ]]; then
        [[ -f "$requested" && -x "$requested" ]] || return 1
        printf '%s\n' "$requested"
        return 0
    fi
    resolved=$(command -v -- "$requested" 2>/dev/null || true)
    [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

dgame_qemu_ptracer_select_prefix() {
    local configured=${DGAME_QEMU_PTRACER:-} candidate="" python=""
    local packaged="$here/scripts/dgame_qemu_ptracer"
    local builtin="$here/scripts/qemu-ptracer-wrapper.py"

    DGAME_QEMU_PTRACER_PREFIX=()
    DGAME_QEMU_PTRACER_DESCRIPTION=""
    if [[ -n "$configured" ]]; then
        candidate=$(dgame_qemu_ptracer_resolve_command "$configured") || {
            echo "[start-vm] DGAME_QEMU_PTRACER 不可执行: $configured" >&2
            return 1
        }
        DGAME_QEMU_PTRACER_PREFIX=("$candidate" --)
        DGAME_QEMU_PTRACER_DESCRIPTION="configured wrapper ($candidate)"
        return 0
    fi
    if [[ -f "$packaged" && -x "$packaged" ]]; then
        DGAME_QEMU_PTRACER_PREFIX=("$packaged" --)
        DGAME_QEMU_PTRACER_DESCRIPTION="packaged wrapper ($packaged)"
        return 0
    fi
    if candidate=$(dgame_qemu_ptracer_resolve_command dgame_qemu_ptracer); then
        DGAME_QEMU_PTRACER_PREFIX=("$candidate" --)
        DGAME_QEMU_PTRACER_DESCRIPTION="PATH wrapper ($candidate)"
        return 0
    fi
    if [[ -f "$builtin" && -r "$builtin" ]]; then
        if [[ -x /usr/bin/python3 ]]; then
            python=/usr/bin/python3
        else
            python=$(command -v python3 2>/dev/null || true)
        fi
        if [[ -n "$python" && -x "$python" ]]; then
            DGAME_QEMU_PTRACER_PREFIX=("$python" "$builtin" --)
            DGAME_QEMU_PTRACER_DESCRIPTION="built-in Python wrapper ($builtin)"
            return 0
        fi
    fi
    if [[ -x /usr/bin/setpriv ]] &&
            /usr/bin/setpriv --help 2>&1 | grep -q -- '--ptracer'; then
        DGAME_QEMU_PTRACER_PREFIX=(/usr/bin/setpriv --ptracer any --)
        DGAME_QEMU_PTRACER_DESCRIPTION="util-linux setpriv"
        return 0
    fi

    echo "[start-vm] 缺少 QEMU ptracer wrapper；DGame 无法读取 QEMU 内存" >&2
    echo "[start-vm] 请保留 scripts/qemu-ptracer-wrapper.py 和 Python 3" >&2
    return 1
}

dgame_qemu_ptracer_validate_scope() {
    case "$1" in
        0|1) return 0 ;;
        2|3)
            echo "[start-vm] kernel.yama.ptrace_scope=$1 不允许进程级 QEMU 例外" >&2
            echo "[start-vm] 请由宿主安全策略恢复 scope=1；不要全局放宽为 0" >&2
            return 1
            ;;
        *)
            echo "[start-vm] 无法识别 kernel.yama.ptrace_scope: '$1'" >&2
            return 1
            ;;
    esac
}

dgame_qemu_ptracer_preflight() {
    local scope_path=/proc/sys/kernel/yama/ptrace_scope scope=""

    dgame_qemu_ptracer_reset
    [[ "${DRY_RUN:-0}" != 1 ]] || return 0
    if [[ -e "$scope_path" ]]; then
        IFS= read -r scope <"$scope_path" || {
            echo "[start-vm] 无法读取 $scope_path" >&2
            return 1
        }
        dgame_qemu_ptracer_validate_scope "$scope" || return 1
        DGAME_QEMU_YAMA_SCOPE=$scope
        if [[ "$scope" == 0 ]]; then
            echo "[start-vm] WARN: ptrace_scope=0 是宿主全局放宽状态；建议恢复为 1" >&2
        fi
    else
        DGAME_QEMU_YAMA_SCOPE=not-present
    fi
    dgame_qemu_ptracer_select_prefix || {
        dgame_qemu_ptracer_reset
        return 1
    }
    DGAME_QEMU_PTRACER_READY=1
}

dgame_qemu_ptracer_build_leaf() {
    local -a qemu_command=("$@")
    local argument

    DGAME_QEMU_LEAF_CMD=()
    ((${#qemu_command[@]} > 0)) || {
        echo "[start-vm] 无法包装空的 QEMU 命令" >&2
        return 1
    }
    for argument in "${qemu_command[@]:1}"; do
        if [[ "$argument" == -daemonize ]]; then
            echo "[start-vm] DGame 内存授权与 -daemonize 不兼容" >&2
            dgame_qemu_ptracer_reset
            return 1
        fi
    done
    if [[ "$DGAME_QEMU_PTRACER_READY" != 1 ]]; then
        dgame_qemu_ptracer_preflight || return 1
    fi
    DGAME_QEMU_LEAF_CMD=(
        "${DGAME_QEMU_PTRACER_PREFIX[@]}" "${qemu_command[@]}"
    )
}
