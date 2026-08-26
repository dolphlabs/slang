/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"
#include "liveness.h"

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
    /* lhs/rhs would otherwise be embedded directly as sl_str_concat's
     * two arguments, whose relative evaluation order C leaves
     * unspecified -- sequence them into named temps (Tier 10's
     * liveness pass assumes left-to-right; this is what makes that
     * true of the generated C). Generated and sequenced one at a
     * time, not both-then-sequence: if rhs is itself a nested call
     * needing lhs's value protected across its own execution (Tier
     * 10's pending-value tracking), lhs's temp has to already exist
     * by the time rhs is generated (see gen_call's own comment on
     * this exact ordering requirement). */
    const char *sc = ctype_of(cg, "str");
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = cg->tmp_id++;
    int ambient_mark = cg->ambient_count;
    char *a = conv_to_str(lt, gen_expr(cg, e->as.binary.lhs));
    a = sequence_one(cg, seq_id, 0, sc, "str", a, e->as.binary.lhs, &prelude);
    char *b = conv_to_str(rt, gen_expr(cg, e->as.binary.rhs));
    b = sequence_one(cg, seq_id, 1, sc, "str", b, e->as.binary.rhs, &prelude);
    cg->ambient_count = ambient_mark;
    return xasprintf("({ %ssl_str_concat(%s, %s); })", prelude.data, a, b);
}

char *gen_numeric_binary(CG *cg, Expr *e, const char *result_t) {
    const char *op = e->as.binary.op;
    const char *lt = infer_type(cg, e->as.binary.lhs);
    const char *rt = infer_type(cg, e->as.binary.rhs);
    const char *rc = ctype_of(cg, result_t);
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = cg->tmp_id++;
    int ambient_mark = cg->ambient_count;
    char *a = maybe_cast(cg, result_t, lt, gen_expr(cg, e->as.binary.lhs));
    a = sequence_one(cg, seq_id, 0, rc, result_t, a, e->as.binary.lhs,
                     &prelude);
    char *b = maybe_cast(cg, result_t, rt, gen_expr(cg, e->as.binary.rhs));
    b = sequence_one(cg, seq_id, 1, rc, result_t, b, e->as.binary.rhs,
                     &prelude);
    cg->ambient_count = ambient_mark;

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
    int widen = !(is_str(lt) && is_str(rt)) && !(is_bytes(lt) && is_bytes(rt));
    const char *pt = widen ? promote(lt, rt) : NULL;
    const char *seq_t = is_str(lt) && is_str(rt)     ? "str"
                        : is_bytes(lt) && is_bytes(rt) ? "bytes"
                                                       : pt;
    const char *ct = ctype_of(cg, seq_t);
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = cg->tmp_id++;
    int ambient_mark = cg->ambient_count;
    char *a = gen_expr(cg, e->as.binary.lhs);
    if (widen)
        a = maybe_cast(cg, pt, lt, a);
    a = sequence_one(cg, seq_id, 0, ct, seq_t, a, e->as.binary.lhs, &prelude);
    char *b = gen_expr(cg, e->as.binary.rhs);
    if (widen)
        b = maybe_cast(cg, pt, rt, b);
    b = sequence_one(cg, seq_id, 1, ct, seq_t, b, e->as.binary.rhs, &prelude);
    cg->ambient_count = ambient_mark;
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

/* Tier 10: every builtin allocates (or could -- e.g. push growing the
 * backing array) except a handful of pure reads (len, bytes_ptr,
 * chan_close's own memcpy-free implementation, ...); rather than
 * auditing each runtime helper's own allocation behavior, every
 * branch below uniformly wraps its result with wrap_safepoint (its
 * own NULL-result_ctype path already produces a valid void statement-
 * expression, so the void-returning builtins -- chan_send, chan_close,
 * exit, del -- need no special-casing beyond computing NULL for
 * result_ctype). push/chan_send/has/del are the only 2-argument
 * builtins (the other ~10 take exactly one, so have no sibling to
 * protect against) and get the same incremental sequence_one
 * treatment gen_call's own arguments do -- generate, cast, sequence,
 * one at a time -- which also closes a Risk 1 gap these 4 sites never
 * went through the original sequencing fix for (their 2 arguments
 * were embedded directly as sibling call arguments to the runtime
 * helper, unspecified evaluation order). */
char *gen_builtin_call(CG *cg, Expr *e, int *handled) {
    const char *name = e->as.call.name;
    *handled = 1;

    if (!strcmp(name, "len")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner;
        if (is_str(t))
            inner = xasprintf("((long long)strlen(%s))", a);
        else if (is_map(t))
            inner = xasprintf("((%s)->count)", a);
        else
            inner = xasprintf("((%s)->len)", a);
        return wrap_safepoint(cg, e, ctype_of(cg, "int"), NULL, inner);
    }
    if (!strcmp(name, "push")) {
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *elem = arr_elem(at);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        StrBuf prelude;
        sb_init(&prelude);
        int seq_id = cg->tmp_id++;
        int ambient_mark = cg->ambient_count;
        char *xs = gen_expr(cg, e->as.call.args[0]);
        xs = sequence_one(cg, seq_id, 0, ctype_of(cg, at), at, xs,
                          e->as.call.args[0], &prelude);
        char *v = maybe_cast(cg, elem, vt, gen_expr(cg, e->as.call.args[1]));
        v = sequence_one(cg, seq_id, 1, ctype_of(cg, elem), elem, v,
                         e->as.call.args[1], &prelude);
        cg->ambient_count = ambient_mark;
        const char *ec = ctype_of(cg, elem);
        char *inner = xasprintf(
            "({ %s _sl_v = %s; sl_arr *_sl_a = %s; sl_arr_push(_sl_a, "
            "&_sl_v, sizeof(%s)); _sl_a; })",
            ec, v, xs, ec);
        return wrap_safepoint(cg, e, ctype_of(cg, at), prelude.data, inner);
    }
    if (!strcmp(name, "pop")) {
        const char *at = infer_type(cg, e->as.call.args[0]);
        char *elem = arr_elem(at);
        char *xs = gen_expr(cg, e->as.call.args[0]);
        const char *ec = ctype_of(cg, elem);
        char *inner = xasprintf(
            "({ sl_arr *_sl_a = %s; *(%s *)(void *)sl_arr_pop(_sl_a, "
            "sizeof(%s)); })",
            xs, ec, ec);
        return wrap_safepoint(cg, e, ec, NULL, inner);
    }
    if (!strcmp(name, "to_str")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner = conv_to_str(t, a);
        return wrap_safepoint(cg, e, ctype_of(cg, "str"), NULL, inner);
    }
    if (!strcmp(name, "to_bytes")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner = xasprintf("sl_bytes_from_str(%s)", a);
        return wrap_safepoint(cg, e, ctype_of(cg, "bytes"), NULL, inner);
    }
    if (!strcmp(name, "bytes_ptr")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner = xasprintf("((void *)(%s)->ptr)", a);
        return wrap_safepoint(cg, e, ctype_of(cg, "rawptr"), NULL, inner);
    }
    if (!strcmp(name, "make_chan")) {
        /* cg->expect must still hold the annotated chan[T] target,
         * exactly as ctor_infer relies on for some/none/ok/err */
        const char *ct = infer_type(cg, e);
        char *elem = chan_elem(ct);
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner = xasprintf("sl_chan_new(sizeof(%s), (int)(%s))",
                                ctype_of(cg, elem), a);
        return wrap_safepoint(cg, e, ctype_of(cg, ct), NULL, inner);
    }
    if (!strcmp(name, "chan_send")) {
        const char *ct = infer_type(cg, e->as.call.args[0]);
        char *elem = chan_elem(ct);
        StrBuf prelude;
        sb_init(&prelude);
        int seq_id = cg->tmp_id++;
        int ambient_mark = cg->ambient_count;
        char *ch = gen_expr(cg, e->as.call.args[0]);
        ch = sequence_one(cg, seq_id, 0, ctype_of(cg, ct), ct, ch,
                          e->as.call.args[0], &prelude);
        const char *saved = expect_push(cg, elem);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        char *v = gen_expr(cg, e->as.call.args[1]);
        cg->expect = saved;
        v = maybe_cast(cg, elem, vt, v);
        v = sequence_one(cg, seq_id, 1, ctype_of(cg, elem), elem, v,
                         e->as.call.args[1], &prelude);
        cg->ambient_count = ambient_mark;
        int id = cg->tmp_id++;
        char *inner = xasprintf(
            "({ %s _sl_cv%d = %s; sl_chan_send(%s, &_sl_cv%d); })",
            ctype_of(cg, elem), id, v, ch, id);
        return wrap_safepoint(cg, e, NULL, prelude.data, inner);
    }
    if (!strcmp(name, "chan_recv")) {
        const char *ct = infer_type(cg, e->as.call.args[0]);
        char *elem = chan_elem(ct);
        char *ch = gen_expr(cg, e->as.call.args[0]);
        int id = cg->tmp_id++;
        const char *ec = ctype_of(cg, elem);
        const char *oc = opt_cname(cg, elem);
        char *inner = xasprintf(
            "({ %s _sl_cv%d; %s *_sl_co%d = (%s *)GC_malloc(sizeof(*_sl_co%d)); "
            "if (sl_chan_recv(%s, &_sl_cv%d)) { _sl_co%d->has = true; "
            "_sl_co%d->v = _sl_cv%d; } else { _sl_co%d->has = false; } "
            "_sl_co%d; })",
            ec, id, oc, id, oc, id, ch, id, id, id, id, id, id);
        return wrap_safepoint(cg, e, xasprintf("%s *", oc), NULL, inner);
    }
    if (!strcmp(name, "chan_close")) {
        char *ch = gen_expr(cg, e->as.call.args[0]);
        char *inner = xasprintf("sl_chan_close(%s)", ch);
        return wrap_safepoint(cg, e, NULL, NULL, inner);
    }
    if (!strcmp(name, "to_le") || !strcmp(name, "to_be")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *a = gen_expr(cg, e->as.call.args[0]);
        if (is_signed_int(t))
            a = xasprintf("(unsigned long long)(long long)(%s)", a);
        else
            a = xasprintf("(unsigned long long)(%s)", a);
        char *inner = xasprintf("sl_%s(%s)", name, a);
        return wrap_safepoint(cg, e, ctype_of(cg, "bytes"), NULL, inner);
    }
    if (!strcmp(name, "from_le") || !strcmp(name, "from_be")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner = xasprintf("((long long)sl_%s(%s))", name, a);
        return wrap_safepoint(cg, e, ctype_of(cg, "int"), NULL, inner);
    }
    if (!strcmp(name, "exit")) {
        char *a = gen_expr(cg, e->as.call.args[0]);
        char *inner = xasprintf("exit((int)(%s))", a);
        return wrap_safepoint(cg, e, NULL, NULL, inner);
    }
    if (!strcmp(name, "has") || !strcmp(name, "del")) {
        const char *t = infer_type(cg, e->as.call.args[0]);
        char *k, *v;
        map_kv(t, &k, &v);
        const char *kc = ctype_of(cg, k);
        StrBuf prelude;
        sb_init(&prelude);
        int seq_id = cg->tmp_id++;
        int ambient_mark = cg->ambient_count;
        char *m = gen_expr(cg, e->as.call.args[0]);
        m = sequence_one(cg, seq_id, 0, ctype_of(cg, t), t, m,
                         e->as.call.args[0], &prelude);
        const char *ikt = infer_type(cg, e->as.call.args[1]);
        char *ix = maybe_cast(cg, k, ikt, gen_expr(cg, e->as.call.args[1]));
        ix = sequence_one(cg, seq_id, 1, kc, k, ix, e->as.call.args[1],
                          &prelude);
        cg->ambient_count = ambient_mark;
        char *inner;
        const char *rc;
        if (!strcmp(name, "has")) {
            inner = xasprintf("({ %s _sl_k = %s; sl_map_has(%s, &_sl_k); })",
                              kc, ix, m);
            rc = ctype_of(cg, "bool");
        } else {
            inner = xasprintf("({ %s _sl_k = %s; sl_map_del(%s, &_sl_k); })",
                              kc, ix, m);
            rc = NULL;
        }
        return wrap_safepoint(cg, e, rc, prelude.data, inner);
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
    char *inner;
    if (!strcmp(name, "some"))
        inner = xasprintf(
            "({ %s _sl_c = (%s)GC_malloc(sizeof(*_sl_c)); "
            "_sl_c->has = true; _sl_c->v = %s; _sl_c; })",
            cn, cn, v);
    else if (!strcmp(name, "ok"))
        inner = xasprintf(
            "({ %s _sl_c = (%s)GC_malloc(sizeof(*_sl_c)); "
            "_sl_c->ok = true; _sl_c->v = %s; _sl_c; })",
            cn, cn, v);
    else
        inner = xasprintf(
            "({ %s _sl_c = (%s)GC_malloc(sizeof(*_sl_c)); "
            "_sl_c->ok = false; _sl_c->e = %s; _sl_c; })",
            cn, cn, v);
    /* Tier 10: some()/ok()/err() allocate directly (GC_malloc), so
     * this is a real safepoint too -- liveness.c doesn't special-case
     * ctor names, e->live_set is populated for this EX_CALL node
     * exactly like any other (see wrap_safepoint). arg has already
     * been generated above; a single argument has no sibling to
     * protect against, so no sequence_one/ambient handling is needed
     * here beyond what wrap_safepoint itself does. */
    return wrap_safepoint(cg, e, cn, NULL, inner);
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
     * leaves unspecified -- sequence them via sequence_one (the
     * primary Risk 1 case: foo(bar(), baz()); see its own comment for
     * why each argument is generated-and-sequenced one at a time,
     * rather than all-generated-then-sequenced -- required for
     * bar()'s temp to already be registered by the time baz() is
     * generated). selfexpr is never sequenced alongside them: a
     * method receiver is always a plain identifier in this language
     * (never a call/allocation of its own), so it has no ordering
     * hazard to guard against, and nothing to register either. */
    int nargs = e->as.call.nargs;
    char **names = (char **)xmalloc(sizeof(char *) * (size_t)(nargs > 0 ? nargs : 1));
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = nargs > 1 ? cg->tmp_id++ : -1;
    int ambient_mark = cg->ambient_count;
    for (int i = 0; i < nargs; i++) {
        const char *saved = expect_push(cg, sig->param_slang[argi + i]);
        const char *at = infer_type(cg, e->as.call.args[i]);
        char *a = gen_expr(cg, e->as.call.args[i]);
        cg->expect = saved;
        char *casted = maybe_cast(cg, sig->param_slang[argi + i], at, a);
        const char *ctype = ctype_of(cg, sig->param_slang[argi + i]);
        names[i] = sequence_one(cg, seq_id, i, ctype, sig->param_slang[argi + i],
                                casted, e->as.call.args[i], &prelude);
    }
    /* Pop this call's own argument-temp contributions back off; what
     * remains (cg->ambient_roots[0..ambient_mark)) is whatever an
     * ENCLOSING call's still-in-progress argument list pushed before
     * this call was itself generated as one of its arguments -- e.g.
     * outer(x, combine(xs, baz())): by the time combine(...) is
     * generated (as outer's arg1), outer's own loop has already
     * pushed x. combine is, from outer's point of view, exactly the
     * same "later sibling that must see an earlier bare-ident
     * argument" case baz() is from combine's -- so combine's own
     * bracket (built below) needs x too, which is exactly what's left
     * on the stack here after popping combine's own pushes. */
    cg->ambient_count = ambient_mark;

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

    /* Tier 10: bracket this call with a root list built straight from
     * the liveness pass's own live_set for this node (see
     * wrap_safepoint) -- everything that must stay scannable while
     * this call (and anything it transitively allocates) runs.
     * Arguments/selfexpr are excluded by construction: they're the
     * callee's concern from the moment they're passed, never in
     * e->live_set (see live_expr's EX_CALL case in liveness.c). The
     * argument-sequencing prelude built above is passed through so
     * wrap_safepoint splices it in ahead of the bracket; cg->ambient_
     * count is already correctly popped back to ambient_mark by this
     * point (the outer(x, combine(xs, baz())) case -- see the comment
     * on that pop above), exactly what wrap_safepoint expects. */
    return wrap_safepoint(cg, e, sig->ret_slang ? ctype_of(cg, sig->ret_slang) : NULL,
                          prelude.data, sb.data);
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
    /* Each key/value is sequenced into its own temp, declared directly
     * in this outer ({ ... }) scope (not the old per-pair { ... }
     * block, which closed immediately after its own sl_map_put --
     * invisible to a LATER pair's own nested-call safepoint bracket
     * needing to reference an EARLIER pair's still-live key/value, the
     * same crash class gen_list's [mk_a(), mk_b()] hit; see
     * sequence_one's own comment). Registered/ambient-pushed
     * unconditionally (not just when >1 total slot, since sl_map_put
     * always needs an addressable &name regardless of pair count). */
    int ambient_mark = cg->ambient_count;
    /* _sl_m itself is ALSO pushed onto ambient, right after
     * ambient_mark is captured -- it's under construction (sl_map_
     * new'd but not yet populated) for the entire loop below, so a
     * nested call inside a LATER pair's own evaluation needs it
     * protected too, not just the pair values sequence_one already
     * registers. Pushed after ambient_mark (not before) specifically
     * so the restore at the end of the loop pops it along with
     * everything else -- _sl_m's own C-level scope is this function's
     * own ({ ... }) block, so leaving it on ambient past this point
     * would dangle for whatever generates next, the same stale-scope
     * bug already fixed elsewhere in this file. */
    ambient_root_push(cg, "_sl_m");
    int seq_id = cg->tmp_id++;
    for (int i = 0; i < e->as.maplit.npairs; i++) {
        const char *kit = infer_type(cg, e->as.maplit.keys[i]);
        char *k = maybe_cast(cg, kt, kit, gen_expr(cg, e->as.maplit.keys[i]));
        char *kname = sequence_one(cg, seq_id, i * 2, kc, kt, k,
                                   e->as.maplit.keys[i], &sb);
        const char *vit = infer_type(cg, e->as.maplit.vals[i]);
        char *v = maybe_cast(cg, vt, vit, gen_expr(cg, e->as.maplit.vals[i]));
        char *vname = sequence_one(cg, seq_id, i * 2 + 1, vc, vt, v,
                                   e->as.maplit.vals[i], &sb);
        sb_append(&sb,
                  xasprintf("sl_map_put(_sl_m, &%s, &%s); ", kname, vname));
    }
    cg->ambient_count = ambient_mark;
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
    /* Each field value is sequenced into its own temp, declared
     * directly in this outer ({ ... }) scope, rather than embedded
     * raw into "_sl_s->field = %s;" -- needed so a LATER field's own
     * nested-call safepoint bracket can reference an EARLIER field's
     * still-live value (Wrapper{ a: bar(), b: baz() }: baz()'s own
     * bracket needs bar()'s temp), the same crash class gen_list's
     * [mk_a(), mk_b()] hit; see sequence_one's own comment).
     * Registered/ambient-pushed unconditionally, matching gen_maplit. */
    int ambient_mark = cg->ambient_count;
    /* _sl_s itself is ALSO pushed onto ambient, right after
     * ambient_mark is captured (popped by the same restore at the end
     * of the loop) -- it's under construction (GC_malloc'd but not
     * yet populated) for the entire loop below, so a nested call
     * inside a LATER field's own evaluation needs it protected too,
     * matching gen_maplit's own _sl_m treatment exactly. */
    ambient_root_push(cg, "_sl_s");
    int seq_id = cg->tmp_id++;
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
        const char *fc = ctype_of(cg, sd->ftypes[fi]);
        char *vname = sequence_one(cg, seq_id, j, fc, sd->ftypes[fi], v,
                                   e->as.structlit.vals[j], &sb);
        sb_append(&sb,
                  xasprintf("_sl_s->%s = %s; ",
                            sanitize_ident(sd->fields[fi]), vname));
    }
    cg->ambient_count = ambient_mark;
    sb_append(&sb, "_sl_s; })");
    return sb.data;
}

char *gen_index(CG *cg, Expr *e) {
    const char *bt = infer_type(cg, e->as.index.base);
    /* base and index would otherwise be embedded directly as sibling
     * call arguments, whose relative evaluation order C leaves
     * unspecified -- sequence them, base first (see sequence_one).
     * Applies uniformly to all 3 cases below, map included: if index
     * is itself a nested call, base's own pending/ambient protection
     * has to already be registered before index is generated, exactly
     * like every other multi-child site (see gen_call's comment on
     * this exact ordering requirement). */
    const char *bc = ctype_of(cg, bt);
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = cg->tmp_id++;
    int ambient_mark = cg->ambient_count;
    char *b = gen_expr(cg, e->as.index.base);
    b = sequence_one(cg, seq_id, 0, bc, bt, b, e->as.index.base, &prelude);

    if (is_map(bt)) {
        /* the index sequences at the map's own KEY ctype, not a fixed
         * "int" (Risk: str/other non-int key types) -- cast first
         * (same order gen_call uses: cast to the destination type,
         * then sequence the already-casted value), matching how a
         * map key of a narrower/wider numeric type would already need
         * casting regardless of this sequencing concern. */
        char *k, *v;
        map_kv(bt, &k, &v);
        const char *kc = ctype_of(cg, k);
        const char *vc = ctype_of(cg, v);
        const char *ikt = infer_type(cg, e->as.index.index);
        char *ix = maybe_cast(cg, k, ikt, gen_expr(cg, e->as.index.index));
        ix = sequence_one(cg, seq_id, 1, kc, k, ix, e->as.index.index,
                          &prelude);
        cg->ambient_count = ambient_mark;
        int id = cg->tmp_id++;
        return xasprintf(
            "({ %s%s _sl_k%d = %s; void *_sl_p%d = sl_map_get(%s, "
            "&_sl_k%d); if (!_sl_p%d) sl_rt_error(\"map key not found\", "
            "0, 0); *(%s *)(void *)_sl_p%d; })",
            prelude.data, kc, id, ix, id, b, id, id, vc, id);
    }
    char *i = gen_expr(cg, e->as.index.index);
    i = sequence_one(cg, seq_id, 1, map_type("int"), "int", i,
                     e->as.index.index, &prelude);
    cg->ambient_count = ambient_mark;
    if (is_bytes(bt)) {
        return xasprintf("({ %s((long long)sl_bytes_at(%s, %s)); })",
                         prelude.data, b, i);
    }
    char *elem = arr_elem(bt);
    const char *ec = ctype_of(cg, elem);
    return xasprintf(
        "({ %s(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s))); })",
        prelude.data, ec, b, i, ec);
}

char *gen_slice(CG *cg, Expr *e) {
    const char *bt = infer_type(cg, e->as.slice.base);
    const char *bc = ctype_of(cg, bt);
    /* base, start, and end would otherwise be embedded directly as
     * sibling call arguments (base always, start/end when both
     * given), whose relative evaluation order C leaves unspecified --
     * sequence base into its own named temp first and register it
     * immediately (see sequence_one/gen_call's comment), since start
     * or end may themselves be a nested call needing base's value
     * protected across their own execution. */
    StrBuf prelude;
    sb_init(&prelude);
    int ambient_mark = cg->ambient_count;
    int id = cg->tmp_id++;
    char *base_name = xasprintf("_sl_b%d", id);
    sb_append(&prelude,
              xasprintf("%s %s = %s; ", bc, base_name,
                        gen_expr(cg, e->as.slice.base)));
    expr_tmp_register(cg, e->as.slice.base, base_name);
    ambient_root_push(cg, base_name);

    char *start = e->as.slice.start ? gen_expr(cg, e->as.slice.start)
                                    : xstrdup("0");
    char *end = e->as.slice.end
                    ? gen_expr(cg, e->as.slice.end)
                    : xasprintf("%s->len", base_name);
    if (e->as.slice.inclusive)
        end = xasprintf("(%s + 1)", end);
    int seq_id = cg->tmp_id++;
    start = sequence_one(cg, seq_id, 0, map_type("int"), "int", start,
                         e->as.slice.start, &prelude);
    end = sequence_one(cg, seq_id, 1, map_type("int"), "int", end,
                       e->as.slice.end, &prelude);
    cg->ambient_count = ambient_mark;
    return xasprintf("({ %s%s(%s, %s, %s); })", prelude.data,
                     is_bytes(bt) ? "sl_bytes_slice" : "sl_arr_slice",
                     base_name, start, end);
}

char *gen_list(CG *cg, Expr *e, const char *expect_elem) {
    const char *t0 =
        expect_elem ? expect_elem : infer_type(cg, e->as.list.elems[0]);
    const char *ec = ctype_of(cg, t0);
    int n = e->as.list.nelems;
    /* elements would otherwise be embedded directly in one aggregate
     * initializer ({el0, el1, ...}), whose relative evaluation order
     * C leaves unspecified -- sequence them, same as every other
     * multi-child site in this file. Generated and sequenced one at a
     * time (not all-generated-then-sequenced): a later element that's
     * itself a nested call needs an earlier element's temp to already
     * be registered by the time it's generated (see gen_call's own
     * comment on this exact ordering requirement -- [mk_a(), mk_b()]
     * is exactly this file's own version of foo(bar(), baz())). */
    char **names = (char **)xmalloc(sizeof(char *) * (size_t)(n > 0 ? n : 1));
    StrBuf prelude;
    sb_init(&prelude);
    int seq_id = n > 1 ? cg->tmp_id++ : -1;
    int ambient_mark = cg->ambient_count;
    for (int i = 0; i < n; i++) {
        const char *ti = infer_type(cg, e->as.list.elems[i]);
        char *el = gen_expr(cg, e->as.list.elems[i]);
        el = maybe_cast(cg, t0, ti, el);
        names[i] = sequence_one(cg, seq_id, i, ec, t0, el, e->as.list.elems[i],
                                &prelude);
    }
    cg->ambient_count = ambient_mark;

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
            char *inner = xasprintf(
                "({ %s _sl_n = (%s)GC_malloc(sizeof(*_sl_n)); "
                "_sl_n->has = false; _sl_n; })",
                cn, cn);
            /* Tier 10: 'none' allocates a fresh opt wrapper via
             * GC_malloc every occurrence -- liveness.c treats this as
             * its own safepoint kind (the one deliberate EX_IDENT
             * exception, see live_expr's EX_IDENT case), so it gets
             * the same bracket treatment as any other allocating
             * call (see wrap_safepoint). No arguments to sequence. */
            return wrap_safepoint(cg, e, cn, NULL, inner);
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
            /* lhs is sequenced into _sl_qN before rhs is generated
             * (already true, for Risk 1: rhs must never re-observe a
             * partially-evaluated lhs) -- but _sl_qN was never
             * registered, so if rhs is itself a nested call, its own
             * safepoint bracket had no way to protect _sl_qN across
             * its execution (lt is always opt/result here, always a
             * GC pointer, so this is a real gap, not a theoretical
             * one). Registered + ambient-pushed the same way
             * sequence_one would, then explicitly popped before
             * returning: _sl_qN is scoped to this ({ ... }) block
             * alone, so leaving it on ambient past this point would
             * dangle for whatever generates next. */
            int ambient_mark = cg->ambient_count;
            char *qname = xasprintf("_sl_q%d", id);
            expr_tmp_register(cg, e->as.binary.lhs, qname);
            ambient_root_push(cg, qname);
            if (is_opt(lt)) {
                char *inner = opt_inner(lt);
                const char *oc = ctype_of(cg, lt);
                const char *ic = ctype_of(cg, inner);
                const char *saved = expect_push(cg, inner);
                const char *rt = infer_type(cg, e->as.binary.rhs);
                char *b = gen_expr(cg, e->as.binary.rhs);
                cg->expect = saved;
                b = maybe_cast(cg, inner, rt, b);
                cg->ambient_count = ambient_mark;
                return xasprintf(
                    "({ %s %s = %s; "
                    "(%s->has ? %s->v : (%s)(%s)); })",
                    oc, qname, a, qname, qname, ic, b);
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
            cg->ambient_count = ambient_mark;
            return xasprintf(
                "({ %s %s = %s; "
                "(%s->ok ? %s->v : (%s)(%s)); })",
                oc, qname, a, qname, qname, ic, b);
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

