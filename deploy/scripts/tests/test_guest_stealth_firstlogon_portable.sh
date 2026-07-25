#!/usr/bin/env bash
# 验证 clone 首启 GPU 重对齐只在 OOBE 后执行 D 盘 EXE 一次，不依赖固定 host HTTP/IP。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
UNATTEND="$REPO_ROOT/deploy/autounattend/autounattend.xml"
CLONE="$REPO_ROOT/deploy/scripts/clone-from-base.sh"
CLONE_POSTPROCESS="$REPO_ROOT/deploy/scripts/lib/clone-postprocess.sh"
UNATTEND_INJECTOR="$REPO_ROOT/deploy/scripts/host-inject-unattend.sh"

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

reject_text() {
    local needle="$1"
    local file="$2"

    if grep -F -- "$needle" "$file" >/dev/null; then
        fail "unexpected '$needle' in $file"
    fi
}

require_text 'D:\工具\respawn-stealth.exe' "$UNATTEND"
require_text "--firstlogon" "$UNATTEND"
require_text '-Wait -PassThru' "$UNATTEND"
require_text '-PathType Leaf' "$UNATTEND"
require_text '-ErrorAction Stop' "$UNATTEND"
require_text 'if ($p.ExitCode -ne 0) { exit $p.ExitCode }' "$UNATTEND"
require_text 'exit 44' "$UNATTEND"
require_text 'exit 45' "$UNATTEND"
require_text 'exit 46' "$UNATTEND"
require_text 'sc.exe config AppXSvc start= demand' "$UNATTEND"
require_text 'sc.exe start AppXSvc &gt;nul 2&gt;&amp;1' "$UNATTEND"
require_text '[switch]$Unattended' "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
reject_text 'if (-not $NoReboot) { Read-Host' \
    "$REPO_ROOT/deploy/guest-stealth/respawn-stealth-local.ps1"
reject_text '192.168.30.33:8765/respawn-stealth.ps1' "$UNATTEND"
reject_text 'irm http://192.168.30.33:8765/respawn-stealth.ps1 | iex' "$UNATTEND"
reject_text 'C:\stealth\respawn-stealth-local.ps1' "$UNATTEND"
reject_text 'C:\stealth\respawn-firstlogon.log' "$UNATTEND"

reject_text 'serve-stealth-http.py' "$CLONE"
reject_text '让 guest FirstLogon 能拉 respawn-stealth.ps1' "$CLONE"
reject_text 'host-fix-gpu-devpkey.sh' "$CLONE"
require_text 'clone_postprocess_guest' "$CLONE"
require_text 'D:\\工具\\respawn-stealth.exe' "$CLONE_POSTPROCESS"
require_text '关键 ZDP' "$CLONE_POSTPROCESS"
reject_text 'host-fix-gpu-devpkey.sh' "$CLONE_POSTPROCESS"
reject_text 'ChildCompletion' "$UNATTEND_INJECTOR"
reject_text 'devpkey-prefixup.py' "$UNATTEND_INJECTOR"
reject_text 'import hivex' "$UNATTEND_INJECTOR"
reject_text '写 hive' "$CLONE"

python3 - "$UNATTEND" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()

def local_name(element):
    return element.tag.rsplit("}", 1)[-1]

def children(element, name):
    return [child for child in element if local_name(child) == name]

all_nodes = list(root.iter())
assert not [node for node in all_nodes
            if local_name(node) in {"SkipMachineOOBE", "SkipUserOOBE"}]

admin_passwords = [node for node in all_nodes
                   if local_name(node) == "AdministratorPassword"]
assert len(admin_passwords) == 1

auto_logons = [node for node in all_nodes if local_name(node) == "AutoLogon"]
assert len(auto_logons) == 1
usernames = children(auto_logons[0], "Username")
assert len(usernames) == 1 and usernames[0].text == "Administrator"

duplicate_admins = []
for account in (node for node in all_nodes if local_name(node) == "LocalAccount"):
    names = children(account, "Name")
    if len(names) == 1 and names[0].text == "Administrator":
        duplicate_admins.append(account)
assert not duplicate_admins

specialize_commands = []
for settings in (node for node in all_nodes if local_name(node) == "settings"):
    if not settings.attrib.get("pass") == "specialize":
        continue
    for command in (node for node in settings.iter()
                    if local_name(node) == "RunSynchronousCommand"):
        order = children(command, "Order")
        path = children(command, "Path")
        assert len(order) == 1 and len(path) == 1
        specialize_commands.append((order[0].text, path[0].text))
assert specialize_commands == [
    ("1", "sc.exe config AppXSvc start= demand"),
    ("2", 'cmd.exe /c "sc.exe start AppXSvc >nul 2>&1 & exit /b 0"'),
]
PY

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/vms/1"
touch "$TEST_TMP/vms/1/disk.qcow2"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "$VMS_DIR" == "$EXPECT_VMS_DIR" ]] || exit 90' \
    '[[ "$DISK" == "$EXPECT_DISK" && "$1" == 1 ]] || exit 91' \
    'exit "${INJECT_EXIT:-0}"' \
    >"$TEST_TMP/scripts/host-inject-unattend.sh"
chmod +x "$TEST_TMP/scripts/host-inject-unattend.sh"

# shellcheck disable=SC1090
source "$CLONE_POSTPROCESS"
export EXPECT_VMS_DIR="$TEST_TMP/vms"
export EXPECT_DISK="$TEST_TMP/vms/1/disk.qcow2"
export INJECT_EXIT=0
clone_postprocess_guest "$TEST_TMP/scripts" "$EXPECT_VMS_DIR" "$EXPECT_DISK" 1 \
    >/dev/null
[[ "$CLONE_POSTPROCESS_WARNINGS" == 0 ]] \
    || fail "successful answer-file injection reported a warning"

export INJECT_EXIT=7
clone_postprocess_guest "$TEST_TMP/scripts" "$EXPECT_VMS_DIR" "$EXPECT_DISK" 1 \
    >/dev/null
[[ "$CLONE_POSTPROCESS_WARNINGS" == 1 ]] \
    || fail "failed answer-file injection did not report exactly one warning"

chmod -x "$TEST_TMP/scripts/host-inject-unattend.sh"
clone_postprocess_guest "$TEST_TMP/scripts" "$EXPECT_VMS_DIR" "$EXPECT_DISK" 1 \
    >/dev/null
[[ "$CLONE_POSTPROCESS_WARNINGS" == 1 ]] \
    || fail "missing answer-file injector did not report exactly one warning"

clone_print_completion 1 "$EXPECT_DISK" base 1 "$EXPECT_VMS_DIR" \
    "$TEST_TMP/scripts" 4 qemu qemu-img 0 0 strict 1 >"$TEST_TMP/completion"
require_text 'host-inject-unattend.sh' "$TEST_TMP/completion"
require_text '下一步 — 先修复 OOBE 注入' "$TEST_TMP/completion"
reject_text '首次开机会按 unattend.xml 完成 OOBE' "$TEST_TMP/completion"

clone_print_completion 1 "$EXPECT_DISK" base 1 "$EXPECT_VMS_DIR" \
    "$TEST_TMP/scripts" 4 qemu qemu-img 0 0 strict 0 >"$TEST_TMP/completion-ok"
require_text '下一步 — 启动' "$TEST_TMP/completion-ok"
require_text '首次开机会按 unattend.xml 完成 OOBE' "$TEST_TMP/completion-ok"
reject_text 'STABLE_DISPLAY=' "$TEST_TMP/completion-ok"
reject_text '先修复 OOBE 注入' "$TEST_TMP/completion-ok"

echo "OK: guest stealth FirstLogon runs D drive EXE once without fixed HTTP"
