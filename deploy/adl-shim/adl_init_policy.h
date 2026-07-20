#ifndef STEALTH_ADL_INIT_POLICY_H
#define STEALTH_ADL_INIT_POLICY_H

#include "adl_types.h"

/* 未实现全局串行化时，不能向调用方承诺 ADL_THREADING_LOCKED。 */
int adl_init_threading_model_status(ADLThreadingModel threading_model);
/* AMD 官方样例已公开的 X3 create option 仅为 bit 0。 */
int adl_init_create_options_status(int create_options);

#endif
