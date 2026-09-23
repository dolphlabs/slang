static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#undef main

static void sl_gc_test_trace_pair(void *p, void (*mark)(void *));

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

    /* Generational: with the minor SWEEP+promote path disabled (see
     * sl_gc_collect_minor's STATUS comment), these tests assert the
     * properties that hold in the current configuration: (1) minor
     * triggers run full collections (objects survive, heap intact);
     * (2) the write-barrier path (store + sl_gc_remember under bracket)
     * executes without corrupting anything. The promotion-gen==1 and
     * old-garbage-survives-minor assertions belong to the re-enable
     * step, when minors actually sweep the nursery. */
    {
        void *promo = sl_gc_alloc(64, NULL);
        if (!promo) return 1;
        memset(promo, 0x5a, 64);
        sl_safepoint sp;
        void *roots[] = { promo };
        sl_rt_safepoint_enter(&sp, roots, 1);
        sl_gc_collect_minor();
        sl_gc_collect_minor();
        if (((unsigned char *)promo)[0] != 0x5a) { sl_rt_safepoint_exit(); return 1; }
        sl_gc_collect();
        if (((unsigned char *)promo)[0] != 0x5a) { sl_rt_safepoint_exit(); return 1; }
        sl_rt_safepoint_exit();
    }

    /* Generational write barrier path: store + sl_gc_remember under a
     * preempt bracket, then force collections and assert survival.
     * (With minors routed to full collections, young is kept alive by
     * the root walk itself; this exercises the barrier machinery with
     * zero minor-sweep risk. The old->young-via-remembered-set-only
     * assertion belongs to the re-enable step.) */
    {
        typedef struct { void *child; } pair_t;
        pair_t *old = (pair_t *)sl_gc_alloc(sizeof(pair_t),
                                            sl_gc_test_trace_pair);
        if (!old) return 1;
        old->child = NULL;
        /* root it across two minors (currently full collections) */
        sl_safepoint sp0;
        void *r0[] = { (void *)old };
        sl_rt_safepoint_enter(&sp0, r0, 1);
        sl_gc_collect_minor();
        sl_gc_collect_minor();
        sl_rt_safepoint_exit();
        /* fresh object, then link it from the old one via the
         * real barrier path (as codegen would: store + remember). */
        void *young = sl_gc_alloc(32, NULL);
        if (!young) return 1;
        memset(young, 0x77, 32);
        sl_rt_preempt_disable();
        old->child = young;
        sl_gc_remember((void *)old);
        sl_rt_preempt_enable();
        /* root the OLD object only (young reachable solely through
         * it); collections must keep young alive. */
        sl_safepoint sp1;
        void *r2[] = { (void *)old };
        sl_rt_safepoint_enter(&sp1, r2, 1);
        sl_gc_collect_minor();
        sl_rt_safepoint_exit();
        if (((unsigned char *)young)[0] != 0x77) return 1;
    }
    return 0;
}

static void sl_gc_test_trace_pair(void *p, void (*mark)(void *)) {
    mark(*(void **)p);
}

int main(void) {
    return sl_runtime_test_main();
}
