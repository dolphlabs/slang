/* The 'unicode' package: UTF-8 validation and counting, code points,
 * truncation by character, full case folding and canonical
 * normalisation (NFC, NFD), per the Unicode Standard in
 * sl_unicode_tables.c (generated; see its header for the version).
 *
 * Why native: `str` cannot be indexed in slang, so a slang package would
 * copy every string to `bytes` before reading it. Here every function
 * reads the str's bytes in place. The checks (valid, count, is_nfc and
 * the common case of equal_fold) allocate nothing, and the transforms
 * (fold, nfc, nfd, truncate) return their input unchanged, with no
 * allocation, when it is already in the requested form -- which is
 * almost all real text, ASCII included.
 *
 * Invalid UTF-8. A str can hold any bytes (to_str of a request body, for
 * one). The checks report it; every transform replaces each maximal
 * invalid subsequence with U+FFFD, the substitution the Unicode Standard
 * recommends (section 3.9, "U+FFFD Substitution of Maximal Subparts"),
 * so a transform's output is always valid UTF-8. Code that must refuse
 * bad input rather than repair it calls valid() first.
 *
 * Structure. The algorithms run over uint32 code-point buffers
 * (sl_uc_buf), with no GC involvement, which is what lets the C
 * conformance test (tests/runtime/test_unicode.c) drive them with the
 * full NormalizationTest.txt. The sl_unicode_* entry points at the end
 * decode, run a pipeline, and make one GC allocation for the result.
 * Scratch buffers start on the C stack (a few dozen bytes each) and
 * move to malloc for anything longer; malloc and free are preempt-bracketed (AGENTS.md: a task
 * preempted inside the allocator abandons its lock).
 *
 * Hostile input. Canonical reordering sorts each run of combining marks.
 * Insertion sort is quadratic, so a str of 100k combining marks would
 * be a denial of service; runs longer than SL_UC_SMALL_RUN are sorted
 * with a stable counting sort by combining class, linear in the run. */

/* Code points held on the C stack before a buffer moves to malloc. Task
   stacks start at 8 KB and cannot grow inside C (AGENTS.md), and
   equal_fold holds four buffers at once, so this stays small. */
#define SL_UC_INLINE 16
#define SL_UC_SMALL_RUN 32   /* insertion-sort runs up to this long */
#define SL_UC_REPLACEMENT 0xFFFDu

/* ---- table lookup -------------------------------------------------------- */

static inline const sl_uc_rec *sl_uc_rec_of(uint32_t cp) {
    if (cp >= 0x110000u) return &SL_UC_RECS[0];
    uint32_t blk = SL_UC_STAGE1[cp >> SL_UC_SHIFT];
    return &SL_UC_RECS[SL_UC_STAGE2[(blk << SL_UC_SHIFT) |
                                    (cp & ((1u << SL_UC_SHIFT) - 1))]];
}

static inline uint8_t sl_uc_ccc(uint32_t cp) {
    return cp < 0x300u ? 0 : sl_uc_rec_of(cp)->ccc;
}

/* Hangul syllables decompose and compose arithmetically (Unicode 3.12). */
#define SL_UC_SBASE 0xAC00u
#define SL_UC_LBASE 0x1100u
#define SL_UC_VBASE 0x1161u
#define SL_UC_TBASE 0x11A7u
#define SL_UC_LCOUNT 19u
#define SL_UC_VCOUNT 21u
#define SL_UC_TCOUNT 28u
#define SL_UC_NCOUNT (SL_UC_VCOUNT * SL_UC_TCOUNT)
#define SL_UC_SCOUNT (SL_UC_LCOUNT * SL_UC_NCOUNT)

/* The composite of a canonical pair, or 0 if they do not compose. */
static uint32_t sl_uc_compose_pair(uint32_t a, uint32_t b) {
    if (a - SL_UC_LBASE < SL_UC_LCOUNT && b - SL_UC_VBASE < SL_UC_VCOUNT)
        return SL_UC_SBASE + ((a - SL_UC_LBASE) * SL_UC_VCOUNT +
                              (b - SL_UC_VBASE)) * SL_UC_TCOUNT;
    if (a - SL_UC_SBASE < SL_UC_SCOUNT &&
        (a - SL_UC_SBASE) % SL_UC_TCOUNT == 0 &&
        b - SL_UC_TBASE - 1 < SL_UC_TCOUNT - 1)
        return a + (b - SL_UC_TBASE);
    size_t lo = 0, hi = SL_UC_NPAIRS;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        const uint32_t *p = SL_UC_PAIRS[mid];
        if (p[0] < a || (p[0] == a && p[1] < b)) lo = mid + 1;
        else hi = mid;
    }
    if (lo < SL_UC_NPAIRS && SL_UC_PAIRS[lo][0] == a && SL_UC_PAIRS[lo][1] == b)
        return SL_UC_PAIRS[lo][2];
    return 0;
}

/* ---- UTF-8 ---------------------------------------------------------------- */

/* Decode one character from p[0..n), n >= 1. Returns the bytes it spans
 * and sets *cp; for an invalid sequence, returns the length of its
 * maximal subpart (at least 1) and sets *cp to -1. The ranges are the
 * Unicode Standard's Table 3-7, which also rules out overlong forms,
 * surrogates and anything past U+10FFFF. */
static inline size_t sl_uc_decode(const unsigned char *p, size_t n,
                                  int32_t *cp) {
    unsigned b0 = p[0];
    if (b0 < 0x80) { *cp = (int32_t)b0; return 1; }
    unsigned need, lo = 0x80, hi = 0xBF;
    uint32_t v;
    if (b0 >= 0xC2 && b0 <= 0xDF) { need = 1; v = b0 & 0x1F; }
    else if (b0 >= 0xE0 && b0 <= 0xEF) {
        need = 2; v = b0 & 0x0F;
        if (b0 == 0xE0) lo = 0xA0;
        else if (b0 == 0xED) hi = 0x9F;
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
        need = 3; v = b0 & 0x07;
        if (b0 == 0xF0) lo = 0x90;
        else if (b0 == 0xF4) hi = 0x8F;
    } else { *cp = -1; return 1; }
    size_t i = 1;
    for (unsigned k = 0; k < need; k++, i++) {
        if (i >= n) { *cp = -1; return i; }
        unsigned b = p[i];
        if (b < lo || b > hi) { *cp = -1; return i; }
        v = (v << 6) | (b & 0x3F);
        lo = 0x80; hi = 0xBF;
    }
    *cp = (int32_t)v;
    return i;
}

static inline size_t sl_uc_utf8_len(uint32_t cp) {
    return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
}

static inline unsigned char *sl_uc_put(unsigned char *w, uint32_t cp) {
    if (cp < 0x80) { *w++ = (unsigned char)cp; }
    else if (cp < 0x800) {
        *w++ = (unsigned char)(0xC0 | (cp >> 6));
        *w++ = (unsigned char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        *w++ = (unsigned char)(0xE0 | (cp >> 12));
        *w++ = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        *w++ = (unsigned char)(0x80 | (cp & 0x3F));
    } else {
        *w++ = (unsigned char)(0xF0 | (cp >> 18));
        *w++ = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        *w++ = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        *w++ = (unsigned char)(0x80 | (cp & 0x3F));
    }
    return w;
}

/* Length of the leading ASCII run of p[0..n), eight bytes at a time. */
static inline size_t sl_uc_ascii_prefix(const unsigned char *p, size_t n) {
    size_t i = 0;
    while (i + 8 <= n) {
        uint64_t w;
        memcpy(&w, p + i, 8);
        if (w & 0x8080808080808080ull) break;
        i += 8;
    }
    while (i < n && p[i] < 0x80) i++;
    return i;
}

static bool sl_uc_valid_n(const unsigned char *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        i += sl_uc_ascii_prefix(p + i, n - i);
        if (i >= n) break;
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        if (cp < 0) return false;
    }
    return true;
}

/* ---- code-point buffers --------------------------------------------------- */

typedef struct {
    uint32_t *p;
    size_t len, cap;
    uint32_t inl[SL_UC_INLINE];
} sl_uc_buf;

static void sl_uc_buf_init(sl_uc_buf *b) {
    b->p = b->inl;
    b->len = 0;
    b->cap = SL_UC_INLINE;
}

static void sl_uc_buf_free(sl_uc_buf *b) {
    if (b->p != b->inl) {
        sl_rt_preempt_disable();
        free(b->p);
        sl_rt_preempt_enable();
    }
    sl_uc_buf_init(b);
}

/* Make room for `extra` more code points. Out of memory is fatal, the
 * same as for a GC allocation: there is no partial answer to return. */
static void sl_uc_buf_reserve(sl_uc_buf *b, size_t extra) {
    if (b->len + extra <= b->cap) return;
    size_t cap = b->cap;
    while (cap < b->len + extra) {
        if (cap > SIZE_MAX / 2 / sizeof(uint32_t)) {
            fprintf(stderr, "slang: unicode: string too large\n");
            abort();
        }
        cap *= 2;
    }
    sl_rt_preempt_disable();
    uint32_t *np = (uint32_t *)malloc(cap * sizeof(uint32_t));
    sl_rt_preempt_enable();
    if (!np) {
        fprintf(stderr, "slang: unicode: out of memory\n");
        abort();
    }
    memcpy(np, b->p, b->len * sizeof(uint32_t));
    uint32_t *old = b->p;
    b->p = np;
    b->cap = cap;
    if (old != b->inl) {
        sl_rt_preempt_disable();
        free(old);
        sl_rt_preempt_enable();
    }
}

static inline void sl_uc_buf_push(sl_uc_buf *b, uint32_t cp) {
    if (b->len == b->cap) sl_uc_buf_reserve(b, 1);
    b->p[b->len++] = cp;
}

/* Decode p[0..n) into b, invalid subparts as U+FFFD. */
static void sl_uc_decode_all(sl_uc_buf *b, const unsigned char *p, size_t n) {
    sl_uc_buf_reserve(b, n);  /* never more code points than bytes */
    size_t i = 0;
    while (i < n) {
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        b->p[b->len++] = cp < 0 ? SL_UC_REPLACEMENT : (uint32_t)cp;
    }
}

/* ---- canonical ordering --------------------------------------------------- */

/* Stable sort of run[0..k) by combining class; every element has
 * ccc > 0. Insertion sort for short runs (the norm: one to three marks),
 * a counting sort for long ones so hostile input stays linear. */
static void sl_uc_sort_run(uint32_t *run, size_t k) {
    if (k < 2) return;
    if (k <= SL_UC_SMALL_RUN) {
        for (size_t i = 1; i < k; i++) {
            uint32_t c = run[i];
            uint8_t cc = sl_uc_ccc(c);
            size_t j = i;
            while (j > 0 && sl_uc_ccc(run[j - 1]) > cc) {
                run[j] = run[j - 1];
                j--;
            }
            run[j] = c;
        }
        return;
    }
    /* One heap block: 256 bucket offsets, then the sorted copy. A run is
       never longer than its str in bytes, so k + 256 cannot overflow. */
    sl_uc_buf tmp;
    sl_uc_buf_init(&tmp);
    sl_uc_buf_reserve(&tmp, 256 + k);
    uint32_t *count = tmp.p, *sorted = tmp.p + 256;
    memset(count, 0, 256 * sizeof(uint32_t));
    for (size_t i = 0; i < k; i++) count[sl_uc_ccc(run[i])]++;
    uint32_t at = 0;
    for (int c = 0; c < 256; c++) {
        uint32_t n = count[c];
        count[c] = at;
        at += n;
    }
    for (size_t i = 0; i < k; i++) sorted[count[sl_uc_ccc(run[i])]++] = run[i];
    memcpy(run, sorted, k * sizeof(uint32_t));
    sl_uc_buf_free(&tmp);
}

/* Put every run of non-starters in b into canonical order. */
static void sl_uc_reorder(sl_uc_buf *b) {
    size_t i = 0;
    while (i < b->len) {
        if (sl_uc_ccc(b->p[i]) == 0) { i++; continue; }
        size_t start = i;
        while (i < b->len && sl_uc_ccc(b->p[i]) != 0) i++;
        sl_uc_sort_run(b->p + start, i - start);
    }
}

/* ---- the pipelines -------------------------------------------------------- */

/* out = the full canonical decomposition of in, canonically ordered. */
static void sl_uc_decompose(sl_uc_buf *out, const uint32_t *in, size_t n) {
    sl_uc_buf_reserve(out, n);
    for (size_t i = 0; i < n; i++) {
        uint32_t c = in[i];
        if (c < 0xC0) { sl_uc_buf_push(out, c); continue; }
        if (c - SL_UC_SBASE < SL_UC_SCOUNT) {
            uint32_t s = c - SL_UC_SBASE;
            sl_uc_buf_reserve(out, 3);
            out->p[out->len++] = SL_UC_LBASE + s / SL_UC_NCOUNT;
            out->p[out->len++] = SL_UC_VBASE + (s % SL_UC_NCOUNT) / SL_UC_TCOUNT;
            if (s % SL_UC_TCOUNT)
                out->p[out->len++] = SL_UC_TBASE + s % SL_UC_TCOUNT;
            continue;
        }
        uint16_t d = sl_uc_rec_of(c)->decomp;
        if (!d) { sl_uc_buf_push(out, c); continue; }
        uint32_t k = SL_UC_DATA[d];
        sl_uc_buf_reserve(out, k);
        for (uint32_t j = 1; j <= k; j++) out->p[out->len++] = SL_UC_DATA[d + j];
    }
    sl_uc_reorder(out);
}

/* Canonical composition of a decomposed, ordered buffer, in place:
 * the algorithm of UAX #15's reference code (Unicode 3.11, D117). `last`
 * is the combining class of the last character kept since the starter,
 * 0 when the starter is the last one kept, and 256 before any starter
 * has been seen, which blocks everything. A character composes with the
 * starter unless something between them blocks it: a class 0 character
 * or one with a class at least its own. */
static void sl_uc_compose(sl_uc_buf *b) {
    if (b->len < 2) return;
    size_t starter = 0, w = 1;
    int last = sl_uc_ccc(b->p[0]) ? 256 : 0;
    for (size_t r = 1; r < b->len; r++) {
        uint32_t c = b->p[r];
        int cc = sl_uc_ccc(c);
        if (last < cc || last == 0) {
            uint32_t comp = sl_uc_compose_pair(b->p[starter], c);
            if (comp) {
                b->p[starter] = comp;
                continue;
            }
        }
        if (cc == 0) starter = w;
        last = cc;
        b->p[w++] = c;
    }
    b->len = w;
}

/* out = the full case folding of in. */
static void sl_uc_fold(sl_uc_buf *out, const uint32_t *in, size_t n) {
    sl_uc_buf_reserve(out, n);
    for (size_t i = 0; i < n; i++) {
        uint32_t c = in[i];
        if (c < 0x80) {
            sl_uc_buf_push(out, c >= 'A' && c <= 'Z' ? c + 32 : c);
            continue;
        }
        uint16_t f = sl_uc_rec_of(c)->fold;
        if (!f) { sl_uc_buf_push(out, c); continue; }
        uint32_t k = SL_UC_DATA[f];
        sl_uc_buf_reserve(out, k);
        for (uint32_t j = 1; j <= k; j++) out->p[out->len++] = SL_UC_DATA[f + j];
    }
}

/* Quick checks (UAX #15 section 9). Returns 1 for certainly yes, 0 for
 * certainly no, -1 for "compute and compare". Invalid UTF-8 is never in
 * any form: a transform would change it. */
static int sl_uc_quick_nfc(const unsigned char *p, size_t n) {
    int result = 1;
    uint8_t last = 0;
    size_t i = 0;
    while (i < n) {
        size_t a = sl_uc_ascii_prefix(p + i, n - i);
        if (a) { i += a; last = 0; if (i >= n) break; }
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        if (cp < 0) return 0;
        const sl_uc_rec *r = sl_uc_rec_of((uint32_t)cp);
        if (r->ccc && last > r->ccc) return 0;
        if (r->flags & SL_UC_QC_NO) return 0;
        if (r->flags & SL_UC_QC_MAYBE) result = -1;
        last = r->ccc;
    }
    return result;
}

/* NFD has no Maybe: a string is in NFD exactly when no character has a
 * canonical decomposition and every run of marks is in order. */
static bool sl_uc_is_nfd(const unsigned char *p, size_t n) {
    uint8_t last = 0;
    size_t i = 0;
    while (i < n) {
        size_t a = sl_uc_ascii_prefix(p + i, n - i);
        if (a) { i += a; last = 0; if (i >= n) break; }
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        if (cp < 0) return false;
        uint32_t c = (uint32_t)cp;
        if (c - SL_UC_SBASE < SL_UC_SCOUNT) return false;
        const sl_uc_rec *r = sl_uc_rec_of(c);
        if (r->decomp) return false;
        if (r->ccc && last > r->ccc) return false;
        last = r->ccc;
    }
    return true;
}

/* NFC of p[0..n) into out. */
static void sl_uc_nfc_into(sl_uc_buf *out, const unsigned char *p, size_t n) {
    sl_uc_buf in;
    sl_uc_buf_init(&in);
    sl_uc_decode_all(&in, p, n);
    sl_uc_decompose(out, in.p, in.len);
    sl_uc_buf_free(&in);
    sl_uc_compose(out);
}

static bool sl_uc_same(const sl_uc_buf *b, const unsigned char *p, size_t n) {
    size_t i = 0;
    for (size_t k = 0; k < b->len; k++) {
        if (i >= n) return false;
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        if (cp < 0 || (uint32_t)cp != b->p[k]) return false;
    }
    return i == n;
}

/* ---- results -------------------------------------------------------------- */

/* One GC allocation: the str for b's code points. */
static char *sl_uc_to_str(const sl_uc_buf *b) {
    size_t n = 0;
    for (size_t i = 0; i < b->len; i++) n += sl_uc_utf8_len(b->p[i]);
    char *out = (char *)sl_gc_alloc_leaf_uninit(n + 1, NULL);
    unsigned char *w = (unsigned char *)out;
    for (size_t i = 0; i < b->len; i++) w = sl_uc_put(w, b->p[i]);
    *w = 0;
    return out;
}

static const char *sl_uc_empty(void) {
    char *out = (char *)sl_gc_alloc_leaf_uninit(1, NULL);
    out[0] = 0;
    return out;
}

/* ---- the package ---------------------------------------------------------- */

static bool sl_unicode_valid(const char *s) {
    if (!s) return true;
    return sl_uc_valid_n((const unsigned char *)s, strlen(s));
}

static bool sl_unicode_valid_bytes(sl_bytes *b) {
    if (!b) return true;
    return sl_uc_valid_n(b->ptr, (size_t)b->len);
}

/* Characters in valid UTF-8: every byte that is not a continuation byte
 * (10xxxxxx) starts one. Eight bytes at a time: a byte is a continuation
 * byte exactly when bit 7 is set and bit 6 is clear. */
static long long sl_uc_count_valid(const unsigned char *p, size_t n) {
    size_t cont = 0, i = 0;
    while (i + 8 <= n) {
        uint64_t w;
        memcpy(&w, p + i, 8);
        uint64_t c = w & ~(w << 1) & 0x8080808080808080ull;
        cont += (size_t)__builtin_popcountll(c);
        i += 8;
    }
    for (; i < n; i++) cont += (p[i] & 0xC0) == 0x80;
    return (long long)(n - cont);
}

/* Characters (code points); each invalid subpart counts as one, as it
   would after repair. Valid input, the norm, takes the fast count. */
static long long sl_unicode_count(const char *s) {
    if (!s) return 0;
    const unsigned char *p = (const unsigned char *)s;
    size_t n = strlen(s), i = 0;
    if (sl_uc_valid_n(p, n)) return sl_uc_count_valid(p, n);
    long long count = 0;
    while (i < n) {
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        count++;
    }
    return count;
}

/* The code points of s, invalid subparts as U+FFFD (65533). */
static sl_arr *sl_unicode_runes(const char *s) {
    size_t n = s ? strlen(s) : 0;
    sl_arr *out = sl_arr_new(sizeof(long long),
                             (long long)(sl_unicode_count(s) + 1));
    const unsigned char *p = (const unsigned char *)s;
    size_t i = 0;
    while (i < n) {
        int32_t cp;
        i += sl_uc_decode(p + i, n - i, &cp);
        long long v = cp < 0 ? (long long)SL_UC_REPLACEMENT : (long long)cp;
        sl_arr_push(out, &v, sizeof(long long));
    }
    return out;
}

/* The UTF-8 for one code point, or none: negative, a surrogate, past
   U+10FFFF, or U+0000, which a str (NUL-terminated) cannot hold. */
static sl_opt_str *sl_unicode_encode(long long cp) {
    sl_opt_str *o =
        (sl_opt_str *)sl_gc_alloc(sizeof(sl_opt_str), sl_gc_trace_sl_opt_str);
    o->has = false;
    if (cp <= 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return o;
    char *out = (char *)sl_gc_alloc_leaf_uninit(5, NULL);
    unsigned char *w = sl_uc_put((unsigned char *)out, (uint32_t)cp);
    *w = 0;
    o->v = out;
    o->has = true;
    return o;
}

/* The first n characters of s. s itself when it is valid and no longer
   than that; a negative n reads as 0. */
static const char *sl_unicode_truncate(const char *s, long long n) {
    if (!s || n <= 0) return sl_uc_empty();
    const unsigned char *p = (const unsigned char *)s;
    size_t len = strlen(s), i = 0;
    long long chars = 0;
    bool clean = true;
    while (i < len && chars < n) {
        int32_t cp;
        i += sl_uc_decode(p + i, len - i, &cp);
        if (cp < 0) clean = false;
        chars++;
    }
    if (clean && i == len) return s;
    if (clean) {
        char *out = (char *)sl_gc_alloc_leaf_uninit(i + 1, NULL);
        memcpy(out, s, i);
        out[i] = 0;
        return out;
    }
    sl_uc_buf b;
    sl_uc_buf_init(&b);
    sl_uc_decode_all(&b, p, i);
    const char *out = sl_uc_to_str(&b);
    sl_uc_buf_free(&b);
    return out;
}

static const char *sl_unicode_fold(const char *s) {
    if (!s) return sl_uc_empty();
    const unsigned char *p = (const unsigned char *)s;
    size_t n = strlen(s);
    size_t a = sl_uc_ascii_prefix(p, n);
    if (a == n) {
        /* ASCII: unchanged unless it has an upper-case letter. */
        size_t i = 0;
        while (i < n && !(p[i] >= 'A' && p[i] <= 'Z')) i++;
        if (i == n) return s;
        char *out = (char *)sl_gc_alloc_leaf_uninit(n + 1, NULL);
        for (size_t k = 0; k < n; k++)
            out[k] = (char)(p[k] >= 'A' && p[k] <= 'Z' ? p[k] + 32 : p[k]);
        out[n] = 0;
        return out;
    }
    sl_uc_buf in, out;
    sl_uc_buf_init(&in);
    sl_uc_buf_init(&out);
    sl_uc_decode_all(&in, p, n);
    sl_uc_fold(&out, in.p, in.len);
    const char *r = sl_uc_same(&out, p, n) ? s : sl_uc_to_str(&out);
    sl_uc_buf_free(&in);
    sl_uc_buf_free(&out);
    return r;
}

static const char *sl_unicode_nfd(const char *s) {
    if (!s) return sl_uc_empty();
    const unsigned char *p = (const unsigned char *)s;
    size_t n = strlen(s);
    if (sl_uc_is_nfd(p, n)) return s;
    sl_uc_buf in, out;
    sl_uc_buf_init(&in);
    sl_uc_buf_init(&out);
    sl_uc_decode_all(&in, p, n);
    sl_uc_decompose(&out, in.p, in.len);
    const char *r = sl_uc_to_str(&out);
    sl_uc_buf_free(&in);
    sl_uc_buf_free(&out);
    return r;
}

static const char *sl_unicode_nfc(const char *s) {
    if (!s) return sl_uc_empty();
    const unsigned char *p = (const unsigned char *)s;
    size_t n = strlen(s);
    int q = sl_uc_quick_nfc(p, n);
    if (q == 1) return s;
    sl_uc_buf out;
    sl_uc_buf_init(&out);
    sl_uc_nfc_into(&out, p, n);
    const char *r = (q == -1 && sl_uc_same(&out, p, n)) ? s : sl_uc_to_str(&out);
    sl_uc_buf_free(&out);
    return r;
}

static bool sl_unicode_is_nfc(const char *s) {
    if (!s) return true;
    const unsigned char *p = (const unsigned char *)s;
    size_t n = strlen(s);
    int q = sl_uc_quick_nfc(p, n);
    if (q >= 0) return q == 1;
    sl_uc_buf out;
    sl_uc_buf_init(&out);
    sl_uc_nfc_into(&out, p, n);
    bool same = sl_uc_same(&out, p, n);
    sl_uc_buf_free(&out);
    return same;
}

/* The canonical caseless match of Unicode 3.13, D145:
   NFD(fold(NFD(x))) for each side, compared. */
static void sl_uc_caseless_key(sl_uc_buf *out, const unsigned char *p,
                               size_t n) {
    sl_uc_buf a, b;
    sl_uc_buf_init(&a);
    sl_uc_buf_init(&b);
    sl_uc_decode_all(&a, p, n);
    sl_uc_decompose(&b, a.p, a.len);
    a.len = 0;
    sl_uc_fold(&a, b.p, b.len);
    sl_uc_decompose(out, a.p, a.len);
    sl_uc_buf_free(&a);
    sl_uc_buf_free(&b);
}

static bool sl_unicode_equal_fold(const char *x, const char *y) {
    if (!x) x = "";
    if (!y) y = "";
    const unsigned char *p = (const unsigned char *)x;
    const unsigned char *q = (const unsigned char *)y;
    /* One pass over the ASCII prefix both strings share, with no strlen.
       Two ASCII bytes that differ after lower-casing settle it: an ASCII
       letter is its own NFD and folds only to ASCII, so the two keys
       differ at that position whatever follows. Any non-ASCII byte goes
       to the full match, because some non-ASCII characters fold to
       ASCII (U+212A KELVIN SIGN to k, U+017F LONG S to s). */
    size_t i = 0;
    for (;; i++) {
        unsigned a = p[i], b = q[i];
        /* identical ASCII bytes first: most of any two names that match */
        if (a == b) {
            if (a == 0) return true;
            if (a < 0x80) continue;
            break;
        }
        if ((a | b) >= 0x80) break;
        /* differ: equal only as two cases of one letter (0 is not one) */
        if ((a | 0x20) != (b | 0x20) || (unsigned)((a | 0x20) - 'a') > 25)
            return false;
    }
    /* The full match on what is left. The bytes before i are ASCII
       starters that already match, and neither NFD nor folding moves
       anything across a starter, so both keys begin with the same
       prefix and it can be dropped. */
    p += i;
    q += i;
    size_t n = strlen((const char *)p), m = strlen((const char *)q);
    sl_uc_buf kx, ky;
    sl_uc_buf_init(&kx);
    sl_uc_buf_init(&ky);
    sl_uc_caseless_key(&kx, p, n);
    sl_uc_caseless_key(&ky, q, m);
    bool eq = kx.len == ky.len &&
              memcmp(kx.p, ky.p, kx.len * sizeof(uint32_t)) == 0;
    sl_uc_buf_free(&kx);
    sl_uc_buf_free(&ky);
    return eq;
}
