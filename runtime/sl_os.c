#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---- os: the operating system around a program -----------------------
 *
 * The fs/os split: `fs` owns open file HANDLES and their contents; `os`
 * owns everything you can ask or do about a path WITHOUT opening it,
 * plus the environment and the process. fs.mkdir predates the split and
 * stays where it is rather than breaking existing programs.
 *
 * Everything here is libc, so importing `os` adds no link flag --
 * unlike crypto (-lcrypto) and sql (-lsqlite3).
 *
 * Every libc call that allocates or walks kernel structures is
 * bracketed with sl_rt_preempt_disable/enable. An async preemption
 * landing inside opendir/readdir or getaddrinfo-style machinery resumes
 * the task on a different worker, and libc's own locks track their
 * owning thread -- the same hazard that made SQLite abort roughly one
 * run in a hundred before sl_sql.c was bracketed. */

#if defined(__APPLE__)
#include <crt_externs.h>
#define SL_OS_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define SL_OS_ENVIRON environ
#endif

static sl_res_bool_str *sl_os_ok_bool(bool v) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_bool_str *sl_os_err_bool(const char *msg) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_int_str *sl_os_ok_int(long long v) {
    sl_res_int_str *r = (sl_res_int_str *)sl_gc_alloc(
        sizeof(sl_res_int_str), sl_gc_trace_sl_res_int_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_int_str *sl_os_err_int(const char *msg) {
    sl_res_int_str *r = (sl_res_int_str *)sl_gc_alloc(
        sizeof(sl_res_int_str), sl_gc_trace_sl_res_int_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_str_str *sl_os_ok_str(char *v) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_str_str *sl_os_err_str(const char *msg) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res__str__str *sl_os_ok_list(sl_arr *v) {
    sl_res__str__str *r = (sl_res__str__str *)sl_gc_alloc(
        sizeof(sl_res__str__str), sl_gc_trace_sl_res__str__str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res__str__str *sl_os_err_list(const char *msg) {
    sl_res__str__str *r = (sl_res__str__str *)sl_gc_alloc(
        sizeof(sl_res__str__str), sl_gc_trace_sl_res__str__str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* ---- environment ---- */

static sl_res_bool_str *sl_os_setenv(const char *k, const char *v) {
    if (!k || !k[0] || strchr(k, '='))
        return sl_os_err_bool("invalid environment variable name");
    sl_rt_preempt_disable();
    int rc = setenv(k, v ? v : "", 1);
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_bool(strerror(e));
    return sl_os_ok_bool(true);
}

static sl_res_bool_str *sl_os_unsetenv(const char *k) {
    if (!k || !k[0] || strchr(k, '='))
        return sl_os_err_bool("invalid environment variable name");
    sl_rt_preempt_disable();
    int rc = unsetenv(k);
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_bool(strerror(e));
    return sl_os_ok_bool(true);
}

/* "KEY=VALUE" entries, in the order the process holds them. Returned as
 * a plain list rather than a map: an environment may legally contain a
 * repeated key, and a map would silently drop one. */
static sl_arr *sl_os_environ(void) {
    sl_arr *a = sl_arr_new(sizeof(char *), 1);
    void *roots[] = { (void *)a };
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1); /* a is live across every
        sl_strdup below, each of which can collect */
    char **env = SL_OS_ENVIRON;
    for (int i = 0; env && env[i]; i++) {
        char *s = sl_strdup(env[i]);
        sl_arr_push(a, &s, sizeof(char *));
    }
    sl_rt_safepoint_exit();
    return a;
}

/* ---- the process ---- */

static long long sl_os_pid(void) { return (long long)getpid(); }

static sl_res_str_str *sl_os_hostname(void) {
    char buf[256];
    sl_rt_preempt_disable();
    int rc = gethostname(buf, sizeof(buf));
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_str(strerror(e));
    buf[sizeof(buf) - 1] = '\0'; /* POSIX leaves truncation unspecified
                                    as to whether it terminates */
    return sl_os_ok_str(sl_strdup(buf));
}

static const char *sl_os_tmpdir(void) {
    const char *t = getenv("TMPDIR");
    if (t && t[0])
        return sl_strdup(t);
    return sl_strdup("/tmp");
}

/* ---- path metadata ----
 *
 * The predicates are bare bools on purpose. "Does this exist" has only
 * two useful answers: a missing path and an unreadable parent directory
 * are both "no, you cannot use it", and a caller that branches on the
 * distinction would be racing anyway -- the answer can change between
 * the check and the use. The accessors below DO return a value that has
 * to come from somewhere, so they carry the errno text. */

static bool sl_os_exists(const char *p) {
    if (!p) return false;
    struct stat st;
    sl_rt_preempt_disable();
    int rc = stat(p, &st);
    sl_rt_preempt_enable();
    return rc == 0;
}

static bool sl_os_is_dir(const char *p) {
    if (!p) return false;
    struct stat st;
    sl_rt_preempt_disable();
    int rc = stat(p, &st);
    sl_rt_preempt_enable();
    return rc == 0 && S_ISDIR(st.st_mode);
}

/* Regular files only: a directory, socket or fifo is not something you
 * can read as a file, so answering "yes" for them would mislead. */
static bool sl_os_is_file(const char *p) {
    if (!p) return false;
    struct stat st;
    sl_rt_preempt_disable();
    int rc = stat(p, &st);
    sl_rt_preempt_enable();
    return rc == 0 && S_ISREG(st.st_mode);
}

static sl_res_int_str *sl_os_size(const char *p) {
    if (!p) return sl_os_err_int("no such file or directory");
    struct stat st;
    sl_rt_preempt_disable();
    int rc = stat(p, &st);
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_int(strerror(e));
    return sl_os_ok_int((long long)st.st_size);
}

/* Unix seconds. Nanosecond fields are spelled differently on every
 * platform (st_mtimespec, st_mtim, st_mtime_nsec) and nothing here
 * needs that resolution; seconds is what Last-Modified wants. */
static sl_res_int_str *sl_os_mtime(const char *p) {
    if (!p) return sl_os_err_int("no such file or directory");
    struct stat st;
    sl_rt_preempt_disable();
    int rc = stat(p, &st);
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_int(strerror(e));
    return sl_os_ok_int((long long)st.st_mtime);
}

/* ---- directories and the namespace ---- */

/* Entry names only, not paths, and "." and ".." are omitted: every
 * caller filters them out, and forgetting to is how a directory walk
 * becomes an infinite loop. */
static sl_res__str__str *sl_os_read_dir(const char *p) {
    if (!p) return sl_os_err_list("no such file or directory");
    sl_rt_preempt_disable();
    DIR *d = opendir(p);
    int oe = errno;
    sl_rt_preempt_enable();
    if (!d)
        return sl_os_err_list(strerror(oe));

    sl_arr *a = sl_arr_new(sizeof(char *), 1);
    void *roots[] = { (void *)a };
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    for (;;) {
        sl_rt_preempt_disable();
        struct dirent *ent = readdir(d);
        sl_rt_preempt_enable();
        if (!ent)
            break;
        const char *n = ent->d_name;
        if (n[0] == '.' && (n[1] == '\0' || (n[1] == '.' && n[2] == '\0')))
            continue;
        char *s = sl_strdup(n);
        sl_arr_push(a, &s, sizeof(char *));
    }
    sl_rt_safepoint_exit();
    sl_rt_preempt_disable();
    closedir(d);
    sl_rt_preempt_enable();
    return sl_os_ok_list(a);
}

/* Files and empty directories alike, so a caller need not know which it
 * has. rmdir is tried only when unlink says "that is a directory". */
static sl_res_bool_str *sl_os_remove(const char *p) {
    if (!p) return sl_os_err_bool("no such file or directory");
    sl_rt_preempt_disable();
    int rc = unlink(p);
    int e = errno;
    if (rc != 0 && (e == EISDIR || e == EPERM)) {
        rc = rmdir(p);
        e = errno;
    }
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_bool(strerror(e));
    return sl_os_ok_bool(true);
}

static sl_res_bool_str *sl_os_rename(const char *from, const char *to) {
    if (!from || !to) return sl_os_err_bool("no such file or directory");
    sl_rt_preempt_disable();
    int rc = rename(from, to);
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_bool(strerror(e));
    return sl_os_ok_bool(true);
}
