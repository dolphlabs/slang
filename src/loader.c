#include "common.h"
#include "diag.h"
#include "lexer.h"
#include "parser.h"
#include "loader.h"

#include "codegen/pkg_net/pkg_net.h"
#include "codegen/pkg_time/pkg_time.h"
#include "codegen/pkg_json/pkg_json.h"
#include "codegen/pkg_proc/pkg_proc.h"
#include "codegen/pkg_fs/pkg_fs.h"
#include "codegen/pkg_log/pkg_log.h"
#include "codegen/pkg_crypto/pkg_crypto.h"
#include "codegen/pkg_sql/pkg_sql.h"
#include "codegen/pkg_regex/pkg_regex.h"
#include "codegen/pkg_os/pkg_os.h"
#include "codegen/pkg_io/pkg_io.h"
#include "codegen/pkg_strings/pkg_strings.h"
#include "codegen/pkg_encoding/pkg_encoding.h"
#include "codegen/pkg_compress/pkg_compress.h"
#include "rtpath.h"
#include "project.h"

#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>

static void load_error(const char *fmt, ...) {
    va_list ap;
    fputs("slang: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc(10, stderr);
    exit(1);
}

/* Base name of a path: "a/b/c" -> "c" */
static char *path_base(const char *path) {
    const char *slash = strrchr(path, '/');
    return xstrdup(slash ? slash + 1 : path);
}

char *pkg_name_of_path(const char *path) {
    char *base = path_base(path);
    for (char *p = base; *p; p++) {
        if (!(isalnum((unsigned char)*p) || *p == '_'))
            *p = '_';
    }
    if (isdigit((unsigned char)base[0]))
        return xasprintf("p_%s", base);
    return base;
}

/* Directory portion of a path: "a/b/c.sl" -> "a/b", "x.sl" -> "." */
static char *path_dir(const char *path) {
    const char *slash = strrchr(path, '/');
    if (!slash)
        return xstrdup(".");
    size_t n = (size_t)(slash - path);
    if (n == 0)
        return xstrdup("/");
    char *d = (char *)xmalloc(n + 1);
    memcpy(d, path, n);
    d[n] = '\0';
    return d;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int is_ident_like(const char *s) {
    if (!s[0])
        return 0;
    if (!(isalpha((unsigned char)s[0]) || s[0] == '_'))
        return 0;
    for (const char *p = s + 1; *p; p++) {
        if (!(isalnum((unsigned char)*p) || *p == '_'))
            return 0;
    }
    return 1;
}

typedef struct {
    PkgList *pkgs;
    SlProject *project;
    char **stack;
    int nstack;
    int scap;
} Loader;

static Program *new_program(void) {
    Program *prog = (Program *)xmalloc(sizeof(Program));
    memset(prog, 0, sizeof(Program));
    prog->main_body = (Block *)xmalloc(sizeof(Block));
    prog->main_body->stmts = NULL;
    prog->main_body->count = 0;
    prog->main_body->cap = 0;
    return prog;
}

static int pkg_index_by_path(Loader *ld, const char *real) {
    for (int i = 0; i < ld->pkgs->count; i++) {
        if (!strcmp(ld->pkgs->items[i].path, real))
            return i;
    }
    return -1;
}

static int on_stack(Loader *ld, const char *real) {
    for (int i = 0; i < ld->nstack; i++) {
        if (!strcmp(ld->stack[i], real))
            return 1;
    }
    return 0;
}

static void stack_push(Loader *ld, const char *real) {
    if (ld->nstack == ld->scap) {
        ld->scap = ld->scap ? ld->scap * 2 : 8;
        ld->stack =
            (char **)xrealloc(ld->stack, ld->scap * sizeof(char *));
    }
    ld->stack[ld->nstack++] = xstrdup(real);
}

static void stack_pop(Loader *ld) { ld->nstack--; }

/* Merge one parsed file into the package's combined program. */
static void merge_program(Package *pkg, Program *src, const char *fname) {
    Program *dst = pkg->prog;

    for (int i = 0; i < src->nfuncs; i++) {
        FuncDecl *f = src->funcs[i];
        for (int j = 0; j < dst->nfuncs; j++) {
            if (!strcmp(dst->funcs[j]->name, f->name))
                load_error("duplicate function '%s' in package '%s' "
                           "(redefined in %s)",
                           f->name, pkg->name, fname);
        }
        if (dst->nfuncs == dst->fcap) {
            dst->fcap = dst->fcap ? dst->fcap * 2 : 8;
            dst->funcs = (FuncDecl **)xrealloc(
                dst->funcs, dst->fcap * sizeof(FuncDecl *));
        }
        dst->funcs[dst->nfuncs++] = f;
    }

    for (int i = 0; i < src->nimports; i++) {
        char *ipath = src->import_paths[i];
        char *alias = src->import_aliases && src->import_aliases[i]
                          ? src->import_aliases[i]
                          : path_base(ipath);
        if (!is_ident_like(alias))
            load_error("import '%s': binding name '%s' is not a valid "
                       "identifier",
                       ipath, alias);
        int dup = 0;
        for (int j = 0; j < dst->nimports; j++) {
            if (!strcmp(dst->import_paths[j], ipath)) {
                dup = 1;
                break;
            }
            char *other = dst->import_aliases && dst->import_aliases[j]
                              ? dst->import_aliases[j]
                              : path_base(dst->import_paths[j]);
            if (!strcmp(other, alias))
                load_error("duplicate import binding '%s' in package '%s'",
                           alias, pkg->name);
        }
        if (dup)
            continue;
        if (dst->nimports == dst->icap) {
            int old = dst->icap;
            dst->icap = dst->icap ? dst->icap * 2 : 8;
            dst->import_paths = (char **)xrealloc(
                dst->import_paths, dst->icap * sizeof(char *));
            dst->import_aliases = (char **)xrealloc(
                dst->import_aliases, dst->icap * sizeof(char *));
            for (int k = old; k < dst->icap; k++)
                dst->import_aliases[k] = NULL;
        }
        dst->import_paths[dst->nimports] = ipath;
        dst->import_aliases[dst->nimports] = src->import_aliases
                                                 ? src->import_aliases[i]
                                                 : NULL;
        dst->nimports++;
    }

    for (int i = 0; i < src->nlinks; i++) {
        if (dst->nlinks == dst->lcap) {
            dst->lcap = dst->lcap ? dst->lcap * 2 : 8;
            dst->link_libs = (char **)xrealloc(
                dst->link_libs, dst->lcap * sizeof(char *));
        }
        dst->link_libs[dst->nlinks++] = src->link_libs[i];
    }

    /* top-level statements concatenate in deterministic file order */
    Block *d = dst->main_body;
    Block *s = src->main_body;
    for (int i = 0; i < s->count; i++) {
        if (d->count == d->cap) {
            d->cap = d->cap ? d->cap * 2 : 8;
            d->stmts =
                (Stmt **)xrealloc(d->stmts, d->cap * sizeof(Stmt *));
        }
        d->stmts[d->count++] = s->stmts[i];
    }
}

static int load_package_dir(Loader *ld, const char *real, const char *name);

/* Built-in packages implemented natively by the code generator. */
/* Each native package declares its own import name in its own
 * pkg_<name>/pkg_<name>.h; adding a package means adding one line
 * here (plus its implementation under src/codegen/pkg_<name>/). */
static const char *NATIVE_PKGS[] = {PKG_TIME_NAME, PKG_NET_NAME,
                                    PKG_JSON_NAME, PKG_PROC_NAME,
                                    PKG_FS_NAME,   PKG_LOG_NAME,
                                    PKG_CRYPTO_NAME, PKG_SQL_NAME,
                                    PKG_REGEX_NAME, PKG_OS_NAME, PKG_IO_NAME,
                                    PKG_STRINGS_NAME,
                                    PKG_ENCODING_NAME,
                                    PKG_COMPRESS_NAME, NULL};

/* Does the import path name a built-in native package? Only the exact
 * name does: "lib/json" is a directory that happens to end in "json",
 * never the built-in json. Matching on the base name made it one, and
 * codegen then resolved lib/json's functions against the built-in. */
static int is_native_name(const char *ipath) {
    for (int i = 0; NATIVE_PKGS[i]; i++) {
        if (!strcmp(ipath, NATIVE_PKGS[i]))
            return 1;
    }
    return 0;
}

/* Returns the built-in package `name`, synthesizing it on first use. */
static int load_native(Loader *ld, const char *name) {
    for (int i = 0; i < ld->pkgs->count; i++) {
        if (ld->pkgs->items[i].native &&
            !strcmp(ld->pkgs->items[i].name, name))
            return i; /* already synthesized */
    }

    Package p;
    p.name = xstrdup(name);
    p.path = xasprintf("<builtin:%s>", name);
    p.prog = new_program();
    p.native = 1;
    p.import_pkg = NULL;

    if (ld->pkgs->count == ld->pkgs->cap) {
        ld->pkgs->cap = ld->pkgs->cap ? ld->pkgs->cap * 2 : 8;
        ld->pkgs->items =
            (Package *)xrealloc(ld->pkgs->items,
                                ld->pkgs->cap * sizeof(Package));
    }
    ld->pkgs->items[ld->pkgs->count++] = p;
    return ld->pkgs->count - 1;
}

static int is_pkg_dir(const char *path) {
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int dir_has_sl_files(const char *path) {
    DIR *dir = opendir(path);
    if (!dir)
        return 0;
    int found = 0;
    struct dirent *ent;
    while (!found && (ent = readdir(dir)) != NULL) {
        size_t len = strlen(ent->d_name);
        found = len > 3 && !strcmp(ent->d_name + len - 3, ".sl");
    }
    closedir(dir);
    return found;
}

/* Resolves and loads one import; returns the imported package's index.
 * Order, as README's Packages section documents it: a directory next to
 * the importer, then a native package, then stdlib/<path>, then a
 * slang.project pin. A local directory shadows a native package only if
 * it holds .sl files, so a data directory that happens to be called
 * "json" does not break `import "json"`. (This used to stat the base
 * name against the PROCESS's working directory, so whether a native
 * import worked depended on where slangc was run from.) */
static int load_import(Loader *ld, const char *from_dir,
                       const char *from_pkg, const char *ipath) {
    char target[PATH_MAX];
    snprintf(target, sizeof(target), "%s/%s", from_dir, ipath);

    char treal[PATH_MAX];
    int native = is_native_name(ipath);
    if (realpath(target, treal) && is_pkg_dir(treal) &&
        (!native || dir_has_sl_files(treal))) {
        return load_package_dir(ld, treal, NULL);
    }

    if (native)
        return load_native(ld, ipath);

    char *std = slang_stdlib_pkg(ipath);
    if (std) {
        return load_package_dir(ld, std, NULL);
    }

    SlPkgPin *pin = project_find_pin(ld->project, ipath);
    if (pin) {
        if (!pin->hash)
            load_error("package '%s' is pinned; run slangc get", ipath);
        char *cached = project_cache_dir(pin);
        if (!project_is_dir(cached))
            load_error("package '%s' is not in the cache; run slangc get",
                       ipath);
        /* The hash covers the WHOLE clone, `dir` or not: what was
           verified must be what was fetched, not the part of it this
           project happens to compile. */
        char *got = project_tree_hash(cached);
        if (strcmp(got, pin->hash))
            load_error("package '%s' hash mismatch; run slangc get", ipath);
        char *pkgdir = project_pkg_dir(pin);
        if (!project_is_dir(pkgdir))
            load_error("package '%s' has no directory '%s'", ipath, pin->dir);
        return load_package_dir(ld, pkgdir, pin->name);
    }

    load_error("cannot resolve import '%s' (imported by package '%s')",
               ipath, from_pkg);
    return -1; /* load_error exits */
}

/* Where `import "ipath"` written in from_dir would find a source package:
 * load_import's order (a local directory, a native package, the standard
 * library, a slang.project pin), loading nothing. Sets *native and returns
 * NULL for a compiler-provided package; NULL alone when nothing matches.
 * For slangc doc, which only reads the files: a pin's hash is not checked
 * here, since nothing from it is compiled. */
char *loader_resolve_dir(const char *from_dir, const char *ipath,
                         int *native) {
    *native = 0;
    char target[PATH_MAX], treal[PATH_MAX];
    snprintf(target, sizeof(target), "%s/%s", from_dir, ipath);
    int nat = is_native_name(ipath);
    if (realpath(target, treal) && is_pkg_dir(treal) &&
        (!nat || dir_has_sl_files(treal)))
        return xstrdup(treal);
    if (nat) {
        *native = 1;
        return NULL;
    }
    char *std = slang_stdlib_pkg(ipath);
    if (std)
        return std;
    char *proot = project_find_root(from_dir);
    if (proot) {
        SlPkgPin *pin = project_find_pin(project_load(proot), ipath);
        if (pin) {
            char *pkgdir = project_pkg_dir(pin);
            if (project_is_dir(pkgdir))
                return pkgdir;
        }
    }
    return NULL;
}

const char *const *native_package_list(void) {
    static const char *list[sizeof(NATIVE_PKGS) / sizeof(NATIVE_PKGS[0]) + 1];
    for (size_t i = 0; i < sizeof(NATIVE_PKGS) / sizeof(NATIVE_PKGS[0]); i++)
        list[i] = NATIVE_PKGS[i];
    return list;
}

/* Records that p's import of `ipath` resolved to package `target`.
 * merge_program keeps one entry per distinct path, and every file of a
 * package resolves a given path from the same directory, so the entry is
 * found by path. *nrec is how many import_pkg slots exist so far. */
static void record_import(Package *p, int *nrec, const char *ipath,
                          int target) {
    if (*nrec < p->prog->nimports) {
        p->import_pkg = (int *)xrealloc(
            p->import_pkg, (size_t)p->prog->nimports * sizeof(int));
        for (int j = *nrec; j < p->prog->nimports; j++)
            p->import_pkg[j] = -1;
        *nrec = p->prog->nimports;
    }
    for (int j = 0; j < p->prog->nimports; j++) {
        if (!strcmp(p->prog->import_paths[j], ipath)) {
            p->import_pkg[j] = target;
            return;
        }
    }
    load_error("internal: import '%s' of package '%s' was not merged", ipath,
               p->name);
}

static const char *loader_test_target = NULL;

void loader_set_test_target(const char *real_dir) {
    loader_test_target = real_dir;
}

static int is_test_file(const char *fname) {
    size_t n = strlen(fname);
    return n > 8 && !strcmp(fname + n - 8, "_test.sl");
}

static int load_package_dir(Loader *ld, const char *real, const char *name) {
    int existing = pkg_index_by_path(ld, real);
    if (existing >= 0)
        return existing;

    if (on_stack(ld, real)) {
        Package *any = &ld->pkgs->items[0];
        (void)any;
        load_error("import cycle detected involving '%s'", real);
    }
    stack_push(ld, real);

    DIR *dir = opendir(real);
    if (!dir)
        load_error("cannot open package directory: %s", real);

    char **names = NULL;
    int nnames = 0, ncap = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        size_t len = strlen(ent->d_name);
        int testing_this = loader_test_target && !strcmp(real, loader_test_target);
        /* *_test.sl belongs to `slangc test` only. A normal build never
           sees it, so test helpers cannot leak into a program, and a test
           file's own imports cannot add link flags to one. */
        if (is_test_file(ent->d_name) && !testing_this)
            continue;
        if (len > 3 && !strcmp(ent->d_name + len - 3, ".sl")) {
            if (nnames == ncap) {
                ncap = ncap ? ncap * 2 : 8;
                names =
                    (char **)xrealloc(names, ncap * sizeof(char *));
            }
            names[nnames++] = xstrdup(ent->d_name);
        }
    }
    closedir(dir);

    if (nnames == 0)
        load_error("no .sl files found in package directory '%s'", real);

    /* deterministic compilation order */
    qsort(names, nnames, sizeof(char *), cmp_str);

    Package p;
    /* Provisional: assign_package_names makes it unique once every
       package is loaded. Until then it only appears in diagnostics. */
    p.name = name ? xstrdup(name) : pkg_name_of_path(real);
    p.path = xstrdup(real);
    p.prog = new_program();
    p.native = 0;
    p.import_pkg = NULL;
    int nrec = 0;

    for (int i = 0; i < nnames; i++) {
        char fpath[PATH_MAX];
        snprintf(fpath, sizeof(fpath), "%s/%s", real, names[i]);
        char *src = read_entire_file(fpath);
        diag_file = xstrdup(fpath); /* lexer and parser errors name it */

        Lexer lx;
        lexer_init(&lx, src);
        int tcap = 256, tcount = 0;
        Token *toks = (Token *)xmalloc(tcap * sizeof(Token));
        for (;;) {
            if (tcount == tcap) {
                tcap *= 2;
                toks = (Token *)xrealloc(toks, tcap * sizeof(Token));
            }
            toks[tcount++] = lexer_next(&lx);
            if (toks[tcount - 1].type == T_EOF)
                break;
        }

        Program *fprog = parse_program(toks, tcount);
        /* The generated runner lives in another package, so the tests it
           calls must be exported. Only test_* functions in test files:
           the package's own non-pub functions stay private, and a test
           reaches them from inside the package as usual. */
        if (loader_test_target && !strcmp(real, loader_test_target) &&
            is_test_file(names[i])) {
            for (int k = 0; k < fprog->nfuncs; k++)
                if (!strncmp(fprog->funcs[k]->name, "test_", 5))
                    fprog->funcs[k]->is_pub = 1;
        }
        merge_program(&p, fprog, names[i]);

        /* imports are resolved relative to this package's directory */
        for (int k = 0; k < fprog->nimports; k++) {
            int target = load_import(ld, real, p.name, fprog->import_paths[k]);
            record_import(&p, &nrec, fprog->import_paths[k], target);
        }
    }

    stack_pop(ld);

    /* Testing a PROGRAM: its top-level statements are main's body, and
       they must not run -- the test runner is main now. Structs and impl
       blocks stay, since tests use them. Top-level lets go too: in a
       program they are main's locals, which no function can see, so
       nothing a test calls depends on them. A LIBRARY keeps its lets,
       which are package globals. */
    if (loader_test_target && !strcmp(real, loader_test_target)) {
        Block *body = p.prog->main_body;
        int program_shaped = 0;
        for (int k = 0; k < body->count; k++) {
            int kind = body->stmts[k]->kind;
            if (kind != ST_LET && kind != ST_STRUCT && kind != ST_ENUM &&
                kind != ST_IMPL)
                program_shaped = 1;
        }
        if (program_shaped) {
            int w = 0;
            for (int k = 0; k < body->count; k++) {
                int kind = body->stmts[k]->kind;
                if (kind == ST_STRUCT || kind == ST_ENUM || kind == ST_IMPL)
                    body->stmts[w++] = body->stmts[k];
            }
            body->count = w;
        }
    }

    if (ld->pkgs->count == ld->pkgs->cap) {
        ld->pkgs->cap = ld->pkgs->cap ? ld->pkgs->cap * 2 : 8;
        ld->pkgs->items = (Package *)xrealloc(
            ld->pkgs->items, ld->pkgs->cap * sizeof(Package));
    }
    ld->pkgs->items[ld->pkgs->count++] = p;

    return ld->pkgs->count - 1;
}

/* Is `name` already the final name of some package? */
static int name_taken(char **final, int n, const char *name) {
    for (int i = 0; i < n; i++)
        if (final[i] && !strcmp(final[i], name))
            return 1;
    return 0;
}

static char *claim_name(char **final, int n, const char *want) {
    if (!name_taken(final, n, want))
        return xstrdup(want);
    for (int k = 2;; k++) {
        char *cand = xasprintf("%s_%d", want, k);
        if (!name_taken(final, n, cand))
            return cand;
    }
}

/* Final package names, unique across the whole program. Codegen keys
 * everything on a package's name -- canonical types "<pkg>.<Name>", C
 * symbols sl_<pkg>_<name>, which packages are native -- so two packages
 * sharing a name were merged into one namespace: "a/util" plus "b/util"
 * failed with a bogus "redefinition of function". A directory's name is
 * only a preference. Natives keep theirs (codegen dispatches on them),
 * then the entry package keeps its own, then the rest in load order; a
 * taken name gets "_2", "_3", ... The suffix cannot collide with another
 * package's symbols: "sl_util_2_f" would need a function named "2_f".
 * Import targets were recorded by index, so they follow automatically. */
static void assign_package_names(PkgList *pkgs, int main_index) {
    int n = pkgs->count;
    char **final = (char **)xmalloc((size_t)n * sizeof(char *));
    for (int i = 0; i < n; i++)
        final[i] = pkgs->items[i].native ? pkgs->items[i].name : NULL;
    if (!pkgs->items[main_index].native)
        final[main_index] = claim_name(final, n, pkgs->items[main_index].name);
    for (int i = 0; i < n; i++) {
        if (!final[i])
            final[i] = claim_name(final, n, pkgs->items[i].name);
    }
    for (int i = 0; i < n; i++)
        pkgs->items[i].name = final[i];
    free(final);
}

int load_packages(const char *main_file, PkgList *out) {
    out->items = NULL;
    out->count = 0;
    out->cap = 0;

    Loader ld;
    ld.pkgs = out;
    ld.project = NULL;
    ld.stack = NULL;
    ld.nstack = 0;
    ld.scap = 0;

    char main_real[PATH_MAX];
    if (!realpath(main_file, main_real))
        load_error("cannot resolve input file '%s'", main_file);

    char *dir = path_dir(main_real);
    char dir_real[PATH_MAX];
    if (!realpath(dir, dir_real))
        load_error("cannot resolve directory of '%s'", main_file);

    char *proot = project_find_root(dir_real);
    if (proot)
        ld.project = project_load(proot);

    int main_index = load_package_dir(&ld, dir_real, NULL);
    assign_package_names(out, main_index);
    return main_index;
}

char **collect_link_libs(PkgList *pkgs, int *out_count) {
    char **out = NULL;
    int n = 0, cap = 0;
    for (int i = 0; i < pkgs->count; i++) {
        Program *prog = pkgs->items[i].prog;
        for (int j = 0; j < prog->nlinks; j++) {
            const char *name = prog->link_libs[j];
            int dup = 0;
            for (int k = 0; k < n; k++) {
                if (!strcmp(out[k], name)) {
                    dup = 1;
                    break;
                }
            }
            if (dup)
                continue;
            if (n == cap) {
                cap = cap ? cap * 2 : 8;
                out = (char **)xrealloc(out, cap * sizeof(char *));
            }
            out[n++] = (char *)name;
        }
    }
    *out_count = n;
    return out;
}