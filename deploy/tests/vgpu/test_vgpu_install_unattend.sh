#!/usr/bin/env bash
# Validate the root vGPU install answer file semantically, then prove the ISO
# builder publishes it at the removable-media root as Autounattend.xml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEMPLATE="$REPO_ROOT/deploy/autounattend/autounattend.xml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

python3 - "$TEMPLATE" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
root = ET.fromstring(text)
ns = {"u": "urn:schemas-microsoft-com:unattend"}

def settings(name):
    found = root.findall(f"u:settings[@pass='{name}']", ns)
    assert len(found) == 1, (name, len(found))
    return found[0]

def component(parent, name):
    found = [
        item for item in parent.findall("u:component", ns)
        if item.attrib.get("name") == name
    ]
    assert len(found) == 1, (name, len(found))
    return found[0]

# A valid windowsPE pass makes Setup cache the answer for specialize/OOBE.  It
# must force the normal product-key UI without supplying an edition-selecting
# key of its own.
windows_pe_setup = component(settings("windowsPE"), "Microsoft-Windows-Setup")
user_data = windows_pe_setup.find("u:UserData", ns)
assert user_data is not None
assert user_data.findtext("u:AcceptEula", namespaces=ns) == "true"
product_key = user_data.find("u:ProductKey", ns)
assert product_key is not None
assert product_key.find("u:Key", ns) is None
assert product_key.findtext("u:WillShowUI", namespaces=ns) == "Always"
assert [node.tag.rsplit("}", 1)[-1] for node in product_key] == ["WillShowUI"]

specialize_shell = component(settings("specialize"), "Microsoft-Windows-Shell-Setup")
assert specialize_shell.findtext("u:ComputerName", namespaces=ns) == "__COMPUTER_NAME__"
assert specialize_shell.findtext("u:TimeZone", namespaces=ns) == "China Standard Time"

oobe_shell = component(settings("oobeSystem"), "Microsoft-Windows-Shell-Setup")
assert oobe_shell.findtext("u:TimeZone", namespaces=ns) == "China Standard Time"
oobe = oobe_shell.find("u:OOBE", ns)
assert oobe is not None
for key in (
    "HideEULAPage",
    "HideOEMRegistrationScreen",
    "HideOnlineAccountScreens",
    "HideLocalAccountScreen",
    "HideWirelessSetupInOOBE",
):
    assert oobe.findtext(f"u:{key}", namespaces=ns) == "true", key
assert oobe.findtext("u:ProtectYourPC", namespaces=ns) == "3"

admin = oobe_shell.find("u:UserAccounts/u:AdministratorPassword", ns)
assert admin is not None
assert admin.find("u:Value", ns).text in (None, "")
assert admin.findtext("u:PlainText", namespaces=ns) == "true"
assert oobe_shell.find("u:UserAccounts/u:LocalAccounts", ns) is None

auto = oobe_shell.find("u:AutoLogon", ns)
assert auto is not None
assert auto.findtext("u:Username", namespaces=ns) == "Administrator"
assert auto.findtext("u:Enabled", namespaces=ns) == "true"
assert int(auto.findtext("u:LogonCount", namespaces=ns)) > 0
assert auto.find("u:Password/u:Value", ns).text in (None, "")
assert auto.findtext("u:Password/u:PlainText", namespaces=ns) == "true"

# Disk layout, target disk, and Windows edition must remain manual choices.
element_names = {
    node.tag.rsplit("}", 1)[-1].lower()
    for node in root.iter()
}
for forbidden in (
    "key",
    "diskconfiguration",
    "imageinstall",
    "installfrom",
    "installto",
    "createpartitions",
    "modifypartitions",
    "willwipedisk",
    "skipmachineoobe",
    "skipuseroobe",
):
    assert forbidden not in element_names, forbidden

# No activation secret, remote-management exposure, downloads, or persistent
# scripts/tasks are allowed in this minimal OOBE answer file.
lower = "\n".join(root.itertext()).lower()
for forbidden in (
    "123456",
    "powershell",
    "http://",
    "https://",
    "winrm",
    "remote desktop",
    "schtasks",
):
    assert forbidden not in lower, forbidden

# The only one-shot commands set NumLock for the sign-in desktop and the
# built-in Administrator profile. RTC is owned entirely by the host launcher;
# no script, registry override, or task is installed in Windows.
commands = [
    node.text or ""
    for node in root.findall(".//u:Path", ns) + root.findall(".//u:CommandLine", ns)
]
assert len(commands) == 2, commands
numlock_commands = [
    command for command in commands
    if "InitialKeyboardIndicators" in command
]
assert len(numlock_commands) == 2, numlock_commands
assert any("HKU\\.DEFAULT" in command for command in numlock_commands)
assert any("HKCU\\Control Panel\\Keyboard" in command for command in numlock_commands)
assert all(" /d 2 /f" in command for command in numlock_commands)

assert all("RealTimeIsUniversal" not in command for command in commands)
PY

command -v xorriso >/dev/null 2>&1 || fail "xorriso is required"
# shellcheck source=../../lib/windows-unattend.sh
source "$REPO_ROOT/deploy/lib/windows-unattend.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
ISO="$TMP_DIR/answer.iso"
EXTRACTED="$TMP_DIR/Autounattend.xml"
windows_unattend_build_iso "$TEMPLATE" "$ISO" DESKTOP-A1B2C3D
[[ -s "$ISO" ]] || fail "answer ISO was not created"
[[ "$(stat -c %a "$ISO")" == 600 ]] || fail "answer ISO must be mode 0600"
xorriso -osirrox on -indev "$ISO" -extract /Autounattend.xml "$EXTRACTED" \
    >/dev/null 2>&1
grep -F '<ComputerName>DESKTOP-A1B2C3D</ComputerName>' "$EXTRACTED" \
    >/dev/null || fail "rendered computer name is missing"
if grep -Fq '__COMPUTER_NAME__' "$EXTRACTED"; then
    fail "rendered answer file retained its placeholder"
fi

echo "PASS: minimal vGPU install OOBE/timezone/NumLock answer ISO"
