/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "../internal.h"

/* ---- native 'proc' package runtime (emitted on demand) ----
 * Graceful shutdown: sl_rt_shutdown_flag is set by a signal handler
 * installed WITHOUT SA_RESTART, so a blocked net.accept()/recv() on
 * the main thread returns an 'interrupted' error the instant SIGTERM/
 * SIGINT arrives, instead of hanging forever -- see ST_SPAWN's
 * codegen (src/codegen/stmt.c) for the other half of this: every
 * spawned worker thread has these signals blocked from birth, so the
 * OS can only ever choose the main thread to run this handler. */
const char *PROC_RUNTIME[] = {
    "#include <signal.h>",
    "",
    "static volatile sig_atomic_t sl_rt_shutdown_flag = 0;",
    "",
    "static void sl_rt_signal_handler(int signum) {",
    "    (void)signum;",
    "    sl_rt_shutdown_flag = 1;",
    "}",
    "",
    "static void sl_proc_install_signal_handlers(void) {",
    "    struct sigaction sa;",
    "    memset(&sa, 0, sizeof(sa));",
    "    sa.sa_handler = sl_rt_signal_handler;",
    "    sigemptyset(&sa.sa_mask);",
    "    sa.sa_flags = 0; /* no SA_RESTART -- see file comment above */",
    "    sigaction(SIGTERM, &sa, NULL);",
    "    sigaction(SIGINT, &sa, NULL);",
    "}",
    "",
    "static bool sl_proc_shutdown_requested(void) {",
    "    return sl_rt_shutdown_flag != 0;",
    "}",
    "",
    "static long long sl_proc_active_tasks(void) {",
    "    return (long long)atomic_load(&sl_rt_active_spawns);",
    "}",
    "",
    "static sl_opt_str *sl_proc_getenv(const char *name) {",
    "    sl_opt_str *o = (sl_opt_str *)sl_gc_alloc(sizeof(sl_opt_str),",
    "                                              sl_gc_trace_sl_opt_str);",
    "    const char *v = getenv(name);",
    "    if (!v) {",
    "        o->has = false;",
    "        return o;",
    "    }",
    "    o->has = true;",
    "    o->v = sl_strdup(v);",
    "    return o;",
    "}",
    "",
};

const int PROC_RUNTIME_LEN = sizeof(PROC_RUNTIME) / sizeof(PROC_RUNTIME[0]);
