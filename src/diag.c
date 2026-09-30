#include "diag.h"

#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

const char *diag_file = NULL;
int diag_json = 0;
static int diag_n = 0;

int diag_count(void) { return diag_n; }

/* A path under the working directory is shown relative to it: shorter to
 * read, and what the user typed in the common case. */
static const char *display_path(const char *path) {
    static char cwd[PATH_MAX];
    static int have_cwd = -1;
    if (have_cwd < 0)
        have_cwd = getcwd(cwd, sizeof(cwd)) != NULL;
    if (!have_cwd || !path)
        return path;
    size_t n = strlen(cwd);
    if (n > 1 && !strncmp(path, cwd, n) && path[n] == '/')
        return path + n + 1;
    return path;
}

static void json_str(FILE *out, const char *s) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", out); break;
        case '\\': fputs("\\\\", out); break;
        case '\n': fputs("\\n", out); break;
        case '\r': fputs("\\r", out); break;
        case '\t': fputs("\\t", out); break;
        default:
            if (*p < 0x20)
                fprintf(out, "\\u%04x", *p);
            else
                fputc(*p, out);
        }
    }
    fputc('"', out);
}

void diag_vreport(const char *file, int line, const char *fmt, va_list ap,
                  const char *suffix) {
    char msg[4096];
    int n = vsnprintf(msg, sizeof(msg), fmt, ap);
    if (n < 0)
        msg[0] = '\0';
    if (suffix && *suffix) {
        size_t len = strlen(msg);
        snprintf(msg + len, sizeof(msg) - len, "%s", suffix);
    }
    const char *shown = display_path(file);
    diag_n++;
    if (diag_json) {
        fputs("{\"file\":", stderr);
        if (shown)
            json_str(stderr, shown);
        else
            fputs("null", stderr);
        fprintf(stderr, ",\"line\":%d,\"severity\":\"error\",\"message\":",
                line);
        json_str(stderr, msg);
        fputs("}\n", stderr);
    } else if (shown) {
        fprintf(stderr, "%s:%d: error: %s\n", shown, line, msg);
    } else {
        fprintf(stderr, "slang: error at line %d: %s\n", line, msg);
    }
    fflush(stderr);
}

void diag_report(const char *file, int line, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    diag_vreport(file, line, fmt, ap, NULL);
    va_end(ap);
}
