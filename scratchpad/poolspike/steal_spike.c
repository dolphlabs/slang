/* Standalone spike validating the work-stealing pop/steal shape before
 * it ever touches the real Slang runtime -- see the Tier 11 stretch
 * plan ("Tier 11 stretch: work-stealing, per-worker run queues") for
 * the full design this validates.
 *
 * What this proves (or disproves): N per-worker mutex-guarded queues
 * (the exact sl_runq shape: linked list + mutex + condvar) plus one
 * global overflow queue, worker pop order own -> global -> bounded
 * steal-rotation -> bounded cond_timedwait on own queue -> loop. The
 * design's own central claim, under adversarial review, was: this
 * bounded-wait shape makes missed-wakeup structurally impossible (a
 * push landing in the gap between a worker's last empty-check and it
 * entering cond_timedwait costs at most ~1ms of latency, never a
 * permanently stranded item, since nothing here relies on a condvar
 * signal actually being observed). This harness tries to break that
 * claim directly rather than trust the proof sketch: every pushed item
 * carries a unique, monotonically-assigned id; every popped item
 * (whether via own-queue pop, global pop, or a steal) is recorded by
 * id; after a clean shutdown-and-drain, the harness asserts EVERY id
 * that was ever pushed was popped EXACTLY once -- neither lost
 * (missed wakeup) nor duplicated (a stolen item dequeued twice, the
 * other concrete risk the design review named).
 *
 * Adversarial timing: SL_SPIKE_JITTER (if set) injects a random
 * usleep() right at the worker's own "about to check if empty" and
 * "about to enter timedwait" points -- specifically widening the
 * window a real race would need to land in, rather than hoping normal
 * scheduling noise finds it.
 *
 * Build and run (see the bottom of this file for the exact commands
 * used during verification -- this comment intentionally does not
 * duplicate them, since a stale copy is worse than none).
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define NUM_WORKERS 8
#define NUM_QUEUES (NUM_WORKERS) /* one local queue per worker, matching
                                     sl_worker_runq[]'s own 1:1 shape */
#define STEAL_ATTEMPTS 4         /* matches min(4, num_workers-1) in the
                                     real design for NUM_WORKERS=8 */
#define TOTAL_ITEMS 200000

typedef struct item {
    struct item *next;
    long id;
} item;

typedef struct spike_runq {
    item *head, *tail;
    pthread_mutex_t mu;
    pthread_cond_t not_empty;
    int shutdown;
} spike_runq;

static spike_runq g_local[NUM_QUEUES];
static spike_runq g_global;

static _Atomic long g_next_id = 0;
static _Atomic int g_pushes_done = 0; /* set to 1 once the producer has
    issued every push -- workers keep draining until this AND every
    queue is empty, so a late steal target doesn't get abandoned */

/* one slot per possible id, 0 = never popped, >1 = duplicate pop
 * (a direct assertion target, not just a counter) */
static _Atomic int *g_popped;

static int jitter_enabled = 0;
static void maybe_jitter(void) {
    if (!jitter_enabled) return;
    /* small, bounded, but real -- enough to let a genuine race land
     * without making the whole run glacially slow */
    usleep((useconds_t)(rand() % 200));
}

static void runq_init(spike_runq *q) {
    q->head = q->tail = NULL;
    pthread_mutex_init(&q->mu, NULL);
    pthread_cond_init(&q->not_empty, NULL);
    q->shutdown = 0;
}

static void runq_push(spike_runq *q, item *it) {
    pthread_mutex_lock(&q->mu);
    it->next = NULL;
    if (q->tail) q->tail->next = it; else q->head = it;
    q->tail = it;
    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->mu);
}

/* non-blocking try-pop -- the exact shape sl_runq_try_pop's own real
 * implementation must have: lock, check, maybe unlink, unlock. */
static item *runq_try_pop(spike_runq *q) {
    pthread_mutex_lock(&q->mu);
    item *it = q->head;
    if (it) {
        q->head = it->next;
        if (!q->head) q->tail = NULL;
    }
    pthread_mutex_unlock(&q->mu);
    return it;
}

static int all_queues_empty_and_done(void) {
    if (!atomic_load_explicit(&g_pushes_done, memory_order_acquire))
        return 0;
    pthread_mutex_lock(&g_global.mu);
    int ge = (g_global.head == NULL);
    pthread_mutex_unlock(&g_global.mu);
    if (!ge) return 0;
    for (int i = 0; i < NUM_QUEUES; i++) {
        pthread_mutex_lock(&g_local[i].mu);
        int e = (g_local[i].head == NULL);
        pthread_mutex_unlock(&g_local[i].mu);
        if (!e) return 0;
    }
    return 1;
}

static void record_pop(item *it) {
    long id = it->id;
    int prev = atomic_fetch_add_explicit(&g_popped[id], 1, memory_order_relaxed);
    if (prev != 0) {
        fprintf(stderr, "SPIKE FAIL: id %ld popped more than once (prev count %d)\n",
                id, prev);
        _exit(2);
    }
    free(it);
}

typedef struct worker_arg {
    long slot;
} worker_arg;

static void *worker_main(void *argp) {
    worker_arg *wa = (worker_arg *)argp;
    long slot = wa->slot;
    unsigned int seed = (unsigned int)(slot * 7919 + 12345);

    for (;;) {
        maybe_jitter();
        item *it = runq_try_pop(&g_local[slot]);
        if (it) { record_pop(it); continue; }

        maybe_jitter();
        it = runq_try_pop(&g_global);
        if (it) { record_pop(it); continue; }

        int stolen = 0;
        for (int a = 0; a < STEAL_ATTEMPTS && a < NUM_QUEUES - 1; a++) {
            long victim = (slot + 1 + a) % NUM_QUEUES;
            maybe_jitter();
            it = runq_try_pop(&g_local[victim]);
            if (it) { record_pop(it); stolen = 1; break; }
        }
        if (stolen) continue;

        if (all_queues_empty_and_done())
            return NULL; /* clean exit, nothing left anywhere and the
                            producer is done issuing pushes */

        maybe_jitter();
        /* bounded wait on OWN queue -- exactly the real design's own
         * shape, no shared/global condvar */
        pthread_mutex_lock(&g_local[slot].mu);
        if (!g_local[slot].head) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 1000000; /* 1ms */
            if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
            pthread_cond_timedwait(&g_local[slot].not_empty, &g_local[slot].mu, &ts);
        }
        pthread_mutex_unlock(&g_local[slot].mu);
        (void)seed;
    }
}

int main(int argc, char **argv) {
    jitter_enabled = (argc > 1 && strcmp(argv[1], "jitter") == 0);
    srand(42);

    g_popped = calloc(TOTAL_ITEMS, sizeof(_Atomic int));
    if (!g_popped) { fprintf(stderr, "oom\n"); return 1; }

    runq_init(&g_global);
    for (int i = 0; i < NUM_QUEUES; i++) runq_init(&g_local[i]);

    pthread_t workers[NUM_WORKERS];
    worker_arg wargs[NUM_WORKERS];
    for (int i = 0; i < NUM_WORKERS; i++) {
        wargs[i].slot = i;
        pthread_create(&workers[i], NULL, worker_main, &wargs[i]);
    }

    /* Producer: pushes TOTAL_ITEMS items, mostly hammering ONE local
     * queue (simulating a single fan-out task spawning heavily from
     * one worker -- exactly the pathology this feature exists to fix),
     * with a minority going to the global queue and other locals, to
     * exercise every push path. */
    for (long i = 0; i < TOTAL_ITEMS; i++) {
        item *it = malloc(sizeof(item));
        it->id = atomic_fetch_add_explicit(&g_next_id, 1, memory_order_relaxed);
        maybe_jitter();
        int r = rand() % 20;
        if (r < 14) {
            runq_push(&g_local[0], it); /* the "hot" queue */
        } else if (r < 17) {
            runq_push(&g_global, it);
        } else {
            runq_push(&g_local[1 + (rand() % (NUM_QUEUES - 1))], it);
        }
    }
    atomic_store_explicit(&g_pushes_done, 1, memory_order_release);
    /* nudge every local queue's condvar once so a worker already deep
     * in a timedwait doesn't wait the full 1ms after the last push */
    for (int i = 0; i < NUM_QUEUES; i++) {
        pthread_mutex_lock(&g_local[i].mu);
        pthread_cond_broadcast(&g_local[i].not_empty);
        pthread_mutex_unlock(&g_local[i].mu);
    }

    for (int i = 0; i < NUM_WORKERS; i++) pthread_join(workers[i], NULL);

    long missing = 0, dup = 0;
    for (long i = 0; i < TOTAL_ITEMS; i++) {
        int c = atomic_load_explicit(&g_popped[i], memory_order_relaxed);
        if (c == 0) missing++;
        else if (c > 1) dup++;
    }
    if (missing || dup) {
        fprintf(stderr, "SPIKE FAIL: %ld items never popped (stranded), %ld popped >1 time\n",
                missing, dup);
        return 1;
    }
    printf("SPIKE OK: all %d items popped exactly once (jitter=%s)\n",
           TOTAL_ITEMS, jitter_enabled ? "on" : "off");
    return 0;
}
