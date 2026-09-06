#ifndef SLANG_RTPATH_H
#define SLANG_RTPATH_H

extern const char *sl_compiler_argv0;

char *slang_runtime_file(const char *name);

/* Realpath of stdlib/<ipath>, or NULL if that directory is missing.
 * Local imports and native packages are tried before this. */
char *slang_stdlib_pkg(const char *ipath);

#endif
