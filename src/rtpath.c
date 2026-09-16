#include "rtpath.h"
#include "common.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libgen.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

const char *sl_compiler_argv0 = NULL;

/* The directory the running compiler actually lives in.
 *
 * argv[0] is not good enough. Invoked through PATH -- which is the
 * normal case for an INSTALLED compiler -- argv[0] is just "slangc",
 * with no directory at all, so every argv0-relative lookup silently
 * resolves against the current working directory instead. That is why
 * `make install` produced a compiler that could not find its own
 * runtime until this existed.
 *
 * Ask the OS instead, and keep argv[0] only as the last resort for
 * platforms neither branch covers. */
static const char *self_dir(void) {
    static char cached[4096];
    static int done = 0;
    if (done)
        return cached[0] ? cached : NULL;
    done = 1;

    char buf[4096];
    buf[0] = '\0';
#if defined(__APPLE__)
    uint32_t sz = sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0)
        buf[0] = '\0';
#elif defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0)
        buf[n] = '\0';
    else
        buf[0] = '\0';
#endif
    if (!buf[0] && sl_compiler_argv0 && strchr(sl_compiler_argv0, '/'))
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
    if (!buf[0])
        return NULL;

    /* realpath resolves a symlinked install (a Homebrew-style
       bin/slangc pointing into a versioned cellar), so lib/ is found
       next to the REAL binary rather than next to the link. */
    char real[4096];
    const char *use = realpath(buf, real) ? real : buf;
    snprintf(cached, sizeof(cached), "%s", use);
    char *slash = strrchr(cached, '/');
    if (!slash) {
        cached[0] = '\0';
        return NULL;
    }
    *slash = '\0';
    return cached;
}

static int readable(const char *p) {
    return p && p[0] && access(p, R_OK) == 0;
}

static char *join_rt(const char *dir, const char *name) {
    return xasprintf("%s/%s", dir, name);
}

char *slang_runtime_file(const char *name) {
    char *p;
    const char *env = getenv("SLANG_RUNTIME");
    if (env && env[0]) {
        p = join_rt(env, name);
        if (readable(p))
            return p;
    }
#ifdef SLANG_RUNTIME_DIR
    p = join_rt(SLANG_RUNTIME_DIR, name);
    if (readable(p))
        return p;
#endif
    const char *sd = self_dir();
    if (sd) {
        p = xasprintf("%s/runtime/%s", sd, name);
        if (readable(p))
            return p;
        p = xasprintf("%s/../runtime/%s", sd, name);
        if (readable(p))
            return p;
        p = xasprintf("%s/../lib/slang/runtime/%s", sd, name);
        if (readable(p))
            return p;
    }
    if (sl_compiler_argv0 && sl_compiler_argv0[0]) {
        char buf[4096];
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
        char *dir = dirname(buf);
        p = xasprintf("%s/runtime/%s", dir, name);
        if (readable(p))
            return p;
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
        dir = dirname(buf);
        p = xasprintf("%s/../runtime/%s", dir, name);
        if (readable(p))
            return p;
        /* The installed layout: PREFIX/bin/slangc alongside
           PREFIX/lib/slang/runtime. Checked after the two in-tree
           shapes above so that running a freshly built compiler out of
           its own source tree still prefers that tree. */
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
        dir = dirname(buf);
        p = xasprintf("%s/../lib/slang/runtime/%s", dir, name);
        if (readable(p))
            return p;
    }
    p = join_rt("runtime", name);
    if (readable(p))
        return p;
    fputs("slang: cannot find runtime file '", stderr);
    fputs(name, stderr);
    fputs("'\nset SLANG_RUNTIME to the runtime/ directory\n", stderr);
    exit(1);
}

static int is_dir(const char *p) {
    struct stat st;
    return p && p[0] && stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int stdlib_ipath_ok(const char *ipath) {
    if (!ipath || !ipath[0] || ipath[0] == '/')
        return 0;
    for (const char *p = ipath; *p; p++) {
        if (p[0] == '.' && p[1] == '.' &&
            (p == ipath || p[-1] == '/') &&
            (p[2] == '/' || p[2] == '\0'))
            return 0;
    }
    return 1;
}

static char *stdlib_join(const char *root, const char *ipath) {
    char cand[PATH_MAX];
    char treal[PATH_MAX];
    if (!root || !root[0])
        return NULL;
    snprintf(cand, sizeof(cand), "%s/%s", root, ipath);
    if (!realpath(cand, treal) || !is_dir(treal))
        return NULL;
    return xstrdup(treal);
}

char *slang_stdlib_pkg(const char *ipath) {
    char *p;
    if (!stdlib_ipath_ok(ipath))
        return NULL;
    const char *env = getenv("SLANG_STDLIB");
    p = stdlib_join(env, ipath);
    if (p)
        return p;
#ifdef SLANG_STDLIB_DIR
    p = stdlib_join(SLANG_STDLIB_DIR, ipath);
    if (p)
        return p;
#endif
    const char *sd = self_dir();
    if (sd) {
        p = stdlib_join(xasprintf("%s/stdlib", sd), ipath);
        if (p)
            return p;
        p = stdlib_join(xasprintf("%s/../stdlib", sd), ipath);
        if (p)
            return p;
        p = stdlib_join(xasprintf("%s/../lib/slang/stdlib", sd), ipath);
        if (p)
            return p;
    }
    if (sl_compiler_argv0 && sl_compiler_argv0[0]) {
        char buf[4096];
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
        char *dir = dirname(buf);
        p = stdlib_join(xasprintf("%s/stdlib", dir), ipath);
        if (p)
            return p;
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
        dir = dirname(buf);
        p = stdlib_join(xasprintf("%s/../stdlib", dir), ipath);
        if (p)
            return p;
        /* The installed layout -- see slang_runtime_file's own copy of
           this step for why it comes last. */
        snprintf(buf, sizeof(buf), "%s", sl_compiler_argv0);
        dir = dirname(buf);
        p = stdlib_join(xasprintf("%s/../lib/slang/stdlib", dir), ipath);
        if (p)
            return p;
    }
    const char *rt = getenv("SLANG_RUNTIME");
    if (rt && rt[0])
        p = stdlib_join(xasprintf("%s/../stdlib", rt), ipath);
    if (p)
        return p;
#ifdef SLANG_RUNTIME_DIR
    p = stdlib_join(xasprintf("%s/../stdlib", SLANG_RUNTIME_DIR), ipath);
    if (p)
        return p;
#endif
    return stdlib_join("stdlib", ipath);
}
