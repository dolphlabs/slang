/* Tier 10's liveness analysis pass -- see todo.md's Tier 10 section
 * and the approved plan for the full design rationale. Pure analysis:
 * never emits C, never calls codegen_program. Mirrors gen_stmt/
 * gen_stmts/gen_block/gen_expr's own recursion shape (this file's
 * live_stmt/live_stmts/live_block/live_expr) so every control-flow
 * case can be diffed directly against its codegen counterpart.
 *
 * Backward liveness: live_in(n) = uses(n) u (live_out(n) \ defs(n)).
 * Every GC-pointer-typed local gets tracked by LiveVar identity (not
 * name -- shadowing across nested scopes must never conflate two
 * different declarations that happen to share a name). Every
 * GC-pointer-typed subexpression that isn't a bare identifier (a
 * nested call's result, a field read, ...) gets tracked by Expr*
 * identity in the same LiveSet as a "pending" entry, so its value is
 * correctly kept live across an intervening safepoint evaluated after
 * it but before its own consumer (see the design note on
 * foo(bar(), baz()) in the plan). */

#include "internal.h"
#include "liveness.h"

#include <string.h>

/* ------------------------------------------------------------------ */
/* LiveVar / LiveSet                                                    */
/* ------------------------------------------------------------------ */

typedef struct {
    char *name;
    const char *slang_type;
} LiveVar;

typedef struct {
    LiveVar **named;
    int nnamed, cap_named;
    Expr **pending;
    int npending, cap_pending;
} LiveSet;

static LiveSet *ls_new(void) {
    LiveSet *s = (LiveSet *)xmalloc(sizeof(LiveSet));
    memset(s, 0, sizeof(LiveSet));
    return s;
}

static LiveSet *ls_clone(LiveSet *s) {
    LiveSet *c = ls_new();
    for (int i = 0; i < s->nnamed; i++) {
        if (c->nnamed == c->cap_named) {
            c->cap_named = c->cap_named ? c->cap_named * 2 : 4;
            c->named = (LiveVar **)xrealloc(c->named,
                                            c->cap_named * sizeof(LiveVar *));
        }
        c->named[c->nnamed++] = s->named[i];
    }
    for (int i = 0; i < s->npending; i++) {
        if (c->npending == c->cap_pending) {
            c->cap_pending = c->cap_pending ? c->cap_pending * 2 : 4;
            c->pending = (Expr **)xrealloc(c->pending,
                                           c->cap_pending * sizeof(Expr *));
        }
        c->pending[c->npending++] = s->pending[i];
    }
    return c;
}

static int ls_has_named(LiveSet *s, LiveVar *v) {
    for (int i = 0; i < s->nnamed; i++)
        if (s->named[i] == v) return 1;
    return 0;
}

static void ls_add_named(LiveSet *s, LiveVar *v) {
    if (!v || ls_has_named(s, v)) return;
    if (s->nnamed == s->cap_named) {
        s->cap_named = s->cap_named ? s->cap_named * 2 : 4;
        s->named =
            (LiveVar **)xrealloc(s->named, s->cap_named * sizeof(LiveVar *));
    }
    s->named[s->nnamed++] = v;
}

static void ls_remove_named(LiveSet *s, LiveVar *v) {
    if (!v) return;
    for (int i = 0; i < s->nnamed; i++) {
        if (s->named[i] == v) {
            s->named[i] = s->named[s->nnamed - 1];
            s->nnamed--;
            return;
        }
    }
}

static int ls_has_pending(LiveSet *s, Expr *e) {
    for (int i = 0; i < s->npending; i++)
        if (s->pending[i] == e) return 1;
    return 0;
}

static void ls_add_pending(LiveSet *s, Expr *e) {
    if (ls_has_pending(s, e)) return;
    if (s->npending == s->cap_pending) {
        s->cap_pending = s->cap_pending ? s->cap_pending * 2 : 4;
        s->pending =
            (Expr **)xrealloc(s->pending, s->cap_pending * sizeof(Expr *));
    }
    s->pending[s->npending++] = e;
}

static void ls_remove_pending(LiveSet *s, Expr *e) {
    for (int i = 0; i < s->npending; i++) {
        if (s->pending[i] == e) {
            s->pending[i] = s->pending[s->npending - 1];
            s->npending--;
            return;
        }
    }
}

/* Union src's named entries into dst, in place. Pending entries are
 * deliberately never unioned across branches (Q3's pending tracking
 * is a strictly local, single-statement-expression-tree mechanism --
 * a pending value from one branch of an if/else can never be relevant
 * on the other, since it always gets resolved to empty by the time a
 * whole statement's live_in is returned). */
static void ls_union_named_into(LiveSet *dst, LiveSet *src) {
    for (int i = 0; i < src->nnamed; i++) ls_add_named(dst, src->named[i]);
}

static int ls_named_equal(LiveSet *a, LiveSet *b) {
    if (a->nnamed != b->nnamed) return 0;
    for (int i = 0; i < a->nnamed; i++)
        if (!ls_has_named(b, a->named[i])) return 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Lexical scope: name -> LiveVar*, one frame per Block, except a
 * guard-let's binding, which is pushed into the CURRENT frame (see
 * live_stmts) to mirror gen_stmts's single shared C brace exactly. */
/* ------------------------------------------------------------------ */

/* Name resolution is delegated ENTIRELY to the real compiler's own
 * var_push/var_find against cg->vars, rather than a separately
 * maintained scope structure -- a hard-won correction, not a
 * simplification for its own sake: cg->vars is flat and reset only
 * once per function (core.c:377-395, confirmed never truncated per
 * block anywhere in gen_stmt, including ST_FOR/ST_FOR_IN/guard-let,
 * none of which ever pop it either), and that IS this language's
 * actual, real scoping semantics -- a name declared inside a nested
 * block genuinely stays resolvable for the rest of the enclosing
 * function in real compiled programs. A separate nested-scope model
 * looks more "properly lexical" but would silently diverge from what
 * real programs actually resolve to, and worse, this pass calls the
 * REAL infer_type/infer_call (Risk 5/the plan's whole design), which
 * internally resolve identifiers via this exact cg->vars table -- a
 * separate scope structure that never touches cg->vars means those
 * calls can't see this pass's own declarations at all.
 *
 * A parallel, index-aligned array maps each cg->vars slot to this
 * pass's own LiveVar identity (only for GC-pointer-typed slots; NULL
 * for scalars). Looked up fresh by INDEX every time rather than
 * caching VarSym* pointers across a var_push call, since var_push can
 * xrealloc cg->vars.items and invalidate any pointer taken before it. */

static LiveVar **slot_map = NULL;
static int slot_map_cap = 0;

static void slot_map_ensure(int n) {
    if (n <= slot_map_cap) return;
    int newcap = slot_map_cap ? slot_map_cap * 2 : 16;
    while (newcap < n) newcap *= 2;
    slot_map = (LiveVar **)xrealloc(slot_map, sizeof(LiveVar *) * (size_t)newcap);
    for (int i = slot_map_cap; i < newcap; i++) slot_map[i] = NULL;
    slot_map_cap = newcap;
}

/* Pushes `name` into cg->vars (mirroring exactly what the real
 * codegen's own var_push call for this construct does, so cg->vars
 * ends up in the same state real compilation would leave it in) and,
 * if its type is GC-pointer-classified, registers a LiveVar for
 * liveness tracking. Returns that LiveVar, or NULL for a scalar (e.g.
 * ST_FOR's always-int induction variable) -- never tracked at all. */
static LiveVar *declare_var(CG *cg, const char *name, const char *slang_type) {
    var_push(cg, name, slang_type);
    int idx = cg->vars.count - 1;
    slot_map_ensure(cg->vars.count);
    if (!type_is_gc_ptr(cg, slang_type)) {
        slot_map[idx] = NULL;
        return NULL;
    }
    LiveVar *v = (LiveVar *)xmalloc(sizeof(LiveVar));
    v->name = xstrdup(name);
    v->slang_type = slang_type;
    slot_map[idx] = v;
    return v;
}

/* Mirrors gen_ident_name/infer_ident_name's exact resolution order
 * (Risk 5 in the plan): a plain local wins first (via the real
 * var_find); otherwise a dotted name is either a package-qualified
 * global (no local use at all, so NULL) or field access through a
 * local (recurse on the left part until it bottoms out at a local or
 * a global). Never re-validates -- this pass only runs on programs
 * that already passed real type-checking via the same infer_type/
 * infer_call this file calls. */
static LiveVar *resolve_local_use(CG *cg, const char *name) {
    VarSym *v = var_find(cg, name);
    if (v) {
        int idx = (int)(v - cg->vars.items);
        slot_map_ensure(cg->vars.count);
        return slot_map[idx];
    }
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_try(cg, left);
        if (pkg) return NULL; /* package-qualified global */
        return resolve_local_use(cg, left);
    }
    return NULL; /* package-level global */
}

/* ------------------------------------------------------------------ */
/* Declared-type helpers mirroring gen_stmt's own special cases        */
/* ------------------------------------------------------------------ */

/* Mirrors ST_LET's exact type-resolution order in gen_stmt (stmt.c),
 * including the empty-list/empty-map special case that skips
 * infer_type on the initializer entirely. */
static const char *let_decl_type(CG *cg, Stmt *s) {
    const char *ann = s->as.let.type_ann;
    if (ann) ann = canon_type(cg, ann, s->line);
    Expr *init = s->as.let.init;
    if (init->kind == EX_LIST && init->as.list.nelems == 0) return ann;
    if (init->kind == EX_MAPLIT && init->as.maplit.npairs == 0) return ann;
    const char *saved = expect_push(cg, ann);
    const char *it = infer_type(cg, init);
    cg->expect = saved;
    return ann ? ann : it;
}

/* guard let x = expr else { ... }: x's type is opt[T]/result[T,E]'s
 * inner T, mirroring gen_stmts's own is_opt/is_result branch. */
static const char *guard_let_inner_type(CG *cg, Stmt *s) {
    const char *et = infer_type(cg, s->as.guard_let.expr);
    if (is_opt(et)) return opt_inner(et);
    if (is_result(et)) {
        char *tv, *tev;
        result_te(et, &tv, &tev);
        return tv;
    }
    cg_error(s->line, "guard let requires an opt or result value (got %s)", et);
    return NULL; /* unreachable */
}

/* ------------------------------------------------------------------ */
/* Termination (Risk 2): a conservative "does this block definitely
 * exit without falling through" check, used only to decide whether a
 * guard-let else block's live_out needs to (defensively) merge
 * forward into the tail, since the compiler itself never enforces the
 * "else must exit" contract (stmt.c:542's comment is not code). Never
 * wrong to under-approximate here (returning 0 when it does in fact
 * always terminate just means a safe, wider live set gets computed;
 * returning 1 when it doesn't would be the only real hazard, so this
 * stays deliberately conservative in the "does it terminate" answer,
 * requiring an unconditional return or exit() on every path). */
static int expr_is_exit_call(Expr *e) {
    return e->kind == EX_CALL && !strcmp(e->as.call.name, "exit");
}

static int block_always_terminates(Block *b) {
    if (b->count == 0) return 0;
    Stmt *last = b->stmts[b->count - 1];
    if (last->kind == ST_RETURN) return 1;
    if (last->kind == ST_EXPR && expr_is_exit_call(last->as.expr_stmt.expr))
        return 1;
    if (last->kind == ST_IF && last->as.if_stmt.else_blk)
        return block_always_terminates(last->as.if_stmt.then_blk) &&
               block_always_terminates(last->as.if_stmt.else_blk);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Expression walker                                                    */
/* ------------------------------------------------------------------ */

static LiveSet *live_expr(CG *cg, Expr *e, LiveSet *live_out);

/* A TRULY bare identifier (no dot) is just a name lookup -- its
 * liveness is fully carried by the named-slot mechanism, so it never
 * needs pending treatment. A DOTTED identifier (e.g. 'p.child') is
 * semantically a field read through 'p' (gen_ident_name compiles it
 * to '(p)->child', re-read fresh at the point it's used, per
 * expr.c:8-31/24-25) -- its own result is exactly the kind of
 * transient, not-yet-consumed value the pending mechanism exists for,
 * so it must NOT be excluded the way a bare identifier is. */
static int is_bare_ident(Expr *e) {
    return e->kind == EX_IDENT && !strchr(e->as.ident.name, '.');
}

/* Resolves the expected parameter type for each of a call's
 * arguments, mirroring gen_call's own signature-resolution dispatch
 * (expr.c) just enough to bracket cg->expect around each argument the
 * same way real codegen does -- 'none'/'some(..)'/'ok(..)'/'err(..)'
 * as an argument can only self-infer via cg->expect, the same class
 * of bug EX_STRUCTLIT's fix above addresses. Returns NULL (no
 * per-argument expectation) for ctor calls (some/ok/err -- handled by
 * gen_ctor's own distinct single-argument expect-pushing, never
 * routed through param_slang), builtins, and native-package/json
 * calls, where replicating the full resolution isn't needed for this
 * pass's own correctness (nothing in tests/ passes none/some/ok/err
 * to one of those, unlike the struct-literal case this was written
 * for -- if that changes, extend this the same way). */
static const char **call_arg_expects(CG *cg, Expr *e) {
    const char *name = e->as.call.name;
    if (!strcmp(name, "some") || !strcmp(name, "ok") || !strcmp(name, "err"))
        return NULL;
    if (is_builtin_name(name)) return NULL;

    FuncSig *sig = NULL;
    char *left, *right;
    if (split_dotted(name, &left, &right)) {
        const char *pkg = import_try(cg, left);
        if (pkg) {
            if (is_native_pkg(cg, pkg)) return NULL;
            sig = sig_find_in(cg, pkg, right);
        } else {
            const char *recv_t = infer_ident_name(cg, left, e->line);
            StructDef *sd = struct_find_canon(cg, recv_t);
            if (!sd) return NULL;
            sig = method_find(cg, sd, right);
        }
    } else {
        sig = sig_find_in(cg, cg->cur_pkg, name);
    }
    if (!sig) return NULL;

    int argi = sig->method_of ? 1 : 0; /* method's self isn't in e->as.call.args */
    int nargs = e->as.call.nargs;
    if (nargs == 0) return NULL;
    const char **expects = (const char **)xmalloc(sizeof(char *) * (size_t)nargs);
    for (int i = 0; i < nargs; i++)
        expects[i] = sig->param_slang[argi + i];
    return expects;
}

/* Processes `children[0..n)` in reverse (right-to-left) of the
 * left-to-right source/parse order every multi-child expression kind
 * in this language uses (Q3/Risk 1: this pass assumes that order
 * consistently; it does not need to match real C evaluation order to
 * be correct, only to be self-consistent -- see Risk 1 in the plan
 * for why the eventual codegen step, unlike this one, does care).
 * Any child whose own type is GC-pointer-classified and which is not
 * a bare identifier becomes a "pending" entry while its later
 * (rightward) siblings are processed, exactly the foo(bar(), baz())
 * mechanism from the plan's Q3.
 *
 * `expects` (nullable, or individual entries nullable) mirrors real
 * codegen's own expect_push/cg->expect bracketing around each field/
 * argument/element (gen_structlit, gen_call, ...): 'none'/'some(..)'/
 * 'ok(..)'/'err(..)' as a struct field value or call argument can
 * only self-infer its type from cg->expect, exactly the same
 * mechanism ctor_infer already relies on elsewhere -- both the
 * classification infer_type call below AND the recursive live_expr
 * call must run with the SAME expectation active real codegen would
 * have, or infer_type throws "cannot infer the type of ..." on
 * perfectly valid programs (confirmed: tests/struct_field_expect
 * failed exactly this way before this bracketing was added). */
static LiveSet *process_children_reverse(CG *cg, Expr **children, int n,
                                         LiveSet *live_out,
                                         const char **expects) {
    if (n == 0) return live_out;

    /* Two genuinely opposite directions have to compose here, which is
     * the actual substance of Q3's foo(bar(), baz()) design and easy
     * to get backward (an earlier bug in this exact function did):
     * the "outer/later" context (live_out, and named-variable uses
     * threaded between siblings) flows backward, right to left,
     * exactly like every other backward-liveness equation in this
     * file. But sibling PENDING markers flow the opposite way: an
     * EARLIER-evaluated (lower-index) sibling's not-yet-consumed
     * result must be visible at a LATER (higher-index) sibling's own
     * safepoint (baz must protect bar's already-computed result),
     * never the reverse (bar's own safepoint, evaluated first, must
     * never see baz's marker -- baz hasn't executed yet) and never a
     * child's own marker at its own safepoint (its value doesn't
     * exist until it returns).
     *
     * Phase 1 (forward, left-to-right): for each child i, snapshot
     * the accumulated pending set from every STRICTLY EARLIER sibling
     * as `before[i]`. */
    int *needs_pending = (int *)xmalloc(sizeof(int) * (size_t)n);
    LiveSet **before = (LiveSet **)xmalloc(sizeof(LiveSet *) * (size_t)n);
    LiveSet *acc = ls_new();
    for (int i = 0; i < n; i++) {
        const char *exp_i = expects ? expects[i] : NULL;
        const char *saved = expect_push(cg, exp_i);
        needs_pending[i] = !is_bare_ident(children[i]) &&
                           type_is_gc_ptr(cg, infer_type(cg, children[i]));
        cg->expect = saved;
        before[i] = acc;
        if (needs_pending[i]) {
            LiveSet *acc2 = ls_clone(acc);
            ls_add_pending(acc2, children[i]);
            acc = acc2;
        }
    }

    /* Phase 2 (backward, right-to-left): thread live_out/named-uses
     * normally, folding in before[i]'s earlier-sibling markers at
     * each child, and explicitly stripping child i's own marker both
     * before processing it (so it never sees itself) and after (so
     * it never leaks to whatever's evaluated even earlier than it). */
    LiveSet *cur = live_out;
    for (int i = n - 1; i >= 0; i--) {
        LiveSet *child_out = ls_clone(cur);
        for (int k = 0; k < before[i]->npending; k++)
            ls_add_pending(child_out, before[i]->pending[k]);
        if (needs_pending[i]) ls_remove_pending(child_out, children[i]);
        const char *exp_i = expects ? expects[i] : NULL;
        const char *saved = expect_push(cg, exp_i);
        cur = live_expr(cg, children[i], child_out);
        cg->expect = saved;
        if (needs_pending[i]) {
            cur = ls_clone(cur);
            ls_remove_pending(cur, children[i]);
        }
    }
    return cur;
}

static LiveSet *live_expr(CG *cg, Expr *e, LiveSet *live_out) {
    switch (e->kind) {
    case EX_INT:
    case EX_FLOAT:
    case EX_STRING:
    case EX_BYTES:
    case EX_BOOL:
        return live_out;

    case EX_IDENT: {
        if (!strcmp(e->as.ident.name, "nullptr"))
            return live_out; /* ((void *)0) -- never allocates */
        if (!strcmp(e->as.ident.name, "none")) {
            /* unlike nullptr, 'none' allocates a fresh sl_opt_* via
             * GC_malloc every occurrence (expr.c's EX_IDENT case) --
             * a real safepoint despite being an EX_IDENT, not one of
             * the 4 kinds ast.h's live_set comment names; recorded
             * here as the one deliberate exception. */
            e->live_set = ls_clone(live_out);
            return live_out;
        }
        LiveVar *v = resolve_local_use(cg, e->as.ident.name);
        if (!v) return live_out;
        LiveSet *r = ls_clone(live_out);
        ls_add_named(r, v);
        return r;
    }

    case EX_UNARY:
        return live_expr(cg, e->as.unary.operand, live_out);
    case EX_CAST:
        return live_expr(cg, e->as.cast.operand, live_out);

    case EX_BINARY: {
        Expr *kids[2] = {e->as.binary.lhs, e->as.binary.rhs};
        return process_children_reverse(cg, kids, 2, live_out, NULL);
    }

    case EX_INDEX: {
        Expr *kids[2] = {e->as.index.base, e->as.index.index};
        return process_children_reverse(cg, kids, 2, live_out, NULL);
    }

    case EX_SLICE: {
        Expr *kids[3];
        int n = 0;
        kids[n++] = e->as.slice.base;
        if (e->as.slice.start) kids[n++] = e->as.slice.start;
        if (e->as.slice.end) kids[n++] = e->as.slice.end;
        return process_children_reverse(cg, kids, n, live_out, NULL);
    }

    case EX_FIELD:
        return live_expr(cg, e->as.field.base, live_out);

    case EX_LIST: {
        /* gen_list/gen_stmt's own ann_list handling never pushes
         * cg->expect per element (confirmed by direct reading) -- so
         * neither does this, matching real behavior exactly rather
         * than "fixing" a per-element expectation the real compiler
         * doesn't actually support either. */
        LiveSet *cur =
            process_children_reverse(cg, e->as.list.elems,
                                     e->as.list.nelems, live_out, NULL);
        e->live_set = ls_clone(cur);
        return cur;
    }

    case EX_MAPLIT: {
        /* interleave key/value pairs in reverse pair order, value
         * before key within each pair (matching gen_maplit's own
         * per-pair k-then-v generation order, reversed). Same note as
         * EX_LIST: gen_maplit never pushes cg->expect per pair. */
        int npairs = e->as.maplit.npairs;
        Expr **kids = (Expr **)xmalloc(sizeof(Expr *) * (size_t)npairs * 2);
        for (int i = 0; i < npairs; i++) {
            kids[i * 2] = e->as.maplit.keys[i];
            kids[i * 2 + 1] = e->as.maplit.vals[i];
        }
        LiveSet *cur =
            process_children_reverse(cg, kids, npairs * 2, live_out, NULL);
        e->live_set = ls_clone(cur);
        return cur;
    }

    case EX_STRUCTLIT: {
        /* mirrors gen_structlit exactly (expr.c): each field value is
         * inferred with cg->expect pushed to THAT field's own
         * declared type -- confirmed necessary the hard way
         * (tests/struct_field_expect failed without it: 'err("boom")'
         * as a field value can only self-infer via cg->expect). */
        const char *canon = infer_type(cg, e);
        StructDef *sd = struct_find_canon(cg, canon);
        int nf = e->as.structlit.nfields;
        const char **field_expects = (const char **)xmalloc(sizeof(char *) * (size_t)nf);
        for (int j = 0; j < nf; j++) {
            int fi = -1;
            for (int i = 0; i < sd->nfields; i++)
                if (!strcmp(sd->fields[i], e->as.structlit.fields[j])) fi = i;
            field_expects[j] = fi >= 0 ? sd->ftypes[fi] : NULL;
        }
        LiveSet *cur =
            process_children_reverse(cg, e->as.structlit.vals, nf, live_out,
                                     field_expects);
        e->live_set = ls_clone(cur);
        return cur;
    }

    case EX_CALL: {
        /* Record the safepoint's live set BEFORE processing args: this
         * is exactly live_out relative to the call's own subtree --
         * everything needed after this call returns, which is what
         * must be scannable on the CALLER's frame while the callee
         * (and anything it transitively allocates) runs. Arguments
         * being evaluated are the callee's concern from the moment
         * they're passed, not tracked here. */
        e->live_set = ls_clone(live_out);

        const char **expects = call_arg_expects(cg, e);
        LiveSet *cur = process_children_reverse(
            cg, e->as.call.args, e->as.call.nargs, live_out, expects);

        /* Method-call receiver: 'p.method(args)' resolves 'left' (=p)
         * as a plain local use, exactly mirroring gen_call's own
         * split_dotted+import_try dispatch (a dotted call name whose
         * left part is NOT a package alias is a method call on that
         * local). Contributes only a named-use addition (receivers in
         * this language are always simple identifiers, never a
         * sub-expression with its own safepoints), so it's safe to
         * fold in without ordering sensitivity. */
        char *left, *right;
        if (split_dotted(e->as.call.name, &left, &right)) {
            const char *pkg = import_try(cg, left);
            if (!pkg) {
                LiveVar *recv = resolve_local_use(cg, left);
                if (recv) ls_add_named(cur, recv);
            }
        }
        return cur;
    }
    }
    return live_out; /* unreachable */
}

/* ------------------------------------------------------------------ */
/* Statement walker                                                     */
/* ------------------------------------------------------------------ */

static LiveSet *live_stmts(CG *cg, Stmt **stmts, int count, LiveSet *live_out);

static LiveSet *live_block(CG *cg, Block *b, LiveSet *live_out) {
    return live_stmts(cg, b->stmts, b->count, live_out);
}

/* Solves the loop back-edge fixpoint described in the plan (Q1/Q2):
 * compute live_in(body) assuming live_out(body) = live_out(loop) (the
 * loop runs zero more times), then recompute with the previous
 * result's named set folded in as the new live_out(body), until it
 * stabilizes. Bounded iteration count as a defensive
 * internal-compiler-error trip wire, not a hand-tuned assumption --
 * see the plan's Q1 for why this is expected to converge in ~2 passes
 * for any single loop level in this language's control-flow surface. */
static LiveSet *solve_loop_fixpoint(CG *cg, Block *body, LiveSet *live_out,
                                    LiveSet **out_backedge) {
    /* break/continue: cur_break_live_set is exactly this loop's own
     * live_out (whatever's needed once the whole loop finishes,
     * regardless of which iteration breaks) -- constant across every
     * fixpoint pass below, so set once. cur_continue_live_set is
     * exactly this iteration's own cur_out (whatever's needed going
     * INTO the next iteration) -- updated every pass, right before
     * that pass's own live_block walk, so a continue textually
     * anywhere in the body resolves against the CURRENT fixpoint
     * iteration's own answer, not a stale one. Saved/restored around
     * the whole solve so an enclosing loop's own targets (if this
     * loop is nested) are exactly as it left them once this one's
     * done -- a nested loop's own recursive call to this same
     * function does the identical save/restore around its own
     * processing, so this composes correctly automatically. */
    void *saved_break = cg->cur_break_live_set;
    void *saved_continue = cg->cur_continue_live_set;
    cg->cur_break_live_set = live_out;
    LiveSet *cur_out = ls_clone(live_out);
    LiveSet *live_in = NULL;
    for (int iter = 0; iter < 10; iter++) {
        cg->cur_continue_live_set = cur_out;
        live_in = live_block(cg, body, cur_out);
        if (iter > 0 && ls_named_equal(live_in, cur_out)) {
            *out_backedge = live_in;
            cg->cur_break_live_set = saved_break;
            cg->cur_continue_live_set = saved_continue;
            return live_in;
        }
        LiveSet *next_out = ls_clone(live_out);
        ls_union_named_into(next_out, live_in);
        cur_out = next_out;
    }
    cg_error(0,
             "internal: liveness fixpoint failed to converge (a loop's "
             "live-set kept changing after 10 iterations)");
    return NULL; /* unreachable */
}

/* Returns 1 if `name` is a real, currently-declared local (regardless
 * of whether it's GC-tracked), setting *out to its LiveVar (NULL for
 * a scalar local, e.g. an int); returns 0 if var_find fails entirely
 * -- not a local at all, e.g. a dotted field-through-local or a
 * package global (see resolve_local_use for that resolution). Used by
 * ST_ASSIGN to distinguish a real def (a bare identifier naming an
 * actual local) from a mere use (anything else). */
static int is_real_local(CG *cg, const char *name, LiveVar **out) {
    VarSym *v = var_find(cg, name);
    if (!v) return 0;
    int idx = (int)(v - cg->vars.items);
    slot_map_ensure(cg->vars.count);
    *out = slot_map[idx];
    return 1;
}

static LiveSet *live_stmt(CG *cg, Stmt *s, LiveSet *live_out) {
    switch (s->kind) {
    case ST_LET:
        /* handled entirely in live_stmts, which needs to declare the
         * new binding before recursing into the tail but resolve the
         * initializer against the OLD scope -- see live_stmts */
        cg_error(s->line, "internal: ST_LET reached live_stmt directly");
        return NULL;

    case ST_ASSIGN: {
        Expr *tgt = s->as.assign.target;
        if (tgt->kind == EX_IDENT) {
            LiveVar *v;
            if (is_real_local(cg, tgt->as.ident.name, &v)) {
                /* real def: v's old value is dead from here backward,
                 * exactly Spike 1a/1b's motivating case */
                LiveSet *out2 = ls_clone(live_out);
                ls_remove_named(out2, v);
                return live_expr(cg, s->as.assign.value, out2);
            }
            /* dotted 'p.x = v' folded into one EX_IDENT by the parser,
             * or a package global -- either way a use, never a def */
            LiveVar *base = resolve_local_use(cg, tgt->as.ident.name);
            LiveSet *out2 = live_expr(cg, s->as.assign.value, live_out);
            if (base) {
                out2 = ls_clone(out2);
                ls_add_named(out2, base);
            }
            return out2;
        }
        if (tgt->kind == EX_FIELD) {
            LiveSet *cur = live_expr(cg, s->as.assign.value, live_out);
            return live_expr(cg, tgt->as.field.base, cur);
        }
        /* EX_INDEX: xs[i]=v, m[k]=v, b[i]=v */
        LiveSet *cur = live_expr(cg, s->as.assign.value, live_out);
        cur = live_expr(cg, tgt->as.index.index, cur);
        return live_expr(cg, tgt->as.index.base, cur);
    }

    case ST_IF: {
        LiveSet *live_in_then =
            live_block(cg, s->as.if_stmt.then_blk, live_out);
        LiveSet *live_in_else =
            s->as.if_stmt.else_blk
                ? live_block(cg, s->as.if_stmt.else_blk, live_out)
                : ls_clone(live_out);
        LiveSet *joined = ls_clone(live_in_then);
        ls_union_named_into(joined, live_in_else);
        return live_expr(cg, s->as.if_stmt.cond, joined);
    }

    case ST_WHILE: {
        LiveSet *backedge = NULL;
        LiveSet *live_in_body = solve_loop_fixpoint(
            cg, s->as.while_stmt.body, live_out, &backedge);
        s->backedge_live_set = backedge;
        LiveSet *joined = ls_clone(live_in_body);
        ls_union_named_into(joined, live_out); /* the "run zero times" exit path */
        return live_expr(cg, s->as.while_stmt.cond, joined);
    }

    case ST_FOR: {
        /* the induction variable is always int (stmt.c:281): never
         * GC-tracked. Pushed here and never popped, matching real
         * gen_stmt exactly (var_push with no corresponding pop) --
         * this language's actual scoping is function-flat, not
         * block-nested (confirmed: no ST_* case ever truncates
         * cg->vars mid-function). KNOWN LIMITATION carried from that
         * same fact: this declaration happens only once this case
         * runs, which in this pass's backward walk is AFTER the tail
         * (the rest of the enclosing block) has already been
         * processed -- a program that references a for-loop's
         * induction variable from code textually after the loop ends
         * (legal in this language, since it's never popped) will hit
         * a loud "undefined variable" cg_error from this pass rather
         * than resolving it, instead of silently computing something
         * wrong. Not fixed here; would need a forward declaration
         * pre-pass to do properly. */
        declare_var(cg, s->as.for_stmt.name, "int");
        LiveSet *backedge = NULL;
        LiveSet *live_in_body = solve_loop_fixpoint(
            cg, s->as.for_stmt.body, live_out, &backedge);
        s->backedge_live_set = backedge;
        LiveSet *joined = ls_clone(live_in_body);
        ls_union_named_into(joined, live_out);
        LiveSet *cur = live_expr(cg, s->as.for_stmt.end, joined);
        return live_expr(cg, s->as.for_stmt.start, cur);
    }

    case ST_FOR_IN: {
        const char *it = infer_type(cg, s->as.for_in.iter);
        /* same "pushed, never popped" caveat as ST_FOR above */
        LiveVar *bound1 = NULL, *bound2 = NULL;
        if (is_arr(it)) {
            bound1 = declare_var(cg, s->as.for_in.name, arr_elem(it));
        } else if (is_bytes(it)) {
            declare_var(cg, s->as.for_in.name, "int");
        } else if (is_map(it)) {
            char *k, *v;
            map_kv(it, &k, &v);
            bound1 = declare_var(cg, s->as.for_in.name, k);
            bound2 = declare_var(cg, s->as.for_in.name2, v);
        }
        /* the bound variable(s) are redefined fresh every iteration
         * (var_push happens once per generated C loop, but the C
         * variable itself is reassigned each pass) -- never carried
         * across the back-edge as a value needing preservation, and
         * never live BEFORE this loop starts either. Unlike
         * ST_ASSIGN's real-def case, nothing else in this walk treats
         * a for-in binding as a "definition" that kills prior
         * liveness -- declare_var only makes the name resolvable, it
         * doesn't touch any live set -- so bound1/bound2 have to be
         * explicitly stripped from both the backedge set and this
         * statement's own returned live_in below, or they leak
         * backward into every earlier program point whenever the
         * loop body references them (which is virtually always: why
         * else bind them). Caught the hard way: an array-of-str or
         * map for-in loop as the last statement in a function, whose
         * bound variable(s) then outlive the walk of everything
         * before it (function-flat, declared-and-never-popped
         * scoping), made an EARLIER call site's own root list
         * reference a C identifier that doesn't exist yet at that
         * point in the generated C -- a hard compile error, not a
         * silent one. The ITERABLE (uses(iter) below) is what's
         * genuinely live across every iteration. */
        LiveSet *backedge = NULL;
        LiveSet *live_in_body = solve_loop_fixpoint(
            cg, s->as.for_in.body, live_out, &backedge);
        ls_remove_named(backedge, bound1);
        ls_remove_named(backedge, bound2);
        s->backedge_live_set = backedge;
        LiveSet *joined = ls_clone(live_in_body);
        ls_remove_named(joined, bound1);
        ls_remove_named(joined, bound2);
        ls_union_named_into(joined, live_out);
        return live_expr(cg, s->as.for_in.iter, joined);
    }

    case ST_RETURN:
        /* kills everything after it in the same block: an
         * unconditional exit's own live_in is exactly uses(value) */
        if (!s->as.ret.value) return ls_new();
        return live_expr(cg, s->as.ret.value, ls_new());

    case ST_BREAK:
        /* Same "ignore the live_out I was handed, substitute a
         * different context" shape as ST_RETURN above -- break jumps
         * straight to whatever's live after the WHOLE loop, not
         * whatever's live after wherever it's textually sitting.
         * cur_break_live_set is set by solve_loop_fixpoint (this
         * loop's own live_out, constant across its fixpoint); NULL
         * means there's no enclosing loop at all -- caught here since
         * this pass can run before codegen's own equivalent check in
         * some paths (--dump-liveness never reaches gen_stmt). */
        if (!cg->cur_break_live_set)
            cg_error(s->line, "'break' outside a loop");
        return ls_clone((LiveSet *)cg->cur_break_live_set);

    case ST_CONTINUE:
        /* Same shape, but "whatever's live going into the next
         * iteration" -- solve_loop_fixpoint's own per-iteration
         * cur_out, updated every fixpoint pass. */
        if (!cg->cur_continue_live_set)
            cg_error(s->line, "'continue' outside a loop");
        return ls_clone((LiveSet *)cg->cur_continue_live_set);

    case ST_EXPR:
        return live_expr(cg, s->as.expr_stmt.expr, live_out);

    case ST_GUARD_LET:
        cg_error(s->line, "internal: ST_GUARD_LET reached live_stmt directly");
        return NULL;

    case ST_SPAWN: {
        Expr *call = s->as.spawn.call;
        int nargs = call->as.call.nargs;
        /* the args-struct GC_malloc (stmt.c:479) only happens when
         * nargs > 0 (stmt.c:476-477 assigns NULL directly otherwise);
         * it has no corresponding EX_CALL/EX_STRUCTLIT node of its
         * own, so its safepoint is recorded directly on the spawn
         * statement's call expression -- reusing the same live_set
         * field every other safepoint kind uses, since this EX_CALL
         * node is never routed through the ordinary gen_call path
         * anyway (ST_SPAWN has its own dedicated codegen) */
        /* spawn's target is always a plain/package-qualified function
         * (stmt.c rejects builtins/native/methods), exactly the case
         * call_arg_expects already resolves via sig_find_in. */
        LiveSet *cur =
            process_children_reverse(cg, call->as.call.args, nargs,
                                     live_out, call_arg_expects(cg, call));
        if (nargs > 0) call->live_set = ls_clone(cur);
        return cur;
    }

    case ST_STRUCT:
    case ST_IMPL:
        return live_out;
    }
    return live_out; /* unreachable */
}

/* Mirrors gen_stmts's exact recursion shape (stmt.c:538-583): a
 * guard-let's binding is visible to every statement after it in the
 * SAME block, and the else block runs only on the path that never
 * reaches the tail at all. cg->vars is mutated to match the exact
 * state real codegen would have at each point: pushed before
 * recursing into whatever needs to see it (the tail), then popped
 * again (cg->vars.count--) before resolving whatever must NOT see it
 * (the initializer/guard expression/else block), matching
 * gen_stmt/gen_stmts's own var_push placement exactly (stmt.c:100,
 * 575). */
static LiveSet *live_stmts(CG *cg, Stmt **stmts, int count, LiveSet *live_out) {
    if (count == 0) return live_out;
    Stmt *s = stmts[0];

    if (s->kind == ST_GUARD_LET) {
        const char *inner = guard_let_inner_type(cg, s);
        LiveVar *gv = declare_var(cg, s->as.guard_let.name, inner);
        LiveSet *live_in_tail = live_stmts(cg, stmts + 1, count - 1, live_out);
        LiveSet *tail_without_gv = ls_clone(live_in_tail);
        ls_remove_named(tail_without_gv, gv); /* doesn't exist before this stmt */
        cg->vars.count--; /* the else block and expr resolve against
                            * the scope BEFORE this guard-let
                            * (stmt.c:566/572-574 run before the real
                            * var_push at 575) */

        int else_falls_through = !block_always_terminates(s->as.guard_let.body);
        LiveSet *live_out_else =
            else_falls_through ? ls_clone(tail_without_gv) : ls_new();
        LiveSet *live_in_else = live_block(cg, s->as.guard_let.body, live_out_else);

        LiveSet *joined = ls_clone(tail_without_gv);
        ls_union_named_into(joined, live_in_else);
        return live_expr(cg, s->as.guard_let.expr, joined);
    }

    if (s->kind == ST_LET) {
        const char *t = let_decl_type(cg, s);
        LiveVar *lv = declare_var(cg, s->as.let.name, t);
        LiveSet *live_out_of_s = live_stmts(cg, stmts + 1, count - 1, live_out);
        LiveSet *out2 = ls_clone(live_out_of_s);
        ls_remove_named(out2, lv); /* dead before this point regardless */
        cg->vars.count--; /* the initializer resolves against the
                            * scope BEFORE this let (stmt.c:100's
                            * var_push happens after gen_expr on
                            * s->as.let.init, never before) */
        return live_expr(cg, s->as.let.init, out2);
    }

    LiveSet *live_out_of_s = live_stmts(cg, stmts + 1, count - 1, live_out);
    return live_stmt(cg, s, live_out_of_s);
}

/* ------------------------------------------------------------------ */
/* Per-function driver                                                  */
/* ------------------------------------------------------------------ */

static void live_function_body(CG *cg, Block *body, char **params,
                               const char **param_types, int nparams) {
    for (int i = 0; i < nparams; i++)
        declare_var(cg, params[i], param_types[i]);
    live_block(cg, body, ls_new());
}

/* ------------------------------------------------------------------ */
/* Print pass: walks the same shape again, in forward source order,
 * printing every node a live_set/backedge_live_set was attached to.
 * Kept fully separate from computation (which discovers safepoints in
 * reverse order) so the dump reads top-to-bottom like the source. */
/* ------------------------------------------------------------------ */

static void print_live_set(FILE *out, LiveSet *s) {
    fputs("{", out);
    for (int i = 0; i < s->nnamed; i++) {
        if (i) fputs(", ", out);
        fputs(s->named[i]->name, out);
    }
    if (s->npending > 0) {
        if (s->nnamed) fputs("; ", out);
        fputs("pending=", out);
        for (int i = 0; i < s->npending; i++) {
            if (i) fputs(",", out);
            fprintf(out, "@L%d", s->pending[i]->line);
        }
    }
    fputs("}", out);
}

static void print_expr(FILE *out, Expr *e);
static void print_stmts(FILE *out, Stmt **stmts, int count);

static void print_block(FILE *out, Block *b) {
    print_stmts(out, b->stmts, b->count);
}

static void print_expr(FILE *out, Expr *e) {
    switch (e->kind) {
    case EX_IDENT:
        if (e->live_set) {
            fprintf(out, "L%d: NONE live=", e->line);
            print_live_set(out, (LiveSet *)e->live_set);
            fputc('\n', out);
        }
        return;
    case EX_BINARY:
        print_expr(out, e->as.binary.lhs);
        print_expr(out, e->as.binary.rhs);
        return;
    case EX_UNARY:
        print_expr(out, e->as.unary.operand);
        return;
    case EX_CAST:
        print_expr(out, e->as.cast.operand);
        return;
    case EX_INDEX:
        print_expr(out, e->as.index.base);
        print_expr(out, e->as.index.index);
        return;
    case EX_SLICE:
        print_expr(out, e->as.slice.base);
        if (e->as.slice.start) print_expr(out, e->as.slice.start);
        if (e->as.slice.end) print_expr(out, e->as.slice.end);
        return;
    case EX_FIELD:
        print_expr(out, e->as.field.base);
        return;
    case EX_LIST:
        for (int i = 0; i < e->as.list.nelems; i++)
            print_expr(out, e->as.list.elems[i]);
        if (e->live_set) {
            fprintf(out, "L%d: LIST live=", e->line);
            print_live_set(out, (LiveSet *)e->live_set);
            fputc('\n', out);
        }
        return;
    case EX_MAPLIT:
        for (int i = 0; i < e->as.maplit.npairs; i++) {
            print_expr(out, e->as.maplit.keys[i]);
            print_expr(out, e->as.maplit.vals[i]);
        }
        if (e->live_set) {
            fprintf(out, "L%d: MAPLIT live=", e->line);
            print_live_set(out, (LiveSet *)e->live_set);
            fputc('\n', out);
        }
        return;
    case EX_STRUCTLIT:
        for (int i = 0; i < e->as.structlit.nfields; i++)
            print_expr(out, e->as.structlit.vals[i]);
        if (e->live_set) {
            fprintf(out, "L%d: STRUCTLIT live=", e->line);
            print_live_set(out, (LiveSet *)e->live_set);
            fputc('\n', out);
        }
        return;
    case EX_CALL:
        for (int i = 0; i < e->as.call.nargs; i++)
            print_expr(out, e->as.call.args[i]);
        if (e->live_set) {
            fprintf(out, "L%d: CALL %s live=", e->line, e->as.call.name);
            print_live_set(out, (LiveSet *)e->live_set);
            fputc('\n', out);
        }
        return;
    default:
        return;
    }
}

static void print_stmts(FILE *out, Stmt **stmts, int count) {
    for (int i = 0; i < count; i++) {
        Stmt *s = stmts[i];
        switch (s->kind) {
        case ST_LET:
            print_expr(out, s->as.let.init);
            break;
        case ST_ASSIGN:
            print_expr(out, s->as.assign.target);
            print_expr(out, s->as.assign.value);
            break;
        case ST_IF:
            print_expr(out, s->as.if_stmt.cond);
            print_block(out, s->as.if_stmt.then_blk);
            if (s->as.if_stmt.else_blk) print_block(out, s->as.if_stmt.else_blk);
            break;
        case ST_WHILE:
            print_expr(out, s->as.while_stmt.cond);
            print_block(out, s->as.while_stmt.body);
            if (s->backedge_live_set) {
                fprintf(out, "L%d: WHILE-BACKEDGE live=", s->line);
                print_live_set(out, (LiveSet *)s->backedge_live_set);
                fputc('\n', out);
            }
            break;
        case ST_FOR:
            print_expr(out, s->as.for_stmt.start);
            print_expr(out, s->as.for_stmt.end);
            print_block(out, s->as.for_stmt.body);
            if (s->backedge_live_set) {
                fprintf(out, "L%d: FOR-BACKEDGE live=", s->line);
                print_live_set(out, (LiveSet *)s->backedge_live_set);
                fputc('\n', out);
            }
            break;
        case ST_FOR_IN:
            print_expr(out, s->as.for_in.iter);
            print_block(out, s->as.for_in.body);
            if (s->backedge_live_set) {
                fprintf(out, "L%d: FOR_IN-BACKEDGE live=", s->line);
                print_live_set(out, (LiveSet *)s->backedge_live_set);
                fputc('\n', out);
            }
            break;
        case ST_RETURN:
            if (s->as.ret.value) print_expr(out, s->as.ret.value);
            break;
        case ST_BREAK:
            fprintf(out, "L%d: BREAK\n", s->line);
            break;
        case ST_CONTINUE:
            fprintf(out, "L%d: CONTINUE\n", s->line);
            break;
        case ST_EXPR:
            print_expr(out, s->as.expr_stmt.expr);
            break;
        case ST_GUARD_LET:
            print_expr(out, s->as.guard_let.expr);
            print_block(out, s->as.guard_let.body);
            break;
        case ST_SPAWN:
            /* print the ARGUMENTS' own sub-safepoints (if any), but
             * not via print_expr on the call node itself -- it shares
             * live_set with the ordinary EX_CALL case (see live_stmt's
             * ST_SPAWN), which would print a second, redundant "CALL"
             * line labeled with the same set as SPAWN-ALLOC below */
            for (int a = 0; a < s->as.spawn.call->as.call.nargs; a++)
                print_expr(out, s->as.spawn.call->as.call.args[a]);
            if (s->as.spawn.call->live_set) {
                fprintf(out, "L%d: SPAWN-ALLOC live=", s->line);
                print_live_set(out, (LiveSet *)s->as.spawn.call->live_set);
                fputc('\n', out);
            }
            break;
        case ST_STRUCT:
        case ST_IMPL:
            break;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Public entry point                                                   */
/* ------------------------------------------------------------------ */

void compute_liveness(CG *cg, Package *pkgs, int npkgs, int main_index) {
    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (int j = 0; j < p->prog->nfuncs; j++) {
            FuncDecl *f = p->prog->funcs[j];
            if (f->is_extern) continue;
            cg->vars.count = 0;
            cg->in_function = 1;
            cg->cur_pkg = p->name;
            FuncSig *sig = sig_find_in(cg, p->name, f->name);
            cg->cur_ret = sig->ret_slang;
            for (int k = 0; k < f->nparams; k++)
                var_push(cg, f->params[k], sig->param_slang[k]);
            live_function_body(cg, f->body, f->params, sig->param_slang,
                               f->nparams);
            cg->in_function = 0;
        }
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL) continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++) {
                FuncDecl *f = s->as.impl.funcs[q];
                cg->vars.count = 0;
                cg->in_function = 1;
                cg->cur_pkg = p->name;
                FuncSig *sig = method_find(
                    cg, struct_find_in_pkg(cg, p->name, s->as.impl.struct_name),
                    f->name);
                cg->cur_ret = sig->ret_slang;
                for (int k = 0; k < f->nparams; k++)
                    var_push(cg, f->params[k], sig->param_slang[k]);
                live_function_body(cg, f->body, f->params, sig->param_slang,
                                   f->nparams);
                cg->in_function = 0;
            }
        }
    }

    /* the main package's top-level statements, walked as their own
     * pseudo-function (Risk 7): no params, void return, fresh scope */
    cg->vars.count = 0;
    cg->in_function = 1;
    cg->cur_ret = NULL;
    cg->cur_pkg = pkgs[main_index].name;
    Block *main_body = pkgs[main_index].prog->main_body;
    live_function_body(cg, main_body, NULL, NULL, 0);
}

void dump_liveness(Package *pkgs, int npkgs, int main_index, FILE *out) {
    CG cg;
    memset(&cg, 0, sizeof(CG));

    /* record which packages are compiler-provided natives (time/net/
     * json/proc) -- mirrors codegen_program's own setup exactly
     * (program.c:578-585); without this, is_native_pkg/native_check
     * can't resolve any time/net/proc call, since collect_decls
     * alone only handles user-defined structs/functions/imports. */
    for (int i = 0; i < npkgs; i++) {
        if (!pkgs[i].native) continue;
        cg.nat_pkgs = (char **)xrealloc(
            cg.nat_pkgs, (size_t)(cg.nnat + 1) * sizeof(char *));
        cg.nat_pkgs[cg.nnat++] = pkgs[i].name;
    }

    collect_decls(&cg, pkgs, npkgs);
    compute_liveness(&cg, pkgs, npkgs, main_index);

    /* second walk: printing only, reusing the same source-order
     * traversal shape, now over an AST whose live_set/
     * backedge_live_set fields are already fully populated. */
    for (int i = 0; i < npkgs; i++) {
        Package *p = &pkgs[i];
        for (int j = 0; j < p->prog->nfuncs; j++) {
            FuncDecl *f = p->prog->funcs[j];
            if (f->is_extern) continue;
            fprintf(out, "== fn %s.%s ==\n", p->name, f->name);
            print_stmts(out, f->body->stmts, f->body->count);
        }
        Block *body = p->prog->main_body;
        for (int j = 0; j < body->count; j++) {
            Stmt *s = body->stmts[j];
            if (s->kind != ST_IMPL) continue;
            for (int q = 0; q < s->as.impl.nfuncs; q++) {
                FuncDecl *f = s->as.impl.funcs[q];
                fprintf(out, "== method %s.%s.%s ==\n", p->name,
                        s->as.impl.struct_name, f->name);
                print_stmts(out, f->body->stmts, f->body->count);
            }
        }
    }
    Block *main_body = pkgs[main_index].prog->main_body;
    fputs("== main ==\n", out);
    print_stmts(out, main_body->stmts, main_body->count);
}

int live_set_nnamed(void *ls) {
    return ls ? ((LiveSet *)ls)->nnamed : 0;
}

const char *live_set_named(void *ls, int i) {
    return ((LiveSet *)ls)->named[i]->name;
}

int live_set_npending(void *ls) {
    return ls ? ((LiveSet *)ls)->npending : 0;
}

Expr *live_set_pending(void *ls, int i) {
    return ((LiveSet *)ls)->pending[i];
}
