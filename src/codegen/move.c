#include "internal.h"
#include "../diag.h"

#include <string.h>

static char *drop_flag(const char *name) {
    return xasprintf("_sl_d_%s", sanitize_ident(name));
}

static VarSym *local_of(CG *cg, const char *name) {
    return var_find(cg, name);
}

static void use_ident(CG *cg, const char *name, int line, int as_place) {
    VarSym *v = local_of(cg, name);
    if (!v || type_is_copy(cg, v->slang))
        return;
    if (v->moved)
        cg_error(line, "use of moved value '%s'", name);
    if (!as_place)
        v->moved = 1;
}

static void check_place(CG *cg, Expr *e);
static void check_rvalue(CG *cg, Expr *e);
static int *snap_moved(CG *cg, int n);
static void restore_moved(CG *cg, int *s, int n);
static void join_moved(CG *cg, int *a, int *b, int n);

static void cannot_move_out(int line, const char *what) {
    cg_error(line, "cannot move out of %s", what);
}

static void check_place(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_IDENT: {
        char *left, *right;
        if (split_dotted(e->as.ident.name, &left, &right) &&
            !import_try(cg, left)) {
            use_ident(cg, left, e->line, 1);
            return;
        }
        use_ident(cg, e->as.ident.name, e->line, 1);
        return;
    }
    case EX_FIELD:
        check_place(cg, e->as.field.base);
        return;
    case EX_UNARY:
        check_place(cg, e->as.unary.operand);
        return;
    case EX_INDEX:
        check_place(cg, e->as.index.base);
        check_rvalue(cg, e->as.index.index);
        return;
    default:
        check_rvalue(cg, e);
        return;
    }
}

static int method_value_self(CG *cg, Expr *call, const char *name) {
    char *left, *right;
    if (!split_dotted(call->as.call.name, &left, &right))
        return 0;
    if (import_try(cg, left))
        return 0;
    if (strcmp(left, name))
        return 0;
    const char *recv_t = infer_ident_name(cg, left, call->line);
    if (type_is_arena(recv_t) || type_is_link(recv_t) || type_is_trip(recv_t))
        return 1;
    StructDef *sd = struct_of_type(cg, recv_t);
    if (!sd)
        return 0;
    FuncSig *sig = method_find(cg, sd, right, call->line);
    if (!sig || sig->nparams < 1)
        return 0;
    const char *self_t = sig->param_slang[0];
    char *inner;
    if (type_wrap(self_t, &inner) != TW_NONE)
        return 0;
    if (struct_type_is_gc(cg, self_t))
        return 0;
    return type_is_copy(cg, self_t);
}

/* The receiver of an EX_METHOD, the way method_value_self answers it for
 * a bare `p.m()`: is `self` a plain, Copy value struct (read in place, so
 * the receiver is not consumed)? Anything else -- a reference, an `own`,
 * a gc struct -- takes `p.m()` down the consuming path, which for a
 * receiver that is itself Copy (a gc struct, an ordinary value struct
 * without `own` fields) does nothing. */
static int recv_value_self(CG *cg, Expr *call) {
    const char *recv_t = infer_type(cg, call->as.method.recv);
    if (type_is_arena(recv_t) || type_is_link(recv_t) || type_is_trip(recv_t))
        return 1;
    StructDef *sd = struct_of_type(cg, recv_t);
    if (!sd)
        return 0;
    FuncSig *sig = method_find(cg, sd, call->as.method.name, call->line);
    if (!sig || sig->nparams < 1)
        return 0; /* a fn-typed field: the value is called, not consumed */
    const char *self_t = sig->param_slang[0];
    char *inner;
    if (type_wrap(self_t, &inner) != TW_NONE)
        return 0;
    if (struct_type_is_gc(cg, self_t))
        return 0;
    return type_is_copy(cg, self_t);
}

static void check_rvalue(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_INT:
    case EX_FLOAT:
    case EX_STRING:
    case EX_BYTES:
    case EX_BOOL:
        return;
    case EX_IDENT: {
        char *left, *right;
        if (split_dotted(e->as.ident.name, &left, &right) &&
            !import_try(cg, left)) {
            use_ident(cg, left, e->line, 1);
            const char *bt = infer_ident_name(cg, left, e->line);
            StructDef *sd = struct_of_type(cg, bt);
            if (sd) {
                for (int i = 0; i < sd->nfields; i++) {
                    if (!strcmp(sd->fields[i], right) &&
                        !type_is_copy(cg, sd->ftypes[i]))
                        cannot_move_out(e->line, "a field");
                }
            }
            return;
        }
        use_ident(cg, e->as.ident.name, e->line, 0);
        return;
    }
    case EX_FIELD: {
        check_place(cg, e->as.field.base);
        const char *bt = infer_type(cg, e->as.field.base);
        StructDef *sd = struct_of_type(cg, bt);
        if (sd) {
            for (int i = 0; i < sd->nfields; i++) {
                if (!strcmp(sd->fields[i], e->as.field.name) &&
                    !type_is_copy(cg, sd->ftypes[i]))
                    cannot_move_out(e->line, "a field");
            }
        }
        return;
    }
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "*")) {
            check_place(cg, e->as.unary.operand);
            const char *t = infer_type(cg, e);
            if (!type_is_copy(cg, t))
                cannot_move_out(e->line, "a dereference");
            return;
        }
        if (!strcmp(e->as.unary.op, "&") || !strcmp(e->as.unary.op, "&mut")) {
            check_place(cg, e->as.unary.operand);
            return;
        }
        check_rvalue(cg, e->as.unary.operand);
        return;
    case EX_BINARY:
        check_rvalue(cg, e->as.binary.lhs);
        check_rvalue(cg, e->as.binary.rhs);
        return;
    case EX_CAST:
        check_rvalue(cg, e->as.cast.operand);
        return;
    case EX_INDEX:
        check_place(cg, e->as.index.base);
        check_rvalue(cg, e->as.index.index);
        return;
    case EX_SLICE:
        check_place(cg, e->as.slice.base);
        if (e->as.slice.start)
            check_rvalue(cg, e->as.slice.start);
        if (e->as.slice.end)
            check_rvalue(cg, e->as.slice.end);
        return;
    case EX_LIST:
        for (int i = 0; i < e->as.list.nelems; i++)
            check_rvalue(cg, e->as.list.elems[i]);
        return;
    case EX_MAPLIT:
        for (int i = 0; i < e->as.maplit.npairs; i++) {
            check_rvalue(cg, e->as.maplit.keys[i]);
            check_rvalue(cg, e->as.maplit.vals[i]);
        }
        return;
    case EX_STRUCTLIT:
        for (int i = 0; i < e->as.structlit.nfields; i++)
            check_rvalue(cg, e->as.structlit.vals[i]);
        return;
    case EX_SPAWN:
        check_rvalue(cg, e->as.spawn.call);
        return;
    case EX_SWITCH: {
        /* The scrutinee and labels run before any arm; the arms are
         * mutually exclusive, so each is checked from the same
         * pre-switch state and the result is the union -- the same
         * shape as ST_IF/ST_SELECT above, at expression level. */
        check_rvalue(cg, e->as.switch_expr.scrut);
        int n = cg->vars.count;
        int *before = snap_moved(cg, n);
        int *acc = NULL;
        for (int i = 0; i < e->as.switch_expr.ncases; i++) {
            for (int j = 0; j < e->as.switch_expr.cases[i].nvals; j++)
                check_rvalue(cg, e->as.switch_expr.cases[i].vals[j]);
        }
        for (int i = 0; i < e->as.switch_expr.ncases; i++) {
            int *arm;
            restore_moved(cg, before, n);
            check_rvalue(cg, e->as.switch_expr.cases[i].value);
            arm = snap_moved(cg, n);
            if (!acc) {
                acc = arm;
            } else {
                join_moved(cg, acc, arm, n);
                acc = snap_moved(cg, n);
            }
        }
        if (e->as.switch_expr.def) {
            int *d;
            restore_moved(cg, before, n);
            check_rvalue(cg, e->as.switch_expr.def);
            d = snap_moved(cg, n);
            if (!acc) {
                acc = d;
            } else {
                join_moved(cg, acc, d, n);
                acc = snap_moved(cg, n);
            }
        }
        if (!acc)
            acc = before;
        restore_moved(cg, acc, n);
        return;
    }
    case EX_CALL: {
        char *left, *right;
        if (split_dotted(e->as.call.name, &left, &right) &&
            !import_try(cg, left)) {
            if (method_value_self(cg, e, left))
                use_ident(cg, left, e->line, 1);
            else
                use_ident(cg, left, e->line, 0);
        }
        /* a call through a function value: the callee expression is used
         * (and can name a moved value) like any other operand */
        if (e->as.call.callee)
            check_rvalue(cg, e->as.call.callee);
        for (int i = 0; i < e->as.call.nargs; i++)
            check_rvalue(cg, e->as.call.args[i]);
        return;
    }
    case EX_METHOD:
        /* Same rule as the EX_CALL case for a bare receiver, applied to an
         * expression: a method that reads `self` in place only uses the
         * receiver as a place; any other consumes it, which for a field or
         * an index is "cannot move out of ...". */
        if (recv_value_self(cg, e))
            check_place(cg, e->as.method.recv);
        else
            check_rvalue(cg, e->as.method.recv);
        for (int i = 0; i < e->as.method.nargs; i++)
            check_rvalue(cg, e->as.method.args[i]);
        return;
    }
}

static int *snap_moved(CG *cg, int n) {
    int *s = (int *)xmalloc((size_t)(n > 0 ? n : 1) * sizeof(int));
    for (int i = 0; i < n; i++)
        s[i] = cg->vars.items[i].moved;
    return s;
}

static void restore_moved(CG *cg, int *s, int n) {
    for (int i = 0; i < n; i++)
        cg->vars.items[i].moved = s[i];
}

static void join_moved(CG *cg, int *a, int *b, int n) {
    for (int i = 0; i < n; i++)
        cg->vars.items[i].moved = a[i] || b[i];
}

static void check_block(CG *cg, Block *b);
static void check_stmts(CG *cg, Stmt **stmts, int count);

/* Path sensitivity. `mv_dead` is set when control cannot reach the
 * statement after the one just checked: a return, a break or continue,
 * or a call that never returns. A branch that ends dead does not take
 * part in the join after an if, switch or select, so a move on a path
 * that leaves cannot make a later use an error. A break or continue
 * hands its state to the enclosing loop (MvLoop.carry), which joins it
 * into both the next iteration and the state after the loop. */
static int mv_dead;

typedef struct MvLoop {
    int *carry;
    int n;
    struct MvLoop *up;
} MvLoop;

static MvLoop *mv_loop;
/* break inside a switch leaves only the switch: depth of switches
 * entered since the innermost loop */
static int mv_switch_depth;

static void loop_carry(CG *cg) {
    if (!mv_loop)
        return;
    for (int i = 0; i < mv_loop->n; i++)
        mv_loop->carry[i] |= cg->vars.items[i].moved;
}

/* Join of mutually exclusive arms: each arm is checked from the same
 * state, and afterwards Arms holds the union of the arms that fall
 * through. */
typedef struct {
    int *acc;
    int live;
} Arms;

static void arms_add(CG *cg, Arms *a, int n) {
    if (mv_dead) {
        mv_dead = 0;
        return;
    }
    int *arm = snap_moved(cg, n);
    if (!a->acc) {
        a->acc = arm;
    } else {
        for (int i = 0; i < n; i++)
            a->acc[i] |= arm[i];
    }
    a->live = 1;
}

/* Leaves cg holding the join; when no arm falls through, the code after
 * is unreachable and stays dead. */
static void arms_end(CG *cg, Arms *a, int *before, int n) {
    if (a->live) {
        restore_moved(cg, a->acc, n);
        mv_dead = 0;
    } else {
        restore_moved(cg, before, n);
        mv_dead = 1;
    }
}

/* One loop body to a fixed point. The state at the top of an iteration
 * is the entry state joined with every way back to it: the body's end
 * when it falls through, and each break or continue. The state after
 * the loop is the same join (the loop can exit at its condition, or by a
 * break), so it is left in cg. */
typedef void (*mv_body_fn)(CG *cg, void *ctx);

static void check_loop(CG *cg, int n, mv_body_fn body, void *ctx) {
    MvLoop lp;
    lp.n = n;
    lp.carry = (int *)xmalloc((size_t)(n > 0 ? n : 1) * sizeof(int));
    memset(lp.carry, 0, (size_t)(n > 0 ? n : 1) * sizeof(int));
    lp.up = mv_loop;
    int saved_sw = mv_switch_depth;
    mv_loop = &lp;
    mv_switch_depth = 0;
    for (;;) {
        int *start = snap_moved(cg, n);
        mv_dead = 0;
        body(cg, ctx);
        int changed = 0;
        for (int i = 0; i < n; i++) {
            int j = start[i] || lp.carry[i] ||
                    (!mv_dead && cg->vars.items[i].moved);
            if (j != start[i])
                changed = 1;
            cg->vars.items[i].moved = j;
        }
        if (!changed)
            break;
    }
    mv_loop = lp.up;
    mv_switch_depth = saved_sw;
    mv_dead = 0;
}

typedef struct {
    Stmt **stmts;
    int count;
    Block *blk;
} LoopBody;

static void loop_body(CG *cg, void *ctx) {
    LoopBody *lb = (LoopBody *)ctx;
    var_scope_push(cg);
    if (lb->blk)
        check_block(cg, lb->blk);
    else
        check_stmts(cg, lb->stmts, lb->count);
    var_scope_pop(cg);
}


static void check_stmt(CG *cg, Stmt *s) {
    if (s->file)
        diag_file = s->file;
    switch (s->kind) {
    case ST_LET: {
        Expr *init = s->as.let.init;
        if (!((init->kind == EX_LIST && init->as.list.nelems == 0) ||
              (init->kind == EX_MAPLIT && init->as.maplit.npairs == 0)))
            check_rvalue(cg, init);
        const char *ann = s->as.let.type_ann;
        if (ann)
            ann = canon_type(cg, ann, s->line);
        const char *t = ann;
        if (!t && !((init->kind == EX_LIST && init->as.list.nelems == 0) ||
                    (init->kind == EX_MAPLIT && init->as.maplit.npairs == 0))) {
            const char *saved = expect_push(cg, ann);
            t = infer_type(cg, init);
            cg->expect = saved;
        }
        var_redecl_check(cg, s->as.let.name, s->line);
        var_push(cg, s->as.let.name, t);
        return;
    }
    case ST_ASSIGN: {
        Expr *tgt = s->as.assign.target;
        check_rvalue(cg, s->as.assign.value);
        if (tgt->kind == EX_IDENT) {
            char *left, *right;
            if (split_dotted(tgt->as.ident.name, &left, &right) &&
                !import_try(cg, left)) {
                use_ident(cg, left, s->line, 1);
                return;
            }
            VarSym *v = local_of(cg, tgt->as.ident.name);
            if (v)
                v->moved = 0;
            return;
        }
        check_place(cg, tgt);
        return;
    }
    case ST_SELECT: {
        /* The arms are mutually exclusive, so a move inside one must
         * not be visible to the others -- each starts from the same
         * pre-select state, exactly like if/else, and the joined
         * result is the union of the arms that fall through. */
        int i, n;
        int *before;
        Arms arms = {0};
        for (i = 0; i < s->as.select_stmt.ncases; i++) {
            SelectCase *sc = &s->as.select_stmt.cases[i];
            check_rvalue(cg, sc->ch);
            if (sc->val)
                check_rvalue(cg, sc->val);
        }
        n = cg->vars.count;
        before = snap_moved(cg, n);
        for (i = 0; i < s->as.select_stmt.ncases; i++) {
            SelectCase *sc = &s->as.select_stmt.cases[i];
            restore_moved(cg, before, n);
            var_scope_push(cg);
            if (sc->bind) {
                const char *ct = infer_type(cg, sc->ch);
                var_redecl_check(cg, sc->bind, sc->line);
                var_push(cg, sc->bind,
                         xasprintf("opt[%s]", chan_elem(ct)));
            }
            check_block(cg, sc->body);
            var_scope_pop(cg);
            arms_add(cg, &arms, n);
        }
        if (s->as.select_stmt.def) {
            restore_moved(cg, before, n);
            check_block(cg, s->as.select_stmt.def);
            arms_add(cg, &arms, n);
        }
        arms_end(cg, &arms, before, n);
        return;
    }
    case ST_IF: {
        check_rvalue(cg, s->as.if_stmt.cond);
        int n = cg->vars.count;
        int *before = snap_moved(cg, n);
        Arms arms = {0};
        check_block(cg, s->as.if_stmt.then_blk);
        arms_add(cg, &arms, n);
        restore_moved(cg, before, n);
        if (s->as.if_stmt.else_blk)
            check_block(cg, s->as.if_stmt.else_blk);
        arms_add(cg, &arms, n);
        arms_end(cg, &arms, before, n);
        return;
    }
    case ST_SWITCH: {
        /* Same exclusivity shape as ST_IF/ST_SELECT: the scrutinee
         * runs once up front; each arm starts from the same
         * pre-switch state; without a `default` the "no arm runs"
         * path keeps the pre-switch state. */
        check_rvalue(cg, s->as.switch_stmt.scrut);
        int n = cg->vars.count;
        int *before = snap_moved(cg, n);
        Arms arms = {0};
        for (int i = 0; i < s->as.switch_stmt.ncases; i++) {
            for (int j = 0; j < s->as.switch_stmt.cases[i].nvals; j++)
                check_rvalue(cg, s->as.switch_stmt.cases[i].vals[j]);
        }
        mv_switch_depth++;
        for (int i = 0; i < s->as.switch_stmt.ncases; i++) {
            restore_moved(cg, before, n);
            var_scope_push(cg);
            check_block(cg, s->as.switch_stmt.cases[i].body);
            var_scope_pop(cg);
            arms_add(cg, &arms, n);
        }
        if (s->as.switch_stmt.def) {
            restore_moved(cg, before, n);
            var_scope_push(cg);
            check_block(cg, s->as.switch_stmt.def);
            var_scope_pop(cg);
            arms_add(cg, &arms, n);
        } else {
            restore_moved(cg, before, n);
            arms_add(cg, &arms, n);
        }
        mv_switch_depth--;
        arms_end(cg, &arms, before, n);
        return;
    }
    case ST_WHILE: {
        check_rvalue(cg, s->as.while_stmt.cond);
        LoopBody lb = {s->as.while_stmt.body->stmts,
                       s->as.while_stmt.body->count, NULL};
        check_loop(cg, cg->vars.count, loop_body, &lb);
        return;
    }
    case ST_FOR: {
        check_rvalue(cg, s->as.for_stmt.start);
        check_rvalue(cg, s->as.for_stmt.end);
        int n = cg->vars.count;
        var_scope_push(cg);
        var_push(cg, s->as.for_stmt.name, "int");
        LoopBody lb = {s->as.for_stmt.body->stmts, s->as.for_stmt.body->count,
                       NULL};
        check_loop(cg, n, loop_body, &lb);
        var_scope_pop(cg);
        return;
    }
    case ST_FOR_IN: {
        check_rvalue(cg, s->as.for_in.iter);
        const char *it = infer_type(cg, s->as.for_in.iter);
        int n = cg->vars.count;
        var_scope_push(cg);
        const char *t1, *t2;
        if (for_in_types(it, s->as.for_in.name2 != NULL, &t1, &t2)) {
            var_push(cg, s->as.for_in.name, t1);
            if (t2)
                var_push(cg, s->as.for_in.name2, t2);
        }
        LoopBody lb = {NULL, 0, s->as.for_in.body};
        check_loop(cg, n, loop_body, &lb);
        var_scope_pop(cg);
        return;
    }
    case ST_RETURN:
        if (s->as.ret.value)
            check_rvalue(cg, s->as.ret.value);
        mv_dead = 1;
        return;
    case ST_EXPR:
        check_rvalue(cg, s->as.expr_stmt.expr);
        if (call_never_returns(cg, s->as.expr_stmt.expr))
            mv_dead = 1;
        return;
    case ST_SPAWN:
        check_rvalue(cg, s->as.spawn.call);
        return;
    case ST_GUARD_LET: {
        check_rvalue(cg, s->as.guard_let.expr);
        if (s->as.guard_let.err_expr)
            check_rvalue(cg, s->as.guard_let.err_expr);
        const char *et = infer_type(cg, s->as.guard_let.expr);
        char *inner = NULL;
        int is_res = 0;
        char *tev = NULL;
        if (is_opt(et))
            inner = opt_inner(et);
        else if (is_result(et)) {
            char *tv;
            result_te(et, &tv, &tev);
            inner = tv;
            is_res = 1;
        }
        if (s->as.guard_let.err_name) {
            int eline = s->as.guard_let.err_line ? s->as.guard_let.err_line
                                                 : s->line;
            if (!is_res) {
                if (!s->as.guard_let.err_expr)
                    cg_error(eline,
                             "else |%s| error binding in guard let requires a "
                             "result[T, E] value (got %s); remove '|%s|' to "
                             "write 'else { ... }'",
                             s->as.guard_let.err_name, et,
                             s->as.guard_let.err_name);
                cg_error(eline,
                         "else let error binding requires a result value");
            }
            var_scope_push(cg);
            var_redecl_check(cg, s->as.guard_let.err_name, eline);
            var_push(cg, s->as.guard_let.err_name, tev);
        }
        /* The else must leave the scope (check_guard_else_leaves), so
         * what it moves is gone only on a path that never reaches the
         * statements after the guard. */
        int gn = cg->vars.count;
        int *gbefore = snap_moved(cg, gn);
        check_block(cg, s->as.guard_let.body);
        restore_moved(cg, gbefore, gn);
        mv_dead = 0;
        if (s->as.guard_let.err_name)
            var_scope_pop(cg);
        if (inner) {
            var_redecl_check(cg, s->as.guard_let.name, s->line);
            var_push(cg, s->as.guard_let.name, inner);
        }
        return;
    }
    case ST_IF_LET: {
        check_rvalue(cg, s->as.if_let.expr);
        if (s->as.if_let.err_expr)
            check_rvalue(cg, s->as.if_let.err_expr);
        const char *et = infer_type(cg, s->as.if_let.expr);
        char *inner = NULL;
        int is_res = 0;
        char *tev = NULL;
        if (is_opt(et))
            inner = opt_inner(et);
        else if (is_result(et)) {
            char *tv;
            result_te(et, &tv, &tev);
            inner = tv;
            is_res = 1;
        }
        int eline = s->as.if_let.err_line ? s->as.if_let.err_line : s->line;
        if (s->as.if_let.err_name && !is_res) {
            if (!s->as.if_let.err_expr)
                cg_error(eline,
                         "else |%s| error binding in if let requires a "
                         "result[T, E] value (got %s); remove '|%s|' to "
                         "write 'else { ... }'",
                         s->as.if_let.err_name, et, s->as.if_let.err_name);
            cg_error(eline, "else let error binding requires a result value");
        }
        /* Same exclusivity as ST_IF: both branches start from the state
         * before the `if let`, and what either moved is moved after it. */
        int n = cg->vars.count;
        int *before = snap_moved(cg, n);
        var_scope_push(cg);
        if (inner) {
            var_redecl_check(cg, s->as.if_let.name, s->line);
            var_push(cg, s->as.if_let.name, inner);
        }
        Arms arms = {0};
        check_block(cg, s->as.if_let.then_blk);
        var_scope_pop(cg);
        arms_add(cg, &arms, n);
        restore_moved(cg, before, n);
        if (s->as.if_let.else_blk) {
            var_scope_push(cg);
            if (s->as.if_let.err_name) {
                var_redecl_check(cg, s->as.if_let.err_name, eline);
                var_push(cg, s->as.if_let.err_name, tev);
            }
            check_block(cg, s->as.if_let.else_blk);
            var_scope_pop(cg);
        }
        arms_add(cg, &arms, n);
        arms_end(cg, &arms, before, n);
        return;
    }
    case ST_UNSAFE:
        check_block(cg, s->as.unsafe_blk.body);
        return;
    case ST_BREAK:
        /* inside a switch, break leaves only the switch: its state
         * reaches the statement after it, as a falling-through arm's
         * does */
        if (mv_switch_depth)
            return;
        loop_carry(cg);
        mv_dead = 1;
        return;
    case ST_CONTINUE:
        loop_carry(cg);
        mv_dead = 1;
        return;
    case ST_STRUCT:
    case ST_ENUM:
    case ST_IMPL:
        return;
    }
}

static void check_stmts(CG *cg, Stmt **stmts, int count) {
    for (int i = 0; i < count; i++)
        check_stmt(cg, stmts[i]);
}

static void check_block(CG *cg, Block *b) {
    var_scope_push(cg);
    check_stmts(cg, b->stmts, b->count);
    var_scope_pop(cg);
}

static void check_fn(CG *cg, Block *body, char **params,
                     const char **param_types, int nparams) {
    var_scope_reset(cg);
    var_scope_push(cg);
    mv_dead = 0;
    mv_loop = NULL;
    mv_switch_depth = 0;
    for (int i = 0; i < nparams; i++)
        var_push(cg, params[i], param_types[i]);
    check_stmts(cg, body->stmts, body->count);
}

void compute_moves(CG *cg, Package *pkgs, int npkgs, int main_index) {
    FuncCursor fc;
    func_cursor_init(&fc);
    while (func_cursor_next(cg, pkgs, npkgs, &fc, 0)) {
        func_cursor_enter(cg, &fc);
        check_fn(cg, fc.fn->body, fc.fn->params, fc.sig->param_slang,
                 fc.fn->nparams);
        cg->in_function = 0;
    }
    cg->in_function = 1;
    cg->cur_ret = NULL;
    cg->cur_pkg = pkgs[main_index].name;
    check_fn(cg, pkgs[main_index].prog->main_body, NULL, NULL, 0);
    cg->in_function = 0;
}

static void emit_drop_ty(CG *cg, const char *cexpr, const char *ty, int stack);

static void emit_drop_ty(CG *cg, const char *cexpr, const char *ty, int stack) {
    char *inner;
    TypeWrap w = type_wrap(ty, &inner);
    if (w == TW_OWN) {
        emit_drop_ty(cg, xasprintf("(*(%s))", cexpr), inner, 0);
        if (!stack)
            emit_line(cg, "free((void *)(%s));", cexpr);
        return;
    }
    if (!strcmp(ty, "arena")) {
        emit_line(cg, "sl_arena_free(&(%s));", cexpr);
        return;
    }
    if (!strcmp(ty, "link")) {
        emit_line(cg, "sl_link_free(&(%s));", cexpr);
        return;
    }
    StructDef *sd = struct_find_canon(cg, ty);
    if (!sd || sd->is_gc)
        return;
    const char *acc = struct_access(cg, ty);
    for (int i = 0; i < sd->nfields; i++) {
        if (!type_needs_drop(cg, sd->ftypes[i]))
            continue;
        emit_drop_ty(cg,
                     xasprintf("(%s)%s%s", cexpr, acc,
                               sanitize_ident(sd->fields[i])),
                     sd->ftypes[i], 0);
    }
}

void emit_drop_flag(CG *cg, const char *name) {
    VarSym *v = local_of(cg, name);
    if (!v || !v->drop)
        return;
    emit_line(cg, "int %s = 1;", drop_flag(name));
}

void emit_drop_overwrite(CG *cg, const char *name) {
    VarSym *v = local_of(cg, name);
    if (!v || !v->drop)
        return;
    emit_line(cg, "if (%s) {", drop_flag(name));
    cg->indent++;
    emit_drop_ty(cg, sanitize_ident(name), v->slang, v->stack);
    cg->indent--;
    emit_line(cg, "}");
}

void emit_scope_drops(CG *cg, int from) {
    for (int i = cg->vars.count - 1; i >= from; i--) {
        VarSym *v = &cg->vars.items[i];
        if (!v->drop)
            continue;
        emit_line(cg, "if (%s) {", drop_flag(v->name));
        cg->indent++;
        emit_drop_ty(cg, sanitize_ident(v->name), v->slang, v->stack);
        cg->indent--;
        emit_line(cg, "}");
    }
}

static void consume_ident(CG *cg, const char *name) {
    VarSym *v = local_of(cg, name);
    if (!v || !v->drop || type_is_copy(cg, v->slang))
        return;
    emit_line(cg, "%s = 0;", drop_flag(name));
}

void move_reinit(CG *cg, const char *name) {
    VarSym *v = local_of(cg, name);
    if (!v || !v->drop)
        return;
    emit_line(cg, "%s = 1;", drop_flag(name));
}

void move_consume(CG *cg, Expr *e) {
    switch (e->kind) {
    case EX_IDENT: {
        char *left, *right;
        if (split_dotted(e->as.ident.name, &left, &right) &&
            !import_try(cg, left))
            return;
        consume_ident(cg, e->as.ident.name);
        return;
    }
    case EX_FIELD:
    case EX_UNARY:
    case EX_INDEX:
    case EX_SLICE:
        return;
    case EX_BINARY:
        move_consume(cg, e->as.binary.lhs);
        move_consume(cg, e->as.binary.rhs);
        return;
    case EX_CAST:
        move_consume(cg, e->as.cast.operand);
        return;
    case EX_LIST:
        for (int i = 0; i < e->as.list.nelems; i++)
            move_consume(cg, e->as.list.elems[i]);
        return;
    case EX_MAPLIT:
        for (int i = 0; i < e->as.maplit.npairs; i++) {
            move_consume(cg, e->as.maplit.keys[i]);
            move_consume(cg, e->as.maplit.vals[i]);
        }
        return;
    case EX_STRUCTLIT:
        for (int i = 0; i < e->as.structlit.nfields; i++)
            move_consume(cg, e->as.structlit.vals[i]);
        return;
    case EX_SPAWN:
        move_consume(cg, e->as.spawn.call);
        return;
    case EX_SWITCH:
        /* The scrutinee is only read (and can never be `own`: only
         * int/bool/str/enum switch); arm values are consumed
         * individually by their own codegen. Nothing to do here. */
        return;
    case EX_CALL: {
        char *left, *right;
        if (split_dotted(e->as.call.name, &left, &right) &&
            !import_try(cg, left) && !method_value_self(cg, e, left))
            consume_ident(cg, left);
        /* `pick(own_thing)(x)`: the call inside the callee consumes its own
         * arguments; skipping it left that drop flag set, so the callee
         * freed the value and the caller freed it again. */
        if (e->as.call.callee)
            move_consume(cg, e->as.call.callee);
        for (int i = 0; i < e->as.call.nargs; i++)
            move_consume(cg, e->as.call.args[i]);
        return;
    }
    case EX_METHOD:
        /* Skipping this would leave an `own` argument's drop flag set: the
         * callee frees its parameter and the caller frees the binding. */
        if (!recv_value_self(cg, e))
            move_consume(cg, e->as.method.recv);
        for (int i = 0; i < e->as.method.nargs; i++)
            move_consume(cg, e->as.method.args[i]);
        return;
    default:
        return;
    }
}
