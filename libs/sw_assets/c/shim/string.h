/* Minimal string.h for stb_image on targets with no C library (wasm32
 * freestanding). The Zig compiler runtime provides these functions. */
#ifndef SW_SHIM_STRING_H
#define SW_SHIM_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);

#endif
