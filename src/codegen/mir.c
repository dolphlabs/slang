#include "internal.h"

#include <string.h>

typedef struct {
    int cont;
    int brk;
} LoopFrame;

typedef struct {
    CG *cg;
    MirFn *fn;
    int cur;
    int tmp;
    LoopFrame *loops;
    int nloops;
    int loopcap;
} Lower;

static MirPlace *pl_local(const char *name) {
    MirPlace *p = (MirPlace *)xmalloc(sizeof(MirPlace));
    memset(p, 0, sizeof(MirPlace));
    p->kind = MP_LOCAL;
    p->as.local = xstrdup(name);
    return p;
}

static MirPlace *pl_field(MirPlace *base, const char *field) {
    MirPlace *p = (MirPlace *)xmalloc(sizeof(MirPlace));
    memset(p, 0, sizeof(MirPlace));
    p->kind = MP_FIELD;
    p->as.field.base = base;
    p->as.field.field = xstrdup(field);
    return p;
}

static MirPlace *pl_deref(MirPlace *base) {
    MirPlace *p = (MirPlace *)xmalloc(sizeof(MirPlace));
    memset(p, 0, sizeof(MirPlace));
    p->kind = MP_DEREF;
    p->as.deref = base;
    return p;
}

static MirPlace *pl_index(MirPlace *base, Expr *index) {
    MirPlace *p = (MirPlace *)xmalloc(sizeof(MirPlace));
    memset(p, 0, sizeof(MirPlace));
    p->kind = MP_INDEX;
    p->as.index.base = base;
    p->as.index.index = index;
    return p;
}

static MirRvalue *rv_use(MirPlace *pl, int line) {
    MirRvalue *r = (MirRvalue *)xmalloc(sizeof(MirRvalue));
    memset(r, 0, sizeof(MirRvalue));
    r->kind = MR_USE;
    r->place = pl;
    r->line = line;
    return r;
}

static MirRvalue *rv_ref(MirPlace *pl, int mut, int line) {
    MirRvalue *r = (MirRvalue *)xmalloc(sizeof(MirRvalue));
    memset(r, 0, sizeof(MirRvalue));
    r->kind = mut ? MR_REFMUT : MR_REF;
    r->place = pl;
    r->line = line;
    return r;
}

static MirRvalue *rv_expr(Expr *e) {
    MirRvalue *r = (MirRvalue *)xmalloc(sizeof(MirRvalue));
    memset(r, 0, sizeof(MirRvalue));
    r->kind = MR_EXPR;
    r->expr = e;
    r->line = e->line;
    return r;
}

static Expr *ex_new(ExprKind kind, int line) {
    Expr *e = (Expr *)xmalloc(sizeof(Expr));
    memset(e, 0, sizeof(Expr));
    e->kind = kind;
    e->line = line;
    return e;
}

static Expr *ex_ident(const char *name, int line) {
    Expr *e = ex_new(EX_IDENT, line);
    e->as.ident.name = xstrdup(name);
    return e;
}

static Expr *ex_bin(const char *op, Expr *l, Expr *r, int line) {
    Expr *e = ex_new(EX_BINARY, line);
    e->as.binary.op = xstrdup(op);
    e->as.binary.lhs = l;
    e->as.binary.rhs = r;
    return e;
}

static int new_bb(Lower *L) {
    MirFn *fn = L->fn;
    if (fn->nblocks == fn->bcap) {
        fn->bcap = fn->bcap ? fn->bcap * 2 : 8;
        fn->blocks = (MirBlock *)xrealloc(fn->blocks,
                                          (size_t)fn->bcap * sizeof(MirBlock));
    }
    memset(&fn->blocks[fn->nblocks], 0, sizeof(MirBlock));
    fn->blocks[fn->nblocks].term.kind = MT_NONE;
    return fn->nblocks++;
}

static int sealed(Lower *L) {
    return L->fn->blocks[L->cur].term.kind != MT_NONE;
}

static void set_term(Lower *L, MirTerm t) {
    if (sealed(L))
        return;
    L->fn->blocks[L->cur].term = t;
}

static void emit_goto(Lower *L, int target, int line) {
    MirTerm t;
    memset(&t, 0, sizeof(t));
    t.kind = MT_GOTO;
    t.line = line;
    t.target = target;
    set_term(L, t);
}

static void emit_if(Lower *L, MirPlace *cond, int then_bb, int else_bb,
                    int line) {
    MirTerm t;
    memset(&t, 0, sizeof(t));
    t.kind = MT_IF;
    t.line = line;
    t.cond = cond;
    t.then_bb = then_bb;
    t.else_bb = else_bb;
    set_term(L, t);
}

static void push_stmt(Lower *L, MirStmt *s) {
    if (sealed(L))
        return;
    MirBlock *b = &L->fn->blocks[L->cur];
    if (b->nstmts == b->cap) {
        b->cap = b->cap ? b->cap * 2 : 8;
        b->stmts = (MirStmt **)xrealloc(b->stmts,
                                        (size_t)b->cap * sizeof(MirStmt *));
    }
    b->stmts[b->nstmts++] = s;
}

static void add_local(Lower *L, const char *name, const char *ty) {
    MirFn *fn = L->fn;
    if (fn->nlocals == fn->lcap) {
        fn->lcap = fn->lcap ? fn->lcap * 2 : 8;
        fn->locals = (MirLocal *)xrealloc(fn->locals,
                                          (size_t)fn->lcap * sizeof(MirLocal));
    }
    fn->locals[fn->nlocals].name = xstrdup(name);
    fn->locals[fn->nlocals].ty = ty;
    fn->nlocals++;
}

static char *fresh(Lower *L, const char *ty) {
    char *n = xasprintf("_t%d", L->tmp++);
    add_local(L, n, ty);
    return n;
}

static void push_loop(Lower *L, int cont, int brk) {
    if (L->nloops == L->loopcap) {
        L->loopcap = L->loopcap ? L->loopcap * 2 : 4;
        L->loops = (LoopFrame *)xrealloc(L->loops,
                                         (size_t)L->loopcap * sizeof(LoopFrame));
    }
    L->loops[L->nloops].cont = cont;
    L->loops[L->nloops].brk = brk;
    L->nloops++;
}

static void pop_loop(Lower *L) { L->nloops--; }

static MirPlace *as_place(CG *cg, Expr *e) {
    if (!e)
        return NULL;
    switch (e->kind) {
    case EX_IDENT: {
        char *left, *right;
        if (split_dotted(e->as.ident.name, &left, &right) &&
            !import_try(cg, left))
            return pl_field(pl_local(left), right);
        return pl_local(e->as.ident.name);
    }
    case EX_FIELD: {
        MirPlace *b = as_place(cg, e->as.field.base);
        return b ? pl_field(b, e->as.field.name) : NULL;
    }
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "*")) {
            MirPlace *b = as_place(cg, e->as.unary.operand);
            return b ? pl_deref(b) : NULL;
        }
        return NULL;
    case EX_INDEX: {
        MirPlace *b = as_place(cg, e->as.index.base);
        return b ? pl_index(b, e->as.index.index) : NULL;
    }
    default:
        return NULL;
    }
}

static MirRvalue *lower_rvalue(Lower *L, Expr *e) {
    if (e->kind == EX_UNARY &&
        (!strcmp(e->as.unary.op, "&") || !strcmp(e->as.unary.op, "&mut"))) {
        MirPlace *pl = as_place(L->cg, e->as.unary.operand);
        if (pl)
            return rv_ref(pl, !strcmp(e->as.unary.op, "&mut"), e->line);
    }
    MirPlace *pl = as_place(L->cg, e);
    if (pl)
        return rv_use(pl, e->line);
    return rv_expr(e);
}

static void emit_assign(Lower *L, MirPlace *dest, MirRvalue *src, int line) {
    MirStmt *s = (MirStmt *)xmalloc(sizeof(MirStmt));
    memset(s, 0, sizeof(MirStmt));
    s->kind = MS_ASSIGN;
    s->line = line;
    s->dest = dest;
    s->src = src;
    push_stmt(L, s);
}

static void emit_eval(Lower *L, MirRvalue *src, int line) {
    MirStmt *s = (MirStmt *)xmalloc(sizeof(MirStmt));
    memset(s, 0, sizeof(MirStmt));
    s->kind = MS_EVAL;
    s->line = line;
    s->src = src;
    push_stmt(L, s);
}

static MirPlace *lower_cond(Lower *L, Expr *e) {
    MirRvalue *rv = lower_rvalue(L, e);
    if (rv->kind == MR_USE && rv->place->kind == MP_LOCAL)
        return rv->place;
    char *t = fresh(L, "bool");
    emit_assign(L, pl_local(t), rv, e->line);
    return pl_local(t);
}

static const char *let_ty(Lower *L, Stmt *s) {
    const char *ann = s->as.let.type_ann;
    if (ann)
        ann = canon_type(L->cg, ann, s->line);
    Expr *init = s->as.let.init;
    if (init->kind == EX_LIST && init->as.list.nelems == 0)
        return ann;
    if (init->kind == EX_MAPLIT && init->as.maplit.npairs == 0)
        return ann;
    const char *saved = expect_push(L->cg, ann);
    const char *it = infer_type(L->cg, init);
    L->cg->expect = saved;
    return ann ? ann : it;
}

static void lower_stmts(Lower *L, Stmt **stmts, int count);
static void lower_block(Lower *L, Block *b);

static void lower_stmt(Lower *L, Stmt *s) {
    if (sealed(L))
        return;
    switch (s->kind) {
    case ST_LET: {
        const char *t = let_ty(L, s);
        add_local(L, s->as.let.name, t);
        var_redecl_check(L->cg, s->as.let.name, s->line);
        var_push(L->cg, s->as.let.name, t);
        emit_assign(L, pl_local(s->as.let.name),
                    lower_rvalue(L, s->as.let.init), s->line);
        return;
    }
    case ST_ASSIGN: {
        MirPlace *dest = as_place(L->cg, s->as.assign.target);
        if (!dest)
            dest = pl_local("_");
        emit_assign(L, dest, lower_rvalue(L, s->as.assign.value), s->line);
        if (s->as.assign.target->kind == EX_IDENT) {
            char *left, *right;
            if (!(split_dotted(s->as.assign.target->as.ident.name, &left,
                               &right) &&
                  !import_try(L->cg, left))) {
                VarSym *v = var_find(L->cg, s->as.assign.target->as.ident.name);
                if (v)
                    v->moved = 0;
            }
        }
        return;
    }
    case ST_IF: {
        MirPlace *cond = lower_cond(L, s->as.if_stmt.cond);
        int then_bb = new_bb(L);
        int else_bb = new_bb(L);
        int join = new_bb(L);
        emit_if(L, cond, then_bb, else_bb, s->line);
        L->cur = then_bb;
        var_scope_push(L->cg);
        lower_block(L, s->as.if_stmt.then_blk);
        var_scope_pop(L->cg);
        emit_goto(L, join, s->line);
        L->cur = else_bb;
        if (s->as.if_stmt.else_blk) {
            var_scope_push(L->cg);
            lower_block(L, s->as.if_stmt.else_blk);
            var_scope_pop(L->cg);
        }
        emit_goto(L, join, s->line);
        L->cur = join;
        return;
    }
    case ST_WHILE: {
        int hdr = new_bb(L);
        int body = new_bb(L);
        int exit = new_bb(L);
        emit_goto(L, hdr, s->line);
        L->cur = hdr;
        MirPlace *cond = lower_cond(L, s->as.while_stmt.cond);
        emit_if(L, cond, body, exit, s->line);
        L->cur = body;
        push_loop(L, hdr, exit);
        var_scope_push(L->cg);
        lower_stmts(L, s->as.while_stmt.body->stmts,
                    s->as.while_stmt.body->count);
        var_scope_pop(L->cg);
        pop_loop(L);
        emit_goto(L, hdr, s->line);
        L->cur = exit;
        return;
    }
    case ST_FOR: {
        add_local(L, s->as.for_stmt.name, "int");
        var_scope_push(L->cg);
        var_push(L->cg, s->as.for_stmt.name, "int");
        char *endn = fresh(L, "int");
        emit_assign(L, pl_local(s->as.for_stmt.name),
                    lower_rvalue(L, s->as.for_stmt.start), s->line);
        emit_assign(L, pl_local(endn), lower_rvalue(L, s->as.for_stmt.end),
                    s->line);
        int hdr = new_bb(L);
        int body = new_bb(L);
        int inc = new_bb(L);
        int exit = new_bb(L);
        emit_goto(L, hdr, s->line);
        L->cur = hdr;
        const char *op = s->as.for_stmt.inclusive ? "<=" : "<";
        Expr *cmp = ex_bin(op, ex_ident(s->as.for_stmt.name, s->line),
                           ex_ident(endn, s->line), s->line);
        MirPlace *cond = lower_cond(L, cmp);
        emit_if(L, cond, body, exit, s->line);
        L->cur = body;
        push_loop(L, inc, exit);
        var_scope_push(L->cg);
        lower_stmts(L, s->as.for_stmt.body->stmts,
                    s->as.for_stmt.body->count);
        var_scope_pop(L->cg);
        pop_loop(L);
        emit_goto(L, inc, s->line);
        L->cur = inc;
        Expr *plus = ex_bin("+", ex_ident(s->as.for_stmt.name, s->line),
                            ex_new(EX_INT, s->line), s->line);
        plus->as.binary.rhs->as.int_lit.value = 1;
        emit_assign(L, pl_local(s->as.for_stmt.name), rv_expr(plus), s->line);
        emit_goto(L, hdr, s->line);
        L->cur = exit;
        var_scope_pop(L->cg);
        return;
    }
    case ST_FOR_IN: {
        const char *it = infer_type(L->cg, s->as.for_in.iter);
        const char *n1 = "int";
        const char *n2 = NULL;
        var_scope_push(L->cg);
        if (is_arr(it)) {
            n1 = arr_elem(it);
            var_push(L->cg, s->as.for_in.name, n1);
        } else if (is_bytes(it)) {
            var_push(L->cg, s->as.for_in.name, n1);
        } else if (is_map(it)) {
            char *k, *v;
            map_kv(it, &k, &v);
            n1 = k;
            n2 = v;
            var_push(L->cg, s->as.for_in.name, n1);
            if (s->as.for_in.name2)
                var_push(L->cg, s->as.for_in.name2, n2);
        }
        add_local(L, s->as.for_in.name, n1);
        if (s->as.for_in.name2)
            add_local(L, s->as.for_in.name2, n2 ? n2 : "int");
        int hdr = new_bb(L);
        int body = new_bb(L);
        int exit = new_bb(L);
        emit_goto(L, hdr, s->line);
        L->cur = hdr;
        {
            MirTerm t;
            memset(&t, 0, sizeof(t));
            t.kind = MT_FOR_IN;
            t.line = s->line;
            t.iter = lower_rvalue(L, s->as.for_in.iter);
            t.name = xstrdup(s->as.for_in.name);
            t.name2 = s->as.for_in.name2 ? xstrdup(s->as.for_in.name2) : NULL;
            t.then_bb = body;
            t.else_bb = exit;
            set_term(L, t);
        }
        L->cur = body;
        push_loop(L, hdr, exit);
        var_scope_push(L->cg);
        lower_block(L, s->as.for_in.body);
        var_scope_pop(L->cg);
        pop_loop(L);
        emit_goto(L, hdr, s->line);
        L->cur = exit;
        var_scope_pop(L->cg);
        return;
    }
    case ST_RETURN: {
        MirTerm t;
        memset(&t, 0, sizeof(t));
        t.kind = MT_RETURN;
        t.line = s->line;
        if (s->as.ret.value)
            t.ret = lower_rvalue(L, s->as.ret.value);
        set_term(L, t);
        return;
    }
    case ST_BREAK: {
        if (L->nloops <= 0)
            cg_error(s->line, "'break' outside a loop");
        emit_goto(L, L->loops[L->nloops - 1].brk, s->line);
        return;
    }
    case ST_CONTINUE: {
        if (L->nloops <= 0)
            cg_error(s->line, "'continue' outside a loop");
        emit_goto(L, L->loops[L->nloops - 1].cont, s->line);
        return;
    }
    case ST_EXPR:
        emit_eval(L, lower_rvalue(L, s->as.expr_stmt.expr), s->line);
        return;
    case ST_SPAWN:
        emit_eval(L, lower_rvalue(L, s->as.spawn.call), s->line);
        return;
    case ST_GUARD_LET: {
        const char *et = infer_type(L->cg, s->as.guard_let.expr);
        char *inner = NULL;
        if (is_opt(et))
            inner = opt_inner(et);
        else if (is_result(et)) {
            char *tv, *tev;
            result_te(et, &tv, &tev);
            inner = tv;
        }
        MirPlace *cond = lower_cond(L, s->as.guard_let.expr);
        int ok_bb = new_bb(L);
        int else_bb = new_bb(L);
        emit_if(L, cond, ok_bb, else_bb, s->line);
        L->cur = else_bb;
        var_scope_push(L->cg);
        /* `else let e = err_of(r)` binds e for the whole else block, so
           this pass has to know about it too -- liveness, escape and
           move all declare it before walking the body, and MIR was the
           one that did not. A `let` inside the else block resolves its
           initializer's type through the var table, so referring to e
           there was rejected as an undefined variable even though the
           emitted C was fine. Using e directly (println, a call
           argument) happened to work, which is why this survived. */
        if (s->as.guard_let.err_name && is_result(et)) {
            char *gtv, *gtev;
            result_te(et, &gtv, &gtev);
            var_redecl_check(L->cg, s->as.guard_let.err_name, s->line);
            var_push(L->cg, s->as.guard_let.err_name, gtev);
        }
        lower_block(L, s->as.guard_let.body);
        var_scope_pop(L->cg);
        L->cur = ok_bb;
        if (inner) {
            add_local(L, s->as.guard_let.name, inner);
            var_redecl_check(L->cg, s->as.guard_let.name, s->line);
            var_push(L->cg, s->as.guard_let.name, inner);
            emit_assign(L, pl_local(s->as.guard_let.name),
                        lower_rvalue(L, s->as.guard_let.expr), s->line);
        }
        return;
    }
    case ST_UNSAFE:
        lower_block(L, s->as.unsafe_blk.body);
        return;
    case ST_STRUCT:
    case ST_IMPL:
        return;
    }
}

static void lower_stmts(Lower *L, Stmt **stmts, int count) {
    for (int i = 0; i < count; i++)
        lower_stmt(L, stmts[i]);
}

static void lower_block(Lower *L, Block *b) {
    lower_stmts(L, b->stmts, b->count);
}

static MirFn *lower_fn(CG *cg, const char *pkg, const char *name, Block *body,
                       char **params, const char **param_types, int nparams) {
    MirFn *fn = (MirFn *)xmalloc(sizeof(MirFn));
    memset(fn, 0, sizeof(MirFn));
    fn->pkg = xstrdup(pkg);
    fn->name = xstrdup(name);
    Lower L;
    memset(&L, 0, sizeof(L));
    L.cg = cg;
    L.fn = fn;
    L.cur = new_bb(&L);
    var_scope_reset(cg);
    var_scope_push(cg);
    for (int i = 0; i < nparams; i++) {
        add_local(&L, params[i], param_types[i]);
        var_push(cg, params[i], param_types[i]);
    }
    lower_stmts(&L, body->stmts, body->count);
    if (!sealed(&L)) {
        MirTerm t;
        memset(&t, 0, sizeof(t));
        t.kind = MT_RETURN;
        set_term(&L, t);
    }
    for (int i = 0; i < fn->nblocks; i++) {
        if (fn->blocks[i].term.kind == MT_NONE)
            fn->blocks[i].term.kind = MT_UNREACHABLE;
    }
    return fn;
}

static void mir_push(CG *cg, MirFn *fn) {
    if (cg->mirs.count == cg->mirs.cap) {
        cg->mirs.cap = cg->mirs.cap ? cg->mirs.cap * 2 : 8;
        cg->mirs.items = (MirFn **)xrealloc(cg->mirs.items,
                                            (size_t)cg->mirs.cap *
                                                sizeof(MirFn *));
    }
    cg->mirs.items[cg->mirs.count++] = fn;
}

void compute_mir(CG *cg, Package *pkgs, int npkgs, int main_index) {
    cg->mirs.count = 0;
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
            mir_push(cg, lower_fn(cg, p->name, f->name, f->body, f->params,
                                  sig->param_slang, f->nparams));
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
                char *mname =
                    xasprintf("%s.%s", s->as.impl.struct_name, f->name);
                mir_push(cg, lower_fn(cg, p->name, mname, f->body, f->params,
                                      sig->param_slang, f->nparams));
                cg->in_function = 0;
            }
        }
    }
    cg->in_function = 1;
    cg->cur_ret = NULL;
    cg->cur_pkg = pkgs[main_index].name;
    mir_push(cg, lower_fn(cg, pkgs[main_index].name, "main",
                          pkgs[main_index].prog->main_body, NULL, NULL, 0));
    cg->in_function = 0;
}

static void dump_place(FILE *out, MirPlace *p) {
    if (!p) {
        fputs("_", out);
        return;
    }
    switch (p->kind) {
    case MP_LOCAL:
        fputs(p->as.local, out);
        return;
    case MP_FIELD:
        dump_place(out, p->as.field.base);
        fprintf(out, ".%s", p->as.field.field);
        return;
    case MP_DEREF:
        fputs("(*", out);
        dump_place(out, p->as.deref);
        fputs(")", out);
        return;
    case MP_INDEX:
        dump_place(out, p->as.index.base);
        fputs("[_]", out);
        return;
    }
}

static void dump_rvalue(FILE *out, MirRvalue *r) {
    if (!r) {
        fputs("_", out);
        return;
    }
    switch (r->kind) {
    case MR_USE:
        dump_place(out, r->place);
        return;
    case MR_REF:
        fputs("&", out);
        dump_place(out, r->place);
        return;
    case MR_REFMUT:
        fputs("&mut ", out);
        dump_place(out, r->place);
        return;
    case MR_EXPR:
        switch (r->expr->kind) {
        case EX_INT:
            fprintf(out, "%lld", r->expr->as.int_lit.value);
            return;
        case EX_BOOL:
            fputs(r->expr->as.bool_lit.value ? "true" : "false", out);
            return;
        case EX_IDENT:
            fputs(r->expr->as.ident.name, out);
            return;
        case EX_CALL:
            fprintf(out, "call %s", r->expr->as.call.name);
            return;
        case EX_SPAWN:
            fprintf(out, "spawn %s", r->expr->as.spawn.call->as.call.name);
            return;
        case EX_BINARY:
            fprintf(out, "(%s)", r->expr->as.binary.op);
            return;
        case EX_STRUCTLIT:
            fprintf(out, "struct %s", r->expr->as.structlit.tyname);
            return;
        default:
            fputs("expr", out);
            return;
        }
    }
}

static void dump_fn(FILE *out, MirFn *fn) {
    fprintf(out, "fn %s.%s\n", fn->pkg, fn->name);
    for (int i = 0; i < fn->nlocals; i++)
        fprintf(out, "  local %s: %s\n", fn->locals[i].name,
                fn->locals[i].ty ? fn->locals[i].ty : "?");
    for (int b = 0; b < fn->nblocks; b++) {
        MirBlock *bb = &fn->blocks[b];
        fprintf(out, "  bb%d:\n", b);
        for (int i = 0; i < bb->nstmts; i++) {
            MirStmt *s = bb->stmts[i];
            fputs("    ", out);
            if (s->kind == MS_ASSIGN) {
                dump_place(out, s->dest);
                fputs(" = ", out);
                dump_rvalue(out, s->src);
            } else {
                fputs("eval ", out);
                dump_rvalue(out, s->src);
            }
            fputc('\n', out);
        }
        fputs("    ", out);
        switch (bb->term.kind) {
        case MT_GOTO:
            fprintf(out, "goto bb%d\n", bb->term.target);
            break;
        case MT_IF:
            fputs("if ", out);
            dump_place(out, bb->term.cond);
            fprintf(out, " -> bb%d bb%d\n", bb->term.then_bb, bb->term.else_bb);
            break;
        case MT_RETURN:
            fputs("return", out);
            if (bb->term.ret) {
                fputs(" ", out);
                dump_rvalue(out, bb->term.ret);
            }
            fputc('\n', out);
            break;
        case MT_FOR_IN:
            fputs("for-in ", out);
            dump_rvalue(out, bb->term.iter);
            fprintf(out, " -> bb%d bb%d\n", bb->term.then_bb, bb->term.else_bb);
            break;
        case MT_UNREACHABLE:
            fputs("unreachable\n", out);
            break;
        default:
            fputs("?\n", out);
            break;
        }
    }
}

void dump_mir(Package *pkgs, int npkgs, int main_index, FILE *out) {
    CG cg;
    memset(&cg, 0, sizeof(cg));
    for (int i = 0; i < npkgs; i++) {
        if (!pkgs[i].native)
            continue;
        cg.nat_pkgs = (char **)xrealloc(
            cg.nat_pkgs, (size_t)(cg.nnat + 1) * sizeof(char *));
        cg.nat_pkgs[cg.nnat++] = pkgs[i].name;
    }
    collect_decls(&cg, pkgs, npkgs);
    StrBuf scratch;
    sb_init(&scratch);
    cg.out = &scratch;
    gen_whole_program(&cg, pkgs, npkgs, main_index);
    free(scratch.data);
    compute_mir(&cg, pkgs, npkgs, main_index);
    for (int i = 0; i < cg.mirs.count; i++)
        dump_fn(out, cg.mirs.items[i]);
}
