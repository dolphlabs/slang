#include "project.h"
#include "common.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void project_error(const char *fmt, ...) {
    va_list ap;
    fputs("slang: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc(10, stderr);
    exit(1);
}

int project_is_dir(const char *path) {
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int is_ident(const char *s) {
    if (!s || !s[0])
        return 0;
    if (!(isalpha((unsigned char)s[0]) || s[0] == '_'))
        return 0;
    for (const char *p = s + 1; *p; p++) {
        if (!(isalnum((unsigned char)p[0]) || *p == '_'))
            return 0;
    }
    return 1;
}

static char *join2(const char *a, const char *b) {
    return xasprintf("%s/%s", a, b);
}

char *project_find_root(const char *start_dir) {
    char cur[PATH_MAX];
    if (!realpath(start_dir, cur))
        return NULL;
    for (;;) {
        char *cand = join2(cur, "slang.project");
        if (access(cand, R_OK) == 0)
            return xstrdup(cur);
        if (!strcmp(cur, "/") || !cur[0])
            return NULL;
        char *slash = strrchr(cur, '/');
        if (!slash)
            return NULL;
        if (slash == cur)
            cur[1] = '\0';
        else
            *slash = '\0';
    }
}

static char *skip_ws(char *p) {
    while (*p == ' ' || *p == '\t')
        p++;
    return p;
}

static char *cut_word(char **pp) {
    char *p = skip_ws(*pp);
    if (!*p)
        return NULL;
    char *s = p;
    while (*p && *p != ' ' && *p != '\t')
        p++;
    if (*p) {
        *p = '\0';
        p++;
    }
    *pp = p;
    return s;
}

static void strip_comment(char *line) {
    char *h = strchr(line, '#');
    if (h)
        *h = '\0';
    size_t n = strlen(line);
    while (n && (line[n - 1] == ' ' || line[n - 1] == '\t' ||
                 line[n - 1] == '\r')) {
        line[--n] = '\0';
    }
}

static SlPkgPin *find_pin(SlProject *p, const char *name) {
    for (int i = 0; i < p->npins; i++) {
        if (!strcmp(p->pins[i].name, name))
            return &p->pins[i];
    }
    return NULL;
}

SlPkgPin *project_find_pin(SlProject *p, const char *name) {
    return p ? find_pin(p, name) : NULL;
}

static void parse_project_file(SlProject *p, char *src, const char *path) {
    int lineno = 0;
    char *save = NULL;
    for (char *line = src; line; line = save) {
        save = strchr(line, '\n');
        if (save) {
            *save = '\0';
            save++;
        }
        lineno++;
        strip_comment(line);
        char *cur = skip_ws(line);
        if (!*cur)
            continue;
        char *kw = cut_word(&cur);
        if (!kw)
            continue;
        if (!strcmp(kw, "name")) {
            char *v = cut_word(&cur);
            if (!v || cut_word(&cur) || !is_ident(v))
                project_error("%s:%d: expected 'name <ident>'", path, lineno);
            if (p->name)
                project_error("%s:%d: duplicate name", path, lineno);
            p->name = xstrdup(v);
        } else if (!strcmp(kw, "version")) {
            char *v = cut_word(&cur);
            if (!v || cut_word(&cur))
                project_error("%s:%d: expected 'version <value>'", path,
                              lineno);
            if (p->version)
                project_error("%s:%d: duplicate version", path, lineno);
            p->version = xstrdup(v);
        } else if (!strcmp(kw, "pkg")) {
            char *name = cut_word(&cur);
            char *gkw = cut_word(&cur);
            char *git = cut_word(&cur);
            char *tkw = cut_word(&cur);
            char *tag = cut_word(&cur);
            if (!name || !is_ident(name) || !gkw || strcmp(gkw, "git") ||
                !git || !tkw || strcmp(tkw, "tag") || !tag || cut_word(&cur))
                project_error("%s:%d: expected 'pkg <name> git <url> tag <tag>'",
                              path, lineno);
            if (find_pin(p, name))
                project_error("%s:%d: duplicate pkg '%s'", path, lineno, name);
            if (p->npins % 8 == 0)
                p->pins = (SlPkgPin *)xrealloc(p->pins, (p->npins + 8) *
                                                            sizeof(SlPkgPin));
            SlPkgPin *pin = &p->pins[p->npins++];
            pin->name = xstrdup(name);
            pin->git = xstrdup(git);
            pin->tag = xstrdup(tag);
            pin->hash = NULL;
        } else {
            project_error("%s:%d: unknown field '%s'", path, lineno, kw);
        }
    }
}

static void parse_lock_file(SlProject *p, char *src, const char *path) {
    int lineno = 0;
    char *save = NULL;
    for (char *line = src; line; line = save) {
        save = strchr(line, '\n');
        if (save) {
            *save = '\0';
            save++;
        }
        lineno++;
        strip_comment(line);
        char *cur = skip_ws(line);
        if (!*cur)
            continue;
        char *name = cut_word(&cur);
        char *hash = cut_word(&cur);
        if (!name || !hash || cut_word(&cur))
            project_error("%s:%d: expected '<name> sha256:<hex>'", path, lineno);
        if (strncmp(hash, "sha256:", 7) || strlen(hash) != 7 + 64)
            project_error("%s:%d: invalid hash", path, lineno);
        SlPkgPin *pin = find_pin(p, name);
        if (!pin)
            project_error("%s:%d: lock entry '%s' is not in slang.project",
                          path, lineno, name);
        if (pin->hash)
            project_error("%s:%d: duplicate lock entry '%s'", path, lineno,
                          name);
        pin->hash = xstrdup(hash);
    }
}

SlProject *project_load(const char *root) {
    SlProject *p = (SlProject *)xmalloc(sizeof(SlProject));
    memset(p, 0, sizeof(SlProject));
    p->root = xstrdup(root);
    char *proj = join2(root, "slang.project");
    parse_project_file(p, read_entire_file(proj), proj);
    if (!p->name || !p->version)
        project_error("%s: missing name or version", proj);
    char *lock = join2(root, "slang.lock");
    if (access(lock, R_OK) == 0)
        parse_lock_file(p, read_entire_file(lock), lock);
    return p;
}

static char *cache_root(void) {
    const char *env = getenv("SLANG_CACHE");
    if (env && env[0])
        return xstrdup(env);
    const char *home = getenv("HOME");
    if (!home || !home[0])
        project_error("HOME is unset; set SLANG_CACHE");
    return join2(home, ".cache/slang");
}

static void mkdir_p(const char *path) {
    char *buf = xstrdup(path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        if (mkdir(buf, 0755) != 0 && errno != EEXIST)
            project_error("cannot create directory '%s'", buf);
        *p = '/';
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST)
        project_error("cannot create directory '%s'", buf);
}

char *project_cache_dir(const SlPkgPin *pin) {
    if (!pin->hash)
        return NULL;
    return xasprintf("%s/pkg/%s/%s", cache_root(), pin->name, pin->hash);
}

typedef struct {
    uint32_t s[8];
    uint64_t bits;
    unsigned char buf[64];
    size_t n;
} Sha256;

static const uint32_t SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void sha_block(Sha256 *c, const unsigned char *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
               ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->s[0], b = c->s[1], d = c->s[3], e = c->s[4], f = c->s[5],
             g = c->s[6], h = c->s[7], cc = c->s[2];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + SHA_K[i] + w[i];
        uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = cc;
        cc = b;
        b = a;
        a = t1 + t2;
    }
    c->s[0] += a;
    c->s[1] += b;
    c->s[2] += cc;
    c->s[3] += d;
    c->s[4] += e;
    c->s[5] += f;
    c->s[6] += g;
    c->s[7] += h;
}

static void sha_init(Sha256 *c) {
    c->s[0] = 0x6a09e667;
    c->s[1] = 0xbb67ae85;
    c->s[2] = 0x3c6ef372;
    c->s[3] = 0xa54ff53a;
    c->s[4] = 0x510e527f;
    c->s[5] = 0x9b05688c;
    c->s[6] = 0x1f83d9ab;
    c->s[7] = 0x5be0cd19;
    c->bits = 0;
    c->n = 0;
}

static void sha_update(Sha256 *c, const void *data, size_t len) {
    const unsigned char *p = (const unsigned char *)data;
    c->bits += (uint64_t)len * 8;
    while (len) {
        size_t take = 64 - c->n;
        if (take > len)
            take = len;
        memcpy(c->buf + c->n, p, take);
        c->n += take;
        p += take;
        len -= take;
        if (c->n == 64) {
            sha_block(c, c->buf);
            c->n = 0;
        }
    }
}

static void sha_final(Sha256 *c, unsigned char out[32]) {
    c->buf[c->n++] = 0x80;
    if (c->n > 56) {
        while (c->n < 64)
            c->buf[c->n++] = 0;
        sha_block(c, c->buf);
        c->n = 0;
    }
    while (c->n < 56)
        c->buf[c->n++] = 0;
    for (int i = 7; i >= 0; i--)
        c->buf[c->n++] = (unsigned char)(c->bits >> (i * 8));
    sha_block(c, c->buf);
    for (int i = 0; i < 8; i++) {
        out[i * 4] = (unsigned char)(c->s[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(c->s[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(c->s[i] >> 8);
        out[i * 4 + 3] = (unsigned char)c->s[i];
    }
}

static char *sha_hex(const unsigned char d[32]) {
    static const char *h = "0123456789abcdef";
    char *s = (char *)xmalloc(7 + 64 + 1);
    memcpy(s, "sha256:", 7);
    for (int i = 0; i < 32; i++) {
        s[7 + i * 2] = h[d[i] >> 4];
        s[7 + i * 2 + 1] = h[d[i] & 15];
    }
    s[7 + 64] = '\0';
    return s;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void collect_files(const char *root, const char *rel, char ***paths,
                          int *n, int *cap) {
    char *dir = rel[0] ? join2(root, rel) : xstrdup(root);
    DIR *dp = opendir(dir);
    if (!dp)
        project_error("cannot open '%s'", dir);
    struct dirent *ent;
    while ((ent = readdir(dp)) != NULL) {
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..") ||
            !strcmp(ent->d_name, ".git"))
            continue;
        char *child = rel[0] ? join2(rel, ent->d_name) : xstrdup(ent->d_name);
        char *full = join2(root, child);
        struct stat st;
        if (stat(full, &st) != 0)
            project_error("cannot stat '%s'", full);
        if (S_ISDIR(st.st_mode))
            collect_files(root, child, paths, n, cap);
        else if (S_ISREG(st.st_mode)) {
            if (*n == *cap) {
                *cap = *cap ? *cap * 2 : 16;
                *paths = (char **)xrealloc(*paths, (size_t)*cap * sizeof(char *));
            }
            (*paths)[(*n)++] = child;
        }
    }
    closedir(dp);
}

char *project_tree_hash(const char *dir) {
    char **paths = NULL;
    int n = 0, cap = 0;
    collect_files(dir, "", &paths, &n, &cap);
    qsort(paths, (size_t)n, sizeof(char *), cmp_str);
    Sha256 ctx;
    sha_init(&ctx);
    for (int i = 0; i < n; i++) {
        sha_update(&ctx, paths[i], strlen(paths[i]));
        sha_update(&ctx, "", 1);
        char *full = join2(dir, paths[i]);
        FILE *f = fopen(full, "rb");
        if (!f)
            project_error("cannot read '%s'", full);
        if (fseek(f, 0, SEEK_END) != 0)
            project_error("cannot read '%s'", full);
        long sz = ftell(f);
        if (sz < 0)
            project_error("cannot read '%s'", full);
        rewind(f);
        unsigned char be[8];
        uint64_t u = (uint64_t)sz;
        for (int b = 7; b >= 0; b--) {
            be[b] = (unsigned char)u;
            u >>= 8;
        }
        sha_update(&ctx, be, 8);
        char buf[4096];
        size_t r;
        while ((r = fread(buf, 1, sizeof(buf), f)) > 0)
            sha_update(&ctx, buf, r);
        fclose(f);
    }
    unsigned char dig[32];
    sha_final(&ctx, dig);
    return sha_hex(dig);
}

static int run_git_clone(const char *url, const char *tag, const char *dest) {
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        execlp("git", "git", "-c", "advice.detachedHead=false", "clone",
               "--quiet", "--depth", "1", "--branch", tag, "--", url, dest,
               (char *)NULL);
        _exit(127);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0)
        return -1;
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0)
        return 0;
    return -1;
}

static void rm_rf(const char *path) {
    DIR *dp = opendir(path);
    if (!dp) {
        unlink(path);
        return;
    }
    struct dirent *ent;
    while ((ent = readdir(dp)) != NULL) {
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, ".."))
            continue;
        char *child = join2(path, ent->d_name);
        struct stat st;
        if (lstat(child, &st) == 0 && S_ISDIR(st.st_mode))
            rm_rf(child);
        else
            unlink(child);
    }
    closedir(dp);
    rmdir(path);
}

static int cmp_pin(const void *a, const void *b) {
    return strcmp(((const SlPkgPin *)a)->name, ((const SlPkgPin *)b)->name);
}

static void write_lock(SlProject *p) {
    SlPkgPin *ord = (SlPkgPin *)xmalloc((size_t)p->npins * sizeof(SlPkgPin));
    memcpy(ord, p->pins, (size_t)p->npins * sizeof(SlPkgPin));
    qsort(ord, (size_t)p->npins, sizeof(SlPkgPin), cmp_pin);
    char *path = join2(p->root, "slang.lock");
    FILE *f = fopen(path, "wb");
    if (!f)
        project_error("cannot write '%s'", path);
    for (int i = 0; i < p->npins; i++) {
        if (!ord[i].hash)
            project_error("package '%s' has no hash after get", ord[i].name);
        fprintf(f, "%s %s\n", ord[i].name, ord[i].hash);
    }
    fclose(f);
}

void project_get(SlProject *p) {
    char *root = cache_root();
    for (int i = 0; i < p->npins; i++) {
        SlPkgPin *pin = &p->pins[i];
        if (pin->hash) {
            char *have = project_cache_dir(pin);
            if (project_is_dir(have) && !strcmp(project_tree_hash(have), pin->hash))
                continue;
        }
        char *tmp = xasprintf("%s/pkg/%s/.tmp", root, pin->name);
        mkdir_p(xasprintf("%s/pkg/%s", root, pin->name));
        rm_rf(tmp);
        if (run_git_clone(pin->git, pin->tag, tmp) != 0)
            project_error("git clone failed for '%s' (%s @ %s)", pin->name,
                          pin->git, pin->tag);
        char *h = project_tree_hash(tmp);
        pin->hash = h;
        char *final = project_cache_dir(pin);
        if (project_is_dir(final))
            rm_rf(tmp);
        else if (rename(tmp, final) != 0)
            project_error("cannot store package '%s' in cache", pin->name);
    }
    write_lock(p);
}
