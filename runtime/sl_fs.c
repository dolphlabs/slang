#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static sl_res_i32_str *sl_fs_ok_i32(int32_t v) {
    sl_res_i32_str *r = (sl_res_i32_str *)sl_gc_alloc(
        sizeof(sl_res_i32_str), sl_gc_trace_sl_res_i32_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_i32_str *sl_fs_err_i32(const char *msg) {
    sl_res_i32_str *r = (sl_res_i32_str *)sl_gc_alloc(
        sizeof(sl_res_i32_str), sl_gc_trace_sl_res_i32_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_bytes_str *sl_fs_ok_bytes(sl_bytes *b) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = true;
    r->v = b;
    return r;
}

static sl_res_bytes_str *sl_fs_err_bytes(const char *msg) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_bool_str *sl_fs_ok_bool(bool v) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_bool_str *sl_fs_err_bool(const char *msg) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_i32_str *sl_fs_open(const char *path) {
    if (!path)
        return sl_fs_err_i32("invalid path");
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return sl_fs_err_i32(strerror(errno));
    return sl_fs_ok_i32((int32_t)fd);
}

static sl_res_i32_str *sl_fs_create(const char *path) {
    if (!path)
        return sl_fs_err_i32("invalid path");
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return sl_fs_err_i32(strerror(errno));
    return sl_fs_ok_i32((int32_t)fd);
}

static sl_res_bytes_str *sl_fs_read(int fd, int max) {
    if (fd < 0)
        return sl_fs_err_bytes("invalid fd");
    if (max < 0)
        return sl_fs_err_bytes("invalid length");
    if (max == 0)
        return sl_fs_ok_bytes(sl_bytes_new(NULL, 0));
    sl_bytes *b = sl_bytes_alloc(max);
    b->len = 0;
    /* EINTR: SIGUSR1 (async preemption) is installed without
       SA_RESTART, so a read from a pipe or terminal that the ticker
       interrupts fails instead of resuming. Retry. */
    ssize_t n;
    do {
        n = read(fd, b->ptr, (size_t)max);
    } while (n < 0 && errno == EINTR);
    if (n < 0)
        return sl_fs_err_bytes(strerror(errno));
    b->len = (long long)n;
    return sl_fs_ok_bytes(b);
}

/* Up to `len` bytes starting at `offset`, without moving the file
 * position -- so several tasks can read different ranges of one fd at
 * once. Loops over short reads; fewer bytes than asked only at EOF. */
static sl_res_bytes_str *sl_fs_pread(int fd, long long offset, long long len) {
    if (fd < 0)
        return sl_fs_err_bytes("invalid fd");
    if (offset < 0 || len < 0)
        return sl_fs_err_bytes("invalid offset or length");
    if (len > (1LL << 31))
        return sl_fs_err_bytes("length over 2GB; read in pieces");
    if (len == 0)
        return sl_fs_ok_bytes(sl_bytes_new(NULL, 0));
    sl_bytes *b = sl_bytes_alloc(len);
    b->len = 0;
    long long got = 0;
    while (got < len) {
        ssize_t n = pread(fd, b->ptr + got, (size_t)(len - got), (off_t)(offset + got));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return sl_fs_err_bytes(strerror(errno));
        }
        if (n == 0)
            break;
        got += n;
    }
    b->len = got;
    return sl_fs_ok_bytes(b);
}

static sl_res_i32_str *sl_fs_write(int fd, sl_bytes *data) {
    if (fd < 0)
        return sl_fs_err_i32("invalid fd");
    if (!data)
        return sl_fs_err_i32("invalid buffer");
    long long off = 0;
    while (off < data->len) {
        ssize_t n = write(fd, data->ptr + off, (size_t)(data->len - off));
        if (n < 0) {
            if (errno == EINTR)
                continue; /* see sl_fs_read */
            return sl_fs_err_i32(strerror(errno));
        }
        if (n == 0)
            return sl_fs_err_i32("short write");
        off += n;
    }
    return sl_fs_ok_i32((int32_t)off);
}

static sl_res_bool_str *sl_fs_close(int fd) {
    if (fd < 0)
        return sl_fs_err_bool("invalid fd");
    if (close(fd) != 0)
        return sl_fs_err_bool(strerror(errno));
    return sl_fs_ok_bool(true);
}

static sl_res_bool_str *sl_fs_mkdir(const char *path) {
    if (!path)
        return sl_fs_err_bool("invalid path");
    if (mkdir(path, 0755) != 0)
        return sl_fs_err_bool(strerror(errno));
    return sl_fs_ok_bool(true);
}

#define SL_TASK_FS_STACK_SIZE 32768

static sl_res_str_str *sl_fs_ok_str(const char *v) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = true;
    r->v = sl_strdup(v);
    return r;
}

static sl_res_str_str *sl_fs_err_str(const char *msg) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* fs.realpath(path): the absolute path with every symlink, "." and ".."
 * resolved -- what a server compares against its root to refuse a file
 * that a link leads outside it. err when the path does not exist. */
static sl_res_str_str *sl_fs_realpath(const char *path) {
    if (!path || !path[0])
        return sl_fs_err_str("invalid path");
    /* libc's realpath keeps PATH_MAX-sized buffers on the stack: more
       than a task's 8 KB, so grow it first, as for OpenSSL and SQLite. */
    sl_rt_need_stack(SL_TASK_FS_STACK_SIZE);
    sl_rt_preempt_disable();
    char *r = realpath(path, NULL);
    int e = errno;
    sl_rt_preempt_enable();
    if (!r)
        return sl_fs_err_str(strerror(e));
    sl_res_str_str *out = sl_fs_ok_str(r);
    sl_rt_preempt_disable();
    free(r);
    sl_rt_preempt_enable();
    return out;
}

/* fs.fstat(fd): [kind, size, mtime_sec, mtime_nsec] of an open file --
 * kind 0 a regular file, 1 a directory, 2 anything else -- or [] when fd
 * is not open. Of the file already opened, so what is served is what
 * was checked. */
static sl_arr *sl_fs_fstat(int fd) {
    sl_arr *a = sl_arr_new(sizeof(long long), 4);
    struct stat st;
    if (fstat(fd, &st) != 0)
        return a;
    long long kind = S_ISREG(st.st_mode) ? 0 : S_ISDIR(st.st_mode) ? 1 : 2;
#if defined(__APPLE__)
    long long msec = (long long)st.st_mtimespec.tv_sec;
    long long mnsec = (long long)st.st_mtimespec.tv_nsec;
#else
    long long msec = (long long)st.st_mtim.tv_sec;
    long long mnsec = (long long)st.st_mtim.tv_nsec;
#endif
    long long vals[4] = {kind, (long long)st.st_size, msec, mnsec};
    for (int i = 0; i < 4; i++)
        sl_arr_push(a, &vals[i], sizeof(long long));
    return a;
}
