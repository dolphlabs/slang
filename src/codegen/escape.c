#include "internal.h"

#include <string.h>

typedef struct {
    const char *name;
    Stmt *let;
} EscCand;

typedef struct {
    EscCand *cands;
    int ncand;
    int cap;
} Esc;

static void esc_push(Esc *esc, const char *name, Stmt *let) {
    if (esc->ncand == esc->cap) {
        esc->cap = esc->cap ? esc->cap * 2 : 8;
        esc->cands =
            (EscCand *)xrealloc(esc->cands, (size_t)esc->cap * sizeof(EscCand));
    }
    esc->cands[esc->ncand].name = name;
    esc->cands[esc->ncand].let = let;
    esc->ncand++;
}

static void mark_escape(Esc *esc, const char *name) {
    for (int i = esc->ncand - 1; i >= 0; i--) {
        if (strcmp(esc->cands[i].name, name))
            continue;
        if (esc->cands[i].let)
            esc->cands[i].let->as.let.stack = 0;
        return;
    }
}

static int ident_is(const char *ident, const char *name) {
    return !strcmp(ident, name);
}

static int ident_field_of(const char *ident, const char *name) {
    size_t n = strlen(name);
    return !strncmp(ident, name, n) && ident[n] == '.';
}

static int ptr_result(Expr *e, const char *name) {
    if (e->kind == EX_IDENT)
        return ident_is(e->as.ident.name, name);
    if (e->kind == EX_CAST)
        return ptr_result(e->as.cast.operand, name);
    return 0;
}

static int operand_of_name(Expr *e, const char *name) {
    if (e->kind == EX_IDENT)
        return ident_is(e->as.ident.name, name) ||
               ident_field_of(e->as.ident.name, name);
    if (e->kind == EX_FIELD)
        return operand_of_name(e->as.field.base, name);
    return 0;
}

static int method_value_self(CG *cg, Expr *call, const char *name, int line) {
    char *left, *right;
    if (!split_dotted(call->as.call.name, &left, &right))
        return 0;
    if (import_try(cg, left))
        return 0;
    if (strcmp(left, name))
        return 0;
    const char *recv_t = infer_ident_name(cg, left, line);
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
    return 1;
}

static int is_print_call(const char *name) {
    return !strcmp(name, "print") || !strcmp(name, "println");
}

static void scan_expr(CG *cg, Esc *esc, Expr *e, const char *name);

static void scan_expr_any(CG *cg, Esc *esc, Expr *e) {
    for (int i = esc->ncand - 1; i >= 0; i--) {
        if (esc->cands[i].let)
            scan_expr(cg, esc, e, esc->cands[i].name);
    }
}

static void scan_expr(CG *cg, Esc *esc, Expr *e, const char *name) {
    switch (e->kind) {
    case EX_INT:
    case EX_FLOAT:
    case EX_STRING:
    case EX_BYTES:
    case EX_BOOL:
        return;
    case EX_IDENT:
        return;
    case EX_UNARY:
        if ((!strcmp(e->as.unary.op, "&") || !strcmp(e->as.unary.op, "&mut")) &&
            operand_of_name(e->as.unary.operand, name))
            mark_escape(esc, name);
        else
            scan_expr(cg, esc, e->as.unary.operand, name);
        return;
    case EX_BINARY:
        scan_expr(cg, esc, e->as.binary.lhs, name);
        scan_expr(cg, esc, e->as.binary.rhs, name);
        return;
    case EX_CAST:
        scan_expr(cg, esc, e->as.cast.operand, name);
        return;
    case EX_INDEX:
        scan_expr(cg, esc, e->as.index.base, name);
        scan_expr(cg, esc, e->as.index.index, name);
        return;
    case EX_SLICE:
        scan_expr(cg, esc, e->as.slice.base, name);
        if (e->as.slice.start)
            scan_expr(cg, esc, e->as.slice.start, name);
        if (e->as.slice.end)
            scan_expr(cg, esc, e->as.slice.end, name);
        return;
    case EX_FIELD:
        scan_expr(cg, esc, e->as.field.base, name);
        return;
    case EX_LIST:
        for (int i = 0; i < e->as.list.nelems; i++) {
            if (ptr_result(e->as.list.elems[i], name))
                mark_escape(esc, name);
            scan_expr(cg, esc, e->as.list.elems[i], name);
        }
        return;
    case EX_MAPLIT:
        for (int i = 0; i < e->as.maplit.npairs; i++) {
            if (ptr_result(e->as.maplit.keys[i], name) ||
                ptr_result(e->as.maplit.vals[i], name))
                mark_escape(esc, name);
            scan_expr(cg, esc, e->as.maplit.keys[i], name);
            scan_expr(cg, esc, e->as.maplit.vals[i], name);
        }
        return;
    case EX_STRUCTLIT:
        for (int i = 0; i < e->as.structlit.nfields; i++) {
            if (ptr_result(e->as.structlit.vals[i], name))
                mark_escape(esc, name);
            scan_expr(cg, esc, e->as.structlit.vals[i], name);
        }
        return;
    case EX_CALL: {
        const char *cname = e->as.call.name;
        int print = is_print_call(cname);
        int value_self = method_value_self(cg, e, name, e->line);
        char *left, *right;
        if (split_dotted(cname, &left, &right) && !import_try(cg, left) &&
            ident_is(left, name) && !value_self)
            mark_escape(esc, name);
        for (int i = 0; i < e->as.call.nargs; i++) {
            if (!print && ptr_result(e->as.call.args[i], name))
                mark_escape(esc, name);
            scan_expr(cg, esc, e->as.call.args[i], name);
        }
        return;
    }
    }
}

static int let_allocates(CG *cg, Stmt *s, const char *t, const char *it) {
    char *inner;
    TypeWrap w = type_wrap(t, &inner);
    if (w == TW_OWN || w == TW_GC) {
        char *ii;
        return type_wrap(it, &ii) != w;
    }
    return struct_type_is_gc(cg, t) &&
           s->as.let.init->kind == EX_STRUCTLIT;
}

static const char *escape_let_type(CG *cg, Stmt *s) {
    const char *ann = s->as.let.type_ann;
    if (ann)
        ann = canon_type(cg, ann, s->line);
    Expr *init = s->as.let.init;
    if (init->kind == EX_LIST && init->as.list.nelems == 0)
        return ann;
    if (init->kind == EX_MAPLIT && init->as.maplit.npairs == 0)
        return ann;
    const char *saved = expect_push(cg, ann);
    const char *it = infer_type(cg, init);
    cg->expect = saved;
    return ann ? ann : it;
}

static void walk_block(CG *cg, Esc *esc, Block *b);

static void walk_stmt(CG *cg, Esc *esc, Stmt *s) {
    switch (s->kind) {
    case ST_LET: {
        scan_expr_any(cg, esc, s->as.let.init);
        const char *t = escape_let_type(cg, s);
        const char *it = NULL;
        Expr *init = s->as.let.init;
        if (!((init->kind == EX_LIST && init->as.list.nelems == 0) ||
              (init->kind == EX_MAPLIT && init->as.maplit.npairs == 0))) {
            const char *saved = expect_push(cg, t);
            it = infer_type(cg, init);
            cg->expect = saved;
        }
        esc_push(esc, s->as.let.name, NULL);
        if (t && it && let_allocates(cg, s, t, it)) {
            s->as.let.stack = 1;
            esc_push(esc, s->as.let.name, s);
        }
        var_redecl_check(cg, s->as.let.name, s->line);
        var_push(cg, s->as.let.name, t);
        return;
    }
    case ST_ASSIGN:
        scan_expr_any(cg, esc, s->as.assign.target);
        scan_expr_any(cg, esc, s->as.assign.value);
        for (int i = esc->ncand - 1; i >= 0; i--) {
            if (!esc->cands[i].let)
                continue;
            if (ptr_result(s->as.assign.value, esc->cands[i].name))
                mark_escape(esc, esc->cands[i].name);
        }
        return;
    case ST_IF:
        scan_expr_any(cg, esc, s->as.if_stmt.cond);
        walk_block(cg, esc, s->as.if_stmt.then_blk);
        if (s->as.if_stmt.else_blk)
            walk_block(cg, esc, s->as.if_stmt.else_blk);
        return;
    case ST_WHILE:
        scan_expr_any(cg, esc, s->as.while_stmt.cond);
        walk_block(cg, esc, s->as.while_stmt.body);
        return;
    case ST_FOR:
        scan_expr_any(cg, esc, s->as.for_stmt.start);
        scan_expr_any(cg, esc, s->as.for_stmt.end);
        {
            int mark = esc->ncand;
            var_scope_push(cg);
            esc_push(esc, s->as.for_stmt.name, NULL);
            var_push(cg, s->as.for_stmt.name, "int");
            walk_block(cg, esc, s->as.for_stmt.body);
            var_scope_pop(cg);
            esc->ncand = mark;
        }
        return;
    case ST_FOR_IN:
        scan_expr_any(cg, esc, s->as.for_in.iter);
        {
            const char *it = infer_type(cg, s->as.for_in.iter);
            int mark = esc->ncand;
            var_scope_push(cg);
            if (is_arr(it)) {
                char *elem = arr_elem(it);
                esc_push(esc, s->as.for_in.name, NULL);
                var_push(cg, s->as.for_in.name, elem);
            } else if (is_bytes(it)) {
                esc_push(esc, s->as.for_in.name, NULL);
                var_push(cg, s->as.for_in.name, "int");
            } else if (is_map(it)) {
                char *k, *v;
                map_kv(it, &k, &v);
                esc_push(esc, s->as.for_in.name, NULL);
                var_push(cg, s->as.for_in.name, k);
                if (s->as.for_in.name2) {
                    esc_push(esc, s->as.for_in.name2, NULL);
                    var_push(cg, s->as.for_in.name2, v);
                }
            }
            walk_block(cg, esc, s->as.for_in.body);
            var_scope_pop(cg);
            esc->ncand = mark;
        }
        return;
    case ST_RETURN:
        if (s->as.ret.value) {
            scan_expr_any(cg, esc, s->as.ret.value);
            for (int i = esc->ncand - 1; i >= 0; i--) {
                if (!esc->cands[i].let)
                    continue;
                if (ptr_result(s->as.ret.value, esc->cands[i].name))
                    mark_escape(esc, esc->cands[i].name);
            }
        }
        return;
    case ST_EXPR:
        scan_expr_any(cg, esc, s->as.expr_stmt.expr);
        return;
    case ST_SPAWN:
        scan_expr_any(cg, esc, s->as.spawn.call);
        for (int i = 0; i < s->as.spawn.call->as.call.nargs; i++) {
            for (int c = esc->ncand - 1; c >= 0; c--) {
                if (!esc->cands[c].let)
                    continue;
                if (ptr_result(s->as.spawn.call->as.call.args[i],
                               esc->cands[c].name))
                    mark_escape(esc, esc->cands[c].name);
            }
        }
        return;
    case ST_GUARD_LET: {
        scan_expr_any(cg, esc, s->as.guard_let.expr);
        walk_block(cg, esc, s->as.guard_let.body);
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
            esc_push(esc, s->as.guard_let.name, NULL);
            var_redecl_check(cg, s->as.guard_let.name, s->line);
            var_push(cg, s->as.guard_let.name, inner);
        }
        return;
    }
    case ST_UNSAFE:
        walk_block(cg, esc, s->as.unsafe_blk.body);
        return;
    case ST_BREAK:
    case ST_CONTINUE:
    case ST_STRUCT:
    case ST_IMPL:
        return;
    }
}

static void walk_block(CG *cg, Esc *esc, Block *b) {
    int mark = esc->ncand;
    var_scope_push(cg);
    for (int i = 0; i < b->count; i++)
        walk_stmt(cg, esc, b->stmts[i]);
    var_scope_pop(cg);
    esc->ncand = mark;
}

static void walk_fn(CG *cg, Esc *esc, Block *body, char **params,
                    const char **param_types, int nparams) {
    esc->ncand = 0;
    var_scope_reset(cg);
    var_scope_push(cg);
    for (int i = 0; i < nparams; i++) {
        esc_push(esc, params[i], NULL);
        var_push(cg, params[i], param_types[i]);
    }
    for (int i = 0; i < body->count; i++)
        walk_stmt(cg, esc, body->stmts[i]);
}

void compute_escape(CG *cg, Package *pkgs, int npkgs, int main_index) {
    Esc esc;
    memset(&esc, 0, sizeof(esc));
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
            walk_fn(cg, &esc, f->body, f->params, sig->param_slang, f->nparams);
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
                walk_fn(cg, &esc, f->body, f->params, sig->param_slang,
                        f->nparams);
                cg->in_function = 0;
            }
        }
    }
    cg->in_function = 1;
    cg->cur_ret = NULL;
    cg->cur_pkg = pkgs[main_index].name;
    walk_fn(cg, &esc, pkgs[main_index].prog->main_body, NULL, NULL, 0);
    cg->in_function = 0;
}
