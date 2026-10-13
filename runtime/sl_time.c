#include <time.h>
#include <errno.h>

/* ---- time: monotonic + wall clock; duration is nanoseconds ---- */

static long long sl_time_mono(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}

static long long sl_time_wall(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}

/* ---- the HTTP Date header (RFC 9110 6.6.1) ----
 *
 * An origin server with a clock sends Date on every response. It changes
 * once a second, so one 29-byte IMF-fixdate ("Tue, 13 Oct 2026 09:30:15
 * GMT") is kept for every thread, the way Go's net/http and fasthttp keep
 * theirs: a seqlock over four atomic words.
 *
 * The preemption ticker keeps it current (sl_hd_tick, every 2 ms on its
 * own thread), so a response reads no clock: it copies the words and
 * checks the sequence did not move -- measured, the clock read was most of
 * the date's cost on the fast write path. Until the ticker has published
 * (or in a program whose ticker is not running), a reader reads the clock
 * itself, and the first to see a new second publishes it through a CAS.
 * A reader that finds a write in progress formats its own copy instead of
 * waiting: no lock, no spin, no allocation, no thread-local. The words are
 * atomics, so the copy is not a data race even when it loses. */
#define SL_HD_LEN 29
static _Atomic unsigned long long sl_hd_seq;      /* odd while a write is in progress */
static _Atomic long long sl_hd_sec = -1;
static _Atomic unsigned long long sl_hd_words[4]; /* 32 bytes; the date is the first 29 */

static void sl_hd_format(long long sec, char out[32]) {
    static const char *const wd = "ThuFriSatSunMonTueWed"; /* 1970-01-01 was a Thursday */
    static const char *const mn = "JanFebMarAprMayJunJulAugSepOctNovDec";
    long long days = sec >= 0 ? sec / 86400 : -((-sec + 86399) / 86400);
    long long rem = sec - days * 86400;
    int w = (int)(((days % 7) + 7) % 7);
    /* civil_from_days, H. Hinnant */
    long long z = days + 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    long long doe = z - era * 146097;
    long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long long y = yoe + era * 400;
    long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long long mp = (5 * doy + 2) / 153;
    int d = (int)(doy - (153 * mp + 2) / 5 + 1);
    int m = (int)(mp < 10 ? mp + 3 : mp - 9);
    if (m <= 2)
        y++;
    if (y < 0)
        y = 0;
    if (y > 9999)
        y = 9999;
    int hh = (int)(rem / 3600), mi = (int)(rem / 60 % 60), ss = (int)(rem % 60);
    memset(out, 0, 32);
    memcpy(out, wd + 3 * w, 3);
    out[3] = ',';
    out[4] = ' ';
    out[5] = (char)('0' + d / 10);
    out[6] = (char)('0' + d % 10);
    out[7] = ' ';
    memcpy(out + 8, mn + 3 * (m - 1), 3);
    out[11] = ' ';
    out[12] = (char)('0' + (int)(y / 1000));
    out[13] = (char)('0' + (int)(y / 100 % 10));
    out[14] = (char)('0' + (int)(y / 10 % 10));
    out[15] = (char)('0' + (int)(y % 10));
    out[16] = ' ';
    out[17] = (char)('0' + hh / 10);
    out[18] = (char)('0' + hh % 10);
    out[19] = ':';
    out[20] = (char)('0' + mi / 10);
    out[21] = (char)('0' + mi % 10);
    out[22] = ':';
    out[23] = (char)('0' + ss / 10);
    out[24] = (char)('0' + ss % 10);
    memcpy(out + 25, " GMT", 4);
}

static _Atomic int sl_hd_ticked; /* the ticker has published at least once */

static void sl_hd_publish(long long now, const char d[32], unsigned long long s1) {
    unsigned long long w[4];
    memcpy(w, d, 32);
    for (int i = 0; i < 4; i++)
        atomic_store_explicit(&sl_hd_words[i], w[i], memory_order_relaxed);
    atomic_store_explicit(&sl_hd_sec, now, memory_order_relaxed);
    atomic_store_explicit(&sl_hd_seq, s1 + 2, memory_order_release);
}

/* The ticker's hook: on its own native thread, never a task. */
static void sl_hd_tick(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long long now = (long long)ts.tv_sec;
    unsigned long long s1 = atomic_load_explicit(&sl_hd_seq, memory_order_acquire);
    if (atomic_load_explicit(&sl_hd_sec, memory_order_relaxed) != now && !(s1 & 1) &&
        atomic_compare_exchange_strong_explicit(&sl_hd_seq, &s1, s1 + 1,
                                                memory_order_acquire,
                                                memory_order_relaxed)) {
        char d[32];
        sl_hd_format(now, d);
        sl_hd_publish(now, d, s1);
    }
    atomic_store_explicit(&sl_hd_ticked, 1, memory_order_relaxed);
}

__attribute__((constructor)) static void sl_hd_register(void) {
    sl_rt_tick_hook = sl_hd_tick;
}

static void sl_hd_current(char out[32]) {
    if (atomic_load_explicit(&sl_hd_ticked, memory_order_relaxed)) {
        unsigned long long s1 = atomic_load_explicit(&sl_hd_seq, memory_order_acquire);
        if (!(s1 & 1)) {
            unsigned long long w[4];
            for (int i = 0; i < 4; i++)
                w[i] = atomic_load_explicit(&sl_hd_words[i], memory_order_relaxed);
            atomic_thread_fence(memory_order_acquire);
            if (atomic_load_explicit(&sl_hd_seq, memory_order_relaxed) == s1) {
                memcpy(out, w, 32);
                return;
            }
        }
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long long now = (long long)ts.tv_sec;
    unsigned long long s1 = atomic_load_explicit(&sl_hd_seq, memory_order_acquire);
    if (!(s1 & 1) && atomic_load_explicit(&sl_hd_sec, memory_order_relaxed) == now) {
        unsigned long long w[4];
        for (int i = 0; i < 4; i++)
            w[i] = atomic_load_explicit(&sl_hd_words[i], memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&sl_hd_seq, memory_order_relaxed) == s1) {
            memcpy(out, w, 32);
            return;
        }
    }
    sl_hd_format(now, out);
    if (!(s1 & 1) && atomic_load_explicit(&sl_hd_sec, memory_order_relaxed) < now &&
        atomic_compare_exchange_strong_explicit(&sl_hd_seq, &s1, s1 + 1,
                                                memory_order_acquire,
                                                memory_order_relaxed)) {
        sl_hd_publish(now, out, s1);
    }
}

/* time.put_http_date(w, off): the current HTTP date into `w` at `off`.
 * Returns off + 29 whether or not it fit, the probe/fill contract of
 * http's put_* helpers: a zero-length probe wire counts, a real one
 * writes. */
static long long sl_time_put_http_date(sl_wire w, long long off) {
    /* the probe pass sizes with a zero-length wire: no clock read */
    if (off >= 0 && off <= w.len && w.len - off >= SL_HD_LEN) {
        char d[32];
        sl_hd_current(d);
        memcpy(w.ptr + off, d, SL_HD_LEN);
    }
    return off + SL_HD_LEN;
}

/* time.http_date(): the same 29 bytes as a str. */
static char *sl_time_http_date(void) {
    char d[32];
    sl_hd_current(d);
    char *out = (char *)sl_gc_alloc_leaf_uninit(SL_HD_LEN + 1, NULL);
    memcpy(out, d, SL_HD_LEN);
    out[SL_HD_LEN] = 0;
    return out;
}

/* Tier 11 fifth slice: time.sleep now PARKS the calling task
 * (sl_task_park/sl_task_resume, runtime_pool.c) instead of blocking
 * the OS thread in nanosleep. Unlike chan, nothing else ever
 * 'satisfies' a sleeping task's wait -- there's no other task to
 * hand off to -- so this package builds the one piece that's
 * genuinely new: a sorted-by-deadline wait list plus one dedicated
 * background thread that actively notices deadlines passing and
 * calls sl_task_resume on their behalf. Package-local (not core
 * scheduler infrastructure like sl_global_runq/sl_parked_tasks),
 * since only time.sleep needs it. See the Tier 11 plan for the full
 * design and the review findings -- notably: this machine's pthread
 * has no pthread_condattr_setclock, so pthread_cond_timedwait's
 * absolute deadline is CLOCK_REALTIME-based here, unlike the old
 * nanosleep-based sleep (relative-duration, immune to wall-clock
 * jumps) -- deadlines are tracked in monotonic time throughout, and
 * the timer thread never waits longer than SL_TIME_MAX_WAIT_NS in
 * one pthread_cond_timedwait call, re-deriving a fresh REALTIME
 * absolute timeout from the monotonic remaining time every
 * iteration, bounding (not eliminating) the wall-clock-jump drift a
 * single long precise wait would otherwise leave unbounded. */
static sl_task *sl_time_sleepers = NULL; /* sorted earliest-deadline-
    first, linked via sl_task.next -- guarded by sl_time_mu */
static pthread_mutex_t sl_time_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sl_time_cond = PTHREAD_COND_INITIALIZER;

#define SL_TIME_MAX_WAIT_NS 1000000000LL

static void sl_time_insert(sl_task *t, long long deadline_ns) {
    t->sleep_deadline_ns = deadline_ns;
    sl_task **pp = &sl_time_sleepers;
    while (*pp && (*pp)->sleep_deadline_ns <= deadline_ns) pp = &(*pp)->next;
    t->next = *pp;
    *pp = t;
}

/* Runs until process exit, same convention sl_worker_loop's own
 * workers already follow -- no shutdown call exists for it either.
 * Deliberately NOT registered with the GC thread registry: it never
 * drives a task (no sl_ctx_switch calls of its own) and never
 * touches a GC-scanned field, only the plain, non-GC-managed
 * `next`/`sleep_deadline_ns` fields on an already-sl_parked_tasks-
 * rooted task, and sl_task_resume itself (which needs no caller
 * registration -- already proven safe from an unregistered caller
 * context in exactly this shape by sl_chan_send/recv's own
 * identical use of it). */
static void *sl_time_thread(void *arg) {
    (void)arg;
    pthread_mutex_lock(&sl_time_mu);
    for (;;) {
        long long now_ns = sl_time_mono();
        while (sl_time_sleepers && sl_time_sleepers->sleep_deadline_ns <= now_ns) {
            sl_task *t = sl_time_sleepers;
            sl_time_sleepers = t->next;
            t->next = NULL;
            sl_task_resume(t); /* safe while holding sl_time_mu -- only
                touches sl_gc_mu and sl_global_runq.mu, a
                deadlock-free ordering already proven by chan's
                identical use of sl_task_resume */
        }
        long long wait_ns = sl_time_sleepers
            ? sl_time_sleepers->sleep_deadline_ns - now_ns : -1;
        if (wait_ns < 0) {
            pthread_cond_wait(&sl_time_cond, &sl_time_mu); /* nothing
                pending -- wait indefinitely for the next insert */
            continue;
        }
        if (wait_ns > SL_TIME_MAX_WAIT_NS) wait_ns = SL_TIME_MAX_WAIT_NS;
        struct timespec rt;
        clock_gettime(CLOCK_REALTIME, &rt);
        long long target_ns = (long long)rt.tv_sec * 1000000000LL + rt.tv_nsec + wait_ns;
        struct timespec abstime;
        abstime.tv_sec = (time_t)(target_ns / 1000000000LL);
        abstime.tv_nsec = (long)(target_ns % 1000000000LL);
        pthread_cond_timedwait(&sl_time_cond, &sl_time_mu, &abstime);
        /* loops back regardless of why it woke -- timeout, signal, or
           spurious -- and re-derives everything from the monotonic
           clock and the list's own current head, never trusting the
           wake reason itself */
    }
    return NULL; /* unreachable -- runs until process exit */
}

/* Called once from main() (program.c), gated on 'time' being
 * imported at all. Tier 11 sixth slice: no longer takes a
 * block_signals parameter -- SIGTERM/SIGINT are blocked exactly
 * ONCE, at the very top of main(), before any thread (including
 * this one) is created, so this thread inherits the blocked mask
 * automatically. See sl_pool_start's own comment (runtime_pool.c)
 * for the full reasoning. */
static void sl_time_start(void) {
    pthread_t th;
    if (sl_rt_thread_spawn(&th, sl_time_thread, NULL) != 0) {
        fprintf(stderr, "slang: failed to start timer thread\n");
        exit(1);
    }
}

static void sl_time_sleep(long long ns) {
    /* Tier 11 eighth slice: bracketed entry-to-return -- see
     * sl_chan_send/recv's own identical bracket and comment
     * (runtime_core.c) for the exact hazard this closes: sl_time_insert
     * below writes sl_rt_current_task->next to link into
     * sl_time_sleepers, and an async signal landing before
     * sl_task_park's own switch completes would let
     * sl_worker_after_switch overwrite that same ->next link pushing
     * this task onto sl_global_runq instead -- corrupting the sleeper
     * list. */
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_time_mu);
    /* sl_rt_cur(), not a raw read: this call sits before the park, so
     * in isolation a raw read is fine -- but generated code calls
     * time.sleep from inside loops (the active_tasks() drain loop in
     * demo/main.sl and stress_test/programs/worker_fanout, for two),
     * and once this body is inlined at -O2 the read lands inside that
     * loop where its thread-affine address can be hoisted above the
     * park a previous iteration performed. Same hazard, same fix, as
     * sl_chan_send/sl_chan_recv (runtime_core.c). */
    sl_time_insert(sl_rt_cur(), sl_time_mono() + ns);
    pthread_cond_signal(&sl_time_cond); /* wake the timer thread in
        case this is now the earliest deadline -- always safe to
        signal unconditionally, worst case a harmless extra
        wake-and-recheck */
    sl_task_park(&sl_time_mu); /* leaves sl_time_mu locked across the
        switch -- see sl_task_park's own comment (runtime_pool.c) */
    /* resumes here once the timer thread confirms the deadline
       passed and calls sl_task_resume -- no loop/recheck needed,
       unlike chan: nothing else could ever resume a sleeping task
       except the timer thread deciding its own deadline has
       passed */
    sl_rt_preempt_enable();
}

