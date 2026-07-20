# 从同一套源文件生成 Windows x86/x64 NVAPI DLL。
#
# GPU-Z/HWiNFO 可能由外层进程或内嵌 helper 选择任一位数，只生成 nvapi64.dll
# 并不能覆盖 32 位调用链。两个目标都使用 -Werror，禁止用告警掩盖 ABI 问题。
CC32 ?= i686-w64-mingw32-gcc
CC64 ?= x86_64-w64-mingw32-gcc
COMMON_DIR := ../gpu-api-common
COMMON_SOURCES := $(COMMON_DIR)/carrier_validation_contract.c \
                  $(COMMON_DIR)/carrier_validation_win.c
COMMON_HEADERS := $(COMMON_DIR)/carrier_validation.h

SOURCES := nvapi_shim.c nvapi_identity.c nvapi_pci.c nvapi_gpu_specs.c \
           nvapi_gpu_details.c nvapi_gpu_legacy_clocks.c \
           nvapi_gpu_legacy_clocks_fill.c nvapi_gpu_pstates.c \
           nvapi_gpu_pstates_fill.c \
           nvapi_identity_contract.c $(COMMON_SOURCES)
HEADERS := nvapi_types.h nvapi_identity.h nvapi_gpu_specs.h \
           nvapi_gpu_details.h nvapi_gpu_legacy_clocks.h \
           nvapi_gpu_pstates.h nvapi_shim_internal.h \
           nvapi_identity_contract.h $(COMMON_HEADERS)
CPPFLAGS := -I$(COMMON_DIR)
CFLAGS := -std=c11 -Os -Wall -Wextra -Werror -fno-ident
LDFLAGS := -shared -static-libgcc -Wl,--subsystem,windows \
           -Wl,--no-undefined -Wl,--no-insert-timestamp
LDLIBS := -ladvapi32 -lkernel32 -lsetupapi -lcfgmgr32

all: nvapi.dll nvapi64.dll

nvapi.dll: $(SOURCES) $(HEADERS) nvapi.def
	@command -v "$(CC32)" >/dev/null || { \
		echo "ERROR: 缺少 $(CC32)，请安装 gcc-mingw-w64-i686" >&2; exit 127; \
	}
	$(CC32) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) nvapi.def $(LDFLAGS) $(LDLIBS)

nvapi64.dll: $(SOURCES) $(HEADERS) nvapi64.def
	@command -v "$(CC64)" >/dev/null || { \
		echo "ERROR: 缺少 $(CC64)，请安装 gcc-mingw-w64-x86-64" >&2; exit 127; \
	}
	$(CC64) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) nvapi64.def $(LDFLAGS) $(LDLIBS)

check: all
	./test-build.sh

clean:
	rm -f nvapi.dll nvapi64.dll

.PHONY: all check clean
