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
