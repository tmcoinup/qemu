#!/bin/bash
# ---------------------------------------------------------------------------
# ctl-vm.sh ——— 运行时显示通道控制（QMP 调 display-pause / display-resume +
#                fb-shm 的 object-add / object-del）
#
# 让你启动 VM 后能在不关机的情况下：
#   - 隐藏 / 重显 SDL 窗口（不退出 QEMU）
#   - 暂停 / 恢复 fb-shm 推流（DCL 不跑，CPU 降到 0）
#   - 完全卸载 / 重新加载 fb-shm（连 socket 都干净拆掉）
#
# 用法：
#     ./ctl-vm.sh <INSTANCE> sdl-hide        # 隐藏 SDL 窗口（DCL 暂停）
#     ./ctl-vm.sh <INSTANCE> sdl-show        # 重显 SDL 窗口
#     ./ctl-vm.sh <INSTANCE> fb-pause        # 暂停 fb-shm（保留 socket）
#     ./ctl-vm.sh <INSTANCE> fb-resume       # 恢复 fb-shm
#     ./ctl-vm.sh <INSTANCE> fb-off          # 彻底卸载 fb-shm（删 socket）
#     ./ctl-vm.sh <INSTANCE> fb-on [rate]    # 重新装 fb-shm（默认 60 Hz）
#     ./ctl-vm.sh <INSTANCE> stream-only     # 一键：隐藏 SDL，仅留 fb-shm
#     ./ctl-vm.sh <INSTANCE> sdl-only        # 一键：暂停 fb-shm，仅留 SDL
#     ./ctl-vm.sh <INSTANCE> status          # 看当前显示通道状态
#
# 典型流程：先 SDL 进系统配完，再切流：
#     ./start-vm.sh 1                # SDL + fb-shm 双开
#     # ... 用 SDL 窗口装驱动 / 改设置 ...
#     ./ctl-vm.sh 1 stream-only      # 隐 SDL，CPU 让给 NVENC
#     # ... 想再回去操作 ...
#     ./ctl-vm.sh 1 sdl-show
# ---------------------------------------------------------------------------
set -euo pipefail

INSTANCE="${1:-}"
ACTION="${2:-status}"
RATE="${3:-60}"

if [[ -z "$INSTANCE" || ! "$INSTANCE" =~ ^[0-9]+$ ]]; then
    sed -n '2,/^# --*$/p' "$0" | sed -e 's/^# *//' -e 's/^#$//' >&2
    exit 2
fi

QMP="/tmp/qemu-stealth-${INSTANCE}.qmp"
FB_SOCK="/tmp/qemu-stealth-${INSTANCE}.fb"

if [[ ! -S "$QMP" ]]; then
    echo "ERROR: QMP socket $QMP 不存在 —— VM ${INSTANCE} 没在跑？" >&2
    exit 1
fi

# QMP 调用：返回 JSON 串到 stdout
_qmp() {
    local cmd="$1"
    {
        printf '%s\n' '{"execute":"qmp_capabilities"}'
        printf '%s\n' "$cmd"
    } | socat - "UNIX-CONNECT:$QMP" 2>/dev/null
}

# 仅取最后一行 return/error
_qmp_call() {
    _qmp "$1" | tail -1
}

case "$ACTION" in
    sdl-hide)
        _qmp_call '{"execute":"display-pause","arguments":{"name":"sdl2"}}'
        ;;
    sdl-show)
        _qmp_call '{"execute":"display-resume","arguments":{"name":"sdl2"}}'
        ;;
    fb-pause)
        _qmp_call '{"execute":"display-pause","arguments":{"name":"fb-shm"}}'
        ;;
    fb-resume)
        _qmp_call '{"execute":"display-resume","arguments":{"name":"fb-shm"}}'
        ;;
    fb-off)
        _qmp_call '{"execute":"object-del","arguments":{"id":"stealth-'$INSTANCE'"}}'
        ;;
    fb-on)
        _qmp_call '{"execute":"object-add","arguments":{"qom-type":"fb-shm","id":"stealth-'$INSTANCE'","path":"'$FB_SOCK'","rate":'$RATE'}}'
        ;;
    stream-only)
        echo "-- 隐藏 SDL --"
        _qmp_call '{"execute":"display-pause","arguments":{"name":"sdl2"}}'
        echo "-- 确保 fb-shm 在跑 --"
        _qmp_call '{"execute":"display-resume","arguments":{"name":"fb-shm"}}'
        ;;
    sdl-only)
        echo "-- 显示 SDL --"
        _qmp_call '{"execute":"display-resume","arguments":{"name":"sdl2"}}'
        echo "-- 暂停 fb-shm --"
        _qmp_call '{"execute":"display-pause","arguments":{"name":"fb-shm"}}'
        ;;
    status)
        echo "VM $INSTANCE state ($QMP):"
        echo "  fb-shm socket : $([[ -S $FB_SOCK ]] && echo "ALIVE ($FB_SOCK)" || echo "DEAD")"
        # query-display-options 给个粗略状态；详细 paused 标志没暴露给 QMP
        _qmp '{"execute":"query-display-options"}' | tail -1 | python3 -c 'import sys,json; print("  -display backend:",json.loads(sys.stdin.read()).get("return",{}).get("type","?"))'
        ;;
    *)
        echo "ERROR: 未知动作 '$ACTION'" >&2
        exit 2
        ;;
esac
