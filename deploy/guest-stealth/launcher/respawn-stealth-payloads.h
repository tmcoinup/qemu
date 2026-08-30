#ifndef RESPAWN_STEALTH_PAYLOADS_H
#define RESPAWN_STEALTH_PAYLOADS_H

#include "payload-security.h"
#include "payload_respawn_ps1.h"
#include "payload_respawn_restart_state_ps1.h"
#include "payload_configure_power_policy_ps1.h"
#include "payload_apply_gpu_spoof_ps1.h"
#include "payload_gpu_spoof_apply_support_ps1.h"
#include "payload_gpu_board_identity_contract_ps1.h"
#include "payload_persist_gpu_profile_ps1.h"
#include "payload_gpu_profile_transaction_ps1.h"
#include "payload_gpu_profile_registry_core_ps1.h"
#include "payload_refresh_gpu_name_ps1.h"
#include "payload_gpu_manufacturer_projection_ps1.h"
#include "payload_gpu_manufacturer_projector_exe.h"
#include "payload_gpu_hardware_id_plan_ps1.h"
#include "payload_gpu_hardware_id_transaction_ps1.h"
#include "payload_project_gpu_hardware_id_ps1.h"
#include "payload_force_displayfreq_ps1.h"
#include "payload_project_monitor_identity_ps1.h"
#include "payload_monitor_identities_json.h"
#include "payload_monitor_friendly_name_projector_exe.h"
#include "payload_install_display_driver_ps1.h"
#include "payload_display_driver_trust_ps1.h"
#include "payload_install_chipset_device_ps1.h"
#include "payload_install_nvapi_system_ps1.h"
#include "payload_nvapi_system_validation_ps1.h"
#include "payload_nvapi_system_transaction_ps1.h"
#include "payload_install_adl_system_ps1.h"
#include "payload_adl_system_transaction_ps1.h"
#include "payload_install_gpu_api_system_ps1.h"
#include "payload_gpu_api_identity_binding_ps1.h"
#include "payload_viogpudo_sys.h"
#include "payload_viogpudo_cat.h"
#include "payload_viogpudo_inf.h"
#include "payload_cannonlake_hsystem_inf.h"
#include "payload_cannonlake_h_cat.h"
#include "payload_sunrisepoint_hsystem_inf.h"
#include "payload_sunrisepoint_h_cat.h"
#include "payload_cougarpoint_system_inf.h"
#include "payload_cougarpoint_cat.h"
#include "payload_pantherpoint_system_inf.h"
#include "payload_pantherpoint_cat.h"
#include "payload_patsburg_system_inf.h"
#include "payload_patsburg_cat.h"
#include "payload_lynxpoint_system_inf.h"
#include "payload_lynxpoint_cat.h"
#include "payload_nvapi_x86_dll.h"
#include "payload_nvapi_x64_dll.h"
#include "payload_nvapi_runtime_probe_x86_exe.h"
#include "payload_nvapi_runtime_probe_x64_exe.h"
#include "payload_adl_x86_dll.h"
#include "payload_adl_x64_dll.h"

/*
 * 所有运行依赖都从一个 EXE 释放。把生成头与发布表集中在本文件，可让 launcher
 * 主流程保持紧凑，并为新增签名硬件包预留独立扩展点。
 */
static const EmbeddedPayload embedded_payloads[] = {
    { L"respawn-stealth-local.ps1", payload_respawn_ps1, (DWORD)sizeof(payload_respawn_ps1) },
    { L"respawn-restart-state.ps1", payload_respawn_restart_state_ps1, (DWORD)sizeof(payload_respawn_restart_state_ps1) },
    { L"configure-power-policy.ps1", payload_configure_power_policy_ps1, (DWORD)sizeof(payload_configure_power_policy_ps1) },
    { L"apply-gpu-spoof.ps1", payload_apply_gpu_spoof_ps1, (DWORD)sizeof(payload_apply_gpu_spoof_ps1) },
    { L"gpu-spoof-apply-support.ps1", payload_gpu_spoof_apply_support_ps1, (DWORD)sizeof(payload_gpu_spoof_apply_support_ps1) },
    { L"gpu-board-identity-contract.ps1", payload_gpu_board_identity_contract_ps1, (DWORD)sizeof(payload_gpu_board_identity_contract_ps1) },
    { L"persist-gpu-profile.ps1", payload_persist_gpu_profile_ps1, (DWORD)sizeof(payload_persist_gpu_profile_ps1) },
    { L"gpu-profile-transaction.ps1", payload_gpu_profile_transaction_ps1, (DWORD)sizeof(payload_gpu_profile_transaction_ps1) },
    { L"gpu-profile-registry-core.ps1", payload_gpu_profile_registry_core_ps1, (DWORD)sizeof(payload_gpu_profile_registry_core_ps1) },
    { L"refresh-gpu-name.ps1", payload_refresh_gpu_name_ps1, (DWORD)sizeof(payload_refresh_gpu_name_ps1) },
    { L"gpu-manufacturer-projection.ps1", payload_gpu_manufacturer_projection_ps1, (DWORD)sizeof(payload_gpu_manufacturer_projection_ps1) },
    { L"gpu-manufacturer-projector.exe", payload_gpu_manufacturer_projector_exe, (DWORD)sizeof(payload_gpu_manufacturer_projector_exe) },
    { L"gpu-hardware-id-plan.ps1", payload_gpu_hardware_id_plan_ps1, (DWORD)sizeof(payload_gpu_hardware_id_plan_ps1) },
    { L"gpu-hardware-id-transaction.ps1", payload_gpu_hardware_id_transaction_ps1, (DWORD)sizeof(payload_gpu_hardware_id_transaction_ps1) },
    { L"project-gpu-hardware-id.ps1", payload_project_gpu_hardware_id_ps1, (DWORD)sizeof(payload_project_gpu_hardware_id_ps1) },
    { L"force-displayfreq.ps1", payload_force_displayfreq_ps1, (DWORD)sizeof(payload_force_displayfreq_ps1) },
    { L"project-monitor-identity.ps1", payload_project_monitor_identity_ps1, (DWORD)sizeof(payload_project_monitor_identity_ps1) },
    { L"monitor-identities.json", payload_monitor_identities_json, (DWORD)sizeof(payload_monitor_identities_json) },
    { L"monitor-friendly-name-projector.exe", payload_monitor_friendly_name_projector_exe, (DWORD)sizeof(payload_monitor_friendly_name_projector_exe) },
    { L"install-display-driver.ps1", payload_install_display_driver_ps1, (DWORD)sizeof(payload_install_display_driver_ps1) },
    { L"display-driver-trust.ps1", payload_display_driver_trust_ps1, (DWORD)sizeof(payload_display_driver_trust_ps1) },
    { L"install-chipset-device.ps1", payload_install_chipset_device_ps1, (DWORD)sizeof(payload_install_chipset_device_ps1) },
    { L"install-nvapi-system.ps1", payload_install_nvapi_system_ps1, (DWORD)sizeof(payload_install_nvapi_system_ps1) },
    { L"nvapi-system-validation.ps1", payload_nvapi_system_validation_ps1, (DWORD)sizeof(payload_nvapi_system_validation_ps1) },
    { L"nvapi-system-transaction.ps1", payload_nvapi_system_transaction_ps1, (DWORD)sizeof(payload_nvapi_system_transaction_ps1) },
    { L"install-adl-system.ps1", payload_install_adl_system_ps1, (DWORD)sizeof(payload_install_adl_system_ps1) },
    { L"adl-system-transaction.ps1", payload_adl_system_transaction_ps1, (DWORD)sizeof(payload_adl_system_transaction_ps1) },
    { L"install-gpu-api-system.ps1", payload_install_gpu_api_system_ps1, (DWORD)sizeof(payload_install_gpu_api_system_ps1) },
    { L"gpu-api-identity-binding.ps1", payload_gpu_api_identity_binding_ps1, (DWORD)sizeof(payload_gpu_api_identity_binding_ps1) },
    { L"viogpudo.sys", payload_viogpudo_sys, (DWORD)sizeof(payload_viogpudo_sys) },
    { L"viogpudo.cat", payload_viogpudo_cat, (DWORD)sizeof(payload_viogpudo_cat) },
    { L"viogpudo.inf", payload_viogpudo_inf, (DWORD)sizeof(payload_viogpudo_inf) },
    { L"CannonLake-HSystem.inf", payload_cannonlake_hsystem_inf, (DWORD)sizeof(payload_cannonlake_hsystem_inf) },
    { L"cannonlake-h.cat", payload_cannonlake_h_cat, (DWORD)sizeof(payload_cannonlake_h_cat) },
    { L"SunrisePoint-HSystem.inf", payload_sunrisepoint_hsystem_inf, (DWORD)sizeof(payload_sunrisepoint_hsystem_inf) },
    { L"sunrisepoint-h.cat", payload_sunrisepoint_h_cat, (DWORD)sizeof(payload_sunrisepoint_h_cat) },
    { L"CougarPointSystem.inf", payload_cougarpoint_system_inf, (DWORD)sizeof(payload_cougarpoint_system_inf) },
    { L"cougarpoint.cat", payload_cougarpoint_cat, (DWORD)sizeof(payload_cougarpoint_cat) },
    { L"PantherPointSystem.inf", payload_pantherpoint_system_inf, (DWORD)sizeof(payload_pantherpoint_system_inf) },
    { L"pantherpoint.cat", payload_pantherpoint_cat, (DWORD)sizeof(payload_pantherpoint_cat) },
    { L"PatsburgSystem.inf", payload_patsburg_system_inf, (DWORD)sizeof(payload_patsburg_system_inf) },
    { L"patsburg.cat", payload_patsburg_cat, (DWORD)sizeof(payload_patsburg_cat) },
    { L"LynxPointSystem.inf", payload_lynxpoint_system_inf, (DWORD)sizeof(payload_lynxpoint_system_inf) },
    { L"lynxpoint.cat", payload_lynxpoint_cat, (DWORD)sizeof(payload_lynxpoint_cat) },
    { L"nvapi.dll", payload_nvapi_x86_dll, (DWORD)sizeof(payload_nvapi_x86_dll) },
    { L"nvapi64.dll", payload_nvapi_x64_dll, (DWORD)sizeof(payload_nvapi_x64_dll) },
    { L"nvapi-runtime-probe-x86.exe", payload_nvapi_runtime_probe_x86_exe, (DWORD)sizeof(payload_nvapi_runtime_probe_x86_exe) },
    { L"nvapi-runtime-probe-x64.exe", payload_nvapi_runtime_probe_x64_exe, (DWORD)sizeof(payload_nvapi_runtime_probe_x64_exe) },
    { L"atiadlxy.dll", payload_adl_x86_dll, (DWORD)sizeof(payload_adl_x86_dll) },
    { L"atiadlxx32.dll", payload_adl_x86_dll, (DWORD)sizeof(payload_adl_x86_dll) },
    { L"atiadlxx.dll", payload_adl_x64_dll, (DWORD)sizeof(payload_adl_x64_dll) },
};

#endif
