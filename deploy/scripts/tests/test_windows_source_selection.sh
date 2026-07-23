#!/usr/bin/env bash
# 执行 Windows 源头部件显式选择、随机池、稳定 profile 绑定与扩容回归。
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
test_script="$script_dir/test_windows_source_selection.ps1"
launcher="$repo_root/deploy/windows/start-vm.ps1"

shell_bin="$(command -v pwsh || command -v powershell || true)"
if [[ -z "$shell_bin" ]]; then
    echo "PASS: PowerShell unavailable; Windows source selection test skipped"
    exit 0
fi

"$shell_bin" -NoLogo -NoProfile -NonInteractive -File "$test_script" \
    -RepoRoot "$repo_root"

for parameter in MemoryId StorageId GpuId MonitorId; do
    grep -F "[string]\$$parameter = ''" "$launcher" >/dev/null
done

while IFS= read -r file; do
    lines="$(wc -l <"$file")"
    [[ "$lines" -le 500 ]] || {
        echo "FAIL: Windows PowerShell file exceeds 500 lines: $file ($lines)" >&2
        exit 1
    }
done < <(find "$repo_root/deploy/windows" -type f -name '*.ps1' -print)

echo 'PASS: Windows source selection wrapper'
