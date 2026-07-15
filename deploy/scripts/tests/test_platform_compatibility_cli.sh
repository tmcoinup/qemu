#!/usr/bin/env bash
# 验证 Linux 启动器的自动 platform compatibility 窄入口。测试只在临时目录
# 执行 DRY_RUN，并使用固定 QMP 替身；不会创建真实 profile、磁盘、TPM 或 VM。
# profile 生成与 Dock 检查使用隔离 subshell，里面的临时 export 不会影响后续
# 场景；同名变量跨 subshell 复用是测试隔离设计，不是意外覆盖。
# shellcheck disable=SC1091,SC2030,SC2031
# 测试从临时环境按绝对仓库路径加载库，SC1091 无法静态跟随这种运行时路径。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
START_VM="$REPO_ROOT/deploy/scripts/start-vm.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

QEMU_STUB="$TMP_DIR/qemu-system-x86_64"
cp "$SCRIPT_DIR/fixtures/qemu-cpu-preflight-stub.sh" "$QEMU_STUB"
chmod +x "$QEMU_STUB"

IMAGE_ROOT="$TMP_DIR/images"
PLATFORM_ID=amd-am4-r3-1200-asus-prime-b350-plus

# 中文注释：compatibility 只放宽整机 machine fidelity。其余能力显式注入为一台
# 48-bit、支持 TSC scaling 的 AMD KVM 宿主，确保成功路径仍经过严格 CPU smoke。
COMMON_ENV=(
    env
    IMAGE_ROOT="$IMAGE_ROOT"
    DRY_RUN=1
    TPM=0
    HOST_TUNE=0
    CPU_ISOLATE=0
    QEMU_CAP_CHECK=0
    STRICT_HARDWARE=1
    STEALTH_KVM_AVAILABLE=1
    STEALTH_KVM_TSC_CONTROL=1
    STEALTH_KVM_GET_TSC_KHZ=1
    STEALTH_KVM_TSC_KHZ=3393624
    STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    STEALTH_HOST_CPU_MAX_MHZ=5000
    STEALTH_HOST_CPU_PHYS_BITS=48
    QEMU="$QEMU_STUB"
    QEMU_IMG=/bin/true
)

success_log="$TMP_DIR/success.log"
VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9752 \
    --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$success_log" 2>&1 \
    || fail "自动 AMD compatibility DRY_RUN 未通过"
grep -E 'amd-am4-r3-(1200|2300x)-asus-prime-b350-plus' "$success_log" >/dev/null \
    || fail "自动选择没有得到与 AMD 宿主匹配的 compatibility 平台"
[[ ! -e "$IMAGE_ROOT/vms/9752/profile" && ! -e "$IMAGE_ROOT/vms/9752/disk.qcow2" ]] \
    || fail "compatibility DRY_RUN 写入了 profile 或磁盘"

# 长 ID 仍是可选的高级固定器，便于测试或运维明确指定目标；日常启动不需要记忆。
VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9760 \
    --platform-id="$PLATFORM_ID" \
    --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/explicit-pin.log" 2>&1 \
    || fail "可选显式 platform ID 固定路径未通过"
grep -F "$PLATFORM_ID" "$TMP_DIR/explicit-pin.log" >/dev/null \
    || fail "显式固定没有选择指定平台"

# 持久化 compatibility profile 后，后续启动只须携带 allow；具体 ID 已经写入
# profile。可选 ID 仍是断言，不能静默改变 Windows 硬件画像。
persisted_profile="$IMAGE_ROOT/vms/9753/profile"
mkdir -p "$(dirname "$persisted_profile")"
(
    source "$REPO_ROOT/deploy/scripts/stealth-lib.sh"
    export STRICT_HARDWARE=1
    export ALLOW_PLATFORM_COMPATIBILITY=1
    export STEALTH_PLATFORM_ID="$PLATFORM_ID"
    export STEALTH_HOST_CPU_VENDOR=AuthenticAMD
    export STEALTH_HOST_CPU_MAX_MHZ=5000
    export STEALTH_REQUIRED_TSC_MHZ=
    export CPUS=4
    unset MEM_TOTAL_MB
    stealth_pick_profile >/dev/null 2>&1
    stealth_save_profile "$persisted_profile"
)
profile_hash_before="$(sha256sum "$persisted_profile")"
VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9753 \
    --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/reload.log" 2>&1 \
    || {
        sed -n '1,80p' "$TMP_DIR/reload.log" >&2
        fail "已持久化的 compatibility profile 无法严格重载"
    }
profile_hash_after="$(sha256sum "$persisted_profile")"
[[ "$profile_hash_before" == "$profile_hash_after" ]] \
    || fail "普通重启改写了 compatibility profile"

# 显式 allow 是 compatibility profile 的生命周期不变量；全局诊断模式不能绕过。
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9753 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/non-strict-bypass.log" 2>&1; then
    fail "STRICT_HARDWARE=0 绕过了 compatibility profile 显式授权"
fi
grep -F 'compatibility profile 必须显式追加 --allow-platform-compatibility' \
    "$TMP_DIR/non-strict-bypass.log" >/dev/null \
    || fail "非严格绕过失败没有 allow 诊断"

# profile 是 0600 持久化文本但仍属于可编辑输入。即使攻击者把 compatibility
# 自报状态伪改成 supported，STRICT_HARDWARE=0 也必须从 manifest 取真值并拒绝，
# 不能把诊断模式变成绕过显式授权的入口。
tampered_profile="$IMAGE_ROOT/vms/9754/profile"
mkdir -p "$(dirname "$tampered_profile")"
cp "$persisted_profile" "$tampered_profile"
sed -i 's/^PLATFORM_STATUS=compatibility$/PLATFORM_STATUS=supported/' "$tampered_profile"
grep -Fx 'PLATFORM_STATUS=supported' "$tampered_profile" >/dev/null \
    || fail "测试未成功构造状态被篡改的 profile"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9754 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/tampered-status.log" 2>&1; then
    fail "篡改后的 PLATFORM_STATUS 绕过了 manifest compatibility 授权"
fi
grep -F 'profile 平台状态与 manifest 不一致' "$TMP_DIR/tampered-status.log" >/dev/null \
    || fail "状态篡改失败没有 manifest 真值诊断"

# 同时伪改 ID/status 指向 enabled 平台也不能逃过完整事实绑定，否则 profile 中
# 仍是 AMD CPU/主板，却会借 Intel supported ID 绕过 compatibility 授权。
tampered_id_profile="$IMAGE_ROOT/vms/9755/profile"
supported_platform=intel-lga1151-i3-9100f-asus-prime-h310m-a-r2
mkdir -p "$(dirname "$tampered_id_profile")"
cp "$persisted_profile" "$tampered_id_profile"
sed -i \
    -e "s/^PLATFORM_ID=.*/PLATFORM_ID=$supported_platform/" \
    -e 's/^PLATFORM_STATUS=compatibility$/PLATFORM_STATUS=supported/' \
    "$tampered_id_profile"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9755 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/tampered-id.log" 2>&1; then
    fail "伪改 supported 平台 ID 绕过了完整 manifest 事实绑定"
fi
grep -F 'profile 与平台' "$TMP_DIR/tampered-id.log" >/dev/null \
    || fail "平台 ID 篡改失败没有事实绑定诊断"

# compatibility 不能通过把 schema 降级成 legacy 来摆脱 manifest 真值检查。
legacy_compat_profile="$IMAGE_ROOT/vms/9756/profile"
mkdir -p "$(dirname "$legacy_compat_profile")"
cp "$persisted_profile" "$legacy_compat_profile"
sed -i 's/^PLATFORM_SCHEMA_VERSION=1$/PLATFORM_SCHEMA_VERSION=0/' "$legacy_compat_profile"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9756 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/legacy-compat.log" 2>&1; then
    fail "降级 schema 绕过了 compatibility 授权"
fi
grep -F 'profile 状态 compatibility 必须来自 schema 1 manifest' \
    "$TMP_DIR/legacy-compat.log" >/dev/null \
    || fail "schema 降级失败没有迁移诊断"

# schema 与 status 联合伪改不能绕过上述单字段检查：旧 schema 不得自称当前
# manifest 的 supported 状态，即使 STRICT_HARDWARE=0 也一样。
downgraded_supported_profile="$IMAGE_ROOT/vms/9757/profile"
mkdir -p "$(dirname "$downgraded_supported_profile")"
cp "$persisted_profile" "$downgraded_supported_profile"
sed -i \
    -e 's/^PLATFORM_SCHEMA_VERSION=1$/PLATFORM_SCHEMA_VERSION=0/' \
    -e 's/^PLATFORM_STATUS=compatibility$/PLATFORM_STATUS=supported/' \
    "$downgraded_supported_profile"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9757 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/downgraded-supported.log" 2>&1; then
    fail "schema/status 联合篡改绕过了 manifest 授权"
fi
grep -F 'profile 状态 supported 必须来自 schema 1 manifest' \
    "$TMP_DIR/downgraded-supported.log" >/dev/null \
    || fail "schema/status 联合篡改没有准确诊断"

# 删除全部平台元数据后，内容与真正的旧 profile 无法区分；STRICT_HARDWARE=0
# 本身不能再裸加载，必须额外给出名称明确的 legacy 诊断授权。
stripped_profile="$IMAGE_ROOT/vms/9758/profile"
mkdir -p "$(dirname "$stripped_profile")"
grep -Ev '^PLATFORM_(SCHEMA_VERSION|CATALOG_REVISION|ID|STATUS|RELEASE_YEAR)=' \
    "$persisted_profile" >"$stripped_profile"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9758 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/stripped-profile.log" 2>&1; then
    fail "删除全部 PLATFORM 元数据后裸绕过了 legacy 授权"
fi
grep -F 'legacy profile 的非严格诊断加载必须显式追加 --allow-legacy-profile' \
    "$TMP_DIR/stripped-profile.log" >/dev/null \
    || fail "删除平台元数据后没有显式 legacy 授权诊断"
VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9758 --allow-legacy-profile \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/explicit-legacy.log" 2>&1 \
    || fail "显式 legacy 诊断授权无法加载无绑定旧 profile"
grep -F '__DRY_RUN_ARGV__' "$TMP_DIR/explicit-legacy.log" >/dev/null \
    || fail "显式 legacy 诊断没有完成只读 argv 生成"

# legacy 放行绝不能在默认严格模式下生效，避免名称含 allow 的选项造成错误安全感。
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9758 --allow-legacy-profile \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/strict-legacy-allow.log" 2>&1; then
    fail "严格模式错误接受了 legacy profile 放行"
fi
grep -F -- '--allow-legacy-profile 仅能与显式 STRICT_HARDWARE=0' \
    "$TMP_DIR/strict-legacy-allow.log" >/dev/null \
    || fail "严格模式 legacy 放行没有准确 CLI 诊断"

# legacy 只表示缺省 schema 0，不是“任意未知版本”；显式 99 必须始终拒绝。
unknown_schema_profile="$IMAGE_ROOT/vms/9759/profile"
mkdir -p "$(dirname "$unknown_schema_profile")"
cp "$stripped_profile" "$unknown_schema_profile"
sed -i '1iPLATFORM_SCHEMA_VERSION=99' "$unknown_schema_profile"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STRICT_HARDWARE=0 \
    "$START_VM" 9759 --allow-legacy-profile \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/unknown-schema.log" 2>&1; then
    fail "未知 profile schema 被 legacy 放行接受"
fi
grep -F 'profile schema 不受支持: 99' "$TMP_DIR/unknown-schema.log" >/dev/null \
    || fail "未知 profile schema 没有准确诊断"

# 已有 profile 不能只靠 QEMU smoke；每次启动都重新核对宿主厂商、频率、完整
# 线程数，以及无 TSC scaling 时的精确频率。
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STEALTH_HOST_CPU_VENDOR=GenuineIntel \
    "$START_VM" 9753 --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/vendor.log" 2>&1; then
    fail "已有 AMD profile 绕过了宿主 CPU 厂商约束"
fi
grep -F 'profile CPU 厂商与宿主不一致' "$TMP_DIR/vendor.log" >/dev/null \
    || fail "跨厂商 profile 缺少准确诊断"

if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STEALTH_HOST_CPU_MAX_MHZ=2000 \
    "$START_VM" 9753 --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/frequency.log" 2>&1; then
    fail "已有 AMD profile 绕过了宿主最大频率约束"
fi
grep -F '超过宿主可达 2000MHz' "$TMP_DIR/frequency.log" >/dev/null \
    || fail "宿主频率不足缺少准确诊断"

if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" CPUS=2 \
    "$START_VM" 9753 --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/threads.log" 2>&1; then
    fail "已有 AMD profile 绕过了完整线程数约束"
fi
grep -F 'profile 要求完整 4 线程，当前 CPUS=2' "$TMP_DIR/threads.log" >/dev/null \
    || fail "线程数不符缺少准确诊断"

if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    STEALTH_KVM_TSC_CONTROL=0 STEALTH_KVM_TSC_KHZ=3200000 \
    "$START_VM" 9753 --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/tsc.log" 2>&1; then
    fail "已有 AMD profile 绕过了无 scaling 的 TSC 约束"
fi
grep -F 'profile TSC=3100MHz 与宿主必需 3200MHz 不一致' "$TMP_DIR/tsc.log" >/dev/null \
    || fail "TSC 不符缺少准确诊断"

# reroll 候选必须等磁盘等后置门禁全部通过才提交。用 1TB 历史盘模拟用户的
# 旧实例；当前 512GB 组件拒绝后，旧 profile 哈希必须原样保留。
printf '%s' 1000204886016 >"$IMAGE_ROOT/vms/9753/disk.qcow2"
reroll_hash_before="$(sha256sum "$persisted_profile")"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    QEMU_IMG="$SCRIPT_DIR/fixtures/qemu-img-capacity-stub.py" \
    "$START_VM" 9753 --reroll \
    --platform-id="$PLATFORM_ID" --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/reroll-disk.log" 2>&1; then
    fail "reroll 意外接受了容量不匹配的历史磁盘"
fi
grep -F '磁盘虚拟容量与硬件 profile 不一致' "$TMP_DIR/reroll-disk.log" >/dev/null \
    || fail "reroll 容量失败缺少准确诊断"
reroll_hash_after="$(sha256sum "$persisted_profile")"
[[ "$reroll_hash_before" == "$reroll_hash_after" ]] \
    || fail "reroll 在磁盘门禁失败前覆盖了旧 profile"
rm -f "$IMAGE_ROOT/vms/9753/disk.qcow2"

mismatched_platform=amd-am4-r3-2300x-asus-prime-b350-plus
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9753 \
    --platform-id="$mismatched_platform" \
    --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/mismatch.log" 2>&1; then
    fail "已有 profile 被另一个命令行平台 ID 静默替换"
fi
grep -F '如确需更换整机身份，请备份后显式追加 --reroll' "$TMP_DIR/mismatch.log" >/dev/null \
    || fail "已有 profile 平台不一致时没有安全迁移诊断"

# Dock 与管理工具属于同一次已授权实例生命周期，必须自动保留 allow，不能
# 生成一个下一次必然被 profile loader 拒绝的裸启动命令。
(
    export HOME="$TMP_DIR/home"
    export HERE="$REPO_ROOT/deploy/scripts"
    export REPO_ROOT
    export PLATFORM_STATUS=compatibility
    export PLATFORM_ID
    export ALLOW_PLATFORM_COMPATIBILITY=1
    source "$REPO_ROOT/deploy/scripts/lib/sv-dock.sh"
    _sv_dock_write_desktop 9753
)
dock_desktop="$TMP_DIR/home/.local/share/applications/win10-9753.desktop"
grep -F "Exec=$REPO_ROOT/deploy/scripts/sv-dock-launch.sh 9753 --proxy --allow-platform-compatibility" \
    "$dock_desktop" >/dev/null || fail "Dock Exec 丢失 compatibility allow"

memory_log="$TMP_DIR/set-memory.log"
VMS_DIR="$IMAGE_ROOT/vms" \
    "$REPO_ROOT/deploy/scripts/set-vm-memory.sh" 9753 4G >"$memory_log" 2>&1 \
    || fail "内存管理工具无法加载 compatibility profile"
grep -F -- "--allow-platform-compatibility" "$memory_log" >/dev/null \
    || fail "内存管理工具的重启提示丢失 compatibility allow"
if grep -F -- "--platform-id=" "$memory_log" >/dev/null; then
    fail "内存管理工具仍要求记忆 compatibility 平台 ID"
fi
# 旧 host 安装器曾负责二次重启并传播 compatibility 参数；当前自签/深层路径
# 已彻底退役，因此这里改验“无副作用 fail-fast”。这样旧自动化不会静默启动一个
# PCI 主 ID 错误的 VM，也不会再通过 SSH 修改 guest。
legacy_installer="$REPO_ROOT/deploy/scripts/install-stealth.sh"
legacy_installer_log="$TMP_DIR/legacy-installer.log"
legacy_installer_status=0
"$legacy_installer" 9753 --allow-platform-compatibility \
    >"$legacy_installer_log" 2>&1 || legacy_installer_status=$?
[[ "$legacy_installer_status" -eq 64 ]] \
    || fail "退役 guest 安装器没有以约定退出码 64 拒绝执行"
grep -F '已退役，未对 host 或 guest 做任何修改' "$legacy_installer_log" >/dev/null \
    || fail "退役 guest 安装器缺少无副作用迁移诊断"
grep -F 'deploy/guest-stealth/package.sh' "$legacy_installer_log" >/dev/null \
    || fail "退役 guest 安装器没有指向统一 EXE 流程"
if grep -F -e 'sv_qemu_instance_pids' -e 'start-vm.sh' -e 'ssh ' -e 'scp ' \
        "$legacy_installer" >&2; then
    fail "退役 guest 安装器仍保留 host/guest 变更动作"
fi

# 仅指定禁用 ID 不够；必须有第二个、名称明确的 compatibility 开关。
missing_allow_log="$TMP_DIR/missing-allow.log"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9752 \
    --platform-id="$PLATFORM_ID" \
    --no-sdl --no-fb-shm --no-bridge >"$missing_allow_log" 2>&1; then
    fail "禁用 AMD 平台在没有显式 compatibility 开关时启动成功"
fi
grep -F -- '--allow-platform-compatibility' "$missing_allow_log" >/dev/null \
    || fail "缺少 compatibility 开关时没有可操作诊断"

# compatibility 开关不能关闭 CPU no-warning smoke；QEMU 替身打印 warning 后应
# 在任何持久化写入前失败。
warning_log="$TMP_DIR/warning.log"
if VMATE_QEMU_STUB_MODE=warning "${COMMON_ENV[@]}" \
    "$START_VM" 9752 \
    --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$warning_log" 2>&1; then
    fail "compatibility 入口错误地跳过了 CPU warning 门禁"
fi
grep -F '选定 CPU 无法由当前 KVM 宿主无警告实现' "$warning_log" >/dev/null \
    || fail "CPU warning 失败缺少严格门禁诊断"

# 宿主位宽不足时 host-phys-bits-limit 会改变客体事实，必须在 CPU smoke 前拒绝。
phys_bits_log="$TMP_DIR/phys-bits.log"
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" STEALTH_HOST_CPU_PHYS_BITS=42 \
    "$START_VM" 9752 \
    --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$phys_bits_log" 2>&1; then
    fail "42-bit 宿主错误地实现了 43-bit Ryzen profile"
fi
grep -F '无法实现 profile 要求的 43 位' "$phys_bits_log" >/dev/null \
    || fail "物理地址位宽失败缺少准确诊断"

# AMD 宿主未给 allow 时仍不能自动把 compatibility 当成 supported 随机池。
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    "$START_VM" 9761 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/no-allow-auto.log" 2>&1; then
    fail "AMD 宿主在没有 allow 时自动选择了 compatibility 平台"
fi
grep -F '无可用整机平台' "$TMP_DIR/no-allow-auto.log" >/dev/null \
    || fail "AMD 自动选择缺少 allow 时没有准确诊断"
grep -F '请追加 --allow-platform-compatibility' "$TMP_DIR/no-allow-auto.log" >/dev/null \
    || fail "存在可用 compatibility 平台时没有提示 allow 参数"

# 若宿主约束连 compatibility 也无法满足，追加 allow 不会解决问题，此时不能给出
# 误导性建议。用频率明显不足的 Intel 宿主视图覆盖 COMMON_ENV 中的 AMD 值。
if VMATE_QEMU_STUB_MODE=good "${COMMON_ENV[@]}" \
    STEALTH_HOST_CPU_VENDOR=GenuineIntel STEALTH_HOST_CPU_MAX_MHZ=1000 \
    "$START_VM" 9762 \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/no-compatible-fallback.log" 2>&1; then
    fail "不满足任何平台约束的宿主错误选中了整机平台"
fi
if grep -F -- '--allow-platform-compatibility' \
    "$TMP_DIR/no-compatible-fallback.log" >/dev/null; then
    fail "没有可用 compatibility 平台时给出了无效 allow 建议"
fi

unknown_id=amd-am4-r3-9999x-does-not-exist
if "${COMMON_ENV[@]}" "$START_VM" 9752 \
    --platform-id="$unknown_id" --allow-platform-compatibility \
    --no-sdl --no-fb-shm --no-bridge >"$TMP_DIR/unknown-id.log" 2>&1; then
    fail "不存在的平台 ID 被 CLI 接受"
fi
grep -F -- "--platform-id 指向不存在的平台: '$unknown_id'" "$TMP_DIR/unknown-id.log" >/dev/null \
    || fail "不存在的平台 ID 没有准确诊断"

echo "OK: automatic platform compatibility CLI checks passed"
