/* PNG decoding with stb_image (public domain or MIT, see
 * THIRD_PARTY_NOTICES.md). Only PNG is compiled in. The allocator is the Zig
 * one (png.zig), so the same code runs on native and on freestanding wasm. */
#include <stddef.h>

#include "shim/string.h"

/* The allocator comes from Zig (png.zig sets it before each decode). */
static void *(*g_alloc)(size_t size);
static void (*g_free)(void *ptr);

void sw_png_set_allocator(void *(*alloc_fn)(size_t size), void (*free_fn)(void *ptr)) {
    g_alloc = alloc_fn;
    g_free = free_fn;
}

static void *sw_stb_malloc(size_t size) {
    return g_alloc ? g_alloc(size) : NULL;
}

static void sw_stb_free(void *ptr) {
    if (ptr && g_free) g_free(ptr);
}

static void *sw_stb_realloc(void *ptr, size_t old_size, size_t new_size) {
    void *fresh = sw_stb_malloc(new_size);
    if (!fresh) return NULL;
    if (ptr) {
        memcpy(fresh, ptr, old_size < new_size ? old_size : new_size);
        sw_stb_free(ptr);
    }
    return fresh;
}

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_NO_SIMD
#define STBI_NO_THREAD_LOCALS
#define STBI_MAX_DIMENSIONS 8192
#define STBI_ASSERT(x) ((void)0)
#define STBI_MALLOC(sz) sw_stb_malloc(sz)
#define STBI_REALLOC_SIZED(p, oldsz, newsz) sw_stb_realloc(p, oldsz, newsz)
#define STBI_FREE(p) sw_stb_free(p)
#include "stb_image.h"

/* Decode PNG bytes to RGBA8. Returns NULL on error. Free the result with
 * sw_png_free. */
unsigned char *sw_png_decode(const unsigned char *data, int len, int *width, int *height) {
    int channels = 0;
    return stbi_load_from_memory(data, len, width, height, &channels, 4);
}

/* The reason for the last failure, as a C string. */
const char *sw_png_error(void) {
    const char *reason = stbi_failure_reason();
    return (reason && *reason) ? reason : "unknown error";
}

/* Free the result of sw_png_decode. */
void sw_png_free(unsigned char *pixels) {
    sw_stb_free(pixels);
}
