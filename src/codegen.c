#include "common.h"
#include "ast.h"
#include "codegen.h"

#include <ctype.h>
#include <stdarg.h>

/* ------------------------------------------------------------------ */
/* Diagnostics                                                         */
/* ------------------------------------------------------------------ */

static void cg_error(int line, const char *fmt, ...) {
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

static char *sanitize_pkg(const char *name);

static void sb_putc(StrBuf *sb, char c) { sb_append_n(sb, &c, 1); }

static void sb_nl(StrBuf *sb) { sb_putc(sb, 10); }

/* Render a slang string as a C string literal (with quotes). */
static char *c_string_literal(const char *s) {
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
static char *c_bytes_literal(const unsigned char *p, long long len) {
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
static char *sanitize_ident(const char *name) {
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

static const char *map_type(const char *t) {
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

static int is_int(const char *t) {
    return !strcmp(t, "int") || !strcmp(t, "i8") || !strcmp(t, "i16") ||
           !strcmp(t, "i32") || !strcmp(t, "i64") || !strcmp(t, "u8") ||
           !strcmp(t, "u16") || !strcmp(t, "u32") || !strcmp(t, "u64") ||
           !strcmp(t, "duration");
}

static int is_signed_int(const char *t) {
    return !strcmp(t, "int") || !strcmp(t, "i8") || !strcmp(t, "i16") ||
           !strcmp(t, "i32") || !strcmp(t, "i64") ||
           !strcmp(t, "duration");
}

static int int_rank(const char *t) {
    if (!strcmp(t, "i8") || !strcmp(t, "u8")) return 0;
    if (!strcmp(t, "i16") || !strcmp(t, "u16")) return 1;
    if (!strcmp(t, "i32") || !strcmp(t, "u32")) return 2;
    return 3; /* i64, u64, int */
}

static int is_flt(const char *t) {
    return !strcmp(t, "float") || !strcmp(t, "f32");
}

static int is_num(const char *t) { return is_int(t) || is_flt(t); }
static int is_str(const char *t) { return !strcmp(t, "str"); }
static int is_bytes(const char *t) { return !strcmp(t, "bytes"); }
static int is_rawptr(const char *t) { return !strcmp(t, "rawptr"); }
static int is_arr(const char *t) { return t[0] == '['; }
static int is_map(const char *t) { return !strncmp(t, "map[", 4); }

/* extern fn boundary: only types with an unambiguous, stable C
 * representation may cross into/out of foreign code. GC'd containers
 * (opt/result/map/struct/array) are deliberately excluded -- handing
 * their internal layout to arbitrary C would be unsafe and pointless. */
static void check_extern_type(const char *t, int line, const char *what) {
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
static void map_kv(const char *t, char **k, char **v) {
    const char *close = strchr(t + 4, ']');
    size_t kl = (size_t)(close - (t + 4));
    char *kt = (char *)xmalloc(kl + 1);
    memcpy(kt, t + 4, kl);
    kt[kl] = '\0';
    *k = kt;
    *v = xstrdup(close + 1);
}

/* Valid map key types: integers, str, bool. */
static int is_map_key(const char *t) {
    return is_int(t) || is_str(t) || !strcmp(t, "bool");
}

static int is_opt(const char *t) { return !strncmp(t, "opt[", 4); }
static int is_result(const char *t) { return !strncmp(t, "result[", 7); }
static int is_chan(const char *t) { return !strncmp(t, "chan[", 5); }

/* "opt[T]" -> T (heap-allocated). Caller must pass an opt type. */
static char *opt_inner(const char *t) {
    size_t n = strlen(t);
    char *inner = (char *)xmalloc(n - 4);
    memcpy(inner, t + 4, n - 5);
    inner[n - 5] = '\0';
    return inner;
}

/* "chan[T]" -> T (heap-allocated). Caller must pass a chan type. */
static char *chan_elem(const char *t) {
    size_t n = strlen(t);
    char *inner = (char *)xmalloc(n - 5);
    memcpy(inner, t + 5, n - 6);
    inner[n - 6] = '\0';
    return inner;
}

/* "result[T,E]" -> T and E (heap-allocated). */
static void result_te(const char *t, char **tv, char **ev) {
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
static char *arr_elem(const char *t) {
    size_t n = strlen(t);
    char *inner = (char *)xmalloc(n - 1);
    memcpy(inner, t + 1, n - 2);
    inner[n - 2] = '\0';
    return inner;
}

/* Can a value of slang type `src` be assigned where `dst` is expected?
 * Widening within the int family and toward floats is implicit;
 * narrowing and sign changes require an explicit cast (`as`). */
static int can_assign(const char *dst, const char *src) {
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
static int int_literal_value(Expr *e, long long *out) {
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

static int fits_in(const char *t, long long v) {
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
static int value_assignable(const char *dst, Expr *src, const char *srct) {
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
static const char *promote(const char *lt, const char *rt) {
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

/* Forward declarations used before their definitions below. */
typedef struct CG CG;
static const char *ctype_of(CG *cg, const char *t);

/* Insert a C cast when the slang types differ (compatibility is
 * guaranteed by value_assignable/can_assign upstream). */
static char *maybe_cast(CG *cg, const char *dst, const char *src,
                        char *expr) {
    if (!strcmp(dst, src))
        return expr;
    return xasprintf("(%s)(%s)", ctype_of(cg, dst), expr);
}

/* ------------------------------------------------------------------ */
/* User-defined structs                                                */
/* ------------------------------------------------------------------ */

typedef struct {
    char *canonical;     /* "pkg.Name" — the slang-level type identity */
    char *pkg;
    char *name;          /* simple name within its package */
    int is_pub;
    char **fields;
    const char **ftypes; /* canonical slang field types */
    int nfields;
    int line;
} StructDef;

typedef struct {
    StructDef *items;
    int count;
    int cap;
} StructTable;

/* ------------------------------------------------------------------ */
/* Symbol tables                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    char *name;
    const char *slang;
    const char *ctype;
} VarSym;

typedef struct {
    VarSym *items;
    int count;
    int cap;
} VarTable;

typedef struct {
    char *name;
    char *pkg;               /* owning package name */
    const char *ret_slang;   /* NULL => void */
    const char **param_slang;
    int nparams;
    int is_pub;
    int is_extern;            /* 'extern fn': calls the bare C symbol */
    const char *method_of;   /* canonical struct name for methods, else NULL */
    int line;
} FuncSig;

typedef struct {
    FuncSig *items;
    int count;
    int cap;
} SigTable;

/* One 'import "path"' binding: within the owning package, `alias`
 * refers to the package named `target`. */
typedef struct {
    char *owner;
    char *alias;
    char *target;
} ImportBind;

typedef struct {
    ImportBind *items;
    int count;
    int cap;
} ImportTable;

typedef struct {
    char *name;
    char *pkg;
    const char *slang;
    int is_pub;
} GlobSym;

typedef struct {
    GlobSym *items;
    int count;
    int cap;
} GlobTable;

/* Monomorphized instantiations of the generic option/result types:
 * one C struct per distinct set of type parameters used. */
typedef struct {
    char *inner; /* canonical slang type T of opt[T] */
    char *cname; /* C typedef name, e.g. sl_opt_str */
} OptInst;

typedef struct {
    OptInst *items;
    int count;
    int cap;
} OptTable;

typedef struct {
    char *tv;    /* canonical slang value type T of result[T,E] */
    char *te;    /* canonical slang error type E */
    char *cname; /* C typedef name, e.g. sl_res_int_str */
} ResInst;

typedef struct {
    ResInst *items;
    int count;
    int cap;
} ResTable;

/* One args-struct + pthread trampoline per distinct spawned target
 * function (shared across every 'spawn' call site targeting it). */
typedef struct {
    char *pkg;    /* target function's owning package */
    char *name;   /* target function's simple name */
    char *sname;  /* C struct type name, e.g. sl_spawn_args_main_handle */
    char *tname;  /* C trampoline function name */
} SpawnShape;

typedef struct {
    SpawnShape *items;
    int count;
    int cap;
} SpawnTable;

struct CG {
    StrBuf *out;
    int indent;
    VarTable vars;
    SigTable sigs;
    GlobTable globs;
    ImportTable imports;
    StructTable structs;
    OptTable opts;
    ResTable res;
    SpawnTable spawns;
    const char *expect; /* expected type while inferring none/ok/err */
    const char *cur_ret;  /* slang return type of enclosing function */
    const char *cur_pkg;
    int in_function;
    int tmp_id;
    char **nat_pkgs; /* names of natively-implemented imported packages */
    int nnat;
};

/* C typedef name for a distinct opt[T] instantiation. */
static const char *opt_cname(CG *cg, const char *inner) {
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
static const char *res_cname(CG *cg, const char *tv, const char *te) {
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
static SpawnShape *spawn_shape_for(CG *cg, FuncSig *sig) {
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
    return s;
}

static void var_push(CG *cg, const char *name, const char *slang) {
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

static VarSym *var_find(CG *cg, const char *name) {
    for (int i = cg->vars.count - 1; i >= 0; i--) {
        if (!strcmp(cg->vars.items[i].name, name))
            return &cg->vars.items[i];
    }
    return NULL;
}

static FuncSig *sig_find_in(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->sigs.count; i++) {
        if (!strcmp(cg->sigs.items[i].pkg, pkg) &&
            !strcmp(cg->sigs.items[i].name, name))
            return &cg->sigs.items[i];
    }
    return NULL;
}

static void glob_push(CG *cg, const char *name, const char *pkg,
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

static GlobSym *glob_find(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->globs.count; i++) {
        if (!strcmp(cg->globs.items[i].pkg, pkg) &&
            !strcmp(cg->globs.items[i].name, name))
            return &cg->globs.items[i];
    }
    return NULL;
}

static void import_push(CG *cg, const char *owner, const char *alias,
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

static const char *import_try(CG *cg, const char *alias) {
    for (int i = 0; i < cg->imports.count; i++) {
        ImportBind *b = &cg->imports.items[i];
        if (!strcmp(b->owner, cg->cur_pkg) && !strcmp(b->alias, alias))
            return b->target;
    }
    return NULL;
}

static const char *import_target(CG *cg, const char *alias, int line) {
    const char *t = import_try(cg, alias);
    if (!t)
        cg_error(line, "'%s' is not an imported package", alias);
    return t;
}

/* Names of compiler-provided packages (see loader.c NATIVE_PKGS). */
static int is_native_pkg(CG *cg, const char *name) {
    for (int i = 0; i < cg->nnat; i++) {
        if (!strcmp(cg->nat_pkgs[i], name))
            return 1;
    }
    return 0;
}

/* Activate cg->expect while inferring/generating an expression whose
 * type is known from context (annotated lets, returns, assignments,
 * call arguments). Returns the previous expectation so the caller can
 * restore it. */
static const char *expect_push(CG *cg, const char *t) {
    const char *saved = cg->expect;
    if (t && (is_opt(t) || is_result(t) || is_chan(t)))
        cg->expect = t;
    return saved;
}

static int split_dotted(const char *name, char **left, char **right) {
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

static char *sanitize_pkg(const char *name) {
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

static char *mangle_func(const char *pkg, const char *name) {
    return xasprintf("sl_%s_%s", sanitize_pkg(pkg), sanitize_ident(name));
}

static char *mangle_glob(const char *pkg, const char *name) {
    return xasprintf("sl_g_%s_%s", sanitize_pkg(pkg), sanitize_ident(name));
}

static char *path_base(const char *path) {
    const char *slash = strrchr(path, '/');
    return xstrdup(slash ? slash + 1 : path);
}

static StructDef *struct_find_canon(CG *cg, const char *canon) {
    for (int i = 0; i < cg->structs.count; i++) {
        if (!strcmp(cg->structs.items[i].canonical, canon))
            return &cg->structs.items[i];
    }
    return NULL;
}

static StructDef *struct_find_in_pkg(CG *cg, const char *pkg,
                                     const char *name) {
    for (int i = 0; i < cg->structs.count; i++) {
        if (!strcmp(cg->structs.items[i].pkg, pkg) &&
            !strcmp(cg->structs.items[i].name, name))
            return &cg->structs.items[i];
    }
    return NULL;
}

static char *mangle_struct(const char *canon) {
    char *l, *r;
    split_dotted(canon, &l, &r);
    return xasprintf("sl_st_%s_%s", sanitize_pkg(l), sanitize_ident(r));
}

/* C type for a slang type, including maps, user-defined structs, and
 * monomorphized opt/result instantiations. */
static const char *ctype_of(CG *cg, const char *t) {
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
static const char *canon_type(CG *cg, const char *t, int line) {
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

static void emit_line(CG *cg, const char *fmt, ...) {
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

static const char *infer_type(CG *cg, Expr *e);

static int is_builtin_name(const char *name) {
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
static FuncSig *method_find(CG *cg, StructDef *sd, const char *name) {
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
static const char *infer_ident_name(CG *cg, const char *name, int line) {
    if (!strcmp(name, "none")) {
        if (!cg->expect || !is_opt(cg->expect))
            cg_error(line,
                     "cannot infer the type of 'none'; annotate the "
                     "binding, e.g. let x: opt[int] = none");
        return cg->expect;
    }
    if (!strcmp(name, "nullptr"))
        return "rawptr";
    VarSym *v = var_find(cg, name);
    if (v)
        return v->slang;
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_try(cg, left);
        if (pkg) {
            GlobSym *g = glob_find(cg, pkg, right);
            if (!g)
                cg_error(line, "package '%s' has no variable '%s'", pkg,
                         right);
            if (!g->is_pub)
                cg_error(line,
                         "variable '%s' is not exported from package '%s' "
                         "(add 'pub' to export it)",
                         right, pkg);
            return g->slang;
        }
        const char *bt = infer_ident_name(cg, left, line);
        StructDef *sd = struct_find_canon(cg, bt);
        if (!sd)
            cg_error(line, "'%s' has no member '%s' (type %s)", left,
                     right, bt);
        for (int i = 0; i < sd->nfields; i++) {
            if (!strcmp(sd->fields[i], right))
                return sd->ftypes[i];
        }
        cg_error(line, "struct '%s' has no field '%s'", sd->canonical,
                 right);
    }
    GlobSym *g = glob_find(cg, cg->cur_pkg, name);
    if (g)
        return g->slang;
    cg_error(line, "undefined variable '%s'", name);
    return NULL; /* unreachable */
}

/* Shared inference for the option/result constructor expressions
 * some(v), none, ok(v), err(e). Returns the constructed slang type.
 * The surrounding context (annotated let, return type, ...) is
 * expected to have activated cg->expect where relevant. */
static const char *ctor_infer(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    int n = e->as.call.nargs;

    if (!strcmp(name, "none")) {
        if (n != 0)
            cg_error(e->line, "'none' takes no arguments");
        if (!cg->expect || !is_opt(cg->expect))
            cg_error(e->line,
                     "cannot infer the type of 'none'; annotate the "
                     "binding, e.g. let x: opt[int] = none");
        return cg->expect;
    }
    if (!strcmp(name, "some")) {
        if (n != 1)
            cg_error(e->line, "some() takes exactly one argument");
        if (cg->expect && is_opt(cg->expect)) {
            char *inner = opt_inner(cg->expect);
            const char *saved = expect_push(cg, inner);
            const char *at = infer_type(cg, e->as.call.args[0]);
            cg->expect = saved;
            if (!value_assignable(inner, e->as.call.args[0], at))
                cg_error(e->line,
                         "cannot use %s where %s expected", at, inner);
            return cg->expect;
        }
        const char *at = infer_type(cg, e->as.call.args[0]);
        return xasprintf("opt[%s]", at);
    }
    if (!strcmp(name, "ok")) {
        if (n != 1)
            cg_error(e->line, "ok() takes exactly one argument");
        if (cg->expect && is_result(cg->expect)) {
            char *tv, *tev;
            result_te(cg->expect, &tv, &tev);
            const char *saved = expect_push(cg, tv);
            const char *at = infer_type(cg, e->as.call.args[0]);
            cg->expect = saved;
            if (!value_assignable(tv, e->as.call.args[0], at))
                cg_error(e->line,
                         "cannot use %s where %s expected", at, tv);
            return cg->expect;
        }
        /* without context the error type defaults to str */
        const char *at = infer_type(cg, e->as.call.args[0]);
        return xasprintf("result[%s,str]", at);
    }
    /* err(e) */
    if (n != 1)
        cg_error(e->line, "err() takes exactly one argument");
    if (cg->expect && is_result(cg->expect)) {
        char *tv, *tev;
        result_te(cg->expect, &tv, &tev);
        const char *saved = expect_push(cg, tev);
        const char *at = infer_type(cg, e->as.call.args[0]);
        cg->expect = saved;
        if (!value_assignable(tev, e->as.call.args[0], at))
            cg_error(e->line,
                     "cannot use %s where %s expected", at, tev);
        return cg->expect;
    }
    cg_error(e->line,
             "cannot infer the type of 'err()'; annotate the binding, "
             "e.g. let r: result[int, str] = err(\"oops\")");
    return NULL; /* unreachable */
}

/* Signatures of the compiler-provided functions in the native 'time'
 * and 'net' packages (see loader.c). ret == NULL means void. */
typedef struct {
    const char *pkg, *name;
    int nargs;
    const char *ret;
} NatSig;

static const NatSig NATIVE_SIGS[] = {
    {"time", "mono", 0, "duration"},
    {"time", "wall", 0, "int"},
    {"time", "sleep", 1, NULL},
    {"net", "listen", 1, "result[i32,str]"},
    {"net", "port", 1, "result[i32,str]"},
    {"net", "accept", 1, "result[i32,str]"},
    {"net", "dial", 2, "result[i32,str]"},
    {"net", "send", 2, "result[i32,str]"},
    {"net", "recv", 2, "result[bytes,str]"},
    {"net", "close", 1, NULL},
    {"net", "nonblock", 1, "result[bool,str]"},
};

/* Validate a call into a native package and return its slang return
 * type. Socket handles and ports are fixed-width ints; payloads are
 * bytes. */
static const char *native_check(CG *cg, const char *pkg, const char *fname,
                                Expr *e) {
    const NatSig *ns = NULL;
    for (int i = 0;
         i < (int)(sizeof(NATIVE_SIGS) / sizeof(NATIVE_SIGS[0])); i++) {
        if (!strcmp(NATIVE_SIGS[i].pkg, pkg) &&
            !strcmp(NATIVE_SIGS[i].name, fname)) {
            ns = &NATIVE_SIGS[i];
            break;
        }
    }
    if (!ns)
        cg_error(e->line, "package '%s' has no function '%s'", pkg, fname);
    int n = e->as.call.nargs;
    if (n != ns->nargs)
        cg_error(e->line,
                 "function '%s.%s' expects %d argument(s), got %d", pkg,
                 fname, ns->nargs, n);

    if (!strcmp(pkg, "time")) {
        if (!strcmp(fname, "sleep")) {
            const char *t = infer_type(cg, e->as.call.args[0]);
            if (!is_int(t))
                cg_error(e->line,
                         "time.sleep expects a duration (got %s)", t);
        }
        return ns->ret;
    }

    /* net: fd/port/max arguments must be narrow integers; host is
     * str; payload is bytes */
    for (int i = 0; i < n; i++) {
        const char *at = infer_type(cg, e->as.call.args[i]);
        int want_fd = (!strcmp(fname, "dial") && i == 1) ||
                      ((!strcmp(fname, "listen") || !strcmp(fname, "recv")) &&
                       i == 1)
                          ? 0
                          : 1;
        (void)want_fd;
        if (!strcmp(fname, "dial") && i == 0) {
            if (!is_str(at))
                cg_error(e->line,
                         "net.dial host must be str (got %s)", at);
            continue;
        }
        if (!strcmp(fname, "send") && i == 1) {
            if (!is_bytes(at))
                cg_error(e->line,
                         "net.send payload must be bytes (got %s)", at);
            continue;
        }
        if (!is_int(at))
            cg_error(e->line,
                     "%s.%s argument %d must be an integer (got %s)", pkg,
                     fname, i + 1, at);
    }
    return ns->ret;
}

static const char *infer_call(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    int n = e->as.call.nargs;

    if (!strcmp(name, "print") || !strcmp(name, "println")) {
        if (n != 1)
            cg_error(e->line, "%s() takes exactly one argument", name);
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (is_arr(t))
            cg_error(e->line,
                     "cannot print a list directly; iterate over its "
                     "elements instead");
        return "void";
    }
    if (!strcmp(name, "len")) {
        if (n != 1)
            cg_error(e->line, "len() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (is_str(t) || is_bytes(t) || is_arr(t) || is_map(t))
            return "int";
        cg_error(e->line,
                 "len() expects a str, bytes, [T], or map (got %s)", t);
    }
    if (!strcmp(name, "push")) {
        if (n != 2)
            cg_error(e->line, "push() takes exactly two arguments");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_arr(t))
            cg_error(e->line, "push() expects a list as its first argument "
                              "(got %s)",
                     t);
        char *elem = arr_elem(t);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        if (!value_assignable(elem, e->as.call.args[1], vt))
            cg_error(e->line, "cannot push %s onto a [%s]", vt, elem);
        return t;
    }
    if (!strcmp(name, "pop")) {
        if (n != 1)
            cg_error(e->line, "pop() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_arr(t))
            cg_error(e->line, "pop() expects a list (got %s)", t);
        return arr_elem(t);
    }
    if (!strcmp(name, "to_str")) {
        if (n != 1)
            cg_error(e->line, "to_str() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (is_arr(t))
            cg_error(e->line, "cannot convert a list to str");
        return "str";
    }
    if (!strcmp(name, "to_bytes")) {
        if (n != 1)
            cg_error(e->line, "to_bytes() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_str(t))
            cg_error(e->line, "to_bytes() expects a str (got %s)", t);
        return "bytes";
    }
    if (!strcmp(name, "bytes_ptr")) {
        if (n != 1)
            cg_error(e->line, "bytes_ptr() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_bytes(t))
            cg_error(e->line, "bytes_ptr() expects bytes (got %s)", t);
        return "rawptr";
    }
    if (!strcmp(name, "make_chan")) {
        if (n != 1)
            cg_error(e->line, "make_chan() takes exactly one argument");
        const char *capt = infer_type(cg, e->as.call.args[0]);
        if (!is_int(capt))
            cg_error(e->line,
                     "make_chan() expects an integer capacity (got %s)",
                     capt);
        if (!cg->expect || !is_chan(cg->expect))
            cg_error(e->line,
                     "cannot infer the element type of make_chan(); "
                     "annotate the binding, e.g. let c: chan[int] = "
                     "make_chan(10)");
        return cg->expect;
    }
    if (!strcmp(name, "chan_send")) {
        if (n != 2)
            cg_error(e->line, "chan_send() takes exactly two arguments");
        const char *ct = infer_type(cg, e->as.call.args[0]);
        if (!is_chan(ct))
            cg_error(e->line,
                     "chan_send() expects a chan as its first argument "
                     "(got %s)",
                     ct);
        char *elem = chan_elem(ct);
        const char *saved = expect_push(cg, elem);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        cg->expect = saved;
        if (!value_assignable(elem, e->as.call.args[1], vt))
            cg_error(e->line, "chan_send(): cannot send %s on a chan[%s]",
                     vt, elem);
        return "void";
    }
    if (!strcmp(name, "chan_recv")) {
        if (n != 1)
            cg_error(e->line, "chan_recv() takes exactly one argument");
        const char *ct = infer_type(cg, e->as.call.args[0]);
        if (!is_chan(ct))
            cg_error(e->line, "chan_recv() expects a chan (got %s)", ct);
        char *elem = chan_elem(ct);
        opt_cname(cg, elem); /* register the instantiation */
        return xasprintf("opt[%s]", elem);
    }
    if (!strcmp(name, "chan_close")) {
        if (n != 1)
            cg_error(e->line, "chan_close() takes exactly one argument");
        const char *ct = infer_type(cg, e->as.call.args[0]);
        if (!is_chan(ct))
            cg_error(e->line, "chan_close() expects a chan (got %s)", ct);
        return "void";
    }
    if (!strcmp(name, "to_le") || !strcmp(name, "to_be")) {
        if (n != 1)
            cg_error(e->line, "%s() takes exactly one argument", name);
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_int(t))
            cg_error(e->line, "%s() expects an integer (got %s)", name, t);
        return "bytes";
    }
    if (!strcmp(name, "from_le") || !strcmp(name, "from_be")) {
        if (n != 1)
            cg_error(e->line, "%s() takes exactly one argument", name);
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_bytes(t))
            cg_error(e->line, "%s() expects bytes (got %s)", name, t);
        return "int";
    }
    if (!strcmp(name, "exit")) {
        if (n != 1)
            cg_error(e->line, "exit() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_int(t))
            cg_error(e->line,
                     "exit() expects an integer status (got %s)", t);
        return "void";
    }
    if (!strcmp(name, "none") || !strcmp(name, "some") ||
        !strcmp(name, "ok") || !strcmp(name, "err"))
        return ctor_infer(cg, e);
    if (!strcmp(name, "has") || !strcmp(name, "del")) {
        if (n != 2)
            cg_error(e->line, "%s() takes exactly two arguments", name);
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_map(t))
            cg_error(e->line,
                     "%s() expects a map as its first argument (got %s)",
                     name, t);
        char *k, *v;
        map_kv(t, &k, &v);
        const char *kt = infer_type(cg, e->as.call.args[1]);
        if (!value_assignable(k, e->as.call.args[1], kt))
            cg_error(e->line,
                     "%s(): key type mismatch: cannot use %s where %s "
                     "expected",
                     name, kt, k);
        return !strcmp(name, "has") ? "bool" : "void";
    }

    FuncSig *sig = NULL;
    const char *recv_t = NULL;
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_try(cg, left);
        if (pkg) {
            sig = sig_find_in(cg, pkg, right);
            if (!sig && is_native_pkg(cg, pkg))
                return native_check(cg, pkg, right, e);
            if (!sig)
                cg_error(e->line, "package '%s' has no function '%s'", pkg,
                         right);
            if (!sig->is_pub)
                cg_error(e->line,
                         "function '%s' is not exported from package '%s' "
                         "(add 'pub' to export it)",
                         right, pkg);
        } else {
            /* method call on a struct-typed receiver */
            recv_t = infer_ident_name(cg, left, e->line);
            StructDef *sd = struct_find_canon(cg, recv_t);
            if (!sd)
                cg_error(e->line, "call to undefined function '%s'", name);
            sig = method_find(cg, sd, right);
            if (!sig)
                cg_error(e->line, "type '%s' has no method '%s'",
                         sd->canonical, right);
            if (!sig->is_pub && strcmp(sd->pkg, cg->cur_pkg))
                cg_error(e->line,
                         "method '%s' is not exported from package '%s' "
                         "(add 'pub' to export it)",
                         right, sd->pkg);
        }
    } else {
        sig = sig_find_in(cg, cg->cur_pkg, name);
        if (!sig)
            cg_error(e->line, "call to undefined function '%s'", name);
    }
    int self_off = recv_t ? 1 : 0;
    if (n + self_off != sig->nparams)
        cg_error(e->line,
                 "function '%s' expects %d argument(s), got %d", name,
                 sig->nparams - self_off, n);
    for (int i = 0; i < n; i++) {
        const char *saved =
            expect_push(cg, sig->param_slang[i + self_off]);
        const char *at = infer_type(cg, e->as.call.args[i]);
        cg->expect = saved;
        if (!value_assignable(sig->param_slang[i + self_off],
                              e->as.call.args[i], at))
            cg_error(e->line,
                     "argument %d of '%s': cannot pass %s where %s expected",
                     i + 1, name, at, sig->param_slang[i + self_off]);
    }
    return sig->ret_slang ? sig->ret_slang : "void";
}

static const char *infer_binary(CG *cg, Expr *e) {
    const char *op = e->as.binary.op;
    const char *lt = infer_type(cg, e->as.binary.lhs);

    if (!strcmp(op, "??")) {
        /* null-coalescing: unwrap an opt/result, falling back to the
         * right-hand side when there is no value. The fallback's
         * expected type must be active while inferring it so bare
         * none/err on the right can resolve their type from context. */
        if (is_opt(lt)) {
            char *inner = opt_inner(lt);
            const char *saved = expect_push(cg, inner);
            const char *rt = infer_type(cg, e->as.binary.rhs);
            cg->expect = saved;
            if (!value_assignable(inner, e->as.binary.rhs, rt))
                cg_error(e->line,
                         "null-coalescing fallback type mismatch: cannot "
                         "use %s where %s expected",
                         rt, inner);
            return inner;
        }
        if (is_result(lt)) {
            char *tv, *tev;
            result_te(lt, &tv, &tev);
            const char *saved = expect_push(cg, tv);
            const char *rt = infer_type(cg, e->as.binary.rhs);
            cg->expect = saved;
            if (!value_assignable(tv, e->as.binary.rhs, rt))
                cg_error(e->line,
                         "null-coalescing fallback type mismatch: cannot "
                         "use %s where %s expected",
                         rt, tv);
            return tv;
        }
        cg_error(e->line,
                 "null-coalescing requires an opt or result value on "
                 "the left (got %s)",
                 lt);
    }

    const char *rt = infer_type(cg, e->as.binary.rhs);
    if (!strcmp(op, "&&") || !strcmp(op, "||")) {
        if (strcmp(lt, "bool") || strcmp(rt, "bool"))
            cg_error(e->line, "'%s' requires bool operands (got %s and %s)",
                     op, lt, rt);
        return "bool";
    }
    if (!strcmp(op, "==") || !strcmp(op, "!=") || !strcmp(op, "<") ||
        !strcmp(op, "<=") || !strcmp(op, ">") || !strcmp(op, ">=")) {
        if (is_num(lt) && is_num(rt))
            return "bool";
        if (is_str(lt) && is_str(rt))
            return "bool";
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) && is_bytes(lt) &&
            is_bytes(rt))
            return "bool";
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) && is_rawptr(lt) &&
            is_rawptr(rt))
            return "bool";
        cg_error(e->line, "cannot compare %s and %s", lt, rt);
    }
    if (!strcmp(op, "+")) {
        if (is_str(lt) || is_str(rt)) {
            const char *other = is_str(lt) ? rt : lt;
            if (!(is_str(other) || is_num(other) || !strcmp(other, "bool") ||
                  is_bytes(other)))
                cg_error(e->line,
                         "cannot concatenate %s onto a string with '+'",
                         other);
            return "str";
        }
        if (is_bytes(lt) && is_bytes(rt))
            return "bytes";
        if (is_arr(lt) && is_arr(rt)) {
            if (strcmp(lt, rt))
                cg_error(e->line,
                         "cannot concatenate lists of different types "
                         "(%s and %s)",
                         lt, rt);
            return lt;
        }
        if (is_num(lt) && is_num(rt))
            return promote(lt, rt);
        cg_error(e->line, "unsupported operand types for '+': %s and %s",
                 lt, rt);
    }
    if (!strcmp(op, "-") || !strcmp(op, "*") || !strcmp(op, "/")) {
        if (is_num(lt) && is_num(rt))
            return promote(lt, rt);
        cg_error(e->line, "unsupported operand types for '%s': %s and %s",
                 op, lt, rt);
    }
    if (!strcmp(op, "%")) {
        if (is_int(lt) && is_int(rt))
            return promote(lt, rt);
        cg_error(e->line, "'%%' requires integer operands (got %s and %s)",
                 lt, rt);
    }
    cg_error(e->line, "unknown operator '%s'", op);
    return NULL; /* unreachable */
}

static const char *infer_type(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_INT:    return "int";
    case EX_FLOAT:  return "float";
    case EX_STRING: return "str";
    case EX_BYTES:  return "bytes";
    case EX_BOOL:   return "bool";
    case EX_IDENT:
        return infer_ident_name(cg, e->as.ident.name, e->line);
    case EX_UNARY: {
        const char *t = infer_type(cg, e->as.unary.operand);
        if (!strcmp(e->as.unary.op, "-")) {
            if (!is_num(t))
                cg_error(e->line,
                         "unary '-' requires a numeric operand (got %s)", t);
            return t;
        }
        if (!strcmp(t, "bool"))
            return "bool";
        cg_error(e->line, "'!' requires a bool operand (got %s)", t);
    }
    case EX_BINARY:
        return infer_binary(cg, e);
    case EX_CALL:
        return infer_call(cg, e);
    case EX_CAST: {
        const char *ty = e->as.cast.ty;
        if (!map_type(ty) || !is_num(ty))
            cg_error(e->line, "invalid cast target type '%s'", ty);
        const char *t = infer_type(cg, e->as.cast.operand);
        if (!is_num(t))
            cg_error(e->line, "cannot cast %s to %s (only numeric types "
                              "participate in casts)",
                     t, ty);
        return ty;
    }
    case EX_INDEX: {
        const char *bt = infer_type(cg, e->as.index.base);
        const char *it = infer_type(cg, e->as.index.index);
        if (is_map(bt)) {
            char *k, *v;
            map_kv(bt, &k, &v);
            if (!value_assignable(k, e->as.index.index, it))
                cg_error(e->line,
                         "map key type mismatch: cannot use %s where %s "
                         "expected",
                         it, k);
            return v;
        }
        if (!is_int(it))
            cg_error(e->line, "index must be an integer (got %s)", it);
        if (is_bytes(bt))
            return "int";
        if (is_arr(bt))
            return arr_elem(bt);
        cg_error(e->line, "cannot index a value of type %s", bt);
    }
    case EX_SLICE: {
        const char *bt = infer_type(cg, e->as.slice.base);
        if (e->as.slice.start) {
            const char *st = infer_type(cg, e->as.slice.start);
            if (!is_int(st))
                cg_error(e->line, "slice start must be an integer (got %s)",
                         st);
        }
        if (e->as.slice.end) {
            const char *et = infer_type(cg, e->as.slice.end);
            if (!is_int(et))
                cg_error(e->line, "slice end must be an integer (got %s)",
                         et);
        }
        if (is_bytes(bt))
            return "bytes";
        if (is_arr(bt))
            return bt;
        cg_error(e->line, "cannot slice a value of type %s", bt);
    }
    case EX_LIST: {
        if (e->as.list.nelems == 0)
            cg_error(e->line,
                     "cannot infer the element type of an empty list; "
                     "annotate the variable, e.g. let xs: [int] = []");
        const char *t0 = infer_type(cg, e->as.list.elems[0]);
        for (int i = 1; i < e->as.list.nelems; i++) {
            const char *ti = infer_type(cg, e->as.list.elems[i]);
            if (!value_assignable(t0, e->as.list.elems[i], ti))
                cg_error(e->line,
                         "list elements must share a common type: cannot "
                         "use %s where %s was established by the first "
                         "element",
                         ti, t0);
        }
        return xasprintf("[%s]", t0);
    }
    case EX_MAPLIT: {
        if (e->as.maplit.npairs == 0)
            cg_error(e->line,
                     "cannot infer the key/value types of an empty map; "
                     "annotate the variable, e.g. let m: map[str]int = {}");
        const char *kt = infer_type(cg, e->as.maplit.keys[0]);
        if (!is_map_key(kt))
            cg_error(e->line,
                     "map keys must be an integer type, str, or bool "
                     "(got %s)",
                     kt);
        const char *vt = infer_type(cg, e->as.maplit.vals[0]);
        for (int i = 1; i < e->as.maplit.npairs; i++) {
            const char *ki = infer_type(cg, e->as.maplit.keys[i]);
            const char *vi = infer_type(cg, e->as.maplit.vals[i]);
            if (!value_assignable(kt, e->as.maplit.keys[i], ki))
                cg_error(e->line,
                         "map keys must share a common type: cannot use %s "
                         "where %s was established by the first key",
                         ki, kt);
            if (!value_assignable(vt, e->as.maplit.vals[i], vi))
                cg_error(e->line,
                         "map values must share a common type: cannot use "
                         "%s where %s was established by the first value",
                         vi, vt);
        }
        return xasprintf("map[%s]%s", kt, vt);
    }
    case EX_FIELD: {
        const char *bt = infer_type(cg, e->as.field.base);
        StructDef *sd = struct_find_canon(cg, bt);
        if (!sd)
            cg_error(e->line, "'.' used on a value of type %s", bt);
        for (int i = 0; i < sd->nfields; i++) {
            if (!strcmp(sd->fields[i], e->as.field.name))
                return sd->ftypes[i];
        }
        cg_error(e->line, "struct '%s' has no field '%s'", sd->canonical,
                 e->as.field.name);
    }
    case EX_STRUCTLIT: {
        const char *canon =
            canon_type(cg, e->as.structlit.tyname, e->line);
        StructDef *sd = struct_find_canon(cg, canon);
        for (int i = 0; i < sd->nfields; i++) {
            int found = -1;
            for (int j = 0; j < e->as.structlit.nfields; j++) {
                if (!strcmp(sd->fields[i], e->as.structlit.fields[j]))
                    found = j;
            }
            if (found < 0)
                cg_error(e->line, "missing field '%s' in %s literal",
                         sd->fields[i], sd->canonical);
            Expr *v = e->as.structlit.vals[found];
            const char *vt = infer_type(cg, v);
            if (!value_assignable(sd->ftypes[i], v, vt))
                cg_error(e->line,
                         "field '%s': cannot use %s where %s expected",
                         sd->fields[i], vt, sd->ftypes[i]);
        }
        for (int j = 0; j < e->as.structlit.nfields; j++) {
            int known = 0;
            for (int i = 0; i < sd->nfields; i++) {
                if (!strcmp(sd->fields[i], e->as.structlit.fields[j]))
                    known = 1;
            }
            if (!known)
                cg_error(e->line,
                         "struct '%s' has no field '%s'", sd->canonical,
                         e->as.structlit.fields[j]);
        }
        return canon;
    }
    }
    return NULL; /* unreachable */
}

/* ------------------------------------------------------------------ */
/* Expression code generation                                          */
/* ------------------------------------------------------------------ */

static char *gen_expr(CG *cg, Expr *e);

/* C expression for a possibly-dotted identifier: locals, package
 * globals, imported members, or struct field chains. */
static char *gen_ident_name(CG *cg, const char *name, int line) {
    VarSym *v = var_find(cg, name);
    if (v)
        return sanitize_ident(name);
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_try(cg, left);
        if (pkg) {
            GlobSym *g = glob_find(cg, pkg, right);
            if (!g || !g->is_pub)
                cg_error(line,
                         "variable '%s' is not accessible from package "
                         "'%s'",
                         right, pkg);
            return mangle_glob(g->pkg, g->name);
        }
        char *base = gen_ident_name(cg, left, line);
        return xasprintf("(%s)->%s", base, sanitize_ident(right));
    }
    GlobSym *g = glob_find(cg, cg->cur_pkg, name);
    if (g)
        return mangle_glob(g->pkg, g->name);
    return sanitize_ident(name);
}

static char *gen_float_literal(double v) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    if (!strpbrk(buf, ".eE"))
        strcat(buf, ".0");
    return xstrdup(buf);
}

/* Convert any scalar/bytes value to a slang str (C string). */
static char *conv_to_str(const char *t, char *expr) {
    if (is_str(t))
        return expr;
    if (is_int(t) && is_signed_int(t))
        return xasprintf("sl_str_from_int((long long)(%s))", expr);
    if (is_int(t))
        return xasprintf("sl_str_from_uint((unsigned long long)(%s))", expr);
    if (is_flt(t))
        return xasprintf("sl_str_from_float((double)(%s))", expr);
    if (!strcmp(t, "bool"))
        return xasprintf("sl_str_from_bool(%s)", expr);
    if (is_bytes(t))
        return xasprintf("sl_str_from_bytes(%s)", expr);
    cg_error(0, "internal: no str conversion for %s", t);
    return NULL; /* unreachable */
}

static char *gen_string_concat(CG *cg, Expr *e, const char *lt,
                               const char *rt) {
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    char *ca = conv_to_str(lt, a);
    char *cb = conv_to_str(rt, b);
    return xasprintf("sl_str_concat(%s, %s)", ca, cb);
}

static char *gen_numeric_binary(CG *cg, Expr *e, const char *result_t) {
    const char *op = e->as.binary.op;
    const char *lt = infer_type(cg, e->as.binary.lhs);
    const char *rt = infer_type(cg, e->as.binary.rhs);
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    a = maybe_cast(cg, result_t, lt, a);
    b = maybe_cast(cg, result_t, rt, b);
    /* Integer '/' and '%' by zero trap the CPU (SIGFPE) rather than
     * raising a catchable error; guard explicitly so it becomes an
     * ordinary runtime error like an out-of-bounds index instead of
     * an uncatchable signal (which would defeat per-task failure
     * isolation once a task can crash the whole process anyway). */
    if ((!strcmp(op, "/") || !strcmp(op, "%")) && is_int(result_t)) {
        int id = cg->tmp_id++;
        return xasprintf(
            "({ %s _sl_dv%d = (%s); if (_sl_dv%d == 0) "
            "sl_rt_error(\"division by zero\", 0, 0); "
            "(%s)((%s) %s _sl_dv%d); })",
            map_type(result_t), id, b, id, map_type(result_t), a, op, id);
    }
    /* Cast the result back to the slang result type: C's integer
     * promotions would otherwise widen narrow types to int and lose
     * the documented wrap-on-overflow semantics. */
    return xasprintf("((%s)((%s) %s (%s)))", map_type(result_t), a, op, b);
}

static char *gen_comparison(CG *cg, Expr *e, const char *lt, const char *rt) {
    const char *op = e->as.binary.op;
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    if (is_str(lt) && is_str(rt))
        return xasprintf("(strcmp(%s, %s) %s 0)", a, b, op);
    if (is_bytes(lt) && is_bytes(rt)) {
        if (!strcmp(op, "=="))
            return xasprintf("(sl_bytes_eq(%s, %s))", a, b);
        return xasprintf("(!sl_bytes_eq(%s, %s))", a, b);
    }
    /* mixed-width numerics: widen both to the common type */
    const char *pt = promote(lt, rt);
    a = maybe_cast(cg, pt, lt, a);
    b = maybe_cast(cg, pt, rt, b);
    return xasprintf("(%s %s %s)", a, op, b);
}

static char *gen_builtin_call(CG *cg, Expr *e, int *handled) {
    const char *name = e->as.call.name;
    *handled = 1;

    if (!strcmp(name, "len")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *a = gen_expr(cg, e->as.call.args[0]);
        if (is_str(t))
            return xasprintf("((long long)strlen(%s))", a);
        if (is_map(t))
            return xasprintf("((%s)->count)", a);
        return xasprintf("((%s)->len)", a);
    }
    if (!strcmp(name, "push")) {
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *elem = arr_elem(at);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        char *xs = gen_expr(cg, e->as.call.args[0]);
        char *v = gen_expr(cg, e->as.call.args[1]);
        v = maybe_cast(cg, elem, vt, v);
        const char *ec = ctype_of(cg, elem);
        return xasprintf(
            "({ %s _sl_v = %s; sl_arr *_sl_a = %s; sl_arr_push(_sl_a, "
            "&_sl_v, sizeof(%s)); _sl_a; })",
            ec, v, xs, ec);
    }
    if (!strcmp(name, "pop")) {
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *elem = arr_elem(at);
        char *xs = gen_expr(cg, e->as.call.args[0]);
        const char *ec = ctype_of(cg, elem);
        return xasprintf(
            "({ sl_arr *_sl_a = %s; *(%s *)(void *)sl_arr_pop(_sl_a, "
            "sizeof(%s)); })",
            xs, ec, ec);
    }
    if (!strcmp(name, "to_str")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *a = gen_expr(cg, e->as.call.args[0]);
        return conv_to_str(t, a);
    }
    if (!strcmp(name, "to_bytes")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        return xasprintf("sl_bytes_from_str(%s)", a);
    }
    if (!strcmp(name, "bytes_ptr")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        return xasprintf("((void *)(%s)->ptr)", a);
    }
    if (!strcmp(name, "make_chan")) {
        /* cg->expect must still hold the annotated chan[T] target,
         * exactly as ctor_infer relies on for some/none/ok/err */
        char *elem = chan_elem(infer_type(cg, e));
        char *a = gen_expr(cg, e->as.call.args[0]);
        return xasprintf("sl_chan_new(sizeof(%s), (int)(%s))",
                         ctype_of(cg, elem), a);
    }
    if (!strcmp(name, "chan_send")) {
        const char *ct = infer_type(cg, e->as.call.args[0]);
        char *elem = chan_elem(ct);
        char *ch = gen_expr(cg, e->as.call.args[0]);
        const char *saved = expect_push(cg, elem);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        char *v = gen_expr(cg, e->as.call.args[1]);
        cg->expect = saved;
        v = maybe_cast(cg, elem, vt, v);
        int id = cg->tmp_id++;
        return xasprintf(
            "({ %s _sl_cv%d = %s; sl_chan_send(%s, &_sl_cv%d); })",
            ctype_of(cg, elem), id, v, ch, id);
    }
    if (!strcmp(name, "chan_recv")) {
        const char *ct = infer_type(cg, e->as.call.args[0]);
        char *elem = chan_elem(ct);
        char *ch = gen_expr(cg, e->as.call.args[0]);
        int id = cg->tmp_id++;
        const char *ec = ctype_of(cg, elem);
        const char *oc = opt_cname(cg, elem);
        return xasprintf(
            "({ %s _sl_cv%d; %s *_sl_co%d = (%s *)GC_malloc(sizeof(*_sl_co%d)); "
            "if (sl_chan_recv(%s, &_sl_cv%d)) { _sl_co%d->has = true; "
            "_sl_co%d->v = _sl_cv%d; } else { _sl_co%d->has = false; } "
            "_sl_co%d; })",
            ec, id, oc, id, oc, id, ch, id, id, id, id, id, id);
    }
    if (!strcmp(name, "chan_close")) {
        char *ch = gen_expr(cg, e->as.call.args[0]);
        return xasprintf("sl_chan_close(%s)", ch);
    }
    if (!strcmp(name, "to_le") || !strcmp(name, "to_be")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *a = gen_expr(cg, e->as.call.args[0]);
        if (is_signed_int(t))
            a = xasprintf("(unsigned long long)(long long)(%s)", a);
        else
            a = xasprintf("(unsigned long long)(%s)", a);
        return xasprintf("sl_%s(%s)", name, a);
    }
    if (!strcmp(name, "from_le") || !strcmp(name, "from_be")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        return xasprintf("((long long)sl_%s(%s))", name, a);
    }
    if (!strcmp(name, "exit")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        return xasprintf("exit((int)(%s))", a);
    }
    if (!strcmp(name, "has") || !strcmp(name, "del")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *m = gen_expr(cg, e->as.call.args[0]);
        char *k, *v;
        map_kv(t, &k, &v);
        const char *kc = ctype_of(cg, k);
        const char *ikt = infer_type(cg, e->as.call.args[1]);
        char *ix = maybe_cast(cg, k, ikt, gen_expr(cg, e->as.call.args[1]));
        if (!strcmp(name, "has"))
            return xasprintf(
                "({ %s _sl_k = %s; sl_map_has(%s, &_sl_k); })", kc, ix, m);
        return xasprintf(
            "({ %s _sl_k = %s; sl_map_del(%s, &_sl_k); })", kc, ix, m);
    }
    *handled = 0;
    return NULL;
}

/* Generate an option/result constructor expression (some/ok/err).
 * 'none' is an identifier and is handled directly in gen_expr. */
static char *gen_ctor(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    Expr *arg = e->as.call.args[0];
    /* ctor_infer validates and returns opt[T] / result[T,E]; cg->expect
     * must still be active while generating the argument so nested
     * none/ok/err resolve correctly */
    const char *ty = ctor_infer(cg, e);
    char *target;
    if (!strcmp(name, "some")) {
        target = opt_inner(ty);
    } else {
        char *tv, *tev;
        result_te(ty, &tv, &tev);
        target = !strcmp(name, "ok") ? tv : tev;
    }
    const char *saved = expect_push(cg, target);
    const char *at = infer_type(cg, arg);
    char *v = gen_expr(cg, arg);
    cg->expect = saved;
    v = maybe_cast(cg, target, at, v);
    const char *cn = ctype_of(cg, ty);
    if (!strcmp(name, "some"))
        return xasprintf(
            "({ %s _sl_c = (%s)GC_malloc(sizeof(*_sl_c)); "
            "_sl_c->has = true; _sl_c->v = %s; _sl_c; })",
            cn, cn, v);
    if (!strcmp(name, "ok"))
        return xasprintf(
            "({ %s _sl_c = (%s)GC_malloc(sizeof(*_sl_c)); "
            "_sl_c->ok = true; _sl_c->v = %s; _sl_c; })",
            cn, cn, v);
    return xasprintf(
        "({ %s _sl_c = (%s)GC_malloc(sizeof(*_sl_c)); "
        "_sl_c->ok = false; _sl_c->e = %s; _sl_c; })",
        cn, cn, v);
}

/* Generate a call into a native package (time/net). Numeric arguments
 * are widened to the C parameter types of the runtime helpers. */
static char *native_gen(CG *cg, const char *pkg, const char *fname,
                        Expr *e) {
    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb, xasprintf("sl_%s_%s(", sanitize_pkg(pkg),
                             sanitize_ident(fname)));
    for (int i = 0; i < e->as.call.nargs; i++) {
        if (i)
            sb_append(&sb, ", ");
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        if (!is_str(at) && !is_bytes(at))
            a = maybe_cast(cg, !strcmp(pkg, "time") ? "int" : "i32", at, a);
        sb_append(&sb, a);
    }
    sb_append(&sb, ")");
    return sb.data;
}

static char *gen_call(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    if (!strcmp(name, "print") || !strcmp(name, "println"))
        cg_error(e->line,
                 "%s() is a statement and cannot be used inside an "
                 "expression",
                 name);

    if (!strcmp(name, "some") || !strcmp(name, "ok") ||
        !strcmp(name, "err"))
        return gen_ctor(cg, e);

    int handled = 0;
    if (is_builtin_name(name)) {
        char *r = gen_builtin_call(cg, e, &handled);
        if (handled)
            return r;
    }

    FuncSig *sig = NULL;
    char *selfexpr = NULL;
    const char *recv_t = NULL;
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_try(cg, left);
        if (pkg) {
            sig = sig_find_in(cg, pkg, right);
            if (!sig && is_native_pkg(cg, pkg))
                return native_gen(cg, pkg, right, e);
            if (!sig)
                cg_error(e->line, "package '%s' has no function '%s'", pkg,
                         right);
            if (!sig->is_pub)
                cg_error(e->line,
                         "function '%s' is not exported from package '%s'",
                         right, pkg);
        } else {
            recv_t = infer_ident_name(cg, left, e->line);
            StructDef *sd = struct_find_canon(cg, recv_t);
            if (!sd)
                cg_error(e->line, "call to undefined function '%s'", name);
            sig = method_find(cg, sd, right);
            if (!sig)
                cg_error(e->line, "type '%s' has no method '%s'",
                         sd->canonical, right);
            if (!sig->is_pub && strcmp(sd->pkg, cg->cur_pkg))
                cg_error(e->line,
                         "method '%s' is not exported from package '%s'",
                         right, sd->pkg);
            selfexpr = gen_ident_name(cg, left, e->line);
        }
    } else {
        sig = sig_find_in(cg, cg->cur_pkg, name);
        if (!sig)
            cg_error(e->line, "call to undefined function '%s'", name);
    }

    StrBuf sb;
    sb_init(&sb);
    char *mangled = sig->is_extern ? xstrdup(sig->name)
                                   : mangle_func(sig->pkg, sig->name);
    sb_append(&sb, mangled);
    sb_putc(&sb, '(');
    int argi = 0;
    if (selfexpr) {
        sb_append(&sb,
                  maybe_cast(cg, sig->param_slang[0], recv_t, selfexpr));
        argi = 1;
    }
    for (int i = 0; i < e->as.call.nargs; i++) {
        if (i || argi)
            sb_append(&sb, ", ");
        const char *saved =
            expect_push(cg, sig->param_slang[argi + i]);
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        cg->expect = saved;
        a = maybe_cast(cg, sig->param_slang[argi + i], at, a);
        sb_append(&sb, a);
    }
    sb_putc(&sb, ')');
    return sb.data;
}

/* Generate a map literal. With expect_k/expect_v (annotated case),
 * elements are checked/cast against those types instead of inferred. */
static char *gen_maplit(CG *cg, Expr *e, const char *expect_k,
                        const char *expect_v) {
    char *kt, *vt;
    if (expect_k) {
        kt = xstrdup(expect_k);
        vt = xstrdup(expect_v);
    } else {
        kt = xstrdup(infer_type(cg, e->as.maplit.keys[0]));
        vt = xstrdup(infer_type(cg, e->as.maplit.vals[0]));
    }
    const char *kc = ctype_of(cg, kt);
    const char *vc = ctype_of(cg, vt);
    int kstr = is_str(kt);
    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb, "({ sl_map *_sl_m = sl_map_new(sizeof(");
    sb_append(&sb, kc);
    sb_append(&sb, "), sizeof(");
    sb_append(&sb, vc);
    sb_append(&sb, xasprintf("), %d); ", kstr));
    for (int i = 0; i < e->as.maplit.npairs; i++) {
        const char *kit = infer_type(cg, e->as.maplit.keys[i]);
        char *k = gen_expr(cg, e->as.maplit.keys[i]);
        k = maybe_cast(cg, kt, kit, k);
        const char *vit = infer_type(cg, e->as.maplit.vals[i]);
        char *v = gen_expr(cg, e->as.maplit.vals[i]);
        v = maybe_cast(cg, vt, vit, v);
        sb_append(&sb,
                  xasprintf("{ %s _sl_k%d = %s; %s _sl_v%d = %s; "
                            "sl_map_put(_sl_m, &_sl_k%d, &_sl_v%d); } ",
                            kc, i, k, vc, i, v, i, i));
    }
    sb_append(&sb, "_sl_m; })");
    return sb.data;
}

static char *gen_structlit(CG *cg, Expr *e) {
    const char *canon = infer_type(cg, e); /* validates fields too */
    StructDef *sd = struct_find_canon(cg, canon);
    const char *sc = mangle_struct(canon);
    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb,
              xasprintf("({ %s *_sl_s = (%s *)GC_malloc(sizeof(%s)); ", sc,
                        sc, sc));
    for (int j = 0; j < e->as.structlit.nfields; j++) {
        int fi = -1;
        for (int i = 0; i < sd->nfields; i++) {
            if (!strcmp(sd->fields[i], e->as.structlit.fields[j]))
                fi = i;
        }
        const char *vt = infer_type(cg, e->as.structlit.vals[j]);
        char *v = gen_expr(cg, e->as.structlit.vals[j]);
        v = maybe_cast(cg, sd->ftypes[fi], vt, v);
        sb_append(&sb,
                  xasprintf("_sl_s->%s = %s; ",
                            sanitize_ident(sd->fields[fi]), v));
    }
    sb_append(&sb, "_sl_s; })");
    return sb.data;
}

static char *gen_index(CG *cg, Expr *e) {
    const char *bt = infer_type(cg, e->as.index.base);
    char *b = gen_expr(cg, e->as.index.base);
    char *i = gen_expr(cg, e->as.index.index);
    if (is_map(bt)) {
        char *k, *v;
        map_kv(bt, &k, &v);
        const char *kc = ctype_of(cg, k);
        const char *vc = ctype_of(cg, v);
        const char *ikt = infer_type(cg, e->as.index.index);
        char *ix = maybe_cast(cg, k, ikt, i);
        int id = cg->tmp_id++;
        return xasprintf(
            "({ %s _sl_k%d = %s; void *_sl_p%d = sl_map_get(%s, "
            "&_sl_k%d); if (!_sl_p%d) sl_rt_error(\"map key not found\", "
            "0, 0); *(%s *)(void *)_sl_p%d; })",
            kc, id, ix, id, b, id, id, vc, id);
    }
    if (is_bytes(bt))
        return xasprintf("((long long)sl_bytes_at(%s, %s))", b, i);
    char *elem = arr_elem(bt);
    const char *ec = ctype_of(cg, elem);
    return xasprintf("(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s)))", ec,
                     b, i, ec);
}

static char *gen_slice(CG *cg, Expr *e) {
    const char *bt = infer_type(cg, e->as.slice.base);
    char *b = gen_expr(cg, e->as.slice.base);
    char *start = e->as.slice.start ? gen_expr(cg, e->as.slice.start)
                                    : xstrdup("0");
    int id = cg->tmp_id++;
    if (is_bytes(bt)) {
        char *end = e->as.slice.end
                        ? gen_expr(cg, e->as.slice.end)
                        : xasprintf("_sl_b%d->len", id);
        if (e->as.slice.inclusive)
            end = xasprintf("(%s + 1)", end);
        return xasprintf(
            "({ sl_bytes *_sl_b%d = %s; sl_bytes_slice(_sl_b%d, %s, %s); })",
            id, b, id, start, end);
    }
    char *end =
        e->as.slice.end ? gen_expr(cg, e->as.slice.end)
                        : xasprintf("_sl_a%d->len", id);
    if (e->as.slice.inclusive)
        end = xasprintf("(%s + 1)", end);
    return xasprintf(
        "({ sl_arr *_sl_a%d = %s; sl_arr_slice(_sl_a%d, %s, %s); })", id, b,
        id, start, end);
}

static char *gen_list(CG *cg, Expr *e, const char *expect_elem) {
    const char *t0 =
        expect_elem ? expect_elem : infer_type(cg, e->as.list.elems[0]);
    const char *ec = ctype_of(cg, t0);
    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb, "({ ");
    sb_append(&sb, ec);
    sb_append(&sb, " _sl_e[] = {");
    for (int i = 0; i < e->as.list.nelems; i++) {
        if (i)
            sb_append(&sb, ", ");
        const char *ti = infer_type(cg, e->as.list.elems[i]);
        char *el = gen_expr(cg, e->as.list.elems[i]);
        el = maybe_cast(cg, t0, ti, el);
        sb_append(&sb, el);
    }
    sb_append(&sb, "}; sl_arr_from(_sl_e, ");
    sb_append(&sb, xasprintf("%d", e->as.list.nelems));
    sb_append(&sb, ", sizeof(");
    sb_append(&sb, ec);
    sb_append(&sb, ")); })");
    return sb.data;
}

static char *gen_expr(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_INT:
        return xasprintf("%lld", e->as.int_lit.value);
    case EX_FLOAT:
        return gen_float_literal(e->as.float_lit.value);
    case EX_STRING:
        return c_string_literal(e->as.str_lit.value);
    case EX_BYTES:
        return xasprintf("sl_bytes_new((const unsigned char *)%s, %lld)",
                         c_bytes_literal(e->as.bytes_lit.data,
                                         e->as.bytes_lit.len),
                         e->as.bytes_lit.len);
    case EX_BOOL:
        return xstrdup(e->as.bool_lit.value ? "true" : "false");
    case EX_IDENT:
        if (!strcmp(e->as.ident.name, "none")) {
            if (!cg->expect || !is_opt(cg->expect))
                cg_error(e->line, "cannot infer the type of 'none'");
            const char *cn = ctype_of(cg, cg->expect);
            return xasprintf(
                "({ %s _sl_n = (%s)GC_malloc(sizeof(*_sl_n)); "
                "_sl_n->has = false; _sl_n; })",
                cn, cn);
        }
        if (!strcmp(e->as.ident.name, "nullptr"))
            return xstrdup("((void *)0)");
        return gen_ident_name(cg, e->as.ident.name, e->line);
    case EX_UNARY: {
        char *o = gen_expr(cg, e->as.unary.operand);
        /* keep narrow-int wrap semantics across unary minus */
        if (!strcmp(e->as.unary.op, "-") && is_int(infer_type(cg, e)))
            return xasprintf("((%s)(-(%s)))", map_type(infer_type(cg, e)),
                             o);
        return xasprintf("(%s%s)", e->as.unary.op, o);
    }
    case EX_CAST: {
        char *o = gen_expr(cg, e->as.cast.operand);
        return xasprintf("((%s)(%s))", map_type(e->as.cast.ty), o);
    }
    case EX_INDEX:
        return gen_index(cg, e);
    case EX_SLICE:
        return gen_slice(cg, e);
    case EX_LIST:
        return gen_list(cg, e, NULL);
    case EX_MAPLIT:
        return gen_maplit(cg, e, NULL, NULL);
    case EX_FIELD: {
        char *b = gen_expr(cg, e->as.field.base);
        return xasprintf("(%s)->%s", b, sanitize_ident(e->as.field.name));
    }
    case EX_STRUCTLIT:
        return gen_structlit(cg, e);
    case EX_BINARY: {
        const char *op = e->as.binary.op;
        const char *lt = infer_type(cg, e->as.binary.lhs);

        if (!strcmp(op, "??")) {
            int id = cg->tmp_id++;
            char *a = gen_expr(cg, e->as.binary.lhs);
            if (is_opt(lt)) {
                char *inner = opt_inner(lt);
                const char *oc = ctype_of(cg, lt);
                const char *ic = ctype_of(cg, inner);
                const char *saved = expect_push(cg, inner);
                const char *rt = infer_type(cg, e->as.binary.rhs);
                char *b = gen_expr(cg, e->as.binary.rhs);
                cg->expect = saved;
                b = maybe_cast(cg, inner, rt, b);
                return xasprintf(
                    "({ %s _sl_q%d = %s; "
                    "(_sl_q%d->has ? _sl_q%d->v : (%s)(%s)); })",
                    oc, id, a, id, id, ic, b);
            }
            char *tv, *tev;
            result_te(lt, &tv, &tev);
            const char *oc = ctype_of(cg, lt);
            const char *ic = ctype_of(cg, tv);
            const char *saved = expect_push(cg, tv);
            const char *rt = infer_type(cg, e->as.binary.rhs);
            char *b = gen_expr(cg, e->as.binary.rhs);
            cg->expect = saved;
            b = maybe_cast(cg, tv, rt, b);
            return xasprintf(
                "({ %s _sl_q%d = %s; "
                "(_sl_q%d->ok ? _sl_q%d->v : (%s)(%s)); })",
                oc, id, a, id, id, ic, b);
        }

        const char *rt = infer_type(cg, e->as.binary.rhs);
        if (!strcmp(op, "&&") || !strcmp(op, "||")) {
            char *a = gen_expr(cg, e->as.binary.lhs);
            char *b = gen_expr(cg, e->as.binary.rhs);
            return xasprintf("(%s %s %s)", a, op, b);
        }
        if (!strcmp(op, "==") || !strcmp(op, "!=") || !strcmp(op, "<") ||
            !strcmp(op, "<=") || !strcmp(op, ">") || !strcmp(op, ">="))
            return gen_comparison(cg, e, lt, rt);
        if (!strcmp(op, "+") && (is_str(lt) || is_str(rt)))
            return gen_string_concat(cg, e, lt, rt);
        if (!strcmp(op, "+") && is_bytes(lt) && is_bytes(rt)) {
            char *a = gen_expr(cg, e->as.binary.lhs);
            char *b = gen_expr(cg, e->as.binary.rhs);
            return xasprintf("sl_bytes_concat(%s, %s)", a, b);
        }
        if (!strcmp(op, "+") && is_arr(lt) && is_arr(rt)) {
            char *a = gen_expr(cg, e->as.binary.lhs);
            char *b = gen_expr(cg, e->as.binary.rhs);
            return xasprintf("sl_arr_concat(%s, %s)", a, b);
        }
        if (!strcmp(op, "+") || !strcmp(op, "-") || !strcmp(op, "*") ||
            !strcmp(op, "/"))
            return gen_numeric_binary(cg, e, promote(lt, rt));
        /* '%' */
        return gen_numeric_binary(cg, e, promote(lt, rt));
    }
    case EX_CALL:
        return gen_call(cg, e);
    }
    return NULL; /* unreachable */
}

/* ------------------------------------------------------------------ */
/* Statement code generation                                           */
/* ------------------------------------------------------------------ */

static void gen_block(CG *cg, Block *b);

static void gen_print(CG *cg, Expr *call, int newline) {
    Expr *arg = call->as.call.args[0];
    const char *t = infer_type(cg, arg);
    char *v = gen_expr(cg, arg);
    if (is_int(t) && is_signed_int(t)) {
        emit_line(cg, "printf(\"%%lld%s\", (long long)(%s));",
                  newline ? "\\n" : "", v);
    } else if (is_int(t)) {
        emit_line(cg, "printf(\"%%llu%s\", (unsigned long long)(%s));",
                  newline ? "\\n" : "", v);
    } else if (is_flt(t)) {
        emit_line(cg, "printf(\"%%g%s\", (double)(%s));",
                  newline ? "\\n" : "", v);
    } else if (!strcmp(t, "bool")) {
        if (newline)
            emit_line(cg, "puts((%s) ? \"true\" : \"false\");", v);
        else
            emit_line(cg, "fputs((%s) ? \"true\" : \"false\", stdout);", v);
    } else if (is_bytes(t)) {
        emit_line(cg, "fwrite((%s)->ptr, 1, (size_t)(%s)->len, stdout);", v,
                  v);
        if (newline)
            emit_line(cg, "putchar(10);");
    } else if (!is_str(t)) {
        cg_error(call->line,
                 "cannot print a value of type %s directly", t);
    } else { /* str */
        if (newline)
            emit_line(cg, "puts(%s);", v);
        else
            emit_line(cg, "fputs(%s, stdout);", v);
    }
}

static void gen_stmt(CG *cg, Stmt *s) {
    switch (s->kind) {
    case ST_LET: {
        const char *ann = s->as.let.type_ann;
        if (ann)
            ann = canon_type(cg, ann, s->line);

        /* empty list literal: requires an annotation */
        if (s->as.let.init->kind == EX_LIST &&
            s->as.let.init->as.list.nelems == 0) {
            if (!ann || !is_arr(ann))
                cg_error(s->line,
                         "cannot infer the element type of an empty list; "
                         "annotate it, e.g. let xs: [int] = []");
            char *elem = arr_elem(ann);
            var_push(cg, s->as.let.name, ann);
            emit_line(cg, "%s %s = sl_arr_new(sizeof(%s));",
                      ctype_of(cg, ann), sanitize_ident(s->as.let.name),
                      ctype_of(cg, elem));
            break;
        }

        /* empty map literal: requires an annotation */
        if (s->as.let.init->kind == EX_MAPLIT &&
            s->as.let.init->as.maplit.npairs == 0) {
            if (!ann || !is_map(ann))
                cg_error(s->line,
                         "cannot infer the key/value types of an empty "
                         "map; annotate it, e.g. let m: map[str]int = {}");
            char *k, *v;
            map_kv(ann, &k, &v);
            var_push(cg, s->as.let.name, ann);
            emit_line(cg, "%s %s = sl_map_new(sizeof(%s), sizeof(%s), %d);",
                      ctype_of(cg, ann), sanitize_ident(s->as.let.name),
                      ctype_of(cg, k), ctype_of(cg, v), is_str(k));
            break;
        }

        const char *saved_expect = expect_push(cg, ann);
        const char *it = infer_type(cg, s->as.let.init);
        const char *t = ann ? ann : it;
        /* Annotated list/map literals: check elements against the
         * declared types instead of the inferred ones. */
        int ann_list =
            ann && is_arr(ann) && s->as.let.init->kind == EX_LIST;
        int ann_map =
            ann && is_map(ann) && s->as.let.init->kind == EX_MAPLIT;
        char *ak = NULL, *av = NULL;
        if (ann_list) {
            char *elem = arr_elem(ann);
            for (int i = 0; i < s->as.let.init->as.list.nelems; i++) {
                Expr *ei = s->as.let.init->as.list.elems[i];
                const char *ti = infer_type(cg, ei);
                if (!value_assignable(elem, ei, ti))
                    cg_error(s->line,
                             "list element %d: cannot use %s where %s "
                             "expected",
                             i + 1, ti, elem);
            }
        } else if (ann_map) {
            map_kv(ann, &ak, &av);
            for (int i = 0; i < s->as.let.init->as.maplit.npairs; i++) {
                Expr *ki = s->as.let.init->as.maplit.keys[i];
                Expr *vi = s->as.let.init->as.maplit.vals[i];
                const char *kty = infer_type(cg, ki);
                const char *vty = infer_type(cg, vi);
                if (!value_assignable(ak, ki, kty))
                    cg_error(s->line,
                             "map key %d: cannot use %s where %s expected",
                             i + 1, kty, ak);
                if (!value_assignable(av, vi, vty))
                    cg_error(
                        s->line,
                        "map value %d: cannot use %s where %s expected",
                        i + 1, vty, av);
            }
        } else if (!value_assignable(t, s->as.let.init, it)) {
            cg_error(s->line,
                     "cannot initialize %s '%s' with a value of type %s%s",
                     t, s->as.let.name, it,
                     ann ? "" : " (annotate the variable to force a "
                                "conversion)");
        }
        char *init;
        if (ann_list)
            init = gen_list(cg, s->as.let.init, arr_elem(ann));
        else if (ann_map)
            init = gen_maplit(cg, s->as.let.init, ak, av);
        else
            init = gen_expr(cg, s->as.let.init);
        init = maybe_cast(cg, t, it, init);
        cg->expect = saved_expect;
        var_push(cg, s->as.let.name, t);
        emit_line(cg, "%s %s = %s;", ctype_of(cg, t),
                  sanitize_ident(s->as.let.name), init);
        break;
    }
    case ST_ASSIGN: {
        Expr *tgt = s->as.assign.target;
        if (tgt->kind == EX_IDENT) {
            const char *name = tgt->as.ident.name;
            VarSym *v = var_find(cg, name);
            char *left, *right;
            if (!v && split_dotted(name, &left, &right) &&
                !import_try(cg, left)) {
                /* dotted field assignment: p.x = v (the parser folds
                 * 'p.x' into a single qualified identifier) */
                const char *bt = infer_ident_name(cg, left, s->line);
                StructDef *sd = struct_find_canon(cg, bt);
                if (!sd)
                    cg_error(s->line, "'%s' has no member '%s'", left,
                             right);
                int fi = -1;
                for (int i = 0; i < sd->nfields; i++) {
                    if (!strcmp(sd->fields[i], right))
                        fi = i;
                }
                if (fi < 0)
                    cg_error(s->line, "struct '%s' has no field '%s'",
                             sd->canonical, right);
                const char *se1 = expect_push(cg, sd->ftypes[fi]);
                const char *vt = infer_type(cg, s->as.assign.value);
                cg->expect = se1;
                if (!value_assignable(sd->ftypes[fi], s->as.assign.value,
                                      vt))
                    cg_error(s->line,
                             "field '%s': cannot assign a value of type %s "
                             "where %s expected",
                             sd->fields[fi], vt, sd->ftypes[fi]);
                char *b = gen_ident_name(cg, left, s->line);
                const char *se2 = expect_push(cg, sd->ftypes[fi]);
                char *val = maybe_cast(cg, sd->ftypes[fi], vt,
                                       gen_expr(cg, s->as.assign.value));
                cg->expect = se2;
                emit_line(cg, "%s->%s = %s;", b,
                          sanitize_ident(sd->fields[fi]), val);
                break;
            }
            if (!v)
                cg_error(s->line, "undefined variable '%s'", name);
            const char *se3 = expect_push(cg, v->slang);
            const char *vt = infer_type(cg, s->as.assign.value);
            cg->expect = se3;
            if (!value_assignable(v->slang, s->as.assign.value, vt))
                cg_error(s->line,
                         "cannot assign a value of type %s to variable "
                         "'%s' of type %s",
                         vt, name, v->slang);
            const char *se4 = expect_push(cg, v->slang);
            char *val =
                maybe_cast(cg, v->slang, vt,
                           gen_expr(cg, s->as.assign.value));
            cg->expect = se4;
            emit_line(cg, "%s = %s;", sanitize_ident(name), val);
            break;
        }
        if (tgt->kind == EX_FIELD) {
            /* struct field target: p.x = v */
            const char *bt = infer_type(cg, tgt->as.field.base);
            StructDef *sd = struct_find_canon(cg, bt);
            if (!sd)
                cg_error(s->line, "'.' used on a value of type %s", bt);
            int fi = -1;
            for (int i = 0; i < sd->nfields; i++) {
                if (!strcmp(sd->fields[i], tgt->as.field.name))
                    fi = i;
            }
            if (fi < 0)
                cg_error(s->line, "struct '%s' has no field '%s'",
                         sd->canonical, tgt->as.field.name);
            const char *se5 = expect_push(cg, sd->ftypes[fi]);
            const char *vt = infer_type(cg, s->as.assign.value);
            cg->expect = se5;
            if (!value_assignable(sd->ftypes[fi], s->as.assign.value, vt))
                cg_error(s->line,
                         "field '%s': cannot assign a value of type %s "
                         "where %s expected",
                         sd->fields[fi], vt, sd->ftypes[fi]);
            char *b = gen_expr(cg, tgt->as.field.base);
            const char *se6 = expect_push(cg, sd->ftypes[fi]);
            char *val = maybe_cast(cg, sd->ftypes[fi], vt,
                                   gen_expr(cg, s->as.assign.value));
            cg->expect = se6;
            emit_line(cg, "%s->%s = %s;", b,
                      sanitize_ident(sd->fields[fi]), val);
            break;
        }
        /* index target: xs[i] = v, b[i] = v, or m[k] = v */
        const char *bt = infer_type(cg, tgt->as.index.base);
        const char *vt = infer_type(cg, s->as.assign.value);
        char *b = gen_expr(cg, tgt->as.index.base);
        char *i = gen_expr(cg, tgt->as.index.index);
        char *val = gen_expr(cg, s->as.assign.value);
        if (is_map(bt)) {
            char *k, *v;
            map_kv(bt, &k, &v);
            const char *ikt = infer_type(cg, tgt->as.index.index);
            if (!value_assignable(k, tgt->as.index.index, ikt))
                cg_error(s->line,
                         "map key type mismatch: cannot use %s where %s "
                         "expected",
                         ikt, k);
            if (!value_assignable(v, s->as.assign.value, vt))
                cg_error(s->line,
                         "map value type mismatch: cannot assign %s where "
                         "%s expected",
                         vt, v);
            char *ix = maybe_cast(cg, k, ikt, i);
            val = maybe_cast(cg, v, vt, val);
            emit_line(cg,
                      "({ %s _sl_k = %s; %s _sl_v = %s; sl_map_put(%s, "
                      "&_sl_k, &_sl_v); });",
                      ctype_of(cg, k), ix, ctype_of(cg, v), val, b);
            break;
        }
        if (is_bytes(bt)) {
            if (!is_int(vt))
                cg_error(s->line,
                         "byte assignment requires an integer (got %s)",
                         vt);
            emit_line(cg, "sl_bytes_set(%s, %s, (unsigned char)(%s));", b, i,
                      val);
            break;
        }
        if (is_arr(bt)) {
            char *elem = arr_elem(bt);
            if (!value_assignable(elem, s->as.assign.value, vt))
                cg_error(s->line,
                         "cannot assign a value of type %s to an element "
                         "of type %s",
                         vt, elem);
            val = maybe_cast(cg, elem, vt, val);
            const char *ec = ctype_of(cg, elem);
            emit_line(cg,
                      "(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s))) = "
                      "(%s)(%s);",
                      ec, b, i, ec, ec, val);
            break;
        }
        cg_error(s->line, "invalid assignment target");
        break;
    }
    case ST_IF: {
        const char *ct = infer_type(cg, s->as.if_stmt.cond);
        if (strcmp(ct, "bool"))
            cg_error(s->line, "if condition must be bool (got %s)", ct);
        char *cond = gen_expr(cg, s->as.if_stmt.cond);
        emit_line(cg, "if (%s) {", cond);
        gen_block(cg, s->as.if_stmt.then_blk);
        if (s->as.if_stmt.else_blk) {
            emit_line(cg, "} else {");
            gen_block(cg, s->as.if_stmt.else_blk);
        }
        emit_line(cg, "}");
        break;
    }
    case ST_WHILE: {
        const char *ct = infer_type(cg, s->as.while_stmt.cond);
        if (strcmp(ct, "bool"))
            cg_error(s->line, "while condition must be bool (got %s)", ct);
        char *cond = gen_expr(cg, s->as.while_stmt.cond);
        emit_line(cg, "while (%s) {", cond);
        gen_block(cg, s->as.while_stmt.body);
        emit_line(cg, "}");
        break;
    }
    case ST_FOR: {
        const char *st = infer_type(cg, s->as.for_stmt.start);
        const char *et = infer_type(cg, s->as.for_stmt.end);
        if (!is_int(st) || !is_int(et))
            cg_error(s->line,
                     "range bounds must be integers (got %s and %s)", st,
                     et);
        var_push(cg, s->as.for_stmt.name, "int");
        char *start = gen_expr(cg, s->as.for_stmt.start);
        char *end = gen_expr(cg, s->as.for_stmt.end);
        char *endvar = xasprintf("sl_end_%d", cg->tmp_id++);
        const char *op = s->as.for_stmt.inclusive ? "<=" : "<";
        char *vname = sanitize_ident(s->as.for_stmt.name);
        emit_line(cg, "{");
        cg->indent++;
        emit_line(cg, "long long %s = %s;", endvar, end);
        emit_line(cg, "for (long long %s = %s; %s %s %s; %s++) {", vname,
                  start, vname, op, endvar, vname);
        gen_block(cg, s->as.for_stmt.body);
        emit_line(cg, "}");
        cg->indent--;
        emit_line(cg, "}");
        break;
    }
    case ST_FOR_IN: {
        const char *it = infer_type(cg, s->as.for_in.iter);
        int id = cg->tmp_id++;
        char *iter = gen_expr(cg, s->as.for_in.iter);
        char *vname = sanitize_ident(s->as.for_in.name);
        if (is_arr(it)) {
            char *elem = arr_elem(it);
            const char *ec = ctype_of(cg, elem);
            var_push(cg, s->as.for_in.name, elem);
            emit_line(cg, "{");
            cg->indent++;
            emit_line(cg, "sl_arr *_sl_it%d = %s;", id, iter);
            emit_line(cg,
                      "for (long long _sl_i%d = 0; _sl_i%d < _sl_it%d->len; "
                      "_sl_i%d++) {",
                      id, id, id, id);
            cg->indent++;
            emit_line(cg, "%s %s = (*(%s *)(void *)sl_arr_get(_sl_it%d, "
                          "_sl_i%d, sizeof(%s)));",
                      ec, vname, ec, id, id, ec);
            gen_block(cg, s->as.for_in.body);
            cg->indent--;
            emit_line(cg, "}");
            cg->indent--;
            emit_line(cg, "}");
            break;
        }
        if (is_bytes(it)) {
            var_push(cg, s->as.for_in.name, "int");
            emit_line(cg, "{");
            cg->indent++;
            emit_line(cg, "sl_bytes *_sl_bt%d = %s;", id, iter);
            emit_line(cg,
                      "for (long long _sl_i%d = 0; _sl_i%d < _sl_bt%d->len; "
                      "_sl_i%d++) {",
                      id, id, id, id);
            cg->indent++;
            emit_line(cg, "long long %s = (long long)_sl_bt%d->ptr[_sl_i%d];",
                      vname, id, id);
            gen_block(cg, s->as.for_in.body);
            cg->indent--;
            emit_line(cg, "}");
            cg->indent--;
            emit_line(cg, "}");
            break;
        }
        if (is_map(it)) {
            if (!s->as.for_in.name2)
                cg_error(s->line,
                         "iterating a map requires two variables: "
                         "for k, v in m");
            char *k, *v;
            map_kv(it, &k, &v);
            const char *kc = ctype_of(cg, k);
            const char *vc = ctype_of(cg, v);
            char *v2name = sanitize_ident(s->as.for_in.name2);
            var_push(cg, s->as.for_in.name, k);
            var_push(cg, s->as.for_in.name2, v);
            emit_line(cg, "{");
            cg->indent++;
            emit_line(cg, "sl_map *_sl_m%d = %s;", id, iter);
            emit_line(cg,
                      "for (long long _sl_i%d = 0; _sl_i%d < _sl_m%d->count; "
                      "_sl_i%d++) {",
                      id, id, id, id);
            cg->indent++;
            emit_line(cg, "long long _sl_slot%d = _sl_m%d->order[_sl_i%d];",
                      id, id, id);
            emit_line(cg,
                      "%s %s = *(%s *)(void *)(_sl_m%d->keys + _sl_slot%d * "
                      "_sl_m%d->ksz);",
                      kc, vname, kc, id, id, id);
            emit_line(cg,
                      "%s %s = *(%s *)(void *)(_sl_m%d->vals + _sl_slot%d * "
                      "_sl_m%d->vsz);",
                      vc, v2name, vc, id, id, id);
            gen_block(cg, s->as.for_in.body);
            cg->indent--;
            emit_line(cg, "}");
            cg->indent--;
            emit_line(cg, "}");
            break;
        }
        cg_error(s->line, "cannot iterate over a value of type %s", it);
        break;
    }
    case ST_RETURN: {
        if (!cg->in_function)
            cg_error(s->line, "'return' outside of a function");
        if (!s->as.ret.value) {
            if (cg->cur_ret)
                cg_error(s->line, "missing return value");
            emit_line(cg, "return;");
        } else {
            if (!cg->cur_ret)
                cg_error(s->line,
                         "cannot return a value from a void function");
            const char *se7 = expect_push(cg, cg->cur_ret);
            const char *vt = infer_type(cg, s->as.ret.value);
            cg->expect = se7;
            if (!value_assignable(cg->cur_ret, s->as.ret.value, vt))
                cg_error(s->line,
                         "return type mismatch: cannot return %s where %s "
                         "expected",
                         vt, cg->cur_ret);
            const char *se8 = expect_push(cg, cg->cur_ret);
            char *val = maybe_cast(cg, cg->cur_ret, vt,
                                   gen_expr(cg, s->as.ret.value));
            cg->expect = se8;
            emit_line(cg, "return %s;", val);
        }
        break;
    }
    case ST_EXPR: {
        Expr *e = s->as.expr_stmt.expr;
        if (e->kind == EX_CALL &&
            (!strcmp(e->as.call.name, "print") ||
             !strcmp(e->as.call.name, "println"))) {
            gen_print(cg, e, !strcmp(e->as.call.name, "println"));
            break;
        }
        /* every other statement kind validates via infer_type before
         * generating; a bare statement call must too, or mismatched
         * arguments (e.g. a str where an int is expected) silently
         * reinterpret the wrong C value instead of being rejected */
        infer_type(cg, e);
        char *code = gen_expr(cg, e);
        emit_line(cg, "%s;", code);
        break;
    }
    case ST_GUARD_LET:
        /* handled by gen_stmts, which needs to see the statements that
         * follow it in the same block */
        break;
    case ST_SPAWN: {
        Expr *call = s->as.spawn.call;
        const char *name = call->as.call.name;
        if (is_builtin_name(name))
            cg_error(s->line, "'spawn' cannot target a builtin function");

        FuncSig *sig;
        char *left, *right;
        if (split_dotted(name, &left, &right)) {
            const char *pkg = import_try(cg, left);
            if (!pkg)
                cg_error(s->line,
                         "'spawn' does not support methods yet (only "
                         "plain functions and pkg.func calls)");
            if (is_native_pkg(cg, pkg))
                cg_error(s->line,
                         "'spawn' cannot target a native package "
                         "function directly; wrap it in a plain "
                         "function and spawn that instead");
            sig = sig_find_in(cg, pkg, right);
            if (!sig)
                cg_error(s->line, "package '%s' has no function '%s'",
                         pkg, right);
            if (!sig->is_pub)
                cg_error(s->line,
                         "function '%s' is not exported from package "
                         "'%s' (add 'pub' to export it)",
                         right, pkg);
        } else {
            sig = sig_find_in(cg, cg->cur_pkg, name);
            if (!sig)
                cg_error(s->line, "call to undefined function '%s'", name);
        }

        int nargs = call->as.call.nargs;
        if (nargs != sig->nparams)
            cg_error(s->line,
                     "function '%s' expects %d argument(s), got %d", name,
                     sig->nparams, nargs);

        SpawnShape *shape = spawn_shape_for(cg, sig);
        int id = cg->tmp_id++;
        emit_line(cg, "{");
        cg->indent++;
        if (nargs == 0) {
            emit_line(cg, "%s *_sl_sa%d = NULL;", shape->sname, id);
        } else {
            emit_line(cg, "%s *_sl_sa%d = (%s *)GC_malloc(sizeof(%s));",
                      shape->sname, id, shape->sname, shape->sname);
            for (int i = 0; i < nargs; i++) {
                const char *saved = expect_push(cg, sig->param_slang[i]);
                const char *at = infer_type(cg, call->as.call.args[i]);
                cg->expect = saved;
                if (!value_assignable(sig->param_slang[i],
                                      call->as.call.args[i], at))
                    cg_error(s->line,
                             "argument %d of '%s': cannot pass %s where "
                             "%s expected",
                             i + 1, name, at, sig->param_slang[i]);
                char *a = gen_expr(cg, call->as.call.args[i]);
                a = maybe_cast(cg, sig->param_slang[i], at, a);
                emit_line(cg, "_sl_sa%d->a%d = %s;", id, i, a);
            }
        }
        emit_line(cg, "pthread_t _sl_tid%d;", id);
        emit_line(cg, "pthread_create(&_sl_tid%d, NULL, %s, _sl_sa%d);", id,
                  shape->tname, id);
        emit_line(cg, "pthread_detach(_sl_tid%d);", id);
        cg->indent--;
        emit_line(cg, "}");
        break;
    }
    case ST_STRUCT:
    case ST_IMPL:
        /* declarations are processed during collect_decls; nothing to
         * execute at runtime */
        break;
    }
}

/* Generate a run of statements. A 'guard let x = <opt/result> else'
 * binds x for the remainder of the enclosing block, so it is handled
 * here rather than per-statement: everything after it is emitted
 * inside a C block that first checks the option and runs the else
 * body (which must exit via return/break/continue/exit). */
static void gen_stmts(CG *cg, Stmt **stmts, int count) {
    for (int i = 0; i < count; i++) {
        Stmt *s = stmts[i];
        if (s->kind != ST_GUARD_LET) {
            gen_stmt(cg, s);
            continue;
        }
        const char *et = infer_type(cg, s->as.guard_let.expr);
        char *inner = NULL;
        int is_res = 0;
        if (is_opt(et)) {
            inner = opt_inner(et);
        } else if (is_result(et)) {
            char *tv, *tev;
            result_te(et, &tv, &tev);
            inner = tv;
            is_res = 1;
        } else {
            cg_error(s->line,
                     "guard let requires an opt or result value (got %s)",
                     et);
        }
        int id = cg->tmp_id++;
        char *e = gen_expr(cg, s->as.guard_let.expr);
        const char *oc = ctype_of(cg, et);
        const char *ic = ctype_of(cg, inner);
        emit_line(cg, "{");
        cg->indent++;
        emit_line(cg, "%s _sl_g%d = %s;", oc, id, e);
        emit_line(cg, "if (!(_sl_g%d->%s)) {", id, is_res ? "ok" : "has");
        gen_block(cg, s->as.guard_let.body);
        emit_line(cg, "}");
        var_push(cg, s->as.guard_let.name, inner);
        emit_line(cg, "%s %s = _sl_g%d->v;", ic,
                  sanitize_ident(s->as.guard_let.name), id);
        gen_stmts(cg, stmts + i + 1, count - i - 1);
        cg->indent--;
        emit_line(cg, "}");
        return;
    }
}

static void gen_block(CG *cg, Block *b) {
    cg->indent++;
    gen_stmts(cg, b->stmts, b->count);
    cg->indent--;
}

/* ------------------------------------------------------------------ */
/* Program-level generation                                            */
/* ------------------------------------------------------------------ */

/* The runtime embedded into every generated program. Kept as plain C
 * source lines so it reads exactly like hand-written code. */
static const char *RUNTIME[] = {
    "#include <stdio.h>",
    "#include <stdlib.h>",
    "#include <string.h>",
    "#include <stdbool.h>",
    "#include <stdint.h>",
    "#define GC_THREADS",
    "#define GC_PTHREADS",
    "#include <gc.h>",
    "#include <pthread.h>",
    "",
    "/* ---- slang runtime ---- */",
    "",
    "/* set once, at the very top of main(); every spawned task's",
    " * trampoline runs with the default (0) value, so runtime errors",
    " * can tell 'the main task' apart from 'a spawned task' and",
    " * isolate a spawned task's failure instead of killing everyone */",
    "static _Thread_local int sl_rt_is_main_thread = 0;",
    "",
    "static void sl_rt_error(const char *msg, long long a, long long b) {",
    "    if (!sl_rt_is_main_thread) {",
    "        fprintf(stderr,",
    "                \"slang: task panicked: %s (index %lld, length %lld)\\n\",",
    "                msg, a, b);",
    "        pthread_exit(NULL);",
    "    }",
    "    fprintf(stderr, \"slang runtime error: %s (index %lld, length %lld)\\n\",",
    "            msg, a, b);",
    "    exit(1);",
    "}",
    "",
    "/* ---- chan[T]: bounded, thread-safe queue for 'spawn'ed tasks ---- */",
    "",
    "typedef struct {",
    "    unsigned char *buf;",
    "    size_t elemsz;",
    "    int cap, head, count, closed;",
    "    pthread_mutex_t mu;",
    "    pthread_cond_t not_empty;",
    "    pthread_cond_t not_full;",
    "} sl_chan;",
    "",
    "static sl_chan *sl_chan_new(size_t elemsz, int cap) {",
    "    if (cap < 1) cap = 1;",
    "    sl_chan *c = (sl_chan *)GC_malloc(sizeof(sl_chan));",
    "    c->buf = (unsigned char *)GC_malloc(elemsz * (size_t)cap);",
    "    c->elemsz = elemsz;",
    "    c->cap = cap;",
    "    c->head = 0;",
    "    c->count = 0;",
    "    c->closed = 0;",
    "    pthread_mutex_init(&c->mu, NULL);",
    "    pthread_cond_init(&c->not_empty, NULL);",
    "    pthread_cond_init(&c->not_full, NULL);",
    "    return c;",
    "}",
    "",
    "static void sl_chan_send(sl_chan *c, const void *val) {",
    "    pthread_mutex_lock(&c->mu);",
    "    while (c->count == c->cap && !c->closed)",
    "        pthread_cond_wait(&c->not_full, &c->mu);",
    "    if (c->closed) {",
    "        pthread_mutex_unlock(&c->mu);",
    "        sl_rt_error(\"send on closed channel\", 0, 0);",
    "        return;",
    "    }",
    "    int tail = (c->head + c->count) % c->cap;",
    "    memcpy(c->buf + (size_t)tail * c->elemsz, val, c->elemsz);",
    "    c->count++;",
    "    pthread_cond_signal(&c->not_empty);",
    "    pthread_mutex_unlock(&c->mu);",
    "}",
    "",
    "/* returns 1 with *out populated, or 0 if closed and drained empty */",
    "static int sl_chan_recv(sl_chan *c, void *out) {",
    "    pthread_mutex_lock(&c->mu);",
    "    while (c->count == 0 && !c->closed)",
    "        pthread_cond_wait(&c->not_empty, &c->mu);",
    "    if (c->count == 0) {",
    "        pthread_mutex_unlock(&c->mu);",
    "        return 0;",
    "    }",
    "    memcpy(out, c->buf + (size_t)c->head * c->elemsz, c->elemsz);",
    "    c->head = (c->head + 1) % c->cap;",
    "    c->count--;",
    "    pthread_cond_signal(&c->not_full);",
    "    pthread_mutex_unlock(&c->mu);",
    "    return 1;",
    "}",
    "",
    "static void sl_chan_close(sl_chan *c) {",
    "    pthread_mutex_lock(&c->mu);",
    "    c->closed = 1;",
    "    pthread_cond_broadcast(&c->not_empty);",
    "    pthread_cond_broadcast(&c->not_full);",
    "    pthread_mutex_unlock(&c->mu);",
    "}",
    "",
    "/* ---- bytes: length-prefixed, binary-safe sequences ---- */",
    "",
    "typedef struct { long long len; unsigned char *ptr; } sl_bytes;",
    "",
    "static sl_bytes *sl_bytes_new(const unsigned char *p, long long n) {",
    "    sl_bytes *b = (sl_bytes *)GC_malloc(sizeof(sl_bytes));",
    "    b->len = n;",
    "    b->ptr = (unsigned char *)GC_malloc((size_t)(n > 0 ? n : 1));",
    "    if (n > 0) memcpy(b->ptr, p, (size_t)n);",
    "    return b;",
    "}",
    "",
    "static int sl_bytes_at(sl_bytes *b, long long i) {",
    "    if (i < 0 || i >= b->len)",
    "        sl_rt_error(\"byte index out of bounds\", i, b->len);",
    "    return (int)b->ptr[i];",
    "}",
    "",
    "static void sl_bytes_set(sl_bytes *b, long long i, unsigned char v) {",
    "    if (i < 0 || i >= b->len)",
    "        sl_rt_error(\"byte index out of bounds\", i, b->len);",
    "    b->ptr[i] = v;",
    "}",
    "",
    "static sl_bytes *sl_bytes_concat(sl_bytes *a, sl_bytes *b) {",
    "    sl_bytes *r = (sl_bytes *)GC_malloc(sizeof(sl_bytes));",
    "    r->len = a->len + b->len;",
    "    r->ptr = (unsigned char *)GC_malloc((size_t)(r->len > 0 ? r->len : 1));",
    "    if (a->len) memcpy(r->ptr, a->ptr, (size_t)a->len);",
    "    if (b->len) memcpy(r->ptr + a->len, b->ptr, (size_t)b->len);",
    "    return r;",
    "}",
    "",
    "static sl_bytes *sl_bytes_slice(sl_bytes *b, long long s, long long e) {",
    "    if (s < 0) s = 0;",
    "    if (e > b->len) e = b->len;",
    "    if (e < s) e = s;",
    "    sl_bytes *r = (sl_bytes *)GC_malloc(sizeof(sl_bytes));",
    "    r->len = e - s;",
    "    r->ptr = (unsigned char *)GC_malloc((size_t)(r->len > 0 ? r->len : 1));",
    "    if (r->len) memcpy(r->ptr, b->ptr + s, (size_t)r->len);",
    "    return r;",
    "}",
    "",
    "static int sl_bytes_eq(sl_bytes *a, sl_bytes *b) {",
    "    if (a->len != b->len) return 0;",
    "    return a->len == 0 || memcmp(a->ptr, b->ptr, (size_t)a->len) == 0;",
    "}",
    "",
    "static char *sl_str_from_bytes(sl_bytes *b) {",
    "    char *p = (char *)GC_malloc((size_t)b->len + 1);",
    "    if (b->len) memcpy(p, b->ptr, (size_t)b->len);",
    "    p[b->len] = 0;",
    "    return p;",
    "}",
    "",
    "static sl_bytes *sl_bytes_from_str(const char *s) {",
    "    return sl_bytes_new((const unsigned char *)s, (long long)strlen(s));",
    "}",
    "",
    "static sl_bytes *sl_to_le(unsigned long long v) {",
    "    unsigned char buf[8];",
    "    for (int i = 0; i < 8; i++)",
    "        buf[i] = (unsigned char)((v >> (8 * i)) & 0xff);",
    "    return sl_bytes_new(buf, 8);",
    "}",
    "",
    "static sl_bytes *sl_to_be(unsigned long long v) {",
    "    unsigned char buf[8];",
    "    for (int i = 0; i < 8; i++)",
    "        buf[7 - i] = (unsigned char)((v >> (8 * i)) & 0xff);",
    "    return sl_bytes_new(buf, 8);",
    "}",
    "",
    "static unsigned long long sl_from_le(sl_bytes *b) {",
    "    if (b->len != 8)",
    "        sl_rt_error(\"from_le expects exactly 8 bytes\", b->len, 8);",
    "    unsigned long long v = 0;",
    "    for (int i = 7; i >= 0; i--) v = (v << 8) | b->ptr[i];",
    "    return v;",
    "}",
    "",
    "static unsigned long long sl_from_be(sl_bytes *b) {",
    "    if (b->len != 8)",
    "        sl_rt_error(\"from_be expects exactly 8 bytes\", b->len, 8);",
    "    unsigned long long v = 0;",
    "    for (int i = 0; i < 8; i++) v = (v << 8) | b->ptr[i];",
    "    return v;",
    "}",
    "",
    "/* ---- growable arrays over GC memory ---- */",
    "",
    "typedef struct {",
    "    long long len, cap;",
    "    unsigned char *data; /* elements stored inline */",
    "    size_t esz;          /* element size in bytes */",
    "} sl_arr;",
    "",
    "static sl_arr *sl_arr_new(size_t esz) {",
    "    sl_arr *a = (sl_arr *)GC_malloc(sizeof(sl_arr));",
    "    a->len = 0;",
    "    a->cap = 0;",
    "    a->data = NULL;",
    "    a->esz = esz;",
    "    return a;",
    "}",
    "",
    "static void sl_arr_reserve(sl_arr *a, long long need) {",
    "    if (need <= a->cap) return;",
    "    long long cap = a->cap ? a->cap : 8;",
    "    while (cap < need) cap *= 2;",
    "    a->data = (unsigned char *)GC_realloc(a->data, (size_t)cap * a->esz);",
    "    a->cap = cap;",
    "}",
    "",
    "static void *sl_arr_get(sl_arr *a, long long i, size_t esz) {",
    "    if (esz != a->esz)",
    "        sl_rt_error(\"internal: element size mismatch\", (long long)esz,",
    "                    (long long)a->esz);",
    "    if (i < 0 || i >= a->len)",
    "        sl_rt_error(\"list index out of bounds\", i, a->len);",
    "    return a->data + (size_t)i * esz;",
    "}",
    "",
    "static void sl_arr_push(sl_arr *a, void *val, size_t esz) {",
    "    if (esz != a->esz)",
    "        sl_rt_error(\"internal: element size mismatch\", (long long)esz,",
    "                    (long long)a->esz);",
    "    sl_arr_reserve(a, a->len + 1);",
    "    memcpy(a->data + (size_t)a->len * esz, val, esz);",
    "    a->len++;",
    "}",
    "",
    "static void *sl_arr_pop(sl_arr *a, size_t esz) {",
    "    if (esz != a->esz)",
    "        sl_rt_error(\"internal: element size mismatch\", (long long)esz,",
    "                    (long long)a->esz);",
    "    if (a->len == 0) sl_rt_error(\"pop from empty list\", 0, 0);",
    "    a->len--;",
    "    return a->data + (size_t)a->len * esz;",
    "}",
    "",
    "static sl_arr *sl_arr_from(void *buf, long long n, size_t esz) {",
    "    sl_arr *a = sl_arr_new(esz);",
    "    sl_arr_reserve(a, n);",
    "    if (n > 0) memcpy(a->data, buf, (size_t)n * esz);",
    "    a->len = n;",
    "    return a;",
    "}",
    "",
    "static sl_arr *sl_arr_slice(sl_arr *a, long long s, long long e) {",
    "    if (s < 0) s = 0;",
    "    if (e > a->len) e = a->len;",
    "    if (e < s) e = s;",
    "    sl_arr *r = sl_arr_new(a->esz);",
    "    sl_arr_reserve(r, e - s);",
    "    if (e > s)",
    "        memcpy(r->data, a->data + (size_t)s * a->esz,",
    "               (size_t)(e - s) * a->esz);",
    "    r->len = e - s;",
    "    return r;",
    "}",
    "",
    "static sl_arr *sl_arr_concat(sl_arr *a, sl_arr *b) {",
    "    if (a->esz != b->esz)",
    "        sl_rt_error(\"cannot concatenate lists of different element types\",",
    "                    (long long)a->esz, (long long)b->esz);",
    "    sl_arr *r = sl_arr_new(a->esz);",
    "    sl_arr_reserve(r, a->len + b->len);",
    "    if (a->len) memcpy(r->data, a->data, (size_t)a->len * a->esz);",
    "    if (b->len)",
    "        memcpy(r->data + (size_t)a->len * a->esz, b->data,",
    "               (size_t)b->len * b->esz);",
    "    r->len = a->len + b->len;",
    "    return r;",
    "}",
    "",
    "/* ---- maps: open-addressing hash tables over GC memory ---- */",
    "",
    "typedef struct {",
    "    long long count, cap;",
    "    size_t ksz, vsz;",
    "    int kstr;            /* keys are NUL-terminated strings */",
    "    unsigned char *keys; /* cap slots */",
    "    unsigned char *vals; /* cap slots */",
    "    unsigned char *state;/* 1 = occupied */",
    "    long long *order;    /* occupied slot indices, insertion order */",
    "} sl_map;",
    "",
    "static unsigned long long sl_hash_bytes(const unsigned char *p, size_t n) {",
    "    unsigned long long h = 1469598103934665603ULL;",
    "    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }",
    "    return h;",
    "}",
    "",
    "static unsigned long long sl_hash_str(const char *s) {",
    "    unsigned long long h = 1469598103934665603ULL;",
    "    for (; *s; s++) { h ^= (unsigned char)*s; h *= 1099511628211ULL; }",
    "    return h;",
    "}",
    "",
    "static sl_map *sl_map_new(size_t ksz, size_t vsz, int kstr) {",
    "    sl_map *m = (sl_map *)GC_malloc(sizeof(sl_map));",
    "    m->count = 0;",
    "    m->cap = 8;",
    "    m->ksz = ksz;",
    "    m->vsz = vsz;",
    "    m->kstr = kstr;",
    "    m->keys = (unsigned char *)GC_malloc(8 * ksz);",
    "    m->vals = (unsigned char *)GC_malloc(8 * vsz);",
    "    m->state = (unsigned char *)GC_malloc(8);",
    "    memset(m->state, 0, 8);",
    "    m->order = (long long *)GC_malloc(8 * sizeof(long long));",
    "    return m;",
    "}",
    "",
    "/* Probe for a key: returns its slot if present, or -(slot)-1 for",
    " * the first empty slot where it could be inserted. */",
    "static long long sl_map_probe(sl_map *m, const void *k,",
    "                              unsigned long long h) {",
    "    long long mask = m->cap - 1;",
    "    long long i = (long long)(h & (unsigned long long)mask);",
    "    for (;;) {",
    "        if (!m->state[i])",
    "            return -i - 1;",
    "        void *kk = m->keys + (size_t)i * m->ksz;",
    "        int eq = m->kstr",
    "                    ? !strcmp(*(const char **)kk, *(const char *const *)k)",
    "                    : memcmp(kk, k, m->ksz) == 0;",
    "        if (eq)",
    "            return i;",
    "        i = (i + 1) & mask;",
    "    }",
    "}",
    "",
    "static void sl_map_grow(sl_map *m) {",
    "    long long old_cap = m->cap;",
    "    unsigned char *ok = m->keys, *ov = m->vals;",
    "    unsigned char *ost = m->state;",
    "    long long ocount = m->count;",
    "    long long *oorder = m->order;",
    "    m->cap = old_cap * 2;",
    "    m->count = 0;",
    "    m->keys = (unsigned char *)GC_malloc((size_t)m->cap * m->ksz);",
    "    m->vals = (unsigned char *)GC_malloc((size_t)m->cap * m->vsz);",
    "    m->state = (unsigned char *)GC_malloc((size_t)m->cap);",
    "    memset(m->state, 0, (size_t)m->cap);",
    "    m->order = (long long *)GC_malloc((size_t)m->cap * sizeof(long long));",
    "    /* reinsert in insertion order so iteration stays deterministic */",
    "    for (long long i = 0; i < ocount; i++) {",
    "        long long slot = oorder[i];",
    "        void *k = ok + (size_t)slot * m->ksz;",
    "        void *v = ov + (size_t)slot * m->vsz;",
    "        unsigned long long h = m->kstr",
    "                                  ? sl_hash_str(*(const char **)k)",
    "                                  : sl_hash_bytes((const unsigned char *)k,",
    "                                                  m->ksz);",
    "        long long s = -sl_map_probe(m, k, h) - 1;",
    "        memcpy(m->keys + (size_t)s * m->ksz, k, m->ksz);",
    "        memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);",
    "        m->state[s] = 1;",
    "        m->order[m->count++] = s;",
    "    }",
    "}",
    "",
    "static void sl_map_put(sl_map *m, const void *k, const void *v) {",
    "    unsigned long long h = m->kstr",
    "                              ? sl_hash_str(*(const char *const *)k)",
    "                              : sl_hash_bytes((const unsigned char *)k,",
    "                                              m->ksz);",
    "    if ((m->count + 1) * 4 >= m->cap * 3)",
    "        sl_map_grow(m);",
    "    long long s = sl_map_probe(m, k, h);",
    "    if (s >= 0) {",
    "        memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);",
    "        return;",
    "    }",
    "    s = -s - 1;",
    "    memcpy(m->keys + (size_t)s * m->ksz, k, m->ksz);",
    "    memcpy(m->vals + (size_t)s * m->vsz, v, m->vsz);",
    "    m->state[s] = 1;",
    "    m->order[m->count++] = s;",
    "}",
    "",
    "static void *sl_map_get(sl_map *m, const void *k) {",
    "    unsigned long long h = m->kstr",
    "                              ? sl_hash_str(*(const char *const *)k)",
    "                              : sl_hash_bytes((const unsigned char *)k,",
    "                                              m->ksz);",
    "    long long s = sl_map_probe(m, k, h);",
    "    if (s < 0)",
    "        return NULL;",
    "    return m->vals + (size_t)s * m->vsz;",
    "}",
    "",
    "static int sl_map_has(sl_map *m, const void *k) {",
    "    return sl_map_get(m, k) != NULL;",
    "}",
    "",
    "static void sl_map_del(sl_map *m, const void *k) {",
    "    unsigned long long h = m->kstr",
    "                              ? sl_hash_str(*(const char *const *)k)",
    "                              : sl_hash_bytes((const unsigned char *)k,",
    "                                              m->ksz);",
    "    long long s = sl_map_probe(m, k, h);",
    "    if (s < 0)",
    "        return;",
    "    m->state[s] = 0;",
    "    for (long long i = 0; i < m->count; i++) {",
    "        if (m->order[i] == s) {",
    "            memmove(m->order + i, m->order + i + 1,",
    "                    (size_t)(m->count - i - 1) * sizeof(long long));",
    "            break;",
    "        }",
    "    }",
    "    m->count--;",
    "}",
    "",
    "/* ---- strings ---- */",
    "",
    "static char *sl_strdup(const char *s) {",
    "    size_t n = strlen(s) + 1;",
    "    char *p = (char *)GC_malloc(n);",
    "    memcpy(p, s, n);",
    "    return p;",
    "}",
    "",
    "static char *sl_str_concat(const char *a, const char *b) {",
    "    size_t la = strlen(a), lb = strlen(b);",
    "    char *p = (char *)GC_malloc(la + lb + 1);",
    "    memcpy(p, a, la);",
    "    memcpy(p + la, b, lb);",
    "    p[la + lb] = 0;",
    "    return p;",
    "}",
    "",
    "static char *sl_str_from_int(long long v) {",
    "    char buf[32];",
    "    snprintf(buf, sizeof(buf), \"%lld\", v);",
    "    return sl_strdup(buf);",
    "}",
    "",
    "static char *sl_str_from_uint(unsigned long long v) {",
    "    char buf[32];",
    "    snprintf(buf, sizeof(buf), \"%llu\", v);",
    "    return sl_strdup(buf);",
    "}",
    "",
    "static char *sl_str_from_float(double v) {",
    "    char buf[64];",
    "    snprintf(buf, sizeof(buf), \"%g\", v);",
    "    return sl_strdup(buf);",
    "}",
    "",
    "static char *sl_str_from_bool(bool v) {",
    "    return sl_strdup(v ? \"true\" : \"false\");",
    "}",
    "",
    "/* ---- user program ---- */",
    "",
};

static void emit_prelude(CG *cg) {
    for (int i = 0; i < (int)(sizeof(RUNTIME) / sizeof(RUNTIME[0])); i++)
        emit_line(cg, "%s", RUNTIME[i]);
}

/* Register a raw (not yet canonicalized) function signature. */
static void sig_register_raw(CG *cg, Package *p, FuncDecl *f,
                             const char *method_of) {
    if (is_builtin_name(f->name))
        cg_error(f->line, "cannot redefine builtin '%s'", f->name);
    if (sig_find_in(cg, p->name, f->name))
        cg_error(f->line,
                 "redefinition of function '%s' in package '%s'", f->name,
                 p->name);

    FuncSig sig;
    memset(&sig, 0, sizeof(sig));
    sig.name = f->name;
    sig.pkg = p->name;
    sig.is_pub = f->is_pub;
    sig.is_extern = f->is_extern;
    sig.ret_slang = f->ret_type;
    sig.nparams = f->nparams;
    sig.method_of = method_of;
    sig.line = f->line;
    sig.param_slang =
        (const char **)xmalloc(sizeof(char *) *
                               (f->nparams ? f->nparams : 1));
    for (int m = 0; m < f->nparams; m++)
        sig.param_slang[m] = f->param_types[m];

    if (cg->sigs.count == cg->sigs.cap) {
        cg->sigs.cap = cg->sigs.cap ? cg->sigs.cap * 2 : 8;
        cg->sigs.items = (FuncSig *)xrealloc(
            cg->sigs.items, cg->sigs.cap * sizeof(FuncSig));
    }
    cg->sigs.items[cg->sigs.count++] = sig;
}

/* Collect imports, structs, free functions, and methods from every
 * package, then canonicalize all stored type names. */
static void collect_decls(CG *cg, Package *pkgs, int npkgs) {
    int i, j;

    /* imports */
    for (i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (j = 0; j < p->prog->nimports; j++) {
            char *ipath = p->prog->import_paths[j];
            import_push(cg, p->name, path_base(ipath), path_base(ipath));
        }
    }

    /* pass 1: free functions + struct shells */
    for (i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (j = 0; j < p->prog->nfuncs; j++)
            sig_register_raw(cg, p, p->prog->funcs[j], NULL);
        Block *body = p->prog->main_body;
        for (j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_STRUCT)
                continue;
            if (struct_find_in_pkg(cg, p->name, s->as.struct_decl.name))
                cg_error(s->line,
                         "redefinition of struct '%s' in package '%s'",
                         s->as.struct_decl.name, p->name);
            if (cg->structs.count == cg->structs.cap) {
                cg->structs.cap = cg->structs.cap ? cg->structs.cap * 2 : 8;
                cg->structs.items = (StructDef *)xrealloc(
                    cg->structs.items,
                    cg->structs.cap * sizeof(StructDef));
            }
            StructDef *sd = &cg->structs.items[cg->structs.count++];
            sd->canonical =
                xasprintf("%s.%s", p->name, s->as.struct_decl.name);
            sd->pkg = p->name;
            sd->name = s->as.struct_decl.name;
            sd->is_pub = s->as.struct_decl.is_pub;
            sd->fields = s->as.struct_decl.fields;
            sd->ftypes = (const char **)s->as.struct_decl.ftypes;
            sd->nfields = s->as.struct_decl.nfields;
            sd->line = s->line;
        }
    }

    /* pass 2: canonicalize struct field types */
    for (i = 0; i < cg->structs.count; i++) {
        StructDef *sd = &cg->structs.items[i];
        cg->cur_pkg = sd->pkg;
        for (j = 0; j < sd->nfields; j++) {
            for (int q = 0; q < j; q++) {
                if (!strcmp(sd->fields[q], sd->fields[j]))
                    cg_error(sd->line,
                             "duplicate field '%s' in struct '%s'",
                             sd->fields[j], sd->canonical);
            }
            sd->ftypes[j] = canon_type(cg, sd->ftypes[j], sd->line);
        }
    }

    /* pass 3: methods from impl blocks */
    for (i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        Block *body = p->prog->main_body;
        for (j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            StructDef *sd =
                struct_find_in_pkg(cg, p->name, s->as.impl.struct_name);
            if (!sd)
                cg_error(s->line, "impl of unknown struct '%s'",
                         s->as.impl.struct_name);
            for (int q = 0; q < s->as.impl.nfuncs; q++)
                sig_register_raw(cg, p, s->as.impl.funcs[q],
                                 sd->canonical);
        }
    }

    /* pass 4: canonicalize all signatures */
    for (i = 0; i < cg->sigs.count; i++) {
        FuncSig *sig = &cg->sigs.items[i];
        cg->cur_pkg = sig->pkg;
        for (j = 0; j < sig->nparams; j++) {
            ((char **)sig->param_slang)[j] =
                (char *)canon_type(cg, sig->param_slang[j], sig->line);
            if (sig->is_extern)
                check_extern_type(sig->param_slang[j], sig->line,
                                  "parameter");
        }
        if (sig->ret_slang)
            sig->ret_slang = canon_type(cg, sig->ret_slang, sig->line);
        if (sig->is_extern && sig->ret_slang)
            check_extern_type(sig->ret_slang, sig->line, "return");
    }
}

/* Type of a constant-literal initializer, or error. */
static const char *literal_type(CG *cg, Expr *e, int line) {
    (void)cg;
    switch (e->kind) {
    case EX_INT:    return "int";
    case EX_FLOAT:  return "float";
    case EX_STRING: return "str";
    case EX_BYTES:  return "bytes";
    case EX_BOOL:   return "bool";
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "-")) {
            Expr *o = e->as.unary.operand;
            if (o->kind == EX_INT) return "int";
            if (o->kind == EX_FLOAT) return "float";
        }
        break;
    default:
        break;
    }
    cg_error(line,
             "package-level variables must be initialized with constant "
             "literals");
    return NULL; /* unreachable */
}

/* C source text for a constant-literal initializer. */
static char *gen_const_init(Expr *e) {
    switch (e->kind) {
    case EX_INT:
        return xasprintf("%lld", e->as.int_lit.value);
    case EX_FLOAT:
        return gen_float_literal(e->as.float_lit.value);
    case EX_STRING:
        return c_string_literal(e->as.str_lit.value);
    case EX_BOOL:
        return xstrdup(e->as.bool_lit.value ? "true" : "false");
    case EX_UNARY: {
        char *o = gen_const_init(e->as.unary.operand);
        return xasprintf("(-%s)", o);
    }
    default:
        return NULL; /* unreachable: validated by literal_type */
    }
}

/* Emit package-level variables of all imported packages as C globals
 * and register them in the symbol table. */
static void emit_globals(CG *cg, Package *pkgs, int npkgs, int main_index) {
    int any = 0;
    for (int i = 0; i < npkgs; i++) {
        if (i == main_index)
            continue; /* main pkg top-level lets are locals of main() */
        Package *p = &pkgs[i];
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind == ST_STRUCT || s->kind == ST_IMPL)
                continue; /* handled by collect_decls */
            if (s->kind != ST_LET)
                cg_error(s->line,
                         "only 'let' declarations are allowed at top "
                         "level in an imported package");
            const char *t = literal_type(cg, s->as.let.init, s->line);
            if (is_arr(t))
                cg_error(s->line,
                         "package-level lists are not supported yet");
            if (glob_find(cg, p->name, s->as.let.name))
                cg_error(s->line, "duplicate variable '%s' in package '%s'",
                         s->as.let.name, p->name);
            glob_push(cg, s->as.let.name, p->name, t, s->as.let.is_pub);
            if (is_bytes(t)) {
                Expr *init = s->as.let.init;
                char *m = mangle_glob(p->name, s->as.let.name);
                emit_line(cg, "static const unsigned char %s_bdata[] = %s;",
                          m, c_bytes_literal(init->as.bytes_lit.data,
                                             init->as.bytes_lit.len));
                emit_line(cg, "static sl_bytes %s = { %lld, (unsigned char *)%s_bdata };",
                          m, init->as.bytes_lit.len, m);
            } else {
                emit_line(cg, "static %s %s = %s;", map_type(t),
                          mangle_glob(p->name, s->as.let.name),
                          gen_const_init(s->as.let.init));
            }
            any = 1;
        }
    }
    if (any)
        emit_line(cg, "");
}

/* Emit forward declarations and definitions for every struct. */
static void emit_struct_types(CG *cg) {
    if (!cg->structs.count)
        return;
    for (int i = 0; i < cg->structs.count; i++) {
        char *m = mangle_struct(cg->structs.items[i].canonical);
        emit_line(cg, "typedef struct %s %s;", m, m);
    }
    emit_line(cg, "");
    for (int i = 0; i < cg->structs.count; i++) {
        StructDef *sd = &cg->structs.items[i];
        char *m = mangle_struct(sd->canonical);
        emit_line(cg, "struct %s {", m);
        cg->indent++;
        for (int j = 0; j < sd->nfields; j++)
            emit_line(cg, "%s %s;", ctype_of(cg, sd->ftypes[j]),
                      sanitize_ident(sd->fields[j]));
        cg->indent--;
        emit_line(cg, "};");
        emit_line(cg, "");
    }
}

/* Emit C definitions for every monomorphized opt/result instantiation
 * discovered during generation. Emitted after struct types so inner
 * struct types are complete. */
static void emit_opt_res_types(CG *cg) {
    for (int i = 0; i < cg->opts.count; i++) {
        OptInst *o = &cg->opts.items[i];
        emit_line(cg, "typedef struct {");
        cg->indent++;
        emit_line(cg, "bool has;");
        emit_line(cg, "%s v;", ctype_of(cg, o->inner));
        cg->indent--;
        emit_line(cg, "} %s;", o->cname);
        emit_line(cg, "");
    }
    for (int i = 0; i < cg->res.count; i++) {
        ResInst *r = &cg->res.items[i];
        emit_line(cg, "typedef struct {");
        cg->indent++;
        emit_line(cg, "bool ok;");
        emit_line(cg, "%s v;", ctype_of(cg, r->tv));
        emit_line(cg, "%s e;", ctype_of(cg, r->te));
        cg->indent--;
        emit_line(cg, "} %s;", r->cname);
        emit_line(cg, "");
    }
}

/* ---- native 'time' package runtime (emitted on demand) ---- */

static const char *TIME_RUNTIME[] = {
    "#include <time.h>",
    "#include <errno.h>",
    "",
    "/* ---- time: monotonic + wall clock; duration is nanoseconds ---- */",
    "",
    "static long long sl_time_mono(void) {",
    "    struct timespec ts;",
    "    clock_gettime(CLOCK_MONOTONIC, &ts);",
    "    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;",
    "}",
    "",
    "static long long sl_time_wall(void) {",
    "    struct timespec ts;",
    "    clock_gettime(CLOCK_REALTIME, &ts);",
    "    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;",
    "}",
    "",
    "static void sl_time_sleep(long long ns) {",
    "    struct timespec ts;",
    "    ts.tv_sec = (time_t)(ns / 1000000000LL);",
    "    ts.tv_nsec = (long)(ns % 1000000000LL);",
    "    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}",
    "}",
    "",
};

/* ---- native 'net' package runtime (emitted on demand) ----
 * TCP built on bytes + fixed-width ints. Every fallible operation
 * returns result[T, str]; recv reports \"would block\" on a
 * non-blocking socket with no data available. */

static const char *NET_RUNTIME[] = {
    "#include <errno.h>",
    "#include <unistd.h>",
    "#include <fcntl.h>",
    "#include <sys/socket.h>",
    "#include <netinet/in.h>",
    "#include <arpa/inet.h>",
    "#include <netdb.h>",
    "",
    "/* ---- net: blocking & non-blocking TCP over bytes + fixed ints ---- */",
    "",
    "static sl_res_i32_str *sl_net_ok_i32(int32_t v) {",
    "    sl_res_i32_str *r =",
    "        (sl_res_i32_str *)GC_malloc(sizeof(sl_res_i32_str));",
    "    r->ok = true;",
    "    r->v = v;",
    "    return r;",
    "}",
    "",
    "static sl_res_i32_str *sl_net_err_i32(const char *msg) {",
    "    sl_res_i32_str *r =",
    "        (sl_res_i32_str *)GC_malloc(sizeof(sl_res_i32_str));",
    "    r->ok = false;",
    "    r->e = sl_strdup(msg);",
    "    return r;",
    "}",
    "",
    "static sl_res_bytes_str *sl_net_ok_bytes(sl_bytes *b) {",
    "    sl_res_bytes_str *r =",
    "        (sl_res_bytes_str *)GC_malloc(sizeof(sl_res_bytes_str));",
    "    r->ok = true;",
    "    r->v = b;",
    "    return r;",
    "}",
    "",
    "static sl_res_bytes_str *sl_net_err_bytes(const char *msg) {",
    "    sl_res_bytes_str *r =",
    "        (sl_res_bytes_str *)GC_malloc(sizeof(sl_res_bytes_str));",
    "    r->ok = false;",
    "    r->e = sl_strdup(msg);",
    "    return r;",
    "}",
    "",
    "static sl_res_bool_str *sl_net_ok_bool(bool v) {",
    "    sl_res_bool_str *r =",
    "        (sl_res_bool_str *)GC_malloc(sizeof(sl_res_bool_str));",
    "    r->ok = true;",
    "    r->v = v;",
    "    return r;",
    "}",
    "",
    "static sl_res_bool_str *sl_net_err_bool(const char *msg) {",
    "    sl_res_bool_str *r =",
    "        (sl_res_bool_str *)GC_malloc(sizeof(sl_res_bool_str));",
    "    r->ok = false;",
    "    r->e = sl_strdup(msg);",
    "    return r;",
    "}",
    "",
    "static sl_res_i32_str *sl_net_listen(int port) {",
    "    int fd = socket(AF_INET, SOCK_STREAM, 0);",
    "    if (fd < 0) return sl_net_err_i32(strerror(errno));",
    "    int one = 1;",
    "    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));",
    "    struct sockaddr_in addr;",
    "    memset(&addr, 0, sizeof(addr));",
    "    addr.sin_family = AF_INET;",
    "    addr.sin_addr.s_addr = htonl(INADDR_ANY);",
    "    addr.sin_port = htons((uint16_t)port);",
    "    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {",
    "        int e = errno; close(fd); return sl_net_err_i32(strerror(e));",
    "    }",
    "    if (listen(fd, 64) != 0) {",
    "        int e = errno; close(fd); return sl_net_err_i32(strerror(e));",
    "    }",
    "    return sl_net_ok_i32((int32_t)fd);",
    "}",
    "",
    "static sl_res_i32_str *sl_net_port(int lfd) {",
    "    struct sockaddr_in addr;",
    "    socklen_t n = sizeof(addr);",
    "    if (getsockname(lfd, (struct sockaddr *)&addr, &n) != 0)",
    "        return sl_net_err_i32(strerror(errno));",
    "    return sl_net_ok_i32((int32_t)ntohs(addr.sin_port));",
    "}",
    "",
    "static sl_res_i32_str *sl_net_accept(int lfd) {",
    "    int cfd = accept(lfd, NULL, NULL);",
    "    if (cfd < 0) return sl_net_err_i32(strerror(errno));",
    "    return sl_net_ok_i32((int32_t)cfd);",
    "}",
    "",
    "static sl_res_i32_str *sl_net_dial(const char *host, int port) {",
    "    char portstr[16];",
    "    snprintf(portstr, sizeof(portstr), \"%d\", port);",
    "    struct addrinfo hints, *res = NULL;",
    "    memset(&hints, 0, sizeof(hints));",
    "    hints.ai_family = AF_INET;",
    "    hints.ai_socktype = SOCK_STREAM;",
    "    int rc = getaddrinfo(host, portstr, &hints, &res);",
    "    if (rc != 0 || !res) return sl_net_err_i32(gai_strerror(rc));",
    "    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);",
    "    if (fd < 0) { freeaddrinfo(res); return sl_net_err_i32(strerror(errno)); }",
    "    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {",
    "        int e = errno; freeaddrinfo(res); close(fd);",
    "        return sl_net_err_i32(strerror(e));",
    "    }",
    "    freeaddrinfo(res);",
    "    return sl_net_ok_i32((int32_t)fd);",
    "}",
    "",
    "static sl_res_i32_str *sl_net_send(int fd, sl_bytes *data) {",
    "    long long off = 0;",
    "    while (off < data->len) {",
    "        ssize_t n = send(fd, data->ptr + off,",
    "                         (size_t)(data->len - off), 0);",
    "        if (n < 0) {",
    "            if (errno == EINTR) continue;",
    "            return sl_net_err_i32(strerror(errno));",
    "        }",
    "        off += n;",
    "    }",
    "    return sl_net_ok_i32((int32_t)data->len);",
    "}",
    "",
    "static sl_res_bytes_str *sl_net_recv(int fd, int max) {",
    "    if (max <= 0) max = 4096;",
    "    sl_bytes *b = (sl_bytes *)GC_malloc(sizeof(sl_bytes));",
    "    b->len = 0;",
    "    b->ptr = (unsigned char *)GC_malloc((size_t)max);",
    "    ssize_t n = recv(fd, b->ptr, (size_t)max, 0);",
    "    if (n < 0) {",
    "        if (errno == EAGAIN || errno == EWOULDBLOCK)",
    "            return sl_net_err_bytes(\"would block\");",
    "        return sl_net_err_bytes(strerror(errno));",
    "    }",
    "    b->len = (long long)n;",
    "    return sl_net_ok_bytes(b);",
    "}",
    "",
    "static void sl_net_close(int fd) { close(fd); }",
    "",
    "static sl_res_bool_str *sl_net_nonblock(int fd) {",
    "    int fl = fcntl(fd, F_GETFL, 0);",
    "    if (fl < 0) return sl_net_err_bool(strerror(errno));",
    "    if (fcntl(fd, F_SETFL, fl | O_NONBLOCK) != 0)",
    "        return sl_net_err_bool(strerror(errno));",
    "    return sl_net_ok_bool(true);",
    "}",
    "",
};

/* The net runtime above unconditionally builds these three result
 * instantiations (i32/str for handles+ports, bytes/str for recv,
 * bool/str for nonblock) regardless of which net functions the
 * slang program actually calls or how it uses their return values;
 * register them whenever net is imported so their typedefs always
 * exist alongside the runtime code that references them. */
static void force_native_result_types(CG *cg) {
    int want_net = 0;
    for (int i = 0; i < cg->imports.count; i++) {
        const char *t = cg->imports.items[i].target;
        if (!strcmp(t, "net") && is_native_pkg(cg, t))
            want_net = 1;
    }
    if (!want_net)
        return;
    res_cname(cg, "i32", "str");
    res_cname(cg, "bytes", "str");
    res_cname(cg, "bool", "str");
}

/* Emit the native-package runtime sections that this program needs,
 * based on which native packages were imported. Must run after
 * emit_opt_res_types so the fixed net result instantiations exist. */
static void emit_native_runtime(CG *cg) {
    int want_time = 0, want_net = 0;
    for (int i = 0; i < cg->imports.count; i++) {
        const char *t = cg->imports.items[i].target;
        if (!strcmp(t, "time") && is_native_pkg(cg, t))
            want_time = 1;
        if (!strcmp(t, "net") && is_native_pkg(cg, t))
            want_net = 1;
    }
    if (!want_time && !want_net)
        return;
    if (want_time)
        for (int i = 0;
             i < (int)(sizeof(TIME_RUNTIME) / sizeof(TIME_RUNTIME[0]));
             i++)
            emit_line(cg, "%s", TIME_RUNTIME[i]);
    if (want_net)
        for (int i = 0;
             i < (int)(sizeof(NET_RUNTIME) / sizeof(NET_RUNTIME[0])); i++)
            emit_line(cg, "%s", NET_RUNTIME[i]);
}

/* Emit the args-struct + pthread trampoline for every distinct
 * 'spawn' target discovered while generating. Must run before any
 * function body that spawns one references it by name. */
static void emit_spawn_trampolines(CG *cg) {
    for (int i = 0; i < cg->spawns.count; i++) {
        SpawnShape *s = &cg->spawns.items[i];
        FuncSig *sig = sig_find_in(cg, s->pkg, s->name);
        char *callee = sig->is_extern ? xstrdup(sig->name)
                                      : mangle_func(sig->pkg, sig->name);

        emit_line(cg, "typedef struct {");
        cg->indent++;
        if (sig->nparams == 0) {
            emit_line(cg, "char _unused;");
        } else {
            for (int j = 0; j < sig->nparams; j++)
                emit_line(cg, "%s a%d;", ctype_of(cg, sig->param_slang[j]),
                          j);
        }
        cg->indent--;
        emit_line(cg, "} %s;", s->sname);
        emit_line(cg, "");

        emit_line(cg, "static void *%s(void *_sl_raw) {", s->tname);
        cg->indent++;
        if (sig->nparams == 0) {
            emit_line(cg, "(void)_sl_raw;");
            emit_line(cg, "%s();", callee);
        } else {
            emit_line(cg, "%s *_sl_a = (%s *)_sl_raw;", s->sname, s->sname);
            StrBuf args;
            sb_init(&args);
            for (int j = 0; j < sig->nparams; j++) {
                if (j)
                    sb_append(&args, ", ");
                sb_append(&args, xasprintf("_sl_a->a%d", j));
            }
            emit_line(cg, "%s(%s);", callee, args.data);
        }
        emit_line(cg, "return NULL;");
        cg->indent--;
        emit_line(cg, "}");
        emit_line(cg, "");
    }
}

static void gen_prototypes(CG *cg, Package *pkgs, int npkgs) {
    int any = 0;
    for (int i = 0; i < npkgs; i++) {
        Program *prog = pkgs[i].prog;

        /* free functions */
        for (int j = 0; j < prog->nfuncs; j++) {
            FuncDecl *f = prog->funcs[j];
            FuncSig *sig = sig_find_in(cg, pkgs[i].name, f->name);
            StrBuf params;
            sb_init(&params);
            if (f->is_extern) {
                /* no body defined here, so the real symbol just needs
                 * a matching prototype for the C compiler + linker;
                 * parameter names are irrelevant in a prototype */
                if (sig->nparams == 0) {
                    sb_append(&params, "void");
                } else {
                    for (int m = 0; m < sig->nparams; m++) {
                        if (m)
                            sb_append(&params, ", ");
                        sb_append(&params, ctype_of(cg, sig->param_slang[m]));
                    }
                }
                emit_line(cg, "extern %s %s(%s);",
                          sig->ret_slang ? ctype_of(cg, sig->ret_slang)
                                         : "void",
                          f->name, params.data);
                any = 1;
                continue;
            }
            if (f->nparams == 0) {
                sb_append(&params, "void");
            } else {
                for (int m = 0; m < f->nparams; m++) {
                    if (m)
                        sb_append(&params, ", ");
                    sb_append(&params, ctype_of(cg, sig->param_slang[m]));
                    sb_putc(&params, ' ');
                    sb_append(&params, sanitize_ident(f->params[m]));
                }
            }
            emit_line(cg, "static %s %s(%s);",
                      sig->ret_slang ? ctype_of(cg, sig->ret_slang)
                                     : "void",
                      mangle_func(pkgs[i].name, f->name), params.data);
            any = 1;
        }

        /* methods from impl blocks */
        Block *body = prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++) {
                FuncDecl *f = s->as.impl.funcs[q];
                FuncSig *sig = sig_find_in(cg, pkgs[i].name, f->name);
                StrBuf params;
                sb_init(&params);
                if (f->nparams == 0) {
                    sb_append(&params, "void");
                } else {
                    for (int m = 0; m < f->nparams; m++) {
                        if (m)
                            sb_append(&params, ", ");
                        sb_append(&params,
                                  ctype_of(cg, sig->param_slang[m]));
                        sb_putc(&params, ' ');
                        sb_append(&params, sanitize_ident(f->params[m]));
                    }
                }
                emit_line(cg, "static %s %s(%s);",
                          sig->ret_slang ? ctype_of(cg, sig->ret_slang)
                                         : "void",
                          mangle_func(pkgs[i].name, f->name), params.data);
                any = 1;
            }
        }
    }
    if (any)
        emit_line(cg, "");
}

static void gen_function(CG *cg, Package *p, FuncDecl *f) {
    FuncSig *sig = sig_find_in(cg, p->name, f->name);

    cg->vars.count = 0; /* fresh scope per function */
    cg->in_function = 1;
    cg->cur_ret = sig->ret_slang;
    cg->cur_pkg = p->name;

    for (int j = 0; j < f->nparams; j++)
        var_push(cg, f->params[j], sig->param_slang[j]);

    StrBuf params;
    sb_init(&params);
    if (f->nparams == 0) {
        sb_append(&params, "void");
    } else {
        for (int j = 0; j < f->nparams; j++) {
            if (j)
                sb_append(&params, ", ");
            sb_append(&params, ctype_of(cg, sig->param_slang[j]));
            sb_putc(&params, ' ');
            sb_append(&params, sanitize_ident(f->params[j]));
        }
    }

    emit_line(cg, "static %s %s(%s) {",
              sig->ret_slang ? ctype_of(cg, sig->ret_slang) : "void",
              mangle_func(p->name, f->name), params.data);
    gen_block(cg, f->body);
    emit_line(cg, "}");
    emit_line(cg, "");

    cg->in_function = 0;
    cg->cur_ret = NULL;
}

/* Generate the complete translation unit into cg->out. */
static void gen_whole_program(CG *cg, Package *pkgs, int npkgs,
                              int main_index) {
    emit_prelude(cg);

    emit_struct_types(cg);

    force_native_result_types(cg);
    emit_opt_res_types(cg);

    emit_native_runtime(cg);

    emit_globals(cg, pkgs, npkgs, main_index);

    gen_prototypes(cg, pkgs, npkgs);

    emit_spawn_trampolines(cg);

    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (int j = 0; j < p->prog->nfuncs; j++) {
            if (p->prog->funcs[j]->is_extern)
                continue; /* declared only; no body to emit */
            gen_function(cg, p, p->prog->funcs[j]);
        }
        /* methods from impl blocks */
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++)
                gen_function(cg, p, s->as.impl.funcs[q]);
        }
    }

    /* top-level statements of the main package become main() */
    cg->vars.count = 0;
    cg->cur_pkg = pkgs[main_index].name;
    emit_line(cg, "int main(void) {");
    emit_line(cg, "    GC_INIT();");
    emit_line(cg, "    sl_rt_is_main_thread = 1;");
    gen_block(cg, pkgs[main_index].prog->main_body);
    emit_line(cg, "    return 0;");
    emit_line(cg, "}");
}

void codegen_program(Package *pkgs, int npkgs, int main_index,
                     StrBuf *out) {
    CG cg;
    memset(&cg, 0, sizeof(CG));
    cg.out = out;
    cg.cur_pkg = pkgs[main_index].name;

    /* record which packages are compiler-provided natives */
    for (int i = 0; i < npkgs; i++) {
        if (!pkgs[i].native)
            continue;
        cg.nat_pkgs = (char **)xrealloc(
            cg.nat_pkgs, (size_t)(cg.nnat + 1) * sizeof(char *));
        cg.nat_pkgs[cg.nnat++] = pkgs[i].name;
    }

    collect_decls(&cg, pkgs, npkgs);

    /* Dry run: generation populates the opt/result monomorphization
     * tables as it goes, but typedefs must be emitted before any use.
     * Generate once into a scratch buffer to discover every
     * instantiation, then generate for real with complete tables. */
    StrBuf scratch;
    sb_init(&scratch);
    cg.out = &scratch;
    gen_whole_program(&cg, pkgs, npkgs, main_index);
    free(scratch.data);

    /* emit_globals (called from gen_whole_program) registers package
     * globals as it emits them; undo that bookkeeping before the real
     * run re-emits and re-registers the same globals, or it trips its
     * own duplicate-declaration check. opts/res are deliberately left
     * to accumulate across both passes (that's the point of the dry
     * run); globs has no such purpose here. */
    cg.globs.count = 0;

    out->len = 0;
    out->data[0] = '\0';
    cg.out = out;
    gen_whole_program(&cg, pkgs, npkgs, main_index);
}
