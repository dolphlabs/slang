/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"
#include "liveness.h"

#include <string.h>


/* ------------------------------------------------------------------ */
/* Diagnostics                                                         */
/* ------------------------------------------------------------------ */

void cg_error(int line, const char *fmt, ...) {
    va_list ap;
    fputs("slang: error at line ", stderr);
    fprintf(stderr, "%d", line);
    fputs(": ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc(10, stderr);
    exit(1);
}

/* ------------------------------------------------------------------ */
/* Small utilities                                                     */
/* ------------------------------------------------------------------ */


void sb_putc(StrBuf *sb, char c) { sb_append_n(sb, &c, 1); }

void sb_nl(StrBuf *sb) { sb_putc(sb, 10); }

/* Render a slang string as a C string literal (with quotes). */
char *c_string_literal(const char *s) {
    StrBuf sb;
    sb_init(&sb);
    sb_putc(&sb, '"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"': sb_append_n(&sb, (const char[]){92, '"', 0}, 2); break;
        case 92:  sb_append_n(&sb, (const char[]){92, 92, 0}, 2); break;
        case 10:  sb_append_n(&sb, (const char[]){92, 'n', 0}, 2); break;
        case 9:   sb_append_n(&sb, (const char[]){92, 't', 0}, 2); break;
        case 13:  sb_append_n(&sb, (const char[]){92, 'r', 0}, 2); break;
        default:
            if (c < 32 || c == 127) {
                static const char hex[] = "0123456789abcdef";
                sb_append_n(&sb,
                            (const char[]){92, 'x', hex[c >> 4], hex[c & 15], 0},
                            4);
            } else {
                sb_putc(&sb, (char)c);
            }
        }
    }
    sb_putc(&sb, '"');
    return sb.data;
}

/* Render raw bytes as a C string literal using 3-digit octal escapes
 * for anything non-printable, so embedded NULs survive verbatim. */
char *c_bytes_literal(const unsigned char *p, long long len) {
    StrBuf sb;
    sb_init(&sb);
    sb_putc(&sb, '"');
    for (long long i = 0; i < len; i++) {
        unsigned char c = p[i];
        if (c >= 32 && c < 127 && c != '"' && c != 92 && c != '?') {
            sb_putc(&sb, (char)c);
        } else {
            sb_append_n(&sb, (const char[]){92, '0' + (char)((c >> 6) & 7),
                                            '0' + (char)((c >> 3) & 7),
                                            '0' + (char)(c & 7), 0},
                        4);
        }
    }
    sb_putc(&sb, '"');
    return sb.data;
}

/* Rename identifiers that collide with C keywords. */
char *sanitize_ident(const char *name) {
    static const char *kws[] = {
        "auto", "break", "case", "char", "const", "continue", "default",
        "do", "double", "else", "enum", "extern", "float", "for", "goto",
        "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch",
        "typedef", "union", "unsigned", "void", "volatile", "while",
        "_Bool", NULL};
    for (int i = 0; kws[i]; i++) {
        if (!strcmp(name, kws[i]))
            return xasprintf("%s_", name);
    }
    return xstrdup(name);
}

/* ------------------------------------------------------------------ */
/* Types (slang-level names mapped to C types at emission time)         */
/* ------------------------------------------------------------------ */

const char *map_type(const char *t) {
    if (!strcmp(t, "int"))    return "long long";
    if (!strcmp(t, "float"))  return "double";
    if (!strcmp(t, "str"))    return "const char *";
    if (!strcmp(t, "bool"))   return "bool";
    if (!strcmp(t, "bytes"))  return "sl_bytes *";
    if (!strcmp(t, "i8"))     return "int8_t";
    if (!strcmp(t, "i16"))    return "int16_t";
    if (!strcmp(t, "i32"))    return "int32_t";
    if (!strcmp(t, "i64"))    return "int64_t";
    if (!strcmp(t, "u8"))     return "uint8_t";
    if (!strcmp(t, "u16"))    return "uint16_t";
    if (!strcmp(t, "u32"))    return "uint32_t";
    if (!strcmp(t, "u64"))    return "uint64_t";
    if (!strcmp(t, "f32"))    return "float";
    if (!strcmp(t, "duration")) return "int64_t";
    if (!strcmp(t, "rawptr")) return "void *";
    if (t[0] == '[')          return "sl_arr *";
    return NULL;
}

int is_int(const char *t) {
    return !strcmp(t, "int") || !strcmp(t, "i8") || !strcmp(t, "i16") ||
           !strcmp(t, "i32") || !strcmp(t, "i64") || !strcmp(t, "u8") ||
           !strcmp(t, "u16") || !strcmp(t, "u32") || !strcmp(t, "u64") ||
           !strcmp(t, "duration");
}

int is_signed_int(const char *t) {
    return !strcmp(t, "int") || !strcmp(t, "i8") || !strcmp(t, "i16") ||
           !strcmp(t, "i32") || !strcmp(t, "i64") ||
           !strcmp(t, "duration");
}

int int_rank(const char *t) {
    if (!strcmp(t, "i8") || !strcmp(t, "u8")) return 0;
    if (!strcmp(t, "i16") || !strcmp(t, "u16")) return 1;
    if (!strcmp(t, "i32") || !strcmp(t, "u32")) return 2;
    return 3; /* i64, u64, int */
}

int is_flt(const char *t) {
    return !strcmp(t, "float") || !strcmp(t, "f32");
}

int is_num(const char *t) { return is_int(t) || is_flt(t); }
int is_str(const char *t) { return !strcmp(t, "str"); }
int is_bytes(const char *t) { return !strcmp(t, "bytes"); }
int is_rawptr(const char *t) { return !strcmp(t, "rawptr"); }
int is_arr(const char *t) { return t[0] == '['; }
int is_map(const char *t) { return !strncmp(t, "map[", 4); }

/* extern fn boundary: only types with an unambiguous, stable C
 * representation may cross into/out of foreign code. GC'd containers
 * (opt/result/map/struct/array) are deliberately excluded -- handing
 * their internal layout to arbitrary C would be unsafe and pointless. */
void check_extern_type(const char *t, int line, const char *what) {
    if (is_num(t) || is_str(t) || is_bytes(t) || !strcmp(t, "bool") ||
        is_rawptr(t))
        return;
    cg_error(line,
             "extern fn %s type '%s' is not FFI-safe; only numeric "
             "types, bool, str, bytes, and rawptr may cross an extern "
             "boundary",
             what, t);
}

/* "map[K]V" -> K and V (heap-allocated). Caller must pass a map type.
 * Keys are scalars (no nested ']'), values may be any type. */
void map_kv(const char *t, char **k, char **v) {
    const char *close = strchr(t + 4, ']');
    size_t kl = (size_t)(close - (t + 4));
    char *kt = (char *)xmalloc(kl + 1);
    memcpy(kt, t + 4, kl);
    kt[kl] = '\0';
    *k = kt;
    *v = xstrdup(close + 1);
}

/* Valid map key types: integers, str, bool. */
int is_map_key(const char *t) {
    return is_int(t) || is_str(t) || !strcmp(t, "bool");
}

int is_opt(const char *t) { return !strncmp(t, "opt[", 4); }
int is_result(const char *t) { return !strncmp(t, "result[", 7); }
int is_chan(const char *t) { return !strncmp(t, "chan[", 5); }

/* Is a value of this slang type a GC-managed heap pointer that a
 * precise stack scanner would need to treat as a root? Excludes
 * rawptr (foreign, never GC-owned -- see the README's C interop
 * safety notes) and every scalar type. `str` counts: it is always a
 * heap buffer (GC_strdup/sl_strdup), just a leaf one with no interior
 * pointers of its own to scan further. */
int type_is_gc_ptr(CG *cg, const char *t) {
    if (is_rawptr(t)) return 0;
    if (is_arr(t) || is_map(t) || is_opt(t) || is_result(t) ||
        is_chan(t) || is_str(t) || is_bytes(t))
        return 1;
    return struct_find_canon(cg, t) != NULL;
    /* else: int / i8..u64 / float / f32 / bool / duration -- scalars,
     * never pointers */
}

/* Does this struct type have at least one GC-pointer field? Every
 * GC-tracked slang type is represented as exactly one C pointer (see
 * ctype_of), so this is exactly "does this struct need a trace
 * function, or can its allocation sites pass a NULL tracer." Shared
 * between emit_struct_tracers (which only emits a tracer when this is
 * true) and every struct allocation call site (which needs the same
 * answer to know whether to reference that tracer or pass NULL). */
int struct_has_gc_fields(CG *cg, StructDef *sd) {
    for (int j = 0; j < sd->nfields; j++)
        if (type_is_gc_ptr(cg, sd->ftypes[j]))
            return 1;
    return 0;
}

/* "opt[T]" -> T (heap-allocated). Caller must pass an opt type. */
char *opt_inner(const char *t) {
    size_t n = strlen(t);
    char *inner = (char *)xmalloc(n - 4);
    memcpy(inner, t + 4, n - 5);
    inner[n - 5] = '\0';
    return inner;
}

/* "chan[T]" -> T (heap-allocated). Caller must pass a chan type. */
char *chan_elem(const char *t) {
    size_t n = strlen(t);
    char *inner = (char *)xmalloc(n - 5);
    memcpy(inner, t + 5, n - 6);
    inner[n - 6] = '\0';
    return inner;
}

/* "result[T,E]" -> T and E (heap-allocated). */
void result_te(const char *t, char **tv, char **ev) {
    const char *comma = strchr(t + 7, ',');
    size_t tl = (size_t)(comma - (t + 7));
    char *a = (char *)xmalloc(tl + 1);
    memcpy(a, t + 7, tl);
    a[tl] = '\0';
    *tv = a;
    size_t el = strlen(comma + 1) - 1; /* strip trailing ']' */
    char *b = (char *)xmalloc(el + 1);
    memcpy(b, comma + 1, el);
    b[el] = '\0';
    *ev = b;
}

/* "[T]" -> "T" (heap-allocated). Caller must pass an array type. */
char *arr_elem(const char *t) {
    size_t n = strlen(t);
    char *inner = (char *)xmalloc(n - 1);
    memcpy(inner, t + 1, n - 2);
    inner[n - 2] = '\0';
    return inner;
}

/* Can a value of slang type `src` be assigned where `dst` is expected?
 * Widening within the int family and toward floats is implicit;
 * narrowing and sign changes require an explicit cast (`as`). */
int can_assign(const char *dst, const char *src) {
    if (!strcmp(dst, src))
        return 1;
    if (is_int(dst) && is_int(src))
        return int_rank(dst) > int_rank(src) &&
               !(is_signed_int(src) && !is_signed_int(dst));
    if (!strcmp(dst, "float"))
        return !strcmp(src, "f32") || is_int(src);
    if (!strcmp(dst, "f32") && is_int(src))
        return 1;
    return 0;
}

/* Value of an integer literal expression (handles unary minus). */
int int_literal_value(Expr *e, long long *out) {
    if (e->kind == EX_INT) {
        *out = e->as.int_lit.value;
        return 1;
    }
    if (e->kind == EX_UNARY && !strcmp(e->as.unary.op, "-") &&
        e->as.unary.operand->kind == EX_INT) {
        *out = -e->as.unary.operand->as.int_lit.value;
        return 1;
    }
    return 0;
}

int fits_in(const char *t, long long v) {
    if (!strcmp(t, "i8"))  return v >= -128 && v <= 127;
    if (!strcmp(t, "u8"))  return v >= 0 && v <= 255;
    if (!strcmp(t, "i16")) return v >= -32768 && v <= 32767;
    if (!strcmp(t, "u16")) return v >= 0 && v <= 65535;
    if (!strcmp(t, "i32")) return v >= -2147483648LL && v <= 2147483647LL;
    if (!strcmp(t, "u32")) return v >= 0 && v <= 4294967295LL;
    if (!strcmp(t, "u64")) return v >= 0;
    return 1; /* i64 / int: full long long range */
}

/* Assignability including literal-fitting: an integer literal may
 * initialize/pass to any int width it fits in, and a float literal may
 * initialize an f32. */
int value_assignable(const char *dst, Expr *src, const char *srct) {
    if (can_assign(dst, srct))
        return 1;
    long long v;
    if (is_int(dst) && is_int(srct) && int_literal_value(src, &v) &&
        fits_in(dst, v))
        return 1;
    if (!strcmp(dst, "f32") && src->kind == EX_FLOAT)
        return 1;
    return 0;
}

/* Arithmetic result type: doubles dominate, then f32 (mixed with ints
 * promotes to double), then the widest int; ties between signed and
 * unsigned of the same width resolve to unsigned (C semantics). */
const char *promote(const char *lt, const char *rt) {
    if (!strcmp(lt, "float") || !strcmp(rt, "float"))
        return "float";
    if (!strcmp(lt, "f32") && !strcmp(rt, "f32"))
        return "f32";
    if (is_flt(lt) || is_flt(rt))
        return "float";
    int rl = int_rank(lt), rr = int_rank(rt);
    if (rl > rr)
        return lt;
    if (rr > rl)
        return rt;
    if (is_signed_int(lt) == is_signed_int(rt))
        return lt;
    return is_signed_int(lt) ? rt : lt;
}

/* Insert a C cast when the slang types differ (compatibility is
 * guaranteed by value_assignable/can_assign upstream). */
char *maybe_cast(CG *cg, const char *dst, const char *src,
                        char *expr) {
    if (!strcmp(dst, src))
        return expr;
    return xasprintf("(%s)(%s)", ctype_of(cg, dst), expr);
}

const char *opt_cname(CG *cg, const char *inner) {
    for (int i = 0; i < cg->opts.count; i++) {
        if (!strcmp(cg->opts.items[i].inner, inner))
            return cg->opts.items[i].cname;
    }
    if (cg->opts.count == cg->opts.cap) {
        cg->opts.cap = cg->opts.cap ? cg->opts.cap * 2 : 8;
        cg->opts.items = (OptInst *)xrealloc(
            cg->opts.items, cg->opts.cap * sizeof(OptInst));
    }
    OptInst *o = &cg->opts.items[cg->opts.count++];
    o->inner = xstrdup(inner);
    o->cname = xasprintf("sl_opt_%s", sanitize_pkg(inner));
    return o->cname;
}

/* C typedef name for a distinct result[T,E] instantiation. */
const char *res_cname(CG *cg, const char *tv, const char *te) {
    for (int i = 0; i < cg->res.count; i++) {
        if (!strcmp(cg->res.items[i].tv, tv) &&
            !strcmp(cg->res.items[i].te, te))
            return cg->res.items[i].cname;
    }
    if (cg->res.count == cg->res.cap) {
        cg->res.cap = cg->res.cap ? cg->res.cap * 2 : 8;
        cg->res.items = (ResInst *)xrealloc(
            cg->res.items, cg->res.cap * sizeof(ResInst));
    }
    ResInst *r = &cg->res.items[cg->res.count++];
    r->tv = xstrdup(tv);
    r->te = xstrdup(te);
    r->cname =
        xasprintf("sl_res_%s_%s", sanitize_pkg(tv), sanitize_pkg(te));
    return r->cname;
}

/* Args-struct + trampoline names for a spawned target, shared by
 * every 'spawn' call site targeting the same function. */
SpawnShape *spawn_shape_for(CG *cg, FuncSig *sig) {
    for (int i = 0; i < cg->spawns.count; i++) {
        if (!strcmp(cg->spawns.items[i].pkg, sig->pkg) &&
            !strcmp(cg->spawns.items[i].name, sig->name))
            return &cg->spawns.items[i];
    }
    if (cg->spawns.count == cg->spawns.cap) {
        cg->spawns.cap = cg->spawns.cap ? cg->spawns.cap * 2 : 8;
        cg->spawns.items = (SpawnShape *)xrealloc(
            cg->spawns.items, cg->spawns.cap * sizeof(SpawnShape));
    }
    SpawnShape *s = &cg->spawns.items[cg->spawns.count++];
    s->pkg = sig->pkg;
    s->name = sig->name;
    char *base = xasprintf("%s_%s", sanitize_pkg(sig->pkg),
                           sanitize_ident(sig->name));
    s->sname = xasprintf("sl_spawn_args_%s", base);
    s->tname = xasprintf("sl_spawn_tramp_%s", base);
    s->has_tracer = 0;
    for (int j = 0; j < sig->nparams; j++)
        if (type_is_gc_ptr(cg, sig->param_slang[j])) { s->has_tracer = 1; break; }
    return s;
}

void var_push(CG *cg, const char *name, const char *slang) {
    if (cg->vars.count == cg->vars.cap) {
        cg->vars.cap = cg->vars.cap ? cg->vars.cap * 2 : 16;
        cg->vars.items =
            (VarSym *)xrealloc(cg->vars.items, cg->vars.cap * sizeof(VarSym));
    }
    cg->vars.items[cg->vars.count].name = (char *)name;
    cg->vars.items[cg->vars.count].slang = slang;
    cg->vars.items[cg->vars.count].ctype = ctype_of(cg, slang);
    cg->vars.count++;
}

VarSym *var_find(CG *cg, const char *name) {
    for (int i = cg->vars.count - 1; i >= 0; i--) {
        if (!strcmp(cg->vars.items[i].name, name))
            return &cg->vars.items[i];
    }
    return NULL;
}

void expr_tmp_register(CG *cg, Expr *e, const char *name) {
    if (cg->expr_tmps.count == cg->expr_tmps.cap) {
        cg->expr_tmps.cap = cg->expr_tmps.cap ? cg->expr_tmps.cap * 2 : 16;
        cg->expr_tmps.items = (ExprTmp *)xrealloc(
            cg->expr_tmps.items, cg->expr_tmps.cap * sizeof(ExprTmp));
    }
    cg->expr_tmps.items[cg->expr_tmps.count].key = e;
    cg->expr_tmps.items[cg->expr_tmps.count].name = (char *)name;
    cg->expr_tmps.count++;
}

const char *expr_tmp_find(CG *cg, Expr *e) {
    for (int i = cg->expr_tmps.count - 1; i >= 0; i--) {
        if (cg->expr_tmps.items[i].key == e)
            return cg->expr_tmps.items[i].name;
    }
    return NULL;
}

/* Evaluates one already-generated C expression (`text`, of C type
 * `ctype`) into its own named temporary via a real, ordered C
 * statement appended to *prelude -- guaranteeing left-to-right
 * evaluation among a group of `seq_id` siblings, unlike embedding raw
 * expression text directly into one fused C expression, where C
 * leaves the relative order between sub-expressions of a function
 * call, an aggregate initializer, or a binary operator unspecified
 * (Tier 10's liveness pass assumes left-to-right order; this is what
 * makes that assumption actually true of the generated C, not just of
 * the analysis).
 *
 * Called once per sibling, in source (left-to-right) order, as each
 * is generated -- not once in a batch after all siblings already
 * exist. That ordering is load-bearing, not stylistic: Tier 10's
 * liveness pass (process_children_reverse, shared by EX_BINARY/
 * EX_INDEX/EX_SLICE/EX_LIST/EX_MAPLIT/EX_STRUCTLIT/EX_CALL alike --
 * see liveness.c) can mark any earlier sibling as a "pending" value a
 * LATER sibling's own nested call-site safepoint bracket must protect
 * (`[mk_a(), mk_b()]`: mk_b()'s own bracket needs mk_a()'s temp), and
 * a bare-identifier sibling needs the same protection via
 * ambient_root_push even though liveness.c itself doesn't pending-
 * track it (`combine(xs, baz())`: baz() needs xs's temp too -- see
 * gen_call's own comment on this). Both only work if the earlier
 * sibling's temp already exists and is registered by the time the
 * later sibling is generated, which requires the caller to interleave
 * generation with calls to this function, one sibling at a time.
 *
 * `expr_node` is the source Expr this temp materializes (registered
 * via expr_tmp_register and pushed onto cg->ambient_roots so a nested
 * call can find it), or NULL for a synthesized, non-source slot (e.g.
 * gen_slice's implicit end) -- never pending-tracked by liveness.c,
 * so never looked up either way. `slang_type` is this value's own
 * slang type (as sequenced, i.e. after any cast the caller already
 * applied) -- registration/ambient-push only happens when it's
 * type_is_gc_ptr-true, matching exactly what liveness.c itself would
 * ever track or a nested call's root list would ever need: a scalar
 * (int/float/bool/...) sibling gets sequenced for evaluation-order
 * (Risk 1 applies to every type, not just GC pointers) but never
 * registered -- registering it anyway would silently cast a plain
 * integer to (void*) into some later sibling's root array, wrong
 * regardless of whether anything reads it yet (caught by -Wint-to-
 * void-pointer-cast on a struct literal with scalar+GC-pointer
 * fields mixed, e.g. demo/main.sl's RollResult). The caller must
 * snapshot cg->ambient_count before the first sibling and restore it
 * after the last, exactly like cg->expect's own save/restore (see
 * every call site). A no-op (returns `text` unchanged, *prelude*
 * untouched, no registration) when `seq_id < 0` -- the caller's
 * signal that there's only one sibling, with no one to be unsequenced
 * relative to. */
char *sequence_one(CG *cg, int seq_id, int idx, const char *ctype,
                   const char *slang_type, char *text, Expr *expr_node,
                   StrBuf *prelude) {
    if (seq_id < 0)
        return text;
    char *name = xasprintf("_sl_seq%d_%d", seq_id, idx);
    sb_append(prelude, xasprintf("%s %s = %s; ", ctype, name, text));
    if (expr_node && type_is_gc_ptr(cg, slang_type)) {
        expr_tmp_register(cg, expr_node, name);
        ambient_root_push(cg, name);
    }
    return name;
}

void ambient_root_push(CG *cg, const char *name) {
    if (cg->ambient_count == cg->ambient_cap) {
        cg->ambient_cap = cg->ambient_cap ? cg->ambient_cap * 2 : 8;
        cg->ambient_roots = (char **)xrealloc(
            cg->ambient_roots, cg->ambient_cap * sizeof(char *));
    }
    cg->ambient_roots[cg->ambient_count++] = (char *)name;
}

/* Tier 10: wraps `inner` (already-generated C expression text for
 * node `e`, of C type `result_ctype`, or NULL if void) with a
 * safepoint bracket built from e->live_set (named + pending) plus
 * whatever's currently on cg->ambient_roots -- generalizes the
 * bracket gen_call originally built inline for its own user/method
 * calls, so every EX_CALL-shaped codegen path (gen_call itself,
 * gen_ctor, gen_builtin_call, native_gen, json_call_gen, and the
 * `none` literal, which liveness.c treats as a 4th safepoint kind
 * alongside CALL/LIST/MAPLIT/STRUCTLIT) shares one implementation
 * instead of duplicating it. `prelude` is optional priming C
 * statements (e.g. a caller's own argument-sequencing temps) to
 * splice in ahead of the bracket -- pass NULL or "" when there are
 * none. Caller is responsible for having already popped its own
 * ambient contributions (if it pushed any while sequencing its own
 * arguments) before calling this -- cg->ambient_count is read as-is,
 * exactly like gen_call's own tail used to read its local
 * ambient_mark once already restored to that value. sl_rt_safepoint_top
 * is what the mark-sweep collector (runtime_gc.c) walks for roots, so
 * every root this bracket protects is real, load-bearing GC state, not
 * inert bookkeeping. Returns `inner` unchanged (or, with a prelude but
 * nothing to protect, just the prelude spliced ahead of it) if there's
 * nothing to protect. */
char *wrap_safepoint(CG *cg, Expr *e, const char *result_ctype,
                     const char *prelude, char *inner) {
    int has_prelude = prelude && prelude[0] != '\0';
    int nlive_named = live_set_nnamed(e->live_set);
    int nlive_pending = live_set_npending(e->live_set);
    int nambient = cg->ambient_count;
    int nroots = nlive_named + nlive_pending + nambient;
    if (nroots == 0) {
        if (!has_prelude)
            return inner;
        return xasprintf("({ %s%s; })", prelude, inner);
    }

    int sp_id = cg->tmp_id++;
    StrBuf sp;
    sb_init(&sp);
    sb_append(&sp, xasprintf("void *_sl_sp%d_roots[] = { ", sp_id));
    int wrote = 0;
    for (int i = 0; i < nlive_named; i++) {
        if (wrote++)
            sb_append(&sp, ", ");
        sb_append(&sp, xasprintf("(void *)%s",
                                 sanitize_ident(live_set_named(e->live_set, i))));
    }
    for (int i = 0; i < nlive_pending; i++) {
        Expr *p = live_set_pending(e->live_set, i);
        const char *tn = expr_tmp_find(cg, p);
        if (!tn)
            cg_error(e->line,
                     "internal error: liveness-pending value has no "
                     "registered temp at line %d",
                     p->line);
        if (wrote++)
            sb_append(&sp, ", ");
        sb_append(&sp, xasprintf("(void *)%s", tn));
    }
    for (int i = 0; i < nambient; i++) {
        if (wrote++)
            sb_append(&sp, ", ");
        sb_append(&sp, xasprintf("(void *)%s", cg->ambient_roots[i]));
    }
    sb_append(&sp, "}; ");
    sb_append(&sp, xasprintf("sl_safepoint _sl_sp%d; "
                             "sl_rt_safepoint_enter(&_sl_sp%d, _sl_sp%d_roots, %d); ",
                             sp_id, sp_id, sp_id, nroots));

    StrBuf block;
    sb_init(&block);
    sb_append(&block, "({ ");
    if (has_prelude)
        sb_append(&block, prelude);
    sb_append(&block, sp.data);
    if (result_ctype) {
        sb_append(&block,
                  xasprintf("%s _sl_spres%d = %s; sl_rt_safepoint_exit(); "
                            "_sl_spres%d; })",
                            result_ctype, sp_id, inner, sp_id));
    } else {
        sb_append(&block,
                  xasprintf("%s; sl_rt_safepoint_exit(); })", inner));
    }
    return block.data;
}

FuncSig *sig_find_in(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->sigs.count; i++) {
        if (!strcmp(cg->sigs.items[i].pkg, pkg) &&
            !strcmp(cg->sigs.items[i].name, name))
            return &cg->sigs.items[i];
    }
    return NULL;
}

void glob_push(CG *cg, const char *name, const char *pkg,
                      const char *slang, int is_pub) {
    if (cg->globs.count == cg->globs.cap) {
        cg->globs.cap = cg->globs.cap ? cg->globs.cap * 2 : 16;
        cg->globs.items = (GlobSym *)xrealloc(
            cg->globs.items, cg->globs.cap * sizeof(GlobSym));
    }
    cg->globs.items[cg->globs.count].name = (char *)name;
    cg->globs.items[cg->globs.count].pkg = (char *)pkg;
    cg->globs.items[cg->globs.count].slang = slang;
    cg->globs.items[cg->globs.count].is_pub = is_pub;
    cg->globs.count++;
}

GlobSym *glob_find(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->globs.count; i++) {
        if (!strcmp(cg->globs.items[i].pkg, pkg) &&
            !strcmp(cg->globs.items[i].name, name))
            return &cg->globs.items[i];
    }
    return NULL;
}

void import_push(CG *cg, const char *owner, const char *alias,
                        const char *target) {
    if (cg->imports.count == cg->imports.cap) {
        cg->imports.cap = cg->imports.cap ? cg->imports.cap * 2 : 16;
        cg->imports.items = (ImportBind *)xrealloc(
            cg->imports.items, cg->imports.cap * sizeof(ImportBind));
    }
    cg->imports.items[cg->imports.count].owner = (char *)owner;
    cg->imports.items[cg->imports.count].alias = (char *)alias;
    cg->imports.items[cg->imports.count].target = (char *)target;
    cg->imports.count++;
}

const char *import_try(CG *cg, const char *alias) {
    for (int i = 0; i < cg->imports.count; i++) {
        ImportBind *b = &cg->imports.items[i];
        if (!strcmp(b->owner, cg->cur_pkg) && !strcmp(b->alias, alias))
            return b->target;
    }
    return NULL;
}

const char *import_target(CG *cg, const char *alias, int line) {
    const char *t = import_try(cg, alias);
    if (!t)
        cg_error(line, "'%s' is not an imported package", alias);
    return t;
}

/* Names of compiler-provided packages (see loader.c NATIVE_PKGS). */
int is_native_pkg(CG *cg, const char *name) {
    for (int i = 0; i < cg->nnat; i++) {
        if (!strcmp(cg->nat_pkgs[i], name))
            return 1;
    }
    return 0;
}

/* Whether the native package `name` is actually imported somewhere in
 * this program -- the "should its runtime/forced types/etc. be
 * emitted at all" check every native package's conditional-inclusion
 * logic shares (see e.g. emit_native_runtime, force_native_result_types). */
int want_pkg(CG *cg, const char *name) {
    for (int i = 0; i < cg->imports.count; i++) {
        if (!strcmp(cg->imports.items[i].target, name) &&
            is_native_pkg(cg, name))
            return 1;
    }
    return 0;
}

/* Activate cg->expect while inferring/generating an expression whose
 * type is known from context (annotated lets, returns, assignments,
 * call arguments). Returns the previous expectation so the caller can
 * restore it. */
const char *expect_push(CG *cg, const char *t) {
    const char *saved = cg->expect;
    if (t && (is_opt(t) || is_result(t) || is_chan(t)))
        cg->expect = t;
    return saved;
}

int split_dotted(const char *name, char **left, char **right) {
    const char *dot = strchr(name, '.');
    if (!dot)
        return 0;
    size_t l = (size_t)(dot - name);
    char *a = (char *)xmalloc(l + 1);
    memcpy(a, name, l);
    a[l] = '\0';
    *left = a;
    *right = xstrdup(dot + 1);
    return 1;
}

char *sanitize_pkg(const char *name) {
    char *s = xstrdup(name);
    for (char *p = s; *p; p++) {
        if (!(isalnum((unsigned char)*p) || *p == '_'))
            *p = '_';
    }
    if (isdigit((unsigned char)s[0])) {
        char *t = xasprintf("p_%s", s);
        return t;
    }
    return s;
}

char *mangle_func(const char *pkg, const char *name) {
    return xasprintf("sl_%s_%s", sanitize_pkg(pkg), sanitize_ident(name));
}

char *mangle_glob(const char *pkg, const char *name) {
    return xasprintf("sl_g_%s_%s", sanitize_pkg(pkg), sanitize_ident(name));
}

char *path_base(const char *path) {
    const char *slash = strrchr(path, '/');
    return xstrdup(slash ? slash + 1 : path);
}

StructDef *struct_find_canon(CG *cg, const char *canon) {
    for (int i = 0; i < cg->structs.count; i++) {
        if (!strcmp(cg->structs.items[i].canonical, canon))
            return &cg->structs.items[i];
    }
    return NULL;
}

StructDef *struct_find_in_pkg(CG *cg, const char *pkg,
                                     const char *name) {
    for (int i = 0; i < cg->structs.count; i++) {
        if (!strcmp(cg->structs.items[i].pkg, pkg) &&
            !strcmp(cg->structs.items[i].name, name))
            return &cg->structs.items[i];
    }
    return NULL;
}

char *mangle_struct(const char *canon) {
    char *l, *r;
    split_dotted(canon, &l, &r);
    return xasprintf("sl_st_%s_%s", sanitize_pkg(l), sanitize_ident(r));
}

/* C type for a slang type, including maps, user-defined structs, and
 * monomorphized opt/result instantiations. */
const char *ctype_of(CG *cg, const char *t) {
    const char *m = map_type(t);
    if (m)
        return m;
    if (is_map(t))
        return "sl_map *";
    if (is_chan(t))
        return "sl_chan *";
    if (is_opt(t))
        return xasprintf("%s *", opt_cname(cg, opt_inner(t)));
    if (is_result(t)) {
        char *tv, *tev;
        result_te(t, &tv, &tev);
        return xasprintf("%s *", res_cname(cg, tv, tev));
    }
    if (struct_find_canon(cg, t))
        return xasprintf("%s *", mangle_struct(t));
    return NULL;
}

/* Resolve a type name as written to its canonical form: builtin types
 * pass through; struct names gain their package qualifier ("Point" ->
 * "main.Point"); containers canonicalize recursively. */
const char *canon_type(CG *cg, const char *t, int line) {
    /* containers first: their inner types must be canonicalized
     * recursively (map_type() would otherwise match the whole
     * container and skip that step) */
    if (t[0] == '[') {
        size_t n = strlen(t);
        char *inner = (char *)xmalloc(n - 1);
        memcpy(inner, t + 1, n - 2);
        inner[n - 2] = '\0';
        const char *ci = canon_type(cg, inner, line);
        return xasprintf("[%s]", ci);
    }
    if (is_map(t)) {
        char *k, *v;
        map_kv(t, &k, &v);
        if (!is_map_key(k))
            cg_error(line,
                     "map keys must be an integer type, str, or bool "
                     "(got '%s')",
                     k);
        const char *cv = canon_type(cg, v, line);
        return xasprintf("map[%s]%s", k, cv);
    }
    if (is_opt(t)) {
        char *inner = opt_inner(t);
        const char *ci = canon_type(cg, inner, line);
        opt_cname(cg, ci); /* register the instantiation */
        return xasprintf("opt[%s]", ci);
    }
    if (is_result(t)) {
        char *a, *b;
        result_te(t, &a, &b);
        const char *ca = canon_type(cg, a, line);
        const char *cb = canon_type(cg, b, line);
        res_cname(cg, ca, cb); /* register the instantiation */
        return xasprintf("result[%s,%s]", ca, cb);
    }
    if (is_chan(t)) {
        /* the channel's own C representation (sl_chan *) does not
         * depend on T, so unlike opt/result there is no per-element
         * instantiation to register -- only the element type itself
         * needs canonicalizing */
        const char *ci = canon_type(cg, chan_elem(t), line);
        return xasprintf("chan[%s]", ci);
    }
    if (map_type(t))
        return t;
    if (!strchr(t, '.')) {
        StructDef *sd = struct_find_in_pkg(cg, cg->cur_pkg, t);
        if (!sd)
            cg_error(line, "unknown type '%s'", t);
        return sd->canonical;
    }
    char *l, *r;
    split_dotted(t, &l, &r);
    const char *pkg = import_target(cg, l, line);
    StructDef *sd = struct_find_in_pkg(cg, pkg, r);
    if (!sd)
        cg_error(line, "package '%s' has no type '%s'", pkg, r);
    if (!sd->is_pub)
        cg_error(line,
                 "type '%s' is not exported from package '%s' (add 'pub' "
                 "to export it)",
                 r, pkg);
    return sd->canonical;
}

/* ------------------------------------------------------------------ */
/* Output helpers                                                      */
/* ------------------------------------------------------------------ */

void emit_line(CG *cg, const char *fmt, ...) {
    char buf[16384];
    va_list ap;
    for (int i = 0; i < cg->indent; i++)
        sb_append(cg->out, "    ");
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    sb_append(cg->out, buf);
    sb_nl(cg->out);
}

/* ------------------------------------------------------------------ */
/* Type inference                                                      */
/* ------------------------------------------------------------------ */

int is_builtin_name(const char *name) {
    return !strcmp(name, "print") || !strcmp(name, "println") ||
           !strcmp(name, "len") || !strcmp(name, "push") ||
           !strcmp(name, "pop") || !strcmp(name, "to_str") ||
           !strcmp(name, "to_bytes") || !strcmp(name, "to_le") ||
           !strcmp(name, "to_be") || !strcmp(name, "from_le") ||
           !strcmp(name, "from_be") || !strcmp(name, "has") ||
           !strcmp(name, "del") || !strcmp(name, "exit") ||
           !strcmp(name, "some") || !strcmp(name, "none") ||
           !strcmp(name, "ok") || !strcmp(name, "err") ||
           !strcmp(name, "nullptr") || !strcmp(name, "bytes_ptr") ||
           !strcmp(name, "make_chan") || !strcmp(name, "chan_send") ||
           !strcmp(name, "chan_recv") || !strcmp(name, "chan_close");
}

/* Find a method `name` declared (via impl) for struct `sd`. */
FuncSig *method_find(CG *cg, StructDef *sd, const char *name) {
    for (int i = 0; i < cg->sigs.count; i++) {
        FuncSig *s = &cg->sigs.items[i];
        if (!strcmp(s->pkg, sd->pkg) && !strcmp(s->name, name) &&
            s->method_of && !strcmp(s->method_of, sd->canonical))
            return s;
    }
    return NULL;
}

/* Resolve a possibly-dotted identifier to its slang type: locals,
 * package globals, imported package members, or struct field chains
 * ("rect.center.x"). */
