/* Tiny hand-written C library exercised by tests/ffi/main.sl: a
 * stand-in for "some real C library" that a slang program links
 * against via 'link "slffi";' and calls via 'extern fn'. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int32_t sl_ffi_add(int32_t a, int32_t b) {
    return a + b;
}

const char *sl_ffi_greet(const char *name) {
    static char buf[128];
    snprintf(buf, sizeof(buf), "Hello, %s!", name);
    return buf;
}

typedef struct {
    int32_t n;
} sl_ffi_counter;

void *sl_ffi_counter_new(int32_t start) {
    sl_ffi_counter *c = (sl_ffi_counter *)malloc(sizeof(sl_ffi_counter));
    c->n = start;
    return c;
}

int32_t sl_ffi_counter_next(void *h) {
    sl_ffi_counter *c = (sl_ffi_counter *)h;
    c->n += 1;
    return c->n;
}

void sl_ffi_counter_free(void *h) {
    free(h);
}

int32_t sl_ffi_sum_bytes(void *ptr, int32_t len) {
    unsigned char *p = (unsigned char *)ptr;
    int32_t sum = 0;
    for (int32_t i = 0; i < len; i++)
        sum += p[i];
    return sum;
}

void *sl_ffi_null(void) {
    return NULL;
}

int32_t sl_ffi_store(int32_t *p, int32_t v) {
    *p = v;
    return v;
}

int32_t sl_ffi_deep_stack(int32_t depth, int32_t *out) {
    volatile unsigned char buf[4096];
    buf[0] = (unsigned char)(depth & 0xFF);
    buf[4095] = (unsigned char)((depth * 7 + 3) & 0xFF);
    int32_t sub = depth > 0 ? sl_ffi_deep_stack(depth - 1, out) : 0;
    int32_t res = sub + (int32_t)buf[0] + (int32_t)buf[4095];
    if (out)
        *out = res;
    return res;
}

int32_t sl_ffi_big_frame(int32_t seed) {
    volatile unsigned char buf[32768];
    buf[0] = (unsigned char)(seed & 0xFF);
    buf[16384] = (unsigned char)((seed + 11) & 0xFF);
    buf[32767] = (unsigned char)((seed + 29) & 0xFF);
    return seed + (int32_t)buf[0] + (int32_t)buf[16384] + (int32_t)buf[32767];
}
