#ifndef SLANG_LOADER_H
#define SLANG_LOADER_H

#include "ast.h"

/* A package: every .sl file in one directory, merged into a single
 * Program (one shared namespace, Go/Odin style). */
typedef struct {
    char *name;    /* package name: pkg_name_of_path(its directory), or
                    * the slang.project pin name */
    char *path;    /* canonical (realpath) directory of the package */
    Program *prog; /* merged AST of all files in the directory */
    int native;    /* 1 = built-in package implemented by codegen
                    * ("time", "net"); prog is empty */
} Package;

typedef struct {
    Package *items;
    int count;
    int cap;
} PkgList;

/* Loads the package containing main_file plus every transitively
 * imported package. Import paths resolve to a local directory, then a
 * native package, then stdlib/<path>, then a slang.project pin.
 * Returns the index of the main package in out. Exits with a
 * diagnostic on missing packages or import cycles. */
int load_packages(const char *main_file, PkgList *out);

/* Test mode, for `slangc test`. When set to a package directory
 * (realpath), that one package is loaded with its *_test.sl files, its
 * test_* functions become callable from the generated runner, and -- if
 * the package is a program rather than a library -- its top-level
 * statements are dropped, since tests run instead of the program.
 * *_test.sl files are otherwise never loaded, in any package. */
void loader_set_test_target(const char *real_dir);

/* The package name for a directory or import path: its base name, made
 * an identifier -- every byte outside [A-Za-z0-9_] becomes '_', and a
 * leading digit gets a "p_" prefix. The loader names a package with it
 * and codegen resolves an import's target with it, so the two always
 * agree. Canonical type names are "<pkg>.<Name>" and are split at the
 * first '.', so a directory like "app.v2" used verbatim produced
 * "sl_st_app_v2.Point" -- invalid C. The rule matches codegen's
 * sanitize_pkg, so every C symbol an already-valid name produced is
 * unchanged. */
char *pkg_name_of_path(const char *path);

/* Collects every 'link "name"' directive across all loaded packages,
 * deduplicated in first-occurrence order. *out_count is set to the
 * number of names returned (0 if none). */
char **collect_link_libs(PkgList *pkgs, int *out_count);

#endif /* SLANG_LOADER_H */