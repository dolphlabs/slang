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
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    b->len = 0;
    b->ptr = (unsigned char *)sl_gc_alloc((size_t)max, NULL);
    ssize_t n = read(fd, b->ptr, (size_t)max);
    if (n < 0)
        return sl_fs_err_bytes(strerror(errno));
    b->len = (long long)n;
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
        if (n < 0)
            return sl_fs_err_i32(strerror(errno));
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
