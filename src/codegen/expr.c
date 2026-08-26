/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"

#include <string.h>

char *gen_ident_name(CG *cg, const char *name, int line) {
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

char *gen_float_literal(double v) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", v);
    if (!strpbrk(buf, ".eE"))
        strcat(buf, ".0");
    return xstrdup(buf);
}

/* Convert any scalar/bytes value to a slang str (C string). */
char *conv_to_str(const char *t, char *expr) {
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

char *gen_string_concat(CG *cg, Expr *e, const char *lt,
                               const char *rt) {
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    char *ca = conv_to_str(lt, a);
    char *cb = conv_to_str(rt, b);
    /* lhs/rhs would otherwise be embedded directly as sl_str_concat's
     * two arguments, whose relative evaluation order C leaves
     * unspecified -- sequence them into named temps first (Tier 10's
     * liveness pass assumes left-to-right; this is what makes that
     * true of the generated C). */
    StrBuf prelude;
    sb_init(&prelude);
    char *texts[2] = {ca, cb};
    const char *ctypes[2] = {ctype_of(cg, "str"), ctype_of(cg, "str")};
    char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
    return xasprintf("({ %ssl_str_concat(%s, %s); })", prelude.data,
                     names[0], names[1]);
}

char *gen_numeric_binary(CG *cg, Expr *e, const char *result_t) {
    const char *op = e->as.binary.op;
    const char *lt = infer_type(cg, e->as.binary.lhs);
    const char *rt = infer_type(cg, e->as.binary.rhs);
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    a = maybe_cast(cg, result_t, lt, a);
    b = maybe_cast(cg, result_t, rt, b);

    StrBuf prelude;
    sb_init(&prelude);
    char *texts[2] = {a, b};
    const char *rc = ctype_of(cg, result_t);
    const char *ctypes[2] = {rc, rc};
    char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
    a = names[0];
    b = names[1];

    /* Integer '/' and '%' by zero trap the CPU (SIGFPE) rather than
     * raising a catchable error; guard explicitly so it becomes an
     * ordinary runtime error like an out-of-bounds index instead of
     * an uncatchable signal (which would defeat per-task failure
     * isolation once a task can crash the whole process anyway). */
    if ((!strcmp(op, "/") || !strcmp(op, "%")) && is_int(result_t)) {
        int id = cg->tmp_id++;
        return xasprintf(
            "({ %s%s _sl_dv%d = (%s); if (_sl_dv%d == 0) "
            "sl_rt_error(\"division by zero\", 0, 0); "
            "(%s)((%s) %s _sl_dv%d); })",
            prelude.data, map_type(result_t), id, b, id, map_type(result_t),
            a, op, id);
    }
    /* Cast the result back to the slang result type: C's integer
     * promotions would otherwise widen narrow types to int and lose
     * the documented wrap-on-overflow semantics. */
    return xasprintf("({ %s((%s)((%s) %s (%s))); })", prelude.data,
                     map_type(result_t), a, op, b);
}

char *gen_comparison(CG *cg, Expr *e, const char *lt, const char *rt) {
    const char *op = e->as.binary.op;
    char *a = gen_expr(cg, e->as.binary.lhs);
    char *b = gen_expr(cg, e->as.binary.rhs);
    if (!(is_str(lt) && is_str(rt)) && !(is_bytes(lt) && is_bytes(rt))) {
        /* mixed-width numerics: widen both to the common type */
        const char *pt = promote(lt, rt);
        a = maybe_cast(cg, pt, lt, a);
        b = maybe_cast(cg, pt, rt, b);
    }
    StrBuf prelude;
    sb_init(&prelude);
    const char *ct = is_str(lt) && is_str(rt)     ? ctype_of(cg, "str")
                     : is_bytes(lt) && is_bytes(rt) ? ctype_of(cg, "bytes")
                                                    : ctype_of(cg, promote(lt, rt));
    char *texts[2] = {a, b};
    const char *ctypes[2] = {ct, ct};
    char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
    a = names[0];
    b = names[1];
    if (is_str(lt) && is_str(rt))
        return xasprintf("({ %s(strcmp(%s, %s) %s 0); })", prelude.data, a,
                         b, op);
    if (is_bytes(lt) && is_bytes(rt)) {
        if (!strcmp(op, "=="))
            return xasprintf("({ %s(sl_bytes_eq(%s, %s)); })", prelude.data,
                             a, b);
        return xasprintf("({ %s(!sl_bytes_eq(%s, %s)); })", prelude.data, a,
                         b);
    }
    return xasprintf("({ %s(%s %s %s); })", prelude.data, a, op, b);
}

char *gen_builtin_call(CG *cg, Expr *e, int *handled) {
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
char *gen_ctor(CG *cg, Expr *e) {
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

char *gen_call(CG *cg, Expr *e) {
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
            if (!strcmp(pkg, "json") && is_native_pkg(cg, pkg))
                return json_call_gen(cg, right, e);
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

    int argi = 0;
    if (selfexpr) {
        selfexpr = maybe_cast(cg, sig->param_slang[0], recv_t, selfexpr);
        argi = 1;
    }
    /* Explicit arguments would otherwise be embedded directly as
     * sibling call arguments, whose relative evaluation order C
     * leaves unspecified -- sequence them first (the primary Risk 1
     * case: foo(bar(), baz())). selfexpr is never sequenced alongside
     * them: a method receiver is always a plain identifier in this
     * language (never a call/allocation of its own), so it has no
     * ordering hazard to guard against. */
    int nargs = e->as.call.nargs;
    char **texts = (char **)xmalloc(sizeof(char *) * (size_t)(nargs > 0 ? nargs : 1));
    const char **ctypes =
        (const char **)xmalloc(sizeof(char *) * (size_t)(nargs > 0 ? nargs : 1));
    for (int i = 0; i < nargs; i++) {
        const char *saved = expect_push(cg, sig->param_slang[argi + i]);
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        cg->expect = saved;
        texts[i] = maybe_cast(cg, sig->param_slang[argi + i], at, a);
        ctypes[i] = ctype_of(cg, sig->param_slang[argi + i]);
    }
    StrBuf prelude;
    sb_init(&prelude);
    char **names = sequence_exprs(cg, texts, ctypes, nargs, &prelude);

    StrBuf sb;
    sb_init(&sb);
    char *mangled = sig->is_extern ? xstrdup(sig->name)
                                   : mangle_func(sig->pkg, sig->name);
    sb_append(&sb, mangled);
    sb_putc(&sb, '(');
    if (selfexpr) {
        sb_append(&sb, selfexpr);
    }
    for (int i = 0; i < nargs; i++) {
        if (i || argi)
            sb_append(&sb, ", ");
        sb_append(&sb, names[i]);
    }
    sb_putc(&sb, ')');
    if (prelude.len == 0)
        return sb.data;
    return xasprintf("({ %s%s; })", prelude.data, sb.data);
}

/* Generate a map literal. With expect_k/expect_v (annotated case),
 * elements are checked/cast against those types instead of inferred. */
char *gen_maplit(CG *cg, Expr *e, const char *expect_k,
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

char *gen_structlit(CG *cg, Expr *e) {
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
        const char *saved = expect_push(cg, sd->ftypes[fi]);
        const char *vt = infer_type(cg, e->as.structlit.vals[j]);
        char *v = gen_expr(cg, e->as.structlit.vals[j]);
        cg->expect = saved;
        v = maybe_cast(cg, sd->ftypes[fi], vt, v);
        sb_append(&sb,
                  xasprintf("_sl_s->%s = %s; ",
                            sanitize_ident(sd->fields[fi]), v));
    }
    sb_append(&sb, "_sl_s; })");
    return sb.data;
}

char *gen_index(CG *cg, Expr *e) {
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
    /* bytes/array reads: base and index would otherwise be embedded
     * directly as sibling call arguments, whose relative evaluation
     * order C leaves unspecified -- sequence them first (see
     * sequence_exprs; the map case above is already safe, it already
     * sequences base/index via separate statements). */
    if (is_bytes(bt)) {
        StrBuf prelude;
        sb_init(&prelude);
        char *texts[2] = {b, i};
        const char *ctypes[2] = {ctype_of(cg, "bytes"), map_type("int")};
        char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
        return xasprintf("({ %s((long long)sl_bytes_at(%s, %s)); })",
                         prelude.data, names[0], names[1]);
    }
    char *elem = arr_elem(bt);
    const char *ec = ctype_of(cg, elem);
    StrBuf prelude;
    sb_init(&prelude);
    char *texts[2] = {b, i};
    const char *ctypes[2] = {ctype_of(cg, bt), map_type("int")};
    char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
    return xasprintf(
        "({ %s(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s))); })",
        prelude.data, ec, names[0], names[1], ec);
}

char *gen_slice(CG *cg, Expr *e) {
    const char *bt = infer_type(cg, e->as.slice.base);
    char *b = gen_expr(cg, e->as.slice.base);
    char *start = e->as.slice.start ? gen_expr(cg, e->as.slice.start)
                                    : xstrdup("0");
    int id = cg->tmp_id++;
    /* base is already safely sequenced into its own statement below;
     * start/end (when both given) would otherwise be embedded
     * directly as sibling call arguments -- sequence them the same
     * way as gen_index above. */
    if (is_bytes(bt)) {
        char *end = e->as.slice.end
                        ? gen_expr(cg, e->as.slice.end)
                        : xasprintf("_sl_b%d->len", id);
        if (e->as.slice.inclusive)
            end = xasprintf("(%s + 1)", end);
        StrBuf prelude;
        sb_init(&prelude);
        char *texts[2] = {start, end};
        const char *ctypes[2] = {map_type("int"), map_type("int")};
        char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
        return xasprintf(
            "({ sl_bytes *_sl_b%d = %s; %ssl_bytes_slice(_sl_b%d, %s, %s); })",
            id, b, prelude.data, id, names[0], names[1]);
    }
    char *end =
        e->as.slice.end ? gen_expr(cg, e->as.slice.end)
                        : xasprintf("_sl_a%d->len", id);
    if (e->as.slice.inclusive)
        end = xasprintf("(%s + 1)", end);
    StrBuf prelude;
    sb_init(&prelude);
    char *texts[2] = {start, end};
    const char *ctypes[2] = {map_type("int"), map_type("int")};
    char **names = sequence_exprs(cg, texts, ctypes, 2, &prelude);
    return xasprintf(
        "({ sl_arr *_sl_a%d = %s; %ssl_arr_slice(_sl_a%d, %s, %s); })", id,
        b, prelude.data, id, names[0], names[1]);
}

char *gen_list(CG *cg, Expr *e, const char *expect_elem) {
    const char *t0 =
        expect_elem ? expect_elem : infer_type(cg, e->as.list.elems[0]);
    const char *ec = ctype_of(cg, t0);
    int n = e->as.list.nelems;
    /* elements would otherwise be embedded directly in one aggregate
     * initializer ({el0, el1, ...}), whose relative evaluation order
     * C leaves unspecified -- sequence them first, same as every
     * other multi-child site in this file. */
    char **texts = (char **)xmalloc(sizeof(char *) * (size_t)(n > 0 ? n : 1));
    const char **ctypes =
        (const char **)xmalloc(sizeof(char *) * (size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) {
        const char *ti = infer_type(cg, e->as.list.elems[i]);
        char *el = gen_expr(cg, e->as.list.elems[i]);
        texts[i] = maybe_cast(cg, t0, ti, el);
        ctypes[i] = ec;
    }
    StrBuf prelude;
    sb_init(&prelude);
    char **names = sequence_exprs(cg, texts, ctypes, n, &prelude);

    StrBuf sb;
    sb_init(&sb);
    sb_append(&sb, "({ ");
    sb_append(&sb, prelude.data);
    sb_append(&sb, ec);
    sb_append(&sb, " _sl_e[] = {");
    for (int i = 0; i < n; i++) {
        if (i)
            sb_append(&sb, ", ");
        sb_append(&sb, names[i]);
    }
    sb_append(&sb, "}; sl_arr_from(_sl_e, ");
    sb_append(&sb, xasprintf("%d", e->as.list.nelems));
    sb_append(&sb, ", sizeof(");
    sb_append(&sb, ec);
    sb_append(&sb, ")); })");
    return sb.data;
}

char *gen_expr(CG *cg, Expr *e) {
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

void gen_print(CG *cg, Expr *call, int newline) {
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

