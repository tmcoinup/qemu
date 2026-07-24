# 从同一套系统级 ADL 兼容实现生成 x86 atiadlxy.dll 与 x64 atiadlxx.dll。
# GPU-Z 2.70 是 PE32，其他检测工具可能是 PE32+，两个架构必须共享相同身份契约。
CC32 ?= i686-w64-mingw32-gcc
CC64 ?= x86_64-w64-mingw32-gcc
COMMON_DIR := ../gpu-api-common
COMMON_SOURCES := $(COMMON_DIR)/aib_identity_catalog.c \
                  $(COMMON_DIR)/gpu_model_catalog.c \
                  $(COMMON_DIR)/carrier_validation_contract.c \
                  $(COMMON_DIR)/carrier_validation_win.c
COMMON_HEADERS := $(COMMON_DIR)/aib_identity_catalog.h \
                  $(COMMON_DIR)/gpu_model_catalog.h \
                  $(COMMON_DIR)/carrier_validation.h

SOURCES := adl_context_handle.c adl_core.c adl_core_extended.c \
           adl_identity_cache.c \
           adl_init_policy.c \
           adl_identity_contract.c adl_identity_win.c \
           adl_overdrive.c adl_profile.c adl_runtime.c adl_topology.c \
           adl_unsupported.c $(COMMON_SOURCES)
HEADERS := adl_context_handle.h adl_core_internal.h adl_identity.h \
           adl_identity_cache.h \
           adl_init_policy.h \
           adl_identity_contract.h adl_profile.h adl_public.h adl_runtime.h \
           adl_types.h $(COMMON_HEADERS)
CPPFLAGS := -I$(COMMON_DIR)
CFLAGS := -std=c11 -Os -Wall -Wextra -Werror -Wformat=2 -fno-ident
LDFLAGS := -shared -static-libgcc -Wl,--subsystem,windows \
           -Wl,--no-undefined -Wl,--no-insert-timestamp
LDLIBS := -ladvapi32 -lkernel32 -lsetupapi -lcfgmgr32

all: atiadlxy.dll atiadlxx.dll

atiadlxy.dll: $(SOURCES) $(HEADERS) atiadlxy.def adl-required-exports.txt
	@command -v "$(CC32)" >/dev/null || { \
		echo "ERROR: 缺少 $(CC32)，请安装 gcc-mingw-w64-i686" >&2; exit 127; \
	}
	$(CC32) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) atiadlxy.def $(LDFLAGS) $(LDLIBS)

atiadlxx.dll: $(SOURCES) $(HEADERS) atiadlxx.def adl-required-exports.txt
	@command -v "$(CC64)" >/dev/null || { \
		echo "ERROR: 缺少 $(CC64)，请安装 gcc-mingw-w64-x86-64" >&2; exit 127; \
	}
	$(CC64) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) atiadlxx.def $(LDFLAGS) $(LDLIBS)

check: all
	./test-build.sh

clean:
	rm -f atiadlxy.dll atiadlxx.dll

.PHONY: all check clean
