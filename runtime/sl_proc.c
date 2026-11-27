#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <fcntl.h>
#include <sys/resource.h>
#if defined(__APPLE__)
#include <sys/event.h>
#include <mach/mach.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#ifndef SYS_pidfd_open
#if defined(__x86_64__)
#define SYS_pidfd_open 434
#elif defined(__aarch64__)
#define SYS_pidfd_open 434
#elif defined(__i386__)
#define SYS_pidfd_open 434
#elif defined(__arm__)
#define SYS_pidfd_open 434
#endif
#endif
#endif

/* Started only in a program that calls proc.shutdown_requested() (see
 * main() in the generated C): SIGTERM/SIGINT are blocked in every thread
 * and arrive here. The first one requests a graceful shutdown. A second
 * one ends the process the way the signal would have, so a drain that
 * never finishes -- or a program that stopped polling -- cannot make it
 * unkillable short of SIGKILL. */
static void *sl_sig_thread(void *arg) {
    (void)arg;
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    for (;;) {
        int sig;
        if (sigwait(&mask, &sig) != 0)
            continue;
        if (atomic_exchange_explicit(&sl_rt_shutdown_flag, 1,
                                     memory_order_acq_rel)) {
            /* Unblocked in this thread only, then raised to it: the
             * current disposition runs -- the default terminates, and
             * io's raw-mode hook restores the terminal before it does. */
            sigset_t one;
            sigemptyset(&one);
            sigaddset(&one, sig);
            pthread_sigmask(SIG_UNBLOCK, &one, NULL);
            raise(sig);
            _exit(128 + sig); /* only if a handler returned */
        }
        if (sl_rt_shutdown_hook) sl_rt_shutdown_hook(); /* unconditional --
            no compile-time knowledge of which packages registered a
            hook, see runtime_core.c's own comment on it */
    }
    return NULL; /* unreachable -- runs until process exit */
}

static void sl_proc_install_signal_handlers(void) {
    pthread_t th;
    if (sl_rt_thread_spawn(&th, sl_sig_thread, NULL) != 0) {
        fprintf(stderr, "slang: failed to start signal thread\n");
        exit(1);
    }
}

static bool sl_proc_shutdown_requested(void) {
    return atomic_load_explicit(&sl_rt_shutdown_flag, memory_order_acquire) != 0;
}

static long long sl_proc_active_tasks(void) {
    return sl_rt_active_others();
}

static void sl_proc_wait_idle(void) {
    sl_rt_wait_idle();
}

/* proc.wait_idle bounded by u: whether the program went idle (the same
 * test as wait_idle) before the deadline. It looks every 5 ms, parking on
 * a pipe nothing writes to as its timer: a drain is rare and short, and
 * this keeps wait_idle's own lock-step wake-up untouched. */
static bool sl_proc_wait_idle_until(sl_until u) {
    static int tick_rd = -1;
    for (;;) {
        long long others = atomic_load(&sl_rt_active_spawns) -
                           atomic_load(&sl_rt_idle_spawned_waiters);
        if (sl_rt_cur_is_spawned())
            others--;
        if (others <= 0)
            return true;
        if (u && sl_until_hit(u))
            return false;
        if (tick_rd < 0) {
            int p[2];
            sl_rt_preempt_disable();
            if (pipe(p) == 0) {
                fcntl(p[0], F_SETFD, FD_CLOEXEC);
                fcntl(p[1], F_SETFD, FD_CLOEXEC);
                fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL, 0) | O_NONBLOCK);
                tick_rd = p[0]; /* p[1] stays open, so p[0] never reads EOF */
            }
            sl_rt_preempt_enable();
            if (tick_rd < 0)
                return others <= 0;
        }
        sl_until step = sl_until_of(sl_now_ns() + 5000000LL);
        if (u && u < step)
            step = u;
        (void)sl_reactor_wait_until(tick_rd, SL_REACTOR_READ, 0, step);
    }
}

static int sl_proc_argc;
static char **sl_proc_argv;

static sl_arr *sl_proc_args(void) {
    sl_arr *a = sl_arr_new(sizeof(char *), 1);
    for (int i = 0; i < sl_proc_argc; i++) {
        char *s = sl_strdup(sl_proc_argv[i]);
        sl_arr_push(a, &s, sizeof(char *));
    }
    return a;
}

static sl_res_str_str *sl_proc_ok_str(char *v) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_str_str *sl_proc_err_str(const char *msg) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_str_str *sl_proc_cwd(void) {
    size_t cap = 256;
    for (;;) {
        char *buf = (char *)malloc(cap);
        if (!buf)
            return sl_proc_err_str("getcwd: out of memory");
        if (getcwd(buf, cap)) {
            char *s = sl_strdup(buf);
            free(buf);
            return sl_proc_ok_str(s);
        }
        int e = errno;
        free(buf);
        if (e != ERANGE)
            return sl_proc_err_str(strerror(e));
        if (cap > (size_t)1 << 20)
            return sl_proc_err_str("getcwd: path too long");
        cap *= 2;
    }
}

static sl_opt_str *sl_proc_getenv(const char *name) {
    sl_opt_str *o = (sl_opt_str *)sl_gc_alloc(sizeof(sl_opt_str),
                                              sl_gc_trace_sl_opt_str);
    const char *v = getenv(name);
    if (!v) {
        o->has = false;
        return o;
    }
    o->has = true;
    o->v = sl_strdup(v);
    return o;
}

static sl_res_int_str *sl_proc_ok_int(long long v) {
    sl_res_int_str *r = (sl_res_int_str *)sl_gc_alloc(
        sizeof(sl_res_int_str), sl_gc_trace_sl_res_int_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_int_str *sl_proc_err_int(const char *msg) {
    sl_res_int_str *r = (sl_res_int_str *)sl_gc_alloc(
        sizeof(sl_res_int_str), sl_gc_trace_sl_res_int_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_bool_str *sl_proc_ok_bool(bool v) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_bool_str *sl_proc_err_bool(const char *msg) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

typedef struct sl_child {
    pid_t pid;
    int flags;
    int exit_fd;
    _Atomic int reaped;
    int status;
    struct sl_child *next;
} sl_child;

static sl_child *sl_proc_children = NULL;
static pthread_mutex_t sl_proc_children_mu = PTHREAD_MUTEX_INITIALIZER;

#define SL_SPAWN_MAX_FDS 64

/* LISTEN_FDS and its companions, which a handed-off child must not see
   from this process's own environment (a stale count, or another
   process's pid). */
static int sl_proc_is_listen_var(const char *kv) {
    return !strncmp(kv, "LISTEN_FDS=", 11) || !strncmp(kv, "LISTEN_PID=", 11) ||
           !strncmp(kv, "LISTEN_FDNAMES=", 15);
}

static sl_res_int_str *sl_proc_spawn_impl(sl_arr *argv_arr, sl_arr *env_arr,
                                          const char *dir, int flags,
                                          sl_arr *fds_arr);

static sl_res_int_str *sl_proc_spawn(sl_arr *argv_arr, sl_arr *env_arr, const char *dir, int flags) {
    return sl_proc_spawn_impl(argv_arr, env_arr, dir, flags, NULL);
}

/* proc.spawn that also passes fds to the child as 3, 4, ... and sets
 * LISTEN_FDS to their count: the systemd socket-activation convention,
 * which net.inherited() reads. Used to hand listening sockets to a new
 * version of a server so it accepts on the same ports with no gap. */
static sl_res_int_str *sl_proc_spawn_fds(sl_arr *argv_arr, sl_arr *env_arr,
                                         const char *dir, int flags,
                                         sl_arr *fds_arr) {
    if (!fds_arr || fds_arr->len == 0)
        return sl_proc_err_int("proc.spawn_fds: no fds to pass");
    if (fds_arr->len > SL_SPAWN_MAX_FDS)
        return sl_proc_err_int("proc.spawn_fds: more than 64 fds");
    const int32_t *fds = (const int32_t *)fds_arr->data;
    for (long long i = 0; i < fds_arr->len; i++) {
        if (fds[i] < 0 || fcntl(fds[i], F_GETFD) < 0)
            return sl_proc_err_int("proc.spawn_fds: not an open fd");
    }
    return sl_proc_spawn_impl(argv_arr, env_arr, dir, flags, fds_arr);
}

static sl_res_int_str *sl_proc_spawn_impl(sl_arr *argv_arr, sl_arr *env_arr,
                                          const char *dir, int flags,
                                          sl_arr *fds_arr) {
    if (!argv_arr || argv_arr->len == 0)
        return sl_proc_err_int("proc.spawn: argv cannot be empty");

    const char **items = (const char **)argv_arr->data;
    if (!items || !items[0] || items[0][0] == '\0')
        return sl_proc_err_int("proc.spawn: argv[0] cannot be empty");

    sl_rt_preempt_disable();

    int argc = (int)argv_arr->len;
    char **argv = (char **)malloc((size_t)(argc + 1) * sizeof(char *));
    if (!argv) {
        sl_rt_preempt_enable();
        return sl_proc_err_int("proc.spawn: out of memory");
    }
    for (int i = 0; i < argc; i++) {
        argv[i] = (char *)items[i];
    }
    argv[argc] = NULL;

    char **envp = NULL;
    int free_envp = 0;
    int nfds = fds_arr ? (int)fds_arr->len : 0;
    char listen_fds[32];
    if (env_arr && env_arr->len > 0) {
        int envc = (int)env_arr->len;
        const char **env_items = (const char **)env_arr->data;
        envp = (char **)malloc((size_t)(envc + 2) * sizeof(char *));
        if (!envp) {
            free(argv);
            sl_rt_preempt_enable();
            return sl_proc_err_int("proc.spawn: out of memory");
        }
        int k = 0;
        for (int i = 0; i < envc; i++) {
            if (nfds > 0 && sl_proc_is_listen_var(env_items[i]))
                continue;
            envp[k++] = (char *)env_items[i];
        }
        envp[k] = NULL;
        free_envp = 1;
    } else {
        extern char **environ;
        envp = environ;
        if (nfds > 0) {
            int envc = 0;
            while (environ[envc]) envc++;
            envp = (char **)malloc((size_t)(envc + 2) * sizeof(char *));
            if (!envp) {
                free(argv);
                sl_rt_preempt_enable();
                return sl_proc_err_int("proc.spawn: out of memory");
            }
            int k = 0;
            for (int i = 0; i < envc; i++)
                if (!sl_proc_is_listen_var(environ[i]))
                    envp[k++] = environ[i];
            envp[k] = NULL;
            free_envp = 1;
        }
    }
    if (nfds > 0) {
        int k = 0;
        while (envp[k]) k++;
        snprintf(listen_fds, sizeof(listen_fds), "LISTEN_FDS=%d", nfds);
        envp[k] = listen_fds;
        envp[k + 1] = NULL;
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    short sflags = 0;

    sigset_t no_signals;
    sigemptyset(&no_signals);
    posix_spawnattr_setsigmask(&attr, &no_signals);
    sflags |= POSIX_SPAWN_SETSIGMASK;

    sigset_t default_signals;
    sigfillset(&default_signals);
    posix_spawnattr_setsigdefault(&attr, &default_signals);
    sflags |= POSIX_SPAWN_SETSIGDEF;

    if (flags & 1) { // SPAWN_GROUP = 1
#if defined(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setpgroup(&attr, 0);
        sflags |= POSIX_SPAWN_SETPGROUP;
#endif
    }
    posix_spawnattr_setflags(&attr, sflags);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    if (flags & 2) { // SPAWN_NULL_STDIN = 2
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    }

    if (nfds > 0) {
        /* Into 3, 4, ... by way of numbers above them all, so a source
           that is also a target (fd 4 to 3 while fd 3 goes to 4) is not
           overwritten before it is copied. dup2 clears close-on-exec on
           the copy, so exactly these reach the child. */
        const int32_t *fds = (const int32_t *)fds_arr->data;
        int base = 3 + nfds;
        for (int i = 0; i < nfds; i++)
            if (fds[i] >= base) base = fds[i] + 1;
        for (int i = 0; i < nfds; i++)
            posix_spawn_file_actions_adddup2(&actions, fds[i], base + i);
        for (int i = 0; i < nfds; i++)
            posix_spawn_file_actions_adddup2(&actions, base + i, 3 + i);
        for (int i = 0; i < nfds; i++)
            posix_spawn_file_actions_addclose(&actions, base + i);
    }

    if (dir && dir[0] != '\0') {
#if defined(__APPLE__) || (defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 29)))
        posix_spawn_file_actions_addchdir_np(&actions, dir);
#endif
    }

    pid_t pid = 0;
    int err = posix_spawnp(&pid, argv[0], &actions, &attr, argv, envp);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    free(argv);
    if (free_envp) free(envp);

    if (err != 0) {
        sl_rt_preempt_enable();
        return sl_proc_err_int(strerror(err));
    }

    int exit_fd = -1;
#if defined(__APPLE__)
    int kq = kqueue();
    if (kq >= 0) {
        fcntl(kq, F_SETFD, FD_CLOEXEC);
        struct kevent kev;
        EV_SET(&kev, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        int kr = kevent(kq, &kev, 1, NULL, 0, NULL);
        if (kr < 0 && errno == ESRCH) {
            close(kq);
            kq = -1;
        } else {
            exit_fd = kq;
        }
    }
#elif defined(__linux__) && defined(SYS_pidfd_open)
    int pfd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (pfd >= 0) {
        fcntl(pfd, F_SETFD, FD_CLOEXEC);
        exit_fd = pfd;
    }
#endif

    sl_child *c = (sl_child *)malloc(sizeof(sl_child));
    if (c) {
        c->pid = pid;
        c->flags = flags;
        c->exit_fd = exit_fd;
        c->reaped = 0;
        c->status = 0;
        pthread_mutex_lock(&sl_proc_children_mu);
        c->next = sl_proc_children;
        sl_proc_children = c;
        pthread_mutex_unlock(&sl_proc_children_mu);
    }

    sl_rt_preempt_enable();
    return sl_proc_ok_int((long long)pid);
}

/* Resident set size now, in bytes; 0 if the system will not say. */
static long long sl_proc_rss_now(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t n = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                  &n) != KERN_SUCCESS)
        return 0;
    return (long long)info.resident_size;
#elif defined(__linux__)
    char buf[128];
    int fd = open("/proc/self/statm", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    ssize_t r = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (r <= 0)
        return 0;
    buf[r] = 0;
    long long pages_total = 0, pages_res = 0;
    if (sscanf(buf, "%lld %lld", &pages_total, &pages_res) != 2)
        return 0;
    return pages_res * (long long)sysconf(_SC_PAGESIZE);
#else
    return 0;
#endif
}

/* proc.runtime_stats: the runtime's counters, in a fixed order the
 * `runtime` package names (stdlib/runtime). */
static sl_arr *sl_proc_runtime_stats(void) {
    long long v[10];
    v[0] = (long long)atomic_load_explicit(&sl_gc_rt_majors, memory_order_relaxed);
    v[1] = (long long)atomic_load_explicit(&sl_gc_minors_done, memory_order_relaxed);
    v[2] = (long long)atomic_load_explicit(&sl_gc_rt_pause_ns_total, memory_order_relaxed);
    v[3] = (long long)atomic_load_explicit(&sl_gc_rt_pause_ns_max, memory_order_relaxed);
    v[4] = (long long)atomic_load_explicit(&sl_gc_rt_live_bytes, memory_order_relaxed);
    v[5] = (long long)atomic_load_explicit(&sl_gc_bytes_since_collect, memory_order_relaxed);
    sl_rt_preempt_disable();
    v[6] = sl_proc_rss_now();
    struct rusage ru;
    long long peak = 0;
    if (getrusage(RUSAGE_SELF, &ru) == 0) {
#if defined(__APPLE__)
        peak = (long long)ru.ru_maxrss;          /* bytes on macOS */
#else
        peak = (long long)ru.ru_maxrss * 1024;   /* kilobytes on Linux */
#endif
    }
    sl_rt_preempt_enable();
    v[7] = peak;
    v[8] = (long long)atomic_load(&sl_rt_active_spawns);
    v[9] = (long long)sl_pool_nworkers;
    sl_arr *a = sl_arr_new(sizeof(long long), SL_ELEM_NOPTR);
    for (int i = 0; i < 10; i++)
        sl_arr_push(a, &v[i], sizeof(long long));
    return a;
}

static char *sl_prof_take_cstr(char *buf) {
    char *s = sl_strdup(buf ? buf : "");
    free(buf);
    return s;
}

static char *sl_proc_task_dump(void) {
    char *buf = NULL;
    size_t len = 0;
    sl_rt_format_tasks(&buf, &len);
    return sl_prof_take_cstr(buf);
}

static char *sl_proc_cpu_profile(long long duration_ms) {
    char *buf = NULL;
    size_t len = 0;
    sl_prof_cpu_sample(duration_ms, &buf, &len);
    return sl_prof_take_cstr(buf);
}

static char *sl_proc_heap_profile(void) {
    sl_rt_preempt_disable();
    long long rss = sl_proc_rss_now();
    struct rusage ru;
    long long peak = 0;
    if (getrusage(RUSAGE_SELF, &ru) == 0) {
#if defined(__APPLE__)
        peak = (long long)ru.ru_maxrss;
#else
        peak = (long long)ru.ru_maxrss * 1024;
#endif
    }
    sl_rt_preempt_enable();
    char *buf = NULL;
    size_t len = 0;
    sl_prof_heap_format((long)sl_pool_nworkers, rss, peak, &buf, &len);
    return sl_prof_take_cstr(buf);
}

static sl_res_bool_str *sl_proc_kill(long long pid, int sig) {
    if (pid == 0)
        return sl_proc_err_bool("proc.kill: invalid pid 0");

    sl_rt_preempt_disable();
    int is_group = 0;
    if (pid > 0) {
        pthread_mutex_lock(&sl_proc_children_mu);
        for (sl_child *c = sl_proc_children; c; c = c->next) {
            if (c->pid == (pid_t)pid) {
                if (c->flags & 1) is_group = 1;
                break;
            }
        }
        pthread_mutex_unlock(&sl_proc_children_mu);
    }

    pid_t target = (is_group || pid < 0) ? -(pid_t)(pid < 0 ? -pid : pid) : (pid_t)pid;
    int rc = kill(target, sig);
    int e = errno;
    sl_rt_preempt_enable();

    if (rc != 0)
        return sl_proc_err_bool(strerror(e));
    return sl_proc_ok_bool(true);
}

static sl_res_int_str *sl_proc_wait(long long pid_val, sl_until deadline) {
    if (pid_val <= 0)
        return sl_proc_err_int("proc.wait: invalid pid");

    pid_t pid = (pid_t)pid_val;
    sl_rt_preempt_disable();

    pthread_mutex_lock(&sl_proc_children_mu);
    sl_child *c = NULL;
    for (sl_child *cur = sl_proc_children; cur; cur = cur->next) {
        if (cur->pid == pid) {
            c = cur;
            break;
        }
    }
    pthread_mutex_unlock(&sl_proc_children_mu);

    if (c && c->reaped) {
        sl_rt_preempt_enable();
        return sl_proc_ok_int(c->status);
    }

    int status = 0;
    pid_t r = waitpid(pid, &status, WNOHANG);
    if (r == pid) {
        int ret = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : status);
        if (c) {
            c->reaped = 1;
            c->status = ret;
            if (c->exit_fd >= 0) {
                close(c->exit_fd);
                c->exit_fd = -1;
            }
        }
        sl_rt_preempt_enable();
        return sl_proc_ok_int(ret);
    }

    if (!c) {
        sl_rt_preempt_enable();
        return sl_proc_err_int("proc.wait: no such child process");
    }

    if (deadline && sl_until_hit(deadline)) {
        sl_rt_preempt_enable();
        return sl_proc_err_int("timeout");
    }

    /* Parked on the child's exit pipe until it is readable -- but a wake is
     * not an exit: sl_reactor_kick wakes every parked task at shutdown
     * (SIGINT, SIGTERM) so that loops polling proc.shutdown_requested()
     * run, whatever their descriptors say. proc.wait used to take that
     * wake, find the child still running, and return "proc.wait: wait
     * failed"; zokor's watcher read the error as the server crashing,
     * forgot it, and left it running in its own process group when it
     * exited. So wait again until the child has exited or the deadline
     * passes. */
    if (c->exit_fd >= 0) {
        for (;;) {
            sl_rt_preempt_enable();
            int wr = sl_reactor_wait_until(c->exit_fd, SL_REACTOR_READ, 0, deadline);
            sl_rt_preempt_disable();

            if (wr == -2 || (deadline && sl_until_hit(deadline))) {
                sl_rt_preempt_enable();
                return sl_proc_err_int("timeout");
            }

            r = waitpid(pid, &status, WNOHANG);
            if (r == 0)
                continue; /* still running: woken, not exited */
            if (r == pid) {
                c->reaped = 1;
                c->status = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : status);
                if (c->exit_fd >= 0) {
                    close(c->exit_fd);
                    c->exit_fd = -1;
                }
                sl_rt_preempt_enable();
                return sl_proc_ok_int(c->status);
            }
            break; /* waitpid failed: reported below */
        }
    } else {
        sl_rt_preempt_enable();
        r = waitpid(pid, &status, 0);
        sl_rt_preempt_disable();
        if (r == pid) {
            c->reaped = 1;
            c->status = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : status);
            sl_rt_preempt_enable();
            return sl_proc_ok_int(c->status);
        }
    }

    sl_rt_preempt_enable();
    return sl_proc_err_int("proc.wait: wait failed");
}

