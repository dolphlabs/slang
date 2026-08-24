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

static char *xasprintf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    char *buf = (char *)xmalloc((size_t)n + 1);
    vsnprintf(buf, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    return buf;
}

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
    if (t[0] == '[')          return "sl_arr *";
    return NULL;
}

static int is_int(const char *t) {
    return !strcmp(t, "int") || !strcmp(t, "i8") || !strcmp(t, "i16") ||
           !strcmp(t, "i32") || !strcmp(t, "i64") || !strcmp(t, "u8") ||
           !strcmp(t, "u16") || !strcmp(t, "u32") || !strcmp(t, "u64");
}

static int is_signed_int(const char *t) {
    return !strcmp(t, "int") || !strcmp(t, "i8") || !strcmp(t, "i16") ||
           !strcmp(t, "i32") || !strcmp(t, "i64");
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
static int is_arr(const char *t) { return t[0] == '['; }

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

/* Insert a C cast when the slang types differ (compatibility is
 * guaranteed by value_assignable/can_assign upstream). */
static char *maybe_cast(const char *dst, const char *src, char *expr) {
    if (!strcmp(dst, src))
        return expr;
    return xasprintf("(%s)(%s)", map_type(dst), expr);
}

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

typedef struct {
    StrBuf *out;
    int indent;
    VarTable vars;
    SigTable sigs;
    GlobTable globs;
    ImportTable imports;
    const char *cur_ret;  /* slang return type of enclosing function */
    const char *cur_pkg;
    int in_function;
    int tmp_id;
} CG;

static void var_push(CG *cg, const char *name, const char *slang) {
    if (cg->vars.count == cg->vars.cap) {
        cg->vars.cap = cg->vars.cap ? cg->vars.cap * 2 : 16;
        cg->vars.items =
            (VarSym *)xrealloc(cg->vars.items, cg->vars.cap * sizeof(VarSym));
    }
    cg->vars.items[cg->vars.count].name = (char *)name;
    cg->vars.items[cg->vars.count].slang = slang;
    cg->vars.items[cg->vars.count].ctype = map_type(slang);
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

static const char *import_target(CG *cg, const char *alias, int line) {
    for (int i = 0; i < cg->imports.count; i++) {
        ImportBind *b = &cg->imports.items[i];
        if (!strcmp(b->owner, cg->cur_pkg) && !strcmp(b->alias, alias))
            return b->target;
    }
    cg_error(line, "'%s' is not an imported package", alias);
    return NULL; /* unreachable */
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
           !strcmp(name, "from_be");
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
        if (is_str(t) || is_bytes(t) || is_arr(t))
            return "int";
        cg_error(e->line, "len() expects a str, bytes, or [T] (got %s)", t);
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

    FuncSig *sig;
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_target(cg, left, e->line);
        sig = sig_find_in(cg, pkg, right);
        if (!sig)
            cg_error(e->line, "package '%s' has no function '%s'", pkg,
                     right);
        if (!sig->is_pub)
            cg_error(e->line,
                     "function '%s' is not exported from package '%s' "
                     "(add 'pub' to export it)",
                     right, pkg);
    } else {
        sig = sig_find_in(cg, cg->cur_pkg, name);
        if (!sig)
            cg_error(e->line, "call to undefined function '%s'", name);
    }
    if (n != sig->nparams)
        cg_error(e->line,
                 "function '%s' expects %d argument(s), got %d", name,
                 sig->nparams, n);
    for (int i = 0; i < sig->nparams; i++) {
        const char *at = infer_type(cg, e->as.call.args[i]);
        if (!value_assignable(sig->param_slang[i], e->as.call.args[i], at))
            cg_error(e->line,
                     "argument %d of '%s': cannot pass %s where %s expected",
                     i + 1, name, at, sig->param_slang[i]);
    }
    return sig->ret_slang ? sig->ret_slang : "void";
}

static const char *infer_binary(CG *cg, Expr *e) {
    const char *op = e->as.binary.op;
    const char *lt = infer_type(cg, e->as.binary.lhs);
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
    case EX_IDENT: {
        VarSym *v = var_find(cg, e->as.ident.name);
        if (v)
            return v->slang;
        char *left, *right;
        if (split_dotted(e->as.ident.name, &left, &right)) {
            const char *pkg = import_target(cg, left, e->line);
            GlobSym *g = glob_find(cg, pkg, right);
            if (!g)
                cg_error(e->line,
                         "package '%s' has no variable '%s'", pkg, right);
            if (!g->is_pub)
                cg_error(e->line,
                         "variable '%s' is not exported from package '%s' "
                         "(add 'pub' to export it)",
                         right, pkg);
            return g->slang;
        }
        GlobSym *g = glob_find(cg, cg->cur_pkg, e->as.ident.name);
        if (g)
            return g->slang;
        cg_error(e->line, "undefined variable '%s'", e->as.ident.name);
    }
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
    }
    return NULL; /* unreachable */
}

/* ------------------------------------------------------------------ */
/* Expression code generation                                          */
/* ------------------------------------------------------------------ */

static char *gen_expr(CG *cg, Expr *e);

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
    a = maybe_cast(result_t, lt, a);
    b = maybe_cast(result_t, rt, b);
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
    a = maybe_cast(pt, lt, a);
    b = maybe_cast(pt, rt, b);
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
        return xasprintf("((%s)->len)", a);
    }
    if (!strcmp(name, "push")) {
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *elem = arr_elem(at);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        char *xs = gen_expr(cg, e->as.call.args[0]);
        char *v = gen_expr(cg, e->as.call.args[1]);
        v = maybe_cast(elem, vt, v);
        const char *ec = map_type(elem);
        return xasprintf(
            "({ %s _sl_v = %s; sl_arr *_sl_a = %s; sl_arr_push(_sl_a, "
            "&_sl_v, sizeof(%s)); _sl_a; })",
            ec, v, xs, ec);
    }
    if (!strcmp(name, "pop")) {
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *elem = arr_elem(at);
        char *xs = gen_expr(cg, e->as.call.args[0]);
        const char *ec = map_type(elem);
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
    *handled = 0;
    return NULL;
}

static char *gen_call(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    if (!strcmp(name, "print") || !strcmp(name, "println"))
        cg_error(e->line,
                 "%s() is a statement and cannot be used inside an "
                 "expression",
                 name);

    int handled = 0;
    if (is_builtin_name(name)) {
        char *r = gen_builtin_call(cg, e, &handled);
        if (handled)
            return r;
    }

    FuncSig *sig;
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_target(cg, left, e->line);
        sig = sig_find_in(cg, pkg, right);
        if (!sig)
            cg_error(e->line, "package '%s' has no function '%s'", pkg,
                     right);
        if (!sig->is_pub)
            cg_error(e->line,
                     "function '%s' is not exported from package '%s'",
                     right, pkg);
    } else {
        sig = sig_find_in(cg, cg->cur_pkg, name);
        if (!sig)
            cg_error(e->line, "call to undefined function '%s'", name);
    }

    StrBuf sb;
    sb_init(&sb);
    char *mangled = mangle_func(sig->pkg, sig->name);
    sb_append(&sb, mangled);
    sb_putc(&sb, '(');
    for (int i = 0; i < e->as.call.nargs; i++) {
        if (i)
            sb_append(&sb, ", ");
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        a = maybe_cast(sig->param_slang[i], at, a);
        sb_append(&sb, a);
    }
    sb_putc(&sb, ')');
    return sb.data;
}

static char *gen_index(CG *cg, Expr *e) {
    const char *bt = infer_type(cg, e->as.index.base);
    char *b = gen_expr(cg, e->as.index.base);
    char *i = gen_expr(cg, e->as.index.index);
    if (is_bytes(bt))
        return xasprintf("((long long)sl_bytes_at(%s, %s))", b, i);
    char *elem = arr_elem(bt);
    return xasprintf("(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s)))",
                     map_type(elem), b, i, map_type(elem));
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
    const char *ec = map_type(t0);
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
        el = maybe_cast(t0, ti, el);
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
    case EX_IDENT: {
        const char *name = e->as.ident.name;
        char *left, *right;
        if (split_dotted(name, &left, &right)) {
            const char *pkg = import_target(cg, left, e->line);
            GlobSym *g = glob_find(cg, pkg, right);
            if (!g || !g->is_pub)
                cg_error(e->line,
                         "variable '%s' is not accessible from package "
                         "'%s'",
                         right, pkg);
            return mangle_glob(g->pkg, g->name);
        }
        GlobSym *g = glob_find(cg, cg->cur_pkg, name);
        if (g)
            return mangle_glob(g->pkg, g->name);
        return sanitize_ident(name);
    }
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
    case EX_BINARY: {
        const char *op = e->as.binary.op;
        const char *lt = infer_type(cg, e->as.binary.lhs);
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
        if (ann && !map_type(ann))
            cg_error(s->line, "unknown type '%s' in annotation", ann);

        /* empty list literal: requires an annotation */
        if (s->as.let.init->kind == EX_LIST &&
            s->as.let.init->as.list.nelems == 0) {
            if (!ann || !is_arr(ann))
                cg_error(s->line,
                         "cannot infer the element type of an empty list; "
                         "annotate it, e.g. let xs: [int] = []");
            char *elem = arr_elem(ann);
            var_push(cg, s->as.let.name, ann);
            emit_line(cg, "%s %s = sl_arr_new(sizeof(%s));", map_type(ann),
                      sanitize_ident(s->as.let.name), map_type(elem));
            break;
        }

        const char *it = infer_type(cg, s->as.let.init);
        const char *t = ann ? ann : it;
        /* Annotated list literal: check elements against the declared
         * element type instead of the inferred one. */
        int ann_list = ann && is_arr(ann) &&
                       s->as.let.init->kind == EX_LIST;
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
        else
            init = gen_expr(cg, s->as.let.init);
        init = maybe_cast(t, it, init);
        var_push(cg, s->as.let.name, t);
        emit_line(cg, "%s %s = %s;", map_type(t),
                  sanitize_ident(s->as.let.name), init);
        break;
    }
    case ST_ASSIGN: {
        Expr *tgt = s->as.assign.target;
        if (tgt->kind == EX_IDENT) {
            VarSym *v = var_find(cg, tgt->as.ident.name);
            if (!v)
                cg_error(s->line, "undefined variable '%s'",
                         tgt->as.ident.name);
            const char *vt = infer_type(cg, s->as.assign.value);
            if (!value_assignable(v->slang, s->as.assign.value, vt))
                cg_error(s->line,
                         "cannot assign a value of type %s to variable "
                         "'%s' of type %s",
                         vt, tgt->as.ident.name, v->slang);
            char *val =
                maybe_cast(v->slang, vt, gen_expr(cg, s->as.assign.value));
            emit_line(cg, "%s = %s;", sanitize_ident(tgt->as.ident.name),
                      val);
            break;
        }
        /* index target: xs[i] = v or b[i] = v */
        const char *bt = infer_type(cg, tgt->as.index.base);
        const char *vt = infer_type(cg, s->as.assign.value);
        char *b = gen_expr(cg, tgt->as.index.base);
        char *i = gen_expr(cg, tgt->as.index.index);
        char *val = gen_expr(cg, s->as.assign.value);
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
            val = maybe_cast(elem, vt, val);
            const char *ec = map_type(elem);
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
            const char *ec = map_type(elem);
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
            const char *vt = infer_type(cg, s->as.ret.value);
            if (!value_assignable(cg->cur_ret, s->as.ret.value, vt))
                cg_error(s->line,
                         "return type mismatch: cannot return %s where %s "
                         "expected",
                         vt, cg->cur_ret);
            char *val = maybe_cast(cg->cur_ret, vt,
                                   gen_expr(cg, s->as.ret.value));
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
        char *code = gen_expr(cg, e);
        emit_line(cg, "%s;", code);
        break;
    }
    }
}

static void gen_block(CG *cg, Block *b) {
    cg->indent++;
    for (int i = 0; i < b->count; i++)
        gen_stmt(cg, b->stmts[i]);
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
    "#include <gc.h>",
    "",
    "/* ---- slang runtime ---- */",
    "",
    "static void sl_rt_error(const char *msg, long long a, long long b) {",
    "    fprintf(stderr, \"slang runtime error: %s (index %lld, length %lld)\\n\",",
    "            msg, a, b);",
    "    exit(1);",
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

/* Collect function signatures and import bindings from every package. */
static void collect_decls(CG *cg, Package *pkgs, int npkgs) {
    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];

        for (int k = 0; k < p->prog->nimports; k++) {
            char *ipath = p->prog->import_paths[k];
            import_push(cg, p->name, path_base(ipath), path_base(ipath));
        }

        for (int j = 0; j < p->prog->nfuncs; j++) {
            FuncDecl *f = p->prog->funcs[j];
            if (is_builtin_name(f->name))
                cg_error(f->line, "cannot redefine builtin '%s'", f->name);
            if (sig_find_in(cg, p->name, f->name))
                cg_error(f->line, "redefinition of function '%s' in "
                                  "package '%s'",
                         f->name, p->name);
            if (f->ret_type && !map_type(f->ret_type))
                cg_error(f->line, "unknown return type '%s'", f->ret_type);

            FuncSig sig;
            sig.name = f->name;
            sig.pkg = p->name;
            sig.is_pub = f->is_pub;
            sig.ret_slang = f->ret_type;
            sig.nparams = f->nparams;
            sig.param_slang =
                (const char **)xmalloc(sizeof(char *) *
                                       (f->nparams ? f->nparams : 1));
            for (int m = 0; m < f->nparams; m++) {
                if (!map_type(f->param_types[m]))
                    cg_error(f->line, "unknown parameter type '%s'",
                             f->param_types[m]);
                sig.param_slang[m] = f->param_types[m];
            }

            if (cg->sigs.count == cg->sigs.cap) {
                cg->sigs.cap = cg->sigs.cap ? cg->sigs.cap * 2 : 8;
                cg->sigs.items = (FuncSig *)xrealloc(
                    cg->sigs.items, cg->sigs.cap * sizeof(FuncSig));
            }
            cg->sigs.items[cg->sigs.count++] = sig;
        }
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

static void gen_prototypes(CG *cg, Package *pkgs, int npkgs) {
    int any = 0;
    for (int i = 0; i < npkgs; i++) {
        Program *prog = pkgs[i].prog;
        for (int j = 0; j < prog->nfuncs; j++) {
            FuncDecl *f = prog->funcs[j];
            FuncSig *sig = sig_find_in(cg, pkgs[i].name, f->name);
            StrBuf params;
            sb_init(&params);
            if (f->nparams == 0) {
                sb_append(&params, "void");
            } else {
                for (int m = 0; m < f->nparams; m++) {
                    if (m)
                        sb_append(&params, ", ");
                    sb_append(&params, map_type(sig->param_slang[m]));
                    sb_putc(&params, ' ');
                    sb_append(&params, sanitize_ident(f->params[m]));
                }
            }
            emit_line(cg, "static %s %s(%s);",
                      sig->ret_slang ? map_type(sig->ret_slang) : "void",
                      mangle_func(pkgs[i].name, f->name), params.data);
            any = 1;
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
            sb_append(&params, map_type(sig->param_slang[j]));
            sb_putc(&params, ' ');
            sb_append(&params, sanitize_ident(f->params[j]));
        }
    }

    emit_line(cg, "static %s %s(%s) {",
              sig->ret_slang ? map_type(sig->ret_slang) : "void",
              mangle_func(p->name, f->name), params.data);
    gen_block(cg, f->body);
    emit_line(cg, "}");
    emit_line(cg, "");

    cg->in_function = 0;
    cg->cur_ret = NULL;
}

void codegen_program(Package *pkgs, int npkgs, int main_index,
                     StrBuf *out) {
    CG cg;
    memset(&cg, 0, sizeof(CG));
    cg.out = out;
    cg.cur_pkg = pkgs[main_index].name;

    collect_decls(&cg, pkgs, npkgs);

    emit_prelude(&cg);

    emit_globals(&cg, pkgs, npkgs, main_index);

    gen_prototypes(&cg, pkgs, npkgs);

    for (int i = 0; i < npkgs; i++)
        for (int j = 0; j < pkgs[i].prog->nfuncs; j++)
            gen_function(&cg, &pkgs[i], pkgs[i].prog->funcs[j]);

    /* top-level statements of the main package become main() */
    cg.vars.count = 0;
    cg.cur_pkg = pkgs[main_index].name;
    emit_line(&cg, "int main(void) {");
    emit_line(&cg, "    GC_INIT();");
    gen_block(&cg, pkgs[main_index].prog->main_body);
    emit_line(&cg, "    return 0;");
    emit_line(&cg, "}");
}