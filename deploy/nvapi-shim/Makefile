# Cross-compile nvapi64.dll for Windows from Ubuntu host.
CC     := x86_64-w64-mingw32-gcc
CFLAGS := -Os -Wall -Wextra -fno-stack-protector -ffreestanding \
          -fno-ident -mwindows
LDFLAGS := -shared -Wl,--kill-at -static-libgcc \
           -Wl,--subsystem,windows -Wl,--enable-stdcall-fixup
LIBS   := -lkernel32 -luser32

all: nvapi64.dll

nvapi64.dll: nvapi64.c nvapi64.def
	$(CC) $(CFLAGS) -o $@ nvapi64.c nvapi64.def $(LDFLAGS) $(LIBS)
	@ls -l $@
	@x86_64-w64-mingw32-objdump -p $@ | grep -E '^\s+\[.*\]' | head -10 || true

clean:
	rm -f nvapi64.dll

.PHONY: all clean
