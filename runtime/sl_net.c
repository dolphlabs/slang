#include <errno.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
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
#include <net/if.h>
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
    sl_reactor_stat_loops, sl_reactor_stat_worker_polls,
    sl_reactor_stat_thread_events;

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
            "scans=%llu loops=%llu thread_events=%llu worker_polls=%llu\n",
            parks, wakes,
            (unsigned long long)sl_reactor_stat_regs,
            (unsigned long long)sl_reactor_stat_scans,
            (unsigned long long)sl_reactor_stat_loops,
            (unsigned long long)sl_reactor_stat_thread_events,
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
    /* The READ slot only: how many times net.close has closed this number
       (low 15 bits), and SL_REACTOR_CLOSING while a close is under way. An
       op reads it before its first syscall and its park compares it under
       the list lock (sl_reactor_close_epoch), so a close that lands after
       the op's EAGAIN but before its park is still seen. 16 bits fit the
       slot's padding on both reactors; a false match needs 32768 closes of
       one number inside one op. */
    uint16_t closes;
#if defined(SL_REACTOR_EPOLL)
    /* A persistent fd's edge arrived with nobody waiting in this
       direction: the next wait returns at once, for its caller to retry,
       instead of parking for an edge that has already passed. */
    uint8_t ready;
    /* The READ slot only: SL_REACTOR_PERSIST_*, the fd's registration. */
    uint8_t persist;
#endif
} sl_reactor_slot;

#if defined(SL_REACTOR_EPOLL)
/* A connected socket (accept, dial) is registered once, edge-triggered for
 * both directions, the way Go's netpoller registers every fd, instead of
 * one-shot and re-armed with an epoll_ctl on every wait: 1.8 of those a
 * request on the PG routes (todo.md R3). An edge with no waiter sets the
 * slot's `ready`, and an edge with one wakes it without a generation
 * check, since any wake there is at worst spurious: every wait on such a
 * fd is its caller's retry loop around a non-blocking call.
 *
 * Opt-in, because it needs every close of the fd to drop the registration
 * first (sl_reactor_forget) -- else a reused number looks registered and
 * its first wait parks for an edge that is never asked for. The runtime
 * closes connected sockets in a handful of places that all do; pipes,
 * eventfds, stdin, a listener and a socket still connecting are closed
 * raw in many more, so they keep the one-shot registration. The forget is
 * an EPOLL_CTL_DEL, not left to close(2): sockets are not close-on-exec,
 * and while a spawned child holds the file open the registration outlives
 * the parent's fd. */
#define SL_REACTOR_PERSIST_NONE   0
#define SL_REACTOR_PERSIST_MARKED 1  /* registered at its first wait */
#define SL_REACTOR_PERSIST_ADDED  2
#endif
/* Set from the waiters' take until close(2) has returned: the fd is still
 * open then, so an op that starts in between reads the new count, gets
 * EAGAIN and would park unseen without it. */
#define SL_REACTOR_CLOSING 0x8000u
#define SL_REACTOR_CLOSE_COUNT 0x7fffu
#define SL_REACTOR_SLOT_CHUNK 4096
#define SL_REACTOR_SLOT_CHUNKS 16384
static sl_reactor_slot *_Atomic sl_reactor_slot_chunks[SL_REACTOR_SLOT_CHUNKS];
static pthread_mutex_t sl_reactor_slot_grow_mu = PTHREAD_MUTEX_INITIALIZER;

/* An epoll event's data carries the fd and the generation of both
 * directions, with the top bit set to tell it from the shutdown and timer
 * tokens (user space pointers never have it): epoll has one registration
 * per fd, which a read and a write parked on it share. kqueue has one
 * knote per filter, the fd and filter in the event, and the generation in
 * udata. The narrower epoll generation only has to outlast the moment
 * between an event's harvest and its handling; a false match is a spurious
 * wakeup. */
#define SL_REACTOR_TAG_FD (1ULL << 63)
#if defined(SL_REACTOR_KQUEUE)
#define SL_REACTOR_GEN_MASK 0xffffffffu
#else
#define SL_REACTOR_GEN_MASK 0x7fffu
#define SL_REACTOR_READ_GEN_SHIFT 33
#define SL_REACTOR_WRITE_GEN_SHIFT 48
/* A persistent registration's event: fd only, no generations. */
#define SL_REACTOR_TAG_PERSIST (1ULL << 32)
#endif

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
/* sl_reactor_wait_until's answer when the fd was closed under the wait.
 * Distinct from -1, which send ignores to outlive a shutdown nudge: a
 * waiter told this must not touch the fd again, because its number may
 * already belong to another connection. */
#define SL_REACTOR_CLOSED (-4)
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

/* The waiters on fd, off their list and onto *ready, marked closed. Taken
 * before close(2) and resumed after it: once the number is free another
 * connection can own it, and its slot must not be mistaken for this fd's.
 * The kernel drops the registration on close with no event, so nothing
 * else would ever wake them, and a later wait on the reused number would
 * overwrite their slot. */
static void sl_reactor_take_closed(int fd, sl_task **ready) {
    sl_reactor_wq *q = &sl_reactor_wqs[sl_reactor_wq_for(fd)];
    pthread_mutex_lock(&q->mu);
    sl_reactor_slot *cs = sl_reactor_slot_at(fd, SL_REACTOR_READ, 1);
    if (cs)
        __atomic_store_n(&cs->closes,
                         (uint16_t)(((cs->closes + 1u) & SL_REACTOR_CLOSE_COUNT) |
                                    SL_REACTOR_CLOSING),
                         __ATOMIC_RELEASE);
    for (int rw = SL_REACTOR_READ; rw <= SL_REACTOR_WRITE; rw++) {
        sl_reactor_slot *s = sl_reactor_slot_at(fd, rw, 0);
        if (!s || !s->task)
            continue;
        sl_task *t = s->task;
        s->task = NULL;
        if (!t->on_wq)
            continue;
        sl_reactor_wq_unlink(q, t);
        t->wait_closed = 1;
        t->next = *ready;
        *ready = t;
    }
    pthread_mutex_unlock(&q->mu);
}

/* The number is free again (close(2) returned) or newly handed out (accept,
 * dial): ops from here on are its next owner's. The count stays, so an op
 * that began before the close still finds it moved on. Caller holds fd's
 * list lock. */
static void sl_reactor_clear_closing_locked(int fd) {
    sl_reactor_slot *cs = sl_reactor_slot_at(fd, SL_REACTOR_READ, 0);
    if (cs && (cs->closes & SL_REACTOR_CLOSING))
        __atomic_store_n(&cs->closes,
                         (uint16_t)(cs->closes & SL_REACTOR_CLOSE_COUNT),
                         __ATOMIC_RELEASE);
}

static void sl_reactor_clear_closing(int fd) {
    sl_reactor_wq *q = &sl_reactor_wqs[sl_reactor_wq_for(fd)];
    pthread_mutex_lock(&q->mu);
    sl_reactor_clear_closing_locked(fd);
    pthread_mutex_unlock(&q->mu);
}

#if !defined(SL_REACTOR_KQUEUE)
/* Arms fd's one registration for every direction with a waiter now, under
 * the fd's list lock. It always names both: a MOD replaces the whole
 * registration, so one direction's wait used to cancel the other's, and
 * being one-shot, an event for one direction disarms the other. A fd with
 * no waiter left stays disarmed. */
static void sl_reactor_arm(int fd) {
    sl_reactor_slot *rd = sl_reactor_slot_at(fd, SL_REACTOR_READ, 0);
    sl_reactor_slot *wr = sl_reactor_slot_at(fd, SL_REACTOR_WRITE, 0);
    struct epoll_event ev;
    ev.events = 0;
    ev.data.u64 = SL_REACTOR_TAG_FD | (uint64_t)(uint32_t)fd;
    if (rd && rd->task) {
        ev.events |= EPOLLIN;
        ev.data.u64 |= (uint64_t)(rd->gen & SL_REACTOR_GEN_MASK)
                       << SL_REACTOR_READ_GEN_SHIFT;
    }
    if (wr && wr->task) {
        ev.events |= EPOLLOUT;
        ev.data.u64 |= (uint64_t)(wr->gen & SL_REACTOR_GEN_MASK)
                       << SL_REACTOR_WRITE_GEN_SHIFT;
    }
    if (!ev.events)
        return;
    ev.events |= EPOLLONESHOT;
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
}

/* A marked fd's one registration, at its first wait, under the fd's list
 * lock. ADD reports readiness the fd already has, so an edge that came
 * before it is not lost. EEXIST is a one-shot registration from before the
 * mark (a dial's connect wait): MOD replaces it. Should both fail the fd
 * goes back to one-shot, which works for anything epoll accepts. */
static void sl_reactor_register_persistent(int fd, sl_reactor_slot *rs) {
    struct epoll_event ev;
    ev.events = EPOLLIN | EPOLLOUT | EPOLLET;
    ev.data.u64 = SL_REACTOR_TAG_FD | SL_REACTOR_TAG_PERSIST |
                  (uint64_t)(uint32_t)fd;
    int regs = 1;
    int rc = epoll_ctl(sl_reactor_fd, EPOLL_CTL_ADD, fd, &ev);
    if (rc != 0 && errno == EEXIST) {
        rc = epoll_ctl(sl_reactor_fd, EPOLL_CTL_MOD, fd, &ev);
        regs = 2;
    }
    if (sl_reactor_stat_enabled())
        atomic_fetch_add_explicit(&sl_reactor_stat_regs, regs,
                                  memory_order_relaxed);
    if (rc == 0) {
        rs->persist = SL_REACTOR_PERSIST_ADDED;
        return;
    }
    rs->persist = SL_REACTOR_PERSIST_NONE;
    sl_reactor_arm(fd);
}
#endif

/* fd is a connected socket whose every close goes through
 * sl_reactor_forget: register it persistently at its first wait. A no-op
 * on kqueue, which keeps one-shot knotes. */
static void sl_reactor_mark_persistent(int fd) {
    if (fd < 0)
        return;
#if defined(SL_REACTOR_EPOLL)
    sl_rt_preempt_disable();
    sl_reactor_wq *q = &sl_reactor_wqs[sl_reactor_wq_for(fd)];
    pthread_mutex_lock(&q->mu);
    sl_reactor_clear_closing_locked(fd);
    sl_reactor_slot *rd = sl_reactor_slot_at(fd, SL_REACTOR_READ, 1);
    sl_reactor_slot *wr = sl_reactor_slot_at(fd, SL_REACTOR_WRITE, 1);
    if (rd && wr) {
        rd->persist = SL_REACTOR_PERSIST_MARKED;
        rd->ready = 0;
        wr->ready = 0;
    }
    pthread_mutex_unlock(&q->mu);
    sl_rt_preempt_enable();
#else
    /* A connected socket's number may still carry a close of its previous
       owner's that is finishing on another thread. */
    sl_rt_preempt_disable();
    sl_reactor_clear_closing(fd);
    sl_rt_preempt_enable();
#endif
}

/* Before close(2) of any fd that may have been marked: drops its
 * persistent registration and state, so the number's next owner starts
 * clean. Under the list lock, so an event already harvested for the old
 * registration finds the fd no longer ADDED and is ignored. Cheap for a
 * fd never marked: one lock, no syscall. */
static void sl_reactor_forget(int fd) {
#if defined(SL_REACTOR_EPOLL)
    if (fd < 0)
        return;
    sl_rt_preempt_disable();
    sl_reactor_wq *q = &sl_reactor_wqs[sl_reactor_wq_for(fd)];
    pthread_mutex_lock(&q->mu);
    sl_reactor_slot *rd = sl_reactor_slot_at(fd, SL_REACTOR_READ, 0);
    sl_reactor_slot *wr = sl_reactor_slot_at(fd, SL_REACTOR_WRITE, 0);
    if (rd) {
        if (rd->persist == SL_REACTOR_PERSIST_ADDED)
            epoll_ctl(sl_reactor_fd, EPOLL_CTL_DEL, fd, NULL);
        rd->persist = SL_REACTOR_PERSIST_NONE;
        rd->ready = 0;
    }
    if (wr)
        wr->ready = 0;
    pthread_mutex_unlock(&q->mu);
    sl_rt_preempt_enable();
#else
    (void)fd;
#endif
}

/* fd's close count, for sl_reactor_wait_epoch: read once per op, before
 * its first syscall. */
static int sl_reactor_close_epoch(int fd) {
    sl_reactor_slot *s = sl_reactor_slot_at(fd, SL_REACTOR_READ, 0);
    return s ? (int)__atomic_load_n(&s->closes, __ATOMIC_ACQUIRE) : 0;
}

#define SL_REACTOR_NO_EPOCH (-1)

static int sl_reactor_closed_since(int fd, int epoch) {
    int now = sl_reactor_close_epoch(fd);
    return now != epoch || (now & SL_REACTOR_CLOSING);
}

/* epoch is the op's sl_reactor_close_epoch, or SL_REACTOR_NO_EPOCH for a
 * fd net.close never closes (pipes, eventfds, links). */
static int sl_reactor_wait_epoch(int fd, int rw, int abort_on_shutdown,
                                 sl_until deadline, int epoch) {
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
    if (epoch != SL_REACTOR_NO_EPOCH && sl_reactor_closed_since(fd, epoch)) {
        /* Closed since this op began, or closing now, by a task that found
           nobody parked to wake: the number is free or another
           connection's by the time this op could retry. */
        pthread_mutex_unlock(&wq->mu);
        sl_rt_preempt_enable();
        return SL_REACTOR_CLOSED;
    }
    sl_task *sl_reactor_self = sl_rt_cur();
    sl_reactor_slot *slot = sl_reactor_slot_at(fd, rw, 1);
    if (!slot) {
        pthread_mutex_unlock(&wq->mu);
        sl_rt_preempt_enable();
        return -1;
    }
#if defined(SL_REACTOR_KQUEUE)
    uint32_t gen = ++slot->gen;
#else
    sl_reactor_slot *rs = rw == SL_REACTOR_READ
                              ? slot
                              : sl_reactor_slot_at(fd, SL_REACTOR_READ, 1);
    int persist = rs && rs->persist != SL_REACTOR_PERSIST_NONE;
    if (persist && slot->ready) {
        /* An edge came since the caller's last try: no park, no syscall;
           the caller tries again. */
        slot->ready = 0;
        pthread_mutex_unlock(&wq->mu);
        sl_rt_preempt_enable();
        return 0;
    }
    ++slot->gen;
#endif
    slot->task = sl_reactor_self;
    sl_reactor_self->wait_fd = fd;
    sl_reactor_self->wait_rw = rw;
    sl_reactor_self->wait_closed = 0;
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
    if (!persist)
        sl_reactor_arm(fd);
    else if (rs->persist == SL_REACTOR_PERSIST_MARKED)
        sl_reactor_register_persistent(fd, rs);
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
    int sl_reactor_wait_closed = sl_reactor_self->wait_closed;
    int sl_reactor_wait_shutdown =
        atomic_load_explicit(&sl_rt_shutdown_flag, memory_order_acquire);
    sl_rt_preempt_enable();
    if (sl_reactor_wait_closed)
        return SL_REACTOR_CLOSED;
    if (sl_reactor_wait_shutdown)
        return -1;
    if (deadline && sl_until_hit(deadline))
        return -2;
    return 0;
}

static int sl_reactor_wait_until(int fd, int rw, int abort_on_shutdown,
                                 sl_until deadline) {
    return sl_reactor_wait_epoch(fd, rw, abort_on_shutdown, deadline,
                                 SL_REACTOR_NO_EPOCH);
}

static int sl_reactor_wait(int fd, int rw, int abort_on_shutdown) {
    return sl_reactor_wait_until(fd, rw, abort_on_shutdown, 0);
}

/* The slot decides: an event from an older wait on this (fd, direction) --
 * its waiter already left by deadline or shutdown, possibly earlier in
 * this same batch -- finds the generation moved on or the slot empty, and
 * wakes nobody. Under the list's lock. */
static void sl_reactor_take_slot(sl_reactor_wq *q, int fd, int rw,
                                 uint32_t ev_gen, sl_task **ready) {
    sl_reactor_slot *slot = sl_reactor_slot_at(fd, rw, 0);
    if (!slot || !slot->task || (slot->gen & SL_REACTOR_GEN_MASK) != ev_gen)
        return;
    sl_task *t = slot->task;
    slot->task = NULL;
    if (!t->on_wq)
        return;
    sl_reactor_wq_unlink(q, t);
    t->next = *ready;
    *ready = t;
}

#if defined(SL_REACTOR_EPOLL)
/* A persistent fd's edge in direction rw: wakes its waiter, whoever that
 * is now, or, with none, leaves `ready` for the next wait. Under the
 * list's lock. */
static void sl_reactor_take_edge(sl_reactor_wq *q, int fd, int rw,
                                 sl_task **ready) {
    sl_reactor_slot *slot = sl_reactor_slot_at(fd, rw, 0);
    if (!slot)
        return;
    sl_task *t = slot->task;
    if (!t || !t->on_wq) {
        slot->task = NULL;
        slot->ready = 1;
        return;
    }
    slot->task = NULL;
    sl_reactor_wq_unlink(q, t);
    t->next = *ready;
    *ready = t;
}
#endif

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
        if (is_shutdown) {
            uint64_t x;
            sl_net_drain(sl_reactor_efd, &x, sizeof(x));
        }
#endif
        if (is_shutdown) {
            sl_reactor_take_all(&ready);
            continue;
        }
        sl_reactor_wq *q = &sl_reactor_wqs[sl_reactor_wq_for(ev_fd)];
        pthread_mutex_lock(&q->mu);
#if defined(SL_REACTOR_KQUEUE)
        sl_reactor_take_slot(q, ev_fd, ev_rw, ev_gen, &ready);
#else
        /* HUP and ERR are reported whatever was asked for, and end both
           directions. */
        uint32_t ev_mask = events[i].events;
        if (ev_tag & SL_REACTOR_TAG_PERSIST) {
            /* Only while the fd is still registered: one closed (and
               forgotten) after this batch was harvested may already be
               another fd's number. */
            sl_reactor_slot *rs = sl_reactor_slot_at(ev_fd, SL_REACTOR_READ, 0);
            if (rs && rs->persist == SL_REACTOR_PERSIST_ADDED) {
                if (ev_mask & (EPOLLIN | EPOLLHUP | EPOLLERR))
                    sl_reactor_take_edge(q, ev_fd, SL_REACTOR_READ, &ready);
                if (ev_mask & (EPOLLOUT | EPOLLHUP | EPOLLERR))
                    sl_reactor_take_edge(q, ev_fd, SL_REACTOR_WRITE, &ready);
            }
            pthread_mutex_unlock(&q->mu);
            continue;
        }
        if (ev_mask & (EPOLLIN | EPOLLHUP | EPOLLERR))
            sl_reactor_take_slot(q, ev_fd, SL_REACTOR_READ,
                                 (uint32_t)(ev_tag >> SL_REACTOR_READ_GEN_SHIFT) &
                                     SL_REACTOR_GEN_MASK,
                                 &ready);
        if (ev_mask & (EPOLLOUT | EPOLLHUP | EPOLLERR))
            sl_reactor_take_slot(q, ev_fd, SL_REACTOR_WRITE,
                                 (uint32_t)(ev_tag >> SL_REACTOR_WRITE_GEN_SHIFT) &
                                     SL_REACTOR_GEN_MASK,
                                 &ready);
        /* This event disarmed the whole registration, even if it woke
           nobody: whoever is still parked needs it back. No syscall when
           nobody is, which is every fd used in one direction at a time. */
        sl_reactor_arm(ev_fd);
#endif
        pthread_mutex_unlock(&q->mu);
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
    now = sl_now_ns();
    sl_reactor_expire_due(now);
    atomic_store_explicit(&sl_rt_netpoll_last_ns, now, memory_order_relaxed);
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
        /* A worker is polling in this thread's place (sl_net_worker_poll),
           or one did within the last tick -- workers between tasks poll
           every SL_NETPOLL_BUSY_NS: stay out of their way, and look again
           in a moment. Blocked in epoll_wait instead, this thread woke for
           every batch of events the workers would have found anyway.
           Deadlines come due on their watch, and when no worker has
           polled for a tick this thread takes the set back. */
        if (atomic_load_explicit(&sl_poller_active, memory_order_acquire) ||
            now - atomic_load_explicit(&sl_rt_netpoll_last_ns,
                                       memory_order_relaxed) < SL_REACTOR_TICK_NS) {
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
        if (n > 0 && sl_reactor_stat_enabled())
            atomic_fetch_add_explicit(&sl_reactor_stat_thread_events,
                                      (unsigned long long)n,
                                      memory_order_relaxed);
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
static int sl_dns_lookup_family_until(const char *host, const char *portstr,
                                      int family, struct addrinfo **res,
                                      sl_until u, int *timed_out);

static int sl_dns_lookup_until(const char *host, const char *portstr,
                               struct addrinfo **res, sl_until u,
                               int *timed_out) {
    return sl_dns_lookup_family_until(host, portstr, AF_INET, res, u,
                                      timed_out);
}

/* family AF_INET, or AF_UNSPEC for IPv4 and IPv6 (with AI_ADDRCONFIG, so
 * a host without IPv6 is not handed IPv6 addresses it cannot reach). */
static int sl_dns_lookup_family_until(const char *host, const char *portstr,
                                      int family, struct addrinfo **res,
                                      sl_until u, int *timed_out) {
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
    job->hints.ai_family = family;
    job->hints.ai_socktype = SOCK_STREAM;
    if (family == AF_UNSPEC)
        job->hints.ai_flags = AI_ADDRCONFIG;
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
    sl_rt_fd_forget_hook = sl_reactor_forget;
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
    /* The number may still carry the closing flag of a net.close finishing
       on another thread; this accept's epoch must be read after it. */
    sl_rt_preempt_disable();
    sl_reactor_clear_closing(fd);
    sl_rt_preempt_enable();
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
    int epoch = sl_reactor_close_epoch(lfd);
    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd >= 0) {
            sl_net_set_nonblocking(cfd);
            sl_reactor_mark_persistent(cfd);
            return sl_net_ok_i32((int32_t)cfd);
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_net_err_i32(strerror(errno));
        if (sl_net_user_nonblock_contains((void *)(intptr_t)lfd))
            return sl_net_err_i32("would block");
        int w = sl_reactor_wait_epoch(lfd, SL_REACTOR_READ, 1, 0, epoch);
        if (w == SL_REACTOR_CLOSED)
            return sl_net_err_i32("closed");
        if (w < 0)
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
    if (connect(fd, addr, alen) == 0) {
        sl_reactor_mark_persistent(fd);
        return fd;                  /* connected immediately -- localhost */
    }
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
    sl_reactor_mark_persistent(fd);
    return fd;
}

/* ---- dialing: IPv4 and IPv6 with happy eyeballs (RFC 8305) ------------
 *
 * A name is resolved for both families and its addresses are tried
 * interleaved (IPv6, IPv4, IPv6, ...; getaddrinfo's own order picks the
 * first, per RFC 6724). An attempt that has not connected within 250 ms
 * does not hold up the next one: both race, the first to connect wins and
 * the rest are closed. Without that, a host with a broken IPv6 route
 * would wait out the whole TCP connect timeout on every IPv6 address
 * before trying IPv4 -- the reason dial used to resolve IPv4 only. One
 * address (an IP literal, a name with one record) is a single attempt,
 * exactly as before. */

#define SL_HE_MAX 16
#define SL_HE_DELAY_NS 250000000LL
/* How often a race with every address started looks at the attempts it
   is not parked on (the reactor parks a task on one fd). */
#define SL_HE_RECHECK_NS 25000000LL

/* 1 connected, 0 still connecting, or -errno. */
static int sl_he_state(int fd) {
    struct pollfd p;
    p.fd = fd;
    p.events = POLLOUT;
    p.revents = 0;
    if (poll(&p, 1, 0) <= 0)
        return 0;
    int so = 0;
    socklen_t l = sizeof(so);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &so, &l);
    if (so != 0)
        return -so;
    if (p.revents & POLLOUT)
        return 1;
    return (p.revents & (POLLERR | POLLHUP)) ? -ECONNREFUSED : 0;
}

static sl_until sl_he_min(sl_until a, sl_until b) {
    if (a == 0) return b;
    if (b == 0) return a;
    return a < b ? a : b;
}

/* Connect to host:port. Returns the fd, or -1 with *err: an errno, -2 for
 * the deadline, EINTR for an interrupted park, or -3 with *gai set to a
 * resolver error code. */
static int sl_net_dial_fd(const char *host, int port, sl_until u, int *err,
                          int *gai) {
    char portstr[16];
    sl_rt_preempt_disable();
    snprintf(portstr, sizeof(portstr), "%d", port);
    sl_rt_preempt_enable();
    struct addrinfo *res = NULL;
    /* An IP literal needs no resolver: getaddrinfo with AI_NUMERICHOST
       answers on this thread, without the resolver thread's queue and
       wake-up -- and without AI_ADDRCONFIG, which on some systems
       refuses "::1" on a host with no global IPv6 address. */
    struct in6_addr lit6;
    struct in_addr lit4;
    if (inet_pton(AF_INET, host, &lit4) == 1 ||
        inet_pton(AF_INET6, host, &lit6) == 1) {
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_NUMERICHOST;
        int rc = getaddrinfo(host, portstr, &hints, &res);
        if (rc != 0 || !res) { *gai = rc; *err = -3; return -1; }
    } else {
        int timed_out = 0;
        int rc = sl_dns_lookup_family_until(host, portstr, AF_UNSPEC, &res,
                                            u, &timed_out);
        if (timed_out) { *err = -2; return -1; }
        if (rc != 0 || !res) { *gai = rc; *err = -3; return -1; }
    }
    if (u && sl_until_hit(u)) { freeaddrinfo(res); *err = -2; return -1; }

    /* interleave the families, keeping each family's own order */
    struct addrinfo *order[SL_HE_MAX];
    int n = 0;
    struct addrinfo *a1 = res, *a2 = NULL;
    int fam1 = res->ai_family;
    for (struct addrinfo *a = res; a; a = a->ai_next)
        if (a->ai_family != fam1) { a2 = a; break; }
    while ((a1 || a2) && n < SL_HE_MAX) {
        while (a1 && a1->ai_family != fam1) a1 = a1->ai_next;
        if (a1) { order[n++] = a1; a1 = a1->ai_next; }
        while (a2 && a2->ai_family == fam1) a2 = a2->ai_next;
        if (a2 && n < SL_HE_MAX) { order[n++] = a2; a2 = a2->ai_next; }
    }

    int fds[SL_HE_MAX];
    int nf = 0, next = 0, last = ECONNREFUSED;
    long long started = 0;
    int winner = -1;
    while (winner < 0) {
        if (next < n && (nf == 0 || sl_now_ns() >= started + SL_HE_DELAY_NS)) {
            struct addrinfo *a = order[next++];
            int fd = socket(a->ai_family, SOCK_STREAM, 0);
            if (fd < 0) { last = errno; continue; }
            sl_net_set_nonblocking(fd);
            if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) {
                winner = fd;
                break;
            }
            if (errno != EINPROGRESS && errno != EAGAIN) {
                last = errno;
                close(fd);
                continue;
            }
            fds[nf++] = fd;
            started = sl_now_ns();
        }
        if (nf == 0) {
            if (next >= n) break;          /* every address refused */
            continue;
        }
        /* Park on the newest attempt until the next one is due (or, with
           every address started, briefly, to look at the others too). */
        sl_until wake = u;
        if (next < n)
            wake = sl_he_min(u, sl_until_of(started + SL_HE_DELAY_NS));
        else if (nf > 1)
            wake = sl_he_min(u, sl_until_of(sl_now_ns() + SL_HE_RECHECK_NS));
        int w = sl_reactor_wait_until(fds[nf - 1], SL_REACTOR_WRITE, 1, wake);
        if (w < 0 && w != -2) {
            for (int i = 0; i < nf; i++) close(fds[i]);
            freeaddrinfo(res);
            *err = EINTR;
            return -1;
        }
        if (w == -2 && u && sl_until_hit(u)) {
            for (int i = 0; i < nf; i++) close(fds[i]);
            freeaddrinfo(res);
            *err = -2;
            return -1;
        }
        for (int i = 0; i < nf;) {
            int st = sl_he_state(fds[i]);
            if (st == 1) {
                winner = fds[i];
                fds[i] = fds[--nf];
                break;
            }
            if (st < 0) {
                last = -st;
                close(fds[i]);
                fds[i] = fds[--nf];
                continue;
            }
            i++;
        }
    }
    for (int i = 0; i < nf; i++)
        close(fds[i]);
    freeaddrinfo(res);
    if (winner < 0) { *err = last; return -1; }
    sl_reactor_mark_persistent(winner);
    return winner;
}

/* net.dial / net.dial_until: the deadline, when set, covers the lookup
 * and every attempt together. */
static sl_res_i32_str *sl_net_dial_u(const char *host, int port, sl_until u) {
    int err = 0, gai = 0;
    int fd = sl_net_dial_fd(host, port, u, &err, &gai);
    if (fd >= 0) return sl_net_ok_i32((int32_t)fd);
    if (err == -2) return sl_net_err_i32("timeout");
    if (err == -3) return sl_net_err_i32(gai_strerror(gai));
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
    sl_rt_preempt_disable();
    sl_reactor_clear_closing(fd);   /* as in sl_net_listen_reuse */
    sl_rt_preempt_enable();
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
    int epoch = sl_reactor_close_epoch(fd);
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
           at 100% CPU. Only a deadline or a close ends the loop; -1 is
           the shutdown nudge and is ignored exactly as before. */
        int w = sl_reactor_wait_epoch(fd, SL_REACTOR_WRITE, 0, u, epoch);
        if (w == -2)
            return sl_net_err_i32("timeout");
        if (w == SL_REACTOR_CLOSED)
            return sl_net_err_i32("closed");
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
    int epoch = sl_reactor_close_epoch(fd);
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
        int wr = sl_reactor_wait_epoch(fd, SL_REACTOR_READ, 1, u, epoch);
        if (wr < 0) {
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes(wr == -2 ? "timeout"
                                    : wr == SL_REACTOR_CLOSED ? "closed"
                                                              : "interrupted");
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

/* A task parked on fd is woken with "closed", and so is one that has seen
 * EAGAIN but not yet parked: its park finds the close count moved on. One
 * whose syscall itself runs after the close still hits a free number
 * (EBADF) or a reused one; only a handle that is not the number (sl_link)
 * or a per-fd reference count, as Go's fdMutex, ends that. */
static void sl_net_close(int fd) {
    sl_net_user_nonblock_remove((void *)(intptr_t)fd); /* avoid a
        stale entry misapplying to a later, unrelated fd that
        happens to reuse the same number. */
    sl_rt_preempt_disable();
    sl_task *ready = NULL;
    sl_reactor_take_closed(fd, &ready);
    sl_reactor_forget(fd);
    close(fd);
    /* Listeners and connected sockets clear the flag when they are made.
       Any other fd net ops are used on (a pipe handed to net.recv), begun
       on this number in the moment between close(2) returning and this,
       reads "closed". */
    sl_reactor_clear_closing(fd);
    sl_reactor_resume_all(ready);
    sl_rt_preempt_enable();
}

static sl_res_bool_str *sl_net_nonblock(int fd) {
    /* fd is already non-blocking at the OS level internally (every
       fd is, now) -- this call's real job is opting IN to the
       synchronous "would block" contract instead of parking, which
       is what the side-table actually tracks. */
    sl_net_user_nonblock_insert((void *)(intptr_t)fd);
    return sl_net_ok_bool(true);
}

/* ---- UDP ---------------------------------------------------------------
 *
 * Datagram sockets on the same fds and reactor as TCP. A peer address is
 * an opaque value: the raw sockaddr (sockaddr_in or sockaddr_in6) as
 * bytes. recv_from hands it back and send_to takes it as is, so replying
 * to a sender never resolves a name or formats a string; net.udp_addr
 * resolves one ahead of time and net.addr_str prints it. The layout is
 * this process's own (BSD sockaddrs carry a length byte), so it is not
 * for storing or sending elsewhere. */

#define SL_UDP_MAX 65535 /* the largest datagram: recv_from's default size */

typedef struct {
    struct sockaddr_storage ss;
    socklen_t len;
} sl_udp_addr;

/* host as an IP literal ("" is any IPv4 address) into a, or -1. */
static int sl_udp_parse_ip(const char *host, int port, sl_udp_addr *a) {
    memset(a, 0, sizeof(*a));
    if (port < 0 || port > 65535)
        return -1;
    if (!strchr(host, ':')) {
        struct sockaddr_in *v4 = (struct sockaddr_in *)&a->ss;
        v4->sin_family = AF_INET;
        v4->sin_port = htons((uint16_t)port);
        if (host[0] == '\0')
            v4->sin_addr.s_addr = htonl(INADDR_ANY);
        else if (inet_pton(AF_INET, host, &v4->sin_addr) != 1)
            return -1;
        a->len = sizeof(struct sockaddr_in);
        return 0;
    }
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&a->ss;
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons((uint16_t)port);
    if (inet_pton(AF_INET6, host, &v6->sin6_addr) != 1)
        return -1;
    a->len = sizeof(struct sockaddr_in6);
    return 0;
}

/* An IP literal as is, anything else through the resolver (IPv4, like
 * net.dial), bounded by u. Returns 0, -1 with *msg set, or -2 for the
 * deadline. */
static int sl_udp_resolve(const char *host, int port, sl_until u,
                          sl_udp_addr *a, const char **msg) {
    if (port < 0 || port > 65535) {
        *msg = "port out of range";
        return -1;
    }
    if (sl_udp_parse_ip(host, port, a) == 0)
        return 0;
    char portstr[16];
    sl_rt_preempt_disable();
    snprintf(portstr, sizeof(portstr), "%d", port);
    sl_rt_preempt_enable();
    struct addrinfo *res = NULL;
    int timed_out = 0;
    int rc = sl_dns_lookup_until(host, portstr, &res, u, &timed_out);
    if (timed_out)
        return -2;
    if (rc != 0 || !res) {
        *msg = gai_strerror(rc);
        return -1;
    }
    memset(a, 0, sizeof(*a));
    memcpy(&a->ss, res->ai_addr, res->ai_addrlen);
    a->len = (socklen_t)res->ai_addrlen;
    freeaddrinfo(res);
    return 0;
}

static sl_bytes *sl_udp_addr_bytes(const struct sockaddr_storage *ss,
                                   socklen_t len) {
    sl_bytes *b = sl_bytes_alloc_uninit(len);
    memcpy(b->ptr, ss, len);
    return b;
}

/* An address from net.udp_addr / recv_from back into a, or -1. */
static int sl_udp_addr_of(sl_bytes *b, sl_udp_addr *a) {
    if (!b || (b->len != (long long)sizeof(struct sockaddr_in) &&
               b->len != (long long)sizeof(struct sockaddr_in6)))
        return -1;
    memset(a, 0, sizeof(*a));
    memcpy(&a->ss, b->ptr, (size_t)b->len);
    a->len = (socklen_t)b->len;
    int fam = ((struct sockaddr *)&a->ss)->sa_family;
    if ((fam == AF_INET && a->len != sizeof(struct sockaddr_in)) ||
        (fam == AF_INET6 && a->len != sizeof(struct sockaddr_in6)) ||
        (fam != AF_INET && fam != AF_INET6))
        return -1;
    return 0;
}

/* A new non-blocking datagram socket the reactor can park on. */
static int sl_udp_socket(int family, int *err) {
    int fd = socket(family, SOCK_DGRAM, 0);
    if (fd < 0) { *err = errno; return -1; }
    sl_net_set_nonblocking(fd);
    return fd;
}

static sl_res_i32_str *sl_udp_ready(int fd) {
    sl_rt_preempt_disable();
    sl_reactor_clear_closing(fd);
    sl_rt_preempt_enable();
    sl_reactor_mark_persistent(fd);
    return sl_net_ok_i32((int32_t)fd);
}

static sl_res_i32_str *sl_udp_bind_opt(const char *host, int port,
                                       int shared) {
    sl_udp_addr a;
    if (sl_udp_parse_ip(host, port, &a) != 0)
        return sl_net_err_i32(port < 0 || port > 65535
                                  ? "port out of range"
                                  : "udp_bind: host must be an IP address or \"\"");
    int e = 0;
    int fd = sl_udp_socket(a.ss.ss_family, &e);
    if (fd < 0) return sl_net_err_i32(strerror(e));
    if (shared) {
        /* Several sockets on one port: multicast listeners, or one
           socket per core with the kernel spreading datagrams. */
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_REUSEPORT
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#endif
    }
    if (bind(fd, (struct sockaddr *)&a.ss, a.len) != 0) {
        e = errno; close(fd);
        return sl_net_err_i32(strerror(e));
    }
    return sl_udp_ready(fd);
}

static sl_res_i32_str *sl_net_udp_bind(const char *host, int port) {
    return sl_udp_bind_opt(host, port, 0);
}

static sl_res_i32_str *sl_net_udp_bind_shared(const char *host, int port) {
    return sl_udp_bind_opt(host, port, 1);
}

/* A connected datagram socket: net.send and net.recv work on it and the
 * kernel drops datagrams from any other sender. */
static sl_res_i32_str *sl_net_udp_dial(const char *host, int port,
                                       sl_until u) {
    sl_udp_addr a;
    const char *msg = "";
    int rc = sl_udp_resolve(host, port, u, &a, &msg);
    if (rc == -2) return sl_net_err_i32("timeout");
    if (rc != 0) return sl_net_err_i32(msg);
    int e = 0;
    int fd = sl_udp_socket(a.ss.ss_family, &e);
    if (fd < 0) return sl_net_err_i32(strerror(e));
    /* connect on a datagram socket only records the peer: it never
       blocks, so there is nothing to park on */
    if (connect(fd, (struct sockaddr *)&a.ss, a.len) != 0) {
        e = errno; close(fd);
        return sl_net_err_i32(strerror(e));
    }
    return sl_udp_ready(fd);
}

static sl_res_bytes_str *sl_net_udp_addr(const char *host, int port,
                                         sl_until u) {
    sl_udp_addr a;
    const char *msg = "";
    int rc = sl_udp_resolve(host, port, u, &a, &msg);
    if (rc == -2) return sl_net_err_bytes("timeout");
    if (rc != 0) return sl_net_err_bytes(msg);
    return sl_net_ok_bytes(sl_udp_addr_bytes(&a.ss, a.len));
}

/* "1.2.3.4:53" or "[::1]:53"; "" for bytes that are no address. */
static const char *sl_net_addr_str(sl_bytes *b) {
    sl_udp_addr a;
    if (sl_udp_addr_of(b, &a) != 0)
        return "";
    char ip[INET6_ADDRSTRLEN];
    char out[INET6_ADDRSTRLEN + 10];
    sl_rt_preempt_disable();
    if (a.ss.ss_family == AF_INET) {
        struct sockaddr_in *v4 = (struct sockaddr_in *)&a.ss;
        inet_ntop(AF_INET, &v4->sin_addr, ip, sizeof(ip));
        snprintf(out, sizeof(out), "%s:%u", ip, ntohs(v4->sin_port));
    } else {
        struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&a.ss;
        inet_ntop(AF_INET6, &v6->sin6_addr, ip, sizeof(ip));
        snprintf(out, sizeof(out), "[%s]:%u", ip, ntohs(v6->sin6_port));
    }
    sl_rt_preempt_enable();
    return sl_strdup(out);
}

/* One datagram to addr. A datagram goes whole or not at all, so the
 * count is always len(data). EAGAIN (a full socket buffer) parks. */
static sl_res_i32_str *sl_net_send_to_u(int fd, sl_bytes *data, sl_bytes *to,
                                        sl_until u) {
    sl_udp_addr a;
    if (sl_udp_addr_of(to, &a) != 0)
        return sl_net_err_i32("send_to: not an address from udp_addr or recv_from");
    if (u && sl_until_hit(u))
        return sl_net_err_i32("timeout");
    int epoch = sl_reactor_close_epoch(fd);
    for (;;) {
        ssize_t n = sendto(fd, data->ptr, (size_t)data->len, 0,
                           (struct sockaddr *)&a.ss, a.len);
        if (n >= 0)
            return sl_net_ok_i32((int32_t)n);
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != ENOBUFS)
            return sl_net_err_i32(strerror(errno));
        if (sl_net_user_nonblock_contains((void *)(intptr_t)fd))
            return sl_net_err_i32("would block");
        int w = sl_reactor_wait_epoch(fd, SL_REACTOR_WRITE, 0, u, epoch);
        if (w == -2)
            return sl_net_err_i32("timeout");
        if (w == SL_REACTOR_CLOSED)
            return sl_net_err_i32("closed");
    }
}

static sl_res_i32_str *sl_net_send_to(int fd, sl_bytes *data, sl_bytes *to) {
    return sl_net_send_to_u(fd, data, to, 0);
}

static sl_res_i32_str *sl_net_send_to_until(int fd, sl_bytes *data,
                                            sl_bytes *to, sl_until u) {
    return sl_net_send_to_u(fd, data, to, u);
}

static sl_res__bytes__str *sl_net_dgram_err(const char *msg) {
    sl_res__bytes__str *r = (sl_res__bytes__str *)sl_gc_alloc(
        sizeof(sl_res__bytes__str), sl_gc_trace_sl_res__bytes__str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* One datagram as [data, sender]. A datagram longer than max is an error
 * ("truncated"), not a silent cut: the rest is gone either way, and a
 * DNS client, say, must know to retry over TCP. Allocation happens only
 * once the datagram is in (sl_net_recv_bytes says why). */
static sl_res__bytes__str *sl_net_recv_from_u(int fd, int max, sl_until u) {
    if (u && sl_until_hit(u))
        return sl_net_dgram_err("timeout");
    if (max <= 0 || max > SL_UDP_MAX) max = SL_UDP_MAX;
    unsigned char *scratch = (unsigned char *)sl_recv_buf_get((size_t)max);
    int epoch = sl_reactor_close_epoch(fd);
    for (;;) {
        struct sockaddr_storage from;
        struct iovec iov = {scratch, (size_t)max};
        struct msghdr mh;
        memset(&mh, 0, sizeof(mh));
        mh.msg_name = &from;
        mh.msg_namelen = sizeof(from);
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        ssize_t n = recvmsg(fd, &mh, 0);
        if (n >= 0) {
            if (mh.msg_flags & MSG_TRUNC) {
                sl_recv_buf_put(scratch);
                return sl_net_dgram_err("truncated");
            }
            sl_bytes *data = sl_net_recv_bytes(scratch, (long long)n);
            sl_recv_buf_put(scratch);
            sl_bytes *addr = sl_udp_addr_bytes(&from, mh.msg_namelen);
            sl_arr *pair = sl_arr_new(sizeof(sl_bytes *), 1);
            sl_arr_push(pair, &data, sizeof(sl_bytes *));
            sl_arr_push(pair, &addr, sizeof(sl_bytes *));
            sl_res__bytes__str *r = (sl_res__bytes__str *)sl_gc_alloc(
                sizeof(sl_res__bytes__str), sl_gc_trace_sl_res__bytes__str);
            r->ok = true;
            r->v = pair;
            return r;
        }
        if (errno == EINTR)
            continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            int e = errno;
            sl_recv_buf_put(scratch);
            return sl_net_dgram_err(strerror(e));
        }
        if (sl_net_user_nonblock_contains((void *)(intptr_t)fd)) {
            sl_recv_buf_put(scratch);
            return sl_net_dgram_err("would block");
        }
        int wr = sl_reactor_wait_epoch(fd, SL_REACTOR_READ, 1, u, epoch);
        if (wr < 0) {
            sl_recv_buf_put(scratch);
            return sl_net_dgram_err(wr == -2 ? "timeout"
                                    : wr == SL_REACTOR_CLOSED ? "closed"
                                                              : "interrupted");
        }
    }
}

static sl_res__bytes__str *sl_net_recv_from(int fd, int max) {
    return sl_net_recv_from_u(fd, max, 0);
}

static sl_res__bytes__str *sl_net_recv_from_until(int fd, int max,
                                                  sl_until u) {
    return sl_net_recv_from_u(fd, max, u);
}

/* Join or leave multicast group `group` on interface `iface` ("" lets the
 * kernel choose), IPv4 or IPv6 by the group's form. */
static sl_res_bool_str *sl_udp_membership(int fd, const char *group,
                                          const char *iface, int join) {
    struct in_addr g4;
    struct in6_addr g6;
    unsigned idx = 0;
    if (iface[0] != '\0') {
        idx = if_nametoindex(iface);
        if (idx == 0)
            return sl_net_err_bool("unknown interface");
    }
    if (inet_pton(AF_INET, group, &g4) == 1) {
        struct ip_mreq m;
        memset(&m, 0, sizeof(m));
        m.imr_multiaddr = g4;
        m.imr_interface.s_addr = htonl(INADDR_ANY);
        if (idx != 0) {
            /* IPv4 names the interface by an address; ip_mreqn takes an
               index but is Linux-only */
#ifdef __linux__
            struct ip_mreqn mn;
            memset(&mn, 0, sizeof(mn));
            mn.imr_multiaddr = g4;
            mn.imr_ifindex = (int)idx;
            if (setsockopt(fd, IPPROTO_IP,
                           join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP,
                           &mn, sizeof(mn)) != 0)
                return sl_net_err_bool(strerror(errno));
            return sl_net_ok_bool(true);
#else
            return sl_net_err_bool("udp_join: an IPv4 interface by name needs Linux; pass \"\"");
#endif
        }
        if (setsockopt(fd, IPPROTO_IP,
                       join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP, &m,
                       sizeof(m)) != 0)
            return sl_net_err_bool(strerror(errno));
        return sl_net_ok_bool(true);
    }
    if (inet_pton(AF_INET6, group, &g6) == 1) {
        struct ipv6_mreq m;
        memset(&m, 0, sizeof(m));
        m.ipv6mr_multiaddr = g6;
        m.ipv6mr_interface = idx;
        if (setsockopt(fd, IPPROTO_IPV6,
                       join ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP, &m,
                       sizeof(m)) != 0)
            return sl_net_err_bool(strerror(errno));
        return sl_net_ok_bool(true);
    }
    return sl_net_err_bool("not a multicast group address");
}

static sl_res_bool_str *sl_net_udp_join(int fd, const char *group,
                                        const char *iface) {
    return sl_udp_membership(fd, group, iface, 1);
}

static sl_res_bool_str *sl_net_udp_leave(int fd, const char *group,
                                         const char *iface) {
    return sl_udp_membership(fd, group, iface, 0);
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
/* The peer's certificate chain as concatenated DER (link.peer_certs). */
static sl_bytes *(*sl_link_tls_peer_certs_fn)(sl_link *l);

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
            sl_reactor_mark_persistent(cfd);
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
    int err = 0, gai = 0;
    int fd = sl_net_dial_fd(host, (int)port, u, &err, &gai);
    if (fd >= 0)
        return sl_link_ok_link(sl_link_from_fd(fd));
    if (err == -2)
        return sl_link_err_link(sl_fault_op(SL_FAULT_TIMEOUT, 0, "connect"));
    if (err == -3)
        return sl_link_err_link(sl_fault_op(SL_FAULT_REFUSED, gai, "dial"));
    if (err == EINTR)
        return sl_link_err_link(sl_fault_op(SL_FAULT_CLOSED, 0, "connect"));
    return sl_link_err_link(sl_link_fault_op("connect", err));
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
    sl_reactor_mark_persistent(d);
    sl_link w = sl_link_from_fd(d);
    w.role = SL_LINK_WRITER;
    if (l->tls)
        sl_link_tls_share_fn(l, &w);
    l->role = SL_LINK_READER;
    return sl_link_ok_link(w);
}

/* The TLS peer's certificate chain, leaf first, as concatenated DER for
 * x509.parse_der; empty on a link without TLS or a peer that sent none.
 * A link only carries a session once sl_tls.c has set the hook. */
static sl_bytes *sl_link_peer_certs(sl_link *l) {
    if (!l || !l->live || !l->tls || !sl_link_tls_peer_certs_fn)
        return sl_bytes_new(NULL, 0);
    return sl_link_tls_peer_certs_fn(l);
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
