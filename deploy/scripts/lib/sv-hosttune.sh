# ---------------------------------------------------------------------------
# sv-hosttune.sh —— 起 VM 前的 host 侧调度/时钟抖动调优 + CPU 频率封顶（默认开）
#
# 必须在 sv-identity 之后 source —— 频率封顶要用它导出的 CPU_MAX_MHZ。
#
# 两件事，都只动 host 侧旋钮，guest 的 CPUID / tsc-freq / 拓扑 / SMBIOS 全不变：
#
#  1) 抖动调优 (HOST_TUNE=1): governor=performance + halt_poll=500000 +
#     THP defrag=never，压低 vCPU 服务延迟方差。ACE「游戏计时异常」(13-131130-8)
#     这类时钟检测对抖动尖刺敏感。
#
#  2) 频率封顶 (CPU_FREQ_CAP=1): 把 scaling_max_freq 压到本实例伪装 CPU 的
#     CPU_MAX_MHZ（= SMBIOS Type4 自报 max-speed）。host(5800) boost 4.6GHz 远超
#     伪装的 Ryzen3-1200 3.4GHz，在固定 tsc-freq 下 guest 实测吞吐会超出该型号规格
#     = 变速器 / 计时异常破绽。**只降不升**：仅当当前 scaling_max_freq 高于本实例
#     上限时才下压，多 VM 并发自然收敛到运行中最小值，绝不让任一 VM 跑出超自身规格
#     的速度。（注：低规格 VM 停了 cap 不会自动回升，重启 host 或手动调即可。）
#
# 行为：
#   - DRY_RUN 下严格 no-op（不触 sudo / 不写 sysfs / 零输出，保 argv 回归基线）。
#   - 已是目标状态则跳过——免每次启动都 sudo。
#   - 取 root：已 root 直接跑 → 免密 sudo → 有 tty 交互输密 → 否则只 WARN 不阻断。
# ---------------------------------------------------------------------------

# DRY_RUN：零副作用、零输出，原样返回（本文件被 source，return 即退出本步骤）。
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
fi

if [[ "${HOST_TUNE:-1}" == "1" ]]; then
    _ht_script="$HERE/host-performance.sh"
    _ht_need=0

    # --- 抖动调优是否需要：全核 governor=performance 且 halt_poll≥500000 ---
    for _g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -r "$_g" ]] || continue
        [[ "$(cat "$_g" 2>/dev/null)" == "performance" ]] || { _ht_need=1; break; }
    done
    _hp=$(cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null || echo 0)
    [[ "$_hp" =~ ^[0-9]+$ ]] || _hp=0
    (( _hp < 500000 )) && _ht_need=1

    # --- 频率封顶是否需要：当前 scaling_max_freq 高于本实例伪装 CPU 上限才下压 ---
    # CPU_MAX_KHZ 总是 export（空 = 不封顶；非空 = 传给 host-performance.sh 下压）。
    export CPU_MAX_KHZ=""
    if [[ "${CPU_FREQ_CAP:-1}" == "1" && "${CPU_MAX_MHZ:-}" =~ ^[0-9]+$ ]] && (( CPU_MAX_MHZ > 0 )); then
        _vm_cap_khz=$(( CPU_MAX_MHZ * 1000 ))
        _cur_max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo 0)
        [[ "$_cur_max" =~ ^[0-9]+$ ]] || _cur_max=0
        if (( _cur_max > _vm_cap_khz )); then        # 只降不升
            _ht_need=1
            export CPU_MAX_KHZ="$_vm_cap_khz"
        fi
    fi

    if (( _ht_need == 0 )); then
        echo ">> host 调优:   已是 performance + halt_poll≥500000$([[ "${CPU_FREQ_CAP:-1}" == "1" ]] && echo " + 频率≤${CPU_MAX_MHZ:-?}MHz")，跳过"
    elif [[ ! -f "$_ht_script" ]]; then
        echo ">> host 调优:   ⚠ 找不到 $_ht_script，跳过（HOST_TUNE=0 可静默）" >&2
    else
        [[ -n "$CPU_MAX_KHZ" ]] && _ht_msg="（含封顶 $(( CPU_MAX_KHZ/1000 ))MHz=伪装 CPU 上限）" || _ht_msg=""
        if [[ $EUID -eq 0 ]]; then
            echo ">> host 调优:   应用 host-performance.sh${_ht_msg} ..."
            bash "$_ht_script" || echo ">> host 调优:   ⚠ 部分失败（不阻断启动）" >&2
        elif sudo -n true 2>/dev/null; then
            echo ">> host 调优:   sudo(免密) 应用 host-performance.sh${_ht_msg} ..."
            sudo -E bash "$_ht_script" || echo ">> host 调优:   ⚠ 部分失败（不阻断启动）" >&2
        elif [[ -t 0 || -t 1 ]]; then
            echo ">> host 调优:   需要 sudo 应用 host-performance.sh${_ht_msg}（可能提示输密；--no-host-tune 关）..."
            sudo -E bash "$_ht_script" || echo ">> host 调优:   ⚠ sudo 失败/取消（不阻断启动）" >&2
        else
            echo ">> host 调优:   ⚠ 需要 sudo 但无 tty 且无免密，跳过" >&2
            echo ">>             手动: sudo CPU_MAX_KHZ=${CPU_MAX_KHZ:-0} deploy/scripts/host-performance.sh（或 HOST_TUNE=0 静默）" >&2
        fi
    fi
fi
