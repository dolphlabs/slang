/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"
#include "liveness.h"

#include <string.h>

/* Tier 10: emits the root-array + sl_safepoint + enter statements for
 * a loop's back-edge, from its already-computed backedge_live_set
 * (named entries only -- liveness.c's solve_loop_fixpoint unions live
 * sets via ls_union_named_into, which never touches the "pending"
 * (anonymous, intra-expression) side of a LiveSet at all, so unlike
 * gen_call's own bracket there's no temp to materialize here: every
 * entry is already a real, stably-addressable, already-declared
 * local). Called right after the loop's own C `{`, wrapping the
 * per-iteration body (and, for ST_FOR_IN, the per-iteration bound-
 * variable statements too) so it re-executes every iteration --
 * protects a loop-carried GC pointer even when nothing inside the
 * loop body happens to go through gen_call's own bracket (a tight
 * loop with no calls at all, or a call to a builtin/native function,
 * neither of which get one -- see todo.md's Tier 10 notes). Returns
 * 1 (bracket opened; caller must emit "sl_rt_safepoint_exit();"
 * after the body) or 0 (empty set, nothing emitted but for the direct
 * yield-check call below, nothing to close) -- matching every other
 * bracket built so far, skipped entirely when there's nothing to
 * protect (the common case for a purely numeric loop).
 *
 * Tier 11 seventh slice (cooperative preemption v1): when n == 0, no
 * bracket opens and (before this slice) NOTHING was emitted at all --
 * meaning a purely-scalar tight loop (e.g. demo/stress/stress.sl's
 * count_primes_range, the exact motivating case) had zero checkpoints
 * of any kind, GC or preemption. `direct_yield_ok` lets most such
 * loops get one anyway: call sl_rt_maybe_yield() directly, unbracketed,
 * right at loop-body entry. Deliberately NOT done for ST_FOR_IN's three
 * variants (array/bytes/map) even at n == 0 -- an independent design
 * review found that those loops hoist a GC-pointer alias (_sl_itN/
 * _sl_btN/_sl_mN, the iterable itself) OUTSIDE any bracket, dereferenced
 * every iteration; today that's dormant (n == 0 means nothing ever
 * checks in inside such a loop, so nothing can collect it out from
 * under the alias), and activating a checkpoint there would turn that
 * dormant rooting gap into a live one. ST_WHILE/ST_FOR have no such
 * hidden alias -- a numeric range loop's bounds are plain `long long`s
 * -- so they pass 1. Fixing ST_FOR_IN's own alias-rooting gap is a
 * separate, disclosed follow-up (see the Tier 11 plan), not bundled
 * into this slice. */
static int emit_backedge_enter(CG *cg, void *backedge_live_set,
                                int direct_yield_ok) {
    int n = live_set_nnamed(backedge_live_set);
    if (n == 0) {
        /* Nothing to root, so no ordering hazard: this call can safely
         * run before anything else here, since there's no bracket for
         * it to run "inside of" one way or the other. Must NOT be
         * emitted unconditionally before this check for loops that DO
         * open a bracket below -- an earlier draft did exactly that,
         * and a design review caught it: sl_rt_maybe_yield() calls
         * sl_rt_gc_checkin(), which can run a full collection, and
         * every loop iteration boundary between this point and the
         * bracket opening a few lines down is a real window where the
         * PREVIOUS iteration's bracket has already closed
         * (sl_rt_safepoint_exit, at the bottom of the loop body) and
         * the CURRENT iteration's hasn't opened yet -- exactly where a
         * loop-carried GC pointer named in backedge_live_set is
         * unrooted. Scoping the unconditional call to the n == 0 path
         * only (nothing to root either way) closes that window; the
         * n > 0 path below already reaches sl_rt_maybe_yield correctly,
         * via sl_rt_safepoint_enter, AFTER its roots are linked in. */
        if (direct_yield_ok)
            emit_line(cg, "sl_rt_maybe_yield();");
        return 0;
    }
    int id = cg->tmp_id++;
    StrBuf roots;
    sb_init(&roots);
    sb_append(&roots, xasprintf("void *_sl_bp%d_roots[] = { ", id));
    for (int i = 0; i < n; i++) {
        if (i)
            sb_append(&roots, ", ");
        sb_append(&roots, xasprintf("(void *)%s", sanitize_ident(
                                                       live_set_named(
                                                           backedge_live_set, i))));
    }
    sb_append(&roots, "};");
    emit_line(cg, "%s", roots.data);
    emit_line(cg, "sl_safepoint _sl_bp%d;", id);
    emit_line(cg, "sl_rt_safepoint_enter(&_sl_bp%d, _sl_bp%d_roots, %d);", id,
              id, n);
    /* Tracks how many of these are currently open so ST_RETURN can
     * unwind exactly that many sl_rt_safepoint_exit() calls before an
     * early return from inside this loop's body -- see its own
     * comment. The caller decrements this right before emitting its
     * own closing exit() call (matching every "if (has_bp)" site). */
    cg->open_backedge_brackets++;
    return 1;
}

void gen_stmt(CG *cg, Stmt *s) {
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
            emit_line(cg, "%s %s = sl_arr_new(sizeof(%s), %d);",
                      ctype_of(cg, ann), sanitize_ident(s->as.let.name),
                      ctype_of(cg, elem), type_is_gc_ptr(cg, elem));
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
            emit_line(cg, "%s %s = sl_map_new(sizeof(%s), sizeof(%s), %d, %d, %d);",
                      ctype_of(cg, ann), sanitize_ident(s->as.let.name),
                      ctype_of(cg, k), ctype_of(cg, v), is_str(k),
                      type_is_gc_ptr(cg, k), type_is_gc_ptr(cg, v));
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
        /* base/index (and, for bytes/array, value) would otherwise be
         * embedded directly as sibling call arguments, whose relative
         * evaluation order C leaves unspecified -- sequence them, one
         * at a time (not all-generated-then-sequenced): a later one
         * that's itself a nested call needs an earlier one's temp
         * already registered by the time it's generated (see
         * gen_call's own comment on this ordering requirement).
         * base/index applies uniformly to all 3 cases below, map
         * included -- the map case's own value assignment is already
         * safely statement-sequenced afterward (separate _sl_k/_sl_v
         * statements), so it doesn't need its own temp for
         * evaluation-order, only base/index need to be protected
         * before it's generated. */
        const char *bc = ctype_of(cg, bt);
        StrBuf prelude;
        sb_init(&prelude);
        int bi_id = cg->tmp_id++;
        int ambient_mark = cg->ambient_count;
        char *b = gen_expr(cg, tgt->as.index.base);
        b = sequence_one(cg, bi_id, 0, bc, bt, b, tgt->as.index.base,
                         &prelude);

        if (is_map(bt)) {
            /* the index sequences at the map's own KEY ctype, not a
             * fixed "int" (Risk: str/other non-int key types) -- cast
             * first (same order gen_call/gen_index use: cast to the
             * destination type, then sequence the already-casted
             * value). */
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
            char *ix =
                maybe_cast(cg, k, ikt, gen_expr(cg, tgt->as.index.index));
            ix = sequence_one(cg, bi_id, 1, ctype_of(cg, k), k, ix,
                              tgt->as.index.index, &prelude);
            char *val = maybe_cast(cg, v, vt, gen_expr(cg, s->as.assign.value));
            cg->ambient_count = ambient_mark;
            emit_line(cg,
                      "({ %s%s _sl_k = %s; %s _sl_v = %s; sl_map_put(%s, "
                      "&_sl_k, &_sl_v); });",
                      prelude.data, ctype_of(cg, k), ix, ctype_of(cg, v), val,
                      b);
            break;
        }
        char *i = gen_expr(cg, tgt->as.index.index);
        i = sequence_one(cg, bi_id, 1, map_type("int"), "int", i,
                         tgt->as.index.index, &prelude);
        if (is_bytes(bt)) {
            if (!is_int(vt))
                cg_error(s->line,
                         "byte assignment requires an integer (got %s)",
                         vt);
            char *val = gen_expr(cg, s->as.assign.value);
            val = sequence_one(cg, bi_id, 2, map_type("int"), "int", val,
                               s->as.assign.value, &prelude);
            cg->ambient_count = ambient_mark;
            emit_line(cg, "%ssl_bytes_set(%s, %s, (unsigned char)(%s));",
                      prelude.data, b, i, val);
            break;
        }
        if (is_arr(bt)) {
            char *elem = arr_elem(bt);
            if (!value_assignable(elem, s->as.assign.value, vt))
                cg_error(s->line,
                         "cannot assign a value of type %s to an element "
                         "of type %s",
                         vt, elem);
            const char *ec = ctype_of(cg, elem);
            char *val = maybe_cast(cg, elem, vt, gen_expr(cg, s->as.assign.value));
            val = sequence_one(cg, bi_id, 2, ec, elem, val,
                               s->as.assign.value, &prelude);
            cg->ambient_count = ambient_mark;
            emit_line(cg,
                      "%s(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s))) = "
                      "(%s)(%s);",
                      prelude.data, ec, b, i, ec, ec, val);
            break;
        }
        cg->ambient_count = ambient_mark;
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
        cg->indent++;
        int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 1);
        cg->loop_depth++;
        int saved_loop_bp = cg->cur_loop_has_bp;
        cg->cur_loop_has_bp = has_bp;
        gen_stmts(cg, s->as.while_stmt.body->stmts,
                  s->as.while_stmt.body->count);
        cg->loop_depth--;
        cg->cur_loop_has_bp = saved_loop_bp;
        if (has_bp) {
            cg->open_backedge_brackets--;
            emit_line(cg, "sl_rt_safepoint_exit();");
        }
        cg->indent--;
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
        cg->indent++;
        int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 1);
        cg->loop_depth++;
        int saved_loop_bp = cg->cur_loop_has_bp;
        cg->cur_loop_has_bp = has_bp;
        gen_stmts(cg, s->as.for_stmt.body->stmts, s->as.for_stmt.body->count);
        cg->loop_depth--;
        cg->cur_loop_has_bp = saved_loop_bp;
        if (has_bp) {
            cg->open_backedge_brackets--;
            emit_line(cg, "sl_rt_safepoint_exit();");
        }
        cg->indent--;
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
            int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 0);
            emit_line(cg, "%s %s = (*(%s *)(void *)sl_arr_get(_sl_it%d, "
                          "_sl_i%d, sizeof(%s)));",
                      ec, vname, ec, id, id, ec);
            cg->loop_depth++;
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = has_bp;
            gen_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            cg->cur_loop_has_bp = saved_loop_bp;
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
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
            int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 0);
            emit_line(cg, "long long %s = (long long)_sl_bt%d->ptr[_sl_i%d];",
                      vname, id, id);
            cg->loop_depth++;
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = has_bp;
            gen_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            cg->cur_loop_has_bp = saved_loop_bp;
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
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
            int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 0);
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
            cg->loop_depth++;
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = has_bp;
            gen_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            cg->cur_loop_has_bp = saved_loop_bp;
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
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
        /* Tier 10: a return from inside one or more loop bodies (this
         * language has no break/continue, so guard-let's "else {
         * return; }" -- extremely common -- is the normal way to
         * leave a loop early) exits past every loop back-edge
         * bracket's own closing sl_rt_safepoint_exit() (emitted at
         * the BOTTOM of the loop body, see emit_backedge_enter's call
         * sites below), skipping it entirely. Left unclosed, that
         * bracket's own stack-allocated sl_safepoint dangles the
         * instant this function's C frame is popped -- and on a
         * long-lived worker-pool thread (Tier 9) that never resets
         * this thread-local chain between requests, the *next*
         * safepoint operation on the SAME thread walks straight into
         * it. Caught the hard way: demo/main.sl's http_worker (a
         * `while true { ... guard let cfd = v else { return; } ... }`
         * loop) crashed on a request *after* the one whose guard
         * fired, deep inside an unrelated sl_rt_safepoint_exit() call,
         * exactly this dangling-chain shape. Closing every currently-
         * open bracket right before the actual "return" (after the
         * return value, if any, is fully evaluated below -- its own
         * evaluation may still need those brackets' protection), in
         * the correct (LIFO) order via a plain count, restores the
         * invariant before control actually leaves the function --
         * sl_rt_safepoint_exit() itself takes no argument (just pops
         * one level), so N calls correctly unwind N levels regardless
         * of which loops they belonged to. */
        if (!s->as.ret.value) {
            if (cg->cur_ret)
                cg_error(s->line, "missing return value");
            for (int i = 0; i < cg->open_backedge_brackets; i++)
                emit_line(cg, "sl_rt_safepoint_exit();");
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
            for (int i = 0; i < cg->open_backedge_brackets; i++)
                emit_line(cg, "sl_rt_safepoint_exit();");
            emit_line(cg, "return %s;", val);
        }
        break;
    }
    case ST_BREAK: {
        if (cg->loop_depth == 0)
            cg_error(s->line, "'break' outside a loop");
        /* Only the INNERMOST enclosing loop's own bracket, never an
         * outer one -- cur_loop_has_bp (unlike open_backedge_brackets,
         * which ST_RETURN uses above) tracks exactly that, save/
         * restored around each loop's own body by the 5 call sites
         * above. Same reasoning as ST_RETURN's own unwind: each
         * iteration's bracket is a fresh stack-allocated sl_safepoint,
         * so leaving it open across a jump out of the loop dangles it
         * the moment this C block's stack space is reused. */
        if (cg->cur_loop_has_bp)
            emit_line(cg, "sl_rt_safepoint_exit();");
        emit_line(cg, "break;");
        break;
    }
    case ST_CONTINUE: {
        if (cg->loop_depth == 0)
            cg_error(s->line, "'continue' outside a loop");
        /* Same as ST_BREAK, but for jumping to the next iteration
         * instead of out of the loop entirely: without closing the
         * current iteration's bracket first, the next iteration's own
         * sl_rt_safepoint_enter() would push a second level on top of
         * an already-open one that nothing will ever pop (the loop's
         * own closing exit(), reached once per iteration normally, is
         * skipped exactly like a bare "continue;" skips the rest of
         * the loop body) -- one extra, permanently unpopped level per
         * skipped iteration. */
        if (cg->cur_loop_has_bp)
            emit_line(cg, "sl_rt_safepoint_exit();");
        emit_line(cg, "continue;");
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
            emit_line(cg, "%s *_sl_sa%d = (%s *)sl_gc_alloc(sizeof(%s), %s);",
                      shape->sname, id, shape->sname, shape->sname,
                      shape->has_tracer
                          ? xasprintf("sl_gc_trace_%s", shape->sname)
                          : "NULL");
            /* Tier 10: _sl_sa%d is under construction (allocated but not
             * yet fully populated) for the whole loop below -- a nested
             * call inside a LATER argument's own evaluation could
             * trigger a collection, and without this, _sl_sa%d itself
             * (and any earlier argument already stored into it) would
             * not yet be reachable from anywhere. Same fix gen_structlit
             * and gen_maplit already apply to their own under-
             * construction containers (expr.c). */
            int ambient_mark = cg->ambient_count;
            ambient_root_push(cg, xasprintf("_sl_sa%d", id));
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
            cg->ambient_count = ambient_mark;
        }
        /* Tier 11 third slice: submits to the worker pool instead of
         * creating a one-shot OS thread. No pthread_t, no per-call
         * sigmask dance, no detach -- SIGTERM/SIGINT blocking now
         * happens once, at pool startup (sl_pool_start, runtime_pool.c),
         * not per spawn call site: a pool worker is created once and
         * runs many tasks over its life, so the mask only needs baking
         * in once too. */
        emit_line(cg, "sl_rt_active_spawns_inc();");
        emit_line(cg, "sl_task_submit(%s_entry, _sl_sa%d);", shape->tname, id);
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
void gen_stmts(CG *cg, Stmt **stmts, int count) {
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

void gen_block(CG *cg, Block *b) {
    cg->indent++;
    gen_stmts(cg, b->stmts, b->count);
    cg->indent--;
}
