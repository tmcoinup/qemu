CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
LDLIBS   = -lX11

SDL2_CFLAGS := $(shell pkg-config --cflags sdl2)
SDL2_LIBS   := $(shell pkg-config --libs   sdl2)

all: stream_client stream_client_dda

stream_client: stream_client.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

stream_client_dda: stream_client_dda.c ../nv-shmem/nv_shmem_proto.h
	$(CC) $(CFLAGS) $(SDL2_CFLAGS) -o $@ stream_client_dda.c $(SDL2_LIBS)

clean:
	rm -f stream_client stream_client_dda stream_client_shmem

.PHONY: all clean
