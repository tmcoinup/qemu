#ifndef STEALTH_ADL_TYPES_H
#define STEALTH_ADL_TYPES_H

/*
 * AMD Display Library 的最小公开 ABI 子集。
 *
 * 结构布局来自 AMD 官方 display-library SDK（MIT），这里只保留本兼容层会实际
 * 读写的字段，避免把整套 SDK 头文件及无关接口带入客体发布物。所有导出均使用
 * C 调用约定；只有内存分配回调按官方 ABI 使用 __stdcall。
 */
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define ADL_CALLBACK __stdcall
#else
#define ADL_CALLBACK
#endif

#define ADL_OK 0
#define ADL_OK_WARNING 1
#define ADL_ERR (-1)
#define ADL_ERR_NOT_INIT (-2)
#define ADL_ERR_INVALID_PARAM (-3)
#define ADL_ERR_INVALID_PARAM_SIZE (-4)
#define ADL_ERR_INVALID_ADL_IDX (-5)
#define ADL_ERR_NOT_SUPPORTED (-8)
#define ADL_ERR_NULL_POINTER (-9)
#define ADL_ERR_INVALID_CALLBACK (-11)

#define ADL_MAX_PATH 256
#define ADL_VENDOR_ID_AMD 1002
#define ADL_ASIC_DISCRETE (1 << 0)
#define ADL_GRAPHIC_CORE_GENERATION_GCN 2
/*
 * ADL2_Main_ControlX3_Create 的公开 sample 定义：bit 0 允许把驱动版本不兼容
 * 的 AMD 设备仍视作 AMD。其余位未有可依赖的公开语义，兼容层必须拒绝。
 */
#define ADL_CREATE_OPTIONS_DEFAULT 0
#define ADL_CREATE_OPTIONS_INTERPRET_INCOMPATIBLE_DRIVER_VERSION_AS_SUPPORTED \
    (1 << 0)
#define ADL_CREATE_OPTIONS_SUPPORTED_MASK \
    ADL_CREATE_OPTIONS_INTERPRET_INCOMPATIBLE_DRIVER_VERSION_AS_SUPPORTED

typedef void *ADL_CONTEXT_HANDLE;
typedef void *(ADL_CALLBACK *ADL_MAIN_MALLOC_CALLBACK)(int);

/* AMD 官方 ADLThreadingModel：X2/X3 初始化入口使用的枚举 ABI。 */
typedef enum ADLThreadingModel {
    ADL_THREADING_UNLOCKED = 0,
    ADL_THREADING_LOCKED = 1
} ADLThreadingModel;

typedef struct AdapterInfo {
    int iSize;
    int iAdapterIndex;
    char strUDID[ADL_MAX_PATH];
    int iBusNumber;
    int iDeviceNumber;
    int iFunctionNumber;
    int iVendorID;
    char strAdapterName[ADL_MAX_PATH];
    char strDisplayName[ADL_MAX_PATH];
    int iPresent;
    int iExist;
    char strDriverPath[ADL_MAX_PATH];
    char strDriverPathExt[ADL_MAX_PATH];
    char strPNPString[ADL_MAX_PATH];
    int iOSDisplayIndex;
} AdapterInfo;

/*
 * 官方 AdapterInfoX2 在 Windows 上扩展 AdapterInfo 的末尾两个 capability
 * 字段；不能把它当成任意大小的 AdapterInfo 缓冲区复用。
 */
typedef struct AdapterInfoX2 {
    int iSize;
    int iAdapterIndex;
    char strUDID[ADL_MAX_PATH];
    int iBusNumber;
    int iDeviceNumber;
    int iFunctionNumber;
    int iVendorID;
    char strAdapterName[ADL_MAX_PATH];
    char strDisplayName[ADL_MAX_PATH];
    int iPresent;
    int iExist;
    char strDriverPath[ADL_MAX_PATH];
    char strDriverPathExt[ADL_MAX_PATH];
    char strPNPString[ADL_MAX_PATH];
    int iOSDisplayIndex;
    int iInfoMask;
    int iInfoValue;
} AdapterInfoX2;

/* ADL graphics version APIs 的官方固定长度输出结构。 */
typedef struct ADLVersionsInfo {
    char strDriverVer[ADL_MAX_PATH];
    char strCatalystVersion[ADL_MAX_PATH];
    char strCatalystWebLink[ADL_MAX_PATH];
} ADLVersionsInfo;

typedef struct ADLVersionsInfoX2 {
    char strDriverVer[ADL_MAX_PATH];
    char strCatalystVersion[ADL_MAX_PATH];
    char strCrimsonVersion[ADL_MAX_PATH];
    char strCatalystWebLink[ADL_MAX_PATH];
} ADLVersionsInfoX2;

typedef struct ADLMemoryInfo {
    int64_t iMemorySize;
    char strMemoryType[ADL_MAX_PATH];
    int64_t iMemoryBandwidth;
} ADLMemoryInfo;

typedef struct ADLMemoryInfo2 {
    int64_t iMemorySize;
    char strMemoryType[ADL_MAX_PATH];
    int64_t iMemoryBandwidth;
    int64_t iHyperMemorySize;
    int64_t iInvisibleMemorySize;
    int64_t iVisibleMemorySize;
} ADLMemoryInfo2;

typedef struct ADLMemoryInfo3 {
    int64_t iMemorySize;
    char strMemoryType[ADL_MAX_PATH];
    int64_t iMemoryBandwidth;
    int64_t iHyperMemorySize;
    int64_t iInvisibleMemorySize;
    int64_t iVisibleMemorySize;
    int64_t iVramVendorRevId;
} ADLMemoryInfo3;

typedef struct ADLGraphicCoreInfo {
    int iGCGen;
    union {
        int iNumCUs;
        int iNumWGPs;
    } core_count;
    union {
        int iNumPEsPerCU;
        int iNumPEsPerWGP;
    } pe_count;
    int iNumSIMDs;
    int iNumROPs;
    int iReserved[11];
} ADLGraphicCoreInfo;

typedef struct ADLBiosInfo {
    char strPartNumber[ADL_MAX_PATH];
    char strVersion[ADL_MAX_PATH];
    char strDate[ADL_MAX_PATH];
} ADLBiosInfo;

typedef struct ADLPMActivity {
    int iSize;
    int iEngineClock;
    int iMemoryClock;
    int iVddc;
    int iActivityPercent;
    int iCurrentPerformanceLevel;
    int iCurrentBusSpeed;
    int iCurrentBusLanes;
    int iMaximumBusLanes;
    int iReserved;
} ADLPMActivity;

typedef struct ADLODParameterRange {
    int iMin;
    int iMax;
    int iStep;
} ADLODParameterRange;

typedef struct ADLODParameters {
    int iSize;
    int iNumberOfPerformanceLevels;
    int iActivityReportingSupported;
    int iDiscretePerformanceLevels;
    int iReserved;
    ADLODParameterRange sEngineClock;
    ADLODParameterRange sMemoryClock;
    ADLODParameterRange sVddc;
} ADLODParameters;

typedef struct ADLODPerformanceLevel {
    int iEngineClock;
    int iMemoryClock;
    int iVddc;
} ADLODPerformanceLevel;

typedef struct ADLODPerformanceLevels {
    int iSize;
    int iReserved;
    ADLODPerformanceLevel aLevels[1];
} ADLODPerformanceLevels;

typedef struct ADLODNParameterRange {
    int iMode;
    int iMin;
    int iMax;
    int iStep;
    int iDefault;
} ADLODNParameterRange;

typedef struct ADLODNCapabilities {
    int iMaximumNumberOfPerformanceLevels;
    ADLODNParameterRange sEngineClockRange;
    ADLODNParameterRange sMemoryClockRange;
    ADLODNParameterRange svddcRange;
    ADLODNParameterRange power;
    ADLODNParameterRange powerTuneTemperature;
    ADLODNParameterRange fanTemperature;
    ADLODNParameterRange fanSpeed;
    ADLODNParameterRange minimumPerformanceClock;
} ADLODNCapabilities;

typedef struct ADLODNCapabilitiesX2 {
    int iMaximumNumberOfPerformanceLevels;
    int iFlags;
    ADLODNParameterRange sEngineClockRange;
    ADLODNParameterRange sMemoryClockRange;
    ADLODNParameterRange svddcRange;
    ADLODNParameterRange power;
    ADLODNParameterRange powerTuneTemperature;
    ADLODNParameterRange fanTemperature;
    ADLODNParameterRange fanSpeed;
    ADLODNParameterRange minimumPerformanceClock;
    ADLODNParameterRange throttleNotificaion;
    ADLODNParameterRange autoSystemClock;
} ADLODNCapabilitiesX2;

typedef struct ADLODNPerformanceLevel {
    int iClock;
    int iVddc;
    int iEnabled;
} ADLODNPerformanceLevel;

typedef struct ADLODNPerformanceLevels {
    int iSize;
    int iMode;
    int iNumberOfPerformanceLevels;
    ADLODNPerformanceLevel aLevels[1];
} ADLODNPerformanceLevels;

typedef struct ADLODNPerformanceLevelX2 {
    int iClock;
    int iVddc;
    int iEnabled;
    int iControl;
} ADLODNPerformanceLevelX2;

typedef struct ADLODNPerformanceLevelsX2 {
    int iSize;
    int iMode;
    int iNumberOfPerformanceLevels;
    ADLODNPerformanceLevelX2 aLevels[1];
} ADLODNPerformanceLevelsX2;

typedef struct ADLODNPerformanceStatus {
    int iCoreClock;
    int iMemoryClock;
    int iDCEFClock;
    int iGFXClock;
    int iUVDClock;
    int iVCEClock;
    int iGPUActivityPercent;
    int iCurrentCorePerformanceLevel;
    int iCurrentMemoryPerformanceLevel;
    int iCurrentDCEFPerformanceLevel;
    int iCurrentGFXPerformanceLevel;
    int iUVDPerformanceLevel;
    int iVCEPerformanceLevel;
    int iCurrentBusSpeed;
    int iCurrentBusLanes;
    int iMaximumBusLanes;
    int iVDDC;
    int iVDDCI;
} ADLODNPerformanceStatus;

typedef struct ADLCrossfireComb {
    int iNumLinkAdapter;
    int iAdaptLink[3];
} ADLCrossfireComb;

typedef struct ADLCrossfireInfo {
    int iErrorCode;
    int iState;
    int iSupported;
} ADLCrossfireInfo;

/* 锁定 GPU-Z 实际使用的公开 ABI 大小，防止编译器选项改变布局。 */
_Static_assert(sizeof(AdapterInfo) == 0x624u, "AdapterInfo ABI");
_Static_assert(sizeof(AdapterInfoX2) == 0x62cu, "AdapterInfoX2 ABI");
_Static_assert(sizeof(ADLVersionsInfo) == 0x300u, "VersionsInfo ABI");
_Static_assert(sizeof(ADLVersionsInfoX2) == 0x400u,
               "VersionsInfoX2 ABI");
_Static_assert(sizeof(ADLMemoryInfo) == 0x110u, "ADLMemoryInfo ABI");
_Static_assert(sizeof(ADLMemoryInfo3) == 0x130u, "ADLMemoryInfo3 ABI");
_Static_assert(sizeof(ADLGraphicCoreInfo) == 0x40u, "GraphicCore ABI");
_Static_assert(sizeof(ADLBiosInfo) == 0x300u, "ADLBiosInfo ABI");
_Static_assert(ADL_VENDOR_ID_AMD == 1002, "ADL AMD decimal vendor ABI");

#endif
