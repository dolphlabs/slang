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
 * right at loop-body entry. ST_FOR_IN hoists one bracket around the
 * whole C for-loop and roots the iterable alias there, so it does not
 * use this per-iteration enter. ST_WHILE/ST_FOR have no hidden alias
 * -- a numeric range loop's bounds are plain `long long`s -- so they
 * pass 1. */
static int emit_backedge_enter(CG *cg, void *backedge_live_set,
                                int direct_yield_ok, int edge_id,
                                const char *extra_root) {
    int nnames = live_set_nnamed(backedge_live_set);
    int n = extra_root ? 1 : 0;
    for (int i = 0; i < nnames; i++)
        n += count_named_gc_roots(cg, live_set_named(backedge_live_set, i));
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
            emit_line(cg, "if ((++_sl_ec%d & SL_PREEMPT_SAMPLE_MASK) == 0) "
                          "sl_rt_maybe_yield();",
                      edge_id);
        return 0;
    }
    int id = cg->tmp_id++;
    StrBuf roots;
    sb_init(&roots);
    sb_append(&roots, xasprintf("void *_sl_bp%d_roots[] = { ", id));
    int wrote = 0;
    for (int i = 0; i < nnames; i++)
        append_named_gc_roots(cg, &roots, live_set_named(backedge_live_set, i),
                              &wrote);
    if (extra_root) {
        if (wrote++)
            sb_append(&roots, ", ");
        sb_append(&roots, xasprintf("(void *)%s", extra_root));
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

static void gen_scoped_block(CG *cg, Block *b) {
    var_scope_push(cg);
    int from = cg->vars.count;
    gen_block(cg, b);
    emit_scope_drops(cg, from);
    var_scope_pop(cg);
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
            var_redecl_check(cg, s->as.let.name, s->line);
            var_push(cg, s->as.let.name, ann);
            emit_drop_flag(cg, s->as.let.name);
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
            var_redecl_check(cg, s->as.let.name, s->line);
            var_push(cg, s->as.let.name, ann);
            emit_drop_flag(cg, s->as.let.name);
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
        move_consume(cg, s->as.let.init);
        if (s->as.let.stack) {
            char *inner;
            TypeWrap w = type_wrap(t, &inner);
            int id = cg->tmp_id++;
            const char *pc;
            if (w == TW_OWN || w == TW_GC) {
                pc = ctype_of(cg, inner);
                init = maybe_cast(cg, inner, it, init);
            } else {
                pc = mangle_struct(t);
                cg->stack_box = 1;
                init = gen_expr(cg, s->as.let.init);
                cg->stack_box = 0;
            }
            cg->expect = saved_expect;
            var_redecl_check(cg, s->as.let.name, s->line);
            var_push(cg, s->as.let.name, t);
            cg->vars.items[cg->vars.count - 1].stack = 1;
            emit_line(cg, "%s _sl_stk%d = %s;", pc, id, init);
            emit_line(cg, "%s %s = &_sl_stk%d;", ctype_of(cg, t),
                      sanitize_ident(s->as.let.name), id);
            emit_drop_flag(cg, s->as.let.name);
            break;
        }
        init = maybe_cast(cg, t, it, init);
        cg->expect = saved_expect;
        var_redecl_check(cg, s->as.let.name, s->line);
        var_push(cg, s->as.let.name, t);
        if (s->as.let.init->kind == EX_IDENT) {
            VarSym *src = var_find(cg, s->as.let.init->as.ident.name);
            if (src)
                cg->vars.items[cg->vars.count - 1].stack = src->stack;
        }
        emit_line(cg, "%s %s = %s;", ctype_of(cg, t),
                  sanitize_ident(s->as.let.name), init);
        emit_drop_flag(cg, s->as.let.name);
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
                StructDef *sd = struct_of_type(cg, bt);
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
                move_consume(cg, s->as.assign.value);
                emit_line(cg, "%s%s%s = %s;", b, struct_access(cg, bt),
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
            int same = s->as.assign.value->kind == EX_IDENT &&
                       !strcmp(s->as.assign.value->as.ident.name, name);
            if (!same)
                emit_drop_overwrite(cg, name);
            move_consume(cg, s->as.assign.value);
            emit_line(cg, "%s = %s;", sanitize_ident(name), val);
            move_reinit(cg, name);
            break;
        }
        if (tgt->kind == EX_UNARY && !strcmp(tgt->as.unary.op, "*")) {
            const char *pt = infer_type(cg, tgt->as.unary.operand);
            char *inner;
            TypeWrap w = type_wrap(pt, &inner);
            if (w == TW_NONE)
                cg_error(s->line, "cannot dereference a value of type %s",
                         pt);
            if (w == TW_REF)
                cg_error(s->line,
                         "cannot assign through a shared borrow of type %s",
                         pt);
            if (type_is_raw_ptr(pt) && !tgt->in_unsafe)
                cg_error(s->line,
                         "dereference of a raw pointer requires an "
                         "'unsafe' block");
            const char *se = expect_push(cg, inner);
            const char *vt = infer_type(cg, s->as.assign.value);
            cg->expect = se;
            if (!value_assignable(inner, s->as.assign.value, vt))
                cg_error(s->line,
                         "cannot assign a value of type %s through a "
                         "pointer to %s",
                         vt, inner);
            char *p = gen_expr(cg, tgt->as.unary.operand);
            const char *se2 = expect_push(cg, inner);
            char *val = maybe_cast(cg, inner, vt,
                                   gen_expr(cg, s->as.assign.value));
            cg->expect = se2;
            move_consume(cg, s->as.assign.value);
            emit_line(cg, "*(%s) = %s;", p, val);
            break;
        }
        if (tgt->kind == EX_FIELD) {
            /* struct field target: p.x = v */
            const char *bt = infer_type(cg, tgt->as.field.base);
            StructDef *sd = struct_of_type(cg, bt);
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
            move_consume(cg, s->as.assign.value);
            emit_line(cg, "%s%s%s = %s;", b, struct_access(cg, bt),
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
            /* Tier 11 eighth slice: sl_map_put itself was never wrapped in
             * a safepoint bracket, unlike every other GC-triggering call
             * this codegen ever emits (gen_call's own wrap_safepoint
             * covers every ordinary user/method/builtin call) -- this is
             * a hand-emitted statement, not an EX_CALL-shaped node, so it
             * never went through that path at all. _sl_k/_sl_v are
             * genuinely unrooted between here (prelude's own inner
             * brackets, if any -- e.g. around a call that produced ix --
             * have already closed) and sl_map_put's own internal use of
             * them; sl_map_put can itself call sl_gc_alloc (via
             * sl_map_grow), and does not root the new key/value in its
             * own table until after that grow completes. Cooperative
             * preemption alone never exposed this -- nothing calls
             * sl_rt_gc_checkin between here and sl_map_put returning, and
             * sl_map_put/sl_map_grow are hand-written runtime functions
             * with no checkin call of their own -- but async preemption
             * can interrupt at any instruction boundary, including deep
             * inside sl_map_grow, with no such guarantee. Root-caused via
             * concurrent_compute's own map[str]int-building loop
             * (m[to_str(i)] = i), confirmed directly with AddressSanitizer
             * (heap-use-after-free in sl_hash_str, reading a str key that
             * had already been swept). Fixed the same way every other
             * risky call site in this codebase already is: an explicit
             * bracket around the call, rooting whichever of _sl_k/_sl_v
             * are actually GC pointers (a plain int/bool/float one is
             * never registered -- same discipline sequence_one's own
             * comment states for exactly this reason). */
            int k_is_ptr = type_is_gc_ptr(cg, k);
            int v_is_ptr = type_is_gc_ptr(cg, v);
            if (k_is_ptr || v_is_ptr) {
                StrBuf roots;
                sb_init(&roots);
                if (k_is_ptr)
                    sb_append(&roots, "(void *)_sl_k");
                if (v_is_ptr) {
                    if (k_is_ptr)
                        sb_append(&roots, ", ");
                    sb_append(&roots, "(void *)_sl_v");
                }
                emit_line(cg,
                          "({ %s%s _sl_k = %s; %s _sl_v = %s; "
                          "void *_sl_mp_roots[] = { %s }; sl_safepoint _sl_mp_sp; "
                          "sl_rt_safepoint_enter(&_sl_mp_sp, _sl_mp_roots, %d); "
                          "sl_map_put(%s, &_sl_k, &_sl_v); "
                          "sl_rt_safepoint_exit(); });",
                          prelude.data, ctype_of(cg, k), ix, ctype_of(cg, v),
                          val, roots.data, k_is_ptr + v_is_ptr, b);
            } else {
                emit_line(cg,
                          "({ %s%s _sl_k = %s; %s _sl_v = %s; sl_map_put(%s, "
                          "&_sl_k, &_sl_v); });",
                          prelude.data, ctype_of(cg, k), ix, ctype_of(cg, v),
                          val, b);
            }
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
        if (is_wire(bt)) {
            if (!is_int(vt))
                cg_error(s->line,
                         "wire assignment requires an integer (got %s)",
                         vt);
            char *val = gen_expr(cg, s->as.assign.value);
            val = sequence_one(cg, bi_id, 2, map_type("int"), "int", val,
                               s->as.assign.value, &prelude);
            cg->ambient_count = ambient_mark;
            emit_line(cg, "%ssl_wire_set(%s, %s, (unsigned char)(%s));",
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
            char *at = panic_at(cg, s->line);
            emit_line(cg,
                      "%s(*(%s *)(void *)sl_arr_get(%s, %s, sizeof(%s), %s)) = "
                      "(%s)(%s);",
                      prelude.data, ec, b, i, ec, at, ec, val);
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
        emit_line(cg, "if (%s) {", strip_outer_parens(cond));
        gen_scoped_block(cg, s->as.if_stmt.then_blk);
        if (s->as.if_stmt.else_blk) {
            emit_line(cg, "} else {");
            gen_scoped_block(cg, s->as.if_stmt.else_blk);
        }
        emit_line(cg, "}");
        break;
    }
    case ST_WHILE: {
        const char *ct = infer_type(cg, s->as.while_stmt.cond);
        if (strcmp(ct, "bool"))
            cg_error(s->line, "while condition must be bool (got %s)", ct);
        char *cond = gen_expr(cg, s->as.while_stmt.cond);
        int scalar = live_set_nnamed(s->backedge_live_set) == 0;
        int poll = !(scalar && cg->loop_depth > 0);
        int eid = 0;
        if (scalar && poll) {
            eid = cg->tmp_id++;
            emit_line(cg, "unsigned long _sl_ec%d = 0;", eid);
        }
        emit_line(cg, "while (%s) {", strip_outer_parens(cond));
        cg->indent++;
        int has_bp = emit_backedge_enter(cg, s->backedge_live_set, poll, eid,
                                        NULL);
        cg->loop_depth++;
        int saved_loop_bp = cg->cur_loop_has_bp;
        cg->cur_loop_has_bp = has_bp;
        var_scope_push(cg);
        {
            int from = cg->vars.count;
            gen_stmts(cg, s->as.while_stmt.body->stmts,
                      s->as.while_stmt.body->count);
            emit_scope_drops(cg, from);
        }
        var_scope_pop(cg);
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
        char *start = gen_expr(cg, s->as.for_stmt.start);
        char *end = gen_expr(cg, s->as.for_stmt.end);
        var_scope_push(cg);
        var_redecl_check(cg, s->as.for_stmt.name, s->line);
        var_push(cg, s->as.for_stmt.name, "int");
        char *endvar = xasprintf("sl_end_%d", cg->tmp_id++);
        const char *op = s->as.for_stmt.inclusive ? "<=" : "<";
        char *vname = sanitize_ident(s->as.for_stmt.name);
        emit_line(cg, "{");
        cg->indent++;
        emit_line(cg, "long long %s = %s;", endvar, end);
        int eid = 0;
        if (live_set_nnamed(s->backedge_live_set) == 0) {
            eid = cg->tmp_id++;
            emit_line(cg, "unsigned long _sl_ec%d = 0;", eid);
        }
        emit_line(cg, "for (long long %s = %s; %s %s %s; %s++) {", vname,
                  start, vname, op, endvar, vname);
        cg->indent++;
        int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 1, eid,
                                        NULL);
        cg->loop_depth++;
        int saved_loop_bp = cg->cur_loop_has_bp;
        cg->cur_loop_has_bp = has_bp;
        var_scope_push(cg);
        {
            int from = cg->vars.count;
            gen_stmts(cg, s->as.for_stmt.body->stmts,
                      s->as.for_stmt.body->count);
            emit_scope_drops(cg, from);
        }
        var_scope_pop(cg);
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
        var_scope_pop(cg);
        break;
    }
    case ST_FOR_IN: {
        const char *it = infer_type(cg, s->as.for_in.iter);
        int id = cg->tmp_id++;
        char *iter = gen_expr(cg, s->as.for_in.iter);
        char *vname = sanitize_ident(s->as.for_in.name);
        var_scope_push(cg);
        if (is_arr(it)) {
            char *elem = arr_elem(it);
            const char *ec = ctype_of(cg, elem);
            var_redecl_check(cg, s->as.for_in.name, s->line);
            var_push(cg, s->as.for_in.name, elem);
            emit_line(cg, "{");
            cg->indent++;
            emit_line(cg, "sl_arr *_sl_it%d = %s;", id, iter);
            int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 0, 0,
                                            xasprintf("_sl_it%d", id));
            int eid = 0;
            if (has_bp) {
                eid = cg->tmp_id++;
                emit_line(cg, "unsigned long _sl_ec%d = 0;", eid);
            }
            emit_line(cg,
                      "for (long long _sl_i%d = 0; _sl_i%d < _sl_it%d->len; "
                      "_sl_i%d++) {",
                      id, id, id, id);
            cg->indent++;
            if (has_bp)
                emit_line(cg,
                          "if ((++_sl_ec%d & SL_PREEMPT_SAMPLE_MASK) == 0) "
                          "sl_rt_maybe_yield();",
                          eid);
            emit_line(cg, "%s %s = (*(%s *)(void *)sl_arr_at(_sl_it%d, "
                          "_sl_i%d, sizeof(%s)));",
                      ec, vname, ec, id, id, ec);
            cg->loop_depth++;
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = 0;
            gen_scoped_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            cg->cur_loop_has_bp = saved_loop_bp;
            cg->indent--;
            emit_line(cg, "}");
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
            cg->indent--;
            emit_line(cg, "}");
            var_scope_pop(cg);
            break;
        }
        if (is_bytes(it)) {
            var_redecl_check(cg, s->as.for_in.name, s->line);
            var_push(cg, s->as.for_in.name, "int");
            emit_line(cg, "{");
            cg->indent++;
            emit_line(cg, "sl_bytes *_sl_bt%d = %s;", id, iter);
            int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 0, 0,
                                            xasprintf("_sl_bt%d", id));
            int eid = 0;
            if (has_bp) {
                eid = cg->tmp_id++;
                emit_line(cg, "unsigned long _sl_ec%d = 0;", eid);
            }
            emit_line(cg,
                      "for (long long _sl_i%d = 0; _sl_i%d < _sl_bt%d->len; "
                      "_sl_i%d++) {",
                      id, id, id, id);
            cg->indent++;
            if (has_bp)
                emit_line(cg,
                          "if ((++_sl_ec%d & SL_PREEMPT_SAMPLE_MASK) == 0) "
                          "sl_rt_maybe_yield();",
                          eid);
            emit_line(cg, "long long %s = (long long)_sl_bt%d->ptr[_sl_i%d];",
                      vname, id, id);
            cg->loop_depth++;
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = 0;
            gen_scoped_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            cg->cur_loop_has_bp = saved_loop_bp;
            cg->indent--;
            emit_line(cg, "}");
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
            cg->indent--;
            emit_line(cg, "}");
            var_scope_pop(cg);
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
            var_redecl_check(cg, s->as.for_in.name, s->line);
            var_push(cg, s->as.for_in.name, k);
            var_redecl_check(cg, s->as.for_in.name2, s->line);
            var_push(cg, s->as.for_in.name2, v);
            emit_line(cg, "{");
            cg->indent++;
            emit_line(cg, "sl_map *_sl_m%d = %s;", id, iter);
            int has_bp = emit_backedge_enter(cg, s->backedge_live_set, 0, 0,
                                            xasprintf("_sl_m%d", id));
            int eid = 0;
            if (has_bp) {
                eid = cg->tmp_id++;
                emit_line(cg, "unsigned long _sl_ec%d = 0;", eid);
            }
            emit_line(cg,
                      "for (long long _sl_i%d = 0; _sl_i%d < _sl_m%d->count; "
                      "_sl_i%d++) {",
                      id, id, id, id);
            cg->indent++;
            if (has_bp)
                emit_line(cg,
                          "if ((++_sl_ec%d & SL_PREEMPT_SAMPLE_MASK) == 0) "
                          "sl_rt_maybe_yield();",
                          eid);
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
            cg->cur_loop_has_bp = 0;
            gen_scoped_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            cg->cur_loop_has_bp = saved_loop_bp;
            cg->indent--;
            emit_line(cg, "}");
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
            cg->indent--;
            emit_line(cg, "}");
            var_scope_pop(cg);
            break;
        }
        var_scope_pop(cg);
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
            emit_scope_drops(cg, 0);
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
            move_consume(cg, s->as.ret.value);
            emit_line(cg, "%s _sl_rv = %s;", ctype_of(cg, cg->cur_ret),
                      val);
            for (int i = 0; i < cg->open_backedge_brackets; i++)
                emit_line(cg, "sl_rt_safepoint_exit();");
            emit_scope_drops(cg, 0);
            emit_line(cg, "return _sl_rv;");
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
        emit_scope_drops(cg, cg->var_scope_sp ? cg->var_scopes[cg->var_scope_sp - 1] : 0);
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
        emit_scope_drops(cg, cg->var_scope_sp ? cg->var_scopes[cg->var_scope_sp - 1] : 0);
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
        /* Cast to void: a statement call whose value is discarded is
           usually a GC-bracketed statement expression -- ({ ...; x; })
           -- and clang's default -Wunused-value fires on every one of
           them. The cast says "discarding is intended", which it is:
           the slang program wrote the call as a statement. */
        emit_line(cg, "(void)(%s);", code);
        break;
    }
    case ST_GUARD_LET:
        /* handled by gen_stmts, which needs to see the statements that
         * follow it in the same block */
        break;
    case ST_SPAWN: {
        Expr *call = s->as.spawn.call;
        const char *name = call->as.call.name;
        FuncSig *sig = spawn_target(cg, call, s->line);
        int nargs = call->as.call.nargs;
        SpawnShape *shape = spawn_shape_for(cg, sig);
        int id = cg->tmp_id++;
        emit_line(cg, "{");
        cg->indent++;
        emit_line(cg, "%s _sl_sa%d;", shape->sname, id);
        emit_line(cg, "_sl_sa%d.join = NULL;", id);
        int ambient_mark = cg->ambient_count;
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
            emit_line(cg, "_sl_sa%d.a%d = %s;", id, i, a);
            if (type_is_gc_ptr(cg, sig->param_slang[i]))
                ambient_root_push(cg, xasprintf("_sl_sa%d.a%d", id, i));
        }
        cg->ambient_count = ambient_mark;
        move_consume(cg, call);
        emit_line(cg, "sl_rt_active_spawns_inc();");
        emit_line(cg, "sl_task_submit_copy(%s_entry, &_sl_sa%d, sizeof(_sl_sa%d), sl_gc_trace_%s);",
                  shape->tname, id, id, shape->sname);
        cg->indent--;
        emit_line(cg, "}");
        break;
    }
    case ST_UNSAFE:
        emit_line(cg, "{");
        gen_scoped_block(cg, s->as.unsafe_blk.body);
        emit_line(cg, "}");
        break;
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
static int expr_same(Expr *a, Expr *b) {
    if (!a || !b || a->kind != b->kind)
        return 0;
    switch (a->kind) {
    case EX_INT:
        return a->as.int_lit.value == b->as.int_lit.value;
    case EX_FLOAT:
        return a->as.float_lit.value == b->as.float_lit.value;
    case EX_BOOL:
        return a->as.bool_lit.value == b->as.bool_lit.value;
    case EX_STRING:
        return !strcmp(a->as.str_lit.value, b->as.str_lit.value);
    case EX_BYTES:
        return a->as.bytes_lit.len == b->as.bytes_lit.len &&
               !memcmp(a->as.bytes_lit.data, b->as.bytes_lit.data,
                       (size_t)a->as.bytes_lit.len);
    case EX_IDENT:
        return !strcmp(a->as.ident.name, b->as.ident.name);
    case EX_UNARY:
        return !strcmp(a->as.unary.op, b->as.unary.op) &&
               expr_same(a->as.unary.operand, b->as.unary.operand);
    case EX_BINARY:
        return !strcmp(a->as.binary.op, b->as.binary.op) &&
               expr_same(a->as.binary.lhs, b->as.binary.lhs) &&
               expr_same(a->as.binary.rhs, b->as.binary.rhs);
    case EX_CALL:
        if (strcmp(a->as.call.name, b->as.call.name) ||
            a->as.call.nargs != b->as.call.nargs)
            return 0;
        for (int i = 0; i < a->as.call.nargs; i++)
            if (!expr_same(a->as.call.args[i], b->as.call.args[i]))
                return 0;
        return 1;
    case EX_CAST:
        return !strcmp(a->as.cast.ty, b->as.cast.ty) &&
               expr_same(a->as.cast.operand, b->as.cast.operand);
    case EX_INDEX:
        return expr_same(a->as.index.base, b->as.index.base) &&
               expr_same(a->as.index.index, b->as.index.index);
    case EX_FIELD:
        return !strcmp(a->as.field.name, b->as.field.name) &&
               expr_same(a->as.field.base, b->as.field.base);
    default:
        return 0;
    }
}

static void gen_guard_else_body(CG *cg, Stmt *s, int gid, const char *acc,
                                int is_res) {
    if (s->as.guard_let.err_name) {
        if (!is_res)
            cg_error(s->line,
                     "else let error binding requires a result value");
        Expr *ee = s->as.guard_let.err_expr;
        if (!ee || ee->kind != EX_CALL || ee->as.call.nargs != 1 ||
            strcmp(ee->as.call.name, "err_of"))
            cg_error(s->line,
                     "else let binding must be err_of(<same expression>)");
        if (!expr_same(ee->as.call.args[0], s->as.guard_let.expr))
            cg_error(s->line,
                     "err_of argument must match the guard expression");
        char *tv, *tev;
        result_te(infer_type(cg, s->as.guard_let.expr), &tv, &tev);
        const char *ec = ctype_of(cg, tev);
        var_redecl_check(cg, s->as.guard_let.err_name, s->line);
        var_push(cg, s->as.guard_let.err_name, tev);
        emit_drop_flag(cg, s->as.guard_let.err_name);
        emit_line(cg, "%s %s = _sl_g%d%se;", ec,
                  sanitize_ident(s->as.guard_let.err_name), gid, acc);
    }
    int from = cg->vars.count;
    gen_stmts(cg, s->as.guard_let.body->stmts, s->as.guard_let.body->count);
    emit_scope_drops(cg, from);
}

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
        const char *acc = type_is_gc_ptr(cg, et) ? "->" : ".";
        emit_line(cg, "%s _sl_g%d = %s;", oc, id, e);
        emit_line(cg, "if (!(_sl_g%d%s%s)) {", id, acc, is_res ? "ok" : "has");
        cg->indent++;
        var_scope_push(cg);
        gen_guard_else_body(cg, s, id, acc, is_res);
        var_scope_pop(cg);
        cg->indent--;
        emit_line(cg, "}");
        var_redecl_check(cg, s->as.guard_let.name, s->line);
        int from = cg->vars.count;
        var_push(cg, s->as.guard_let.name, inner);
        emit_drop_flag(cg, s->as.guard_let.name);
        emit_line(cg, "%s %s = _sl_g%d%sv;", ic,
                  sanitize_ident(s->as.guard_let.name), id, acc);
        gen_stmts(cg, stmts + i + 1, count - i - 1);
        emit_scope_drops(cg, from);
        cg->vars.count = from;
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
