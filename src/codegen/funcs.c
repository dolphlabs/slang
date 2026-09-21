/* One place that knows which function bodies a pass has to visit.
 *
 * Every whole-program pass (mir, escape, move, liveness, prototype and body
 * generation) used to carry its own copy of the same two loops -- each
 * package's plain functions, then the methods of its impl blocks -- and the
 * copies had to be kept in step by hand. A pass that missed a kind of body
 * failed silently: most switches over the tree have a `default:` that ignores
 * what it does not know, and a body no pass visits is unrooted by the
 * collector or unchecked by the borrow and move passes, not a compile error.
 * That is the same class of bug as a child a pass never visits (an
 * expression's callee, a method's receiver).
 *
 * User-defined generics add a third kind of body -- an instance of a generic
 * function or method -- and it must be reached by exactly the passes that
 * reach the others. Routing them all through this cursor makes that a
 * one-line change here instead of a hunt through six files.
 *
 * Order matters and is preserved exactly: the generated C follows it. For
 * each package, its plain functions in declaration order, then the methods of
 * its impl blocks in declaration order; then every generic instance, in the
 * order the instances were made.
 *
 * The cursor owns cg->tenv while it iterates: each yield installs that
 * body's type parameters (none, for a declared function), and the final
 * call clears them. A pass therefore cannot forget to set it. */

#include "internal.h"

static int func_cursor_next_inst(CG *cg, FuncCursor *c);

void func_cursor_init(FuncCursor *c) {
    memset(c, 0, sizeof(*c));
}

/* Advance to the next function. `with_extern` also yields `extern fn`
 * declarations (which have no body): prototype emission needs them, the
 * passes that walk bodies do not. Returns 0 when there are no more. */
int func_cursor_next(CG *cg, Package *pkgs, int npkgs, FuncCursor *c,
                     int with_extern) {
    for (;;) {
        if (c->i_pkg >= npkgs)
            return func_cursor_next_inst(cg, c);
        Package *p = &pkgs[c->i_pkg];
        if (c->phase == 0) { /* plain functions */
            if (c->i_fn < p->prog->nfuncs) {
                FuncDecl *f = p->prog->funcs[c->i_fn++];
                if (f->is_extern && !with_extern)
                    continue;
                c->pkg = p;
                c->fn = f;
                c->sig = sig_of_decl(cg, f);
                c->impl_struct = NULL;
                c->tenv = NULL;
                cg->tenv = NULL;
                generic_note_body(NULL, 0);
                return 1;
            }
            c->phase = 1;
            c->i_stmt = 0;
            c->i_impl = 0;
            continue;
        }
        /* methods of impl blocks */
        Block *body = p->prog->main_body;
        while (c->i_stmt < body->count) {
            Stmt *s = body->stmts[c->i_stmt];
            /* `impl Box[T]` declares no bodies: its methods are templates,
             * with no signature and no meaning until a T is known. The
             * instances they produce are yielded at the end instead. */
            if (s->kind != ST_IMPL || s->as.impl.ntparams) {
                c->i_stmt++;
                c->i_impl = 0;
                continue;
            }
            if (c->i_impl < s->as.impl.nfuncs) {
                FuncDecl *f = s->as.impl.funcs[c->i_impl++];
                c->pkg = p;
                c->fn = f;
                c->sig = sig_of_decl(cg, f);
                c->impl_struct = s->as.impl.struct_name;
                c->tenv = NULL;
                cg->tenv = NULL;
                generic_note_body(NULL, 0);
                return 1;
            }
            c->i_stmt++;
            c->i_impl = 0;
        }
        c->i_pkg++;
        c->phase = 0;
        c->i_fn = 0;
    }
}

/* Instances of generic methods, after every declared function.
 *
 * The count is re-read on each call, so an instance discovered WHILE this
 * loop runs (generating one instance's body can name another) is yielded
 * by the same loop. That is what drives the set to a fixpoint during the
 * dry run, with no separate queue. */
static int func_cursor_next_inst(CG *cg, FuncCursor *c) {
    if (c->i_inst >= cg->finsts.count) {
        cg->tenv = NULL;
        generic_note_body(NULL, 0);
        return 0;
    }
    FuncInst *fi = cg->finsts.items[c->i_inst++];
    c->pkg = fi->pkg;
    c->fn = fi->fn;
    c->sig = fi->sig;
    c->impl_struct = fi->recv;
    c->tenv = &fi->env;
    cg->tenv = c->tenv;
    generic_note_body(fi->note, fi->line);
    return 1;
}

/* The state every body walk starts from: inside a function, in the
 * declaring package, returning the signature's type. The caller resets
 * cg->in_function to 0 when the body is done, as it always has. */
void func_cursor_enter(CG *cg, const FuncCursor *c) {
    cg->in_function = 1;
    cg->cur_pkg = c->pkg->name;
    cg->cur_ret = c->sig->ret_slang;
    cg->tenv = (TypeEnv *)c->tenv;
}
