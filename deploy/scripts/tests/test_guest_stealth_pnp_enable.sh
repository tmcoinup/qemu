#!/usr/bin/env bash
# 验证 guest-stealth 的 PnP 收尾逻辑会修复 Code 22，并且不会再主动禁用显示适配器。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPOOF="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
APPLY_SUPPORT="$REPO_ROOT/deploy/scripts/gpu-spoof-apply-support.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
RESTART_HELPER="$REPO_ROOT/deploy/guest-stealth/respawn-restart-state.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$APPLY_SUPPORT" ]] || fail "缺少 apply support helper"
grep -F 'function Enable-GpuSpoofDisplayDevices' "$APPLY_SUPPORT" >/dev/null \
    || fail "apply support 缺少 Display 设备自动启用函数"
grep -F 'function Test-GpuSpoofDisplayNeedsEnable' "$APPLY_SUPPORT" >/dev/null \
    || fail "apply support 缺少 Code 22/禁用态判断函数"
grep -E 'Code 22|CM_PROB_DISABLED' "$APPLY_SUPPORT" >/dev/null \
    || fail "apply support 没有显式处理设备管理器 Code 22"
grep -F 'if (-not $ListOnly)' "$SPOOF" >/dev/null \
    || fail "apply-gpu-spoof.ps1 的开头启用兜底必须避开 -ListOnly 只读模式"
grep -F "Enable-GpuSpoofDisplayDevices -Reason '浅层物理门禁通过后清理 Code 22'" \
        "$SPOOF" >/dev/null || fail "apply 没有在物理门禁后调用 Code 22 修复"
grep -F 'pnputil.exe /scan-devices' "$APPLY_SUPPORT" >/dev/null \
    || fail "apply support 没有使用非禁用式 PnP 扫描"
grep -F 'Get-PnpDevice -Class Display -PresentOnly' "$APPLY_SUPPORT" >/dev/null \
    || fail "AutoDetect 没有限制为当前实际存在的 Display 设备"
grep -F "'^PCI\\\\VEN_1AF4&DEV_1050&SUBSYS_" "$APPLY_SUPPORT" >/dev/null \
    || fail "AutoDetect 没有排除 RDP/非 stock Display 节点"
grep -F 'if ($gpuDevices.Count -ne 1)' "$APPLY_SUPPORT" >/dev/null \
    || fail "AutoDetect 没有对零个或多个物理 Display 节点 fail closed"

if grep -nE "Get-PnpDevice.*-Class[[:space:]]+'?Display'?.*-Status[[:space:]]+OK" "$APPLY_SUPPORT" >&2; then
    fail "Display 枚举不能限制为 -Status OK，否则 Code 22 设备会被漏掉"
fi

if grep -nF 'Disable-PnpDevice' "$SPOOF" "$APPLY_SUPPORT" >&2; then
    fail "apply 链不应再禁用显示适配器刷新 PnP"
fi

[[ -f "$RESTART_HELPER" ]] || fail "缺少 respawn 重启状态 helper"
grep -F 'function Enable-RespawnDisplayDevices' "$RESTART_HELPER" >/dev/null \
    || fail "respawn 重启状态 helper 缺少外层 Display 启用兜底"
grep -F 'Enable-PnpDevice -InstanceId' "$RESTART_HELPER" >/dev/null \
    || fail "respawn 重启状态 helper 没有实际调用 Enable-PnpDevice"
grep -F 'Code 22' "$RESTART_HELPER" >/dev/null \
    || fail "respawn 重启状态 helper 没有记录 Code 22 场景"
grep -F 'Enable-RespawnDisplayDevices' "$RESPAWN" >/dev/null \
    || fail "respawn 主流程没有调用拆分后的 Display 启用兜底"

echo "OK: guest-stealth PnP enable fallback checks passed"
