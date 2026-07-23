#!/usr/bin/env bash
# Windows QEMU 运行时 backend/object 与 ICH9 patched 属性预检回归。
#
# 动态测试用无副作用 fake QEMU 驱动纯 PowerShell 函数，不读取 Windows
# hypervisor/optional-feature，也不创建 VM 身份、NVRAM 或网络状态。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PREFLIGHT="$REPO_ROOT/deploy/windows/lib/VMate.Preflight.ps1"
DISPLAY="$REPO_ROOT/deploy/windows/lib/VMate.Display.ps1"
LAUNCHER="$REPO_ROOT/deploy/windows/start-vm.ps1"

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

test_static_contract() {
    local device property

    require_text "Assert-VMateQemuRuntimeCapabilities -Qemu \$Qemu" "$PREFLIGHT"
    require_text "-RequireFbShm (-not \$NoFbShm.IsPresent)" "$LAUNCHER"
    require_text "-RequireSdl (-not (\$Headless.IsPresent -or \$NoSdl.IsPresent))" \
        "$LAUNCHER"
    require_text "-RequireVnc \$Headless.IsPresent" "$LAUNCHER"
    require_text "@('-netdev', 'help')" "$PREFLIGHT"
    require_text "@('-object', 'fb-shm,help')" "$PREFLIGHT"
    require_text "@('-display', 'help')" "$PREFLIGHT"
    require_text "@('-vnc', 'help')" "$PREFLIGHT"

    for device in ICH9-LPC ICH9-SMB ich9-ahci; do
        require_text "'$device' = \$chipsetIdentityProperties" "$PREFLIGHT"
    done
    for property in \
        x-pci-vendor-id x-pci-device-id x-pci-revision \
        x-pci-sub-vendor-id x-pci-sub-device-id; do
        require_text "'$property'" "$PREFLIGHT"
    done
    require_text "'x-speed', 'x-width'" "$PREFLIGHT"
    require_text 'function Get-VMateMonitorEdidCapabilityProperties' "$PREFLIGHT"
    require_text "'edid-managed-timing-version'" "$PREFLIGHT"
    require_text 'function Test-VMateQemuHelpProperties' "$PREFLIGHT"
    require_text "'virtio-vga' = @(\$monitorEdidProperties" "$PREFLIGHT"
    require_text ". (Join-Path \$libraryRoot 'VMate.Display.ps1')" "$LAUNCHER"
    require_text "Test-VMateQemuHelpProperties -HelpOutput \$probeText" "$DISPLAY"
    require_text "-RequireBlob \$GpuZeroCopy.IsPresent" "$LAUNCHER"
    require_text 'function Test-VMateGpuHostmem' "$DISPLAY"
    require_text "'share\edk2-x86_64-code.fd'" "$LAUNCHER"
    require_text "'share\edk2-i386-vars.fd'" "$LAUNCHER"
}

write_fake_qemu() {
    local target="$1"

    # 该 fake 只实现预检查询协议。VMATE_FAKE_MISSING 采用 capability:item，
    # 使测试可以逐项证明缺失能力确实 fail-fast。
    cat >"$target" <<'FAKE_QEMU'
#!/usr/bin/env bash
set -euo pipefail
printf "%s\n" "$*" >>"${VMATE_FAKE_LOG:?}"
missing="${VMATE_FAKE_MISSING:-}"
if [[ "$1" == "-netdev" && "$2" == "help" ]]; then
    echo "Available netdev backend types:"
    [[ "$missing" == "netdev:user" ]] || echo "user"
elif [[ "$1" == "-object" && "$2" == "fb-shm,help" ]]; then
    echo "fb-shm options:"
    for item in path rate x y width height; do
        [[ "$missing" == "fb-shm:$item" ]] || echo "$item=<value>"
    done
elif [[ "$1" == "-display" && "$2" == "help" ]]; then
    echo "Available display backend types:"
    [[ "$missing" == "display:sdl" ]] || echo "sdl"
elif [[ "$1" == "-vnc" && "$2" == "help" ]]; then
    [[ "$missing" == "vnc:server" ]] || echo "vnc options:"
    exit 1
elif [[ "$1" == "-device" && "$2" == *,help ]]; then
    device="${2%%,*}"
    echo "$device options:"
    for item in x-pci-vendor-id x-pci-device-id x-pci-revision \
        x-pci-sub-vendor-id x-pci-sub-device-id x-speed x-width \
        x-identity-compat x-codec-id x-codec-revision \
        x-codec-subsystem-id subsys_ven subsys x-identity-profile \
        model-number firmware-rev subsys-vendor-id subsys-id subnqn \
        vendorid productid manufacturer product x-force-numlock-on \
        edid-fixed-native edid-managed-timing-version \
        edid-vendor edid-name edid-serial \
        edid-binary-serial edid-revision edid-width-mm \
        edid-height-mm edid-product-id edid-manufacture-week \
        edid-manufacture-year edid-video-input edid-min-vfreq-hz \
        edid-max-vfreq-hz edid-min-hfreq-khz edid-max-hfreq-khz \
        edid-max-pixel-clock-mhz edid-secondary-xres edid-secondary-yres \
        edid-secondary-refresh-rate xres yres xmax ymax blob hostmem; do
        key="device:$device:$item"
        if [[ "$missing" == "$key" ]]; then
            echo "not-$item=<deceptive-value>"
        else
            echo "$item=<value>"
        fi
    done
else
    echo "unsupported fake QEMU probe: $*" >&2
    exit 2
fi
FAKE_QEMU
    chmod +x "$target"
}

test_dynamic_capabilities() {
    local shell_bin tmp fake log

    shell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$shell_bin" ]]; then
        echo "SKIP: PowerShell not found; static preflight contract passed"
        return
    fi

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    fake="$tmp/qemu-system-x86_64"
    log="$tmp/probes.log"
    : >"$log"
    write_fake_qemu "$fake"

    # shellcheck disable=SC2016
    VMATE_PREFLIGHT="$PREFLIGHT" VMATE_DISPLAY="$DISPLAY" \
        VMATE_FAKE_QEMU="$fake" \
        VMATE_FAKE_LOG="$log" "$shell_bin" -NoLogo -NoProfile -NonInteractive \
        -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_PREFLIGHT
            . $env:VMATE_DISPLAY

            function Assert-ProbeFails {
                param([scriptblock]$Action, [string]$Expected)
                try {
                    & $Action
                } catch {
                    if ($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
                        throw "错误未包含预期文本 [$Expected]：$($_.Exception.Message)"
                    }
                    return
                }
                throw "缺失能力未被拒绝：$Expected"
            }

            $qemu = $env:VMATE_FAKE_QEMU
            Assert-VMateQemuRuntimeCapabilities -Qemu $qemu `
                -RequireFbShm $true -RequireSdl $true -RequireVnc $true
            Assert-VMateQemuDeviceCapabilities -Qemu $qemu

            $env:VMATE_FAKE_MISSING = "netdev:user"
            Assert-ProbeFails {
                Assert-VMateQemuRuntimeCapabilities -Qemu $qemu `
                    -RequireFbShm $false -RequireSdl $false -RequireVnc $false
            } "user netdev"
            $env:VMATE_FAKE_MISSING = "fb-shm:rate"
            Assert-ProbeFails {
                Assert-VMateQemuRuntimeCapabilities -Qemu $qemu `
                    -RequireFbShm $true -RequireSdl $false -RequireVnc $false
            } "rate"
            $env:VMATE_FAKE_MISSING = "display:sdl"
            Assert-ProbeFails {
                Assert-VMateQemuRuntimeCapabilities -Qemu $qemu `
                    -RequireFbShm $false -RequireSdl $true -RequireVnc $false
            } "SDL"
            $env:VMATE_FAKE_MISSING = "vnc:server"
            Assert-ProbeFails {
                Assert-VMateQemuRuntimeCapabilities -Qemu $qemu `
                    -RequireFbShm $false -RequireSdl $false -RequireVnc $true
            } "VNC"
            $env:VMATE_FAKE_MISSING =
                "device:ICH9-SMB:x-pci-sub-device-id"
            Assert-ProbeFails {
                Assert-VMateQemuDeviceCapabilities -Qemu $qemu
            } "ICH9-SMB"
            $env:VMATE_FAKE_MISSING = "device:pcie-root-port:x-width"
            Assert-ProbeFails {
                Assert-VMateQemuDeviceCapabilities -Qemu $qemu
            } "pcie-root-port"
            $env:VMATE_FAKE_MISSING =
                "device:virtio-vga:edid-max-pixel-clock-mhz"
            Assert-ProbeFails {
                Assert-VMateQemuDeviceCapabilities -Qemu $qemu
            } "virtio-vga"
            $env:VMATE_FAKE_MISSING =
                "device:virtio-vga:edid-managed-timing-version"
            Assert-ProbeFails {
                Assert-VMateQemuDeviceCapabilities -Qemu $qemu
            } "virtio-vga"

            $env:VMATE_FAKE_MISSING = ""
            if (-not (Test-VMateVirtioGpuGl -Executable $qemu `
                    -RequireBlob $true)) {
                throw "完整 GL 能力被错误拒绝"
            }
            $env:VMATE_FAKE_MISSING =
                "device:virtio-vga-gl:edid-manufacture-year"
            if (Test-VMateVirtioGpuGl -Executable $qemu -RequireBlob $true) {
                throw "缺失完整 EDID 的 GL 设备未回退"
            }
            $env:VMATE_FAKE_MISSING = "device:virtio-vga-gl:blob"
            if (Test-VMateVirtioGpuGl -Executable $qemu -RequireBlob $true) {
                throw "零拷贝 GL 缺少 blob 时未回退"
            }
            if (-not (Test-VMateVirtioGpuGl -Executable $qemu `
                    -RequireBlob $false)) {
                throw "禁用零拷贝时不应要求 blob/hostmem"
            }

            foreach ($value in @("256M", "262144K", "268435456", "1G", "8G")) {
                if (-not (Test-VMateGpuHostmem -Value $value)) {
                    throw "合法 hostmem 被拒绝：$value"
                }
            }
            foreach ($value in @("255M", "300M", "9G", "1T", "268435455")) {
                if (Test-VMateGpuHostmem -Value $value) {
                    throw "非法 hostmem 被接受：$value"
                }
            }

            $env:VMATE_FAKE_MISSING = ""
            [System.IO.File]::WriteAllText($env:VMATE_FAKE_LOG, "")
            Assert-VMateQemuRuntimeCapabilities -Qemu $qemu `
                -RequireFbShm $false -RequireSdl $false -RequireVnc $false
        '

    grep -Fx -- '-netdev help' "$log" >/dev/null \
        || fail "user netdev probe did not run"
    if grep -E -- '^-object |^-display |^-vnc ' "$log" >/dev/null; then
        fail "disabled optional runtime capabilities were still probed"
    fi
}

test_firmware_selection() {
    local shell_bin tmp qemu_dir stock vars legacy_stock legacy_vars
    local stealth iso_out disk_out missing_out
    local -a launcher_args

    shell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$shell_bin" ]]; then
        echo "SKIP: PowerShell not found; ISO firmware DryRun not executed"
        return
    fi
    [[ -f "$REPO_ROOT/deploy/firmware/OVMF_CODE_4M_stealth.fd" ]] \
        || fail "repository stealth OVMF fixture is missing"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    qemu_dir="$tmp/qemu"
    stock="$qemu_dir/share/edk2-x86_64-code.fd"
    vars="$qemu_dir/share/edk2-i386-vars.fd"
    legacy_stock="$qemu_dir/share/qemu/edk2-x86_64-code.fd"
    legacy_vars="$qemu_dir/share/qemu/edk2-i386-vars.fd"
    stealth="$(realpath "$REPO_ROOT/deploy/firmware/OVMF_CODE_4M_stealth.fd")"
    iso_out="$tmp/iso-argv.txt"
    disk_out="$tmp/disk-argv.txt"
    mkdir -p "$qemu_dir/share/qemu" "$tmp/user"
    touch "$qemu_dir/qemu-system-x86_64.exe" "$tmp/disk.qcow2" \
        "$tmp/install.iso"
    printf 'stock-code' >"$stock"
    printf 'stock-vars' >"$vars"
    printf 'legacy-code' >"$legacy_stock"
    printf 'legacy-vars' >"$legacy_vars"

    launcher_args=(
        -NoLogo -NoProfile -NonInteractive
        -File "$LAUNCHER" -Qemu "$qemu_dir/qemu-system-x86_64.exe" \
        -VmRoot "$tmp/vm" -Disk "$tmp/disk.qcow2" \
        -HardwareManifest "$REPO_ROOT/deploy/hardware/platforms.json" \
        -ComponentManifest "$REPO_ROOT/deploy/hardware/components.json" \
        -PlatformId intel-lga1151-i3-9100f-asus-prime-h310m-a-r2 \
        -FbShmPath "$tmp/fb.sock" -GpuGlProbe Unavailable \
        -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
        -DryRun
    )
    USERPROFILE="$tmp/user" "$shell_bin" "${launcher_args[@]}" \
        -Iso "$tmp/install.iso" >"$iso_out"

    grep -Fx -- "if=pflash,format=raw,readonly=on,file=$stock" \
        "$iso_out" >/dev/null \
        || fail "ISO DryRun did not select QEMU distribution stock OVMF"
    if grep -F -- 'OVMF_CODE_4M_stealth.fd' "$iso_out" >/dev/null; then
        fail "ISO DryRun selected repository stealth OVMF"
    fi

    USERPROFILE="$tmp/user" "$shell_bin" "${launcher_args[@]}" >"$disk_out"
    grep -Fx -- "if=pflash,format=raw,readonly=on,file=$stealth" \
        "$disk_out" >/dev/null \
        || fail "disk DryRun did not prefer repository stealth OVMF"
    if grep -Fx -- "if=pflash,format=raw,readonly=on,file=$stock" \
        "$disk_out" >/dev/null; then
        fail "disk DryRun selected stock OVMF while stealth OVMF exists"
    fi

    missing_out="$tmp/missing-iso.txt"
    if USERPROFILE="$tmp/user" "$shell_bin" "${launcher_args[@]}" \
        -Iso "$tmp/not-found.iso" >"$missing_out" 2>&1; then
        fail "missing installation ISO was accepted"
    fi
    grep -F -- '安装 ISO 不是可读文件' "$missing_out" >/dev/null \
        || fail "missing ISO rejection was not diagnostic"
    [[ ! -e "$tmp/vm" ]] \
        || fail "missing ISO validation created VM/profile state"
}

test_static_contract
test_dynamic_capabilities
test_firmware_selection
echo "OK: Windows QEMU preflight capability checks passed"
