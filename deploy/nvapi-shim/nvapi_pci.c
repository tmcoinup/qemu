/*
 * 不依赖 Windows API 的 PCI 标识组合函数。
 *
 * 单独成文件后，DLL 和宿主机原生单元测试会编译完全相同的实现，防止测试只检查
 * 一份手写期望值，却没有覆盖实际交付代码。
 */

#include "nvapi_identity.h"

#define VIRTIO_GPU_CARRIER_VENDOR_ID UINT32_C(0x1af4)
#define VIRTIO_GPU_CARRIER_DEVICE_ID UINT32_C(0x1050)

NvU32 nvapi_pack_pci_identifier(NvU32 device_id, NvU32 vendor_id)
{
    return ((device_id & 0xffffu) << 16) | (vendor_id & 0xffffu);
}

/*
 * 主键用于把 NVAPI 结果与 Windows 唯一的 PNPDeviceID/BDF 载体归并，必须保持
 * 1AF4:1050；型号由 external device、逻辑 subsystem/revision 以及其它标准接口
 * 返回。这样鲁大师等多源工具不会把同一 devnode 拆成 Red Hat + NVIDIA 两块卡。
 */
void nvapi_build_carrier_pci_identifiers(
    const struct nvapi_gpu_identity *identity, NvU32 *device_id,
    NvU32 *subsystem_id, NvU32 *revision_id, NvU32 *external_device_id)
{
    *device_id = nvapi_pack_pci_identifier(VIRTIO_GPU_CARRIER_DEVICE_ID,
                                            VIRTIO_GPU_CARRIER_VENDOR_ID);
    *subsystem_id = nvapi_pack_pci_identifier(
        identity->subsystem_device_id, identity->subsystem_vendor_id);
    *revision_id = identity->revision_id;
    *external_device_id = identity->pci_device_id;
}
