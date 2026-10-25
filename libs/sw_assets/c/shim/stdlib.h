/* Minimal stdlib.h for stb_image on targets with no C library (wasm32
 * freestanding). stb_image allocates through STBI_MALLOC (sw_stb.c) and needs
 * only abs(). */
#ifndef SW_SHIM_STDLIB_H
#define SW_SHIM_STDLIB_H

static inline int abs(int v) { return v < 0 ? -v : v; }

#endif
