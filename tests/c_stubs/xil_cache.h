#ifndef AWG_TEST_XIL_CACHE_H
#define AWG_TEST_XIL_CACHE_H
#include <stdint.h>
typedef uintptr_t UINTPTR;
void Xil_DCacheFlushRange(UINTPTR, uint32_t);
void Xil_DCacheInvalidateRange(UINTPTR, uint32_t);
#endif
