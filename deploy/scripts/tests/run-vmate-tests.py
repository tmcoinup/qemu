#!/usr/bin/env python3
"""并发执行 VMate 回归测试，并为每个用例保留独立、可读的日志。"""

from __future__ import annotations

import argparse
import asyncio
import os
import pathlib
import sys
import time
from dataclasses import dataclass


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent

# 快速集只包含不启动完整客机、不修改宿主网络且没有共享实例号的测试。完整集仍会
# 自动发现全部 test_*.sh/test_*.py，但改为串行，防止旧测试共用 /tmp socket 时互撞。
QUICK_TESTS = (
    "test_base_boot_storage.sh",
    "test_base_image_lifecycle.sh",
    "test_clone_output_permissions.sh",
    "test_build_host_helper_integration.sh",
    "test_build_dependency_auto_install.sh",
    "test_build_tooling_static.sh",
    "test_component_manifest.sh",
    "test_component_peripheral_catalog_exact.py",
    "test_cpu_asset_profile.sh",
    "test_cpu_helper_abi_prompt.sh",
    "test_cpu_pinner.py",
    "test_cpu_pinner_host_contract.py",
    "test_cpu_profile_mapping_contract.sh",
    "test_cpu_pinner_handshake.sh",
    "test_cpu_pinner_lifecycle.py",
    "test_strict_group_guard.py",
    "test_cpu_realize_preflight.sh",
    "test_ddr3_pool_matching.sh",
    "test_disk_capacity.sh",
    "test_finalize_clone_restart.sh",
    "test_signed_driver_package.py",
    "test_guest_hardware_snapshot_static.sh",
    "test_guest_chipset_registry_matrix.py",
    "test_guest_dnf_deps_exe_build.sh",
    "test_guest_gpu_identity_transaction.sh",
    "test_guest_gpu_manufacturer_projection.sh",
    "test_guest_monitor_edid_ownership.sh",
    "test_guest_monitor_identity_projection.sh",
    "test_guest_gpu_schema1_migration.sh",
    "test_guest_numlock_launcher.sh",
    "test_iso_boot_input_safety.sh",
    "test_guest_shallow_pci_identity.sh",
    "test_guest_shallow_pci_runtime_helpers.sh",
    "test_guest_gpu_hardware_id_projection.sh",
    "test_guest_gpu_projection_recovery.sh",
    "test_guest_stealth_display_mode.sh",
    "test_guest_stealth_exe_build.sh",
    "test_guest_stealth_chipset_install.sh",
    "test_guest_stealth_driver_install.sh",
    "test_guest_stealth_gpu_map.sh",
    "test_guest_stealth_adl_system.sh",
    "test_guest_nvapi_managed_cleanup.sh",
    "test_guest_stealth_nvapi_system.sh",
    "test_guest_stealth_power_policy.sh",
    "test_guest_stealth_payload_table.py",
    "test_guest_stealth_firstlogon_portable.sh",
    "test_guest_vendor_api_package.sh",
    "test_guest_vendor_api_removed_recovery.sh",
    "test_guest_vendor_api_same_vendor.sh",
    "test_guest_vendor_api_transaction.sh",
    "test_gpu_zerocopy_launcher.sh",
    "test_h310_supported_cpu_catalog.sh",
    "test_hardware_pool_catalog.sh",
    "test_hardware_serials.sh",
    "test_host_compatibility_platform.sh",
    "test_host_display_cache_guard.sh",
    "test_host_performance_ppd.sh",
    "test_household_compatibility_catalog.sh",
    "test_household_cross_generation_fallback.sh",
    "test_household_platform_selection.sh",
    "test_storage_compatibility_catalog.sh",
    "test_storage_aio_policy.sh",
    "test_storage_profile_migration.sh",
    "test_host_cpu_isolate_transaction.sh",
    "test_host_helper_install.sh",
    "test_kvm_capabilities.py",
    "test_linux_platform_argv.sh",
    "test_linux_component_selection.sh",
    "test_memory_topology.sh",
    "test_memory_speed_fidelity.sh",
    "test_legacy_memory_profile_migration.sh",
    "test_shared_memory_catalog.sh",
    "test_windows_memory_catalog.sh",
    "test_nvme_identity_profiles.sh",
    "test_nvapi_shim.sh",
    "test_nvapi_runtime_probe.sh",
    "test_adl_shim.sh",
    "test_ovmf_mmio64_window.sh",
    "test_platform_compatibility_cli.sh",
    "test_board_serial_runtime.sh",
    "test_board_vendor_policy.py",
    "test_windows_board_identity.sh",
    "test_platform_full_digest.py",
    "test_platform_manifest.sh",
    "test_platform_profile_registry_binding.sh",
    "test_profile_duplicate_keys.sh",
    "test_qemu_ptracer_launch.sh",
    "test_qemu_edid_component_profiles.sh",
    "test_sdl_gl_black_screen_static.sh",
    "test_sdl_keyboard_grab_static.sh",
    "test_sdl_pointer_mapping_static.sh",
    "test_setup_vlan_bridge.sh",
    "test_setup_vlan_autoonce.sh",
    "test_setup_vlan_bridge_contract.sh",
    "test_start_vm_bridge_preflight.sh",
    "test_soak_monitor.py",
    "test_start_vm_vlan_autosetup.sh",
    "test_stop_vm_instance_lock.sh",
    "test_tsc_policy.sh",
    "test_tpm_platform_adaptation.sh",
    "test_tpm_private_ca.sh",
    "test_tpm_reroll_safety.sh",
    "test_tpm_state_binding.sh",
    "test_windows_fb_shm_static.sh",
    "test_windows_gpu_sync_static.sh",
    "test_windows_extra_arguments.sh",
    "test_windows_platform_compatibility.sh",
    "test_windows_component_multibrand.sh",
    "test_windows_source_selection.sh",
    "test_windows_preflight_capabilities.sh",
    "test_windows_profile_identity_unique.sh",
    "test_windows_smbios_storage_preflight.sh",
    "test_windows_platform_static.sh",
    "test_xhci_identity_safety.sh",
)


@dataclass(frozen=True)
class TestResult:
    """单个子进程的稳定结果；日志延后按测试名排序输出。"""

    name: str
    returncode: int
    output: str
    elapsed_seconds: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="运行 VMate 启动器与硬件身份回归测试")
    parser.add_argument(
        "--mode",
        choices=("quick", "full"),
        default="quick",
        help="quick 并发运行安全单测；full 串行运行目录内所有测试",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=max(1, min(4, os.cpu_count() or 1)),
        help="quick 模式最大并发数（默认最多 4）",
    )
    return parser.parse_args()


def discover_tests(mode: str) -> list[pathlib.Path]:
    if mode == "quick":
        tests = [SCRIPT_DIR / name for name in QUICK_TESTS]
    else:
        tests = sorted(SCRIPT_DIR.glob("test_*.sh"))
        tests.extend(sorted(SCRIPT_DIR.glob("test_*.py")))
        # 测试调度器本身不是被测用例，否则会无限递归。
        tests = [path for path in tests if path.name != pathlib.Path(__file__).name]

    missing = [str(path) for path in tests if not path.is_file()]
    if missing:
        raise FileNotFoundError("以下测试不存在：" + ", ".join(missing))
    return tests


async def run_one(path: pathlib.Path, gate: asyncio.Semaphore) -> TestResult:
    """异步等待子进程，既限制并发，也不会阻塞状态输出或其它用例。"""

    command = ["bash", str(path)] if path.suffix == ".sh" else [sys.executable, str(path)]
    async with gate:
        started = time.monotonic()
        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=SCRIPT_DIR,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        output_bytes, _ = await process.communicate()
        elapsed = time.monotonic() - started
        return TestResult(
            name=path.name,
            returncode=process.returncode or 0,
            output=output_bytes.decode("utf-8", errors="replace"),
            elapsed_seconds=elapsed,
        )


async def async_main(args: argparse.Namespace) -> int:
    tests = discover_tests(args.mode)
    # full 模式刻意串行：部分历史集成测试沿用固定 /tmp 路径，不能安全并发。
    jobs = 1 if args.mode == "full" else max(1, args.jobs)
    gate = asyncio.Semaphore(jobs)
    print(f"VMate tests: mode={args.mode}, jobs={jobs}, cases={len(tests)}", flush=True)

    results = await asyncio.gather(*(run_one(path, gate) for path in tests))
    failures = 0
    for result in sorted(results, key=lambda item: item.name):
        state = "PASS" if result.returncode == 0 else "FAIL"
        print(f"[{state}] {result.name} ({result.elapsed_seconds:.2f}s)")
        if result.output.strip():
            print(result.output.rstrip())
        if result.returncode != 0:
            failures += 1

    print(f"VMate tests complete: passed={len(results) - failures}, failed={failures}")
    return 1 if failures else 0


def main() -> int:
    args = parse_args()
    if args.jobs < 1:
        print("ERROR: --jobs 必须大于 0", file=sys.stderr)
        return 2
    try:
        return asyncio.run(async_main(args))
    except (FileNotFoundError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
