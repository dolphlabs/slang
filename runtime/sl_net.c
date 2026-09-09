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
#endif
static pthread_mutex_t sl_reactor_mu = PTHREAD_MUTEX_INITIALIZER;
static sl_task *sl_reactor_waiting = NULL; /* linked via sl_task.next,
    guarded by sl_reactor_mu -- same reuse-`next`-for-one-wait-list-
    at-a-time pattern chan/time already establish */

#define SL_REACTOR_READ  0
#define SL_REACTOR_WRITE 1
#define SL_REACTOR_SHUTDOWN_IDENT 0xDEADBEEF

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
#if defined(SL_REACTOR_KQUEUE)
            int is_shutdown = events[i].filter == EVFILT_USER;
            sl_task *t = is_shutdown ? NULL : (sl_task *)events[i].udata;
#else
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

typedef struct sl_dns_job {
    struct sl_dns_job *next;
    char *host;
    char portstr[16];
    struct addrinfo hints;
    int rc;
    struct addrinfo *res;
    int wake_wr;
    _Atomic int done;
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
        atomic_store_explicit(&j->done, 1, memory_order_release);
        char x = 1;
        (void)write(j->wake_wr, &x, 1);
        close(j->wake_wr);
    }
    return NULL;
}

static int sl_dns_lookup(const char *host, const char *portstr,
                         struct addrinfo **res) {
    sl_dns_job job;
    memset(&job, 0, sizeof(job));
    size_t n = strlen(host) + 1;
    job.host = (char *)malloc(n);
    if (!job.host)
        return EAI_MEMORY;
    memcpy(job.host, host, n);
    sl_rt_preempt_disable();
    snprintf(job.portstr, sizeof(job.portstr), "%s", portstr);
    sl_rt_preempt_enable();
    job.hints.ai_family = AF_INET;
    job.hints.ai_socktype = SOCK_STREAM;
    atomic_store_explicit(&job.done, 0, memory_order_relaxed);
    int pfd[2];
    if (pipe(pfd) != 0) {
        free(job.host);
        return EAI_SYSTEM;
    }
    fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pfd[1], F_SETFD, FD_CLOEXEC);
    sl_net_set_nonblocking(pfd[0]);
    job.wake_wr = pfd[1];
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_dns_mu);
    job.next = NULL;
    if (sl_dns_tail)
        sl_dns_tail->next = &job;
    else
        sl_dns_head = &job;
    sl_dns_tail = &job;
    pthread_cond_signal(&sl_dns_cv);
    pthread_mutex_unlock(&sl_dns_mu);
    sl_rt_preempt_enable();
    for (;;) {
        sl_reactor_wait(pfd[0], SL_REACTOR_READ, 0);
        char x;
        ssize_t nr = read(pfd[0], &x, 1);
        if (nr == 1)
            break;
        if (nr < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            continue;
        break;
    }
    close(pfd[0]);
    int rc = atomic_load_explicit(&job.done, memory_order_acquire)
                 ? job.rc
                 : EAI_FAIL;
    *res = job.res;
    free(job.host);
    return rc;
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

static sl_res_i32_str *sl_net_listen_reuse(int port, int reuse_port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return sl_net_err_i32(strerror(errno));
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
        int e = errno; close(fd); return sl_net_err_i32(strerror(e));
    }
    if (listen(fd, 1024) != 0) {
        int e = errno; close(fd); return sl_net_err_i32(strerror(e));
    }
    sl_net_set_nonblocking(fd); /* net.accept's own park loop is what
        makes this transparent to callers that never call
        net.nonblock() themselves */
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

static sl_res_i32_str *sl_net_dial(const char *host, int port) {
    char portstr[16];
    sl_rt_preempt_disable();
    snprintf(portstr, sizeof(portstr), "%d", port);
    sl_rt_preempt_enable();
    struct addrinfo *res = NULL;
    int rc = sl_dns_lookup(host, portstr, &res);
    if (rc != 0 || !res) return sl_net_err_i32(gai_strerror(rc));
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return sl_net_err_i32(strerror(errno)); }
    sl_net_set_nonblocking(fd);
    int cres = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (cres == 0) return sl_net_ok_i32((int32_t)fd); /* connected
        immediately -- e.g. localhost */
    if (errno != EINPROGRESS) {
        int e = errno; close(fd); return sl_net_err_i32(strerror(e));
    }
    if (sl_reactor_wait(fd, SL_REACTOR_WRITE, 1) < 0) {
        close(fd); return sl_net_err_i32("interrupted");
    }
    int so_err = 0; socklen_t slen = sizeof(so_err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen); /* the
        standard, historically-recommended non-blocking-connect
        idiom: disambiguate write-readiness via SO_ERROR rather than
        inspecting which filter fired, avoiding older select()-based
        stacks' own readable/writable ambiguity on a failed connect */
    if (so_err != 0) { close(fd); return sl_net_err_i32(strerror(so_err)); }
    return sl_net_ok_i32((int32_t)fd);
}

static sl_res_i32_str *sl_net_send(int fd, sl_bytes *data) {
    long long off = 0;
    while (off < data->len) {
        ssize_t n = send(fd, data->ptr + off,
                         (size_t)(data->len - off), 0);
        if (n >= 0) { off += n; continue; }
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_net_err_i32(strerror(errno));
        if (sl_net_user_nonblock_contains((void *)(intptr_t)fd))
            return sl_net_err_i32("would block");
        sl_reactor_wait(fd, SL_REACTOR_WRITE, 0); /* return value
            deliberately ignored -- always keep retrying, even
            through a shutdown nudge, to let an in-flight write
            finish (tests/proc_shutdown's own requirement) -- see
            sl_reactor_wait's own comment for why abort_on_shutdown
            must be 0 here specifically, not 1 */
    }
    return sl_net_ok_i32((int32_t)data->len);
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

static sl_res_bytes_str *sl_net_recv(int fd, int max) {
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
        if (sl_reactor_wait(fd, SL_REACTOR_READ, 1) < 0) {
            sl_rt_safepoint_exit();
            sl_recv_buf_put(scratch);
            return sl_net_err_bytes("interrupted");
        }
    }
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
    sl_res_i32_str *r = sl_net_listen((int)port);
    if (!r->ok)
        return sl_link_err_link(sl_fault_op(SL_FAULT_IO, 0, "listen"));
    return sl_link_ok_link(sl_link_from_fd((int)r->v));
}

static sl_res_link_fault sl_link_listen_reuse(long long port, long long reuse) {
    sl_res_i32_str *r = sl_net_listen_reuse((int)port, reuse != 0);
    if (!r->ok)
        return sl_link_err_link(sl_fault_op(SL_FAULT_IO, 0, "listen"));
    return sl_link_ok_link(sl_link_from_fd((int)r->v));
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

