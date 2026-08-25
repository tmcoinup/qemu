#!/usr/bin/env bash
# GPU-P 官方宿主驱动发现、路径边界和离线发布事务回归。
# Linux CI 执行静态门禁；存在 PowerShell 时再执行无 Hyper-V 副作用的纯函数测试。
# shellcheck disable=SC2016 # PowerShell 合同字符串必须保持字面量 $。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DISCOVERY="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.DriverDiscovery.ps1"
STORE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.DriverStore.ps1"
WINDOWS_IMAGE="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.WindowsImage.ps1"
GUEST_MONITOR="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.GuestMonitor.ps1"

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

reject_regex() {
    local pattern="$1"
    local file="$2"
    if grep -Ei -- "$pattern" "$file" >/dev/null; then
        fail "unexpected pattern '$pattern' in $file"
    fi
}

test_files_are_bounded_ps51_modules() {
    local file signature lines
    for file in "$DISCOVERY" "$STORE" "$WINDOWS_IMAGE" "$GUEST_MONITOR"; do
        [[ -f "$file" ]] || fail "missing module: $file"
        signature="$(od -An -tx1 -N3 "$file" | tr -d ' \n')"
        [[ "$signature" == "efbbbf" ]] \
            || fail "Windows PowerShell 5.1 UTF-8 BOM missing: $file"
        lines="$(wc -l <"$file")"
        (( lines <= 500 )) || fail "$file exceeds 500 lines: $lines"
        require_text '#Requires -Version 5.1' "$file"
    done
    require_text ". (Join-Path \$PSScriptRoot 'VMate.GpuP.DriverDiscovery.ps1')" \
        "$STORE"
    require_text ". (Join-Path \$PSScriptRoot 'VMate.GpuP.WindowsImage.ps1')" \
        "$STORE"
    require_text ". (Join-Path \$PSScriptRoot 'VMate.GpuP.GuestMonitor.ps1')" \
        "$STORE"
}

test_discovery_is_bound_to_real_signed_vendor_package() {
    require_text 'Get-VMateGpuPHostPartitionableGpu' "$DISCOVERY"
    require_text 'ConvertTo-VMateGpuPInstanceId' "$DISCOVERY"
    require_text 'Win32_PnPEntity' "$DISCOVERY"
    require_text 'Win32_PNPSignedDriver' "$DISCOVERY"
    require_text 'Win32_SystemDriver' "$DISCOVERY"
    require_text 'Win32_PNPSignedDriverCIMDataFile' "$DISCOVERY"
    require_text '-ClassName Win32_PNPSignedDriverCIMDataFile' "$DISCOVERY"
    require_text '[string]$driver.CimClass.CimClassName' "$DISCOVERY"
    require_text '[string]$file.CimClass.CimClassName' "$DISCOVERY"
    require_text '[string]$Selection.InstanceId' "$DISCOVERY"
    require_text "('INF\\' + [string]\$Selection.SignedDriver.InfName)" \
        "$DISCOVERY"
    require_text '$candidate.Equals($publishedInf' "$DISCOVERY"
    require_text 'IsSigned -ne $true' "$DISCOVERY"
    require_text 'DriverProviderName' "$DISCOVERY"
    require_text "Vendor = 'NVIDIA'; VendorId = '10DE'" "$DISCOVERY"
    require_text "Vendor = 'AMD'; VendorId = '1002'" "$DISCOVERY"
    require_text "Providers = @('NVIDIA', 'NVIDIA Corporation')" "$DISCOVERY"
    require_text "'Advanced Micro Devices, Inc.'" "$DISCOVERY"
    require_text '[string]$_.DeviceID -ieq $selected.InstanceId' "$DISCOVERY"
    require_text '[string]$_.Name -ieq $serviceName' "$DISCOVERY"

    # 禁止型号、DEV ID、驱动版本及厂商服务名硬编码；全部来自最终 InstanceId/CIM。
    reject_regex '4060|1060|DEV_[0-9A-F]{4}|nvlddmkm|amdkmdag|amdwddmg' \
        "$DISCOVERY"
}

test_copy_plan_has_fail_closed_path_mapping() {
    require_text '[System.IO.Path]::GetFullPath' "$DISCOVERY"
    require_text 'Test-VMateGpuPPathWithinRoot' "$DISCOVERY"
    require_text '[System.IO.FileAttributes]::ReparsePoint' "$DISCOVERY"
    require_text "@('System32', 'HostDriverStore')" "$DISCOVERY"
    require_text "Equals('SysWOW64'" "$DISCOVERY"
    require_text '不属于 DriverStore/System32/SysWOW64' "$DISCOVERY"
    require_text 'Get-FileHash -LiteralPath $source -Algorithm SHA256' "$DISCOVERY"
    require_text '官方驱动关联未包含 DriverStore 文件' "$DISCOVERY"
}

test_offline_publish_is_transactional_and_idempotent() {
    local before_line copy_line after_line
    require_text "[string]\$vm.State -cne 'Off'" "$STORE"
    require_text 'Get-VMHardDiskDrive' "$STORE"
    require_text 'Get-VHD -Path $path' "$STORE"
    require_text 'Mount-VHD -Path $resolvedVhd -NoDriveLetter' "$STORE"
    require_text '-ReadOnly:$DryRun' "$STORE"
    require_text 'finally {' "$STORE"
    require_text 'Dismount-VHD -Path $resolvedVhd' "$STORE"
    require_text 'VHD 必须包含唯一且无 reparse 的 Windows 卷' "$STORE"
    require_text 'Assert-VMateGpuPGuestWindowsImage' "$STORE"
    require_text 'Install-VMateGpuPGuestMonitorProvisioner' "$STORE"
    require_text "PeMachine = \$pe.Machine" "$WINDOWS_IMAGE"
    require_text "if (\$pe.Architecture -cne 'x64')" "$WINDOWS_IMAGE"
    require_text "BuildCompatibilityPolicy = 'Windows builds may differ" \
        "$WINDOWS_IMAGE"
    require_text "Status = 'DryRun'" "$STORE"
    require_text "Status = 'UpToDate'" "$STORE"
    require_text "Ensure-VMateGpuPDirectory \$auditRoot '.staging'" "$STORE"
    require_text '[System.IO.File]::Replace(' "$STORE"
    require_text '$temporary, $Destination, $replaceBackup)' "$STORE"
    require_text "'.replace-backup'" "$STORE"
    require_text '[IO.Directory]::Move($stage, $packagePath)' "$STORE"
    require_text 'Remove-Item -LiteralPath $temporary -Force' "$STORE"
    require_text 'manifest.before.json' "$STORE"
    require_text 'manifest.after.json' "$STORE"
    require_text 'PackageFingerprint' "$STORE"
    require_text 'VendorId = [string]$Selection.Vendor.VendorId' "$STORE"
    require_text 'GuestWindowsRelativePath' "$STORE"
    require_text 'DestinationSHA256' "$STORE"
    require_text '$previous' "$STORE"
    require_text 'for ($index = $published.Count - 1' "$STORE"
    require_text 'Remove-Item -LiteralPath $stage -Recurse' "$STORE"
    before_line="$(grep -nF "Join-Path \$stage 'manifest.before.json'" "$STORE" | head -n1 | cut -d: -f1)"
    copy_line="$(grep -nF 'Copy-Item -LiteralPath $entry.SourcePath' "$STORE" | head -n1 | cut -d: -f1)"
    after_line="$(grep -nF "Join-Path \$stage 'manifest.after.json'" "$STORE" | head -n1 | cut -d: -f1)"
    (( before_line < copy_line && copy_line < after_line )) \
        || fail 'manifest/copy order is not before -> staged copy -> after'

    # 驱动同步不得隐式改变 GPU-P adapter 或厂商包身份。
    reject_regex '(Add|Remove|Set)-VMGpuPartitionAdapter|pnputil|dism\.exe|devcon' \
        "$STORE"
}

test_pure_functions_when_powershell_exists() {
    local shell_bin tmp
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    [[ -n "$shell_bin" ]] || return 0
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/Windows/System32/DriverStore/FileRepository/vendor.inf_amd64_x" \
        "$tmp/Windows/System32/drivers" "$tmp/Windows/SysWOW64" \
        "$tmp/Windows/INF"
    printf 'package' >"$tmp/Windows/System32/DriverStore/FileRepository/vendor.inf_amd64_x/core.bin"
    printf 'service' >"$tmp/Windows/System32/drivers/vendor.sys"
    printf 'wow' >"$tmp/Windows/SysWOW64/vendor.dll"
    printf 'reject' >"$tmp/Windows/INF/vendor.inf"

    VMATE_DISCOVERY="$DISCOVERY" VMATE_TEST_WINDOWS="$tmp/Windows" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_DISCOVERY
            $root = $env:VMATE_TEST_WINDOWS
            $store = Join-Path $root "System32/DriverStore/FileRepository/vendor.inf_amd64_x/core.bin"
            $driver = Join-Path $root "System32/drivers/vendor.sys"
            $wow = Join-Path $root "SysWOW64/vendor.dll"
            $plan = @(New-VMateGpuPDriverCopyPlan -SystemRoot $root `
                -SourcePaths @($store, $driver, $wow))
            if ($plan.Count -ne 3) { throw "copy plan count mismatch" }
            if ($plan.GuestWindowsRelativePath -notcontains `
                "System32\HostDriverStore\FileRepository\vendor.inf_amd64_x\core.bin") {
                throw "DriverStore mapping mismatch"
            }
            if ($plan.GuestWindowsRelativePath -notcontains `
                "System32\drivers\vendor.sys") { throw "System32 mapping mismatch" }
            if ($plan.GuestWindowsRelativePath -notcontains `
                "SysWOW64\vendor.dll") { throw "SysWOW64 mapping mismatch" }
            $nvidia = Get-VMateGpuPVendor "PCI\VEN_10DE&DEV_0001\INSTANCE"
            $amd = Get-VMateGpuPVendor "PCI\VEN_1002&DEV_0001\INSTANCE"
            if ($nvidia.Vendor -cne "NVIDIA" -or $amd.Vendor -cne "AMD") {
                throw "vendor mapping mismatch"
            }
            if (Test-VMateGpuPProvider "NVIDIA" $amd) {
                throw "cross-vendor provider was accepted"
            }
            $parsed = ConvertTo-VMateGpuPInstanceId `
                "\\?\PCI#VEN_10DE&DEV_0001#INSTANCE#{00000000-0000-0000-0000-000000000000}"
            if ($parsed -cne "PCI\VEN_10DE&DEV_0001\INSTANCE") {
                throw "partitionable InstanceId parsing mismatch: $parsed"
            }
            try {
                [void](ConvertTo-VMateGpuPGuestRelativePath `
                    (Join-Path $root "INF/vendor.inf") $root)
                throw "unsupported SystemRoot path was accepted"
            } catch {
                if ($_.Exception.Message -eq "unsupported SystemRoot path was accepted") { throw }
            }
            # PowerShell 7 on Linux can preserve a handled error as process status 1;
            # all unexpected errors above are terminating, so normalize only success.
            exit 0
        '
    rm -rf "$tmp"
}

test_windows_image_architecture_when_powershell_exists() {
    local shell_bin tmp
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    [[ -n "$shell_bin" ]] || return 0
    tmp="$(mktemp -d)"
    VMATE_WINDOWS_IMAGE="$WINDOWS_IMAGE" VMATE_IMAGE_ROOT="$tmp/Windows" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
            $ErrorActionPreference = "Stop"
            . $env:VMATE_WINDOWS_IMAGE
            $root = $env:VMATE_IMAGE_ROOT
            [IO.Directory]::CreateDirectory((Join-Path $root "System32/Config")) | Out-Null
            [IO.Directory]::CreateDirectory((Join-Path $root "System32/DriverStore")) | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $root "System32/Config/SYSTEM"), [byte[]]@(1))
            $kernel = Join-Path $root "System32/ntoskrnl.exe"
            function Write-TestPe([uint16]$Machine) {
                $bytes = New-Object byte[] 512
                $bytes[0] = 0x4d; $bytes[1] = 0x5a
                [BitConverter]::GetBytes([uint32]0x80).CopyTo($bytes, 0x3c)
                $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
                [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0x84)
                [IO.File]::WriteAllBytes($kernel, $bytes)
            }
            Write-TestPe 0x8664
            $image = Assert-VMateGpuPGuestWindowsImage $root
            if ($image.Architecture -cne "x64" -or
                $image.BuildCompatibilityPolicy -notmatch "may differ") {
                throw "x64/different-build policy was rejected"
            }
            foreach ($machine in [uint16]0x014c, [uint16]0xaa64) {
                Write-TestPe $machine
                try {
                    [void](Assert-VMateGpuPGuestWindowsImage $root)
                    throw "non-x64 image was accepted"
                } catch {
                    if ($_.Exception.Message -eq "non-x64 image was accepted") { throw }
                }
            }
            exit 0
        '
    rm -rf "$tmp"
}

test_files_are_bounded_ps51_modules
test_discovery_is_bound_to_real_signed_vendor_package
test_copy_plan_has_fail_closed_path_mapping
test_offline_publish_is_transactional_and_idempotent
test_pure_functions_when_powershell_exists
test_windows_image_architecture_when_powershell_exists

echo 'OK: Windows GPU-P DriverStore discovery and publish checks passed'
