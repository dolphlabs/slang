#include "rtpath.h"
#include "common.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libgen.h>

const char *sl_compiler_argv0 = NULL;

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
