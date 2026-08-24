#ifndef SLANG_LOADER_H
#define SLANG_LOADER_H

#include "ast.h"

/* A package: every .sl file in one directory, merged into a single
 * Program (one shared namespace, Go/Odin style). */
typedef struct {
    char *name;    /* package name: base name of its directory */
    char *path;    /* canonical (realpath) directory of the package */
    Program *prog; /* merged AST of all files in the directory */
} Package;

typedef struct {
    Package *items;
    int count;
    int cap;
} PkgList;

/* Loads the package containing main_file plus every transitively
 * imported package. Import paths resolve relative to the importing
 * file's directory. Returns the index of the main package in out.
 * Exits with a diagnostic on missing packages or import cycles. */
int load_packages(const char *main_file, PkgList *out);

#endif /* SLANG_LOADER_H */