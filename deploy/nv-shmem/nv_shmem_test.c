/*
 * nv_shmem_test.c — unit test for the ring buffer protocol.
 *
 * Spawns one producer thread and one consumer thread that share an
 * in-process buffer. Producer pushes N records of mixed sizes; consumer
 * pulls them and verifies the byte content. Exercises the wrap path
 * by sizing the ring smaller than the total bytes pushed.
 *
 * Build: cc -O2 -Wall -pthread -o nv_shmem_test nv_shmem_test.c
 */

#define _GNU_SOURCE
#include "nv_shmem_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>

#define RING_CAP   (1u * 1024u * 1024u)   /* 1 MiB */
#define N_RECORDS  100000

static uint8_t          g_ring[RING_CAP];
static NvShmemRingCtrl  g_ctrl;

static uint64_t mono_us(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* Deterministic record content: byte i of record k is (k+i) & 0xFF. */
static void fill_record(uint8_t *buf, uint32_t size, uint32_t k) {
    for (uint32_t i = 0; i < size; i++) buf[i] = (uint8_t)(k + i);
}
static int verify_record(const uint8_t *buf, uint32_t size, uint32_t k) {
    for (uint32_t i = 0; i < size; i++)
        if (buf[i] != (uint8_t)(k + i)) return -1;
    return 0;
}

static void *producer(void *arg) {
    (void)arg;
    uint8_t scratch[64 * 1024];
    for (uint32_t k = 0; k < N_RECORDS; k++) {
        /* mixed sizes: small (RFB-like) up to large (NAL-like) */
        uint32_t size;
        switch (k & 7) {
        case 0:
        case 1:
        case 2:
        case 3:  size = 6  + (k & 31); break;        /* small frequent */
        case 4:  size = 200 + (k & 511); break;
        case 5:  size = 1000 + (k & 8191); break;
        case 6:  size = 4096; break;
        case 7:  size = 32 * 1024 + (k & 1023); break; /* video-frame size */
        default: size = 100;
        }
        fill_record(scratch, size, k);
        while (nv_shmem_write(g_ring, RING_CAP, &g_ctrl, scratch, size) != 0) {
            /* ring full — back off briefly */
            usleep(50);
        }
    }
    return NULL;
}

static void *consumer(void *arg) {
    (void)arg;
    uint8_t scratch[256 * 1024];
    uint32_t out_size = 0;
    uint32_t k = 0;
    while (k < N_RECORDS) {
        int rc = nv_shmem_read(g_ring, RING_CAP, &g_ctrl,
                               scratch, sizeof(scratch), &out_size);
        if (rc == 0) { usleep(50); continue; }
        if (rc < 0) {
            fprintf(stderr, "FAIL: oversize record %u (size=%u, max=%zu)\n",
                    k, out_size, sizeof(scratch));
            exit(1);
        }
        if (verify_record(scratch, out_size, k) != 0) {
            fprintf(stderr, "FAIL: record %u content mismatch (size=%u)\n", k, out_size);
            exit(1);
        }
        k++;
    }
    return NULL;
}

int main(void) {
    printf("ring=%u bytes, records=%u\n", RING_CAP, N_RECORDS);
    pthread_t pt, ct;
    uint64_t t0 = mono_us();
    pthread_create(&pt, NULL, producer, NULL);
    pthread_create(&ct, NULL, consumer, NULL);
    pthread_join(pt, NULL);
    pthread_join(ct, NULL);
    uint64_t dt = mono_us() - t0;
    printf("PASS: %u records in %.2f ms (%.1f M-rec/s)\n",
           N_RECORDS, dt / 1000.0, N_RECORDS * 1.0 / dt);
    printf("final writer_seq=%u reader_seq=%u (delta=%u)\n",
           g_ctrl.writer_seq, g_ctrl.reader_seq,
           g_ctrl.writer_seq - g_ctrl.reader_seq);
    return 0;
}
