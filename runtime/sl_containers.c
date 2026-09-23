/* ---- wait lists -----------------------------------------------------
 *
 * A blocked party is represented by an sl_waiter NODE rather than by
 * the sl_task itself. The node lives on the blocked task's own C stack,
 * which is alive for exactly as long as that task stays parked inside
 * the call that pushed it.
 *
 * The old shape linked tasks directly through sl_task.next. That field
 * is also the run queue's link, so a task could only ever be on ONE
 * list -- an invariant the previous version of this file documented at
 * length, and which `select` cannot live with: it needs one task
 * waiting on N channels at once.
 *
 * Moving the link into the node has a second effect worth naming, since
 * the comments below used to turn on it. chan no longer writes
 * sl_task.next at all, so the specific async-preemption hazard those
 * comments describe -- a signal landing between the list push and the
 * park, redirecting through sl_worker_after_switch, which pushes the
 * SAME task onto the run queue by overwriting the very ->next link the
 * push just set -- is structurally gone for channels. The preempt
 * brackets stay: they also cover the park transition itself, which is a
 * separate hazard with its own history (see sl_task_park), and
 * sl_rt_cur() is still mandatory across a park because the task resumes
 * on whichever worker dequeues it.
 *
 * Two rules keep the stack-allocated nodes safe:
 *
 *   1. Every read or write of a node happens under the owning
 *      channel's (or mutex's) lock.
 *   2. A waker must not touch a node after resuming it. The resumed
 *      task can return from the parking call on another worker
 *      immediately and take its stack frame -- node included -- with
 *      it. Pop first, resume last, never look again.
 */

struct sl_select;

typedef struct sl_waiter {
    struct sl_waiter *next;
    sl_task *task;
    struct sl_select *sel; /* NULL for a plain chan_send/chan_recv or a
                              mutex_lock; set when this node is one arm
                              of a select (see sl_select_run) */
} sl_waiter;

/* ---- chan[T]: bounded, thread-safe queue for 'spawn'ed tasks ---- */

typedef struct {
    unsigned char *buf;
    size_t elemsz;
    int cap, head, count, closed;
    int elem_is_ptr;
    pthread_mutex_t mu;
    sl_waiter *send_waiters, *send_waiters_tail; /* parties parked
        waiting for buffer space, oldest first */
    sl_waiter *recv_waiters, *recv_waiters_tail; /* same, for parties
        parked waiting for data */
} sl_chan;

static void sl_gc_trace_chan(void *p, void (*mark)(void *)) {
    sl_chan *c = (sl_chan *)p;
    if (!c->buf) return;
    mark(c->buf);
    /* Value-struct interiors (same as sl_gc_trace_arr). */
    if (!c->elem_is_ptr) {
        if (c->elemsz < (long long)sizeof(void *)) return;
        for (int i = 0; i < c->cap; i++) {
            unsigned char *el = c->buf + (size_t)i * (size_t)c->elemsz;
            for (size_t off = 0; off + sizeof(void *) <= (size_t)c->elemsz;
                 off += sizeof(void *))
                mark(*(void **)(el + off));
        }
        return;
    }
    for (int i = 0; i < c->cap; i++)
        mark(*(void **)(c->buf + (size_t)i * c->elemsz));
}

static sl_chan *sl_chan_new(size_t elemsz, int cap, int elem_is_ptr) {
    if (cap < 1) cap = 1;
    sl_chan *c = (sl_chan *)sl_gc_alloc(sizeof(sl_chan), sl_gc_trace_chan);
    c->buf = (unsigned char *)sl_gc_alloc(elemsz * (size_t)cap, NULL);
    c->elemsz = elemsz;
    c->cap = cap;
    c->head = 0;
    c->count = 0;
    c->closed = 0;
    c->elem_is_ptr = elem_is_ptr;
    pthread_mutex_init(&c->mu, NULL);
    return c;
}

/* Wait-list helpers, shared by chan, mutex and select. All three park
 * their blocked tasks the same way. */
static void sl_wl_push(sl_waiter **head, sl_waiter **tail, sl_waiter *w) {
    w->next = NULL;
    if (*tail) (*tail)->next = w; else *head = w;
    *tail = w;
}
static sl_waiter *sl_wl_pop(sl_waiter **head, sl_waiter **tail) {
    sl_waiter *w = *head;
    if (w) { *head = w->next; if (!*head) *tail = NULL; w->next = NULL; }
    return w;
}
/* Only select needs this: a plain waiter is always removed by whoever
 * wakes it, but a select that fires on ONE channel has to take its
 * nodes off the other N-1. A missing node is not an error -- a waker
 * may already have popped it (see sl_waiter_wake returning 0). */
static void sl_wl_remove(sl_waiter **head, sl_waiter **tail,
                         sl_waiter *w) {
    sl_waiter **pp = head;
    sl_waiter *prev = NULL;
    while (*pp) {
        if (*pp == w) {
            *pp = w->next;
            if (*tail == w) *tail = prev;
            w->next = NULL;
            return;
        }
        prev = *pp;
        pp = &(*pp)->next;
    }
}

/* The select bookkeeping a waiter points at. Lives on the selecting
 * task's own stack, like the nodes themselves. */
typedef struct sl_select {
    pthread_mutex_t mu;
    int woken;  /* some channel has claimed this select; at most one may */
    int parked; /* the task has actually switched out, so resuming it is
                   legal -- see sl_select_run for why this is separate */
    sl_task *task;
} sl_select;

/* Wake one waiter, under the owning channel's lock.
 *
 * Returns 1 if the task was resumed (or is guaranteed to be), 0 if this
 * node belonged to a select that another channel already claimed -- in
 * which case the caller should move on to the next waiter, because this
 * one is not going to consume anything.
 *
 * Lock order is channel-then-select, always. sl_select_run never holds
 * sel->mu while taking a channel lock, so there is no cycle.
 *
 * `woken` and `parked` are separate on purpose. Setting `woken` claims
 * the select, but the selecting task may not have switched out yet: it
 * enqueues on every channel BEFORE it parks, so a waker can find the
 * node while the task is still running. Resuming a task that is not
 * parked is precisely the corruption sl_worker_after_switch's comments
 * describe. So a waker that claims an unparked select resumes nothing
 * and returns 1 anyway -- the claim is enough, because the selecting
 * task checks `woken` under this same lock before deciding to park, and
 * will skip the park and re-poll instead. */
static int sl_waiter_wake(sl_waiter *w) {
    struct sl_select *s = w->sel;
    if (!s) {
        sl_task_resume(w->task);
        return 1;
    }
    pthread_mutex_lock(&s->mu);
    if (s->woken) {
        pthread_mutex_unlock(&s->mu);
        return 0;
    }
    s->woken = 1;
    if (!s->parked) {
        pthread_mutex_unlock(&s->mu);
        return 1; /* claimed; it has not parked yet and now never will */
    }
    pthread_mutex_unlock(&s->mu);
    sl_task_resume(s->task);
    return 1;
}

/* Hand the value to the first waiter that can actually take it. A
 * claimed-elsewhere select is skipped rather than counted. */
static void sl_wl_wake_one(sl_waiter **head, sl_waiter **tail) {
    sl_waiter *w;
    while ((w = sl_wl_pop(head, tail)))
        if (sl_waiter_wake(w))
            return;
}

/* Tier 11 fourth slice: chan_send/chan_recv now PARK a blocked task
 * (sl_task_park/sl_task_resume, runtime_pool.c) instead of blocking
 * the OS thread on a condvar -- the worker that was running the
 * blocked task goes back to servicing the run queue instead of
 * sitting idle. A woken waiter re-locks c->mu and re-checks the loop
 * condition itself, exactly like the old condvar-signal-then-
 * recheck did -- it is never handed a value directly, just told a
 * value (or a close) MIGHT now be available. No GC-checkin
 * bookkeeping is needed in this loop anymore either: a parked task
 * holds no OS thread hostage at all (unlike the old blocked-condvar
 * model), so it can never make the collector's quiescence wait wait
 * on it -- sl_task_park itself does not call sl_rt_gc_checkin(); the
 * very next checkin the now-freed OS thread reaches is
 * sl_worker_run_loop's own, immediately after re-entering its loop.
 * See the Tier 11 plan for the full design and the two critical bugs
 * (a lost-wakeup race, and main()'s own top-level task having no
 * dispatch loop to resume into) a dedicated review pass found before
 * any of this was implemented. */
static void sl_chan_send(sl_chan *c, const void *val) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return -- NOT
     * just around sl_task_park's own internal body (already covered
     * there). The bracket covers the whole park transition, which is
     * a live async-preemption target in its own right; see
     * sl_task_park's own comment (runtime_pool.c). The wait-list half
     * of the original hazard is gone now that the link lives in a
     * stack node rather than in sl_task.next -- see the wait-list
     * commentary at the top of this file. */
    sl_waiter self;
    self.sel = NULL;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&c->mu);
    while (c->count == c->cap && !c->closed) {
        /* sl_rt_cur(), NOT a raw sl_rt_current_task read. The bracket
         * this function opened makes a raw read safe against ASYNC
         * preemption, which is what that exemption was written for --
         * but it says nothing about the migration sl_task_park performs
         * ITSELF. park is a context switch: the task resumes on
         * whichever worker dequeues it, so on the second and later trips
         * round this loop a compiler that cached the thread-affine
         * address of sl_rt_current_task before the park reads the OLD
         * worker's slot -- which by then names whatever task that worker
         * is now running. Confirmed at -O2, not theorised: comparing the
         * raw read against a value captured before the park trips
         * immediately. */
        self.task = sl_rt_cur();
        sl_wl_push(&c->send_waiters, &c->send_waiters_tail, &self);
        sl_task_park(&c->mu); /* leaves c->mu locked across the switch --
            see sl_task_park's own comment (runtime_pool.c) for why */
        pthread_mutex_lock(&c->mu); /* re-acquire before re-checking */
    }
    if (c->closed) {
        pthread_mutex_unlock(&c->mu);
        sl_rt_preempt_enable();
        sl_rt_error("send on closed channel", 0, 0);
        return;
    }
    int tail = (c->head + c->count) % c->cap;
    memcpy(c->buf + (size_t)tail * c->elemsz, val, c->elemsz);
    c->count++;
    /* Generational barrier (inside the existing bracket). */
    sl_gc_remember(c);
    sl_wl_wake_one(&c->recv_waiters, &c->recv_waiters_tail);
    pthread_mutex_unlock(&c->mu);
    sl_rt_preempt_enable();
}

/* returns 1 with *out populated, or 0 if closed and drained empty */
static int sl_chan_recv(sl_chan *c, void *out) {
    /* Tier 11 eighth slice: same bracket, same reason, as
     * sl_chan_send's own comment above -- entry-to-every-return, not
     * just sl_task_park's own internal coverage. This is the far more
     * heavily-exercised half of the pair for a producer/consumer
     * workload like concurrent_compute's own results-collection loop
     * (one long-lived task calling chan_recv in a loop, parking and
     * resuming across many different, real pool-worker OS threads over
     * its lifetime -- each resume makes it a live async-preemption
     * target again, regardless of which thread first ran it) --
     * root-caused directly to a real crash (sl_gc_collect SEGV on a
     * tiny, garbage address, from the run queue's own ->next chain
     * having been corrupted by exactly this unbracketed window) before
     * this fix. */
    sl_waiter self;
    self.sel = NULL;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&c->mu);
    while (c->count == 0 && !c->closed) {
        /* sl_rt_cur(), not a raw read -- see sl_chan_send's own copy of
         * this loop for the full reasoning. Same hazard, same fix. */
        self.task = sl_rt_cur();
        sl_wl_push(&c->recv_waiters, &c->recv_waiters_tail, &self);
        sl_task_park(&c->mu);
        pthread_mutex_lock(&c->mu);
    }
    if (c->count == 0) {
        pthread_mutex_unlock(&c->mu);
        sl_rt_preempt_enable();
        return 0;
    }
    memcpy(out, c->buf + (size_t)c->head * c->elemsz, c->elemsz);
    c->head = (c->head + 1) % c->cap;
    c->count--;
    sl_wl_wake_one(&c->send_waiters, &c->send_waiters_tail);
    pthread_mutex_unlock(&c->mu);
    sl_rt_preempt_enable();
    return 1;
}

/* Wakes everyone it can. A select already claimed by another channel is
 * skipped (sl_waiter_wake returns 0) rather than retried -- it is about
 * to re-poll every one of its cases anyway, and will see the close
 * then. */
static void sl_chan_close(sl_chan *c) {
    pthread_mutex_lock(&c->mu);
    c->closed = 1;
    sl_waiter *w;
    while ((w = sl_wl_pop(&c->recv_waiters, &c->recv_waiters_tail)))
        sl_waiter_wake(w);
    while ((w = sl_wl_pop(&c->send_waiters, &c->send_waiters_tail)))
        sl_waiter_wake(w);
    pthread_mutex_unlock(&c->mu);
}

/* ---- mutex: task-level mutual exclusion ----------------------------
 *
 * A pthread_mutex_t protects sl_mutex's OWN fields for microseconds at
 * a time; it is not the lock slang code holds. Holding a real pthread
 * lock across user code would block the WORKER THREAD, and with M:N
 * green threads that starves every other task queued behind it -- the
 * same reason chan parks instead of using a condvar. So a contended
 * lock parks the task (sl_task_park) and the unlocker hands the worker
 * back to the run queue.
 *
 * Deliberately NOT recursive. A task that locks a mutex it already
 * holds would otherwise park forever on itself, and a hang is the
 * worst possible diagnosis to be handed; sl_rt_error names it instead.
 * For the same reason unlock checks ownership: unlocking someone
 * else's mutex is always a bug, and it is one that otherwise shows up
 * much later as corruption in unrelated data.
 *
 * `owner` is compared, never dereferenced -- it is a task identity,
 * not a live reference, so it stays correct even if that task has
 * since exited (which is itself the bug of dropping a held lock). The
 * struct needs no GC tracer: it holds no GC pointers, and parked
 * waiters are already roots via sl_parked_tasks. */

typedef struct {
    pthread_mutex_t mu;   /* guards the fields below, never user code */
    int held;
    sl_task *owner;       /* identity only; see the note above */
    sl_waiter *waiters, *waiters_tail;
} sl_mutex;

static sl_mutex *sl_mutex_new(void) {
    sl_mutex *m = (sl_mutex *)sl_gc_alloc(sizeof(sl_mutex), NULL);
    m->held = 0;
    m->owner = NULL;
    m->waiters = NULL;
    m->waiters_tail = NULL;
    pthread_mutex_init(&m->mu, NULL);
    return m;
}

/* Bracketed entry-to-every-return, exactly like sl_chan_send/recv: the
 * window between sl_wl_push writing this task's ->next and
 * sl_task_park actually suspending is a live async-preemption target,
 * and a preemption landing there would overwrite that same ->next with
 * a run-queue link. See sl_chan_send's own comment for the full
 * reasoning -- same hazard, same fix, same sl_rt_cur() rule across the
 * park (the task may resume on a different worker). */
static void sl_mutex_lock(sl_mutex *m) {
    sl_waiter self;
    self.sel = NULL;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&m->mu);
    if (m->held && m->owner == sl_rt_cur()) {
        pthread_mutex_unlock(&m->mu);
        sl_rt_preempt_enable();
        sl_rt_error("mutex_lock: this task already holds this mutex "
                    "(slang mutexes are not recursive)", 0, 0);
        return;
    }
    while (m->held) {
        self.task = sl_rt_cur();
        sl_wl_push(&m->waiters, &m->waiters_tail, &self);
        sl_task_park(&m->mu); /* leaves m->mu locked across the switch */
        pthread_mutex_lock(&m->mu);
    }
    m->held = 1;
    m->owner = sl_rt_cur();
    pthread_mutex_unlock(&m->mu);
    sl_rt_preempt_enable();
}

/* returns 1 if the lock was taken, 0 if it is held by someone else */
static int sl_mutex_trylock(sl_mutex *m) {
    int got = 0;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&m->mu);
    if (!m->held) {
        m->held = 1;
        m->owner = sl_rt_cur();
        got = 1;
    }
    pthread_mutex_unlock(&m->mu);
    sl_rt_preempt_enable();
    return got;
}

static void sl_mutex_unlock(sl_mutex *m) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&m->mu);
    if (!m->held) {
        pthread_mutex_unlock(&m->mu);
        sl_rt_preempt_enable();
        sl_rt_error("mutex_unlock: this mutex is not locked", 0, 0);
        return;
    }
    if (m->owner != sl_rt_cur()) {
        pthread_mutex_unlock(&m->mu);
        sl_rt_preempt_enable();
        sl_rt_error("mutex_unlock: this task does not hold this mutex",
                    0, 0);
        return;
    }
    m->held = 0;
    m->owner = NULL;
    /* Resumed while m->mu is still held -- the same rule sl_task_resume
     * documents: the waker holds the lock protecting the wait list the
     * task was just removed from, so t->next is free to reuse. The
     * woken task re-checks m->held itself; it is not handed the lock,
     * so a trylock racing in between is a legal outcome, not a bug. */
    sl_waiter *w = sl_wl_pop(&m->waiters, &m->waiters_tail);
    if (w)
        sl_waiter_wake(w);
    pthread_mutex_unlock(&m->mu);
    sl_rt_preempt_enable();
}

/* ---- select: wait on several channels at once -----------------------
 *
 * One sl_sel_case per arm, built by the caller (generated C) alongside
 * an sl_waiter array of the same length. Both live on the selecting
 * task's stack, and so does the sl_select they share -- nothing here
 * allocates.
 *
 * The shape is poll-then-park-then-repoll rather than a rendezvous
 * handoff. That is affordable because slang channels are ALWAYS
 * buffered (sl_chan_new clamps cap to >= 1), so a value is never handed
 * from one task directly into another's frame: it always goes through
 * the buffer, and a woken select can simply look again. Losing the race
 * to another receiver just means going round once more, which is
 * correct, if occasionally wasteful, and removes the whole class of
 * handoff bugs.
 *
 * Polling starts at a rotating offset. Without it, case 0 would win
 * every time both are ready, and a busy first channel would starve
 * every later arm indefinitely. The counter is deliberately relaxed:
 * it only has to vary, never to be exact. */

typedef struct {
    sl_chan *ch;
    int is_send;
    void *val;  /* recv: where to put the value; send: what to send */
    int closed; /* recv result: the channel was closed and drained, so
                   this arm fires with `none` rather than a value --
                   the same convention chan_recv already uses */
} sl_sel_case;

static _Atomic unsigned sl_sel_rr = 0;

/* 1 = this arm fired, 0 = not ready, -1 = send on a closed channel
 * (the caller reports it after unlocking; panicking with a lock held
 * is what sl_rt_error_at's own comment forbids). Called with ch->mu
 * held. */
static int sl_sel_try_locked(sl_sel_case *sc) {
    sl_chan *c = sc->ch;
    if (sc->is_send) {
        if (c->closed)
            return -1;
        if (c->count == c->cap)
            return 0;
        int tail = (c->head + c->count) % c->cap;
        memcpy(c->buf + (size_t)tail * c->elemsz, sc->val, c->elemsz);
        c->count++;
        sl_wl_wake_one(&c->recv_waiters, &c->recv_waiters_tail);
        return 1;
    }
    if (c->count > 0) {
        memcpy(sc->val, c->buf + (size_t)c->head * c->elemsz, c->elemsz);
        c->head = (c->head + 1) % c->cap;
        c->count--;
        sc->closed = 0;
        sl_wl_wake_one(&c->send_waiters, &c->send_waiters_tail);
        return 1;
    }
    if (c->closed) {
        sc->closed = 1; /* fires immediately, forever, with none */
        return 1;
    }
    return 0;
}

/* One pass over every arm, starting at a rotating offset. Returns the
 * index that fired, or -1 for none; sets *bad on a send to a closed
 * channel. */
static int sl_sel_poll(sl_sel_case *cs, int n, int *bad) {
    unsigned start = atomic_fetch_add(&sl_sel_rr, 1u);
    int k;
    for (k = 0; k < n; k++) {
        int r;
        int i = (int)((start + (unsigned)k) % (unsigned)n);
        pthread_mutex_lock(&cs[i].ch->mu);
        r = sl_sel_try_locked(&cs[i]);
        pthread_mutex_unlock(&cs[i].ch->mu);
        if (r < 0) {
            *bad = 1;
            return -1;
        }
        if (r > 0)
            return i;
    }
    return -1;
}

static void sl_sel_enqueue(sl_sel_case *cs, sl_waiter *nodes, int n,
                           struct sl_select *sel, sl_task *t) {
    int i;
    for (i = 0; i < n; i++) {
        nodes[i].task = t;
        nodes[i].sel = sel;
        pthread_mutex_lock(&cs[i].ch->mu);
        if (cs[i].is_send)
            sl_wl_push(&cs[i].ch->send_waiters,
                       &cs[i].ch->send_waiters_tail, &nodes[i]);
        else
            sl_wl_push(&cs[i].ch->recv_waiters,
                       &cs[i].ch->recv_waiters_tail, &nodes[i]);
        pthread_mutex_unlock(&cs[i].ch->mu);
    }
}

/* Off every list before `sel` and `nodes` (both stack objects in
 * sl_select_run's frame) can go out of scope. Taking each channel lock
 * here is also what serialises against a waker part-way through
 * sl_waiter_wake on one of these nodes. A node a waker already popped
 * is simply not found, which sl_wl_remove treats as success. */
static void sl_sel_dequeue(sl_sel_case *cs, sl_waiter *nodes, int n) {
    int i;
    for (i = 0; i < n; i++) {
        pthread_mutex_lock(&cs[i].ch->mu);
        if (cs[i].is_send)
            sl_wl_remove(&cs[i].ch->send_waiters,
                         &cs[i].ch->send_waiters_tail, &nodes[i]);
        else
            sl_wl_remove(&cs[i].ch->recv_waiters,
                         &cs[i].ch->recv_waiters_tail, &nodes[i]);
        pthread_mutex_unlock(&cs[i].ch->mu);
    }
}

/* Returns the index of the arm that fired, or -1 for the default arm.
 * With no default and no arm ever becoming ready, this parks forever --
 * exactly like chan_recv on a channel nobody sends to.
 *
 * The second poll, after enqueueing, is not redundant: it is the whole
 * reason this terminates. A plain chan_recv holds c->mu continuously
 * from "is there a value" through "put me on the wait list" to the
 * park, so a sender cannot slip between the check and the sleep. A
 * select cannot do that -- it would have to hold N locks at once -- so
 * there is a real window between the first poll and the enqueue in
 * which a sender deposits a value, finds an empty wait list, wakes
 * nobody, and goes away. Parking after that window without looking
 * again loses the wakeup permanently: the value is sitting in the
 * buffer and no further send is coming. Once the nodes are on the
 * lists, a sender either sees them (and claims us) or landed before
 * them (and the second poll sees the value); it cannot fall between.
 *
 * Found by a hang, not by reading: 1 run in ~30 of tests/select
 * deadlocked with every worker idle in sl_worker_run_loop. */
static int sl_select_run(sl_sel_case *cs, sl_waiter *nodes, int n,
                         int has_default) {
    sl_select sel;
    int fired, bad_send = 0;

    pthread_mutex_init(&sel.mu, NULL);
    sel.woken = 0;
    sel.parked = 0;
    sel.task = NULL;

    /* Bracketed entry-to-every-return, the same rule chan and mutex
     * follow: this function parks, and the park transition is a live
     * async-preemption target. */
    sl_rt_preempt_disable();
    for (;;) {
        fired = sl_sel_poll(cs, n, &bad_send);
        if (bad_send || fired >= 0 || has_default)
            break;

        sel.task = sl_rt_cur();
        sl_sel_enqueue(cs, nodes, n, &sel, sel.task);

        fired = sl_sel_poll(cs, n, &bad_send);
        if (bad_send || fired >= 0) {
            /* Never parked, so no waker can be holding a resume for us;
             * sl_waiter_wake only resumes when `parked` is set. */
            sl_sel_dequeue(cs, nodes, n);
            break;
        }

        pthread_mutex_lock(&sel.mu);
        if (sel.woken) {
            /* Claimed while we were enqueueing or polling. Do NOT park:
             * that waker resumed nothing, because it saw parked == 0.
             * The claim was the whole message. */
            pthread_mutex_unlock(&sel.mu);
        } else {
            sel.parked = 1; /* set under sel.mu, which is not released
                until the context switch has completed -- so a waker
                that observes this is looking at a task that really has
                switched out */
            sl_task_park(&sel.mu);
        }

        sl_sel_dequeue(cs, nodes, n);
        /* Safe to reset unlocked: every node is unlinked above, so no
         * waker can still reach &sel. */
        sel.woken = 0;
        sel.parked = 0;
    }

    pthread_mutex_destroy(&sel.mu);
    sl_rt_preempt_enable();
    if (bad_send)
        sl_rt_error("send on closed channel", 0, 0);
    return fired;
}

/* ---- bytes: length-prefixed, binary-safe sequences ---- */

typedef struct { long long len; unsigned char *ptr; } sl_bytes;

static void sl_gc_trace_bytes(void *p, void (*mark)(void *)) {
    mark(((sl_bytes *)p)->ptr);
}

static sl_bytes *sl_bytes_new(const unsigned char *p, long long n) {
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    b->len = n;
    b->ptr = (unsigned char *)sl_gc_alloc((size_t)(n > 0 ? n : 1), NULL);
    if (n > 0) memcpy(b->ptr, p, (size_t)n);
    return b;
}

static sl_bytes sl_bytes_static(const unsigned char *p, long long n) {
    sl_bytes b;
    b.len = n;
    b.ptr = (unsigned char *)p;
    return b;
}

static int sl_bytes_at(sl_bytes *b, long long i, const char *at) {
    if (i < 0 || i >= b->len)
        sl_rt_error_at("byte index out of bounds", i, b->len, at);
    return (int)b->ptr[i];
}

static void sl_bytes_set(sl_bytes *b, long long i, unsigned char v) {
    if (i < 0 || i >= b->len)
        sl_rt_error("byte index out of bounds", i, b->len);
    b->ptr[i] = v;
}

static sl_bytes *sl_bytes_concat(sl_bytes *a, sl_bytes *b) {
    sl_bytes *r = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    r->len = a->len + b->len;
    r->ptr = (unsigned char *)sl_gc_alloc((size_t)(r->len > 0 ? r->len : 1), NULL);
    if (a->len) memcpy(r->ptr, a->ptr, (size_t)a->len);
    if (b->len) memcpy(r->ptr + a->len, b->ptr, (size_t)b->len);
    return r;
}

static sl_bytes *sl_bytes_slice(sl_bytes *b, long long s, long long e) {
    if (s < 0) s = 0;
    if (e > b->len) e = b->len;
    if (e < s) e = s;
    sl_bytes *r = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    r->len = e - s;
    r->ptr = (unsigned char *)sl_gc_alloc((size_t)(r->len > 0 ? r->len : 1), NULL);
    if (r->len) memcpy(r->ptr, b->ptr + s, (size_t)r->len);
    return r;
}

static int sl_bytes_eq(sl_bytes *a, sl_bytes *b) {
    if (a->len != b->len) return 0;
    return a->len == 0 || memcmp(a->ptr, b->ptr, (size_t)a->len) == 0;
}

static char *sl_str_from_bytes(sl_bytes *b) {
    char *p = (char *)sl_gc_alloc((size_t)b->len + 1, NULL);
    if (b->len) memcpy(p, b->ptr, (size_t)b->len);
    p[b->len] = 0;
    return p;
}

/* The wire counterpart. A wire is a view into arena (non-GC) memory, so
 * this is the one allocation -- there is no header to also allocate the
 * way sl_bytes has one, which is what makes to_str(w[a..b]) one
 * allocation where to_str(to_bytes(w[a..b])) was three. */
static char *sl_str_from_wire(sl_wire w) {
    char *p = (char *)sl_gc_alloc((size_t)w.len + 1, NULL);
    if (w.len) memcpy(p, w.ptr, (size_t)w.len);
    p[w.len] = 0;
    return p;
}

/* wire_put_bytes: the sl_bytes counterpart of sl_wire_put (sl_core.c) --
 * split across the two files because sl_bytes isn't defined yet where
 * sl_wire is. Same contract: writes only what fits, returns the count. */
static long long sl_wire_put_bytes(sl_wire w, long long off, sl_bytes *b) {
    long long room, n;
    if (!b || off < 0 || off > w.len)
        return 0;
    room = w.len - off;
    n = b->len;
    if (n > room)
        n = room;
    if (n > 0)
        memcpy(w.ptr + off, b->ptr, (size_t)n);
    return n;
}

static sl_bytes *sl_bytes_from_str(const char *s) {
    return sl_bytes_new((const unsigned char *)s, (long long)strlen(s));
}

static sl_bytes *sl_to_le(unsigned long long v) {
    unsigned char buf[8];
    for (int i = 0; i < 8; i++)
        buf[i] = (unsigned char)((v >> (8 * i)) & 0xff);
    return sl_bytes_new(buf, 8);
}

static sl_bytes *sl_to_be(unsigned long long v) {
    unsigned char buf[8];
    for (int i = 0; i < 8; i++)
        buf[7 - i] = (unsigned char)((v >> (8 * i)) & 0xff);
    return sl_bytes_new(buf, 8);
}

static unsigned long long sl_from_le(sl_bytes *b) {
    if (b->len != 8)
        sl_rt_error("from_le expects exactly 8 bytes", b->len, 8);
    unsigned long long v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | b->ptr[i];
    return v;
}

static unsigned long long sl_from_be(sl_bytes *b) {
    if (b->len != 8)
        sl_rt_error("from_be expects exactly 8 bytes", b->len, 8);
    unsigned long long v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | b->ptr[i];
    return v;
}

/* ---- growable arrays over GC memory ---- */

typedef struct {
    long long len, cap;
    unsigned char *data; /* elements stored inline */
    size_t esz;          /* element size in bytes */
    int elem_is_ptr;
} sl_arr;

static void sl_gc_trace_arr(void *p, void (*mark)(void *)) {
    sl_arr *a = (sl_arr *)p;
    if (!a->data) return;
    mark(a->data);
    /* Phase-2 FIX (orphan-buffer interiors): the DATA buffer is a bare
     * sl_gc_alloc with trace=NULL -- marked but never TRACED. Its words
     * are scanned HERE, through the header, instead: every element word
     * when elem_is_ptr is false ([ValueStruct] interiors), every element
     * pointer when true. mark() validates via sl_gc_set.
     *
     * This covers whichever buffer a->data names TODAY. An OLD buffer
     * replaced by realloc is NOT covered (nothing names it) -- but its
     * stale interior pointers name the SAME young objects the new
     * buffer's copy names (memcpy copies pointers). Those objects are
     * kept alive through the new buffer; freeing "via" the orphan would
     * kill them -- EXCEPT the orphan is unreachable, so no mark ever
     * visits it, so it marks nothing, so it frees nothing THROUGH
     * itself. The orphan's own storage is reclaimed unmarked. Its
     * stale words are never READ as roots. Sound. */
    if (!a->elem_is_ptr) {
        if (a->esz < (long long)sizeof(void *)) return;
        for (long long i = 0; i < a->len; i++) {
            unsigned char *el = a->data + (size_t)i * a->esz;
            for (size_t off = 0; off + sizeof(void *) <= (size_t)a->esz;
                 off += sizeof(void *))
                mark(*(void **)(el + off));
        }
        return;
    }
    for (long long i = 0; i < a->len; i++)
        mark(*(void **)(a->data + (size_t)i * a->esz));
}

static sl_arr *sl_arr_new(size_t esz, int elem_is_ptr) {
    sl_arr *a = (sl_arr *)sl_gc_alloc(sizeof(sl_arr), sl_gc_trace_arr);
    a->len = 0;
    a->cap = 0;
    a->data = NULL;
    a->esz = esz;
    a->elem_is_ptr = elem_is_ptr;
    return a;
}

static void sl_arr_reserve(sl_arr *a, long long need) {
    if (need <= a->cap) return;
    long long cap = a->cap ? a->cap : 8;
    while (cap < need) cap *= 2;
    a->data = (unsigned char *)sl_gc_realloc(a->data, (size_t)cap * a->esz);
    a->cap = cap;
    /* Post-swap barrier: `a` itself may be old, and the swap above
     * overwrote its a->data field (which sl_gc_trace_arr follows).
     * Registers `a` for the NEXT minor, no matter how many cycles
     * intervene since the last store. (A pre-swap barrier is useless:
     * realloc never collects synchronously, so no collection can land
     * between a pre-barrier and the swap; dedup would make it free
     * anyway. Post-only.) */
    sl_rt_preempt_disable();
    sl_gc_remember(a);
    sl_rt_preempt_enable();
}

static void *sl_arr_get(sl_arr *a, long long i, size_t esz, const char *at) {
    if (esz != a->esz)
        sl_rt_error("internal: element size mismatch", (long long)esz,
                    (long long)a->esz);
    if (i < 0 || i >= a->len)
        sl_rt_error_at("list index out of bounds", i, a->len, at);
    return a->data + (size_t)i * esz;
}

static void *sl_arr_at(sl_arr *a, long long i, size_t esz) {
    return a->data + (size_t)i * esz;
}

static void sl_arr_push(sl_arr *a, void *val, size_t esz) {
    if (esz != a->esz)
        sl_rt_error("internal: element size mismatch", (long long)esz,
                    (long long)a->esz);
    sl_arr_reserve(a, a->len + 1);
    memcpy(a->data + (size_t)a->len * esz, val, esz);
    a->len++;
    /* Element store into a potentially-old container. sl_gc_remember
     * no-ops for young containers; the remembered flag dedups repeats. */
    {
        sl_rt_preempt_disable();
        sl_gc_remember(a);
        sl_rt_preempt_enable();
    }
}

static void *sl_arr_pop(sl_arr *a, size_t esz) {
    if (esz != a->esz)
        sl_rt_error("internal: element size mismatch", (long long)esz,
                    (long long)a->esz);
    if (a->len == 0) sl_rt_error("pop from empty list", 0, 0);
    a->len--;
    return a->data + (size_t)a->len * esz;
}

static sl_arr *sl_arr_from(void *buf, long long n, size_t esz, int elem_is_ptr) {
    sl_arr *a = sl_arr_new(esz, elem_is_ptr);
    sl_arr_reserve(a, n);
    if (n > 0) memcpy(a->data, buf, (size_t)n * esz);
    a->len = n;
    return a;
}

static sl_arr *sl_arr_slice(sl_arr *a, long long s, long long e) {
    if (s < 0) s = 0;
    if (e > a->len) e = a->len;
    if (e < s) e = s;
    sl_arr *r = sl_arr_new(a->esz, a->elem_is_ptr);
    sl_arr_reserve(r, e - s);
    if (e > s)
        memcpy(r->data, a->data + (size_t)s * a->esz,
               (size_t)(e - s) * a->esz);
    r->len = e - s;
    return r;
}

static sl_arr *sl_arr_concat(sl_arr *a, sl_arr *b) {
    if (a->esz != b->esz)
        sl_rt_error("cannot concatenate lists of different element types",
                    (long long)a->esz, (long long)b->esz);
    sl_arr *r = sl_arr_new(a->esz, a->elem_is_ptr);
    sl_arr_reserve(r, a->len + b->len);
    if (a->len) memcpy(r->data, a->data, (size_t)a->len * a->esz);
    if (b->len)
        memcpy(r->data + (size_t)a->len * a->esz, b->data,
               (size_t)b->len * b->esz);
    r->len = a->len + b->len;
    return r;
}

/* ---- maps: open-addressing hash tables over GC memory ---- */

typedef struct {
    long long count, cap;
    size_t ksz, vsz;
    int kstr;            /* keys are NUL-terminated strings */
    int key_is_ptr, val_is_ptr;
    unsigned char *keys; /* cap slots */
    unsigned char *vals; /* cap slots */
    unsigned char *state;/* 1 = occupied */
    long long *order;    /* occupied slot indices, insertion order */
} sl_map;

static void sl_gc_trace_map(void *p, void (*mark)(void *)) {
    sl_map *m = (sl_map *)p;
    if (m->keys) mark(m->keys);
    if (m->vals) mark(m->vals);
    if (m->state) mark(m->state);
    if (m->order) mark(m->order);
    /* Value-struct interiors (same as sl_gc_trace_arr): scan every word
     * of every occupied slot when the precise flag is unset. mark()
     * validates, so non-pointer words are harmless. */
    for (long long i = 0; i < m->count; i++) {
        long long slot = m->order[i];
        if (m->key_is_ptr)
            mark(*(void **)(m->keys + (size_t)slot * m->ksz));
        else if (m->ksz >= sizeof(void *)) {
            for (size_t off = 0; off + sizeof(void *) <= m->ksz;
                 off += sizeof(void *))
                mark(*(void **)(m->keys + (size_t)slot * m->ksz + off));
        }
        if (m->val_is_ptr)
            mark(*(void **)(m->vals + (size_t)slot * m->vsz));
        else if (m->vsz >= sizeof(void *)) {
            for (size_t off = 0; off + sizeof(void *) <= m->vsz;
                 off += sizeof(void *))
                mark(*(void **)(m->vals + (size_t)slot * m->vsz + off));
        }
    }
}

static unsigned long long sl_hash_bytes(const unsigned char *p, size_t n) {
    unsigned long long h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static unsigned long long sl_hash_str(const char *s) {
    unsigned long long h = 1469598103934665603ULL;
    for (; *s; s++) { h ^= (unsigned char)*s; h *= 1099511628211ULL; }
    return h;
}

static sl_map *sl_map_new(size_t ksz, size_t vsz, int kstr,
                           int key_is_ptr, int val_is_ptr) {
    sl_map *m = (sl_map *)sl_gc_alloc(sizeof(sl_map), sl_gc_trace_map);
    m->count = 0;
    m->cap = 8;
    m->ksz = ksz;
    m->vsz = vsz;
    m->kstr = kstr;
    m->key_is_ptr = key_is_ptr;
    m->val_is_ptr = val_is_ptr;
    m->keys = (unsigned char *)sl_gc_alloc(8 * ksz, NULL);
    m->vals = (unsigned char *)sl_gc_alloc(8 * vsz, NULL);
    m->state = (unsigned char *)sl_gc_alloc(8, NULL);
    m->order = (long long *)sl_gc_alloc(8 * sizeof(long long), NULL);
    return m;
}

/* Probe for a key: returns its slot if present, or -(slot)-1 for
 * the first empty slot where it could be inserted. */
static long long sl_map_probe(sl_map *m, const void *k,
                              unsigned long long h) {
    long long mask = m->cap - 1;
    long long i = (long long)(h & (unsigned long long)mask);
    for (;;) {
        if (!m->state[i])
            return -i - 1;
        void *kk = m->keys + (size_t)i * m->ksz;
        int eq = m->kstr
                    ? !strcmp(*(const char **)kk, *(const char *const *)k)
                    : memcmp(kk, k, m->ksz) == 0;
        if (eq)
            return i;
        i = (i + 1) & mask;
    }
}

static void sl_map_grow(sl_map *m) {
    /* Tier 11 eighth slice: bracketed entry-to-return -- ok/ov/oorder
     * below hold the OLD keys/vals/order buffers, which are STILL the
     * only live copies of every already-inserted key/value at the
     * moment they're captured, but become unreachable from m itself
     * the instant the very next line overwrites m->keys with a fresh
     * sl_gc_alloc'd buffer -- and there are three more such
     * reassignments right after it (m->vals/state/order), each
     * capable of setting sl_gc_collect_pending. Cooperative
     * preemption alone could never expose this (nothing in this
     * function or sl_gc_alloc calls sl_rt_gc_checkin, so a collection
     * could never actually land mid-sequence, only get pending), but
     * async preemption can suspend this task between any two of these
     * four allocs with no bracket to stop it -- and if a DIFFERENT
     * task then drives the actual collection through its own,
     * unrelated checkin while this one sits queued, ok/ov/oorder are
     * plain locals, not GC roots, and not necessarily rediscovered by
     * the conservative stack scan either (their true recorded values
     * only cover what this session directly verified, not every
     * variable in every hand-written runtime helper -- this bracket
     * closes the gap outright rather than depending on that). Root-
     * caused directly: concurrent_compute's own map[str]int-building
     * loop, caught live under lldb with a real, reproduced crash --
     * sl_hash_str(NULL) inside this function's own reinsertion loop,
     * meaning a PREVIOUSLY-inserted key had already been swept by the
     * time this grow tried to rehash it. */
    sl_rt_preempt_disable();
    sl_gc_remember(m);
    long long old_cap = m->cap;
    unsigned char *ok = m->keys, *ov = m->vals;
    unsigned char *ost = m->state;
    long long ocount = m->count;
    long long *oorder = m->order;
    m->cap = old_cap * 2;
    m->count = 0;
    m->keys = (unsigned char *)sl_gc_alloc((size_t)m->cap * m->ksz, NULL);
    m->vals = (unsigned char *)sl_gc_alloc((size_t)m->cap * m->vsz, NULL);
    m->state = (unsigned char *)sl_gc_alloc((size_t)m->cap, NULL);
    m->order = (long long *)sl_gc_alloc((size_t)m->cap * sizeof(long long), NULL);
    (void)ost;
    /* reinsert in insertion order so iteration stays deterministic */
    for (long long i = 0; i < ocount; i++) {
        long long slot = oorder[i];
        void *k = ok + (size_t)slot * m->ksz;
        void *v = ov + (size_t)slot * m->vsz;
        unsigned long long h = m->kstr
                                  ? sl_hash_str(*(const char **)k)
                                  : sl_hash_bytes((const unsigned char *)k,
                                                  m->ksz);
        long long s = -sl_map_probe(m, k, h) - 1;
        memcpy(m->keys + (size_t)s * m->ksz, k, m->ksz);
        memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);
        m->state[s] = 1;
        m->order[m->count++] = s;
    }
    sl_rt_preempt_enable();
}

static void sl_map_put(sl_map *m, const void *k, const void *v) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return -- not
     * just sl_map_grow's own internal bracket (which only covers
     * ITS OWN four-alloc sequence). This closes the whole family of
     * the same class of bug at once, rather than continuing to chase
     * individual sub-windows within it: between sl_map_probe finding
     * an empty slot and this function actually committing it
     * (m->state[s]=1, m->order[m->count++]=s), an async preemption
     * has nothing structurally wrong to exploit on its own (m isn't
     * shared across tasks), but this function is exactly the kind of
     * multi-step, GC-adjacent sequence this slice's own audit
     * (sl_map_grow) found a real bug in -- bracketing the whole
     * caller, not just the one nested call that already needed it,
     * is the same discipline sl_gc_alloc/sl_task_park/every other
     * fully-bracketed function in this codebase already follows. */
    sl_rt_preempt_disable();
    /* Generational barrier (inside the existing bracket). */
    sl_gc_remember(m);
    unsigned long long h = m->kstr
                              ? sl_hash_str(*(const char *const *)k)
                              : sl_hash_bytes((const unsigned char *)k,
                                              m->ksz);
    if ((m->count + 1) * 4 >= m->cap * 3)
        sl_map_grow(m);
    long long s = sl_map_probe(m, k, h);
    if (s >= 0) {
        memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);
        sl_rt_preempt_enable();
        return;
    }
    s = -s - 1;
    memcpy(m->keys + (size_t)s * m->ksz, k, m->ksz);
    memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);
    m->state[s] = 1;
    m->order[m->count++] = s;
    sl_rt_preempt_enable();
}

static void *sl_map_get(sl_map *m, const void *k) {
    unsigned long long h = m->kstr
                              ? sl_hash_str(*(const char *const *)k)
                              : sl_hash_bytes((const unsigned char *)k,
                                              m->ksz);
    long long s = sl_map_probe(m, k, h);
    if (s < 0)
        return NULL;
    return m->vals + (size_t)s * m->vsz;
}

static int sl_map_has(sl_map *m, const void *k) {
    return sl_map_get(m, k) != NULL;
}

static void sl_map_del(sl_map *m, const void *k) {
    /* Tier 11 eighth slice: bracketed entry-to-every-return -- same
     * reasoning as sl_map_put's own bracket just above. */
    sl_rt_preempt_disable();
    unsigned long long h = m->kstr
                              ? sl_hash_str(*(const char *const *)k)
                              : sl_hash_bytes((const unsigned char *)k,
                                              m->ksz);
    long long s = sl_map_probe(m, k, h);
    if (s < 0) {
        sl_rt_preempt_enable();
        return;
    }
    m->state[s] = 0;
    for (long long i = 0; i < m->count; i++) {
        if (m->order[i] == s) {
            memmove(m->order + i, m->order + i + 1,
                    (size_t)(m->count - i - 1) * sizeof(long long));
            break;
        }
    }
    m->count--;
    sl_rt_preempt_enable();
}

/* ---- strings ---- */

static char *sl_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)sl_gc_alloc(n, NULL);
    memcpy(p, s, n);
    return p;
}

/* ---- parsing: str -> number ----------------------------------------
 *
 * These return a flag plus an out-parameter rather than a result[T,str]
 * because this file is spliced into the program BEFORE the monomorphized
 * result types exist. The generated code wraps the answer into the right
 * result struct at the call site (see to_int/to_float in expr.c).
 *
 * Strict on purpose. The demos this replaces used libc atoi(), which
 * returns 0 for "abc", 80 for "80x80", and 0 for "", reporting nothing
 * in any of those cases -- so `PORT=abc` silently bound an ephemeral
 * port. Every one of those inputs is an error here, with a message that
 * names the input. That is the whole reason to_int exists rather than
 * an `extern fn atoi`.
 *
 * Rejected deliberately: surrounding whitespace, a lone sign, embedded
 * underscores, "0x" prefixes, and anything after the digits. A caller
 * who wants leniency can trim first; a caller who gets leniency they
 * did not ask for cannot undo it. */

/* ---- user-declared enums --------------------------------------------
 *
 * A slang `enum` is an i32 ordinal at runtime (see src/codegen/enum.c);
 * each declared enum gets one static `sl_en_<pkg>_<Name>_names[]` /
 * `_values[]` pair emitted alongside it (emit_enum_tables), and every
 * generated call into these three helpers passes that enum's own pair.
 * Ordinals are not guaranteed contiguous (explicit '= N' values may
 * leave gaps), so this is a linear scan, not an array index -- fine at
 * the sizes an enum realistically has. from_int/from_str use the same
 * flag-plus-out-param convention as sl_str_parse_int below, for the
 * same reason: the generated call site wraps the answer into the real
 * result[EnumT,str] struct (see the "__enum_from_int"/"__enum_from_str"
 * codegen in expr.c), which doesn't exist yet when this file is
 * spliced in. */

static const char *sl_enum_name(int32_t ord, const char **names,
                                const int32_t *values, int n) {
    for (int i = 0; i < n; i++) {
        if (values[i] == ord)
            return names[i];
    }
    /* Every value of an enum-typed slang expression was produced by
     * this same closed set (a variant literal, or a from_int/from_str
     * lookup that already validated against it) -- reaching here means
     * a codegen bug, not bad input, so this is an internal error, not
     * a user-facing panic. */
    sl_rt_error("internal: enum value has no matching variant", ord, n);
    return NULL; /* unreachable */
}

static int sl_enum_from_int(int32_t v, const int32_t *values, int n,
                            int32_t *out_idx) {
    for (int i = 0; i < n; i++) {
        if (values[i] == v) {
            *out_idx = i;
            return 1;
        }
    }
    return 0;
}

static int sl_enum_from_str(const char *s, const char **names, int n,
                            int32_t *out_idx) {
    for (int i = 0; i < n; i++) {
        if (!strcmp(names[i], s)) {
            *out_idx = i;
            return 1;
        }
    }
    return 0;
}

static int sl_str_parse_int(const char *s, long long *out,
                            const char **err) {
    if (!s || !*s) { *err = "cannot parse an empty string as int"; return 0; }
    const char *p = s;
    int neg = 0;
    if (*p == '+' || *p == '-') { neg = (*p == '-'); p++; }
    if (!*p) { *err = "no digits after the sign"; return 0; }
    unsigned long long acc = 0;
    /* The positive limit is one smaller than the negative one, so the
       bound is computed from the sign rather than assumed symmetric --
       otherwise "-9223372036854775808" is rejected as overflow despite
       being exactly representable. */
    const unsigned long long limit =
        neg ? 9223372036854775808ULL : 9223372036854775807ULL;
    for (; *p; p++) {
        if (*p < '0' || *p > '9') { *err = "not a base-10 integer"; return 0; }
        unsigned d = (unsigned)(*p - '0');
        if (acc > (limit - d) / 10ULL) { *err = "out of range for int"; return 0; }
        acc = acc * 10ULL + d;
    }
    *out = neg ? -(long long)acc : (long long)acc;
    return 1;
}

static int sl_str_parse_f64(const char *s, double *out, const char **err) {
    if (!s || !*s) { *err = "cannot parse an empty string as float"; return 0; }
    /* strtod accepts "inf", "nan" and hex floats. Those are almost never
       what a config value or a request field meant, and accepting them
       silently turns a typo into a NaN that propagates. */
    for (const char *q = s; *q; q++) {
        char c = *q;
        if (!((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' ||
              c == 'e' || c == 'E')) {
            *err = "not a decimal number";
            return 0;
        }
    }
    errno = 0;
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s) { *err = "not a decimal number"; return 0; }
    if (*end) { *err = "trailing characters after the number"; return 0; }
    if (errno == ERANGE) { *err = "out of range for float"; return 0; }
    *out = v;
    return 1;
}

static char *sl_str_concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *p = (char *)sl_gc_alloc(la + lb + 1, NULL);
    memcpy(p, a, la);
    memcpy(p + la, b, lb);
    p[la + lb] = 0;
    return p;
}

/* Tier 11 eighth slice: sl_str_from_int/_uint/_float's own snprintf
 * call (BEFORE sl_strdup, unlike sl_strdup's own internal calls,
 * which sl_gc_alloc's own bracket already covers) is bracketed
 * directly -- snprintf's libc implementation touches locale state
 * behind its own internal, thread-affine os_unfair_lock, exactly
 * the same vulnerability class as malloc/free (found the same way:
 * sl_str_from_int specifically crashed cc_real_preempt under real
 * load, os_unfair_lock's own 'recursive lock' abort surfacing on a
 * LATER, unrelated snprintf call on the same OS thread after an
 * earlier one was interrupted mid-call and abandoned by a task
 * migrating to a different worker). */
static char *sl_str_from_int(long long v) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", v);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_str_from_uint(unsigned long long v) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", v);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_str_from_float(double v) {
    sl_rt_preempt_disable();
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_str_from_bool(bool v) {
    return sl_strdup(v ? "true" : "false");
}

static char *sl_str_from_fault(sl_fault f) {
    const char *d = f.detail ? f.detail : "";
    const char *op = f.op ? f.op : "";
    if (!op[0] && f.code == 0)
        return sl_strdup(d);
    sl_rt_preempt_disable();
    char buf[256];
    /* f.code is an errno wherever it is set at all (every producer is a
       syscall wrapper), so render it as the text a person can act on.
       "listen: Address already in use" tells you to change the port;
       "listen io (code 48)" makes you look 48 up. */
    if (op[0] && f.code != 0)
        snprintf(buf, sizeof(buf), "%s: %s", op, strerror(f.code));
    else if (op[0])
        snprintf(buf, sizeof(buf), "%s %s", op, d);
    else
        snprintf(buf, sizeof(buf), "%s: %s", d, strerror(f.code));
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static void sl_fault_print(sl_fault f, int newline) {
    char *s = sl_str_from_fault(f);
    if (newline)
        puts(s);
    else
        fputs(s, stdout);
}

typedef struct {
    int done;
    int panicked;
    char *err;
    unsigned char *val;
    size_t valsz;
    int val_is_ptr;
    sl_task *waiter;
    pthread_mutex_t mu;
} sl_join;

static void sl_gc_trace_join(void *p, void (*mark)(void *)) {
    sl_join *j = (sl_join *)p;
    mark(j->err);
    mark(j->val);
    if (!j->done || j->panicked) return;
    /* Value-struct interiors (same as sl_gc_trace_arr). */
    if (j->val_is_ptr) {
        mark(*(void **)j->val);
        return;
    }
    for (size_t off = 0; off + sizeof(void *) <= j->valsz;
         off += sizeof(void *))
        mark(*(void **)(j->val + off));
}

static sl_join *sl_join_new(size_t valsz, int val_is_ptr) {
    sl_join *j = (sl_join *)sl_gc_alloc(sizeof(sl_join), sl_gc_trace_join);
    j->valsz = valsz;
    j->val_is_ptr = val_is_ptr;
    j->val = (unsigned char *)sl_gc_alloc(valsz > 0 ? valsz : 1, NULL);
    pthread_mutex_init(&j->mu, NULL);
    return j;
}

static void sl_join_wake(sl_join *j) {
    if (j->waiter) {
        sl_task *w = j->waiter;
        j->waiter = NULL;
        sl_task_resume(w);
    }
}

static void sl_join_finish(sl_join *j, const void *val) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&j->mu);
    if (!j->done) {
        if (val && j->valsz)
            memcpy(j->val, val, j->valsz);
        j->done = 1;
        sl_join_wake(j);
    }
    pthread_mutex_unlock(&j->mu);
    sl_rt_preempt_enable();
}

static void sl_join_fail(void *jp, const char *msg) {
    sl_join *j = (sl_join *)jp;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&j->mu);
    if (!j->done) {
        j->panicked = 1;
        j->err = sl_strdup(msg);
        j->done = 1;
        sl_join_wake(j);
    }
    pthread_mutex_unlock(&j->mu);
    sl_rt_preempt_enable();
}

static int sl_join_wait(sl_join *j, void *out) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&j->mu);
    while (!j->done) {
        j->waiter = sl_rt_cur();
        sl_task_park(&j->mu);
        pthread_mutex_lock(&j->mu);
    }
    int ok = !j->panicked;
    if (ok && out && j->valsz)
        memcpy(out, j->val, j->valsz);
    pthread_mutex_unlock(&j->mu);
    sl_rt_preempt_enable();
    return ok;
}

static char *sl_join_err(sl_join *j) {
    return j->err ? j->err : sl_strdup("task panicked");
}

/* ---- user program ---- */

