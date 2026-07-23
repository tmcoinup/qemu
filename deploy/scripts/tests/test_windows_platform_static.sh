#!/usr/bin/env bash
# Windows/WHPX 平台、身份持久化、严格门禁和编码器选择回归。
# 仅用无副作用 DryRun/profile 函数；真实 WHPX 仍须在 Windows 物理宿主验收。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"
DISPLAY="$REPO_ROOT/deploy/windows/lib/VMate.Display.ps1"
STREAMER="$REPO_ROOT/deploy/windows/stream-fb-shm.ps1"
MANIFEST="$REPO_ROOT/deploy/hardware/platforms.json"
COMPONENTS="$REPO_ROOT/deploy/hardware/components.json"
PLATFORM_ID="intel-lga1151-i3-9100f-asus-prime-h310m-a-r2"
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
require_text() {
    local needle="$1"
    local file="$2"
    grep -F -- "$needle" "$file" >/dev/null \
        || fail "missing '$needle' in $file"
}
pwsh_bin() {
    command -v pwsh || command -v powershell || true
}
test_windows_powershell_files_have_bom() {
    local file signature
    while IFS= read -r -d '' file; do
        signature="$(od -An -tx1 -N3 "$file" | tr -d ' \n')"
        [[ "$signature" == "efbbbf" ]] \
            || fail "Windows PowerShell 5.1 UTF-8 BOM missing: $file"
    done < <(find "$REPO_ROOT/deploy/windows" -type f -name '*.ps1' -print0)
    for file in \
        "$REPO_ROOT/deploy/scripts/tests/test_windows_manifest_integrity.ps1" \
        "$REPO_ROOT/deploy/scripts/tests/test_windows_profile_integrity.ps1" \
        "$REPO_ROOT/deploy/scripts/tests/test_windows_powershell51.ps1"; do
        signature="$(od -An -tx1 -N3 "$file" | tr -d ' \n')"
        [[ "$signature" == "efbbbf" ]] \
            || fail "Windows PowerShell 5.1 test BOM missing: $file"
    done
}
prepare_vm_files() {
    local root="$1"
    mkdir -p "$root/user"
    printf 'firmware-fixture' | tee "$root/disk.qcow2" "$root/code.fd" >"$root/vars.fd"
}
run_launcher_dry() {
    local shell_bin="$1"
    local root="$2"
    local platform_id="${VMATE_TEST_PLATFORM_ID:-$PLATFORM_ID}"
    local host_cpu='Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz'
    if [[ "$platform_id" == *'-i5-6400t-'* ]]; then
        host_cpu='Intel(R) Core(TM) i5-6400T CPU @ 2.20GHz'
    fi
    shift 2
    USERPROFILE="$root/user" "$shell_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$LAUNCHER" -Qemu /bin/true -VmRoot "$root/vm" \
        -Disk "$root/disk.qcow2" -OvmfCode "$root/code.fd" \
        -OvmfVarsTemplate "$root/vars.fd" -HardwareManifest "$MANIFEST" \
        -ComponentManifest "$COMPONENTS" \
        -PlatformId "$platform_id" -FbShmPath "$root/fb.sock" \
        -GpuGlProbe Unavailable -DryRunHostCpuName "$host_cpu" -DryRun "$@"
}
test_static_policy_markers() {
    require_text "[switch]\$AllowTcgFallback" "$LAUNCHER"
    require_text "[switch]\$AllowPlatformCompatibility" "$LAUNCHER"
    require_text "[switch]\$RequireNestedVirtualization" "$LAUNCHER"
    require_text "[string]\$HardwareManifest = ''" "$LAUNCHER"
    require_text "[string]\$ComponentManifest = ''" "$LAUNCHER"
    require_text "deploy\\hardware\\platforms.json" "$LAUNCHER"
    require_text "deploy\\hardware\\components.json" "$LAUNCHER"
    require_text "'-cpu', \$guestCpuArgument" "$LAUNCHER"
    require_text "'-uuid'" "$LAUNCHER"
    require_text "'-rtc'" "$LAUNCHER"
    require_text "New-VMateSmbiosArguments" "$LAUNCHER"
    require_text "Enter-VMateProfileCommitLock" "$LAUNCHER"
    require_text "Prepare-VMateHardwareProfile" "$LAUNCHER"
    require_text "Commit-VMateHardwareProfile" "$LAUNCHER"
    require_text "Exit-VMateProfileCommitLock" "$LAUNCHER"
    require_text "Read-VMateComponentManifest" "$LAUNCHER"
    require_text "Assert-VMateStorageCapacity" "$LAUNCHER"
    require_text "(Join-Path \$repo 'qemu-system-x86_64.exe')" "$LAUNCHER"
    require_text "(Join-Path \$repo 'qemu-fb-shm-stream.exe')" "$STREAMER"
    require_text "Windows11" "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
    require_text "TPM 2.0 + Secure Boot" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
    require_text "whpx,hyperv=off,kernel-irqchip=off" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
    require_text 'Assert-VMateQemuDeviceCapabilities -Qemu $Qemu' \
        "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
    require_text "'virtio-vga-gl,edid=on,edid-fixed-native=on,'" "$LAUNCHER"
    require_text "'virtio-vga,edid=on,edid-fixed-native=on,'" "$LAUNCHER"
    require_text ". (Join-Path \$libraryRoot 'VMate.Display.ps1')" "$LAUNCHER"
    require_text "Test-VMateQemuHelpProperties -HelpOutput \$probeText" "$DISPLAY"
    require_text "'edid-fixed-native'" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
    require_text "'edid-managed-timing-version'" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
    require_text "'edid-managed-timing-version' = 1" \
        "$REPO_ROOT/deploy/windows/lib/VMate.ComponentRuntime.ps1"
    require_text "'-accel', 'tcg,thread=multi'" "$LAUNCHER"
    require_text '[System.IO.File]::Replace($temporary, $Path, $backup)' \
        "$REPO_ROOT/deploy/windows/lib/VMate.ProfileStore.ps1"
    require_text ". (Join-Path \$PSScriptRoot 'VMate.Manifest.ps1')" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Profile.ps1"
    require_text ". (Join-Path \$PSScriptRoot 'VMate.ProfileStore.ps1')" \
        "$REPO_ROOT/deploy/windows/lib/VMate.Profile.ps1"
    # 静态证明 commit 位于所有平台/SMBIOS/GPU/ROI 参数构造之后；运行时负测
    # 另行证明这些校验失败时 active profile 与备份均不变化。
    local prepare_line device_line roi_line commit_line
    prepare_line="$(grep -n 'Prepare-VMateHardwareProfile' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
    device_line="$(grep -n 'New-VMatePlatformDeviceArguments' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
    roi_line="$(grep -n 'Split-VMateRoi \$FbShmRoi' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
    commit_line="$(grep -n 'Commit-VMateHardwareProfile' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
    (( prepare_line < device_line && device_line < roi_line && roi_line < commit_line )) \
        || fail "profile transaction order is not prepare -> full argv -> commit"
}
test_dry_run_has_explicit_identity_and_no_side_effects() {
    local shell_bin="$1"
    local tmp out uuid
    tmp="$(mktemp -d)"
    prepare_vm_files "$tmp"
    out="$tmp/out.txt"
    run_launcher_dry "$shell_bin" "$tmp" >"$out"
    grep -Fx -- 'whpx,hyperv=off,kernel-irqchip=off' "$out" >/dev/null \
        || fail "default accelerator must disable Hyper-V surface"
    if grep -Fx -- 'tcg,thread=multi' "$out" >/dev/null; then
        fail "default launcher must not include TCG"
    fi
    grep -Fx -- 'host' "$out" >/dev/null || fail "WHPX CPU policy must be host"
    grep -Fx -- 'base=localtime,clock=host,driftfix=slew' "$out" >/dev/null \
        || fail "Windows guest RTC policy is missing"
    grep -F -- 'e1000e,id=nic0' "$out" | grep -F -- 'subsys=0xa01f' >/dev/null \
        || fail "Intel 82574L add-in subsystem is missing"
    grep -F -- 'mac=3C:FD:FE:' "$out" >/dev/null \
        || fail "Intel NIC OUI must match e1000e"
    python3 "$SCRIPT_DIR/component_argv_assert.py" "$COMPONENTS" "$out" \
        || fail "Windows dry-run 的 SSD/显示器目录投影不完整"
    grep -F -- 'intel-hda,id=hda,bus=pcie.0,addr=0x4,x-pci-vendor-id=0x8086' \
        "$out" >/dev/null || fail "manifest HDA controller BDF/identity is missing"
    grep -F -- 'hda-duplex,bus=hda.0,x-identity-compat=on' "$out" | \
        grep -F -- 'x-codec-id=0x10ec0887' | \
        grep -F -- 'x-codec-subsystem-id=0x104386c7' >/dev/null \
        || fail "protocol-only ALC887 identity is missing"
    grep -F -- 'pcie-root-port,id=rp1' "$out" | \
        grep -F -- 'bus=pcie.0,addr=0x1' | grep -F -- 'x-speed=5,x-width=2' | \
        grep -F -- 'x-pci-device-id=0xa338' >/dev/null \
        || fail "H310M-A M.2 link must be Gen2 x2"
    grep -F -- 'pcie-root-port,id=rp2' "$out" | \
        grep -F -- 'bus=pcie.0,addr=0x2' | grep -F -- 'x-pci-device-id=0xa339' \
        >/dev/null \
        || fail "rp2 must use the next Intel root-port ID"
    grep -F -- 'pcie-root-port,id=rp3' "$out" | \
        grep -F -- 'bus=pcie.0,addr=0x3' | grep -F -- 'x-pci-device-id=0xa33a' \
        >/dev/null \
        || fail "rp3 must use the third Intel root-port ID"
    grep -Fx -- 'qemu-xhci,id=xhci,bus=rp3' "$out" >/dev/null || fail "qemu-xhci behavior ID must not be overridden"
    grep -F -- 'usb-kbd,id=kbd0,bus=xhci.0,vendorid=0x045e,productid=0x0750' \
        "$out" >/dev/null || fail "Microsoft keyboard ID is missing"
    grep -F -- 'x-force-numlock-on=on' "$out" >/dev/null \
        || fail "QEMU guest NumLock force-on policy is missing"
    grep -F -- 'usb-mouse,bus=xhci.0,vendorid=0x045e,productid=0x00cb' \
        "$out" >/dev/null || fail "Microsoft mouse ID is missing"
    grep -F -- 'type=0,vendor=American Megatrends Inc.' "$out" >/dev/null \
        || fail "SMBIOS Type 0 is missing"
    grep -F -- 'type=3,manufacturer=ASUSTeK COMPUTER INC.' "$out" | \
        grep -F -- 'chassis-type=0x03' >/dev/null \
        || fail "SMBIOS desktop chassis type is missing"
    grep -F -- 'type=4,sock_pfx=LGA1151,manufacturer=Intel(R) Corporation' "$out" >/dev/null \
        || fail "SMBIOS Type 4 manifest CPU pairing is missing"
    if grep -F -- 'q35-pcihost.x-pci-mch-' "$out" >/dev/null; then
        fail "Windows 不得覆盖 OVMF 用于识别 Q35 machine 的 MCH identity"
    fi
    grep -Fx -- 'ICH9-LPC.x-pci-device-id=0xa303' "$out" >/dev/null \
        || fail "manifest LPC identity is missing"
    grep -Fx -- 'ICH9-SMB.x-pci-device-id=0xa323' "$out" >/dev/null \
        || fail "manifest SMBus identity is missing"
    grep -Fx -- 'ich9-ahci.x-pci-device-id=0xa352' "$out" >/dev/null \
        || fail "manifest AHCI identity is missing"
    uuid="$(awk '$0 == "-uuid" { getline; print; exit }' "$out")"
    [[ "$uuid" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] \
        || fail "invalid dry-run UUID: $uuid"
    [[ ! -e "$tmp/vm" ]] || fail "DryRun created VM/profile/OVMF state"
    run_launcher_dry "$shell_bin" "$tmp" -AllowTcgFallback >"$out"
    grep -Fx -- 'tcg,thread=multi' "$out" >/dev/null \
        || fail "explicit TCG fallback was not appended"
    grep -F -- 'model-id=Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' "$out" >/dev/null \
        || fail "TCG fallback must preserve the audited household CPU model"
    run_launcher_dry "$shell_bin" "$tmp" -ExposeHyperv >"$out"
    grep -Fx -- 'whpx,hyperv=auto' "$out" >/dev/null \
        || fail "explicit Hyper-V exposure was not applied"
    run_launcher_dry "$shell_bin" "$tmp" -GuestOs Linux >"$out"
    grep -Fx -- 'base=utc,clock=host,driftfix=slew' "$out" >/dev/null \
        || fail "Linux guest RTC policy must be UTC"
    # 用和 manifest 完全相同的宿主 CPU 名称进入严格路径，验证 Type 4 的
    # family/socket/电压/时钟等深层字段确实接线，而非只验证功能模式。
    USERPROFILE="$tmp/user" "$shell_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$LAUNCHER" -Qemu /bin/true -VmRoot "$tmp/vm" \
        -Disk "$tmp/disk.qcow2" -OvmfCode "$tmp/code.fd" \
        -OvmfVarsTemplate "$tmp/vars.fd" -HardwareManifest "$MANIFEST" \
        -ComponentManifest "$COMPONENTS" \
        -PlatformId "$PLATFORM_ID" -FbShmPath "$tmp/fb.sock" \
        -GpuGlProbe Unavailable \
        -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
        -DryRun >"$out"
    grep -F -- 'processor-family=0x00CE,voltage=140,external-clock=100' \
        "$out" >/dev/null || fail "strict SMBIOS Type 4 facts are missing"
    python3 "$SCRIPT_DIR/memory_argv_assert.py" \
        "$REPO_ROOT/deploy/hardware/memory.json" "$MANIFEST" "$PLATFORM_ID" \
        "$out" 8192
    # 同一根 DDR4-2400 *-CRC DIMM 在 H110/i5-6400T 上只能配置为 2133；
    # profile 和 argv 都必须保留额定 2400，不能把 SPD 一起“降级”为 2133。
    VMATE_TEST_PLATFORM_ID='intel-lga1151-i5-6400t-asus-h110m-a-m2' \
        run_launcher_dry "$shell_bin" "$tmp" >"$out"
    python3 "$SCRIPT_DIR/memory_argv_assert.py" \
        "$REPO_ROOT/deploy/hardware/memory.json" "$MANIFEST" \
        'intel-lga1151-i5-6400t-asus-h110m-a-m2' "$out" 8192
    rm -rf "$tmp"
}
test_profile_transaction_and_integrity() {
    local shell_bin="$1"
    "$shell_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$REPO_ROOT/deploy/scripts/tests/test_windows_profile_integrity.ps1" \
        -RepoRoot "$REPO_ROOT"
    "$shell_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$REPO_ROOT/deploy/scripts/tests/test_windows_manifest_integrity.ps1" \
        -RepoRoot "$REPO_ROOT"
}
test_manifest_status_and_fidelity_fail_closed() {
    local shell_bin="$1"
    local tmp bad_status bad_fidelity bad_bdf candidate
    tmp="$(mktemp -d)"
    bad_status="$tmp/status.json"
    bad_fidelity="$tmp/fidelity.json"
    bad_bdf="$tmp/bdf.json"

    # 仅改目录语义、不破坏 JSON 结构，证明 Windows 会和 Linux 一样拒绝：
    # enabled compatibility、伪称目标 PCH BDF 等价、实际 Q35 BDF 漂移。
    sed '0,/"status": "supported"/s//"status": "compatibility"/' \
        "$MANIFEST" >"$bad_status"
    sed 's/"target_pch_bdf_equivalent": false/"target_pch_bdf_equivalent": true/' \
        "$MANIFEST" >"$bad_fidelity"
    sed 's/"windows_hda": "00:04.0"/"windows_hda": "00:06.0"/' \
        "$MANIFEST" >"$bad_bdf"

    for candidate in "$bad_status" "$bad_fidelity" "$bad_bdf"; do
        if MANIFEST_LIB="$REPO_ROOT/deploy/windows/lib/VMate.Manifest.ps1" \
            MANIFEST_PATH="$candidate" \
            "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
                . $env:MANIFEST_LIB
                [void](Read-VMateHardwareManifest $env:MANIFEST_PATH)
            ' >"$tmp/reject.out" 2>&1; then
            fail "tampered Windows manifest unexpectedly passed: $candidate"
        fi
    done
    rm -rf "$tmp"
}
test_unsupported_guest_policies_fail_before_writes() {
    local shell_bin="$1"
    local tmp
    tmp="$(mktemp -d)"
    prepare_vm_files "$tmp"
    if USERPROFILE="$tmp/user" "$shell_bin" -NoLogo -NoProfile -NonInteractive \
        -File "$LAUNCHER" -Qemu /bin/true -VmRoot "$tmp/vm" \
        -Disk "$tmp/disk.qcow2" -OvmfCode "$tmp/code.fd" \
        -OvmfVarsTemplate "$tmp/vars.fd" -HardwareManifest "$MANIFEST" \
        -PlatformId "$PLATFORM_ID" -FbShmPath "$tmp/fb.sock" \
        -GpuGlProbe Unavailable \
        -DryRunHostCpuName 'Intel(R) Core(TM) i5-6500' -DryRun >"$tmp/out" 2>&1; then
        fail "WHPX host/manifest CPU mismatch unexpectedly passed strict mode"
    fi
    require_text '平台 CPU' "$tmp/out"
    if run_launcher_dry "$shell_bin" "$tmp" -GuestOs Windows11 \
        >"$tmp/out" 2>&1; then
        fail "Windows 11 unexpectedly bypassed TPM/Secure Boot gate"
    fi
    require_text 'TPM 2.0 + Secure Boot' "$tmp/out"
    [[ ! -e "$tmp/vm" ]] || fail "failed Windows 11 gate wrote VM state"
    if run_launcher_dry "$shell_bin" "$tmp" -RequireNestedVirtualization \
        >"$tmp/out" 2>&1; then
        fail "nested virtualization unexpectedly passed WHPX gate"
    fi
    require_text '不支持嵌套虚拟化' "$tmp/out"
    rm -rf "$tmp"
}
test_component_catalog_validation() {
    local shell_bin="$1"
    local tmp bad
    tmp="$(mktemp -d)"
    bad="$tmp/components-bad.json"
    sed 's/"schema_version": 1/"schema_version": 99/' "$COMPONENTS" >"$bad"
    REPO_ROOT="$REPO_ROOT" COMPONENT_PATH="$COMPONENTS" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            . "$env:REPO_ROOT/deploy/windows/lib/VMate.Common.ps1"
            . "$env:REPO_ROOT/deploy/windows/lib/VMate.Components.ps1"
            $components = Read-VMateComponentManifest $env:COMPONENT_PATH
            $storageIds = @($components.storage_items.id)
            $monitorIds = @($components.monitor_items.id)
            if ($storageIds.Count -ne 4 -or "samsung-970-pro-512gb" `
                    -notin $storageIds -or "intel-760p-512gb" `
                    -notin $storageIds -or "wd-pc-sn730-512gb" `
                    -notin $storageIds -or
                "kioxia-xg6-512gb" -notin $storageIds -or
                $monitorIds.Count -ne 4 -or
                "aoc-24b2xh" -notin $monitorIds -or
                "xiaomi-rmmnt238nf" -notin $monitorIds -or
                "lenovo-l24e-30" -notin $monitorIds -or
                $components.keyboard.id -ne "microsoft-wired-keyboard-600" -or
                $components.mouse.id -ne "microsoft-usb-optical-mouse") {
                throw "component selection mismatch"
            }
            $binding = New-VMateComponentProfileBinding $components
            $binding.catalog_revision = "appended-catalog"
            $binding.catalog_digest = "appended-catalog-digest"
            Assert-VMateComponentProfileBinding $binding $components
            $binding.storage_digest = "tampered"
            $rejected = $false
            try {
                Assert-VMateComponentProfileBinding $binding $components
            } catch {
                $rejected = $true
            }
            if (-not $rejected) {
                throw "tampered component binding unexpectedly passed"
            }
        '
    if REPO_ROOT="$REPO_ROOT" COMPONENT_PATH="$bad" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            . "$env:REPO_ROOT/deploy/windows/lib/VMate.Common.ps1"
            . "$env:REPO_ROOT/deploy/windows/lib/VMate.Components.ps1"
            [void](Read-VMateComponentManifest $env:COMPONENT_PATH)
        ' >"$tmp/out" 2>&1; then
        fail "unknown component schema unexpectedly passed"
    fi
    rm -rf "$tmp"
}

test_encoder_auto_fallback_dry_run() {
    local shell_bin="$1"
    local tmp out
    tmp="$(mktemp -d)"
    touch "$tmp/streamer.exe"
    out="$tmp/out.txt"
    "$shell_bin" -NoLogo -NoProfile -NonInteractive -File "$STREAMER" \
        -Streamer "$tmp/streamer.exe" -Output "$tmp/out.mp4" \
        -Encoder auto -EncoderProbe Nvenc -DryRun >"$out"
    grep -Fx -- 'h264_nvenc' "$out" >/dev/null \
        || fail "auto encoder did not select NVENC"
    grep -Fx -- 'p1' "$out" >/dev/null || fail "NVENC preset is not p1"

    "$shell_bin" -NoLogo -NoProfile -NonInteractive -File "$STREAMER" \
        -Streamer "$tmp/streamer.exe" -Output "$tmp/out.mp4" \
        -Encoder auto -EncoderProbe Software -DryRun >"$out"
    grep -Fx -- 'libx264' "$out" >/dev/null \
        || fail "auto encoder did not fall back to libx264"
    grep -Fx -- 'veryfast' "$out" >/dev/null \
        || fail "software preset is not veryfast"
    if "$shell_bin" -NoLogo -NoProfile -NonInteractive -File "$STREAMER" \
        -Streamer "$tmp/streamer.exe" -Output "$tmp/out.mp4" \
        -Encoder auto -EncoderProbe None -DryRun >"$out" 2>&1; then
        fail "empty encoder capability injection unexpectedly passed"
    fi
    rm -rf "$tmp"
}

test_nsis_rejects_stale_version() {
    require_text 'validate_installer_version(args.outfile, args.srcdir)' \
        "$REPO_ROOT/scripts/nsis.py"
    require_text 'subprocess.run(makensis, check=True)' "$REPO_ROOT/scripts/nsis.py"
    require_text 'stage_vmate_runtime(args.srcdir, install_root)' \
        "$REPO_ROOT/scripts/nsis.py"
    require_text '-DCONFIG_VMATE_RUNTIME=y' "$REPO_ROOT/scripts/nsis.py"
    local runtime_file
    for runtime_file in VMate.Memory VMate.MemoryBinding VMate.Manifest \
            VMate.Manifest.Validation VMate.BoardIdentity VMate.ComponentPolicy \
            VMate.StoragePolicy VMate.ComponentRuntime VMate.ComponentSelection \
            VMate.Display VMate.Gpu; do
        require_text "\"deploy/windows/lib/$runtime_file.ps1\"" \
            "$REPO_ROOT/scripts/nsis.py"
    done
    require_text '"deploy/hardware/memory.json"' "$REPO_ROOT/scripts/nsis.py"
    require_text '"deploy/hardware/board-vendors.json"' "$REPO_ROOT/scripts/nsis.py"
    require_text '"deploy/hardware/storage.json"' "$REPO_ROOT/scripts/nsis.py"
    require_text '"deploy/hardware/gpu-boards.json"' "$REPO_ROOT/scripts/nsis.py"
    require_text '"deploy/firmware/OVMF_CODE_4M_stealth.fd"' "$REPO_ROOT/scripts/nsis.py"
    require_text '"deploy/windows/lib/VMate.ProfileStore.ps1"' \
        "$REPO_ROOT/scripts/nsis.py"
    require_text 'Section "VMate Runtime (required)" SectionVMateRuntime' \
        "$REPO_ROOT/qemu.nsi"
    require_text 'File /r "${BINDIR}\deploy\windows\*.*"' "$REPO_ROOT/qemu.nsi"
    REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import importlib.util
import os
import re
import tempfile

root = os.environ["REPO_ROOT"]
spec = importlib.util.spec_from_file_location("qemu_nsis", os.path.join(root, "scripts/nsis.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.validate_installer_version("qemu-setup-11.0.2.exe", root)
try:
    module.validate_installer_version("qemu-setup-9.2.0.exe", root)
except RuntimeError:
    pass
else:
    raise SystemExit("stale installer version unexpectedly accepted")

# 扫描已打包入口/模块的 Join-Path dot-source，证明 runtime tuple 对传递依赖闭包。
runtime = set(module.VMATE_RUNTIME_FILES)
required = set()
for relative in runtime:
    if not relative.endswith(".ps1"):
        continue
    with open(os.path.join(root, relative), encoding="utf-8-sig") as source:
        for name in re.findall(
                r"Join-Path\s+\$(?:libraryRoot|PSScriptRoot)\s+'(VMate\.[^']+\.ps1)'",
                source.read()):
            required.add("deploy/windows/lib/" + name)
missing_dependencies = sorted(required - runtime)
if missing_dependencies:
    raise SystemExit("NSIS runtime misses dot-source closure: " +
                     ", ".join(missing_dependencies))

with tempfile.TemporaryDirectory() as staging:
    if not module.stage_vmate_runtime(root, staging):
        raise SystemExit("VMate runtime was not detected")
    for relative in module.VMATE_RUNTIME_FILES:
        if not os.path.isfile(os.path.join(staging, relative)):
            raise SystemExit("staged runtime is missing " + relative)

with tempfile.TemporaryDirectory() as upstream:
    if module.stage_vmate_runtime(upstream, upstream):
        raise SystemExit("plain upstream tree unexpectedly enabled VMate runtime")

with tempfile.TemporaryDirectory() as incomplete:
    marker = os.path.join(incomplete, "deploy", "windows", "start-vm.ps1")
    os.makedirs(os.path.dirname(marker))
    open(marker, "w", encoding="utf-8").close()
    try:
        module.stage_vmate_runtime(incomplete, incomplete)
    except RuntimeError:
        pass
    else:
        raise SystemExit("incomplete VMate runtime unexpectedly passed")
PY
}

test_optional_nsis_runtime_syntax() (
    local nsis tmp output
    nsis="$(command -v makensis || true)"
    if [[ -z "$nsis" ]]; then
        echo 'SKIP: makensis not found; VMate Runtime NSIS generation skipped'
        return
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/keymaps" "$tmp/share"
    touch "$tmp/keymaps/en-us" "$tmp/share/placeholder" \
        "$tmp/qemu-img.exe" "$tmp/qemu-io.exe" \
        "$tmp/qemu-fb-shm-stream.exe" "$tmp/qemu-system-x86_64.exe" \
        "$tmp/system-mui-text.nsh"
    SRC_ROOT="$REPO_ROOT" STAGE_ROOT="$tmp" python3 - <<'PY'
import importlib.util
import os
root = os.environ["SRC_ROOT"]
staging = os.environ["STAGE_ROOT"]
spec = importlib.util.spec_from_file_location("qemu_nsis",
    os.path.join(root, "scripts/nsis.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.stage_vmate_runtime(root, staging)
module.validate_vmate_runtime_binaries(staging)
with open(os.path.join(staging, "system-emulations.nsh"), "w") as nsh, \
        open(os.path.join(staging, "system-mui-text.nsh"), "w") as mui:
    module.write_system_emulation_sections(
        [os.path.join(staging, "qemu-system-x86_64.exe")], nsh, mui, True)
PY
    output="$($nsis -V3 -NOCD -DW64 -DCONFIG_VMATE_RUNTIME=y \
        -DSRCDIR="$REPO_ROOT" -DBINDIR="$tmp" \
        -DOUTFILE="$tmp/vmate-test.exe" "$REPO_ROOT/qemu.nsi" 2>&1)"
    [[ -s "$tmp/vmate-test.exe" ]] || fail "makensis did not generate installer"
    if grep -iF -- 'warning' <<<"$output" >/dev/null; then
        fail "makensis emitted warning: $output"
    fi
)

test_windows_powershell_files_have_bom
test_static_policy_markers
shell_bin="$(pwsh_bin)"
if [[ -n "$shell_bin" ]]; then
    test_dry_run_has_explicit_identity_and_no_side_effects "$shell_bin"
    test_profile_transaction_and_integrity "$shell_bin"
    test_manifest_status_and_fidelity_fail_closed "$shell_bin"
    test_unsupported_guest_policies_fail_before_writes "$shell_bin"
    test_component_catalog_validation "$shell_bin"
    test_encoder_auto_fallback_dry_run "$shell_bin"
else
    echo 'SKIP: PowerShell not found; DryRun/profile/encoder tests skipped'
fi
test_nsis_rejects_stale_version
test_optional_nsis_runtime_syntax
echo 'OK: Windows platform/profile/preflight static checks passed'
