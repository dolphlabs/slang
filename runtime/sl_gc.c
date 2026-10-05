#include <sched.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif

/* ---- precise mark-sweep collector (replaces Boehm) ---- */

typedef struct sl_gc_obj {
    struct sl_gc_obj *next;
    size_t size;
    void (*trace)(void *payload, void (*mark)(void *ptr));
    void (*fini)(void *payload);
    unsigned char marked;
    /* Generational (young/old, non-moving, STW nursery) GC. gen 0 =
     * young (nursery, swept by every minor collection), 2 = young that
     * has survived one minor (still swept by minors; promoted if it
     * survives the next), 1 = old (swept only by a major/full
     * collection). "Young" is therefore gen != 1 everywhere. Objects never move, so
     * a conservative candidate word can never be a stale address --
     * required by sl_gc_scan_conservative (see its comment). */
    unsigned char gen;
    /* Remembered-set dedup: set when this old object is appended to
     * its task's gc_rem_* shard, cleared when a minor GC harvests and
     * scans it. A hot object stored to repeatedly costs one shard
     * append per minor cycle. */
    unsigned char remembered;
    /* Phase 1 (§7f) page flag: 1 when this header lives in a per-worker
     * young page (recycled through the page, never class_push/free).
     * Uses the header's tail padding: sizeof stays 40 (asserted below). */
    unsigned char paged;
    /* The slot's full extent, header included, 8-aligned: what the
     * allocator reserved (a split remainder or absorbed waste makes
     * it larger than sizeof + size). The sweep-end hole walk strides
     * by cap, never by size, so it can never land mid-slot and file
     * a fragment another claim then overwrites. Fits the last pad
     * word: sizeof stays 40. */
    uint32_t cap;
} sl_gc_obj;
_Static_assert(sizeof(sl_gc_obj) == 40,
              "sl_gc_obj grew; retune the young-page slot math");

static sl_gc_obj *sl_gc_young = NULL;
static sl_gc_obj *sl_gc_old = NULL;
static _Atomic(sl_gc_obj *) sl_gc_retired = NULL;
static pthread_mutex_t sl_gc_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic size_t sl_gc_bytes_since_collect = 0;
static size_t sl_gc_threshold = 8 * 1024 * 1024;
/* Majors come after sl_gc_threshold bytes are PROMOTED (each minor adds
 * what it moved to the old generation, owned buffers born old included),
 * or after SL_GC_MAJOR_EVERY minors, whichever is first. Allocation used
 * to count: with a 1 MB-per-worker nursery a full-heap major followed
 * nearly every minor, re-marking an old heap that had barely grown --
 * on the quote server in a Linux container, 801 majors to 801 minors in
 * 8 s, 27% of wall time stopped. The minor bound remains because the
 * collector does not move objects: a promoted object that dies pins its
 * young page until a major frees it, and pacing by promotion alone grew
 * the quote server's peak RSS by 7 MB. Quote ABBA, Linux: every 8
 * minors +4% req/s at equal RSS, every 16 +9% for +0.8 MB, every 32 +10%
 * for +1.6 MB, promotion alone +6% for +7 MB. Under
 * SLANG_GC_THRESHOLD_KB every allocation still counts, so that mode
 * lands majors as often as possible. */
#define SL_GC_MAJOR_EVERY 16
static long sl_gc_minors_since_major = 0; /* under sl_gc_mu */
/* Generational nursery: bytes allocated since the last MINOR
 * collection, and the nursery threshold that triggers one. A minor
 * collection sweeps only sl_gc_young (plus tracing roots-reachable old
 * subgraphs -- see sl_gc_collect_minor_real); a major collection
 * (sl_gc_threshold, paced to the live set as before) sweeps both
 * generations. Default 512KB (phase-3 tuning; see the tuning log). */
static _Atomic size_t sl_gc_bytes_since_minor = 0;
/* Adaptive (fix-gc.md 1.2a): starts at SL_GC_NURSERY_BASE and doubles,
 * up to sl_gc_nursery_max, while minors cost more than an eighth of the
 * time between them and find more than an eighth of it live; halves back
 * otherwise (sl_gc_nursery_adapt). A minor's cost follows what is live, not the
 * nursery's size: on the quote server each minor re-marked about four
 * requests' worth of young data once per request, so a 4 MB nursery
 * served 25% more req/s with a lower p99 and no more RSS. A program
 * whose minors are cheap -- most of them -- keeps the small nursery and
 * its footprint (the compute benchmark: 2.7% of time in minors, 7 MB
 * RSS at 512 KB against 12 MB at 4 MB for no speed). Read by every
 * allocating thread, written by the collector: atomic, relaxed. */
#define SL_GC_NURSERY_BASE (512 * 1024)
static _Atomic size_t sl_gc_nursery_threshold = SL_GC_NURSERY_BASE;
static size_t sl_gc_nursery_max = SL_GC_NURSERY_BASE;
static long long sl_gc_minor_last_end_ns = 0;
static int sl_gc_nursery_fixed = 0;
static _Atomic int sl_gc_collect_minor_pending = 0;
/* SLANG_GC_THRESHOLD_KB: collect every that-many KB allocated, and never
 * grow the threshold. For tests: a rooting bug shows up only when a
 * collection lands at the one safepoint where the object is unrooted,
 * and at the default threshold (which grows to 256MB) collections are
 * too rare to land there reliably. */
/* SLANG_GC_NURSERY_KB: minor-collect every that-many KB allocated into
 * the nursery (sl_gc_young). Same parse-once-at-first-registration
 * pattern as SLANG_GC_THRESHOLD_KB: a fixed threshold for tests so a
 * low value forces a minor collection on nearly every allocation. */
static int sl_gc_threshold_fixed = 0;
static _Atomic unsigned long long sl_gc_stat_survived = 0;
static _Atomic unsigned long long sl_gc_stat_allocated_cycle = 0;

static _Atomic unsigned long long sl_gc_stat_collects = 0;
static _Atomic unsigned long long sl_gc_stat_minor_collects = 0;
static _Atomic unsigned long long sl_gc_stat_allocs = 0;
static _Atomic unsigned long long sl_gc_stat_alloc_bytes = 0;
static _Atomic unsigned long long sl_gc_stat_pause_ns_total = 0;
static _Atomic unsigned long long sl_gc_stat_pause_ns_max = 0;
static _Atomic unsigned long long sl_gc_stat_minor_pause_ns_max = 0;
static _Atomic unsigned long long sl_gc_stat_minor_pause_ns_total = 0;
static _Atomic unsigned long long sl_gc_stat_swept = 0;
static _Atomic unsigned long long sl_gc_stat_minor_swept = 0;
static _Atomic unsigned long long sl_gc_stat_marked = 0;
static _Atomic unsigned long long sl_gc_stat_promoted = 0;
#define SL_GC_STAT_BUCKETS 16
static _Atomic unsigned long long sl_gc_stat_pause_buckets[SL_GC_STAT_BUCKETS];

static int sl_gc_stat_enabled(void) {
    static int cached = -1;
    if (cached < 0)
        cached = getenv("SLANG_GC_STAT") ? 1 : 0;
    return cached;
}

static void sl_gc_stat_pause(long long ns, size_t marked, size_t swept) {
    if (!sl_gc_stat_enabled())
        return;
    atomic_fetch_add_explicit(&sl_gc_stat_collects, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sl_gc_stat_pause_ns_total, (unsigned long long)(ns > 0 ? ns : 0), memory_order_relaxed);
    unsigned long long prev = atomic_load_explicit(&sl_gc_stat_pause_ns_max, memory_order_relaxed);
    while ((unsigned long long)(ns > 0 ? ns : 0) > prev &&
           !atomic_compare_exchange_weak_explicit(&sl_gc_stat_pause_ns_max, &prev,
                                                  (unsigned long long)(ns > 0 ? ns : 0),
                                                  memory_order_relaxed, memory_order_relaxed)) {
    }
    atomic_fetch_add_explicit(&sl_gc_stat_marked, (unsigned long long)marked, memory_order_relaxed);
    atomic_fetch_add_explicit(&sl_gc_stat_swept, (unsigned long long)swept, memory_order_relaxed);
    atomic_fetch_add_explicit(&sl_gc_stat_survived, (unsigned long long)marked, memory_order_relaxed);
    atomic_fetch_add_explicit(&sl_gc_stat_allocated_cycle, (unsigned long long)(marked + swept), memory_order_relaxed);
    int b = 0;
    long long bound = 100000;
    while (b + 1 < SL_GC_STAT_BUCKETS && ns >= bound) {
        bound *= 2;
        b++;
    }
    atomic_fetch_add_explicit(&sl_gc_stat_pause_buckets[b], 1, memory_order_relaxed);
}

static void sl_gc_stat_minor_pause(long long ns, size_t swept, size_t promoted) {
    if (!sl_gc_stat_enabled())
        return;
    atomic_fetch_add_explicit(&sl_gc_stat_minor_collects, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sl_gc_stat_minor_pause_ns_total,
                              (unsigned long long)(ns > 0 ? ns : 0),
                              memory_order_relaxed);
    unsigned long long prev = atomic_load_explicit(&sl_gc_stat_minor_pause_ns_max, memory_order_relaxed);
    while ((unsigned long long)(ns > 0 ? ns : 0) > prev &&
           !atomic_compare_exchange_weak_explicit(&sl_gc_stat_minor_pause_ns_max, &prev,
                                                  (unsigned long long)(ns > 0 ? ns : 0),
                                                  memory_order_relaxed, memory_order_relaxed)) {
    }
    atomic_fetch_add_explicit(&sl_gc_stat_minor_swept, (unsigned long long)swept, memory_order_relaxed);
    atomic_fetch_add_explicit(&sl_gc_stat_promoted, (unsigned long long)promoted, memory_order_relaxed);
}

/* Where a pause goes, per kind (SLANG_GC_STAT): time-to-safepoint (the
 * rendezvous, until every thread has acked or is blocked), harvest of
 * pending lists and remembered shards, the sl_gc_set build, mark, sweep,
 * and the tail (page prune, trim, release). Totals in ns; ttsp also keeps
 * its max. tasks is every task the harvest walks, rem the remembered
 * entries a minor traces. All gated, so the collector pays one branch. */
enum { SL_GC_PH_TTSP, SL_GC_PH_HARVEST, SL_GC_PH_SET, SL_GC_PH_MARK,
       SL_GC_PH_SWEEP, SL_GC_PH_TAIL, SL_GC_PH_N };
static const char *const sl_gc_ph_name[SL_GC_PH_N] = {
    "ttsp", "harvest", "setbuild", "mark", "sweep", "tail"};
static _Atomic unsigned long long sl_gc_stat_ph[2][SL_GC_PH_N];
static _Atomic unsigned long long sl_gc_stat_ttsp_max[2];
static _Atomic unsigned long long sl_gc_stat_tasks_walked[2];
static _Atomic unsigned long long sl_gc_stat_rem_entries;

/* Phase marks for one collection: t[i] is when phase i ended, t0 the
 * start. Only read when stat is on. */
typedef struct {
    int on;
    long long t0;
    long long t[SL_GC_PH_N];
} sl_gc_phase_clock;

static inline void sl_gc_ph_mark(sl_gc_phase_clock *c, int ph) {
    if (c->on)
        c->t[ph] = sl_rt_monotonic_ns();
}

static void sl_gc_stat_phases(const sl_gc_phase_clock *c, int major) {
    if (!c->on)
        return;
    long long prev = c->t0;
    for (int i = 0; i < SL_GC_PH_N; i++) {
        long long d = c->t[i] - prev;
        if (d < 0)
            d = 0;
        atomic_fetch_add_explicit(&sl_gc_stat_ph[major][i],
                                  (unsigned long long)d, memory_order_relaxed);
        if (i == SL_GC_PH_TTSP) {
            unsigned long long m = atomic_load_explicit(
                &sl_gc_stat_ttsp_max[major], memory_order_relaxed);
            while ((unsigned long long)d > m &&
                   !atomic_compare_exchange_weak_explicit(
                       &sl_gc_stat_ttsp_max[major], &m, (unsigned long long)d,
                       memory_order_relaxed, memory_order_relaxed)) {
            }
        }
        prev = c->t[i];
    }
}

/* Stopped threads' waits for a pause to end (sl_gc_ack_and_wait), and
 * how many of them slept rather than spun to the end: the spin covers
 * only the first few microseconds. */
static _Atomic unsigned long long sl_gc_stat_stw_waits = 0;
static _Atomic unsigned long long sl_gc_stat_stw_sleeps = 0;

static void sl_gc_stat_dump(void) {
    if (!sl_gc_stat_enabled())
        return;
    unsigned long long collects = atomic_load_explicit(&sl_gc_stat_collects, memory_order_relaxed);
    unsigned long long minor_collects = atomic_load_explicit(&sl_gc_stat_minor_collects, memory_order_relaxed);
    unsigned long long allocs = atomic_load_explicit(&sl_gc_stat_allocs, memory_order_relaxed);
    unsigned long long bytes = atomic_load_explicit(&sl_gc_stat_alloc_bytes, memory_order_relaxed);
    unsigned long long total = atomic_load_explicit(&sl_gc_stat_pause_ns_total, memory_order_relaxed);
    unsigned long long max = atomic_load_explicit(&sl_gc_stat_pause_ns_max, memory_order_relaxed);
    unsigned long long minor_max = atomic_load_explicit(&sl_gc_stat_minor_pause_ns_max, memory_order_relaxed);
    unsigned long long minor_total = atomic_load_explicit(&sl_gc_stat_minor_pause_ns_total, memory_order_relaxed);
    unsigned long long minor_swept = atomic_load_explicit(&sl_gc_stat_minor_swept, memory_order_relaxed);
    unsigned long long promoted = atomic_load_explicit(&sl_gc_stat_promoted, memory_order_relaxed);
    unsigned long long marked = atomic_load_explicit(&sl_gc_stat_marked, memory_order_relaxed);
    unsigned long long swept = atomic_load_explicit(&sl_gc_stat_swept, memory_order_relaxed);
    unsigned long long surv = atomic_load_explicit(&sl_gc_stat_survived, memory_order_relaxed);
    unsigned long long cyc = atomic_load_explicit(&sl_gc_stat_allocated_cycle, memory_order_relaxed);
    fprintf(stderr, "slang-gc-stat collects=%llu minor_collects=%llu allocs=%llu alloc_bytes=%llu pause_ns_total=%llu pause_ns_max=%llu marked=%llu swept=%llu survived=%llu cycle_allocs=%llu threshold=%zu minor_pause_ns_max=%llu minor_swept=%llu promoted=%llu nursery_threshold=%zu minor_pause_ns_total=%llu\n",
            collects, minor_collects, allocs, bytes, total, max, marked, swept, surv, cyc, sl_gc_threshold, minor_max, minor_swept, promoted,
            atomic_load_explicit(&sl_gc_nursery_threshold, memory_order_relaxed),
            minor_total);
    fprintf(stderr, "slang-gc-stat pause_buckets_ns=[");
    long long bound = 100000;
    for (int b = 0; b < SL_GC_STAT_BUCKETS; b++) {
        unsigned long long n = atomic_load_explicit(&sl_gc_stat_pause_buckets[b], memory_order_relaxed);
        fprintf(stderr, "%s<%lld:%llu", b ? "," : "", bound, n);
        bound *= 2;
    }
    fprintf(stderr, "]\n");
    for (int k = 0; k < 2; k++) {
        const char *kind = k ? "major" : "minor";
        fprintf(stderr, "slang-gc-stat %s_phases", kind);
        for (int i = 0; i < SL_GC_PH_N; i++)
            fprintf(stderr, " %s_%s_ns=%llu", kind, sl_gc_ph_name[i],
                    atomic_load_explicit(&sl_gc_stat_ph[k][i],
                                         memory_order_relaxed));
        fprintf(stderr, " %s_ttsp_ns_max=%llu %s_tasks_walked=%llu", kind,
                atomic_load_explicit(&sl_gc_stat_ttsp_max[k],
                                     memory_order_relaxed),
                kind,
                atomic_load_explicit(&sl_gc_stat_tasks_walked[k],
                                     memory_order_relaxed));
        if (!k)
            fprintf(stderr, " minor_rem_entries=%llu",
                    atomic_load_explicit(&sl_gc_stat_rem_entries,
                                         memory_order_relaxed));
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "slang-gc-stat stw_waits=%llu stw_sleeps=%llu\n",
            atomic_load_explicit(&sl_gc_stat_stw_waits, memory_order_relaxed),
            atomic_load_explicit(&sl_gc_stat_stw_sleeps, memory_order_relaxed));
}

__attribute__((destructor))
static void sl_gc_stat_atexit(void) { sl_gc_stat_dump(); }

/* A root array can legitimately hold a pointer that was never
 * sl_gc_alloc'd at all: every str-typed value is type_is_gc_ptr-true
 * and gets rooted like any other GC pointer, but a slang string
 * LITERAL compiles directly to a C string literal (c_string_literal,
 * core.c) -- a raw pointer into .rodata, not a heap allocation.
 * Treating it as one (reading the sl_gc_obj header presumed to sit
 * just before it) is undefined behavior -- caught by ASan as a
 * global-buffer-overflow the first time a real collection actually
 * ran against a program using string literals (which is effectively
 * all of them). This hash set of every currently-live sl_gc_alloc'd
 * payload address lets sl_gc_mark tell 'one of mine' from 'the type
 * system says pointer, but this specific value isn't a heap
 * allocation' before ever computing ptr - 1, instead of assuming
 * every non-NULL pointer handed to it is safe to treat as a header.
 *
 * Built once at the START of each collection (sl_gc_set_build) and
 * freed at the end of it, rather than maintained incrementally on
 * every allocation. Three reasons, in the order they were found:
 *
 *  1. CORRECTNESS. Incremental maintenance inserted at splice time,
 *     so an object still sitting in a task's un-spliced batch was
 *     in no table -- and sl_gc_mark's first act is to reject
 *     anything not in the table. That made the collector's own
 *     'trace every task's pending batch' loop a silent no-op,
 *     defeating the exact hazard its comment describes: a pending
 *     object's children ARE on sl_gc_all and WERE being swept out
 *     from under it. Building from sl_gc_all AND every live task's
 *     pending list closes it by construction.
 *  2. MEMORY. The table is 8 bytes per live object at a 0.5 load
 *     factor -- so 16 bytes per object of permanently-resident
 *     memory, ~21 with the doubling slack, against a measured total
 *     of ~113 B/object. It has exactly one reader (sl_gc_mark) and
 *     that reader only runs during a collection, so keeping it
 *     resident between collections bought nothing.
 *  3. THROUGHPUT. The insert ran under sl_gc_mu, the mutex todo.md
 *     names as the top remaining performance ceiling.
 *
 * Not a new cost: the wholesale rebuild this replaces already walked
 * every survivor once per collection. It moved from after the sweep
 * to before the mark, and gained the pending lists.
 */
static void **sl_gc_set = NULL;
static size_t sl_gc_set_cap = 0;
static size_t sl_gc_set_count = 0;

static size_t sl_gc_ptrhash(void *p) {
    uintptr_t x = (uintptr_t)p;
    x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33;
    return (size_t)x;
}

/* linear-probing insert into a fixed-capacity table -- the caller
 * (sl_gc_set_build) sizes the table for the whole population up
 * front, so there is no grow path and no load-factor check here. */
static void sl_gc_set_raw_insert(void **tbl, size_t cap, void *p) {
    size_t i = sl_gc_ptrhash(p) & (cap - 1);
    while (tbl[i]) i = (i + 1) & (cap - 1);
    tbl[i] = p;
}

static int sl_gc_set_contains(void *p) {
    if (!sl_gc_set_cap) return 0;
    size_t i = sl_gc_ptrhash(p) & (sl_gc_set_cap - 1);
    for (;;) {
        if (!sl_gc_set[i]) return 0;
        if (sl_gc_set[i] == p) return 1;
        i = (i + 1) & (sl_gc_set_cap - 1);
    }
}

/* one entry per registered thread, pointing at that thread's own
 * _Thread_local storage -- valid as long as the thread lives, since
 * each thread publishes the address of its own TLS vars at
 * registration time (a standard, portable technique: the address of
 * a _Thread_local variable is stable for the lifetime of the owning
 * thread). Guarded by sl_gc_mu. */
/* Defined with the young pages below; named here for the registry. */
typedef struct sl_gc_page sl_gc_page;
typedef struct sl_gc_worker_state sl_gc_worker_state;

/* Late page functions the registry entry/exit needs. */
static void sl_gc_pages_publish(void);
static void sl_gc_pages_orphan_all(void);
static void sl_gc_page_stat_dump(void);
static int sl_gc_page_debug_enabled(void);

typedef struct sl_gc_thread {
    struct sl_gc_thread *next;
    sl_task **task_slot; /* &sl_rt_current_task for this OS thread --
        NOT &sl_rt_current_task->safepoint_top. The latter (this
        field's shape before Tier 11's second slice) is a single
        dereference cached at registration time: correct as long as
        sl_rt_current_task never changes for the thread's whole life
        (true before a worker pool exists, since one task lives and
        dies with its OS thread), but stale the instant a pooled
        worker gets reassigned to a new task -- the collector would
        keep reading whichever task's safepoint_top field happened
        to be current AT REGISTRATION, not the task actually running
        now. task_slot fixes this by pointing at the STABLE
        _Thread_local variable itself; sl_gc_collect's mark phase
        below dereferences it twice instead of once, always landing
        on whichever task is current at SCAN time. */
    _Atomic int *blocked_ptr;
    _Atomic unsigned long *acked_cycle_ptr;
    sl_gc_worker_state *state_ptr; /* &sl_gc_wstate for this OS
        thread -- published at registration like task_slot, so the
        sweep-end page prune can reach a stopped thread's page list
        (same pattern). */
} sl_gc_thread;
static sl_gc_thread *sl_gc_threads = NULL;

/* Task-owned allocation shard. Mutators never take sl_gc_mu: objects
 * stay on sl_task.gc_pend_* until the next STW harvest or the task
 * dies (lock-free retire onto sl_gc_retired). The byte counter is
 * an atomic published every SL_GC_PENDING_BATCH allocs.
 *
 * A collection first splices EVERY task's pending list onto sl_gc_all
 * (sl_gc_harvest_task), before building sl_gc_set or marking anything,
 * so a pending object is an ordinary object for that cycle: kept if a
 * root reaches it, swept if not. Doing that is safe because mark does
 * not start until every registered thread is acked or gc_blocked, and
 * neither state is reachable from sl_gc_alloc.
 *
 * Pending lists used to be traced as ROOTS instead, and spliced only
 * after the sweep. When they held at most SL_GC_PENDING_BATCH objects
 * that was harmless; once shards stayed on the task until the next
 * collection, it meant everything allocated since the last collection
 * was kept alive by it -- so every short-lived object survived one full
 * extra cycle, and a loop producing nothing but garbage held two cycles
 * of it: 1.2GB of RSS for 18M small results (the pg streaming case). */
#define SL_GC_PENDING_BATCH 32
static _Atomic int sl_gc_stop_requested = 0;
static _Atomic unsigned long sl_gc_cycle = 0;
/* Stopped threads sleep here for the rest of a pause (sl_gc_ack_and_wait)
 * instead of calling sched_yield in a loop. On Linux that loop was a
 * syscall per turn that returned at once -- every CPU but the
 * collector's is idle during a pause -- and under a VM each turn cost
 * reschedule IPIs too: profiled on the quote server in a Linux
 * container, the stopped threads' yielding was 60% of all CPU. The
 * collector raises and clears sl_gc_stop_requested, and bumps
 * sl_gc_cycle, under sl_gc_stw_mu, and broadcasts when anyone sleeps,
 * so a sleeper never misses the end of a pause or the start of a
 * chained one it must ack. Lock order: sl_gc_mu before sl_gc_stw_mu. */
static pthread_mutex_t sl_gc_stw_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sl_gc_stw_cv = PTHREAD_COND_INITIALIZER;
static int sl_gc_stw_sleepers = 0; /* under sl_gc_stw_mu */
/* Pause-instruction turns a stopped thread spins before sleeping: a few
 * microseconds, so a pause that ends that fast costs no wakeup. */
#define SL_GC_STW_SPIN 256
static _Atomic int sl_gc_collect_pending = 0;
static _Atomic int sl_gc_collecting = 0;

static _Thread_local sl_gc_thread sl_rt_gc_reg;
static _Thread_local _Atomic int sl_rt_gc_blocked = 0;
static _Thread_local _Atomic unsigned long sl_rt_gc_acked_cycle = 0;
/* sl_gc_ack_and_wait runs on a task's stack too (via the checkin slow
   path), so it writes the ack through this (SL_RT_TLS_ADDR_FN). */
SL_RT_TLS_ADDR_FN(sl_rt_tls_gc_acked_cycle, _Atomic unsigned long,
                  sl_rt_gc_acked_cycle)

static void sl_gc_collect(void);
static void sl_gc_collect_minor(void);
static void sl_gc_mark(void *ptr);
static void sl_gc_mark_minor(void *ptr);
/* Tier 12 (leaf-loop poll): the fast-path condition of sl_rt_gc_checkin
 * as a callable predicate for generated leaf-loop polls: nonzero when
 * a collection has been requested and the next safepoint must check
 * in. Reads only process-global atomics (acquire), never TLS — safe
 * to call every iteration, including on arm64 where the compiler
 * caches thread pointers. Generated code calls this rather than
 * inlining three atomic loads, so the flag set stays in one place. */
static inline int sl_gc_poll_needed(void) {
    return atomic_load_explicit(&sl_gc_stop_requested,
                                memory_order_acquire) ||
           atomic_load_explicit(&sl_gc_collect_pending,
                                memory_order_acquire) ||
           atomic_load_explicit(&sl_gc_collect_minor_pending,
                                memory_order_acquire);
}
typedef void (*sl_gc_markfn_t)(void *ptr);
/* The mark function the CURRENT collection's root scan should use
 * (forward-declared here because sl_gc_scan_conservative is defined
 * before sl_gc_mark itself; set by sl_gc_collect/sl_gc_collect_minor
 * before calling sl_gc_mark_roots). */
static void (*sl_gc_cur_mark)(void *ptr);

static void sl_gc_mark_entry_arg_fn(sl_task *t, sl_gc_markfn_t mark) {
    if (!t) return;
    if (t->entry_arg_trace)
        t->entry_arg_trace(t->entry_arg, mark);
    else
        mark(t->entry_arg);
}

static void sl_gc_mark_entry_arg(sl_task *t) {
    sl_gc_mark_entry_arg_fn(t, sl_gc_mark);
}

static void sl_gc_register_thread(void) {
    /* Tier 11: this OS thread's chain lives in a per-thread sl_task
     * (sl_rt_current_task, runtime_core.c) rather than a bare
     * _Thread_local safepoint pointer -- see task_slot's own field
     * comment above for why this must be &sl_rt_current_task itself,
     * not &sl_rt_current_task->safepoint_top. Still true today (one
     * task per OS thread, no scheduler running yet) that
     * sl_rt_current_task never actually changes after this point --
     * task_slot's extra indirection costs nothing observable now and
     * is exactly what makes it safe for a future worker pool to
     * reassign sl_rt_current_task freely. */
    memset(&sl_rt_task_storage, 0, sizeof(sl_rt_task_storage));
    sl_rt_current_task = &sl_rt_task_storage;
    sl_rt_gc_reg.task_slot = &sl_rt_current_task;
    sl_rt_gc_reg.blocked_ptr = &sl_rt_gc_blocked;
    sl_rt_gc_reg.acked_cycle_ptr = &sl_rt_gc_acked_cycle;
    sl_gc_pages_publish();
    pthread_mutex_lock(&sl_gc_mu);
    sl_rt_gc_reg.next = sl_gc_threads;
    sl_gc_threads = &sl_rt_gc_reg;
    if (!sl_gc_threshold_fixed) {
        const char *kb = getenv("SLANG_GC_THRESHOLD_KB");
        long v = kb ? strtol(kb, NULL, 10) : 0;
        if (v > 0) {
            sl_gc_threshold = (size_t)v * 1024;
            sl_gc_threshold_fixed = 1;
        }
    }
    if (!sl_gc_nursery_fixed) {
        const char *nkb = getenv("SLANG_GC_NURSERY_KB");
        long nv = nkb ? strtol(nkb, NULL, 10) : 0;
        if (nv > 0) {
            atomic_store_explicit(&sl_gc_nursery_threshold,
                                  (size_t)nv * 1024, memory_order_relaxed);
            sl_gc_nursery_fixed = 1;
        }
    }
    pthread_mutex_unlock(&sl_gc_mu);
}

/* ack the current STW cycle and wait for it to end. A loop tracking
 * the actual cycle number, not a single ack-then-spin-on-a-boolean:
 * sl_gc_stop_requested is one flag reused across every cycle, and a
 * thread parked on 'while (stop_requested) yield' can miss a brief
 * 0-then-1 transition entirely if two collections happen back to
 * back -- it keeps seeing 1 straight through the boundary, having
 * already acked the older cycle, and never re-acks the newer one.
 * Re-checking the cycle number on every spin and re-acking the
 * instant it moves closes that gap: a newer cycle number is itself
 * proof the one this thread acked already finished (only one
 * collection is ever in flight, via the sl_gc_collecting exchange
 * below), so there's nothing lost by no longer waiting for a clean
 * 0 observation on the shared flag. */
static inline void sl_gc_cpu_relax(void) {
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}

static inline void sl_gc_ack_and_wait(void) {
    _Atomic unsigned long *acked = sl_rt_tls_gc_acked_cycle();
    unsigned long cyc = atomic_load_explicit(&sl_gc_cycle,
                                              memory_order_acquire);
    atomic_store_explicit(acked, cyc, memory_order_release);
    int spins = 0;
    int slept = 0;
    while (atomic_load_explicit(&sl_gc_stop_requested,
                                 memory_order_acquire)) {
        if (spins < SL_GC_STW_SPIN) {
            spins++;
            sl_gc_cpu_relax();
        } else {
            slept = 1;
            pthread_mutex_lock(&sl_gc_stw_mu);
            sl_gc_stw_sleepers++;
            while (atomic_load_explicit(&sl_gc_stop_requested,
                                         memory_order_acquire) &&
                   atomic_load_explicit(&sl_gc_cycle,
                                         memory_order_acquire) == cyc)
                pthread_cond_wait(&sl_gc_stw_cv, &sl_gc_stw_mu);
            sl_gc_stw_sleepers--;
            pthread_mutex_unlock(&sl_gc_stw_mu);
        }
        unsigned long now = atomic_load_explicit(&sl_gc_cycle,
                                                  memory_order_acquire);
        if (now != cyc) {
            cyc = now;
            atomic_store_explicit(acked, cyc, memory_order_release);
        }
    }
    if ((spins || slept) && sl_gc_stat_enabled()) {
        atomic_fetch_add_explicit(&sl_gc_stat_stw_waits, 1,
                                  memory_order_relaxed);
        if (slept)
            atomic_fetch_add_explicit(&sl_gc_stat_stw_sleeps, 1,
                                      memory_order_relaxed);
    }
}

/* This can't be 'checkin, then separately unlink' -- there is a real
 * gap between 'I last checked in and saw nothing pending' and 'I
 * actually removed myself from sl_gc_threads', and a brand new
 * collection can start in exactly that gap, snapshot the registry
 * while this thread is still in it, and then have this thread finish
 * unregistering and return -- tearing down its own TLS while the
 * collector still holds a pointer into it. Re-checking
 * stop_requested *inside the same lock* that does the unlink closes
 * this: sl_gc_collect() also needs sl_gc_mu for its snapshot, and
 * always sets stop_requested before acquiring it, so mutex ordering
 * guarantees either this thread unlinks before any snapshot can see
 * it, or the snapshot (and the store, strictly earlier) already
 * happened, in which case this thread's own load inside the lock is
 * guaranteed to observe it. */
static void sl_gc_unregister_thread(void) {
    for (;;) {
        pthread_mutex_lock(&sl_gc_mu);
        if (atomic_load_explicit(&sl_gc_stop_requested,
                                  memory_order_acquire)) {
            pthread_mutex_unlock(&sl_gc_mu);
            sl_gc_ack_and_wait();
            continue;
        }
        sl_gc_thread **pp = &sl_gc_threads;
        while (*pp) {
            if (*pp == &sl_rt_gc_reg) { *pp = sl_rt_gc_reg.next; break; }
            pp = &(*pp)->next;
        }
        /* Hand off this worker's young pages (own-thread teardown):
         * empty ones freed now, the rest orphaned under this same lock
         * for the next sweep. Live headers keep that memory valid. */
        sl_gc_pages_orphan_all();
        pthread_mutex_unlock(&sl_gc_mu);
        return;
    }
}

/* called from sl_rt_safepoint_enter, and around each of the six
 * blocking runtime calls. A loop, not a one-shot check: there is a
 * real window between another thread's atomic_exchange on
 * sl_gc_collecting succeeding and its first line inside
 * sl_gc_collect() actually storing stop_requested = 1. A thread
 * whose own stop_requested load happens in that window sees 0 *and*
 * loses the collecting exchange -- a one-shot version then returns
 * having done nothing at all, no ack, no wait. Looping back to
 * re-check stop_requested instead closes the window: the winner is
 * at most a few instructions from its own store. */
/* The slow half: everything that actually needs the preempt bracket.
 * Split out so the common case below touches no thread-local state
 * at all. */
static void sl_rt_gc_checkin_slow(void) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return, not just
     * around sl_gc_collect's own sl_gc_mu use -- the losing/spin path
     * (sched_yield) doesn't hold sl_gc_mu itself but is harmless to
     * cover too (a task mid-spin here isn't doing useful work a
     * preemption would usefully interleave around anyway). No
     * separate bracket needed inside sl_gc_collect itself: it's only
     * ever called from this one call site, already covered. */
    sl_rt_preempt_disable();
    for (;;) {
        if (atomic_load_explicit(&sl_gc_stop_requested,
                                  memory_order_acquire)) {
            sl_gc_ack_and_wait();
            sl_rt_preempt_enable();
            return;
        }
        if (!atomic_load_explicit(&sl_gc_collect_pending,
                                   memory_order_acquire) &&
            !atomic_load_explicit(&sl_gc_collect_minor_pending,
                                   memory_order_acquire)) {
            sl_rt_preempt_enable();
            return;
        }
        if (!atomic_exchange_explicit(&sl_gc_collecting, 1,
                                       memory_order_acq_rel)) {
            int want_major = atomic_load_explicit(&sl_gc_collect_pending,
                                                  memory_order_acquire);
            /* A major collection subsumes any pending minor: it sweeps
             * both generations. Prefer it when both flags are set. */
            if (want_major)
                sl_gc_collect();
            else
                sl_gc_collect_minor();
            sl_rt_preempt_enable();
            return;
        }
        sched_yield();
    }
}

/* Called at EVERY safepoint -- every loop back-edge and every
 * root-bearing call site in generated code -- so its cost is the
 * runtime's per-unit-of-work tax, and it showed up as exactly that.
 * A CPU profile of the demo HTTP server under load put
 * sl_rt_maybe_yield at ~84% of the request path, with this function
 * dominating it and _tlv_get_addr underneath.
 *
 * The reason was that the old version bracketed itself entry-to-exit
 * with sl_rt_preempt_disable/enable. Each of those calls sl_rt_cur(),
 * which on Darwin is a retry loop around a CALL into dyld
 * (_tlv_get_addr) -- a thread-local read is not a register offset
 * here -- plus an acq_rel atomic RMW on the task. So the fast path,
 * whose entire job is to read two globals and find nothing to do,
 * was paying two dyld calls and two read-modify-writes to do it.
 *
 * Nothing about those two loads needs protecting. The bracket exists
 * for sl_gc_ack_and_wait and sl_gc_collect below -- being
 * async-preempted while holding sl_gc_mu is what freezes the lock
 * and wedges the process -- and both live in the slow path. An async
 * preemption landing between these two loads corrupts nothing: they
 * are loads. And a collection that starts immediately after the
 * check is handled exactly as it was before, by the next safepoint;
 * the old code raced the same way, it just paid more to do it.
 *
 * Ordering: acquire on both, so a thread that observes neither flag
 * genuinely has nothing to acknowledge. */
static inline void sl_rt_gc_checkin(void) {
    if (sl_gc_poll_needed())
        sl_rt_gc_checkin_slow();
}

/* zero-filled, like GC_malloc's documented guarantee -- no existing
 * call site relying on that needs auditing. Collection is never
 * triggered synchronously from here: several hand-written runtime
 * helpers (sl_bytes_new, sl_chan_new, sl_map_new/grow) do more than
 * one allocation before returning a single logical object, with no
 * safepoint bracket of their own around the intermediate steps -- an
 * in-place collection could sweep the first allocation before the
 * second one is even made. Crossing the threshold only sets a
 * pending flag; the actual mark+sweep is deferred to the next
 * sl_rt_gc_checkin(), which by construction only ever fires at a
 * call-site or loop-back-edge bracket boundary, exactly where
 * everything currently live is already registered in the chain and
 * no hand-written helper is mid-flight. This makes the threshold
 * soft, not exact -- acceptable, matching the 'not a pause-time
 * optimization' stance for this collector's first version. */
/* Tier 11 eighth slice: bracketed around the sl_gc_mu-held section
 * specifically -- this is the concrete, predicted-in-advance
 * failure mode a first activation of the real handler reproduced
 * immediately under real load before this bracket existed: async-
 * preempting a task while it holds sl_gc_mu here freezes that lock
 * held while the task sits queued (possibly for a while, under a
 * saturated pool); a completely different thread's own
 * sl_rt_gc_checkin/sl_gc_collect then blocks on sl_gc_mu
 * indefinitely, and every OTHER thread spins in sl_gc_ack_and_wait
 * waiting for a quiescence that can never arrive -- not a crash,
 * effectively a livelock, and confirmed directly: cc_real_preempt
 * at 2,000 tasks went from ~1.4s (1,000 tasks) to still not done
 * after 2 minutes, sample showing 74% of all samples in swtch_pri
 * (the collector's own spin-wait), before this bracket was added. */
/* Add `delta` allocated bytes to the collection triggers. Two atomic RMWs
 * on lines every worker writes: called per worker every
 * SL_GC_PUBLISH_BATCH bytes (sl_gc_alloc_gen), not per allocation. */
static void sl_gc_publish_delta(size_t delta) {
    if (!delta) return;
    /* Majors are paced by promotion (sl_gc_collect_minor_real), except
     * in the fixed-threshold test mode, which lands them as often as
     * possible. */
    if (sl_gc_threshold_fixed) {
        size_t prev = atomic_fetch_add_explicit(&sl_gc_bytes_since_collect,
                                                delta, memory_order_relaxed);
        if (prev + delta >= sl_gc_threshold)
            atomic_store_explicit(&sl_gc_collect_pending, 1,
                                   memory_order_release);
    }
    size_t mprev = atomic_fetch_add_explicit(&sl_gc_bytes_since_minor, delta,
                                             memory_order_relaxed);
    if (mprev + delta >= atomic_load_explicit(&sl_gc_nursery_threshold,
                                              memory_order_relaxed))
        atomic_store_explicit(&sl_gc_collect_minor_pending, 1,
                               memory_order_release);
}

static void sl_gc_retire_list(sl_gc_obj *head, sl_gc_obj *tail) {
    sl_gc_obj *old = atomic_load_explicit(&sl_gc_retired, memory_order_relaxed);
    do {
        tail->next = old;
    } while (!atomic_compare_exchange_weak_explicit(
                 &sl_gc_retired, &old, head,
                 memory_order_release, memory_order_relaxed));
}

static pthread_mutex_t sl_gc_rem_orphan_mu = PTHREAD_MUTEX_INITIALIZER;
static sl_gc_obj **sl_gc_rem_orphans = NULL;
static size_t sl_gc_rem_orphan_n = 0;
static size_t sl_gc_rem_orphan_cap = 0;

/* Remembered-set entries of tasks that finished before a collection
 * harvested them. A task's shard (gc_rem_*) is otherwise reached only
 * through the task, and a finished task is on no list a collection
 * walks: its entries were lost while the objects kept remembered = 1,
 * which made every later barrier on them a no-op -- an old object
 * written by a task that then exited could gain young children no minor
 * ever looked for. The shard's buffer leaked with it, since
 * sl_task_grab zeroes a recycled task. Workers finish tasks
 * concurrently, hence the lock; the next collection's harvest
 * (sl_gc_harvest_rem_all) drains it. */
static void sl_gc_orphan_rem(sl_task *t) {
    if (!t->gc_rem_buf)
        return;
    if (t->gc_rem_n) {
        pthread_mutex_lock(&sl_gc_rem_orphan_mu);
        size_t need = sl_gc_rem_orphan_n + t->gc_rem_n;
        if (need > sl_gc_rem_orphan_cap) {
            size_t ncap = sl_gc_rem_orphan_cap ? sl_gc_rem_orphan_cap : 64;
            while (ncap < need) ncap *= 2;
            sl_gc_obj **nb = (sl_gc_obj **)realloc(
                sl_gc_rem_orphans, ncap * sizeof(sl_gc_obj *));
            if (!nb) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
            sl_gc_rem_orphans = nb;
            sl_gc_rem_orphan_cap = ncap;
        }
        memcpy(sl_gc_rem_orphans + sl_gc_rem_orphan_n, t->gc_rem_buf,
               t->gc_rem_n * sizeof(sl_gc_obj *));
        sl_gc_rem_orphan_n = need;
        pthread_mutex_unlock(&sl_gc_rem_orphan_mu);
    }
    free(t->gc_rem_buf);
    t->gc_rem_buf = NULL;
    t->gc_rem_n = 0;
    t->gc_rem_cap = 0;
}

/* Collector-side remembered entry (stopped-the-world): an object the
 * minor just promoted that may hold young pointers, for the next minor's
 * harvest (sl_gc_harvest_rem_all drains this list with the tasks'
 * shards). */
static void sl_gc_rem_orphan_push(sl_gc_obj *h) {
    pthread_mutex_lock(&sl_gc_rem_orphan_mu);
    if (sl_gc_rem_orphan_n == sl_gc_rem_orphan_cap) {
        size_t ncap = sl_gc_rem_orphan_cap ? sl_gc_rem_orphan_cap * 2 : 64;
        sl_gc_obj **nb = (sl_gc_obj **)realloc(
            sl_gc_rem_orphans, ncap * sizeof(sl_gc_obj *));
        if (!nb) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
        sl_gc_rem_orphans = nb;
        sl_gc_rem_orphan_cap = ncap;
    }
    sl_gc_rem_orphans[sl_gc_rem_orphan_n++] = h;
    pthread_mutex_unlock(&sl_gc_rem_orphan_mu);
}

/* A finished task's GC state, handed over before the task is released:
 * its pending allocations to sl_gc_retired, its remembered entries to
 * sl_gc_rem_orphans. */
static void sl_gc_flush_task(sl_task *t) {
    if (!t) return;
    sl_gc_orphan_rem(t);
    if (!t->gc_pend_head) return;
    sl_gc_obj *head = t->gc_pend_head;
    sl_gc_obj *tail = t->gc_pend_tail;
    t->gc_pend_head = NULL;
    t->gc_pend_tail = NULL;
    t->gc_pend_n = 0;
    sl_gc_retire_list(head, tail);
}

static void sl_gc_drain_retired(void) {
    sl_gc_obj *ret = atomic_exchange_explicit(&sl_gc_retired, NULL,
                                              memory_order_acquire);
    if (!ret) return;
    sl_gc_obj *tail = ret;
    while (tail->next) tail = tail->next;
    tail->next = sl_gc_young;
    sl_gc_young = ret;
}

static void sl_gc_harvest_task(sl_task *t) {
    if (!t || !t->gc_pend_head) return;
    t->gc_pend_tail->next = sl_gc_young;
    sl_gc_young = t->gc_pend_head;
    t->gc_pend_head = NULL;
    t->gc_pend_tail = NULL;
    t->gc_pend_n = 0;
}

/* Remembered-set harvest helper for sl_gc_for_pending_tasks: appends
 * one task's gc_rem_* shard onto a caller-owned array. We are STW
 * (inside sl_gc_mu), so the shard is stable and no locking is needed.
 * The shard buffers stay owned by their tasks; only the count resets. */
static sl_gc_obj **sl_gc_rem_harvest_buf = NULL;
static size_t sl_gc_rem_harvest_n = 0;
static size_t sl_gc_rem_harvest_cap = 0;

static void sl_gc_harvest_rem_task(sl_task *t) {
    if (!t || !t->gc_rem_n) return;
    size_t need = sl_gc_rem_harvest_n + t->gc_rem_n;
    if (need > sl_gc_rem_harvest_cap) {
        size_t ncap = sl_gc_rem_harvest_cap ? sl_gc_rem_harvest_cap : 32;
        while (ncap < need) ncap *= 2;
        sl_gc_obj **nb = (sl_gc_obj **)realloc(sl_gc_rem_harvest_buf,
                                               ncap * sizeof(*nb));
        if (!nb) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
        sl_gc_rem_harvest_buf = nb;
        sl_gc_rem_harvest_cap = ncap;
    }
    memcpy(sl_gc_rem_harvest_buf + sl_gc_rem_harvest_n, t->gc_rem_buf,
           t->gc_rem_n * sizeof(*sl_gc_rem_harvest_buf));
    sl_gc_rem_harvest_n += t->gc_rem_n;
    t->gc_rem_n = 0;
}

static void sl_gc_for_pending_tasks(void (*fn)(sl_task *),
                                    sl_gc_thread **snap, int nsnap);

/* This collection's whole remembered set into sl_gc_rem_harvest_buf:
 * every live task's shard, then the entries finished tasks left behind
 * (sl_gc_orphan_rem). */
static void sl_gc_harvest_rem_all(sl_gc_thread **snap, int nsnap) {
    sl_gc_rem_harvest_n = 0;
    sl_gc_for_pending_tasks(sl_gc_harvest_rem_task, snap, nsnap);
    pthread_mutex_lock(&sl_gc_rem_orphan_mu);
    if (sl_gc_rem_orphan_n) {
        size_t need = sl_gc_rem_harvest_n + sl_gc_rem_orphan_n;
        if (need > sl_gc_rem_harvest_cap) {
            size_t ncap = sl_gc_rem_harvest_cap ? sl_gc_rem_harvest_cap : 32;
            while (ncap < need) ncap *= 2;
            sl_gc_obj **nb = (sl_gc_obj **)realloc(sl_gc_rem_harvest_buf,
                                                   ncap * sizeof(*nb));
            if (!nb) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
            sl_gc_rem_harvest_buf = nb;
            sl_gc_rem_harvest_cap = ncap;
        }
        memcpy(sl_gc_rem_harvest_buf + sl_gc_rem_harvest_n, sl_gc_rem_orphans,
               sl_gc_rem_orphan_n * sizeof(*sl_gc_rem_harvest_buf));
        sl_gc_rem_harvest_n = need;
        sl_gc_rem_orphan_n = 0;
    }
    pthread_mutex_unlock(&sl_gc_rem_orphan_mu);
}

/* Generational write barrier (coarse v1): record an OLD-generation
 * container object in the current task's remembered-set shard so the
 * next minor GC scans it as a root. Unconditional on the stored value
 * (no young-check): simpler, and dedup via `remembered` keeps a hot
 * object to one shard append per minor cycle. No-op for young objects
 * (scanned anyway), NULL tasks, and non-GC payloads (never called
 * with those, but cheap to be safe).
 *
 * Callers must hold the preempt-disable bracket across the mutation
 * AND this call (see sl_map_put / codegen barrier sites): the shard
 * grow below mallocs, and a bare sl_rt_current_task read outside the
 * bracket is unsafe on Darwin (see darwin-tlv-async-preempt-hazard).
 * Takes the object HEADER; sl_gc_remember() wraps payload pointers.
 *
 * The gen/remembered check-then-set below races NOTHING: the only
 * writer of a task's shard is the task itself while running (mutators
 * never touch another task's shard), and the only other accessor is
 * the collector STW (all mutators stopped). No atomics needed.
 *
 * SOUNDNESS NOTE: this function trusts its caller to pass a real
 * sl_gc_obj header. Every barrier site is audited for that. A missed
 * site is silent heap corruption (an old->young edge the next minor
 * never scans); an EXTRA site (young container) is just a wasted
 * no-op. */
static void sl_gc_remember_obj(sl_gc_obj *h) {
    if (!h) return;
    if (h->gen != 1 || h->remembered) return;
    sl_task *t = sl_rt_cur();
    if (!t) return;
    if (t->gc_rem_n == t->gc_rem_cap) {
        size_t ncap = t->gc_rem_cap ? t->gc_rem_cap * 2 : 16;
        sl_gc_obj **nbuf = (sl_gc_obj **)malloc(ncap * sizeof(sl_gc_obj *));
        if (!nbuf) return;
        if (t->gc_rem_buf) {
            memcpy(nbuf, t->gc_rem_buf, t->gc_rem_n * sizeof(sl_gc_obj *));
            free(t->gc_rem_buf);
        }
        t->gc_rem_buf = nbuf;
        t->gc_rem_cap = ncap;
    }
    t->gc_rem_buf[t->gc_rem_n++] = h;
    h->remembered = 1;
}

/* sl_containers.c: marks a whole list or map dirty (their gc_clean). */
static void sl_gc_dirty_all(void *obj);
/* sl_containers.c: a remembered list's or map's trace for the minor's
 * remembered phase (see sl_gc_minor_mark). */
static int sl_gc_trace_arr_minor(void *p, void (*mark)(void *));
static int sl_gc_trace_map_minor(void *p, void (*mark)(void *));

/* The barrier for a store whose position in the container is not known:
 * a list or a map is dirty all over (see sl_arr's gc_clean). Stores that
 * know where they wrote use sl_arr_remember_at, or lower gc_clean
 * themselves and call sl_gc_remember_obj. */
static void sl_gc_remember(void *obj) {
    if (!obj) return;
    sl_gc_dirty_all(obj);
    sl_gc_remember_obj((sl_gc_obj *)obj - 1);
}

/* Tasks the harvest walks visit, for SLANG_GC_STAT (collector-only:
 * written under sl_gc_mu, stopped-the-world). */
static unsigned long long sl_gc_walk_count = 0;

static void sl_gc_for_pending_tasks(void (*fn)(sl_task *),
                                    sl_gc_thread **snap, int nsnap) {
    unsigned long long n = (unsigned long long)nsnap;
    for (int i = 0; i < nsnap; i++)
        fn(*snap[i]->task_slot);
    pthread_mutex_lock(&sl_global_runq.mu);
    for (sl_task *t = sl_global_runq.head; t; t = t->next, n++)
        fn(t);
    pthread_mutex_unlock(&sl_global_runq.mu);
    for (unsigned s = 0; s < (unsigned)SL_RUNQ_STRIPES; s++) {
        pthread_mutex_lock(&sl_runq_stripes[s].mu);
        for (sl_task *t = sl_runq_stripes[s].head; t; t = t->runq_link, n++)
            fn(t);
        pthread_mutex_unlock(&sl_runq_stripes[s].mu);
    }
    /* runnext slots: runnable like a stripe's tasks, but on neither list
       (sl_runnext's comment, sl_core.c, on why no worker can be changing
       one while this runs) */
    for (int i = 0; i < SL_RUNNEXT_SLOTS; i++) {
        sl_task *t = atomic_load_explicit(&sl_runnext[i], memory_order_acquire);
        if (t) {
            fn(t);
            n++;
        }
    }
    for (sl_task *t = sl_parked_tasks; t; t = t->parked_next, n++)
        fn(t);
    sl_gc_walk_count += n;
}

/* Size-class freelist for fixed-size GC headers + tiny payloads.
    The HTTP serve path mallocs per alloc (response literal header +
    payload, result wrappers), and glibc malloc at that rate is both
    the p99 tax and the RSS retainer. Classes are exact total sizes
    (header + payload); pop only reuses a block whose total matches
    exactly, so reused blocks never need resize bookkeeping. Larger
    sizes fall through to malloc. Freed blocks return to the class
    list instead of the sweep free(); the sweep still frees anything
    the freelist will not retain (bounded per class). */
#define SL_GC_CLASS_N 6
static const size_t sl_gc_class_sizes[SL_GC_CLASS_N] = {40, 48, 56, 72, 144,
                                                        320};
#define SL_GC_CLASS_MAX 64
static sl_gc_obj *sl_gc_class_fl[SL_GC_CLASS_N];
static int sl_gc_class_fl_n[SL_GC_CLASS_N];
static pthread_mutex_t sl_gc_class_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned long long sl_gc_class_stat_hits = 0;
static _Atomic unsigned long long sl_gc_class_stat_over = 0;

static int sl_gc_class_stat_enabled(void) {
    static int cached = -1;
    if (cached < 0)
        cached = getenv("SLANG_GC_CLASS_STAT") ? 1 : 0;
    return cached;
}

static void sl_gc_class_stat_dump(void) {
    if (!sl_gc_class_stat_enabled())
        return;
    unsigned long long hits = atomic_load_explicit(
        &sl_gc_class_stat_hits, memory_order_relaxed);
    unsigned long long over = atomic_load_explicit(
        &sl_gc_class_stat_over, memory_order_relaxed);
    fprintf(stderr, "slang-gc-class-stat hits=%llu overflow_frees=%llu",
            hits, over);
    for (int i = 0; i < SL_GC_CLASS_N; i++)
        fprintf(stderr, " c%zu=%d", sl_gc_class_sizes[i],
                sl_gc_class_fl_n[i]);
    fprintf(stderr, "\n");
}

__attribute__((destructor))
static void sl_gc_class_stat_atexit(void) {
    sl_gc_class_stat_dump();
    sl_gc_page_stat_dump();
}

static int sl_gc_class_for(size_t total) {
    for (int i = 0; i < SL_GC_CLASS_N; i++) {
        if (total == sl_gc_class_sizes[i])
            return i;
    }
    return -1;
}

static sl_gc_obj *sl_gc_class_pop(size_t total) {
    int c = sl_gc_class_for(total);
    if (c < 0)
        return NULL;
    pthread_mutex_lock(&sl_gc_class_mu);
    sl_gc_obj *h = sl_gc_class_fl[c];
    if (h) {
        sl_gc_class_fl[c] = h->next;
        sl_gc_class_fl_n[c]--;
    }
    pthread_mutex_unlock(&sl_gc_class_mu);
    if (!h)
        return NULL;
    if (sl_gc_class_stat_enabled())
        atomic_fetch_add_explicit(&sl_gc_class_stat_hits, 1,
                                  memory_order_relaxed);
    h->trace = NULL;
    h->fini = NULL;
    h->marked = 0;
    h->gen = 0;
    h->remembered = 0;
    return h;
}

static void sl_gc_class_push(sl_gc_obj *h) {
    size_t total = h->size + sizeof(sl_gc_obj);
    int c = sl_gc_class_for(total);
    if (c < 0) {
        free(h);
        return;
    }
    /* Scrub GC state before freelisting: a recycled header must be
     * indistinguishable from a fresh malloc (gen young, unmarked,
     * unremembered). The sweep already cleared marked, but gen may be
     * 1 (a swept OLD object) and remembered may be set -- either would
     * corrupt the next owner's lifecycle (an old-gen young object
     * escapes nursery sweeping; a set remembered flag suppresses the
     * barrier that should re-register it). Belt and suspenders with
     * sl_gc_class_pop's own reset: push scrubs so an idle freelist
     * header never carries stale GC state, pop scrubs so a recycled
     * header always re-enters young even if push is ever bypassed. */
    h->marked = 0;
    h->gen = 0;
    h->remembered = 0;
    pthread_mutex_lock(&sl_gc_class_mu);
    if (sl_gc_class_fl_n[c] < SL_GC_CLASS_MAX) {
        h->next = sl_gc_class_fl[c];
        sl_gc_class_fl[c] = h;
        sl_gc_class_fl_n[c]++;
        pthread_mutex_unlock(&sl_gc_class_mu);
        return;
    }
    pthread_mutex_unlock(&sl_gc_class_mu);
    if (sl_gc_class_stat_enabled())
        atomic_fetch_add_explicit(&sl_gc_class_stat_over, 1,
                                  memory_order_relaxed);
    free(h);
}

/* ---- Phase 1 (§7f): per-worker young pages ----
 *
 * Every object used to be its own malloc, onto a per-task pending list,
 * then into the young/old linked lists, with a small exact-size
 * freelist (c40..c320) on the side. The freelist hits ~0% on real
 * paths (199 of 802,624 allocs on the quote decode bench: variable
 * string sizes never match an exact class), so each allocation paid a
 * malloc and each death a free, plus a mutex for the rare hit.
 *
 * A page is 16KB, 16KB-aligned, so its struct is one mask away from
 * any object in it. Small objects (header+payload <= 1024, 8-aligned)
 * bump-allocate from the owning worker's pages; a death clears its
 * start bit and drops a live count, and once per surviving page per
 * sweep the holes are filed into the page's free list by one linear
 * bitmap walk (already coalesced, in walk order), which the next
 * claim searches first-fit, splitting only when the remainder still
 * holds a node; a smaller remainder is absorbed into the taken slot
 * and covered by its cap, so the walk never sees it. Deaths
 * outnumber surviving pages a thousand to one, so filing once per
 * page beats once per death. A page whose live counters both reach
 * zero is reset at the end of the sweep that emptied it and retained up to the
 * per-worker cap, so the next cycle bump-allocates over it with no
 * fragmentation to walk; past the cap, or orphaned with no worker
 * left to reuse it, it is freed. Larger totals stay on malloc
 * and keep today's class_push/free path, which this section otherwise
 * leaves alone.
 *
 * Lifetime is exact, not traced: every claim bumps young_live or
 * old_live by the object's birth gen; every sweep death decrements
 * one of them; every promotion moves one count across. A page is
 * empty exactly when both are zero. Headers stay on the same
 * young/old/pending lists either way, so mark, the remembered set,
 * the gc_clean frontier and sl_gc_set's build walk nothing new.
 *
 * Threading: a worker touches only its own pages (its _Thread_local
 * list, inside the allocation bracket that pins the task to this
 * thread), so claims take no lock. The sweep runs stopped-the-world
 * and may empty another worker's page; it never frees one mid-sweep
 * (that would strand the owner's list and bump pointer). Instead the
 * sweep-end prune -- still stopped, still under sl_gc_mu -- unlinks
 * and frees every empty page from every registered thread's list
 * (addresses published at registration, the task_slot pattern) and
 * from the orphan list, and repairs bump pointers. A thread going
 * away NULLs its own list and orphans what's left; live headers keep
 * that memory valid until a sweep empties and frees it.
 *
 * The per-page start bitmap (one bit per 8-byte slot) records, for
 * Phase 2's page-table validation, what sl_gc_set knows today. Phase
 * 1 only maintains it: set on claim, cleared on recycle. */

#define SL_GC_PAGE_SIZE 16384
#define SL_GC_PAGE_ALIGN 16384
#define SL_GC_PAGE_MAX_TOTAL 1024
/* Pages one worker may hold: 1024 x 16KB = 16MB, the largest nursery
 * (sl_gc_nursery_set_max). The nursery trigger is global, so one busy
 * worker can allocate a whole cycle's budget by itself, and page slack
 * (holes, survivors) takes more than the budget's bytes. Past the cap,
 * claims fall back to malloc, and every fallback is a libc malloc now
 * and a libc free at the sweep: at the old cap of 64, sized for the
 * fixed 512KB nursery, a third of the decode probe's allocations on
 * one worker fell back once the adaptive nursery reached 1MB. Young
 * bytes are bounded by the nursery trigger, not by this cap. */
#define SL_GC_PAGE_MAX_PAGES 1024
/* Empty pages a worker keeps across a sweep, to bump-allocate over in
 * the next cycle: 128 x 16KB = 2MB, one worker's share of the largest
 * nursery. Keeping fewer than a cycle needs frees and re-allocates the
 * difference every sweep, and on macOS those aligned 16KB blocks were
 * not reused: peak RSS doubled. Keeping 256 measured no faster (Linux
 * quote, +311 req/s against +421 for 128) for more retained memory.
 * Empties past it are freed, so a worker that burst to the full cap
 * returns to this after one sweep. */
#define SL_GC_PAGE_KEEP_PAGES 128
/* A split remainder must still hold a 16-byte free node; anything
 * smaller is absorbed into the taken slot (and covered by its cap). */
#define SL_GC_PAGE_MIN_SPLIT 16
#define SL_GC_PAGE_MAGIC 0x534c4743504147ULL
#define SL_GC_PAGE_SLOT 8
#define SL_GC_PAGE_SLOTS (SL_GC_PAGE_SIZE / SL_GC_PAGE_SLOT)
#define SL_GC_PAGE_BITMAP_WORDS (SL_GC_PAGE_SLOTS / 64)

struct sl_gc_page {
    unsigned long long magic;
    sl_gc_page *next; /* owning worker's list (or the orphan list) */
    size_t bump; /* next fresh offset from the payload start */
    size_t free_head; /* offset+1 of first free slot, 0 = none */
    long young_live; /* resident slots born young and not yet swept */
    long old_live; /* resident slots born old, or promoted */
    /* full: claimed against and missed this cycle. No death happens
     * outside a sweep, so a miss stays a miss until the next prune
     * clears it -- the fallback path skips full pages instead of
     * re-walking their free lists on every allocation. */
    unsigned char full;
    unsigned long long bitmap[SL_GC_PAGE_BITMAP_WORDS];
    /* payload follows, 8-aligned */
};
#define SL_GC_PAGE_PAYLOAD_OFF (((sizeof(sl_gc_page)) + 7) & ~(size_t)7)
#define SL_GC_PAGE_PAYLOAD_CAP (SL_GC_PAGE_SIZE - SL_GC_PAGE_PAYLOAD_OFF)

/* One TLS word for the allocator: a single accessor read per
 * allocation instead of one per field. */
struct sl_gc_worker_state {
    sl_gc_page *pages;
    sl_gc_page *cur;
    int npages;
    /* Every page full and the cap reached: no claim can succeed before
     * the next sweep (no death happens outside one -- the same rule as a
     * page's `full`), so allocation goes straight to malloc instead of
     * walking every page first. Walking up to 64 full pages on every
     * allocation, inside the allocator's preempt bracket, was most of
     * the allocator's time once promoted objects pinned the pages: 74%
     * of the quote decode probe's allocations fell back. Cleared by the
     * sweep-end prune. */
    int exhausted;
    /* Bytes this worker allocated and has not yet added to the triggers
     * (sl_gc_publish_delta). Published every SL_GC_PUBLISH_BATCH, so the
     * shared counters take one pair of atomic adds per 16 KB instead of
     * per allocation: with four workers those adds on two shared lines
     * were a measurable part of every allocation (fix-gc.md 1.3). A
     * trigger is late by at most a batch per worker; per worker, not per
     * task, so hundreds of parked tasks cannot each hold back a batch. */
    size_t unpub;
    /* Objects this worker allocated outside its pages (over 1 KB, or with
     * its pages exhausted) since the last collection. A minor recognizes
     * a paged object by its page (sl_gc_known); these, plus the ones that
     * survived the last minor still young (sl_gc_young_m), are the only
     * young objects its table has to list (fix-gc.md 1.5). */
    sl_gc_obj **mbuf;
    size_t mbuf_n, mbuf_cap;
};
#define SL_GC_PUBLISH_BATCH (16 * 1024)
static _Thread_local sl_gc_worker_state sl_gc_wstate;
SL_RT_TLS_ADDR_FN(sl_gc_tls_state, sl_gc_worker_state, sl_gc_wstate)

/* ---- 1.5: recognizing an object without listing it ----
 *
 * Every collection used to build a hash set of every object it could
 * mark (all young ones for a minor), so that a candidate pointer -- a
 * root slot, a field, a conservatively scanned stack word -- could be
 * checked before its header was read. Building it walked the young list
 * and hashed every object into a fresh table: about half of each minor
 * on the quote decode probe (20-26 ms of 49-53 ms over 15 minors), the
 * inserts more than the walk.
 *
 * A paged object needs no entry: its page is 16 KB-aligned, and the
 * page's start bitmap already records every object start (set on claim,
 * cleared on free). So a pointer is a paged object iff its 16 KB base is
 * a live page and the bit for "pointer minus one header" is set. The
 * base must be checked against a registry first: a conservative word can
 * be any address, and reading a page header at one that is not a page
 * could fault. The registry is a small open-addressing set of page
 * bases, written when a page is created (a mutator, under the
 * allocator's bracket, so under its own mutex) or freed (stopped the
 * world, or a thread's teardown under sl_gc_mu), and read only while the
 * world is stopped.
 *
 * Only objects outside pages still go in the hash set, and a minor's
 * set lists only the young ones -- each worker's mbuf plus
 * sl_gc_young_m -- without walking the young list. Majors and the
 * verifier walk both lists as before and insert only the unpaged. */
#define SL_GC_PAGEREG_TOMB ((uintptr_t)1)
static uintptr_t *sl_gc_pagereg = NULL;
static size_t sl_gc_pagereg_cap = 0;
static size_t sl_gc_pagereg_live = 0;
static size_t sl_gc_pagereg_used = 0; /* live + tombstones */
static pthread_mutex_t sl_gc_pagereg_mu = PTHREAD_MUTEX_INITIALIZER;

static void sl_gc_pagereg_put(uintptr_t *tbl, size_t cap, uintptr_t b) {
    size_t i = sl_gc_ptrhash((void *)b) & (cap - 1);
    while (tbl[i] > SL_GC_PAGEREG_TOMB) i = (i + 1) & (cap - 1);
    tbl[i] = b;
}

/* Caller holds sl_gc_pagereg_mu. */
static void sl_gc_pagereg_resize(void) {
    size_t cap = 256;
    while (cap < (sl_gc_pagereg_live + 1) * 4) cap *= 2;
    uintptr_t *tbl = (uintptr_t *)calloc(cap, sizeof(uintptr_t));
    if (!tbl) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    for (size_t i = 0; i < sl_gc_pagereg_cap; i++)
        if (sl_gc_pagereg[i] > SL_GC_PAGEREG_TOMB)
            sl_gc_pagereg_put(tbl, cap, sl_gc_pagereg[i]);
    free(sl_gc_pagereg);
    sl_gc_pagereg = tbl;
    sl_gc_pagereg_cap = cap;
    sl_gc_pagereg_used = sl_gc_pagereg_live;
}

static void sl_gc_pagereg_add(uintptr_t b) {
    pthread_mutex_lock(&sl_gc_pagereg_mu);
    if ((sl_gc_pagereg_used + 1) * 2 > sl_gc_pagereg_cap)
        sl_gc_pagereg_resize();
    sl_gc_pagereg_put(sl_gc_pagereg, sl_gc_pagereg_cap, b);
    sl_gc_pagereg_live++;
    sl_gc_pagereg_used++;
    pthread_mutex_unlock(&sl_gc_pagereg_mu);
}

static void sl_gc_pagereg_del(uintptr_t b) {
    pthread_mutex_lock(&sl_gc_pagereg_mu);
    if (sl_gc_pagereg_cap) {
        size_t i = sl_gc_ptrhash((void *)b) & (sl_gc_pagereg_cap - 1);
        while (sl_gc_pagereg[i]) {
            if (sl_gc_pagereg[i] == b) {
                sl_gc_pagereg[i] = SL_GC_PAGEREG_TOMB;
                sl_gc_pagereg_live--;
                break;
            }
            i = (i + 1) & (sl_gc_pagereg_cap - 1);
        }
    }
    pthread_mutex_unlock(&sl_gc_pagereg_mu);
}

/* Stopped-the-world only (see above): no lock. */
static int sl_gc_pagereg_has(uintptr_t b) {
    if (!sl_gc_pagereg_cap) return 0;
    size_t i = sl_gc_ptrhash((void *)b) & (sl_gc_pagereg_cap - 1);
    for (;;) {
        uintptr_t v = sl_gc_pagereg[i];
        if (!v) return 0;
        if (v == b) return 1;
        i = (i + 1) & (sl_gc_pagereg_cap - 1);
    }
}

/* Is p the payload of a live object this collection can mark? A paged
 * object answers from its page's bitmap; anything else from sl_gc_set
 * (the unpaged objects of this collection). Stopped-the-world only. */
static int sl_gc_known(void *p) {
    uintptr_t a = (uintptr_t)p;
    uintptr_t base = a & ~(uintptr_t)(SL_GC_PAGE_ALIGN - 1);
    if (sl_gc_pagereg_has(base)) {
        uintptr_t payload = base + SL_GC_PAGE_PAYLOAD_OFF;
        if (a < payload + sizeof(sl_gc_obj))
            return 0;
        uintptr_t off = a - sizeof(sl_gc_obj) - payload;
        if (off % SL_GC_PAGE_SLOT || off >= SL_GC_PAGE_PAYLOAD_CAP)
            return 0;
        size_t slot = off / SL_GC_PAGE_SLOT;
        const sl_gc_page *pg = (const sl_gc_page *)base;
        return (int)((pg->bitmap[slot / 64] >> (slot % 64)) & 1);
    }
    return sl_gc_set_contains(p);
}

/* Non-paged young objects that survived the last minor still young
 * (aged); rebuilt by every minor sweep, emptied by a major (which
 * promotes everything it keeps). Collector-only. */
static sl_gc_obj **sl_gc_young_m = NULL;
static size_t sl_gc_young_m_n = 0, sl_gc_young_m_cap = 0;

static void sl_gc_objs_push(sl_gc_obj ***buf, size_t *n, size_t *cap,
                            sl_gc_obj *h) {
    if (*n == *cap) {
        size_t nc = *cap ? *cap * 2 : 64;
        sl_gc_obj **nb = (sl_gc_obj **)realloc(*buf, nc * sizeof(*nb));
        if (!nb) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
        *buf = nb;
        *cap = nc;
    }
    (*buf)[(*n)++] = h;
}

/* Orphaned pages: non-empty pages of threads that went away, under
 * sl_gc_mu (unregister and both sweeps already hold it). */
static sl_gc_page *sl_gc_orphans = NULL;

static _Atomic unsigned long long sl_gc_page_stat_claims = 0;
static _Atomic unsigned long long sl_gc_page_stat_reuse = 0;
static _Atomic unsigned long long sl_gc_page_stat_pages = 0;
static _Atomic unsigned long long sl_gc_page_stat_freed = 0;
static _Atomic unsigned long long sl_gc_page_stat_fallback = 0;
static _Atomic unsigned long long sl_gc_page_stat_deaths = 0;

/* Diagnostic counters only: gated on the class-stat env, so the
 * production path pays one predictable branch, never an atomic. */
#define SL_GC_PAGE_COUNT(counter) do { \
    if (sl_gc_class_stat_enabled()) \
        atomic_fetch_add_explicit(&(counter), 1, memory_order_relaxed); \
} while (0)

static void sl_gc_page_stat_dump(void) {
    if (!sl_gc_class_stat_enabled())
        return;
    fprintf(stderr, "slang-gc-page-stat claims=%llu reuse=%llu pages=%llu "
            "freed=%llu fallback=%llu deaths=%llu\n",
            atomic_load_explicit(&sl_gc_page_stat_claims,
                                 memory_order_relaxed),
            atomic_load_explicit(&sl_gc_page_stat_reuse,
                                 memory_order_relaxed),
            atomic_load_explicit(&sl_gc_page_stat_pages,
                                 memory_order_relaxed),
            atomic_load_explicit(&sl_gc_page_stat_freed,
                                 memory_order_relaxed),
            atomic_load_explicit(&sl_gc_page_stat_fallback,
                                 memory_order_relaxed),
            atomic_load_explicit(&sl_gc_page_stat_deaths,
                                 memory_order_relaxed));
}

static inline sl_gc_page *sl_gc_page_of(const sl_gc_obj *h) {
    return (sl_gc_page *)((uintptr_t)h & ~(uintptr_t)(SL_GC_PAGE_ALIGN - 1));
}

static inline void sl_gc_page_mark(sl_gc_page *pg, size_t off) {
    size_t slot = off / SL_GC_PAGE_SLOT;
    pg->bitmap[slot / 64] |= 1ULL << (slot % 64);
}

static inline void sl_gc_page_unmark(sl_gc_page *pg, size_t off) {
    size_t slot = off / SL_GC_PAGE_SLOT;
    pg->bitmap[slot / 64] &= ~(1ULL << (slot % 64));
}

/* Claim `total` bytes from pg: first-fit over the free list (splitting
 * only when the remainder still holds a node), else the bump pointer.
 * Returns offset+1, or 0 when neither fits; *reused reports a
 * free-list hit and *taken the slot's full extent for the header's
 * cap (bigger than total when a small remainder was absorbed). */
static size_t sl_gc_page_claim(sl_gc_page *pg, size_t total, int *reused,
                               size_t *taken) {
    char *base = (char *)pg + SL_GC_PAGE_PAYLOAD_OFF;
    size_t *link = &pg->free_head;
    while (*link) {
        size_t off = *link - 1;
        size_t *node = (size_t *)(base + off);
        if (node[1] >= total) {
            size_t rem = node[1] - total;
            if (rem >= SL_GC_PAGE_MIN_SPLIT) {
                size_t *rn = (size_t *)(base + off + total);
                rn[0] = node[0];
                rn[1] = rem;
                *link = off + total + 1;
                *taken = total;
            } else {
                *link = node[0];
                *taken = node[1];
            }
            *reused = 1;
            return off + 1;
        }
        link = node;
    }
    if (pg->bump + total <= SL_GC_PAGE_PAYLOAD_CAP) {
        size_t off = pg->bump;
        pg->bump += total;
        *reused = 0;
        *taken = total;
        return off + 1;
    }
    return 0;
}

/* A fresh page for this worker: caller holds the allocation bracket
 * (aligned_alloc can take a libc lock). Linked onto the worker's
 * list; NULL past the per-worker cap or on OOM (the caller then falls
 * back to malloc, so a failed page never fails the allocation). */
static sl_gc_page *sl_gc_page_new(sl_gc_worker_state *st) {
    if (st->npages >= SL_GC_PAGE_MAX_PAGES)
        return NULL;
    void *mem = aligned_alloc(SL_GC_PAGE_ALIGN, SL_GC_PAGE_SIZE);
    if (!mem)
        return NULL;
    sl_gc_page *pg = (sl_gc_page *)mem;
    pg->magic = SL_GC_PAGE_MAGIC;
    pg->next = st->pages;
    st->pages = pg;
    pg->bump = 0;
    pg->free_head = 0;
    pg->young_live = 0;
    pg->old_live = 0;
    pg->full = 0;
    memset(pg->bitmap, 0, sizeof(pg->bitmap));
    st->npages++;
    SL_GC_PAGE_COUNT(sl_gc_page_stat_pages);
    sl_gc_pagereg_add((uintptr_t)pg);
    return pg;
}

/* Book a claimed slot: start bit, birth-gen count, header flag and
 * slot extent. `taken` is the slot's full extent (bigger than total
 * when a small remainder was absorbed); the hole walk strides by it.
 * With page debugging on, claiming a bit-set slot aborts. */
static inline sl_gc_obj *sl_gc_page_book(sl_gc_page *pg, size_t got,
                                         size_t taken, unsigned char gen,
                                         int reused) {
    size_t off = got - 1;
    if (sl_gc_page_debug_enabled()) {
        size_t slot = off / SL_GC_PAGE_SLOT;
        if (pg->bitmap[slot / 64] & (1ULL << (slot % 64))) {
            fprintf(stderr, "slang-gc-page-debug: double claim off %zu\n",
                    off);
            abort();
        }
    }
    sl_gc_page_mark(pg, off);
    if (gen != 1)
        pg->young_live++;
    else
        pg->old_live++;
    SL_GC_PAGE_COUNT(sl_gc_page_stat_claims);
    if (reused)
        SL_GC_PAGE_COUNT(sl_gc_page_stat_reuse);
    sl_gc_obj *h = (sl_gc_obj *)((char *)pg + SL_GC_PAGE_PAYLOAD_OFF +
                                 got - 1);
    h->paged = 1;
    h->cap = (uint32_t)taken;
    return h;
}

/* Reserve `total` (8-aligned, header included) for an object born with
 * `gen`. NULL when total is over the page limit, the worker is at its
 * page cap, or a page allocation failed: the caller falls back. One
 * TLS read per call; pages that missed this cycle are skipped (no
 * death happens outside a sweep, so a miss stays a miss). */
static sl_gc_obj *sl_gc_page_alloc(sl_gc_worker_state *st, size_t total,
                                   unsigned char gen) {
    if (total > SL_GC_PAGE_MAX_TOTAL)
        return NULL;
    if (st->exhausted)
        return NULL;
    /* The bump pointer's page first: the common case stays one page. */
    sl_gc_page *cur = st->cur;
    if (cur && !cur->full) {
        int reused = 0;
        size_t taken = 0;
        size_t got = sl_gc_page_claim(cur, total, &reused, &taken);
        if (got)
            return sl_gc_page_book(cur, got, taken, gen, reused);
        cur->full = 1;
    }
    for (sl_gc_page *pg = st->pages; pg; pg = pg->next) {
        if (pg == cur || pg->full)
            continue;
        int reused = 0;
        size_t taken = 0;
        size_t got = sl_gc_page_claim(pg, total, &reused, &taken);
        if (got) {
            st->cur = pg;
            return sl_gc_page_book(pg, got, taken, gen, reused);
        }
        pg->full = 1;
    }
    sl_gc_page *pg = sl_gc_page_new(st);
    if (!pg) {
        st->exhausted = 1;
        return NULL;
    }
    int reused = 0;
    size_t taken = 0;
    size_t got = sl_gc_page_claim(pg, total, &reused, &taken);
    /* A fresh page always fits a page-sized total, from its bump. */
    st->cur = pg;
    return sl_gc_page_book(pg, got, taken, gen, reused);
}

/* Return a dead paged object to its page: clear its start bit and
 * drop a live count. O(1): the hole itself is filed later, once per
 * surviving page per sweep (below), instead of once per death --
 * deaths outnumber surviving pages a thousand to one. Runs
 * stopped-the-world, like the sweep that calls it. */
static void sl_gc_page_free_obj(sl_gc_obj *h) {
    sl_gc_page *pg = sl_gc_page_of(h);
    SL_GC_PAGE_COUNT(sl_gc_page_stat_deaths);
    size_t off = (size_t)((char *)h - ((char *)pg + SL_GC_PAGE_PAYLOAD_OFF));
    if (sl_gc_page_debug_enabled()) {
        size_t slot = off / SL_GC_PAGE_SLOT;
        if (!(pg->bitmap[slot / 64] & (1ULL << (slot % 64)))) {
            fprintf(stderr, "slang-gc-page-debug: double free off %zu\n",
                    off);
            abort();
        }
    }
    sl_gc_page_unmark(pg, off);
    if (h->gen != 1)
        pg->young_live--;
    else
        pg->old_live--;
}

/* File one surviving page's holes after a sweep: a linear walk over
 * the bitmap, live objects skipped by their slot extents, dead runs
 * filed as free slots. Runs are maximal by construction (every dead
 * byte belonged to a dead slot of at least node size), already
 * coalesced, in walk order. Striding by cap, not size, is what keeps
 * absorbed waste inside its owner's stride instead of filing it as a
 * fragment the next claim overwrites a live header with. */
static void sl_gc_page_rebuild_free(sl_gc_page *pg) {
    char *base = (char *)pg + SL_GC_PAGE_PAYLOAD_OFF;
    pg->free_head = 0;
    size_t off = 0;
    while (off < pg->bump) {
        size_t slot = off / SL_GC_PAGE_SLOT;
        if (pg->bitmap[slot / 64] & (1ULL << (slot % 64))) {
            sl_gc_obj *h = (sl_gc_obj *)(base + off);
            if (h->cap < 40 || (h->cap % SL_GC_PAGE_SLOT) != 0 ||
                off + h->cap > pg->bump) {
                fprintf(stderr, "slang: corrupt page slot cap %u at %zu\n",
                        h->cap, off);
                abort();
            }
            off += h->cap;
        } else {
            size_t start = off;
            do {
                off += SL_GC_PAGE_SLOT;
                slot = off / SL_GC_PAGE_SLOT;
            } while (off < pg->bump &&
                     !(pg->bitmap[slot / 64] & (1ULL << (slot % 64))));
            size_t *node = (size_t *)(base + start);
            node[0] = pg->free_head;
            node[1] = off - start;
            pg->free_head = start + 1;
        }
    }
}

/* A young paged object survived: still resident, now old's. */
static inline void sl_gc_page_promoted(sl_gc_obj *h) {
    sl_gc_page *pg = sl_gc_page_of(h);
    pg->young_live--;
    pg->old_live++;
}

/* Drop every empty page from one worker's list (headp/curp/npp are
 * that worker's published TLS addresses, or a local orphan-list pair
 * with NULLs) and repair its bump pointer. Empty worker pages are
 * reset and retained up to SL_GC_PAGE_KEEP_PAGES -- everything in them
 * just died, so the next cycle bump-allocates over them with no
 * fragmentation to walk -- and freed past it; orphan empties (no
 * worker left to reuse them) are always freed. Pages that survived
 * keep their holes for cross-cycle reuse. The survivor count goes
 * back into the worker's page cap, so freed pages reopen room for new
 * ones. Stopped-the-world; frees under sl_gc_mu, the sweep's own
 * standing practice. */
static void sl_gc_pages_prune_list(sl_gc_page **headp, sl_gc_page **curp,
                                   int *npp, int retain) {
    int nlive = 0;
    for (sl_gc_page *pg = *headp; pg; pg = pg->next)
        if (pg->young_live != 0 || pg->old_live != 0)
            nlive++;
    int keep = retain && nlive < SL_GC_PAGE_KEEP_PAGES
                   ? SL_GC_PAGE_KEEP_PAGES - nlive
                   : 0;
    sl_gc_page *cur = curp ? *curp : NULL;
    int cur_dead = 0;
    int n = nlive;
    sl_gc_page **link = headp;
    while (*link) {
        sl_gc_page *pg = *link;
        if (pg->young_live == 0 && pg->old_live == 0) {
            if (keep > 0) {
                /* Everything in it died: start the page over. */
                pg->bump = 0;
                pg->free_head = 0;
                pg->full = 0;
                memset(pg->bitmap, 0, sizeof(pg->bitmap));
                keep--;
                n++;
                link = &pg->next;
                continue;
            }
            if (pg == cur)
                cur_dead = 1;
            *link = pg->next;
            sl_gc_pagereg_del((uintptr_t)pg);
            free(pg);
            SL_GC_PAGE_COUNT(sl_gc_page_stat_freed);
            continue;
        }
        /* Survived with new holes from this sweep: misses expire. */
        pg->full = 0;
        sl_gc_page_rebuild_free(pg);
        n++;
        link = &pg->next;
    }
    if (curp && cur_dead)
        *curp = *headp;
    if (npp)
        *npp = n;
}

/* The sweep-end prune reaches these through the registry. */
static void sl_gc_pages_publish(void) {
    sl_rt_gc_reg.state_ptr = &sl_gc_wstate;
}

/* Exiting thread's handoff: free what's empty, orphan the rest under
 * the caller's sl_gc_mu. Bare TLS: own-thread teardown. */
static void sl_gc_pages_orphan_all(void) {
    sl_gc_page *pg = sl_gc_wstate.pages;
    sl_gc_wstate.pages = NULL;
    sl_gc_wstate.cur = NULL;
    sl_gc_wstate.npages = 0;
    sl_gc_wstate.exhausted = 0;
    /* This thread's unpaged young objects outlive it (on the young
     * list): the next minor finds them through sl_gc_young_m instead. */
    for (size_t i = 0; i < sl_gc_wstate.mbuf_n; i++)
        sl_gc_objs_push(&sl_gc_young_m, &sl_gc_young_m_n, &sl_gc_young_m_cap,
                        sl_gc_wstate.mbuf[i]);
    free(sl_gc_wstate.mbuf);
    sl_gc_wstate.mbuf = NULL;
    sl_gc_wstate.mbuf_n = sl_gc_wstate.mbuf_cap = 0;
    while (pg) {
        sl_gc_page *nx = pg->next;
        if (pg->young_live == 0 && pg->old_live == 0) {
            sl_gc_pagereg_del((uintptr_t)pg);
            free(pg);
            SL_GC_PAGE_COUNT(sl_gc_page_stat_freed);
        } else {
            pg->next = sl_gc_orphans;
            sl_gc_orphans = pg;
        }
        pg = nx;
    }
}

/* End of either sweep: free what emptied, everywhere. */
static void sl_gc_pages_sweep_end(void) {
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next) {
        sl_gc_worker_state *st = gt->state_ptr;
        st->exhausted = 0;
        sl_gc_pages_prune_list(&st->pages, &st->cur, &st->npages, 1);
    }
    sl_gc_pages_prune_list(&sl_gc_orphans, NULL, NULL, 0);
}

/* The sweep's way to let go of a dead object: paged ones return to
 * their page, everything else keeps the class freelist path. */
static inline void sl_gc_recycle(sl_gc_obj *h) {
    if (h->paged)
        sl_gc_page_free_obj(h);
    else
        sl_gc_class_push(h);
}

/* `owner`, when not NULL, is the object whose tracer will read this
 * buffer (sl_gc_alloc_owned): the buffer takes the owner's generation,
 * read here, inside the bracket. Read by the caller before the call
 * instead, an async preemption landing in between could let a collection
 * promote the owner after its gen was taken, and the buffer would be born
 * young under an old owner no barrier remembered -- a young object a
 * minor frees while the owner still uses it. Making collections likely
 * at that point (an allocation-entry yield tried for fix-gc.md 1.1) made
 * the verifier catch exactly that: young leaves held by old maps. */
static void *sl_gc_alloc_gen(size_t n,
                             void (*trace)(void *, void (*)(void *)),
                             void (*fini)(void *), const void *owner) {
    sl_rt_preempt_disable();
    unsigned char gen = owner ? ((const sl_gc_obj *)owner - 1)->gen : 0;
    sl_task *t = sl_rt_cur();
    sl_gc_worker_state *st = sl_gc_tls_state();
    /* Pages first (no lock, this worker's own), then the exact-size
     * class freelist, then malloc: every path below zeroes and links
     * the header the same way. */
    size_t total = sizeof(sl_gc_obj) + n;
    sl_gc_obj *h = NULL;
    if (total <= SL_GC_PAGE_MAX_TOTAL) {
        h = sl_gc_page_alloc(st, (total + 7) & ~(size_t)7, gen);
        if (!h)
            SL_GC_PAGE_COUNT(sl_gc_page_stat_fallback);
    } else {
        h = sl_gc_class_pop(total);
    }
    if (!h) {
        h = (sl_gc_obj *)malloc(total);
        if (!h) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
        h->paged = 0;
    }
    memset(h + 1, 0, n);
    h->size = n;
    h->trace = trace;
    h->fini = fini;
    h->marked = 0;
    h->gen = gen;
    h->remembered = 0;
    if (!h->paged)
        sl_gc_objs_push(&st->mbuf, &st->mbuf_n, &st->mbuf_cap, h);
    h->next = t->gc_pend_head;
    if (!t->gc_pend_head) t->gc_pend_tail = h;
    t->gc_pend_head = h;
    t->gc_pend_n++;
    if (sl_gc_stat_enabled()) {
        atomic_fetch_add_explicit(&sl_gc_stat_allocs, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&sl_gc_stat_alloc_bytes,
                                  (unsigned long long)(sizeof(sl_gc_obj) + n),
                                  memory_order_relaxed);
    }
    /* The fixed-threshold test modes publish every allocation: they exist
     * to land collections at as many safepoints as possible. */
    st->unpub += sizeof(sl_gc_obj) + n;
    if (st->unpub >= SL_GC_PUBLISH_BATCH || sl_gc_threshold_fixed ||
        sl_gc_nursery_fixed) {
        sl_gc_publish_delta(st->unpub);
        st->unpub = 0;
    }
    sl_rt_preempt_enable();
    return (void *)(h + 1);
}

static void *sl_gc_alloc_fin(size_t n,
                             void (*trace)(void *, void (*)(void *)),
                             void (*fini)(void *)) {
    return sl_gc_alloc_gen(n, trace, fini, NULL);
}

static void *sl_gc_alloc(size_t n,
                          void (*trace)(void *, void (*)(void *))) {
    return sl_gc_alloc_fin(n, trace, NULL);
}

/* An out-of-line buffer whose CONTENTS its owner's tracer reads
 * directly: sl_map's keys/vals/state/order, sl_arr's data, sl_chan's
 * ring, sl_join's value slot, sl_json_val's item/key/value arrays.
 * Every such buffer MUST come from here, never from sl_gc_alloc.
 *
 * The buffer is born in its owner's generation, so it can never be
 * freed before its owner. A minor sweeps only young objects and never
 * sweeps old ones, dead or alive -- so a young buffer hanging off an
 * OLD owner was freed by the first minor after the owner died, while
 * the owner itself stayed on sl_gc_old until the next major. Nothing
 * reaches a dead owner precisely, but a stale word in an async-
 * preempted task's conservatively scanned stack (or an uninitialized
 * root slot) can, and sl_gc_mark accepts it: the owner is still a
 * member of sl_gc_set. Its tracer then read the freed buffer --
 * sl_gc_trace_map indexes m->keys by values read from m->order, so a
 * recycled order buffer became a wild load. That was the GC-minor
 * crash (concurrent_compute, 16KB nursery: 10/12 runs, every one a
 * GPF in sl_gc_trace_map).
 *
 * A child the tracer only MARKS needs none of this: sl_gc_mark
 * validates a stale pointer against sl_gc_set before touching it.
 *
 * The owner's generation changes only during a collection. A caller
 * whose owner may already be old (any grow/replace path) holds one
 * preempt bracket from this call to the store into the owner, so no
 * collection can promote the owner in between. A freshly allocated
 * owner needs no bracket: if a collection promotes it in that window,
 * the buffer -- still in a register, saved by the async-preempt
 * trampoline -- is found by the conservative scan and promoted with
 * it, like any other fresh pointer. A gen-1 buffer still starts on the
 * task's pending list and is harvested onto sl_gc_young; the minor
 * sweep moves it to sl_gc_old instead of freeing it (see
 * sl_gc_collect_minor_real). */
static void *sl_gc_alloc_owned(size_t n, const void *owner) {
    return sl_gc_alloc_gen(n, NULL, NULL, owner);
}

/* true drop-in for GC_realloc(p, n): old size/trace read from p's
 * own header, so no call site needs to track them separately (one
 * real site, pkg_json's sl_utf8_append, overwrites its tracked
 * capacity variable before the realloc call, so the old size
 * wouldn't even be available there under a signature that needed
 * it passed in). Never grows in place -- allocates fresh, copies,
 * and lets the old block go unreachable for the next sweep; a real
 * collector makes an orphaned block garbage, not a leak. */
static void *sl_gc_realloc(void *old, size_t newn) {
    if (!old) return sl_gc_alloc(newn, NULL);
    sl_gc_obj *oh = (sl_gc_obj *)old - 1;
    void *nw = sl_gc_alloc_fin(newn, oh->trace, oh->fini);
    size_t copy = oh->size < newn ? oh->size : newn;
    memcpy(nw, old, copy);
    /* The old buffer stays linked (young or old list) until the next
     * collection of its generation reclaims it -- same as before. Its
     * header keeps whatever gen it had; the NEW buffer is young (set
     * by sl_gc_alloc_fin). A buffer whose contents an owner's tracer
     * reads must use sl_gc_realloc_owned instead. */
    return nw;
}

/* sl_gc_realloc for an owned buffer: the new block is born in the
 * owner's generation (see sl_gc_alloc_owned for why that matters).
 * No barrier here: the caller stores the result into the owner and
 * issues the barrier on the owner itself, before its next checkin. */
static void *sl_gc_realloc_owned(void *old, size_t newn,
                                 const void *owner) {
    void *nw = sl_gc_alloc_owned(newn, owner);
    if (old) {
        const sl_gc_obj *oh = (const sl_gc_obj *)old - 1;
        memcpy(nw, old, oh->size < newn ? oh->size : newn);
    }
    return nw;
}

/* growable worklist for the mark phase's breadth-first walk -- an
 * explicit stack, not C recursion, so a long chain of live objects
 * (e.g. a long list) can't overflow the collecting thread's own
 * stack. */
static void **sl_gc_wl = NULL;
static size_t sl_gc_wl_cap = 0;
static size_t sl_gc_wl_n = 0;

static void sl_gc_mark(void *ptr) {
    if (!ptr) return;
    if (!sl_gc_known(ptr)) return; /* not one of ours -- e.g. a
        string literal (.rodata, never sl_gc_alloc'd); unsafe to
        treat ptr - 1 as a header, see sl_gc_set's own comment */
    sl_gc_obj *h = (sl_gc_obj *)ptr - 1;
    if (h->marked) return;
    h->marked = 1;
    if (sl_gc_wl_n == sl_gc_wl_cap) {
        sl_gc_wl_cap = sl_gc_wl_cap ? sl_gc_wl_cap * 2 : 256;
        sl_gc_wl = (void **)realloc(sl_gc_wl,
                                     sl_gc_wl_cap * sizeof(void *));
        if (!sl_gc_wl) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    }
    sl_gc_wl[sl_gc_wl_n++] = ptr;
}

/* Minor-GC mark: like sl_gc_mark, but only for objects on the young
 * list. An OLD object is implicitly alive for the minor cycle (a major
 * collection reclaims old garbage), is not in a minor's sl_gc_set (see
 * sl_gc_set_build), and so is neither marked nor traced here -- nor is
 * its mark bit left to clear afterwards. YOUNG objects mark and recurse
 * exactly like a major cycle; an owned buffer born old (gen 1, still on
 * the young list) is marked, not traced.
 *
 * CORRECTNESS INVARIANT (the whole design hinges on this): at the END
 * of every minor cycle, no live OLD object points at a YOUNG object
 * that is not ALSO being promoted this same cycle. Two mechanisms
 * establish it together: (1) young->young reachability promotes the
 * whole reachable subgraph in one pass (recursion below does this
 * naturally); (2) every POST-promotion old->young store goes through
 * the write barrier, which remembers the old container for the NEXT
 * cycle. A minor cycle that violates this invariant frees a young
 * object still referenced by an old one -- silent heap corruption,
 * exactly the failure mode to suspect first if promotion ever loses
 * objects. */
/* First-survival young objects (gen 0) a minor's mark has met, marked
 * already or not: the remembered phase reads it around each entry's
 * trace to learn whether that old object still holds a pointer that
 * will be young after this minor. Collector-only (STW, under
 * sl_gc_mu). */
static unsigned long long sl_gc_minor_gen0_seen = 0;

static void sl_gc_mark_minor(void *ptr) {
    if (!ptr) return;
    if (!sl_gc_known(ptr)) return;
    sl_gc_obj *h = (sl_gc_obj *)ptr - 1;
    /* Old: alive for this minor, neither marked nor traced -- and never
     * marked, since nothing would clear the bit before a major read it.
     * sl_gc_known recognizes old paged objects too, so the generation is
     * checked here (an owned buffer born old, still on the young list,
     * is moved to the old list by the sweep whether marked or not). */
    if (h->gen == 1) return;
    if (h->gen == 0)
        sl_gc_minor_gen0_seen++;
    if (h->marked) return;
    h->marked = 1;
    if (sl_gc_wl_n == sl_gc_wl_cap) {
        sl_gc_wl_cap = sl_gc_wl_cap ? sl_gc_wl_cap * 2 : 256;
        sl_gc_wl = (void **)realloc(sl_gc_wl,
                                     sl_gc_wl_cap * sizeof(void *));
        if (!sl_gc_wl) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    }
    sl_gc_wl[sl_gc_wl_n++] = ptr;
}

/* Tier 11 eighth slice: the conservative half of the mark phase --
 * every word in [lo, hi) of an async-preempted task's own stack
 * buffer offered to sl_gc_mark as a candidate. Split out of
 * sl_gc_collect's run-queue walk (its only caller, further down)
 * purely so this ONE function can carry the no-sanitize attribute:
 * a conservative stack scanner reads whatever is there, including
 * words AddressSanitizer has deliberately poisoned (its per-frame
 * redzones, which live inside this same malloc'd buffer because a
 * task's stack IS a heap allocation here). Without the attribute an
 * ASan build reports a stack-buffer-underflow on the collector's
 * very first conservative scan -- a genuine false positive (the
 * address is comfortably inside the buffer; it is simply in a
 * redzone slot), and one that made ASan useless for this runtime
 * exactly when it is most wanted. Scoped to this function alone, so
 * every other memory access in the collector -- sl_gc_mark's own
 * header dereference included, since sl_gc_mark stays fully
 * instrumented and is called FROM here -- keeps its checking. Same
 * accommodation every conservative collector needs; the attribute
 * is feature-tested rather than assumed, so a compiler without it
 * still builds. */
#if defined(__has_attribute)
#if __has_attribute(no_sanitize)
#define SL_GC_NO_ASAN __attribute__((no_sanitize("address")))
#endif
#endif
#ifndef SL_GC_NO_ASAN
#define SL_GC_NO_ASAN
#endif
/* The mark function the CURRENT collection's root scan should use.
 * Set by sl_gc_collect (major) / sl_gc_collect_minor before calling
 * sl_gc_mark_roots: the async-preempted conservative scan inside the
 * shared root walk cannot take a mark parameter (its no_sanitize
 * attribute and call shape are fixed), so it dispatches through this
 * instead. A minor cycle sets sl_gc_mark_minor (old objects
 * marked-but-not-traced); a major cycle sets sl_gc_mark. Single-threaded
 * during STW: only the collector thread reads it, no atomics needed.
 * (Declared near the top; defined here next to its only reader.) */
static void (*sl_gc_cur_mark)(void *ptr);

/* A bytes keeps its data inline (sl_bytes_alloc), so code holding only
 * b->ptr holds an address 16 bytes into the object, which sl_gc_set does
 * not list. Recognize exactly that word, so a register or stack slot left
 * with only the data pointer keeps the bytes alive -- what it did when
 * the data was its own object. */
static void sl_gc_trace_bytes(void *p, void (*mark)(void *));
SL_GC_NO_ASAN
static void sl_gc_mark_inline_bytes(void *w) {
    if ((uintptr_t)w < 2 * sizeof(void *)) return;
    void *o = (char *)w - 2 * sizeof(void *);
    if (!sl_gc_known(o)) return;
    sl_gc_obj *h = (sl_gc_obj *)o - 1;
    if (h->trace == sl_gc_trace_bytes && ((void **)o)[1] == w)
        sl_gc_cur_mark(o);
}

SL_GC_NO_ASAN
static void sl_gc_scan_conservative(uintptr_t lo, uintptr_t hi) {
    lo &= ~(uintptr_t)7; /* align down -- rsp itself is always 16-byte
        aligned in practice, but this makes the loop below correct
        even if that ever changes */
    for (uintptr_t a = lo; a + sizeof(void *) <= hi; a += sizeof(void *)) {
        void *w = *(void **)a;
        sl_gc_cur_mark(w);
        sl_gc_mark_inline_bytes(w);
    }
}

/* Page invariant checker (SLANG_GC_PAGE_DEBUG): validates the whole
 * young-page accounting at the start of every set build -- listed
 * headers have bits set and vice versa, free chains stay in-bounds,
 * per-page counters match their listed headers. Slow (quadratic in
 * places), like SLANG_GC_VERIFY_MINOR, and off unless asked. */
static int sl_gc_page_debug_enabled(void) {
    static int cached = -1;
    if (cached < 0)
        cached = getenv("SLANG_GC_PAGE_DEBUG") ? 1 : 0;
    return cached;
}

static void sl_gc_page_check_list(const char *what, sl_gc_obj *head) {
    for (sl_gc_obj *h = head; h; h = h->next) {
        if (!h->paged)
            continue;
        sl_gc_page *pg = sl_gc_page_of(h);
        if (pg->magic != SL_GC_PAGE_MAGIC) {
            fprintf(stderr, "slang-gc-page-debug: %s header %p paged but "
                    "page magic %llx\n", what, (void *)h, pg->magic);
            abort();
        }
        size_t off = (size_t)((char *)h - ((char *)pg +
                                           SL_GC_PAGE_PAYLOAD_OFF));
        size_t slot = off / SL_GC_PAGE_SLOT;
        if (!(pg->bitmap[slot / 64] & (1ULL << (slot % 64)))) {
            fprintf(stderr, "slang-gc-page-debug: %s header %p paged but "
                    "bit clear (off %zu)\n", what, (void *)h, off);
            abort();
        }
    }
}

static void sl_gc_page_check_free(sl_gc_page *pg) {
    char *base = (char *)pg + SL_GC_PAGE_PAYLOAD_OFF;
    size_t link = pg->free_head;
    /* More steps than slots means a cycle: a slot filed twice. */
    for (size_t steps = 0; steps <= SL_GC_PAGE_SLOTS + 1; steps++) {
        if (!link)
            return;
        if (steps > SL_GC_PAGE_SLOTS) {
            fprintf(stderr, "slang-gc-page-debug: free list cycle\n");
            abort();
        }
        size_t off = link - 1;
        size_t *node = (size_t *)(base + off);
        size_t slot = off / SL_GC_PAGE_SLOT;
        if (pg->bitmap[slot / 64] & (1ULL << (slot % 64))) {
            fprintf(stderr, "slang-gc-page-debug: free slot off %zu bit "
                    "set (live?)\n", off);
            abort();
        }
        link = node[0];
    }
}

static int sl_gc_page_listed(sl_gc_obj *h) {
    for (sl_gc_obj *o = sl_gc_young; o; o = o->next)
        if (o == h)
            return 1;
    for (sl_gc_obj *o = sl_gc_old; o; o = o->next)
        if (o == h)
            return 1;
    return 0;
}

static void sl_gc_page_debug_check(void) {
    if (!sl_gc_page_debug_enabled())
        return;
    static int once = 0;
    if (!once) {
        once = 1;
        fprintf(stderr, "slang-gc-page-debug: validator alive\n");
    }
    sl_gc_page_check_list("young", sl_gc_young);
    sl_gc_page_check_list("old", sl_gc_old);
    /* Pending and retired headers pin their slots too: a clear bit on
     * any of them means the page can be reset under a live object. */
    sl_gc_obj *ret = atomic_load_explicit(&sl_gc_retired,
                                          memory_order_relaxed);
    sl_gc_page_check_list("retired", ret);
    /* Reverse: every set bit must be a listed header. A set bit with
     * no owner is a stale mark the rebuild walk would read as a live
     * header and skip by, filing the bytes after it as free. */
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next) {
        sl_gc_worker_state *st = gt->state_ptr;
        if (!st)
            continue;
        for (sl_gc_page *pg = st->pages; pg; pg = pg->next) {
            char *base = (char *)pg + SL_GC_PAGE_PAYLOAD_OFF;
            for (size_t off = 0; off < pg->bump; off += SL_GC_PAGE_SLOT) {
                size_t slot = off / SL_GC_PAGE_SLOT;
                if (!(pg->bitmap[slot / 64] & (1ULL << (slot % 64))))
                    continue;
                if (!sl_gc_page_listed((sl_gc_obj *)(base + off))) {
                    fprintf(stderr, "slang-gc-page-debug: stale bit off "
                            "%zu\n", off);
                    abort();
                }
            }
        }
    }
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next) {
        sl_gc_worker_state *st = gt->state_ptr;
        if (!st)
            continue;
        for (sl_gc_page *pg = st->pages; pg; pg = pg->next) {
            if (pg->magic != SL_GC_PAGE_MAGIC) {
                fprintf(stderr, "slang-gc-page-debug: worker page magic "
                        "%llx\n", pg->magic);
                abort();
            }
            sl_gc_page_check_free(pg);
        }
    }
    for (sl_gc_page *pg = sl_gc_orphans; pg; pg = pg->next)
        sl_gc_page_check_free(pg);
    /* Counter sums: every page's young_live + old_live must equal its
     * listed headers. A shortfall frees the page under live objects;
     * an excess pins it. Either corrupts. */
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next) {
        sl_gc_worker_state *st = gt->state_ptr;
        if (!st)
            continue;
        for (sl_gc_page *pg = st->pages; pg; pg = pg->next) {
            long young = 0, old = 0;
            for (sl_gc_obj *o = sl_gc_young; o; o = o->next) {
                if (!o->paged)
                    continue;
                if (sl_gc_page_of(o) == pg) {
                    if (o->gen != 1)
                        young++;
                    else
                        old++;
                }
            }
            for (sl_gc_obj *o = sl_gc_old; o; o = o->next) {
                if (!o->paged)
                    continue;
                if (sl_gc_page_of(o) == pg) {
                    if (o->gen != 1)
                        young++;
                    else
                        old++;
                }
            }
            if (young != pg->young_live || old != pg->old_live) {
                fprintf(stderr, "slang-gc-page-debug: page %p counts "
                        "(%ld,%ld) vs listed (%ld,%ld)\n", (void *)pg,
                        pg->young_live, pg->old_live, young, old);
                abort();
            }
        }
    }
    /* Free chains must stay inside their page: bounded links, no
     * cycles, sane sizes. A wild chain makes the next claim write a
     * header into live memory. */
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next) {
        sl_gc_worker_state *st = gt->state_ptr;
        if (!st)
            continue;
        for (sl_gc_page *pg = st->pages; pg; pg = pg->next) {
            char *base = (char *)pg + SL_GC_PAGE_PAYLOAD_OFF;
            size_t link = pg->free_head;
            for (size_t steps = 0; link; steps++) {
                if (steps > SL_GC_PAGE_SLOTS ||
                    link - 1 >= SL_GC_PAGE_PAYLOAD_CAP ||
                    (link - 1) % SL_GC_PAGE_SLOT != 0) {
                    fprintf(stderr, "slang-gc-page-debug: bad free chain "
                            "link %zu\n", link);
                    abort();
                }
                size_t *node = (size_t *)(base + link - 1);
                if (node[1] < 16 ||
                    link - 1 + node[1] > SL_GC_PAGE_PAYLOAD_CAP) {
                    fprintf(stderr, "slang-gc-page-debug: bad free node "
                            "size %zu\n", node[1]);
                    abort();
                }
                link = node[0];
            }
        }
    }
}

/* Build the 'is this pointer one of mine' table for one collection,
 * from sl_gc_young -- which by now also holds every task's pending
 * allocations, spliced on just before this runs -- and, with `with_old`,
 * sl_gc_old. A major needs both. A minor needs only the young list: it
 * frees nothing old and traces nothing old, so to sl_gc_mark_minor a
 * pointer to an old object is exactly as uninteresting as a string
 * literal, and "not in the table" is the right answer for both. The old
 * objects a minor must look inside reach it through the remembered set,
 * which holds headers, not candidates to validate. Building from both
 * lists made every minor walk and hash the whole old heap: at a
 * 200k-entry cache that was most of a 50ms minor. See sl_gc_set's own
 * comment. Sized for the population up front at a 0.5 load factor, so
 * sl_gc_set_raw_insert needs no grow path. */
/* The unpaged objects this collection can mark (paged ones answer from
 * their pages, sl_gc_known). A minor's are the young ones: each worker's
 * mbuf and sl_gc_young_m, with no walk of the young list. A major's, and
 * the verifier's full mark, are every unpaged object on either list. */
static void sl_gc_set_build(int with_old) {
    sl_gc_page_debug_check();
    size_t n = 0;
    if (with_old) {
        for (sl_gc_obj *o = sl_gc_young; o; o = o->next) n += !o->paged;
        for (sl_gc_obj *o = sl_gc_old; o; o = o->next) n += !o->paged;
    } else {
        n = sl_gc_young_m_n;
        for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next)
            n += gt->state_ptr->mbuf_n;
    }
    size_t cap = 1024;
    while (cap < (n + 1) * 2) cap *= 2;
    void **tbl = (void **)calloc(cap, sizeof(void *));
    if (!tbl) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    if (with_old) {
        for (sl_gc_obj *o = sl_gc_young; o; o = o->next)
            if (!o->paged)
                sl_gc_set_raw_insert(tbl, cap, (void *)(o + 1));
        for (sl_gc_obj *o = sl_gc_old; o; o = o->next)
            if (!o->paged)
                sl_gc_set_raw_insert(tbl, cap, (void *)(o + 1));
    } else {
        for (size_t i = 0; i < sl_gc_young_m_n; i++)
            sl_gc_set_raw_insert(tbl, cap, (void *)(sl_gc_young_m[i] + 1));
        for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next) {
            sl_gc_worker_state *st = gt->state_ptr;
            for (size_t i = 0; i < st->mbuf_n; i++)
                sl_gc_set_raw_insert(tbl, cap, (void *)(st->mbuf[i] + 1));
        }
    }
    sl_gc_set = tbl;
    sl_gc_set_cap = cap;
    sl_gc_set_count = n;
}

/* End a pause: lower the stop and wake the stopped threads asleep in
 * sl_gc_ack_and_wait. Called with sl_gc_mu held. */
static void sl_gc_stw_release(void) {
    pthread_mutex_lock(&sl_gc_stw_mu);
    atomic_store_explicit(&sl_gc_stop_requested, 0, memory_order_release);
    if (sl_gc_stw_sleepers)
        pthread_cond_broadcast(&sl_gc_stw_cv);
    pthread_mutex_unlock(&sl_gc_stw_mu);
}

/* STW rendezvous shared by minor and major collections: raise
 * sl_gc_stop_requested, bump the cycle, snapshot the thread registry,
 * and spin until every other thread has acked or is blocked. The
 * safepoint/quiescence protocol is not generation-aware and needs no
 * per-kind variant. Caller must hold NO locks; returns with a
 * caller-owned snapshot that must be free()d. */
static void sl_gc_stw_sync(sl_gc_thread ***out_snap, int *out_nsnap) {
    /* Under sl_gc_stw_mu: a thread still asleep from the previous pause
     * (a minor chaining into a major keeps the stop raised) must wake to
     * ack this cycle. */
    pthread_mutex_lock(&sl_gc_stw_mu);
    atomic_store_explicit(&sl_gc_stop_requested, 1, memory_order_release);
    unsigned long cyc = atomic_fetch_add_explicit(&sl_gc_cycle, 1,
                                    memory_order_release) + 1;
    if (sl_gc_stw_sleepers)
        pthread_cond_broadcast(&sl_gc_stw_cv);
    pthread_mutex_unlock(&sl_gc_stw_mu);

    sl_gc_thread **snap = NULL;
    int nsnap = 0, snap_cap = 0;
    pthread_mutex_lock(&sl_gc_mu);
    for (sl_gc_thread *t = sl_gc_threads; t; t = t->next) {
        if (nsnap == snap_cap) {
            snap_cap = snap_cap ? snap_cap * 2 : 16;
            snap = (sl_gc_thread **)realloc(snap,
                                    (size_t)snap_cap * sizeof(*snap));
        }
        snap[nsnap++] = t;
    }
    pthread_mutex_unlock(&sl_gc_mu);

    for (;;) {
        int all_ready = 1;
        for (int i = 0; i < nsnap; i++) {
            sl_gc_thread *t = snap[i];
            if (t == &sl_rt_gc_reg) continue;
            if (atomic_load_explicit(t->blocked_ptr, memory_order_acquire))
                continue;
            if (atomic_load_explicit(t->acked_cycle_ptr,
                                      memory_order_acquire) == cyc)
                continue;
            all_ready = 0;
            break;
        }
        if (all_ready) break;
        sched_yield();
    }
    *out_snap = snap;
    *out_nsnap = nsnap;
}

/* the actual STW mark+sweep. Called only from sl_rt_gc_checkin,
 * never synchronously from sl_gc_alloc (see the comment there).
 * sl_gc_stop_requested and sl_gc_cycle are set *before* sl_gc_mu is
 * ever taken here, and the registry is only read into a private
 * snapshot under a brief lock, released before the quiescence wait
 * -- both load-bearing: holding sl_gc_mu across the whole wait would
 * deadlock against a mutator that needs the same mutex to finish
 * park/resume/unregister before it can reach its own next checkin;
 * reading the live list without the lock for the whole wait would
 * race a concurrent sl_gc_register_thread(). */

/* Root scan shared by minor and major collections: the exact Tier-11
 * root set, parameterized only by the mark function. A minor cycle
 * passes sl_gc_mark_minor (old objects marked-but-not-traced); a
 * major cycle passes sl_gc_mark (everything traced). The root
 * ENUMERATION itself is identical -- this is the verbatim, hard-won
 * code, factored so a generational rewrite cannot reintroduce a
 * rooting gap. Caller holds sl_gc_mu. */
static void sl_gc_mark_roots(sl_gc_thread **snap, int nsnap,
                             sl_gc_markfn_t mark) {
    for (int i = 0; i < nsnap; i++) {
        sl_task *sl_gc_scan_task = *snap[i]->task_slot; /* see
            task_slot's own field comment above: this reads whichever
            task is current AT SCAN TIME, not a value cached at
            registration -- the load-bearing fix for worker reuse. */
        mark(sl_gc_scan_task->join);
        sl_gc_mark_entry_arg_fn(sl_gc_scan_task, mark); /* Tier 11 third-slice
            review finding: root the CURRENTLY-RUNNING task's own
            entry_arg directly too, not just a queued task's (below).
            %s_entry's own generated body builds no safepoint bracket
            around its args struct before reading its fields, so
            nothing else protects it once the task starts running --
            confirmed by a dedicated dequeue-window stress spike
            (see the Tier 11 plan) that reproduced entry_arg
            corruption without this line. */
        for (sl_safepoint *sp = sl_gc_scan_task->safepoint_top; sp;
             sp = sp->prev)
            for (int j = 0; j < sp->nroots; j++)
                mark(sp->roots[j]);
    }
    /* A queued task's entry_arg is a live root that nothing else
     * reaches: a not-yet-started task has an EMPTY safepoint chain,
     * so the per-thread loop above finds nothing about it at all (for
     * real spawn, entry_arg is always a real sl_gc_alloc'd struct).
     * Root it directly by walking the run queue here, while already
     * holding sl_gc_mu: lock order is always sl_gc_mu-then-runq-mu,
     * consistently, and sl_runq_push/pop_blocking (runtime_pool.c)
     * never hold the queue's own mutex while touching sl_gc_mu, so
     * this can't deadlock against them. sl_global_runq itself is
     * declared in RUNTIME[] (runtime_core.c), not here or in
     * runtime_pool.c -- same ordering reason as sl_task: this function
     * needs the complete sl_runq type and the variable both visible at
     * its own definition site, which is well before RUNTIME_POOL is
     * emitted.
     *
     * Tier 11 fourth slice: the safepoint-chain walk below is NOT
     * redundant with the per-thread loop above, and 'a queued task's
     * chain is empty' -- true for every task on this queue before
     * parking existed -- stopped being true the moment sl_task_resume
     * started pushing RESUMED tasks onto this same queue. A resumed
     * task parked mid-execution, deep inside its own nest of live
     * call-site brackets (e.g. inside sl_chan_recv, itself called from
     * generated code holding a dozen live locals), and it sits here,
     * runnable but not yet picked up, for as long as every worker
     * stays busy -- an unbounded stretch under a saturated pool. For
     * that whole stretch it is in NONE of the other root sources: no
     * OS thread's task_slot points at it (it isn't running), and
     * sl_task_resume already unlinked it from sl_parked_tasks (whose
     * own walk further below is the only other place a non-empty chain
     * gets scanned). Marking only entry_arg here therefore left every
     * local a resumed task still legitimately held -- its received
     * channel value included -- invisible to the mark phase, and the
     * sweep freed them out from under it. Reproduced directly by the
     * chan-recv-parking stress case: a worker task's just-received
     * struct read back, after resuming, as another allocation's
     * contents (its own `id` field holding a heap pointer, its
     * `payload` holding a string a DIFFERENT task had since allocated
     * into the recycled block) or as zeroes. Walking the chain here
     * too costs nothing for the not-yet-started case the run queue was
     * originally the only source for -- that chain is NULL, so the
     * loop body never runs -- and is the exact same walk the
     * sl_parked_tasks registry below already does, for the exact same
     * reason: a task suspended mid-execution carries live roots that
     * only its own chain names. */
    pthread_mutex_lock(&sl_global_runq.mu);
    for (sl_task *sl_gc_qt = sl_global_runq.head; sl_gc_qt;
         sl_gc_qt = sl_gc_qt->next) {
        mark(sl_gc_qt->join);
        sl_gc_mark_entry_arg_fn(sl_gc_qt, mark);
        for (sl_safepoint *sp = sl_gc_qt->safepoint_top; sp; sp = sp->prev)
            for (int j = 0; j < sp->nroots; j++)
                mark(sp->roots[j]);
        /* Tier 11 eighth slice: a task with async_preempted set was
         * suspended by a real, arbitrary-instruction-boundary signal,
         * not a cooperative checkpoint -- its safepoint chain, walked
         * above exactly like any other queued task's, is NOT
         * necessarily a complete picture of what it's holding live. A
         * signal can land inside the narrow, real window between
         * sl_gc_alloc returning a fresh pointer and generated code
         * storing it into a rooted slot (a struct field, a list
         * element, a local that will only be added to a bracket a few
         * instructions later) -- nothing in this codebase's own
         * safepoint-bracket discipline has ever needed to cover that
         * gap before, because cooperative checkpoints are placed BY
         * THE COMPILER, which knows to never land one there (see
         * cooperative v1's own 'does not add a checkpoint to a call
         * site with zero live GC roots' scope note -- that's exactly
         * the discipline that keeps this gap closed for the
         * cooperative case). Async preemption has no such guarantee.
         * The fix falls out of the trampoline's own design rather than
         * needing a codegen change: it pushes the FULL register file
         * (every GPR, not just callee-saved) onto the task's own real
         * stack before ever switching away, so any value that was
         * live ONLY in a register at the exact interrupted instant is
         * now sitting in memory, at some address between t->rsp
         * (which points into the middle of that exact save block once
         * queued) and the top of t's stack buffer. A plain conservative
         * scan of that range, validated against sl_gc_set (already
         * built for the unrelated-but-structurally-identical job of
         * telling a real heap pointer from a string literal -- see
         * sl_gc_mark's own comment) before ever marking anything,
         * closes it: sl_gc_mark is already safe to call on arbitrary,
         * mostly-garbage candidate words, since it no-ops on anything
         * sl_gc_set doesn't recognize before it would ever dereference
         * ptr-1. Cooperatively-parked/queued tasks (async_preempted
         * unset) are NOT scanned this way -- their chain is already a
         * complete, precise picture, and conservative scanning them
         * would only risk pinning garbage for no benefit. Reproduced
         * directly without this: cc_real_preempt's own map-heavy
         * workload crashed with a NULL deref inside sl_hash_str,
         * called from sl_map_grow rehashing a key that had been
         * silently swept -- a live sl_gc_alloc'd str, sitting
         * register-resident at the exact instant an async signal
         * landed, invisible to the precise-only walk. */
        if (sl_gc_qt->async_preempted) {
            sl_gc_scan_conservative(
                (uintptr_t)sl_gc_qt->rsp,
                (uintptr_t)sl_gc_qt->stack_base +
                    (uintptr_t)sl_gc_qt->stack_size);
        }
    }
    pthread_mutex_unlock(&sl_global_runq.mu);
    for (unsigned s = 0; s < (unsigned)SL_RUNQ_STRIPES; s++) {
        pthread_mutex_lock(&sl_runq_stripes[s].mu);
        for (sl_task *sl_gc_qt = sl_runq_stripes[s].head; sl_gc_qt;
             sl_gc_qt = sl_gc_qt->runq_link) {
            mark(sl_gc_qt->join);
            sl_gc_mark_entry_arg_fn(sl_gc_qt, mark);
            for (sl_safepoint *sp = sl_gc_qt->safepoint_top; sp; sp = sp->prev)
                for (int j = 0; j < sp->nroots; j++)
                    mark(sp->roots[j]);
            if (sl_gc_qt->async_preempted) {
                sl_gc_scan_conservative(
                    (uintptr_t)sl_gc_qt->rsp,
                    (uintptr_t)sl_gc_qt->stack_base +
                        (uintptr_t)sl_gc_qt->stack_size);
            }
        }
        pthread_mutex_unlock(&sl_runq_stripes[s].mu);
    }
    /* runnext slots hold runnable tasks too, rooted exactly like a
       stripe's (see sl_gc_for_pending_tasks for the same walk) */
    for (int i = 0; i < SL_RUNNEXT_SLOTS; i++) {
        sl_task *sl_gc_qt = atomic_load_explicit(&sl_runnext[i],
                                                 memory_order_acquire);
        if (!sl_gc_qt)
            continue;
        mark(sl_gc_qt->join);
        sl_gc_mark_entry_arg_fn(sl_gc_qt, mark);
        for (sl_safepoint *sp = sl_gc_qt->safepoint_top; sp; sp = sp->prev)
            for (int j = 0; j < sp->nroots; j++)
                mark(sp->roots[j]);
        if (sl_gc_qt->async_preempted) {
            sl_gc_scan_conservative(
                (uintptr_t)sl_gc_qt->rsp,
                (uintptr_t)sl_gc_qt->stack_base +
                    (uintptr_t)sl_gc_qt->stack_size);
        }
    }
    /* Tier 11 fourth slice: a PARKED task (chan_send/recv, this slice)
     * is reachable from neither a registered thread's task_slot (the
     * worker that parked it reassigns that back to its own idle
     * sentinel before fetching the next task) nor the run queue walk
     * just above (it's on some primitive's own wait list instead,
     * e.g. a channel's send/recv_waiters) -- sl_parked_tasks
     * (runtime_core.c) is the dedicated registry every parking
     * primitive must register into for exactly this reason. Unlike a
     * queued task, a parked task's safepoint chain is NOT empty (it
     * parked mid-execution, not before starting), so both entry_arg
     * and the chain need marking here, same as the per-thread walk
     * above. Already holding sl_gc_mu -- sl_parked_tasks is guarded
     * by the same lock, so no extra locking needed to walk it. */
    for (sl_task *sl_gc_pt = sl_parked_tasks; sl_gc_pt;
         sl_gc_pt = sl_gc_pt->parked_next) {
        mark(sl_gc_pt->join);
        sl_gc_mark_entry_arg_fn(sl_gc_pt, mark);
        for (sl_safepoint *sp = sl_gc_pt->safepoint_top; sp; sp = sp->prev)
            for (int j = 0; j < sp->nroots; j++)
                mark(sp->roots[j]);
    }
    while (sl_gc_wl_n > 0) {
        void *p = sl_gc_wl[--sl_gc_wl_n];
        sl_gc_obj *h = (sl_gc_obj *)p - 1;
        if (h->trace) h->trace(p, mark);
    }
}

/* Minor (nursery) STW collection: sweeps ONLY sl_gc_young. Roots are
 * the full Tier-11 set plus every harvested remembered-set object; see
 * sl_gc_minor_mark for which of them are traced. Survivors on
 * sl_gc_young promote to sl_gc_old. sl_gc_old itself is never swept
 * here -- that is what makes this fast. */
static void sl_gc_collect_minor(void);
static void sl_gc_collect_minor_real(void);
static void sl_gc_collect_minor(void) {
    sl_gc_collect_minor_real();
}

/* Defined in sl_containers.c, which every program includes right after
 * this file: the minor traces a remembered list or map only past its
 * gc_clean (the _dirty tracers), and the verifier names what held a
 * missed object. */
static void sl_gc_trace_chan(void *p, void (*mark)(void *));
static void sl_gc_trace_bytes(void *p, void (*mark)(void *));
static void sl_gc_trace_arr(void *p, void (*mark)(void *));
static void sl_gc_trace_map(void *p, void (*mark)(void *));
static void sl_gc_trace_join(void *p, void (*mark)(void *));

/* The minor's whole mark phase: roots, then the remembered set, every
 * drain. `root_mark` is the mark the root phase traces with: always
 * sl_gc_mark_minor on the collection path; sl_gc_verify_minor_marks
 * runs sl_gc_mark from the same roots as its ground truth. */
static void sl_gc_minor_mark(sl_gc_thread **snap, int nsnap, size_t rem_n,
                             sl_gc_markfn_t root_mark) {
    sl_gc_wl_n = 0;
    sl_gc_cur_mark = root_mark;
    sl_gc_mark_roots(snap, nsnap, root_mark); /* drains with root_mark */
    /* Remembered phase: trace each harvested OLD object as a root with
     * the MINOR mark (marks it, then marks-but-does-not-trace its old
     * children while queueing young ones). Drain per entry. Young
     * objects reachable ONLY through old-remembered memory are found
     * here. */
    /* With promotion after two survivals (fix-gc.md 1.2), a child this
     * trace marks for the first time (gen 0) is still young after this
     * minor: it only ages. So an entry whose trace met one stays
     * remembered for the next minor, which reaches that child again --
     * by then gen 2, marked, promoted. A list or map moves its frontier
     * (gc_clean) only up to the first position whose element met such a
     * child, so the next minor retraces from there and no further back:
     * a container growing every minor (a cache being built) is traced
     * about twice per position, not from the start each time. Dropped
     * once its trace meets no gen-0 child. */
    for (size_t i = 0; i < rem_n; i++) {
        sl_gc_obj *rh = sl_gc_rem_harvest_buf[i];
        void *payload = (void *)(rh + 1);
        sl_gc_mark_minor(payload);
        int keep = 0;
        /* A list or map is traced only past what is still clean. */
        if (rh->trace == sl_gc_trace_arr) {
            keep = sl_gc_trace_arr_minor(payload, sl_gc_mark_minor);
        } else if (rh->trace == sl_gc_trace_map) {
            keep = sl_gc_trace_map_minor(payload, sl_gc_mark_minor);
        } else if (rh->trace) {
            unsigned long long seen0 = sl_gc_minor_gen0_seen;
            rh->trace(payload, sl_gc_mark_minor);
            keep = sl_gc_minor_gen0_seen != seen0;
        }
        while (sl_gc_wl_n > 0) {
            void *p = sl_gc_wl[--sl_gc_wl_n];
            sl_gc_obj *wh = (sl_gc_obj *)p - 1;
            if (wh->trace) wh->trace(p, sl_gc_mark_minor);
        }
        if (keep) {
            sl_gc_rem_orphan_push(rh); /* stays remembered = 1 */
        } else {
            rh->remembered = 0;
        }
    }
    sl_gc_rem_harvest_n = 0;
    while (sl_gc_wl_n > 0) {
        void *p = sl_gc_wl[--sl_gc_wl_n];
        sl_gc_obj *h = (sl_gc_obj *)p - 1;
        if (h->trace) h->trace(p, sl_gc_mark_minor);
    }
}

/* ---- SLANG_GC_VERIFY_MINOR: check the write barrier against the truth
 *
 * A minor collection is only sound if every young object reachable from
 * the roots is reachable WITHOUT tracing an old object, other than the
 * old objects in the remembered set -- that is, if every store that put
 * a young pointer into an old object went through the barrier. A missed
 * barrier frees a live object, silently, on the next minor. With this
 * set, every minor marks the way a true minor does (old objects marked,
 * never traced), then clears the marks and runs a full mark from the
 * same roots as ground truth, and reports every young object the full
 * mark reached and the minor did not, with the kind of old container
 * holding it. The sweep then keeps the union, so a verified run frees
 * nothing live even when it finds a hole. The exit line counts minors
 * and missed objects; the suite runs the GC-bearing tests under it and
 * requires missed=0. Diagnostic only: it roughly doubles minor cost. */
static int sl_gc_verify_minor_enabled(void) {
    static int cached = -1;
    if (cached < 0)
        cached = getenv("SLANG_GC_VERIFY_MINOR") ? 1 : 0;
    return cached;
}

/* All four under sl_gc_mu: only a collection touches them. */
static unsigned long long sl_gc_verify_minors = 0;
static unsigned long long sl_gc_verify_missed = 0;
static unsigned sl_gc_verify_reports = 0;
static sl_gc_obj *sl_gc_verify_parent = NULL;
static size_t sl_gc_verify_rem_n = 0; /* this minor's harvest length */

__attribute__((destructor))
static void sl_gc_verify_atexit(void) {
    if (!sl_gc_verify_minor_enabled())
        return;
    fprintf(stderr, "slang-gc-verify minors=%llu missed=%llu\n",
            sl_gc_verify_minors, sl_gc_verify_missed);
}

static const char *sl_gc_verify_kind(const sl_gc_obj *h) {
    if (!h->trace) return "leaf";
    if (h->trace == sl_gc_trace_arr) return "list";
    if (h->trace == sl_gc_trace_map) return "map";
    if (h->trace == sl_gc_trace_chan) return "channel";
    if (h->trace == sl_gc_trace_join) return "join";
    if (h->trace == sl_gc_trace_bytes) return "bytes";
    return "struct or other container";
}

/* Missed young objects carry remembered == 2 while the verifier runs (a
 * young object never has the flag set otherwise); an old object whose
 * tracer reaches one gained that pointer without a barrier. */
static void sl_gc_verify_child(void *c) {
    if (!c || !sl_gc_known(c))
        return;
    sl_gc_obj *h = (sl_gc_obj *)c - 1;
    if (h->gen == 1 || h->remembered != 2)
        return;
    if (sl_gc_verify_reports++ >= 20)
        return;
    /* Remembered or not tells the two failure kinds apart: not in this
     * minor's remembered set means a store skipped the barrier; in it
     * means the barrier ran and tracing through the container missed
     * the child. The harvest buffer still holds this minor's entries. */
    int remembered = 0;
    for (size_t i = 0; i < sl_gc_verify_rem_n; i++)
        if (sl_gc_rem_harvest_buf[i] == sl_gc_verify_parent)
            remembered = 1;
    fprintf(stderr,
            "slang-gc-verify: minor missed a live young %s (%zu bytes) "
            "held by an old %s (%zu bytes, trace=%p, %s)\n",
            sl_gc_verify_kind(h), h->size,
            sl_gc_verify_kind(sl_gc_verify_parent),
            sl_gc_verify_parent->size,
            (void *)sl_gc_verify_parent->trace,
            remembered ? "in the remembered set" : "not remembered");
}

static void sl_gc_verify_parents(sl_gc_obj *list) {
    for (sl_gc_obj *o = list; o; o = o->next) {
        if (o->gen != 1 || !o->marked || !o->trace)
            continue;
        sl_gc_verify_parent = o;
        o->trace((void *)(o + 1), sl_gc_verify_child);
    }
}

/* Runs after sl_gc_minor_mark(..., sl_gc_mark_minor); leaves on every
 * young object the union of the two marks. */
static void sl_gc_verify_minor_marks(sl_gc_thread **snap, int nsnap,
                                     size_t rem_n) {
    sl_gc_verify_rem_n = rem_n;
    size_t n = 0;
    for (sl_gc_obj *h = sl_gc_young; h; h = h->next)
        n++;
    unsigned char *minor = (unsigned char *)malloc(n ? n : 1);
    if (!minor) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    size_t i = 0;
    for (sl_gc_obj *h = sl_gc_young; h; h = h->next)
        minor[i++] = h->marked;
    for (sl_gc_obj *h = sl_gc_young; h; h = h->next)
        h->marked = 0;
    for (sl_gc_obj *h = sl_gc_old; h; h = h->next)
        h->marked = 0;

    /* The minor ran against its own young-only table; the truth needs
     * every object. */
    free(sl_gc_set);
    sl_gc_set_build(1);
    sl_gc_wl_n = 0;
    sl_gc_cur_mark = sl_gc_mark;
    sl_gc_mark_roots(snap, nsnap, sl_gc_mark); /* drains */

    size_t missed = 0;
    i = 0;
    for (sl_gc_obj *h = sl_gc_young; h; h = h->next, i++) {
        if (h->gen != 1 && h->marked && !minor[i]) {
            h->remembered = 2;
            missed++;
        }
    }
    if (missed) {
        sl_gc_verify_parents(sl_gc_old);
        sl_gc_verify_parents(sl_gc_young); /* owned buffers born old */
    }
    i = 0;
    for (sl_gc_obj *h = sl_gc_young; h; h = h->next, i++) {
        if (minor[i])
            h->marked = 1;
        if (h->remembered == 2)
            h->remembered = 0;
    }
    free(minor);
    sl_gc_verify_minors++;
    sl_gc_verify_missed += missed;
}

/* Real minor (nursery) STW collection: nursery-only sweep + promotion.
 *
 * Old objects are marked, never traced -- from the roots as much as from
 * the remembered set -- so a minor costs the nursery plus the remembered
 * set, whatever the size of the old heap. That is sound only while every
 * old->young edge is in the remembered set, and SLANG_GC_VERIFY_MINOR
 * checks exactly that against a full mark (tests/run_tests.sh runs the
 * GC-heavy tests under it). The root phase used to trace old objects
 * too, which hid the edges that had no barrier -- a struct literal
 * promoted between its allocation and its field stores, a select send,
 * a recv buffer filled after its park, a finished task's remembered
 * entries, a major's young survivors -- and made every minor as
 * expensive as marking the whole reachable old heap: 104ms per minor
 * against a 200k-entry cache, where it now costs the nursery's worth. */
/* The nursery's ceiling: 2 MB per worker, at most 16 MB, never below the
 * base. Set once by sl_pool_start, before any task runs. Every
 * collection pays a fixed cost (the rendezvous, ~0.5 ms on a busy
 * server), so a busy server collects less often with a larger nursery;
 * an idle or light one never grows to it (sl_gc_nursery_adapt).
 * Raised from 1 MB a worker (owner decision, 2026-10-05): quote server
 * in a Linux container, 4 workers, ABBA x4: 3,616 -> 4,037 req/s, p99
 * 43 -> 38 ms, CPU per request 973 -> 957 us, peak RSS 31.2 -> 36.6 MB. */
static void sl_gc_nursery_set_max(long workers) {
    size_t mx = (size_t)(workers > 0 ? workers : 1) * 2 * 1024 * 1024;
    if (mx > (size_t)16 * 1024 * 1024)
        mx = (size_t)16 * 1024 * 1024;
    if (mx < SL_GC_NURSERY_BASE)
        mx = SL_GC_NURSERY_BASE;
    sl_gc_nursery_max = mx;
}

/* After each minor (collector, under sl_gc_mu): resize the nursery from
 * this minor's pause against the time since the previous minor ended,
 * and from how much of the nursery it found live. Growing pays only when
 * minors keep re-marking live young data (the quote server: a handful of
 * in-flight requests, every minor); when almost nothing survives, the
 * cost is the fixed per-minor overhead, and a bigger nursery would buy
 * little for its footprint (a tight loop of short strings grew to 8 MB on
 * pause share alone). So it grows only if both are high, and shrinks if
 * either is low. The gaps between the thresholds keep it from flapping.
 * Untouched under SLANG_GC_NURSERY_KB. */
static void sl_gc_nursery_adapt(long long start_ns, long long end_ns,
                                size_t live_young) {
    if (sl_gc_nursery_fixed)
        return;
    long long prev = sl_gc_minor_last_end_ns;
    sl_gc_minor_last_end_ns = end_ns;
    if (!prev)
        return;
    long long pause = end_ns - start_ns;
    long long interval = end_ns - prev;
    size_t cur = atomic_load_explicit(&sl_gc_nursery_threshold,
                                      memory_order_relaxed);
    size_t next = cur;
    if (pause * 8 > interval && live_young * 8 > cur &&
        cur < sl_gc_nursery_max)
        next = cur * 2 > sl_gc_nursery_max ? sl_gc_nursery_max : cur * 2;
    else if ((pause * 64 < interval || live_young * 32 < cur) &&
             cur > SL_GC_NURSERY_BASE)
        next = cur / 2 < SL_GC_NURSERY_BASE ? SL_GC_NURSERY_BASE : cur / 2;
    if (next != cur)
        atomic_store_explicit(&sl_gc_nursery_threshold, next,
                              memory_order_relaxed);
}

static void sl_gc_collect_minor_real(void) {
    int stat_on = sl_gc_stat_enabled();
    long long t0 = sl_rt_monotonic_ns();
    sl_gc_thread **snap = NULL;
    int nsnap = 0;
    sl_gc_phase_clock pc = {.on = stat_on, .t0 = t0};
    sl_gc_stw_sync(&snap, &nsnap);
    sl_gc_ph_mark(&pc, SL_GC_PH_TTSP);

    pthread_mutex_lock(&sl_gc_mu);
    unsigned long long walked0 = sl_gc_walk_count;
    sl_gc_drain_retired();
    sl_gc_for_pending_tasks(sl_gc_harvest_task, snap, nsnap);
    sl_gc_harvest_rem_all(snap, nsnap);
    size_t rem_n = sl_gc_rem_harvest_n;
    sl_gc_ph_mark(&pc, SL_GC_PH_HARVEST);
    sl_gc_set_build(0);
    sl_gc_ph_mark(&pc, SL_GC_PH_SET);
    /* Minor promotion is single-generation: a young object that
     * survives one minor promotes to old (no aging counter -- matches
     * the handoff's design). */
    sl_gc_minor_mark(snap, nsnap, rem_n, sl_gc_mark_minor);
    if (sl_gc_verify_minor_enabled())
        sl_gc_verify_minor_marks(snap, nsnap, rem_n);
    free(sl_gc_wl);
    sl_gc_wl = NULL;
    sl_gc_wl_cap = 0;
    sl_gc_ph_mark(&pc, SL_GC_PH_MARK);

    /* gen 1 on the young list is an owned buffer born old (see
     * sl_gc_alloc_owned). It moves to sl_gc_old whether or not it was
     * marked: its owner is old, a minor never frees old objects, and
     * the buffer must outlive its owner. A major reclaims both. */
    /* Promotion after two survivals (fix-gc.md 1.2). With a single
     * survival, any minor that landed while a request was half built --
     * four workers mid-decode, or one task walking a decoded tree --
     * promoted the whole of it, and it died old: 30-82% of allocations
     * promoted on the quote decode probe, all left for majors. A first
     * survival now only ages an object (gen 2, still young, still on
     * this list); a second promotes it.
     *
     * An object promoted here may point at one that survived this minor
     * for the first time and stays young: an old->young edge no barrier
     * recorded. So every promoted object that can hold pointers is
     * remembered for the next minor, which traces it once (a list or map
     * from position 0) and marks those children; they are promoted at
     * their own second survival, remembered in turn, and so on. The cost
     * is one more trace per promoted object, and promotion is what this
     * makes rare. */
    sl_gc_obj **mpp = &sl_gc_young;
    size_t swept = 0, promoted = 0, live_young = 0, promoted_bytes = 0;
    /* Rebuilt below from the unpaged objects that stay young (1.5). */
    sl_gc_young_m_n = 0;
    while (*mpp) {
        sl_gc_obj *h = *mpp;
        if (h->gen == 1) {
            /* an owned buffer born old: moved, marked or not (above) */
            *mpp = h->next;
            h->marked = 0;
            h->remembered = 0;
            h->next = sl_gc_old;
            sl_gc_old = h;
            promoted++;
            promoted_bytes += sizeof(sl_gc_obj) + h->size;
        } else if (!h->marked) {
            *mpp = h->next;
            if (h->fini)
                h->fini((void *)(h + 1));
            sl_gc_recycle(h);
            swept++;
        } else if (h->gen == 0) {
            live_young += sizeof(sl_gc_obj) + h->size;
            h->marked = 0;
            h->gen = 2;
            if (!h->paged)
                sl_gc_objs_push(&sl_gc_young_m, &sl_gc_young_m_n,
                                &sl_gc_young_m_cap, h);
            mpp = &h->next;
        } else {
            live_young += sizeof(sl_gc_obj) + h->size;
            *mpp = h->next;
            if (h->paged)
                sl_gc_page_promoted(h);
            h->marked = 0;
            h->gen = 1;
            h->next = sl_gc_old;
            sl_gc_old = h;
            promoted++;
            promoted_bytes += sizeof(sl_gc_obj) + h->size;
            if (h->trace) {
                sl_gc_dirty_all((void *)(h + 1));
                h->remembered = 1;
                sl_gc_rem_orphan_push(h);
            } else {
                h->remembered = 0;
            }
        }
    }
    /* Only the verifier's full mark marks old objects in a minor. */
    if (sl_gc_verify_minor_enabled())
        for (sl_gc_obj *o = sl_gc_old; o; o = o->next)
            o->marked = 0;
    /* Every worker's unpaged allocations were on the young list and the
     * sweep just dealt with each: freed, promoted, or kept in
     * sl_gc_young_m. */
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next)
        gt->state_ptr->mbuf_n = 0;
    sl_gc_ph_mark(&pc, SL_GC_PH_SWEEP);
    sl_gc_drain_retired();
    sl_gc_pages_sweep_end();
    /* The table's only reader is mark, which runs only inside a
     * collection -- so it is dead weight between collections and is
     * released rather than carried. See sl_gc_set's own comment. */
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    free(snap);

    /* Majors are paced by promotion: what reached the old generation
     * since the last one, against the live-paced threshold -- or every
     * SL_GC_MAJOR_EVERY minors, whichever comes first (fix-gc.md 1.9). */
    if (!sl_gc_threshold_fixed) {
        size_t prev = atomic_fetch_add_explicit(&sl_gc_bytes_since_collect,
                                                promoted_bytes,
                                                memory_order_relaxed);
        if (prev + promoted_bytes >= sl_gc_threshold ||
            ++sl_gc_minors_since_major >= SL_GC_MAJOR_EVERY)
            atomic_store_explicit(&sl_gc_collect_pending, 1,
                                   memory_order_release);
    }
    atomic_store_explicit(&sl_gc_bytes_since_minor, 0, memory_order_relaxed);
    sl_gc_nursery_adapt(t0, sl_rt_monotonic_ns(), live_young);
    if (stat_on) {
        sl_gc_ph_mark(&pc, SL_GC_PH_TAIL);
        sl_gc_stat_phases(&pc, 0);
        atomic_fetch_add_explicit(&sl_gc_stat_tasks_walked[0],
                                  sl_gc_walk_count - walked0,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&sl_gc_stat_rem_entries,
                                  (unsigned long long)rem_n,
                                  memory_order_relaxed);
        sl_gc_stat_minor_pause(sl_rt_monotonic_ns() - t0, swept, promoted);
    }
    atomic_store_explicit(&sl_gc_collect_minor_pending, 0, memory_order_release);
    /* A major may ALSO be pending (both thresholds tripped on the same
     * allocation burst). Leave sl_gc_collect_pending and
     * sl_gc_stop_requested set in that case so the next checkin runs
     * the major cycle; only fully release when no major is due. */
    if (!atomic_load_explicit(&sl_gc_collect_pending, memory_order_acquire)) {
        sl_gc_stw_release();
        atomic_store_explicit(&sl_gc_collecting, 0, memory_order_release);
    } else {
        atomic_store_explicit(&sl_gc_collecting, 0, memory_order_release);
    }
    pthread_mutex_unlock(&sl_gc_mu);
    /* Chain directly into the pending major while still on the
     * collector path rather than returning to mutators first: the
     * slow-path checkin re-arms via sl_gc_collecting. */
    if (atomic_load_explicit(&sl_gc_collect_pending, memory_order_acquire)) {
        if (!atomic_exchange_explicit(&sl_gc_collecting, 1, memory_order_acq_rel))
            sl_gc_collect();
    }
}

/* Give the C heap's free memory back to the OS after a major: glibc
 * keeps what free() returned, and the sweep's frees are most of it.
 * After the pause, not inside it, and at most every 100 ms: it walks
 * every arena under its locks, and inside the pause it ran after every
 * major -- on the quote server in a Linux container a major came after
 * every minor, so this was most of the 0.75 ms major tail, 800 times in
 * 8 s, with every worker stopped. Measured there (ABBA): every major but
 * outside the pause, -14% req/s (it still ran 100 times a second); every
 * 100 ms, +8.5% req/s, p99 -15%, peak RSS +3.7 MB; every second, about
 * the same speed for +4.6 MB. Memory still goes back within 100 ms of
 * the major that freed it. Called by the collecting thread once the
 * world runs again (its caller's preempt bracket still open); a
 * collection starting meanwhile waits for it like for any thread not
 * yet at a safepoint, which the interval keeps rare. */
static void sl_gc_trim_heap(void) {
#if defined(__GLIBC__)
    static _Atomic long long last_ns = 0;
    long long now = sl_rt_monotonic_ns();
    long long last = atomic_load_explicit(&last_ns, memory_order_relaxed);
    if (now - last < 100000000LL)
        return;
    atomic_store_explicit(&last_ns, now, memory_order_relaxed);
    malloc_trim(0);
#endif
}

/* Major (full-heap) STW collection: today's sl_gc_collect retargeted
 * at both generations. Sweeps sl_gc_young AND sl_gc_old; re-paces
 * sl_gc_threshold by live bytes. Harvests the remembered set so its
 * flags do not leak (no scan needed: the full root walk below already
 * reaches every old object). */
static void sl_gc_collect(void) {
    long long t0 = 0;
    int stat_on = sl_gc_stat_enabled();
    if (stat_on)
        t0 = sl_rt_monotonic_ns();
    sl_gc_thread **snap = NULL;
    int nsnap = 0;
    sl_gc_phase_clock pc = {.on = stat_on, .t0 = t0};
    sl_gc_stw_sync(&snap, &nsnap);
    sl_gc_ph_mark(&pc, SL_GC_PH_TTSP);

    pthread_mutex_lock(&sl_gc_mu);
    unsigned long long walked0 = sl_gc_walk_count;
    sl_gc_drain_retired();
    /* Every live task's pending allocations join sl_gc_young BEFORE
     * the mark, so this cycle can free the ones nothing reaches.
     * Fresh allocations land on sl_gc_young; an owned buffer born old
     * (sl_gc_alloc_owned) stays there, gen 1, until the next minor
     * moves it. A major frees it like anything else unmarked. */
    sl_gc_for_pending_tasks(sl_gc_harvest_task, snap, nsnap);
    sl_gc_harvest_rem_all(snap, nsnap);
    for (size_t i = 0; i < sl_gc_rem_harvest_n; i++)
        sl_gc_rem_harvest_buf[i]->remembered = 0;
    sl_gc_rem_harvest_n = 0;
    sl_gc_ph_mark(&pc, SL_GC_PH_HARVEST);

    /* Must run before the first sl_gc_mark of the cycle: mark's very
     * first act is to reject any pointer this table does not hold. */
    sl_gc_set_build(1);
    sl_gc_ph_mark(&pc, SL_GC_PH_SET);

    sl_gc_wl_n = 0;
    sl_gc_cur_mark = sl_gc_mark;
    sl_gc_mark_roots(snap, nsnap, sl_gc_mark);
    while (sl_gc_wl_n > 0) {
        void *p = sl_gc_wl[--sl_gc_wl_n];
        sl_gc_obj *h = (sl_gc_obj *)p - 1;
        if (h->trace) h->trace(p, sl_gc_mark);
    }
    free(sl_gc_wl);
    sl_gc_wl = NULL;
    sl_gc_wl_cap = 0;
    sl_gc_ph_mark(&pc, SL_GC_PH_MARK);

    /* Every young survivor is promoted. The remembered set was just
     * emptied (above) and no old object is re-remembered, which is sound
     * only if no old->young edge outlives this cycle -- and that holds
     * exactly when nothing live is left young. A survivor kept young
     * here, held by an old container whose barrier entry this cycle had
     * just discarded, was invisible to the next minor: live, and only
     * the old full-mark root phase (sl_gc_minor_mark) kept it from
     * being freed. The cost is tenuring whatever happens to be live at
     * a major a minor early; majors are rare, so it is at most one
     * nursery's worth until the next one. Spliced onto sl_gc_old after
     * that list's own sweep below, which would otherwise free them. */
    size_t marked = 0, swept = 0, live_bytes = 0;
    sl_gc_obj *promoted_head = NULL, *promoted_tail = NULL;
    sl_gc_obj **pp = &sl_gc_young;
    while (*pp) {
        sl_gc_obj *h = *pp;
        if (h->marked) {
            live_bytes += sizeof(sl_gc_obj) + h->size;
            h->marked = 0;
            h->remembered = 0;
            if (h->paged && h->gen != 1)
                sl_gc_page_promoted(h);
            h->gen = 1;
            *pp = h->next;
            h->next = NULL;
            if (promoted_tail)
                promoted_tail->next = h;
            else
                promoted_head = h;
            promoted_tail = h;
            marked++;
        } else {
            *pp = h->next;
            if (h->fini)
                h->fini((void *)(h + 1));
            sl_gc_recycle(h);
            swept++;
        }
    }
    pp = &sl_gc_old;
    while (*pp) {
        sl_gc_obj *h = *pp;
        if (h->marked) {
            live_bytes += sizeof(sl_gc_obj) + h->size;
            h->marked = 0;
            h->remembered = 0;
            pp = &h->next;
            marked++;
        } else {
            *pp = h->next;
            if (h->fini)
                h->fini((void *)(h + 1));
            sl_gc_recycle(h);
            swept++;
        }
    }
    if (promoted_tail) {
        promoted_tail->next = sl_gc_old;
        sl_gc_old = promoted_head;
    }
    /* A major leaves nothing young: no unpaged young object to track. */
    sl_gc_young_m_n = 0;
    for (sl_gc_thread *gt = sl_gc_threads; gt; gt = gt->next)
        gt->state_ptr->mbuf_n = 0;
    sl_gc_ph_mark(&pc, SL_GC_PH_SWEEP);
    sl_gc_drain_retired();
    sl_gc_pages_sweep_end();
    /* The table's only reader is mark, which runs only inside a
     * collection -- so it is dead weight between collections and is
     * released rather than carried. See sl_gc_set's own comment. */
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    free(snap);

    atomic_store_explicit(&sl_gc_bytes_since_collect, 0, memory_order_relaxed);
    atomic_store_explicit(&sl_gc_bytes_since_minor, 0, memory_order_relaxed);
    /* Pace by the live heap, as Go's GOGC=100 does: the next collection
     * comes after allocating as much as survived this one, and never
     * before 8MB. The heap then peaks near twice what is live, however
     * much garbage the program makes.
     *
     * This replaced a threshold that doubled, up to 256MB, whenever a
     * collection found under a quarter of objects alive -- which is
     * every collection of a program that mostly makes garbage, so it
     * sat at 256MB and a program with 1MB live held hundreds of MB.
     * Measured on 18M short-lived results (macOS): 514MB and 3.6s with
     * the ratchet, 19MB and 3.0s collecting every 8MB. It also never
     * followed a heap that GROWS: 8MB forever re-marked an ever-larger
     * live set, which pacing by live bytes avoids. */
    sl_gc_minors_since_major = 0;
    if (!sl_gc_threshold_fixed) {
        size_t floor = 8 * 1024 * 1024;
        sl_gc_threshold = live_bytes > floor ? live_bytes : floor;
    }
    if (stat_on) {
        sl_gc_ph_mark(&pc, SL_GC_PH_TAIL);
        sl_gc_stat_phases(&pc, 1);
        atomic_fetch_add_explicit(&sl_gc_stat_tasks_walked[1],
                                  sl_gc_walk_count - walked0,
                                  memory_order_relaxed);
        sl_gc_stat_pause(sl_rt_monotonic_ns() - t0, marked, swept);
    }
    atomic_store_explicit(&sl_gc_collect_pending, 0, memory_order_release);
    atomic_store_explicit(&sl_gc_collect_minor_pending, 0, memory_order_release);
    sl_gc_stw_release();
    atomic_store_explicit(&sl_gc_collecting, 0, memory_order_release);
    pthread_mutex_unlock(&sl_gc_mu);
    sl_gc_trim_heap();
}

