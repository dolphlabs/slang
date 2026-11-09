/* The 'unicode' package's runtime (runtime/sl_unicode.c) against the
 * Unicode Standard's own conformance data, read from tests/runtime/unicode/
 * at run time:
 *
 *   NormalizationTest.txt  every line's five columns through NFC and NFD,
 *                          both on code-point buffers and through the
 *                          UTF-8 entry points, is_nfc included; then every
 *                          code point the file does not list, which must
 *                          be unchanged by both forms
 *   CaseFolding.txt        every C and F mapping, and every other code
 *                          point folding to itself
 *
 * plus the Standard's maximal-subpart example for invalid UTF-8 (Table
 * 3-8), overlong and surrogate encodings, and the long-run canonical
 * ordering path checked against the short-run one.
 *
 * The data files carry their Unicode version in their first line; it
 * must match the tables' SL_UC_VERSION, so a table regenerated without
 * new test data (or the reverse) fails here instead of passing on stale
 * expectations. */

static int sl_runtime_test_main(void);

#define main sl_runtime_unused_main
#include "sl_core.c"
#include "sl_gc.c"
#include "sl_ryu_tables.c"
#include "sl_ryu.c"
#include "sl_containers.c"
#include "sl_sched.c"
#include "sl_pool.c"
#undef main

/* Emitted by codegen in a real program (emit_opt_res_types). */
typedef struct sl_opt_str sl_opt_str;
struct sl_opt_str {
    bool has;
    const char *v;
};
static void sl_gc_trace_sl_opt_str(void *p, void (*mark)(void *)) {
    sl_opt_str *o = (sl_opt_str *)p;
    mark((void *)o->v);
}

#include "sl_unicode_tables.c"
#include "sl_unicode.c"

#ifndef SL_UC_TEST_DIR
#define SL_UC_TEST_DIR "tests/runtime/unicode"
#endif

static int sl_uc_failures;
static unsigned long sl_uc_norm_cases, sl_uc_norm_others, sl_uc_fold_cases;

static void fail(const char *what, unsigned long line) {
    if (sl_uc_failures++ < 20)
        fprintf(stderr, "test_unicode: %s (line %lu)\n", what, line);
}

/* Parse "1E0A 0323" into b. */
static void parse_cps(sl_uc_buf *b, const char *s) {
    b->len = 0;
    while (*s) {
        while (*s == ' ') s++;
        if (!*s) break;
        char *end;
        unsigned long v = strtoul(s, &end, 16);
        sl_uc_buf_push(b, (uint32_t)v);
        s = end;
    }
}

static bool buf_eq(const sl_uc_buf *a, const sl_uc_buf *b) {
    return a->len == b->len &&
           memcmp(a->p, b->p, a->len * sizeof(uint32_t)) == 0;
}

/* NUL-terminated UTF-8 for b, malloc'd. */
static char *utf8_of(const sl_uc_buf *b) {
    char *s = (char *)malloc(b->len * 4 + 1);
    unsigned char *w = (unsigned char *)s;
    for (size_t i = 0; i < b->len; i++) w = sl_uc_put(w, b->p[i]);
    *w = 0;
    return s;
}

static FILE *open_data(const char *name, const char *want_prefix) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", SL_UC_TEST_DIR, name);
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "test_unicode: cannot open %s\n", path);
        return NULL;
    }
    char first[256], want[128];
    snprintf(want, sizeof want, "# %s-%s.txt", want_prefix, SL_UC_VERSION);
    if (!fgets(first, sizeof first, f) || strncmp(first, want, strlen(want))) {
        fprintf(stderr, "test_unicode: %s is not version %s\n", path,
                SL_UC_VERSION);
        fclose(f);
        return NULL;
    }
    return f;
}

static void nfc_buf(sl_uc_buf *out, const sl_uc_buf *in) {
    out->len = 0;
    sl_uc_decompose(out, in->p, in->len);
    sl_uc_compose(out);
}

static void nfd_buf(sl_uc_buf *out, const sl_uc_buf *in) {
    out->len = 0;
    sl_uc_decompose(out, in->p, in->len);
}

/* NFC and NFD of `src` must be `want_c` and `want_d`, by buffer and by str. */
static void check_forms(const sl_uc_buf *src, const sl_uc_buf *want_c,
                        const sl_uc_buf *want_d, unsigned long line) {
    sl_uc_buf got;
    sl_uc_buf_init(&got);
    nfc_buf(&got, src);
    if (!buf_eq(&got, want_c)) fail("NFC (buffer)", line);
    nfd_buf(&got, src);
    if (!buf_eq(&got, want_d)) fail("NFD (buffer)", line);
    sl_uc_buf_free(&got);

    char *s = utf8_of(src), *c = utf8_of(want_c), *d = utf8_of(want_d);
    if (strcmp(sl_unicode_nfc(s), c)) fail("NFC (str)", line);
    if (strcmp(sl_unicode_nfd(s), d)) fail("NFD (str)", line);
    if (sl_unicode_is_nfc(s) != (strcmp(s, c) == 0)) fail("is_nfc", line);
    /* An unchanged string comes back as itself, with no allocation. */
    if (!strcmp(s, c) && sl_unicode_nfc(s) != s) fail("nfc copied", line);
    if (!strcmp(s, d) && sl_unicode_nfd(s) != s) fail("nfd copied", line);
    free(s);
    free(c);
    free(d);
}

static int test_normalization(void) {
    FILE *f = open_data("NormalizationTest.txt", "NormalizationTest");
    if (!f) return 1;
    static unsigned char listed[0x110000];
    char line[1024];
    unsigned long ln = 1, cases = 0;
    int part = -1;
    sl_uc_buf col[5];
    for (int i = 0; i < 5; i++) sl_uc_buf_init(&col[i]);
    while (fgets(line, sizeof line, f)) {
        ln++;
        if (line[0] == '#' || line[0] == '\n') continue;
        if (line[0] == '@') {
            if (!strncmp(line, "@Part", 5)) part = atoi(line + 5);
            continue;
        }
        char *fields[5], *p = line;
        for (int i = 0; i < 5; i++) {
            fields[i] = p;
            p = strchr(p, ';');
            if (!p) { fail("malformed line", ln); goto next; }
            *p++ = 0;
        }
        for (int i = 0; i < 5; i++) parse_cps(&col[i], fields[i]);
        if (part == 1 && col[0].len == 1) listed[col[0].p[0]] = 1;
        /* c2 == NFC(c1) == NFC(c2) == NFC(c3); c4 == NFC(c4) == NFC(c5)
           c3 == NFD(c1) == NFD(c2) == NFD(c3); c5 == NFD(c4) == NFD(c5) */
        for (int i = 0; i < 3; i++) check_forms(&col[i], &col[1], &col[2], ln);
        for (int i = 3; i < 5; i++) check_forms(&col[i], &col[3], &col[4], ln);
        cases++;
    next:;
    }
    fclose(f);
    /* Everything not in Part 1 is its own NFC and NFD. */
    unsigned long others = 0;
    sl_uc_buf one, got;
    sl_uc_buf_init(&one);
    sl_uc_buf_init(&got);
    for (uint32_t cp = 1; cp < 0x110000; cp++) {
        if (listed[cp] || (cp >= 0xD800 && cp <= 0xDFFF)) continue;
        one.len = 0;
        sl_uc_buf_push(&one, cp);
        nfc_buf(&got, &one);
        if (!buf_eq(&got, &one)) fail("unlisted code point changed by NFC", cp);
        nfd_buf(&got, &one);
        if (!buf_eq(&got, &one)) fail("unlisted code point changed by NFD", cp);
        others++;
    }
    sl_uc_buf_free(&one);
    sl_uc_buf_free(&got);
    for (int i = 0; i < 5; i++) sl_uc_buf_free(&col[i]);
    sl_uc_norm_cases = cases;
    sl_uc_norm_others = others;
    return 0;
}

static int test_case_folding(void) {
    FILE *f = open_data("CaseFolding.txt", "CaseFolding");
    if (!f) return 1;
    static unsigned char mapped[0x110000];
    char line[512];
    unsigned long ln = 1, cases = 0;
    sl_uc_buf want, got, one;
    sl_uc_buf_init(&want);
    sl_uc_buf_init(&got);
    sl_uc_buf_init(&one);
    while (fgets(line, sizeof line, f)) {
        ln++;
        if (line[0] == '#' || line[0] == '\n') continue;
        char *code = strtok(line, ";");
        char *status = strtok(NULL, ";");
        char *mapping = strtok(NULL, ";");
        if (!code || !status || !mapping) { fail("malformed line", ln); continue; }
        while (*status == ' ') status++;
        if (*status != 'C' && *status != 'F') continue;
        uint32_t cp = (uint32_t)strtoul(code, NULL, 16);
        parse_cps(&want, mapping);
        one.len = 0;
        sl_uc_buf_push(&one, cp);
        got.len = 0;
        sl_uc_fold(&got, one.p, one.len);
        if (!buf_eq(&got, &want)) fail("fold mapping", ln);
        char *s = utf8_of(&one), *w = utf8_of(&want);
        if (strcmp(sl_unicode_fold(s), w)) fail("fold (str)", ln);
        free(s);
        free(w);
        mapped[cp] = 1;
        cases++;
    }
    fclose(f);
    for (uint32_t cp = 1; cp < 0x110000; cp++) {
        if (mapped[cp] || (cp >= 0xD800 && cp <= 0xDFFF)) continue;
        one.len = 0;
        sl_uc_buf_push(&one, cp);
        got.len = 0;
        sl_uc_fold(&got, one.p, one.len);
        if (!buf_eq(&got, &one)) fail("unmapped code point changed by fold", cp);
    }
    sl_uc_buf_free(&want);
    sl_uc_buf_free(&got);
    sl_uc_buf_free(&one);
    sl_uc_fold_cases = cases;
    return 0;
}

/* Bytes in, expected code points out (-1 for each U+FFFD). */
static void check_decode(const char *name, const unsigned char *in, size_t n,
                         const int32_t *want, size_t wn) {
    size_t i = 0, k = 0;
    while (i < n) {
        int32_t cp;
        i += sl_uc_decode(in + i, n - i, &cp);
        if (k >= wn || cp != want[k]) { fail(name, (unsigned long)k); return; }
        k++;
    }
    if (k != wn) fail(name, (unsigned long)k);
}

static int test_utf8(void) {
    /* The Unicode Standard, Table 3-8: a, then three maximal subparts,
       b, one, c, two, d. */
    static const unsigned char t38[] = {0x61, 0xF1, 0x80, 0x80, 0xE1, 0x80,
                                        0xC2, 0x62, 0x80, 0x63, 0x80, 0xBF,
                                        0x64};
    static const int32_t t38w[] = {'a', -1, -1, -1, 'b', -1, 'c', -1, -1, 'd'};
    check_decode("Table 3-8", t38, sizeof t38, t38w, 10);

    static const unsigned char overlong[] = {0xC0, 0xAF, 0xE0, 0x80, 0xAF};
    static const int32_t overlong_w[] = {-1, -1, -1, -1, -1};
    check_decode("overlong", overlong, sizeof overlong, overlong_w, 5);

    static const unsigned char surrogate[] = {0xED, 0xA0, 0x80};
    static const int32_t surrogate_w[] = {-1, -1, -1};
    check_decode("surrogate", surrogate, sizeof surrogate, surrogate_w, 3);

    static const unsigned char too_big[] = {0xF4, 0x90, 0x80, 0x80};
    static const int32_t too_big_w[] = {-1, -1, -1, -1};
    check_decode("past U+10FFFF", too_big, sizeof too_big, too_big_w, 4);

    static const unsigned char edges[] = {0x7F, 0xC2, 0x80, 0xDF, 0xBF, 0xE0,
                                          0xA0, 0x80, 0xED, 0x9F, 0xBF, 0xEE,
                                          0x80, 0x80, 0xEF, 0xBF, 0xBF, 0xF0,
                                          0x90, 0x80, 0x80, 0xF4, 0x8F, 0xBF,
                                          0xBF};
    static const int32_t edges_w[] = {0x7F, 0x80, 0x7FF, 0x800, 0xD7FF,
                                      0xE000, 0xFFFF, 0x10000, 0x10FFFF};
    check_decode("range edges", edges, sizeof edges, edges_w, 9);

    /* A truncated sequence at the end of the input. */
    static const unsigned char cut[] = {0x61, 0xE2, 0x82};
    static const int32_t cut_w[] = {'a', -1};
    check_decode("truncated", cut, sizeof cut, cut_w, 2);

    /* Repair through a transform: always valid UTF-8 out. */
    const char *fixed = sl_unicode_nfc((const char *)"a\xF1\x80\x80\xE1\x80\xC2" "b");
    if (strcmp(fixed, "a\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD" "b"))
        fail("nfc repair", 0);
    if (sl_unicode_valid("a\xC0\xAF")) fail("valid accepted an overlong", 0);
    if (!sl_unicode_valid("caf\xC3\xA9 \xF0\x9F\x98\x80")) fail("valid rejected", 0);
    if (sl_unicode_count("caf\xC3\xA9 \xF0\x9F\x98\x80") != 6) fail("count", 0);
    /* D145's first NFD: U+0345 folds to a starter (iota), so marks must
       be ordered before folding. Both strings are alpha + acute +
       ypogegrammeni, in the two orders. */
    if (!sl_unicode_equal_fold("\xCE\xB1\xCD\x85\xCC\x81",
                               "\xCE\xB1\xCC\x81\xCD\x85"))
        fail("equal_fold of canonically equivalent strings", 0);
    return 0;
}

/* The counting sort (runs over SL_UC_SMALL_RUN) must order exactly as
 * the insertion sort does, stability included. */
static int test_long_runs(void) {
    static const uint32_t marks[] = {0x0300, 0x0301, 0x0316, 0x0317, 0x0323,
                                     0x0327, 0x0345, 0x05B0, 0x0E38, 0x302A};
    uint64_t seed = 0x9e3779b97f4a7c15ull;
    for (int round = 0; round < 50; round++) {
        size_t k = 33 + (size_t)round * 40;
        sl_uc_buf a, b;
        sl_uc_buf_init(&a);
        sl_uc_buf_init(&b);
        for (size_t i = 0; i < k; i++) {
            seed = seed * 6364136223846793005ull + 1442695040888963407ull;
            uint32_t m = marks[(seed >> 33) % 10];
            sl_uc_buf_push(&a, m);
            sl_uc_buf_push(&b, m);
        }
        sl_uc_sort_run(a.p, a.len);
        /* reference: insertion sort over the whole run */
        for (size_t i = 1; i < b.len; i++) {
            uint32_t c = b.p[i];
            size_t j = i;
            while (j > 0 && sl_uc_ccc(b.p[j - 1]) > sl_uc_ccc(c)) {
                b.p[j] = b.p[j - 1];
                j--;
            }
            b.p[j] = c;
        }
        if (!buf_eq(&a, &b)) fail("long-run ordering", (unsigned long)k);
        sl_uc_buf_free(&a);
        sl_uc_buf_free(&b);
    }
    return 0;
}

static int sl_runtime_test_main(void) {
    int bad = test_utf8();
    bad |= test_long_runs();
    bad |= test_normalization();
    bad |= test_case_folding();
    if (bad || sl_uc_failures) {
        fprintf(stderr, "test_unicode: %d failure(s)\n", sl_uc_failures);
        return 1;
    }
    printf("PASS unicode conformance (Unicode %s): %lu normalization cases, "
           "%lu other code points, %lu case foldings\n",
           SL_UC_VERSION, sl_uc_norm_cases, sl_uc_norm_others,
           sl_uc_fold_cases);
    return 0;
}

int main(void) {
    return sl_runtime_test_main();
}
