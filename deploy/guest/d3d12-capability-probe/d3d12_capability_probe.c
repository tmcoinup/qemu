#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <dxgi1_2.h>
#include <d3d12.h>

#include <stdio.h>
#include <string.h>

static void description_utf8(const WCHAR *source, char *target, size_t size)
{
    int converted;

    if (size == 0) {
        return;
    }
    converted = WideCharToMultiByte(CP_UTF8, 0, source, -1, target,
                                    (int)size, NULL, NULL);
    if (converted <= 0) {
        strncpy(target, "<description-unavailable>", size - 1);
        target[size - 1] = '\0';
    }
}

static const char *yes_no(BOOL value)
{
    return value ? "yes" : "no";
}

int main(int argc, char **argv)
{
    IDXGIFactory1 *factory = NULL;
    HRESULT hr;
    UINT index;
    int require_tier_zero = 0;
    int nvidia_seen = 0;
    int nvidia_query_ok = 0;
    int nvidia_nonzero = 0;

    if (argc == 2 && strcmp(argv[1], "--require-tier-zero") == 0) {
        require_tier_zero = 1;
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [--require-tier-zero]\n", argv[0]);
        return 64;
    }

    hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    if (FAILED(hr)) {
        printf("D3D12_NATIVE_VERIFY FAIL stage=create-factory hr=0x%08lX\n",
               (unsigned long)hr);
        return 3;
    }

    for (index = 0; ; ++index) {
        IDXGIAdapter1 *adapter = NULL;
        DXGI_ADAPTER_DESC1 desc;
        ID3D12Device *device = NULL;
        D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5;
        HRESULT create_hr;
        HRESULT options_hr = E_FAIL;
        char description[512];

        hr = IDXGIFactory1_EnumAdapters1(factory, index, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        if (FAILED(hr)) {
            printf("D3D12_ADAPTER index=%u enumerate_hr=0x%08lX\n",
                   index, (unsigned long)hr);
            continue;
        }

        memset(&desc, 0, sizeof(desc));
        hr = IDXGIAdapter1_GetDesc1(adapter, &desc);
        if (FAILED(hr)) {
            printf("D3D12_ADAPTER index=%u describe_hr=0x%08lX\n",
                   index, (unsigned long)hr);
            IDXGIAdapter1_Release(adapter);
            continue;
        }

        description_utf8(desc.Description, description, sizeof(description));
        create_hr = D3D12CreateDevice((IUnknown *)adapter,
                                      D3D_FEATURE_LEVEL_11_0,
                                      &IID_ID3D12Device,
                                      (void **)&device);
        memset(&options5, 0, sizeof(options5));
        if (SUCCEEDED(create_hr)) {
            options_hr = ID3D12Device_CheckFeatureSupport(
                device, D3D12_FEATURE_D3D12_OPTIONS5,
                &options5, sizeof(options5));
        }

        printf("D3D12_ADAPTER index=%u vendor=%04X device=%04X subsystem=%08lX "
               "revision=%02X software=%s description=\"%s\" "
               "create_hr=0x%08lX options5_hr=0x%08lX "
               "raytracing_tier=%u raytracing_supported=%s\n",
               index, desc.VendorId, desc.DeviceId,
               (unsigned long)desc.SubSysId, desc.Revision,
               yes_no((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0),
               description, (unsigned long)create_hr,
               (unsigned long)options_hr,
               SUCCEEDED(options_hr) ? (unsigned int)options5.RaytracingTier : 0,
               yes_no(SUCCEEDED(options_hr) &&
                      options5.RaytracingTier !=
                          D3D12_RAYTRACING_TIER_NOT_SUPPORTED));

        if (desc.VendorId == 0x10DE &&
            (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0) {
            nvidia_seen = 1;
            if (SUCCEEDED(options_hr)) {
                nvidia_query_ok = 1;
                if (options5.RaytracingTier !=
                    D3D12_RAYTRACING_TIER_NOT_SUPPORTED) {
                    nvidia_nonzero = 1;
                }
            }
        }

        if (device != NULL) {
            ID3D12Device_Release(device);
        }
        IDXGIAdapter1_Release(adapter);
    }

    IDXGIFactory1_Release(factory);

    if (!nvidia_seen || !nvidia_query_ok) {
        printf("D3D12_NATIVE_VERIFY FAIL nvidia_seen=%s options5_query_ok=%s\n",
               yes_no(nvidia_seen), yes_no(nvidia_query_ok));
        return 3;
    }
    if (require_tier_zero && nvidia_nonzero) {
        printf("D3D12_NATIVE_VERIFY FAIL expected_raytracing_tier=0 "
               "native_raytracing_nonzero=yes\n");
        return 2;
    }

    printf("D3D12_NATIVE_VERIFY PASS nvidia_seen=yes options5_query_ok=yes "
           "native_raytracing_nonzero=%s\n", yes_no(nvidia_nonzero));
    return 0;
}
