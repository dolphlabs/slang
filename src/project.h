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
} SlProject;

char *project_find_root(const char *start_dir);
SlProject *project_load(const char *root);
SlPkgPin *project_find_pin(SlProject *p, const char *name);
char *project_cache_dir(const SlPkgPin *pin);
/* Where the package's .sl files are: the cache directory, plus the
 * pin's `dir` when it has one. */
char *project_pkg_dir(const SlPkgPin *pin);
char *project_tree_hash(const char *dir);
void project_get(SlProject *p);
int project_is_dir(const char *path);

#endif
