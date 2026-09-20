#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/stat.h>
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
 * concurrent readers -- it is only ever a strerror text). */
static int sl_io_fill(void) {
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
            if (sl_reactor_wait(0, SL_REACTOR_READ, 1) < 0) {
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
