# ---------------------------------------------------------------------------
# sv-hosttune.sh —— 起 VM 前的 host 侧调度/时钟抖动调优 + CPU 频率封顶（默认开）
#
# 必须在 sv-identity 之后 source —— 频率封顶要用它导出的 CPU_MAX_MHZ。
#
# 两件事，都只动 host 侧旋钮，guest 的 CPUID / tsc-freq / 拓扑 / SMBIOS 全不变：
#
#  1) 抖动调优 (HOST_TUNE=1): governor=performance + 可配置 halt_poll +
#     THP defrag=never。多开默认 KVM_HALT_POLL_NS=0，靠 cpuset 隔离防止宿主
#     编译抢 vCPU；需要旧低延迟策略时显式 KVM_HALT_POLL_NS=500000。
#
#  2) 频率封顶 (CPU_FREQ_CAP=1): 把 scaling_max_freq 压到「**运行中所有 VM**
#     伪装 CPU 上限(CPU_MAX_MHZ=SMBIOS Type4 max-speed)的最小值」。host boost 远
#     超伪装规格时 guest 实测吞吐会超该型号 = 变速器/计时异常破绽。因为 host
#     scaling_max_freq 是全局的，要保证**任一在跑 VM 都不超自身规格**，唯一安全
#     的全局值就是各 VM 规格的最小者(跑得比自报慢=合理；绝不超规格)。每次启动按
#     当前在跑集合重算 → 既能在低规格 VM 退出后回升，也能在其加入时压低。
#     (注：VM 停机不触发重算；低规格 VM 退出后高规格 VM 要到下次启动/手动调才回升。)
#     更彻底的「每 VM 绑核+按核各自封顶」留待 host 迁到 E5(22 核)后一次做对——
#     当前 8 核物理上容不下多台 4vCPU 各占独立核。
#
# 行为：
#   - DRY_RUN 下严格 no-op（不触 sudo / 不写 sysfs / 零输出，保 argv 回归基线）。
#   - 已是目标态则跳过——免重复调用。
#   - 取 root：已 root 直接跑 → sudo -n(配了 NOPASSWD 免密) → 有 tty 交互 → 否则
#     只 WARN 不阻断启动。失败一律不阻断主流程。
# ---------------------------------------------------------------------------

# DRY_RUN：零副作用、零输出，原样返回（本文件被 source，return 即退出本步骤）。
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
fi

if [[ "${HOST_TUNE:-1}" == "1" ]]; then
    _ht_script="$HERE/host-performance.sh"
    _ht_need=0
    _ht_halt_poll_target="${KVM_HALT_POLL_NS:-0}"
    [[ "$_ht_halt_poll_target" =~ ^[0-9]+$ ]] || _ht_halt_poll_target=0

    # --- 抖动调优是否需要：全核 governor=performance 且 halt_poll 等于目标值 ---
    for _g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -r "$_g" ]] || continue
        [[ "$(cat "$_g" 2>/dev/null)" == "performance" ]] || { _ht_need=1; break; }
    done
    _hp=$(cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null || echo 0)
    [[ "$_hp" =~ ^[0-9]+$ ]] || _hp=0
    (( _hp != _ht_halt_poll_target )) && _ht_need=1

    # --- 频率封顶目标 = 运行中所有 VM(含本实例) CPU_MAX_MHZ 的最小值 ---
    # _ht_cap_arg: 传给 host-performance.sh 的 kHz；空=不封顶(CPU_FREQ_CAP=0)。
    _ht_cap_arg=""
    if [[ "${CPU_FREQ_CAP:-1}" == "1" && "${CPU_MAX_MHZ:-}" =~ ^[0-9]+$ ]] && (( CPU_MAX_MHZ > 0 )); then
        _ht_target_mhz="$CPU_MAX_MHZ"
        # 扫描在跑的其它实例，取其 profile 里 CPU_MAX_MHZ 的最小值一起比。
        _vms_base="$(dirname "${VM_DIR:-/home/ubuntu/images/vms/$INSTANCE}")"
        _running_inst=$(pgrep -af 'qemu-system-x86_64 .*-name win10' 2>/dev/null \
                        | grep -v inhibit | grep -oE 'vms/[0-9]+/' | grep -oE '[0-9]+' | sort -u || true)
        local_other=""
        for _ri in $_running_inst; do
            [[ "$_ri" == "$INSTANCE" ]] && continue
            _rp="$_vms_base/$_ri/profile"
            [[ -r "$_rp" ]] || continue
            _rmhz="$(stealth_profile_get CPU_MAX_MHZ "$_rp" 2>/dev/null || true)"
            [[ "$_rmhz" =~ ^[0-9]+$ ]] || continue
            (( _rmhz < _ht_target_mhz )) && _ht_target_mhz="$_rmhz"
            local_other="$local_other $_ri($_rmhz)"
        done
        _ht_target_khz=$(( _ht_target_mhz * 1000 ))
        # 钳到硬件上限，便于和 scaling_max_freq 现值精确比对(host-performance 也会钳)。
        _hw_max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
        [[ "$_hw_max" =~ ^[0-9]+$ ]] || _hw_max=0
        _ht_clamped=$_ht_target_khz
        (( _hw_max > 0 && _ht_clamped > _hw_max )) && _ht_clamped=$_hw_max
        _cur_max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo 0)
        [[ "$_cur_max" =~ ^[0-9]+$ ]] || _cur_max=0
        (( _cur_max != _ht_clamped )) && _ht_need=1
        _ht_cap_arg="$_ht_target_khz"
        [[ -n "$local_other" ]] && echo ">> host 调优:   在跑实例规格${local_other}，本机 ${CPU_MAX_MHZ}MHz → 全局封顶取最小 ${_ht_target_mhz}MHz"
    fi

    if (( _ht_need == 0 )); then
        echo ">> host 调优:   已是 performance + halt_poll=${_ht_halt_poll_target}ns$([[ -n "$_ht_cap_arg" ]] && echo " + 频率封顶 $(( _ht_cap_arg/1000 ))MHz")，跳过"
    elif [[ ! -f "$_ht_script" ]]; then
        echo ">> host 调优:   ⚠ 找不到 $_ht_script，跳过（HOST_TUNE=0 可静默）" >&2
    else
        _ht_msg="$([[ -n "$_ht_cap_arg" ]] && echo "（封顶 $(( _ht_cap_arg/1000 ))MHz）")"
        # 取 root 顺序：已 root 直接跑 → sudo -n(NOPASSWD 免密) → 有 tty 交互 → 否则 WARN。
        if [[ $EUID -eq 0 ]]; then
            echo ">> host 调优:   应用 host-performance.sh${_ht_msg} ..."
            bash "$_ht_script" $_ht_cap_arg || echo ">> host 调优:   ⚠ 部分失败（不阻断启动）" >&2
        elif sudo -n "$_ht_script" $_ht_cap_arg 2>/dev/null; then
            echo ">> host 调优:   ✓ sudo(免密)已应用 host-performance.sh${_ht_msg}"
        elif [[ -t 0 || -t 1 ]]; then
            echo ">> host 调优:   需 sudo 应用 host-performance.sh${_ht_msg}（NOPASSWD 未配会提示输密；--no-host-tune 关）..."
            sudo "$_ht_script" $_ht_cap_arg || echo ">> host 调优:   ⚠ sudo 失败/取消（不阻断启动）" >&2
        else
            echo ">> host 调优:   ⚠ 需 sudo 但无 tty 且无免密，跳过" >&2
            echo ">>             手动: sudo $_ht_script ${_ht_cap_arg}（或配 NOPASSWD / HOST_TUNE=0）" >&2
        fi
    fi
fi
