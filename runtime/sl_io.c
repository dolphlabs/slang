#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

/* ---- io: the process's standard streams ------------------------------
 *
 * stdin is read through one process-wide buffer, so read_line and
 * read_all see the same stream and neither loses what the other
 * buffered. The read side has three jobs the raw fd could not do:
 *
 *  1. PARK, don't block. A blocking read(2) on a terminal holds a whole
 *     worker thread for as long as a person takes to type -- and in this
 *     runtime that froze every other task in the program (measured: two
 *     allocating tasks never finished while main sat in fs.read(0)).
 *     Where the fd can be polled (a terminal, a pipe, a socket) the task
 *     waits on the net reactor instead and only then calls read(2),
 *     which by then cannot block. A regular file or /dev/null never
 *     blocks and epoll refuses them (EPERM), so those are read directly;
 *     handing one to the reactor would park the task forever.
 *
 *  2. FLUSH first. print("name? ") leaves the prompt in stdout's buffer,
 *     and stdout is only line-buffered even on a terminal. libc flushes
 *     it automatically when you read through stdio; we read with read(2),
 *     so we do it ourselves before every wait.
 *
 *  3. Split lines. "\n" or "\r\n" ends one and is not returned. A final
 *     line with no terminator is still a line; end of input with nothing
 *     buffered is `none`. EOF is not sticky: on a terminal, Ctrl-D ends
 *     one read and the next call reads again, as in a shell.
 *
 * Concurrency: the buffer is guarded by a mutex held only for short,
 * allocation-free critical sections -- never across a wait or a GC
 * allocation (a collector waiting for this thread to reach a safepoint
 * while another thread holds the mutex and waits for the collector would
 * deadlock). Two tasks reading stdin at once are memory-safe but get
 * interleaved chunks; give stdin to one task.
 *
 * The buffer is malloc'd and capped, so unbounded input cannot exhaust
 * memory: a single line, or read_all's whole input, past the cap is an
 * error rather than an allocation. */

#define SL_IO_CHUNK 16384
#define SL_IO_MAX_BUFFERED (256LL * 1024 * 1024)

static pthread_mutex_t sl_io_mu = PTHREAD_MUTEX_INITIALIZER;
static unsigned char *sl_io_buf = NULL;
static size_t sl_io_pos = 0, sl_io_len = 0, sl_io_cap = 0;
/* Bytes after sl_io_pos already searched for a newline and found
 * none. Without this every new chunk of a long line rescans the whole
 * line so far, which is quadratic: one 300 MB line took minutes. */
static size_t sl_io_scanned = 0;

/* ---- result construction ---- */

static sl_res_opt_str__str *sl_io_res_line(char *s, bool present) {
    /* s (GC memory) is live across the opt allocation, and the opt
     * across the result's: root each so a collection in the next
     * allocation cannot take it. */
    sl_opt_str *o;
    {
        void *roots[] = { (void *)s };
        sl_safepoint sp;
        sl_rt_safepoint_enter(&sp, roots, 1);
        o = (sl_opt_str *)sl_gc_alloc(sizeof(sl_opt_str),
                                      sl_gc_trace_sl_opt_str);
        sl_rt_safepoint_exit();
    }
    o->has = present;
    o->v = present ? s : NULL;
    sl_res_opt_str__str *r;
    {
        void *roots[] = { (void *)o };
        sl_safepoint sp;
        sl_rt_safepoint_enter(&sp, roots, 1);
        r = (sl_res_opt_str__str *)sl_gc_alloc(
            sizeof(sl_res_opt_str__str), sl_gc_trace_sl_res_opt_str__str);
        sl_rt_safepoint_exit();
    }
    r->ok = true;
    r->v = o;
    return r;
}

static sl_res_opt_str__str *sl_io_err_line(const char *msg) {
    char *e = sl_strdup(msg);
    sl_res_opt_str__str *r;
    void *roots[] = { (void *)e };
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    r = (sl_res_opt_str__str *)sl_gc_alloc(
        sizeof(sl_res_opt_str__str), sl_gc_trace_sl_res_opt_str__str);
    sl_rt_safepoint_exit();
    r->ok = false;
    r->e = e;
    return r;
}

static sl_res_bytes_str *sl_io_ok_bytes(sl_bytes *b) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = true;
    r->v = b;
    return r;
}

static sl_res_bytes_str *sl_io_err_bytes(const char *msg) {
    char *e = sl_strdup(msg);
    sl_res_bytes_str *r;
    void *roots[] = { (void *)e };
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    r = (sl_res_bytes_str *)sl_gc_alloc(sizeof(sl_res_bytes_str),
                                        sl_gc_trace_sl_res_bytes_str);
    sl_rt_safepoint_exit();
    r->ok = false;
    r->e = e;
    return r;
}

/* ---- the buffer (caller holds sl_io_mu, preempt disabled) ---- */

static int sl_io_append_locked(const unsigned char *p, size_t n) {
    if (sl_io_pos == sl_io_len) {
        sl_io_pos = sl_io_len = 0; /* drained: start over */
        sl_io_scanned = 0;
    }
    size_t live = sl_io_len - sl_io_pos;
    if (live + n > (size_t)SL_IO_MAX_BUFFERED)
        return -1;
    if (sl_io_len + n > sl_io_cap && sl_io_pos > 0) {
        memmove(sl_io_buf, sl_io_buf + sl_io_pos, live);
        sl_io_pos = 0;
        sl_io_len = live;
    }
    if (sl_io_len + n > sl_io_cap) {
        size_t cap = sl_io_cap ? sl_io_cap : 65536;
        while (cap < sl_io_len + n)
            cap *= 2;
        unsigned char *nb = (unsigned char *)realloc(sl_io_buf, cap);
        if (!nb)
            return -1;
        sl_io_buf = nb;
        sl_io_cap = cap;
    }
    memcpy(sl_io_buf + sl_io_len, p, n);
    sl_io_len += n;
    return 0;
}

/* Take the next line out of the buffer into a malloc'd copy (GC memory
 * cannot be allocated under the mutex -- see the header). `final` also
 * accepts unterminated data as the last line.
 * Returns 1 with the line and its length set, 0 when there is no complete line, -1 on
 * out of memory. */
static int sl_io_take_line(int final, char **out, size_t *n) {
    int rc = 0;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_io_mu);
    size_t live = sl_io_len - sl_io_pos;
    unsigned char *nl = NULL;
    if (live > sl_io_scanned) {
        nl = (unsigned char *)memchr(sl_io_buf + sl_io_pos + sl_io_scanned,
                                     '\n', live - sl_io_scanned);
        if (!nl)
            sl_io_scanned = live;
    }
    if (nl || (final && live)) {
        size_t take = nl ? (size_t)(nl - (sl_io_buf + sl_io_pos)) : live;
        char *copy = (char *)malloc(take + 1);
        if (copy) {
            memcpy(copy, sl_io_buf + sl_io_pos, take);
            *out = copy;
            *n = take;
            sl_io_pos += take + (nl ? 1 : 0);
            sl_io_scanned = 0;
            rc = 1;
        } else {
            rc = -1;
        }
    }
    pthread_mutex_unlock(&sl_io_mu);
    sl_rt_preempt_enable();
    return rc;
}

/* ---- filling it ---- */

/* Whether waiting on the reactor can work for this fd. */
static int sl_io_pollable(int fd) {
    struct stat st;
    int r;
    sl_rt_preempt_disable();
    r = fstat(fd, &st) == 0 &&
        (S_ISFIFO(st.st_mode) || S_ISSOCK(st.st_mode) || isatty(fd));
    sl_rt_preempt_enable();
    return r;
}

static char sl_io_err[128];

/* Read once from stdin into the buffer. 1 = more data, 0 = end of
 * input, -1 = failure (message in sl_io_err, which is racy under
 * concurrent readers -- it is only ever a strerror text), -2 = the
 * deadline `u` (absolute; 0 for none) passed with nothing to read. The
 * deadline only bounds the wait on a pollable fd; a file never waits. */
static int sl_io_fill_until(sl_until u) {
    sl_rt_preempt_disable();
    fflush(stdout);
    sl_rt_preempt_enable();

    unsigned char *chunk = (unsigned char *)malloc(SL_IO_CHUNK);
    if (!chunk) {
        snprintf(sl_io_err, sizeof(sl_io_err), "out of memory");
        return -1;
    }
    for (;;) {
        if (sl_io_pollable(0)) {
            int w = sl_reactor_wait_until(0, SL_REACTOR_READ, 1, u);
            if (w == -2) {
                free(chunk);
                return -2;
            }
            if (w < 0) {
                free(chunk);
                snprintf(sl_io_err, sizeof(sl_io_err), "interrupted");
                return -1;
            }
        }
        sl_rt_preempt_disable();
        ssize_t n = read(0, chunk, SL_IO_CHUNK);
        int e = errno;
        sl_rt_preempt_enable();
        if (n > 0) {
            int rc;
            sl_rt_preempt_disable();
            pthread_mutex_lock(&sl_io_mu);
            rc = sl_io_append_locked(chunk, (size_t)n);
            pthread_mutex_unlock(&sl_io_mu);
            sl_rt_preempt_enable();
            free(chunk);
            if (rc != 0) {
                snprintf(sl_io_err, sizeof(sl_io_err),
                         "stdin: more than %lld MiB buffered without "
                         "reaching the end of the line or of the input",
                         SL_IO_MAX_BUFFERED / (1024 * 1024));
                return -1;
            }
            return 1;
        }
        if (n == 0) {
            free(chunk);
            return 0;
        }
        if (e == EINTR)
            continue;
        if (e == EAGAIN || e == EWOULDBLOCK) {
            /* someone made fd 0 non-blocking (it is shared with the
               parent shell): wait for it, on this thread */
            struct pollfd p = { 0, POLLIN, 0 };
            sl_rt_preempt_disable();
            poll(&p, 1, -1);
            sl_rt_preempt_enable();
            continue;
        }
        free(chunk);
        snprintf(sl_io_err, sizeof(sl_io_err), "%s", strerror(e));
        return -1;
    }
}

static int sl_io_fill(void) {
    return sl_io_fill_until(0);
}

/* ---- the API ---- */

/* One line from stdin without its "\n" (or "\r\n"). none = end of
 * input. */
static sl_res_opt_str__str *sl_io_read_line(void) {
    for (;;) {
        char *line = NULL;
        size_t n = 0;
        int got = sl_io_take_line(0, &line, &n);
        if (got < 0)
            return sl_io_err_line("out of memory");
        if (got == 0) {
            int rc = sl_io_fill();
            if (rc < 0)
                return sl_io_err_line(sl_io_err);
            if (rc > 0)
                continue;
            /* end of input: a last line with no terminator still counts */
            got = sl_io_take_line(1, &line, &n);
            if (got < 0)
                return sl_io_err_line("out of memory");
            if (got == 0)
                return sl_io_res_line(NULL, false);
        }
        if (n > 0 && line[n - 1] == '\r')
            n--;
        char *s = (char *)sl_gc_alloc(n + 1, NULL);
        memcpy(s, line, n);
        s[n] = '\0';
        sl_rt_preempt_disable();
        free(line);
        sl_rt_preempt_enable();
        return sl_io_res_line(s, true);
    }
}

/* Everything until end of input, as bytes. */
static sl_res_bytes_str *sl_io_read_all(void) {
    for (;;) {
        int rc = sl_io_fill();
        if (rc < 0)
            return sl_io_err_bytes(sl_io_err);
        if (rc == 0)
            break;
    }
    unsigned char *copy;
    size_t n;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_io_mu);
    n = sl_io_len - sl_io_pos;
    copy = (unsigned char *)malloc(n ? n : 1);
    if (copy && n)
        memcpy(copy, sl_io_buf + sl_io_pos, n);
    if (copy) {
        sl_io_pos = sl_io_len = 0;
        sl_io_scanned = 0;
    }
    pthread_mutex_unlock(&sl_io_mu);
    sl_rt_preempt_enable();
    if (!copy)
        return sl_io_err_bytes("out of memory");
    sl_bytes *b = sl_bytes_new(copy, (long long)n);
    sl_rt_preempt_disable();
    free(copy);
    sl_rt_preempt_enable();
    return sl_io_ok_bytes(b);
}

/* stderr is unbuffered, so these appear immediately; one fprintf keeps a
 * line from being split by another thread's write. */
static void sl_io_eprint(const char *s) {
    sl_rt_preempt_disable();
    fprintf(stderr, "%s", s ? s : "");
    sl_rt_preempt_enable();
}

static void sl_io_eprintln(const char *s) {
    sl_rt_preempt_disable();
    fprintf(stderr, "%s\n", s ? s : "");
    sl_rt_preempt_enable();
}

static void sl_io_flush(void) {
    sl_rt_preempt_disable();
    fflush(stdout);
    sl_rt_preempt_enable();
}

static bool sl_io_is_tty(int32_t fd) {
    sl_rt_preempt_disable();
    bool r = isatty((int)fd) == 1;
    sl_rt_preempt_enable();
    return r;
}

/* ---- the terminal ----------------------------------------------------
 *
 * Two things change stdin's line discipline: read_secret (echo off for the
 * length of one read) and raw_on (no line editing, no echo, keys arrive as
 * they are pressed). Both are undone by the same rule: the attributes the
 * terminal had before the FIRST change are saved once, and put back when
 * the LAST change ends -- so a read_secret inside raw mode, or two at once,
 * neither strands the terminal nor restores it too early.
 *
 * A program that dies with the terminal in raw mode leaves the person's
 * shell unusable (no echo, no line editing), so restoring is not left to
 * the caller. While a change is active:
 *   - atexit restores it, which covers exit(), a panic in the main task
 *     and falling off the end of main;
 *   - SIGINT, SIGTERM, SIGHUP, SIGQUIT and SIGABRT restore it and then
 *     die of the same signal. This is only hooked where the signal still
 *     has its default action. With `proc` imported those signals are
 *     taken by proc's own thread -- the process survives Ctrl-C, reads
 *     return "interrupted", and the program leaves through exit(), so
 *     atexit does the work.
 * SIGKILL and a crash cannot be caught. Ctrl-Z is not handled: the
 * process stops with the terminal still in the mode it set.
 *
 * Signals stay enabled in raw mode (ISIG), so Ctrl-C still interrupts and
 * a program stuck in a key loop can always be stopped. Output processing
 * stays on too, so "\n" still starts a new line. */

static pthread_mutex_t sl_io_tmu = PTHREAD_MUTEX_INITIALIZER;
static struct termios sl_io_tty_orig;
static volatile sig_atomic_t sl_io_tty_saved = 0;
static int sl_io_tty_echo_depth = 0;
static int sl_io_tty_raw = 0;
static int sl_io_tty_atexit_set = 0;

#define SL_IO_NTTYSIGS 5
static const int sl_io_tty_sigs[SL_IO_NTTYSIGS] = {
    SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGABRT
};
static struct sigaction sl_io_tty_prev[SL_IO_NTTYSIGS];
static int sl_io_tty_hooked[SL_IO_NTTYSIGS];

/* Async-signal-safe: tcsetattr, raise. SA_RESETHAND | SA_NODEFER means the
 * signal has its default action again and is not blocked, so raise()
 * ends the process the way the signal would have. */
static void sl_io_tty_on_signal(int sig) {
    if (sl_io_tty_saved)
        tcsetattr(0, TCSANOW, &sl_io_tty_orig);
    raise(sig);
}

static void sl_io_tty_atexit(void) {
    if (sl_io_tty_saved)
        tcsetattr(0, TCSADRAIN, &sl_io_tty_orig);
}

static void sl_io_tty_hook_signals(void) {
    for (int i = 0; i < SL_IO_NTTYSIGS; i++) {
        struct sigaction old, mine;
        if (sigaction(sl_io_tty_sigs[i], NULL, &old) != 0)
            continue;
        if (old.sa_handler != SIG_DFL || (old.sa_flags & SA_SIGINFO))
            continue;
        memset(&mine, 0, sizeof(mine));
        mine.sa_handler = sl_io_tty_on_signal;
        sigemptyset(&mine.sa_mask);
        mine.sa_flags = SA_RESETHAND | SA_NODEFER;
        if (sigaction(sl_io_tty_sigs[i], &mine, &sl_io_tty_prev[i]) == 0)
            sl_io_tty_hooked[i] = 1;
    }
}

static void sl_io_tty_unhook_signals(void) {
    for (int i = 0; i < SL_IO_NTTYSIGS; i++) {
        if (sl_io_tty_hooked[i]) {
            sigaction(sl_io_tty_sigs[i], &sl_io_tty_prev[i], NULL);
            sl_io_tty_hooked[i] = 0;
        }
    }
}

/* The attributes for the modes now active, built from the saved ones.
 * Caller holds sl_io_tmu with preemption disabled. */
static int sl_io_tty_apply_locked(void) {
    struct termios t = sl_io_tty_orig;
    if (sl_io_tty_echo_depth > 0)
        t.c_lflag &= ~(tcflag_t)ECHO;
    if (sl_io_tty_raw) {
        t.c_lflag &= ~(tcflag_t)(ICANON | ECHO | IEXTEN);
        t.c_iflag &= ~(tcflag_t)(IXON | ICRNL | INLCR | IGNCR);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
    }
    return tcsetattr(0, TCSADRAIN, &t);
}

/* Start a mode (raw != 0: raw; else: echo off). 0, or the errno. */
static int sl_io_tty_enter(int raw) {
    int rc = 0;
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_io_tmu);
    if (!sl_io_tty_saved) {
        struct termios t;
        if (tcgetattr(0, &t) != 0) {
            rc = errno;
        } else {
            sl_io_tty_orig = t;
            if (!sl_io_tty_atexit_set) {
                atexit(sl_io_tty_atexit);
                sl_io_tty_atexit_set = 1;
            }
            sl_io_tty_hook_signals();
            sl_io_tty_saved = 1;
        }
    }
    if (rc == 0) {
        if (raw)
            sl_io_tty_raw = 1;
        else
            sl_io_tty_echo_depth++;
        if (sl_io_tty_apply_locked() != 0) {
            rc = errno;
            if (raw)
                sl_io_tty_raw = 0;
            else
                sl_io_tty_echo_depth--;
        }
        if (!sl_io_tty_raw && sl_io_tty_echo_depth == 0 && sl_io_tty_saved) {
            /* nothing left active (the apply failed): undo the save */
            tcsetattr(0, TCSADRAIN, &sl_io_tty_orig);
            sl_io_tty_saved = 0;
            sl_io_tty_unhook_signals();
        }
    }
    pthread_mutex_unlock(&sl_io_tmu);
    sl_rt_preempt_enable();
    return rc;
}

/* End a mode; the terminal goes back to how it was when the last one
 * ends. */
static void sl_io_tty_leave(int raw) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_io_tmu);
    if (sl_io_tty_saved) {
        if (raw)
            sl_io_tty_raw = 0;
        else if (sl_io_tty_echo_depth > 0)
            sl_io_tty_echo_depth--;
        if (!sl_io_tty_raw && sl_io_tty_echo_depth == 0) {
            tcsetattr(0, TCSADRAIN, &sl_io_tty_orig);
            sl_io_tty_saved = 0;
            sl_io_tty_unhook_signals();
        } else {
            sl_io_tty_apply_locked();
        }
    }
    pthread_mutex_unlock(&sl_io_tmu);
    sl_rt_preempt_enable();
}

static sl_res_bool_str *sl_io_ok_bool(bool v) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_bool_str *sl_io_err_bool(const char *msg) {
    char *e = sl_strdup(msg);
    sl_res_bool_str *r;
    void *roots[] = { (void *)e };
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    r = (sl_res_bool_str *)sl_gc_alloc(sizeof(sl_res_bool_str),
                                       sl_gc_trace_sl_res_bool_str);
    sl_rt_safepoint_exit();
    r->ok = false;
    r->e = e;
    return r;
}

/* Key-by-key input. Until raw_off, stdin delivers each key as it is
 * pressed instead of a line at a time. Fails if stdin is not a terminal. */
static sl_res_bool_str *sl_io_raw_on(void) {
    sl_rt_preempt_disable();
    int tty = isatty(0) == 1;
    sl_rt_preempt_enable();
    if (!tty)
        return sl_io_err_bool("stdin is not a terminal");
    int e = sl_io_tty_enter(1);
    if (e != 0) {
        char msg[160];
        sl_rt_preempt_disable();
        snprintf(msg, sizeof(msg), "cannot set raw mode: %s", strerror(e));
        sl_rt_preempt_enable();
        return sl_io_err_bool(msg);
    }
    return sl_io_ok_bool(true);
}

/* Back to line-at-a-time input with echo. Harmless when raw mode is not
 * on. */
static sl_res_bool_str *sl_io_raw_off(void) {
    sl_io_tty_leave(1);
    return sl_io_ok_bool(true);
}

/* One line, like read_line, with the terminal's echo off while it is
 * read. Not a terminal: exactly read_line. The person's Enter is not
 * echoed either, so the newline is written here, or the next output would
 * land on the prompt's line. */
static sl_res_opt_str__str *sl_io_read_secret(void) {
    sl_rt_preempt_disable();
    int tty = isatty(0) == 1;
    sl_rt_preempt_enable();
    if (!tty)
        return sl_io_read_line();
    int e = sl_io_tty_enter(0);
    if (e != 0) {
        char msg[160];
        sl_rt_preempt_disable();
        snprintf(msg, sizeof(msg), "cannot turn off echo: %s", strerror(e));
        sl_rt_preempt_enable();
        return sl_io_err_line(msg);
    }
    sl_res_opt_str__str *r = sl_io_read_line();
    sl_io_tty_leave(0);
    sl_rt_preempt_disable();
    fflush(stdout);
    int out = isatty(1) ? 1 : (isatty(2) ? 2 : -1);
    if (out >= 0)
        (void)!write(out, "\n", 1);
    sl_rt_preempt_enable();
    return r;
}

/* ---- terminal size ---- */

static int sl_io_winsize(struct winsize *ws) {
    static const int fds[3] = { 1, 2, 0 };
    int ok = 0;
    sl_rt_preempt_disable();
    for (int i = 0; i < 3 && !ok; i++) {
        if (ioctl(fds[i], TIOCGWINSZ, ws) == 0 && ws->ws_col > 0 &&
            ws->ws_row > 0)
            ok = 1;
    }
    sl_rt_preempt_enable();
    return ok;
}

static sl_opt_int *sl_io_opt_int(bool has, long long v) {
    /* no tracer: an opt of a scalar holds no GC pointers, so the compiler
       emits none for it */
    sl_opt_int *o = (sl_opt_int *)sl_gc_alloc(sizeof(sl_opt_int), NULL);
    o->has = has;
    o->v = has ? v : 0;
    return o;
}

/* Columns of the terminal, from stdout, else stderr, else stdin; none when
 * none of them is a terminal. Asked afresh every call, so it follows a
 * resized window. */
static sl_opt_int *sl_io_term_width(void) {
    struct winsize ws;
    if (!sl_io_winsize(&ws))
        return sl_io_opt_int(false, 0);
    return sl_io_opt_int(true, (long long)ws.ws_col);
}

static sl_opt_int *sl_io_term_height(void) {
    struct winsize ws;
    if (!sl_io_winsize(&ws))
        return sl_io_opt_int(false, 0);
    return sl_io_opt_int(true, (long long)ws.ws_row);
}

/* ---- keys ------------------------------------------------------------
 *
 * read_key turns the bytes of one key press into a name: printable
 * characters as themselves (a whole UTF-8 character), everything else as
 * a lowercase name -- "enter", "tab", "backspace", "esc", "up", "down",
 * "left", "right", "home", "end", "insert", "delete", "pageup",
 * "pagedown", "f1".."f12", "ctrl-a".."ctrl-z", and "alt-x". Modified
 * cursor keys carry a prefix in the order ctrl-, alt-, shift-:
 * "ctrl-left", "shift-up", "ctrl-shift-right". A sequence it does not
 * know is "unknown", and is consumed whole, so it cannot leak into the
 * next key.
 *
 * A lone Escape and the start of an escape sequence are the same byte.
 * What follows it within SL_IO_ESC_WAIT_NS is part of the sequence;
 * silence means the key was Escape. It works on a pipe too, which is how
 * the decoder is tested. */

#define SL_IO_ESC_WAIT_NS 50000000LL

static int sl_io_pushback = -1; /* one byte handed back; guarded by sl_io_mu */

/* 1 = a byte, 0 = end of input, -1 = failure (sl_io_err), -2 = `u` passed. */
static int sl_io_getbyte(unsigned char *b, sl_until u) {
    for (;;) {
        int have = 0;
        sl_rt_preempt_disable();
        pthread_mutex_lock(&sl_io_mu);
        if (sl_io_pushback >= 0) {
            *b = (unsigned char)sl_io_pushback;
            sl_io_pushback = -1;
            have = 1;
        } else if (sl_io_pos < sl_io_len) {
            *b = sl_io_buf[sl_io_pos++];
            sl_io_scanned = 0;
            have = 1;
        }
        pthread_mutex_unlock(&sl_io_mu);
        sl_rt_preempt_enable();
        if (have)
            return 1;
        int rc = sl_io_fill_until(u);
        if (rc <= 0)
            return rc;
    }
}

static void sl_io_ungetbyte(unsigned char b) {
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_io_mu);
    sl_io_pushback = b;
    pthread_mutex_unlock(&sl_io_mu);
    sl_rt_preempt_enable();
}

static sl_until sl_io_esc_deadline(void) {
    return sl_until_of(sl_now_ns() + SL_IO_ESC_WAIT_NS);
}

/* Not an escape: enter, tab, backspace, ctrl-x, a printable character or a
 * UTF-8 sequence. `b` is its first byte. */
static void sl_io_key_plain(unsigned char b, char *out, size_t cap) {
    if (b == '\r' || b == '\n') {
        snprintf(out, cap, "enter");
    } else if (b == '\t') {
        snprintf(out, cap, "tab");
    } else if (b == 0x7f || b == 0x08) {
        snprintf(out, cap, "backspace");
    } else if (b >= 1 && b <= 26) {
        snprintf(out, cap, "ctrl-%c", 'a' + (b - 1));
    } else if (b == 0) {
        snprintf(out, cap, "ctrl-space");
    } else if (b < 0x20) {
        snprintf(out, cap, "ctrl-%c", (char)(b + 0x40)); /* ctrl-[ ... ctrl-_ */
    } else if (b < 0x80) {
        snprintf(out, cap, "%c", (char)b);
    } else {
        int more = (b >= 0xf0 && b < 0xf8) ? 3
                 : (b >= 0xe0)             ? 2
                 : (b >= 0xc0)             ? 1
                                           : -1;
        unsigned char seq[4];
        seq[0] = b;
        int got = 0;
        while (more > 0 && got < more) {
            unsigned char c;
            if (sl_io_getbyte(&c, sl_io_esc_deadline()) != 1)
                break;
            if ((c & 0xc0) != 0x80) {
                sl_io_ungetbyte(c);
                break;
            }
            seq[1 + got++] = c;
        }
        if (more < 0 || got != more) {
            snprintf(out, cap, "\xef\xbf\xbd"); /* U+FFFD */
        } else {
            size_t n = (size_t)more + 1;
            if (n >= cap)
                n = cap - 1;
            memcpy(out, seq, n);
            out[n] = '\0';
        }
    }
}

/* "ctrl-", "alt-", "shift-" for an xterm modifier parameter (1 + bits:
 * shift 1, alt 2, ctrl 4). */
static void sl_io_mods(int param, char *out, size_t cap) {
    int m = param > 1 ? param - 1 : 0;
    out[0] = '\0';
    if (m & 4)
        strncat(out, "ctrl-", cap - strlen(out) - 1);
    if (m & 2)
        strncat(out, "alt-", cap - strlen(out) - 1);
    if (m & 1)
        strncat(out, "shift-", cap - strlen(out) - 1);
}

static void sl_io_key_named(int param, const char *name, char *out,
                            size_t cap) {
    char mods[24];
    sl_io_mods(param, mods, sizeof(mods));
    snprintf(out, cap, "%s%s", mods, name);
}

static const char *sl_io_fkey_name(int n) {
    static const char *const names[] = {
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11",
        "f12"
    };
    return n >= 1 && n <= 12 ? names[n - 1] : NULL;
}

/* After ESC [ : parameters, then a final byte. */
static int sl_io_key_csi(char *out, size_t cap) {
    char par[24];
    size_t np = 0;
    unsigned char c = 0;
    for (;;) {
        int rc = sl_io_getbyte(&c, sl_io_esc_deadline());
        if (rc == -1)
            return -1;
        if (rc != 1) {
            snprintf(out, cap, "unknown");
            return 1;
        }
        if (c >= 0x40 && c <= 0x7e)
            break;
        if (np + 1 < sizeof(par))
            par[np++] = (char)c;
    }
    par[np] = '\0';
    int a = 0, b = 0, field = 0, ok = 1;
    for (size_t i = 0; i < np; i++) {
        if (par[i] >= '0' && par[i] <= '9') {
            int *dst = field == 0 ? &a : &b;
            *dst = *dst * 10 + (par[i] - '0');
        } else if (par[i] == ';' && field == 0) {
            field = 1;
        } else {
            ok = 0; /* '<' (mouse), '?', a third field ... */
        }
    }
    const char *name = NULL;
    if (ok) {
        switch (c) {
        case 'A': name = "up"; break;
        case 'B': name = "down"; break;
        case 'C': name = "right"; break;
        case 'D': name = "left"; break;
        case 'H': name = "home"; break;
        case 'F': name = "end"; break;
        case 'P': name = "f1"; break;
        case 'Q': name = "f2"; break;
        case 'R': name = "f3"; break;
        case 'S': name = "f4"; break;
        case 'Z':
            snprintf(out, cap, "shift-tab");
            return 1;
        case '~':
            switch (a) {
            case 1: case 7: name = "home"; break;
            case 2: name = "insert"; break;
            case 3: name = "delete"; break;
            case 4: case 8: name = "end"; break;
            case 5: name = "pageup"; break;
            case 6: name = "pagedown"; break;
            case 11: case 12: case 13: case 14: case 15:
                name = sl_io_fkey_name(a - 10);
                break;
            case 17: case 18: case 19: case 20: case 21:
                name = sl_io_fkey_name(a - 11);
                break;
            case 23: case 24:
                name = sl_io_fkey_name(a - 12);
                break;
            default: break;
            }
            break;
        default: break;
        }
    }
    if (!name) {
        snprintf(out, cap, "unknown");
        return 1;
    }
    sl_io_key_named(b, name, out, cap);
    return 1;
}

/* After ESC O : one byte (application-mode cursor keys, F1-F4). */
static int sl_io_key_ss3(char *out, size_t cap) {
    unsigned char c;
    int rc = sl_io_getbyte(&c, sl_io_esc_deadline());
    if (rc == -1)
        return -1;
    const char *name = NULL;
    if (rc == 1) {
        switch (c) {
        case 'A': name = "up"; break;
        case 'B': name = "down"; break;
        case 'C': name = "right"; break;
        case 'D': name = "left"; break;
        case 'H': name = "home"; break;
        case 'F': name = "end"; break;
        case 'P': name = "f1"; break;
        case 'Q': name = "f2"; break;
        case 'R': name = "f3"; break;
        case 'S': name = "f4"; break;
        default: break;
        }
    }
    snprintf(out, cap, "%s", name ? name : "unknown");
    return 1;
}

/* One key into `out`. 1 = a key, 0 = end of input, -1 = failure. */
static int sl_io_key_text(char *out, size_t cap) {
    unsigned char b;
    int rc = sl_io_getbyte(&b, 0);
    if (rc <= 0)
        return rc;
    if (b != 0x1b) {
        sl_io_key_plain(b, out, cap);
        return 1;
    }
    unsigned char c;
    rc = sl_io_getbyte(&c, sl_io_esc_deadline());
    if (rc == -1)
        return -1;
    if (rc != 1) { /* nothing followed: the Escape key itself */
        snprintf(out, cap, "esc");
        return 1;
    }
    if (c == '[')
        return sl_io_key_csi(out, cap);
    if (c == 'O')
        return sl_io_key_ss3(out, cap);
    if (c == 0x1b) { /* Escape, Escape: report the first, keep the second */
        sl_io_ungetbyte(c);
        snprintf(out, cap, "esc");
        return 1;
    }
    char inner[40];
    sl_io_key_plain(c, inner, sizeof(inner));
    snprintf(out, cap, "alt-%s", inner);
    return 1;
}

static sl_res_opt_str__str *sl_io_read_key(void) {
    char key[64];
    int rc = sl_io_key_text(key, sizeof(key));
    if (rc < 0)
        return sl_io_err_line(sl_io_err);
    if (rc == 0)
        return sl_io_res_line(NULL, false);
    return sl_io_res_line(sl_strdup(key), true);
}
