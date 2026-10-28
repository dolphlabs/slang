#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
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

static sl_res_int_str *sl_os_mtime_ns(const char *p) {
    if (!p) return sl_os_err_int("no such file or directory");
    struct stat st;
    sl_rt_preempt_disable();
    int rc = stat(p, &st);
    int e = errno;
    sl_rt_preempt_enable();
    if (rc != 0)
        return sl_os_err_int(strerror(e));
    long long ns = 0;
#if defined(__APPLE__)
    ns = (long long)st.st_mtimespec.tv_sec * 1000000000LL + (long long)st.st_mtimespec.tv_nsec;
#elif defined(_POSIX_C_SOURCE) && _POSIX_C_SOURCE >= 200809L
    ns = (long long)st.st_mtim.tv_sec * 1000000000LL + (long long)st.st_mtim.tv_nsec;
#elif defined(st_mtime) && defined(st_mtimensec)
    ns = (long long)st.st_mtime * 1000000000LL + (long long)st.st_mtimensec;
#else
    ns = (long long)st.st_mtime * 1000000000LL;
#endif
    return sl_os_ok_int(ns);
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

/* ---- file watcher (FSEvents on macOS, inotify on Linux) ---- */

static bool sl_os_is_excluded(const char *rel_path, char **excludes, int nexcludes) {
    if (!excludes || nexcludes <= 0 || !rel_path) return false;
    for (int i = 0; i < nexcludes; i++) {
        const char *ex = excludes[i];
        if (!ex || !ex[0]) continue;
        size_t exlen = strlen(ex);
        const char *p = rel_path;
        while (*p) {
            while (*p == '/') p++;
            if (!*p) break;
            const char *seg = p;
            while (*p && *p != '/') p++;
            size_t seglen = (size_t)(p - seg);
            if (seglen == exlen && strncmp(seg, ex, exlen) == 0) {
                return true;
            }
        }
        if (strncmp(rel_path, ex, exlen) == 0) {
            if (rel_path[exlen] == '\0' || rel_path[exlen] == '/' || ex[exlen - 1] == '/') {
                return true;
            }
        }
    }
    return false;
}

#if defined(SLANG_OS_WATCH)

#if defined(__APPLE__)
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#elif defined(__linux__)
#include <sys/inotify.h>
typedef struct sl_inotify_wd_entry {
    int wd;
    char *dir;
} sl_inotify_wd_entry;
#endif

typedef struct sl_watcher {
    int id;
    char *root;
    size_t root_len;
    char **excludes;
    int nexcludes;
    int pipe_rd;
    int pipe_wr;
    bool signaled;

    pthread_mutex_t mu;
    char **pending_paths;
    int pending_count;
    int pending_cap;

#if defined(__APPLE__)
    FSEventStreamRef stream;
    dispatch_queue_t queue;
#elif defined(__linux__)
    int inotify_fd;
    sl_inotify_wd_entry *wd_table;
    int wd_count;
    int wd_cap;
#endif

    struct sl_watcher *next;
} sl_watcher;

static pthread_mutex_t sl_os_watch_mu = PTHREAD_MUTEX_INITIALIZER;
static sl_watcher *sl_os_watchers = NULL;
static int sl_os_next_watch_id = 1;

static sl_watcher *sl_os_find_watcher(int id) {
    pthread_mutex_lock(&sl_os_watch_mu);
    for (sl_watcher *w = sl_os_watchers; w; w = w->next) {
        if (w->id == id) {
            pthread_mutex_unlock(&sl_os_watch_mu);
            return w;
        }
    }
    pthread_mutex_unlock(&sl_os_watch_mu);
    return NULL;
}

#if defined(__APPLE__)
static void sl_os_fsevent_cb(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]) {
    (void)streamRef;
    (void)eventFlags;
    (void)eventIds;
    sl_watcher *w = (sl_watcher *)clientCallBackInfo;
    if (!w) return;
    char **paths = (char **)eventPaths;

    pthread_mutex_lock(&w->mu);
    bool added = false;
    for (size_t i = 0; i < numEvents; i++) {
        const char *p = paths[i];
        if (!p) continue;
        const char *rel = p;
        if (w->root_len > 0 && strncmp(p, w->root, w->root_len) == 0) {
            rel = p + w->root_len;
            while (*rel == '/') rel++;
        }
        if (!*rel) continue;
        if (sl_os_is_excluded(rel, w->excludes, w->nexcludes))
            continue;
        bool dup = false;
        for (int j = 0; j < w->pending_count; j++) {
            if (strcmp(w->pending_paths[j], rel) == 0) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (w->pending_count >= w->pending_cap) {
            int ncap = w->pending_cap == 0 ? 32 : w->pending_cap * 2;
            char **np = (char **)realloc(w->pending_paths, (size_t)ncap * sizeof(char *));
            if (!np) break;
            w->pending_paths = np;
            w->pending_cap = ncap;
        }
        w->pending_paths[w->pending_count++] = strdup(rel);
        added = true;
    }
    if (added && !w->signaled) {
        w->signaled = true;
        char b = 1;
        (void)write(w->pipe_wr, &b, 1);
    }
    pthread_mutex_unlock(&w->mu);
}
#elif defined(__linux__)
static void sl_os_inotify_add_tree(sl_watcher *w, const char *dir_path) {
    const char *rel = dir_path;
    if (w->root_len > 0 && strncmp(dir_path, w->root, w->root_len) == 0) {
        rel = dir_path + w->root_len;
        while (*rel == '/') rel++;
    }
    if (*rel && sl_os_is_excluded(rel, w->excludes, w->nexcludes))
        return;

    int wd = inotify_add_watch(w->inotify_fd, dir_path,
        IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB);
    if (wd >= 0) {
        pthread_mutex_lock(&w->mu);
        if (w->wd_count >= w->wd_cap) {
            int ncap = w->wd_cap == 0 ? 16 : w->wd_cap * 2;
            sl_inotify_wd_entry *ne = (sl_inotify_wd_entry *)realloc(
                w->wd_table, (size_t)ncap * sizeof(sl_inotify_wd_entry));
            if (ne) {
                w->wd_table = ne;
                w->wd_cap = ncap;
            }
        }
        if (w->wd_count < w->wd_cap) {
            w->wd_table[w->wd_count].wd = wd;
            w->wd_table[w->wd_count].dir = strdup(dir_path);
            w->wd_count++;
        }
        pthread_mutex_unlock(&w->mu);
    }

    DIR *d = opendir(dir_path);
    if (!d) return;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        char sub[PATH_MAX];
        snprintf(sub, sizeof(sub), "%s/%s", dir_path, ent->d_name);
        struct stat st;
        if (stat(sub, &st) == 0 && S_ISDIR(st.st_mode)) {
            sl_os_inotify_add_tree(w, sub);
        }
    }
    closedir(d);
}

static void sl_os_inotify_drain(sl_watcher *w) {
    char buf[4096] __attribute__ ((aligned(__alignof__(struct inotify_event))));
    ssize_t len;
    while ((len = read(w->inotify_fd, buf, sizeof(buf))) > 0) {
        for (char *ptr = buf; ptr < buf + len; ) {
            struct inotify_event *event = (struct inotify_event *)ptr;
            const char *dir = NULL;
            pthread_mutex_lock(&w->mu);
            for (int i = 0; i < w->wd_count; i++) {
                if (w->wd_table[i].wd == event->wd) {
                    dir = w->wd_table[i].dir;
                    break;
                }
            }
            pthread_mutex_unlock(&w->mu);
            if (dir) {
                char full[PATH_MAX];
                if (event->len > 0) {
                    snprintf(full, sizeof(full), "%s/%s", dir, event->name);
                } else {
                    snprintf(full, sizeof(full), "%s", dir);
                }
                if ((event->mask & IN_ISDIR) && (event->mask & IN_CREATE)) {
                    sl_os_inotify_add_tree(w, full);
                }
                const char *rel = full;
                if (w->root_len > 0 && strncmp(full, w->root, w->root_len) == 0) {
                    rel = full + w->root_len;
                    while (*rel == '/') rel++;
                }
                if (*rel && !sl_os_is_excluded(rel, w->excludes, w->nexcludes)) {
                    pthread_mutex_lock(&w->mu);
                    bool dup = false;
                    for (int j = 0; j < w->pending_count; j++) {
                        if (strcmp(w->pending_paths[j], rel) == 0) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        if (w->pending_count >= w->pending_cap) {
                            int ncap = w->pending_cap == 0 ? 32 : w->pending_cap * 2;
                            char **np = (char **)realloc(w->pending_paths, (size_t)ncap * sizeof(char *));
                            if (np) {
                                w->pending_paths = np;
                                w->pending_cap = ncap;
                            }
                        }
                        if (w->pending_count < w->pending_cap) {
                            w->pending_paths[w->pending_count++] = strdup(rel);
                        }
                    }
                    pthread_mutex_unlock(&w->mu);
                }
            }
            ptr += sizeof(struct inotify_event) + event->len;
        }
    }
}
#endif

#if defined(__APPLE__)
typedef struct {
    sl_watcher *w;
    int rc;
} sl_fsevent_init_arg;

static void *sl_fsevent_init_fn(void *arg) {
    sl_fsevent_init_arg *a = (sl_fsevent_init_arg *)arg;
    sl_watcher *w = a->w;
    char resolved[PATH_MAX];
    if (realpath(w->root, resolved)) {
        free(w->root);
        w->root = strdup(resolved);
    }
    w->root_len = strlen(w->root);
    CFStringRef mypath = CFStringCreateWithCString(NULL, w->root, kCFStringEncodingUTF8);
    CFArrayRef pathsToWatch = CFArrayCreate(NULL, (const void **)&mypath, 1, &kCFTypeArrayCallBacks);
    FSEventStreamContext ctx = {0, (void *)w, NULL, NULL, NULL};
    w->stream = FSEventStreamCreate(
        NULL,
        &sl_os_fsevent_cb,
        &ctx,
        pathsToWatch,
        kFSEventStreamEventIdSinceNow,
        0.05,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
    );
    CFRelease(pathsToWatch);
    CFRelease(mypath);
    if (!w->stream) {
        a->rc = -1;
        return NULL;
    }
    w->queue = dispatch_queue_create("sl_os_watch", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(w->stream, w->queue);
    FSEventStreamStart(w->stream);
    a->rc = 0;
    return NULL;
}

static void *sl_fsevent_teardown_fn(void *arg) {
    sl_watcher *w = (sl_watcher *)arg;
    if (w->stream) {
        FSEventStreamStop(w->stream);
        FSEventStreamInvalidate(w->stream);
        FSEventStreamRelease(w->stream);
    }
    if (w->queue) {
        dispatch_release(w->queue);
    }
    return NULL;
}
#endif

static sl_res_int_str *sl_os_watch(const char *path, sl_arr *excludes) {
    if (!path || !path[0])
        return sl_os_err_int("invalid path");

    int pfd[2] = {-1, -1};
#if defined(__APPLE__)
    if (pipe(pfd) != 0)
        return sl_os_err_int(strerror(errno));
    fcntl(pfd[0], F_SETFL, O_NONBLOCK);
    fcntl(pfd[1], F_SETFL, O_NONBLOCK);
    fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pfd[1], F_SETFD, FD_CLOEXEC);
#endif

    sl_watcher *w = (sl_watcher *)calloc(1, sizeof(sl_watcher));
    if (!w) {
        if (pfd[0] >= 0) close(pfd[0]);
        if (pfd[1] >= 0) close(pfd[1]);
        return sl_os_err_int("out of memory");
    }
    w->root = strdup(path);
    w->root_len = strlen(w->root);
    w->pipe_rd = pfd[0];
    w->pipe_wr = pfd[1];
    pthread_mutex_init(&w->mu, NULL);

    if (excludes && excludes->len > 0) {
        w->nexcludes = excludes->len;
        w->excludes = (char **)malloc((size_t)w->nexcludes * sizeof(char *));
        const char **items = (const char **)excludes->data;
        for (int i = 0; i < w->nexcludes; i++) {
            w->excludes[i] = strdup(items[i]);
        }
    }

#if defined(__APPLE__)
    sl_fsevent_init_arg iarg = { w, 0 };
    pthread_t init_th;
    if (pthread_create(&init_th, NULL, sl_fsevent_init_fn, &iarg) != 0 || pthread_join(init_th, NULL) != 0 || iarg.rc != 0) {
        close(pfd[0]);
        close(pfd[1]);
        free(w->root);
        for (int i = 0; i < w->nexcludes; i++) free(w->excludes[i]);
        free(w->excludes);
        pthread_mutex_destroy(&w->mu);
        free(w);
        return sl_os_err_int("failed to create FSEventStream");
    }
#elif defined(__linux__)
    w->inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (w->inotify_fd < 0) {
        free(w->root);
        for (int i = 0; i < w->nexcludes; i++) free(w->excludes[i]);
        free(w->excludes);
        pthread_mutex_destroy(&w->mu);
        free(w);
        return sl_os_err_int("failed to initialize inotify");
    }
    w->pipe_rd = w->inotify_fd;
    sl_os_inotify_add_tree(w, w->root);
#endif

    pthread_mutex_lock(&sl_os_watch_mu);
    w->id = sl_os_next_watch_id++;
    w->next = sl_os_watchers;
    sl_os_watchers = w;
    pthread_mutex_unlock(&sl_os_watch_mu);

    return sl_os_ok_int((long long)w->id);
}

static sl_res__str__str *sl_os_watch_next(int handle, int64_t deadline) {
    sl_watcher *w = sl_os_find_watcher(handle);
    if (!w) return sl_os_err_list("invalid watch handle");

    for (;;) {
#if defined(__linux__)
        sl_os_inotify_drain(w);
#endif
        pthread_mutex_lock(&w->mu);
        if (w->pending_count > 0) {
            int count = w->pending_count;
            char **paths = (char **)malloc((size_t)count * sizeof(char *));
            for (int i = 0; i < count; i++) {
                paths[i] = w->pending_paths[i];
            }
            w->pending_count = 0;
            w->signaled = false;
            if (w->pipe_wr >= 0) {
                char buf[64];
                while (read(w->pipe_rd, buf, sizeof(buf)) > 0) {}
            }
            pthread_mutex_unlock(&w->mu);

            sl_arr *a = sl_arr_new(sizeof(char *), 1);
            void *roots[] = { (void *)a };
            sl_safepoint sp;
            sl_rt_safepoint_enter(&sp, roots, 1);
            for (int i = 0; i < count; i++) {
                char *s = sl_strdup(paths[i]);
                free(paths[i]);
                sl_arr_push(a, &s, sizeof(char *));
            }
            free(paths);
            sl_rt_safepoint_exit();
            return sl_os_ok_list(a);
        }
        pthread_mutex_unlock(&w->mu);

        if (deadline && sl_until_hit(deadline)) {
            return sl_os_err_list("timeout");
        }

        int wr = sl_reactor_wait_until(w->pipe_rd, SL_REACTOR_READ, 1, deadline);
        if (wr == -2) {
            return sl_os_err_list("timeout");
        }
        if (wr < 0) {
            return sl_os_err_list("watch reactor error");
        }
    }
}

static sl_res_bool_str *sl_os_watch_close(int handle) {
    pthread_mutex_lock(&sl_os_watch_mu);
    sl_watcher **prev = &sl_os_watchers;
    sl_watcher *w = NULL;
    for (sl_watcher *cur = sl_os_watchers; cur; cur = cur->next) {
        if (cur->id == handle) {
            w = cur;
            *prev = cur->next;
            break;
        }
        prev = &cur->next;
    }
    pthread_mutex_unlock(&sl_os_watch_mu);
    if (!w) return sl_os_err_bool("invalid watch handle");

#if defined(__APPLE__)
    pthread_t tear_th;
    if (pthread_create(&tear_th, NULL, sl_fsevent_teardown_fn, w) == 0) {
        pthread_join(tear_th, NULL);
    }
#elif defined(__linux__)
    if (w->inotify_fd >= 0) {
        close(w->inotify_fd);
    }
    for (int i = 0; i < w->wd_count; i++) {
        free(w->wd_table[i].dir);
    }
    free(w->wd_table);
#endif
    if (w->pipe_rd >= 0 && w->pipe_rd != w->pipe_wr) close(w->pipe_rd);
    if (w->pipe_wr >= 0) close(w->pipe_wr);

    pthread_mutex_lock(&w->mu);
    for (int i = 0; i < w->pending_count; i++) free(w->pending_paths[i]);
    free(w->pending_paths);
    for (int i = 0; i < w->nexcludes; i++) free(w->excludes[i]);
    free(w->excludes);
    free(w->root);
    pthread_mutex_unlock(&w->mu);
    pthread_mutex_destroy(&w->mu);
    free(w);
    return sl_os_ok_bool(true);
}

#else

static sl_res_int_str *sl_os_watch(const char *path, sl_arr *excludes) {
    (void)path; (void)excludes;
    return sl_os_err_int("os.watch not supported on this platform");
}

static sl_res__str__str *sl_os_watch_next(int handle, int64_t deadline) {
    (void)handle; (void)deadline;
    return sl_os_err_list("os.watch not supported on this platform");
}

static sl_res_bool_str *sl_os_watch_close(int handle) {
    (void)handle;
    return sl_os_err_bool("os.watch not supported on this platform");
}

#endif

