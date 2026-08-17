#!/usr/bin/env python3
"""Regression tests for the G-11 NVIDIA NV_Modes registry policy."""

from __future__ import annotations

import hashlib
import importlib.util
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = REPO_ROOT / "deploy/lib/nvidia_modes.py"
HOST_HELPER = REPO_ROOT / "deploy/host/sync-monitor-cache.sh"
SYNC_WRAPPER = REPO_ROOT / "deploy/scripts/sync-monitor-profile.sh"
GUEST_HELPER = REPO_ROOT / "deploy/guest/spoof-monitor.ps1"

spec = importlib.util.spec_from_file_location("g11_nvidia_modes", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit(f"FAIL: cannot load {MODULE_PATH}")
modes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modes)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


expected = {
    (1920, 1080),
    (1600, 900),
    (1360, 768),
    (1280, 1024),
    (1280, 960),
    (1280, 768),
    (1280, 720),
    (1024, 768),
    (800, 600),
    (640, 480),
}
policy_set = set(modes.mode_set(modes.FHD_NV_MODES_POLICY))
require(policy_set == expected, f"policy mode set differs: {sorted(policy_set)}")
require((1600, 900) in policy_set, "1600x900 was lost")
require(not any(modes.is_16_10(mode) for mode in policy_set), "policy has 16:10")
require(len(policy_set) == 10, f"policy is not the reviewed 10-mode set: {policy_set}")

legacy_expected = expected | {
    (1600, 1200),
    (1600, 1024),
    (1440, 1080),
    (1366, 768),
    (1152, 864),
}
require(
    set(modes.mode_set(modes.LEGACY_FHD_NV_MODES_POLICY)) == legacy_expected,
    "reviewed legacy migration source changed",
)

source_set = set(modes.mode_set(modes.GRID_53833_NV_MODES))
removed = source_set - policy_set
require(
    {
        (1920, 1200),
        (1680, 1050),
        (1280, 800),
        (2560, 1600),
    }.issubset(removed),
    f"GRID 16:10 modes were not removed: {sorted(removed)}",
)
require(
    {(2048, 1536), (1920, 1440), (2560, 1440), (720, 480), (720, 576)}
    .issubset(removed),
    "above-FHD/TV modes were not removed",
)
require(
    {
        (1600, 1200),
        (1600, 1024),
        (1440, 1080),
        (1366, 768),
        (1152, 864),
    }.issubset(removed),
    "extra compatibility modes were not removed",
)

policy, changed = modes.locked_policy_for(modes.GRID_53833_NV_MODES)
require(changed and policy == modes.FHD_NV_MODES_POLICY, "source was not rewritten")
policy, changed = modes.locked_policy_for(modes.LEGACY_FHD_NV_MODES_POLICY)
require(changed and policy == modes.FHD_NV_MODES_POLICY,
        "reviewed legacy policy was not migrated")
policy, changed = modes.locked_policy_for(modes.FHD_NV_MODES_POLICY)
require(not changed and policy == modes.FHD_NV_MODES_POLICY, "policy is not idempotent")

encoded = modes.encode_reg_multi_sz(modes.FHD_NV_MODES_POLICY)
source_encoded = modes.encode_reg_multi_sz(modes.GRID_53833_NV_MODES)
require(
    hashlib.sha256(source_encoded).hexdigest()
    == "24d56a0eff18bbb52579822dc03bc740582e2a2e7eb2aeaa73262c0134a49ab8",
    "locked GRID 538.33 REG_MULTI_SZ bytes changed",
)
require(
    hashlib.sha256(encoded).hexdigest()
    == "f1eb560018991dfbe711341590a0b329fd3c03b977e953c4aa7db44bce37f8a2",
    "reviewed G-11 policy REG_MULTI_SZ bytes changed",
)
require(
    hashlib.sha256(
        modes.encode_reg_multi_sz(modes.LEGACY_FHD_NV_MODES_POLICY)
    ).hexdigest()
    == "1a23c1cb37c881fed5c7eed3f483a915ee35806eb86e50194d0000b1b5be7d14",
    "reviewed legacy G-11 migration source changed",
)
require(
    modes.decode_reg_multi_sz(encoded) == modes.FHD_NV_MODES_POLICY,
    "REG_MULTI_SZ round trip differs",
)
for malformed in (encoded[:-2], encoded + b"\x00", b"x\x00\x00"):
    try:
        modes.decode_reg_multi_sz(malformed)
    except modes.NvidiaModePolicyError:
        pass
    else:
        raise AssertionError("malformed REG_MULTI_SZ was accepted")

unknown_values = [
    modes.GRID_53833_NV_MODES + ("1440x900x8,16,32,64=1;",),
    (modes.FHD_NV_MODES_POLICY[0].replace("1600x900", "1600x1000"),),
    (modes.FHD_NV_MODES_POLICY[0].replace("=7FF", "=7FE"),),
]
for unknown in unknown_values:
    try:
        modes.locked_policy_for(unknown)
    except modes.NvidiaModePolicyError:
        pass
    else:
        raise AssertionError(f"unknown NV_Modes was overwritten: {unknown!r}")

host_text = HOST_HELPER.read_text(encoding="utf-8")
for required in (
    "DISPLAY_ADAPTER_CLASS_GUID",
    "NVIDIA_DISPLAY_SERVICE",
    "nvidia_driver_targets",
    "locked_policy_for",
    "Enum', 'PCI",
    "value(target, 'NV_Modes')",
    "NV_Modes 写后校验失败",
    "GRID_53833_DRIVER_VERSION",
    "GRID_53833_INF_SHA256",
    "verify_driver_package",
    "EXPECTED_NVIDIA_PNP_ID",
    r"PCI\VEN_10DE&DEV_1E30&SUBSYS_132610DE",
    "expected_enum_prefix",
    "legacy/非当前 B-native NVIDIA PnP 残留",
    "ProviderName",
    "DriverVersion",
    "InfPath",
    r"oem(?:0|[1-9][0-9]*)\.inf",
    "os.scandir(windows_inf_dir)",
    "(('Current', True), ('Default', False)",
    "('LastKnownGood', False)",
    "current_stats = control_set_stats[current_name.lower()]",
):
    require(required in host_text, f"host helper omits {required!r}")
require(
    "[cs, 'Control', 'Video'" not in host_text,
    "host helper scans Control\\Video instead of following Enum\\PCI Driver",
)
target_resolver = host_text.index("def nvidia_driver_targets(cs):")
pnp_guard = host_text.index("if not expected_device:", target_resolver)
driver_relation = host_text.index(
    "driver = reg_string(instance, 'Driver')", target_resolver)
require(
    pnp_guard < driver_relation,
    "host helper authenticates a stale NVIDIA Driver relation before the fixed B/native PnP guard",
)
require(
    "device_name_lower.startswith(expected_enum_prefix + '&')" in host_text,
    "host helper does not accept the fixed B/native endpoint's normal PCI suffixes",
)
require("'key': 'NV_R&T'" not in host_text,
        "host helper writes the NVIDIA timing restriction value")
require(".lower().startswith('controlset')" not in host_text,
        "host helper still scans loosely named/orphan ControlSets")
require("assert d[:4]" not in host_text,
        "SYSTEM hive validation disappears under PYTHONOPTIMIZE")
require("open(path, 'wb').write(d)" not in host_text,
        "SYSTEM hive fixup can truncate the hive during writeback")
require("WINDOWS_HIVE_VALIDATOR=" in host_text,
        "host helper does not define the shared primary-hive validator")
require(
    host_text.count('python3 "$WINDOWS_HIVE_VALIDATOR" "$HIVE"') == 2,
    "host helper does not run the shared validator before and after commit",
)
require("if off != len(d):" not in host_text,
        "host helper incorrectly requires hbins to cover physical hive slack")
require("eolp < actual_end" not in host_text,
        "host helper incorrectly compares regf Length with physical EOF")
require("sequence = max(pri, sec)" not in host_text,
        "host helper hides a dirty hive by synchronizing sequence numbers")
require("stream.write(d[:HBIN])" not in host_text,
        "host helper rewrites the base block during hive validation")

sync_text = SYNC_WRAPPER.read_text(encoding="utf-8")


def extract_shell_assignment(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}=([^\s]+)$", text, flags=re.MULTILINE)
    require(match is not None, f"cannot parse shell assignment {name}")
    return match.group(1)


require(
    extract_shell_assignment(sync_text, "GRID_53833_DRIVER_VERSION")
    == modes.GRID_53833_DRIVER_VERSION,
    "sync wrapper GRID driver version differs from host policy",
)
require(
    extract_shell_assignment(sync_text, "GRID_53833_INF_SHA256")
    == modes.GRID_53833_INF_SHA256,
    "sync wrapper GRID INF hash differs from host policy",
)
require(
    extract_shell_assignment(sync_text, "GRID_53833_CATALOG_SHA256")
    == modes.GRID_53833_CATALOG_SHA256,
    "sync wrapper GRID catalog hash differs from host policy",
)
require(
    extract_shell_assignment(host_text, "EXPECTED_DRIVER_VERSION")
    == f'"{modes.GRID_53833_DRIVER_VERSION}"',
    "host helper default driver version differs from policy",
)
require(
    extract_shell_assignment(host_text, "EXPECTED_DRIVER_INF_SHA256")
    == f'"{modes.GRID_53833_INF_SHA256}"',
    "host helper default INF hash differs from policy",
)

guest_text = GUEST_HELPER.read_text(encoding="utf-8")
for required in (
    "$NvidiaGrid53833NvModes",
    "$NvidiaFhdNvModesPolicy",
    "$NvidiaGrid53833ProviderNames",
    "$NvidiaGrid53833DriverVersion",
    "$NvidiaGrid53833InfSha256",
    "Set-NvidiaFhdModePolicy",
    "Get-PnpDevice -Class Display -PresentOnly",
    "-ine 'nvlddmkm'",
    "GetValueKind($identityName)",
    "[Microsoft.Win32.RegistryValueKind]::String",
    "[StringComparison]::OrdinalIgnoreCase",
    "$infPath -cnotmatch '^oem(?:0|[1-9][0-9]*)\\.inf$'",
    "Join-Path $env:SystemRoot 'INF'",
    "Get-FileHash -LiteralPath $publishedInf -Algorithm SHA256",
    "Refusing to overwrite unknown NV_Modes",
):
    require(required in guest_text, f"guest helper omits {required!r}")

# Keep the duplicated PowerShell payload byte-for-byte aligned with the Python
# policy.  Both arrays use simple single-quoted literals by design.
def extract_ps_array(name: str) -> tuple[str, ...]:
    match = re.search(
        rf"\${re.escape(name)}\s*=\s*\[string\[\]\]@\((.*?)\n\)",
        guest_text,
        flags=re.DOTALL,
    )
    require(match is not None, f"cannot parse PowerShell array {name}")
    return tuple(re.findall(r"'([^']*)'", match.group(1)))


require(
    extract_ps_array("NvidiaGrid53833NvModes") == modes.GRID_53833_NV_MODES,
    "PowerShell locked source differs from host policy",
)
require(
    extract_ps_array("NvidiaLegacyFhdNvModesPolicy")
    == modes.LEGACY_FHD_NV_MODES_POLICY,
    "PowerShell reviewed legacy migration source differs from host policy",
)
require(
    extract_ps_array("NvidiaFhdNvModesPolicy") == modes.FHD_NV_MODES_POLICY,
    "PowerShell FHD policy differs from host policy",
)


def extract_ps_string(name: str) -> str:
    match = re.search(
        rf"\${re.escape(name)}\s*=\s*'([^']*)'",
        guest_text,
    )
    require(match is not None, f"cannot parse PowerShell string {name}")
    return match.group(1)


require(
    extract_ps_string("NvidiaGrid53833DriverVersion")
    == modes.GRID_53833_DRIVER_VERSION,
    "PowerShell GRID driver version differs from host policy",
)
require(
    extract_ps_string("NvidiaGrid53833InfSha256")
    == modes.GRID_53833_INF_SHA256,
    "PowerShell GRID INF hash differs from host policy",
)
provider_match = re.search(
    r"\$NvidiaGrid53833ProviderNames\s*=\s*\[string\[\]\]@\(([^)]*)\)",
    guest_text,
)
require(provider_match is not None, "cannot parse PowerShell NVIDIA providers")
require(
    tuple(re.findall(r"'([^']*)'", provider_match.group(1)))
    == ("NVIDIA", "NVIDIA Corporation"),
    "PowerShell accepts an unexpected NVIDIA ProviderName",
)

# Every adapter's driver identity and published-INF hash must be authenticated
# in the all-target planning pass, before the first registry write.  This is
# what gives an identity/hash failure the zero-write behavior promised by the
# guest repair tool.
policy_function_match = re.search(
    r"function Set-NvidiaFhdModePolicy \{(.*?)\n\}",
    guest_text,
    flags=re.DOTALL,
)
require(policy_function_match is not None,
        "cannot parse Set-NvidiaFhdModePolicy")
policy_function = policy_function_match.group(1)
first_write = policy_function.find("Set-RegistryValue")
require(first_write >= 0, "NVIDIA policy function has no registry write")
for preflight in (
    "Assert-NvidiaFhdModePolicy $NvidiaFhdNvModesPolicy",
    "ConvertTo-NvModeCanonical $NvidiaLegacyFhdNvModesPolicy",
    "GetValueKind($identityName)",
    "$NvidiaGrid53833ProviderNames",
    "$NvidiaGrid53833DriverVersion",
    "$infPath -cnotmatch '^oem(?:0|[1-9][0-9]*)\\.inf$'",
    "Get-FileHash -LiteralPath $publishedInf -Algorithm SHA256",
    "$NvidiaGrid53833InfSha256",
    "GetValueKind('NV_Modes')",
    "Test-StringArrayEqual -Left $existingText -Right $legacyPolicyText",
    "Refusing to overwrite unknown NV_Modes",
):
    position = policy_function.find(preflight)
    require(position >= 0, f"NVIDIA policy preflight omits {preflight!r}")
    require(position < first_write,
            f"NVIDIA policy checks {preflight!r} only after a write")

main_policy_call = guest_text.rfind("$nvidiaModeTargets = Set-NvidiaFhdModePolicy")
main_edid_write = guest_text.rfind("Set-MonitorRegistry $edid $config")
require(main_policy_call >= 0 and main_edid_write >= 0,
        "cannot locate guest policy/EDID operations")
require(main_policy_call < main_edid_write,
        "guest EDID writes can occur before NVIDIA driver authentication")

print("OK: locked GRID 538.33/legacy NV_Modes -> 10-mode G-11 FHD policy")
