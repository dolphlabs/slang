#include <stdarg.h>

/* ---- json: generic parse tree ---- */

typedef enum { SL_JV_NULL, SL_JV_BOOL, SL_JV_NUM, SL_JV_STR, SL_JV_ARR, SL_JV_OBJ } sl_jv_kind;
typedef struct sl_json_val sl_json_val;
struct sl_json_val {
    sl_jv_kind kind;
    union {
        bool b;
        /* The literal as written, next to its double: the double is
         * exact only up to 2^53, so integers decode from the text (see
         * sl_json_num_int). Fits the union without growing it. */
        struct { double d; char *text; } num;
        char *str;
        struct { sl_json_val **items; long long len; } arr;
        struct { char **keys; sl_json_val **vals; long long len; } obj;
    } as;
};

/* Tier 10: sl_json_val is a hand-rolled tree, not a slang-declared
 * type, so it gets its own hand-written tracer (mirrors sl_arr/
 * sl_map's own custom tracers in runtime_core.c) rather than a
 * codegen-generated one. .arr.items/.obj.keys/.obj.vals are each a
 * separate sl_gc_alloc'd array of pointers (trace = NULL on the
 * array itself -- this function walks its slots directly, exactly
 * the sl_arr/sl_map pattern), and each slot's own pointee is
 * recursively traced through its own header once marked. */
static void sl_gc_trace_json_val(void *p, void (*mark)(void *)) {
    sl_json_val *v = (sl_json_val *)p;
    switch (v->kind) {
    case SL_JV_NUM:
        mark(v->as.num.text);
        break;
    case SL_JV_STR:
        mark(v->as.str);
        break;
    case SL_JV_ARR:
        if (!v->as.arr.items) break;
        mark(v->as.arr.items);
        for (long long i = 0; i < v->as.arr.len; i++)
            mark(v->as.arr.items[i]);
        break;
    case SL_JV_OBJ:
        if (v->as.obj.keys) {
            mark(v->as.obj.keys);
            for (long long i = 0; i < v->as.obj.len; i++)
                mark(v->as.obj.keys[i]);
        }
        if (v->as.obj.vals) {
            mark(v->as.obj.vals);
            for (long long i = 0; i < v->as.obj.len; i++)
                mark(v->as.obj.vals[i]);
        }
        break;
    default:
        break;
    }
}

#define SL_JSON_MAX_DEPTH 512

typedef struct {
    const char *s;
    long long len;
    long long pos;
    long long depth;
    char *err;
} sl_jparser;

/* Tier 11 eighth slice: bracketed entry-to-return -- vsnprintf/
 * snprintf's own libc implementation touches locale state behind an
 * internal, thread-affine lock, same vulnerability class as malloc/
 * free (see sl_gc_alloc's own comment, runtime_gc.c, for the
 * concrete failure this closes: an async-preempted, migrated task
 * abandoning a libSystem lock mid-hold). sl_gc_alloc's own call is
 * separately, transitively covered by its own bracket. */
static void sl_jerr(sl_jparser *p, const char *fmt, ...) {
    if (p->err) return;
    sl_rt_preempt_disable();
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    char *m = (char *)sl_gc_alloc(strlen(buf) + 32, NULL);
    snprintf(m, strlen(buf) + 32, "%s (at byte %lld)", buf, p->pos);
    sl_rt_preempt_enable();
    p->err = m;
}

static int sl_jpeek(sl_jparser *p) {
    return p->pos < p->len ? (unsigned char)p->s[p->pos] : -1;
}
static int sl_jnext(sl_jparser *p) {
    return p->pos < p->len ? (unsigned char)p->s[p->pos++] : -1;
}
static void sl_jskip_ws(sl_jparser *p) {
    while (p->pos < p->len) {
        char c = p->s[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->pos++;
        else break;
    }
}

static sl_json_val *sl_jv_new(sl_jv_kind k) {
    sl_json_val *v = (sl_json_val *)sl_gc_alloc(sizeof(sl_json_val),
                                                 sl_gc_trace_json_val);
    v->kind = k;
    return v;
}

static sl_json_val *sl_jparse_value(sl_jparser *p);

static int sl_hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int sl_jparse_hex4(sl_jparser *p) {
    int v = 0;
    for (int i = 0; i < 4; i++) {
        int c = sl_jnext(p);
        int h = sl_hexval(c);
        if (h < 0) { sl_jerr(p, "invalid \\u escape"); return -1; }
        v = (v << 4) | h;
    }
    return v;
}

static void sl_utf8_append(char **buf, long long *len, long long *cap, long cp) {
    if (*len + 4 > *cap) {
        *cap = (*cap ? *cap * 2 : 64);
        *buf = (char *)sl_gc_realloc(*buf, (size_t)*cap);
    }
    unsigned char *o = (unsigned char *)*buf + *len;
    if (cp < 0x80) {
        o[0] = (unsigned char)cp;
        *len += 1;
    } else if (cp < 0x800) {
        o[0] = (unsigned char)(0xC0 | (cp >> 6));
        o[1] = (unsigned char)(0x80 | (cp & 0x3F));
        *len += 2;
    } else if (cp < 0x10000) {
        o[0] = (unsigned char)(0xE0 | (cp >> 12));
        o[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        o[2] = (unsigned char)(0x80 | (cp & 0x3F));
        *len += 3;
    } else {
        o[0] = (unsigned char)(0xF0 | (cp >> 18));
        o[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        o[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        o[3] = (unsigned char)(0x80 | (cp & 0x3F));
        *len += 4;
    }
}

/* One input byte, as it is. Input is UTF-8 already: widening a byte past
 * 0x7F as if it were a code point turned "é" into "Ã©". */
static void sl_jbuf_byte(char **buf, long long *len, long long *cap, int c) {
    if (*len + 1 > *cap) {
        *cap = (*cap ? *cap * 2 : 64);
        *buf = (char *)sl_gc_realloc(*buf, (size_t)*cap);
    }
    (*buf)[(*len)++] = (char)c;
}

static char *sl_jparse_string_raw(sl_jparser *p) {
    /* Most strings have no escapes: find the closing quote first and copy
     * them in one allocation of the right size. Anything else (an escape,
     * a control character, no closing quote) takes the loop below from
     * the same position, which reports it. */
    long long end = p->pos;
    while (end < p->len) {
        unsigned char c = (unsigned char)p->s[end];
        if (c == '"' || c == '\\' || c < 0x20) break;
        end++;
    }
    if (end < p->len && p->s[end] == '"') {
        long long n = end - p->pos;
        char *s = (char *)sl_gc_alloc((size_t)n + 1, NULL);
        memcpy(s, p->s + p->pos, (size_t)n);
        s[n] = 0;
        p->pos = end + 1;
        return s;
    }
    char *buf = NULL;
    long long len = 0, cap = 0;
    for (;;) {
        if (p->pos >= p->len) { sl_jerr(p, "unterminated string"); return NULL; }
        int c = sl_jnext(p);
        if (c == '"') break;
        if (c == '\\') {
            int e = sl_jnext(p);
            switch (e) {
            case '"': sl_utf8_append(&buf, &len, &cap, '"'); break;
            case '\\': sl_utf8_append(&buf, &len, &cap, '\\'); break;
            case '/': sl_utf8_append(&buf, &len, &cap, '/'); break;
            case 'b': sl_utf8_append(&buf, &len, &cap, '\b'); break;
            case 'f': sl_utf8_append(&buf, &len, &cap, '\f'); break;
            case 'n': sl_utf8_append(&buf, &len, &cap, '\n'); break;
            case 'r': sl_utf8_append(&buf, &len, &cap, '\r'); break;
            case 't': sl_utf8_append(&buf, &len, &cap, '\t'); break;
            case 'u': {
                int cp = sl_jparse_hex4(p);
                if (cp < 0) return NULL;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    if (sl_jnext(p) != '\\' || sl_jnext(p) != 'u') {
                        sl_jerr(p, "unpaired UTF-16 surrogate");
                        return NULL;
                    }
                    int lo = sl_jparse_hex4(p);
                    if (lo < 0) return NULL;
                    if (lo < 0xDC00 || lo > 0xDFFF) {
                        sl_jerr(p, "invalid low surrogate");
                        return NULL;
                    }
                    long full = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    sl_utf8_append(&buf, &len, &cap, full);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    sl_jerr(p, "unpaired UTF-16 surrogate");
                    return NULL;
                } else {
                    sl_utf8_append(&buf, &len, &cap, cp);
                }
                break;
            }
            default:
                sl_jerr(p, "invalid escape '\\%c'", e >= 32 && e < 127 ? e : '?');
                return NULL;
            }
        } else if (c < 0x20) {
            sl_jerr(p, "control character in string");
            return NULL;
        } else {
            sl_jbuf_byte(&buf, &len, &cap, c);
        }
    }
    sl_jbuf_byte(&buf, &len, &cap, 0);
    return buf ? buf : sl_strdup("");
}

static sl_json_val *sl_jparse_string(sl_jparser *p) {
    char *s = sl_jparse_string_raw(p);
    if (!s) return NULL;
    sl_json_val *v = sl_jv_new(SL_JV_STR);
    v->as.str = s;
    return v;
}

static sl_json_val *sl_jparse_number(sl_jparser *p) {
    long long start = p->pos;
    if (sl_jpeek(p) == '-') sl_jnext(p);
    if (sl_jpeek(p) == '0') {
        sl_jnext(p);
    } else if (sl_jpeek(p) >= '1' && sl_jpeek(p) <= '9') {
        while (sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9') sl_jnext(p);
    } else {
        sl_jerr(p, "invalid number");
        return NULL;
    }
    if (sl_jpeek(p) == '.') {
        sl_jnext(p);
        if (!(sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9')) {
            sl_jerr(p, "invalid number: expected digit after '.'");
            return NULL;
        }
        while (sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9') sl_jnext(p);
    }
    if (sl_jpeek(p) == 'e' || sl_jpeek(p) == 'E') {
        sl_jnext(p);
        if (sl_jpeek(p) == '+' || sl_jpeek(p) == '-') sl_jnext(p);
        if (!(sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9')) {
            sl_jerr(p, "invalid number: expected digit in exponent");
            return NULL;
        }
        while (sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9') sl_jnext(p);
    }
    long long n = p->pos - start;
    char *tmp = (char *)sl_gc_alloc((size_t)n + 1, NULL);
    memcpy(tmp, p->s + start, (size_t)n);
    tmp[n] = 0;
    sl_json_val *v = sl_jv_new(SL_JV_NUM);
    v->as.num.d = strtod(tmp, NULL);
    v->as.num.text = tmp;
    return v;
}

static sl_json_val *sl_jparse_array(sl_jparser *p) {
    if (++p->depth > SL_JSON_MAX_DEPTH) {
        sl_jerr(p, "maximum nesting depth (%d) exceeded", SL_JSON_MAX_DEPTH);
        return NULL;
    }
    sl_json_val *v = sl_jv_new(SL_JV_ARR);
    v->as.arr.items = NULL;
    v->as.arr.len = 0;
    long long cap = 0;
    sl_jskip_ws(p);
    if (sl_jpeek(p) == ']') { sl_jnext(p); p->depth--; return v; }
    for (;;) {
        sl_jskip_ws(p);
        sl_json_val *item = sl_jparse_value(p);
        if (!item) { p->depth--; return NULL; }
        if (v->as.arr.len >= cap) {
            cap = cap ? cap * 2 : 4;
            /* Bracketed so v's generation cannot change between the
             * owned realloc reading it and the store (sl_arr_reserve). */
            sl_rt_preempt_disable();
            v->as.arr.items = (sl_json_val **)sl_gc_realloc_owned(v->as.arr.items, (size_t)cap * sizeof(sl_json_val *), v);
            sl_rt_preempt_enable();
        }
        v->as.arr.items[v->as.arr.len++] = item;
        sl_jskip_ws(p);
        int c = sl_jnext(p);
        if (c == ',') continue;
        if (c == ']') break;
        sl_jerr(p, "expected ',' or ']' in array");
        p->depth--;
        return NULL;
    }
    p->depth--;
    return v;
}

static sl_json_val *sl_jparse_object(sl_jparser *p) {
    if (++p->depth > SL_JSON_MAX_DEPTH) {
        sl_jerr(p, "maximum nesting depth (%d) exceeded", SL_JSON_MAX_DEPTH);
        return NULL;
    }
    sl_json_val *v = sl_jv_new(SL_JV_OBJ);
    v->as.obj.keys = NULL;
    v->as.obj.vals = NULL;
    v->as.obj.len = 0;
    long long cap = 0;
    sl_jskip_ws(p);
    if (sl_jpeek(p) == '}') { sl_jnext(p); p->depth--; return v; }
    for (;;) {
        sl_jskip_ws(p);
        if (sl_jpeek(p) != '"') {
            sl_jerr(p, "expected string key in object");
            p->depth--;
            return NULL;
        }
        sl_jnext(p);
        char *key = sl_jparse_string_raw(p);
        if (!key) { p->depth--; return NULL; }
        sl_jskip_ws(p);
        if (sl_jnext(p) != ':') {
            sl_jerr(p, "expected ':' after object key");
            p->depth--;
            return NULL;
        }
        sl_jskip_ws(p);
        sl_json_val *val = sl_jparse_value(p);
        if (!val) { p->depth--; return NULL; }
        if (v->as.obj.len >= cap) {
            cap = cap ? cap * 2 : 4;
            sl_rt_preempt_disable(); /* see sl_jparse_array */
            v->as.obj.keys = (char **)sl_gc_realloc_owned(v->as.obj.keys, (size_t)cap * sizeof(char *), v);
            v->as.obj.vals = (sl_json_val **)sl_gc_realloc_owned(v->as.obj.vals, (size_t)cap * sizeof(sl_json_val *), v);
            sl_rt_preempt_enable();
        }
        v->as.obj.keys[v->as.obj.len] = key;
        v->as.obj.vals[v->as.obj.len] = val;
        v->as.obj.len++;
        sl_jskip_ws(p);
        int c = sl_jnext(p);
        if (c == ',') continue;
        if (c == '}') break;
        sl_jerr(p, "expected ',' or '}' in object");
        p->depth--;
        return NULL;
    }
    p->depth--;
    return v;
}

static int sl_jmatch_lit(sl_jparser *p, const char *lit) {
    long long n = (long long)strlen(lit);
    if (p->pos + n > p->len) return 0;
    if (memcmp(p->s + p->pos, lit, (size_t)n) != 0) return 0;
    p->pos += n;
    return 1;
}

static sl_json_val *sl_jparse_value(sl_jparser *p) {
    sl_jskip_ws(p);
    int c = sl_jpeek(p);
    if (c < 0) { sl_jerr(p, "unexpected end of input"); return NULL; }
    if (c == '"') { sl_jnext(p); return sl_jparse_string(p); }
    if (c == '{') { sl_jnext(p); return sl_jparse_object(p); }
    if (c == '[') { sl_jnext(p); return sl_jparse_array(p); }
    if (c == '-' || (c >= '0' && c <= '9')) return sl_jparse_number(p);
    if (c == 't') {
        if (!sl_jmatch_lit(p, "true")) { sl_jerr(p, "invalid literal"); return NULL; }
        sl_json_val *v = sl_jv_new(SL_JV_BOOL); v->as.b = true; return v;
    }
    if (c == 'f') {
        if (!sl_jmatch_lit(p, "false")) { sl_jerr(p, "invalid literal"); return NULL; }
        sl_json_val *v = sl_jv_new(SL_JV_BOOL); v->as.b = false; return v;
    }
    if (c == 'n') {
        if (!sl_jmatch_lit(p, "null")) { sl_jerr(p, "invalid literal"); return NULL; }
        return sl_jv_new(SL_JV_NULL);
    }
    sl_jerr(p, "unexpected character '%c'", c >= 32 && c < 127 ? c : '?');
    return NULL;
}

static sl_json_val *sl_json_parse(const char *s, long long len, char **errmsg) {
    sl_jparser p = { s, len, 0, 0, NULL };
    sl_json_val *v = sl_jparse_value(&p);
    if (!v) { *errmsg = p.err; return NULL; }
    sl_jskip_ws(&p);
    if (p.pos != p.len) {
        sl_jerr(&p, "trailing garbage after JSON value");
        *errmsg = p.err;
        return NULL;
    }
    *errmsg = NULL;
    return v;
}

/* ---- json: struct-object field lookup ---- */

static sl_json_val *sl_json_obj_get(sl_json_val *v, const char *key) {
    for (long long i = 0; i < v->as.obj.len; i++)
        if (!strcmp(v->as.obj.keys[i], key))
            return v->as.obj.vals[i];
    return NULL;
}

static const char *sl_json_kind_name(sl_json_val *v) {
    switch (v->kind) {
    case SL_JV_NULL: return "null";
    case SL_JV_BOOL: return "a boolean";
    case SL_JV_NUM:  return "a number";
    case SL_JV_STR:  return "a string";
    case SL_JV_ARR:  return "an array";
    case SL_JV_OBJ:  return "an object";
    }
    return "a value";
}

/* ---- json: error message helpers ---- */

/* Tier 11 eighth slice: bracketed -- see sl_jerr's own comment above
 * for why (vsnprintf/snprintf's internal locale locking). */
static char *sl_json_errf(const char *fmt, ...) {
    sl_rt_preempt_disable();
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    sl_rt_preempt_enable();
    return sl_strdup(buf);
}

static char *sl_json_wrap_err(const char *ctx, char *inner) {
    size_t n = strlen(ctx) + strlen(inner) + 4;
    char *m = (char *)sl_gc_alloc(n, NULL);
    sl_rt_preempt_disable();
    snprintf(m, n, "%s: %s", ctx, inner);
    sl_rt_preempt_enable();
    return m;
}

/* ---- json: scalar decode helpers ---- */

static bool sl_json_dec_num(sl_json_val *v, double *out, char **err) {
    if (v->kind != SL_JV_NUM) {
        *err = sl_json_errf("expected a number, got %s", sl_json_kind_name(v));
        return false;
    }
    *out = v->as.num.d;
    return true;
}

static bool sl_json_dec_bool(sl_json_val *v, bool *out, char **err) {
    if (v->kind != SL_JV_BOOL) {
        *err = sl_json_errf("expected a boolean, got %s", sl_json_kind_name(v));
        return false;
    }
    *out = v->as.b;
    return true;
}

static bool sl_json_dec_str(sl_json_val *v, const char **out, char **err) {
    if (v->kind != SL_JV_STR) {
        *err = sl_json_errf("expected a string, got %s", sl_json_kind_name(v));
        return false;
    }
    *out = v->as.str;
    return true;
}

static const char sl_b64_alpha[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int sl_b64_digit(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

/* RFC 4648 base64 in `s` to bytes; false if it is not valid base64. */
static bool sl_json_b64(const char *s, sl_bytes **out) {
    size_t n = strlen(s);
    if (n % 4 != 0)
        return false;
    size_t pad = 0;
    if (n >= 1 && s[n - 1] == '=') pad++;
    if (n >= 2 && s[n - 2] == '=') pad++;
    size_t outn = (n / 4) * 3 - pad;
    sl_bytes *b = sl_bytes_alloc((long long)outn);
    size_t oi = 0;
    for (size_t i = 0; i < n; i += 4) {
        int a = sl_b64_digit((unsigned char)s[i]);
        int b1 = sl_b64_digit((unsigned char)s[i + 1]);
        int c = s[i + 2] == '=' ? 0 : sl_b64_digit((unsigned char)s[i + 2]);
        int d = s[i + 3] == '=' ? 0 : sl_b64_digit((unsigned char)s[i + 3]);
        if (a < 0 || b1 < 0 ||
            (s[i + 2] != '=' && c < 0) || (s[i + 3] != '=' && d < 0) ||
            (s[i + 2] == '=' && s[i + 3] != '='))
            return false;
        unsigned v24 = ((unsigned)a << 18) | ((unsigned)b1 << 12) |
                       ((unsigned)c << 6) | (unsigned)d;
        if (oi < outn) b->ptr[oi++] = (unsigned char)(v24 >> 16);
        if (oi < outn) b->ptr[oi++] = (unsigned char)(v24 >> 8);
        if (oi < outn) b->ptr[oi++] = (unsigned char)v24;
    }
    *out = b;
    return true;
}

static bool sl_json_dec_bytes(sl_json_val *v, sl_bytes **out, char **err) {
    if (v->kind != SL_JV_STR) {
        *err = sl_json_errf("expected a base64 string, got %s",
                            sl_json_kind_name(v));
        return false;
    }
    if (!sl_json_b64(v->as.str, out)) {
        *err = sl_json_errf("invalid base64");
        return false;
    }
    return true;
}

/* ---- json: exact integer decoding ----
 *
 * Integers decode from the number's text, never from its double. The
 * double is exact only up to 2^53, so 9007199254740993 -- an ordinary
 * 64-bit id -- used to come back as 9007199254740992, silently: the
 * rounded value is itself an integer, so no check could notice. The
 * text is exact, and it is still the JSON grammar's number (the parser
 * validated it), so exponent and fraction forms keep working exactly:
 * 1e3 is 1000 and 5.0 is 5, while 1.5 and 1e-1 are not integers.
 */
enum { SL_JSON_INT_OK, SL_JSON_INT_FRACTION, SL_JSON_INT_TOO_BIG };

/* Magnitude and sign of s[0..end), a validated JSON number, when it is
 * an integer: SL_JSON_INT_OK, else _FRACTION (not a whole number) or
 * _TOO_BIG (magnitude above UINT64_MAX). No allocation. Bounded by `end`
 * so the direct decoder can read a number in place, unterminated. */
static int sl_json_num_int_n(const char *s, const char *end, bool *neg,
                             unsigned long long *mag) {
#define SL_JDIGIT(q) ((q) < end && *(q) >= '0' && *(q) <= '9')
    *neg = false;
    *mag = 0;
    if (s < end && *s == '-') {
        *neg = true;
        s++;
    }
    const char *ip = s;
    while (SL_JDIGIT(s)) s++;
    size_t ilen = (size_t)(s - ip);
    const char *fp = s;
    size_t flen = 0;
    if (s < end && *s == '.') {
        fp = ++s;
        while (SL_JDIGIT(s)) s++;
        flen = (size_t)(s - fp);
    }
    /* An exponent past this many digits cannot leave a nonzero value
     * inside 64 bits, nor a whole number out of a fraction -- clamping
     * keeps the arithmetic below from overflowing on "1e99999999". */
    long long exp = 0;
    if (s < end && (*s == 'e' || *s == 'E')) {
        s++;
        bool eneg = false;
        if (s < end && (*s == '+' || *s == '-')) eneg = (*s++ == '-');
        while (SL_JDIGIT(s)) {
            if (exp < 1000000) exp = exp * 10 + (*s - '0');
            s++;
        }
        if (eneg) exp = -exp;
    }
#undef SL_JDIGIT
    /* The value is D * 10^scale, D being every digit written (integer
     * part then fraction) and scale the exponent less the fraction's
     * length. */
    size_t n = ilen + flen;
    long long scale = exp - (long long)flen;
    size_t keep = n; /* digits of D that land left of the decimal point */
    if (scale < 0) {
        unsigned long long drop = (unsigned long long)(-scale);
        keep = drop >= n ? 0 : n - (size_t)drop;
        for (size_t i = keep; i < n; i++) {
            char c = i < ilen ? ip[i] : fp[i - ilen];
            if (c != '0') return SL_JSON_INT_FRACTION;
        }
    }
    unsigned long long acc = 0;
    for (size_t i = 0; i < keep; i++) {
        char c = i < ilen ? ip[i] : fp[i - ilen];
        if (__builtin_mul_overflow(acc, 10ULL, &acc) ||
            __builtin_add_overflow(acc, (unsigned long long)(c - '0'), &acc))
            return SL_JSON_INT_TOO_BIG;
    }
    if (acc != 0) {
        for (long long k = 0; k < scale; k++) {
            if (__builtin_mul_overflow(acc, 10ULL, &acc))
                return SL_JSON_INT_TOO_BIG;
        }
    }
    *mag = acc;
    return SL_JSON_INT_OK;
}

static int sl_json_num_int(const char *s, bool *neg,
                           unsigned long long *mag) {
    return sl_json_num_int_n(s, s + strlen(s), neg, mag);
}

/* Decode into a signed type whose range is [lo, hi]. */
static bool sl_json_dec_signed(sl_json_val *v, long long lo, long long hi,
                               const char *tname, long long *out,
                               char **err) {
    double unused;
    if (!sl_json_dec_num(v, &unused, err)) return false;
    const char *text = v->as.num.text;
    bool neg;
    unsigned long long mag;
    int st = sl_json_num_int(text, &neg, &mag);
    if (st == SL_JSON_INT_FRACTION) {
        *err = sl_json_errf("expected an integer, got %s", text);
        return false;
    }
    /* |lo| as unsigned, without negating LLONG_MIN in signed arithmetic */
    unsigned long long neg_lim = lo < 0 ? (unsigned long long)(-(lo + 1)) + 1 : 0;
    if (st == SL_JSON_INT_TOO_BIG ||
        (!neg && mag > (unsigned long long)hi) || (neg && mag > neg_lim)) {
        *err = sl_json_errf("value %s out of range for %s", text, tname);
        return false;
    }
    if (!neg || mag == 0)
        *out = (long long)mag;
    else
        *out = -(long long)(mag - 1) - 1;
    return true;
}

/* Decode into an unsigned type whose range is [0, hi]. */
static bool sl_json_dec_unsigned(sl_json_val *v, unsigned long long hi,
                                 const char *tname, unsigned long long *out,
                                 char **err) {
    double unused;
    if (!sl_json_dec_num(v, &unused, err)) return false;
    const char *text = v->as.num.text;
    bool neg;
    unsigned long long mag;
    int st = sl_json_num_int(text, &neg, &mag);
    if (st == SL_JSON_INT_FRACTION) {
        *err = sl_json_errf("expected an integer, got %s", text);
        return false;
    }
    if (neg && mag != 0) {
        *err = sl_json_errf("expected a non-negative integer, got %s", text);
        return false;
    }
    if (st == SL_JSON_INT_TOO_BIG || mag > hi) {
        *err = sl_json_errf("value %s out of range for %s", text, tname);
        return false;
    }
    *out = mag;
    return true;
}

#define SL_JSON_SIGNED_DEC(NAME, T, LO, HI, TNAME)                          \
    static bool NAME(sl_json_val *v, T *out, char **err) {                  \
        long long x;                                                        \
        if (!sl_json_dec_signed(v, (LO), (HI), TNAME, &x, err))             \
            return false;                                                   \
        *out = (T)x;                                                        \
        return true;                                                        \
    }

#define SL_JSON_UNSIGNED_DEC(NAME, T, HI, TNAME)                            \
    static bool NAME(sl_json_val *v, T *out, char **err) {                  \
        unsigned long long x;                                               \
        if (!sl_json_dec_unsigned(v, (HI), TNAME, &x, err))                 \
            return false;                                                   \
        *out = (T)x;                                                        \
        return true;                                                        \
    }

SL_JSON_SIGNED_DEC(sl_json_dec_i8, int8_t, INT8_MIN, INT8_MAX, "i8")
SL_JSON_SIGNED_DEC(sl_json_dec_i16, int16_t, INT16_MIN, INT16_MAX, "i16")
SL_JSON_SIGNED_DEC(sl_json_dec_i32, int32_t, INT32_MIN, INT32_MAX, "i32")
SL_JSON_UNSIGNED_DEC(sl_json_dec_u8, uint8_t, UINT8_MAX, "u8")
SL_JSON_UNSIGNED_DEC(sl_json_dec_u16, uint16_t, UINT16_MAX, "u16")
SL_JSON_UNSIGNED_DEC(sl_json_dec_u32, uint32_t, UINT32_MAX, "u32")
SL_JSON_SIGNED_DEC(sl_json_dec_i64, int64_t, INT64_MIN, INT64_MAX, "i64")
SL_JSON_UNSIGNED_DEC(sl_json_dec_u64, uint64_t, UINT64_MAX, "u64")

/* slang's `int` is C `long long`, while `i64` and `duration` are
 * `int64_t`. On macOS those are the same type; on Linux glibc int64_t is
 * `long`, a DIFFERENT type of the same size, so one decoder taking
 * int64_t* was passed a long long* and GCC rejected it as an incompatible
 * pointer. One decoder per C type, sharing the range and integrality
 * checks, keeps both exact on every platform. */
/* long long is 64 bits on every platform slang supports, so int's range
 * is i64's; stdint.h's limits avoid adding limits.h to every program. */
SL_JSON_SIGNED_DEC(sl_json_dec_int, long long, INT64_MIN, INT64_MAX, "int")

static bool sl_json_dec_f32(sl_json_val *v, float *out, char **err) {
    double d;
    if (!sl_json_dec_num(v, &d, err)) return false;
    *out = (float)d;
    return true;
}

static bool sl_json_dec_f64(sl_json_val *v, double *out, char **err) {
    return sl_json_dec_num(v, out, err);
}

/* ---- json: direct decode ----
 *
 * json.decode reads the input straight into the target type first: the
 * per-type sl_jdf_* functions codegen emits call the readers below, and a
 * decode allocates only the values it returns. The tree above made a node
 * per value, a copy of every number's text and a key per member, then
 * looked each field up by strcmp: 14.8ms and ~26,000 allocations for a
 * 97KB body of 2,000 objects.
 *
 * These readers never build an error. Any failure returns false and the
 * caller decodes again through the tree, which names the error: which
 * error wins (a syntax error anywhere before a type error, fields in
 * declared order) and every message stay exactly what they were. So the
 * one rule here: never accept what the tree rejects. Every check below
 * mirrors the tree parser's; rejecting more only costs a fallback. */

/* Skip whitespace and return the next byte (-1 at the end), unread. */
static int sl_jd_peek(sl_jparser *p) {
    sl_jskip_ws(p);
    return sl_jpeek(p);
}

/* Consume `c` after any whitespace. */
static bool sl_jd_eat(sl_jparser *p, int c) {
    if (sl_jd_peek(p) != c) return false;
    p->pos++;
    return true;
}

/* Open an array or object: the bracket and one level of the tree's depth
 * limit, which bounds the C stack for recursive types too. */
static bool sl_jd_open(sl_jparser *p, int c) {
    if (!sl_jd_eat(p, c)) return false;
    return ++p->depth <= SL_JSON_MAX_DEPTH;
}

/* The closing bracket right after an opening one: an empty container. */
static bool sl_jd_empty(sl_jparser *p, int close) {
    if (sl_jd_peek(p) != close) return false;
    p->pos++;
    p->depth--;
    return true;
}

/* After an element or member: true on `,` (another follows), false with
 * *done set on the closing bracket, false with *done clear otherwise. */
static bool sl_jd_more(sl_jparser *p, int close, bool *done) {
    sl_jskip_ws(p);
    int c = sl_jnext(p);
    *done = c == close;
    if (*done) p->depth--;
    return c == ',';
}

/* The number at p->pos, validated against sl_jparse_number's grammar; its
 * text is p->s[*start .. p->pos). */
static bool sl_jd_number(sl_jparser *p, long long *start) {
    sl_jskip_ws(p);
    *start = p->pos;
    if (sl_jpeek(p) == '-') p->pos++;
    int c = sl_jpeek(p);
    if (c == '0') {
        p->pos++;
    } else if (c >= '1' && c <= '9') {
        while (sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9') p->pos++;
    } else {
        return false;
    }
    if (sl_jpeek(p) == '.') {
        p->pos++;
        if (!(sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9')) return false;
        while (sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9') p->pos++;
    }
    if (sl_jpeek(p) == 'e' || sl_jpeek(p) == 'E') {
        p->pos++;
        if (sl_jpeek(p) == '+' || sl_jpeek(p) == '-') p->pos++;
        if (!(sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9')) return false;
        while (sl_jpeek(p) >= '0' && sl_jpeek(p) <= '9') p->pos++;
    }
    return true;
}

static bool sl_jd_hex4(sl_jparser *p, int *out) {
    int v = 0;
    for (int i = 0; i < 4; i++) {
        int h = sl_hexval(sl_jnext(p));
        if (h < 0) return false;
        v = (v << 4) | h;
    }
    *out = v;
    return true;
}

/* Past a string whose opening quote is consumed, checking what
 * sl_jparse_string_raw checks, without copying it. */
static bool sl_jd_skip_string(sl_jparser *p) {
    for (;;) {
        if (p->pos >= p->len) return false;
        int c = sl_jnext(p);
        if (c == '"') return true;
        if (c < 0x20) return false;
        if (c != '\\') continue;
        int cp;
        switch (sl_jnext(p)) {
        case '"': case '\\': case '/': case 'b':
        case 'f': case 'n': case 'r': case 't':
            break;
        case 'u':
            if (!sl_jd_hex4(p, &cp)) return false;
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                int lo;
                if (sl_jnext(p) != '\\' || sl_jnext(p) != 'u') return false;
                if (!sl_jd_hex4(p, &lo)) return false;
                if (lo < 0xDC00 || lo > 0xDFFF) return false;
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                return false;
            }
            break;
        default:
            return false;
        }
    }
}

/* Past any one value, checked as sl_jparse_value checks it: an unknown
 * key's value, or a repeated key's (the first one counts, as in the
 * tree's field lookup). */
static bool sl_jd_skip(sl_jparser *p) {
    int c = sl_jd_peek(p);
    if (c == '"') {
        p->pos++;
        return sl_jd_skip_string(p);
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        long long start;
        return sl_jd_number(p, &start);
    }
    if (c == 't') return sl_jmatch_lit(p, "true");
    if (c == 'f') return sl_jmatch_lit(p, "false");
    if (c == 'n') return sl_jmatch_lit(p, "null");
    if (c != '[' && c != '{') return false;
    int close = c == '[' ? ']' : '}';
    if (!sl_jd_open(p, c)) return false;
    if (sl_jd_empty(p, close)) return true;
    for (;;) {
        if (close == '}') {
            if (!sl_jd_eat(p, '"') || !sl_jd_skip_string(p)) return false;
            if (!sl_jd_eat(p, ':')) return false;
        }
        if (!sl_jd_skip(p)) return false;
        bool done;
        if (sl_jd_more(p, close, &done)) continue;
        return done;
    }
}

/* The key of the next member and its colon. A key without escapes is read
 * in place (*k points into the input, *klen bytes); one with escapes is
 * decoded, and like the tree's key it ends at its first NUL. */
static bool sl_jd_key(sl_jparser *p, const char **k, long long *klen) {
    if (!sl_jd_eat(p, '"')) return false;
    long long start = p->pos;
    long long end = start;
    while (end < p->len) {
        unsigned char c = (unsigned char)p->s[end];
        if (c == '"' || c == '\\' || c < 0x20) break;
        end++;
    }
    if (end < p->len && p->s[end] == '"') {
        *k = p->s + start;
        *klen = end - start;
        p->pos = end + 1;
    } else {
        char *s = sl_jparse_string_raw(p);
        if (!s) return false;
        *k = s;
        *klen = (long long)strlen(s);
    }
    return sl_jd_eat(p, ':');
}

/* The end of the whole input: only whitespace may follow the value. */
static bool sl_jd_end(sl_jparser *p) {
    sl_jskip_ws(p);
    return p->pos == p->len;
}

static bool sl_jd_null(sl_jparser *p) {
    return sl_jd_peek(p) == 'n' && sl_jmatch_lit(p, "null");
}

static bool sl_jd_bool(sl_jparser *p, bool *out) {
    int c = sl_jd_peek(p);
    if (c == 't' && sl_jmatch_lit(p, "true")) { *out = true; return true; }
    if (c == 'f' && sl_jmatch_lit(p, "false")) { *out = false; return true; }
    return false;
}

static bool sl_jd_str(sl_jparser *p, const char **out) {
    if (!sl_jd_eat(p, '"')) return false;
    char *s = sl_jparse_string_raw(p);
    if (!s) return false;
    *out = s;
    return true;
}

static bool sl_jd_bytes(sl_jparser *p, sl_bytes **out) {
    const char *s;
    return sl_jd_str(p, &s) && sl_json_b64(s, out);
}

/* The next number as an integer in [lo, hi], or false. */
static bool sl_jd_signed(sl_jparser *p, long long lo, long long hi,
                         long long *out) {
    long long start;
    if (!sl_jd_number(p, &start)) return false;
    bool neg;
    unsigned long long mag;
    if (sl_json_num_int_n(p->s + start, p->s + p->pos, &neg, &mag) !=
        SL_JSON_INT_OK)
        return false;
    unsigned long long neg_lim = lo < 0 ? (unsigned long long)(-(lo + 1)) + 1 : 0;
    if ((!neg && mag > (unsigned long long)hi) || (neg && mag > neg_lim))
        return false;
    *out = (!neg || mag == 0) ? (long long)mag : -(long long)(mag - 1) - 1;
    return true;
}

static bool sl_jd_unsigned(sl_jparser *p, unsigned long long hi,
                           unsigned long long *out) {
    long long start;
    if (!sl_jd_number(p, &start)) return false;
    bool neg;
    unsigned long long mag;
    if (sl_json_num_int_n(p->s + start, p->s + p->pos, &neg, &mag) !=
        SL_JSON_INT_OK)
        return false;
    if ((neg && mag != 0) || mag > hi) return false;
    *out = mag;
    return true;
}

#define SL_JD_SIGNED(NAME, T, LO, HI)                                       \
    static bool NAME(sl_jparser *p, T *out) {                               \
        long long x;                                                        \
        if (!sl_jd_signed(p, (LO), (HI), &x)) return false;                 \
        *out = (T)x;                                                        \
        return true;                                                        \
    }

#define SL_JD_UNSIGNED(NAME, T, HI)                                         \
    static bool NAME(sl_jparser *p, T *out) {                               \
        unsigned long long x;                                               \
        if (!sl_jd_unsigned(p, (HI), &x)) return false;                     \
        *out = (T)x;                                                        \
        return true;                                                        \
    }

SL_JD_SIGNED(sl_jd_i8, int8_t, INT8_MIN, INT8_MAX)
SL_JD_SIGNED(sl_jd_i16, int16_t, INT16_MIN, INT16_MAX)
SL_JD_SIGNED(sl_jd_i32, int32_t, INT32_MIN, INT32_MAX)
SL_JD_UNSIGNED(sl_jd_u8, uint8_t, UINT8_MAX)
SL_JD_UNSIGNED(sl_jd_u16, uint16_t, UINT16_MAX)
SL_JD_UNSIGNED(sl_jd_u32, uint32_t, UINT32_MAX)
SL_JD_SIGNED(sl_jd_i64, int64_t, INT64_MIN, INT64_MAX)
SL_JD_UNSIGNED(sl_jd_u64, uint64_t, UINT64_MAX)
/* int is long long, i64 int64_t: see sl_json_dec_int. */
SL_JD_SIGNED(sl_jd_int, long long, INT64_MIN, INT64_MAX)

/* strtod reads a terminated copy of the text, the same text the tree
 * parser hands it, so the double is the same one. */
static bool sl_jd_f64(sl_jparser *p, double *out) {
    long long start;
    if (!sl_jd_number(p, &start)) return false;
    long long n = p->pos - start;
    char buf[64];
    char *tmp = buf;
    if (n >= (long long)sizeof(buf))
        tmp = (char *)sl_gc_alloc((size_t)n + 1, NULL);
    memcpy(tmp, p->s + start, (size_t)n);
    tmp[n] = 0;
    /* strtod reads the locale, behind libc's own lock */
    sl_rt_preempt_disable();
    *out = strtod(tmp, NULL);
    sl_rt_preempt_enable();
    return true;
}

static bool sl_jd_f32(sl_jparser *p, float *out) {
    double d;
    if (!sl_jd_f64(p, &d)) return false;
    *out = (float)d;
    return true;
}

/* ---- json: output string builder ---- */

typedef struct { char *data; long long len, cap; } sl_json_sb;

static void sl_json_sb_init(sl_json_sb *sb) {
    sb->data = NULL;
    sb->len = 0;
    sb->cap = 0;
}

static void sl_json_sb_append_n(sl_json_sb *sb, const char *s, long long n) {
    if (sb->len + n + 1 > sb->cap) {
        long long cap = sb->cap ? sb->cap * 2 : 64;
        while (cap < sb->len + n + 1) cap *= 2;
        sb->data = (char *)sl_gc_realloc(sb->data, (size_t)cap);
        sb->cap = cap;
    }
    memcpy(sb->data + sb->len, s, (size_t)n);
    sb->len += n;
    sb->data[sb->len] = 0;
}

static void sl_json_sb_append(sl_json_sb *sb, const char *s) {
    sl_json_sb_append_n(sb, s, (long long)strlen(s));
}

/* ---- json: scalar encode helpers ---- */

static void sl_json_enc_bytes(sl_bytes *b, sl_json_sb *out) {
    sl_json_sb_append_n(out, "\"", 1);
    long long i = 0;
    while (i + 3 <= b->len) {
        unsigned n = ((unsigned)b->ptr[i] << 16) |
                     ((unsigned)b->ptr[i + 1] << 8) |
                     (unsigned)b->ptr[i + 2];
        char q[4];
        q[0] = sl_b64_alpha[(n >> 18) & 63];
        q[1] = sl_b64_alpha[(n >> 12) & 63];
        q[2] = sl_b64_alpha[(n >> 6) & 63];
        q[3] = sl_b64_alpha[n & 63];
        sl_json_sb_append_n(out, q, 4);
        i += 3;
    }
    if (i < b->len) {
        unsigned n = (unsigned)b->ptr[i] << 16;
        if (i + 1 < b->len) n |= (unsigned)b->ptr[i + 1] << 8;
        char q[4];
        q[0] = sl_b64_alpha[(n >> 18) & 63];
        q[1] = sl_b64_alpha[(n >> 12) & 63];
        q[2] = (i + 1 < b->len) ? sl_b64_alpha[(n >> 6) & 63] : '=';
        q[3] = '=';
        sl_json_sb_append_n(out, q, 4);
    }
    sl_json_sb_append_n(out, "\"", 1);
}

static void sl_json_enc_str(const char *s, sl_json_sb *out) {
    sl_json_sb_append_n(out, "\"", 1);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  sl_json_sb_append(out, "\\\""); break;
        case '\\': sl_json_sb_append(out, "\\\\"); break;
        case '\n': sl_json_sb_append(out, "\\n"); break;
        case '\r': sl_json_sb_append(out, "\\r"); break;
        case '\t': sl_json_sb_append(out, "\\t"); break;
        case '\b': sl_json_sb_append(out, "\\b"); break;
        case '\f': sl_json_sb_append(out, "\\f"); break;
        default:
            if (*p < 0x20) {
                char buf[8];
                sl_rt_preempt_disable(); /* Tier 11 eighth slice --
                    snprintf's internal locale locking, see sl_jerr's
                    own comment above */
                snprintf(buf, sizeof(buf), "\\u%04x", *p);
                sl_rt_preempt_enable();
                sl_json_sb_append(out, buf);
            } else {
                char c = (char)*p;
                sl_json_sb_append_n(out, &c, 1);
            }
        }
    }
    sl_json_sb_append_n(out, "\"", 1);
}

/* Tier 11 eighth slice: bracketed -- see sl_jerr's own comment
 * above for why (snprintf's internal locale locking). */
static void sl_json_enc_i64(long long v, sl_json_sb *out) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", v);
    sl_rt_preempt_enable();
    sl_json_sb_append(out, buf);
}

static void sl_json_enc_u64(unsigned long long v, sl_json_sb *out) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", v);
    sl_rt_preempt_enable();
    sl_json_sb_append(out, buf);
}

static void sl_json_enc_f64(double v, sl_json_sb *out) {
    sl_rt_preempt_disable();
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    sl_rt_preempt_enable();
    sl_json_sb_append(out, buf);
}

static void sl_json_enc_bool(bool v, sl_json_sb *out) {
    sl_json_sb_append(out, v ? "true" : "false");
}

static void sl_json_enc_null(sl_json_sb *out) {
    sl_json_sb_append(out, "null");
}

/* ---- json: map iteration helpers (sl_map is defined earlier in
 * RUNTIME; these read its fields directly, in insertion order) ---- */

static const char *sl_json_map_key_at(sl_map *m, long long i) {
    long long slot = m->order[i];
    return *(const char **)(m->keys + (size_t)slot * m->ksz);
}

static void *sl_json_map_val_at(sl_map *m, long long i) {
    long long slot = m->order[i];
    return m->vals + (size_t)slot * m->vsz;
}
