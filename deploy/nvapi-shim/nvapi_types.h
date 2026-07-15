#ifndef STEALTH_NVAPI_TYPES_H
#define STEALTH_NVAPI_TYPES_H

/*
 * 这里只声明本 shim 实际使用的最小 NVAPI ABI，避免为了十几个入口把完整
 * NVIDIA SDK 复制进仓库。数值必须与 NVIDIA 公共头文件保持一致；调用约定由
 * 每个函数显式写成 __cdecl，尤其不能在 32 位构建中误用 __stdcall。
 */

#include <stdint.h>

typedef int32_t NvAPI_Status;
typedef uint32_t NvU32;
typedef void *NvPhysicalGpuHandle;
typedef void *NvLogicalGpuHandle;

/* NVIDIA 公共 nvapi_lite_common.h 中的稳定状态码。 */
#define NVAPI_OK                              ((NvAPI_Status)0)
#define NVAPI_ERROR                           ((NvAPI_Status)-1)
#define NVAPI_API_NOT_INITIALIZED             ((NvAPI_Status)-4)
#define NVAPI_INVALID_ARGUMENT                ((NvAPI_Status)-5)
#define NVAPI_NVIDIA_DEVICE_NOT_FOUND         ((NvAPI_Status)-6)
#define NVAPI_INCOMPATIBLE_STRUCT_VERSION     ((NvAPI_Status)-9)
#define NVAPI_HANDLE_INVALIDATED              ((NvAPI_Status)-10)
#define NVAPI_EXPECTED_LOGICAL_GPU_HANDLE     ((NvAPI_Status)-100)
#define NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE    ((NvAPI_Status)-101)
#define NVAPI_NOT_SUPPORTED                   ((NvAPI_Status)-104)

/* NVAPI 的短字符串和物理 GPU 数组大小都是公开 ABI 的固定值。 */
#define NVAPI_SHORT_STRING_MAX 64
#define NVAPI_MAX_PHYSICAL_GPUS 64
#define NVAPI_MAX_LOGICAL_GPUS 64

/* GPU-Z 使用的公开时钟 ABI：domain 0=核心、4=显存、7=处理器。 */
#define NVAPI_MAX_GPU_PUBLIC_CLOCKS 32
#define NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS 0u
#define NVAPI_GPU_PUBLIC_CLOCK_MEMORY 4u
#define NVAPI_GPU_PUBLIC_CLOCK_PROCESSOR 7u
#define NVAPI_GPU_PUBLIC_CLOCK_UNDEFINED NVAPI_MAX_GPU_PUBLIC_CLOCKS
#define NVAPI_CLOCK_TYPE_CURRENT 0u
#define NVAPI_CLOCK_TYPE_BASE 1u
#define NVAPI_CLOCK_TYPE_BOOST 2u

/*
 * P-States 2.0 的稳定 ABI 上限。GPU-Z 2.70 会先读取 P0 的可变核心范围，
 * 再决定是否采用 GetAllClockFrequencies 作为核心/显存时钟来源；因此只实现
 * 后一个入口会令显存时钟停留在低层寄存器探测失败后的 0 MHz。
 */
#define NVAPI_MAX_GPU_PSTATE20_PSTATES 16
#define NVAPI_MAX_GPU_PSTATE20_CLOCKS 8
#define NVAPI_MAX_GPU_PSTATE20_BASE_VOLTAGES 4
#define NVAPI_GPU_PERF_PSTATE_P0 0u
#define NVAPI_GPU_PSTATE20_CLOCK_TYPE_SINGLE 0u
#define NVAPI_GPU_PSTATE20_CLOCK_TYPE_RANGE 1u
#define NVAPI_GPU_VOLTAGE_DOMAIN_CORE 0u

struct nvapi_clock_domain {
    NvU32 presence;
    NvU32 frequency_khz;
};

struct nvapi_clock_frequencies {
    NvU32 version;
    NvU32 clock_type_and_reserved;
    struct nvapi_clock_domain domain[NVAPI_MAX_GPU_PUBLIC_CLOCKS];
};

/* MAKE_NVAPI_VERSION(struct, n) 的低 16 位是结构大小，高 16 位是版本。 */
#define NVAPI_CLOCK_FREQUENCIES_VERSION_1 \
    ((NvU32)sizeof(struct nvapi_clock_frequencies) | (UINT32_C(1) << 16))
#define NVAPI_CLOCK_FREQUENCIES_VERSION_2 \
    ((NvU32)sizeof(struct nvapi_clock_frequencies) | (UINT32_C(2) << 16))
#define NVAPI_CLOCK_FREQUENCIES_VERSION_3 \
    ((NvU32)sizeof(struct nvapi_clock_frequencies) | (UINT32_C(3) << 16))

/* P-States 2.0 结构由 nvapi_gpu_pstates.h 声明，这里只固定接口编号。 */
#define NVAPI_ID_GPU_GET_PSTATES20 UINT32_C(0x6FF81213)

/* NV_GPU_BUS_TYPE 中 3 才是 PCI Express；4 表示 FPCI。 */
#define NVAPI_GPU_BUS_TYPE_PCI_EXPRESS 3u

/*
 * QueryInterface ID 来自 NVIDIA 官方 nvapi_interface.h。BusType 与 BusId
 * 的编号外观非常接近，必须使用具名常量，避免再次把两个不同签名的函数绑反。
 */
#define NVAPI_ID_GPU_GET_BUS_TYPE UINT32_C(0x1BB18724)
#define NVAPI_ID_GPU_GET_BUS_ID   UINT32_C(0x1BE0B8E5)

/* 本轮型号细节所需的公开/历史 NVAPI QueryInterface 编号。 */
#define NVAPI_ID_GPU_GET_VBIOS_REVISION       UINT32_C(0xACC3DA0A)
#define NVAPI_ID_GPU_GET_VBIOS_OEM_REVISION   UINT32_C(0x2D43FB31)
#define NVAPI_ID_GPU_GET_VBIOS_VERSION_STRING UINT32_C(0xA561FD7D)
#define NVAPI_ID_GPU_GET_RAM_TYPE             UINT32_C(0x57F7CAAC)
#define NVAPI_ID_GPU_GET_RAM_BUS_WIDTH        UINT32_C(0x7975C581)
#define NVAPI_ID_GPU_GET_FB_WIDTH_LOCATION    UINT32_C(0x11104158)
#define NVAPI_ID_GPU_GET_PERF_CLOCKS          UINT32_C(0x1EA54A3B)
#define NVAPI_ID_GPU_GET_LEGACY_ALL_CLOCKS    UINT32_C(0x1BD69F49)
#define NVAPI_ID_GPU_GET_ALL_CLOCKS           UINT32_C(0xDCB616C3)
#define NVAPI_ID_ENUM_LOGICAL_GPUS             UINT32_C(0x48B3EA59)
#define NVAPI_ID_LOGICAL_FROM_PHYSICAL         UINT32_C(0xADD604D1)
#define NVAPI_ID_PHYSICAL_FROM_LOGICAL         UINT32_C(0xAEA3FA32)
#define NVAPI_ID_GPU_GET_CONNECTED_OUTPUTS     UINT32_C(0x1730BFC9)
#define NVAPI_ID_GPU_GET_CONNECTED_SLI_OUTPUTS UINT32_C(0x0680DE09)

#endif
