/* inspect(x): JavaScript-console-style rendering of any value.
 *
 * A `str` is a NUL-terminated GC string, so the builder below mirrors
 * sl_json_sb's own shape (sl_json.c): exponential growth through
 * sl_gc_realloc, always NUL-terminated. It is a separate type with its
 * own name because the two builders can coexist in one generated
 * program (a program can both json.encode and inspect) and two
 * file-scope `static` helpers with the same name in one translation
 * unit would be a redefinition error.
 *
 * Only scalar appends live here. Composite printers (lists, maps,
 * structs, opt/result, enums) are monomorphized per slang type by
 * src/codegen/inspect.c, which knows each type's C layout; this file
 * cannot, since element/field types are erased at runtime.
 *
 * snprintf calls are bracketed exactly like sl_str_from_int's own
 * (sl_containers.c): libc's locale locking is not async-preemption
 * safe, and an interruption mid-call with a later task migration
 * abandoned the lock and crashed a later unrelated snprintf. */

typedef struct { char *data; long long len, cap; } sl_inspect_sb;

#define SL_INSPECT_MAX_DEPTH 8

static void sl_inspect_sb_init(sl_inspect_sb *sb) {
    sb->data = NULL;
    sb->len = 0;
    sb->cap = 0;
}

static void sl_inspect_sb_append_n(sl_inspect_sb *sb, const char *s,
                                   long long n) {
    if (n <= 0)
        return;
    if (sb->len + n + 1 > sb->cap) {
        long long cap = sb->cap ? sb->cap * 2 : 64;
        while (cap < sb->len + n + 1)
            cap *= 2;
        sb->data = (char *)sl_gc_realloc(sb->data, (size_t)cap);
        sb->cap = cap;
    }
    memcpy(sb->data + sb->len, s, (size_t)n);
    sb->len += n;
    sb->data[sb->len] = 0;
}

static void sl_inspect_sb_append(sl_inspect_sb *sb, const char *s) {
    sl_inspect_sb_append_n(sb, s, (long long)strlen(s));
}

/* Hands the built text to the caller as a GC str. An empty inspection
 * (only possible for a zero-length... in practice never, but cheap to
 * be total) still returns a valid empty string, never NULL. */
static char *sl_inspect_sb_finish(sl_inspect_sb *sb) {
    if (!sb->data)
        return sl_strdup("");
    return sb->data;
}

static void sl_inspect_i64(sl_inspect_sb *out, long long v) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", v);
    sl_rt_preempt_enable();
    sl_inspect_sb_append(out, buf);
}

static void sl_inspect_u64(sl_inspect_sb *out, unsigned long long v) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", v);
    sl_rt_preempt_enable();
    sl_inspect_sb_append(out, buf);
}

static void sl_inspect_f64(sl_inspect_sb *out, double v) {
    sl_rt_preempt_disable();
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    sl_rt_preempt_enable();
    sl_inspect_sb_append(out, buf);
}

static void sl_inspect_bool(sl_inspect_sb *out, bool v) {
    sl_inspect_sb_append(out, v ? "true" : "false");
}

/* Strings render double-quoted with JSON-style escapes, so an empty
 * string shows as "" (visible, not invisible) and a string holding
 * digits never reads as a number. A NULL pointer (never produced by
 * live code, but cheap to be total over) renders as "". */
static void sl_inspect_str(sl_inspect_sb *out, const char *s) {
    sl_inspect_sb_append_n(out, "\"", 1);
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            switch (*p) {
            case '"': sl_inspect_sb_append(out, "\\\""); break;
            case '\\': sl_inspect_sb_append(out, "\\\\"); break;
            case '\n': sl_inspect_sb_append(out, "\\n"); break;
            case '\r': sl_inspect_sb_append(out, "\\r"); break;
            case '\t': sl_inspect_sb_append(out, "\\t"); break;
            case '\b': sl_inspect_sb_append(out, "\\b"); break;
            case '\f': sl_inspect_sb_append(out, "\\f"); break;
            default:
                if (*p < 0x20) {
                    sl_rt_preempt_disable();
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", *p);
                    sl_rt_preempt_enable();
                    sl_inspect_sb_append(out, buf);
                } else {
                    char c = (char)*p;
                    sl_inspect_sb_append_n(out, &c, 1);
                }
            }
        }
    }
    sl_inspect_sb_append_n(out, "\"", 1);
}

static const char sl_inspect_b64_alpha[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Bytes have no printable form of their own; base64 in quotes keeps
 * them unambiguous next to str (same choice as json's own byte
 * encoding, so the two never disagree about what a bytes value
 * looks like). */
static void sl_inspect_bytes(sl_inspect_sb *out, sl_bytes *b) {
    sl_inspect_sb_append_n(out, "\"", 1);
    if (b && b->ptr && b->len > 0) {
        long long i = 0;
        while (i + 3 <= b->len) {
            unsigned n = ((unsigned)b->ptr[i] << 16) |
                         ((unsigned)b->ptr[i + 1] << 8) |
                         (unsigned)b->ptr[i + 2];
            char q[4];
            q[0] = sl_inspect_b64_alpha[(n >> 18) & 63];
            q[1] = sl_inspect_b64_alpha[(n >> 12) & 63];
            q[2] = sl_inspect_b64_alpha[(n >> 6) & 63];
            q[3] = sl_inspect_b64_alpha[n & 63];
            sl_inspect_sb_append_n(out, q, 4);
            i += 3;
        }
        if (i < b->len) {
            unsigned n = (unsigned)b->ptr[i] << 16;
            if (i + 1 < b->len)
                n |= (unsigned)b->ptr[i + 1] << 8;
            char q[4];
            q[0] = sl_inspect_b64_alpha[(n >> 18) & 63];
            q[1] = sl_inspect_b64_alpha[(n >> 12) & 63];
            q[2] = (i + 1 < b->len) ? sl_inspect_b64_alpha[(n >> 6) & 63]
                                    : '=';
            q[3] = '=';
            sl_inspect_sb_append_n(out, q, 4);
        }
    }
    sl_inspect_sb_append_n(out, "\"", 1);
}

/* A fault renders as fault("...") with its human-readable form quoted
 * inside, so it never reads as a plain string: the prefix names the
 * kind of thing it is, the quotes show exactly where its text ends. */
static void sl_inspect_fault(sl_inspect_sb *out, sl_fault f) {
    char *s = sl_str_from_fault(f);
    sl_inspect_sb_append(out, "fault(");
    sl_inspect_str(out, s);
    sl_inspect_sb_append_n(out, ")", 1);
}

/* A peer renders the way println already shows it (1.2.3.4:5678),
 * unquoted: it is an address, not text. */
static void sl_inspect_peer(sl_inspect_sb *out, sl_peer p) {
    sl_rt_preempt_disable();
    char buf[32];
    snprintf(buf, sizeof(buf), "%u.%u.%u.%u:%u",
             (unsigned)((p.addr >> 24) & 255u),
             (unsigned)((p.addr >> 16) & 255u),
             (unsigned)((p.addr >> 8) & 255u),
             (unsigned)(p.addr & 255u), (unsigned)p.port);
    sl_rt_preempt_enable();
    sl_inspect_sb_append(out, buf);
}

static void sl_inspect_until(sl_inspect_sb *out, sl_until u) {
    sl_inspect_i64(out, (long long)u);
}

/* An arena view has no owned text of its own; show exactly the bytes
 * it views, quoted like a str. A caller that needs ownership copies
 * into bytes first -- inspect never allocates ownership, it only
 * looks. */
static void sl_inspect_wire(sl_inspect_sb *out, sl_wire w) {
    sl_inspect_sb_append_n(out, "\"", 1);
    for (long long i = 0; i < w.len; i++) {
        unsigned char c = w.ptr[i];
        switch (c) {
        case '"': sl_inspect_sb_append(out, "\\\""); break;
        case '\\': sl_inspect_sb_append(out, "\\\\"); break;
        case '\n': sl_inspect_sb_append(out, "\\n"); break;
        case '\r': sl_inspect_sb_append(out, "\\r"); break;
        case '\t': sl_inspect_sb_append(out, "\\t"); break;
        default:
            if (c < 0x20) {
                sl_rt_preempt_disable();
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                sl_rt_preempt_enable();
                sl_inspect_sb_append(out, buf);
            } else {
                char ch = (char)c;
                sl_inspect_sb_append_n(out, &ch, 1);
            }
        }
    }
    sl_inspect_sb_append_n(out, "\"", 1);
}

/* Insertion-order value slot, the same three lines as json's own
 * map-value helper (sl_json_map_val_at): slot i's value lives at
 * order[i]. A separate copy because that helper only exists when
 * json is also in use, and inspect must stand alone. */
static void *sl_inspect_map_val_at(sl_map *m, long long i) {
    long long slot = m->order[i];
    return m->vals + (size_t)slot * m->vsz;
}
