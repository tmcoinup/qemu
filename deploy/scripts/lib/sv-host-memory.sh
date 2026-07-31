#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 每实例宿主 OOM 保护
#
# Linux 内核的 oom_score_adj 会在 fork/exec 时由子进程继承。因此只需在任何
# QEMU/swtpm/显示守护启动前保护当前 start-vm.sh，整棵实例进程树都会继承；
# 启动失败或 VM 退出后进程消失，宿主没有需要恢复的持久配置。
#
# 这里不按客体 RAM、CPU 数、Windows/Linux 类型分支，也不依赖发行版版本号。
# root helper 会在运行时探测 /proc/PID/oom_score_adj，并使用固定的 -500 策略。
# 它降低 VM 在全局 OOM 中被选中的概率，但不制造物理内存；既有 MEM_GUARD 仍
# 负责启动时容量门禁。
# ---------------------------------------------------------------------------

: "${HOST_OOM_PROTECT:=1}"
case "$HOST_OOM_PROTECT" in
    0|1) ;;
    *)
        echo "ERROR: HOST_OOM_PROTECT 必须是 0 或 1" >&2
        exit 2
        ;;
esac

# DRY_RUN 的契约是绝不触发 sudo、proc 写入或额外状态输出。
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
fi

if [[ "$HOST_OOM_PROTECT" == "0" ]]; then
    echo ">> OOM 保护:    已由 HOST_OOM_PROTECT=0 显式关闭" >&2
    return 0
fi

_sv_oom_helper="${SV_HOST_PERF_HELPER:-/usr/local/libexec/qemu-vmate-host-performance}"
if ! declare -F _sv_root_helper_is_safe >/dev/null 2>&1 \
   || ! _sv_root_helper_is_safe "$_sv_oom_helper"; then
    echo "ERROR: OOM 保护缺少安全的 root-owned helper: $_sv_oom_helper" >&2
    echo "       请在仓库根目录运行: deploy/tools/build.sh --install-host-helpers" >&2
    exit 1
fi

_sv_oom_pid="$BASHPID"
if ! read -r _sv_oom_state _sv_oom_start \
        < <(sv_proc_state_starttime "$_sv_oom_pid"); then
    echo "ERROR: 无法读取当前 VM 启动器的进程 generation" >&2
    exit 1
fi
if [[ "$_sv_oom_state" =~ ^[ZzXx]$ || ! "$_sv_oom_start" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: 当前 VM 启动器进程 generation 无效" >&2
    exit 1
fi

_sv_oom_output=""
_sv_oom_status=0
if [[ $EUID -eq 0 ]]; then
    _sv_oom_output="$(
        "$_sv_oom_helper" protect-launcher \
            "$INSTANCE" "$_sv_oom_pid" "$_sv_oom_start"
    )" || _sv_oom_status=$?
else
    _sv_oom_output="$(
        sudo -n -- "$_sv_oom_helper" protect-launcher \
            "$INSTANCE" "$_sv_oom_pid" "$_sv_oom_start"
    )" || _sv_oom_status=$?
fi

if (( _sv_oom_status != 0 )); then
    echo "ERROR: 无法为实例 $INSTANCE 建立临时 OOM 保护" >&2
    if [[ -n "$_sv_oom_output" ]]; then
        printf '       %s\n' "${_sv_oom_output//$'\n'/$'\n       '}" >&2
    fi
    echo "       helper 版本过旧时请运行: deploy/tools/build.sh --install-host-helpers" >&2
    echo "       如需明确接受未保护启动，可临时设置 HOST_OOM_PROTECT=0" >&2
    exit 1
fi

read -r _sv_oom_label _sv_oom_policy _sv_oom_score _sv_oom_target _sv_oom_extra \
    <<<"$_sv_oom_output"
_sv_oom_score_value="${_sv_oom_score#score=}"
if [[ "$_sv_oom_label" != "host-memory-protect:" \
   || "$_sv_oom_policy" != "policy=oom-score-v1" \
   || "$_sv_oom_target" != "pid=$_sv_oom_pid" \
   || "$_sv_oom_output" == *$'\n'* \
   || -n "$_sv_oom_extra" \
   || ! "$_sv_oom_score_value" =~ ^-[0-9]+$ ]] \
   || (( _sv_oom_score_value < -1000 || _sv_oom_score_value > -500 )); then
    echo "ERROR: OOM helper 返回了未知协议，拒绝假定保护已生效" >&2
    if [[ -n "$_sv_oom_output" ]]; then
        printf '       %s\n' "${_sv_oom_output//$'\n'/$'\n       '}" >&2
    fi
    exit 1
fi

echo ">> OOM 保护:    实例 $INSTANCE 进程树 oom_score_adj=$_sv_oom_score_value（随 VM 退出失效）"

unset _sv_oom_helper _sv_oom_pid _sv_oom_state _sv_oom_start
unset _sv_oom_output _sv_oom_status _sv_oom_label _sv_oom_policy
unset _sv_oom_score _sv_oom_score_value _sv_oom_target _sv_oom_extra
