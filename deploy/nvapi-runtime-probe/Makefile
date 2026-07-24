# 构建两个独立位数的 Windows 控制台探针。它们不链接 NVAPI import library，
# 只依赖系统 Kernel32，并在运行时从对应 Windows 系统目录加载 NVAPI。
CC32 ?= i686-w64-mingw32-gcc
CC64 ?= x86_64-w64-mingw32-gcc

SOURCE := nvapi-runtime-probe.c
CFLAGS := -std=c11 -Os -Wall -Wextra -Werror -fno-ident
LDFLAGS := -static-libgcc -Wl,--subsystem,console \
           -Wl,--no-insert-timestamp

all: nvapi-runtime-probe-x86.exe nvapi-runtime-probe-x64.exe

nvapi-runtime-probe-x86.exe: $(SOURCE)
	@command -v "$(CC32)" >/dev/null || { \
		echo "ERROR: 缺少 $(CC32)，请安装 gcc-mingw-w64-i686" >&2; exit 127; \
	}
	$(CC32) $(CFLAGS) -DNVAPI_PROBE_X86=1 -o $@ $< $(LDFLAGS)

nvapi-runtime-probe-x64.exe: $(SOURCE)
	@command -v "$(CC64)" >/dev/null || { \
		echo "ERROR: 缺少 $(CC64)，请安装 gcc-mingw-w64-x86-64" >&2; exit 127; \
	}
	$(CC64) $(CFLAGS) -DNVAPI_PROBE_X64=1 -o $@ $< $(LDFLAGS)

check: all
	./test-build.sh

clean:
	rm -f nvapi-runtime-probe-x86.exe nvapi-runtime-probe-x64.exe

.PHONY: all check clean
