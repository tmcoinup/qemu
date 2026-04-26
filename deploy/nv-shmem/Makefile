CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
LDLIBS  ?= -lpthread

all: nv_shmem_test nv_shmem_probe

nv_shmem_test: nv_shmem_test.c nv_shmem_proto.h
	$(CC) $(CFLAGS) -o $@ nv_shmem_test.c $(LDLIBS)

nv_shmem_probe: nv_shmem_probe.c nv_shmem_proto.h
	$(CC) $(CFLAGS) -o $@ nv_shmem_probe.c

check: nv_shmem_test
	./nv_shmem_test

clean:
	rm -f nv_shmem_test nv_shmem_probe

.PHONY: all check clean
