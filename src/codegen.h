#ifndef SLANG_CODEGEN_H
#define SLANG_CODEGEN_H

#include "ast.h"
#include "common.h"
#include "loader.h"

/* Translates a set of packages into a complete, self-contained C
 * source program appended to `out`. pkgs[main_index] is the entry
 * package whose top-level statements become main(). *out_want_tls is
 * set to 1 if the program uses any net.tls_* function (so the driver
 * knows to link OpenSSL), 0 otherwise. *out_want_crypto is set to 1
 * if the program imports crypto (needs -lcrypto), 0 otherwise.
 * *out_want_sql is set to 1 if the program imports sql (needs
 * -lsqlite3), 0 otherwise. Exits with a diagnostic on semantic
 * errors. */
void codegen_program(Package *pkgs, int npkgs, int main_index,
                     StrBuf *out, int *out_want_tls, int *out_want_crypto,
                     int *out_want_sql);

#endif /* SLANG_CODEGEN_H */