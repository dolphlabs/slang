/* The 'encoding' package: hex, base64, base64url, percent-encoding,
 * query strings, and binary float conversion.
 *
 * All of it is pure computation over memory slang already owns -- no
 * syscalls, no libc call that allocates or takes a lock -- so like
 * sl_strings.c and unlike sl_os.c / sl_sql.c none of it needs a preempt
 * bracket. The one exception is sl_encoding_query_keys, which builds a
 * list through sl_arr_push and is bracketed with a safepoint where it
 * allocates, exactly as sl_strings_split is.
 *
 * ---- str vs bytes, and why %00 is an error -------------------------
 *
 * slang's `str` is a NUL-TERMINATED UTF-8 byte string (ctype_of:
 * `const char *`); `bytes` carries an explicit length. That difference
 * decides every return type here and is not cosmetic:
 *
 *   - hex_decode and base64_decode yield arbitrary bytes, so they
 *     return `bytes`. A zero byte in a decoded key or digest is
 *     ordinary data and round-trips exactly.
 *
 *   - url_decode and form_decode yield text, so they return `str`. A
 *     literal "%00" in the input therefore CANNOT be represented: the
 *     NUL would terminate the string early and the caller would see a
 *     silently truncated value while len() reported the short length --
 *     precisely the class of bug the README's error-model rule exists
 *     to prevent. They reject it with a message instead. A caller who
 *     genuinely wants an embedded NUL from a percent-escape wants
 *     bytes, and should be decoding with hex or base64.
 *
 * ---- strictness ----------------------------------------------------
 *
 * The decoders reject rather than repair, the same choice to_int made:
 * a caller who wants leniency can pre-process, while a caller handed
 * leniency they did not ask for cannot undo it. Concretely, a truncated
 * base64 credential fails loudly here rather than comparing unequal to
 * the right one three call frames later.
 *
 * Every error message names the byte OFFSET where it gave up, because
 * "invalid base64" about a 400-character token is not a diagnosis. */

#include <float.h>

_Static_assert(sizeof(double) == 8 && DBL_MANT_DIG == 53 &&
                   DBL_MAX_EXP == 1024,
               "encoding.float64_* requires IEEE-754 binary64 double");

/* hex_encode emits lowercase, percent-escapes emit uppercase. Not an
 * inconsistency -- each follows its own norm. RFC 3986 section 2.1 says
 * URI producers SHOULD use uppercase for percent-encodings, and every
 * browser and HTTP library does; digests, by contrast, are lowercase
 * everywhere (sha256sum, git, every API that returns one), and a
 * checksum that does not string-compare against the reference tool's
 * output is a checksum nobody can use. Both decoders accept either. */
static const char SL_ENC_HEX_LOWER[] = "0123456789abcdef";
static const char SL_ENC_HEX_UPPER[] = "0123456789ABCDEF";

static const char SL_ENC_B64_STD[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char SL_ENC_B64_URL[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/* ---- result/opt constructors ---------------------------------------
 *
 * Same shape as sl_os.c's and sl_crypto.c's: allocate through
 * sl_gc_alloc with the matching tracer so the value is collected like
 * any other, and copy the message with sl_strdup so a caller may keep
 * it after the frame that produced it is gone. */

static sl_res_bytes_str *sl_enc_ok_bytes(sl_bytes *b) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = true;
    r->v = b;
    return r;
}

static sl_res_bytes_str *sl_enc_err_bytes(const char *msg) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_float_str *sl_enc_ok_float(double value) {
    sl_res_float_str *r = (sl_res_float_str *)sl_gc_alloc(
        sizeof(sl_res_float_str), sl_gc_trace_sl_res_float_str);
    r->ok = true;
    r->v = value;
    return r;
}

static sl_res_float_str *sl_enc_err_float(const char *msg) {
    sl_res_float_str *r = (sl_res_float_str *)sl_gc_alloc(
        sizeof(sl_res_float_str), sl_gc_trace_sl_res_float_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static sl_res_str_str *sl_enc_ok_str(char *v) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_str_str *sl_enc_err_str(const char *msg) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(
        sizeof(sl_res_str_str), sl_gc_trace_sl_res_str_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* Messages are formatted into a buffer the CALLER owns -- on its own C
 * stack -- and the err_* constructors copy them with sl_strdup, so
 * nothing here escapes the frame.
 *
 * The buffer is a parameter rather than a static or a _Thread_local
 * because a task can be async-preempted between the snprintf and the
 * copy and resume on a different worker: thread-local storage would
 * then be a DIFFERENT thread's buffer, and the error message would come
 * from whatever else was decoding at that moment. A stack buffer moves
 * with the task (stack relocation rewrites the pointer), so it stays
 * correct across that migration. */
static char *sl_enc_msg(char *buf, size_t bufn, const char *what,
                        long long at) {
    snprintf(buf, bufn, "%s at offset %lld", what, at);
    return buf;
}

/* sl_bytes_new COPIES from its argument, so it cannot allocate a buffer
 * to be filled in place -- passing NULL with a nonzero length memcpys
 * from NULL. The decoders below know the exact output size up front and
 * write every byte of it, so they allocate the same shape directly. */
static sl_bytes *sl_enc_bytes_raw(long long n) {
    return sl_bytes_alloc(n);
}

/* Float byte conversion goes through the IEEE-754 bit pattern and then
 * shifts bytes explicitly. memcpy avoids aliasing violations, and the
 * shifts make the result independent of host endianness. */
static sl_bytes *sl_encoding_float64_to_le(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    sl_bytes *out = sl_enc_bytes_raw(8);
    for (int i = 0; i < 8; i++) {
        out->ptr[i] = (unsigned char)(bits & UINT64_C(0xff));
        bits >>= 8;
    }
    return out;
}

static sl_res_float_str *sl_encoding_float64_from_le(sl_bytes *bytes) {
    if (!bytes || bytes->len != 8)
        return sl_enc_err_float(
            "encoding.float64_from_le: expected exactly 8 bytes");
    uint64_t bits = 0;
    for (int i = 0; i < 8; i++)
        bits |= (uint64_t)bytes->ptr[i] << (8 * i);
    double value;
    memcpy(&value, &bits, sizeof(value));
    return sl_enc_ok_float(value);
}

/* ---- hex ------------------------------------------------------------ */

static char *sl_encoding_hex_encode(sl_bytes *b) {
    long long n = b ? b->len : 0;
    char *out = (char *)sl_gc_alloc((size_t)n * 2 + 1, NULL);
    for (long long i = 0; i < n; i++) {
        unsigned char c = b->ptr[i];
        out[i * 2] = SL_ENC_HEX_LOWER[c >> 4];
        out[i * 2 + 1] = SL_ENC_HEX_LOWER[c & 15];
    }
    out[n * 2] = 0;
    return out;
}

/* -1 for a non-hex byte. Both cases are accepted on the way in: hex
   arrives from other systems as often as from this one, and uppercase
   is not an error in any spec that produces it. */
static int sl_enc_hex_digit(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static sl_res_bytes_str *sl_encoding_hex_decode(const char *s) {
    if (!s) return sl_enc_ok_bytes(sl_bytes_new(NULL, 0));
    size_t n = strlen(s);
    if (n % 2)
        return sl_enc_err_bytes(
            "hex_decode: odd number of digits (a byte needs two)");
    sl_bytes *out = sl_enc_bytes_raw((long long)(n / 2));
    for (size_t i = 0; i < n; i += 2) {
        int hi = sl_enc_hex_digit((unsigned char)s[i]);
        int lo = sl_enc_hex_digit((unsigned char)s[i + 1]);
        if (hi < 0 || lo < 0) {
            char m[128];
            return sl_enc_err_bytes(
                sl_enc_msg(m, sizeof(m), "hex_decode: not a hex digit",
                           (long long)(hi < 0 ? i : i + 1)));
        }
        out->ptr[i / 2] = (unsigned char)((hi << 4) | lo);
    }
    return sl_enc_ok_bytes(out);
}

/* ---- base64 ---------------------------------------------------------
 *
 * One encoder and one decoder, each taking the alphabet and whether to
 * pad, because standard and url differ ONLY in those two things and
 * duplicating the quantum arithmetic twice would mean fixing every
 * future bug twice. */

static char *sl_enc_b64(sl_bytes *b, const char *alpha, int pad) {
    long long n = b ? b->len : 0;
    long long full = n / 3, rem = n % 3;
    /* padded: 4 chars per 3 bytes, tail rounded up to 4.
       unpadded: the tail contributes rem + 1 chars (2 for 1 byte,
       3 for 2) -- the padding is what the other form adds. */
    long long outn = full * 4;
    if (rem) outn += pad ? 4 : rem + 1;
    char *out = (char *)sl_gc_alloc((size_t)outn + 1, NULL);
    char *w = out;
    long long i = 0;
    for (; i + 3 <= n; i += 3) {
        unsigned v = ((unsigned)b->ptr[i] << 16) |
                     ((unsigned)b->ptr[i + 1] << 8) |
                     (unsigned)b->ptr[i + 2];
        *w++ = alpha[(v >> 18) & 63];
        *w++ = alpha[(v >> 12) & 63];
        *w++ = alpha[(v >> 6) & 63];
        *w++ = alpha[v & 63];
    }
    if (rem) {
        unsigned v = (unsigned)b->ptr[i] << 16;
        if (rem == 2) v |= (unsigned)b->ptr[i + 1] << 8;
        *w++ = alpha[(v >> 18) & 63];
        *w++ = alpha[(v >> 12) & 63];
        if (rem == 2) *w++ = alpha[(v >> 6) & 63];
        else if (pad) *w++ = '=';
        if (pad) *w++ = '=';
    }
    *w = 0;
    return out;
}

static int sl_enc_b64_digit(int c, const char *alpha) {
    const char *p = memchr(alpha, c, 64);
    return p ? (int)(p - alpha) : -1;
}

/* `pad` says whether '=' padding is REQUIRED (standard) or merely
   tolerated (url). Rejecting padding outright on the url form would
   break tokens from the several libraries that emit it, while requiring
   it there would break the many that do not -- so url accepts either
   and standard insists on a complete quantum, which is what its own
   producers always emit. */
static sl_res_bytes_str *sl_enc_b64_decode(const char *s, const char *alpha,
                                           int pad, const char *who) {
    if (!s) return sl_enc_ok_bytes(sl_bytes_new(NULL, 0));
    size_t n = strlen(s);
    while (n && s[n - 1] == '=') n--; /* trailing padding, if any */
    if (pad && strlen(s) % 4)
        return sl_enc_err_bytes(
            "base64_decode: length is not a multiple of 4 (input is "
            "truncated, or is base64url -- try base64url_decode)");
    if (n % 4 == 1)
        return sl_enc_err_bytes(
            "base64 decode: trailing character with no quantum to join");

    long long outn = (long long)(n / 4) * 3;
    size_t tail = n % 4;
    if (tail) outn += (long long)tail - 1; /* 2 chars -> 1 byte, 3 -> 2 */
    sl_bytes *out = sl_enc_bytes_raw(outn);
    unsigned char *w = out->ptr;

    size_t i = 0;
    for (; i + 4 <= n; i += 4) {
        int d[4];
        for (int k = 0; k < 4; k++) {
            d[k] = sl_enc_b64_digit((unsigned char)s[i + k], alpha);
            if (d[k] < 0) {
                char m[96], full[160];
                snprintf(m, sizeof(m), "%s: byte not in the alphabet", who);
                return sl_enc_err_bytes(
                    sl_enc_msg(full, sizeof(full), m, (long long)(i + k)));
            }
        }
        unsigned v = ((unsigned)d[0] << 18) | ((unsigned)d[1] << 12) |
                     ((unsigned)d[2] << 6) | (unsigned)d[3];
        *w++ = (unsigned char)(v >> 16);
        *w++ = (unsigned char)(v >> 8);
        *w++ = (unsigned char)v;
    }
    if (tail) {
        int d[4] = {0, 0, 0, 0};
        for (size_t k = 0; k < tail; k++) {
            d[k] = sl_enc_b64_digit((unsigned char)s[i + k], alpha);
            if (d[k] < 0) {
                char m[96], full[160];
                snprintf(m, sizeof(m), "%s: byte not in the alphabet", who);
                return sl_enc_err_bytes(
                    sl_enc_msg(full, sizeof(full), m, (long long)(i + k)));
            }
        }
        unsigned v = ((unsigned)d[0] << 18) | ((unsigned)d[1] << 12) |
                     ((unsigned)d[2] << 6);
        *w++ = (unsigned char)(v >> 16);
        if (tail == 3) *w++ = (unsigned char)(v >> 8);
    }
    return sl_enc_ok_bytes(out);
}

static char *sl_encoding_base64_encode(sl_bytes *b) {
    return sl_enc_b64(b, SL_ENC_B64_STD, 1);
}

static sl_res_bytes_str *sl_encoding_base64_decode(const char *s) {
    return sl_enc_b64_decode(s, SL_ENC_B64_STD, 1, "base64_decode");
}

static char *sl_encoding_base64url_encode(sl_bytes *b) {
    return sl_enc_b64(b, SL_ENC_B64_URL, 0);
}

static sl_res_bytes_str *sl_encoding_base64url_decode(const char *s) {
    return sl_enc_b64_decode(s, SL_ENC_B64_URL, 0, "base64url_decode");
}

/* ---- percent-encoding ----------------------------------------------- */

/* RFC 3986's unreserved set, and nothing else. Encoding more than
   strictly necessary is always safe; encoding less is how a '&' in a
   value silently becomes a field separator. */
static int sl_enc_unreserved(int c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
           c == '~';
}

static char *sl_enc_percent(const char *s, int plus_space) {
    if (!s) s = "";
    size_t n = strlen(s), outn = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (sl_enc_unreserved(c) || (plus_space && c == ' ')) outn += 1;
        else outn += 3;
    }
    char *out = (char *)sl_gc_alloc(outn + 1, NULL);
    char *w = out;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (sl_enc_unreserved(c)) {
            *w++ = (char)c;
        } else if (plus_space && c == ' ') {
            *w++ = '+';
        } else {
            *w++ = '%';
            *w++ = SL_ENC_HEX_UPPER[c >> 4];
            *w++ = SL_ENC_HEX_UPPER[c & 15];
        }
    }
    *w = 0;
    return out;
}

/* Shared by url_decode, form_decode and query_get. Writes into `w` and
 * returns the number of bytes written, or -1 with *err set.
 *
 * `err` carries a pointer to a static message rather than an allocation
 * because the only caller that can fail turns it straight into a
 * result, and an allocation on the error path of a parser that runs
 * once per request is worth avoiding. */
static long long sl_enc_unpercent(const char *s, size_t n, int plus_space,
                                  char *w, const char **err) {
    char *w0 = w;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '%') {
            if (i + 2 >= n) {
                *err = "truncated percent-escape (needs two hex digits)";
                return -1;
            }
            int hi = sl_enc_hex_digit((unsigned char)s[i + 1]);
            int lo = sl_enc_hex_digit((unsigned char)s[i + 2]);
            if (hi < 0 || lo < 0) {
                *err = "percent-escape is not two hex digits";
                return -1;
            }
            int v = (hi << 4) | lo;
            /* See this file's header: a str cannot hold a NUL, and
               truncating silently is worse than refusing. */
            if (v == 0) {
                *err = "%00 cannot be represented in a str (decode to "
                       "bytes with hex_decode or base64_decode instead)";
                return -1;
            }
            *w++ = (char)v;
            i += 2;
        } else if (plus_space && c == '+') {
            *w++ = ' ';
        } else {
            *w++ = (char)c;
        }
    }
    return (long long)(w - w0);
}

static sl_res_str_str *sl_enc_decode_str(const char *s, int plus_space) {
    if (!s) return sl_enc_ok_str(sl_strdup(""));
    size_t n = strlen(s);
    /* Decoding never grows: %XX shrinks 3 bytes to 1, '+' stays 1. */
    char *out = (char *)sl_gc_alloc(n + 1, NULL);
    const char *err = NULL;
    long long m = sl_enc_unpercent(s, n, plus_space, out, &err);
    if (m < 0) return sl_enc_err_str(err);
    out[m] = 0;
    return sl_enc_ok_str(out);
}

static char *sl_encoding_url_encode(const char *s) {
    return sl_enc_percent(s, 0);
}

static sl_res_str_str *sl_encoding_url_decode(const char *s) {
    return sl_enc_decode_str(s, 0);
}

static char *sl_encoding_form_encode(const char *s) {
    return sl_enc_percent(s, 1);
}

static sl_res_str_str *sl_encoding_form_decode(const char *s) {
    return sl_enc_decode_str(s, 1);
}

/* ---- query strings ---------------------------------------------------
 *
 * Both entry points accept a whole URL, a bare query string, or one
 * with a leading '?', because a caller holding `req.path` should not
 * have to find the '?' itself before asking a question about the query.
 * An input with no '?' is treated as a query string in full -- that is
 * what a caller who already split it will pass. */
static const char *sl_enc_query_start(const char *s, size_t *n) {
    const char *q = strchr(s, '?');
    if (q) s = q + 1;
    const char *hash = strchr(s, '#'); /* a fragment is not part of the query */
    *n = hash ? (size_t)(hash - s) : strlen(s);
    return s;
}

/* Bounds of the next key=value pair starting at *i, advancing *i past
   the separator. Returns 0 when the query is exhausted. Both ';' and
   '&' separate: some older producers emit ';', and treating it as an
   ordinary value byte turns two fields into one long malformed one. */
static int sl_enc_query_next(const char *q, size_t n, size_t *i,
                             size_t *ks, size_t *ke, size_t *vs,
                             size_t *ve) {
    while (*i < n && (q[*i] == '&' || q[*i] == ';')) (*i)++;
    if (*i >= n) return 0;
    size_t start = *i;
    while (*i < n && q[*i] != '&' && q[*i] != ';') (*i)++;
    size_t end = *i;
    const char *eq = memchr(q + start, '=', end - start);
    *ks = start;
    *ke = eq ? (size_t)(eq - q) : end;
    /* A key with no '=' has an empty value, not a missing one: "?debug"
       is a flag, and reporting it absent would make it unreadable. */
    *vs = eq ? (size_t)(eq - q) + 1 : end;
    *ve = end;
    return 1;
}

static sl_opt_str *sl_encoding_query_get(const char *url, const char *key) {
    sl_opt_str *o =
        (sl_opt_str *)sl_gc_alloc(sizeof(sl_opt_str), sl_gc_trace_sl_opt_str);
    o->has = false;
    if (!url || !key) return o;

    size_t n;
    const char *q = sl_enc_query_start(url, &n);
    size_t klen = strlen(key);
    size_t i = 0, ks, ke, vs, ve;
    while (sl_enc_query_next(q, n, &i, &ks, &ke, &vs, &ve)) {
        /* The KEY is encoded too, so compare decoded forms -- "a+b" and
           "a%20b" and "a b" are one key, and a byte compare would say
           three. */
        char kbuf[256];
        const char *err = NULL;
        size_t rawk = ke - ks;
        if (rawk >= sizeof(kbuf)) continue; /* no real key is 256 bytes */
        long long kn =
            sl_enc_unpercent(q + ks, rawk, 1, kbuf, &err);
        if (kn < 0) continue; /* a malformed key cannot match a valid one */
        if ((size_t)kn != klen || memcmp(kbuf, key, klen) != 0) continue;

        size_t rawv = ve - vs;
        char *val = (char *)sl_gc_alloc(rawv + 1, NULL);
        long long vn = sl_enc_unpercent(q + vs, rawv, 1, val, &err);
        if (vn < 0) return o; /* present but undecodable: report absent */
        val[vn] = 0;
        o->has = true;
        o->v = val;
        return o;
    }
    return o;
}

/* Bracketed for the same reason sl_strings_split is: sl_arr_push
   allocates and can grow the backing store, and the partially-built
   list is reachable only from this C frame. */
static sl_arr *sl_encoding_query_keys(const char *url) {
    sl_arr *out = sl_arr_new(sizeof(char *), 1);
    if (!url) return out;
    void *roots[1];
    sl_safepoint sp;
    roots[0] = (void *)out;
    sl_rt_safepoint_enter(&sp, roots, 1);

    size_t n;
    const char *q = sl_enc_query_start(url, &n);
    size_t i = 0, ks, ke, vs, ve;
    while (sl_enc_query_next(q, n, &i, &ks, &ke, &vs, &ve)) {
        size_t rawk = ke - ks;
        char *k = (char *)sl_gc_alloc(rawk + 1, NULL);
        const char *err = NULL;
        long long kn = sl_enc_unpercent(q + ks, rawk, 1, k, &err);
        if (kn < 0) continue; /* skip a malformed key, keep the rest */
        k[kn] = 0;
        sl_arr_push(out, &k, sizeof(char *));
    }
    sl_rt_safepoint_exit();
    return out;
}

/* ---- a JSON document's structural tape --------------------------------
 *
 * One pass over the text, in C, producing a flat list of ints, five per
 * value (and per object key), in document order:
 *
 *     kind, end, count, from, to
 *
 *   kind   0 null, 1 bool, 2 number, 3 string, 4 list, 5 object, 7 key;
 *          a string or key that holds a backslash escape has 8 added
 *   end    the entry after this value's subtree (entry = index / 5)
 *   count  a list's items or an object's fields; 0 for the rest
 *   from   byte span in the text: a string's or key's inside (between
 *   to     the quotes, escapes not decoded), the whole value otherwise
 *
 * An object's entries are key, value, key, value... What a reader wants
 * from a document it will walk -- stdlib/template looks fields up and
 * ranges over lists -- is where things are, not a copy of every string:
 * a caller materialises only what it reads (strings.from_bytes over the
 * span), and skips a subtree in one step via `end`. The text is
 * validated as JSON (RFC 8259) on the way, so a span is always well
 * formed; nesting is limited to 512 levels with an explicit stack, so no
 * input can exhaust the C stack: the chain of open containers lives in
 * the tape (see below), so the C frame is a few words whatever the depth. */

#define SL_JT_STRIDE 5
#define SL_JT_MAX_DEPTH 512

typedef struct {
    long long *v;
    size_t n, cap;
} sl_jt_buf;

static int sl_jt_grow(sl_jt_buf *t, size_t need) {
    if (t->n + need <= t->cap) return 1;
    size_t cap = t->cap ? t->cap * 2 : 320;
    while (cap < t->n + need) cap *= 2;
    sl_rt_preempt_disable();
    long long *nv = (long long *)realloc(t->v, cap * sizeof(long long));
    sl_rt_preempt_enable();
    if (!nv) return 0;
    t->v = nv;
    t->cap = cap;
    return 1;
}

/* Appends an entry, returning its entry index, or -1 out of memory. */
static long long sl_jt_add(sl_jt_buf *t, long long kind, long long from, long long to) {
    if (!sl_jt_grow(t, SL_JT_STRIDE)) return -1;
    long long e = (long long)(t->n / SL_JT_STRIDE);
    long long *w = t->v + t->n;
    w[0] = kind;
    w[1] = e + 1;
    w[2] = 0;
    w[3] = from;
    w[4] = to;
    t->n += SL_JT_STRIDE;
    return e;
}

static int sl_jt_ws(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/* The string starting at s[i] (a quote). Sets *close to the closing
 * quote's index and *esc when it holds an escape; returns NULL or what
 * is wrong. */
static const char *sl_jt_string(const unsigned char *s, size_t n, size_t i,
                                size_t *close, int *esc) {
    *esc = 0;
    for (i++; i < n; i++) {
        unsigned char c = s[i];
        if (c == '"') {
            *close = i;
            return NULL;
        }
        if (c < 0x20) { *close = i; return "a control character in a string"; }
        if (c == '\\') {
            *esc = 1;
            if (i + 1 >= n) break;
            unsigned char e = s[++i];
            if (e == 'u') {
                if (i + 4 >= n) { *close = i; return "a short \\u escape"; }
                for (int k = 1; k <= 4; k++)
                    if (sl_enc_hex_digit(s[i + k]) < 0) { *close = i; return "a bad \\u escape"; }
                i += 4;
            } else if (!(e == '"' || e == '\\' || e == '/' || e == 'b' || e == 'f' ||
                         e == 'n' || e == 'r' || e == 't')) {
                *close = i;
                return "an unknown escape";
            }
        }
    }
    *close = n;
    return "an unterminated string";
}

/* RFC 8259's number grammar; returns the index after it, or 0. */
static size_t sl_jt_number(const unsigned char *s, size_t n, size_t i) {
    if (i < n && s[i] == '-') i++;
    if (i >= n) return 0;
    if (s[i] == '0') i++;
    else if (s[i] >= '1' && s[i] <= '9') while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    else return 0;
    if (i < n && s[i] == '.') {
        i++;
        if (i >= n || s[i] < '0' || s[i] > '9') return 0;
        while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    }
    if (i < n && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        if (i < n && (s[i] == '+' || s[i] == '-')) i++;
        if (i >= n || s[i] < '0' || s[i] > '9') return 0;
        while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    }
    return i;
}

static sl_res__int__str *sl_jt_err(const char *what, size_t at) {
    char m[160];
    snprintf(m, sizeof m, "json_tape: %s at byte %zu", what, at);
    sl_res__int__str *r = (sl_res__int__str *)sl_gc_alloc(
        sizeof(sl_res__int__str), sl_gc_trace_sl_res__int__str);
    r->ok = false;
    r->e = sl_strdup(m);
    return r;
}

static sl_res__int__str *sl_encoding_json_tape(const char *text) {
    const unsigned char *s = (const unsigned char *)(text ? text : "");
    size_t n = strlen((const char *)s);
    sl_jt_buf t = {0};
    /* The open containers form a chain through the tape itself: while a
       container is open its `to` slot holds its parent's entry (-1 at
       the root), and closing it writes the real end of its span. No
       stack array -- this runs on a task's small stack. */
    long long top = -1;
    int depth = 0;
    const char *bad = NULL;
    size_t i = 0;
    /* in an object: a key comes next (after '{' or ',') */
    int want_key = 0;
    for (;;) {
        while (i < n && sl_jt_ws(s[i])) i++;
        if (i >= n) { bad = "unexpected end of data"; goto fail; }
        if (top >= 0) {
            t.v[top * SL_JT_STRIDE + 2]++;
            if (t.v[top * SL_JT_STRIDE] == 5) {
                if (!want_key || s[i] != '"') { bad = "expected a key"; goto fail; }
                size_t close;
                int esc;
                bad = sl_jt_string(s, n, i, &close, &esc);
                if (bad) { i = close; goto fail; }
                if (sl_jt_add(&t, esc ? 15 : 7, (long long)i + 1, (long long)close) < 0) {
                    bad = "out of memory"; goto fail;
                }
                i = close + 1;
                while (i < n && sl_jt_ws(s[i])) i++;
                if (i >= n || s[i] != ':') { bad = "expected ':'"; goto fail; }
                i++;
                while (i < n && sl_jt_ws(s[i])) i++;
                if (i >= n) { bad = "unexpected end of data"; goto fail; }
            }
        }
        want_key = 0;
        unsigned char c = s[i];
        if (c == '{' || c == '[') {
            if (depth >= SL_JT_MAX_DEPTH) { bad = "nesting deeper than 512"; goto fail; }
            long long e = sl_jt_add(&t, c == '{' ? 5 : 4, (long long)i, (long long)i);
            if (e < 0) { bad = "out of memory"; goto fail; }
            i++;
            while (i < n && sl_jt_ws(s[i])) i++;
            unsigned char closer = c == '{' ? '}' : ']';
            if (i < n && s[i] == closer) {
                i++;
                t.v[e * SL_JT_STRIDE + 4] = (long long)i;
            } else {
                t.v[e * SL_JT_STRIDE + 4] = top;
                top = e;
                depth++;
                want_key = c == '{';
                continue;
            }
        } else if (c == '"') {
            size_t close;
            int esc;
            bad = sl_jt_string(s, n, i, &close, &esc);
            if (bad) { i = close; goto fail; }
            if (sl_jt_add(&t, esc ? 11 : 3, (long long)i + 1, (long long)close) < 0) {
                bad = "out of memory"; goto fail;
            }
            i = close + 1;
        } else if (c == 't' && i + 4 <= n && !memcmp(s + i, "true", 4)) {
            if (sl_jt_add(&t, 1, (long long)i, (long long)i + 4) < 0) { bad = "out of memory"; goto fail; }
            i += 4;
        } else if (c == 'f' && i + 5 <= n && !memcmp(s + i, "false", 5)) {
            if (sl_jt_add(&t, 1, (long long)i, (long long)i + 5) < 0) { bad = "out of memory"; goto fail; }
            i += 5;
        } else if (c == 'n' && i + 4 <= n && !memcmp(s + i, "null", 4)) {
            if (sl_jt_add(&t, 0, (long long)i, (long long)i + 4) < 0) { bad = "out of memory"; goto fail; }
            i += 4;
        } else {
            size_t end = sl_jt_number(s, n, i);
            if (!end) { bad = "unexpected character"; goto fail; }
            if (sl_jt_add(&t, 2, (long long)i, (long long)end) < 0) { bad = "out of memory"; goto fail; }
            i = end;
        }
        /* after a value: ',' for the next one, or close containers */
        for (;;) {
            while (i < n && sl_jt_ws(s[i])) i++;
            if (top < 0) {
                if (i != n) { bad = "trailing data after the value"; goto fail; }
                goto done;
            }
            if (i >= n) { bad = "unexpected end of data"; goto fail; }
            int is_obj = t.v[top * SL_JT_STRIDE] == 5;
            if (s[i] == ',') {
                i++;
                want_key = is_obj;
                break;
            }
            if (s[i] != (is_obj ? '}' : ']')) { bad = "expected ',' or a closing bracket"; goto fail; }
            i++;
            depth--;
            long long parent = t.v[top * SL_JT_STRIDE + 4];
            t.v[top * SL_JT_STRIDE + 1] = (long long)(t.n / SL_JT_STRIDE);
            t.v[top * SL_JT_STRIDE + 4] = (long long)i;
            top = parent;
        }
    }
done: {
        sl_arr *out = sl_arr_new(sizeof(long long), 0);
        void *roots[1];
        sl_safepoint sp;
        roots[0] = (void *)out;
        sl_rt_safepoint_enter(&sp, roots, 1);
        sl_arr_reserve(out, (long long)t.n);
        if (t.n) memcpy(out->data, t.v, t.n * sizeof(long long));
        out->len = (long long)t.n;
        sl_rt_preempt_disable();
        free(t.v);
        sl_rt_preempt_enable();
        sl_res__int__str *r = (sl_res__int__str *)sl_gc_alloc(
            sizeof(sl_res__int__str), sl_gc_trace_sl_res__int__str);
        r->ok = true;
        r->v = out;
        sl_rt_safepoint_exit();
        return r;
    }
fail:
    sl_rt_preempt_disable();
    free(t.v);
    sl_rt_preempt_enable();
    return sl_jt_err(bad, i);
}

/* ---- XOR with a repeating key -----------------------------------------
 *
 * head, then data XORed with key repeated over it, in one allocation: a
 * WebSocket client frame (RFC 6455 §5.3) is its header followed by the
 * payload masked with a 4-byte key, and building it this way copies the
 * payload once. The XOR runs eight bytes at a time over a key widened to
 * a word; the result is the same as the byte-at-a-time definition for
 * any key length, since the word is the key repeated from offset 0 and
 * each word starts at a multiple of 8 into data. That holds for keys
 * whose length divides 8 (1, 2, 4, 8); other lengths take the byte
 * loop. An empty key copies data unchanged. */
static sl_bytes *sl_encoding_xor_mask(sl_bytes *head, sl_bytes *data, sl_bytes *key) {
    long long hn = head ? head->len : 0;
    long long dn = data ? data->len : 0;
    long long kn = key ? key->len : 0;
    sl_bytes *out = sl_enc_bytes_raw(hn + dn);
    unsigned char *w = out->ptr;
    if (hn) memcpy(w, head->ptr, (size_t)hn);
    w += hn;
    const unsigned char *d = dn ? data->ptr : NULL;
    if (kn == 0) {
        if (dn) memcpy(w, d, (size_t)dn);
        return out;
    }
    const unsigned char *k = key->ptr;
    long long i = 0;
    if (8 % kn == 0) {
        unsigned char kw[8];
        for (int j = 0; j < 8; j++) kw[j] = k[j % kn];
        unsigned long long m;
        memcpy(&m, kw, 8);
        for (; i + 8 <= dn; i += 8) {
            unsigned long long x;
            memcpy(&x, d + i, 8);
            x ^= m;
            memcpy(w + i, &x, 8);
        }
    }
    for (; i < dn; i++) w[i] = d[i] ^ k[i % kn];
    return out;
}
