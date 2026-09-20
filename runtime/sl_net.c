#include <errno.h>
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
    fprintf(stderr, "slang-reactor-stat parks=%llu wakes=%llu\n", parks,
            wakes);
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
static pthread_mutex_t sl_reactor_mu = PTHREAD_MUTEX_INITIALIZER;
static sl_task *sl_reactor_waiting = NULL; /* linked via sl_task.next,
    guarded by sl_reactor_mu -- same reuse-`next`-for-one-wait-list-
    at-a-time pattern chan/time already establish */
static long long sl_reactor_wake_at = 0; /* absolute mono-ns the
    reactor's CURRENT sleep is due to end, or 0 for an indefinite
    sleep. Guarded by sl_reactor_mu. Lets a registering waiter skip
    the timer nudge when the reactor is already going to wake soon
    enough to see it -- see sl_reactor_timer_nudge. */

#define SL_REACTOR_READ  0
#define SL_REACTOR_WRITE 1
#define SL_REACTOR_SHUTDOWN_IDENT 0xDEADBEEF
#define SL_REACTOR_TIMER_IDENT    0xDEADBEEE

/* The reactor computes how long to sleep from the deadlines already on
 * sl_reactor_waiting, and only then blocks. A task that registers a
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
    (void)write(sl_reactor_timer_efd, &one, sizeof(one));
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
static void sl_reactor_expire_waiters(void) {
    long long now = sl_now_ns();
    sl_task **pp = &sl_reactor_waiting;
    while (*pp) {
        sl_task *t = *pp;
        if (t->io_deadline_ns && t->io_deadline_ns <= now) {
            *pp = t->next;
            t->next = NULL;
            sl_task_resume(t);
            continue;
        }
        pp = &t->next;
    }
}

static void sl_reactor_kick(void) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_reactor_mu);
    sl_task *w;
    while ((w = sl_reactor_waiting)) {
        sl_reactor_waiting = w->next;
        w->next = NULL;
        sl_task_resume(w);
    }
    pthread_mutex_unlock(&sl_reactor_mu);
    sl_rt_preempt_enable();
}

static int sl_reactor_wait_until(int fd, int rw, int abort_on_shutdown,
                                 sl_until deadline) {
    if (deadline && sl_until_hit(deadline))
        return -2;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_reactor_mu);
    if (abort_on_shutdown &&
        atomic_load_explicit(&sl_rt_shutdown_flag, memory_order_acquire)) {
        pthread_mutex_unlock(&sl_reactor_mu);
        sl_rt_preempt_enable();
        return -1;
    }
    sl_task *sl_reactor_self = sl_rt_cur();
    sl_reactor_self->io_deadline_ns = deadline;
    sl_reactor_self->next = sl_reactor_waiting;
    sl_reactor_waiting = sl_reactor_self;
    sl_reactor_shard_count(sl_reactor_shard_for(fd), 0);
#if defined(SL_REACTOR_KQUEUE)
    struct kevent kev;
    EV_SET(&kev, fd, rw == SL_REACTOR_READ ? EVFILT_READ : EVFILT_WRITE,
           EV_ADD | EV_ONESHOT, 0, 0, (void *)sl_reactor_self);
    kevent(sl_reactor_fd, &kev, 1, NULL, 0, NULL);
#else
    struct epoll_event ev;
    ev.events = (rw == SL_REACTOR_READ ? EPOLLIN : EPOLLOUT) | EPOLLONESHOT;
    ev.data.ptr = sl_reactor_self;
    if (epoll_ctl(sl_reactor_fd, EPOLL_CTL_ADD, fd, &ev) != 0 &&
        errno == EEXIST)
        epoll_ctl(sl_reactor_fd, EPOLL_CTL_MOD, fd, &ev);
#endif
    /* After EV_ADD, before parking, and still under sl_reactor_mu: the
       reactor must recompute its sleep with this waiter included --
       see sl_reactor_timer_nudge for why nothing else would ever wake
       it. Skipped when the reactor is already due to wake at or before
       this deadline, which is the common case once a server has more
       than one deadline-bearing connection, and saves a syscall on
       every park. */
    if (deadline && (sl_reactor_wake_at == 0 ||
                     sl_reactor_wake_at > deadline))
        sl_reactor_timer_nudge();
    sl_task_park(&sl_reactor_mu);
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

static void *sl_reactor_thread(void *arg) {
    (void)arg;
#if defined(SL_REACTOR_KQUEUE)
    struct kevent events[64];
#else
    struct epoll_event events[64];
#endif
    for (;;) {
        long long soonest = -1;
        pthread_mutex_lock(&sl_reactor_mu);
        {
            sl_task *w;
            long long now = sl_now_ns();
            for (w = sl_reactor_waiting; w; w = w->next) {
                if (!w->io_deadline_ns)
                    continue;
                long long rem = w->io_deadline_ns - now;
                if (rem < 0)
                    rem = 0;
                if (soonest < 0 || rem < soonest)
                    soonest = rem;
            }
            /* Published to would-be nudgers while still holding the
               lock, and read by them under the same lock -- that
               ordering is what makes the nudge skippable. If a
               registration wins the lock first, this computation
               already includes it; if it loses, it reads a value that
               provably does NOT account for it and decides from that.
               Publishing after the unlock would leave the window where
               a registration reads the PREVIOUS round's wake time,
               concludes "the reactor will wake in time", and is then
               overwritten by an indefinite sleep. */
            sl_reactor_wake_at = soonest < 0 ? 0 : now + soonest;
        }
        pthread_mutex_unlock(&sl_reactor_mu);
#if defined(SL_REACTOR_KQUEUE)
        struct timespec ts, *tsp = NULL;
        if (soonest >= 0) {
            ts.tv_sec = (time_t)(soonest / 1000000000LL);
            ts.tv_nsec = (long)(soonest % 1000000000LL);
            tsp = &ts;
        }
        int n = kevent(sl_reactor_fd, NULL, 0, events, 64, tsp);
#else
        int timeout = soonest < 0 ? -1 : (int)(soonest / 1000000LL);
        int n = epoll_wait(sl_reactor_fd, events, 64, timeout);
#endif
        if (n < 0) { if (errno == EINTR) continue; continue; }
        pthread_mutex_lock(&sl_reactor_mu);
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
            sl_task *t = is_shutdown ? NULL : (sl_task *)events[i].udata;
#else
            if (events[i].data.ptr == &sl_reactor_timer_token) {
                uint64_t tx;
                (void)read(sl_reactor_timer_efd, &tx, sizeof(tx));
                continue;
            }
            int is_shutdown = events[i].data.ptr == &sl_reactor_shutdown_token;
            sl_task *t = is_shutdown ? NULL : (sl_task *)events[i].data.ptr;
            if (is_shutdown) {
                uint64_t x;
                (void)read(sl_reactor_efd, &x, sizeof(x));
            }
#endif
            if (is_shutdown) {
                sl_task *w;
                while ((w = sl_reactor_waiting)) {
                    sl_reactor_waiting = w->next;
                    w->next = NULL;
                    sl_task_resume(w);
                }
                continue;
            }
            /* only resume if the removal actually found t on the
               list -- it may already be gone if a shutdown drain
               (above, same batch) already resumed it, e.g. the
               shutdown EVFILT_USER event and this fd's own readiness
               event landing in the same kevent() batch. Resuming
               unconditionally here would double-push t onto
               sl_global_runq -- found and fixed during this slice's
               own design review. */
            sl_task **pp = &sl_reactor_waiting;
            int found = 0;
            while (*pp) { if (*pp == t) { *pp = t->next; found = 1; break; } pp = &(*pp)->next; }
            if (found) {
                t->next = NULL;
                sl_task_resume(t);
            }
        }
        sl_reactor_expire_waiters();
        pthread_mutex_unlock(&sl_reactor_mu);
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
    (void)write(sl_reactor_efd, &one, sizeof(one));
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
    char *host;
    char portstr[16];
    struct addrinfo hints;
    int rc;
    struct addrinfo *res;
    int wake_wr;
    _Atomic int state;
} sl_dns_job;

static pthread_mutex_t sl_dns_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sl_dns_cv = PTHREAD_COND_INITIALIZER;
static sl_dns_job *sl_dns_head;
static sl_dns_job *sl_dns_tail;

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
        j->rc = getaddrinfo(j->host, j->portstr, &j->hints, &j->res);
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
            (void)write(wake_wr, &x, 1);
            close(wake_wr);
        } else {
            /* the caller gave up; nobody else will ever look at this */
            if (j->rc == 0 && j->res)
                freeaddrinfo(j->res);
            close(j->wake_wr);
            free(j->host);
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
    sl_reactor_efd = eventfd(0, EFD_CLOEXEC);
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
    sl_reactor_timer_efd = eventfd(0, EFD_CLOEXEC);
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

static void sl_net_recv_copy(sl_bytes *b, unsigned char *scratch, long long n) {
    if (n > 0) {
        b->ptr = (unsigned char *)sl_gc_alloc((size_t)n, NULL);
        memcpy(b->ptr, scratch, (size_t)n);
    }
    b->len = n;
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
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    void *_sl_rcv_roots[] = { (void *)b };
    sl_safepoint _sl_rcv_sp;
    sl_rt_safepoint_enter(&_sl_rcv_sp, _sl_rcv_roots, 1); /* stays
        entered across any parking below -- composes correctly with
        a park+resume for the same reason it already composes with
        stack growth: it resolves through
        sl_rt_current_task->safepoint_top, not anything thread-local.
        See the Tier 10 comment this replaces for why b needs its own
        bracket at all (a hand-written runtime function, not codegen
        output, so the caller's own bracket was built before b even
        existed). */
    for (;;) {
        ssize_t n = recv(fd, scratch, (size_t)max, 0);
        if (n >= 0) {
            sl_net_recv_copy(b, scratch, (long long)n);
            sl_rt_safepoint_exit();
            sl_recv_buf_put(scratch);
            return sl_net_ok_bytes(b);
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            sl_rt_safepoint_exit();
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes(strerror(errno));
        }
        if (sl_net_user_nonblock_contains((void *)(intptr_t)fd)) {
            sl_rt_safepoint_exit();
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes("would block");
        }
        int wr = sl_reactor_wait_until(fd, SL_REACTOR_READ, 1, u);
        if (wr < 0) {
            sl_rt_safepoint_exit();
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

static sl_res_int_fault sl_link_send_ptr(sl_link *l, const unsigned char *ptr,
                                         long long len, sl_until u) {
    long long off = 0;
    if (!l || !l->live)
        return sl_link_err_int(sl_fault_op(SL_FAULT_CLOSED, 0, "send"));
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
    if (w.len <= 0)
        return sl_link_ok_int(0);
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

