/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"

#include <string.h>

const char *infer_ident_name(CG *cg, const char *name, int line) {
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
const char *ctor_infer(CG *cg, Expr *e) {
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

const char *infer_call(CG *cg, Expr *e) {
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

const char *infer_binary(CG *cg, Expr *e) {
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

const char *infer_type(CG *cg, Expr *e) {
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

/* C expression for a possibly-dotted identifier: locals, package
 * globals, imported members, or struct field chains. */
