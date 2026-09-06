#include <signal.h>

static void *sl_sig_thread(void *arg) {
    (void)arg;
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    for (;;) {
        int sig;
        sigwait(&mask, &sig);
        atomic_store_explicit(&sl_rt_shutdown_flag, 1, memory_order_release);
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
    return (long long)atomic_load(&sl_rt_active_spawns);
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

