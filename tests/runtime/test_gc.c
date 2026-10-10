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

typedef struct { const sl_gc_obj *want; int found; } sl_gc_test_find;

static void sl_gc_test_find_fn(sl_gc_obj *h, void *ctx) {
    sl_gc_test_find *f = (sl_gc_test_find *)ctx;
    if (h == f->want) f->found = 1;
}

/* Is payload still a heap object (a start bit in a page, or listed in an
 * mbuf, sl_gc_young_m or sl_gc_old)? A freed block is in none. */
static int sl_gc_test_on_heap(const void *payload) {
    sl_gc_test_find f = { (const sl_gc_obj *)payload - 1, 0 };
    sl_gc_for_each_obj(sl_gc_test_find_fn, &f);
    return f.found;
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
    sl_gc_set_build(0);
    sl_gc_obj *bh = (sl_gc_obj *)b - 1;
    sl_gc_obj *oh = (sl_gc_obj *)other - 1;
    int bad = 0;

    void *only_ptr[2] = { NULL, b->ptr };
    sl_gc_scan_conservative((uintptr_t)only_ptr, (uintptr_t)(only_ptr + 2), sl_gc_mark);
    if (!bh->marked) bad = 1;
    bh->marked = 0;

    void *past[2] = { b->ptr + 1, (char *)other + 2 * sizeof(void *) };
    sl_gc_scan_conservative((uintptr_t)past, (uintptr_t)(past + 2), sl_gc_mark);
    if (bh->marked || oh->marked) bad = 1;

    bh->marked = 0;
    oh->marked = 0;
    sl_gc_mslots[0].wl_n = 0;
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
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
    sl_gc_set_build(0);
    sl_gc_obj *sh = (sl_gc_obj *)small - 1;
    sl_gc_obj *bh = (sl_gc_obj *)big - 1;
    int bad = 0;
    if (!sh->paged || bh->paged) bad = 1;

    void *headers[2] = { sh, bh };
    sl_gc_scan_conservative((uintptr_t)headers, (uintptr_t)(headers + 2), sl_gc_mark);
    if (!sh->marked || !bh->marked) bad = 1;
    sh->marked = 0;
    bh->marked = 0;

    void *inside[2] = { (char *)sh + 1, (char *)bh + 1 };
    sl_gc_scan_conservative((uintptr_t)inside, (uintptr_t)(inside + 2), sl_gc_mark);
    if (sh->marked || bh->marked) bad = 1;

    sh->marked = 0;
    bh->marked = 0;
    sl_gc_mslots[0].wl_n = 0;
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    return bad;
}

/* A worker's page count must be its list's length after a sweep: the
 * page cap is checked against it, and the parallel sweep splits that
 * many pages (pagev) between threads. Pages kept alive across a minor
 * are what the prune used to count twice. */
static int sl_gc_test_npages(void) {
    enum { N = 2000 };
    static void *keep[N];
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, keep, N);
    for (int i = 0; i < N; i++)
        keep[i] = sl_gc_alloc(200, NULL);
    sl_gc_collect_minor();
    sl_gc_worker_state *st = sl_gc_tls_state();
    int n = 0;
    for (sl_gc_page *pg = st->pages; pg; pg = pg->next)
        n++;
    int bad = n < 2 || st->npages != n;
    if (bad)
        fprintf(stderr, "npages %d, list holds %d\n", st->npages, n);
    for (int i = 0; i < N; i++)
        keep[i] = NULL;
    sl_rt_safepoint_exit();
    sl_gc_collect();
    return bad;
}

static int sl_gc_test_finis = 0;
static void sl_gc_test_fini(void *p) {
    (void)p;
    sl_gc_test_finis++;
}

/* Paged objects are swept from their pages, not from a list: a promoted
 * one must stay off sl_gc_old (which a major's set build walks whole),
 * the sweeps must still run a dead paged object's finalizer and free its
 * slot, and an old paged object must survive minors and die at a major. */
static int sl_gc_test_page_sweep(void) {
    void *keep = sl_gc_alloc_fin(24, NULL, sl_gc_test_fini);
    void *dead = sl_gc_alloc_fin(24, NULL, sl_gc_test_fini);
    sl_gc_obj *kh = (sl_gc_obj *)keep - 1;
    if (!kh->paged || !((sl_gc_obj *)dead - 1)->paged) return 1;
    sl_safepoint sp;
    void *roots[] = { keep };
    sl_rt_safepoint_enter(&sp, roots, 1);
    sl_gc_test_finis = 0;
    sl_gc_collect_minor();
    if (sl_gc_test_finis != 1 || sl_gc_test_on_heap(dead)) {
        sl_rt_safepoint_exit();
        return 1;
    }
    sl_gc_collect_minor();
    if (kh->gen != 1 || !sl_gc_test_on_heap(keep)) {
        sl_rt_safepoint_exit();
        return 1;
    }
    for (sl_gc_obj *o = sl_gc_old; o; o = o->next)
        if (o->paged) { sl_rt_safepoint_exit(); return 1; }
    sl_gc_collect_minor();
    if (sl_gc_test_finis != 1 || !sl_gc_test_on_heap(keep)) {
        sl_rt_safepoint_exit();
        return 1;
    }
    roots[0] = NULL;
    sl_gc_collect_minor(); /* old: a minor never frees it */
    if (sl_gc_test_finis != 1 || !sl_gc_test_on_heap(keep)) {
        sl_rt_safepoint_exit();
        return 1;
    }
    sl_gc_collect();
    sl_rt_safepoint_exit();
    if (sl_gc_test_finis != 2 || sl_gc_test_on_heap(keep)) return 1;
    return sl_gc_test_npages();
}

/* A list the compiler proved pointer-free ([int], SL_ELEM_NOPTR) is never
 * scanned: an int that happens to equal a young object's address must not
 * keep it alive, and the ints themselves must survive the collection. A
 * list flagged 0 (unknown) still scans every word, so it does keep it. */
static int sl_gc_test_pointer_free(void) {
    sl_arr *ints = sl_arr_new(sizeof(long long), 2);
    sl_arr *unknown = sl_arr_new(sizeof(long long), 0);
    sl_safepoint sp;
    void *roots[] = { ints, unknown };
    sl_rt_safepoint_enter(&sp, roots, 2);
    void *victim = sl_gc_alloc(48, NULL);
    void *kept = sl_gc_alloc(48, NULL);
    long long v = (long long)(intptr_t)victim, k = (long long)(intptr_t)kept;
    sl_arr_push(ints, &v, sizeof v);
    sl_arr_push(unknown, &k, sizeof k);
    victim = kept = NULL;
    sl_gc_collect_minor();
    int bad = sl_gc_test_on_heap((void *)(intptr_t)v) ||
              !sl_gc_test_on_heap((void *)(intptr_t)k) ||
              ((long long *)ints->data)[0] != v;
    sl_rt_safepoint_exit();
    sl_gc_collect();
    return bad;
}

/* Each mark slot's functions use that slot alone -- its work list, its
 * gen-0 count -- so threads marking through different slots share none
 * of it (todo.md R4, parallel mark). Slot 3 marks a young object; slot 0
 * must not see it. */
static int sl_gc_test_mark_slots(void) {
    void *young = sl_gc_alloc(24, NULL);
    sl_gc_set_build(0);
    sl_gc_marker *s0 = &sl_gc_mslots[0], *s3 = &sl_gc_mslots[3];
    size_t n0 = s0->wl_n, n3 = s3->wl_n;
    unsigned long long g0 = s0->gen0_seen, g3 = s3->gen0_seen;
    sl_gc_mark_minor_fns[3](young);
    int bad = s3->wl_n != n3 + 1 || s3->wl[s3->wl_n - 1] != young ||
              s3->gen0_seen != g3 + 1 || s0->wl_n != n0 ||
              s0->gen0_seen != g0;
    /* Marked once is marked for every slot: a second claim pushes
       nothing, through any slot. */
    sl_gc_mark_minor_fns[5](young);
    if (sl_gc_mslots[5].wl_n != 0) bad = 1;
    ((sl_gc_obj *)young - 1)->marked = 0;
    s3->wl_n = n3;
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    return bad;
}

/* The adaptive nursery's policy is driven by measured time between minors.
 * Test each branch with controlled samples here; end-to-end timing varies
 * across machines and must not decide whether this policy test passes. */
static int sl_gc_test_nursery_adapt(void) {
    size_t base = SL_GC_NURSERY_BASE;
    struct nursery_case {
        const char *name;
        size_t current;
        size_t maximum;
        int fixed;
        long long previous_end;
        long long start;
        long long end;
        size_t live;
        size_t want;
    } cases[] = {
        {"growth", base, 4 * base, 0, 1000, 1150, 1200,
         base / 4 + 1, 2 * base},
        {"growth cap", 3 * base, 7 * base / 2, 0, 1000, 1150, 1200,
         3 * base / 4 + 1, 7 * base / 2},
        {"pause boundary", base, 4 * base, 0, 1000, 1140, 1160,
         base / 4, base},
        {"live boundary", base, 4 * base, 0, 1000, 1150, 1200,
         base / 8, base},
        {"hysteresis", 2 * base, 4 * base, 0, 1000, 1980, 2000,
         base / 8, 2 * base},
        {"shrink by pause", 4 * base, 4 * base, 0, 1000, 1990, 2000,
         4 * base, 2 * base},
        {"shrink by survival", 4 * base, 4 * base, 0, 1000, 1150, 1200,
         base / 16, 2 * base},
        {"base floor", base, 4 * base, 0, 1000, 1999, 2000,
         0, base},
        {"fixed nursery", 2 * base, 4 * base, 1, 1000, 1150, 1200,
         base, 2 * base},
        {"first sample", base, 4 * base, 0, 0, 1000, 1200,
         base, base},
    };
    size_t saved_threshold = atomic_load_explicit(
        &sl_gc_nursery_threshold, memory_order_relaxed);
    size_t saved_maximum = sl_gc_nursery_max;
    int saved_fixed = sl_gc_nursery_fixed;
    long long saved_previous_end = sl_gc_minor_last_end_ns;
    int bad = 0;

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        atomic_store_explicit(&sl_gc_nursery_threshold, cases[i].current,
                              memory_order_relaxed);
        sl_gc_nursery_max = cases[i].maximum;
        sl_gc_nursery_fixed = cases[i].fixed;
        sl_gc_minor_last_end_ns = cases[i].previous_end;
        sl_gc_nursery_adapt(cases[i].start, cases[i].end, cases[i].live);
        size_t got = atomic_load_explicit(&sl_gc_nursery_threshold,
                                          memory_order_relaxed);
        if (got != cases[i].want) {
            fprintf(stderr,
                    "nursery adaptation %s: got %zu bytes, expected %zu\n",
                    cases[i].name, got, cases[i].want);
            bad = 1;
        }
    }

    atomic_store_explicit(&sl_gc_nursery_threshold, saved_threshold,
                          memory_order_relaxed);
    sl_gc_nursery_max = saved_maximum;
    sl_gc_nursery_fixed = saved_fixed;
    sl_gc_minor_last_end_ns = saved_previous_end;
    return bad;
}

int main(void) {
    if (sl_gc_test_nursery_adapt()) return 1;
    puts("PASS nursery adaptation policy");
    if (sl_runtime_test_main()) return 1;
    if (sl_gc_test_inline_bytes()) return 1;
    if (sl_gc_test_pointer_free()) { fprintf(stderr, "pointer_free test FAILED\n"); return 1; }
    if (sl_gc_test_mark_slots()) { fprintf(stderr, "mark_slots test FAILED\n"); return 1; }
    if (sl_gc_test_page_sweep()) return 1;
    return sl_gc_test_header_word();
}
