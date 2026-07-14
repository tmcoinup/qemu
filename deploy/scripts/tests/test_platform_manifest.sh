#!/usr/bin/env bash
# 验证版本化整机 manifest、严格候选选择、E5 v4 的 2200MHz TSC 路径，以及
# profile 持久化。测试完全在临时目录运行，不启动 QEMU、不修改已有 VM。
# 下方三个隔离 subshell 故意复用相同变量名构造互斥宿主视图；赋值不会跨 subshell
# 泄漏，SC2030/SC2031 在这里正是预期语义。
# shellcheck disable=SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"

stealth_platform_validate >/dev/null

# JSON 索引必须同时保留可审计的兼容条目和可随机的 supported 条目；兼容条目
# 不能因为同厂商而偷偷进入随机池。
mapfile -t platform_rows < <(stealth_platform_index)
(( ${#platform_rows[@]} == 4 )) || fail "平台数量应为 4，实际 ${#platform_rows[@]}"

enabled_count=0
for row in "${platform_rows[@]}"; do
    IFS='|' read -r platform_id enabled vendor max_mhz threads tsc_mhz <<<"$row"
    [[ "$platform_id" =~ ^[a-z0-9-]+$ ]] || fail "平台 ID 格式错误: $platform_id"
    [[ "$vendor" == GenuineIntel || "$vendor" == AuthenticAMD ]] || fail "CPU 厂商错误"
    [[ "$max_mhz" =~ ^[0-9]+$ && "$threads" =~ ^[0-9]+$ && "$tsc_mhz" =~ ^[0-9]+$ ]] \
        || fail "平台数字字段错误: $row"
    [[ "$enabled" == true ]] && enabled_count=$((enabled_count + 1))
done
(( enabled_count == 2 )) || fail "随机平台应只有两个 Intel bundle"

# 每个启用平台必须能完整导出，且 CPU、内存、BIOS、PCI 和板载设备字段相互约束。
for row in "${platform_rows[@]}"; do
    IFS='|' read -r platform_id enabled _ _ _ _ <<<"$row"
    [[ "$enabled" == true ]] || continue
    stealth_platform_load "$platform_id"
    [[ "$PLATFORM_SCHEMA_VERSION" == 1 && "$PLATFORM_STATUS" == supported ]] \
        || fail "$platform_id schema/status 错误"
    (( CPU_CORES == 4 && CPU_THREADS == 4 )) || fail "$platform_id 不是完整 4C/4T"
    (( CPU_TSC_MHZ == CPU_CUR_MHZ )) || fail "$platform_id TSC 与基准频率不一致"
    [[ "$CPU_FEATURES" != *topoext* ]] || fail "Intel 平台带入 AMD topoext"
    [[ "$MEM_TYPE" == DDR4 && "$MEM_VOLTAGE_MV" == 1200 && "$MEM_RANK" == 1 ]] \
        || fail "$platform_id 内存类型/电压/rank 错误"
    [[ ",$MEM_ALLOWED_TOTAL_MB," == *",8192,"* ]] || fail "$platform_id 不允许默认 8GB"
    (( MEM_MAX_CAPACITY_MB == BOARD_MAX_MEMORY_GIB * 1024 )) \
        || fail "$platform_id Type16 最大容量不一致"
    [[ "$NIC_MODEL" == "Intel 82574L Gigabit Network Connection" ]] \
        || fail "$platform_id 声明了当前未实现的网卡"
    [[ "$NIC_ATTACHMENT" == add_in && "$BOARD_NIC_STATE" == disabled_in_bios ]] \
        || fail "$platform_id 网卡 attachment/板载状态矛盾"
    [[ "$NIC_SUBSYSTEM_VEN:$NIC_SUBSYSTEM_DEV:$NIC_MAC_OUI" == \
       "0x8086:0xA01F:3c:fd:fe" ]] || fail "$platform_id 82574L 子系统/OUI 未绑定"
    [[ "$NVME_MAX_PCIE_GENERATION" -le "$PCIE_GENERATION" ]] \
        || fail "$platform_id NVMe 总线能力错误"
    [[ "$NVME_LANES" == 2 || "$NVME_LANES" == 4 ]] || fail "$platform_id NVMe lane 数错误"
    [[ "$NVME_ATTACHMENT" == m2_socket ]] || fail "$platform_id 没有物理 M.2 约束"
    [[ "$SYSTEM_CHASSIS_TYPE" == 0x03 ]] || fail "$platform_id chassis type 未绑定 Desktop"
    [[ "$AUDIO_CODEC:$AUDIO_CODEC_ID:$AUDIO_CODEC_REVISION:$AUDIO_CODEC_SUBSYSTEM_ID" == \
       "ALC887:0x10ec0887:0x00100302:0x104386c7" ]] \
        || fail "$platform_id ALC887 协议身份不完整"
    [[ "$AUDIO_IDENTITY_FIDELITY" == protocol_identity_only ]] \
        || fail "$platform_id 误声称完整 ALC887 拓扑"
    [[ "$MCH_PCI_VEN:$LPC_PCI_VEN:$SMBUS_PCI_VEN:$AHCI_PCI_VEN" == \
       "0x8086:0x8086:0x8086:0x8086" ]] || fail "$platform_id 启用芯片组厂商不一致"
    for identity in "$MCH_PCI_DEV:$MCH_REV" "$LPC_PCI_DEV:$LPC_REV" \
                    "$SMBUS_PCI_DEV:$SMBUS_REV" "$AHCI_PCI_DEV:$AHCI_REV"; do
        [[ "$identity" =~ ^0x[0-9A-Fa-f]{4}:0x[0-9A-Fa-f]{2}$ ]] \
            || fail "$platform_id 芯片组 device/revision 未完整导出: $identity"
    done
done

# AMD bundle 默认不能加载。新的窄门禁允许调用方在保持 STRICT_HARDWARE=1 的
# 同时显式接受 platform compatibility；旧的全局非严格直调语义暂时保留，但正常
# 启动器不再要求关闭 KVM/TPM/CPU realize 等无关检查。
amd_platform=amd-am4-r3-1200-asus-prime-b350-plus
if STRICT_HARDWARE=1 stealth_platform_load "$amd_platform" 2>/dev/null; then
    fail "严格模式不应加载 AMD/Q35 兼容 bundle"
fi
STRICT_HARDWARE=1 ALLOW_PLATFORM_COMPATIBILITY=1 \
    stealth_platform_load "$amd_platform" 2>/dev/null \
    || fail "显式 compatibility 门禁不应关闭其它严格检查"
[[ "$PLATFORM_STATUS" == compatibility ]] || fail "AMD bundle 未标 compatibility"
STRICT_HARDWARE=0 stealth_platform_load "$amd_platform" 2>/dev/null \
    || fail "非严格模式显式指定时应允许加载 AMD 兼容 bundle"
[[ "$PLATFORM_STATUS" == compatibility ]] || fail "AMD bundle 未标 compatibility"

# 正常 profile 选择路径必须同时验证“指定 ID + 显式 compatibility + 同厂商 +
# 完整线程数 + 频率/TSC”。没有第二把开关时，即使全局严格门禁开启也不能误选。
if (
    export STRICT_HARDWARE=1
    export ALLOW_PLATFORM_COMPATIBILITY=0
    export STEALTH_PLATFORM_ID="$amd_platform"
    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    stealth_pick_profile >/dev/null 2>&1
); then
    fail "显式 AMD ID 在未允许 compatibility 时被选择"
fi
(
    export STRICT_HARDWARE=1
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_PLATFORM_ID="$amd_platform"
    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    unset MEM_TOTAL_MB
    stealth_pick_profile >/dev/null 2>&1
    [[ "$PLATFORM_ID" == "$amd_platform" && "$PLATFORM_STATUS" == compatibility ]]
) || fail "显式 AMD compatibility 平台未通过完整宿主约束选择"
if (
    export STRICT_HARDWARE=1
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_PLATFORM_ID="$amd_platform"
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    stealth_pick_profile >/dev/null 2>&1
); then
    fail "显式 AMD compatibility 平台绕过了宿主 CPU 厂商约束"
fi

# 模拟 E5 v4 2.2GHz、无 TSC scaling：TSC 维度上唯一可生成的 4C/4T
# 候选是 i5-6400T。它仍须由上层在真实宿主进行 KVM CPU realize smoke；
# 本单元测试不得被解读为 E5 严格兼容性证明。
unset MEM_TOTAL_MB
# 选择器按全局变量名读取宿主视图；导出同时固定其调用的子进程环境。
export STEALTH_HOST_CPU_VENDOR=GenuineIntel
export STEALTH_HOST_CPU_MAX_MHZ=3600
export STEALTH_REQUIRED_TSC_MHZ=2200
export CPUS=4
stealth_pick_profile
[[ "$PLATFORM_ID" == intel-lga1151-i5-6400t-asus-h110m-a-m2 ]] \
    || fail "E5 v4 2200MHz 没选到 i5-6400T bundle: $PLATFORM_ID"
[[ "$NIC_MAC" == 3c:fd:fe:* ]] || fail "Intel 82574L 没使用 Intel OUI: $NIC_MAC"

# 无对应 TSC 或错误 vCPU 数必须失败，不能放宽到任意同厂 CPU。
export STEALTH_REQUIRED_TSC_MHZ=2300
if stealth_pick_profile >/dev/null 2>&1; then
    fail "无 2300MHz TSC 候选时发生了静默回退"
fi
export STEALTH_REQUIRED_TSC_MHZ=2200
export CPUS=2
if stealth_pick_profile >/dev/null 2>&1; then
    fail "CPUS=2 不应匹配完整 4C/4T SKU"
fi

# 平台字段必须随 profile 一起保存和安全加载，重启不能丢失 bundle 身份。
export CPUS=4
unset MEM_TOTAL_MB
stealth_pick_profile
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
profile="$tmp_dir/hardware.profile"
stealth_save_profile "$profile"
saved_id="$PLATFORM_ID"
unset PLATFORM_ID CPU_TSC_MHZ MEM_ALLOWED_TOTAL_MB NIC_ATTACHMENT SYSTEM_CHASSIS_TYPE AUDIO_CODEC_ID AUDIO_IDENTITY_FIDELITY
STRICT_HARDWARE=1 stealth_load_profile "$profile"

# save 可能被 `if !` 调用，Bash 会在整个函数体抑制 errexit；因此写入、chmod、
# rename 必须逐步显式返回失败。用 /dev/full 模拟磁盘短写，并让 mktemp 返回一个
# 攻击者预置的符号链接，确认不会误报成功或提交截断 profile。
failed_save_dir="$tmp_dir/failed-save"
failed_save_profile="$failed_save_dir/profile"
failed_save_tmp="$failed_save_dir/injected.tmp"
mkdir -p "$failed_save_dir"
# shellcheck disable=SC2317 # stealth_save_profile 会按命令名间接调用此测试替身。
mktemp() {
    ln -s /dev/full "$failed_save_tmp"
    printf '%s\n' "$failed_save_tmp"
}
if stealth_save_profile "$failed_save_profile" 2>/dev/null; then
    unset -f mktemp
    fail "profile 短写在条件调用上下文中被误报为成功"
fi
unset -f mktemp
[[ ! -e "$failed_save_profile" && ! -L "$failed_save_profile" ]] \
    || fail "profile 短写后提交了目标文件"
[[ ! -e "$failed_save_tmp" && ! -L "$failed_save_tmp" ]] \
    || fail "profile 短写后遗留不安全临时文件"
[[ "$PLATFORM_ID" == "$saved_id" && "$CPU_TSC_MHZ" == 2200 ]] \
    || fail "profile 重载后平台/TSC 漂移"
[[ "$MEM_ALLOWED_TOTAL_MB" == 2048,4096,8192 && "$NIC_ATTACHMENT" == add_in && \
   "$SYSTEM_CHASSIS_TYPE" == 0x03 ]] \
    || fail "profile 重载后平台约束丢失"
[[ "$AUDIO_CODEC_ID" == 0x10ec0887 && "$AUDIO_IDENTITY_FIDELITY" == protocol_identity_only ]] \
    || fail "profile 重载后音频协议身份丢失"

# catalog revision 是审计元数据，允许旧 profile 保留生成时的版本；但是
# CPU、BIOS 和 PCI 任一平台事实被手改都必须被严格加载器拒绝。
old_revision_profile="$tmp_dir/old-revision.profile"
sed 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-01-01.1/' \
    "$profile" >"$old_revision_profile"
chmod 600 "$old_revision_profile"
STRICT_HARDWARE=1 stealth_load_profile "$old_revision_profile" \
    || fail "事实未变时不应仅因 catalog revision 较旧而拒绝"

for tampered_field in CPU_NAME BIOS_VERSION MCH_PCI_DEV; do
    tampered_profile="$tmp_dir/tampered-${tampered_field}.profile"
    sed "s/^${tampered_field}=.*/${tampered_field}=forged/" "$profile" >"$tampered_profile"
    chmod 600 "$tampered_profile"
    if STRICT_HARDWARE=1 stealth_load_profile "$tampered_profile" >/dev/null 2>&1; then
        fail "严格模式接受了篡改字段: $tampered_field"
    fi
done

# 顶层 fidelity 是目录事实而非说明性文字。若把 supported 改解释为目标 PCH
# 等价，或让清单中的 Linux HDA 地址脱离真实 Q35 自动分配结果，加载器必须拒绝。
bad_fidelity="$tmp_dir/platforms-false-equivalence.json"
sed 's/"target_pch_bdf_equivalent": false/"target_pch_bdf_equivalent": true/' \
    "$REPO_ROOT/deploy/hardware/platforms.json" >"$bad_fidelity"
if STEALTH_PLATFORM_MANIFEST="$bad_fidelity" stealth_platform_validate >/dev/null 2>&1; then
    fail "清单错误宣称目标 PCH BDF 等价时未被拒绝"
fi

bad_bdf="$tmp_dir/platforms-bad-bdf.json"
sed 's/"linux_hda": "00:05.0"/"linux_hda": "00:06.0"/' \
    "$REPO_ROOT/deploy/hardware/platforms.json" >"$bad_bdf"
if STEALTH_PLATFORM_MANIFEST="$bad_bdf" stealth_platform_validate >/dev/null 2>&1; then
    fail "清单 BDF 与当前 Q35 启动器不一致时未被拒绝"
fi

bad_phys_bits="$tmp_dir/platforms-bad-phys-bits.json"
sed '0,/"phys_bits": 43/s//"phys_bits": 53/' \
    "$REPO_ROOT/deploy/hardware/platforms.json" >"$bad_phys_bits"
if STEALTH_PLATFORM_MANIFEST="$bad_phys_bits" stealth_platform_validate >/dev/null 2>&1; then
    fail "清单接受了 QEMU/KVM 无法实现的 53-bit CPU"
fi

# 删去 manifest 身份模拟旧 profile；严格模式必须要求用户显式 reroll，不能用
# 加载器补出的默认值冒充已审计平台。
legacy_profile="$tmp_dir/legacy.profile"
grep -Ev '^PLATFORM_(SCHEMA_VERSION|CATALOG_REVISION|ID|STATUS|RELEASE_YEAR)=' \
    "$profile" >"$legacy_profile"
chmod 600 "$legacy_profile"
unset PLATFORM_SCHEMA_VERSION PLATFORM_CATALOG_REVISION PLATFORM_ID PLATFORM_STATUS PLATFORM_RELEASE_YEAR
if STRICT_HARDWARE=1 stealth_load_profile "$legacy_profile" >/dev/null 2>&1; then
    fail "严格模式接受了 legacy-unversioned profile"
fi

# 未知 schema 必须拒绝，防止新旧加载器对同一字段作不同解释。
bad_manifest="$tmp_dir/platforms-bad.json"
sed 's/"schema_version": 1/"schema_version": 99/' \
    "$REPO_ROOT/deploy/hardware/platforms.json" >"$bad_manifest"
if STEALTH_PLATFORM_MANIFEST="$bad_manifest" stealth_platform_validate >/dev/null 2>&1; then
    fail "未知 schema_version 未被拒绝"
fi

echo "OK: versioned platform manifest checks passed"
