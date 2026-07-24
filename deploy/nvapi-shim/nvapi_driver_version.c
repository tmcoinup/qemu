#include <stddef.h>
#include <string.h>

#include "nvapi_driver_version.h"

/*
 * GPU-Z 2.70 把此查询失败当作旧版驱动路径，并会继续调用本投影层没有承诺的
 * display-handle 接口。返回与既有兼容基线一致的版本，可让它留在公开 NVAPI
 * 查询路径；这里仅描述兼容快照，不宣称客体装有真实 NVIDIA 显示驱动。
 */
NvAPI_Status nvapi_fill_driver_and_branch_version(
    NvU32 *version, char branch[NVAPI_SHORT_STRING_MAX])
{
    static const char compat_branch[] = "r545_99";

    if (version == NULL || branch == NULL) {
        return NVAPI_INVALID_ARGUMENT;
    }

    *version = UINT32_C(54633);
    memset(branch, 0, NVAPI_SHORT_STRING_MAX);
    memcpy(branch, compat_branch, sizeof(compat_branch));
    return NVAPI_OK;
}
