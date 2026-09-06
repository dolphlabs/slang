#include "internal.h"

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
    if (type_is_arena(recv_t))
        return 1;
    StructDef *sd = struct_of_type(cg, recv_t);
    if (!sd)
        return 0;
    FuncSig *sig = method_find(cg, sd, right);
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
    case EX_CALL: {
        char *left, *right;
        if (split_dotted(e->as.call.name, &left, &right) &&
            !import_try(cg, left)) {
            if (method_value_self(cg, e, left))
                use_ident(cg, left, e->line, 1);
            else
                use_ident(cg, left, e->line, 0);
        }
        for (int i = 0; i < e->as.call.nargs; i++)
            check_rvalue(cg, e->as.call.args[i]);
        return;
    }
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

static void check_stmt(CG *cg, Stmt *s) {
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
    case ST_IF: {
        check_rvalue(cg, s->as.if_stmt.cond);
        int n = cg->vars.count;
        int *before = snap_moved(cg, n);
        check_block(cg, s->as.if_stmt.then_blk);
        int *then_m = snap_moved(cg, n);
        restore_moved(cg, before, n);
        if (s->as.if_stmt.else_blk)
            check_block(cg, s->as.if_stmt.else_blk);
        int *else_m = snap_moved(cg, n);
        join_moved(cg, then_m, else_m, n);
        return;
    }
    case ST_WHILE: {
        check_rvalue(cg, s->as.while_stmt.cond);
        int n = cg->vars.count;
        for (;;) {
            int *start = snap_moved(cg, n);
            var_scope_push(cg);
            check_stmts(cg, s->as.while_stmt.body->stmts,
                        s->as.while_stmt.body->count);
            var_scope_pop(cg);
            int *end = snap_moved(cg, n);
            int changed = 0;
            for (int i = 0; i < n; i++) {
                int j = start[i] || end[i];
                if (j != start[i])
                    changed = 1;
                cg->vars.items[i].moved = j;
            }
            if (!changed)
                break;
        }
        return;
    }
    case ST_FOR: {
        check_rvalue(cg, s->as.for_stmt.start);
        check_rvalue(cg, s->as.for_stmt.end);
        int n = cg->vars.count;
        var_scope_push(cg);
        var_push(cg, s->as.for_stmt.name, "int");
        for (;;) {
            int *start = snap_moved(cg, n);
            var_scope_push(cg);
            check_stmts(cg, s->as.for_stmt.body->stmts,
                        s->as.for_stmt.body->count);
            var_scope_pop(cg);
            int *end = snap_moved(cg, n);
            int changed = 0;
            for (int i = 0; i < n; i++) {
                int j = start[i] || end[i];
                if (j != start[i])
                    changed = 1;
                cg->vars.items[i].moved = j;
            }
            if (!changed)
                break;
        }
        var_scope_pop(cg);
        return;
    }
    case ST_FOR_IN: {
        check_rvalue(cg, s->as.for_in.iter);
        const char *it = infer_type(cg, s->as.for_in.iter);
        int n = cg->vars.count;
        var_scope_push(cg);
        if (is_arr(it))
            var_push(cg, s->as.for_in.name, arr_elem(it));
        else if (is_bytes(it))
            var_push(cg, s->as.for_in.name, "int");
        else if (is_map(it)) {
            char *k, *v;
            map_kv(it, &k, &v);
            var_push(cg, s->as.for_in.name, k);
            if (s->as.for_in.name2)
                var_push(cg, s->as.for_in.name2, v);
        }
        for (;;) {
            int *start = snap_moved(cg, n);
            var_scope_push(cg);
            check_block(cg, s->as.for_in.body);
            var_scope_pop(cg);
            int *end = snap_moved(cg, n);
            int changed = 0;
            for (int i = 0; i < n; i++) {
                int j = start[i] || end[i];
                if (j != start[i])
                    changed = 1;
                cg->vars.items[i].moved = j;
            }
            if (!changed)
                break;
        }
        var_scope_pop(cg);
        return;
    }
    case ST_RETURN:
        if (s->as.ret.value)
            check_rvalue(cg, s->as.ret.value);
        return;
    case ST_EXPR:
        check_rvalue(cg, s->as.expr_stmt.expr);
        return;
    case ST_SPAWN:
        check_rvalue(cg, s->as.spawn.call);
        return;
    case ST_GUARD_LET: {
        check_rvalue(cg, s->as.guard_let.expr);
        check_block(cg, s->as.guard_let.body);
        const char *et = infer_type(cg, s->as.guard_let.expr);
        char *inner = NULL;
        if (is_opt(et))
            inner = opt_inner(et);
        else if (is_result(et)) {
            char *tv, *tev;
            result_te(et, &tv, &tev);
            inner = tv;
        }
        if (inner) {
            var_redecl_check(cg, s->as.guard_let.name, s->line);
            var_push(cg, s->as.guard_let.name, inner);
        }
        return;
    }
    case ST_UNSAFE:
        check_block(cg, s->as.unsafe_blk.body);
        return;
    case ST_BREAK:
    case ST_CONTINUE:
    case ST_STRUCT:
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
    for (int i = 0; i < nparams; i++)
        var_push(cg, params[i], param_types[i]);
    check_stmts(cg, body->stmts, body->count);
}

void compute_moves(CG *cg, Package *pkgs, int npkgs, int main_index) {
    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (int j = 0; j < p->prog->nfuncs; j++) {
            FuncDecl *f = p->prog->funcs[j];
            if (f->is_extern)
                continue;
            cg->in_function = 1;
            cg->cur_pkg = p->name;
            FuncSig *sig = sig_find_in(cg, p->name, f->name);
            cg->cur_ret = sig->ret_slang;
            check_fn(cg, f->body, f->params, sig->param_slang, f->nparams);
            cg->in_function = 0;
        }
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL)
                continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++) {
                FuncDecl *f = s->as.impl.funcs[q];
                cg->in_function = 1;
                cg->cur_pkg = p->name;
                FuncSig *sig = method_find(
                    cg,
                    struct_find_in_pkg(cg, p->name, s->as.impl.struct_name),
                    f->name);
                cg->cur_ret = sig->ret_slang;
                check_fn(cg, f->body, f->params, sig->param_slang,
                         f->nparams);
                cg->in_function = 0;
            }
        }
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
    case EX_CALL: {
        char *left, *right;
        if (split_dotted(e->as.call.name, &left, &right) &&
            !import_try(cg, left) && !method_value_self(cg, e, left))
            consume_ident(cg, left);
        for (int i = 0; i < e->as.call.nargs; i++)
            move_consume(cg, e->as.call.args[i]);
        return;
    }
    default:
        return;
    }
}
