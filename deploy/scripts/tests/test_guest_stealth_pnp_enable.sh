#!/usr/bin/env bash
# 验证 guest-stealth 的 PnP 收尾逻辑会修复 Code 22，并且不会再主动禁用显示适配器。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPOOF="$REPO_ROOT/deploy/scripts/apply-gpu-spoof.ps1"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -F 'function Enable-StealthDisplayDevices' "$SPOOF" >/dev/null \
    || fail "apply-gpu-spoof.ps1 缺少 Display 设备自动启用函数"
grep -F 'function Test-StealthDisplayNeedsEnable' "$SPOOF" >/dev/null \
    || fail "apply-gpu-spoof.ps1 缺少 Code 22/禁用态判断函数"
grep -E 'Code 22|CM_PROB_DISABLED' "$SPOOF" >/dev/null \
    || fail "apply-gpu-spoof.ps1 没有显式处理设备管理器 Code 22"
grep -F 'if (-not $ListOnly)' "$SPOOF" >/dev/null \
    || fail "apply-gpu-spoof.ps1 的开头启用兜底必须避开 -ListOnly 只读模式"
grep -F 'pnputil.exe /scan-devices' "$SPOOF" >/dev/null \
    || fail "apply-gpu-spoof.ps1 没有使用非禁用式 PnP 扫描"
grep -F 'Get-PnpDevice -Class Display -PresentOnly' "$SPOOF" >/dev/null \
    || fail "AutoDetect 没有限制为当前实际存在的 Display 设备"
grep -F "'^PCI\\\\VEN_1AF4&DEV_1050&SUBSYS_" "$SPOOF" >/dev/null \
    || fail "AutoDetect 没有排除 RDP/非 stock Display 节点"
grep -F 'if ($gpuDevices.Count -ne 1)' "$SPOOF" >/dev/null \
    || fail "AutoDetect 没有对零个或多个物理 Display 节点 fail closed"

if grep -nE "Get-PnpDevice.*-Class[[:space:]]+'?Display'?.*-Status[[:space:]]+OK" "$SPOOF" >&2; then
    fail "Display 枚举不能限制为 -Status OK，否则 Code 22 设备会被漏掉"
fi

if grep -nF 'Disable-PnpDevice' "$SPOOF" >&2; then
    fail "apply-gpu-spoof.ps1 不应再禁用显示适配器刷新 PnP"
fi

grep -F 'function Enable-RespawnDisplayDevices' "$RESPAWN" >/dev/null \
    || fail "respawn-stealth-local.ps1 缺少外层 Display 启用兜底"
grep -F 'Enable-PnpDevice -InstanceId' "$RESPAWN" >/dev/null \
    || fail "respawn-stealth-local.ps1 没有实际调用 Enable-PnpDevice"
grep -F 'Code 22' "$RESPAWN" >/dev/null \
    || fail "respawn-stealth-local.ps1 没有记录 Code 22 场景"

echo "OK: guest-stealth PnP enable fallback checks passed"
