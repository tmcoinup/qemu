/*
 * fb-shm GPU sideband 私有接口。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * 该接口把平台相关的 dma-buf / D3D11 句柄导出，
 * 与 fb-shm 的客户端、socket 和 SHM 生命周期隔离。
 * 导出失败是正常能力降级。
 * 所有函数只通过 bool 返回结果，不记录 warning，
 * 也不改变兼容的 SHM 帧路径。
 */

#ifndef QEMU_UI_FB_SHM_GPU_H
#define QEMU_UI_FB_SHM_GPU_H

#include "ui/fb-shm-abi.h"

typedef struct QemuDmaBuf QemuDmaBuf;
typedef struct FbShmGpuBackend FbShmGpuBackend;

/*
 * 一次 GPU 通知对应的可见区域。
 *
 * x/y 已经包含 scanout 原点和 fb-shm ROI 偏移；
 * 构造 wire frame 时会再次做减法式边界检查，
 * 避免无符号加法溢出绕过 backing 范围验证。
 */
typedef struct FbShmGpuFrameLayout {
    uint32_t width;
    uint32_t height;
    uint32_t x;
    uint32_t y;
    uint32_t backing_width;
    uint32_t backing_height;
    bool y0_top;
} FbShmGpuFrameLayout;

/*
 * 平台导出结果。
 *
 * Linux fd 由本结构独占，发送完后必须调用
 * fb_shm_gpu_export_cleanup()。
 * Windows 使用 frame.handle_name，fd 始终为 -1。
 */
typedef struct FbShmGpuExport {
    FbShmGpuFrame frame;
    int fd;
} FbShmGpuExport;

/*
 * 等待 consumer 确认的 GPU 帧状态。
 *
 * pending_sequence=0 表示没有在途帧。
 * last_sequence 是已开始序列的上界，完成后不回退。
 * 因而旧 DONE 不能完成新帧，ACK 前也不能发第二帧。
 * 结构可零初始化，只由主线程访问，无需加锁。
 */
typedef struct FbShmGpuPendingFrame {
    uint64_t pending_sequence;
    uint64_t last_sequence;
} FbShmGpuPendingFrame;

FbShmGpuBackend *fb_shm_gpu_backend_new(const char *display_id);
void fb_shm_gpu_backend_free(FbShmGpuBackend *backend);

/*
 * 清理当前平台 backing，
 * 但保留单调递增的 GPU frame sequence。
 */
void fb_shm_gpu_backend_reset(FbShmGpuBackend *backend);

/*
 * Windows/ANGLE 路径缓存 D3D11 命名共享纹理；
 * 其它平台安静返回 false。
 * texture 为 NULL 或校验失败时会同步撤销上一份共享 backing。
 */
bool fb_shm_gpu_backend_set_d3d_texture(FbShmGpuBackend *backend,
                                        void *texture,
                                        uint32_t backing_width,
                                        uint32_t backing_height);

/*
 * Windows 原始 D3D11 handoff 只有在 texture、命名 NT handle 和
 * IDXGIKeyedMutex 全部就绪时才可用；其它平台固定返回 false。
 */
bool fb_shm_gpu_backend_has_d3d_texture(const FbShmGpuBackend *backend);

/*
 * 把 key=0 从 QEMU 交给 consumer。ReleaseSync 不等待；
 * 只在 QEMU 当前持有 key=0 且 ReleaseSync(0) 成功时返回 true。
 */
bool fb_shm_gpu_backend_d3d_release0(FbShmGpuBackend *backend);

/*
 * DONE 后用 AcquireSync(0, 0) 尝试收回 key=0。
 * timeout 立即返回 false；调用方可异步重试。
 */
bool fb_shm_gpu_backend_d3d_acquire0(FbShmGpuBackend *backend);

/*
 * Linux 已有 dma-buf 的零拷贝旁路；
 * 不支持的平台安静返回 false。
 */
bool fb_shm_gpu_export_dmabuf(FbShmGpuBackend *backend,
                              QemuDmaBuf *dmabuf,
                              const FbShmGpuFrameLayout *layout,
                              FbShmGpuExport *out);

/*
 * Linux SDL/EGL texture 或 Windows SDL/ANGLE D3D11
 * texture 导出。
 */
bool fb_shm_gpu_export_texture(FbShmGpuBackend *backend,
                               uint32_t texture_id,
                               const FbShmGpuFrameLayout *layout,
                               FbShmGpuExport *out);

void fb_shm_gpu_export_cleanup(FbShmGpuExport *exported);

/*
 * 在途帧状态机：begin 拒绝并发、重复和倒退序列。
 * complete/cancel 必须精确匹配；错误 ACK 不改状态。
 */
bool fb_shm_gpu_pending_begin(FbShmGpuPendingFrame *state,
                              uint64_t frame_sequence);
bool fb_shm_gpu_pending_complete(FbShmGpuPendingFrame *state,
                                 uint64_t frame_sequence);
bool fb_shm_gpu_pending_cancel(FbShmGpuPendingFrame *state,
                               uint64_t frame_sequence);
bool fb_shm_gpu_pending_active(const FbShmGpuPendingFrame *state,
                               uint64_t *frame_sequence);

/*
 * 纯平台无关的 wire frame 构造器，
 * 单元测试直接覆盖所有边界条件。
 * handle_name 仅用于 D3D11；dma-buf 必须传 NULL。
 */
bool fb_shm_gpu_frame_build(FbShmGpuFrame *frame,
                            const FbShmGpuFrameLayout *layout,
                            uint32_t handle_type,
                            uint32_t extra_flags,
                            uint32_t stride,
                            uint32_t fourcc,
                            uint64_t modifier,
                            uint64_t frame_seq,
                            const char *handle_name);

#endif /* QEMU_UI_FB_SHM_GPU_H */
