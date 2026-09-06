#include "rtpath.h"
#include "common.h"

#include <stdlib.h>
#include <string.h>
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
