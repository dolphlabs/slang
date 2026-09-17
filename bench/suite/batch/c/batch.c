/* heavy/batch in C: mmap, one pthread per core over newline-aligned byte
 * ranges, open-addressing hash tables per thread, merged at the end.
 * See bench/SPEC.md.
 *
 *   cc -O3 -march=native -flto -o batch batch.c -lpthread
 *   ./batch <file.csv>
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---- u64 -> i64 table (user_id -> revenue) ------------------------- */

typedef struct {
    uint64_t *keys; /* key + 1, so 0 marks an empty slot */
    int64_t *vals;
    size_t cap, len;
} utab_t;

static inline uint64_t mix64(uint64_t x) {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    return x ^ (x >> 33);
}

static void utab_init(utab_t *t, size_t cap) {
    t->cap = cap;
    t->len = 0;
    t->keys = calloc(cap, sizeof *t->keys);
    t->vals = calloc(cap, sizeof *t->vals);
}

static void utab_add(utab_t *t, uint64_t key, int64_t v);

static void utab_grow(utab_t *t) {
    utab_t n;
    utab_init(&n, t->cap * 2);
    for (size_t i = 0; i < t->cap; i++)
        if (t->keys[i]) utab_add(&n, t->keys[i] - 1, t->vals[i]);
    free(t->keys);
    free(t->vals);
    *t = n;
}

static void utab_add(utab_t *t, uint64_t key, int64_t v) {
    if ((t->len + 1) * 2 > t->cap) utab_grow(t);
    size_t mask = t->cap - 1;
    size_t i = mix64(key) & mask;
    uint64_t k = key + 1;
    while (t->keys[i] && t->keys[i] != k) i = (i + 1) & mask;
    if (!t->keys[i]) {
        t->keys[i] = k;
        t->len++;
    }
    t->vals[i] += v;
}

/* ---- short string -> i64 table (sku -> revenue) --------------------- */

#define SKU_MAX 16

typedef struct {
    char key[SKU_MAX];
    uint8_t klen; /* 0 marks an empty slot */
    int64_t val;
} sslot_t;

typedef struct {
    sslot_t *slots;
    size_t cap, len;
} stab_t;

static inline uint64_t hash_bytes(const char *p, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)p[i]) * 1099511628211ULL;
    return mix64(h);
}

static void stab_init(stab_t *t, size_t cap) {
    t->cap = cap;
    t->len = 0;
    t->slots = calloc(cap, sizeof *t->slots);
}

static void stab_add(stab_t *t, const char *k, size_t n, int64_t v);

static void stab_grow(stab_t *t) {
    stab_t n;
    stab_init(&n, t->cap * 2);
    for (size_t i = 0; i < t->cap; i++)
        if (t->slots[i].klen) stab_add(&n, t->slots[i].key, t->slots[i].klen, t->slots[i].val);
    free(t->slots);
    *t = n;
}

static void stab_add(stab_t *t, const char *k, size_t n, int64_t v) {
    if ((t->len + 1) * 2 > t->cap) stab_grow(t);
    size_t mask = t->cap - 1;
    size_t i = hash_bytes(k, n) & mask;
    while (t->slots[i].klen && (t->slots[i].klen != n || memcmp(t->slots[i].key, k, n)))
        i = (i + 1) & mask;
    if (!t->slots[i].klen) {
        memcpy(t->slots[i].key, k, n);
        t->slots[i].klen = (uint8_t)n;
        t->len++;
    }
    t->slots[i].val += v;
}

/* ---- per-thread work -------------------------------------------------- */

typedef struct {
    int64_t count, qty, revenue;
    int seen;
} region_t;

typedef struct {
    const char *start, *end;
    int64_t rows;
    region_t regions[26 * 26];
    utab_t users;
    stab_t skus;
} job_t;

static inline int64_t parse_int(const char **pp) {
    const char *p = *pp;
    int64_t v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    *pp = p + 1; /* skip the separator */
    return v;
}

static void *work(void *arg) {
    job_t *j = arg;
    utab_init(&j->users, 1 << 20);
    stab_init(&j->skus, 1 << 18);
    const char *p = j->start, *end = j->end;
    while (p < end) {
        while (*p != ',') p++; /* ts */
        p++;
        int64_t user = parse_int(&p);
        const char *sku = p;
        while (*p != ',') p++;
        size_t sku_len = (size_t)(p - sku);
        p++;
        int64_t qty = parse_int(&p);
        int64_t price = parse_int(&p);
        region_t *r = &j->regions[(p[0] - 'A') * 26 + (p[1] - 'A')];
        p += 3; /* two letters and the newline */
        int64_t revenue = qty * price;
        r->count++;
        r->qty += qty;
        r->revenue += revenue;
        r->seen = 1;
        j->rows++;
        utab_add(&j->users, (uint64_t)user, revenue);
        if (sku_len > SKU_MAX) sku_len = SKU_MAX;
        stab_add(&j->skus, sku, sku_len, revenue);
    }
    return NULL;
}

/* ---- ranking ------------------------------------------------------------ */

typedef struct {
    int64_t revenue;
    uint64_t user;
} utop_t;

typedef struct {
    int64_t revenue;
    char sku[SKU_MAX + 1];
    uint8_t len;
} stop_t;

static int sku_less(const char *a, size_t an, const char *b, size_t bn) {
    int c = memcmp(a, b, an < bn ? an : bn);
    return c ? c < 0 : an < bn;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file.csv>\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) {
        perror(argv[1]);
        return 1;
    }
    size_t size = (size_t)st.st_size;
    const char *data = size ? mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0) : "";
    if (data == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    madvise((void *)data, size, MADV_SEQUENTIAL);

    int threads = 1;
#ifdef __linux__
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof set, &set) == 0) threads = CPU_COUNT(&set);
#else
    threads = (int)sysconf(_SC_NPROCESSORS_ONLN);
#endif
    const char *w = getenv("WORKERS");
    if (w && atoi(w) > 0) threads = atoi(w);
    if ((size_t)threads > size / (1 << 16) + 1) threads = (int)(size / (1 << 16) + 1);

    job_t *jobs = calloc((size_t)threads, sizeof *jobs);
    pthread_t *tids = calloc((size_t)threads, sizeof *tids);
    const char *cursor = data;
    for (int i = 0; i < threads; i++) {
        const char *end = i == threads - 1 ? data + size : data + size / (size_t)threads * (size_t)(i + 1);
        if (end < cursor) end = cursor;
        while (end < data + size && end[-1] != '\n') end++;
        jobs[i].start = cursor;
        jobs[i].end = end;
        cursor = end;
        pthread_create(&tids[i], NULL, work, &jobs[i]);
    }
    for (int i = 0; i < threads; i++) pthread_join(tids[i], NULL);

    /* merge into the largest tables */
    int64_t rows = 0;
    region_t regions[26 * 26] = {{0}};
    utab_t *users = &jobs[0].users;
    stab_t *skus = &jobs[0].skus;
    for (int i = 0; i < threads; i++) {
        rows += jobs[i].rows;
        for (int r = 0; r < 26 * 26; r++) {
            regions[r].count += jobs[i].regions[r].count;
            regions[r].qty += jobs[i].regions[r].qty;
            regions[r].revenue += jobs[i].regions[r].revenue;
            regions[r].seen |= jobs[i].regions[r].seen;
        }
        if (jobs[i].users.len > users->len) users = &jobs[i].users;
        if (jobs[i].skus.len > skus->len) skus = &jobs[i].skus;
    }
    for (int i = 0; i < threads; i++) {
        utab_t *u = &jobs[i].users;
        if (u != users) {
            for (size_t k = 0; k < u->cap; k++)
                if (u->keys[k]) utab_add(users, u->keys[k] - 1, u->vals[k]);
            free(u->keys);
            free(u->vals);
        }
        stab_t *s = &jobs[i].skus;
        if (s != skus) {
            for (size_t k = 0; k < s->cap; k++)
                if (s->slots[k].klen) stab_add(skus, s->slots[k].key, s->slots[k].klen, s->slots[k].val);
            free(s->slots);
        }
    }

    utop_t ut[100];
    int nu = 0;
    for (size_t k = 0; k < users->cap; k++) {
        if (!users->keys[k]) continue;
        utop_t c = {users->vals[k], users->keys[k] - 1};
        if (nu == 100 && !(c.revenue > ut[99].revenue || (c.revenue == ut[99].revenue && c.user < ut[99].user)))
            continue;
        int at = nu < 100 ? nu++ : 99;
        while (at > 0 && (c.revenue > ut[at - 1].revenue ||
                          (c.revenue == ut[at - 1].revenue && c.user < ut[at - 1].user))) {
            ut[at] = ut[at - 1];
            at--;
        }
        ut[at] = c;
    }
    stop_t stp[10];
    int ns = 0;
    for (size_t k = 0; k < skus->cap; k++) {
        sslot_t *sl = &skus->slots[k];
        if (!sl->klen) continue;
        stop_t c = {.revenue = sl->val, .len = sl->klen};
        memcpy(c.sku, sl->key, sl->klen);
        #define AHEAD(a, b) ((a).revenue > (b).revenue || ((a).revenue == (b).revenue && sku_less((a).sku, (a).len, (b).sku, (b).len)))
        if (ns == 10 && !AHEAD(c, stp[9])) continue;
        int at = ns < 10 ? ns++ : 9;
        while (at > 0 && AHEAD(c, stp[at - 1])) {
            stp[at] = stp[at - 1];
            at--;
        }
        stp[at] = c;
    }

    char *out = NULL;
    size_t outlen = 0;
    FILE *o = open_memstream(&out, &outlen);
    fprintf(o, "rows=%" PRId64 "\n", rows);
    for (int a = 0; a < 26; a++)
        for (int b = 0; b < 26; b++) {
            region_t *r = &regions[a * 26 + b];
            if (r->seen)
                fprintf(o, "region=%c%c count=%" PRId64 " qty=%" PRId64 " revenue=%" PRId64 "\n",
                        'A' + a, 'A' + b, r->count, r->qty, r->revenue);
        }
    for (int i = 0; i < nu; i++)
        fprintf(o, "top_user rank=%d user_id=%" PRIu64 " revenue=%" PRId64 "\n", i + 1, ut[i].user, ut[i].revenue);
    for (int i = 0; i < ns; i++)
        fprintf(o, "top_sku rank=%d sku=%.*s revenue=%" PRId64 "\n", i + 1, stp[i].len, stp[i].sku, stp[i].revenue);
    fclose(o);
    fwrite(out, 1, outlen, stdout);
    return 0;
}
