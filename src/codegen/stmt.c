/* Split out of the original monolithic codegen.c -- see
 * internal.h for the shared CG state and cross-file API. */

#include "internal.h"
#include "../diag.h"
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

/* Tier 12 (leaf-loop poll): hoisted bracket + per-iteration cheap poll.
 * Emits the roots array + sl_safepoint + enter ONCE plus the task
 * variable (one TLS read for the whole loop), then returns the bracket
 * id for the per-iteration poll (emit_leaf_poll) and the loop-end
 * exit. The bracket stays open across all iterations, so loop-carried
 * roots are linked for the loop's whole duration; the per-iteration
 * poll re-snapshots reassigned pointers (see emit_leaf_poll).
 * Balanced by construction: one enter before the loop, one exit after.
 *
 * SCOPE WARNING: the emitted declarations live in the caller's C block
 * and must be visible at BOTH the loop head (enter) and after the loop
 * (exit). Every slang block that generates braces (if arms, loop
 * bodies via gen_scoped_block, switch arms) opens a NEW C block — a
 * leaf loop nested inside one is fine (enter and exit are both inside
 * that same block), because the exit is emitted right after the loop
 * within the same generation of the same block. The declarations use
 * unique tmp_id suffixes, so nesting never collides. */
static int emit_leaf_bracket(CG *cg, void *backedge_live_set) {
    int nnames = live_set_nnamed(backedge_live_set);
    int n = 0;
    for (int i = 0; i < nnames; i++)
        n += count_named_gc_roots(cg, live_set_named(backedge_live_set, i));
    int id = cg->tmp_id++;
    StrBuf roots;
    sb_init(&roots);
    sb_append(&roots, xasprintf("void *_sl_lb%d_roots[] = { ", id));
    int wrote = 0;
    for (int i = 0; i < nnames; i++)
        append_named_gc_roots(cg, &roots, live_set_named(backedge_live_set, i),
                              &wrote);
    sb_append(&roots, "};");
    emit_line(cg, "%s", roots.data);
    emit_line(cg, "sl_safepoint _sl_lb%d;", id);
    emit_line(cg, "sl_rt_safepoint_enter(&_sl_lb%d, _sl_lb%d_roots, %d);", id,
              id, n);
    /* Resolve the task once for the per-iteration sampled yield
     * (sl_rt_poll_yield takes it as a parameter): one TLS read for the
     * whole loop instead of one per sample. sl_task* is
     * migration-stable (only the TLS slot address is thread-affine),
     * so holding it across iterations is sound — same reasoning as
     * sl_rt_maybe_yield_t's own parameter. */
    emit_line(cg, "sl_task *_sl_lb_task%d = sl_rt_cur();", id);
    cg->open_backedge_brackets++;
    return id;
}

/* Tier 12 per-iteration poll for a leaf loop whose bracket (emit_leaf_
 * bracket) is hoisted around the loop. Rebuilds the roots array from
 * the CURRENT variable values (plain pointer stores into a fresh stack
 * array, no TLS, no call) so reassigned pointer variables stay current,
 * then: if a collection is requested, take the full enter/exit path
 * (link + check-in, which also runs the sampled preemption check);
 * else only the 1-in-1024 preemption sample fires, calling the sampled
 * yield directly. Fast path per iteration: one small stack array + one
 * relaxed-load call + one counter increment — no TLS read, no stack
 * probe.
 *
 * The slow path's nested enter/exit pair balances within the iteration
 * (enter pushes, exit pops the same level); the hoisted bracket stays
 * open beneath it. bid selects the hoisted task variable for the
 * sampled yield; eid suffixes the nested safepoint and the roots
 * array. The sample counter (_sl_lp_ec) is declared ONCE per loop by
 * the loop's own code below (not here), so it persists across
 * iterations — declaring it inside this per-iteration block would
 * reset it to 0 every iteration and sample every time. Emits nothing
 * if there are no roots (scalar loops keep their sampled maybe_yield
 * instead). */
static void emit_leaf_poll(CG *cg, void *backedge_live_set, int bid,
                           int eid) {
    int nnames = live_set_nnamed(backedge_live_set);
    int n = 0;
    for (int i = 0; i < nnames; i++)
        n += count_named_gc_roots(cg, live_set_named(backedge_live_set, i));
    if (n == 0)
        return;
    /* NOTE: flat inside the loop body — no wrapping brace. An earlier
     * draft opened a { here and closed it in the loop-end code; the
     * extra close landed after the loop and closed the FUNCTION early
     * (lt6: "use of undeclared identifier 'sum'"). This function opens
     * NOTHING it doesn't close: roots array + if/else balance inline. */
    StrBuf roots;
    sb_init(&roots);
    sb_append(&roots, xasprintf("void *_sl_lp%d_roots[] = { ", eid));
    int wrote = 0;
    for (int i = 0; i < nnames; i++)
        append_named_gc_roots(cg, &roots, live_set_named(backedge_live_set, i),
                              &wrote);
    sb_append(&roots, "};");
    emit_line(cg, "%s", roots.data);
    emit_line(cg, "if (sl_gc_poll_needed()) {");
    cg->indent++;
    emit_line(cg, "sl_safepoint _sl_lp%d;", eid);
    emit_line(cg, "sl_rt_safepoint_enter(&_sl_lp%d, _sl_lp%d_roots, %d);",
              eid, eid, n);
    emit_line(cg, "sl_rt_safepoint_exit();");
    cg->indent--;
    emit_line(cg, "} else if ((++_sl_lp_ec%d & SL_PREEMPT_SAMPLE_MASK) == 0) {",
              eid);
    cg->indent++;
    emit_line(cg, "sl_rt_poll_yield(_sl_lb_task%d);", bid);
    cg->indent--;
    emit_line(cg, "}");
}

static void gen_scoped_block(CG *cg, Block *b) {
    var_scope_push(cg);
    int from = cg->vars.count;
    gen_block(cg, b);
    emit_scope_drops(cg, from);
    var_scope_pop(cg);
}

/* Break-target stack: loops push kind 0 around their bodies (see the
 * three loop cases below), switches push kind 1 around their arms
 * (see ST_SWITCH). ST_BREAK reads the top; ST_CONTINUE scans down
 * for the nearest loop. */
static void break_push(CG *cg, int kind, const char *end) {
    if (cg->break_len == cg->break_cap) {
        cg->break_cap = cg->break_cap ? cg->break_cap * 2 : 8;
        cg->break_kind = (int *)xrealloc(cg->break_kind,
                                        (size_t)cg->break_cap * sizeof(int));
        cg->break_end = (char **)xrealloc(cg->break_end,
                                         (size_t)cg->break_cap *
                                             sizeof(char *));
        cg->break_used = (int *)xrealloc(cg->break_used,
                                        (size_t)cg->break_cap * sizeof(int));
    }
    cg->break_kind[cg->break_len] = kind;
    cg->break_end[cg->break_len] = end ? xstrdup(end) : NULL;
    cg->break_used[cg->break_len] = 0;
    cg->break_len++;
}

static void break_pop(CG *cg) { cg->break_len--; }

static void check_guard_else_leaves(CG *cg, Block *body, int line);
static void gen_if_let(CG *cg, Stmt *s);

/* Tier 12 (leaf-loop poll): whether an expression can run without any
 * call, allocation, or park. Conservative: anything unrecognized
 * returns 0 (full safepoint, today's behavior). Every EX_CALL returns
 * 0 — even len(), which lowers to a bracketed expression. */
static int expr_is_leaf(CG *cg, Expr *e);
static int block_is_leaf(CG *cg, Block *b);
static int stmt_is_leaf(CG *cg, Stmt *s);

static int expr_is_leaf(CG *cg, Expr *e) {
    if (!e)
        return 1;
    switch (e->kind) {
    case EX_INT:
    case EX_FLOAT:
    case EX_STRING:
    case EX_BYTES:
    case EX_BOOL:
    case EX_IDENT:
        return 1;
    case EX_BINARY: {
        const char *op = e->as.binary.op;
        if (!strcmp(op, "??"))
            return expr_is_leaf(cg, e->as.binary.lhs) &&
                   expr_is_leaf(cg, e->as.binary.rhs);
        /* Concat (str/bytes/list) allocates — not a leaf. NOTE: no
         * infer_type call here. expr_is_leaf runs DURING codegen's
         * statement walk, where the variable scope at the loop head
         * does not include bindings declared INSIDE the loop body
         * (e.g. `let id = old[i]` in batch's user_grow): inferring
         * the operand type would resolve those names against the
         * wrong scope and fail the compile ("undefined variable").
         * Instead match only on the operator: every non-+ binary op
         * is pure (comparison, arithmetic, logic); + is assumed to
         * allocate (string/bytes/list concat) and disqualifies.
         * Numeric + pays the price of a missed optimization — rare
         * in scan loops, and soundness beats coverage. */
        if (!strcmp(op, "+"))
            return 0;
        return expr_is_leaf(cg, e->as.binary.lhs) &&
               expr_is_leaf(cg, e->as.binary.rhs);
    }
    case EX_UNARY:
        return expr_is_leaf(cg, e->as.unary.operand);
    case EX_CAST:
        return expr_is_leaf(cg, e->as.cast.operand);
    case EX_FIELD:
        return expr_is_leaf(cg, e->as.field.base);
    case EX_INDEX: {
        /* Bounds-checked but non-allocating, non-parking: the check
         * panics (never returns) on failure, so no safepoint is needed
         * on that path. FIELD-INDEXING (hd.cl_lo etc. — the parser
         * folds `p.x` into EX_IDENT, resolved via var_find) is NOT
         * covered here; this is only container indexing.
         * NOTE: no infer_type here (scope reason — see EX_BINARY):
         * every index form codegen lowers without a call (bytes,
         * list, str, wire) is leaf-eligible; map indexing contains a
         * call to the miss reporter on the failure path — but that
         * path never returns, so it needs no safepoint; treat ALL
         * indexing as leaf iff base and index are. */
        return expr_is_leaf(cg, e->as.index.base) &&
               expr_is_leaf(cg, e->as.index.index);
    }
    case EX_SLICE:
        return expr_is_leaf(cg, e->as.slice.base) &&
               expr_is_leaf(cg, e->as.slice.start) &&
               expr_is_leaf(cg, e->as.slice.end);
    case EX_CALL:
    case EX_METHOD:
    case EX_SPAWN: {
        /* Every call lowers to code with its own bracket or a park —
         * never a leaf. One exception: len(x) is a pure read of an
         * already-live value (a field load: ->len), bracketed only
         * because every builtin is uniformly wrapped. Treating it as
         * a leaf is sound: it allocates nothing, parks nothing, and
         * its argument was already evaluated. All other calls —
         * user, native, method, ctor, print — return 0. */
        if (e->kind == EX_CALL && e->as.call.name &&
            !strcmp(e->as.call.name, "len") && e->as.call.nargs == 1 &&
            !e->as.call.callee)
            return expr_is_leaf(cg, e->as.call.args[0]);
        return 0;
    }
    case EX_LIST:
    case EX_MAPLIT:
    case EX_STRUCTLIT:
        /* Allocations. Never leaves. */
        return 0;
    case EX_SWITCH: {
        if (!expr_is_leaf(cg, e->as.switch_expr.scrut))
            return 0;
        for (int i = 0; i < e->as.switch_expr.ncases; i++) {
            for (int j = 0; j < e->as.switch_expr.cases[i].nvals; j++) {
                if (!expr_is_leaf(cg, e->as.switch_expr.cases[i].vals[j]))
                    return 0;
            }
            if (!expr_is_leaf(cg, e->as.switch_expr.cases[i].value))
                return 0;
        }
        return expr_is_leaf(cg, e->as.switch_expr.def);
    }
    }
    return 0;
}

/* A statement is a leaf iff it generates no call, allocation, or park.
 * ST_SPAWN/ST_SELECT are never leaves (spawn submits work; select
 * parks); decls never appear in bodies. print/println are calls.
 * Everything else recurses. */
static int stmt_is_leaf(CG *cg, Stmt *s) {
    if (!s)
        return 1;
    switch (s->kind) {
    case ST_LET:
        return expr_is_leaf(cg, s->as.let.init);
    case ST_ASSIGN:
        return expr_is_leaf(cg, s->as.assign.target) &&
               expr_is_leaf(cg, s->as.assign.value);
    case ST_IF:
        return expr_is_leaf(cg, s->as.if_stmt.cond) &&
               block_is_leaf(cg, s->as.if_stmt.then_blk) &&
               block_is_leaf(cg, s->as.if_stmt.else_blk);
    case ST_WHILE:
    case ST_FOR:
    case ST_FOR_IN:
        /* Nested loops contain an inner back-edge safepoint (their own
         * bracket or poll): the outer loop is NOT a leaf. Without this
         * the outer would hoist its bracket across the inner loop's
         * own enter/exit — sound but the inner's per-iteration
         * enter/exit already pays the full cost, so the outer poll
         * saves nothing and doubles bracket traffic. More importantly
         * the inner loop's own bracket management (has_bp,
         * open_backedge_brackets) composes correctly only when the
         * outer uses the standard path. Revisit if profiles show
         * doubly-nested scan loops matter. (ST_FOR_IN as an OUTER
         * loop keeps the standard hoisted-iterable bracket below —
         * this only governs the leaf-poll path.) */
        return 0;
    case ST_RETURN:
        return s->as.ret.value ? expr_is_leaf(cg, s->as.ret.value) : 1;
    case ST_BREAK:
    case ST_CONTINUE:
        /* break/continue THEMSELVES emit no call/alloc/park — but inside
         * a leaf loop they close the HOISTED bracket (cur_loop_has_bp
         * is set, ST_BREAK emits sl_rt_safepoint_exit). A leaf loop
         * whose body can break/continue would then double-exit: once
         * at the break/continue, once at the loop-end exit. The
         * per-iteration bracket has the same shape (break closes that
         * iteration's bracket, loop-end exit closes... no — for the
         * per-iteration bracket the loop-end exit is INSIDE the loop,
         * so break's exit + loop-end exit are DIFFERENT brackets).
         * For the hoisted bracket they are the SAME bracket → a body
         * containing break/continue disqualifies the loop. The common
         * scan loops (batch parser, http header scan... except the
         * router's sp2 loop, which breaks) don't break; the router
         * loop correctly falls back (verified below). */
        return 0;
    case ST_EXPR: {
        Expr *e = s->as.expr_stmt.expr;
        if (e->kind == EX_CALL)
            return 0;
        return expr_is_leaf(cg, e);
    }
    case ST_GUARD_LET:
        /* Any guard-let disqualifies the loop from the leaf path.
         * Reason: guard-let codegen (gen_stmts) SPLITS the enclosing
         * block at the guard — the statements after the guard generate
         * inside a NEW nested C scope (see gen_stmts: the guard emits
         * `{ ... guard handling ... gen_stmts(rest) ... }`). A leaf
         * poll emitted before such a guard would be separated from
         * the loop-end close by that scope boundary, and more
         * importantly the poll's own position (before the guard's
         * split) vs the loop body's actual generation (inside the
         * split) disagree about block structure. The common byte-scan
         * loops don't use guard-let; the lt2 linked-list walk does,
         * and it correctly falls back to the per-iteration bracket
         * (verified: lt2 prints 6 under verifier + forced preemption).
         * NOTE: this is about codegen SHAPE, not soundness — a guard
         * whose else body is break/continue/return would unwind the
         * hoisted bracket exactly like the per-iteration one. */
        return 0;
    case ST_IF_LET:
        return expr_is_leaf(cg, s->as.if_let.expr) &&
               block_is_leaf(cg, s->as.if_let.then_blk) &&
               block_is_leaf(cg, s->as.if_let.else_blk);
    case ST_SWITCH: {
        if (!expr_is_leaf(cg, s->as.switch_stmt.scrut))
            return 0;
        for (int i = 0; i < s->as.switch_stmt.ncases; i++) {
            for (int j = 0; j < s->as.switch_stmt.cases[i].nvals; j++) {
                if (!expr_is_leaf(cg, s->as.switch_stmt.cases[i].vals[j]))
                    return 0;
            }
            if (!block_is_leaf(cg, s->as.switch_stmt.cases[i].body))
                return 0;
        }
        return block_is_leaf(cg, s->as.switch_stmt.def);
    }
    case ST_SPAWN:
    case ST_SELECT:
    case ST_STRUCT:
    case ST_ENUM:
    case ST_IMPL:
    case ST_UNSAFE:
        return 0;
    }
    return 0;
}

static int block_is_leaf(CG *cg, Block *b) {
    if (!b)
        return 1;
    for (int i = 0; i < b->count; i++) {
        if (!stmt_is_leaf(cg, b->stmts[i]))
            return 0;
    }
    return 1;
}

void gen_stmt(CG *cg, Stmt *s) {
    if (s->file)
        diag_file = s->file;
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
            /* Same elem_is_ptr fix as gen_list (see expr.c): use
             * type_has_gc_roots so [ValueStruct] empties trace interior
             * pointers on minor collections. */
            emit_line(cg, "%s %s = sl_arr_new(sizeof(%s), %d);",
                      ctype_of(cg, ann), sanitize_ident(s->as.let.name),
                      ctype_of(cg, elem), elem_trace_flag(cg, elem));
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
            /* Same map flag fix as gen_maplit (see expr.c). */
            emit_line(cg, "%s %s = sl_map_new(sizeof(%s), sizeof(%s), %d, %d, %d);",
                      ctype_of(cg, ann), sanitize_ident(s->as.let.name),
                      ctype_of(cg, k), ctype_of(cg, v), is_str(k),
                      elem_trace_flag(cg, k), elem_trace_flag(cg, v));
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
                /* an element expects the element type, as in
                   infer_type: `none` in [some(1), none] */
                cg->expect = elem;
                const char *ti = infer_type(cg, ei);
                cg->expect = ann;
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
                cg->expect = ak;
                const char *kty = infer_type(cg, ki);
                cg->expect = av;
                const char *vty = infer_type(cg, vi);
                cg->expect = ann;
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
                     num_cast_hint(it, t)[0] ? num_cast_hint(it, t)
                     : ann ? "" : " (annotate the variable to force a "
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
                             "where %s expected%s",
                             sd->fields[fi], vt, sd->ftypes[fi],
                             num_cast_hint(vt, sd->ftypes[fi]));
                char *b = gen_ident_name(cg, left, s->line);
                const char *se2 = expect_push(cg, sd->ftypes[fi]);
                char *val = maybe_cast(cg, sd->ftypes[fi], vt,
                                       gen_expr(cg, s->as.assign.value));
                cg->expect = se2;
                move_consume(cg, s->as.assign.value);
                emit_line(cg, "%s%s%s = %s;", b, struct_access(cg, bt),
                          sanitize_ident(sd->fields[fi]), val);
                /* Same barrier as the EX_FIELD case. */
                {
                    char *bin2;
                    int is_box2 = type_wrap(bt, &bin2) == TW_GC;
                    if (!is_box2 && type_has_gc_roots(cg, sd->ftypes[fi]) && struct_type_is_gc(cg, bt))
                        emit_line(cg, "{ sl_rt_preempt_disable(); sl_gc_remember((void *)(%s)); sl_rt_preempt_enable(); }", b);
                }
                break;
            }
            if (!v)
                cg_error(s->line, "undefined variable '%s'%s", name,
                         hint_top_level_let(cg, name));
            const char *se3 = expect_push(cg, v->slang);
            const char *vt = infer_type(cg, s->as.assign.value);
            cg->expect = se3;
            if (!value_assignable(v->slang, s->as.assign.value, vt))
                cg_error(s->line,
                         "cannot assign a value of type %s to variable "
                         "'%s' of type %s%s",
                         vt, name, v->slang, num_cast_hint(vt, v->slang));
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
            /* Generational barrier (coarse v1): unconditional remember
             * when the field has GC roots and the container is
             * GC-traced and not a `gc T` box (malloc'd inline wrapper,
             * not a sl_gc_obj). Own preempt bracket (inline store). */
            {
                char *bin;
                int is_box = type_wrap(bt, &bin) == TW_GC;
                if (!is_box && type_has_gc_roots(cg, sd->ftypes[fi]) && struct_type_is_gc(cg, bt))
                    emit_line(cg, "{ sl_rt_preempt_disable(); sl_gc_remember((void *)(%s)); sl_rt_preempt_enable(); }", b);
            }
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
            /* ...and the map itself, plus every local live after this
             * statement. The bracket's enter is a safepoint and can
             * collect; rooting only _sl_k/_sl_v let a collection there
             * free the map, when nothing else referenced it --
             * httpc.run's per-request `headers`, built one put after
             * another, was swept between two of them. Hidden while the
             * collector treated each task's recent allocations as
             * roots. */
            /* _sl_k/_sl_v are rooted by their type, not only when they
             * are themselves GC pointers: a value struct holding a str
             * (map[str]P) was not rooted at all, so a collection at this
             * bracket's enter freed the str and sl_map_put stored a
             * dangling pointer (tests/value_struct_containers). */
            int k_roots = count_gc_root_exprs(cg, k);
            int v_roots = count_gc_root_exprs(cg, v);
            void *after = tgt->live_set;
            int nroots = 1 + k_roots + v_roots + cg->ambient_count;
            for (int li = 0; li < live_set_nnamed(after); li++)
                nroots += count_named_gc_roots(cg, live_set_named(after, li));
            StrBuf roots;
            sb_init(&roots);
            sb_append(&roots, "(void *)_sl_mpm");
            int wrote = 1;
            append_gc_roots_of(cg, &roots, "_sl_k", k, &wrote);
            append_gc_roots_of(cg, &roots, "_sl_v", v, &wrote);
            for (int li = 0; li < live_set_nnamed(after); li++)
                append_named_gc_roots(cg, &roots, live_set_named(after, li),
                                      &wrote);
            for (int ai = 0; ai < cg->ambient_count; ai++)
                sb_append(&roots, xasprintf(", (void *)%s", cg->ambient_roots[ai]));
            emit_line(cg,
                      "({ %ssl_map *_sl_mpm = %s; %s _sl_k = %s; %s _sl_v = %s; "
                      "void *_sl_mp_roots[] = { %s }; sl_safepoint _sl_mp_sp; "
                      "sl_rt_safepoint_enter(&_sl_mp_sp, _sl_mp_roots, %d); "
                      "sl_map_put(_sl_mpm, &_sl_k, &_sl_v); "
                      "sl_rt_safepoint_exit(); });",
                      prelude.data, b, ctype_of(cg, k), ix, ctype_of(cg, v),
                      val, roots.data, nroots);
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
            /* Generational barrier when the element has GC roots, naming
             * the position so a minor traces the list only from there
             * (sl_arr's gc_clean). Own preempt bracket (inline store; map
             * stores are covered inside sl_map_put). `i` is the index's
             * sequenced temp, so naming it again evaluates nothing twice. */
            if (type_has_gc_roots(cg, elem))
                emit_line(cg, "{ sl_rt_preempt_disable(); sl_arr_remember_at(%s, %s); sl_rt_preempt_enable(); }", b, i);
            break;
        }
        cg->ambient_count = ambient_mark;
        cg_error(s->line, "invalid assignment target");
        break;
    }
    case ST_IF: {
        if (s->as.if_stmt.from_guard)
            check_guard_else_leaves(cg, s->as.if_stmt.then_blk, s->line);
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
        /* Tier 12: leaf body with live roots — hoisted bracket plus a
         * per-iteration poll instead of a full safepoint. The hoisted
         * enter/exit wrap the while with NO extra scope (the function
         * body already scopes locals): counter, roots, safepoint, and
         * task variable are plain declarations before the loop.
         * has_bp tracks the hoisted bracket for break/continue/return
         * unwinding exactly like the per-iteration one did. */
        int leaf = !scalar && expr_is_leaf(cg, s->as.while_stmt.cond) &&
                   block_is_leaf(cg, s->as.while_stmt.body);
        int bid = 0, le_eid = 0;
        if (leaf) {
            le_eid = cg->tmp_id++;
            emit_line(cg, "unsigned long _sl_lp_ec%d = 0;", le_eid);
            bid = emit_leaf_bracket(cg, s->backedge_live_set);
        }
        emit_line(cg, "while (%s) {", strip_outer_parens(cond));
        cg->indent++;
        int has_bp;
        if (leaf) {
            /* The poll is flat inside the loop (balanced inline), so
             * break/continue/return must unwind exactly ONE level: the
             * hoisted bracket. Do NOT count anything extra — the
             * hoisted bracket is the one open_backedge_brackets tracks,
             * and has_bp = 1 keeps the loop-end close correct. */
            emit_leaf_poll(cg, s->backedge_live_set, bid, le_eid);
            has_bp = 1;
        } else {
            has_bp = emit_backedge_enter(cg, s->backedge_live_set, poll,
                                         eid, NULL);
        }
        cg->loop_depth++;
        break_push(cg, 0, NULL);
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
        break_pop(cg);
        cg->cur_loop_has_bp = saved_loop_bp;
        if (leaf) {
            /* Poll is flat inside the loop (balanced inline): close the
             * loop, THEN exit the hoisted bracket after it. Only the
             * loop's own brace closes here (indent back to function
             * level); the exit follows at that level. has_bp is NOT
             * cleared — the shared code below is SKIPPED for leaf
             * (else branch), so the exit+decrement here are the one
             * and only close. Indent: one -- for the while's matching
             * close (the ++ after the while line).
             *
             * BREAK/CONTINUE: bodies containing break/continue never
             * reach the leaf path (stmt_is_leaf returns 0 for them),
             * so no double-exit: break's own exit closes the
             * per-iteration bracket (non-leaf path), and the loop-end
             * exit below closes that same iteration bracket... the
             * standard balanced shape, unchanged. continue likewise
             * closes the current iteration's bracket before jumping.
             * The hoisted bracket has no such path to balance, which
             * is exactly why break/continue disqualify. */
            cg->indent--;
            emit_line(cg, "}");
            emit_line(cg, "sl_rt_safepoint_exit();");
            cg->open_backedge_brackets--;
        } else {
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
            cg->indent--;
            emit_line(cg, "}");
        }
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
        int scalar = live_set_nnamed(s->backedge_live_set) == 0;
        /* ST_FOR bounds are evaluated once into C locals (sl_end_N)
         * BEFORE the loop — under the caller's bracket, not the
         * hoisted one. A call in bounds runs before the hoisted enter
         * and nests its own bracket fine, so bounds calls are SOUND
         * either way; but the range-loop shape that matters (len(t),
         * plain ints) is always leaf. Conservative: bounds must be
         * leaf (rules out calls in bounds; rare and not worth the
         * audit). The per-iteration condition reads sl_end_N (an
         * int, needs no root) plus the induction var (an int). */
        int leaf = !scalar && expr_is_leaf(cg, s->as.for_stmt.start) &&
                   expr_is_leaf(cg, s->as.for_stmt.end) &&
                   block_is_leaf(cg, s->as.for_stmt.body);
        int eid = 0, bid = 0, le_eid = 0;
        if (scalar) {
            eid = cg->tmp_id++;
            emit_line(cg, "unsigned long _sl_ec%d = 0;", eid);
        } else if (leaf) {
            le_eid = cg->tmp_id++;
            emit_line(cg, "unsigned long _sl_lp_ec%d = 0;", le_eid);
            bid = emit_leaf_bracket(cg, s->backedge_live_set);
        }
        emit_line(cg, "for (long long %s = %s; %s %s %s; %s++) {", vname,
                  start, vname, op, endvar, vname);
        cg->indent++;
        int has_bp;
        if (leaf) {
            /* Same as ST_WHILE: poll scope balances itself; only the
             * hoisted bracket counts for unwinding. */
            emit_leaf_poll(cg, s->backedge_live_set, bid, le_eid);
            has_bp = 1;
        } else {
            has_bp = emit_backedge_enter(cg, s->backedge_live_set, 1, eid,
                                         NULL);
        }
        cg->loop_depth++;
        break_push(cg, 0, NULL);
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
        break_pop(cg);
        cg->cur_loop_has_bp = saved_loop_bp;
        if (leaf) {
            /* Same as ST_WHILE: poll flat inside; close the for, then
             * exit the hoisted bracket after it. The shared code is
             * skipped (else branch) so this is the one and only
             * exit+decrement. */
            cg->indent--;
            emit_line(cg, "}");
            emit_line(cg, "sl_rt_safepoint_exit();");
            cg->open_backedge_brackets--;
        } else {
            if (has_bp) {
                cg->open_backedge_brackets--;
                emit_line(cg, "sl_rt_safepoint_exit();");
            }
            cg->indent--;
            emit_line(cg, "}");
        }
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
            break_push(cg, 0, NULL);
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = 0;
            gen_scoped_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            break_pop(cg);
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
            break_push(cg, 0, NULL);
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = 0;
            gen_scoped_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            break_pop(cg);
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
            break_push(cg, 0, NULL);
            int saved_loop_bp = cg->cur_loop_has_bp;
            cg->cur_loop_has_bp = 0;
            gen_scoped_block(cg, s->as.for_in.body);
            cg->loop_depth--;
            break_pop(cg);
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
                         "expected%s",
                         vt, cg->cur_ret, num_cast_hint(vt, cg->cur_ret));
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
        if (cg->break_len == 0)
            cg_error(s->line, "'break' outside a loop or switch");
        int top = cg->break_len - 1;
        if (cg->break_kind[top] == 1) {
            /* Inside a `switch` arm: no loop bracket to close
             * (switches open none), just drop arm locals and jump to
             * the switch end. The label itself is only emitted when
             * some break used it (see ST_SWITCH). */
            cg->break_used[top] = 1;
            emit_scope_drops(cg, cg->var_scope_sp ? cg->var_scopes[cg->var_scope_sp - 1] : 0);
            emit_line(cg, "goto %s;", cg->break_end[top]);
            break;
        }
        if (cg->loop_depth == 0)
            cg_error(s->line, "'break' outside a loop or switch");
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
    case ST_IF_LET:
        gen_if_let(cg, s);
        break;
    case ST_SELECT: {
        /* Every arm's channel -- and a send arm's value -- is evaluated
         * ONCE here, before anything can block. Evaluating them lazily
         * per arm would mean re-running side effects on every trip round
         * sl_select_run's internal retry loop, and would make "which
         * channel did this arm mean" depend on when it fired.
         *
         * One safepoint covers sl_select_run AND the opt allocation for
         * whichever arm fires. It has to: the received value lands in an
         * ordinary C temp, and allocating the opt is exactly the thing
         * that can trigger a collection while that temp is the only
         * reference to it. Allocating all n opts up front instead would
         * be simpler but would produce n-1 pieces of garbage per pass
         * through a select loop. Only the arm that fired allocates, so
         * at most one allocation happens inside the bracket and nothing
         * is unrooted across it. This is the same hazard chan_recv's own
         * codegen documents, in the same shape. */
        int n = s->as.select_stmt.ncases;
        int id = cg->tmp_id++;
        int i, nroots = 0;
        char **elems = (char **)xmalloc((size_t)n * sizeof(char *));
        StrBuf roots;

        emit_line(cg, "{");
        cg->indent++;
        for (i = 0; i < n; i++) {
            SelectCase *sc = &s->as.select_stmt.cases[i];
            const char *ct = infer_type(cg, sc->ch);
            if (!is_chan(ct))
                cg_error(sc->line,
                         "select: chan_%s() expects a chan (got %s)",
                         sc->is_send ? "send" : "recv", ct);
            elems[i] = chan_elem(ct);
            char *ch = gen_expr(cg, sc->ch);
            emit_line(cg, "sl_chan *_sl_selh%d_%d = %s;", id, i, ch);
            emit_line(cg, "%s _sl_selv%d_%d;", ctype_of(cg, elems[i]), id,
                      i);
            if (sc->is_send) {
                const char *saved = expect_push(cg, elems[i]);
                const char *vt = infer_type(cg, sc->val);
                char *v = gen_expr(cg, sc->val);
                cg->expect = saved;
                if (!value_assignable(elems[i], sc->val, vt))
                    cg_error(sc->line,
                             "chan_send(): cannot send %s on a chan[%s]",
                             vt, elems[i]);
                v = maybe_cast(cg, elems[i], vt, v);
                emit_line(cg, "_sl_selv%d_%d = %s;", id, i, v);
            } else {
                /* Zeroed, not merely declared: a recv arm that fires
                 * because the channel is CLOSED never writes this slot,
                 * and it is named in the root array below. An
                 * uninitialised pointer there would be a garbage root.
                 * (sl_gc_mark tolerates NULL and non-GC addresses.) */
                emit_line(cg,
                          "memset(&_sl_selv%d_%d, 0, "
                          "sizeof(_sl_selv%d_%d));",
                          id, i, id, i);
            }
        }
        emit_line(cg, "sl_sel_case _sl_selc%d[%d];", id, n);
        emit_line(cg, "sl_waiter _sl_seln%d[%d];", id, n);
        for (i = 0; i < n; i++) {
            SelectCase *sc = &s->as.select_stmt.cases[i];
            emit_line(cg, "_sl_selc%d[%d].ch = _sl_selh%d_%d;", id, i, id,
                      i);
            emit_line(cg, "_sl_selc%d[%d].is_send = %d;", id, i,
                      sc->is_send);
            emit_line(cg, "_sl_selc%d[%d].val = (void *)&_sl_selv%d_%d;",
                      id, i, id, i);
            emit_line(cg, "_sl_selc%d[%d].closed = 0;", id, i);
        }

        sb_init(&roots);
        for (i = 0; i < n; i++) {
            sb_append(&roots, nroots ? ", " : "");
            sb_append(&roots, xasprintf("(void *)_sl_selh%d_%d", id, i));
            nroots++;
            if (type_is_gc_ptr(cg, elems[i])) {
                sb_append(&roots,
                          xasprintf(", (void *)_sl_selv%d_%d", id, i));
                nroots++;
            }
        }
        emit_line(cg, "void *_sl_selr%d[] = { %s };", id, roots.data);
        emit_line(cg, "sl_safepoint _sl_selsp%d;", id);
        emit_line(cg,
                  "sl_rt_safepoint_enter(&_sl_selsp%d, _sl_selr%d, %d);",
                  id, id, nroots);
        emit_line(cg,
                  "int _sl_seli%d = sl_select_run(_sl_selc%d, "
                  "_sl_seln%d, %d, %d);",
                  id, id, id, n, s->as.select_stmt.def ? 1 : 0);
        for (i = 0; i < n; i++) {
            SelectCase *sc = &s->as.select_stmt.cases[i];
            const char *oc;
            if (!sc->bind)
                continue;
            oc = opt_cname(cg, elems[i]);
            emit_line(cg, "%s *_sl_selo%d_%d = NULL;", oc, id, i);
            emit_line(cg,
                      "if (_sl_seli%d == %d) _sl_selo%d_%d = (%s *)"
                      "sl_gc_alloc(sizeof(*_sl_selo%d_%d), %s);",
                      id, i, id, i, oc, id, i,
                      type_has_gc_roots(cg, elems[i])
                          ? xasprintf("sl_gc_trace_%s", oc)
                          : "NULL");
        }
        emit_line(cg, "sl_rt_safepoint_exit();");

        for (i = 0; i < n; i++) {
            SelectCase *sc = &s->as.select_stmt.cases[i];
            emit_line(cg, "%sif (_sl_seli%d == %d) {", i ? "} else " : "",
                      id, i);
            cg->indent++;
            var_scope_push(cg);
            {
                int from = cg->vars.count;
                if (sc->bind) {
                    char *ot = xasprintf("opt[%s]", elems[i]);
                    emit_line(cg,
                              "_sl_selo%d_%d->has = !_sl_selc%d[%d].closed;",
                              id, i, id, i);
                    emit_line(cg,
                              "if (_sl_selo%d_%d->has) _sl_selo%d_%d->v = "
                              "_sl_selv%d_%d;",
                              id, i, id, i, id, i);
                    var_redecl_check(cg, sc->bind, sc->line);
                    var_push(cg, sc->bind, ot);
                    emit_line(cg, "%s %s = _sl_selo%d_%d;", ctype_of(cg, ot),
                              sanitize_ident(sc->bind), id, i);
                }
                gen_block(cg, sc->body);
                emit_scope_drops(cg, from);
            }
            var_scope_pop(cg);
            cg->indent--;
        }
        if (s->as.select_stmt.def) {
            emit_line(cg, "} else {");
            cg->indent++;
            gen_scoped_block(cg, s->as.select_stmt.def);
            cg->indent--;
        }
        emit_line(cg, "}");
        cg->indent--;
        emit_line(cg, "}");
        break;
    }
    case ST_SWITCH: {
        /* A uniform if-ladder over the arms (one C `if` per arm, `||`
         * across its labels): int/bool/enum compare with ==, str
         * with !strcmp. A single ladder keeps one obviously-correct
         * path instead of two; clang builds the jump table itself at
         * -O2 for dense integer arms. The scrutinee runs once into a
         * temp. Deliberately NOT ambient-rooted (unlike ??'s _sl_qN):
         * every read of it sits in the if-ladder conditions, which
         * are pure comparisons with no calls, and the last one runs
         * before any arm body does -- by the time an allocating call
         * executes, the temp is dead. No fallthrough: every arm ends
         * its own block. `break` in an arm jumps to the end label
         * (see ST_BREAK); `continue` still targets the enclosing
         * loop. */
        const char *st = infer_type(cg, s->as.switch_stmt.scrut);
        int ncases = s->as.switch_stmt.ncases;
        Expr ***groups = ncases ? (Expr ***)xmalloc(sizeof(Expr **) *
                                                   (size_t)ncases)
                               : NULL;
        int *counts = ncases ? (int *)xmalloc(sizeof(int) * (size_t)ncases)
                             : NULL;
        for (int i = 0; i < ncases; i++) {
            groups[i] = s->as.switch_stmt.cases[i].vals;
            counts[i] = s->as.switch_stmt.cases[i].nvals;
        }
        switch_validate(cg, st, groups, counts, ncases,
                        s->as.switch_stmt.def != NULL, s->line);
        free(groups);
        free(counts);
        int kind = switch_kind(cg, st);
        int id = cg->tmp_id++;
        char *sv = gen_expr(cg, s->as.switch_stmt.scrut);
        char *svname = xasprintf("_sl_sv%d", id);
        char *endname = xasprintf("_sl_sw_end%d", id);
        emit_line(cg, "{");
        cg->indent++;
        emit_line(cg, "%s %s = %s;", ctype_of(cg, st), svname, sv);
        break_push(cg, 1, endname);
        cg->switch_depth++;
        for (int i = 0; i < ncases; i++) {
            char *cond = xstrdup("");
            for (int j = 0; j < s->as.switch_stmt.cases[i].nvals; j++) {
                Expr *lb = s->as.switch_stmt.cases[i].vals[j];
                char *term = kind == 3
                                 ? xasprintf("!strcmp(%s, %s)", svname,
                                             c_string_literal(
                                                 lb->as.str_lit.value))
                                 : xasprintf("%s == %s", svname,
                                             switch_label_c_const(lb));
                cond = xasprintf("%s%s%s", cond, j ? " || " : "", term);
            }
            emit_line(cg, "%sif (%s) {", i ? "} else " : "", cond);
            cg->indent++;
            var_scope_push(cg);
            {
                int from = cg->vars.count;
                gen_block(cg, s->as.switch_stmt.cases[i].body);
                emit_scope_drops(cg, from);
            }
            var_scope_pop(cg);
            cg->indent--;
        }
        if (s->as.switch_stmt.def) {
            emit_line(cg, "%s{", ncases ? "} else " : "");
            cg->indent++;
            gen_scoped_block(cg, s->as.switch_stmt.def);
            cg->indent--;
        }
        emit_line(cg, "}");
        int used = cg->break_used[cg->break_len - 1];
        break_pop(cg);
        cg->switch_depth--;
        if (used)
            emit_line(cg, "%s: (void)0;", endname);
        cg->indent--;
        emit_line(cg, "}");
        break;
    }
    case ST_SPAWN: {
        Expr *call = s->as.spawn.call;
        const char *name = call->as.call.name;
        const char *sft = spawn_fn_type(cg, call);
        FuncSig *sig = spawn_target(cg, call, s->line);
        int nargs = call->as.call.nargs;
        SpawnShape *shape = sft ? spawn_shape_for_fn(cg, sft)
                                : spawn_shape_for(cg, sig);
        int id = cg->tmp_id++;
        emit_line(cg, "{");
        cg->indent++;
        emit_line(cg, "%s _sl_sa%d;", shape->sname, id);
        emit_line(cg, "_sl_sa%d.join = NULL;", id);
        if (sft)
            emit_line(cg, "_sl_sa%d.fn = %s;", id,
                      call->as.call.callee
                          ? gen_expr(cg, call->as.call.callee)
                          : gen_ident_name(cg, name, s->line));
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
    case ST_ENUM:
    case ST_IMPL:
        /* declarations are processed during collect_decls; nothing to
         * execute at runtime */
        break;
    }
}

/* ---- functions that never return ------------------------------------ */

static int noret_has(CG *cg, const char *pkg, const char *name) {
    for (int i = 0; i < cg->nnoret; i++)
        if (!strcmp(cg->noret_pkg[i], pkg) && !strcmp(cg->noret_name[i], name))
            return 1;
    return 0;
}

static void noret_add(CG *cg, const char *pkg, const char *name) {
    cg->noret_pkg = (const char **)xrealloc(
        cg->noret_pkg, (size_t)(cg->nnoret + 1) * sizeof(char *));
    cg->noret_name = (const char **)xrealloc(
        cg->noret_name, (size_t)(cg->nnoret + 1) * sizeof(char *));
    cg->noret_pkg[cg->nnoret] = pkg;
    cg->noret_name[cg->nnoret] = name;
    cg->nnoret++;
}

/* Is `name` bound anywhere in b (a let, a loop variable, a guard, if let
 * or select binding)? A binding shadows a function of the same name, so
 * a call through it is a function value, not the function. */
static int block_binds(Block *b, const char *name);

static int stmt_binds(Stmt *s, const char *name) {
    switch (s->kind) {
    case ST_LET:
        return !strcmp(s->as.let.name, name);
    case ST_IF:
        return block_binds(s->as.if_stmt.then_blk, name) ||
               block_binds(s->as.if_stmt.else_blk, name);
    case ST_WHILE:
        return block_binds(s->as.while_stmt.body, name);
    case ST_FOR:
        return !strcmp(s->as.for_stmt.name, name) ||
               block_binds(s->as.for_stmt.body, name);
    case ST_FOR_IN:
        return !strcmp(s->as.for_in.name, name) ||
               (s->as.for_in.name2 && !strcmp(s->as.for_in.name2, name)) ||
               block_binds(s->as.for_in.body, name);
    case ST_GUARD_LET:
        return !strcmp(s->as.guard_let.name, name) ||
               (s->as.guard_let.err_name &&
                !strcmp(s->as.guard_let.err_name, name)) ||
               block_binds(s->as.guard_let.body, name);
    case ST_IF_LET:
        return !strcmp(s->as.if_let.name, name) ||
               (s->as.if_let.err_name && !strcmp(s->as.if_let.err_name, name)) ||
               block_binds(s->as.if_let.then_blk, name) ||
               block_binds(s->as.if_let.else_blk, name);
    case ST_UNSAFE:
        return block_binds(s->as.unsafe_blk.body, name);
    case ST_SELECT:
        for (int i = 0; i < s->as.select_stmt.ncases; i++) {
            SelectCase *c = &s->as.select_stmt.cases[i];
            if ((c->bind && !strcmp(c->bind, name)) ||
                block_binds(c->body, name))
                return 1;
        }
        return block_binds(s->as.select_stmt.def, name);
    case ST_SWITCH:
        for (int i = 0; i < s->as.switch_stmt.ncases; i++)
            if (block_binds(s->as.switch_stmt.cases[i].body, name))
                return 1;
        return block_binds(s->as.switch_stmt.def, name);
    default:
        return 0;
    }
}

static int block_binds(Block *b, const char *name) {
    if (!b)
        return 0;
    for (int i = 0; i < b->count; i++)
        if (stmt_binds(b->stmts[i], name))
            return 1;
    return 0;
}

/* Does b contain a return anywhere, at any depth? A function with one can
 * return however its last statement ends. */
static int block_has_return(Block *b);

static int stmt_has_return(Stmt *s) {
    switch (s->kind) {
    case ST_RETURN:
        return 1;
    case ST_IF:
        return block_has_return(s->as.if_stmt.then_blk) ||
               block_has_return(s->as.if_stmt.else_blk);
    case ST_WHILE:
        return block_has_return(s->as.while_stmt.body);
    case ST_FOR:
        return block_has_return(s->as.for_stmt.body);
    case ST_FOR_IN:
        return block_has_return(s->as.for_in.body);
    case ST_GUARD_LET:
        return block_has_return(s->as.guard_let.body);
    case ST_IF_LET:
        return block_has_return(s->as.if_let.then_blk) ||
               block_has_return(s->as.if_let.else_blk);
    case ST_UNSAFE:
        return block_has_return(s->as.unsafe_blk.body);
    case ST_SELECT:
        for (int i = 0; i < s->as.select_stmt.ncases; i++)
            if (block_has_return(s->as.select_stmt.cases[i].body))
                return 1;
        return block_has_return(s->as.select_stmt.def);
    case ST_SWITCH:
        for (int i = 0; i < s->as.switch_stmt.ncases; i++)
            if (block_has_return(s->as.switch_stmt.cases[i].body))
                return 1;
        return block_has_return(s->as.switch_stmt.def);
    default:
        return 0;
    }
}

static int block_has_return(Block *b) {
    if (!b)
        return 0;
    for (int i = 0; i < b->count; i++)
        if (stmt_has_return(b->stmts[i]))
            return 1;
    return 0;
}

/* Is e a call to a package function known never to return? Only a plain
 * call by name counts: a function value, a method or a generic function
 * is never assumed to diverge, so this can only under-claim. */
static int call_never_returns(CG *cg, Expr *e) {
    if (e->kind != EX_CALL || e->as.call.callee || !e->as.call.name)
        return 0;
    const char *n = e->as.call.name;
    if (!strcmp(n, "exit") || !strcmp(n, "panic"))
        return 1;
    const char *dot = strchr(n, '.');
    if (!dot) {
        /* a local binding of the same name shadows the function */
        if (cg->noret_fn) {
            for (int i = 0; i < cg->noret_fn->nparams; i++)
                if (!strcmp(cg->noret_fn->params[i], n))
                    return 0;
            if (block_binds(cg->noret_fn->body, n))
                return 0;
        } else if (var_find(cg, n)) {
            return 0;
        }
        return noret_has(cg, cg->cur_pkg, n);
    }
    size_t alen = (size_t)(dot - n);
    char alias[256];
    if (alen >= sizeof(alias) || strchr(dot + 1, '.'))
        return 0;
    memcpy(alias, n, alen);
    alias[alen] = '\0';
    const char *pkg = import_try(cg, alias);
    return pkg && noret_has(cg, pkg, dot + 1);
}

#define LEAVE_BREAK 1      /* a break leaves (it is not inside a switch) */
#define LEAVE_EXITS_ONLY 2 /* only a call that never returns counts */

/* Does control never reach the end of b? True when its last statement is
 * return, continue, break (with LEAVE_BREAK), a call that never returns
 * (exit, panic, or a function compute_noreturn found), or an if/else, if
 * let/else, or switch with a default whose every branch is itself such a
 * block. With LEAVE_EXITS_ONLY, return/break/continue do not count: the
 * question is then whether the enclosing FUNCTION can return at all.
 * Conservative: a loop, a select, or an enum switch exhaustive without a
 * default answer no, so a guard's else built from one is rejected even
 * when it does leave -- end it with an explicit return instead. A break
 * inside a switch leaves only the switch, so it does not count there;
 * continue still reaches the enclosing loop. */
static int block_leaves(CG *cg, Block *b, int flags) {
    if (!b || b->count == 0)
        return 0;
    Stmt *last = b->stmts[b->count - 1];
    int exits_only = flags & LEAVE_EXITS_ONLY;
    switch (last->kind) {
    case ST_RETURN:
    case ST_CONTINUE:
        return !exits_only;
    case ST_BREAK:
        return !exits_only && (flags & LEAVE_BREAK);
    case ST_EXPR:
        return call_never_returns(cg, last->as.expr_stmt.expr);
    case ST_IF:
        return last->as.if_stmt.else_blk &&
               block_leaves(cg, last->as.if_stmt.then_blk, flags) &&
               block_leaves(cg, last->as.if_stmt.else_blk, flags);
    case ST_IF_LET:
        return last->as.if_let.else_blk &&
               block_leaves(cg, last->as.if_let.then_blk, flags) &&
               block_leaves(cg, last->as.if_let.else_blk, flags);
    case ST_SWITCH: {
        int arm = flags & ~LEAVE_BREAK;
        if (!last->as.switch_stmt.def ||
            !block_leaves(cg, last->as.switch_stmt.def, arm))
            return 0;
        for (int i = 0; i < last->as.switch_stmt.ncases; i++)
            if (!block_leaves(cg, last->as.switch_stmt.cases[i].body, arm))
                return 0;
        return 1;
    }
    case ST_UNSAFE:
        return block_leaves(cg, last->as.unsafe_blk.body, flags);
    default:
        return 0;
    }
}

int block_leaves_scope(CG *cg, Block *b) {
    return block_leaves(cg, b, LEAVE_BREAK);
}

/* Finds every package function that never returns, to a fixed point (a
 * die() calling a fatal() calling exit()): no return anywhere in its body,
 * and a last statement that cannot complete. Generic functions, externs and
 * methods are left out: the table only ever under-claims, and over-
 * claiming would let a guard's else fall through into an unset binding. */
void compute_noreturn(CG *cg, Package *pkgs, int npkgs) {
    const char *saved = cg->cur_pkg;
    int changed = 1;
    while (changed) {
        changed = 0;
        for (int i = 0; i < npkgs; i++) {
            if (pkgs[i].native)
                continue;
            cg->cur_pkg = pkgs[i].name;
            Program *prog = pkgs[i].prog;
            for (int j = 0; j < prog->nfuncs; j++) {
                FuncDecl *f = prog->funcs[j];
                if (f->ntparams || f->is_extern || !f->body ||
                    noret_has(cg, pkgs[i].name, f->name))
                    continue;
                cg->noret_fn = f;
                if (!block_has_return(f->body) &&
                    block_leaves(cg, f->body, LEAVE_EXITS_ONLY)) {
                    noret_add(cg, pkgs[i].name, f->name);
                    changed = 1;
                }
            }
        }
    }
    cg->noret_fn = NULL;
    cg->cur_pkg = saved;
}

/* A guard's else runs exactly when the guard failed, so falling out of it
 * would run the rest of the block anyway -- and for `guard let`, with the
 * bound name holding no value (a zeroed str is NULL: it segfaulted). */
static void check_guard_else_leaves(CG *cg, Block *body, int line) {
    if (!block_leaves_scope(cg, body))
        cg_error(line, "guard's else must leave the scope: end it with "
                       "return, break, continue, exit(..) or panic(..)");
}

/* Generate a run of statements. A 'guard let x = <opt/result> else'
 * binds x for the remainder of the enclosing block, so it is handled
 * here rather than per-statement: everything after it is emitted
 * inside a C block that first checks the option and runs the else
 * body, which must leave the scope (check_guard_else_leaves). */
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
        /* every call through a function value is named "<function value>",
         * so the name alone cannot tell `fs[0](x)` from `fs[1](x)` */
        if ((a->as.call.callee != NULL) != (b->as.call.callee != NULL))
            return 0;
        if (a->as.call.callee &&
            !expr_same(a->as.call.callee, b->as.call.callee))
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
    case EX_SWITCH: {
        if (a->as.switch_expr.ncases != b->as.switch_expr.ncases)
            return 0;
        if ((a->as.switch_expr.def != NULL) !=
            (b->as.switch_expr.def != NULL))
            return 0;
        if (!expr_same(a->as.switch_expr.scrut, b->as.switch_expr.scrut))
            return 0;
        for (int i = 0; i < a->as.switch_expr.ncases; i++) {
            if (a->as.switch_expr.cases[i].nvals !=
                b->as.switch_expr.cases[i].nvals)
                return 0;
            for (int j = 0; j < a->as.switch_expr.cases[i].nvals; j++)
                if (!expr_same(a->as.switch_expr.cases[i].vals[j],
                               b->as.switch_expr.cases[i].vals[j]))
                    return 0;
            if (!expr_same(a->as.switch_expr.cases[i].value,
                           b->as.switch_expr.cases[i].value))
                return 0;
        }
        if (a->as.switch_expr.def &&
            !expr_same(a->as.switch_expr.def, b->as.switch_expr.def))
            return 0;
        return 1;
    }
    default:
        return 0;
    }
}

/* `else let e = err_of(<expr>)`, on a guard or an if let: only for a
 * result, and only err_of of the very expression being unwrapped. */
static void check_err_binding(Expr *ee, Expr *expr, int is_res, int line,
                              const char *what) {
    if (!is_res)
        cg_error(line, "else let error binding requires a result value");
    if (!ee || ee->kind != EX_CALL || ee->as.call.nargs != 1 ||
        !ee->as.call.name || strcmp(ee->as.call.name, "err_of"))
        cg_error(line, "else let binding must be err_of(<same expression>)");
    if (!expr_same(ee->as.call.args[0], expr))
        cg_error(line, "err_of argument must match the %s expression", what);
}

static void gen_guard_else_body(CG *cg, Stmt *s, int gid, const char *acc,
                                int is_res) {
    if (s->as.guard_let.err_name) {
        check_err_binding(s->as.guard_let.err_expr, s->as.guard_let.expr,
                          is_res, s->line, "guard");
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

/* if let x = <opt/result> { then } else let e = err_of(..) { else }:
 * the guard's shape, but each binding lives only in its own branch and
 * either branch may fall through, so it is an ordinary statement. */
static void gen_if_let(CG *cg, Stmt *s) {
    const char *et = infer_type(cg, s->as.if_let.expr);
    char *inner = NULL;
    char *tev = NULL;
    int is_res = 0;
    if (is_opt(et)) {
        inner = opt_inner(et);
    } else if (is_result(et)) {
        char *tv;
        result_te(et, &tv, &tev);
        inner = tv;
        is_res = 1;
    } else {
        cg_error(s->line, "if let requires an opt or result value (got %s)",
                 et);
    }
    if (s->as.if_let.err_name)
        check_err_binding(s->as.if_let.err_expr, s->as.if_let.expr, is_res,
                          s->line, "if let");
    int id = cg->tmp_id++;
    char *e = gen_expr(cg, s->as.if_let.expr);
    const char *acc = type_is_gc_ptr(cg, et) ? "->" : ".";
    emit_line(cg, "{");
    cg->indent++;
    emit_line(cg, "%s _sl_g%d = %s;", ctype_of(cg, et), id, e);
    emit_line(cg, "if (_sl_g%d%s%s) {", id, acc, is_res ? "ok" : "has");
    cg->indent++;
    var_scope_push(cg);
    int from = cg->vars.count;
    var_redecl_check(cg, s->as.if_let.name, s->line);
    var_push(cg, s->as.if_let.name, inner);
    emit_drop_flag(cg, s->as.if_let.name);
    emit_line(cg, "%s %s = _sl_g%d%sv;", ctype_of(cg, inner),
              sanitize_ident(s->as.if_let.name), id, acc);
    gen_stmts(cg, s->as.if_let.then_blk->stmts, s->as.if_let.then_blk->count);
    emit_scope_drops(cg, from);
    var_scope_pop(cg);
    cg->indent--;
    if (s->as.if_let.else_blk) {
        emit_line(cg, "} else {");
        cg->indent++;
        var_scope_push(cg);
        if (s->as.if_let.err_name) {
            var_redecl_check(cg, s->as.if_let.err_name, s->line);
            var_push(cg, s->as.if_let.err_name, tev);
            emit_drop_flag(cg, s->as.if_let.err_name);
            emit_line(cg, "%s %s = _sl_g%d%se;", ctype_of(cg, tev),
                      sanitize_ident(s->as.if_let.err_name), id, acc);
        }
        int efrom = cg->vars.count;
        gen_stmts(cg, s->as.if_let.else_blk->stmts,
                  s->as.if_let.else_blk->count);
        emit_scope_drops(cg, efrom);
        var_scope_pop(cg);
        cg->indent--;
    }
    emit_line(cg, "}");
    cg->indent--;
    emit_line(cg, "}");
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
        check_guard_else_leaves(cg, s->as.guard_let.body, s->line);
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
