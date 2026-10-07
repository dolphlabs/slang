/* A crash must say what it was. A segfault used to end a slang program
 * with nothing on stderr (the api server's log in #325 was empty). The
 * runtime's fatal-signal handler writes the signal, the fault address and
 * the pc, then lets the process die of the same signal as before -- same
 * exit status, same core.
 *
 * Each case runs in a forked child with its stderr on a pipe: a real
 * fault (a store to address 16, which re-faults after the handler
 * restores the default action) and a signal sent with raise(), which
 * does not re-fault and must be raised again. Both children must print
 * the report and die of their signal. */

static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#undef main

#include <sys/wait.h>

static int sl_tf_case(int how, int want_sig, const char *want) {
    int fds[2];
    if (pipe(fds) != 0)
        return 1;
    pid_t pid = fork();
    if (pid < 0)
        return 1;
    if (pid == 0) {
        dup2(fds[1], 2);
        close(fds[0]);
        sl_rt_install_altstack();
        sl_rt_install_fatal_handlers();
        if (how == 0)
            *(volatile int *)(uintptr_t)16 = 1;
        else
            raise(SIGBUS);
        _exit(0); /* reached only if the signal did not kill us */
    }
    close(fds[1]);
    char out[512];
    size_t n = 0;
    ssize_t r;
    while (n + 1 < sizeof(out) && (r = read(fds[0], out + n, sizeof(out) - 1 - n)) > 0)
        n += (size_t)r;
    out[n] = 0;
    close(fds[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    if (!WIFSIGNALED(st) || WTERMSIG(st) != want_sig) {
        fprintf(stderr, "test_fatal: case %d: child did not die of signal %d (status %d)\n",
                how, want_sig, st);
        return 1;
    }
    if (!strstr(out, want)) {
        fprintf(stderr, "test_fatal: case %d: stderr lacks \"%s\": %s\n", how, want, out);
        return 1;
    }
    return 0;
}

static int sl_runtime_test_main(void) {
    int bad = 0;
    bad |= sl_tf_case(0, SIGSEGV, "slang: fatal SIGSEGV at address 0x0000000000000010, pc 0x");
    bad |= sl_tf_case(1, SIGBUS, "slang: fatal SIGBUS at address ");
    return bad;
}

int main(void) {
    return sl_runtime_test_main();
}
