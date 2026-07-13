#!/usr/bin/env bash
# 验证 RAM/DIMM/通道/槽位组合约束。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../lib/stealth-memory-topology.sh
source "$REPO_ROOT/deploy/scripts/lib/stealth-memory-topology.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 被测函数按变量名读取拓扑输入；导出让静态检查和潜在子进程语义一致。
export RAM=8192
export MEM_ALLOWED_TOTAL_MB="2048,4096,8192"
export MEM_MODULE_MB="2048,4096"
export MEM_CHANNELS=2
export BOARD_DIMM_SLOTS=4
export MEM_MAX_CAPACITY_MB=65536
stealth_resolve_memory_topology
[[ "$NUM_DIMMS" == "2" && "$PER_DIMM_MB" == "4096" ]] \
    || fail "8GiB 应解析成 2x4GiB"
[[ "$T16_NUM_DEVICES" == "4" && "$T16_MAX_CAPACITY" == "65536M" ]] \
    || fail "Type16 应反映主板四槽和最大容量"

RAM=4096
stealth_resolve_memory_topology
[[ "$NUM_DIMMS" == "1" && "$PER_DIMM_MB" == "4096" ]] \
    || fail "4GiB 应与 SMBIOS/SPD chunk 对齐为 1x4GiB"

RAM=6144
if stealth_resolve_memory_topology >/dev/null 2>&1; then
    fail "manifest 未允许 6GiB 时必须拒绝"
fi

export RAM=8192
export MEM_ALLOWED_TOTAL_MB="8192"
export MEM_MODULE_MB="3072,4096"
export MEM_CHANNELS=1
if stealth_resolve_memory_topology >/dev/null 2>&1; then
    fail "不存在 8GiB module 时不得伪造单条"
fi

echo "PASS: memory topology"
