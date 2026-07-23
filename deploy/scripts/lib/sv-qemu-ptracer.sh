#!/usr/bin/env bash
# shellcheck disable=SC2034
# QEMU_LEAF_CMD 与说明变量由 source 本模块的 sv-assemble.sh 消费。
# ---------------------------------------------------------------------------
# QEMU 叶进程定向内存读取授权
#
# PR_SET_PTRACER 只跨 exec 保留，不会经过普通 fork 传给子进程。因此这里仅负责
# 生成“wrapper -> exec QEMU”的最终叶命令；GNOME/systemd inhibit 等外层生命周期
# 包装仍由 sv-display-guard.sh 添加。每次启动、每个实例都独立授权，不修改宿主
# kernel.yama.ptrace_scope，也不共享任何全局运行态。
# ---------------------------------------------------------------------------

QEMU_LEAF_CMD=()
SV_QEMU_PTRACER_PREFIX=()
SV_QEMU_PTRACER_DESCRIPTION=""
SV_QEMU_PTRACER_READY=0
SV_QEMU_YAMA_SCOPE=""

sv_qemu_ptracer_reset() {
    QEMU_LEAF_CMD=()
    SV_QEMU_PTRACER_PREFIX=()
    SV_QEMU_PTRACER_DESCRIPTION=""
    SV_QEMU_PTRACER_READY=0
    SV_QEMU_YAMA_SCOPE=""
}

sv_qemu_ptracer_resolve_named_command() {
    local requested="$1" resolved=""

    if [[ "$requested" == */* ]]; then
        [[ -f "$requested" && -x "$requested" ]] || return 1
        printf '%s\n' "$requested"
        return 0
    fi

    resolved="$(command -v -- "$requested" 2>/dev/null || true)"
    [[ -n "$resolved" && -f "$resolved" && -x "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

sv_qemu_ptracer_select_prefix() {
    local configured="${DGAME_QEMU_PTRACER:-}" candidate=""
    local packaged_wrapper="${HERE:-}/dgame_qemu_ptracer"
    local bundled_wrapper="${HERE:-}/qemu-ptracer-wrapper.py" python=""

    SV_QEMU_PTRACER_PREFIX=()
    SV_QEMU_PTRACER_DESCRIPTION=""

    # 高级部署可显式指定包内 wrapper；普通机器无需设置该变量，会自动探测。
    if [[ -n "$configured" ]]; then
        if ! candidate="$(sv_qemu_ptracer_resolve_named_command "$configured")"; then
            echo "ERROR: DGAME_QEMU_PTRACER 不可执行: $configured" >&2
            return 1
        fi
        SV_QEMU_PTRACER_PREFIX=("$candidate" --)
        SV_QEMU_PTRACER_DESCRIPTION="dgame_qemu_ptracer ($candidate)"
        return 0
    fi

    # 发布包可把 wrapper 放在 start-vm.sh 同目录；该路径优先于 PATH，确保包内
    # 二进制与 DGame 版本一致。源码部署没有该文件时继续走 PATH/系统 setpriv。
    if [[ -f "$packaged_wrapper" && -x "$packaged_wrapper" ]]; then
        SV_QEMU_PTRACER_PREFIX=("$packaged_wrapper" --)
        SV_QEMU_PTRACER_DESCRIPTION="包内 dgame_qemu_ptracer ($packaged_wrapper)"
        return 0
    fi

    if candidate="$(sv_qemu_ptracer_resolve_named_command dgame_qemu_ptracer)"; then
        SV_QEMU_PTRACER_PREFIX=("$candidate" --)
        SV_QEMU_PTRACER_DESCRIPTION="PATH dgame_qemu_ptracer ($candidate)"
        return 0
    fi

    # Python 3 是启动器现有宿主依赖。仓库自带的 wrapper 避免依赖新版
    # util-linux：Ubuntu 22.04/24.04 的 setpriv 尚不支持 --ptracer。
    if [[ -f "$bundled_wrapper" && -r "$bundled_wrapper" ]]; then
        if [[ -x /usr/bin/python3 ]]; then
            python=/usr/bin/python3
        else
            python="$(command -v python3 2>/dev/null || true)"
        fi
        if [[ -n "$python" && -f "$python" && -x "$python" ]]; then
            SV_QEMU_PTRACER_PREFIX=("$python" "$bundled_wrapper" --)
            SV_QEMU_PTRACER_DESCRIPTION="内置 Python wrapper ($bundled_wrapper)"
            return 0
        fi
    fi

    # util-linux 2.41+ 的 setpriv 可承担同一职责；仅在实际探测到该参数时回退。
    if [[ -x /usr/bin/setpriv ]] \
        && /usr/bin/setpriv --help 2>&1 | grep -q -- '--ptracer'; then
        SV_QEMU_PTRACER_PREFIX=(/usr/bin/setpriv --ptracer any --)
        SV_QEMU_PTRACER_DESCRIPTION="util-linux setpriv (/usr/bin/setpriv)"
        return 0
    fi
    if candidate="$(command -v setpriv 2>/dev/null || true)"; then
        if [[ -f "$candidate" && -x "$candidate" ]] \
            && "$candidate" --help 2>&1 | grep -q -- '--ptracer'; then
            SV_QEMU_PTRACER_PREFIX=("$candidate" --ptracer any --)
            SV_QEMU_PTRACER_DESCRIPTION="util-linux setpriv ($candidate)"
            return 0
        fi
    fi

    echo "ERROR: 缺少可用的 QEMU ptracer wrapper" >&2
    echo "       请保留 qemu-ptracer-wrapper.py 并安装 Python 3，或提供" >&2
    echo "       dgame_qemu_ptracer / util-linux 2.41+ setpriv" >&2
    return 1
}

sv_qemu_ptracer_validate_yama_scope() {
    local scope="$1"

    case "$scope" in
        0|1) return 0 ;;
        2|3)
            echo "ERROR: kernel.yama.ptrace_scope=$scope 不允许普通用户的 QEMU 叶节点例外" >&2
            echo "       请按宿主安全策略使用 scope=1；不要用 scope=0 掩盖启动链错误" >&2
            return 1
            ;;
        *)
            echo "ERROR: 无法识别 kernel.yama.ptrace_scope: '$scope'" >&2
            return 1
            ;;
    esac
}

sv_qemu_ptracer_check_yama_scope() {
    local scope_path=/proc/sys/kernel/yama/ptrace_scope scope=""

    if [[ ! -e "$scope_path" ]]; then
        SV_QEMU_YAMA_SCOPE="not-present"
        return 0
    fi
    IFS= read -r scope <"$scope_path" || {
        echo "ERROR: 无法读取 $scope_path" >&2
        return 1
    }
    sv_qemu_ptracer_validate_yama_scope "$scope" || return 1
    SV_QEMU_YAMA_SCOPE="$scope"
    if [[ "$scope" == "0" ]]; then
        echo ">> WARN: kernel.yama.ptrace_scope=0；当前为宿主全局放宽状态，" >&2
        echo "         旧 VM 滚动重启完成后应恢复为 1" >&2
    fi
}

sv_qemu_ptracer_preflight() {
    sv_qemu_ptracer_reset
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    sv_qemu_ptracer_check_yama_scope || {
        sv_qemu_ptracer_reset
        return 1
    }
    sv_qemu_ptracer_select_prefix || {
        sv_qemu_ptracer_reset
        return 1
    }
    SV_QEMU_PTRACER_READY=1
}

sv_qemu_ptracer_build_leaf_command() {
    local -a qemu_command=("$@")
    local argument

    QEMU_LEAF_CMD=()
    if (( ${#qemu_command[@]} == 0 )); then
        echo "ERROR: 无法包装空的 QEMU 命令" >&2
        sv_qemu_ptracer_reset
        return 1
    fi

    # -daemonize 会在 wrapper exec 之后再次 fork，定向授权将留在退出的父进程；
    # 因此发现该选项必须 fail closed，不能生成看似成功但实际不可读的 VM。
    for argument in "${qemu_command[@]:1}"; do
        if [[ "$argument" == "-daemonize" ]]; then
            echo "ERROR: QEMU 叶进程授权与 -daemonize 不兼容；请由 start-vm 管理前台 QEMU" >&2
            sv_qemu_ptracer_reset
            return 1
        fi
    done

    if [[ "$SV_QEMU_PTRACER_READY" != "1" ]]; then
        sv_qemu_ptracer_preflight || return 1
    fi
    QEMU_LEAF_CMD=("${SV_QEMU_PTRACER_PREFIX[@]}" "${qemu_command[@]}")
    echo ">> DGame memory: QEMU 叶节点 Yama 例外就绪 ($SV_QEMU_PTRACER_DESCRIPTION)"
}
