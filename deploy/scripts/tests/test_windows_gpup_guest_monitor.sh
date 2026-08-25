#!/usr/bin/env bash
# P-11 Guest Monitor：离线注入、无凭据 LocalSystem 启动和单 Monitor 门禁。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$script_dir/../../.." && pwd)
gpup="$repo/deploy/windows/gpup"
source_file="$gpup/native/VMateGuestMonitorProvisioner.c"
binary="$gpup/native/bin/VMateGuestMonitorProvisioner.exe"
provisioner="$gpup/VMate.GpuP.GuestMonitor.ps1"
validation="$gpup/VMate.GpuP.GuestMonitorValidation.ps1"
guest_validation="$gpup/VMate.GpuP.GuestValidation.ps1"
guest_entry="$gpup/Test-VMateGpuPGuest.ps1"
driver_store="$gpup/VMate.GpuP.DriverStore.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

contains() {
    grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}

test_sources_and_binary_are_bounded() {
    local file signature lines
    for file in "$provisioner" "$validation"; do
        [[ -f "$file" ]] || fail "missing PowerShell module: $file"
        signature=$(od -An -tx1 -N3 "$file" | tr -d ' \n')
        [[ "$signature" == efbbbf ]] || fail "UTF-8 BOM missing: $file"
        lines=$(wc -l <"$file")
        (( lines <= 500 )) || fail "$file exceeds 500 lines: $lines"
    done
    [[ -f "$source_file" ]] || fail "missing native source"
    [[ -f "$binary" ]] || fail "missing native binary"
    (( $(wc -l <"$source_file") <= 500 )) || fail "native source exceeds 500 lines"
    file "$binary" | grep -F 'PE32+ executable' >/dev/null ||
        fail 'Guest Monitor provisioner is not a Windows x64 PE'
}

test_native_build_is_reproducible_and_driverless() {
    local compiler temporary committed_hash rebuilt_hash
    compiler=${VMATE_MINGW_CC:-x86_64-w64-mingw32-gcc}
    command -v "$compiler" >/dev/null || return 0
    temporary=$(mktemp --suffix=.exe)
    trap 'rm -f -- "$temporary"' RETURN
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -municode \
        -Wl,--no-insert-timestamp -o "$temporary" "$source_file" \
        -lsetupapi -lcfgmgr32 -ladvapi32
    committed_hash=$(sha256sum "$binary" | awk '{print $1}')
    rebuilt_hash=$(sha256sum "$temporary" | awk '{print $1}')
    [[ "$rebuilt_hash" == "$committed_hash" ]] ||
        fail 'Guest Monitor provisioner binary is stale'
    contains 'SetupDiCreateDeviceInfoW' "$source_file"
    contains 'DIF_REGISTERDEVICE' "$source_file"
    contains 'ROOT\\VMATEP11MONITOR\\' "$source_file"
    contains 'VMate P-11 Virtual Console Monitor' "$source_file"
    contains 'RegisterServiceCtrlHandlerExW' "$source_file"
    if grep -E 'UpdateDriverForPlugAndPlayDevices|monitor\.inf|CreateService' \
            "$source_file" >/dev/null; then
        fail 'Guest provisioner must not install a guest driver or create services'
    fi
    rm -f -- "$temporary"
    trap - RETURN
}

test_offline_service_contract_is_fail_closed() {
    contains 'VMateP11GuestProvisioner' "$provisioner"
    contains 'VMateGuestMonitorProvisioner.exe' "$provisioner"
    contains 'Invoke-VMateGpuPOfflineSystemHive' "$provisioner"
    contains '& $reg load $nativeName $SystemHivePath' "$provisioner"
    contains '& $reg unload $nativeName' "$provisioner"
    contains "Start = @('DWord', 2)" "$provisioner"
    contains "Type = @('DWord', 0x10)" "$provisioner"
    contains "ObjectName = @('String', 'LocalSystem')" "$provisioner"
    contains 'GuestTestSigningRequired = $false' "$provisioner"
    contains 'GuestKernelDriverInstalled = $false' "$provisioner"
    contains "VMate.GpuP.GuestMonitor.ps1" "$driver_store"
    contains 'Install-VMateGpuPGuestMonitorProvisioner' "$driver_store"
    if grep -Ei 'bcdedit.*testsigning|nointegritychecks|pnputil|devcon|Add-WindowsDriver' \
            "$provisioner" >/dev/null; then
        fail 'offline Monitor provisioning changes guest CI or installs a driver'
    fi
}

test_validation_requires_exactly_one_healthy_monitor() {
    contains 'function Assert-VMateGpuPGuestMonitor' "$validation"
    contains '^ROOT\\VMATEP11MONITOR\\[0-9A-F]+$' "$validation"
    contains '[switch]$RequireMonitor' "$guest_validation"
    contains 'Assert-VMateGpuPGuestMonitor' "$guest_validation"
    contains '[switch]$RequireMonitor' "$guest_entry"

    local shell_bin
    shell_bin=$(command -v pwsh || command -v powershell || true)
    [[ -n "$shell_bin" ]] || return 0
    VMATE_MONITOR_VALIDATION="$validation" "$shell_bin" -NoLogo -NoProfile \
        -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_MONITOR_VALIDATION
        $script:items = @([pscustomobject]@{
            PNPClass = "Monitor"
            Name = "VMate P-11 Virtual Console Monitor"
            PNPDeviceID = "ROOT\VMATEP11MONITOR\0000"
            Status = "OK"; Present = $true
            ConfigManagerErrorCode = 0; Service = $null
        })
        function Get-CimInstance { return @($script:items) }
        $result = Assert-VMateGpuPGuestMonitor
        if ($result.InstanceId -cne "ROOT\VMATEP11MONITOR\0000") {
            throw "healthy Monitor was rejected"
        }
        $script:items += [pscustomobject]@{
            PNPClass = "Monitor"; Name = "Unexpected Monitor"
            PNPDeviceID = "ROOT\OTHER\0000"; Status = "OK"
            Present = $true; ConfigManagerErrorCode = 0; Service = $null
        }
        try {
            [void](Assert-VMateGpuPGuestMonitor)
            throw "multiple Monitor devices were accepted"
        } catch {
            if ($_.Exception.Message -eq "multiple Monitor devices were accepted") {
                throw
            }
        }
        exit 0
        '
}

test_sources_and_binary_are_bounded
test_native_build_is_reproducible_and_driverless
test_offline_service_contract_is_fail_closed
test_validation_requires_exactly_one_healthy_monitor

echo 'OK: Windows GPU-P Guest Monitor provisioning checks passed'
