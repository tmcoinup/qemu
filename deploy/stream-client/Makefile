CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
LDLIBS   = -lX11

all: stream_client stream_client_shmem

stream_client: stream_client.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

stream_client_shmem: stream_client_shmem.c ../nv-shmem/nv_shmem_proto.h
	$(CC) $(CFLAGS) -o $@ stream_client_shmem.c $(LDLIBS) -lpthread

clean:
	rm -f stream_client stream_client_shmem

.PHONY: all clean
