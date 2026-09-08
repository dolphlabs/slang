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
} sl_gc_obj;

static sl_gc_obj *sl_gc_all = NULL;
static _Atomic(sl_gc_obj *) sl_gc_retired = NULL;
static pthread_mutex_t sl_gc_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic size_t sl_gc_bytes_since_collect = 0;
static size_t sl_gc_threshold = 8 * 1024 * 1024;

static _Atomic unsigned long long sl_gc_stat_collects = 0;
static _Atomic unsigned long long sl_gc_stat_allocs = 0;
static _Atomic unsigned long long sl_gc_stat_alloc_bytes = 0;
static _Atomic unsigned long long sl_gc_stat_pause_ns_total = 0;
static _Atomic unsigned long long sl_gc_stat_pause_ns_max = 0;
static _Atomic unsigned long long sl_gc_stat_swept = 0;
static _Atomic unsigned long long sl_gc_stat_marked = 0;
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
    int b = 0;
    long long bound = 100000;
    while (b + 1 < SL_GC_STAT_BUCKETS && ns >= bound) {
        bound *= 2;
        b++;
    }
    atomic_fetch_add_explicit(&sl_gc_stat_pause_buckets[b], 1, memory_order_relaxed);
}

static void sl_gc_stat_dump(void) {
    if (!sl_gc_stat_enabled())
        return;
    unsigned long long collects = atomic_load_explicit(&sl_gc_stat_collects, memory_order_relaxed);
    unsigned long long allocs = atomic_load_explicit(&sl_gc_stat_allocs, memory_order_relaxed);
    unsigned long long bytes = atomic_load_explicit(&sl_gc_stat_alloc_bytes, memory_order_relaxed);
    unsigned long long total = atomic_load_explicit(&sl_gc_stat_pause_ns_total, memory_order_relaxed);
    unsigned long long max = atomic_load_explicit(&sl_gc_stat_pause_ns_max, memory_order_relaxed);
    unsigned long long marked = atomic_load_explicit(&sl_gc_stat_marked, memory_order_relaxed);
    unsigned long long swept = atomic_load_explicit(&sl_gc_stat_swept, memory_order_relaxed);
    fprintf(stderr, "slang-gc-stat collects=%llu allocs=%llu alloc_bytes=%llu pause_ns_total=%llu pause_ns_max=%llu marked=%llu swept=%llu\n",
            collects, allocs, bytes, total, max, marked, swept);
    fprintf(stderr, "slang-gc-stat pause_buckets_ns=[");
    long long bound = 100000;
    for (int b = 0; b < SL_GC_STAT_BUCKETS; b++) {
        unsigned long long n = atomic_load_explicit(&sl_gc_stat_pause_buckets[b], memory_order_relaxed);
        fprintf(stderr, "%s<%lld:%llu", b ? "," : "", bound, n);
        bound *= 2;
    }
    fprintf(stderr, "]\n");
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
} sl_gc_thread;
static sl_gc_thread *sl_gc_threads = NULL;

/* Task-owned allocation shard. Mutators never take sl_gc_mu: objects
 * stay on sl_task.gc_pend_* until the next STW harvest or the task
 * dies (lock-free retire onto sl_gc_retired). The byte counter is
 * an atomic published every SL_GC_PENDING_BATCH allocs.
 *
 * Pending objects are not on sl_gc_all, so sweep cannot free them.
 * They may reference objects that are, so the collector traces every
 * live task's pending list as a root. Reading another task's list
 * is safe because mark does not start until every registered thread
 * is acked or gc_blocked, and neither state is reachable from
 * sl_gc_alloc. */
#define SL_GC_PENDING_BATCH 32
static _Atomic int sl_gc_stop_requested = 0;
static _Atomic unsigned long sl_gc_cycle = 0;
static _Atomic int sl_gc_collect_pending = 0;
static _Atomic int sl_gc_collecting = 0;

static _Thread_local sl_gc_thread sl_rt_gc_reg;
static _Thread_local _Atomic int sl_rt_gc_blocked = 0;
static _Thread_local _Atomic unsigned long sl_rt_gc_acked_cycle = 0;

static void sl_gc_collect(void);
static void sl_gc_mark(void *ptr);

static void sl_gc_mark_entry_arg(sl_task *t) {
    if (!t) return;
    if (t->entry_arg_trace)
        t->entry_arg_trace(t->entry_arg, sl_gc_mark);
    else
        sl_gc_mark(t->entry_arg);
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
    pthread_mutex_lock(&sl_gc_mu);
    sl_rt_gc_reg.next = sl_gc_threads;
    sl_gc_threads = &sl_rt_gc_reg;
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
static inline void sl_gc_ack_and_wait(void) {
    unsigned long cyc = atomic_load_explicit(&sl_gc_cycle,
                                              memory_order_acquire);
    atomic_store_explicit(&sl_rt_gc_acked_cycle, cyc,
                           memory_order_release);
    while (atomic_load_explicit(&sl_gc_stop_requested,
                                 memory_order_acquire)) {
        sched_yield();
        unsigned long now = atomic_load_explicit(&sl_gc_cycle,
                                                  memory_order_acquire);
        if (now != cyc) {
            cyc = now;
            atomic_store_explicit(&sl_rt_gc_acked_cycle, cyc,
                                   memory_order_release);
        }
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
                                   memory_order_acquire)) {
            sl_rt_preempt_enable();
            return;
        }
        if (!atomic_exchange_explicit(&sl_gc_collecting, 1,
                                       memory_order_acq_rel)) {
            sl_gc_collect();
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
    if (atomic_load_explicit(&sl_gc_stop_requested,
                             memory_order_acquire) ||
        atomic_load_explicit(&sl_gc_collect_pending,
                             memory_order_acquire))
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
static void sl_gc_publish_bytes(sl_task *t) {
    size_t delta = t->gc_pend_bytes - t->gc_pend_pub;
    if (!delta) return;
    t->gc_pend_pub = t->gc_pend_bytes;
    size_t prev = atomic_fetch_add_explicit(&sl_gc_bytes_since_collect, delta,
                                            memory_order_relaxed);
    if (prev + delta >= sl_gc_threshold)
        atomic_store_explicit(&sl_gc_collect_pending, 1,
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

static void sl_gc_flush_task(sl_task *t) {
    if (!t || !t->gc_pend_head) return;
    sl_gc_publish_bytes(t);
    sl_gc_obj *head = t->gc_pend_head;
    sl_gc_obj *tail = t->gc_pend_tail;
    t->gc_pend_head = NULL;
    t->gc_pend_tail = NULL;
    t->gc_pend_n = 0;
    t->gc_pend_bytes = 0;
    t->gc_pend_pub = 0;
    sl_gc_retire_list(head, tail);
}

static void sl_gc_drain_retired(void) {
    sl_gc_obj *ret = atomic_exchange_explicit(&sl_gc_retired, NULL,
                                              memory_order_acquire);
    if (!ret) return;
    sl_gc_obj *tail = ret;
    while (tail->next) tail = tail->next;
    tail->next = sl_gc_all;
    sl_gc_all = ret;
}

static void sl_gc_harvest_task(sl_task *t) {
    if (!t || !t->gc_pend_head) return;
    t->gc_pend_tail->next = sl_gc_all;
    sl_gc_all = t->gc_pend_head;
    t->gc_pend_head = NULL;
    t->gc_pend_tail = NULL;
    t->gc_pend_n = 0;
    t->gc_pend_bytes = 0;
    t->gc_pend_pub = 0;
}

static size_t sl_gc_pend_count(sl_task *t) {
    size_t n = 0;
    if (!t) return 0;
    for (sl_gc_obj *po = t->gc_pend_head; po; po = po->next) n++;
    return n;
}

static void sl_gc_pend_insert(sl_task *t, void **tbl, size_t cap) {
    if (!t) return;
    for (sl_gc_obj *po = t->gc_pend_head; po; po = po->next)
        sl_gc_set_raw_insert(tbl, cap, (void *)(po + 1));
}

static void sl_gc_pend_mark(sl_task *t) {
    if (!t) return;
    for (sl_gc_obj *po = t->gc_pend_head; po; po = po->next)
        sl_gc_mark((void *)(po + 1));
}

static void sl_gc_pend_unmark(sl_task *t) {
    if (!t) return;
    for (sl_gc_obj *po = t->gc_pend_head; po; po = po->next)
        po->marked = 0;
}

static void sl_gc_for_pending_tasks(void (*fn)(sl_task *),
                                    sl_gc_thread **snap, int nsnap) {
    for (int i = 0; i < nsnap; i++)
        fn(*snap[i]->task_slot);
    pthread_mutex_lock(&sl_global_runq.mu);
    for (sl_task *t = sl_global_runq.head; t; t = t->next)
        fn(t);
    pthread_mutex_unlock(&sl_global_runq.mu);
    for (unsigned s = 0; s < (unsigned)SL_RUNQ_STRIPES; s++) {
        pthread_mutex_lock(&sl_runq_stripes[s].mu);
        for (sl_task *t = sl_runq_stripes[s].head; t; t = t->runq_link)
            fn(t);
        pthread_mutex_unlock(&sl_runq_stripes[s].mu);
    }
    for (sl_task *t = sl_parked_tasks; t; t = t->parked_next)
        fn(t);
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
    h->trace = NULL;
    h->fini = NULL;
    h->marked = 0;
    return h;
}

static void sl_gc_class_push(sl_gc_obj *h) {
    size_t total = h->size + sizeof(sl_gc_obj);
    int c = sl_gc_class_for(total);
    if (c < 0) {
        free(h);
        return;
    }
    pthread_mutex_lock(&sl_gc_class_mu);
    if (sl_gc_class_fl_n[c] < SL_GC_CLASS_MAX) {
        h->next = sl_gc_class_fl[c];
        sl_gc_class_fl[c] = h;
        sl_gc_class_fl_n[c]++;
        pthread_mutex_unlock(&sl_gc_class_mu);
        return;
    }
    pthread_mutex_unlock(&sl_gc_class_mu);
    free(h);
}

static void *sl_gc_alloc_fin(size_t n,
                             void (*trace)(void *, void (*)(void *)),
                             void (*fini)(void *)) {
    sl_rt_preempt_disable();
    sl_task *t = sl_rt_cur();
    sl_gc_obj *h = sl_gc_class_pop(sizeof(sl_gc_obj) + n);
    if (!h) {
        h = (sl_gc_obj *)malloc(sizeof(sl_gc_obj) + n);
        if (!h) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    }
    memset(h + 1, 0, n);
    h->size = n;
    h->trace = trace;
    h->fini = fini;
    h->marked = 0;
    h->next = t->gc_pend_head;
    if (!t->gc_pend_head) t->gc_pend_tail = h;
    t->gc_pend_head = h;
    t->gc_pend_n++;
    t->gc_pend_bytes += sizeof(sl_gc_obj) + n;
    if (sl_gc_stat_enabled()) {
        atomic_fetch_add_explicit(&sl_gc_stat_allocs, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&sl_gc_stat_alloc_bytes,
                                  (unsigned long long)(sizeof(sl_gc_obj) + n),
                                  memory_order_relaxed);
    }
    sl_gc_publish_bytes(t);
    sl_rt_preempt_enable();
    return (void *)(h + 1);
}

static void *sl_gc_alloc(size_t n,
                          void (*trace)(void *, void (*)(void *))) {
    return sl_gc_alloc_fin(n, trace, NULL);
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
    if (!sl_gc_set_contains(ptr)) return; /* not one of ours -- e.g. a
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
SL_GC_NO_ASAN
static void sl_gc_scan_conservative(uintptr_t lo, uintptr_t hi) {
    lo &= ~(uintptr_t)7; /* align down -- rsp itself is always 16-byte
        aligned in practice, but this makes the loop below correct
        even if that ever changes */
    for (uintptr_t a = lo; a + sizeof(void *) <= hi; a += sizeof(void *))
        sl_gc_mark(*(void **)a);
}

/* Build the 'is this pointer one of mine' table for one collection,
 * from every object the collector can reach a header for: sl_gc_all,
 * plus every registered thread's un-spliced allocation batch. The
 * pending lists are not optional -- omitting them is what made the
 * pending-tracing loop below a no-op. See sl_gc_set's own comment.
 *
 * Safe to read each thread's batch here for the same reason the
 * pending-tracing loop can: every thread in snap has acked the stop
 * request or is gc_blocked, so none of them is inside sl_gc_alloc
 * mutating its own batch. Sized for the whole population up front at
 * a 0.5 load factor, so sl_gc_set_raw_insert needs no grow path. */
static void sl_gc_set_build(sl_gc_thread **snap, int nsnap) {
    size_t n = 0;
    for (sl_gc_obj *o = sl_gc_all; o; o = o->next) n++;
    for (int i = 0; i < nsnap; i++)
        n += sl_gc_pend_count(*snap[i]->task_slot);
    pthread_mutex_lock(&sl_global_runq.mu);
    for (sl_task *t = sl_global_runq.head; t; t = t->next)
        n += sl_gc_pend_count(t);
    pthread_mutex_unlock(&sl_global_runq.mu);
    for (unsigned s = 0; s < (unsigned)SL_RUNQ_STRIPES; s++) {
        pthread_mutex_lock(&sl_runq_stripes[s].mu);
        for (sl_task *t = sl_runq_stripes[s].head; t; t = t->runq_link)
            n += sl_gc_pend_count(t);
        pthread_mutex_unlock(&sl_runq_stripes[s].mu);
    }
    for (sl_task *t = sl_parked_tasks; t; t = t->parked_next)
        n += sl_gc_pend_count(t);
    size_t cap = 1024;
    while (cap < (n + 1) * 2) cap *= 2;
    void **tbl = (void **)calloc(cap, sizeof(void *));
    if (!tbl) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    for (sl_gc_obj *o = sl_gc_all; o; o = o->next)
        sl_gc_set_raw_insert(tbl, cap, (void *)(o + 1));
    for (int i = 0; i < nsnap; i++)
        sl_gc_pend_insert(*snap[i]->task_slot, tbl, cap);
    pthread_mutex_lock(&sl_global_runq.mu);
    for (sl_task *t = sl_global_runq.head; t; t = t->next)
        sl_gc_pend_insert(t, tbl, cap);
    pthread_mutex_unlock(&sl_global_runq.mu);
    for (unsigned s = 0; s < (unsigned)SL_RUNQ_STRIPES; s++) {
        pthread_mutex_lock(&sl_runq_stripes[s].mu);
        for (sl_task *t = sl_runq_stripes[s].head; t; t = t->runq_link)
            sl_gc_pend_insert(t, tbl, cap);
        pthread_mutex_unlock(&sl_runq_stripes[s].mu);
    }
    for (sl_task *t = sl_parked_tasks; t; t = t->parked_next)
        sl_gc_pend_insert(t, tbl, cap);
    sl_gc_set = tbl;
    sl_gc_set_cap = cap;
    sl_gc_set_count = n;
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
static void sl_gc_collect(void) {
    long long t0 = 0;
    int stat_on = sl_gc_stat_enabled();
    if (stat_on)
        t0 = sl_rt_monotonic_ns();
    atomic_store_explicit(&sl_gc_stop_requested, 1, memory_order_release);
    unsigned long cyc = atomic_fetch_add_explicit(&sl_gc_cycle, 1,
                                    memory_order_release) + 1;

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

    pthread_mutex_lock(&sl_gc_mu);
    sl_gc_drain_retired();

    /* Must run before the first sl_gc_mark of the cycle: mark's very
     * first act is to reject any pointer this table does not hold. */
    sl_gc_set_build(snap, nsnap);

    sl_gc_wl_n = 0;
    for (int i = 0; i < nsnap; i++) {
        sl_gc_pend_mark(*snap[i]->task_slot);
        sl_task *sl_gc_scan_task = *snap[i]->task_slot; /* see
            task_slot's own field comment above: this reads whichever
            task is current AT SCAN TIME, not a value cached at
            registration -- the load-bearing fix for worker reuse. */
        sl_gc_mark(sl_gc_scan_task->join);
        sl_gc_mark_entry_arg(sl_gc_scan_task); /* Tier 11 third-slice
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
                sl_gc_mark(sp->roots[j]);
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
        sl_gc_mark(sl_gc_qt->join);
        sl_gc_mark_entry_arg(sl_gc_qt);
        sl_gc_pend_mark(sl_gc_qt);
        for (sl_safepoint *sp = sl_gc_qt->safepoint_top; sp; sp = sp->prev)
            for (int j = 0; j < sp->nroots; j++)
                sl_gc_mark(sp->roots[j]);
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
            sl_gc_mark(sl_gc_qt->join);
            sl_gc_mark_entry_arg(sl_gc_qt);
            sl_gc_pend_mark(sl_gc_qt);
            for (sl_safepoint *sp = sl_gc_qt->safepoint_top; sp; sp = sp->prev)
                for (int j = 0; j < sp->nroots; j++)
                    sl_gc_mark(sp->roots[j]);
            if (sl_gc_qt->async_preempted) {
                sl_gc_scan_conservative(
                    (uintptr_t)sl_gc_qt->rsp,
                    (uintptr_t)sl_gc_qt->stack_base +
                        (uintptr_t)sl_gc_qt->stack_size);
            }
        }
        pthread_mutex_unlock(&sl_runq_stripes[s].mu);
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
        sl_gc_mark(sl_gc_pt->join);
        sl_gc_mark_entry_arg(sl_gc_pt);
        sl_gc_pend_mark(sl_gc_pt);
        for (sl_safepoint *sp = sl_gc_pt->safepoint_top; sp; sp = sp->prev)
            for (int j = 0; j < sp->nroots; j++)
                sl_gc_mark(sp->roots[j]);
    }
    while (sl_gc_wl_n > 0) {
        void *p = sl_gc_wl[--sl_gc_wl_n];
        sl_gc_obj *h = (sl_gc_obj *)p - 1;
        if (h->trace) h->trace(p, sl_gc_mark);
    }
    /* Release the worklist rather than keeping it for next time. It
     * grows to hold every object marked in a cycle, so on a large
     * heap it is 8 bytes per live object of RESIDENT memory between
     * collections -- measured at ~10 B/object of a total ~113 B/object
     * footprint on an 800k-live-string probe, purely to save a
     * doubling ramp (~12 reallocs) once per collection against a full
     * mark-sweep. Bad trade: the memory is permanent, the saving is
     * per-cycle and negligible. */
    free(sl_gc_wl);
    sl_gc_wl = NULL;
    sl_gc_wl_cap = 0;

    sl_gc_obj **pp = &sl_gc_all;
    size_t marked = 0, swept = 0;
    while (*pp) {
        sl_gc_obj *h = *pp;
        if (!h->marked) {
            *pp = h->next;
            if (h->fini)
                h->fini((void *)(h + 1));
            sl_gc_class_push(h);
            swept++;
        } else {
            h->marked = 0;
            pp = &h->next;
            marked++;
        }
    }
    /* Pending objects are now markable (sl_gc_set_build puts them in
     * the table), but they are NOT on sl_gc_all, so the sweep loop
     * above never reaches them to clear the flag it just set. Leaving
     * it set is not a leak, it is a use-after-free: sl_gc_mark's own
     * 'if (h->marked) return' would then skip the object on the NEXT
     * cycle without ever tracing its children, and those children ARE
     * on sl_gc_all and get swept. Caught empirically -- 4 of 6
     * concurrent_compute runs segfaulting -- not by reading the code. */
    sl_gc_for_pending_tasks(sl_gc_pend_unmark, snap, nsnap);
    sl_gc_for_pending_tasks(sl_gc_harvest_task, snap, nsnap);
    sl_gc_drain_retired();
    /* The table's only reader is sl_gc_mark, which runs only inside
     * this function -- so it is dead weight between collections and
     * is released rather than carried. See sl_gc_set's own comment. */
    free(sl_gc_set);
    sl_gc_set = NULL;
    sl_gc_set_cap = 0;
    sl_gc_set_count = 0;
    free(snap);

    atomic_store_explicit(&sl_gc_bytes_since_collect, 0, memory_order_relaxed);
#if defined(__GLIBC__)
    malloc_trim(0);
#endif
    if (stat_on)
        sl_gc_stat_pause(sl_rt_monotonic_ns() - t0, marked, swept);
    atomic_store_explicit(&sl_gc_collect_pending, 0, memory_order_release);
    atomic_store_explicit(&sl_gc_stop_requested, 0, memory_order_release);
    atomic_store_explicit(&sl_gc_collecting, 0, memory_order_release);
    pthread_mutex_unlock(&sl_gc_mu);
}

