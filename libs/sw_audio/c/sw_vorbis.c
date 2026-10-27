/* Ogg Vorbis decoding with stb_vorbis (public domain or MIT, see
 * THIRD_PARTY_NOTICES.md). stb_vorbis.c is not changed.
 *
 * stb_vorbis gets all its memory from one buffer that Zig gives to
 * sw_vorbis_open (vorbis.zig). It does not call malloc, alloca or the C
 * library. This file supplies the few C library functions that the decoder
 * uses, so the same code runs on native and on freestanding wasm. */

#define STB_VORBIS_NO_CRT
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#define STB_VORBIS_NO_INTEGER_CONVERSION

typedef __SIZE_TYPE__ sw_size_t;

/* lookup1_values calls pow with an integer exponent and compares the result
 * with an integer. A loop gives the exact value. */
static double sw_vorbis_pow(double base, int exponent) {
    double result = 1.0;
    int i;
    for (i = 0; i < exponent; ++i) result *= base;
    return result;
}

static double sw_vorbis_ldexp(double x, int exponent) {
    while (exponent > 0) {
        x *= 2.0;
        --exponent;
    }
    while (exponent < 0) {
        x *= 0.5;
        ++exponent;
    }
    return x;
}

static int sw_vorbis_abs(int v) { return v < 0 ? -v : v; }

static void sw_vorbis_swap(unsigned char *a, unsigned char *b, sw_size_t size) {
    sw_size_t i;
    for (i = 0; i < size; ++i) {
        unsigned char t = a[i];
        a[i] = b[i];
        b[i] = t;
    }
}

static void sw_vorbis_sift(unsigned char *base, sw_size_t root, sw_size_t count, sw_size_t size,
                           int (*compare)(const void *, const void *)) {
    for (;;) {
        sw_size_t child = root * 2 + 1;
        if (child >= count) return;
        if (child + 1 < count && compare(base + child * size, base + (child + 1) * size) < 0) ++child;
        if (compare(base + root * size, base + child * size) >= 0) return;
        sw_vorbis_swap(base + root * size, base + child * size, size);
        root = child;
    }
}

/* A heap sort. The decoder sorts the code words and the floor points while it
 * reads the setup header. */
static void sw_vorbis_qsort(void *items, sw_size_t count, sw_size_t size,
                            int (*compare)(const void *, const void *)) {
    unsigned char *base = (unsigned char *)items;
    sw_size_t i;
    if (count < 2) return;
    for (i = count / 2; i > 0; --i) sw_vorbis_sift(base, i - 1, count, size, compare);
    for (i = count - 1; i > 0; --i) {
        sw_vorbis_swap(base, base + i * size, size);
        sw_vorbis_sift(base, 0, i, size, compare);
    }
}

#define assert(x) ((void)0)
#define memcpy __builtin_memcpy
#define memset __builtin_memset
#define memcmp __builtin_memcmp
#define alloca __builtin_alloca
#define sin(x) __builtin_sin(x)
#define cos(x) __builtin_cos(x)
#define exp(x) __builtin_exp(x)
#define log(x) __builtin_log(x)
#define floor(x) __builtin_floor(x)
#define pow(x, y) sw_vorbis_pow((x), (y))
#define ldexp(x, y) sw_vorbis_ldexp((x), (y))
#define abs(x) sw_vorbis_abs(x)
#define qsort sw_vorbis_qsort

#include "stb_vorbis.c"

/* Open Ogg Vorbis data. `data` must stay valid until sw_vorbis_close.
 * `memory` is the only memory of the decoder. Returns NULL on error, and
 * puts the stb_vorbis error code in *error (3 = the memory is too small). */
void *sw_vorbis_open(const unsigned char *data, int len, char *memory, int memory_len, int *error) {
    stb_vorbis_alloc alloc;
    alloc.alloc_buffer = memory;
    alloc.alloc_buffer_length_in_bytes = memory_len;
    return stb_vorbis_open_memory(data, len, error, &alloc);
}

void sw_vorbis_close(void *handle) { stb_vorbis_close((stb_vorbis *)handle); }

int sw_vorbis_channels(void *handle) { return stb_vorbis_get_info((stb_vorbis *)handle).channels; }

unsigned int sw_vorbis_rate(void *handle) { return stb_vorbis_get_info((stb_vorbis *)handle).sample_rate; }

/* The length in frames, or 0 if the data does not give it. */
unsigned int sw_vorbis_length(void *handle) { return stb_vorbis_stream_length_in_samples((stb_vorbis *)handle); }

/* Decode up to `frames` frames of `channels` interleaved floats into `out`.
 * Returns the number of frames. 0 is the end of the data. */
int sw_vorbis_read(void *handle, float *out, int frames, int channels) {
    return stb_vorbis_get_samples_float_interleaved((stb_vorbis *)handle, channels, out, frames * channels);
}

/* Go back to the first frame. Returns 0 on error. */
int sw_vorbis_rewind(void *handle) { return stb_vorbis_seek_start((stb_vorbis *)handle); }
