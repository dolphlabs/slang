/* What is particular to the 'math' package (sigs.c has the table and the
 * reasons it is native): the one type parameter its NA_NUM arguments
 * share, the C name a call resolves to, its constants, and which of its
 * functions report a domain error at the caller's line. */

#include "../internal.h"

/* An integer or float literal, or one negated: `5`, `-1`, `2.5`. Its type
 * is whatever the other arguments are, when they have one, so
 * math.clamp(x, 0, 10) on a u8 is a u8 and not an int. */
static int math_literal(Expr *a, int *is_float, long long *iv) {
    int neg = 0;
    if (a->kind == EX_UNARY && !strcmp(a->as.unary.op, "-")) {
        neg = 1;
        a = a->as.unary.operand;
    }
    if (a->kind == EX_INT && !a->as.int_lit.enum_ty && !a->as.int_lit.big_u64) {
        *is_float = 0;
        *iv = neg ? -a->as.int_lit.value : a->as.int_lit.value;
        return 1;
    }
    if (a->kind == EX_FLOAT) {
        *is_float = 1;
        return 1;
    }
    return 0;
}

static int int_lit_fits(long long v, const char *t) {
    if (!strcmp(t, "i8")) return v >= -128 && v <= 127;
    if (!strcmp(t, "i16")) return v >= -32768 && v <= 32767;
    if (!strcmp(t, "i32")) return v >= -2147483648LL && v <= 2147483647LL;
    if (!strcmp(t, "u8")) return v >= 0 && v <= 255;
    if (!strcmp(t, "u16")) return v >= 0 && v <= 65535;
    if (!strcmp(t, "u32")) return v >= 0 && v <= 4294967295LL;
    if (!strcmp(t, "u64")) return v >= 0;
    return 1; /* int, i64, and the floats */
}

static int is_num_kind(NatArgKind k) {
    return k == NA_NUM || k == NA_NUM_INT || k == NA_NUM_FLT;
}

/* T for a call of `ns`: the promotion (core.c's, as for `a + b`) of its
 * NA_NUM arguments that are not literals, or of all of them when every
 * one is. NULL when the function has no NA_NUM argument. */
const char *math_type_of_args(const NatSig *ns, Expr **args,
                              const char *const *argt, int line) {
    int fam_int = 0, fam_flt = 0, any = 0;
    for (int i = 0; i < ns->nargs; i++) {
        if (!is_num_kind(ns->argkinds[i]))
            continue;
        any = 1;
        fam_int |= ns->argkinds[i] == NA_NUM_INT;
        fam_flt |= ns->argkinds[i] == NA_NUM_FLT;
    }
    if (!any)
        return NULL;
    const char *t = NULL;     /* from the non-literal arguments */
    const char *lit_t = NULL; /* from the literals */
    int saw_float_lit = 0;
    for (int i = 0; i < ns->nargs; i++) {
        if (!is_num_kind(ns->argkinds[i]))
            continue;
        int lf;
        long long iv;
        if (math_literal(args[i], &lf, &iv)) {
            saw_float_lit |= lf;
            lit_t = lit_t ? promote(lit_t, argt[i]) : argt[i];
        } else {
            t = t ? promote(t, argt[i]) : argt[i];
        }
    }
    if (!t)
        t = lit_t;
    else if (saw_float_lit && is_int(t))
        t = "float"; /* math.min(n, 0.5): a float literal makes it float */
    if (fam_int && is_flt(t))
        cg_error(line, "math.%s takes integers (got %s)", ns->name, t);
    if (fam_flt && is_int(t))
        t = "float";
    /* Every integer literal must be a value of T. */
    for (int i = 0; i < ns->nargs; i++) {
        int lf;
        long long iv;
        if (is_num_kind(ns->argkinds[i]) && math_literal(args[i], &lf, &iv) &&
            !lf && !int_lit_fits(iv, t))
            cg_error(line, "math.%s argument %d: %lld does not fit in %s",
                     ns->name, i + 1, iv, t);
    }
    return t;
}

/* ns->ret with T for each '@': "@" -> "i32", "opt[@]" -> "opt[i32]". */
const char *math_ret_type(const NatSig *ns, const char *t) {
    if (!ns->ret || !strchr(ns->ret, '@'))
        return ns->ret;
    StrBuf sb;
    sb_init(&sb);
    for (const char *p = ns->ret; *p; p++) {
        if (*p == '@')
            sb_append(&sb, t);
        else
            sb_append_n(&sb, p, 1);
    }
    return sb.data;
}

/* The runtime's name for T (runtime/sl_math.c instantiates every
 * function once per suffix). `int` is long long and i64 is int64_t, which
 * are different C types on Linux, so they keep separate names. */
const char *math_suffix(const char *t) {
    return !strcmp(t, "float") ? "f64" : t;
}

/* Functions whose domain error panics. They get the call's pkg.func:line
 * as a last C argument, as `/` reports a division by zero. */
int math_takes_at(const char *name) {
    static const char *const at[] = {
        "div_floor", "div_ceil", "div_euclid", "rem_euclid",
        "isqrt", "align_up", "align_down",
    };
    for (size_t i = 0; i < sizeof(at) / sizeof(at[0]); i++)
        if (!strcmp(name, at[i]))
            return 1;
    return 0;
}

const MathConst *math_const_find(const char *name) {
    for (int i = 0; i < MATH_CONSTS_LEN; i++)
        if (!strcmp(MATH_CONSTS[i].name, name))
            return &MATH_CONSTS[i];
    return NULL;
}
