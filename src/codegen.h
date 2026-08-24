#ifndef SLANG_CODEGEN_H
#define SLANG_CODEGEN_H

#include "ast.h"
#include "common.h"
#include "loader.h"

/* Translates a set of packages into a complete, self-contained C
 * source program appended to `out`. pkgs[main_index] is the entry
 * package whose top-level statements become main(). Exits with a
 * diagnostic on semantic errors. */
void codegen_program(Package *pkgs, int npkgs, int main_index,
                     StrBuf *out);

#endif /* SLANG_CODEGEN_H */