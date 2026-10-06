static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#undef main

static void sl_gc_test_trace_pair(void *p, void (*mark)(void *));
static int sl_gc_test_owned_buffers(void);
static int sl_gc_test_inline_bytes(void);

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

    /* Generational: a rooted young object survives minors and a major;
     * the first minor ages it (gen 2, still young) and the second
     * promotes it (fix-gc.md 1.2). */
    {
        void *promo = sl_gc_alloc(64, NULL);
        if (!promo) return 1;
        memset(promo, 0x5a, 64);
        sl_safepoint sp;
        void *roots[] = { promo };
        sl_rt_safepoint_enter(&sp, roots, 1);
        sl_gc_collect_minor();
        if (((sl_gc_obj *)promo - 1)->gen != 2) { sl_rt_safepoint_exit(); return 1; }
        sl_gc_collect_minor();
        if (((sl_gc_obj *)promo - 1)->gen != 1) { sl_rt_safepoint_exit(); return 1; }
        if (((unsigned char *)promo)[0] != 0x5a) { sl_rt_safepoint_exit(); return 1; }
        sl_gc_collect();
        if (((unsigned char *)promo)[0] != 0x5a) { sl_rt_safepoint_exit(); return 1; }
        sl_rt_safepoint_exit();
    }

    /* Generational write barrier path: store + sl_gc_remember under a
     * preempt bracket, then a minor must keep the young child alive. */
    {
        typedef struct { void *child; } pair_t;
        pair_t *old = (pair_t *)sl_gc_alloc(sizeof(pair_t),
                                            sl_gc_test_trace_pair);
        if (!old) return 1;
        old->child = NULL;
        /* root it across two minors: promoted to old */
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
    if (sl_gc_test_owned_buffers() != 0)
        return 1;
    return 0;
}

static void sl_gc_test_trace_pair(void *p, void (*mark)(void *)) {
    mark(*(void **)p);
}

static unsigned char sl_gc_test_gen(const void *payload) {
    return ((const sl_gc_obj *)payload - 1)->gen;
}

/* Is payload still a heap object (on either generation's list, or this
 * task's not-yet-harvested pending list)? A freed block is on none. */
static int sl_gc_test_on_heap(const void *payload) {
    const sl_gc_obj *h = (const sl_gc_obj *)payload - 1;
    for (sl_gc_obj *o = sl_gc_young; o; o = o->next)
        if (o == h) return 1;
    for (sl_gc_obj *o = sl_gc_old; o; o = o->next)
        if (o == h) return 1;
    for (sl_gc_obj *o = sl_rt_current_task->gc_pend_head; o; o = o->next)
        if (o == h) return 1;
    return 0;
}

static char *sl_gc_test_key(int i) {
    char *k = (char *)sl_gc_alloc(16, NULL);
    snprintf(k, 16, "k%d", i);
    return k;
}

/* Owned buffers (sl_gc_alloc_owned) must never be freed before their
 * owner. The failure this guards: a map promoted to old, then grown --
 * its new keys/vals/state/order buffers were YOUNG -- then dropped. The
 * next minor freed the young buffers but kept the dead old map, and a
 * stale word naming the map (a conservatively scanned stack slot) made
 * a later collection trace it: sl_gc_trace_map read a recycled order
 * buffer as slot indices and faulted. A stale root stands in for the
 * stale stack word here, so the test is deterministic. */
static int sl_gc_test_owned_buffers(void) {
    /* Born in the owner's generation. */
    {
        void *owner = sl_gc_alloc(32, NULL);
        if (sl_gc_test_gen(sl_gc_alloc_owned(64, owner)) != 0) return 1;
        sl_safepoint sp;
        void *roots[] = { owner };
        sl_rt_safepoint_enter(&sp, roots, 1);
        sl_gc_collect_minor();
        sl_gc_collect_minor();
        if (sl_gc_test_gen(owner) != 1) { sl_rt_safepoint_exit(); return 1; }
        unsigned char *old_buf = (unsigned char *)sl_gc_alloc_owned(64, owner);
        if (sl_gc_test_gen(old_buf) != 1) { sl_rt_safepoint_exit(); return 1; }
        memset(old_buf, 0x3c, 64);
        unsigned char *moved =
            (unsigned char *)sl_gc_realloc_owned(old_buf, 128, owner);
        if (sl_gc_test_gen(moved) != 1 || moved[63] != 0x3c) {
            sl_rt_safepoint_exit();
            return 1;
        }
        /* Unreferenced, an old-born buffer survives a minor (moved to
         * the old list, not freed); a major reclaims it. */
        sl_gc_collect_minor();
        if (!sl_gc_test_on_heap(old_buf) || sl_gc_test_gen(old_buf) != 1) {
            sl_rt_safepoint_exit();
            return 1;
        }
        sl_gc_collect();
        sl_rt_safepoint_exit();
        if (sl_gc_test_on_heap(old_buf)) return 1;
    }

    /* Map: promoted, grown while old, dropped, minor, then traced. */
    {
        sl_map *m = sl_map_new(sizeof(char *), sizeof(long long), 1, 1, 0);
        sl_safepoint sp;
        void *roots[] = { (void *)m };
        sl_rt_safepoint_enter(&sp, roots, 1);
        for (long long i = 0; i < 4; i++) {
            char *k = sl_gc_test_key((int)i);
            sl_map_put(m, &k, &i);
        }
        sl_gc_collect_minor();
        sl_gc_collect_minor();
        if (sl_gc_test_gen(m) != 1) { sl_rt_safepoint_exit(); return 1; }
        long long old_cap = m->cap;
        for (long long i = 4; i < 40; i++) {
            char *k = sl_gc_test_key((int)i);
            sl_map_put(m, &k, &i);
        }
        if (m->cap == old_cap) { sl_rt_safepoint_exit(); return 1; }
        if (sl_gc_test_gen(m->keys) != 1 || sl_gc_test_gen(m->vals) != 1 ||
            sl_gc_test_gen(m->state) != 1 || sl_gc_test_gen(m->order) != 1) {
            sl_rt_safepoint_exit();
            return 1;
        }
        roots[0] = NULL; /* the map dies */
        sl_gc_collect_minor();
        if (!sl_gc_test_on_heap(m->keys) || !sl_gc_test_on_heap(m->vals) ||
            !sl_gc_test_on_heap(m->state) || !sl_gc_test_on_heap(m->order)) {
            sl_rt_safepoint_exit();
            return 1;
        }
        /* A stale word names the dead map again, and the tracer walks
         * order -> slot -> vals. Those must still be the map's own
         * buffers. (Its young KEY strings are legitimately gone -- the
         * map was dead -- and the tracer only marks those, which
         * validates them; nothing here may dereference one.) */
        roots[0] = (void *)m;
        sl_gc_collect_minor();
        if (m->count != 40) { sl_rt_safepoint_exit(); return 1; }
        for (long long i = 0; i < m->count; i++) {
            long long slot = m->order[i];
            if (slot < 0 || slot >= m->cap || m->state[slot] != 1 ||
                *(long long *)(m->vals + (size_t)slot * m->vsz) != i) {
                sl_rt_safepoint_exit();
                return 1;
            }
        }
        sl_rt_safepoint_exit();
    }

    /* List: promoted, grown while old, dropped, minor. */
    {
        sl_arr *a = sl_arr_new(sizeof(void *), 1);
        sl_safepoint sp;
        void *roots[] = { (void *)a };
        sl_rt_safepoint_enter(&sp, roots, 1);
        void *el = sl_gc_alloc(16, NULL);
        sl_arr_push(a, &el, sizeof(void *));
        sl_gc_collect_minor();
        sl_gc_collect_minor();
        if (sl_gc_test_gen(a) != 1) { sl_rt_safepoint_exit(); return 1; }
        long long old_cap = a->cap;
        while (a->cap == old_cap) {
            void *e = sl_gc_alloc(16, NULL);
            sl_arr_push(a, &e, sizeof(void *));
        }
        if (sl_gc_test_gen(a->data) != 1) { sl_rt_safepoint_exit(); return 1; }
        roots[0] = NULL;
        sl_gc_collect_minor();
        if (!sl_gc_test_on_heap(a->data)) { sl_rt_safepoint_exit(); return 1; }
        sl_rt_safepoint_exit();
    }
    sl_gc_collect();
    return 0;
}

/* A bytes keeps its data in the same object (sl_bytes_alloc), so the
 * conservative scan must take a word equal to b->ptr as a reference to b:
 * an async-preempted task can be left holding nothing else. Only that
 * exact word: a pointer further into the data, or 16 bytes into an object
 * that is not a bytes, must not count. */
static int sl_gc_test_inline_bytes(void) {
    sl_bytes *b = sl_bytes_new((const unsigned char *)"inline", 6);
    if (b->ptr != (unsigned char *)(b + 1) || memcmp(b->ptr, "inline", 6))
        return 1;
    void *other = sl_gc_alloc(64, NULL);
    sl_gc_harvest_task(sl_rt_cur());
    sl_gc_set_build(0);
    void (*saved)(void *) = sl_gc_cur_mark;
    sl_gc_cur_mark = sl_gc_mark;
    sl_gc_obj *bh = (sl_gc_obj *)b - 1;
    sl_gc_obj *oh = (sl_gc_obj *)other - 1;
    int bad = 0;

    void *only_ptr[2] = { NULL, b->ptr };
    sl_gc_scan_conservative((uintptr_t)only_ptr, (uintptr_t)(only_ptr + 2));
    if (!bh->marked) bad = 1;
    bh->marked = 0;

    void *past[2] = { b->ptr + 1, (char *)other + 2 * sizeof(void *) };
    sl_gc_scan_conservative((uintptr_t)past, (uintptr_t)(past + 2));
    if (bh->marked || oh->marked) bad = 1;

    bh->marked = 0;
    oh->marked = 0;
    sl_gc_wl_n = 0;
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    sl_gc_cur_mark = saved;
    return bad;
}

/* A fresh object is held by its header inside the inlined allocator
 * (`h`, before `h + 1` is formed), so a conservatively scanned word equal
 * to a header must keep the object -- paged (small) and unpaged (past
 * SL_GC_PAGE_MAX_TOTAL) alike. One byte past the header is an interior
 * word and must not. */
static int sl_gc_test_header_word(void) {
    void *small = sl_gc_alloc(10, NULL);
    void *big = sl_gc_alloc(4096, NULL);
    sl_gc_harvest_task(sl_rt_cur());
    sl_gc_set_build(0);
    void (*saved)(void *) = sl_gc_cur_mark;
    sl_gc_cur_mark = sl_gc_mark;
    sl_gc_obj *sh = (sl_gc_obj *)small - 1;
    sl_gc_obj *bh = (sl_gc_obj *)big - 1;
    int bad = 0;
    if (!sh->paged || bh->paged) bad = 1;

    void *headers[2] = { sh, bh };
    sl_gc_scan_conservative((uintptr_t)headers, (uintptr_t)(headers + 2));
    if (!sh->marked || !bh->marked) bad = 1;
    sh->marked = 0;
    bh->marked = 0;

    void *inside[2] = { (char *)sh + 1, (char *)bh + 1 };
    sl_gc_scan_conservative((uintptr_t)inside, (uintptr_t)(inside + 2));
    if (sh->marked || bh->marked) bad = 1;

    sh->marked = 0;
    bh->marked = 0;
    sl_gc_wl_n = 0;
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    sl_gc_cur_mark = saved;
    return bad;
}

int main(void) {
    if (sl_runtime_test_main()) return 1;
    if (sl_gc_test_inline_bytes()) return 1;
    return sl_gc_test_header_word();
}
