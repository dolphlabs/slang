/* The 'encoding' package: hex, base64, base64url, percent-encoding and
 * query strings.
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
 * write every byte of it, so they allocate the same shape directly.
 * Same two-allocation order sl_bytes_new itself uses. */
static sl_bytes *sl_enc_bytes_raw(long long n) {
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    b->len = n;
    b->ptr = (unsigned char *)sl_gc_alloc((size_t)(n > 0 ? n : 1), NULL);
    return b;
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
