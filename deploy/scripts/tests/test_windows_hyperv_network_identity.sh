#!/usr/bin/env bash
# Hyper-V 静态随机 MAC 身份合同回归。
# shellcheck disable=SC2016 # PowerShell 片段必须保留字面量 $。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE="$REPO_ROOT/deploy/windows/gpup/VMate.HyperV.NetworkIdentity.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}
reject_regex() {
    if grep -E -- "$1" "$2" >/dev/null; then fail "forbidden '$1' in $2"; fi
}

test_static_contract() {
    [[ -f "$MODULE" ]] || fail "missing module: $MODULE"
    [[ "$(wc -l < "$MODULE")" -le 500 ]] || fail 'module exceeds 500 lines'
    [[ "$(od -An -tx1 -N3 "$MODULE" | tr -d ' \n')" == efbbbf ]] \
        || fail 'PowerShell module lacks UTF-8 BOM'
    require_text 'RandomNumberGenerator]::Create()' "$MODULE"
    require_text "return '02' +" "$MODULE"
    require_text 'Global\VMate.HyperV.NetworkIdentity.Allocator' "$MODULE"
    [[ "$(grep -cF 'Enter-VMateHyperVNetworkIdentityAllocator' "$MODULE")" -ge 3 ]] \
        || fail 'generation and apply must both hold allocator mutex'
    require_text 'Get-VMNetworkAdapter -All' "$MODULE"
    require_text 'Get-VMNetworkAdapter -ManagementOS' "$MODULE"
    require_text 'HardwareIdentity' "$MODULE"
    require_text 'identity.json' "$MODULE"
    require_text '-StaticMacAddress $desired' "$MODULE"
    require_text '-DynamicMacAddress -Confirm:$false' "$MODULE"
    require_text 'Get-VMateHyperVNetworkIdentityObserved' "$MODULE"
    require_text "Status = 'NotPresent'" "$MODULE"
    require_text '已回滚并验证原 MAC 策略' "$MODULE"
    reject_regex 'Get-Random|00155D|VirtualDiskId|Set-VHD|Set-ItemProperty|'\
'New-ItemProperty|reg(\.exe)?[[:space:]]+add' "$MODULE"
}

test_dynamic_contract() {
    local shell_bin
    shell_bin="$(command -v pwsh || command -v powershell || true)"
    if [[ -z "$shell_bin" ]]; then
        echo 'SKIP: PowerShell not found; Hyper-V network identity static contract passed'
        return
    fi
    VMATE_HYPERV_NETWORK_IDENTITY="$MODULE" \
        "$shell_bin" -NoLogo -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        . $env:VMATE_HYPERV_NETWORK_IDENTITY
        function Assert-Equal($Actual, $Expected, $Message) {
            if ([string]$Actual -cne [string]$Expected) {
                throw "$Message actual=$Actual expected=$Expected"
            }
        }
        function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
            try { & $Action } catch {
                if ($_.Exception.Message -notmatch $Pattern) { throw $_ }
                return
            }
            throw "expected failure: $Pattern"
        }
        $seen = @{}
        1..100 | ForEach-Object {
            $mac = New-VMateHyperVRandomMacAddress
            if ($mac -notmatch "^02[0-9A-F]{10}$") { throw "invalid MAC: $mac" }
            if ($seen.ContainsKey($mac)) { throw "duplicate MAC: $mac" }
            $seen[$mac] = $true
        }
        Assert-Throws { Assert-VMateHyperVLocalUnicastMacAddress `
                "00155D010203" } "locally-administered unicast"

        $script:allAdapters = @()
        $script:managementAdapters = @()
        $script:vmAdapters = @()
        function Get-VMNetworkAdapter {
            param([switch]$All, [switch]$ManagementOS, [object]$VM,
                [object]$ErrorAction)
            if ($All) { return @($script:allAdapters) }
            if ($ManagementOS) { return @($script:managementAdapters) }
            return @($script:vmAdapters)
        }
        function Get-VMateHyperVReservedNetworkIdentity { return @() }
        function Assert-VMateHyperVNetworkIdentityHost { }
        $vm = [pscustomobject]@{ Id = [Guid]::NewGuid(); State = "Off" }
        $empty = New-VMateHyperVNetworkIdentityFragment -VM $vm
        Assert-Equal $empty.Status "NotPresent" "no-NIC status"
        Assert-Equal @($empty.NetworkAdapters).Count 0 "no-NIC items"

        $adapter = [pscustomobject]@{ Id = "adapter-1"; Name = "NIC"
            VMId = $vm.Id; MacAddress = ""
            DynamicMacAddressEnabled = $true }
        $script:vmAdapters = @($adapter)
        $script:allAdapters = @($adapter)
        $fragment = New-VMateHyperVNetworkIdentityFragment -VM $vm
        Assert-VMateHyperVNetworkIdentityFragment $fragment
        $planned = [string]$fragment.NetworkAdapters[0].StaticMacAddress
        if ($planned -notmatch "^02[0-9A-F]{10}$") { throw "bad planned MAC" }

        function Set-VMNetworkAdapter {
            param($VMNetworkAdapter, $StaticMacAddress, [switch]$DynamicMacAddress,
                [switch]$Confirm, $ErrorAction)
            if ($DynamicMacAddress) {
                $VMNetworkAdapter.DynamicMacAddressEnabled = $true
            } else {
                $VMNetworkAdapter.MacAddress = $StaticMacAddress
                $VMNetworkAdapter.DynamicMacAddressEnabled = $false
            }
        }
        $result = Set-VMateHyperVNetworkIdentity $vm $fragment
        Assert-Equal $result.Status "Applied" "apply status"
        Assert-Equal $adapter.MacAddress $planned "MAC readback"
        Assert-Equal $adapter.DynamicMacAddressEnabled $false "static policy"
        $adapter.VMId = ""
        $again = Set-VMateHyperVNetworkIdentity $vm $fragment
        Assert-Equal $again.Changed 0 "idempotent apply with missing VMId"

        $adapter.MacAddress = ""
        $adapter.DynamicMacAddressEnabled = $true
        $script:failStatic = $true
        function Set-VMNetworkAdapter {
            param($VMNetworkAdapter, $StaticMacAddress, [switch]$DynamicMacAddress,
                [switch]$Confirm, $ErrorAction)
            if ($script:failStatic -and -not $DynamicMacAddress) {
                $script:failStatic = $false; throw "injected setter failure"
            }
            if ($DynamicMacAddress) {
                $VMNetworkAdapter.DynamicMacAddressEnabled = $true
            } else {
                $VMNetworkAdapter.MacAddress = $StaticMacAddress
                $VMNetworkAdapter.DynamicMacAddressEnabled = $false
            }
        }
        Assert-Throws { Set-VMateHyperVNetworkIdentity $vm $fragment } `
            "已回滚并验证原 MAC 策略"
        Assert-Equal $adapter.DynamicMacAddressEnabled $true "rollback policy"

        $collision = [pscustomobject]@{ Id = "other-adapter"; Name = "Other"
            VMId = [Guid]::NewGuid(); MacAddress = $planned
            DynamicMacAddressEnabled = $false }
        $script:allAdapters = @($adapter, $collision)
        Assert-Throws { Set-VMateHyperVNetworkIdentity $vm $fragment } `
            "已被另一张"
    '
}

test_static_contract
test_dynamic_contract
echo 'PASS: Hyper-V network identity contract'
