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
 * *out_want_compress is set to 1 if the program imports compress
 * (needs -lz). *out_want_sql is set to 1 if the program imports sql (needs
 * -lsqlite3), 0 otherwise. Exits with a diagnostic on semantic
 * errors. */
void codegen_program(Package *pkgs, int npkgs, int main_index,
                     StrBuf *out, int *out_want_tls, int *out_want_crypto,
                     int *out_want_sql, int *out_want_compress);

/* Frame guards. A slang function whose C frame turns out to be large is
 * emitted as a noinline body behind a thin wrapper that reserves stack
 * before the body's frame is allocated (see sl_rt_stack_reserve). The driver
 * measures frames with the C compiler, so it cannot know them until a first
 * compile: it sets the guards, regenerates, and compiles again.
 *
 * `symbols` are C function names as codegen_function_symbols reports them;
 * `frames` the measured frame size in bytes of each. */
void codegen_set_frame_guards(const char *const *symbols, const int *frames,
                              int n);

/* The C names of every function the last codegen_program emitted -- the set
 * the driver may guard, and the way it tells a slang function's frame
 * diagnostic from a runtime function's. */
const char *const *codegen_function_symbols(int *n);

#endif /* SLANG_CODEGEN_H */