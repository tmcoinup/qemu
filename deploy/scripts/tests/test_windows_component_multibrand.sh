#!/usr/bin/env bash
# Windows 多品牌 SSD/GPU/显示器目录、序列策略和持久绑定回归。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
POWERSHELL="$(command -v pwsh || command -v powershell || true)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -n "$POWERSHELL" ]] || {
    echo "SKIP: PowerShell not found"
    exit 0
}

REPO_ROOT="$REPO_ROOT" "$POWERSHELL" -NoLogo -NoProfile -NonInteractive \
    -Command '
        $ErrorActionPreference = "Stop"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Common.ps1"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Components.ps1"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Arguments.ps1"
        . "$env:REPO_ROOT/deploy/scripts/tests/fixtures/gpu_board_catalog_cases.ps1"

        function Test-VMateCompatibilityPlatform {
            param([object]$Platform)
            return $false
        }

        function Assert-Throws {
            param([scriptblock]$Action, [string]$Message)
            try { & $Action } catch { return }
            throw $Message
        }

        $path = "$env:REPO_ROOT/deploy/hardware/components.json"
        $catalog = Read-VMateComponentManifest $path
        $gpuCases = @(Get-TestGpuBoardCases `
            "$env:REPO_ROOT/deploy/hardware/gpu-boards.json")
        Assert-TestGpuBoardCoverage $gpuCases
        . "$env:REPO_ROOT/deploy/scripts/tests/fixtures/windows_component_policy_exact_fixture.ps1"
        Invoke-VMateComponentPolicyExactTests $catalog
        if ($catalog.storage_items.Count -ne 4 -or
            $catalog.gpu_items.Count -ne 18 -or
            $catalog.legacy_gpu_items.Count -ne 6 -or
            $catalog.monitor_items.Count -ne 4) {
            throw "多品牌目录数量错误。"
        }
        $expectedMonitors = [ordered]@{
            "samsung-s24f350" = @(2, 2016)
            "aoc-24b2xh" = @(6, 2020)
            "xiaomi-rmmnt238nf" = @(5, 2020)
            "lenovo-l24e-30" = @(4, 2020)
        }
        foreach ($monitor in $catalog.monitor_items) {
            $expected = $expectedMonitors[[string]$monitor.id]
            if ($null -eq $expected -or $monitor.enabled -ne $true -or
                [int]$monitor.selection_weight -ne [int]$expected[0] -or
                [int]$monitor.release_year -ne [int]$expected[1]) {
                throw "显示器 ID、启用状态、权重或发售年份未精确锁定。"
            }
        }
        Assert-Throws {
            Assert-VMateMonitorCatalogSet @(
                $catalog.monitor_items | Select-Object -Skip 1)
        } "缺少受控显示器 ID 的目录没有 fail closed。"
        foreach ($mutation in @(
                @("id", "AOC-24B2XH"),
                @("enabled", $false),
                @("selection_weight", 7),
                @("release_year", 2021),
                @("windows_friendly_name", "Wrong Monitor"))) {
            $badMonitor = $catalog.monitor_items[1] |
                ConvertTo-Json -Depth 32 | ConvertFrom-Json
            $badMonitor.($mutation[0]) = $mutation[1]
            Assert-Throws {
                Assert-VMateMonitorComponent $badMonitor
            } "显示器字段 $($mutation[0]) 篡改没有 fail closed。"
        }
        $exactCapacity = @(Get-VMateStorageCapacityCandidates `
                $catalog.storage_items 512110190592)
        $expectedStorageIds = @("samsung-970-pro-512gb",
            "intel-760p-512gb", "wd-pc-sn730-512gb", "kioxia-xg6-512gb")
        if ($exactCapacity.Count -ne 4 -or
            (@($exactCapacity.id | Sort-Object) -join ",") -cne
                (@($expectedStorageIds | Sort-Object) -join ",")) {
            throw "外置存储目录没有严格限定四款精确 512GB 型号。"
        }
        if ([string]$catalog.storage.id -cnotin $expectedStorageIds -or
            [int64]$catalog.storage.raw_bytes -ne 512110190592) {
            throw "默认随机存储没有限定在统一 512G 产品子池。"
        }
        $expectedGpuIds = @($gpuCases.StableId | Sort-Object)
        if ((@($catalog.gpu_items.id | Sort-Object) -join ",") -cne
                ($expectedGpuIds -join ",") -or
            @($catalog.gpu_items | Where-Object {
                    [string]$_.carrier_vendor -cne "0x1AF4" -or
                    [string]$_.subsystem_vendor -ceq
                        [string]$_.carrier_vendor
                }).Count -ne 0) {
            throw "AIB 离线目录投影或真实 subsystem/virtio 载体边界错误。"
        }
        Assert-Throws {
            Get-VMateStorageCapacityCandidates $catalog.storage_items 123456
        } "未知磁盘容量没有 fail closed。"

        $missingProfile = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("vmate-missing-" + [Guid]::NewGuid().ToString("N") + ".json")
        $dryComponents = Resolve-VMateComponentsForProfile $catalog `
            $missingProfile $false -DryRun $true `
            -DryRunStorageId "samsung-970-pro-512gb"
        if ([string]$dryComponents.storage.id -cne
            "samsung-970-pro-512gb") {
            throw "DryRun 没有按显式稳定 ID 选择存储。"
        }
        Assert-Throws {
            Resolve-VMateComponentsForProfile $catalog `
                $missingProfile $false -DryRun $true `
                -StorageId "sk-hynix-gold-p31-500gb"
        } "DryRun 接受了非统一 512G 的显式存储 ID。"
        Assert-Throws {
            Resolve-VMateComponentsForProfile $catalog $missingProfile $false `
                -DryRun $true -DryRunStorageId "missing-storage"
        } "DryRun 接受了不存在的存储 ID。"

        $profilePath = [System.IO.Path]::GetTempFileName()
        try {
            [pscustomobject]@{
                components = [pscustomobject]@{
                    storage_id = "samsung-970-pro-512gb"
                    monitor_id = "aoc-24b2xh"
                    keyboard_id = "microsoft-wired-keyboard-600"
                    mouse_id = "microsoft-usb-optical-mouse"
                    tablet_id = "qemu-generic-usb-tablet"
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath `
                -Encoding UTF8
            $persisted = Resolve-VMateComponentsForProfile $catalog `
                $profilePath $false -QemuImg "missing-qemu-img" `
                -Disk "missing-disk"
            if ([string]$persisted.storage.id -cne "samsung-970-pro-512gb") {
                throw "已有 profile 没有优先按持久 storage_id 解析。"
            }
            $rerolled = Resolve-VMateComponentsForProfile $catalog `
                $profilePath $true -DryRun $true `
                -DryRunStorageId "samsung-970-pro-512gb"
            if ([string]$rerolled.storage.id -cne
                "samsung-970-pro-512gb") {
                throw "reroll 没有进入新存储选择契约。"
            }
        } finally {
            Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
        }
        foreach ($storage in $catalog.storage_items) {
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($iteration in 1..32) {
                $serial = New-VMateStorageSerial $storage
                Assert-VMateComponentSerial $storage $serial "SSD"
                if (-not $seen.Add($serial)) {
                    throw "SSD 序列号生成器重复：$($storage.id)"
                }
            }
            $selectedStorage = New-VMateResolvedComponents $catalog $storage `
                $catalog.monitor $catalog.keyboard $catalog.mouse $catalog.tablet
            $platform = [pscustomobject]@{
                id = "argument-test"
                devices = [pscustomobject]@{
                    root_port = [pscustomobject]@{
                        pci_vendor = "0x8086"
                        pci_device = "0xA338"
                        revision = "0xF0"
                    }
                    nvme = [pscustomobject]@{
                        boot_supported = $true
                        max_pcie_generation = 2
                        lanes = 2
                    }
                    audio = [pscustomobject]@{
                        controller_pci_vendor = "0x8086"
                        controller_pci_device = "0xA348"
                        identity_fidelity = "protocol_identity_only"
                        codec_id = "0x10EC0887"
                        codec_revision = "0x100302"
                        codec_subsystem_id = "0x104386C7"
                    }
                    nic = [pscustomobject]@{
                        subsystem_vendor = "0x8086"
                        subsystem_device = "0xA01F"
                    }
                }
            }
            $profile = [pscustomobject]@{
                identity = [pscustomobject]@{
                    uuid = "12345678-1234-4abc-8def-1234567890ab"
                    nvme_serial = New-VMateStorageSerial $storage
                    mac = "00:1B:21:12:34:56"
                }
            }
            $argv = @(New-VMatePlatformDeviceArguments $platform $profile `
                    $selectedStorage "disk.qcow2" 2201 33891)
            $nvmeArg = @($argv | Where-Object {
                    [string]$_ -match "^nvme,id=nvmectl0,"
                })
            if ($nvmeArg.Count -ne 1 -or
                $nvmeArg[0] -notmatch ("x-identity-profile=" +
                    [Regex]::Escape([string]$storage.identity_profile))) {
                throw "SSD identity profile 未接入 QEMU 参数：$($storage.id)"
            }
        }
        foreach ($caseText in @(
                "samsung-970-pro-512gb|SN0NN0000000000",
                "intel-760p-512gb|BTHHN0000000512D",
                "wd-pc-sn730-512gb|N00000000000",
                "wd-pc-sn730-512gb|NFFFFFFFFFFF",
                "kioxia-xg6-512gb|N00000000000",
                "kioxia-xg6-512gb|NFFFFFFFFFFF")) {
            $caseId, $caseSerial = $caseText -split "\|", 2
            Assert-VMateComponentSerial `
                (Get-VMateComponentById $catalog.storage_items `
                    $caseId "storage") $caseSerial "SSD"
        }
        foreach ($caseText in @(
                "samsung-970-pro-512gb|S000N0000000000",
                "samsung-970-pro-512gb|SFFFNFFFFFFFFFF",
                "samsung-970-pro-512gb|SNNNNNNNNNNNNNN",
                "intel-760p-512gb|BTHH00000000512D",
                "intel-760p-512gb|BTHHFFFFFFFF512D",
                "intel-760p-512gb|BTHHNNNNNNNN512D",
                "wd-pc-sn730-512gb|000000000000",
                "wd-pc-sn730-512gb|FFFFFFFFFFFF",
                "wd-pc-sn730-512gb|NNNNNNNNNNNN",
                "kioxia-xg6-512gb|000000000000",
                "kioxia-xg6-512gb|FFFFFFFFFFFF",
                "kioxia-xg6-512gb|NNNNNNNNNNNN")) {
            $caseId, $caseSerial = $caseText -split "\|", 2
            Assert-Throws {
                Assert-VMateComponentSerial `
                    (Get-VMateComponentById $catalog.storage_items `
                        $caseId "storage") $caseSerial "SSD"
            } "Windows 接受了 $caseId 占位序列号 $caseSerial。"
        }
        foreach ($monitor in $catalog.monitor_items) {
            if ([int]$monitor.native_resolution.x -ne 1920 -or
                [int]$monitor.native_resolution.y -ne 1080 -or
                [string]$monitor.native_resolution.aspect_ratio -ne "16:9") {
                throw "显示器不是 1920x1080/16:9：$($monitor.id)"
            }
            foreach ($iteration in 1..16) {
                $serial = New-VMateMonitorSerial $monitor
                Assert-VMateMonitorSerial $monitor $serial
            }
        }
        $aoc = Get-VMateComponentById $catalog.monitor_items `
            "aoc-24b2xh" "monitor"
        $originalRandomText = (
            Get-Item -Path Function:\New-VMatePolicyRandomText).ScriptBlock
        $script:aocRandomValues =
            [System.Collections.Generic.Queue[string]]::new()
        foreach ($value in @("ABCD", "1", "Z", "000000",
                "EFGH", "2", "Y", "123456")) {
            $script:aocRandomValues.Enqueue($value)
        }
        try {
            function New-VMatePolicyRandomText {
                param([int]$Length, [string]$Alphabet)
                if ($script:aocRandomValues.Count -eq 0) {
                    throw "AOC 故障注入随机序列耗尽。"
                }
                $value = $script:aocRandomValues.Dequeue()
                if ($value.Length -ne $Length) {
                    throw "AOC 故障注入长度与生成器请求不一致。"
                }
                return $value
            }
            $aocSerial = New-VMateMonitorSerial $aoc
            if ($aocSerial -cne "EFGH2YA123456" -or
                $script:aocRandomValues.Count -ne 0) {
                throw "AOC binary suffix 000000 没有重抽完整序列。"
            }
            Assert-VMateMonitorSerial $aoc $aocSerial
            if ((Get-VMateMonitorBinarySerial $aoc $aocSerial) -cne
                "0x0001E240") {
                throw "AOC 重抽后的 binary serial 映射错误。"
            }
        } finally {
            Set-Item -Path Function:\New-VMatePolicyRandomText `
                -Value $originalRandomText
            Remove-Variable -Name aocRandomValues -Scope Script `
                -ErrorAction SilentlyContinue
        }

        $binding = [pscustomobject]@{
            binding_version = 3
            storage_id = "samsung-970-pro-512gb"
            gpu_id = "amd-radeon-rx-560"
            monitor_id = "aoc-24b2xh"
            keyboard_id = "microsoft-wired-keyboard-600"
            mouse_id = "microsoft-usb-optical-mouse"
            tablet_id = "qemu-generic-usb-tablet"
        }
        $selected = Resolve-VMateComponentSelection $catalog $binding
        if ([string]$selected.gpu.identity_fidelity -cne
            "label_only_out_of_scope") {
            throw "旧 generic GPU profile 没有通过兼容池恢复。"
        }
        $v3 = New-VMateComponentProfileBinding $selected
        Assert-VMateComponentProfileBinding $v3 $selected
        $v3.catalog_revision = "catalog-appended"
        $v3.catalog_digest = "catalog-appended"
        Assert-VMateComponentProfileBinding $v3 $selected
        $v3.storage_digest = "tampered"
        Assert-Throws {
            Assert-VMateComponentProfileBinding $v3 $selected
        } "所选 SSD 摘要篡改未被拒绝。"

        $legacyBinding = [pscustomobject]@{
            schema_version = 1
            catalog_revision = "legacy"
            catalog_digest = "legacy"
            storage_id = "samsung-970-pro-512gb"
            monitor_id = "samsung-s24f350"
            keyboard_id = "microsoft-wired-keyboard-600"
            mouse_id = "microsoft-usb-optical-mouse"
        }
        $legacy = Resolve-VMateComponentSelection $catalog $legacyBinding
        Assert-VMateComponentProfileBinding $legacyBinding $legacy
        $downgraded = New-VMateComponentProfileBinding $catalog |
            ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $downgraded.PSObject.Properties.Remove("binding_version")
        Assert-Throws {
            Assert-VMateComponentProfileBinding $downgraded $legacy
        } "V3 摘要绑定删除版本后错误降级为旧版绑定。"
        $legacyBinding.storage_id = "wd-blue-sn570-500gb"
        Assert-Throws {
            $legacyWd = Resolve-VMateComponentSelection $catalog $legacyBinding
            Assert-VMateComponentProfileBinding $legacyBinding $legacyWd
        } "无条目摘要的非 Samsung 绑定错误通过。"

        $badStorage = $catalog.storage_items[0] |
            ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $badStorage.identity_profile = "intel-760p-512gb"
        Assert-Throws {
            Assert-VMateStorageComponent $badStorage
        } "跨品牌 identity_profile 拼接未被拒绝。"
        $badGpu = $catalog.gpu_items[0] |
            ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $badGpu.subsystem_device = "0xFFFF"
        Assert-Throws {
            Assert-VMateGpuBoardComponent $badGpu
        } "AIB 真实 subsystem 篡改未被拒绝。"
        $badMonitor = $catalog.monitor_items[0] |
            ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $badMonitor.native_resolution.x = 2560
        Assert-Throws {
            Assert-VMateMonitorComponent $badMonitor
        } "非 1920x1080 显示器错误通过。"
    '

runtime_tmp="$(mktemp -d)"
trap 'rm -rf "$runtime_tmp"' EXIT
fake_qemu_img="$runtime_tmp/qemu-img"
disk="$runtime_tmp/disk.qcow2"
printf 'fixture' >"$disk"
cat >"$fake_qemu_img" <<'FAKE_QEMU_IMG'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
    printf 'qemu-img version %s\n' "${VMATE_FAKE_VERSION:-11.0.2}"
elif [[ "${1:-}" == "info" ]]; then
    printf '{"virtual-size":%s,"format":"%s"}\n' \
        "${VMATE_FAKE_SIZE:?}" "${VMATE_FAKE_FORMAT:-qcow2}"
else
    exit 64
fi
FAKE_QEMU_IMG
chmod +x "$fake_qemu_img"

REPO_ROOT="$REPO_ROOT" VMATE_FAKE_QEMU_IMG="$fake_qemu_img" \
    VMATE_FAKE_DISK="$disk" VMATE_FAKE_SIZE=512110190592 \
    "$POWERSHELL" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Common.ps1"
        . "$env:REPO_ROOT/deploy/windows/lib/VMate.Components.ps1"

        function Assert-Throws {
            param([scriptblock]$Action, [string]$Pattern)
            try { & $Action } catch {
                if ($_.Exception.Message -notmatch $Pattern) {
                    throw "错误不可诊断：$($_.Exception.Message)"
                }
                return
            }
            throw "预期失败没有发生：$Pattern"
        }

        $catalog = Read-VMateComponentManifest `
            "$env:REPO_ROOT/deploy/hardware/components.json"
        $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) `
            ("vmate-new-" + [Guid]::NewGuid().ToString("N") + ".json")
        $selected = Resolve-VMateComponentsForProfile $catalog $profilePath `
            $false -QemuImg $env:VMATE_FAKE_QEMU_IMG `
            -Disk $env:VMATE_FAKE_DISK
        if ([int64]$selected.storage.raw_bytes -ne 512110190592 -or
            [string]$selected.storage.id -notin @(
                "samsung-970-pro-512gb", "intel-760p-512gb",
                "wd-pc-sn730-512gb", "kioxia-xg6-512gb")) {
            throw "新 profile 没有按磁盘真实字节数选择 512GB 型号。"
        }

        # 选择后的第二次 qemu-img info 必须重新读取磁盘；这里模拟两次读取间
        # virtual-size 改变，确保既有 TOCTOU 防线没有被容量握手替代。
        $env:VMATE_FAKE_SIZE = "500107862016"
        Assert-Throws {
            Assert-VMateStorageCapacity -QemuImg $env:VMATE_FAKE_QEMU_IMG `
                -Disk $env:VMATE_FAKE_DISK `
                -ExpectedBytes ([int64]$selected.storage.raw_bytes) `
                -DryRun $false
        } "磁盘虚拟容量"

        $env:VMATE_FAKE_SIZE = "123456"
        Assert-Throws {
            Resolve-VMateComponentsForProfile $catalog $profilePath $false `
                -QemuImg $env:VMATE_FAKE_QEMU_IMG -Disk $env:VMATE_FAKE_DISK
        } "统一 512G"
        $env:VMATE_FAKE_SIZE = "500107862016"
        Assert-Throws {
            Resolve-VMateComponentsForProfile $catalog $profilePath `
                $false -QemuImg $env:VMATE_FAKE_QEMU_IMG `
                -Disk $env:VMATE_FAKE_DISK
        } "统一 512G"
        Assert-Throws {
            Resolve-VMateComponentsForProfile $catalog $profilePath $false `
                -QemuImg $env:VMATE_FAKE_QEMU_IMG `
                -Disk $env:VMATE_FAKE_DISK `
                -StorageId "samsung-970-pro-512gb"
        } "统一 512G"
        $env:VMATE_FAKE_SIZE = "512110190592"
        $env:VMATE_FAKE_FORMAT = "raw"
        Assert-Throws {
            Get-VMateStorageVirtualSize -QemuImg $env:VMATE_FAKE_QEMU_IMG `
                -Disk $env:VMATE_FAKE_DISK
        } "磁盘格式 raw"
        $env:VMATE_FAKE_FORMAT = "qcow2"
        $env:VMATE_FAKE_VERSION = "10.2.0"
        Assert-Throws {
            Get-VMateStorageVirtualSize -QemuImg $env:VMATE_FAKE_QEMU_IMG `
                -Disk $env:VMATE_FAKE_DISK
        } "11.0.2"
    '

printf 'firmware-code' >"$runtime_tmp/code.fd"
printf 'firmware-vars' >"$runtime_tmp/vars.fd"
USERPROFILE="$runtime_tmp/user" "$POWERSHELL" -NoLogo -NoProfile \
    -NonInteractive -File "$REPO_ROOT/deploy/windows/start-vm.ps1" \
    -Qemu /bin/true -VmRoot "$runtime_tmp/vm" \
    -Disk "$runtime_tmp/not-created.qcow2" \
    -OvmfCode "$runtime_tmp/code.fd" \
    -OvmfVarsTemplate "$runtime_tmp/vars.fd" -NoFbShm -NoSdl \
    -PlatformId intel-lga1151-i3-9100f-asus-prime-h310m-a-r2 \
    -DryRunHostCpuName 'Intel(R) Core(TM) i3-9100F CPU @ 3.60GHz' \
    -StorageId samsung-970-pro-512gb \
    -GpuId asus-ph-gtx1050ti-4g -MonitorId aoc-24b2xh -DryRun \
    >"$runtime_tmp/dry-run.out"
component_revision="$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["catalog_revision"])' \
    "$REPO_ROOT/deploy/hardware/components.json")"
grep -F "Parts:    $component_revision / samsung-970-pro-512gb" \
    "$runtime_tmp/dry-run.out" >/dev/null ||
    fail "DryRun 未在无真实磁盘时按显式 storage ID 工作"

grep -F 'x-identity-profile=$storageIdentityProfile' \
    "$REPO_ROOT/deploy/windows/lib/VMate.Arguments.ps1" >/dev/null ||
    fail "Windows NVMe 参数没有使用所选 identity profile"
grep -F 'discard=unmap,detect-zeroes=unmap' \
    "$REPO_ROOT/deploy/windows/lib/VMate.Arguments.ps1" >/dev/null ||
    fail "Windows 启动盘没有启用零块回收"
if grep -F 'use-samsung-id=on' \
    "$REPO_ROOT/deploy/windows/lib/VMate.Arguments.ps1" >/dev/null; then
    fail "Windows NVMe 参数仍硬编码 Samsung 开关"
fi

resolve_line="$(grep -n -m1 'Resolve-VMateComponentsForProfile' \
    "$REPO_ROOT/deploy/windows/start-vm.ps1" | cut -d: -f1)"
prepare_line="$(grep -n -m1 'Prepare-VMateHardwareProfile' \
    "$REPO_ROOT/deploy/windows/start-vm.ps1" | cut -d: -f1)"
capacity_line="$(grep -n -m1 'Assert-VMateStorageCapacity' \
    "$REPO_ROOT/deploy/windows/start-vm.ps1" | cut -d: -f1)"
[[ "$resolve_line" -lt "$prepare_line" && "$prepare_line" -lt "$capacity_line" ]] ||
    fail "容量检查没有位于 profile/所选部件解析之后"
grep -F 'Get-VMateStorageVirtualSize' \
    "$REPO_ROOT/deploy/windows/lib/VMate.ComponentSelection.ps1" >/dev/null ||
    fail "新 profile 选择前没有读取实际磁盘容量"

echo "OK: Windows multi-brand component catalog tests passed"
