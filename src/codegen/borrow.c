#include "internal.h"

#include <string.h>

typedef struct {
    char *root;
    char *borrower;
    int mut;
    int line;
} Loan;

typedef struct {
    Loan *items;
    int n;
    int cap;
} LoanSet;

typedef struct {
    CG *cg;
    MirFn *fn;
    LoanSet cur;
    int nlocs;
    unsigned char *live_in;
    unsigned char *live_out;
    int *is_param;
    int *use;
    int *def;
} BK;

static const char *local_ty(MirFn *fn, const char *name) {
    for (int i = fn->nlocals - 1; i >= 0; i--) {
        if (!strcmp(fn->locals[i].name, name))
            return fn->locals[i].ty;
    }
    return NULL;
}

static int loc_idx(MirFn *fn, const char *name) {
    for (int i = fn->nlocals - 1; i >= 0; i--) {
        if (!strcmp(fn->locals[i].name, name))
            return i;
    }
    return -1;
}

static int wrap_is_ref(const char *t, int *mut) {
    char *inner;
    TypeWrap w;
    if (!t)
        return 0;
    w = type_wrap(t, &inner);
    if (w == TW_REFMUT) {
        if (mut)
            *mut = 1;
        return 1;
    }
    if (w == TW_REF) {
        if (mut)
            *mut = 0;
        return 1;
    }
    return 0;
}

static int local_is_ref(BK *bk, const char *name) {
    return wrap_is_ref(local_ty(bk->fn, name), NULL);
}

static int skip_gc(BK *bk, const char *name) {
    const char *t = local_ty(bk->fn, name);
    char *inner;
    TypeWrap w;
    if (!t)
        return 0;
    w = type_wrap(t, &inner);
    if (w == TW_GC)
        return 1;
    if (w != TW_NONE)
        return 0;
    return struct_type_is_gc(bk->cg, t);
}

static int name_is_param(BK *bk, const char *name) {
    int i = loc_idx(bk->fn, name);
    return i >= 0 && bk->is_param[i];
}

static void ls_add(LoanSet *s, const char *root, const char *borrower, int mut,
                   int line) {
    int i;
    for (i = 0; i < s->n; i++) {
        if (strcmp(s->items[i].root, root))
            continue;
        if (s->items[i].borrower && borrower &&
            !strcmp(s->items[i].borrower, borrower) &&
            s->items[i].mut == mut)
            return;
        if (!s->items[i].borrower && !borrower && s->items[i].mut == mut)
            return;
    }
    if (s->n == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 8;
        s->items = (Loan *)xrealloc(s->items, (size_t)s->cap * sizeof(Loan));
    }
    s->items[s->n].root = xstrdup(root);
    s->items[s->n].borrower = borrower ? xstrdup(borrower) : NULL;
    s->items[s->n].mut = mut;
    s->items[s->n].line = line;
    s->n++;
}

static void ls_kill_borrower(LoanSet *s, const char *name) {
    int i = 0;
    if (!name)
        return;
    while (i < s->n) {
        if (s->items[i].borrower && !strcmp(s->items[i].borrower, name)) {
            s->items[i] = s->items[s->n - 1];
            s->n--;
            continue;
        }
        i++;
    }
}

static void ls_kill_temps(LoanSet *s) {
    int i = 0;
    while (i < s->n) {
        if (!s->items[i].borrower) {
            s->items[i] = s->items[s->n - 1];
            s->n--;
            continue;
        }
        i++;
    }
}

static void ls_clone_into(LoanSet *dst, const LoanSet *src) {
    int i;
    dst->n = 0;
    for (i = 0; i < src->n; i++)
        ls_add(dst, src->items[i].root, src->items[i].borrower,
               src->items[i].mut, src->items[i].line);
}

static void ls_union(LoanSet *dst, const LoanSet *src) {
    int i;
    for (i = 0; i < src->n; i++)
        ls_add(dst, src->items[i].root, src->items[i].borrower,
               src->items[i].mut, src->items[i].line);
}

static int ls_eq(const LoanSet *a, const LoanSet *b) {
    int i, j;
    if (a->n != b->n)
        return 0;
    for (i = 0; i < a->n; i++) {
        int found = 0;
        for (j = 0; j < b->n; j++) {
            if (strcmp(a->items[i].root, b->items[j].root))
                continue;
            if (a->items[i].mut != b->items[j].mut)
                continue;
            if (!a->items[i].borrower && !b->items[j].borrower) {
                found = 1;
                break;
            }
            if (a->items[i].borrower && b->items[j].borrower &&
                !strcmp(a->items[i].borrower, b->items[j].borrower)) {
                found = 1;
                break;
            }
        }
        if (!found)
            return 0;
    }
    return 1;
}

static void check_borrow(BK *bk, const char *root, int mut, int line) {
    int i;
    if (!root || skip_gc(bk, root))
        return;
    for (i = 0; i < bk->cur.n; i++) {
        Loan *l = &bk->cur.items[i];
        if (strcmp(l->root, root))
            continue;
        if (mut && l->mut)
            cg_error(line, "cannot borrow '%s' as mutable more than once",
                     root);
        if (mut && !l->mut)
            cg_error(line,
                     "cannot borrow '%s' as mutable because it is also "
                     "borrowed as immutable",
                     root);
        if (!mut && l->mut)
            cg_error(line,
                     "cannot borrow '%s' as immutable because it is also "
                     "borrowed as mutable",
                     root);
    }
}

static void check_write(BK *bk, const char *root, int line) {
    int i;
    if (!root || skip_gc(bk, root))
        return;
    for (i = 0; i < bk->cur.n; i++) {
        if (!strcmp(bk->cur.items[i].root, root))
            cg_error(line, "cannot assign to '%s' because it is borrowed",
                     root);
    }
}

static void check_read(BK *bk, const char *root, int moving, int line) {
    int i;
    if (!root || skip_gc(bk, root))
        return;
    for (i = 0; i < bk->cur.n; i++) {
        Loan *l = &bk->cur.items[i];
        if (strcmp(l->root, root))
            continue;
        if (moving)
            cg_error(line, "cannot move '%s' because it is borrowed", root);
        if (l->mut)
            cg_error(line, "cannot use '%s' because it is mutably borrowed",
                     root);
    }
}

static const char *place_base(MirPlace *p) {
    if (!p)
        return NULL;
    switch (p->kind) {
    case MP_LOCAL:
        return p->as.local;
    case MP_FIELD:
        return place_base(p->as.field.base);
    case MP_DEREF:
        return place_base(p->as.deref);
    case MP_INDEX:
        return place_base(p->as.index.base);
    }
    return NULL;
}

static int place_deep(MirPlace *p) {
    return p && p->kind != MP_LOCAL;
}

static void access_place(BK *bk, MirPlace *p, int write, int moving, int line) {
    const char *base = place_base(p);
    if (!base)
        return;
    if (local_is_ref(bk, base) && (place_deep(p) || !write))
        return;
    if (write)
        check_write(bk, base, line);
    else
        check_read(bk, base, moving, line);
}

static void copy_loans(BK *bk, const char *src, const char *dest, int mut,
                       int line) {
    (void)line;
    int i, n, found = 0;
    if (!src)
        return;
    n = bk->cur.n;
    for (i = 0; i < n; i++) {
        Loan *l = &bk->cur.items[i];
        if (!l->borrower || strcmp(l->borrower, src))
            continue;
        found = 1;
        ls_add(&bk->cur, l->root, dest, mut || l->mut, line);
    }
    if (!found && local_is_ref(bk, src)) {
        int sm = 0;
        wrap_is_ref(local_ty(bk->fn, src), &sm);
        ls_add(&bk->cur, src, dest, mut || sm, line);
    }
}

static void borrow_place(BK *bk, MirPlace *p, int mut, const char *dest,
                         int line) {
    const char *base = place_base(p);
    if (!base || skip_gc(bk, base))
        return;
    if (local_is_ref(bk, base)) {
        copy_loans(bk, base, dest, mut, line);
        return;
    }
    check_borrow(bk, base, mut, line);
    ls_add(&bk->cur, base, dest, mut, line);
}

static void mark_name(BK *bk, const char *name, int isdef) {
    int i = loc_idx(bk->fn, name);
    if (i < 0)
        return;
    if (isdef)
        bk->def[i] = 1;
    else
        bk->use[i] = 1;
}

static void mark_place(BK *bk, MirPlace *p, int isdef) {
    const char *base;
    if (!p)
        return;
    base = place_base(p);
    if (!base)
        return;
    if (isdef && !place_deep(p))
        mark_name(bk, base, 1);
    else
        mark_name(bk, base, 0);
}

static void mark_expr(BK *bk, CG *cg, Expr *e);

static void mark_ident(BK *bk, CG *cg, const char *name) {
    char *left, *right;
    if (split_dotted(name, &left, &right) && !import_try(cg, left))
        mark_name(bk, left, 0);
    else if (!strchr(name, '.'))
        mark_name(bk, name, 0);
}

static void mark_expr(BK *bk, CG *cg, Expr *e) {
    int i;
    if (!e)
        return;
    switch (e->kind) {
    case EX_IDENT:
        mark_ident(bk, cg, e->as.ident.name);
        return;
    case EX_FIELD:
        mark_expr(bk, cg, e->as.field.base);
        return;
    case EX_UNARY:
        mark_expr(bk, cg, e->as.unary.operand);
        return;
    case EX_BINARY:
        mark_expr(bk, cg, e->as.binary.lhs);
        mark_expr(bk, cg, e->as.binary.rhs);
        return;
    case EX_CALL:
        mark_ident(bk, cg, e->as.call.name);
        for (i = 0; i < e->as.call.nargs; i++)
            mark_expr(bk, cg, e->as.call.args[i]);
        return;
    case EX_CAST:
        mark_expr(bk, cg, e->as.cast.operand);
        return;
    case EX_INDEX:
        mark_expr(bk, cg, e->as.index.base);
        mark_expr(bk, cg, e->as.index.index);
        return;
    case EX_SLICE:
        mark_expr(bk, cg, e->as.slice.base);
        mark_expr(bk, cg, e->as.slice.start);
        mark_expr(bk, cg, e->as.slice.end);
        return;
    case EX_LIST:
        for (i = 0; i < e->as.list.nelems; i++)
            mark_expr(bk, cg, e->as.list.elems[i]);
        return;
    case EX_MAPLIT:
        for (i = 0; i < e->as.maplit.npairs; i++) {
            mark_expr(bk, cg, e->as.maplit.keys[i]);
            mark_expr(bk, cg, e->as.maplit.vals[i]);
        }
        return;
    case EX_STRUCTLIT:
        for (i = 0; i < e->as.structlit.nfields; i++)
            mark_expr(bk, cg, e->as.structlit.vals[i]);
        return;
    default:
        return;
    }
}

static void mark_rvalue(BK *bk, MirRvalue *r) {
    if (!r)
        return;
    switch (r->kind) {
    case MR_USE:
    case MR_REF:
    case MR_REFMUT:
        mark_place(bk, r->place, 0);
        return;
    case MR_EXPR:
        mark_expr(bk, bk->cg, r->expr);
        return;
    }
}

static void mark_stmt(BK *bk, MirStmt *s) {
    memset(bk->use, 0, (size_t)bk->nlocs * sizeof(int));
    memset(bk->def, 0, (size_t)bk->nlocs * sizeof(int));
    if (s->dest)
        mark_place(bk, s->dest, 1);
    mark_rvalue(bk, s->src);
}

static void mark_term(BK *bk, MirTerm *t) {
    memset(bk->use, 0, (size_t)bk->nlocs * sizeof(int));
    memset(bk->def, 0, (size_t)bk->nlocs * sizeof(int));
    if (t->cond)
        mark_place(bk, t->cond, 0);
    mark_rvalue(bk, t->ret);
    mark_rvalue(bk, t->iter);
}

static void bits_or(unsigned char *dst, const unsigned char *src, int n) {
    int i;
    for (i = 0; i < n; i++)
        dst[i] = (unsigned char)(dst[i] | src[i]);
}

static int bits_eq(const unsigned char *a, const unsigned char *b, int n) {
    return memcmp(a, b, (size_t)n) == 0;
}

static void add_succ(int *succs, int *n, int cap, int t) {
    int i;
    if (t < 0)
        return;
    for (i = 0; i < *n; i++)
        if (succs[i] == t)
            return;
    if (*n < cap)
        succs[(*n)++] = t;
}

static int term_succs(MirTerm *t, int *succs, int cap) {
    int n = 0;
    switch (t->kind) {
    case MT_GOTO:
        add_succ(succs, &n, cap, t->target);
        break;
    case MT_IF:
    case MT_FOR_IN:
        add_succ(succs, &n, cap, t->then_bb);
        add_succ(succs, &n, cap, t->else_bb);
        break;
    default:
        break;
    }
    return n;
}

static void compute_liveness(BK *bk) {
    MirFn *fn = bk->fn;
    int nbb = fn->nblocks;
    int nl = bk->nlocs;
    unsigned char *tmp;
    int changed, b, i, s, ns;
    int succs[8];
    if (nl == 0)
        return;
    bk->live_in = (unsigned char *)xmalloc((size_t)nbb * (size_t)nl);
    bk->live_out = (unsigned char *)xmalloc((size_t)nbb * (size_t)nl);
    memset(bk->live_in, 0, (size_t)nbb * (size_t)nl);
    memset(bk->live_out, 0, (size_t)nbb * (size_t)nl);
    tmp = (unsigned char *)xmalloc((size_t)nl);
    changed = 1;
    while (changed) {
        changed = 0;
        for (b = nbb - 1; b >= 0; b--) {
            MirBlock *bb = &fn->blocks[b];
            ns = term_succs(&bb->term, succs, 8);
            memset(tmp, 0, (size_t)nl);
            for (s = 0; s < ns; s++)
                bits_or(tmp, bk->live_in + succs[s] * nl, nl);
            if (!bits_eq(tmp, bk->live_out + b * nl, nl)) {
                memcpy(bk->live_out + b * nl, tmp, (size_t)nl);
                changed = 1;
            }
            mark_term(bk, &bb->term);
            for (i = 0; i < nl; i++)
                if (bk->use[i])
                    tmp[i] = 1;
            for (i = bb->nstmts - 1; i >= 0; i--) {
                mark_stmt(bk, bb->stmts[i]);
                for (s = 0; s < nl; s++) {
                    if (bk->def[s])
                        tmp[s] = 0;
                    if (bk->use[s])
                        tmp[s] = 1;
                }
            }
            if (!bits_eq(tmp, bk->live_in + b * nl, nl)) {
                memcpy(bk->live_in + b * nl, tmp, (size_t)nl);
                changed = 1;
            }
        }
    }
    free(tmp);
}

static void kill_dead(BK *bk, int bbi, int after) {
    MirBlock *bb = &bk->fn->blocks[bbi];
    unsigned char *bits;
    int i, s, nl = bk->nlocs;
    if (nl == 0) {
        ls_kill_temps(&bk->cur);
        return;
    }
    bits = (unsigned char *)xmalloc((size_t)nl);
    memcpy(bits, bk->live_out + bbi * nl, (size_t)nl);
    mark_term(bk, &bb->term);
    for (i = 0; i < nl; i++)
        if (bk->use[i])
            bits[i] = 1;
    for (i = bb->nstmts - 1; i > after; i--) {
        mark_stmt(bk, bb->stmts[i]);
        for (s = 0; s < nl; s++) {
            if (bk->def[s])
                bits[s] = 0;
            if (bk->use[s])
                bits[s] = 1;
        }
    }
    i = 0;
    while (i < bk->cur.n) {
        Loan *l = &bk->cur.items[i];
        int idx;
        if (!l->borrower) {
            bk->cur.items[i] = bk->cur.items[bk->cur.n - 1];
            bk->cur.n--;
            continue;
        }
        idx = loc_idx(bk->fn, l->borrower);
        if (idx >= 0 && !bits[idx]) {
            bk->cur.items[i] = bk->cur.items[bk->cur.n - 1];
            bk->cur.n--;
            continue;
        }
        i++;
    }
    free(bits);
}

static MirPlace *ast_place(CG *cg, Expr *e) {
    if (!e)
        return NULL;
    switch (e->kind) {
    case EX_IDENT: {
        MirPlace *p = (MirPlace *)xmalloc(sizeof(MirPlace));
        char *left, *right;
        memset(p, 0, sizeof(MirPlace));
        if (split_dotted(e->as.ident.name, &left, &right) &&
            !import_try(cg, left)) {
            MirPlace *b = (MirPlace *)xmalloc(sizeof(MirPlace));
            memset(b, 0, sizeof(MirPlace));
            b->kind = MP_LOCAL;
            b->as.local = left;
            p->kind = MP_FIELD;
            p->as.field.base = b;
            p->as.field.field = right;
            return p;
        }
        p->kind = MP_LOCAL;
        p->as.local = xstrdup(e->as.ident.name);
        return p;
    }
    case EX_FIELD: {
        MirPlace *b = ast_place(cg, e->as.field.base);
        MirPlace *p;
        if (!b)
            return NULL;
        p = (MirPlace *)xmalloc(sizeof(MirPlace));
        memset(p, 0, sizeof(MirPlace));
        p->kind = MP_FIELD;
        p->as.field.base = b;
        p->as.field.field = xstrdup(e->as.field.name);
        return p;
    }
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "*")) {
            MirPlace *b = ast_place(cg, e->as.unary.operand);
            MirPlace *p;
            if (!b)
                return NULL;
            p = (MirPlace *)xmalloc(sizeof(MirPlace));
            memset(p, 0, sizeof(MirPlace));
            p->kind = MP_DEREF;
            p->as.deref = b;
            return p;
        }
        return NULL;
    case EX_INDEX: {
        MirPlace *b = ast_place(cg, e->as.index.base);
        MirPlace *p;
        if (!b)
            return NULL;
        p = (MirPlace *)xmalloc(sizeof(MirPlace));
        memset(p, 0, sizeof(MirPlace));
        p->kind = MP_INDEX;
        p->as.index.base = b;
        p->as.index.index = e->as.index.index;
        return p;
    }
    default:
        return NULL;
    }
}

static void walk_expr(BK *bk, Expr *e, const char *ret_to);

static const char *call_ret_ty(BK *bk, Expr *e) {
    char *left, *right;
    FuncSig *sig = NULL;
    if (e->inf_ty)
        return e->inf_ty;
    if (split_dotted(e->as.call.name, &left, &right)) {
        if (import_try(bk->cg, left))
            sig = sig_find_in(bk->cg, import_try(bk->cg, left), right);
        else {
            const char *recv = local_ty(bk->fn, left);
            StructDef *sd = recv ? struct_of_type(bk->cg, recv) : NULL;
            if (sd)
                sig = method_find(bk->cg, sd, right);
        }
    } else {
        sig = sig_find_in(bk->cg, bk->cg->cur_pkg, e->as.call.name);
    }
    return sig && sig->ret_slang ? sig->ret_slang : NULL;
}

static void walk_call(BK *bk, Expr *e, const char *ret_to) {
    int i, ret_mut = 0, ret_ref;
    const char *rt;
    char *left, *right;
    if (split_dotted(e->as.call.name, &left, &right) &&
        !import_try(bk->cg, left)) {
        MirPlace tmp;
        memset(&tmp, 0, sizeof(tmp));
        tmp.kind = MP_LOCAL;
        tmp.as.local = left;
        access_place(bk, &tmp, 0, 0, e->line);
    }
    rt = call_ret_ty(bk, e);
    ret_ref = wrap_is_ref(rt, &ret_mut);
    for (i = 0; i < e->as.call.nargs; i++) {
        Expr *a = e->as.call.args[i];
        const char *bind = (ret_to && ret_ref) ? ret_to : NULL;
        walk_expr(bk, a, bind);
    }
}

static void walk_expr(BK *bk, Expr *e, const char *ret_to) {
    int i;
    if (!e)
        return;
    switch (e->kind) {
    case EX_IDENT: {
        MirPlace *p = ast_place(bk->cg, e);
        int moving = 0;
        const char *ty;
        if (!p)
            return;
        ty = local_ty(bk->fn, place_base(p));
        if (ty && !type_is_copy(bk->cg, ty) && !local_is_ref(bk, place_base(p)))
            moving = 1;
        if (local_is_ref(bk, place_base(p)) && !place_deep(p)) {
            if (ret_to)
                copy_loans(bk, place_base(p), ret_to, 0, e->line);
        } else {
            access_place(bk, p, 0, moving, e->line);
        }
        return;
    }
    case EX_FIELD:
    case EX_INDEX: {
        MirPlace *p = ast_place(bk->cg, e);
        access_place(bk, p, 0, 0, e->line);
        if (e->kind == EX_INDEX)
            walk_expr(bk, e->as.index.index, NULL);
        return;
    }
    case EX_UNARY:
        if (!strcmp(e->as.unary.op, "&") || !strcmp(e->as.unary.op, "&mut")) {
            MirPlace *p = ast_place(bk->cg, e->as.unary.operand);
            int mut = !strcmp(e->as.unary.op, "&mut");
            if (p)
                borrow_place(bk, p, mut, ret_to, e->line);
            return;
        }
        if (!strcmp(e->as.unary.op, "*")) {
            MirPlace *p = ast_place(bk->cg, e);
            access_place(bk, p, 0, 0, e->line);
            return;
        }
        walk_expr(bk, e->as.unary.operand, NULL);
        return;
    case EX_BINARY:
        walk_expr(bk, e->as.binary.lhs, NULL);
        walk_expr(bk, e->as.binary.rhs, NULL);
        return;
    case EX_CALL:
        walk_call(bk, e, ret_to);
        return;
    case EX_CAST:
        walk_expr(bk, e->as.cast.operand, ret_to);
        return;
    case EX_SLICE:
        walk_expr(bk, e->as.slice.base, NULL);
        walk_expr(bk, e->as.slice.start, NULL);
        walk_expr(bk, e->as.slice.end, NULL);
        return;
    case EX_LIST:
        for (i = 0; i < e->as.list.nelems; i++)
            walk_expr(bk, e->as.list.elems[i], NULL);
        return;
    case EX_MAPLIT:
        for (i = 0; i < e->as.maplit.npairs; i++) {
            walk_expr(bk, e->as.maplit.keys[i], NULL);
            walk_expr(bk, e->as.maplit.vals[i], NULL);
        }
        return;
    case EX_STRUCTLIT:
        for (i = 0; i < e->as.structlit.nfields; i++)
            walk_expr(bk, e->as.structlit.vals[i], NULL);
        return;
    default:
        return;
    }
}

static void walk_rvalue(BK *bk, MirRvalue *r, const char *dest) {
    if (!r)
        return;
    switch (r->kind) {
    case MR_USE: {
        const char *base = place_base(r->place);
        int moving = 0;
        const char *ty = base ? local_ty(bk->fn, base) : NULL;
        if (base && local_is_ref(bk, base) && !place_deep(r->place)) {
            int mut = 0;
            wrap_is_ref(ty, &mut);
            copy_loans(bk, base, dest, mut, r->line);
            if (mut)
                ls_kill_borrower(&bk->cur, base);
            return;
        }
        if (ty && !type_is_copy(bk->cg, ty))
            moving = 1;
        access_place(bk, r->place, 0, moving, r->line);
        return;
    }
    case MR_REF:
        borrow_place(bk, r->place, 0, dest, r->line);
        return;
    case MR_REFMUT:
        borrow_place(bk, r->place, 1, dest, r->line);
        return;
    case MR_EXPR:
        walk_expr(bk, r->expr, dest);
        return;
    }
}

static void check_return(BK *bk, MirRvalue *r, int line) {
    int i, mut = 0;
    const char *base;
    if (!r)
        return;
    if (r->kind == MR_REF || r->kind == MR_REFMUT) {
        base = place_base(r->place);
        if (base && !local_is_ref(bk, base) && !name_is_param(bk, base))
            cg_error(line, "cannot return borrow of local '%s'", base);
        return;
    }
    if (r->kind == MR_USE) {
        base = place_base(r->place);
        if (!base || !local_is_ref(bk, base) || place_deep(r->place))
            return;
        for (i = 0; i < bk->cur.n; i++) {
            Loan *l = &bk->cur.items[i];
            if (!l->borrower || strcmp(l->borrower, base))
                continue;
            if (!name_is_param(bk, l->root) && !local_is_ref(bk, l->root))
                cg_error(line, "cannot return borrow of local '%s'", l->root);
        }
        return;
    }
    if (r->kind == MR_EXPR && r->expr &&
        wrap_is_ref(r->expr->inf_ty, &mut)) {
        walk_rvalue(bk, r, NULL);
        if (r->expr->kind == EX_UNARY &&
            (!strcmp(r->expr->as.unary.op, "&") ||
             !strcmp(r->expr->as.unary.op, "&mut"))) {
            MirPlace *p = ast_place(bk->cg, r->expr->as.unary.operand);
            base = place_base(p);
            if (base && !local_is_ref(bk, base) && !name_is_param(bk, base))
                cg_error(line, "cannot return borrow of local '%s'", base);
        }
    }
}

static void walk_stmt(BK *bk, MirStmt *s) {
    const char *dest = NULL;
    if (s->dest && s->dest->kind == MP_LOCAL)
        dest = s->dest->as.local;
    if (s->dest) {
        const char *base = place_base(s->dest);
        if (base && dest && !strcmp(base, dest) && !place_deep(s->dest) &&
            local_is_ref(bk, dest))
            ls_kill_borrower(&bk->cur, dest);
        else
            access_place(bk, s->dest, 1, 0, s->line);
    }
    walk_rvalue(bk, s->src, dest);
}

static void walk_term(BK *bk, MirTerm *t) {
    if (t->cond)
        access_place(bk, t->cond, 0, 0, t->line);
    if (t->kind == MT_RETURN)
        check_return(bk, t->ret, t->line);
    else
        walk_rvalue(bk, t->ret, NULL);
    walk_rvalue(bk, t->iter, NULL);
}

static void seed_params(BK *bk) {
    int i;
    for (i = 0; i < bk->fn->nlocals; i++) {
        int mut = 0;
        if (!bk->is_param[i])
            continue;
        if (!wrap_is_ref(bk->fn->locals[i].ty, &mut))
            continue;
        ls_add(&bk->cur, bk->fn->locals[i].name, bk->fn->locals[i].name, mut,
               0);
    }
}

static void run_block(BK *bk, int bbi, LoanSet *out) {
    MirBlock *bb = &bk->fn->blocks[bbi];
    int i;
    for (i = 0; i < bb->nstmts; i++) {
        walk_stmt(bk, bb->stmts[i]);
        kill_dead(bk, bbi, i);
    }
    walk_term(bk, &bb->term);
    ls_kill_temps(&bk->cur);
    ls_clone_into(out, &bk->cur);
}

static FuncSig *mir_sig(CG *cg, MirFn *fn) {
    char *left, *right;
    if (split_dotted(fn->name, &left, &right)) {
        StructDef *sd = struct_find_in_pkg(cg, fn->pkg, left);
        if (sd)
            return method_find(cg, sd, right);
    }
    return sig_find_in(cg, fn->pkg, fn->name);
}

static void check_fn(CG *cg, MirFn *fn) {
    BK bk;
    FuncSig *sig;
    LoanSet *outs;
    int nbb = fn->nblocks;
    int *predn, **preds;
    int b, i, s, ns, changed, succs[8];
    memset(&bk, 0, sizeof(bk));
    bk.cg = cg;
    bk.fn = fn;
    bk.nlocs = fn->nlocals;
    bk.use = (int *)xmalloc((size_t)(bk.nlocs ? bk.nlocs : 1) * sizeof(int));
    bk.def = (int *)xmalloc((size_t)(bk.nlocs ? bk.nlocs : 1) * sizeof(int));
    bk.is_param = (int *)xmalloc((size_t)(bk.nlocs ? bk.nlocs : 1) * sizeof(int));
    memset(bk.is_param, 0, (size_t)(bk.nlocs ? bk.nlocs : 1) * sizeof(int));
    sig = mir_sig(cg, fn);
    if (sig) {
        int n = sig->nparams;
        if (n > fn->nlocals)
            n = fn->nlocals;
        for (i = 0; i < n; i++)
            bk.is_param[i] = 1;
    }
    var_scope_reset(cg);
    var_scope_push(cg);
    cg->cur_pkg = fn->pkg;
    for (i = 0; i < fn->nlocals; i++)
        if (fn->locals[i].ty)
            var_push(cg, fn->locals[i].name, fn->locals[i].ty);
    compute_liveness(&bk);
    outs = (LoanSet *)xmalloc((size_t)nbb * sizeof(LoanSet));
    memset(outs, 0, (size_t)nbb * sizeof(LoanSet));
    predn = (int *)xmalloc((size_t)nbb * sizeof(int));
    preds = (int **)xmalloc((size_t)nbb * sizeof(int *));
    memset(predn, 0, (size_t)nbb * sizeof(int));
    for (b = 0; b < nbb; b++)
        preds[b] = (int *)xmalloc((size_t)nbb * sizeof(int));
    for (b = 0; b < nbb; b++) {
        ns = term_succs(&fn->blocks[b].term, succs, 8);
        for (s = 0; s < ns; s++)
            preds[succs[s]][predn[succs[s]]++] = b;
    }
    changed = 1;
    while (changed) {
        changed = 0;
        for (b = 0; b < nbb; b++) {
            LoanSet next;
            memset(&next, 0, sizeof(next));
            memset(&bk.cur, 0, sizeof(bk.cur));
            if (b == 0)
                seed_params(&bk);
            for (i = 0; i < predn[b]; i++)
                ls_union(&bk.cur, &outs[preds[b][i]]);
            run_block(&bk, b, &next);
            if (!ls_eq(&outs[b], &next)) {
                ls_clone_into(&outs[b], &next);
                changed = 1;
            }
        }
    }
}

void compute_borrowck(CG *cg, Package *pkgs, int npkgs, int main_index) {
    int i;
    (void)pkgs;
    (void)npkgs;
    (void)main_index;
    for (i = 0; i < cg->mirs.count; i++)
        check_fn(cg, cg->mirs.items[i]);
}
