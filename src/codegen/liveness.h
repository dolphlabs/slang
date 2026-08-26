#ifndef SLANG_LIVENESS_H
#define SLANG_LIVENESS_H

#include "../loader.h"
#include <stdio.h>

/* Tier 10: computes exact per-call-site live-GC-pointer-local sets for
 * every function across pkgs (see todo.md's Tier 10 section for the
 * design). Pure analysis -- never calls codegen_program, never emits
 * C. Results are attached to the AST itself (Expr.live_set,
 * Stmt.backedge_live_set) as a side effect; this entry point then
 * prints them in source order to `out` for inspection/testing. Exits
 * with the same diagnostics codegen_program would on a malformed
 * program (it type-checks via the same infer_type/infer_call/
 * infer_ident_name functions codegen itself uses). */
void dump_liveness(Package *pkgs, int npkgs, int main_index, FILE *out);

#endif /* SLANG_LIVENESS_H */
