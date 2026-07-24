#!/usr/bin/env bash
# 验证硬件池显示器清单、只改 FriendlyName 的投影器及统一 EXE 接线。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CATALOG="$REPO_ROOT/deploy/hardware/components.json"
EXPORTER="$REPO_ROOT/deploy/scripts/export-monitor-device-manifest.py"
PROJECT_SCRIPT="$REPO_ROOT/deploy/guest-stealth/project-monitor-identity.ps1"
PROJECTOR="$REPO_ROOT/deploy/guest-stealth/launcher/monitor-friendly-name-projector.c"
RESPAWN="$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
BUILD_SCRIPT="$REPO_ROOT/deploy/guest-stealth/build-exe.sh"
PACKAGE_SCRIPT="$REPO_ROOT/deploy/guest-stealth/package.sh"
LAUNCHER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-launcher.c"
PAYLOADS_HEADER="$REPO_ROOT/deploy/guest-stealth/launcher/respawn-stealth-payloads.h"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for file in "$CATALOG" "$EXPORTER" "$PROJECT_SCRIPT" "$PROJECTOR" \
        "$RESPAWN" "$BUILD_SCRIPT" "$PACKAGE_SCRIPT" "$LAUNCHER"; do
    [[ -f "$file" ]] || fail "缺少文件: $file"
done
for bounded_file in "$EXPORTER" "$PROJECT_SCRIPT" "$PROJECTOR" "$RESPAWN" \
        "$LAUNCHER" "$0"; do
    [[ "$(wc -l < "$bounded_file")" -le 500 ]] \
        || fail "显示器实现或入口超过 500 行: $bounded_file"
done

python3 "$EXPORTER" --catalog "$CATALOG" \
    --output "$TMP_DIR/monitor-identities.json"

# 导出清单必须与 components.json 中所有 enabled monitor 一一对应；测试不写死四款，
# 后续扩池时缺 windows_friendly_name 或漏打包会直接失败。
python3 - "$CATALOG" "$TMP_DIR/monitor-identities.json" <<'PY'
import json
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
assert manifest["schema_version"] == 1
expected = {}
for item in catalog["monitors"]:
    if not item.get("enabled", False):
        continue
    code = item["vendor_code"] + item["product_id"][2:].upper()
    expected[item["id"]] = {
        "component_id": item["id"],
        "pnp_code": code,
        "hardware_id": "MONITOR\\" + code,
        "instance_prefix": "DISPLAY\\" + code + "\\",
        "friendly_name": item["windows_friendly_name"],
    }
actual = {item["component_id"]: item for item in manifest["monitors"]}
assert actual == expected, (actual, expected)
assert len({item["pnp_code"] for item in actual.values()}) == len(actual)
PY

# 重复 PnP ID 和控制字符名称都必须在生成阶段失败，不能把歧义留给管理员客体。
python3 - "$CATALOG" "$TMP_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys

catalog_path = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])
exporter = catalog_path.parents[1] / "scripts" / "export-monitor-device-manifest.py"
base = json.loads(catalog_path.read_text(encoding="utf-8"))
cases = []
duplicate = json.loads(json.dumps(base))
duplicate["monitors"][1]["vendor_code"] = duplicate["monitors"][0]["vendor_code"]
duplicate["monitors"][1]["product_id"] = duplicate["monitors"][0]["product_id"]
cases.append(duplicate)
control = json.loads(json.dumps(base))
control["monitors"][0]["windows_friendly_name"] = "bad\nname"
cases.append(control)
for index, case in enumerate(cases):
    source = tmp / f"bad-{index}.json"
    output = tmp / f"bad-{index}-out.json"
    source.write_text(json.dumps(case), encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(exporter), "--catalog", str(source),
         "--output", str(output)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert result.returncode != 0, index
    assert not output.exists(), index
PY

PS_FILES="$PROJECT_SCRIPT:$RESPAWN" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $failed = $false
    foreach ($path in $env:PS_FILES -split [IO.Path]::PathSeparator) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        foreach ($item in $errors) {
            [Console]::Error.WriteLine("{0}: {1}", $path, $item.Message)
        }
        if ($errors.Count -gt 0) { $failed = $true }
    }
    if ($failed) { exit 1 }
' || fail "PowerShell AST 解析失败"

# 单独加载 manifest 纯函数，在 Linux PowerShell 上验证运行时 schema 门禁。
EXPECTED_MONITOR_COUNT="$(
    jq '[.monitors[] | select(.enabled == true)] | length' "$CATALOG"
)" PROJECT_SCRIPT="$PROJECT_SCRIPT" MANIFEST="$TMP_DIR/monitor-identities.json" \
pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $source = [IO.File]::ReadAllText($env:PROJECT_SCRIPT)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $source, [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Read-MonitorManifest"
    }, $true)
    if ($null -eq $definition) { throw "缺少 Read-MonitorManifest" }
    . ([scriptblock]::Create($definition.Extent.Text))
    $entries = @(Read-MonitorManifest -Path $env:MANIFEST)
    if ($entries.Count -ne [int]$env:EXPECTED_MONITOR_COUNT -or
        @($entries.pnp_code | Sort-Object -Unique).Count -ne $entries.Count) {
        throw "运行时 manifest 解析结果异常"
    }
' || fail "运行时显示器 manifest 门禁失败"

x86_64-w64-mingw32-gcc \
    -std=c11 -Wall -Wextra -Werror -O2 -municode -mconsole \
    -static -static-libgcc -Wl,--no-insert-timestamp \
    "$PROJECTOR" -lsetupapi -lcfgmgr32 \
    -o "$TMP_DIR/monitor-friendly-name-projector.exe"
file "$TMP_DIR/monitor-friendly-name-projector.exe" |
    grep -F 'PE32+ executable' >/dev/null ||
    fail "显示器投影器不是 x64 PE"

for contract in GUID_DEVCLASS_MONITOR SPDRP_HARDWAREID \
        CM_Set_DevNode_PropertyW k_device_friendly_name DEVPROP_TYPE_EMPTY \
        --clear; do
    grep -F -- "$contract" "$PROJECTOR" >/dev/null \
        || fail "C 投影器缺少契约: $contract"
done
[[ "$(grep -c '^static const DEVPROPKEY ' "$PROJECTOR")" -eq 1 ]] ||
    fail "C 投影器声明了 FriendlyName 之外的可写设备属性"
if grep -E 'k_device_description|SPDRP_(DRIVER|CLASS)|Device_HardwareIds' \
        "$PROJECTOR" >/dev/null; then
    fail "C 投影器触碰了 FriendlyName 之外的显示器身份"
fi

for contract in \
        'Get-PnpDevice -Class Monitor -PresentOnly' \
        "'DEVPKEY_Device_HardwareIds'" \
        "'DEVPKEY_Device_FriendlyName'" \
        "'DEVPKEY_NAME'" \
        'Assert-ProtectedMonitorStateUnchanged' \
        "'StealthGPU-ProjectMonitorIdentity'" \
        'New-ScheduledTaskTrigger -AtStartup' \
        'New-ScheduledTaskTrigger -AtLogOn' \
        '-StartWhenAvailable -MultipleInstances Queue' \
        'Remove-MonitorProjectionTaskVerified' \
        'Restore-MonitorFriendlyName' \
        'Export-ScheduledTask'; do
    grep -F -- "$contract" "$PROJECT_SCRIPT" >/dev/null \
        || fail "PowerShell 投影缺少契约: $contract"
done
if grep -E '\\$matches[[:space:]]*=' \
        "$PROJECT_SCRIPT" >/dev/null; then
    fail '显示器脚本覆盖了 PowerShell 自动变量 $Matches'
fi

projection_line="$(grep -n -- '-File $monitorScript -RegisterTask' "$RESPAWN" |
    cut -d: -f1)"
gpu_finalize_line="$(grep -n '^    Invoke-GpuProjectionFinalization ' "$RESPAWN" |
    cut -d: -f1)"
[[ -n "$projection_line" && -n "$gpu_finalize_line" &&
   "$projection_line" -gt "$gpu_finalize_line" ]] ||
    fail "显示器名称投影没有位于 GPU/驱动就绪之后"

while read -r payload symbol; do
    grep -F "$payload" "$BUILD_SCRIPT" >/dev/null ||
        fail "构建脚本没有生成 payload: $payload"
    grep -F "#include \"payload_${symbol}.h\"" "$PAYLOADS_HEADER" >/dev/null ||
        fail "payload 表没有包含生成头: $payload"
    grep -F "{ L\"$payload\", payload_${symbol}," "$PAYLOADS_HEADER" >/dev/null ||
        fail "payload 表没有释放文件: $payload"
    grep -F "$payload" "$PACKAGE_SCRIPT" >/dev/null ||
        fail "legacy 调试包没有复制文件: $payload"
done <<'EOF'
project-monitor-identity.ps1 project_monitor_identity_ps1
monitor-identities.json monitor_identities_json
monitor-friendly-name-projector.exe monitor_friendly_name_projector_exe
EOF

echo "OK: guest monitor identity projection checks passed"
