/* slangc doc: a package's API from the command line.
 *
 *   slangc doc                   every package this directory can import
 *   slangc doc <pkg>             its exported items, one line each
 *   slangc doc <pkg>.<name>      one item in full: its doc comment and
 *   slangc doc <pkg> <name>      signature (a struct with its fields and
 *                                methods)
 *   slangc doc <pkg> <text>      no item by that name: every item whose
 *                                name contains <text> (any case), else
 *                                whose signature or doc does
 *
 * An agent asks for the one API it needs instead of reading a page or the
 * package source. Packages resolve exactly as `import` does from the
 * current directory: a local directory, a compiler-provided package, the
 * standard library, then a slang.project pin.
 *
 * Source packages are read the way the documentation site reads them
 * (www/build.py): an exported item is a `pub` declaration, and its docs
 * are the run of // comments directly above it. Native packages have no
 * source; their signatures come from the compiler's own NatSig tables. */

#include "common.h"
#include "loader.h"
#include "rtpath.h"
#include "codegen/internal.h"

#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    char *name;   /* "get", or "Client.get" for a method */
    char *kind;   /* fn, struct, enum, let */
    char *sig;    /* one line for fn/let; the whole block for struct/enum */
    char *doc;    /* comment text, lines joined with '\n'; "" if none */
    char *owner;  /* struct a method belongs to, else NULL */
} DocItem;

typedef struct {
    DocItem *items;
    int count, cap;
} DocList;

static void doc_push(DocList *l, DocItem it) {
    if (l->count == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 32;
        l->items = (DocItem *)xrealloc(l->items, (size_t)l->cap * sizeof(DocItem));
    }
    l->items[l->count++] = it;
}

static char *read_file_or_null(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    StrBuf b;
    sb_init(&b);
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        sb_append_n(&b, buf, n);
    fclose(f);
    return b.data;
}

/* Split text into lines; the array and the text both stay allocated. */
static char **split_lines(char *text, int *n) {
    int cap = 256, cnt = 0;
    char **lines = (char **)xmalloc((size_t)cap * sizeof(char *));
    char *p = text;
    while (*p) {
        if (cnt == cap) {
            cap *= 2;
            lines = (char **)xrealloc(lines, (size_t)cap * sizeof(char *));
        }
        lines[cnt++] = p;
        char *nl = strchr(p, '\n');
        if (!nl)
            break;
        *nl = '\0';
        p = nl + 1;
    }
    *n = cnt;
    return lines;
}

static const char *skip_ws(const char *s) {
    while (*s == ' ' || *s == '\t')
        s++;
    return s;
}

static int starts_word(const char *s, const char *w) {
    size_t n = strlen(w);
    return !strncmp(s, w, n) && (s[n] == ' ' || s[n] == '\t');
}

/* Copy an identifier starting at s. */
static char *ident_at(const char *s) {
    const char *e = s;
    while (*e == '_' || (*e >= 'a' && *e <= 'z') || (*e >= 'A' && *e <= 'Z') ||
           (*e >= '0' && *e <= '9'))
        e++;
    if (e == s)
        return NULL;
    char *r = (char *)xmalloc((size_t)(e - s) + 1);
    memcpy(r, s, (size_t)(e - s));
    r[e - s] = '\0';
    return r;
}

/* Collapse runs of whitespace to one space and trim. */
static char *squeeze(const char *s) {
    StrBuf b;
    sb_init(&b);
    int sp = 0;
    for (s = skip_ws(s); *s; s++) {
        if (*s == ' ' || *s == '\t' || *s == '\n') {
            sp = 1;
            continue;
        }
        if (sp && b.len)
            sb_putc(&b, ' ');
        sp = 0;
        sb_putc(&b, *s);
    }
    return b.data ? b.data : xstrdup("");
}

/* The run of // comments directly above line i, without a leading banner
 * of dashes (a section divider, not documentation). */
static char *doc_above(char **lines, int i) {
    int j = i - 1;
    while (j >= 0 && !strncmp(skip_ws(lines[j]), "//", 2))
        j--;
    StrBuf b;
    sb_init(&b);
    int started = 0;
    for (int k = j + 1; k < i; k++) {
        const char *t = skip_ws(lines[k]) + 2;
        if (*t == ' ')
            t++;
        if (!started) {
            const char *q = t;
            while (*q == '-' || *q == ' ')
                q++;
            if (*q == '\0')
                continue; /* banner or blank comment before the text */
        }
        started = 1;
        if (b.len)
            sb_putc(&b, '\n');
        sb_append(&b, t);
    }
    return b.data ? b.data : xstrdup("");
}

/* A fn signature may span lines: everything from the declaration up to the
 * `{` that opens its body, on one line. */
static char *fn_signature(char **lines, int n, int i) {
    StrBuf b;
    sb_init(&b);
    for (int k = i; k < n && k < i + 20; k++) {
        const char *brace = strchr(lines[k], '{');
        if (brace) {
            sb_append_n(&b, lines[k], (size_t)(brace - lines[k]));
            break;
        }
        sb_append(&b, lines[k]);
        sb_putc(&b, ' ');
    }
    char *s = squeeze(b.data ? b.data : "");
    if (!strncmp(s, "pub ", 4))
        return xstrdup(s + 4);
    return s;
}

/* A struct or enum: its declaration through the `}` that closes it. */
static char *block_text(char **lines, int n, int i) {
    StrBuf b;
    sb_init(&b);
    int depth = 0;
    for (int k = i; k < n && k < i + 200; k++) {
        const char *l = lines[k];
        if (k == i && !strncmp(l, "pub ", 4))
            l += 4;
        sb_append(&b, l);
        sb_putc(&b, '\n');
        for (const char *c = lines[k]; *c; c++) {
            if (*c == '/' && c[1] == '/')
                break;
            if (*c == '{')
                depth++;
            else if (*c == '}')
                depth--;
        }
        if (depth <= 0 && strchr(lines[k], '}'))
            break;
    }
    if (b.len && b.data[b.len - 1] == '\n')
        b.data[--b.len] = '\0';
    return b.data;
}

static int is_test_file(const char *name) {
    size_t n = strlen(name);
    return n > 8 && !strcmp(name + n - 8, "_test.sl");
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Every exported item of the source package in dir, in file order. */
static void scan_source_package(const char *dir, DocList *out) {
    DIR *d = opendir(dir);
    if (!d)
        return;
    char **names = NULL;
    int nn = 0, cap = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        size_t len = strlen(de->d_name);
        if (len < 4 || strcmp(de->d_name + len - 3, ".sl") ||
            is_test_file(de->d_name))
            continue;
        if (nn == cap) {
            cap = cap ? cap * 2 : 16;
            names = (char **)xrealloc(names, (size_t)cap * sizeof(char *));
        }
        names[nn++] = xstrdup(de->d_name);
    }
    closedir(d);
    if (nn)
        qsort(names, (size_t)nn, sizeof(char *), cmp_str);
    for (int f = 0; f < nn; f++) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", dir, names[f]);
        char *text = read_file_or_null(path);
        if (!text)
            continue;
        int n;
        char **lines = split_lines(text, &n);
        char *impl = NULL;
        for (int i = 0; i < n; i++) {
            const char *l = lines[i];
            if (starts_word(l, "impl")) {
                /* `impl Name {` or `impl Name[T] {`: methods follow */
                impl = ident_at(skip_ws(l + 4));
                continue;
            }
            if (impl && l[0] == '}') {
                impl = NULL;
                continue;
            }
            const char *t = l;
            int indented = (*t == ' ' || *t == '\t');
            t = skip_ws(t);
            if (!starts_word(t, "pub"))
                continue;
            if (indented && !impl)
                continue;
            const char *r = skip_ws(t + 3);
            DocItem it;
            memset(&it, 0, sizeof(it));
            if (starts_word(r, "fn")) {
                char *name = ident_at(skip_ws(r + 2));
                if (!name)
                    continue;
                it.kind = "fn";
                if (impl && indented) {
                    it.name = xasprintf("%s.%s", impl, name);
                    it.owner = impl;
                } else {
                    it.name = name;
                }
                it.sig = fn_signature(lines, n, i);
            } else if (!indented && (starts_word(r, "struct") ||
                                     starts_word(r, "gc") ||
                                     starts_word(r, "enum"))) {
                const char *q = r;
                if (starts_word(q, "gc"))
                    q = skip_ws(q + 2);
                int is_enum = starts_word(q, "enum");
                q = skip_ws(q + (is_enum ? 4 : 6));
                it.name = ident_at(q);
                if (!it.name)
                    continue;
                it.kind = is_enum ? "enum" : "struct";
                it.sig = block_text(lines, n, i);
            } else if (!indented && starts_word(r, "let")) {
                it.name = ident_at(skip_ws(r + 3));
                if (!it.name)
                    continue;
                it.kind = "let";
                it.sig = squeeze(r);
            } else {
                continue;
            }
            it.doc = doc_above(lines, i);
            doc_push(out, it);
        }
    }
}

/* ---- native packages ---------------------------------------------------- */

static const char *argkind_name(NatArgKind k) {
    switch (k) {
    case NA_INT:
    case NA_I64: return "int";
    case NA_F64: return "float";
    case NA_STR:
    case NA_STR_FAULT: return "str";
    case NA_BYTES: return "bytes";
    case NA_RAWPTR: return "rawptr";
    case NA_ARR_STR: return "[str]";
    case NA_ARR_BYTES: return "[bytes]";
    case NA_WIRE: return "wire";
    case NA_UNTIL: return "until";
    }
    return "?";
}

static void scan_native_package(const char *pkg, DocList *out) {
    const NatSig *sigs[512];
    int n = native_sigs_of(pkg, sigs, 512);
    for (int i = 0; i < n; i++) {
        StrBuf b;
        sb_init(&b);
        sb_append(&b, "fn ");
        sb_append(&b, sigs[i]->name);
        sb_putc(&b, '(');
        for (int a = 0; a < sigs[i]->nargs; a++) {
            if (a)
                sb_append(&b, ", ");
            sb_append(&b, argkind_name(sigs[i]->argkinds[a]));
        }
        sb_putc(&b, ')');
        if (sigs[i]->ret) {
            sb_append(&b, " -> ");
            sb_append(&b, sigs[i]->ret);
        }
        DocItem it;
        memset(&it, 0, sizeof(it));
        it.name = (char *)sigs[i]->name;
        it.kind = "fn";
        it.sig = b.data;
        it.doc = "";
        doc_push(out, it);
    }
}

/* ---- output -------------------------------------------------------------- */

/* The first sentence of a doc comment, on one line. */
static char *first_sentence(const char *doc) {
    char *flat = squeeze(doc);
    for (char *p = flat; *p; p++) {
        if (*p == '.' && (p[1] == ' ' || p[1] == '\0')) {
            p[1] = '\0';
            break;
        }
    }
    if (strlen(flat) > 160)
        strcpy(flat + 157, "...");
    return flat;
}

/* A struct or enum on one line: `struct Point { x: int, y: int }`. */
static char *one_line(const char *block) {
    StrBuf b;
    sb_init(&b);
    char *copy = xstrdup(block);
    int n;
    char **lines = split_lines(copy, &n);
    for (int i = 0; i < n; i++) {
        char *l = lines[i];
        char *c = strstr(l, "//");
        if (c)
            *c = '\0';
        char *s = squeeze(l);
        if (!*s)
            continue;
        if (b.len && strcmp(s, "}") && b.data[b.len - 1] != '{')
            sb_putc(&b, ' ');
        else if (b.len)
            sb_putc(&b, ' ');
        sb_append(&b, s);
    }
    char *r = b.data ? b.data : xstrdup("");
    /* a trailing comma before the closing brace reads as noise */
    size_t len = strlen(r);
    if (len >= 3 && !strcmp(r + len - 3, ", }")) {
        r[len - 3] = ' ';
        r[len - 2] = '}';
        r[len - 1] = '\0';
    }
    return r;
}

static void print_doc_lines(const char *doc, const char *indent) {
    if (!*doc)
        return;
    char *copy = xstrdup(doc);
    int n;
    char **lines = split_lines(copy, &n);
    for (int i = 0; i < n; i++)
        printf("%s// %s\n", indent, lines[i]);
}

/* One item of a listing. Its summary goes ABOVE the signature, where a
 * doc comment sits in source: printed below, indented, it read as the
 * comment of the item on the next line, so a listing looked like it gave
 * each function its neighbour's documentation. */
static void print_summary_item(DocItem *it) {
    const char *sig = strcmp(it->kind, "struct") && strcmp(it->kind, "enum")
                          ? it->sig
                          : one_line(it->sig);
    if (*it->doc)
        printf("// %s\n", first_sentence(it->doc));
    if (it->owner && !strncmp(sig, "fn ", 3))
        printf("fn %s.%s\n", it->owner, sig + 3); /* fn Str.write(...) */
    else
        printf("%s\n", sig);
}

static void print_summary(const char *pkg, const char *where, DocList *l) {
    printf("package %s (%s)\n\n", pkg, where);
    for (int i = 0; i < l->count; i++)
        print_summary_item(&l->items[i]);
    if (!l->count && !strcmp(pkg, "json"))
        /* no NatSig table: its calls are generic over the target type */
        printf("fn encode(value: <a gc struct, list, map or scalar>) -> str\n"
               "fn decode(text: str) -> result[T, str]   "
               "(T from the annotation: let r: result[User, str] = "
               "json.decode(s);)\n");
    else if (!l->count)
        printf("(no exported items)\n");
}

static void print_item(DocList *l, DocItem *it) {
    print_doc_lines(it->doc, "");
    printf("%s\n", it->sig);
    if (strcmp(it->kind, "struct"))
        return;
    int any = 0;
    for (int i = 0; i < l->count; i++) {
        DocItem *m = &l->items[i];
        if (!m->owner || strcmp(m->owner, it->name))
            continue;
        if (!any)
            printf("\nmethods:\n");
        any = 1;
        if (*m->doc)
            printf("  // %s\n", first_sentence(m->doc));
        printf("  %s\n", m->sig);
    }
}

/* Case-insensitive substring test. */
static int icontains(const char *hay, const char *needle) {
    if (!hay || !needle || !*needle)
        return 0;
    size_t n = strlen(needle);
    for (const char *h = hay; *h; h++) {
        size_t k = 0;
        while (k < n && h[k] &&
               tolower((unsigned char)h[k]) == tolower((unsigned char)needle[k]))
            k++;
        if (k == n)
            return 1;
    }
    return 0;
}

/* ---- package listing ----------------------------------------------------- */

static void list_packages(void) {
    printf("native (built into the compiler):\n ");
    const char *const *nat = native_package_list();
    for (int i = 0; nat[i]; i++)
        printf(" %s", nat[i]);
    printf("\n");
    char *std = slang_stdlib_root();
    if (std) {
        DIR *d = opendir(std);
        if (d) {
            char **names = NULL;
            int nn = 0, cap = 0;
            struct dirent *de;
            while ((de = readdir(d))) {
                if (de->d_name[0] == '.')
                    continue;
                char p[PATH_MAX];
                struct stat st;
                snprintf(p, sizeof(p), "%s/%s", std, de->d_name);
                if (stat(p, &st) || !S_ISDIR(st.st_mode))
                    continue;
                if (nn == cap) {
                    cap = cap ? cap * 2 : 16;
                    names = (char **)xrealloc(names, (size_t)cap * sizeof(char *));
                }
                names[nn++] = xstrdup(de->d_name);
            }
            closedir(d);
            if (nn)
                qsort(names, (size_t)nn, sizeof(char *), cmp_str);
            printf("standard library:\n ");
            for (int i = 0; i < nn; i++)
                printf(" %s", names[i]);
            printf("\n");
        }
    }
    printf("\nslangc doc <pkg> lists a package; slangc doc <pkg>.<name> shows "
           "one item;\nslangc doc <pkg> <text> lists the items whose name (or, "
           "failing that, signature\nor doc) contains <text>.\n");
}

int cmd_doc(int argc, char **argv) {
    if (argc <= 2) {
        list_packages();
        return 0;
    }
    if (argc > 4) {
        fputs("slang: usage: slangc doc [<pkg>[.<name>] | <pkg> <name>]\n",
              stderr);
        return 2;
    }
    char *pkg = xstrdup(argv[2]);
    char *item = argc == 4 ? xstrdup(argv[3]) : NULL;
    if (!item) {
        /* pkg.name, or pkg.Type.method: the package is the part before
           the first dot, since import paths name directories, not dots */
        char *dot = strchr(pkg, '.');
        if (dot) {
            *dot = '\0';
            item = dot + 1;
        }
    }
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) {
        fputs("slang: cannot read the current directory\n", stderr);
        return 2;
    }
    int native = 0;
    char *dir = loader_resolve_dir(cwd, pkg, &native);
    DocList l;
    memset(&l, 0, sizeof(l));
    const char *where;
    if (native) {
        scan_native_package(pkg, &l);
        where = "native";
    } else if (dir) {
        scan_source_package(dir, &l);
        char *std = slang_stdlib_root();
        size_t cl = strlen(cwd), sl = std ? strlen(std) : 0;
        if (std && !strncmp(dir, std, sl) && dir[sl] == '/')
            where = "standard library";
        else if (!strncmp(dir, cwd, cl) && dir[cl] == '/')
            where = xasprintf("./%s", dir + cl + 1);
        else
            where = dir;
    } else {
        fprintf(stderr, "slang: no package '%s' here (run slangc doc for the "
                        "list)\n", pkg);
        return 1;
    }
    if (!item) {
        print_summary(pkg, where, &l);
        return 0;
    }
    for (int i = 0; i < l.count; i++) {
        if (!strcmp(l.items[i].name, item)) {
            print_item(&l, &l.items[i]);
            return 0;
        }
    }
    /* Not a name: search. Paging a whole package listing to find the one
     * call that sets a header is what an agent otherwise does, and every
     * page of it is re-sent on every later turn. Names first; only when no
     * name matches, signatures and doc text. */
    int found = 0;
    for (int pass = 0; pass < 2 && !found; pass++) {
        for (int i = 0; i < l.count; i++) {
            DocItem *it = &l.items[i];
            int hit = pass == 0 ? icontains(it->name, item)
                                : icontains(it->sig, item) ||
                                      icontains(it->doc, item);
            if (!hit)
                continue;
            if (!found)
                printf("package %s: %s matching '%s'\n\n", pkg,
                       pass == 0 ? "names" : "signatures and docs", item);
            found++;
            print_summary_item(it);
        }
    }
    if (found) {
        printf("\nslangc doc %s.<name> shows one in full.\n", pkg);
        return 0;
    }
    fprintf(stderr, "slang: package '%s' has no exported '%s', and nothing in "
                    "it mentions it (slangc doc %s lists what it has)\n",
            pkg, item, pkg);
    return 1;
}
