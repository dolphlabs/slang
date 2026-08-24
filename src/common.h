#ifndef SLANG_COMMON_H
#define SLANG_COMMON_H

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Allocation helpers that abort on OOM. The compiler is a short-lived
 * process, so we never bother freeing intermediate structures. */

static inline void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (!p) {
        fputs("slang: out of memory", stderr);
        fputc(10, stderr); /* newline */
        exit(1);
    }
    return p;
}

static inline void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n);
    if (!q) {
        fputs("slang: out of memory", stderr);
        fputc(10, stderr); /* newline */
        exit(1);
    }
    return q;
}

static inline char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)xmalloc(n);
    memcpy(p, s, n);
    return p;
}

/* Growable string buffer used to build the generated C source. */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} StrBuf;

static inline void sb_init(StrBuf *sb) {
    sb->cap = 1 << 16;
    sb->len = 0;
    sb->data = (char *)xmalloc(sb->cap);
    sb->data[0] = '\0';
}

static inline void sb_append_n(StrBuf *sb, const char *s, size_t n) {
    if (sb->len + n + 1 > sb->cap) {
        while (sb->len + n + 1 > sb->cap)
            sb->cap *= 2;
        sb->data = (char *)xrealloc(sb->data, sb->cap);
    }
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static inline void sb_append(StrBuf *sb, const char *s) {
    sb_append_n(sb, s, strlen(s));
}

/* Read an entire file into a NUL-terminated heap buffer. Exits with a
 * diagnostic on failure. */
static inline char *read_entire_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fputs("slang: cannot open file: ", stderr);
        fputs(path, stderr);
        fputc(10, stderr);
        exit(1);
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) {
        fputs("slang: cannot read file: ", stderr);
        fputs(path, stderr);
        fputc(10, stderr);
        exit(1);
    }
    char *buf = (char *)xmalloc((size_t)size + 1);
    size_t nread = fread(buf, 1, (size_t)size, f);
    buf[nread] = '\0';
    fclose(f);
    return buf;
}

#endif /* SLANG_COMMON_H */
