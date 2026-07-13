/*
 * fb-shm 跨平台 GPU sideband 导出。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Linux 接受已有 QemuDmaBuf，或在 SDL 确实使用 EGL
 * 且扩展齐全时把当前 GL texture 导出为 dma-buf。
 * Windows 接受 SDL/ANGLE 传入的 D3D11 texture，
 * 创建命名 NT shared handle。任何失败都安静返回 false，
 * 由调用方继续 SHM。
 */

#include "qemu/osdep.h"
#include "ui/fb-shm-gpu.h"
#include "ui/dmabuf.h"

#if defined(CONFIG_OPENGL) && defined(CONFIG_GBM) && !defined(_WIN32)
#include "ui/egl-helpers.h"
#include "standard-headers/drm/drm_fourcc.h"
#endif

#ifdef _WIN32
#include <windows.h>
#ifdef CONFIG_OPENGL
#include <d3d11.h>
#include <dxgi1_2.h>
#endif
#endif

struct FbShmGpuBackend {
    char *display_id;
    uint64_t frame_seq;
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    ID3D11Texture2D *d3d_texture;
    IDXGIKeyedMutex *d3d_mutex;
    HANDLE d3d_handle;
    char *d3d_name;
    uint32_t d3d_generation;
    uint32_t d3d_width;
    uint32_t d3d_height;
    uint32_t d3d_stride;
    uint32_t d3d_fourcc;
    bool d3d_key0_owned;
#endif
};

static void fb_shm_gpu_export_init(FbShmGpuExport *out)
{
    memset(out, 0, sizeof(*out));
    out->fd = -1;
}

FbShmGpuBackend *fb_shm_gpu_backend_new(const char *display_id)
{
    FbShmGpuBackend *backend = g_new0(FbShmGpuBackend, 1);

    backend->display_id = g_strdup(display_id && *display_id ?
                                   display_id : "default");
    return backend;
}

void fb_shm_gpu_backend_reset(FbShmGpuBackend *backend)
{
    if (!backend) {
        return;
    }

#if defined(_WIN32) && defined(CONFIG_OPENGL)
    if (backend->d3d_handle) {
        CloseHandle(backend->d3d_handle);
        backend->d3d_handle = NULL;
    }
    g_clear_pointer(&backend->d3d_name, g_free);
    if (backend->d3d_mutex) {
        /* mutex 和 texture 的 COM 引用分别释放。 */
        backend->d3d_mutex->lpVtbl->Release(backend->d3d_mutex);
        backend->d3d_mutex = NULL;
    }
    if (backend->d3d_texture) {
        /*
         * prepare 成功后持有一份 COM 引用，防止 virgl
         * 切换资源前纹理地址被复用，导致仅按裸指针比较时
         * 错误沿用上一份 shared handle。
         */
        backend->d3d_texture->lpVtbl->Release(backend->d3d_texture);
        backend->d3d_texture = NULL;
    }
    backend->d3d_width = 0;
    backend->d3d_height = 0;
    backend->d3d_stride = 0;
    backend->d3d_fourcc = 0;
    backend->d3d_key0_owned = false;
#endif
}

void fb_shm_gpu_backend_free(FbShmGpuBackend *backend)
{
    if (!backend) {
        return;
    }

    fb_shm_gpu_backend_reset(backend);
    g_free(backend->display_id);
    g_free(backend);
}

#if defined(_WIN32) && defined(CONFIG_OPENGL)
static char *fb_shm_gpu_safe_id(const char *id)
{
    char *safe = g_strdup(id && *id ? id : "default");

    for (char *p = safe; *p; p++) {
        if (!g_ascii_isalnum(*p) && *p != '-' && *p != '_') {
            *p = '_';
        }
    }
    return safe;
}

static char *fb_shm_gpu_d3d_name(FbShmGpuBackend *backend)
{
    g_autofree char *safe_id = fb_shm_gpu_safe_id(backend->display_id);
    unsigned long process_id = (unsigned long)GetCurrentProcessId();

    backend->d3d_generation++;
    /*
     * Local namespace 不隔离先后启动的 QEMU。
     * 名称加入 PID，避免新旧 handle 冲突。
     */
    return g_strdup_printf("Local\\qemu-fb-shm-%lu-%s-d3d-%u",
                           process_id, safe_id, backend->d3d_generation);
}

static bool fb_shm_gpu_d3d_format(DXGI_FORMAT format, uint32_t *fourcc)
{
    switch (format) {
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        *fourcc = FB_SHM_FOURCC_BGRA;
        return true;
    case DXGI_FORMAT_B8G8R8X8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
        *fourcc = FB_SHM_FOURCC_BGR0;
        return true;
    default:
        /*
         * ABI 没有可无损表达该 DXGI 像素布局的 fourcc，
         * 直接回退 SHM。
         */
        return false;
    }
}

static bool fb_shm_gpu_d3d_create_handle(ID3D11Texture2D *texture,
                                          const char *name,
                                          HANDLE *handle)
{
    IDXGIResource1 *resource = NULL;
    g_autofree gunichar2 *wide_name = NULL;
    HRESULT hr;

    wide_name = g_utf8_to_utf16(name, -1, NULL, NULL, NULL);
    if (!wide_name) {
        return false;
    }

    hr = texture->lpVtbl->QueryInterface(texture, &IID_IDXGIResource1,
                                         (void **)&resource);
    if (FAILED(hr)) {
        return false;
    }

    /*
     * consumer 虽只读像素，仍要用 ReleaseSync(0) 归还。
     * 微软 NT-handle 示例因此授予 READ|WRITE；
     * 只给 READ 可能让跨设备归还失败。
     */
    hr = resource->lpVtbl->CreateSharedHandle(
        resource, NULL,
        DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
        (LPCWSTR)wide_name, handle);
    resource->lpVtbl->Release(resource);
    return SUCCEEDED(hr) && *handle;
}

static IDXGIKeyedMutex *
fb_shm_gpu_d3d_query_mutex(ID3D11Texture2D *texture)
{
    IDXGIKeyedMutex *mutex = NULL;
    HRESULT hr;

    hr = texture->lpVtbl->QueryInterface(texture, &IID_IDXGIKeyedMutex,
                                         (void **)&mutex);
    if (FAILED(hr)) {
        return NULL;
    }
    return mutex;
}
#endif

bool fb_shm_gpu_backend_set_d3d_texture(FbShmGpuBackend *backend,
                                        void *texture,
                                        uint32_t backing_width,
                                        uint32_t backing_height)
{
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    ID3D11Texture2D *d3d_texture = texture;
    D3D11_TEXTURE2D_DESC desc;
    g_autofree char *name = NULL;
    IDXGIKeyedMutex *mutex = NULL;
    HANDLE handle = NULL;
    uint32_t fourcc;
    uint32_t required_flags;

    if (!backend) {
        return false;
    }
    if (!d3d_texture || !backing_width || !backing_height) {
        fb_shm_gpu_backend_reset(backend);
        return false;
    }
    if (backend->d3d_texture == d3d_texture && backend->d3d_mutex &&
        backend->d3d_name && backend->d3d_handle &&
        backend->d3d_width == backing_width &&
        backend->d3d_height == backing_height) {
        return true;
    }

    fb_shm_gpu_backend_reset(backend);
    d3d_texture->lpVtbl->GetDesc(d3d_texture, &desc);
    required_flags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE |
                     D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
    if (desc.Width != backing_width || desc.Height != backing_height ||
        desc.SampleDesc.Count != 1 || desc.ArraySize != 1 ||
        backing_width > UINT32_MAX / 4 ||
        (desc.MiscFlags & required_flags) != required_flags ||
        !fb_shm_gpu_d3d_format(desc.Format, &fourcc)) {
        return false;
    }

    mutex = fb_shm_gpu_d3d_query_mutex(d3d_texture);
    if (!mutex) {
        return false;
    }

    name = fb_shm_gpu_d3d_name(backend);
    if (!fb_shm_gpu_d3d_create_handle(d3d_texture, name, &handle)) {
        mutex->lpVtbl->Release(mutex);
        if (handle) {
            CloseHandle(handle);
        }
        return false;
    }

    d3d_texture->lpVtbl->AddRef(d3d_texture);
    backend->d3d_texture = d3d_texture;
    backend->d3d_mutex = mutex;
    backend->d3d_handle = handle;
    backend->d3d_name = g_steal_pointer(&name);
    backend->d3d_width = backing_width;
    backend->d3d_height = backing_height;
    backend->d3d_stride = backing_width * 4;
    backend->d3d_fourcc = fourcc;
    /* 与 D-Bus handoff 一致：provider 初始持有 key=0。 */
    backend->d3d_key0_owned = true;
    return true;
#else
    (void)backend;
    (void)texture;
    (void)backing_width;
    (void)backing_height;
    return false;
#endif
}

bool fb_shm_gpu_backend_has_d3d_texture(const FbShmGpuBackend *backend)
{
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    return backend && backend->d3d_texture && backend->d3d_mutex &&
           backend->d3d_handle && backend->d3d_name;
#else
    (void)backend;
    return false;
#endif
}

bool fb_shm_gpu_backend_d3d_release0(FbShmGpuBackend *backend)
{
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    HRESULT hr;

    if (!fb_shm_gpu_backend_has_d3d_texture(backend) ||
        !backend->d3d_key0_owned) {
        return false;
    }

    /*
     * keyed mutex 只同步所有权，不提交 producer 命令。
     * 从 texture 取得 immediate context 并 Flush，
     * 确保 consumer 看到完整帧；此路径不依赖 EGL current。
     */
    backend->d3d_texture->lpVtbl->GetDevice(backend->d3d_texture, &device);
    if (!device) {
        fb_shm_gpu_backend_reset(backend);
        return false;
    }
    device->lpVtbl->GetImmediateContext(device, &context);
    if (!context) {
        device->lpVtbl->Release(device);
        fb_shm_gpu_backend_reset(backend);
        return false;
    }
    context->lpVtbl->Flush(context);
    context->lpVtbl->Release(context);
    device->lpVtbl->Release(device);

    hr = backend->d3d_mutex->lpVtbl->ReleaseSync(backend->d3d_mutex, 0);
    if (hr != S_OK) {
        /* 所有权不可证明，撤销 direct path 并继续 SHM。 */
        fb_shm_gpu_backend_reset(backend);
        return false;
    }
    backend->d3d_key0_owned = false;
    return true;
#else
    (void)backend;
    return false;
#endif
}

bool fb_shm_gpu_backend_d3d_acquire0(FbShmGpuBackend *backend)
{
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    HRESULT hr;

    if (!fb_shm_gpu_backend_has_d3d_texture(backend)) {
        return false;
    }
    if (backend->d3d_key0_owned) {
        return true;
    }

    /* timeout=0：尚未归还时立即返回，不阻塞主线程。 */
    hr = backend->d3d_mutex->lpVtbl->AcquireSync(backend->d3d_mutex, 0, 0);
    if (hr == S_OK) {
        backend->d3d_key0_owned = true;
        return true;
    }
    if (hr != WAIT_TIMEOUT) {
        /* abandoned/失败表示资源不可靠，后续只走 SHM。 */
        fb_shm_gpu_backend_reset(backend);
    }
    return false;
#else
    (void)backend;
    return false;
#endif
}

bool fb_shm_gpu_export_dmabuf(FbShmGpuBackend *backend,
                              QemuDmaBuf *dmabuf,
                              const FbShmGpuFrameLayout *layout,
                              FbShmGpuExport *out)
{
#if defined(CONFIG_GBM) && !defined(_WIN32)
    const uint32_t *offsets;
    const uint32_t *strides;
    int noffsets = 0;
    int nstrides = 0;
    int fds[DMABUF_MAX_PLANES] = { -1, -1, -1, -1 };
    uint32_t flags = 0;
    uint64_t sequence;

    if (!backend || !dmabuf || !layout || !out ||
        qemu_dmabuf_get_num_planes(dmabuf) != 1 ||
        qemu_dmabuf_get_backing_width(dmabuf) != layout->backing_width ||
        qemu_dmabuf_get_backing_height(dmabuf) != layout->backing_height) {
        return false;
    }

    offsets = qemu_dmabuf_get_offsets(dmabuf, &noffsets);
    strides = qemu_dmabuf_get_strides(dmabuf, &nstrides);
    /*
     * 当前 wire ABI 没有 plane offset 字段，
     * 只允许无损表达的 offset=0。
     */
    if (!offsets || noffsets != 1 || offsets[0] != 0 ||
        !strides || nstrides != 1 || !strides[0] ||
        !qemu_dmabuf_get_fourcc(dmabuf)) {
        return false;
    }

    qemu_dmabuf_dup_fds(dmabuf, fds, G_N_ELEMENTS(fds));
    if (fds[0] < 0) {
        return false;
    }

    fb_shm_gpu_export_init(out);
    if (qemu_dmabuf_get_y0_top(dmabuf)) {
        flags |= FB_SHM_GPU_FRAME_F_Y0_TOP;
    }
    sequence = backend->frame_seq + 1;
    if (!sequence || !fb_shm_gpu_frame_build(
            &out->frame, layout, FB_SHM_GPU_HANDLE_DMA_BUF, flags,
            strides[0], qemu_dmabuf_get_fourcc(dmabuf),
            qemu_dmabuf_get_modifier(dmabuf), sequence, NULL)) {
        close(fds[0]);
        return false;
    }

    backend->frame_seq = sequence;
    out->fd = fds[0];
    return true;
#else
    (void)backend;
    (void)dmabuf;
    (void)layout;
    (void)out;
    return false;
#endif
}

bool fb_shm_gpu_export_texture(FbShmGpuBackend *backend,
                               uint32_t texture_id,
                               const FbShmGpuFrameLayout *layout,
                               FbShmGpuExport *out)
{
#if defined(_WIN32) && defined(CONFIG_OPENGL)
    uint64_t sequence;

    (void)texture_id;
    if (!fb_shm_gpu_backend_has_d3d_texture(backend) || !layout || !out ||
        backend->d3d_key0_owned ||
        backend->d3d_width != layout->backing_width ||
        backend->d3d_height != layout->backing_height) {
        return false;
    }

    fb_shm_gpu_export_init(out);
    sequence = backend->frame_seq + 1;
    if (!sequence || !fb_shm_gpu_frame_build(
            &out->frame, layout, FB_SHM_GPU_HANDLE_D3D11_TEXTURE,
            FB_SHM_GPU_FRAME_F_KEYED_MUTEX, backend->d3d_stride,
            backend->d3d_fourcc, 0, sequence, backend->d3d_name)) {
        return false;
    }
    backend->frame_seq = sequence;
    return true;
#elif defined(CONFIG_OPENGL) && defined(CONFIG_GBM)
    EGLint offsets[DMABUF_MAX_PLANES] = { 0 };
    EGLint strides[DMABUF_MAX_PLANES] = { 0 };
    EGLint fourcc = 0;
    EGLuint64KHR modifier = DRM_FORMAT_MOD_INVALID;
    int fds[DMABUF_MAX_PLANES] = { -1, -1, -1, -1 };
    int num_planes = 0;
    uint64_t sequence;
    bool exported;

    if (!backend || !texture_id || !layout || !out) {
        return false;
    }

    exported = egl_dmabuf_export_texture(texture_id, fds, offsets, strides,
                                         &fourcc, &num_planes, &modifier);
    if (!exported || num_planes != 1 || fds[0] < 0 || offsets[0] != 0 ||
        strides[0] <= 0 || fourcc == 0) {
        for (int i = 0; i < DMABUF_MAX_PLANES; i++) {
            if (fds[i] >= 0) {
                close(fds[i]);
            }
        }
        return false;
    }

    fb_shm_gpu_export_init(out);
    sequence = backend->frame_seq + 1;
    if (!sequence || !fb_shm_gpu_frame_build(
            &out->frame, layout, FB_SHM_GPU_HANDLE_DMA_BUF, 0,
            strides[0], fourcc, modifier, sequence, NULL)) {
        close(fds[0]);
        return false;
    }
    backend->frame_seq = sequence;
    out->fd = fds[0];
    return true;
#else
    (void)backend;
    (void)texture_id;
    (void)layout;
    (void)out;
    return false;
#endif
}
