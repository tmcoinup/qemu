#ifndef STEALTH_ADL_CONTEXT_HANDLE_H
#define STEALTH_ADL_CONTEXT_HANDLE_H

#include <stddef.h>
#include <stdint.h>

/*
 * 低位保存 slot 编号加一，零值保留给无效句柄。容量因此比编码空间少一个。
 * generation 位于高位；slot 重用时 generation 递增，陈旧 ADL_CONTEXT_HANDLE
 * 不会重新指向新 context。
 */
#define ADL_CONTEXT_SLOT_BITS 6u
#define ADL_CONTEXT_SLOT_CODE_LIMIT ((uintptr_t)1u << ADL_CONTEXT_SLOT_BITS)
#define ADL_CONTEXT_SLOT_CAPACITY \
    ((size_t)(ADL_CONTEXT_SLOT_CODE_LIMIT - (uintptr_t)1u))
#define ADL_CONTEXT_SLOT_MASK (ADL_CONTEXT_SLOT_CODE_LIMIT - (uintptr_t)1u)
#define ADL_CONTEXT_GENERATION_MAX (UINTPTR_MAX >> ADL_CONTEXT_SLOT_BITS)

int adl_context_handle_encode(size_t slot_index, uintptr_t generation,
                              uintptr_t *token);
int adl_context_handle_decode(uintptr_t token, size_t *slot_index,
                              uintptr_t *generation);

#endif
