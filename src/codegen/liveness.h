#ifndef SLANG_LIVENESS_H
#define SLANG_LIVENESS_H

#include "../loader.h"
#include <stdio.h>

typedef struct CG CG; /* opaque here -- full definition in codegen/internal.h */

/* Tier 10: computes exact per-call-site live-GC-pointer-local sets for
 * every function across pkgs (see todo.md's Tier 10 section for the
 * design). Pure analysis -- never emits C. Results are attached to
 * the AST itself (Expr.live_set, Stmt.backedge_live_set) as a side
 * effect. Takes an already-set-up CG* (post-collect_decls) rather
 * than building its own, so the real codegen path can call it once,
 * before gen_whole_program reads Expr.live_set, using the very same
 * CG. Exits with the same diagnostics codegen_program would on a
 * malformed program (it type-checks via the same infer_type/
 * infer_call/infer_ident_name functions codegen itself uses). */
void compute_liveness(CG *cg, Package *pkgs, int npkgs, int main_index);

/* --dump-liveness CLI mode: builds its own throwaway CG, calls
 * compute_liveness, then prints every node a live_set/
 * backedge_live_set got attached to, in source order, to `out`. Never
 * calls codegen_program, never emits C. */
void dump_liveness(Package *pkgs, int npkgs, int main_index, FILE *out);

/* Read-only accessors onto a LiveSet* (as stored, opaquely, in
 * Expr.live_set/Stmt.backedge_live_set) -- LiveSet's actual layout
 * stays private to liveness.c. `ls == NULL` behaves like an empty
 * set, so a call site is never required to null-check before using
 * these. Used by gen_call (expr.c) to build each call-site safepoint
 * bracket's root list straight from the liveness pass's own data. */
int live_set_nnamed(void *ls);
const char *live_set_named(void *ls, int i);
int live_set_npending(void *ls);
Expr *live_set_pending(void *ls, int i);

#endif /* SLANG_LIVENESS_H */
