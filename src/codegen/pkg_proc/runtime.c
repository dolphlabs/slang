/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "../internal.h"

/* ---- native 'proc' package runtime (emitted on demand) ----
 * Tier 11 sixth slice: graceful shutdown is now delivered via a
 * dedicated sigwait() thread, not a sigaction-installed handler. The
 * old design relied on leaving exactly one OS thread (main's own)
 * unblocked and getting EINTR on whatever blocking net.accept()/recv()
 * call happened to be running there -- correct only as long as main's
 * own task could never migrate to a different OS thread. Once chan/
 * time.sleep parking made that migration possible (Tier 11 fourth/
 * fifth slices), the invariant broke: main's original thread could end
 * up idle-in-the-pool while a DIFFERENT thread runs main's resumed
 * task, with no guarantee that thread has these signals unblocked.
 * The fix: block SIGTERM/SIGINT everywhere (main()'s own top-level
 * code, program.c, blocks them once before any thread is ever
 * created, so every subsequently-created thread -- pool workers, the
 * timer thread, the reactor thread, and this signal thread itself --
 * inherits the blocked mask automatically) and have exactly one
 * dedicated thread block on sigwait() for them, decoupling delivery
 * from OS-thread identity entirely -- it doesn't matter which thread
 * happens to be running which task, since the signal never lands on
 * any of them. This is also what makes net.*'s own parking (this same
 * slice) able to preserve its shutdown-interruption behavior: the
 * signal thread nudges sl_rt_shutdown_hook (runtime_core.c), which the
 * reactor sets to its own wake-everyone-currently-parked function, if
 * 'net' is imported. */
const char *PROC_RUNTIME[] = {
    "#include <signal.h>",
    "",
    "static void *sl_sig_thread(void *arg) {",
    "    (void)arg;",
    "    sigset_t mask;",
    "    sigemptyset(&mask);",
    "    sigaddset(&mask, SIGTERM);",
    "    sigaddset(&mask, SIGINT);",
    "    for (;;) {",
    "        int sig;",
    "        sigwait(&mask, &sig);",
    "        atomic_store_explicit(&sl_rt_shutdown_flag, 1, memory_order_release);",
    "        if (sl_rt_shutdown_hook) sl_rt_shutdown_hook(); /* unconditional --",
    "            no compile-time knowledge of which packages registered a",
    "            hook, see runtime_core.c's own comment on it */",
    "    }",
    "    return NULL; /* unreachable -- runs until process exit */",
    "}",
    "",
    "static void sl_proc_install_signal_handlers(void) {",
    "    pthread_t th;",
    "    if (pthread_create(&th, NULL, sl_sig_thread, NULL) != 0) {",
    "        fprintf(stderr, \"slang: failed to start signal thread\\n\");",
    "        exit(1);",
    "    }",
    "}",
    "",
    "static bool sl_proc_shutdown_requested(void) {",
    "    return atomic_load_explicit(&sl_rt_shutdown_flag, memory_order_acquire) != 0;",
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
