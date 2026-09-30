#ifndef SLANG_DIAG_H
#define SLANG_DIAG_H

#include <stdarg.h>

/* Compiler diagnostics: one place that decides how an error looks, for the
 * lexer, the parser, the loader and codegen alike.
 *
 * Text:  path/to/file.sl:12: error: <message>   (the form gcc, clang, Go and
 *        rustc share, which editors and models already know how to read)
 * JSON:  with --json, one object per line on stderr:
 *        {"file":"...","line":12,"severity":"error","message":"..."}
 *
 * The path is relative to the working directory when the file is under it. */

/* The source file being lexed, parsed or checked; NULL when none applies.
 * Stages set it as they move between files and functions. */
extern const char *diag_file;

/* Set by --json. */
extern int diag_json;

void diag_report(const char *file, int line, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
void diag_vreport(const char *file, int line, const char *fmt, va_list ap,
                  const char *suffix);

/* How many errors have been reported so far. */
int diag_count(void);

#endif /* SLANG_DIAG_H */
