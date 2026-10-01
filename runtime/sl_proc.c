#include <errno.h>
#include <signal.h>
#include <unistd.h>

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

