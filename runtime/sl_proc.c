#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <fcntl.h>
#if defined(__APPLE__)
#include <sys/event.h>
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

static sl_res_int_str *sl_proc_spawn(sl_arr *argv_arr, sl_arr *env_arr, const char *dir, int flags) {
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
    if (env_arr && env_arr->len > 0) {
        int envc = (int)env_arr->len;
        const char **env_items = (const char **)env_arr->data;
        envp = (char **)malloc((size_t)(envc + 1) * sizeof(char *));
        if (!envp) {
            free(argv);
            sl_rt_preempt_enable();
            return sl_proc_err_int("proc.spawn: out of memory");
        }
        for (int i = 0; i < envc; i++) {
            envp[i] = (char *)env_items[i];
        }
        envp[envc] = NULL;
    } else {
        envp = (char **)malloc(sizeof(char *));
        if (!envp) {
            free(argv);
            sl_rt_preempt_enable();
            return sl_proc_err_int("proc.spawn: out of memory");
        }
        envp[0] = NULL;
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
    free(envp);

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

    if (c->exit_fd >= 0) {
        sl_rt_preempt_enable();
        int wr = sl_reactor_wait_until(c->exit_fd, SL_REACTOR_READ, 0, deadline);
        sl_rt_preempt_disable();

        if (wr == -2) {
            sl_rt_preempt_enable();
            return sl_proc_err_int("timeout");
        }

        r = waitpid(pid, &status, WNOHANG);
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

