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

static int sl_jmatch_lit(sl_jparser *p, const char *lit) {
    long long n = (long long)strlen(lit);
    if (p->pos + n > p->len) return 0;
    if (memcmp(p->s + p->pos, lit, (size_t)n) != 0) return 0;
    p->pos += n;
    return 1;
}

/* ---- json: iterative tree parse ----
 *
 * The parse descends into arrays and objects with an explicit heap
 * stack, never C recursion, so nesting depth costs heap, not the
 * calling task's stack. Task stacks start at 8KB and grow only at slang
 * safepoints, which a C recursion never reaches, so a recursive descent
 * here ran out of stack at a nesting of about 80, far below
 * SL_JSON_MAX_DEPTH.
 *
 * Every byte is peeked, skipped and consumed in the order the recursive
 * parser did, so every error message and byte position is unchanged
 * (tests/json_parity pins them), and a successful parse makes the same
 * allocations.
 *
 * GC. A collection cannot start inside this function on its own --
 * there is no safepoint in it, and sl_gc_alloc only arms a pending flag
 * -- but an async preemption can suspend the task here while another
 * thread collects. That collection finds this task's live values only
 * by scanning its stack conservatively. So the frame stack below, which
 * is malloc'd and never scanned, must never be the only thing holding a
 * node: every container is linked into its parent the moment it opens
 * (an object reserves its member's slot, value NULL, when the key is
 * read), so everything parsed so far is reachable from `root`, a local.
 * A container can therefore be promoted mid-parse, and each later store
 * into it is followed by the write barrier (sl_jstore). */
typedef struct {
    sl_json_val *v;   /* the array or object being filled */
    long long cap;    /* its items, or keys/vals, capacity */
} sl_jframe;

/* The barrier after a store into container v. Store first, then check:
 * if a collection promoted v before the store, gen reads 1 here and v is
 * remembered; if one ran after the store, v was still young then and
 * that collection traced the stored child itself. The remember call is
 * bracketed for its shard malloc and its task lookup. */
static inline void sl_jstore_barrier(sl_json_val *v) {
    sl_gc_obj *h = (sl_gc_obj *)v - 1;
    if (h->gen == 1 && !h->remembered) {
        sl_rt_preempt_disable();
        sl_gc_remember_obj(h);
        sl_rt_preempt_enable();
    }
}

/* Make room for one more element or member of f->v. The owned buffers
 * take v's generation, and the bracket keeps that generation fixed from
 * the allocation to the store into v (sl_arr_reserve). */
static void sl_jreserve(sl_jframe *f) {
    sl_json_val *v = f->v;
    long long len = v->kind == SL_JV_OBJ ? v->as.obj.len : v->as.arr.len;
    if (len < f->cap) return;
    f->cap = f->cap ? f->cap * 2 : 4;
    sl_rt_preempt_disable();
    if (v->kind == SL_JV_OBJ) {
        v->as.obj.keys = (char **)sl_gc_realloc_owned(
            v->as.obj.keys, (size_t)f->cap * sizeof(char *), v);
        v->as.obj.vals = (sl_json_val **)sl_gc_realloc_owned(
            v->as.obj.vals, (size_t)f->cap * sizeof(sl_json_val *), v);
    } else {
        v->as.arr.items = (sl_json_val **)sl_gc_realloc_owned(
            v->as.arr.items, (size_t)f->cap * sizeof(sl_json_val *), v);
    }
    sl_rt_preempt_enable();
}

/* `val` is the next element of an array, or the value of the member
 * whose slot sl_jparse_value reserved when it read the key. */
static void sl_jplace(sl_jframe *f, sl_json_val *val) {
    sl_json_val *v = f->v;
    if (v->kind == SL_JV_OBJ) {
        v->as.obj.vals[v->as.obj.len - 1] = val;
    } else {
        sl_jreserve(f);
        v->as.arr.items[v->as.arr.len++] = val;
    }
    sl_jstore_barrier(v);
}

static sl_json_val *sl_jparse_value(sl_jparser *p) {
    sl_jframe *st = NULL;     /* open containers, innermost last */
    long long n = 0, cap = 0; /* its depth and capacity */
    sl_json_val *root = NULL;
    for (;;) {
        /* ---- one value ---- */
        sl_json_val *val;
        sl_jskip_ws(p);
        int c = sl_jpeek(p);
        if (c < 0) { sl_jerr(p, "unexpected end of input"); goto fail; }
        if (c == '"') {
            sl_jnext(p);
            if (!(val = sl_jparse_string(p))) goto fail;
        } else if (c == '{' || c == '[') {
            sl_jnext(p);
            if (++p->depth > SL_JSON_MAX_DEPTH) {
                sl_jerr(p, "maximum nesting depth (%d) exceeded",
                        SL_JSON_MAX_DEPTH);
                goto fail;
            }
            val = sl_jv_new(c == '{' ? SL_JV_OBJ : SL_JV_ARR);
            /* sl_gc_alloc zero-fills: items/keys/vals NULL, len 0 */
        } else if (c == '-' || (c >= '0' && c <= '9')) {
            if (!(val = sl_jparse_number(p))) goto fail;
        } else if (c == 't') {
            if (!sl_jmatch_lit(p, "true")) { sl_jerr(p, "invalid literal"); goto fail; }
            val = sl_jv_new(SL_JV_BOOL); val->as.b = true;
        } else if (c == 'f') {
            if (!sl_jmatch_lit(p, "false")) { sl_jerr(p, "invalid literal"); goto fail; }
            val = sl_jv_new(SL_JV_BOOL); val->as.b = false;
        } else if (c == 'n') {
            if (!sl_jmatch_lit(p, "null")) { sl_jerr(p, "invalid literal"); goto fail; }
            val = sl_jv_new(SL_JV_NULL);
        } else {
            sl_jerr(p, "unexpected character '%c'", c >= 32 && c < 127 ? c : '?');
            goto fail;
        }
        if (n == 0) root = val;
        else sl_jplace(&st[n - 1], val);

        if (val->kind == SL_JV_ARR || val->kind == SL_JV_OBJ) {
            if (n == cap) {
                long long ncap = cap ? cap * 2 : 16;
                sl_rt_preempt_disable();
                sl_jframe *ns = (sl_jframe *)realloc(st, (size_t)ncap * sizeof(*st));
                sl_rt_preempt_enable();
                if (!ns) { sl_jerr(p, "out of memory"); goto fail; }
                st = ns;
                cap = ncap;
            }
            st[n].v = val;
            st[n].cap = 0;
            n++;
            int close = val->kind == SL_JV_OBJ ? '}' : ']';
            sl_jskip_ws(p);
            if (sl_jpeek(p) == close) {
                sl_jnext(p);
                p->depth--;
                n--;
            } else if (val->kind == SL_JV_ARR) {
                continue; /* its first element */
            } else {
                goto key; /* its first member */
            }
        }

        /* ---- after a value: close containers until one continues ---- */
        for (;;) {
            if (n == 0) goto done;
            sl_jframe *f = &st[n - 1];
            int obj = f->v->kind == SL_JV_OBJ;
            sl_jskip_ws(p);
            int d = sl_jnext(p);
            if (d == ',') break;
            if (d == (obj ? '}' : ']')) {
                p->depth--;
                n--;
                continue;
            }
            sl_jerr(p, obj ? "expected ',' or '}' in object"
                           : "expected ',' or ']' in array");
            goto fail;
        }
        if (st[n - 1].v->kind == SL_JV_ARR) continue; /* next element */

    key: {
        /* ---- an object member's key and colon; reserves its slot ---- */
        sl_jframe *f = &st[n - 1];
        sl_jskip_ws(p);
        if (sl_jpeek(p) != '"') {
            sl_jerr(p, "expected string key in object");
            goto fail;
        }
        sl_jnext(p);
        char *k = sl_jparse_string_raw(p);
        if (!k) goto fail;
        sl_jskip_ws(p);
        if (sl_jnext(p) != ':') {
            sl_jerr(p, "expected ':' after object key");
            goto fail;
        }
        sl_jreserve(f);
        sl_json_val *o = f->v;
        o->as.obj.keys[o->as.obj.len] = k;
        o->as.obj.vals[o->as.obj.len] = NULL;
        o->as.obj.len++;
        sl_jstore_barrier(o);
    }
    }

done:
    if (st) {
        sl_rt_preempt_disable();
        free(st);
        sl_rt_preempt_enable();
    }
    return root;

fail:
    /* the recursive parser undid each open level's depth on its way out */
    p->depth -= n;
    root = NULL;
    goto done;
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
 * tree's field lookup). It accepts and rejects exactly what the tree
 * parser does; on a reject the caller falls back to the tree, which
 * names the error.
 *
 * A loop with a bit per open level (object or array), not recursion:
 * this runs on the task's stack, which starts at 8KB and does not grow
 * inside C, so recursing once per level of the input ran out of it long
 * before SL_JSON_MAX_DEPTH. sl_jd_open enforces that cap, so its bits
 * (64 bytes) are all the levels one call can open. noinline keeps those
 * 64 bytes out of the frames of the recursive sl_jdf_* decoders that
 * call this. Containers are tested after the scalars because most
 * values are scalars; in that order this is a little faster than the
 * recursive version was on a 97KB body. */
__attribute__((noinline))
static bool sl_jd_skip(sl_jparser *p) {
    unsigned char obj_stack[(SL_JSON_MAX_DEPTH + 7) / 8];
    int depth = 0;  /* levels this call has opened and not yet closed */
    int in_obj = 0; /* whether the innermost of them is an object */
    for (;;) {
        int c = sl_jd_peek(p);
        if (c == '"') {
            p->pos++;
            if (!sl_jd_skip_string(p)) return false;
        } else if (c == '-' || (c >= '0' && c <= '9')) {
            long long start;
            if (!sl_jd_number(p, &start)) return false;
        } else if (c == 't') {
            if (!sl_jmatch_lit(p, "true")) return false;
        } else if (c == 'f') {
            if (!sl_jmatch_lit(p, "false")) return false;
        } else if (c == 'n') {
            if (!sl_jmatch_lit(p, "null")) return false;
        } else if (c == '[' || c == '{') {
            int is_obj = c == '{';
            if (!sl_jd_open(p, c)) return false; /* caps the nesting */
            if (!sl_jd_empty(p, is_obj ? '}' : ']')) {
                if (is_obj)
                    obj_stack[depth >> 3] |= (unsigned char)(1u << (depth & 7));
                else
                    obj_stack[depth >> 3] &= (unsigned char)~(1u << (depth & 7));
                depth++;
                in_obj = is_obj;
                if (is_obj && (!sl_jd_eat(p, '"') || !sl_jd_skip_string(p) ||
                               !sl_jd_eat(p, ':')))
                    return false;
                continue; /* the first element or member's value */
            }
        } else {
            return false;
        }
        /* A value is done: past its separator, closing what ends here. */
        for (;;) {
            if (depth == 0) return true;
            bool closed;
            if (sl_jd_more(p, in_obj ? '}' : ']', &closed)) {
                if (in_obj && (!sl_jd_eat(p, '"') || !sl_jd_skip_string(p) ||
                               !sl_jd_eat(p, ':')))
                    return false;
                break; /* the next element or member's value */
            }
            if (!closed) return false;
            depth--;
            if (depth)
                in_obj = (obj_stack[(depth - 1) >> 3] >> ((depth - 1) & 7)) & 1;
        }
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

/* The next key, if it is exactly the literal q (the key in quotes, qn
 * bytes, no escapes): 1 with it and its colon consumed, 0 with nothing
 * consumed but whitespace, -1 on a missing colon. A struct decoder tries
 * the field it expects next this way -- keys nearly always arrive in
 * declaration order -- before scanning the key with sl_jd_key and
 * comparing it against every field. A key written with escapes never
 * matches the literal and takes that general path, which decodes it. */
static inline int sl_jd_key_is(sl_jparser *p, const char *q, long long qn) {
    sl_jskip_ws(p);
    if (p->len - p->pos < qn || memcmp(p->s + p->pos, q, (size_t)qn) != 0)
        return 0;
    p->pos += qn;
    return sl_jd_eat(p, ':') ? 1 : -1;
}

/* The end of the whole input: only whitespace may follow the value. */
static bool sl_jd_end(sl_jparser *p) {
    sl_jskip_ws(p);
    return p->pos == p->len;
}

/* ---- json: stack for recursive target types ----
 *
 * A target type that contains itself (a struct holding opt[Self], [Self]
 * or map[str]Self, directly or through other types) is decoded by C
 * functions that recurse once per level of the data -- that is what
 * decoding a tree means -- and C recursion never reaches a safepoint, so
 * it never grows the task's stack. For those types only, codegen measures
 * the input's nesting with sl_json_depth before decoding and passes it
 * here with `per_level`, the stack one level can cost (its derivation is
 * at json_level_bytes, src/codegen/pkg_json/dispatch.c). The stack grows
 * only when this input needs more than the task has left, so a shallow
 * decode costs one scan of its input and no memory. */

/* The deepest nesting of brackets in s[0..n), outside strings. Not a
 * validator, and never an underestimate of how deep a decoder can get:
 * on the prefix a decoder accepts, this agrees with it about where
 * strings start and end, and a decoder stops at the first byte it
 * rejects. Stops counting past SL_JSON_MAX_DEPTH, where they all stop. */
static long long sl_json_depth(const char *s, long long n) {
    long long d = 0, max = 0;
    for (long long i = 0; i < n; i++) {
        char c = s[i];
        if (c == '"') {
            for (i++; i < n && s[i] != '"'; i++)
                if (s[i] == '\\') i++;
        } else if (c == '[' || c == '{') {
            if (++d > max) {
                max = d;
                if (max > SL_JSON_MAX_DEPTH) break;
            }
        } else if ((c == ']' || c == '}') && d > 0) {
            d--;
        }
    }
    return max;
}

/* Before decoding s[0..n) into a recursive type: grow the task's stack if
 * the input's nesting, at `per_level` bytes a level, needs more than it
 * has left. Nesting cannot exceed the length, so a body too short to
 * matter is not even scanned. Called from generated code at the
 * json.decode call site, where moving the stack is safe (see
 * sl_rt_stack_reserve). */
static void sl_json_stack_for(const char *s, long long n, size_t per_level) {
    sl_task *t = sl_rt_cur();
    if (!t || !t->stack_base) return;
    char probe;
    size_t room = (size_t)((uintptr_t)&probe - (uintptr_t)t->stack_base);
    if (room < SL_TASK_GUARD_MARGIN) room = 0;
    else room -= SL_TASK_GUARD_MARGIN;
    long long levels = n < SL_JSON_MAX_DEPTH ? n : SL_JSON_MAX_DEPTH;
    if ((size_t)levels * per_level <= room) return;
    levels = sl_json_depth(s, n);
    if (levels > SL_JSON_MAX_DEPTH) levels = SL_JSON_MAX_DEPTH;
    if ((size_t)levels * per_level <= room) return;
    sl_rt_stack_reserve((size_t)levels * per_level);
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

/* One pass over a plain integer token: an optional '-', then "0" or up
 * to 18 digits without a leading zero, not followed by '.', 'e' or 'E'.
 * That is every integer field of an ordinary body (ids, counts, cents),
 * and 18 digits cannot overflow 64 bits. Anything else -- a fraction, an
 * exponent, a longer number -- returns false with the position untouched,
 * and the caller takes the exact two-pass path (sl_jd_number, then
 * sl_json_num_int_n), whose results this matches wherever it answers.
 * The two passes were a tenth of a quote decode's time. */
static bool sl_jd_int_fast(sl_jparser *p, bool *neg,
                           unsigned long long *mag) {
    const char *s = p->s;
    long long i = p->pos, len = p->len;
    bool ng = false;
    if (i < len && s[i] == '-') {
        ng = true;
        i++;
    }
    if (i >= len) return false;
    unsigned long long v = 0;
    if (s[i] == '0') {
        i++;
    } else if (s[i] >= '1' && s[i] <= '9') {
        int nd = 0;
        while (i < len && s[i] >= '0' && s[i] <= '9') {
            if (++nd > 18) return false;
            v = v * 10 + (unsigned long long)(s[i] - '0');
            i++;
        }
    } else {
        return false;
    }
    if (i < len && (s[i] == '.' || s[i] == 'e' || s[i] == 'E'))
        return false;
    p->pos = i;
    *neg = ng;
    *mag = v;
    return true;
}

/* The next number as an integer in [lo, hi], or false. */
static bool sl_jd_signed(sl_jparser *p, long long lo, long long hi,
                         long long *out) {
    bool neg;
    unsigned long long mag;
    sl_jskip_ws(p);
    if (!sl_jd_int_fast(p, &neg, &mag)) {
        long long start;
        if (!sl_jd_number(p, &start)) return false;
        if (sl_json_num_int_n(p->s + start, p->s + p->pos, &neg, &mag) !=
            SL_JSON_INT_OK)
            return false;
    }
    unsigned long long neg_lim = lo < 0 ? (unsigned long long)(-(lo + 1)) + 1 : 0;
    if ((!neg && mag > (unsigned long long)hi) || (neg && mag > neg_lim))
        return false;
    *out = (!neg || mag == 0) ? (long long)mag : -(long long)(mag - 1) - 1;
    return true;
}

static bool sl_jd_unsigned(sl_jparser *p, unsigned long long hi,
                           unsigned long long *out) {
    bool neg;
    unsigned long long mag;
    sl_jskip_ws(p);
    if (!sl_jd_int_fast(p, &neg, &mag)) {
        long long start;
        if (!sl_jd_number(p, &start)) return false;
        if (sl_json_num_int_n(p->s + start, p->s + p->pos, &neg, &mag) !=
            SL_JSON_INT_OK)
            return false;
    }
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

static void sl_json_sb_grow(sl_json_sb *sb, long long need) {
    if (sb->len + need + 1 > sb->cap) {
        long long cap = sb->cap ? sb->cap * 2 : 64;
        while (cap < sb->len + need + 1) cap *= 2;
        sb->data = (char *)sl_gc_realloc(sb->data, (size_t)cap);
        sb->cap = cap;
    }
}

/* One allocation for what the caller knows it will write (json.encode's
 * call site passes a skeleton estimate from the static type): a ~200-byte
 * quote response fits its first buffer instead of climbing 64->128->256.
 * An underestimate just grows as before, so this never changes output. */
static void sl_json_sb_reserve(sl_json_sb *sb, long long need) {
    if (need > 0 && sb->len + need + 1 > sb->cap) {
        sb->data = (char *)sl_gc_realloc(sb->data, (size_t)(sb->len + need + 1));
        sb->cap = sb->len + need + 1;
    }
}

static void sl_json_sb_append_n(sl_json_sb *sb, const char *s, long long n) {
    sl_json_sb_grow(sb, n);
    memcpy(sb->data + sb->len, s, (size_t)n);
    sb->len += n;
    sb->data[sb->len] = 0;
}

static void sl_json_sb_append(sl_json_sb *sb, const char *s) {
    sl_json_sb_append_n(sb, s, (long long)strlen(s));
}

/* Escaping tail of the string encoder below, predeclared: the clean fast
 * path calls it, so it must be declared before it. */
static void sl_json_enc_str_esc(const char *s, long long n, long long i,
                                sl_json_sb *out);

/* No byte needing an escape: quotes and bytes in one grow check. */
static void sl_json_enc_str_clean(const char *s, long long n, sl_json_sb *out) {
    sl_json_sb_grow(out, n + 2);
    char *w = out->data + out->len;
    w[0] = '"';
    memcpy(w + 1, s, (size_t)n);
    w[n + 1] = '"';
    w[n + 2] = 0;
    out->len += n + 2;
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
    long long n = (long long)strlen(s);
    long long i = 0;
    /* Strings with no escape (every SKU and region on the quote path)
     * take the memcpy path. Only the first dirty byte diverts to the
     * reserving tail. */
    while (i < n) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\' || c < 0x20) break;
        i++;
    }
    if (i == n) {
        sl_json_enc_str_clean(s, n, out);
        return;
    }
    sl_json_enc_str_esc(s, n, i, out);
}

static void sl_json_enc_str_esc(const char *s, long long n, long long i,
                                sl_json_sb *out) {
    /* Worst case: every byte becomes \u00XX (6 bytes), plus the quotes.
     * The clean prefix s[0..i) copies first, so the loop starts at the
     * first dirty byte instead of re-walking it. */
    sl_json_sb_grow(out, n * 6 + 2);
    char *w = out->data + out->len;
    char *dst = w;
    *w++ = '"';
    if (i > 0) {
        memcpy(w, s, (size_t)i);
        w += i;
    }
    for (const unsigned char *p = (const unsigned char *)s + i; *p; p++) {
        switch (*p) {
        case '"':  *w++ = '\\'; *w++ = '"'; break;
        case '\\': *w++ = '\\'; *w++ = '\\'; break;
        case '\n': *w++ = '\\'; *w++ = 'n'; break;
        case '\r': *w++ = '\\'; *w++ = 'r'; break;
        case '\t': *w++ = '\\'; *w++ = 't'; break;
        case '\b': *w++ = '\\'; *w++ = 'b'; break;
        case '\f': *w++ = '\\'; *w++ = 'f'; break;
        default:
            if (*p < 0x20) {
                /* No libc: the old tail below snprintf'd "\\u%04x" here
                 * behind a preempt bracket (see sl_jerr). A control byte
                 * is one hex digit short of 0x10, zero-padded to four. */
                static const char hexd[16] = "0123456789abcdef";
                *w++ = '\\'; *w++ = 'u'; *w++ = '0'; *w++ = '0';
                *w++ = hexd[(*p >> 4) & 15]; *w++ = hexd[*p & 15];
            } else {
                *w++ = (char)*p;
            }
        }
    }
    *w++ = '"';
    *w = 0;
    out->len += w - dst;
}

/* Tier 11 eighth slice: bracketed -- see sl_jerr's own comment
 * above for why (snprintf's internal locale locking). i64/u64 bypass it
 * entirely below with a digit loop: snprintf's locale lock is the reason
 * the bracket existed at all, and %lld pays a full format parse per
 * value. A quote body carries 4000 of them. */
static void sl_json_enc_i64(long long v, sl_json_sb *out) {
    /* 20 bytes covers sign + 19 digits. */
    sl_json_sb_grow(out, 20);
    char *w = out->data + out->len;
    char *dst = w;
    char tmp[20];
    int n = 0;
    unsigned long long mag;
    if (v < 0) {
        /* INT64_MIN has no positive long long; negate in unsigned. */
        mag = (unsigned long long)(-(v + 1)) + 1;
    } else {
        mag = (unsigned long long)v;
    }
    do {
        tmp[n++] = (char)('0' + mag % 10);
        mag /= 10;
    } while (mag);
    if (v < 0) tmp[n++] = '-';
    for (int i = n - 1; i >= 0; i--) *w++ = tmp[i];
    *w = 0;
    out->len += w - dst;
}

static void sl_json_enc_u64(unsigned long long v, sl_json_sb *out) {
    sl_json_sb_grow(out, 20);
    char *w = out->data + out->len;
    char *dst = w;
    char tmp[20];
    int n = 0;
    do {
        tmp[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    for (int i = n - 1; i >= 0; i--) *w++ = tmp[i];
    *w = 0;
    out->len += w - dst;
}

static void sl_json_enc_f64(double v, sl_json_sb *out) {
    sl_rt_preempt_disable();
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    sl_rt_preempt_enable();
    sl_json_sb_append(out, buf);
}

static void sl_json_enc_bool(bool v, sl_json_sb *out) {
    if (v) {
        sl_json_sb_append_n(out, "true", 4);
    } else {
        sl_json_sb_append_n(out, "false", 5);
    }
}

static void sl_json_enc_null(sl_json_sb *out) {
    sl_json_sb_append_n(out, "null", 4);
}

/* Old byte-at-a-time encoder, kept declared but undefined: documents what
 * the two paths above replace (a strlen per escape, an append per byte,
 * snprintf per integer). Any accidental call fails at link time. */
static void sl_json_enc_str_old(const char *s, sl_json_sb *out);

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
