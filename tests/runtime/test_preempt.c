/* The preemption signal's kernel frame must never land on a task stack.
 *
 * On x86_64 the async trampoline's last instruction is
 * `jmp *-136(%rsp)`, with %rsp already back at the interrupted value: the
 * resume target sits 8 bytes below the 128-byte red zone the kernel skips
 * when it builds a signal frame on the current stack. On Darwin the word
 * the kernel writes there is &uc->uc_mcontext, so a SIGUSR1 landing on
 * that one instruction boundary replaced the resume target with a pointer
 * into the frame, and the jmp faulted on the task's own stack (SIGBUS,
 * pc == fault address). The handler runs on a per-thread alternate stack
 * now (SA_ONSTACK), so nothing below a task's sp is ever written.
 *
 * This checks the disposition the runtime installs, then delivers SIGUSR1
 * with exactly those flags to a thread spinning with a sentinel at
 * -136(%rsp) -- the slot the trampoline jumps through -- and requires the
 * sentinel to survive. Without SA_ONSTACK it is overwritten on every
 * delivery, so the result does not depend on timing. */

static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#undef main

#define SL_TP_SENTINEL 0x5afe5afe5afe5afeULL

static volatile int sl_tp_ready = 0;
static volatile int sl_tp_seen = 0;
static volatile unsigned long long sl_tp_after = 0;

static void sl_tp_on_signal(int sig, siginfo_t *si, void *uc) {
    (void)sig; (void)si; (void)uc;
    sl_tp_seen = 1;
}

#if defined(__x86_64__)
static void *sl_tp_thread(void *arg) {
    (void)arg;
    sl_rt_install_altstack(); /* as every task-running thread does */
    /* 256 bytes below the compiler's frame so the sentinel sits in
     * scratch space; the loop touches no stack, so the only possible
     * writer of -136(%rsp) is the kernel delivering the signal. */
    __asm__ volatile(
        "subq $256, %%rsp\n\t"
        "movabsq $0x5afe5afe5afe5afe, %%rax\n\t"
        "movq %%rax, -136(%%rsp)\n\t"
        "movl $1, %[ready]\n\t"
        "1:\n\t"
        "pause\n\t"
        "cmpl $0, %[seen]\n\t"
        "je 1b\n\t"
        "movq -136(%%rsp), %%rax\n\t"
        "movq %%rax, %[after]\n\t"
        "addq $256, %%rsp\n\t"
        : [ready] "=m"(sl_tp_ready), [after] "=m"(sl_tp_after)
        : [seen] "m"(sl_tp_seen)
        : "rax", "memory", "cc");
    return NULL;
}
#endif

static int sl_runtime_test_main(void) {
    int fail = 0;
    sl_preempt_install_handlers();
    struct sigaction cur;
    if (sigaction(SIGUSR1, NULL, &cur) != 0) {
        fprintf(stderr, "FAIL: cannot read the SIGUSR1 disposition\n");
        return 1;
    }
    if (!(cur.sa_flags & SA_ONSTACK)) {
        fprintf(stderr, "FAIL: preempt handler installed without SA_ONSTACK\n");
        fail = 1;
    }
    sl_rt_install_altstack();
    stack_t ss;
    if (sigaltstack(NULL, &ss) != 0 || (ss.ss_flags & SS_DISABLE)) {
        fprintf(stderr, "FAIL: no alternate signal stack after sl_rt_install_altstack\n");
        fail = 1;
    }
#if defined(__x86_64__)
    struct sigaction probe = cur;
    probe.sa_sigaction = sl_tp_on_signal;
    if (sigaction(SIGUSR1, &probe, NULL) != 0) {
        fprintf(stderr, "FAIL: cannot install the probe handler\n");
        return 1;
    }
    pthread_t th;
    if (pthread_create(&th, NULL, sl_tp_thread, NULL) != 0) {
        fprintf(stderr, "FAIL: cannot start the probe thread\n");
        return 1;
    }
    while (!sl_tp_ready)
        sched_yield();
    pthread_kill(th, SIGUSR1);
    pthread_join(th, NULL);
    sigaction(SIGUSR1, &cur, NULL);
    if (sl_tp_after != SL_TP_SENTINEL) {
        fprintf(stderr,
                "FAIL: signal frame overwrote the trampoline resume slot "
                "(-136(%%rsp) = %#llx)\n",
                (unsigned long long)sl_tp_after);
        fail = 1;
    }
#endif
    return fail;
}

int main(void) {
    return sl_runtime_test_main();
}
