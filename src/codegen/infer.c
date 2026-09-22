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
            if (!g) {
                /* pkg.f used as a VALUE rather than called */
                FuncSig *fs = sig_find_in(cg, pkg, right);
                if (fs && !fs->method_of) {
                    if (!fs->is_pub)
                        cg_error(line,
                                 "function '%s' is not exported from "
                                 "package '%s'",
                                 right, pkg);
                    return fn_type_of_sig(cg, fs);
                }
                cg_error(line, "package '%s' has no variable '%s'", pkg,
                         right);
            }
            if (!g->is_pub)
                cg_error(line,
                         "variable '%s' is not exported from package '%s' "
                         "(add 'pub' to export it)",
                         right, pkg);
            return g->slang;
        }
        const char *bt = infer_ident_name(cg, left, line);
        StructDef *sd = struct_of_type(cg, bt);
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
    {
        /* A bare function name used as a value. Checked after variables
         * and globals, so a binding always shadows a function of the
         * same name rather than silently becoming one. */
        FuncSig *fs = sig_find_in(cg, cg->cur_pkg, name);
        if (fs) {
            if (fs->method_of)
                cg_error(line,
                         "'%s' is a method; methods cannot be used as "
                         "function values (they take a receiver the type "
                         "does not name)",
                         name);
            return fn_type_of_sig(cg, fs);
        }
        if (func_tmpl_find_in_pkg(cg, cg->cur_pkg, name))
            cg_error(line,
                     "'%s' is a generic function; it cannot be used as a "
                     "value or spawned (write a plain function that calls "
                     "it with a concrete type, and use that instead)",
                     name);
    }
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
        if (is_str(t) || is_bytes(t) || is_arr(t) || is_map(t) || is_wire(t))
            return "int";
        cg_error(e->line,
                 "len() expects a str, bytes, [T], map, or wire (got %s)",
                 t);
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
        const char *saved = expect_push(cg, elem);
        const char *vt = infer_type(cg, e->as.call.args[1]);
        cg->expect = saved;
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
        if (is_result(t) || is_opt(t))
            cg_error(e->line, "cannot convert opt/result to str; unwrap first");
        return "str";
    }
    if (!strcmp(name, "to_bytes")) {
        if (n != 1)
            cg_error(e->line, "to_bytes() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_str(t) && !is_wire(t))
            cg_error(e->line, "to_bytes() expects a str or a wire (got %s)", t);
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
    if (!strcmp(name, "to_int") || !strcmp(name, "to_float")) {
        if (n != 1)
            cg_error(e->line, "%s() takes exactly one argument", name);
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_str(t))
            cg_error(e->line, "%s() expects a str (got %s)", name, t);
        /* Fallible on purpose, and the inverse of to_str: parsing can
           fail, and a parser that cannot say so is how `PORT=abc` ends
           up binding port 0. */
        const char *v = !strcmp(name, "to_int") ? "int" : "float";
        res_cname(cg, v, "str"); /* register the instantiation */
        return xasprintf("result[%s,str]", v);
    }
    /* resolve_enum_refs (enum.c) rewrites Type.from_int(n)/Type.from_str(s)
     * into these sentinel names, tagging which enum via call.enum_ty.
     * Fallible for the same reason to_int is: not every int/str is a
     * valid variant. */
    if (!strcmp(name, "__enum_from_int") || !strcmp(name, "__enum_from_str")) {
        int from_int = !strcmp(name, "__enum_from_int");
        if (n != 1)
            cg_error(e->line, "%s() takes exactly one argument",
                     from_int ? "from_int" : "from_str");
        const char *at = infer_type(cg, e->as.call.args[0]);
        if (from_int ? !is_int(at) : !is_str(at))
            cg_error(e->line, "%s() expects %s (got %s)",
                     from_int ? "from_int" : "from_str",
                     from_int ? "an int" : "a str", at);
        res_cname(cg, e->as.call.enum_ty, "str"); /* register the instantiation */
        return xasprintf("result[%s,str]", e->as.call.enum_ty);
    }
    if (!strcmp(name, "make_mutex")) {
        if (n != 0)
            cg_error(e->line, "make_mutex() takes no arguments");
        return "mutex";
    }
    if (!strcmp(name, "mutex_lock") || !strcmp(name, "mutex_unlock") ||
        !strcmp(name, "mutex_trylock")) {
        if (n != 1)
            cg_error(e->line, "%s() takes exactly one argument", name);
        const char *mt = infer_type(cg, e->as.call.args[0]);
        if (!is_mutex(mt))
            cg_error(e->line, "%s() expects a mutex (got %s)", name, mt);
        return !strcmp(name, "mutex_trylock") ? "bool" : "void";
    }
    if (!strcmp(name, "join_wait")) {
        if (n != 1)
            cg_error(e->line, "join_wait() takes exactly one argument");
        const char *jt = infer_type(cg, e->as.call.args[0]);
        if (!is_join(jt))
            cg_error(e->line, "join_wait() expects a join handle (got %s)",
                     jt);
        char *elem = join_elem(jt);
        res_cname(cg, elem, "str");
        return xasprintf("result[%s,str]", elem);
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
    /* panic(msg) and assert(cond[, msg]) end the current task with a
       located message: in a spawned task that becomes the err of its
       join_wait, which is what lets `slangc test` report a failing test
       and carry on; in the main task it ends the program. */
    if (!strcmp(name, "panic")) {
        if (n != 1)
            cg_error(e->line, "panic() takes exactly one argument, the message");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_str(t))
            cg_error(e->line, "panic() expects a str message (got %s)", t);
        return "void";
    }
    if (!strcmp(name, "assert")) {
        if (n != 1 && n != 2)
            cg_error(e->line,
                     "assert() takes a condition and an optional message");
        const char *ct = infer_type(cg, e->as.call.args[0]);
        if (strcmp(ct, "bool"))
            cg_error(e->line, "assert() expects a bool condition (got %s)", ct);
        if (n == 2) {
            const char *mt = infer_type(cg, e->as.call.args[1]);
            if (!is_str(mt))
                cg_error(e->line, "assert() expects a str message (got %s)", mt);
        }
        return "void";
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
    if (!strcmp(name, "arena_new")) {
        if (n != 1)
            cg_error(e->line, "arena_new() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_int(t))
            cg_error(e->line,
                     "arena_new() expects an integer capacity (got %s)", t);
        return "arena";
    }
    if (!strcmp(name, "until_of")) {
        if (n != 1)
            cg_error(e->line, "until_of() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_int(t) && !is_until(t))
            cg_error(e->line,
                     "until_of() expects a duration (got %s)", t);
        return "until";
    }
    if (!strcmp(name, "until_never")) {
        if (n != 0)
            cg_error(e->line, "until_never() takes no arguments");
        return "until";
    }
    if (!strcmp(name, "until_hit")) {
        if (n != 1)
            cg_error(e->line, "until_hit() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_until(t))
            cg_error(e->line, "until_hit() expects an until (got %s)", t);
        return "bool";
    }
    if (!strcmp(name, "fault_timeout") || !strcmp(name, "fault_reset") ||
        !strcmp(name, "fault_closed") || !strcmp(name, "fault_io") ||
        !strcmp(name, "fault_refused")) {
        if (n != 0)
            cg_error(e->line, "%s() takes no arguments", name);
        return "fault";
    }
    if (!strcmp(name, "fault_kind")) {
        if (n != 1)
            cg_error(e->line, "fault_kind() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_fault(t))
            cg_error(e->line, "fault_kind() expects a fault (got %s)", t);
        return "int";
    }
    if (!strcmp(name, "fault_code")) {
        if (n != 1)
            cg_error(e->line, "fault_code() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_fault(t))
            cg_error(e->line, "fault_code() expects a fault (got %s)", t);
        return "int";
    }
    if (!strcmp(name, "fault_op")) {
        if (n != 1)
            cg_error(e->line, "fault_op() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_fault(t))
            cg_error(e->line, "fault_op() expects a fault (got %s)", t);
        return "str";
    }
    if (!strcmp(name, "peer_v4")) {
        if (n != 5)
            cg_error(e->line, "peer_v4() takes five arguments");
        for (int i = 0; i < 5; i++) {
            const char *t = infer_type(cg, e->as.call.args[i]);
            if (!is_int(t))
                cg_error(e->line,
                         "peer_v4() argument %d must be an integer (got %s)",
                         i + 1, t);
        }
        return "peer";
    }
    if (!strcmp(name, "peer_port")) {
        if (n != 1)
            cg_error(e->line, "peer_port() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_peer(t))
            cg_error(e->line, "peer_port() expects a peer (got %s)", t);
        return "int";
    }
    if (!strcmp(name, "trip_new")) {
        if (n != 0)
            cg_error(e->line, "trip_new() takes no arguments");
        return "trip";
    }
    if (!strcmp(name, "link_listen")) {
        if (n != 1 && n != 2)
            cg_error(e->line, "link_listen() takes one or two arguments");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_int(t))
            cg_error(e->line,
                     "link_listen() expects an integer port (got %s)", t);
        if (n == 2) {
            const char *rt = infer_type(cg, e->as.call.args[1]);
            if (!is_int(rt))
                cg_error(e->line,
                         "link_listen() expects an integer reuse flag (got %s)",
                         rt);
        }
        cg->want_link = 1;
        res_cname(cg, "link", "fault");
        return "result[link,fault]";
    }
    if (!strcmp(name, "link_dial")) {
        if (n != 3)
            cg_error(e->line, "link_dial() takes exactly three arguments");
        const char *ht = infer_type(cg, e->as.call.args[0]);
        const char *pt = infer_type(cg, e->as.call.args[1]);
        const char *ut = infer_type(cg, e->as.call.args[2]);
        if (!is_str(ht))
            cg_error(e->line, "link_dial() expects a host string (got %s)",
                     ht);
        if (!is_int(pt))
            cg_error(e->line, "link_dial() expects an integer port (got %s)",
                     pt);
        if (!is_until(ut))
            cg_error(e->line, "link_dial() expects an until (got %s)", ut);
        cg->want_link = 1;
        res_cname(cg, "link", "fault");
        return "result[link,fault]";
    }

    if (!strcmp(name, "err_of")) {
        if (n != 1)
            cg_error(e->line, "err_of() takes exactly one argument");
        const char *t = infer_type(cg, e->as.call.args[0]);
        if (!is_result(t))
            cg_error(e->line, "err_of() expects a result (got %s)", t);
        char *tv, *tev;
        result_te(t, &tv, &tev);
        return tev;
    }

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
            if (!strcmp(pkg, "json") && is_native_pkg(cg, pkg))
                return json_call_infer(cg, right, e);
            sig = sig_find_in(cg, pkg, right);
            if (!sig && is_native_pkg(cg, pkg))
                return native_check(cg, pkg, right, e);
            if (!sig)
                sig = generic_call_sig(cg, pkg, right, e);
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
            if (type_is_trip(recv_t)) {
                if (!strcmp(right, "pull")) {
                    if (n != 0)
                        cg_error(e->line, "trip.pull() takes no arguments");
                    return "void";
                }
                if (!strcmp(right, "down")) {
                    if (n != 0)
                        cg_error(e->line, "trip.down() takes no arguments");
                    return "bool";
                }
                cg_error(e->line, "type 'trip' has no method '%s'", right);
            }
            if (type_is_link(recv_t)) {
                cg->want_link = 1;
                if (!strcmp(right, "accept")) {
                    if (n != 1)
                        cg_error(e->line,
                                 "link.accept() takes exactly one argument");
                    const char *ut = infer_type(cg, e->as.call.args[0]);
                    if (!is_until(ut))
                        cg_error(e->line,
                                 "link.accept() expects an until (got %s)",
                                 ut);
                    res_cname(cg, "link", "fault");
                    return "result[link,fault]";
                }
                if (!strcmp(right, "send") || !strcmp(right, "recv") ||
                    !strcmp(right, "send_bytes") ||
                    !strcmp(right, "send_static")) {
                    if (n != 2)
                        cg_error(e->line,
                                 "link.%s() takes exactly two arguments",
                                 right);
                    const char *wt = infer_type(cg, e->as.call.args[0]);
                    const char *ut = infer_type(cg, e->as.call.args[1]);
                    if (!strcmp(right, "send_static")) {
                        if (e->as.call.args[0]->kind != EX_BYTES)
                            cg_error(e->line,
                                     "link.send_static() expects a bytes literal");
                    } else if (!strcmp(right, "send_bytes")) {
                        if (!is_bytes(wt))
                            cg_error(e->line,
                                     "link.%s() expects bytes (got %s)",
                                     right, wt);
                    } else if (!is_wire(wt)) {
                        cg_error(e->line,
                                 "link.%s() expects a wire (got %s)",
                                 right, wt);
                    }
                    if (!is_until(ut))
                        cg_error(e->line,
                                 "link.%s() expects an until (got %s)",
                                 right, ut);
                    res_cname(cg, "int", "fault");
                    return "result[int,fault]";
                }
                if (!strcmp(right, "peer")) {
                    if (n != 0)
                        cg_error(e->line, "link.peer() takes no arguments");
                    return "peer";
                }
                if (!strcmp(right, "port")) {
                    if (n != 0)
                        cg_error(e->line, "link.port() takes no arguments");
                    return "int";
                }
                cg_error(e->line, "type 'link' has no method '%s'", right);
            }
            if (type_is_arena(recv_t)) {
                if (!strcmp(right, "alloc")) {
                    if (n != 1)
                        cg_error(e->line,
                                 "arena.alloc() takes exactly one argument");
                    const char *vt = infer_type(cg, e->as.call.args[0]);
                    return xasprintf("&mut %s", vt);
                }
                if (!strcmp(right, "alloc_bytes")) {
                    if (n != 1)
                        cg_error(e->line,
                                 "arena.alloc_bytes() takes exactly one "
                                 "argument");
                    const char *vt = infer_type(cg, e->as.call.args[0]);
                    if (!is_int(vt))
                        cg_error(e->line,
                                 "arena.alloc_bytes() expects an integer "
                                 "byte count (got %s)",
                                 vt);
                    return "&mut u8";
                }
                if (!strcmp(right, "reset")) {
                    if (n != 0)
                        cg_error(e->line, "arena.reset() takes no arguments");
                    return "void";
                }
                if (!strcmp(right, "wire")) {
                    if (n != 1)
                        cg_error(e->line,
                                 "arena.wire() takes exactly one argument");
                    const char *vt = infer_type(cg, e->as.call.args[0]);
                    if (!is_int(vt))
                        cg_error(e->line,
                                 "arena.wire() expects an integer byte "
                                 "count (got %s)",
                                 vt);
                    return "wire";
                }
                cg_error(e->line, "type 'arena' has no method '%s'", right);
            }
            StructDef *sd = struct_of_type(cg, recv_t);
            int fld = -1;
            if (!sd)
                cg_error(e->line, "call to undefined function '%s'", name);
            /* A fn-typed FIELD wins over a method of the same name:
             * `x.f(1)` where f is a field holding a function value is a
             * call through that value, and it takes no receiver. The
             * parser folds one dot into the call's name, so this is the
             * only place that shape can be recognised. */
            for (int i = 0; i < sd->nfields; i++) {
                if (!strcmp(sd->fields[i], right) && is_fn(sd->ftypes[i])) {
                    fld = i;
                    break;
                }
            }
            if (fld >= 0) {
                sig = fn_sig_of_type(cg, sd->ftypes[fld], name, e->line);
                recv_t = NULL; /* no implicit self for a field call */
                goto have_sig;
            }
            sig = method_find(cg, sd, right, e->line);
            if (!sig)
                cg_error(e->line, "type '%s' has no method '%s'",
                         sd->canonical, right);
            if (!sig->is_pub && strcmp(sd->pkg, cg->cur_pkg))
                cg_error(e->line,
                         "method '%s' is not exported from package '%s' "
                         "(add 'pub' to export it)",
                         right, sd->pkg);
        }
    } else if (e->as.call.callee) {
        const char *ct = infer_type(cg, e->as.call.callee);
        if (!is_fn(ct))
            cg_error(e->line,
                     "this expression is not callable (type %s)", ct);
        sig = fn_sig_of_type(cg, ct, "<function value>", e->line);
    } else {
        const char *fvt = fn_var_type(cg, name);
        if (fvt) {
            sig = fn_sig_of_type(cg, fvt, name, e->line);
        } else {
            sig = sig_find_in(cg, cg->cur_pkg, name);
            if (!sig)
                sig = generic_call_sig(cg, cg->cur_pkg, name, e);
            if (!sig)
                cg_error(e->line, "call to undefined function '%s'", name);
        }
    }
have_sig:;
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

FuncSig *method_target(CG *cg, const char *recv_t, const char *name,
                       int line, StructDef **sd_out, int *fld) {
    /* arena, link and trip have hand-written pseudo-methods that are
     * emitted from a variable's name (gen_call). They are handles that
     * live in locals; say so instead of the misleading "no such field". */
    if (type_is_arena(recv_t) || type_is_link(recv_t) || type_is_trip(recv_t))
        cg_error(line,
                 "'%s' is a method of the built-in type %s, which can only "
                 "be called on a variable: assign the receiver to a name "
                 "first",
                 name, recv_t);
    StructDef *sd = struct_of_type(cg, recv_t);
    if (!sd)
        cg_error(line, "cannot call '%s' on a value of type %s: it has no "
                       "methods", name, recv_t);
    *sd_out = sd;
    *fld = -1;
    /* A fn-typed FIELD wins over a method of the same name, exactly as it
     * does for `x.f(1)` on a variable. */
    for (int i = 0; i < sd->nfields; i++) {
        if (!strcmp(sd->fields[i], name) && is_fn(sd->ftypes[i])) {
            *fld = i;
            return fn_sig_of_type(cg, sd->ftypes[i], name, line);
        }
    }
    FuncSig *sig = method_find(cg, sd, name, line);
    if (!sig)
        cg_error(line, "type '%s' has no method '%s'", sd->canonical, name);
    if (!sig->is_pub && strcmp(sd->pkg, cg->cur_pkg))
        cg_error(line,
                 "method '%s' is not exported from package '%s' (add 'pub' "
                 "to export it)",
                 name, sd->pkg);
    return sig;
}

/* recv.name(args) where recv is an arbitrary expression. */
const char *infer_method(CG *cg, Expr *e) {
    const char *name = e->as.method.name;
    const char *recv_t = infer_type(cg, e->as.method.recv);
    StructDef *sd;
    int fld;
    FuncSig *sig = method_target(cg, recv_t, name, e->line, &sd, &fld);
    int self_off = fld >= 0 ? 0 : 1;
    int n = e->as.method.nargs;
    if (n + self_off != sig->nparams)
        cg_error(e->line, "function '%s' expects %d argument(s), got %d",
                 name, sig->nparams - self_off, n);
    for (int i = 0; i < n; i++) {
        const char *saved = expect_push(cg, sig->param_slang[i + self_off]);
        const char *at = infer_type(cg, e->as.method.args[i]);
        cg->expect = saved;
        if (!value_assignable(sig->param_slang[i + self_off],
                              e->as.method.args[i], at))
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
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) && is_fault(lt) &&
            is_fault(rt))
            return "bool";
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) && is_peer(lt) &&
            is_peer(rt))
            return "bool";
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) && is_until(lt) &&
            is_until(rt))
            return "bool";
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) && is_enum(cg, lt) &&
            !strcmp(lt, rt))
            return "bool";
        /* Equality only: `true < false` has no meaning worth giving it.
           Before this, `a == b` on two bools was "cannot compare bool and
           bool", forcing `a && b || !a && !b` for the most basic test a
           language has. */
        if ((!strcmp(op, "==") || !strcmp(op, "!=")) &&
            !strcmp(lt, "bool") && !strcmp(rt, "bool"))
            return "bool";
        if (!strcmp(lt, "bool") && !strcmp(rt, "bool"))
            cg_error(e->line, "'%s' does not apply to bool (only == and != "
                              "do)", op);
        cg_error(e->line, "cannot compare %s and %s", lt, rt);
    }
    if (!strcmp(op, "+")) {
        if (is_str(lt) || is_str(rt) || is_fault(lt) || is_fault(rt) ||
            is_enum(cg, lt) || is_enum(cg, rt)) {
            const char *other =
                (is_str(lt) || is_fault(lt) || is_enum(cg, lt)) ? rt : lt;
            if (!(is_str(other) || is_num(other) || !strcmp(other, "bool") ||
                  is_bytes(other) || is_fault(other) || is_enum(cg, other)))
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
        if (type_is_raw_ptr(lt) && is_int(rt)) {
            if (!e->in_unsafe)
                cg_error(e->line,
                         "pointer arithmetic requires an 'unsafe' block");
            return lt;
        }
        if (is_int(lt) && type_is_raw_ptr(rt)) {
            if (!e->in_unsafe)
                cg_error(e->line,
                         "pointer arithmetic requires an 'unsafe' block");
            return rt;
        }
        cg_error(e->line, "unsupported operand types for '+': %s and %s",
                 lt, rt);
    }
    if (!strcmp(op, "-") || !strcmp(op, "*") || !strcmp(op, "/")) {
        if (is_num(lt) && is_num(rt))
            return promote(lt, rt);
        if (!strcmp(op, "-") && type_is_raw_ptr(lt) && is_int(rt)) {
            if (!e->in_unsafe)
                cg_error(e->line,
                         "pointer arithmetic requires an 'unsafe' block");
            return lt;
        }
        cg_error(e->line, "unsupported operand types for '%s': %s and %s",
                 op, lt, rt);
    }
    if (!strcmp(op, "%")) {
        if (is_int(lt) && is_int(rt))
            return promote(lt, rt);
        cg_error(e->line, "'%%' requires integer operands (got %s and %s)",
                 lt, rt);
    }
    /* Bitwise AND/OR/XOR promote like arithmetic: the result has to be
     * wide enough to hold either operand's bits. Floats are rejected --
     * there is no meaningful bit pattern to combine, and silently
     * truncating to int would hide the mistake. */
    if (!strcmp(op, "&") || !strcmp(op, "|") || !strcmp(op, "^")) {
        if (is_int(lt) && is_int(rt))
            return promote(lt, rt);
        cg_error(e->line,
                 "'%s' requires integer operands (got %s and %s)", op, lt, rt);
    }
    /* Shifts do NOT promote to the wider of the two: the value being
     * shifted keeps its own type, and the shift COUNT is just a count,
     * so `x << n` is as wide as x regardless of n's type. Promoting here
     * would silently widen a u8 the moment it was shifted by an int. */
    if (!strcmp(op, "<<") || !strcmp(op, ">>")) {
        if (is_int(lt) && is_int(rt))
            return lt;
        cg_error(e->line,
                 "'%s' requires integer operands (got %s and %s)", op, lt, rt);
    }
    cg_error(e->line, "unknown operator '%s'", op);
    return NULL; /* unreachable */
}

const char *infer_type(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_INT:
        /* resolve_enum_refs (enum.c) rewrites a `Type.Variant` reference
         * into this same node shape, tagged with enum_ty -- check that
         * first, before the ordinary-literal typing below. */
        if (e->as.int_lit.enum_ty)
            return e->as.int_lit.enum_ty;
        /* A literal too large for i64 is not an int that happens to
         * overflow -- it is a u64. Typing it that way makes
         * `let x = 18446744073709551615;` correct, and makes
         * `let x: int = 18446744073709551615;` the error it should be,
         * instead of both silently yielding LLONG_MAX. */
        return e->as.int_lit.big_u64 ? "u64" : "int";
    case EX_FLOAT:  return "float";
    case EX_STRING: return "str";
    case EX_BYTES:  return "bytes";
    case EX_BOOL:   return "bool";
    case EX_IDENT:
        return infer_ident_name(cg, e->as.ident.name, e->line);
    case EX_UNARY: {
        const char *t = infer_type(cg, e->as.unary.operand);
        const char *op = e->as.unary.op;
        if (!strcmp(op, "-")) {
            if (!is_num(t))
                cg_error(e->line,
                         "unary '-' requires a numeric operand (got %s)", t);
            return t;
        }
        if (!strcmp(op, "!")) {
            if (!strcmp(t, "bool"))
                return "bool";
            cg_error(e->line, "'!' requires a bool operand (got %s)", t);
        }
        if (!strcmp(op, "~")) {
            if (is_int(t))
                return t;
            cg_error(e->line,
                     "'~' requires an integer operand (got %s)", t);
        }
        if (!strcmp(op, "&") || !strcmp(op, "&mut")) {
            if (!expr_addressable(e->as.unary.operand))
                cg_error(e->line, "cannot take the address of a temporary");
            return !strcmp(op, "&mut") ? xasprintf("&mut %s", t)
                                       : xasprintf("&%s", t);
        }
        if (!strcmp(op, "*")) {
            char *inner;
            TypeWrap w = type_wrap(t, &inner);
            if (w == TW_NONE)
                cg_error(e->line, "cannot dereference a value of type %s", t);
            if (type_is_raw_ptr(t) && !e->in_unsafe)
                cg_error(e->line,
                         "dereference of a raw pointer requires an "
                         "'unsafe' block");
            return inner;
        }
        cg_error(e->line, "unknown unary operator '%s'", op);
    }
    case EX_BINARY:
        return infer_binary(cg, e);
    case EX_CALL: {
        const char *t = infer_call(cg, e);
        e->inf_ty = t;
        return t;
    }
    case EX_METHOD: {
        const char *t = infer_method(cg, e);
        e->inf_ty = t;
        return t;
    }
    case EX_SPAWN: {
        FuncSig *sig = spawn_target(cg, e->as.spawn.call, e->line);
        if (!sig->ret_slang)
            cg_error(e->line,
                     "'spawn' as an expression requires a function that "
                     "returns a value; use 'spawn f();' as a statement");
        for (int i = 0; i < e->as.spawn.call->as.call.nargs; i++) {
            const char *saved = expect_push(cg, sig->param_slang[i]);
            infer_type(cg, e->as.spawn.call->as.call.args[i]);
            cg->expect = saved;
        }
        {
            const char *sft = spawn_fn_type(cg, e->as.spawn.call);
            if (sft)
                spawn_shape_for_fn(cg, sft);
            else
                spawn_shape_for(cg, sig);
        }
        const char *t = xasprintf("join[%s]", sig->ret_slang);
        e->inf_ty = t;
        return t;
    }
    case EX_CAST: {
        const char *ty = e->as.cast.ty;
        const char *t = infer_type(cg, e->as.cast.operand);
        /* enum -> i32 (its backing type) is a separate, narrow allowance
         * from the general numeric casts below -- NOT a change to
         * is_num(), which arithmetic and other numeric contexts also
         * rely on; folding enums into it would silently let
         * `Status.Pending + 1` compile. There's no reverse direction
         * here: int -> enum is fallible (not every int is a valid
         * variant), so it goes through Type.from_int instead, which
         * returns a result. */
        if (is_enum(cg, t)) {
            if (strcmp(ty, "i32"))
                cg_error(e->line,
                         "enum '%s' can only be cast to i32 (its backing "
                         "type), not %s",
                         enum_find_canon(cg, t)->name, ty);
            return ty;
        }
        if (!map_type(ty) || !is_num(ty))
            cg_error(e->line, "invalid cast target type '%s'", ty);
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
        if (is_bytes(bt) || is_wire(bt))
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
        if (is_wire(bt))
            return "wire";
        if (is_arr(bt))
            return bt;
        cg_error(e->line, "cannot slice a value of type %s", bt);
    }
    case EX_LIST: {
        /* [] takes its type from context -- a parameter, a struct field,
         * a return, an assignment -- through cg->expect, exactly as
         * `none` does. Only with no list type expected is it an error. */
        if (e->as.list.nelems == 0 && cg->expect && is_arr(cg->expect)) {
            e->as.list.resolved = cg->expect;
            return cg->expect;
        }
        if (e->as.list.nelems == 0 && e->as.list.resolved)
            return e->as.list.resolved;
        if (e->as.list.nelems == 0)
            cg_error(e->line,
                     "cannot infer the element type of an empty list; "
                     "annotate the variable, e.g. let xs: [int] = []");
        /* elements expect the ELEMENT type: [[]] against [[int]] */
        const char *outer = cg->expect;
        if (outer && is_arr(outer))
            cg->expect = arr_elem(outer);
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
        cg->expect = outer;
        return xasprintf("[%s]", t0);
    }
    case EX_MAPLIT: {
        if (e->as.maplit.npairs == 0)
            cg_error(e->line,
                     "cannot infer the key/value types of an empty map; "
                     "annotate the variable, e.g. let m: map[str]int = {}");
        const char *kt = infer_type(cg, e->as.maplit.keys[0]);
        if (!is_map_key(cg, kt))
            cg_error(e->line,
                     "map keys must be an integer type, str, bool, or "
                     "enum (got %s)",
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
        StructDef *sd = struct_of_type(cg, bt);
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
        const char *canon = structlit_type(cg, e);
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
            const char *saved = expect_push(cg, sd->ftypes[i]);
            const char *vt = infer_type(cg, v);
            cg->expect = saved;
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
