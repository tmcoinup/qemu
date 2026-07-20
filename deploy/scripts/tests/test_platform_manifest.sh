#!/usr/bin/env bash
# 验证版本化整机 manifest、严格候选选择、E5 v4 的 2200MHz TSC 路径，以及
# profile 持久化。测试完全在临时目录运行，不启动 QEMU、不修改已有 VM。
# 下方三个隔离 subshell 故意复用相同变量名构造互斥宿主视图；赋值不会跨 subshell
# 泄漏，SC2030/SC2031 在这里正是预期语义。
# shellcheck disable=SC2030,SC2031,SC2034,SC2153,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/fixtures/catalog-cpu-preflight-stub.sh"
stealth_platform_validate >/dev/null
# JSON 索引必须同时保留可审计的兼容条目和可随机的 supported 条目；兼容条目
# 不能因为同厂商而偷偷进入随机池。
mapfile -t platform_rows < <(stealth_platform_index)
(( ${#platform_rows[@]} == 5 )) || fail "平台数量应为 5，实际 ${#platform_rows[@]}"

# 审计白名单钉住型号、系列、料号、主板和年代。结构校验只能证明字段自洽，
# 不能代替 DMTF/CPU 厂商/主板支持表中的外部事实。
python3 - "$REPO_ROOT/deploy/hardware/platforms.json" <<'PY' || \
    fail "平台审计事实与清单不一致"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    platforms = {item["id"]: item for item in json.load(stream)["platforms"]}
expected = {
    "amd-am4-r3-1200-asus-prime-b350-plus": (
        False, "compatibility", 2017, "AMD Ryzen 3 1200 Quad-Core Processor",
        "YD1200BBM4KAE", "PRIME B350-PLUS", "0x006B", "0x00EC", True),
    "intel-lga1151-i3-9100f-asus-prime-h310m-a-r2": (
        True, "supported", 2019, "Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz",
        "BX80684I39100F", "PRIME H310M-A R2.0", "0x00CE", "0x00EC", True),
    "intel-lga1151-celeron-g4900-asus-prime-h310m-a-r2": (
        True, "supported", 2018, "Intel(R) Celeron(R) G4900 CPU @ 3.10GHz",
        "BX80684G4900", "PRIME H310M-A R2.0", "0x00C7", "0x00EC", True),
    "intel-lga1151-pentium-g5400-asus-prime-h310m-a-r2": (
        True, "supported", 2018, "Intel(R) Pentium(R) Gold G5400 CPU @ 3.70GHz",
        "BX80684G5400", "PRIME H310M-A R2.0", "0x000B", "0x00FC", True),
    "intel-lga1151-i5-6400t-asus-h110m-a-m2": (
        True, "supported", 2016, "Intel(R) Core(TM) i5-6400T CPU @ 2.20GHz",
        "BXC80662I56400T", "H110M-A/M.2", "0x00CD", "0x00EC", False),
}
if set(platforms) != set(expected):
    raise SystemExit("平台 ID 集合不是审计后的五个 bundle")
for platform_id, facts in expected.items():
    item = platforms[platform_id]
    cpu = item["cpu"]
    actual = (
        item["enabled"], item["status"], item["release_year"], cpu["name"],
        cpu["part"], item["board"]["product"], cpu["smbios"]["family"],
        cpu["smbios"]["characteristics"], item["tpm"]["supported"])
    if actual != facts:
        raise SystemExit(f"{platform_id}: {actual!r} != {facts!r}")
PY

enabled_count=0
for row in "${platform_rows[@]}"; do
    IFS='|' read -r platform_id enabled vendor max_mhz threads tsc_mhz <<<"$row"
    [[ "$platform_id" =~ ^[a-z0-9-]+$ ]] || fail "平台 ID 格式错误: $platform_id"
    [[ "$vendor" == GenuineIntel || "$vendor" == AuthenticAMD ]] || fail "CPU 厂商错误"
    [[ "$max_mhz" =~ ^[0-9]+$ && "$threads" =~ ^[0-9]+$ && "$tsc_mhz" =~ ^[0-9]+$ ]] \
        || fail "平台数字字段错误: $row"
    [[ "$enabled" == true ]] && enabled_count=$((enabled_count + 1))
done
(( enabled_count == 4 )) || fail "随机平台应只有四个 Intel bundle"

# 每个平台（包括默认不进入随机池的 compatibility 条目）都必须能完整导出，
# 且 CPU、内存、BIOS、PCI、TPM 和板载设备字段相互约束。
for row in "${platform_rows[@]}"; do
    IFS='|' read -r platform_id enabled _ _ _ _ <<<"$row"
    if [[ "$enabled" == true ]]; then
        stealth_platform_load "$platform_id"
        [[ "$PLATFORM_STATUS" == supported ]] \
            || fail "$platform_id 启用平台不是 supported"
    else
        STRICT_HARDWARE=1 ALLOW_PLATFORM_COMPATIBILITY=1 \
            stealth_platform_load "$platform_id"
        [[ "$PLATFORM_STATUS" == compatibility ]] \
            || fail "$platform_id 禁用平台不是 compatibility"
    fi
    [[ "$PLATFORM_SCHEMA_VERSION" == 1 ]] || fail "$platform_id schema 错误"
    (( CPU_CORES == 2 || CPU_CORES == 4 )) \
        || fail "$platform_id 核数不在已审计桌面 SKU 范围"
    (( CPU_THREADS == 2 || CPU_THREADS == 4 )) \
        || fail "$platform_id 线程数不在已审计桌面 SKU 范围"
    (( CPU_TSC_MHZ == CPU_CUR_MHZ )) || fail "$platform_id TSC 与基准频率不一致"
    if [[ "$CPU_VENDOR" == GenuineIntel ]]; then
        [[ "$CPU_FEATURES" != *topoext* ]] || fail "Intel 平台带入 AMD topoext"
    else
        [[ "$CPU_FEATURES" == *topoext* ]] || fail "AMD 平台缺少 topoext"
    fi
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
    if [[ "$platform_id" == intel-lga1151-i5-6400t-asus-h110m-a-m2 ]]; then
        [[ "$TPM_CAPABILITY:$TPM_SUPPORTED:$TPM_IMPLEMENTATION:$TPM_VERSION:$TPM_FRONTEND:$TPM_PCR_BANKS" == \
           "none:0:none:none:none:" ]] \
            || fail "$platform_id 在缺少板级 PTT 证据时没有 fail closed"
    elif [[ "$CPU_VENDOR" == GenuineIntel ]]; then
        [[ "$TPM_CAPABILITY:$TPM_SUPPORTED:$TPM_IMPLEMENTATION:$TPM_VERSION:$TPM_FRONTEND:$TPM_PCR_BANKS" == \
           "firmware:1:intel-ptt:2.0:tpm-crb:sha256" ]] \
            || fail "$platform_id Intel PTT 能力没有完整导出"
    else
        [[ "$TPM_CAPABILITY:$TPM_SUPPORTED:$TPM_IMPLEMENTATION:$TPM_VERSION:$TPM_FRONTEND:$TPM_PCR_BANKS" == \
           "firmware:1:amd-ftpm:2.0:tpm-crb:sha256" ]] \
            || fail "$platform_id AMD fTPM 能力没有完整导出"
    fi
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

# 显式 ID 的高级选择路径必须验证“compatibility allow + 同厂商 + 完整线程数 +
# 频率/TSC”。没有 allow 时，即使全局严格门禁开启也不能误选。
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

# allow 是受支持候选缺失时的回退授权，不是强制降级。未知 Intel 宿主同时有
# 静态 supported 与同厂商 household compatibility 候选，必须始终先用前者；
# 测试不得篡改已做完整摘要绑定的生产目录来伪造 supported 状态。
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
(
    export STRICT_HARDWARE=1
    export ALLOW_PLATFORM_COMPATIBILITY=1
    unset STEALTH_PLATFORM_ID MEM_TOTAL_MB
    export STEALTH_PLATFORM_MANIFEST="$REPO_ROOT/deploy/hardware/platforms.json"
    export STEALTH_HOST_CPU_VENDOR=GenuineIntel
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    mapfile -t PLATFORM_POOL < <(stealth_platform_index)
    for _ in 1 2 3 4; do
        stealth_pick_profile >/dev/null 2>&1
        [[ "$PLATFORM_STATUS" == supported &&
           "$PLATFORM_CPU_SOURCE" == manifest ]] \
            || fail "存在匹配 supported 平台时错误回退 compatibility: $PLATFORM_ID"
    done
) || fail "supported 优先于 compatibility 的回退策略失效"

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
profile="$tmp_dir/hardware.profile"
stealth_save_profile "$profile"
saved_id="$PLATFORM_ID"
unset PLATFORM_ID CPU_TSC_MHZ MEM_ALLOWED_TOTAL_MB NIC_ATTACHMENT SYSTEM_CHASSIS_TYPE
unset AUDIO_CODEC_ID AUDIO_IDENTITY_FIDELITY TPM_CAPABILITY TPM_SUPPORTED
unset TPM_IMPLEMENTATION TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS
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
[[ "$TPM_CAPABILITY:$TPM_SUPPORTED:$TPM_IMPLEMENTATION:$TPM_VERSION:$TPM_FRONTEND:$TPM_PCR_BANKS" == \
   "none:0:none:none:none:" ]] \
    || fail "profile 重载后 TPM 平台能力丢失"

# 升级前 schema-1 profile 尚未保存 TPM_*。六项全部缺失时只能按原
# PLATFORM_ID 在内存中补齐，不能要求用户丢弃既有 TPM state；部分缺失则
# 必须视为截断/篡改，避免混合旧值和新目录事实。
old_tpm_profile="$tmp_dir/old-tpm.profile"
grep -Ev '^TPM_(CAPABILITY|SUPPORTED|IMPLEMENTATION|VERSION|FRONTEND|PCR_BANKS)=' \
    "$profile" >"$old_tpm_profile"
chmod 600 "$old_tpm_profile"
unset TPM_CAPABILITY TPM_SUPPORTED TPM_IMPLEMENTATION
unset TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS
STRICT_HARDWARE=1 stealth_load_profile "$old_tpm_profile"
[[ "$TPM_CAPABILITY:$TPM_SUPPORTED:$TPM_IMPLEMENTATION:$TPM_VERSION:$TPM_FRONTEND:$TPM_PCR_BANKS" == \
   "none:0:none:none:none:" ]] \
    || fail "旧 schema-1 profile 未按原平台补齐 TPM 事实"
if grep -q '^TPM_' "$old_tpm_profile"; then
    fail "加载旧 profile 时非原子地改写了磁盘文件"
fi

partial_tpm_profile="$tmp_dir/partial-tpm.profile"
grep -v '^TPM_VERSION=' "$profile" >"$partial_tpm_profile"
chmod 600 "$partial_tpm_profile"
unset TPM_CAPABILITY TPM_SUPPORTED TPM_IMPLEMENTATION
unset TPM_VERSION TPM_FRONTEND TPM_PCR_BANKS
if STRICT_HARDWARE=1 stealth_load_profile "$partial_tpm_profile" \
    >/dev/null 2>&1; then
    fail "部分缺失 TPM 平台字段的 schema-1 profile 被接受"
fi

# catalog revision 是审计元数据，允许旧 profile 保留生成时的版本；但是
# CPU、BIOS 和 PCI 任一平台事实被手改都必须被严格加载器拒绝。
old_revision_profile="$tmp_dir/old-revision.profile"
sed 's/^PLATFORM_CATALOG_REVISION=.*/PLATFORM_CATALOG_REVISION=2026-01-01.1/' \
    "$profile" >"$old_revision_profile"
chmod 600 "$old_revision_profile"
STRICT_HARDWARE=1 stealth_load_profile "$old_revision_profile" \
    || fail "事实未变时不应仅因 catalog revision 较旧而拒绝"

for tampered_field in CPU_NAME BIOS_VERSION MCH_PCI_DEV TPM_VERSION TPM_FRONTEND; do
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

# 正常池只允许已审计的小型家用拓扑；完整 CPU 摘要还须拒绝通用校验会接受的
# i5 stepping/phys_bits/features 联动漂移和 AMD compatibility CPU 漂移。
python3 - "$REPO_ROOT/deploy/hardware/platforms.json" "$tmp_dir" <<'PY'
import copy
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    original = json.load(stream)
for mode in ("8c16t", "xeon-e5", "bare-e", "qemu64", "audited-facts", "amd-facts"):
    manifest = copy.deepcopy(original)
    target = ("amd-am4-r3-1200-asus-prime-b350-plus" if mode == "amd-facts"
              else "intel-lga1151-i5-6400t-asus-h110m-a-m2")
    cpu = next(item["cpu"] for item in manifest["platforms"] if item["id"] == target)
    if mode == "8c16t":
        cpu.update(cores=8, threads=16)
        cpu["smbios"]["characteristics"] = "0x00FC"
    elif mode == "qemu64":
        cpu["qemu_arg"] = "qemu64," + cpu["qemu_arg"].split(",", 1)[1]
    elif mode == "audited-facts":
        cpu["qemu_arg"] = cpu["qemu_arg"].replace("stepping=3", "stepping=4")
        cpu.update(phys_bits=40, features="+invtsc,+tsc-deadline,+ssse3")
    elif mode == "amd-facts":
        cpu.update(phys_bits=44, features=cpu["features"] + ",+ssse3")
    else:
        marker = "Xeon(R) E5-2680 v4" if mode == "xeon-e5" else "E-2288G"
        old_name = cpu["name"]
        cpu["name"] = f"{old_name} {marker}"
        cpu["qemu_arg"] = cpu["qemu_arg"].replace(old_name, cpu["name"])
    pathlib.Path(sys.argv[2], f"platforms-bad-{mode}.json").write_text(
        json.dumps(manifest), encoding="utf-8")
PY
for mutation in 8c16t xeon-e5 bare-e qemu64 audited-facts amd-facts; do
    if STEALTH_PLATFORM_MANIFEST="$tmp_dir/platforms-bad-$mutation.json" \
        stealth_platform_validate >/dev/null 2>&1; then
        fail "正常池非法 CPU 变异未被拒绝: $mutation"
    fi
done

for mutation in characteristics family; do
    bad_cpu="$tmp_dir/platforms-bad-$mutation.json"
    if [[ "$mutation" == characteristics ]]; then
        sed '0,/"characteristics": "0x00EC"/s//"characteristics": "0x00FC"/' \
            "$REPO_ROOT/deploy/hardware/platforms.json" >"$bad_cpu"
    else
        sed '0,/"family": "0x006B"/s//"family": "0x0139"/' \
            "$REPO_ROOT/deploy/hardware/platforms.json" >"$bad_cpu"
    fi
    if STEALTH_PLATFORM_MANIFEST="$bad_cpu" \
        stealth_platform_validate >/dev/null 2>&1; then
        fail "清单接受了错误的 SMBIOS $mutation"
    fi
done

swapped_tuple="$tmp_dir/platforms-swapped-cpu.json"
python3 - "$REPO_ROOT/deploy/hardware/platforms.json" "$swapped_tuple" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["platforms"][1]["cpu"], manifest["platforms"][2]["cpu"] = (
    manifest["platforms"][2]["cpu"], manifest["platforms"][1]["cpu"])
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
PY
if STEALTH_PLATFORM_MANIFEST="$swapped_tuple" \
    stealth_platform_validate >/dev/null 2>&1; then
    fail "清单接受了跨平台互换的 CPU/主板组合"
fi

# TPM 是平台事实而不是启动器默认值。构造最小定向变异，确认缺字段、
# TPM 1.2 错配 CRB，以及 unsupported 却仍声明 guest device 都会 fail closed。
make_bad_tpm_manifest() {
    local target="$1"
    local mutation="$2"
    python3 - "$REPO_ROOT/deploy/hardware/platforms.json" "$target" "$mutation" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
mutation = sys.argv[3]
with source.open("r", encoding="utf-8") as stream:
    manifest = json.load(stream)
tpm = manifest["platforms"][0]["tpm"]
if mutation == "missing":
    del tpm["pcr_banks"]
elif mutation == "crb12":
    tpm["version"] = "1.2"
    tpm["pcr_banks"] = ["sha1"]
elif mutation == "unsupported-device":
    tpm.update({
        "capability": "none",
        "supported": False,
        "implementation": "none",
        "version": "none",
        "emulation_frontend": "tpm-tis",
        "pcr_banks": [],
    })
elif mutation == "untrusted-source":
    tpm["support_source_ref"] = "https://example.invalid/tpm"
elif mutation == "same-sources":
    tpm["version_source_ref"] = tpm["support_source_ref"]
else:
    raise SystemExit(f"unknown mutation: {mutation}")
with target.open("w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
PY
}

for mutation in missing crb12 unsupported-device untrusted-source same-sources; do
    bad_tpm="$tmp_dir/platforms-bad-tpm-$mutation.json"
    make_bad_tpm_manifest "$bad_tpm" "$mutation"
    if STEALTH_PLATFORM_MANIFEST="$bad_tpm" \
        stealth_platform_validate >/dev/null 2>&1; then
        fail "非法 TPM 清单未被拒绝: $mutation"
    fi
done

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
