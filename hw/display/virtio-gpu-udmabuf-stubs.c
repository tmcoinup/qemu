#include "qemu/osdep.h"
#include "hw/virtio/virtio-gpu.h"

bool virtio_gpu_have_udmabuf(void)
{
    /* nothing (stub) */
    return false;
}

void virtio_gpu_init_udmabuf(struct virtio_gpu_simple_resource *res)
{
    /* nothing (stub) */
}

void virtio_gpu_fini_udmabuf(struct virtio_gpu_simple_resource *res)
{
    /* nothing (stub) */
}

int virtio_gpu_update_dmabuf(VirtIOGPU *g,
                             uint32_t scanout_id,
                             struct virtio_gpu_simple_resource *res,
                             struct virtio_gpu_framebuffer *fb,
                             struct virtio_gpu_rect *r)
{
    /* nothing (stub) */
    return 0;
}

int virtio_gpu_update_dmabuf_fd(VirtIOGPU *g,
                                uint32_t scanout_id,
                                int dmabuf_fd,
                                uint32_t width,
                                uint32_t height,
                                uint32_t stride,
                                uint32_t x,
                                uint32_t y,
                                uint32_t backing_width,
                                uint32_t backing_height,
                                uint32_t fourcc,
                                uint64_t modifier,
                                bool y0_top,
                                bool owns_fd)
{
    /* nothing (stub) */
    return -EINVAL;
}

void virtio_gpu_clear_dmabuf(VirtIOGPU *g, uint32_t scanout_id)
{
    /* nothing (stub) */
}
