/*
 * nv_shmem_probe.c — host-side debug tool. Open and mmap an ivshmem
 * backing file (typically /dev/shm/nv-shmem-vmN), dump the protocol
 * header, ring states, and optionally bytes from either ring.
 *
 *   ./nv_shmem_probe                         # vm1 default
 *   ./nv_shmem_probe /dev/shm/nv-shmem-vm2
 *   ./nv_shmem_probe -i                      # init: write magic + sizes
 *   ./nv_shmem_probe -d video -n 64          # dump first 64B of video ring
 *
 * Build: cc -O2 -Wall -o nv_shmem_probe nv_shmem_probe.c
 */

#define _GNU_SOURCE
#include "nv_shmem_proto.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *DEFAULT_PATH = "/dev/shm/nv-shmem-vm1";

static void hexdump(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if ((i % 16) == 0) printf("  %04zx ", i);
        printf("%02x ", p[i]);
        if ((i % 16) == 15 || i == n - 1) printf("\n");
    }
}

int main(int argc, char **argv) {
    const char *path = NULL;
    int do_init = 0;
    const char *dump_ring = NULL;
    size_t dump_n = 64;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-i")) do_init = 1;
        else if (!strcmp(argv[i], "-d") && i+1 < argc) dump_ring = argv[++i];
        else if (!strcmp(argv[i], "-n") && i+1 < argc) dump_n = atoi(argv[++i]);
        else if (argv[i][0] != '-') path = argv[i];
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
    }
    if (!path) path = DEFAULT_PATH;

    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }
    struct stat st;
    if (fstat(fd, &st) < 0) { perror("fstat"); return 1; }
    printf("file: %s (%zu bytes)\n", path, (size_t)st.st_size);
    if ((size_t)st.st_size < NV_SHMEM_TOTAL_BYTES) {
        printf("  WARN: smaller than expected NV_SHMEM_TOTAL_BYTES=%u\n",
               NV_SHMEM_TOTAL_BYTES);
    }

    void *base = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) { perror("mmap"); return 1; }

    NvShmemHdr *hdr = (NvShmemHdr *)base;

    if (do_init) {
        memset(hdr, 0, sizeof(*hdr));
        hdr->magic        = NV_SHMEM_MAGIC;
        hdr->version      = NV_SHMEM_VERSION;
        hdr->total_bytes  = NV_SHMEM_TOTAL_BYTES;
        hdr->hdr_bytes    = NV_SHMEM_HDR_BYTES;
        hdr->video_off    = NV_SHMEM_VIDEO_OFF;
        hdr->video_bytes  = NV_SHMEM_VIDEO_BYTES;
        hdr->input_off    = NV_SHMEM_INPUT_OFF;
        hdr->input_bytes  = NV_SHMEM_INPUT_BYTES;
        printf("initialized header\n");
    }

    printf("\n=== header ===\n");
    printf("  magic        = 0x%08x %s\n", hdr->magic,
           hdr->magic == NV_SHMEM_MAGIC ? "(NVHM ✓)" : "(MISMATCH — uninitialized?)");
    printf("  version      = %u\n", hdr->version);
    printf("  total_bytes  = %u (%.1f MiB)\n", hdr->total_bytes, hdr->total_bytes / 1048576.0);
    printf("  hdr_bytes    = %u\n", hdr->hdr_bytes);
    printf("  video [off=%u size=%u (%.1f MiB)]\n",
           hdr->video_off, hdr->video_bytes, hdr->video_bytes / 1048576.0);
    printf("  input [off=%u size=%u]\n", hdr->input_off, hdr->input_bytes);
    printf("  guest size   = %ux%u%s\n",
           hdr->guest_width, hdr->guest_height,
           hdr->guest_width ? "" : " (not yet reported by guest)");
    printf("  host_alive   = %u\n", hdr->host_alive_tick);
    printf("  guest_alive  = %u\n", hdr->guest_alive_tick);

    printf("\n=== rings ===\n");
    printf("  video : writer_seq=%u  reader_seq=%u  used=%u  free=%u\n",
           hdr->video.writer_seq, hdr->video.reader_seq,
           nv_shmem_ring_used(hdr->video.writer_seq, hdr->video.reader_seq),
           nv_shmem_ring_free(hdr->video.writer_seq, hdr->video.reader_seq, NV_SHMEM_VIDEO_BYTES));
    printf("  input : writer_seq=%u  reader_seq=%u  used=%u  free=%u\n",
           hdr->input.writer_seq, hdr->input.reader_seq,
           nv_shmem_ring_used(hdr->input.writer_seq, hdr->input.reader_seq),
           nv_shmem_ring_free(hdr->input.writer_seq, hdr->input.reader_seq, NV_SHMEM_INPUT_BYTES));

    if (dump_ring) {
        uint32_t off = 0, sz = 0;
        if (!strcmp(dump_ring, "video")) { off = hdr->video_off; sz = hdr->video_bytes; }
        else if (!strcmp(dump_ring, "input")) { off = hdr->input_off; sz = hdr->input_bytes; }
        else { fprintf(stderr, "unknown ring %s\n", dump_ring); return 2; }
        if (dump_n > sz) dump_n = sz;
        printf("\n=== %s ring first %zu bytes ===\n", dump_ring, dump_n);
        hexdump((uint8_t *)base + off, dump_n);
    }

    munmap(base, st.st_size);
    close(fd);
    return 0;
}
