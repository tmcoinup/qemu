/*
 * 不依赖 Windows API 的 PCI 标识组合函数。
 *
 * 单独成文件后，DLL 和宿主机原生单元测试会编译完全相同的实现，防止测试只检查
 * 一份手写期望值，却没有覆盖实际交付代码。
 */

#include "nvapi_identity.h"

NvU32 nvapi_pack_pci_identifier(NvU32 device_id, NvU32 vendor_id)
{
    return ((device_id & 0xffffu) << 16) | (vendor_id & 0xffffu);
}
