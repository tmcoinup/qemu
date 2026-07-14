#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# QEMU 实例进程识别公共函数
#
# start-vm 当前使用 `-name win10-N,debug-threads=on`，历史实例曾使用
# `win10-ryzen3-N`。stop、安装重启和后续生命周期工具必须共享同一个严格匹配器，
# 避免脚本各自维护名称后再次漂移；实例号后要求逗号或空格，实例 1 不会命中 10。
# ---------------------------------------------------------------------------

sv_qemu_instance_pattern() {
    local instance="$1"

    [[ "$instance" =~ ^[0-9]{1,10}$ ]] || return 1
    (( 10#$instance >= 1 )) || return 1
    printf '^win10-(ryzen3-)?%s(,|$)' "$instance"
}

sv_qemu_instance_pids() {
    local instance="$1"
    local pattern proc_dir pid exe index qemu_name="" found=1
    local -a argv=()

    pattern="$(sv_qemu_instance_pattern "$instance")" || return 1
    for proc_dir in /proc/[0-9]*; do
        pid="${proc_dir#/proc/}"
        exe="$(readlink -- "$proc_dir/exe" 2>/dev/null || true)"
        exe="${exe% (deleted)}"
        [[ "${exe##*/}" == "qemu-system-x86_64" && -r "$proc_dir/cmdline" ]] || continue
        argv=()
        mapfile -d '' -t argv <"$proc_dir/cmdline" 2>/dev/null || continue
        # 必须解析 NUL 分隔 argv，并只认精确 `-name` 后面的相邻值。宽泛 pgrep
        # 正则会把其它参数中碰巧出现的 `-name win10-N,` 当成实例名，进而等待或
        # 强杀错误 VM。
        qemu_name=""
        for ((index=0; index + 1 < ${#argv[@]}; index++)); do
            [[ "${argv[index]}" == "-name" ]] && qemu_name="${argv[index + 1]}"
        done
        # QEMU 接受重复 -name 且以最后一个为准；只比较最终值，不能让前面的
        # 失效参数把同一进程同时归到两个实例。
        if [[ -n "$qemu_name" && "$qemu_name" =~ $pattern ]]; then
            printf '%s\n' "$pid"
            found=0
        fi
    done
    return "$found"
}

sv_qemu_instance_pid() {
    local instance="$1"

    # 真实生命周期只允许同实例一个 QEMU；若损坏状态出现多个，调用方拿第一个
    # 用于诊断，批量终止路径应改用 sv_qemu_instance_pids。
    sv_qemu_instance_pids "$instance" 2>/dev/null | head -n1 || true
}
