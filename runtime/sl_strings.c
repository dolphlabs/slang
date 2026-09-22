/* The 'strings' package: search, trim, case, split and join on `str`.
 *
 * slang's `str` is a NUL-terminated UTF-8 byte string (see ctype_of:
 * `const char *`). Every index here is a BYTE offset and the case
 * operations only touch A-Z / a-z -- doing better means a Unicode table
 * and a normalisation policy, which is a different project. Callers
 * working in other scripts should read these as byte operations,
 * because that is what they are.
 *
 * Allocation goes through sl_gc_alloc, so every returned str is
 * collected like any other. Nothing here holds a pointer into its
 * input: a returned str is always a fresh copy, which is what lets a
 * caller keep a slice after the original goes out of scope.
 *
 * These are pure computation over memory slang already owns -- no
 * syscalls, no libc calls that allocate or lock -- so unlike sl_os.c
 * and sl_sql.c they need no preempt brackets. The one exception is
 * sl_strings_split, which builds a list and is bracketed where it
 * allocates through the array helpers. */

static char *sl_strings_dupn(const char *p, size_t n) {
    char *out = (char *)sl_gc_alloc(n + 1, NULL);
    if (n) memcpy(out, p, n);
    out[n] = 0;
    return out;
}

/* Byte offset of `needle` in `hay` at or after 0, or -1.
 *
 * An empty needle is found at 0. That is the convention memmem, Go's
 * strings.Index and byteutil.find all use, and it is what makes
 * split(s, "") terminate rather than loop. */
static long long sl_strings_find(const char *hay, const char *needle) {
    if (!hay || !needle) return -1;
    if (!*needle) return 0;
    const char *hit = strstr(hay, needle);
    return hit ? (long long)(hit - hay) : -1;
}

static long long sl_strings_rfind(const char *hay, const char *needle) {
    if (!hay || !needle) return -1;
    size_t nl = strlen(needle);
    if (!nl) return (long long)strlen(hay);
    size_t hl = strlen(hay);
    if (nl > hl) return -1;
    for (size_t i = hl - nl + 1; i-- > 0;)
        if (!memcmp(hay + i, needle, nl))
            return (long long)i;
    return -1;
}

static bool sl_strings_contains(const char *hay, const char *needle) {
    return sl_strings_find(hay, needle) >= 0;
}

static bool sl_strings_has_prefix(const char *s, const char *p) {
    if (!s || !p) return false;
    size_t n = strlen(p);
    return strlen(s) >= n && !memcmp(s, p, n);
}

static bool sl_strings_has_suffix(const char *s, const char *p) {
    if (!s || !p) return false;
    size_t sl = strlen(s), pl = strlen(p);
    return sl >= pl && !memcmp(s + sl - pl, p, pl);
}

/* Non-overlapping occurrences, the same count split() would produce
   minus one. An empty needle counts len+1 times, matching find's
   empty-needle rule. */
static long long sl_strings_count(const char *hay, const char *needle) {
    if (!hay || !needle) return 0;
    size_t nl = strlen(needle);
    if (!nl) return (long long)strlen(hay) + 1;
    long long n = 0;
    for (const char *p = hay; (p = strstr(p, needle)); p += nl)
        n++;
    return n;
}

static int sl_strings_is_space(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static char *sl_strings_trim_start(const char *s) {
    if (!s) return sl_strings_dupn("", 0);
    while (*s && sl_strings_is_space(*s)) s++;
    return sl_strings_dupn(s, strlen(s));
}

static char *sl_strings_trim_end(const char *s) {
    if (!s) return sl_strings_dupn("", 0);
    size_t n = strlen(s);
    while (n && sl_strings_is_space(s[n - 1])) n--;
    return sl_strings_dupn(s, n);
}

static char *sl_strings_trim(const char *s) {
    if (!s) return sl_strings_dupn("", 0);
    while (*s && sl_strings_is_space(*s)) s++;
    size_t n = strlen(s);
    while (n && sl_strings_is_space(s[n - 1])) n--;
    return sl_strings_dupn(s, n);
}

static char *sl_strings_to_upper(const char *s) {
    if (!s) return sl_strings_dupn("", 0);
    size_t n = strlen(s);
    char *out = sl_strings_dupn(s, n);
    for (size_t i = 0; i < n; i++)
        if (out[i] >= 'a' && out[i] <= 'z') out[i] = (char)(out[i] - 32);
    return out;
}

static char *sl_strings_to_lower(const char *s) {
    if (!s) return sl_strings_dupn("", 0);
    size_t n = strlen(s);
    char *out = sl_strings_dupn(s, n);
    for (size_t i = 0; i < n; i++)
        if (out[i] >= 'A' && out[i] <= 'Z') out[i] = (char)(out[i] + 32);
    return out;
}

/* Bytes [start, end). Out-of-range indices CLAMP rather than panic:
 * slicing is how a caller narrows a string they just searched, and
 * find() returning -1 on the line above should not turn the next line
 * into a crash. A negative index counts from the end, so slice(s, -3, 0)
 * with end <= 0 meaning "to the end" would be ambiguous -- end <= start
 * after clamping is simply the empty string. */
static char *sl_strings_slice(const char *s, long long start, long long end) {
    if (!s) return sl_strings_dupn("", 0);
    long long n = (long long)strlen(s);
    if (start < 0) start += n;
    if (end < 0) end += n;
    if (start < 0) start = 0;
    if (end > n) end = n;
    if (start >= n || end <= start) return sl_strings_dupn("", 0);
    return sl_strings_dupn(s + start, (size_t)(end - start));
}

static char *sl_strings_repeat(const char *s, long long times) {
    if (!s || times <= 0) return sl_strings_dupn("", 0);
    size_t n = strlen(s);
    if (!n) return sl_strings_dupn("", 0);
    /* Refuse rather than wrap: a repeat count from a request body that
       overflows size_t would otherwise allocate a tiny buffer and then
       write past it. */
    if ((unsigned long long)times > (SIZE_MAX - 1) / n)
        sl_rt_error("strings.repeat: result would overflow", times,
                    (long long)n);
    size_t total = n * (size_t)times;
    char *out = (char *)sl_gc_alloc(total + 1, NULL);
    for (long long i = 0; i < times; i++)
        memcpy(out + (size_t)i * n, s, n);
    out[total] = 0;
    return out;
}

static char *sl_strings_replace(const char *s, const char *old,
                                const char *neu) {
    if (!s) return sl_strings_dupn("", 0);
    if (!old || !*old) return sl_strings_dupn(s, strlen(s));
    if (!neu) neu = "";
    size_t ol = strlen(old), nl = strlen(neu);
    long long hits = sl_strings_count(s, old);
    if (hits <= 0) return sl_strings_dupn(s, strlen(s));
    size_t total = strlen(s) + (size_t)hits * nl - (size_t)hits * ol;
    char *out = (char *)sl_gc_alloc(total + 1, NULL);
    char *w = out;
    for (const char *p = s;;) {
        const char *hit = strstr(p, old);
        if (!hit) {
            size_t rest = strlen(p);
            memcpy(w, p, rest);
            w += rest;
            break;
        }
        memcpy(w, p, (size_t)(hit - p));
        w += hit - p;
        memcpy(w, neu, nl);
        w += nl;
        p = hit + ol;
    }
    *w = 0;
    return out;
}

/* Split on every occurrence of `sep`. Adjacent separators produce empty
 * elements, so the result always has count(s, sep) + 1 elements and
 * join(split(s, sep), sep) == s for any non-empty sep.
 *
 * An empty separator splits into single BYTES, not characters -- see
 * this file's header on why that distinction is deliberate.
 *
 * Bracketed: sl_arr_push allocates and can grow the backing store, and
 * the partially-built list is only reachable from this C frame, so the
 * safepoint holds it across every allocation. */
static sl_arr *sl_strings_split(const char *s, const char *sep) {
    sl_arr *out = sl_arr_new(sizeof(char *), 1);
    void *roots[1];
    sl_safepoint sp;
    if (!s) return out;
    roots[0] = (void *)out;
    sl_rt_safepoint_enter(&sp, roots, 1);
    if (!sep || !*sep) {
        for (const char *p = s; *p; p++) {
            char *one = sl_strings_dupn(p, 1);
            sl_arr_push(out, &one, sizeof(char *));
        }
    } else {
        size_t sl = strlen(sep);
        const char *p = s;
        for (;;) {
            const char *hit = strstr(p, sep);
            if (!hit) {
                char *last = sl_strings_dupn(p, strlen(p));
                sl_arr_push(out, &last, sizeof(char *));
                break;
            }
            char *piece = sl_strings_dupn(p, (size_t)(hit - p));
            sl_arr_push(out, &piece, sizeof(char *));
            p = hit + sl;
        }
    }
    sl_rt_safepoint_exit();
    return out;
}

static char *sl_strings_join(sl_arr *parts, const char *sep) {
    if (!parts || parts->len <= 0) return sl_strings_dupn("", 0);
    if (!sep) sep = "";
    size_t sepl = strlen(sep), total = 0;
    const char **items = (const char **)parts->data;
    for (long long i = 0; i < parts->len; i++)
        total += items[i] ? strlen(items[i]) : 0;
    total += sepl * (size_t)(parts->len - 1);
    char *out = (char *)sl_gc_alloc(total + 1, NULL);
    char *w = out;
    for (long long i = 0; i < parts->len; i++) {
        if (i && sepl) { memcpy(w, sep, sepl); w += sepl; }
        if (items[i]) {
            size_t n = strlen(items[i]);
            memcpy(w, items[i], n);
            w += n;
        }
    }
    *w = 0;
    return out;
}

/* The bytes counterpart of strings.join: one allocation for the result,
 * one copy of each piece. A list element is never NULL for [bytes]
 * built by the language, but the check costs nothing and a native
 * function should not trust its caller's list. */
/* One allocation for a str made from a byte range, where
   `to_str(b[lo..hi])` costs two: the slice, then the str built from it.
   Bounds are clamped the way strings.slice clamps, and a negative index
   counts from the end, so a caller cannot read outside the buffer. */
static char *sl_strings_from_bytes(sl_bytes *b, long long lo, long long hi) {
    long long n = b ? b->len : 0;
    if (lo < 0) lo += n;
    if (hi < 0) hi += n;
    if (lo < 0) lo = 0;
    if (hi > n) hi = n;
    if (!b || lo >= n || hi <= lo) return sl_strings_dupn("", 0);
    return sl_strings_dupn((const char *)(b->ptr + lo), (size_t)(hi - lo));
}

/* from_bytes, lowercasing ASCII during the copy. */
static char *sl_strings_from_bytes_lower(sl_bytes *b, long long lo,
                                         long long hi) {
    long long n = b ? b->len : 0;
    if (lo < 0) lo += n;
    if (hi < 0) hi += n;
    if (lo < 0) lo = 0;
    if (hi > n) hi = n;
    if (!b || lo >= n || hi <= lo) return sl_strings_dupn("", 0);
    char *out = sl_strings_dupn((const char *)(b->ptr + lo), (size_t)(hi - lo));
    for (long long i = 0; i < hi - lo; i++) {
        if (out[i] >= 'A' && out[i] <= 'Z') out[i] = (char)(out[i] + 32);
    }
    return out;
}

static sl_bytes *sl_strings_join_bytes(sl_arr *parts, sl_bytes *sep) {
    long long n = parts ? parts->len : 0;
    sl_bytes **items = parts ? (sl_bytes **)parts->data : NULL;
    long long sepl = sep ? sep->len : 0;
    long long total = 0;
    for (long long i = 0; i < n; i++)
        total += items[i] ? items[i]->len : 0;
    if (n > 1) total += sepl * (n - 1);
    sl_bytes *r = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    r->len = total;
    r->ptr = NULL;
    r->ptr = (unsigned char *)sl_gc_alloc((size_t)(total > 0 ? total : 1), NULL);
    unsigned char *w = r->ptr;
    for (long long i = 0; i < n; i++) {
        if (i && sepl) {
            memcpy(w, sep->ptr, (size_t)sepl);
            w += sepl;
        }
        if (items[i] && items[i]->len) {
            memcpy(w, items[i]->ptr, (size_t)items[i]->len);
            w += items[i]->len;
        }
    }
    return r;
}

/* Shortest round-trip: try 1..17 significant digits and keep the first
 * that strtod reads back as the same double. 17 always succeeds for an
 * IEEE double. NaN and the infinities use the spellings Postgres and
 * JavaScript accept, since printf's "nan"/"inf" parse nowhere useful.
 * snprintf/strtod are bracketed: both can take locale locks (see
 * sl_gc_alloc's comment in sl_gc.c). */
static char *sl_strings_from_float(double x) {
    if (x != x) return sl_strdup("NaN");
    if (x > 1.7976931348623157e308) return sl_strdup("Infinity");
    if (x < -1.7976931348623157e308) return sl_strdup("-Infinity");
    char buf[40];
    sl_rt_preempt_disable();
    for (int prec = 1; prec <= 17; prec++) {
        snprintf(buf, sizeof(buf), "%.*g", prec, x);
        if (strtod(buf, NULL) == x) break;
    }
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

