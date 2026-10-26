#include <errno.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/socket.h>
#if defined(__linux__)
#include <sys/epoll.h>
#include <sys/eventfd.h>
#define SL_REACTOR_EPOLL 1
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
#include <sys/event.h>
#define SL_REACTOR_KQUEUE 1
#else
#error "slang net: need kqueue or epoll"
#endif
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/un.h>
#ifdef SLANG_NET_DNS
#include <arpa/nameser.h>
#include <resolv.h>
#endif

/* ---- net: TCP over bytes + fixed ints, parked (not blocked) on a
 * kqueue reactor -- Tier 11 sixth slice. See the design plan for the
 * full writeup and every review finding; this file's own comments
 * cover the load-bearing ones inline. */

/* Every plain-TCP fd becomes non-blocking at the OS level
 * internally, always, unconditionally -- readiness notification via
 * kqueue is meaningless if the read/write it's telling you to retry
 * could itself still block. The user-visible 'net.nonblock()'
 * contract (a fd opts into synchronous "would block" instead of
 * parking) is tracked separately -- see sl_net_user_nonblock below
 * -- since it can no longer be read back off the fd's own flags. */
static void sl_net_set_nonblocking(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* TLS parks on the same reactor (WANT_READ/WANT_WRITE). FDs stay
 * non-blocking; sl_net_tls_* retries through sl_reactor_wait. */

/* A wakeup byte or eventfd count written, or one drained, whose only
 * failure that matters is EINTR: a full eventfd counter, an empty one,
 * or a full pipe is already the state the caller wants. The result is
 * used, not cast away -- glibc marks read/write warn_unused_result under
 * _FORTIFY_SOURCE, which Ubuntu's GCC turns on at -O, and a (void) cast
 * does not silence that: generated C warned there. */
static void sl_net_nudge(int fd, const void *p, size_t n) {
    for (;;) {
        ssize_t r = write(fd, p, n);
        if (r >= 0 || errno != EINTR)
            return;
    }
}

static void sl_net_drain(int fd, void *p, size_t n) {
    for (;;) {
        ssize_t r = read(fd, p, n);
        if (r >= 0 || errno != EINTR)
            return;
    }
}

/* ---- the reactor ---- */

/* Contention instrumentation first: 16 fd-hashed shard mutexes that
    serialize only park/wake counters, never the wait list itself.
    Lets a remasure attribute reactor pressure per fd-hash before any
    queue surgery, same pattern as SLANG_SCHED_STAT. The single global
    wait list + single epoll thread below are untouched. */
#define SL_REACTOR_SHARDS 16

typedef struct sl_reactor_shard {
    pthread_mutex_t mu;
    _Atomic unsigned long long parks;
    _Atomic unsigned long long wakes;
} sl_reactor_shard;

static sl_reactor_shard sl_reactor_shards[SL_REACTOR_SHARDS] = {
    [0 ... SL_REACTOR_SHARDS - 1] = {
        .mu = PTHREAD_MUTEX_INITIALIZER,
    },
};

static inline unsigned sl_reactor_shard_for(int fd) {
    unsigned u = (unsigned)(fd >= 0 ? fd : 0);
    u ^= u >> 16;
    u *= 2654435761u;
    u ^= u >> 13;
    return u % (unsigned)SL_REACTOR_SHARDS;
}

static int sl_reactor_stat_enabled(void) {
    static int cached = -1;
    if (cached < 0)
        cached = getenv("SLANG_REACTOR_STAT") ? 1 : 0;
    return cached;
}

static void sl_reactor_shard_count(unsigned shard, int wake) {
    if (!sl_reactor_stat_enabled())
        return;
    pthread_mutex_lock(&sl_reactor_shards[shard].mu);
    if (wake)
        atomic_fetch_add_explicit(&sl_reactor_shards[shard].wakes, 1,
                                  memory_order_relaxed);
    else
        atomic_fetch_add_explicit(&sl_reactor_shards[shard].parks, 1,
                                  memory_order_relaxed);
    pthread_mutex_unlock(&sl_reactor_shards[shard].mu);
}

/* SLANG_REACTOR_STAT's reactor-side counts: epoll_ctl/kevent
 * registrations, passes over every waiter, and reactor loop iterations
 * (tests/run_tests.sh, reactor work budget). */
static _Atomic unsigned long long sl_reactor_stat_regs, sl_reactor_stat_scans,
    sl_reactor_stat_loops, sl_reactor_stat_worker_polls;

static void sl_reactor_stat_dump(void) {
    if (!sl_reactor_stat_enabled())
        return;
    unsigned long long parks = 0, wakes = 0;
    for (int i = 0; i < SL_REACTOR_SHARDS; i++) {
        parks += atomic_load_explicit(&sl_reactor_shards[i].parks,
                                      memory_order_relaxed);
        wakes += atomic_load_explicit(&sl_reactor_shards[i].wakes,
                                      memory_order_relaxed);
    }
    fprintf(stderr, "slang-reactor-stat parks=%llu wakes=%llu registrations=%llu "
            "scans=%llu loops=%llu worker_polls=%llu\n", parks, wakes,
            (unsigned long long)sl_reactor_stat_regs,
            (unsigned long long)sl_reactor_stat_scans,
            (unsigned long long)sl_reactor_stat_loops,
            (unsigned long long)sl_reactor_stat_worker_polls);
}

__attribute__((destructor))
static void sl_reactor_stat_atexit(void) { sl_reactor_stat_dump(); }

static int sl_reactor_fd = -1;
#if defined(SL_REACTOR_EPOLL)
static int sl_reactor_efd = -1;
static char sl_reactor_shutdown_token;
static int sl_reactor_timer_efd = -1;
static char sl_reactor_timer_token;
#endif
/* The tasks parked on the reactor, in SL_REACTOR_WQS lists hashed by
 * fd, each under its own lock (linked via sl_task.next -- the same
 * reuse-`next`-for-one-wait-list-at-a-time pattern chan/time use). One
 * global list and lock made every IO wait of every worker, and every
 * event the reactor handled, contend for one mutex held across
 * epoll_ctl and the park's context switch: at 64 connections about two
 * of five threads sat blocked on it, and two workers outran four.
 *
 * A registration names its (fd, direction) and a generation, never a
 * task: a wait that ends by its deadline or by shutdown leaves its
 * one-shot registration armed, and the event it later delivers must
 * not reach whatever that task is doing by then -- waiting on another
 * fd in another list, or finished and freed. Each (fd, direction) has a
 * slot holding the task waiting on it now and the generation of that
 * wait; an event wakes the slot's task only if its generation still
 * matches, and the reactor never dereferences a task it found any other
 * way than through a slot or a list. Trusting the task pointer in the
 * event used to unlink a moved-on task from the wrong list and link it
 * into its own twice, a cycle the reactor then walked forever holding
 * that list's lock (tests/reactor_stale_event). */
#define SL_REACTOR_WQS 16
#define SL_REACTOR_WQ_MASK ((uintptr_t)(SL_REACTOR_WQS - 1))
typedef struct sl_reactor_wq {
    pthread_mutex_t mu;
    sl_task *waiting;
} sl_reactor_wq;
static sl_reactor_wq sl_reactor_wqs[SL_REACTOR_WQS] = {
    [0 ... SL_REACTOR_WQS - 1] = { .mu = PTHREAD_MUTEX_INITIALIZER },
};

/* The waiter slots, under the lock of the list their fd hashes to. Two
 * per fd (read, write), in chunks allocated on first use and never
 * freed, so a slot pointer stays valid without a lock on the table. */
typedef struct sl_reactor_slot {
    sl_task *task;
    uint32_t gen;
} sl_reactor_slot;
#define SL_REACTOR_SLOT_CHUNK 4096
#define SL_REACTOR_SLOT_CHUNKS 16384
static sl_reactor_slot *_Atomic sl_reactor_slot_chunks[SL_REACTOR_SLOT_CHUNKS];
static pthread_mutex_t sl_reactor_slot_grow_mu = PTHREAD_MUTEX_INITIALIZER;

/* An epoll event's data carries the fd, direction and generation, with
 * the top bit set to tell it from the shutdown and timer tokens (user
 * space pointers never have it). kqueue has the fd and filter already
 * and keeps the generation in udata. */
#define SL_REACTOR_TAG_FD (1ULL << 63)
#define SL_REACTOR_GEN_MASK 0x3fffffffu

/* The slot for (fd, rw), or NULL when fd is out of range or, without
 * `create`, its chunk does not exist yet. */
static sl_reactor_slot *sl_reactor_slot_at(int fd, int rw, int create) {
    if (fd < 0)
        return NULL;
    unsigned long idx = (unsigned long)fd * 2 + (unsigned long)rw;
    unsigned long c = idx / SL_REACTOR_SLOT_CHUNK;
    if (c >= SL_REACTOR_SLOT_CHUNKS)
        return NULL;
    sl_reactor_slot *chunk =
        atomic_load_explicit(&sl_reactor_slot_chunks[c], memory_order_acquire);
    if (!chunk) {
        if (!create)
            return NULL;
        pthread_mutex_lock(&sl_reactor_slot_grow_mu);
        chunk = atomic_load_explicit(&sl_reactor_slot_chunks[c], memory_order_relaxed);
        if (!chunk) {
            chunk = (sl_reactor_slot *)calloc(SL_REACTOR_SLOT_CHUNK, sizeof(*chunk));
            if (chunk)
                atomic_store_explicit(&sl_reactor_slot_chunks[c], chunk,
                                      memory_order_release);
        }
        pthread_mutex_unlock(&sl_reactor_slot_grow_mu);
        if (!chunk)
            return NULL;
    }
    return &chunk[idx % SL_REACTOR_SLOT_CHUNK];
}

/* A waiter leaving its list for any reason but its own event (deadline,
 * shutdown) gives up its slot, so the event its registration may still
 * deliver finds nobody. Under the list's lock. */
static void sl_reactor_slot_release(sl_task *t) {
    sl_reactor_slot *s = sl_reactor_slot_at(t->wait_fd, t->wait_rw, 0);
    if (s && s->task == t)
        s->task = NULL;
}
static inline unsigned sl_reactor_wq_for(int fd) {
    unsigned u = (unsigned)(fd >= 0 ? fd : 0);
    u ^= u >> 16;
    u *= 2654435761u;
    u ^= u >> 13;
    return u & (unsigned)SL_REACTOR_WQ_MASK;
}
/* The longest the reactor sleeps, deadlines or not. A waiter whose
 * deadline is at least this far off finds the reactor already due to
 * wake in time and never has to nudge it, so a server's idle and read
 * timeouts (seconds) cost no syscall per wait. Without the cap a reactor
 * that found no deadline waiter slept indefinitely and the next
 * registration had to nudge: 28% of all deadline waits under keep-alive
 * load. The price is one reactor wakeup a second in an idle process. */
#define SL_REACTOR_MAX_SLEEP_NS 1000000000LL

/* Off its waiter list, in O(1): the list is doubly linked through
 * next/wq_prev. Under q->mu. A connection-heavy server has thousands of
 * waiters, and finding each ready one by walking its list was a scan per
 * event. */
static void sl_reactor_wq_unlink(sl_reactor_wq *q, sl_task *t) {
    if (t->wq_prev)
        t->wq_prev->next = t->next;
    else
        q->waiting = t->next;
    if (t->next)
        t->next->wq_prev = t->wq_prev;
    t->next = NULL;
    t->wq_prev = NULL;
    t->on_wq = 0;
}

/* Absolute mono-ns the reactor's next sleep is due to end: never more
 * than SL_REACTOR_MAX_SLEEP_NS away once it has scanned, LLONG_MAX
 * before that. Lets a registering waiter skip the timer nudge when the
 * reactor is already going to wake soon enough to see it
 * (sl_reactor_timer_nudge).
 *
 * No lock covers every list, so the protocol is ordering, with
 * sl_reactor_reg_gen counting deadline registrations. The reactor reads
 * the count, scans, publishes wake_at, and reads the count again; if it
 * moved, it scans again instead of sleeping. A waiter links itself into
 * its list, bumps the count, and only then reads wake_at, nudging if it
 * is later than its deadline. If the bump precedes the reactor's second
 * read, the reactor rescans, and the rescan takes the waiter's list lock
 * and sees the link. If it follows, the waiter's read follows the
 * publish, so it sees that scan's time or a later one: either later than
 * its deadline (it nudges) or the reactor wakes first and its next scan
 * includes the waiter. Sequentially consistent on both sides.
 *
 * This replaced storing 0 ("computing") for the length of every scan,
 * which made waiters nudge whenever they caught the reactor mid-scan:
 * half of all deadline waits under keep-alive load, each a write(2) and
 * an extra reactor wakeup that itself scanned again. */
static _Atomic long long sl_reactor_wake_at = LLONG_MAX;

#if defined(SL_REACTOR_EPOLL)
/* An idle worker polls the reactor's set itself instead of sleeping
 * (sl_net_worker_poll), the way Go's scheduler polls its netpoller: what
 * it finds ready it runs next, with no reactor-thread wakeup and no
 * handoff in between. One poller at a time (sl_poller_active). It waits
 * on its own outer set holding the reactor's set and a break eventfd, so
 * work queued while it sleeps (sl_net_poll_break) wakes it and only it.
 * The reactor thread steps aside while a worker polls and takes the set
 * back, within SL_REACTOR_TICK_NS, once none does. */
#define SL_REACTOR_TICK_NS 2000000L
static int sl_poll_outer_fd = -1;
static int sl_poll_break_efd = -1;
static char sl_poll_break_token, sl_poll_inner_token;
static _Atomic int sl_poller_active = 0;
static _Atomic int sl_poller_sleeping = 0;
static _Atomic int sl_poll_break_sent = 0;
#endif
static _Atomic unsigned long long sl_reactor_reg_gen = 0;

#define SL_REACTOR_READ  0
#define SL_REACTOR_WRITE 1
#define SL_REACTOR_SHUTDOWN_IDENT 0xDEADBEEF
#define SL_REACTOR_TIMER_IDENT    0xDEADBEEE

/* The reactor computes how long to sleep from the deadlines already on
 * the waiting lists, and only then blocks. A task that registers a
 * deadline AFTER that computation -- the overwhelmingly common case,
 * since the reactor is asleep almost all the time -- would otherwise
 * be invisible until some unrelated event happened to wake the loop,
 * and with no other traffic the reactor sleeps forever (tsp == NULL)
 * and the deadline never fires at all.
 *
 * So every deadline-bearing registration nudges the reactor once,
 * making it round the loop and recompute its timeout with the new
 * waiter included. Both the kqueue EVFILT_USER knote and the epoll
 * eventfd latch a trigger that arrives before the wait begins, so
 * there is no lost-wakeup race with the unlock/block window.
 *
 * This is a distinct ident from the shutdown nudge on purpose: the
 * shutdown event deliberately drains every waiter and marks it
 * interrupted, which is exactly the wrong response to "a timer needs
 * recomputing". */
static void sl_reactor_timer_nudge(void) {
#if defined(SL_REACTOR_KQUEUE)
    struct kevent kev;
    EV_SET(&kev, SL_REACTOR_TIMER_IDENT, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(sl_reactor_fd, &kev, 1, NULL, 0, NULL);
#else
    uint64_t one = 1;
    sl_net_nudge(sl_reactor_timer_efd, &one, sizeof(one));
#endif
}

/* abort_on_shutdown differs between callers: accept/recv/dial pass 1
 * (check sl_rt_shutdown_flag both before parking -- so a waiter that
 * starts AFTER the one-time shutdown nudge already fired doesn't
 * hang forever with nothing left to wake it -- and after resuming,
 * to return -1); send passes 0 (never pre-empted, always genuinely
 * parks and waits for real write-readiness, since it must keep
 * retrying through a shutdown signal to let an in-flight write
 * finish -- tests/proc_shutdown's own 'client got full response'
 * requirement). Passing 1 for send here would busy-spin at 100% CPU
 * once shutdown is set and a peer's receive buffer stays full --
 * found and fixed during this slice's own design review.
 *
 * At most ONE waiter per (fd, filter) at a time: EV_ADD on an
 * already-pending (fd, filter) knote UPDATES it (including udata)
 * rather than creating a second one -- confirmed kqueue behavior. A
 * second concurrent sl_reactor_wait on the same fd+direction
 * silently orphans the first waiter, not a crash, a silent
 * permanent hang. This is a real, accepted scoping constraint, not
 * a bug to route around -- callers must not have two tasks
 * concurrently waiting on the same fd for the same direction (see
 * demo/main.sl's own single-acceptor design, which this constraint
 * requires). */
/* Moves every waiter whose deadline has passed from its list onto
 * *ready (via next), for the caller to resume once no list lock is held:
 * a resume takes sl_gc_mu and a run-queue lock and may wake a worker,
 * none of which the lists' lock holders should wait behind. */
/* Every waiter whose deadline has passed onto `ready`, and the soonest
 * deadline still to come (ns from `now`, -1 if none): one pass for both,
 * made only when the reactor's wake_at says one may be due. */
static long long sl_reactor_expire_waiters(sl_task **ready, long long now) {
    long long soonest = -1;
    if (sl_reactor_stat_enabled())
        atomic_fetch_add_explicit(&sl_reactor_stat_scans, 1,
                                  memory_order_relaxed);
    for (int i = 0; i < SL_REACTOR_WQS; i++) {
        sl_reactor_wq *q = &sl_reactor_wqs[i];
        pthread_mutex_lock(&q->mu);
        sl_task *t = q->waiting;
        while (t) {
            sl_task *nx = t->next;
            if (t->io_deadline_ns && t->io_deadline_ns <= now) {
                sl_reactor_wq_unlink(q, t);
                sl_reactor_slot_release(t);
                t->next = *ready;
                *ready = t;
            } else if (t->io_deadline_ns) {
                long long rem = t->io_deadline_ns - now;
                if (soonest < 0 || rem < soonest)
                    soonest = rem;
            }
            t = nx;
        }
        pthread_mutex_unlock(&q->mu);
    }
    return soonest;
}

/* Every waiter on every list onto *ready (the shutdown drain). */
static void sl_reactor_take_all(sl_task **ready) {
    for (int i = 0; i < SL_REACTOR_WQS; i++) {
        sl_reactor_wq *q = &sl_reactor_wqs[i];
        pthread_mutex_lock(&q->mu);
        sl_task *w;
        while ((w = q->waiting)) {
            sl_reactor_wq_unlink(q, w);
            sl_reactor_slot_release(w);
            w->next = *ready;
            *ready = w;
        }
        pthread_mutex_unlock(&q->mu);
    }
}

static void sl_reactor_resume_all(sl_task *ready) {
    while (ready) {
        sl_task *t = ready;
        ready = t->next;
        t->next = NULL;
        sl_task_resume(t);
    }
}

static void sl_reactor_kick(void) {
    sl_rt_preempt_disable();
    sl_task *ready = NULL;
    sl_reactor_take_all(&ready);
    sl_reactor_resume_all(ready);
    sl_rt_preempt_enable();
}

static int sl_reactor_wait_until(int fd, int rw, int abort_on_shutdown,
                                 sl_until deadline) {
    if (deadline && sl_until_hit(deadline))
        return -2;
    sl_rt_preempt_disable();
    unsigned wqi = sl_reactor_wq_for(fd);
    sl_reactor_wq *wq = &sl_reactor_wqs[wqi];
    pthread_mutex_lock(&wq->mu);
    if (abort_on_shutdown &&
        atomic_load_explicit(&sl_rt_shutdown_flag, memory_order_acquire)) {
        pthread_mutex_unlock(&wq->mu);
        sl_rt_preempt_enable();
        return -1;
    }
    sl_task *sl_reactor_self = sl_rt_cur();
    sl_reactor_slot *slot = sl_reactor_slot_at(fd, rw, 1);
    if (!slot) {
        pthread_mutex_unlock(&wq->mu);
        sl_rt_preempt_enable();
        return -1;
    }
    uint32_t gen = ++slot->gen;
    slot->task = sl_reactor_self;
    sl_reactor_self->wait_fd = fd;
    sl_reactor_self->wait_rw = rw;
    sl_reactor_self->io_deadline_ns = deadline;
    sl_reactor_self->wq_prev = NULL;
    sl_reactor_self->next = wq->waiting;
    if (wq->waiting)
        wq->waiting->wq_prev = sl_reactor_self;
    wq->waiting = sl_reactor_self;
    sl_reactor_self->on_wq = 1;
    sl_reactor_shard_count(sl_reactor_shard_for(fd), 0);
#if defined(SL_REACTOR_KQUEUE)
    struct kevent kev;
    EV_SET(&kev, fd, rw == SL_REACTOR_READ ? EVFILT_READ : EVFILT_WRITE,
           EV_ADD | EV_ONESHOT, 0, 0, (void *)(uintptr_t)gen);
    kevent(sl_reactor_fd, &kev, 1, NULL, 0, NULL);
    if (sl_reactor_stat_enabled())
        atomic_fetch_add_explicit(&sl_reactor_stat_regs, 1,
                                  memory_order_relaxed);
#else
    struct epoll_event ev;
    ev.events = (rw == SL_REACTOR_READ ? EPOLLIN : EPOLLOUT) | EPOLLONESHOT;
    ev.data.u64 = SL_REACTOR_TAG_FD |
                  ((uint64_t)(gen & SL_REACTOR_GEN_MASK) << 33) |
                  ((uint64_t)(rw & 1) << 32) | (uint64_t)(uint32_t)fd;
    /* MOD first: after its first wait a connection's fd is registered
       (EPOLLONESHOT disarms it, it does not remove it), so this is one
       call per wait where ADD-then-MOD was two. */
    int sl_reactor_regs = 1;
    if (epoll_ctl(sl_reactor_fd, EPOLL_CTL_MOD, fd, &ev) != 0 &&
        errno == ENOENT) {
        epoll_ctl(sl_reactor_fd, EPOLL_CTL_ADD, fd, &ev);
        sl_reactor_regs = 2;
    }
    if (sl_reactor_stat_enabled())
        atomic_fetch_add_explicit(&sl_reactor_stat_regs, sl_reactor_regs,
                                  memory_order_relaxed);
#endif
    /* After EV_ADD, before parking, and after this waiter is on its
       list (see sl_reactor_wake_at for the ordering): the reactor must
       recompute its sleep with this waiter included --
       see sl_reactor_timer_nudge for why nothing else would ever wake
       it. Skipped when the reactor is already due to wake at or before
       this deadline, which is the common case once a server has more
       than one deadline-bearing connection, and saves a syscall on
       every park. */
    if (deadline) {
        atomic_fetch_add_explicit(&sl_reactor_reg_gen, 1,
                                  memory_order_seq_cst);
        /* wake_at is a lower bound on every waiter's deadline: lower it
           to this one if it is sooner, and only then wake the reactor to
           sleep less. The reactor rescans its waiters only once wake_at
           has passed. */
        long long at = atomic_load_explicit(&sl_reactor_wake_at,
                                            memory_order_seq_cst);
        while (at > deadline &&
               !atomic_compare_exchange_weak_explicit(
                   &sl_reactor_wake_at, &at, deadline,
                   memory_order_seq_cst, memory_order_seq_cst)) {
        }
        int nudge = at > deadline;
        if (nudge)
            sl_reactor_timer_nudge();
        if (sl_sched_stat_enabled()) {
            atomic_fetch_add_explicit(&sl_sched_stat_deadline_waits, 1,
                                      memory_order_relaxed);
            if (nudge)
                atomic_fetch_add_explicit(&sl_sched_stat_reactor_nudges, 1,
                                          memory_order_relaxed);
        }
    }
    sl_task_park(&wq->mu);
    sl_reactor_self->io_deadline_ns = 0;
    int sl_reactor_wait_shutdown =
        atomic_load_explicit(&sl_rt_shutdown_flag, memory_order_acquire);
    sl_rt_preempt_enable();
    if (sl_reactor_wait_shutdown)
        return -1;
    if (deadline && sl_until_hit(deadline))
        return -2;
    return 0;
}

static int sl_reactor_wait(int fd, int rw, int abort_on_shutdown) {
    return sl_reactor_wait_until(fd, rw, abort_on_shutdown, 0);
}

/* The tasks `events` (n of them, from this reactor's kqueue or epoll
 * set) make ready, onto `ready`: shared by the reactor thread and a
 * worker polling in its place (sl_net_worker_poll). */
#if defined(SL_REACTOR_KQUEUE)
static void sl_reactor_take_events(struct kevent *events, int n, sl_task **ready_out) {
#else
static void sl_reactor_take_events(struct epoll_event *events, int n, sl_task **ready_out) {
#endif
    sl_task *ready = *ready_out;
    for (int i = 0; i < n; i++) {
        /* A timer nudge carries no task and means nothing beyond
           "go round again" -- the sl_reactor_expire_waiters() call
           at the bottom of this iteration is the whole point of
           it. Skipping it before `t` is read matters: udata /
           data.ptr is not a task pointer on these events. */
#if defined(SL_REACTOR_KQUEUE)
        if (events[i].filter == EVFILT_USER &&
            events[i].ident == SL_REACTOR_TIMER_IDENT)
            continue;
        int is_shutdown = events[i].filter == EVFILT_USER;
        int ev_fd = (int)events[i].ident;
        int ev_rw = events[i].filter == EVFILT_WRITE ? SL_REACTOR_WRITE : SL_REACTOR_READ;
        uint32_t ev_gen = (uint32_t)(uintptr_t)events[i].udata;
        uint32_t gen_mask = 0xffffffffu;
#else
        if (events[i].data.ptr == &sl_reactor_timer_token) {
            uint64_t tx;
            sl_net_drain(sl_reactor_timer_efd, &tx, sizeof(tx));
            continue;
        }
        int is_shutdown = events[i].data.ptr == &sl_reactor_shutdown_token;
        uint64_t ev_tag = events[i].data.u64;
        if (!is_shutdown && !(ev_tag & SL_REACTOR_TAG_FD))
            continue;
        int ev_fd = (int)(uint32_t)ev_tag;
        int ev_rw = (int)((ev_tag >> 32) & 1);
        uint32_t ev_gen = (uint32_t)(ev_tag >> 33) & SL_REACTOR_GEN_MASK;
        uint32_t gen_mask = SL_REACTOR_GEN_MASK;
        if (is_shutdown) {
            uint64_t x;
            sl_net_drain(sl_reactor_efd, &x, sizeof(x));
        }
#endif
        if (is_shutdown) {
            sl_reactor_take_all(&ready);
            continue;
        }
        /* The slot decides: an event from an older wait on this
           (fd, direction) -- its waiter already left by deadline or
           shutdown, possibly earlier in this same batch -- finds the
           generation moved on or the slot empty, and wakes nobody. */
        sl_reactor_wq *q = &sl_reactor_wqs[sl_reactor_wq_for(ev_fd)];
        sl_task *t = NULL;
        pthread_mutex_lock(&q->mu);
        sl_reactor_slot *slot = sl_reactor_slot_at(ev_fd, ev_rw, 0);
        if (slot && slot->task && (slot->gen & gen_mask) == ev_gen) {
            t = slot->task;
            slot->task = NULL;
            if (t->on_wq)
                sl_reactor_wq_unlink(q, t);
            else
                t = NULL;
        }
        pthread_mutex_unlock(&q->mu);
        if (t) {
            t->next = ready;
            ready = t;
        }
    }
    *ready_out = ready;
}

/* Waiters are rescanned -- for expired deadlines and the next soonest --
 * only once wake_at, a lower bound on every waiter's deadline, has
 * passed. A waiter that leaves cannot make the bound wrong, only early;
 * one that joins with a sooner deadline lowers it itself
 * (sl_reactor_wait_until). Count, scan, publish, count again: see
 * sl_reactor_wake_at for why a waiter cannot be missed. */
static void sl_reactor_expire_due(long long now) {
    if (now < atomic_load_explicit(&sl_reactor_wake_at, memory_order_seq_cst))
        return;
    sl_task *expired = NULL;
    unsigned long long gen;
    long long soonest;
    do {
        gen = atomic_load_explicit(&sl_reactor_reg_gen, memory_order_seq_cst);
        now = sl_now_ns();
        soonest = sl_reactor_expire_waiters(&expired, now);
        if (soonest < 0 || soonest > SL_REACTOR_MAX_SLEEP_NS)
            soonest = SL_REACTOR_MAX_SLEEP_NS;
        atomic_store_explicit(&sl_reactor_wake_at, now + soonest,
                              memory_order_seq_cst);
    } while (atomic_load_explicit(&sl_reactor_reg_gen,
                                  memory_order_seq_cst) != gen);
    sl_reactor_resume_all(expired);
}

#if defined(SL_REACTOR_EPOLL)
/* Queued work for a worker sleeping in sl_net_worker_poll: wake it, once
 * per sleep. Called after every run-queue push (sl_rt_netpoll_break_hook);
 * the fence pairs with the poller's between announcing its sleep and
 * looking at the queues one last time, so one of the two sees the other. */
static void sl_net_poll_break(void) {
    atomic_thread_fence(memory_order_seq_cst);
    if (!atomic_load_explicit(&sl_poller_sleeping, memory_order_relaxed))
        return;
    if (atomic_exchange_explicit(&sl_poll_break_sent, 1, memory_order_acq_rel))
        return;
    uint64_t one = 1;
    sl_net_nudge(sl_poll_break_efd, &one, sizeof(one));
}

/* An idle worker's turn at the reactor (sl_rt_netpoll_hook, from
 * sl_runq_pop_blocking with the run queue unlocked): 0 if another worker
 * already polls, else 1 once it has waited -- until a socket is ready, a
 * deadline is due, work is queued or a second has passed -- and resumed
 * whatever it found. With block = 0 it does not wait: a spinning worker
 * (sl_runq_spin) looks at the set between scans of the run queues, as
 * Go's findrunnable does with netpoll(0), so a request that becomes
 * readable while every worker is busy or spinning is seen at once rather
 * than when some worker next goes idle. Resumed tasks go to the run queues
 * as the reactor thread's would, and this worker pops one next.
 *
 * Blocked for the collector throughout, as a worker asleep on the run
 * queue is: it holds no task, and a resume takes sl_gc_mu, so it
 * serializes with a collection exactly as the reactor thread (which the
 * collector never waits for) always has. */
static int sl_net_worker_poll(int block) {
    int idle = 0;
    if (!atomic_compare_exchange_strong_explicit(&sl_poller_active, &idle, 1,
                                                 memory_order_acq_rel,
                                                 memory_order_relaxed))
        return 0;
    atomic_store_explicit(&sl_rt_gc_blocked, 1, memory_order_release);
    /* Resume as the reactor thread does, onto the shared queues: this
       worker's runnext slot is for the task it is running, and it is
       running none. */
    int *slot = sl_rt_tls_runnext_idx();
    int own_slot = *slot;
    *slot = -1;
    long long now = sl_now_ns();
    sl_reactor_expire_due(now);
    now = sl_now_ns();
    long long wait = atomic_load_explicit(&sl_reactor_wake_at,
                                          memory_order_seq_cst) - now;
    if (wait < 0)
        wait = 0;
    if (wait > SL_REACTOR_MAX_SLEEP_NS)
        wait = SL_REACTOR_MAX_SLEEP_NS;
    if (block) {
        atomic_store_explicit(&sl_poller_sleeping, 1, memory_order_seq_cst);
        atomic_thread_fence(memory_order_seq_cst);
        if (atomic_load_explicit(&sl_global_runq_count, memory_order_relaxed) == 0) {
            struct epoll_event outer[2];
            epoll_wait(sl_poll_outer_fd, outer, 2,
                       (int)((wait + 999999LL) / 1000000LL));
        }
        atomic_store_explicit(&sl_poller_sleeping, 0, memory_order_seq_cst);
        if (atomic_exchange_explicit(&sl_poll_break_sent, 0, memory_order_acq_rel)) {
            uint64_t x;
            sl_net_drain(sl_poll_break_efd, &x, sizeof(x));
        }
    }
    struct epoll_event events[64];
    int n = epoll_wait(sl_reactor_fd, events, 64, 0);
    sl_task *ready = NULL;
    if (n > 0)
        sl_reactor_take_events(events, n, &ready);
    if (sl_reactor_stat_enabled())
        atomic_fetch_add_explicit(&sl_reactor_stat_worker_polls, 1,
                                  memory_order_relaxed);
    sl_reactor_resume_all(ready);
    sl_reactor_expire_due(sl_now_ns());
    *slot = own_slot;
    atomic_store_explicit(&sl_poller_active, 0, memory_order_release);
    atomic_store_explicit(&sl_rt_gc_blocked, 0, memory_order_release);
    /* A collection may have started while this thread counted as
       blocked, and gone on without it. A worker woken on the run queue
       only ever is by a push, which a collection holds off; this one
       wakes on its own timeout or the network. So it waits out any
       collection here, before it can run a task: the run loop checks in
       before it pops, not after. */
    sl_rt_gc_checkin();
    return 1;
}
#endif

static void *sl_reactor_thread(void *arg) {
    (void)arg;
#if defined(SL_REACTOR_KQUEUE)
    struct kevent events[64];
#else
    struct epoll_event events[64];
#endif
    for (;;) {
        long long soonest;
        long long now = sl_now_ns();
        if (sl_reactor_stat_enabled())
            atomic_fetch_add_explicit(&sl_reactor_stat_loops, 1,
                                      memory_order_relaxed);
        sl_reactor_expire_due(now);
#if defined(SL_REACTOR_EPOLL)
        /* A worker is polling in this thread's place (sl_net_worker_poll):
           stay out of its way, and look again in a moment. Deadlines
           come due on its watch, and when every worker is busy and none
           polls, this thread takes the set back within one tick. */
        if (atomic_load_explicit(&sl_poller_active, memory_order_acquire)) {
            struct timespec tick = {0, SL_REACTOR_TICK_NS};
            nanosleep(&tick, NULL);
            continue;
        }
#endif
        now = sl_now_ns();
        soonest = atomic_load_explicit(&sl_reactor_wake_at,
                                       memory_order_seq_cst) - now;
        if (soonest < 0)
            soonest = 0;
        if (soonest > SL_REACTOR_MAX_SLEEP_NS)
            soonest = SL_REACTOR_MAX_SLEEP_NS;
        /* soonest is in [0, SL_REACTOR_MAX_SLEEP_NS]: never forever. */
#if defined(SL_REACTOR_KQUEUE)
        struct timespec ts;
        ts.tv_sec = (time_t)(soonest / 1000000000LL);
        ts.tv_nsec = (long)(soonest % 1000000000LL);
        int n = kevent(sl_reactor_fd, NULL, 0, events, 64, &ts);
#else
        /* Rounded up: a timeout that ends early finds wake_at not yet
           passed and would spin until it is. */
        int n = epoll_wait(sl_reactor_fd, events, 64,
                           (int)((soonest + 999999LL) / 1000000LL));
#endif
        if (n < 0) { if (errno == EINTR) continue; continue; }
        /* Tasks to resume, collected under their lists' locks and
           resumed after: a resume takes sl_gc_mu and a run-queue lock
           and may wake a worker, which no waiter should queue behind. */
        sl_task *ready = NULL;
        sl_reactor_take_events(events, n, &ready);
        sl_reactor_resume_all(ready);
    }
    return NULL; /* unreachable -- runs until process exit */
}

static void sl_net_shutdown_nudge(void) {
#if defined(SL_REACTOR_KQUEUE)
    struct kevent kev;
    EV_SET(&kev, SL_REACTOR_SHUTDOWN_IDENT, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(sl_reactor_fd, &kev, 1, NULL, 0, NULL);
#else
    uint64_t one = 1;
    sl_net_nudge(sl_reactor_efd, &one, sizeof(one));
    /* A worker polling in the reactor's place wakes for it too, even if
       the reactor thread takes the shutdown event first. */
    if (sl_poll_break_efd >= 0)
        sl_net_nudge(sl_poll_break_efd, &one, sizeof(one));
#endif
}

/* A lookup handed to the resolver thread. Heap-allocated, and owned by
 * whichever side gives it up LAST: a caller whose deadline passes
 * abandons the job instead of waiting, and the resolver thread -- still
 * inside getaddrinfo, which cannot be interrupted -- frees it when it
 * finishes. `state` decides who that is, atomically: 0 pending, 1 done
 * (the caller frees), 2 abandoned (the resolver frees). */
typedef struct sl_dns_job {
    struct sl_dns_job *next;
    int kind;
    char *host;
    char portstr[16];
    struct addrinfo hints;
    int rc;
    struct addrinfo *res;
    int qtype;
    int dns_error;
    unsigned char *packet;
    size_t packet_cap;
    size_t packet_len;
    int wake_wr;
    _Atomic int state;
} sl_dns_job;

enum { SL_DNS_JOB_ADDR = 0, SL_DNS_JOB_RECORD = 1 };

static pthread_mutex_t sl_dns_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sl_dns_cv = PTHREAD_COND_INITIALIZER;
static sl_dns_job *sl_dns_head;
static sl_dns_job *sl_dns_tail;
#ifdef SLANG_NET_DNS
#define SL_DNS_MAX_OUTSTANDING_RECORDS 64
static size_t sl_dns_record_slots;

static int sl_dns_record_reserve(void) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_dns_mu);
    int reserved = sl_dns_record_slots < SL_DNS_MAX_OUTSTANDING_RECORDS;
    if (reserved) sl_dns_record_slots++;
    pthread_mutex_unlock(&sl_dns_mu);
    sl_rt_preempt_enable();
    return reserved;
}

static void sl_dns_record_release_task(void) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_dns_mu);
    if (sl_dns_record_slots) sl_dns_record_slots--;
    pthread_mutex_unlock(&sl_dns_mu);
    sl_rt_preempt_enable();
}

static void sl_dns_record_release_thread(void) {
    pthread_mutex_lock(&sl_dns_mu);
    if (sl_dns_record_slots) sl_dns_record_slots--;
    pthread_mutex_unlock(&sl_dns_mu);
}
#endif

static void *sl_dns_thread(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&sl_dns_mu);
        while (!sl_dns_head)
            pthread_cond_wait(&sl_dns_cv, &sl_dns_mu);
        sl_dns_job *j = sl_dns_head;
        sl_dns_head = j->next;
        if (!sl_dns_head)
            sl_dns_tail = NULL;
        j->next = NULL;
        pthread_mutex_unlock(&sl_dns_mu);
#ifdef SLANG_NET_DNS
        if (j->kind == SL_DNS_JOB_RECORD) {
            j->rc = res_query(j->host, ns_c_in, j->qtype,
                              (unsigned char *)j->packet,
                              (int)j->packet_cap);
            j->dns_error = h_errno;
            if (j->rc >= 0 && (size_t)j->rc <= j->packet_cap)
                j->packet_len = (size_t)j->rc;
            else
                j->rc = -1;
        } else {
#endif
            j->rc = getaddrinfo(j->host, j->portstr, &j->hints, &j->res);
#ifdef SLANG_NET_DNS
        }
#endif
        /* Read before the exchange: once it succeeds the caller owns the
           job and frees it the moment the wake byte lands, so nothing
           after the handoff may touch `j`. Re-reading j->wake_wr for the
           close() used to hit a freed -- or already re-calloc'd, wake_wr
           still 0 -- job, and closed fd 0, then whichever socket had
           been given fd 0 since. */
        int wake_wr = j->wake_wr;
        int expect = 0;
        if (atomic_compare_exchange_strong_explicit(
                &j->state, &expect, 1, memory_order_acq_rel,
                memory_order_acquire)) {
            char x = 1;
            sl_net_nudge(wake_wr, &x, 1);
            close(wake_wr);
        } else {
            /* the caller gave up; nobody else will ever look at this */
            if (j->kind == SL_DNS_JOB_ADDR && j->rc == 0 && j->res)
                freeaddrinfo(j->res);
#ifdef SLANG_NET_DNS
            if (j->kind == SL_DNS_JOB_RECORD)
                sl_dns_record_release_thread();
#endif
            close(j->wake_wr);
            free(j->host);
            free(j->packet);
            free(j);
        }
    }
    return NULL;
}

/* getaddrinfo on the resolver thread while this task parks. `u` of 0
 * waits for as long as the lookup takes; otherwise a passed deadline
 * returns EAI_AGAIN with *timed_out set, and the job is abandoned to the
 * resolver thread. */
static int sl_dns_lookup_until(const char *host, const char *portstr,
                               struct addrinfo **res, sl_until u,
                               int *timed_out) {
    *timed_out = 0;
    *res = NULL;
    if (u && sl_until_hit(u)) {
        *timed_out = 1;
        return EAI_AGAIN;
    }
    sl_rt_preempt_disable();
    sl_dns_job *job = (sl_dns_job *)calloc(1, sizeof(sl_dns_job));
    size_t n = strlen(host) + 1;
    char *hcopy = job ? (char *)malloc(n) : NULL;
    sl_rt_preempt_enable();
    if (!job || !hcopy) {
        free(job);
        return EAI_MEMORY;
    }
    memcpy(hcopy, host, n);
    job->host = hcopy;
    job->kind = SL_DNS_JOB_ADDR;
    sl_rt_preempt_disable();
    snprintf(job->portstr, sizeof(job->portstr), "%s", portstr);
    sl_rt_preempt_enable();
    job->hints.ai_family = AF_INET;
    job->hints.ai_socktype = SOCK_STREAM;
    atomic_store_explicit(&job->state, 0, memory_order_relaxed);
    int pfd[2];
    if (pipe(pfd) != 0) {
        free(job->host);
        free(job);
        return EAI_SYSTEM;
    }
    fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pfd[1], F_SETFD, FD_CLOEXEC);
    sl_net_set_nonblocking(pfd[0]);
    job->wake_wr = pfd[1];
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_dns_mu);
    job->next = NULL;
    if (sl_dns_tail)
        sl_dns_tail->next = job;
    else
        sl_dns_head = job;
    sl_dns_tail = job;
    pthread_cond_signal(&sl_dns_cv);
    pthread_mutex_unlock(&sl_dns_mu);
    sl_rt_preempt_enable();
    for (;;) {
        int w = sl_reactor_wait_until(pfd[0], SL_REACTOR_READ, 0, u);
        if (w == -2) {
            int expect = 0;
            if (atomic_compare_exchange_strong_explicit(
                    &job->state, &expect, 2, memory_order_acq_rel,
                    memory_order_acquire)) {
                close(pfd[0]);
                *timed_out = 1;
                return EAI_AGAIN;       /* the resolver frees the job */
            }
            /* finished just as the deadline passed: use the answer,
               waiting (no deadline now) for its wake byte */
            u = 0;
        }
        char x;
        ssize_t nr = read(pfd[0], &x, 1);
        if (nr == 1)
            break;
        if (nr < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            continue;
        break;
    }
    close(pfd[0]);
    int rc = atomic_load_explicit(&job->state, memory_order_acquire) == 1
                 ? job->rc
                 : EAI_FAIL;
    *res = job->res;
    free(job->host);
    free(job);
    return rc;
}

#ifdef SLANG_NET_DNS
/* DNS record requests share the resolver thread with getaddrinfo, so a
 * slow nameserver never blocks a slang worker. The caller owns packet on
 * success; an expired caller transfers ownership of the entire job to the
 * resolver thread, which frees it after the uncancellable libc query. */
static int sl_dns_query_until(const char *name, int qtype,
                              unsigned char **packet, size_t *packet_len,
                              sl_until u, int *dns_error, int *timed_out) {
    *packet = NULL;
    *packet_len = 0;
    *dns_error = 0;
    *timed_out = 0;
    if (!name || !sl_dns_name_valid(name, 1))
        return -2;
    if (qtype != ns_t_srv && qtype != ns_t_txt)
        return -2;
    if (u && sl_until_hit(u)) {
        *timed_out = 1;
        return -1;
    }
    if (!sl_dns_record_reserve())
        return -4;

    size_t n = strlen(name);
    int absolute = name[n - 1] == '.';
    size_t qlen = n + (absolute ? 1 : 2);
    sl_rt_preempt_disable();
    sl_dns_job *job = (sl_dns_job *)calloc(1, sizeof(sl_dns_job));
    char *qname = job ? (char *)malloc(qlen) : NULL;
    unsigned char *answer = job
        ? (unsigned char *)malloc(SL_DNS_MAX_PACKET) : NULL;
    sl_rt_preempt_enable();
    if (!job || !qname || !answer) {
        sl_rt_preempt_disable();
        free(job);
        free(qname);
        free(answer);
        sl_rt_preempt_enable();
        sl_dns_record_release_task();
        return -3;
    }
    memcpy(qname, name, n);
    if (absolute) {
        qname[n] = '\0';
    } else {
        qname[n] = '.';
        qname[n + 1] = '\0';
    }
    job->kind = SL_DNS_JOB_RECORD;
    job->host = qname;
    job->qtype = qtype;
    job->packet = answer;
    job->packet_cap = SL_DNS_MAX_PACKET;
    atomic_store_explicit(&job->state, 0, memory_order_relaxed);
    int pfd[2];
    if (pipe(pfd) != 0) {
        sl_rt_preempt_disable();
        free(job->host);
        free(job->packet);
        free(job);
        sl_rt_preempt_enable();
        sl_dns_record_release_task();
        return -3;
    }
    fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pfd[1], F_SETFD, FD_CLOEXEC);
    sl_net_set_nonblocking(pfd[0]);
    job->wake_wr = pfd[1];
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_dns_mu);
    job->next = NULL;
    if (sl_dns_tail)
        sl_dns_tail->next = job;
    else
        sl_dns_head = job;
    sl_dns_tail = job;
    pthread_cond_signal(&sl_dns_cv);
    pthread_mutex_unlock(&sl_dns_mu);
    sl_rt_preempt_enable();
    for (;;) {
        int w = sl_reactor_wait_until(pfd[0], SL_REACTOR_READ, 0, u);
        if (w < 0) {
            int expect = 0;
            if (atomic_compare_exchange_strong_explicit(
                    &job->state, &expect, 2, memory_order_acq_rel,
                    memory_order_acquire)) {
                close(pfd[0]);
                if (w == -2) {
                    *timed_out = 1;
                    return -1; /* resolver thread owns and frees the job */
                }
                return -3; /* resolver thread owns and frees the job */
            }
            if (expect == 1)
                break; /* resolver completed as the wait ended */
            u = 0;
        }
        char x;
        ssize_t nr = read(pfd[0], &x, 1);
        if (nr == 1)
            break;
        if (nr < 0 && (errno == EINTR || errno == EAGAIN ||
                       errno == EWOULDBLOCK))
            continue;
        int expect = 0;
        if (atomic_compare_exchange_strong_explicit(
                &job->state, &expect, 2, memory_order_acq_rel,
                memory_order_acquire)) {
            close(pfd[0]);
            return -3; /* resolver thread owns and frees the job */
        }
        if (expect == 1)
            break;
        u = 0;
    }
    close(pfd[0]);
    int rc = atomic_load_explicit(&job->state, memory_order_acquire) == 1
                 ? job->rc : -1;
    *dns_error = job->dns_error;
    if (rc >= 0) {
        *packet = job->packet;
        *packet_len = job->packet_len;
    } else {
        sl_rt_preempt_disable();
        free(job->packet);
        sl_rt_preempt_enable();
    }
    sl_rt_preempt_disable();
    free(job->host);
    free(job);
    sl_rt_preempt_enable();
    sl_dns_record_release_task();
    return rc;
}

static void *sl_dns_malloc(size_t n) {
    sl_rt_preempt_disable();
    void *p = malloc(n);
    sl_rt_preempt_enable();
    return p;
}

static void sl_dns_free(void *p) {
    sl_rt_preempt_disable();
    free(p);
    sl_rt_preempt_enable();
}

static sl_res__str__str *sl_net_dns_ok(sl_arr *values) {
    void *roots[1] = {values};
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    sl_res__str__str *r = (sl_res__str__str *)sl_gc_alloc(
        sizeof(sl_res__str__str), sl_gc_trace_sl_res__str__str);
    r->ok = true;
    r->v = values;
    sl_rt_safepoint_exit();
    return r;
}

static sl_res__str__str *sl_net_dns_err(const char *message) {
    void *roots[1] = {NULL};
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    sl_res__str__str *r = (sl_res__str__str *)sl_gc_alloc(
        sizeof(sl_res__str__str), sl_gc_trace_sl_res__str__str);
    roots[0] = r;
    r->ok = false;
    char *text = sl_strdup(message);
    sl_rt_preempt_disable();
    r->e = text;
    sl_gc_remember(r);
    sl_rt_preempt_enable();
    sl_rt_safepoint_exit();
    return r;
}

static sl_res__str__str *sl_net_dns_query(const char *name, int qtype,
                                          sl_until u) {
    unsigned char *packet = NULL;
    size_t packet_len = 0;
    int dns_error = 0, timed_out = 0;
    int rc = sl_dns_query_until(name, qtype, &packet, &packet_len,
                                u, &dns_error, &timed_out);
    if (timed_out)
        return sl_net_dns_err("timeout");
    if (rc == -2)
        return sl_net_dns_err("invalid DNS query name");
    if (rc == -3)
        return sl_net_dns_err("DNS resolver allocation or pipe failure");
    if (rc == -4)
        return sl_net_dns_err("DNS resolver request limit reached");
    if (rc < 0) {
        if (qtype == ns_t_txt &&
            (dns_error == NO_DATA || dns_error == HOST_NOT_FOUND))
            return sl_net_dns_ok(sl_arr_new(sizeof(char *), 1));
        if (dns_error == TRY_AGAIN)
            return sl_net_dns_err("DNS resolver temporary failure");
        if (dns_error == NO_RECOVERY)
            return sl_net_dns_err("DNS resolver failure");
        return sl_net_dns_err("DNS record lookup returned no answer");
    }

    const char *parse_error = NULL;
    sl_arr *values = sl_arr_new(sizeof(char *), 1);
    void *roots[2] = {values, NULL};
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 2);
    if (qtype == ns_t_srv) {
        sl_dns_srv_record *records = (sl_dns_srv_record *)
            sl_dns_malloc(sizeof(sl_dns_srv_record) * SL_DNS_MAX_SRV_RECORDS);
        if (!records) {
            sl_rt_safepoint_exit();
            sl_dns_free(packet);
            return sl_net_dns_err("DNS resolver allocation failure");
        }
        size_t count = 0;
        int valid = sl_dns_parse_srv_packet(packet, packet_len, name, records,
                                             SL_DNS_MAX_SRV_RECORDS, &count,
                                             &parse_error);
        if (valid) {
            for (size_t i = 0; i < count; i++) {
                char text[SL_DNS_MAX_NAME + 32];
                size_t n = strlen(records[i].target);
                if (strcmp(records[i].target, ".") != 0 && n &&
                    records[i].target[n - 1] == '.')
                    n--;
                int written = snprintf(text, sizeof(text), "%u:%u:%u:%.*s",
                                       (unsigned)records[i].priority,
                                       (unsigned)records[i].weight,
                                       (unsigned)records[i].port, (int)n,
                                       records[i].target);
                if (written < 0 || (size_t)written >= sizeof(text)) {
                    valid = 0;
                    parse_error = "DNS SRV target exceeds the size limit";
                    break;
                }
                char *value = sl_strdup(text);
                roots[1] = value;
                sl_arr_push(values, &value, sizeof(value));
            }
            if (count == 0) {
                valid = 0;
                parse_error = "DNS SRV lookup returned no records";
            }
        }
        sl_dns_free(records);
        sl_rt_safepoint_exit();
        sl_dns_free(packet);
        if (!valid) return sl_net_dns_err(parse_error);
        return sl_net_dns_ok(values);
    }

    sl_dns_txt_record *records = (sl_dns_txt_record *)
        sl_dns_malloc(sizeof(sl_dns_txt_record) * SL_DNS_MAX_TXT_RECORDS);
    char *storage = (char *)sl_dns_malloc(SL_DNS_MAX_TXT_BYTES +
                                           SL_DNS_MAX_TXT_RECORDS);
    if (!records || !storage) {
        sl_dns_free(records);
        sl_dns_free(storage);
        sl_rt_safepoint_exit();
        sl_dns_free(packet);
        return sl_net_dns_err("DNS resolver allocation failure");
    }
    size_t count = 0;
    int valid = sl_dns_parse_txt_packet(packet, packet_len, name, records,
                                         SL_DNS_MAX_TXT_RECORDS, storage,
                                         SL_DNS_MAX_TXT_BYTES +
                                             SL_DNS_MAX_TXT_RECORDS,
                                         &count, &parse_error);
    if (valid) {
        for (size_t i = 0; i < count; i++) {
            char *value = sl_strdup(records[i].value);
            roots[1] = value;
            sl_arr_push(values, &value, sizeof(value));
        }
    }
    sl_dns_free(records);
    sl_dns_free(storage);
    sl_rt_safepoint_exit();
    sl_dns_free(packet);
    if (!valid) return sl_net_dns_err(parse_error);
    return sl_net_dns_ok(values);
}

static sl_res__str__str *sl_net_lookup_srv_until(const char *name,
                                                  sl_until u) {
    return sl_net_dns_query(name, ns_t_srv, u);
}

static sl_res__str__str *sl_net_lookup_txt_until(const char *name,
                                                  sl_until u) {
    return sl_net_dns_query(name, ns_t_txt, u);
}
#endif /* SLANG_NET_DNS */

static int sl_dns_lookup(const char *host, const char *portstr,
                         struct addrinfo **res) {
    int timed_out;
    return sl_dns_lookup_until(host, portstr, res, 0, &timed_out);
}

/* Called once from main() (program.c), gated on 'net' being imported
 * at all, BEFORE sl_proc_install_signal_handlers() so
 * sl_rt_shutdown_hook is guaranteed set before the signal thread
 * could ever consume a signal. No GC registration needed for
 * sl_reactor_thread, for the same reasons already established for
 * the timer thread: it never drives a task and never touches a
 * GC-scanned field, only sl_task.next and sl_task_resume itself
 * (already proven safe from an unregistered caller). */
#if defined(SL_REACTOR_EPOLL)
/* Every eventfd the reactor's set holds is nonblocking. A worker polling
 * in the reactor's place (sl_net_worker_poll) and the reactor thread can
 * both be handed the same level-triggered event; the second to drain it
 * found the counter already empty, and a blocking one stopped that thread
 * in read() for good -- the reactor thread, in net_dial_until, about one
 * run in 80 on one CPU (tests/run_tests.sh, reactor drains). */
static int sl_reactor_eventfd(void) {
    return eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
}
#endif

static void sl_reactor_start(void) {
#if defined(SL_REACTOR_KQUEUE)
    sl_reactor_fd = kqueue();
    if (sl_reactor_fd < 0) {
        fprintf(stderr, "slang: failed to create kqueue\n");
        exit(1);
    }
    struct kevent kev;
    EV_SET(&kev, SL_REACTOR_SHUTDOWN_IDENT, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    kevent(sl_reactor_fd, &kev, 1, NULL, 0, NULL);
    EV_SET(&kev, SL_REACTOR_TIMER_IDENT, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    kevent(sl_reactor_fd, &kev, 1, NULL, 0, NULL);
#else
    sl_reactor_fd = epoll_create1(EPOLL_CLOEXEC);
    if (sl_reactor_fd < 0) {
        fprintf(stderr, "slang: failed to create epoll\n");
        exit(1);
    }
    sl_reactor_efd = sl_reactor_eventfd();
    if (sl_reactor_efd < 0) {
        fprintf(stderr, "slang: failed to create eventfd\n");
        exit(1);
    }
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.ptr = &sl_reactor_shutdown_token;
    if (epoll_ctl(sl_reactor_fd, EPOLL_CTL_ADD, sl_reactor_efd, &ev) != 0) {
        fprintf(stderr, "slang: failed to arm shutdown eventfd\n");
        exit(1);
    }
    sl_reactor_timer_efd = sl_reactor_eventfd();
    if (sl_reactor_timer_efd < 0) {
        fprintf(stderr, "slang: failed to create timer eventfd\n");
        exit(1);
    }
    ev.events = EPOLLIN;
    ev.data.ptr = &sl_reactor_timer_token;
    if (epoll_ctl(sl_reactor_fd, EPOLL_CTL_ADD, sl_reactor_timer_efd, &ev) != 0) {
        fprintf(stderr, "slang: failed to arm timer eventfd\n");
        exit(1);
    }
    sl_poll_outer_fd = epoll_create1(EPOLL_CLOEXEC);
    sl_poll_break_efd = sl_reactor_eventfd();
    if (sl_poll_outer_fd >= 0 && sl_poll_break_efd >= 0) {
        int armed = 1;
        ev.events = EPOLLIN;
        ev.data.ptr = &sl_poll_inner_token;
        armed &= epoll_ctl(sl_poll_outer_fd, EPOLL_CTL_ADD, sl_reactor_fd, &ev) == 0;
        ev.events = EPOLLIN;
        ev.data.ptr = &sl_poll_break_token;
        armed &= epoll_ctl(sl_poll_outer_fd, EPOLL_CTL_ADD, sl_poll_break_efd, &ev) == 0;
        if (armed && !getenv("SLANG_NO_WORKER_POLL")) {
            sl_rt_netpoll_break_hook = sl_net_poll_break;
            sl_rt_netpoll_hook = sl_net_worker_poll;
        }
    }
#endif
    sl_rt_shutdown_hook = sl_net_shutdown_nudge;
    sl_rt_io_kick_hook = sl_reactor_kick;
    pthread_t th;
    if (sl_rt_thread_spawn(&th, sl_reactor_thread, NULL) != 0) {
        fprintf(stderr, "slang: failed to start reactor thread\n");
        exit(1);
    }
    if (sl_rt_thread_spawn(&th, sl_dns_thread, NULL) != 0) {
        fprintf(stderr, "slang: failed to start dns thread\n");
        exit(1);
    }
}

/* ---- per-fd opt-in to synchronous "would block" (net.nonblock) ---- */

/* sl_gc_set's own thread-safety (runtime_gc.c) comes entirely from
 * its callers always already holding sl_gc_mu -- none of its own
 * functions lock anything. net.*'s own call sites have no such
 * existing lock to piggyback on (they can now run on genuinely
 * different worker threads at once), so this reuses sl_gc_set's
 * linear-probing shape but is self-locking -- found and fixed
 * during this slice's own design review. */
static void **sl_net_user_nonblock = NULL;
static size_t sl_net_user_nonblock_cap = 0;
static size_t sl_net_user_nonblock_count = 0;
static pthread_mutex_t sl_net_user_nonblock_mu = PTHREAD_MUTEX_INITIALIZER;

static size_t sl_net_user_nonblock_hash(void *p) {
    uintptr_t x = (uintptr_t)p;
    x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33;
    return (size_t)x;
}
static void sl_net_user_nonblock_raw_insert(void **tbl, size_t cap, void *p) {
    size_t i = sl_net_user_nonblock_hash(p) & (cap - 1);
    while (tbl[i]) i = (i + 1) & (cap - 1);
    tbl[i] = p;
}
static void sl_net_user_nonblock_grow(size_t min_cap) {
    size_t newcap = sl_net_user_nonblock_cap ? sl_net_user_nonblock_cap : 64;
    while (newcap < min_cap) newcap *= 2;
    void **nt = (void **)calloc(newcap, sizeof(void *));
    if (!nt) { fprintf(stderr, "slang: out of memory\n"); exit(1); }
    for (size_t i = 0; i < sl_net_user_nonblock_cap; i++)
        if (sl_net_user_nonblock[i]) sl_net_user_nonblock_raw_insert(nt, newcap, sl_net_user_nonblock[i]);
    free(sl_net_user_nonblock);
    sl_net_user_nonblock = nt;
    sl_net_user_nonblock_cap = newcap;
}
/* Tier 11 eighth slice: all three bracketed entry-to-return -- insert
 * transitively calls calloc/free (via _grow, same os_unfair_lock
 * class as sl_gc_alloc's own comment describes), and all three hold
 * sl_net_user_nonblock_mu itself: an async-preempted, queued task
 * freezing THIS lock held would stall every other task calling
 * net.nonblock()/net.recv()'s own EAGAIN check until it's rescheduled
 * -- lower severity than an os_unfair_lock recursive abort, but the
 * same class of gap this whole slice's disable_depth bracket exists
 * to close. */
static void sl_net_user_nonblock_insert(void *p) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_net_user_nonblock_mu);
    if ((sl_net_user_nonblock_count + 1) * 2 >= sl_net_user_nonblock_cap)
        sl_net_user_nonblock_grow(sl_net_user_nonblock_cap ? sl_net_user_nonblock_cap * 2 : 64);
    sl_net_user_nonblock_raw_insert(sl_net_user_nonblock, sl_net_user_nonblock_cap, p);
    sl_net_user_nonblock_count++;
    pthread_mutex_unlock(&sl_net_user_nonblock_mu);
    sl_rt_preempt_enable();
}
static int sl_net_user_nonblock_contains(void *p) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_net_user_nonblock_mu);
    int found = 0;
    if (sl_net_user_nonblock_cap) {
        size_t i = sl_net_user_nonblock_hash(p) & (sl_net_user_nonblock_cap - 1);
        for (;;) {
            if (!sl_net_user_nonblock[i]) break;
            if (sl_net_user_nonblock[i] == p) { found = 1; break; }
            i = (i + 1) & (sl_net_user_nonblock_cap - 1);
        }
    }
    pthread_mutex_unlock(&sl_net_user_nonblock_mu);
    sl_rt_preempt_enable();
    return found;
}
static void sl_net_user_nonblock_remove(void *p) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_net_user_nonblock_mu);
    if (sl_net_user_nonblock_cap) {
        size_t i = sl_net_user_nonblock_hash(p) & (sl_net_user_nonblock_cap - 1);
        for (;;) {
            if (!sl_net_user_nonblock[i]) break;
            if (sl_net_user_nonblock[i] == p) {
                sl_net_user_nonblock[i] = NULL;
                sl_net_user_nonblock_count--;
                /* simple tombstone-free removal: rehash the cluster
                   forward, standard linear-probing deletion */
                size_t j = i;
                for (;;) {
                    j = (j + 1) & (sl_net_user_nonblock_cap - 1);
                    if (!sl_net_user_nonblock[j]) break;
                    void *rehome = sl_net_user_nonblock[j];
                    sl_net_user_nonblock[j] = NULL;
                    sl_net_user_nonblock_count--;
                    sl_net_user_nonblock_raw_insert(sl_net_user_nonblock, sl_net_user_nonblock_cap, rehome);
                    sl_net_user_nonblock_count++;
                }
                break;
            }
            i = (i + 1) & (sl_net_user_nonblock_cap - 1);
        }
    }
    pthread_mutex_unlock(&sl_net_user_nonblock_mu);
    sl_rt_preempt_enable();
}

static sl_res_i32_str *sl_net_ok_i32(int32_t v) {
    sl_res_i32_str *r = (sl_res_i32_str *)sl_gc_alloc(
        sizeof(sl_res_i32_str), sl_gc_trace_sl_res_i32_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_i32_str *sl_net_err_i32(const char *msg) {
    sl_res_i32_str *r = (sl_res_i32_str *)sl_gc_alloc(
        sizeof(sl_res_i32_str), sl_gc_trace_sl_res_i32_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_bytes_str *sl_net_ok_bytes(sl_bytes *b) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = true;
    r->v = b;
    return r;
}

static sl_res_bytes_str *sl_net_err_bytes(const char *msg) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_bool_str *sl_net_ok_bool(bool v) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_bool_str *sl_net_err_bool(const char *msg) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_i32_str *sl_net_listen_reuse(int port, int reuse_port);

static sl_res_i32_str *sl_net_listen(int port) {
    return sl_net_listen_reuse(port, 0);
}

/* Core listener setup: returns the fd, or -1 with *err set to the errno
 * that caused it.
 *
 * Split out so the two public shapes -- net.listen's result[i32, str]
 * and link_listen's result[link, fault] -- each build their own error
 * from the SAME errno. Before this, link_listen called the str version
 * and then threw the message away for a bare fault_io() with code 0, so
 * "Address already in use" reached the program as "listen io". That is
 * precisely the collapse the error model says not to do. */
static int sl_net_listen_fd(int port, int reuse_port, int *err) {
    *err = 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *err = errno; return -1; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_REUSEPORT
    if (reuse_port)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#endif
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        *err = errno; close(fd); return -1;
    }
    if (listen(fd, 1024) != 0) {
        *err = errno; close(fd); return -1;
    }
    sl_net_set_nonblocking(fd); /* net.accept's own park loop is what
        makes this transparent to callers that never call
        net.nonblock() themselves */
    return fd;
}

static sl_res_i32_str *sl_net_listen_reuse(int port, int reuse_port) {
    int e = 0;
    int fd = sl_net_listen_fd(port, reuse_port, &e);
    if (fd < 0) return sl_net_err_i32(strerror(e));
    return sl_net_ok_i32((int32_t)fd);
}

static sl_res_i32_str *sl_net_port(int lfd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof(addr);
    if (getsockname(lfd, (struct sockaddr *)&addr, &n) != 0)
        return sl_net_err_i32(strerror(errno));
    return sl_net_ok_i32((int32_t)ntohs(addr.sin_port));
}

static sl_res_i32_str *sl_net_accept(int lfd) {
    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd >= 0) {
            sl_net_set_nonblocking(cfd);
            return sl_net_ok_i32((int32_t)cfd);
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_net_err_i32(strerror(errno));
        if (sl_net_user_nonblock_contains((void *)(intptr_t)lfd))
            return sl_net_err_i32("would block");
        if (sl_reactor_wait(lfd, SL_REACTOR_READ, 1) < 0)
            return sl_net_err_i32("interrupted");
    }
}

/* Connect a non-blocking socket to one address, parking until it
 * completes. Returns the fd, or -1 with *err set (errno, or -2 for the
 * deadline). */
static int sl_net_connect_addr(struct sockaddr *addr, socklen_t alen,
                               int family, sl_until u, int *err) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) { *err = errno; return -1; }
    sl_net_set_nonblocking(fd);
    if (connect(fd, addr, alen) == 0)
        return fd;                  /* connected immediately -- localhost */
    /* EAGAIN: a Unix-domain listener whose backlog is full (Linux) */
    if (errno != EINPROGRESS && errno != EAGAIN) {
        *err = errno; close(fd); return -1;
    }
    int w = sl_reactor_wait_until(fd, SL_REACTOR_WRITE, 1, u);
    if (w == -2) { *err = -2; close(fd); return -1; }
    if (w < 0) { *err = EINTR; close(fd); return -1; }
    int so_err = 0; socklen_t slen = sizeof(so_err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen); /* the
        standard non-blocking-connect idiom: disambiguate write-readiness
        via SO_ERROR rather than inspecting which filter fired */
    if (so_err != 0) { *err = so_err; close(fd); return -1; }
    return fd;
}

/* net.dial / net.dial_until. Every resolved address is tried in turn,
 * not just the first: a name with a stale or unreachable record ahead
 * of a working one would otherwise fail outright. The deadline, when
 * set, covers the lookup and every attempt together. */
static sl_res_i32_str *sl_net_dial_u(const char *host, int port, sl_until u) {
    char portstr[16];
    sl_rt_preempt_disable();
    snprintf(portstr, sizeof(portstr), "%d", port);
    sl_rt_preempt_enable();
    struct addrinfo *res = NULL;
    int timed_out = 0;
    int rc = sl_dns_lookup_until(host, portstr, &res, u, &timed_out);
    if (timed_out) return sl_net_err_i32("timeout");
    if (rc != 0 || !res) return sl_net_err_i32(gai_strerror(rc));
    int err = 0;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        int fd = sl_net_connect_addr(a->ai_addr, a->ai_addrlen, a->ai_family,
                                     u, &err);
        if (fd >= 0) {
            freeaddrinfo(res);
            return sl_net_ok_i32((int32_t)fd);
        }
        if (err == -2 || err == EINTR) break;
    }
    freeaddrinfo(res);
    if (err == -2) return sl_net_err_i32("timeout");
    if (err == EINTR) return sl_net_err_i32("interrupted");
    return sl_net_err_i32(strerror(err));
}

static sl_res_i32_str *sl_net_dial(const char *host, int port) {
    return sl_net_dial_u(host, port, 0);
}

static sl_res_i32_str *sl_net_dial_until(const char *host, int port,
                                         sl_until u) {
    return sl_net_dial_u(host, port, u);
}

/* A Unix-domain stream socket. The fd works with every fd-based call:
 * send/recv and their _until forms, close, idle_alive. */
static int sl_net_unix_addr(const char *path, struct sockaddr_un *sa,
                            const char **why) {
    memset(sa, 0, sizeof(*sa));
    sa->sun_family = AF_UNIX;
    size_t n = strlen(path);
    if (n == 0) { *why = "empty socket path"; return -1; }
    if (n >= sizeof(sa->sun_path)) {
        *why = "socket path too long";
        return -1;
    }
    memcpy(sa->sun_path, path, n);
    return 0;
}

static sl_res_i32_str *sl_net_dial_unix(const char *path, sl_until u) {
    struct sockaddr_un sa;
    const char *why = NULL;
    if (sl_net_unix_addr(path, &sa, &why) != 0) return sl_net_err_i32(why);
    int err = 0;
    int fd = sl_net_connect_addr((struct sockaddr *)&sa, sizeof(sa), AF_UNIX,
                                 u, &err);
    if (fd >= 0) return sl_net_ok_i32((int32_t)fd);
    if (err == -2) return sl_net_err_i32("timeout");
    if (err == EINTR) return sl_net_err_i32("interrupted");
    return sl_net_err_i32(strerror(err));
}

/* Listen on a Unix-domain socket at `path`, which must not exist yet --
 * a stale file is an error, not silently removed, since it might belong
 * to a server that is still running. Accept with net.accept. */
static sl_res_i32_str *sl_net_listen_unix(const char *path) {
    struct sockaddr_un sa;
    const char *why = NULL;
    if (sl_net_unix_addr(path, &sa, &why) != 0) return sl_net_err_i32(why);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return sl_net_err_i32(strerror(errno));
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0 ||
        listen(fd, 1024) != 0) {
        int e = errno;
        close(fd);
        return sl_net_err_i32(strerror(e));
    }
    sl_net_set_nonblocking(fd);
    return sl_net_ok_i32((int32_t)fd);
}

/* See sl_net_recv_u for the `u` convention. A send that times out
 * mid-buffer has ALREADY put `off` bytes on the wire, and there is no
 * way to report both "timed out" and "wrote this much" through
 * result[i32,str] -- so a "timeout" error here means the stream is
 * left at an unknown offset and the connection must be closed, not
 * retried. That is the right contract for a framed protocol anyway:
 * a half-written frame is unrecoverable regardless. */
static sl_res_i32_str *sl_net_send_u(int fd, sl_bytes *data, sl_until u) {
    long long off = 0;
    if (u && sl_until_hit(u) && data->len > 0)
        return sl_net_err_i32("timeout");
    while (off < data->len) {
        ssize_t n = send(fd, data->ptr + off,
                         (size_t)(data->len - off), 0);
        if (n >= 0) { off += n; continue; }
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_net_err_i32(strerror(errno));
        if (sl_net_user_nonblock_contains((void *)(intptr_t)fd))
            return sl_net_err_i32("would block");
        /* abort_on_shutdown stays 0: always keep retrying through a
           shutdown nudge so an in-flight write can finish
           (tests/proc_shutdown's own requirement) -- see
           sl_reactor_wait's own comment for why 1 here would busy-spin
           at 100% CPU. Only -2 (deadline) ends the loop; -1 is the
           shutdown nudge and is ignored exactly as before. */
        if (sl_reactor_wait_until(fd, SL_REACTOR_WRITE, 0, u) == -2)
            return sl_net_err_i32("timeout");
    }
    return sl_net_ok_i32((int32_t)data->len);
}

static sl_res_i32_str *sl_net_send(int fd, sl_bytes *data) {
    return sl_net_send_u(fd, data, 0);
}

static sl_res_i32_str *sl_net_send_until(int fd, sl_bytes *data, sl_until u) {
    return sl_net_send_u(fd, data, u);
}

#define SL_RECV_FL_MAX 64
#define SL_RECV_FL_BYTES (1024 * 1024)

typedef struct sl_recv_chunk {
    struct sl_recv_chunk *next;
    size_t cap;
} sl_recv_chunk;

static sl_recv_chunk *sl_recv_fl;
static int sl_recv_fl_n;
static size_t sl_recv_fl_bytes;
static pthread_mutex_t sl_recv_fl_mu = PTHREAD_MUTEX_INITIALIZER;

static void *sl_recv_buf_get(size_t n) {
    sl_recv_chunk *c = NULL;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_recv_fl_mu);
    sl_recv_chunk **pp = &sl_recv_fl;
    sl_recv_chunk *it = sl_recv_fl;
    while (it) {
        if (it->cap >= n) {
            *pp = it->next;
            sl_recv_fl_n--;
            sl_recv_fl_bytes -= it->cap;
            c = it;
            break;
        }
        pp = &it->next;
        it = it->next;
    }
    pthread_mutex_unlock(&sl_recv_fl_mu);
    sl_rt_preempt_enable();
    if (c)
        return (void *)(c + 1);
    sl_rt_preempt_disable();
    c = (sl_recv_chunk *)malloc(sizeof(sl_recv_chunk) + n);
    sl_rt_preempt_enable();
    if (!c) {
        fprintf(stderr, "slang: out of memory allocating recv buffer\n");
        exit(1);
    }
    c->next = NULL;
    c->cap = n;
    return (void *)(c + 1);
}

static void sl_recv_buf_put(void *p) {
    sl_recv_chunk *c;
    if (!p)
        return;
    c = ((sl_recv_chunk *)p) - 1;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_recv_fl_mu);
    if (sl_recv_fl_n < SL_RECV_FL_MAX &&
        sl_recv_fl_bytes + c->cap <= SL_RECV_FL_BYTES) {
        c->next = sl_recv_fl;
        sl_recv_fl = c;
        sl_recv_fl_n++;
        sl_recv_fl_bytes += c->cap;
        pthread_mutex_unlock(&sl_recv_fl_mu);
        sl_rt_preempt_enable();
        return;
    }
    pthread_mutex_unlock(&sl_recv_fl_mu);
    sl_rt_preempt_enable();
    free(c);
}

/* What a recv returns: the n received bytes as a new value, built only
 * after the data is in. Never allocate it before the wait: a bytes
 * header made before the park and filled after it sat through the park,
 * where a minor collection promoted it, and the data then stored into
 * it was an old->young edge no barrier saw -- freed by the next minor
 * while the program still held it. Header and data are one allocation
 * (sl_bytes_alloc), made once the data is in. */
static sl_bytes *sl_net_recv_bytes(const unsigned char *scratch, long long n) {
    sl_bytes *b = sl_bytes_alloc_uninit(n);
    if (n > 0) memcpy(b->ptr, scratch, (size_t)n);
    return b;
}

/* `u` of 0 means "no deadline" and reproduces the original blocking
 * behaviour exactly; a non-zero `u` is an absolute monotonic instant
 * (sl_until_of). A timeout returns the reserved error string "timeout"
 * -- callers distinguish it from a peer error by comparing against
 * that exact text, the same distinction the link API draws with
 * SL_FAULT_TIMEOUT. The deadline is checked before the first recv() as
 * well as around each park, so an already-expired deadline never
 * performs I/O. */
static sl_res_bytes_str *sl_net_recv_u(int fd, int max, sl_until u) {
    if (u && sl_until_hit(u))
        return sl_net_err_bytes("timeout");
    if (max <= 0) max = 4096;
    unsigned char *scratch = (unsigned char *)sl_recv_buf_get((size_t)max);
    /* Nothing GC-held lives across the wait below: the result is built
     * once the bytes are in (sl_net_recv_bytes says why). */
    for (;;) {
        ssize_t n = recv(fd, scratch, (size_t)max, 0);
        if (n >= 0) {
            sl_bytes *b = sl_net_recv_bytes(scratch, (long long)n);
            sl_recv_buf_put(scratch);
            return sl_net_ok_bytes(b);
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes(strerror(errno));
        }
        if (sl_net_user_nonblock_contains((void *)(intptr_t)fd)) {
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes("would block");
        }
        int wr = sl_reactor_wait_until(fd, SL_REACTOR_READ, 1, u);
        if (wr < 0) {
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes(wr == -2 ? "timeout" : "interrupted");
        }
    }
}

static sl_res_bytes_str *sl_net_recv(int fd, int max) {
    return sl_net_recv_u(fd, max, 0);
}

static sl_res_bytes_str *sl_net_recv_until(int fd, int max, sl_until u) {
    return sl_net_recv_u(fd, max, u);
}

/* See pkg_net/sigs.c. EAGAIN is the only answer that means "open and
 * quiet": 0 is an orderly close, >0 is bytes nobody asked for (a pooled
 * HTTP connection must be silent between requests, so it is unusable),
 * and any other error is a reset or worse. */
static bool sl_net_idle_alive(int fd) {
    unsigned char b;
    ssize_t n = recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT);
    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
}

static void sl_net_close(int fd) {
    sl_net_user_nonblock_remove((void *)(intptr_t)fd); /* avoid a
        stale entry misapplying to a later, unrelated fd that
        happens to reuse the same number. NOTE (known, accepted
        limitation): if another task is genuinely parked waiting on
        this fd via the reactor right now, closing it here silently
        removes its kqueue registration with no event ever delivered
        -- that task hangs forever, permanently leaking its GC roots
        and, if it was spawned, wedging any active_tasks()-based
        shutdown drain. Not exercised by any current test; not new
        to this slice. */
    close(fd);
}

static sl_res_bool_str *sl_net_nonblock(int fd) {
    /* fd is already non-blocking at the OS level internally (every
       fd is, now) -- this call's real job is opting IN to the
       synchronous "would block" contract instead of parking, which
       is what the side-table actually tracks. */
    sl_net_user_nonblock_insert((void *)(intptr_t)fd);
    return sl_net_ok_bool(true);
}

static int sl_link_fault_kind(int e) {
    if (e == ETIMEDOUT)
        return SL_FAULT_TIMEOUT;
    if (e == ECONNRESET)
        return SL_FAULT_RESET;
    if (e == ECONNREFUSED)
        return SL_FAULT_REFUSED;
    if (e == EPIPE)
        return SL_FAULT_CLOSED;
    return SL_FAULT_IO;
}

static sl_fault sl_link_fault_errno(int e) {
    return sl_fault_op(sl_link_fault_kind(e), e, "");
}

static sl_fault sl_link_fault_op(const char *op, int e) {
    return sl_fault_op(sl_link_fault_kind(e), e, op);
}

static sl_res_link_fault sl_link_ok_link(sl_link v) {
    return (sl_res_link_fault){ .ok = true, .v = v };
}

static sl_res_link_fault sl_link_err_link(sl_fault f) {
    return (sl_res_link_fault){ .ok = false, .e = f };
}

static sl_res_int_fault sl_link_ok_int(long long v) {
    return (sl_res_int_fault){ .ok = true, .v = v };
}

static sl_res_int_fault sl_link_err_int(sl_fault f) {
    return (sl_res_int_fault){ .ok = false, .e = f };
}

/* A link's TLS session, when it has one: sl_tls.c sets these the first
 * time a link starts TLS, so they are never NULL where `l->tls` is set. */
static sl_res_int_fault (*sl_link_tls_send_fn)(sl_link *l,
                                               const unsigned char *ptr,
                                               long long len, sl_until u);
static sl_res_int_fault (*sl_link_tls_recv_fn)(sl_link *l, sl_wire w,
                                               sl_until u);
/* Gives `w` (a fresh writer half) its share of `l`'s session. */
static void (*sl_link_tls_share_fn)(sl_link *l, sl_link *w);

/* After split(), the link it was called on only reads and the one it
 * returned only writes: two tasks sending on one connection could
 * interleave partial writes, and two reading would split its bytes
 * between them. */
static sl_fault sl_link_wrong_half(int writing) {
    return sl_fault_make(SL_FAULT_IO,
                         writing ? "send: this link was split; send through "
                                   "the writer split() returned"
                                 : "recv: this link is the writer split() "
                                   "returned; read from the link it was "
                                   "split from");
}

static sl_res_int_fault sl_link_send_ptr(sl_link *l, const unsigned char *ptr,
                                         long long len, sl_until u) {
    long long off = 0;
    if (!l || !l->live)
        return sl_link_err_int(sl_fault_op(SL_FAULT_CLOSED, 0, "send"));
    if (l->role == SL_LINK_READER)
        return sl_link_err_int(sl_link_wrong_half(1));
    if (l->tls)
        return sl_link_tls_send_fn(l, ptr, len, u);
    while (off < len) {
        if (u && sl_until_hit(u))
            return sl_link_err_int(sl_fault_op(SL_FAULT_TIMEOUT, 0, "send"));
        ssize_t n = send(l->fd, ptr + off, (size_t)(len - off), 0);
        if (n >= 0) {
            off += n;
            continue;
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_link_err_int(sl_link_fault_op("send", errno));
        int wr = sl_reactor_wait_until(l->fd, SL_REACTOR_WRITE, 0, u);
        if (wr == -2)
            return sl_link_err_int(sl_fault_op(SL_FAULT_TIMEOUT, 0, "send"));
        if (wr < 0)
            return sl_link_err_int(sl_fault_op(SL_FAULT_CLOSED, 0, "send"));
    }
    return sl_link_ok_int(len);
}

static sl_res_link_fault sl_link_listen(long long port) {
    int e = 0;
    int fd = sl_net_listen_fd((int)port, 0, &e);
    if (fd < 0)
        return sl_link_err_link(sl_link_fault_op("listen", e));
    return sl_link_ok_link(sl_link_from_fd(fd));
}

static sl_res_link_fault sl_link_listen_reuse(long long port, long long reuse) {
    int e = 0;
    int fd = sl_net_listen_fd((int)port, reuse != 0, &e);
    if (fd < 0)
        return sl_link_err_link(sl_link_fault_op("listen", e));
    return sl_link_ok_link(sl_link_from_fd(fd));
}

static sl_res_link_fault sl_link_accept(sl_link *ln, sl_until u) {
    if (!ln || !ln->live)
        return sl_link_err_link(sl_fault_op(SL_FAULT_CLOSED, 0, "accept"));
    for (;;) {
        if (u && sl_until_hit(u))
            return sl_link_err_link(sl_fault_op(SL_FAULT_TIMEOUT, 0, "accept"));
        int cfd = accept(ln->fd, NULL, NULL);
        if (cfd >= 0) {
            sl_net_set_nonblocking(cfd);
            return sl_link_ok_link(sl_link_from_fd(cfd));
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_link_err_link(sl_link_fault_op("accept", errno));
        int w = sl_reactor_wait_until(ln->fd, SL_REACTOR_READ, 1, u);
        if (w == -2)
            return sl_link_err_link(sl_fault_op(SL_FAULT_TIMEOUT, 0, "accept"));
        if (w < 0)
            return sl_link_err_link(sl_fault_op(SL_FAULT_CLOSED, 0, "accept"));
    }
}

static sl_res_link_fault sl_link_dial(const char *host, long long port,
                                     sl_until u) {
    char portstr[16];
    sl_rt_preempt_disable();
    snprintf(portstr, sizeof(portstr), "%d", (int)port);
    sl_rt_preempt_enable();
    struct addrinfo *res = NULL;
    int rc = sl_dns_lookup(host, portstr, &res);
    if (rc != 0 || !res)
        return sl_link_err_link(sl_fault_op(SL_FAULT_REFUSED, rc, "dial"));
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return sl_link_err_link(sl_link_fault_op("dial", errno));
    }
    sl_net_set_nonblocking(fd);
    int cres = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (cres == 0)
        return sl_link_ok_link(sl_link_from_fd(fd));
    if (errno != EINPROGRESS) {
        int e = errno;
        close(fd);
        return sl_link_err_link(sl_link_fault_op("connect", e));
    }
    int w = sl_reactor_wait_until(fd, SL_REACTOR_WRITE, 1, u);
    if (w == -2) {
        close(fd);
        return sl_link_err_link(sl_fault_op(SL_FAULT_TIMEOUT, 0, "connect"));
    }
    if (w < 0) {
        close(fd);
        return sl_link_err_link(sl_fault_op(SL_FAULT_CLOSED, 0, "connect"));
    }
    int so_err = 0;
    socklen_t slen = sizeof(so_err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen);
    if (so_err != 0) {
        close(fd);
        return sl_link_err_link(sl_link_fault_op("connect", so_err));
    }
    return sl_link_ok_link(sl_link_from_fd(fd));
}

static sl_res_int_fault sl_link_send(sl_link *l, sl_wire w, sl_until u) {
    return sl_link_send_ptr(l, w.ptr, w.len, u);
}

static sl_res_int_fault sl_link_send_bytes(sl_link *l, const unsigned char *ptr,
                                           long long len, sl_until u) {
    if (!ptr || len <= 0)
        return sl_link_ok_int(0);
    return sl_link_send_ptr(l, ptr, len, u);
}

static sl_res_int_fault sl_link_send_static(sl_link *l, sl_bytes b, sl_until u) {
    if (!b.ptr || b.len <= 0)
        return sl_link_ok_int(0);
    return sl_link_send_ptr(l, b.ptr, b.len, u);
}

static sl_res_int_fault sl_link_recv(sl_link *l, sl_wire w, sl_until u) {
    if (!l || !l->live)
        return sl_link_err_int(sl_fault_op(SL_FAULT_CLOSED, 0, "recv"));
    if (l->role == SL_LINK_WRITER)
        return sl_link_err_int(sl_link_wrong_half(0));
    if (w.len <= 0)
        return sl_link_ok_int(0);
    if (l->tls)
        return sl_link_tls_recv_fn(l, w, u);
    for (;;) {
        if (u && sl_until_hit(u))
            return sl_link_err_int(sl_fault_op(SL_FAULT_TIMEOUT, 0, "recv"));
        ssize_t n = recv(l->fd, w.ptr, (size_t)w.len, 0);
        if (n >= 0)
            return sl_link_ok_int((long long)n);
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_link_err_int(sl_link_fault_op("recv", errno));
        int wr = sl_reactor_wait_until(l->fd, SL_REACTOR_READ, 1, u);
        if (wr == -2)
            return sl_link_err_int(sl_fault_op(SL_FAULT_TIMEOUT, 0, "recv"));
        if (wr < 0)
            return sl_link_err_int(sl_fault_op(SL_FAULT_CLOSED, 0, "recv"));
    }
}

/* `c.split()`: a second link on the same connection, for writing from
 * another task while this one reads -- a WebSocket server pushing to a
 * client it is also reading from. The new link is a dup of the fd, so the
 * two halves wait on the reactor independently (one registration each);
 * see sl_link for why each owns its own fd number. Over TLS both halves
 * share the session, serialized by its lock (sl_tls.c). */
static sl_res_link_fault sl_link_split(sl_link *l) {
    if (!l || !l->live)
        return sl_link_err_link(sl_fault_op(SL_FAULT_CLOSED, 0, "split"));
    if (l->role != SL_LINK_WHOLE)
        return sl_link_err_link(sl_fault_make(SL_FAULT_IO,
            "split: this link is already split"));
    int d = fcntl(l->fd, F_DUPFD_CLOEXEC, 0);
    if (d < 0)
        return sl_link_err_link(sl_link_fault_op("split", errno));
    /* O_NONBLOCK belongs to the open file description, which the dup
       shares, so the writer is non-blocking already. */
    sl_link w = sl_link_from_fd(d);
    w.role = SL_LINK_WRITER;
    if (l->tls)
        sl_link_tls_share_fn(l, &w);
    l->role = SL_LINK_READER;
    return sl_link_ok_link(w);
}

static long long sl_link_port(sl_link *l) {
    struct sockaddr_in addr;
    socklen_t n = sizeof(addr);
    if (!l || !l->live)
        return 0;
    if (getsockname(l->fd, (struct sockaddr *)&addr, &n) != 0)
        return 0;
    return (long long)ntohs(addr.sin_port);
}

static sl_peer sl_link_peer(sl_link *l) {
    sl_peer p;
    p.addr = 0;
    p.port = 0;
    if (!l || !l->live)
        return p;
    struct sockaddr_in addr;
    socklen_t n = sizeof(addr);
    if (getpeername(l->fd, (struct sockaddr *)&addr, &n) != 0)
        return p;
    p.addr = ntohl(addr.sin_addr.s_addr);
    p.port = ntohs(addr.sin_port);
    return p;
}
