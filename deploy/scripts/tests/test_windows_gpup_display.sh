#!/usr/bin/env bash
# 验证 GPU-P 的宿主 IDD 边界与 guest 单一真实厂商显示栈门禁。
# shellcheck disable=SC2016 # PowerShell 合同字符串必须保持字面量 $。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST_DISPLAY="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.Display.ps1"
GUEST_TEST="$REPO_ROOT/deploy/windows/gpup/Test-VMateGpuPGuest.ps1"
GUEST_VALIDATION="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.GuestValidation.ps1"
D3D_VALIDATION="$REPO_ROOT/deploy/windows/gpup/VMate.GpuP.D3DValidation.ps1"

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
    shift
    if grep -E -- "$pattern" "$@" >/dev/null; then
        fail "forbidden pattern '$pattern' in $*"
    fi
}

test_static_contract() {
    local file
    for file in "$HOST_DISPLAY" "$GUEST_TEST" "$GUEST_VALIDATION" \
        "$D3D_VALIDATION"; do
        [[ -f "$file" ]] || fail "missing GPU-P display file: $file"
        [[ "$(wc -l < "$file")" -le 500 ]] \
            || fail "PowerShell file exceeds 500 lines: $file"
        [[ "$(od -An -tx1 -N3 "$file" | tr -d ' \n')" == efbbbf ]] \
            || fail "PowerShell 5.1 file lacks UTF-8 BOM: $file"
    done

    # 宿主只读盘点必须同时依据实例、服务和实际 driver files 分类 IDD。
    require_text 'Win32_PnPEntity' "$HOST_DISPLAY"
    require_text "PNPClass -ceq 'Display'" "$HOST_DISPLAY"
    require_text 'Win32_PnPSignedDriverCIMDataFile' "$HOST_DISPLAY"
    require_text 'IsNonPhysical = -not $isPhysicalPci' "$HOST_DISPLAY"
    require_text 'IsIndirectDisplay = $isIndirect' "$HOST_DISPLAY"
    require_text 'GameViewer|Indirect|IddCx' "$HOST_DISPLAY"

    # 外部安装器要锁 Publisher/摘要/签名和静默模式，且不允许仓库内捆绑。
    require_text 'Get-AuthenticodeSignature -LiteralPath $fullPath' "$HOST_DISPLAY"
    require_text "[string]\$signature.Status -cne 'Valid'" "$HOST_DISPLAY"
    require_text 'ExpectedPublisher' "$HOST_DISPLAY"
    require_text '禁止在项目中捆绑私有驱动' "$HOST_DISPLAY"
    require_text "@('/i', ('\"{0}\"' -f \$trust.Path), '/qn', '/norestart')" \
        "$HOST_DISPLAY"
    require_text 'Assert-VMateGpuPHostContext -RequireHyperV -RequireAdministrator' \
        "$HOST_DISPLAY"

    # Guest 只接受一张健康、型号精确相等且具有真实厂商 PCI 证据的目标 GPU；
    # 非严格模式可以额外保留经过完整身份约束的微软控制台显卡。
    require_text "VMate.GpuP.GuestValidation.ps1" "$GUEST_TEST"
    require_text '$targetGpu.Count -ne 1' "$GUEST_VALIDATION"
    require_text 'ConsoleCompatible = @($extras' "$GUEST_VALIDATION"
    require_text '$problem -notin @(0, 22)' "$GUEST_VALIDATION"
    require_text '.Equals($GpuName.Trim(),' "$GUEST_VALIDATION"
    require_text "if (\$Vendor -ieq 'NVIDIA') { '10DE' } else { '1002' }" \
        "$GUEST_VALIDATION"
    require_text '拒绝名称字符串投影' "$GUEST_VALIDATION"
    require_text 'VioGpuDod|viogpudo\.sys|VEN_1AF4' "$GUEST_VALIDATION"
    require_text 'GameViewer|IndirectKmd|IddCx|IddSample' "$GUEST_VALIDATION"
    require_text "[string]\$Display.Service -ieq 'VirtualRender'" "$GUEST_VALIDATION"
    require_text "[IO.Path]::GetFileName(\$_) -ieq 'vrd.sys'" "$GUEST_VALIDATION"
    require_text 'Get-AuthenticodeSignature -LiteralPath $Path' "$GUEST_VALIDATION"
    require_text "foreach (\$directory in @('System32', 'SysWOW64'))" \
        "$GUEST_VALIDATION"
    require_text 'nvldumdx|nvwgf2umx|nvapi64|nvcuda' "$GUEST_VALIDATION"
    require_text 'atidxx64|amdxx64|amdxc64|amdocl64' "$GUEST_VALIDATION"
    require_text "'--query-gpu=name,driver_version,uuid'" \
        "$D3D_VALIDATION"
    require_text "'--query-gpu=serial'" "$D3D_VALIDATION"
    require_text "'--query-gpu=memory.total'" "$D3D_VALIDATION"
    require_text 'ReportedMemoryTotalMiB = $reportedMemoryMiB' "$D3D_VALIDATION"
    require_text 'Invoke-VMateGpuPD3D11HardwareProbe' "$GUEST_VALIDATION"
    require_text 'D3D11 = $d3d11' "$GUEST_VALIDATION"
    require_text 'D3D_DRIVER_TYPE_HARDWARE = 1' "$D3D_VALIDATION"
    require_text 'D3D11CreateDevice' "$D3D_VALIDATION"
    require_text 'LoadedModulePaths = $loadedModulePaths' "$D3D_VALIDATION"
    require_text 'LoadedVendorModule' "$D3D_VALIDATION"
    require_text 'Assert-VMateGpuPSignedBinary -Path $path -Publisher $Vendor' \
        "$D3D_VALIDATION"
    require_text 'System32\atiadlxx.dll' "$D3D_VALIDATION"
    require_text 'SysWOW64\atiadlxy.dll' "$D3D_VALIDATION"
    require_text '$adlPaths = @(@(' "$D3D_VALIDATION"
    require_text '$paths = @(@(' "$GUEST_VALIDATION"
    require_text 'WarpFallbackAllowed = $false' "$D3D_VALIDATION"
    require_text 'VendorGpuUuid = if ($null -eq $smi)' "$GUEST_VALIDATION"
    require_text "if (\$Vendor -ieq 'AMD' -and \$RequireNvidiaSmi.IsPresent)" \
        "$GUEST_VALIDATION"
    require_text 'devnode 仍 Present' "$GUEST_VALIDATION"
    require_text "Join-Path \$env:ProgramData 'StealthGPU'" "$GUEST_TEST"

    # 清理边界：仅一个禁用调用、无确认；禁止删除、重绑和注册表隐藏。
    [[ "$(grep -cF 'Disable-PnpDevice' "$GUEST_VALIDATION")" -eq 1 ]] \
        || fail 'guest cleanup must contain exactly one Disable-PnpDevice call'
    require_text 'Disable-PnpDevice -InstanceId $target.InstanceId -Confirm:$false' \
        "$GUEST_VALIDATION"
    reject_regex 'Remove-PnpDevice|pnputil(\.exe)?|devcon(\.exe)?|'\
'Remove-WindowsDriver|Add-WindowsDriver|Enable-PnpDevice|'\
'Set-ItemProperty|New-ItemProperty|reg(\.exe)?[[:space:]]+add' \
        "$HOST_DISPLAY" "$GUEST_TEST" "$GUEST_VALIDATION"
    reject_regex 'Invoke-WebRequest|Start-BitsTransfer|Download(File|String)|'\
'FromBase64String|GameViewer[^|]*\.(exe|dll|sys)' "$HOST_DISPLAY"
}

test_dynamic_contract() {
    local powershell_bin
    powershell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$powershell_bin" ]]; then
        echo 'SKIP: PowerShell not found; GPU-P display static contract passed'
        return
    fi

    VMATE_GPUP_HOST_DISPLAY="$HOST_DISPLAY" \
    VMATE_GPUP_GUEST_TEST="$GUEST_TEST" \
        "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_GPUP_HOST_DISPLAY
        function Assert-VMateGpuPHostContext { return [pscustomobject]@{} }
        function Get-CimAssociatedInstance {
            param($InputObject, $Association, $ErrorAction)
            return [pscustomobject]@{
                Name = "C:\Windows\System32\drivers\GameViewerIddDriver.sys"
            }
        }
        function Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
            if ($ClassName -eq "Win32_PnPEntity") {
                return [pscustomobject]@{ PNPClass = "Display"
                    PNPDeviceID = "ROOT\GAMEVIEWER\0000"
                    Service = "WUDFRd"; Name = "GameViewer Virtual Display Adapter"
                    Status = "OK"; Present = $true }
            }
            if ($ClassName -eq "Win32_PnPSignedDriver") {
                return [pscustomobject]@{ DeviceClass = "DISPLAY"
                    DeviceID = "ROOT\GAMEVIEWER\0000"; DriverProviderName = "Vendor"
                    DriverVersion = "1.0"; InfName = "oem1.inf" }
            }
            if ($ClassName -eq "Win32_SystemDriver") { return @() }
            throw "unexpected CIM class: $ClassName"
        }
        $hostIdd = @(Get-VMateGpuPHostIndirectDisplayAdapter)
        if ($hostIdd.Count -ne 1 -or -not $hostIdd[0].IsIndirectDisplay -or
            $hostIdd[0].IsPhysicalPci) {
            throw "host IDD inventory did not classify mocked GameViewer adapter"
        }

        . $env:VMATE_GPUP_GUEST_TEST
        function Assert-VMateGpuPGuestContext { return [pscustomobject]@{} }
        function Assert-VMateWindowsProductionCodeIntegrity {
            return [pscustomobject]@{ Enabled = $true; TestSigningActive = $false }
        }
        function Get-VMateGpuPGuestVendorRuntimeFiles { return @() }
        function Assert-VMateGpuPDriverStack { }
        function Assert-VMateGpuPNoNvapiShim { }
        function Assert-VMateGpuPVendorApiFiles { }
        function Invoke-VMateGpuPD3D11HardwareProbe {
            return [pscustomobject]@{ Passed = $true; DriverType = "Hardware" }
        }
        function Assert-VMateGpuPD3DLoadedVendorModule {
            param($ProbeResult, $Vendor, $ExpectedVersion)
            $ProbeResult | Add-Member LoadedVendorModule "mock-umd.dll" -Force
            return $ProbeResult
        }
        function Invoke-VMateNvidiaSmiValidation {
            return [pscustomobject]@{ Name = "NVIDIA GeForce GTX 1060 6GB"
                DriverVersion = "577.00"; Uuid = "GPU-mock" }
        }
        function New-TestDisplay {
            param($Name, $InstanceId, $Service = "nvlddmkm", $Problem = 0,
                $Status = "OK", $Provider = "NVIDIA")
            return [pscustomobject]@{ Name = $Name; InstanceId = $InstanceId
                HardwareIds = @($InstanceId); Service = $Service
                ProblemCode = $Problem; Status = $Status; Present = $true
                DriverProvider = $Provider; DriverVersion = "32.0.15.7700"
                InfName = "oem1.inf"; IsSigned = $true; Signer = "WHCP"
                DriverFiles = @() }
        }
        function Assert-Fails {
            param([scriptblock]$Action, [string]$Expected)
            try { & $Action } catch {
                if ($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
                    throw "wrong failure: $($_.Exception.Message)"
                }
                return
            }
            throw "expected failure was accepted: $Expected"
        }

        $nvidia = New-TestDisplay "NVIDIA GeForce GTX 1060 6GB" `
            "PCI\VEN_10DE&DEV_1C03\GPU"
        $global:testDisplays = @($nvidia)
        function Get-VMateGpuPGuestDisplayInventory {
            return @($global:testDisplays)
        }
        $ok = Test-VMateGpuPGuest NVIDIA "NVIDIA GeForce GTX 1060 6GB" `
            "577.00" -StrictMode $true -RequireNvidiaSmi
        if (-not $ok.Passed -or -not $ok.D3D11.Passed -or
            -not (Test-VMateGpuPVersionMatch "32.0.15.7700" "577.00" NVIDIA)) {
            throw "valid NVIDIA GPU-P fixture was rejected"
        }
        $vrd = New-TestDisplay "NVIDIA GeForce GTX 1060 6GB" `
            "ROOT\VIRTUALRENDER\0000" "VirtualRender"
        $vrd.HardwareIds = @("ROOT\VIRTUALRENDER")
        $global:testDisplays = @($vrd)
        $vrdResult = Test-VMateGpuPGuest NVIDIA `
            "NVIDIA GeForce GTX 1060 6GB" "577.00"
        if (-not $vrdResult.Passed) {
            throw "trusted VRD path incorrectly required a guest PCI VEN"
        }
        $global:testDisplays = @($nvidia)
        $global:testDisplays = @($nvidia,
            (New-TestDisplay "Second GPU" "PCI\VEN_10DE&DEV_2200\GPU2"))
        Assert-Fails { Test-VMateGpuPGuest NVIDIA `
                "NVIDIA GeForce GTX 1060 6GB" "577.00" } `
            "必须只有一张健康"
        $global:testDisplays = @($nvidia,
            (New-TestDisplay "Microsoft Hyper-V Video" "VMBUS\VIDEO" `
                "synthvid" 22 "Error" "Microsoft Corporation"))
        Assert-Fails { Test-VMateGpuPGuest NVIDIA `
                "NVIDIA GeForce GTX 1060 6GB" "577.00" } `
            "devnode 仍 Present"
        $nonStrict = Test-VMateGpuPGuest NVIDIA `
            "NVIDIA GeForce GTX 1060 6GB" "577.00" -StrictMode $false
        if (-not $nonStrict.Passed) { throw "disabled Hyper-V Video was not tolerated" }
        $healthyConsole = New-TestDisplay "Microsoft Hyper-V Video" `
            "VMBUS\CONSOLE" "HyperVideo" 0 "OK" "Microsoft Corporation"
        $global:testDisplays = @($nvidia, $healthyConsole)
        $consoleResult = Test-VMateGpuPGuest NVIDIA `
            "NVIDIA GeForce GTX 1060 6GB" "577.00" -StrictMode $false
        if (-not $consoleResult.ConsoleCompatible -or
            $consoleResult.HealthyDisplayCount -ne 2) {
            throw "healthy Hyper-V console video was not tolerated"
        }
        $global:testDisplays = @($nvidia,
            (New-TestDisplay "Microsoft Hyper-V Video" "ROOT\FAKE" `
                "HyperVideo" 0 "OK" "Microsoft Corporation"))
        Assert-Fails { Test-VMateGpuPGuest NVIDIA `
                "NVIDIA GeForce GTX 1060 6GB" "577.00" -StrictMode $false } `
            "非严格模式只允许"
        $global:testDisplays = @($nvidia)
        $nvidia.Service = "VioGpuDod"
        Assert-Fails { Test-VMateGpuPGuest NVIDIA `
                "NVIDIA GeForce GTX 1060 6GB" "577.00" -StrictMode $false } `
            "被禁止"
        $nvidia.Service = "nvlddmkm"
        Assert-Fails { Test-VMateGpuPGuest NVIDIA "Projected Name" "577.00" } `
            "所选宿主真实型号"

        $amd = New-TestDisplay "AMD Radeon PRO" `
            "PCI\VEN_1002&DEV_73A1\GPU" "amdkmdag" 0 "OK" `
            "Advanced Micro Devices, Inc."
        $global:testDisplays = @($amd)
        $amdResult = Test-VMateGpuPGuest AMD "AMD Radeon PRO" `
            "32.0.15.7700"
        if (-not $amdResult.Passed) { throw "valid AMD GPU-P fixture was rejected" }
        Assert-Fails { Test-VMateGpuPGuest AMD "AMD Radeon PRO" `
                "32.0.15.7700" -RequireNvidiaSmi } "不能要求 nvidia-smi"

        $hyperV = New-TestDisplay "Microsoft Hyper-V Video" "VMBUS\VIDEO" `
            "HyperVideo" 0 "OK" "Microsoft Corporation"
        $global:testDisplays = @($hyperV, $amd)
        $global:disabled = @()
        function Disable-PnpDevice {
            param($InstanceId, [switch]$Confirm, $ErrorAction)
            if ($Confirm) { throw "cleanup prompted" }
            $global:disabled += $InstanceId
            foreach ($display in $global:testDisplays) {
                if ($display.InstanceId -eq $InstanceId) {
                    $display.ProblemCode = 22
                    $display.Status = "Error"
                }
            }
        }
        [void](Disable-VMateHyperVVideo)
        if ($global:disabled.Count -ne 1 -or
            $global:disabled[0] -ne "VMBUS\VIDEO") {
            throw "cleanup disabled a non-Hyper-V display"
        }
    '
}

test_static_contract
test_dynamic_contract
echo 'PASS: Windows GPU-P host IDD and guest display contract'
