#include "common.h"
#include "ast.h"
#include "codegen.h"

#include <ctype.h>
#include <stdarg.h>

/* The two-character C escape sequence backslash + 'n', built from char
 * codes so it survives any source preprocessing. */
static const char C_NL[3] = {92, 'n', 0};

/* A double-quote character as a NUL-terminated string, built from a
 * char code so no source-level escaping is needed. */
static const char Q[2] = {34, 0};

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
        case 10:  sb_append_n(&sb, C_NL, 2); break;
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
/* Types                                                               */
/* ------------------------------------------------------------------ */

static const char *map_type(const char *slang_type) {
    if (!strcmp(slang_type, "int")) return "long long";
    if (!strcmp(slang_type, "float")) return "double";
    if (!strcmp(slang_type, "str")) return "const char *";
    if (!strcmp(slang_type, "bool")) return "bool";
    return NULL;
}

static int is_ll(const char *t) { return !strcmp(t, "long long"); }
static int is_dbl(const char *t) { return !strcmp(t, "double"); }
static int is_num(const char *t) { return is_ll(t) || is_dbl(t); }
static int is_str(const char *t) { return !strcmp(t, "const char *"); }

/* Can a value of type `src` be assigned/returned/passed where `dst`
 * is expected? int widens to double implicitly. */
static int can_assign(const char *dst, const char *src) {
    if (!strcmp(dst, src))
        return 1;
    if (is_num(dst) && is_num(src))
        return is_dbl(dst); /* only widening int -> double */
    return 0;
}

static char *maybe_cast(const char *dst, const char *src, char *expr) {
    if (is_dbl(dst) && is_ll(src))
        return xasprintf("(double)(%s)", expr);
    return expr;
}

/* ------------------------------------------------------------------ */
/* Symbol tables                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    char *name;
    const char *ctype;
} VarSym;

typedef struct {
    VarSym *items;
    int count;
    int cap;
} VarTable;

typedef struct {
    char *name;
    char *pkg;             /* owning package name */
    const char *ret_ctype; /* NULL => void */
    const char **param_ctypes;
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
    char *owner; /* package containing the import statement */
    char *alias; /* binding name (base name of the import path) */
    char *target;/* imported package name */
} ImportBind;

typedef struct {
    ImportBind *items;
    int count;
    int cap;
} ImportTable;

/* Package-level variable ('pub let' / top-level let in an imported
 * package). */
typedef struct {
    char *name;
    char *pkg;
    const char *ctype;
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
    VarTable vars;       /* locals of the current function */
    SigTable sigs;       /* all functions across all packages */
    GlobTable globs;     /* package-level variables */
    ImportTable imports; /* all import bindings, resolved per owner pkg */
    const char *cur_ret;  /* return type of enclosing function, NULL=void */
    const char *cur_pkg;  /* package whose scope we are generating into */
    int in_function;
    int tmp_id;
} CG;

static void var_push(CG *cg, const char *name, const char *ctype) {
    if (cg->vars.count == cg->vars.cap) {
        cg->vars.cap = cg->vars.cap ? cg->vars.cap * 2 : 16;
        cg->vars.items =
            (VarSym *)xrealloc(cg->vars.items, cg->vars.cap * sizeof(VarSym));
    }
    cg->vars.items[cg->vars.count].name = (char *)name;
    cg->vars.items[cg->vars.count].ctype = ctype;
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
                      const char *ctype, int is_pub) {
    if (cg->globs.count == cg->globs.cap) {
        cg->globs.cap = cg->globs.cap ? cg->globs.cap * 2 : 16;
        cg->globs.items = (GlobSym *)xrealloc(
            cg->globs.items, cg->globs.cap * sizeof(GlobSym));
    }
    cg->globs.items[cg->globs.count].name = (char *)name;
    cg->globs.items[cg->globs.count].pkg = (char *)pkg;
    cg->globs.items[cg->globs.count].ctype = ctype;
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

/* Resolve an alias like "geometry" to its target package name within
 * the current package's imports. */
static const char *import_target(CG *cg, const char *alias, int line) {
    for (int i = 0; i < cg->imports.count; i++) {
        ImportBind *b = &cg->imports.items[i];
        if (!strcmp(b->owner, cg->cur_pkg) && !strcmp(b->alias, alias))
            return b->target;
    }
    cg_error(line, "'%s' is not an imported package", alias);
    return NULL; /* unreachable */
}

/* Split "pkg.member" into two parts. Returns 0 if there is no dot. */
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

/* Make a package name safe for use inside a C identifier. */
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

/* Base name of a path: "a/b/c" -> "c" */
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

static const char *infer_call(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    if (!strcmp(name, "print") || !strcmp(name, "println")) {
        if (e->as.call.nargs != 1)
            cg_error(e->line, "%s() takes exactly one argument", name);
        infer_type(cg, e->as.call.args[0]);
        return "void";
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
    if (e->as.call.nargs != sig->nparams)
        cg_error(e->line,
                 "function '%s' expects %d argument(s), got %d", name,
                 sig->nparams, e->as.call.nargs);
    for (int i = 0; i < sig->nparams; i++) {
        const char *at = infer_type(cg, e->as.call.args[i]);
        if (!can_assign(sig->param_ctypes[i], at))
            cg_error(e->line,
                     "argument %d of '%s': cannot pass %s where %s expected",
                     i + 1, name, at, sig->param_ctypes[i]);
    }
    return sig->ret_ctype ? sig->ret_ctype : "void";
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
        if ((is_num(lt) && is_num(rt)) || (is_str(lt) && is_str(rt)))
            return "bool";
        cg_error(e->line, "cannot compare %s and %s", lt, rt);
    }
    if (!strcmp(op, "+")) {
        if (is_str(lt) || is_str(rt)) {
            const char *other = is_str(lt) ? rt : lt;
            if (!(is_str(other) || is_num(other) || !strcmp(other, "bool")))
                cg_error(e->line,
                         "cannot concatenate %s onto a string with '+'",
                         other);
            return "const char *";
        }
        if (is_num(lt) && is_num(rt))
            return (is_dbl(lt) || is_dbl(rt)) ? "double" : "long long";
        cg_error(e->line, "unsupported operand types for '+': %s and %s",
                 lt, rt);
    }
    if (!strcmp(op, "-") || !strcmp(op, "*") || !strcmp(op, "/")) {
        if (is_num(lt) && is_num(rt))
            return (is_dbl(lt) || is_dbl(rt)) ? "double" : "long long";
        cg_error(e->line, "unsupported operand types for '%s': %s and %s",
                 op, lt, rt);
    }
    if (!strcmp(op, "%")) {
        if (is_ll(lt) && is_ll(rt))
            return "long long";
        cg_error(e->line, "'%%' requires integer operands (got %s and %s)",
                 lt, rt);
    }
    cg_error(e->line, "unknown operator '%s'", op);
    return NULL; /* unreachable */
}

static const char *infer_type(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_INT:    return "long long";
    case EX_FLOAT:  return "double";
    case EX_STRING: return "const char *";
    case EX_BOOL:   return "bool";
    case EX_IDENT: {
        VarSym *v = var_find(cg, e->as.ident.name);
        if (v)
            return v->ctype;
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
            return g->ctype;
        }
        GlobSym *g = glob_find(cg, cg->cur_pkg, e->as.ident.name);
        if (g)
            return g->ctype;
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
    }
    return NULL; /* unreachable */
}

/* ------------------------------------------------------------------ */
/* Expression code generation                                          */
/* ------------------------------------------------------------------ */

static const char *conv_fn_for(const char *t);

static char *gen_expr(CG *cg, Expr *e);

static char *gen_float_literal(double v) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    if (!strpbrk(buf, ".eE"))
        strcat(buf, ".0");
    return xstrdup(buf);
}

static char *gen_string_concat(CG *cg, Expr *e, const char *lt,
                               const char *rt) {
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    const char *conv_l = is_str(lt) ? "" : conv_fn_for(lt);
    const char *conv_r = is_str(rt) ? "" : conv_fn_for(rt);
    return xasprintf("sl_str_concat(%s%s, %s%s)", conv_l, a, conv_r, b);
}

static const char *conv_fn_for(const char *t) {
    if (is_ll(t)) return "sl_str_from_int(";
    if (is_dbl(t)) return "sl_str_from_float(";
    if (!strcmp(t, "bool")) return "sl_str_from_bool(";
    return "";
}

/* Wrap conversion helper calls that were opened by conv_fn_for. */
static char *close_conv(char *expr, const char *lt, const char *rt) {
    int need_close = (!is_str(lt) ? 1 : 0) + (!is_str(rt) ? 1 : 0);
    while (need_close-- > 0)
        expr = xasprintf("%s)", expr);
    return expr;
}

static char *gen_numeric_binary(CG *cg, Expr *e, const char *result_t) {
    const char *op = e->as.binary.op;
    const char *lt = infer_type(cg, e->as.binary.lhs);
    const char *rt = infer_type(cg, e->as.binary.rhs);
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    a = maybe_cast(result_t, lt, a);
    b = maybe_cast(result_t, rt, b);
    return xasprintf("(%s %s %s)", a, op, b);
}

static char *gen_comparison(CG *cg, Expr *e, const char *lt, const char *rt) {
    const char *op = e->as.binary.op;
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    if (is_str(lt) && is_str(rt))
        return xasprintf("(strcmp(%s, %s) %s 0)", a, b, op);
    return xasprintf("(%s %s %s)", a, op, b);
}

static char *gen_call(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    if (!strcmp(name, "print") || !strcmp(name, "println"))
        cg_error(e->line,
                 "%s() is a statement and cannot be used inside an "
                 "expression",
                 name);

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
        a = maybe_cast(sig->param_ctypes[i], at, a);
        sb_append(&sb, a);
    }
    sb_putc(&sb, ')');
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
        return xasprintf("(%s%s)", e->as.unary.op, o);
    }
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
        if (!strcmp(op, "+") && (is_str(lt) || is_str(rt))) {
            char *r = gen_string_concat(cg, e, lt, rt);
            return close_conv(r, lt, rt);
        }
        if (!strcmp(op, "+") || !strcmp(op, "-") || !strcmp(op, "*") ||
            !strcmp(op, "/")) {
            const char *res =
                (is_dbl(lt) || is_dbl(rt)) ? "double" : "long long";
            return gen_numeric_binary(cg, e, res);
        }
        /* '%' */
        return gen_numeric_binary(cg, e, "long long");
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
    if (is_ll(t)) {
        emit_line(cg, "printf(%s%%lld%s%s, %s);", Q, newline ? C_NL : "",
                  Q, v);
    } else if (is_dbl(t)) {
        emit_line(cg, "printf(%s%%g%s%s, %s);", Q, newline ? C_NL : "",
                  Q, v);
    } else if (!strcmp(t, "bool")) {
        if (newline)
            emit_line(cg, "puts((%s) ? %strue%s : %sfalse%s);", v, Q, Q,
                      Q, Q);
        else
            emit_line(cg, "fputs((%s) ? %strue%s : %sfalse%s, stdout);",
                      v, Q, Q, Q, Q);
    } else { /* string */
        if (newline)
            emit_line(cg, "puts(%s);", v);
        else
            emit_line(cg, "fputs(%s, stdout);", v);
    }
}

static void gen_stmt(CG *cg, Stmt *s) {
    switch (s->kind) {
    case ST_LET: {
        const char *t = infer_type(cg, s->as.let.init);
        char *init = gen_expr(cg, s->as.let.init);
        var_push(cg, s->as.let.name, t);
        emit_line(cg, "%s %s = %s;", t, sanitize_ident(s->as.let.name),
                  init);
        break;
    }
    case ST_ASSIGN: {
        VarSym *v = var_find(cg, s->as.assign.name);
        if (!v)
            cg_error(s->line, "undefined variable '%s'", s->as.assign.name);
        const char *vt = infer_type(cg, s->as.assign.value);
        if (!can_assign(v->ctype, vt))
            cg_error(s->line,
                     "cannot assign a value of type %s to variable '%s' "
                     "of type %s",
                     vt, s->as.assign.name, v->ctype);
        char *val = maybe_cast(v->ctype, vt, gen_expr(cg, s->as.assign.value));
        emit_line(cg, "%s = %s;", sanitize_ident(s->as.assign.name), val);
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
        if (!is_ll(st) || !is_ll(et))
            cg_error(s->line,
                     "range bounds must be integers (got %s and %s)", st,
                     et);
        var_push(cg, s->as.for_stmt.name, "long long");
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
            if (!can_assign(cg->cur_ret, vt))
                cg_error(s->line,
                         "return type mismatch: cannot return %s where %s "
                         "expected",
                         vt, cg->cur_ret);
            char *val =
                maybe_cast(cg->cur_ret, vt, gen_expr(cg, s->as.ret.value));
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

/* Emit the runtime prelude: includes plus small helper functions that
 * are embedded into every generated program. Lines that contain quote
 * characters are composed with Q to avoid source-level escaping. */
static void emit_prelude(CG *cg) {
    emit_line(cg, "#include <stdio.h>");
    emit_line(cg, "#include <stdlib.h>");
    emit_line(cg, "#include <string.h>");
    emit_line(cg, "#include <stdbool.h>");
    emit_line(cg, "#include <gc.h>");
    emit_line(cg, "");
    emit_line(cg, "/* ---- slang runtime ---- */");
    emit_line(cg, "");
    emit_line(cg, "static char *sl_strdup(const char *s) {");
    emit_line(cg, "    size_t n = strlen(s) + 1;");
    emit_line(cg, "    char *p = (char *)GC_malloc(n);");
    emit_line(cg, "    memcpy(p, s, n);");
    emit_line(cg, "    return p;");
    emit_line(cg, "}");
    emit_line(cg, "");
    emit_line(cg, "static char *sl_str_concat(const char *a, const char *b) {");
    emit_line(cg, "    size_t la = strlen(a), lb = strlen(b);");
    emit_line(cg, "    char *p = (char *)GC_malloc(la + lb + 1);");
    emit_line(cg, "    memcpy(p, a, la);");
    emit_line(cg, "    memcpy(p + la, b, lb);");
    emit_line(cg, "    p[la + lb] = 0;");
    emit_line(cg, "    return p;");
    emit_line(cg, "}");
    emit_line(cg, "");
    emit_line(cg, "static char *sl_str_from_int(long long v) {");
    emit_line(cg, "    char buf[32];");
    emit_line(cg, "    snprintf(buf, sizeof(buf), %s%%lld%s, v);", Q, Q);
    emit_line(cg, "    return sl_strdup(buf);");
    emit_line(cg, "}");
    emit_line(cg, "");
    emit_line(cg, "static char *sl_str_from_float(double v) {");
    emit_line(cg, "    char buf[64];");
    emit_line(cg, "    snprintf(buf, sizeof(buf), %s%%g%s, v);", Q, Q);
    emit_line(cg, "    return sl_strdup(buf);");
    emit_line(cg, "}");
    emit_line(cg, "");
    emit_line(cg, "static char *sl_str_from_bool(bool v) {");
    emit_line(cg, "    return sl_strdup(v ? %strue%s : %sfalse%s);", Q, Q,
              Q, Q);
    emit_line(cg, "}");
    emit_line(cg, "");
    emit_line(cg, "/* ---- user program ---- */");
    emit_line(cg, "");
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
            if (!strcmp(f->name, "print") || !strcmp(f->name, "println"))
                cg_error(f->line, "cannot redefine builtin '%s'", f->name);
            if (sig_find_in(cg, p->name, f->name))
                cg_error(f->line, "redefinition of function '%s' in "
                                  "package '%s'",
                         f->name, p->name);

            FuncSig sig;
            sig.name = f->name;
            sig.pkg = p->name;
            sig.is_pub = f->is_pub;
            sig.ret_ctype = f->ret_type ? map_type(f->ret_type) : NULL;
            sig.nparams = f->nparams;
            sig.param_ctypes =
                (const char **)xmalloc(sizeof(char *) *
                                       (f->nparams ? f->nparams : 1));
            for (int m = 0; m < f->nparams; m++)
                sig.param_ctypes[m] = map_type(f->param_types[m]);

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
    case EX_INT:    return "long long";
    case EX_FLOAT:  return "double";
    case EX_STRING: return "const char *";
    case EX_BOOL:   return "bool";
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "-")) {
            Expr *o = e->as.unary.operand;
            if (o->kind == EX_INT) return "long long";
            if (o->kind == EX_FLOAT) return "double";
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

static const char *zero_default(const char *t) {
    if (!strcmp(t, "bool"))
        return "false";
    if (is_str(t))
        return ""; /* empty C string literal */
    return "0";
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
            const char *t =
                s->as.let.init
                    ? literal_type(cg, s->as.let.init, s->line)
                    : NULL;
            if (glob_find(cg, p->name, s->as.let.name))
                cg_error(s->line, "duplicate variable '%s' in package '%s'",
                         s->as.let.name, p->name);
            glob_push(cg, s->as.let.name, p->name, t, s->as.let.is_pub);
            emit_line(cg, "static %s %s = %s;", t ? t : "long long",
                      mangle_glob(p->name, s->as.let.name),
                      t ? gen_const_init(s->as.let.init)
                        : zero_default(t ? t : "long long"));
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
                    sb_append(&params, sig->param_ctypes[m]);
                    sb_putc(&params, ' ');
                    sb_append(&params, sanitize_ident(f->params[m]));
                }
            }
            emit_line(cg, "static %s %s(%s);",
                      sig->ret_ctype ? sig->ret_ctype : "void",
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
    cg->cur_ret = sig->ret_ctype;
    cg->cur_pkg = p->name;

    for (int j = 0; j < f->nparams; j++)
        var_push(cg, f->params[j], sig->param_ctypes[j]);

    StrBuf params;
    sb_init(&params);
    if (f->nparams == 0) {
        sb_append(&params, "void");
    } else {
        for (int j = 0; j < f->nparams; j++) {
            if (j)
                sb_append(&params, ", ");
            sb_append(&params, sig->param_ctypes[j]);
            sb_putc(&params, ' ');
            sb_append(&params, sanitize_ident(f->params[j]));
        }
    }

    emit_line(cg, "static %s %s(%s) {",
              sig->ret_ctype ? sig->ret_ctype : "void",
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
