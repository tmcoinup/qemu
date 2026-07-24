#ifndef STEALTH_NVAPI_DRIVER_VERSION_H
#define STEALTH_NVAPI_DRIVER_VERSION_H

#include "nvapi_types.h"

/*
 * 填充 GPU-Z 2.70 兼容的驱动版本快照。该 helper 不依赖 Windows API，
 * 因而可由宿主测试直接覆盖；调用方仍负责在进入这里前验证 NVAPI 生命周期。
 */
NvAPI_Status nvapi_fill_driver_and_branch_version(
    NvU32 *version, char branch[NVAPI_SHORT_STRING_MAX]);

#endif
