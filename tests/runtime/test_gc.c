static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#undef main

static int sl_runtime_test_main(void) {
    sl_gc_register_thread();
    void *a = sl_gc_alloc(64, NULL);
    void *b = sl_gc_alloc(128, NULL);
    if (!a || !b)
        return 1;
    memset(a, 0xab, 64);
    memset(b, 0xcd, 128);
    sl_gc_collect();
    void *keep[48];
    for (int i = 0; i < 48; i++) {
        keep[i] = sl_gc_alloc(16, NULL);
        if (!keep[i]) return 1;
        memset(keep[i], i, 16);
    }
    sl_gc_collect();
    for (int i = 0; i < 48; i++) {
        unsigned char *p = (unsigned char *)keep[i];
        if (p[0] != (unsigned char)i) return 1;
    }
    void *c = sl_gc_alloc(32, NULL);
    if (!c)
        return 1;
    sl_gc_collect();
    return 0;
}

int main(void) {
    return sl_runtime_test_main();
}
