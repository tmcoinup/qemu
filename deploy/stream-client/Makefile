CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
LDLIBS   = -lX11

all: stream_client

stream_client: stream_client.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f stream_client

.PHONY: all clean
