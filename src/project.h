#ifndef SLANG_PROJECT_H
#define SLANG_PROJECT_H

typedef struct {
    char *name;
    char *git;
    char *tag;
    /* Sub-directory of the repository that holds the package, or NULL
     * for the repository root. A library that also ships examples, docs
     * and its own tests keeps them out of a consumer's build by putting
     * the package itself in one directory and pinning `dir <that>`. */
    char *dir;
    char *hash;
} SlPkgPin;

typedef struct {
    char *root;
    char *name;
    char *version;
    SlPkgPin *pins;
    int npins;
    char **excludes;
    int nexcludes;
} SlProject;

char *project_find_root(const char *start_dir);
SlProject *project_load(const char *root);
SlPkgPin *project_find_pin(SlProject *p, const char *name);
char *project_cache_dir(const SlPkgPin *pin);
/* Where the package's .sl files are: the cache directory, plus the
 * pin's `dir` when it has one. */
char *project_pkg_dir(const SlPkgPin *pin);
char *project_tree_hash(const char *dir);
/* When `import "ipath"` written in `from_dir`, inside a fetched package,
 * names a directory that package's own manifest excludes: that exclude,
 * with the package's name in *pkg_name. NULL otherwise. */
const char *project_excluded_import(const char *from_dir, const char *ipath,
                                    const char **pkg_name);
void project_get(SlProject *p);
char *project_cache_subdir(const char *sub);
int project_is_dir(const char *path);

#endif
