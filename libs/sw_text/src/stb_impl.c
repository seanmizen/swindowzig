// The stb_truetype implementation, plus a small C API for font.zig. The
// wrapper has only plain types, so Zig declares it by hand and needs no
// translate-c step. stb_truetype needs no libc here: every libc call it makes
// is replaced below, so this file builds for freestanding WASM too.
#include <stddef.h>

// The allocator comes from Zig (font.zig sets it before any font opens). A
// function pointer, not an extern symbol, so a program that links this file
// and never uses sw_text still links.
static void *(*sw_text_alloc_fn)(size_t size);
static void (*sw_text_free_fn)(void *ptr);

static void *sw_text_malloc(size_t size) { return sw_text_alloc_fn ? sw_text_alloc_fn(size) : 0; }
static void sw_text_free(void *ptr) {
    if (sw_text_free_fn) sw_text_free_fn(ptr);
}

void sw_ttf_set_allocator(void *(*alloc_fn)(size_t), void (*free_fn)(void *)) {
    sw_text_alloc_fn = alloc_fn;
    sw_text_free_fn = free_fn;
}

#define STBTT_malloc(x, u) ((void)(u), sw_text_malloc(x))
#define STBTT_free(x, u) ((void)(u), sw_text_free(x))
#define STBTT_assert(x) ((void)0)
#define STBTT_ifloor(x) ((int)__builtin_floor(x))
#define STBTT_iceil(x) ((int)__builtin_ceil(x))
#define STBTT_sqrt(x) __builtin_sqrt(x)
#define STBTT_fabs(x) __builtin_fabs(x)
#define STBTT_pow(x, y) __builtin_pow(x, y)
#define STBTT_fmod(x, y) __builtin_fmod(x, y)
#define STBTT_cos(x) __builtin_cos(x)
#define STBTT_acos(x) __builtin_acos(x)
#define STBTT_strlen(x) __builtin_strlen(x)
#define STBTT_memcpy __builtin_memcpy
#define STBTT_memset __builtin_memset

#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/// Read a font. `data` must stay valid while the font is open. Returns null if
/// the data is not a TrueType font.
void *sw_ttf_open(const unsigned char *data) {
    int offset = stbtt_GetFontOffsetForIndex(data, 0);
    if (offset < 0) return 0;
    stbtt_fontinfo *info = (stbtt_fontinfo *)sw_text_malloc(sizeof(stbtt_fontinfo));
    if (!info) return 0;
    if (!stbtt_InitFont(info, data, offset)) {
        sw_text_free(info);
        return 0;
    }
    return info;
}

void sw_ttf_close(void *info) { sw_text_free(info); }

/// Glyph index for a code point. 0 means the font has no glyph for it.
int sw_ttf_glyph_index(const void *info, int codepoint) {
    return stbtt_FindGlyphIndex((const stbtt_fontinfo *)info, codepoint);
}

/// Scale from font units to pixels, for a line from ascent to descent that is
/// `pixel_height` tall.
float sw_ttf_scale(const void *info, float pixel_height) {
    return stbtt_ScaleForPixelHeight((const stbtt_fontinfo *)info, pixel_height);
}

void sw_ttf_vmetrics(const void *info, int *ascent, int *descent, int *line_gap) {
    stbtt_GetFontVMetrics((const stbtt_fontinfo *)info, ascent, descent, line_gap);
}

int sw_ttf_advance(const void *info, int glyph) {
    int advance = 0, bearing = 0;
    stbtt_GetGlyphHMetrics((const stbtt_fontinfo *)info, glyph, &advance, &bearing);
    return advance;
}

/// Pixel box of a glyph at `scale`, relative to the pen on the baseline. y
/// grows downward.
void sw_ttf_bitmap_box(const void *info, int glyph, float scale, int *x0, int *y0, int *x1, int *y1) {
    stbtt_GetGlyphBitmapBox((const stbtt_fontinfo *)info, glyph, scale, scale, x0, y0, x1, y1);
}

/// Draw a glyph as 8-bit coverage into `out` (`width` * `height` bytes).
void sw_ttf_render(const void *info, int glyph, float scale, unsigned char *out, int width, int height) {
    stbtt_MakeGlyphBitmap((const stbtt_fontinfo *)info, out, width, height, width, scale, scale, glyph);
}
