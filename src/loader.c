#include "common.h"
#include "lexer.h"
#include "parser.h"
#include "loader.h"

#include "codegen/pkg_net/pkg_net.h"
#include "codegen/pkg_time/pkg_time.h"
#include "codegen/pkg_json/pkg_json.h"
#include "codegen/pkg_proc/pkg_proc.h"

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
    /* realpaths of packages currently being loaded (cycle detection) */
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
        char *alias = path_base(ipath);
        if (!is_ident_like(alias))
            load_error("import '%s': binding name '%s' is not a valid "
                       "identifier",
                       ipath, alias);
        int dup = 0;
        for (int j = 0; j < dst->nimports; j++) {
            if (!strcmp(dst->import_paths[j], ipath)) {
                dup = 1; /* same package imported twice: harmless */
                break;
            }
            char *other = path_base(dst->import_paths[j]);
            if (!strcmp(other, alias))
                load_error("duplicate import binding '%s' in package '%s'",
                           alias, pkg->name);
        }
        if (dup)
            continue;
        if (dst->nimports == dst->icap) {
            dst->icap = dst->icap ? dst->icap * 2 : 8;
            dst->import_paths = (char **)xrealloc(
                dst->import_paths, dst->icap * sizeof(char *));
        }
        dst->import_paths[dst->nimports++] = ipath;
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

static int load_package_dir(Loader *ld, const char *real);

/* Built-in packages implemented natively by the code generator. */
/* Each native package declares its own import name in its own
 * pkg_<name>/pkg_<name>.h; adding a package means adding one line
 * here (plus its implementation under src/codegen/pkg_<name>/). */
static const char *NATIVE_PKGS[] = {PKG_TIME_NAME, PKG_NET_NAME,
                                    PKG_JSON_NAME, PKG_PROC_NAME, NULL};

/* If the import path refers to a built-in native package (and there is
 * no local directory of the same name), synthesize it. */
static int try_load_native(Loader *ld, const char *ipath,
                           const char *from_pkg) {
    char *base = path_base(ipath);
    int is_native = 0;
    for (int i = 0; NATIVE_PKGS[i]; i++) {
        if (!strcmp(base, NATIVE_PKGS[i]))
            is_native = 1;
    }
    if (!is_native)
        return -1;

    /* a user directory with this name takes precedence */
    struct stat st;
    if (stat(base, &st) == 0 && S_ISDIR(st.st_mode))
        return -1;

    for (int i = 0; i < ld->pkgs->count; i++) {
        if (ld->pkgs->items[i].native &&
            !strcmp(ld->pkgs->items[i].name, base))
            return i; /* already synthesized */
    }

    Package p;
    p.name = base;
    p.path = xasprintf("<builtin:%s>", base);
    p.prog = new_program();
    p.native = 1;

    if (ld->pkgs->count == ld->pkgs->cap) {
        ld->pkgs->cap = ld->pkgs->cap ? ld->pkgs->cap * 2 : 8;
        ld->pkgs->items =
            (Package *)xrealloc(ld->pkgs->items,
                                ld->pkgs->cap * sizeof(Package));
    }
    ld->pkgs->items[ld->pkgs->count++] = p;
    return ld->pkgs->count - 1;
}

/* Resolve one import path relative to the importing package directory
 * and load that package. */
static void load_import(Loader *ld, const char *from_dir,
                        const char *from_pkg, const char *ipath) {
    int nat = try_load_native(ld, ipath, from_pkg);
    if (nat >= 0)
        return;

    char target[PATH_MAX];
    snprintf(target, sizeof(target), "%s/%s", from_dir, ipath);

    char treal[PATH_MAX];
    if (!realpath(target, treal))
        load_error("cannot resolve import '%s' (imported by package '%s')",
                   ipath, from_pkg);

    struct stat st;
    if (stat(treal, &st) != 0 || !S_ISDIR(st.st_mode))
        load_error("import '%s' is not a directory (imported by package "
                   "'%s')",
                   ipath, from_pkg);

    load_package_dir(ld, treal);
}

static int load_package_dir(Loader *ld, const char *real) {
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
    p.name = path_base(real);
    p.path = xstrdup(real);
    p.prog = new_program();
    p.native = 0;

    for (int i = 0; i < nnames; i++) {
        char fpath[PATH_MAX];
        snprintf(fpath, sizeof(fpath), "%s/%s", real, names[i]);
        char *src = read_entire_file(fpath);

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
        merge_program(&p, fprog, names[i]);

        /* imports are resolved relative to this package's directory */
        for (int k = 0; k < fprog->nimports; k++)
            load_import(ld, real, p.name, fprog->import_paths[k]);
    }

    stack_pop(ld);

    if (ld->pkgs->count == ld->pkgs->cap) {
        ld->pkgs->cap = ld->pkgs->cap ? ld->pkgs->cap * 2 : 8;
        ld->pkgs->items = (Package *)xrealloc(
            ld->pkgs->items, ld->pkgs->cap * sizeof(Package));
    }
    ld->pkgs->items[ld->pkgs->count++] = p;

    return ld->pkgs->count - 1;
}

int load_packages(const char *main_file, PkgList *out) {
    out->items = NULL;
    out->count = 0;
    out->cap = 0;

    Loader ld;
    ld.pkgs = out;
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

    return load_package_dir(&ld, dir_real);
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