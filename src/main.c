/* slangc - the slang compiler driver.
 *
 * Pipeline: read .sl file -> lex -> parse -> generate C -> invoke cc.
 *
 * Usage:
 *   slangc <file.sl>              compile to an executable
 *   slangc <file.sl> -o <name>    choose the output name
 *   slangc <file.sl> --emit-c     only write the generated C file
 *   slangc <file.sl> --keep-c     keep the generated C file after compiling
 *   slangc <file.sl> --run        compile and immediately run the result
 *   slangc new <name>|.           scaffold a new project
 *   slangc get [file.sl|dir]      resolve dependencies, write slang.lock
 *   slangc --version              print the version
 */

#include "common.h"
#include "loader.h"
#include "lexer.h"
#include "parser.h"
#include "codegen.h"
#include "codegen/liveness.h"
#include "codegen/mir.h"
#include "rtpath.h"
#include "project.h"

#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SLANG_VERSION
#define SLANG_VERSION "0.2.0"
#endif

static void print_usage(void) {
    fputs("usage: slangc <file.sl> [-o <name>] [--emit-c] [--keep-c] [--run] "
          "[--dump-liveness] [--dump-mir]\n"
          "       slangc new <name>|.        scaffold a project here or in <name>\n"
          "       slangc get [file.sl|dir]   resolve deps, write slang.lock\n"
          "       slangc test [dir] [--run substr] [--keep]   run test_* functions in *_test.sl\n"
          "       slangc --version",
          stderr);
    fputc(10, stderr);
}

static void write_file(const char *path, const char *data, size_t len);
static int build(const char *input, const char *outname, int emit_c,
                 int keep_c, int run, int want_liveness_dump,
                 int want_mir_dump);

/* ---- slangc new -----------------------------------------------------
 *
 * Scaffolding lives in the compiler rather than a companion tool
 * because the compiler already OWNS both formats: project.c parses
 * slang.project and writes slang.lock. A separate `slang-init` would
 * have to reimplement a grammar it does not control, and would drift
 * from it on the first change.
 *
 * It deliberately does NOT write slang.lock. The lock is derived --
 * `slangc get` generates it from the pins in slang.project -- and a
 * lock file for a project with no dependencies records nothing. Cargo
 * and Go draw the same line: `cargo new` writes Cargo.toml but not
 * Cargo.lock, `go mod init` writes go.mod but not go.sum. */

static int valid_pkg_name(const char *n) {
    if (!n || !*n)
        return 0;
    if (!isalpha((unsigned char)n[0]) && n[0] != '_')
        return 0;
    for (const char *p = n; *p; p++)
        if (!isalnum((unsigned char)*p) && *p != '_')
            return 0;
    return 1;
}

static int exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

static int cmd_new(const char *arg) {
    char dirbuf[4096];
    const char *dir;
    char namebuf[256];
    const char *name;

    if (!arg) {
        fputs("slang: usage: slangc new <name>|.\n", stderr);
        return 1;
    }

    if (!strcmp(arg, ".")) {
        if (!getcwd(dirbuf, sizeof(dirbuf))) {
            fputs("slang: cannot determine working directory\n", stderr);
            return 1;
        }
        dir = dirbuf;
        const char *slash = strrchr(dir, '/');
        snprintf(namebuf, sizeof(namebuf), "%s", slash ? slash + 1 : dir);
        /* A directory may legally be called "my-app"; a package may not.
           Translate rather than refuse, since the user did not choose
           this name as a package name. */
        for (char *q = namebuf; *q; q++)
            if (!isalnum((unsigned char)*q) && *q != '_')
                *q = '_';
        name = namebuf;
    } else {
        dir = arg;
        const char *slash = strrchr(arg, '/');
        name = slash ? slash + 1 : arg;
        if (mkdir(dir, 0755) != 0 && !exists(dir)) {
            fputs("slang: cannot create directory: ", stderr);
            fputs(dir, stderr);
            fputc(10, stderr);
            return 1;
        }
    }

    if (!valid_pkg_name(name)) {
        fputs("slang: '", stderr);
        fputs(name, stderr);
        fputs("' is not a usable package name (letters, digits and "
              "underscore; must not start with a digit)\n", stderr);
        return 1;
    }

    char *proj = xasprintf("%s/slang.project", dir);
    if (exists(proj)) {
        fputs("slang: ", stderr);
        fputs(proj, stderr);
        fputs(" already exists -- refusing to overwrite\n", stderr);
        return 1;
    }

    char *pbody = xasprintf("name %s\nversion 0.1.0\n", name);
    write_file(proj, pbody, strlen(pbody));

    char *mainsl = xasprintf("%s/main.sl", dir);
    if (!exists(mainsl)) {
        char *mbody = xasprintf(
            "// %s\n"
            "//\n"
            "// Build and run:  slangc main.sl --run\n"
            "// Add a package:  add a `pkg` line to slang.project, then\n"
            "//                 `slangc get` to write slang.lock\n"
            "\n"
            "println(\"hello from %s\");\n",
            name, name);
        write_file(mainsl, mbody, strlen(mbody));
    }

    char *ign = xasprintf("%s/.gitignore", dir);
    if (!exists(ign)) {
        const char *ibody =
            "# slangc writes the binary next to the source it compiled,\n"
            "# and keeps generated C only with --keep-c.\n"
            "main\n"
            "*.gen.c\n";
        write_file(ign, ibody, strlen(ibody));
    }

    fputs("created ", stdout);
    fputs(proj, stdout);
    fputc(10, stdout);
    fputs("created ", stdout);
    fputs(mainsl, stdout);
    fputc(10, stdout);
    fputs("\nnext:  ", stdout);
    if (strcmp(arg, ".")) {
        fputs("cd ", stdout);
        fputs(dir, stdout);
        fputs(" && ", stdout);
    }
    fputs("slangc main.sl --run\n", stdout);
    return 0;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        fputs("slang: cannot write file: ", stderr);
        fputs(path, stderr);
        fputc(10, stderr);
        exit(1);
    }
    fwrite(data, 1, len, f);
    fclose(f);
}

/* Strip directory and extension: "dir/foo.sl" -> "foo" */
static char *derive_stem(const char *path) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    char *stem = xstrdup(base);
    char *dot = strrchr(stem, '.');
    if (dot && dot != stem)
        *dot = '\0';
    return stem;
}

/* ---- finding OpenSSL -------------------------------------------------
 *
 * `net` over TLS, `crypto` and `httpc` over https compile against
 * OpenSSL. pkg-config used to be the only way slangc looked for it, and
 * when pkg-config was not on PATH -- or could not see a keg-only Homebrew
 * install -- the first a user heard of it was the C compiler's
 * "'openssl/err.h' file not found", which does not say what to do. Found
 * while verifying the v0.2.0 tarball, on a machine whose Homebrew lives at
 * /usr/local/Homebrew rather than either standard prefix.
 *
 * Tried in order, first hit wins:
 *   1. OPENSSL_DIR       an explicit answer beats every guess
 *   2. pkg-config        what a correctly configured machine already has
 *   3. known prefixes    Homebrew on Apple Silicon, Intel, and the older
 *                        /usr/local/Homebrew layout; MacPorts
 *   4. brew --prefix     a Homebrew installed somewhere unusual
 *   5. system headers    Linux distributions: no flags needed at all
 * A prefix counts only if include/openssl/ssl.h is really there, so a
 * stale directory is skipped rather than handed to the compiler.
 *
 * Nothing found is NOT an error here. A compiler can have include paths
 * this cannot see (CPATH, a sysroot, a wrapper script), so refusing to
 * compile would block working setups. The result is instead remembered,
 * and if compilation then fails, slangc explains the likely cause. */

static int openssl_prefix_ok(const char *prefix) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/include/openssl/ssl.h", prefix);
    return exists(path);
}

static void openssl_flags_for_prefix(char *out, size_t n, const char *prefix) {
    snprintf(out, n, "-I%s/include -L%s/lib -lssl -lcrypto", prefix, prefix);
}

/* Runs `cmd` and keeps its first line in `out`. Returns 1 only when the
 * command exited 0 and printed something: pkg-config prints nothing to
 * stdout when it fails, and a bare "-lssl -lcrypto" from a fallback path
 * must not be mistaken for a real answer. */
static int first_line_of(const char *cmd, char *out, size_t n) {
    FILE *f = popen(cmd, "r");
    if (!f)
        return 0;
    int got = fgets(out, (int)n, f) != NULL;
    int status = pclose(f);
    if (!got || status != 0)
        return 0;
    size_t len = strlen(out);
    while (len && (out[len - 1] == '\n' || out[len - 1] == '\r'))
        out[--len] = '\0';
    return len > 0;
}

/* Fills `out` with compiler flags for OpenSSL. Returns where they came
 * from, or NULL when no install was located and plain -lssl -lcrypto is
 * a hope rather than an answer. */
static const char *find_openssl(char *out, size_t n) {
    const char *dir = getenv("OPENSSL_DIR");
    if (dir && *dir) {
        if (openssl_prefix_ok(dir)) {
            openssl_flags_for_prefix(out, n, dir);
            return "OPENSSL_DIR";
        }
        fprintf(stderr,
                "slang: warning: OPENSSL_DIR=%s has no include/openssl/ssl.h; "
                "looking elsewhere\n", dir);
    }

    if (first_line_of("pkg-config --cflags --libs openssl 2>/dev/null", out, n))
        return "pkg-config";

    static const char *const prefixes[] = {
        "/opt/homebrew/opt/openssl@3",       /* Homebrew, Apple Silicon */
        "/opt/homebrew/opt/openssl",
        "/usr/local/opt/openssl@3",          /* Homebrew, Intel */
        "/usr/local/opt/openssl",
        "/usr/local/Homebrew/opt/openssl@3", /* older Homebrew layout */
        "/usr/local/Homebrew/opt/openssl",
        "/opt/local",                        /* MacPorts */
        NULL,
    };
    for (int i = 0; prefixes[i]; i++) {
        if (openssl_prefix_ok(prefixes[i])) {
            openssl_flags_for_prefix(out, n, prefixes[i]);
            return prefixes[i];
        }
    }

    char brew[4096];
    if (first_line_of("brew --prefix openssl@3 2>/dev/null", brew, sizeof(brew)) &&
        openssl_prefix_ok(brew)) {
        openssl_flags_for_prefix(out, n, brew);
        return "brew --prefix";
    }

    snprintf(out, n, "-lssl -lcrypto");
    if (exists("/usr/include/openssl/ssl.h") ||
        exists("/usr/local/include/openssl/ssl.h"))
        return "system headers";
    return NULL;
}

static int cmd_get(const char *hint) {
    char start[PATH_MAX];
    if (hint && hint[0]) {
        if (!realpath(hint, start)) {
            fputs("slang: cannot resolve '", stderr);
            fputs(hint, stderr);
            fputs("'\n", stderr);
            return 1;
        }
        struct stat st;
        if (stat(start, &st) == 0 && S_ISREG(st.st_mode)) {
            char *slash = strrchr(start, '/');
            if (slash) {
                if (slash == start)
                    start[1] = '\0';
                else
                    *slash = '\0';
            }
        }
    } else if (!getcwd(start, sizeof(start))) {
        fputs("slang: cannot determine working directory\n", stderr);
        return 1;
    }
    char *root = project_find_root(start);
    if (!root) {
        fputs("slang: no slang.project found\n", stderr);
        return 1;
    }
    SlProject *p = project_load(root);
    project_get(p);
    fputs("wrote ", stdout);
    fputs(root, stdout);
    fputs("/slang.lock\n", stdout);
    return 0;
}

/* ---- slangc test ----------------------------------------------------
 *
 * Go's shape, because it is proven and server developers already know it:
 *
 *   - test files are *_test.sl, and a normal build never sees them;
 *   - a test is `fn test_name()` in a test file, inside the package it
 *     tests, so it can reach that package's private functions;
 *   - a test fails by panicking: assert(cond, msg) or panic(msg).
 *
 * Each test runs in its OWN task and is joined before the next starts, so
 * a failure is a joined task's err -- reported with the test's name and
 * the location of the assert -- and the run carries on. Tests run one at a
 * time on purpose: output stays in order, and nothing is concurrent that
 * the test did not make concurrent itself.
 *
 * How: discover the test functions, generate a runner program that
 * imports the package under test and calls each one, and compile it with
 * the ordinary pipeline. The loader's test mode (loader.c) is what adds
 * the test files, exports the test functions to the runner, and -- for a
 * program rather than a library -- drops the top-level statements, since
 * the runner is main now. */

static int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcmp(s + a - b, suffix);
}

/* Relative path from directory `from` to directory `to`, both absolute
 * and canonical. Imports resolve relative to the importing file, so this
 * is how the runner, which lives in a temporary directory, reaches the
 * package under test without the language gaining absolute imports. */
static char *relative_path(const char *from, const char *to) {
    const char *a = from, *b = to;
    const char *last_common = from;
    while (*a && *b && *a == *b) {
        if (*a == '/')
            last_common = a;
        a++;
        b++;
    }
    if ((*a == '\0' && (*b == '/' || *b == '\0')) ||
        (*b == '\0' && *a == '/'))
        last_common = a;
    const char *rest_from = from + (last_common - from);
    const char *rest_to = to + (last_common - from);
    StrBuf sb;
    sb_init(&sb);
    for (const char *q = rest_from; *q; q++)
        if (*q == '/')
            sb_append(&sb, sb.len ? "/.." : "..");
    if (*rest_to == '/')
        rest_to++;
    if (*rest_to) {
        if (sb.len)
            sb_append(&sb, "/");
        sb_append(&sb, rest_to);
    }
    if (!sb.len)
        sb_append(&sb, ".");
    return sb.data;
}

static int cmd_test(int argc, char **argv) {
    const char *target = ".";
    const char *filter = NULL;
    int keep = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--keep")) {
            keep = 1;   /* keep the generated runner, and say where */
        } else if (!strcmp(argv[i], "--run")) {
            if (i + 1 >= argc) {
                fputs("slang: --run needs a substring of the test names to run\n",
                      stderr);
                return 2;
            }
            filter = argv[++i];
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "slang: unknown option for test: %s\n", argv[i]);
            return 2;
        } else {
            target = argv[i];
        }
    }

    char treal[PATH_MAX];
    if (!realpath(target, treal)) {
        fprintf(stderr, "slang: cannot find '%s'\n", target);
        return 2;
    }
    struct stat st;
    if (stat(treal, &st) == 0 && S_ISREG(st.st_mode)) {
        char *slash = strrchr(treal, '/');
        if (slash)
            *slash = '\0';
    }

    DIR *d = opendir(treal);
    if (!d) {
        fprintf(stderr, "slang: cannot open '%s'\n", treal);
        return 2;
    }
    char **files = NULL;
    int nfiles = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ends_with(ent->d_name, "_test.sl") && strlen(ent->d_name) > 8) {
            files = (char **)xrealloc(files, (nfiles + 1) * sizeof(char *));
            files[nfiles++] = xstrdup(ent->d_name);
        }
    }
    closedir(d);
    if (nfiles == 0) {
        printf("no test files (*_test.sl) in %s\n", treal);
        return 0;
    }
    for (int i = 0; i < nfiles; i++)          /* stable, readable order */
        for (int j = i + 1; j < nfiles; j++)
            if (strcmp(files[i], files[j]) > 0) {
                char *t = files[i];
                files[i] = files[j];
                files[j] = t;
            }

    char **tests = NULL;
    int ntests = 0, nfound = 0;
    for (int i = 0; i < nfiles; i++) {
        char fpath[PATH_MAX];
        snprintf(fpath, sizeof(fpath), "%s/%s", treal, files[i]);
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
        Program *prog = parse_program(toks, tcount);
        for (int k = 0; k < prog->nfuncs; k++) {
            FuncDecl *f = prog->funcs[k];
            if (strncmp(f->name, "test_", 5))
                continue;
            /* A test takes nothing and returns nothing: anything else was
               meant as a helper, and silently skipping it would make a
               typo'd test pass by never running. */
            if (f->nparams != 0 || f->ret_type) {
                fprintf(stderr,
                        "slang: %s:%d: test function '%s' must take no "
                        "parameters and return nothing\n",
                        files[i], f->line, f->name);
                return 2;
            }
            nfound++;
            if (filter && !strstr(f->name, filter))
                continue;
            tests = (char **)xrealloc(tests, (ntests + 1) * sizeof(char *));
            tests[ntests++] = xstrdup(f->name);
        }
    }
    if (nfound == 0) {
        printf("no test_ functions in the *_test.sl files of %s\n", treal);
        return 0;
    }
    if (ntests == 0) {
        printf("no tests match \"%s\" (%d test%s in %s)\n", filter, nfound,
               nfound == 1 ? "" : "s", treal);
        return 0;
    }

    const char *tmp = getenv("TMPDIR");
    char tmpl[PATH_MAX];
    snprintf(tmpl, sizeof(tmpl), "%s/slangtest_XXXXXX",
             tmp && *tmp ? tmp : "/tmp");
    size_t tl = strlen(tmpl);
    if (tl > 16 && tmpl[tl - 17] == '/' && tmpl[tl - 18] == '/')
        memmove(tmpl + tl - 17, tmpl + tl - 16, 17);   /* TMPDIR ending in '/' */
    if (!mkdtemp(tmpl)) {
        fprintf(stderr, "slang: cannot create a temporary directory\n");
        return 2;
    }
    char tmpreal[PATH_MAX];
    if (!realpath(tmpl, tmpreal)) {
        fprintf(stderr, "slang: cannot resolve %s\n", tmpl);
        return 2;
    }

    StrBuf r;
    sb_init(&r);
    sb_append(&r, "import \"time\";\n");
    sb_append(&r, xasprintf("import \"%s\" as sltest_pkg;\n\n",
                            relative_path(tmpreal, treal)));
    sb_append(&r,
        "fn sltest_ms(d: duration) -> str {\n"
        "    let us = d / 1000;\n"
        "    if us < 1000 {\n"
        "        return to_str(us) + \"us\";\n"
        "    }\n"
        "    return to_str(us / 1000) + \"ms\";\n"
        "}\n\n"
        "fn sltest_report(name: str, r: result[bool, str], d: duration) -> int {\n"
        "    guard let _passed = r else let e = err_of(r) {\n"
        "        println(\"FAIL \" + name + \" (\" + sltest_ms(d) + \")\");\n"
        "        println(\"     \" + e);\n"
        "        return 1;\n"
        "    }\n"
        "    println(\"ok   \" + name + \" (\" + sltest_ms(d) + \")\");\n"
        "    return 0;\n"
        "}\n\n");
    for (int i = 0; i < ntests; i++)
        sb_append(&r, xasprintf("fn sltest_run_%d() -> bool {\n"
                                "    sltest_pkg.%s();\n"
                                "    return true;\n"
                                "}\n\n", i, tests[i]));
    sb_append(&r, "let sltest_failed = 0;\nlet sltest_all = time.mono();\n");
    for (int i = 0; i < ntests; i++)
        sb_append(&r, xasprintf(
            "let sltest_t%d = time.mono();\n"
            "sltest_failed = sltest_failed + sltest_report(\"%s\", "
            "join_wait(spawn sltest_run_%d()), time.mono() - sltest_t%d);\n",
            i, tests[i], i, i));
    sb_append(&r, xasprintf(
        "let sltest_took = sltest_ms(time.mono() - sltest_all);\n"
        "if sltest_failed > 0 {\n"
        "    println(\"FAIL: \" + to_str(sltest_failed) + \" of %d failed (\" + sltest_took + \")\");\n"
        "    exit(1);\n"
        "}\n"
        "println(\"ok: %d passed (\" + sltest_took + \")\");\n",
        ntests, ntests));

    char runner_src[PATH_MAX], runner_bin[PATH_MAX];
    snprintf(runner_src, sizeof(runner_src), "%s/main.sl", tmpreal);
    snprintf(runner_bin, sizeof(runner_bin), "%s/runner", tmpreal);
    write_file(runner_src, r.data, r.len);

    loader_set_test_target(treal);
    setenv("SLANG_TEST_RUNNER", "1", 1);
    int rc = build(runner_src, runner_bin, 0, 0, 1, 0, 0);

    char gen[PATH_MAX];
    snprintf(gen, sizeof(gen), "%s.gen.c", runner_bin);
    if (keep || exists(gen)) {
        /* build keeps generated C only when compiling it failed -- then it
           is worth keeping, and the message above already names it. */
        fprintf(stderr, "slang: runner left in %s for inspection\n", tmpreal);
        return rc;
    }
    unlink(runner_src);
    unlink(runner_bin);
    rmdir(tmpreal);
    return rc;
}

/* The compile pipeline: load, generate C, compile, and optionally run.
 * main() reaches it after parsing flags; `slangc test` reaches it with a
 * generated runner as the input. */
/* ---- frame guards: measure with the C compiler, guard what needs it ----
 *
 * How big a function's C frame is depends on the C compiler, and it can be
 * far more than the generated code suggests: clang gives every call site its
 * own 8-byte spill slot and inlines callees into their caller, so a function
 * with about 250 call sites had a 4,200-byte frame and crashed on the 8KB task
 * stack, while gcc gave the same C a 240-byte one. slangc cannot know that
 * without asking the compiler, and estimating it would be wrong in one
 * direction or the other.
 *
 * So the first compile asks: -Wframe-larger-than=N makes both compilers
 * report the true frame of every function above N bytes (clang at link time
 * under -flto, gcc at compile time with an "In function" line). A slang
 * function on that list is regenerated behind an entry guard
 * (sl_rt_stack_reserve) and the program is compiled again. Programs with no
 * such function -- almost all of them -- take the one compile they always
 * did, and pay nothing at run time. SLANG_FRAME_LIMIT overrides N (the tests
 * use a tiny one to put a guard on nearly every function). */

#define FRAME_LIMIT_DEFAULT 1536
#define FRAME_ROUNDS_MAX 3

static int frame_limit(void) {
    const char *e = getenv("SLANG_FRAME_LIMIT");
    int v = e ? atoi(e) : 0;
    return v > 0 ? v : FRAME_LIMIT_DEFAULT;
}

/* Run `cmd` through the shell with stderr folded into stdout; return its exit
 * status and all of its output. */
static int run_capture(const char *cmd, char **out_text) {
    StrBuf cap;
    sb_init(&cap);
    StrBuf full;
    sb_init(&full);
    sb_append(&full, "LC_ALL=C ");     /* ASCII quotes around names in gcc */
    sb_append(&full, cmd);
    sb_append(&full, " 2>&1");
    FILE *fp = popen(full.data, "r");
    if (!fp) {
        *out_text = xstrdup("");
        return -1;
    }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0)
        sb_append_n(&cap, buf, n);
    int st = pclose(fp);
    *out_text = cap.data ? cap.data : xstrdup("");
    return st;
}

typedef struct {
    char *name;
    int bytes;
} FrameDiag;

/* clang:  ... stack frame size (4200) exceeds limit (1500) in function 'f'
 *         (in 'f' without "function" when it is not the linker reporting)
 * gcc:    file.c: In function 'f':
 *         file.c:9:1: warning: the frame size of 1040 bytes is larger than 800 bytes
 * Returns how many were found. */
static int parse_frame_diags(const char *text, FrameDiag **out) {
    int n = 0, cap = 0;
    FrameDiag *v = NULL;
    char gcc_fn[256] = "";
    const char *p = text;
    while (*p) {
        const char *eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        char *line = (char *)xmalloc(len + 1);
        memcpy(line, p, len);
        line[len] = '\0';
        const char *q;
        if ((q = strstr(line, "In function '")) != NULL) {
            q += strlen("In function '");
            const char *e = strchr(q, '\'');
            if (e && (size_t)(e - q) < sizeof(gcc_fn)) {
                memcpy(gcc_fn, q, (size_t)(e - q));
                gcc_fn[e - q] = '\0';
            }
        } else {
            int bytes = 0;
            char name[256] = "";
            if ((q = strstr(line, "stack frame size (")) != NULL) {
                bytes = atoi(q + strlen("stack frame size ("));
                const char *in = strstr(q, ") in ");
                if (in) {
                    in += strlen(") in ");
                    if (!strncmp(in, "function ", 9))
                        in += 9;
                    if (*in == '\'') {
                        in++;
                        const char *e = strchr(in, '\'');
                        if (e && (size_t)(e - in) < sizeof(name)) {
                            memcpy(name, in, (size_t)(e - in));
                            name[e - in] = '\0';
                        }
                    }
                }
            } else if ((q = strstr(line, "the frame size of ")) != NULL) {
                bytes = atoi(q + strlen("the frame size of "));
                snprintf(name, sizeof(name), "%s", gcc_fn);
            }
            if (bytes > 0 && name[0]) {
                if (n == cap) {
                    cap = cap ? cap * 2 : 8;
                    v = (FrameDiag *)xrealloc(v, sizeof(FrameDiag) * (size_t)cap);
                }
                v[n].name = xstrdup(name);
                v[n].bytes = bytes;
                n++;
            }
        }
        free(line);
        if (!eol)
            break;
        p = eol + 1;
    }
    *out = v;
    return n;
}

/* The compiler's own output with the frame diagnostics removed: every other
 * warning still reaches the user exactly as before. */
static char *strip_frame_diags(const char *text) {
    StrBuf keep;
    sb_init(&keep);
    const char *p = text;
    char *held = NULL; /* an "In function" line waiting to learn what follows */
    int in_diag = 0;   /* inside a frame diagnostic's source/caret lines */
    while (*p) {
        const char *eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        char *line = (char *)xmalloc(len + 2);
        memcpy(line, p, len);
        line[len] = '\n';
        line[len + 1] = '\0';
        int is_frame = strstr(line, "stack frame size (") ||
                       strstr(line, "the frame size of ");
        int is_ctx = strstr(line, "In function '") != NULL;
        int is_snippet = in_diag && (strchr(line, '|') != NULL);
        if (is_frame) {
            free(held);
            held = NULL;
            in_diag = 1;
        } else if (is_snippet) {
            /* source or caret line of a frame diagnostic: dropped */
        } else if (is_ctx) {
            free(held);
            held = line;
            line = NULL;
            in_diag = 0;
        } else {
            if (held) {
                sb_append(&keep, held);
                free(held);
                held = NULL;
            }
            in_diag = 0;
            sb_append(&keep, line);
        }
        free(line);
        if (!eol)
            break;
        p = eol + 1;
    }
    if (held) {
        sb_append(&keep, held);
        free(held);
    }
    return keep.data ? keep.data : xstrdup("");
}

/* True if `name` is the C name of a slang function this build emitted; a
 * guarded function's body is reported as NAME__body. `*base` gets the
 * function's own name. */
static int is_slang_symbol(const char *name, char *base, size_t cap) {
    snprintf(base, cap, "%s", name);
    size_t l = strlen(base);
    if (l > 6 && !strcmp(base + l - 6, "__body"))
        base[l - 6] = '\0';
    int n = 0;
    const char *const *syms = codegen_function_symbols(&n);
    for (int i = 0; i < n; i++)
        if (!strcmp(syms[i], base))
            return 1;
    return 0;
}

static int build(const char *input, const char *outname, int emit_c,
                 int keep_c, int run, int want_liveness_dump,
                 int want_mir_dump) {
    /* ---- frontend: load the main package and all imports ---- */
    PkgList pkgs;
    int main_index = load_packages(input, &pkgs);

    if (want_mir_dump) {
        dump_mir(pkgs.items, pkgs.count, main_index, stdout);
        return 0;
    }

    if (want_liveness_dump) {
        /* Tier 10's liveness analysis, fully decoupled from the real
         * compile pipeline: never calls codegen_program, never emits
         * C. See src/codegen/liveness.c. */
        dump_liveness(pkgs.items, pkgs.count, main_index, stdout);
        return 0;
    }

    StrBuf out;
    sb_init(&out);
    int want_tls = 0;
    int want_crypto = 0;
    int want_sql = 0;
    int want_compress = 0;
    codegen_program(pkgs.items, pkgs.count, main_index, &out, &want_tls,
                    &want_crypto, &want_sql, &want_compress);

    /* ---- output ---- */
    char *stem = derive_stem(input);
    if (!outname)
        outname = stem;

    char gen_path[1024];
    snprintf(gen_path, sizeof(gen_path), "%s.gen.c", outname);
    write_file(gen_path, out.data, out.len);

    if (emit_c) {
        fputs("wrote ", stdout);
        fputs(gen_path, stdout);
        fputc(10, stdout);
        return 0;
    }

    /* ---- backend: invoke the system C compiler ----
     * Collector and scheduler live in runtime/ and are spliced into
     * the generated C; compiled programs do not link libgc. */

    /* net.tls_* needs OpenSSL, and crypto does too -- located only when
     * the program actually uses it. See find_openssl. */
    char tlsflags[1024] = "-lssl -lcrypto";
    const char *openssl_source = "";
    if (want_tls || want_crypto)
        openssl_source = find_openssl(tlsflags, sizeof(tlsflags));

    int nlinks = 0;
    char **link_libs = collect_link_libs(&pkgs, &nlinks);

    StrBuf cmd;
    sb_init(&cmd);
    /* -O3 -flto on the generated C. Green-thread TLS still forbids
       caching sl_rt_current_task (or any _Thread_local) across a park
       or preemption: the address is OS-thread affine, the task is not.
       Reads go through SL_RT_TLS_CUR. */
    sb_append(&cmd, "cc -O3 -flto ");
    sb_append(&cmd, xasprintf("-Wframe-larger-than=%d ", frame_limit()));
    sb_append(&cmd, gen_path);
    sb_append(&cmd, " -o ");
    sb_append(&cmd, outname);
    sb_append(&cmd, " -lpthread"); /* 'spawn' always links against pthreads,
                                      and now so does the collector itself
                                      (thread registry, mutex, condvar-free
                                      spin/yield) */
    if (want_tls || want_crypto) {
        sb_append(&cmd, " ");
        sb_append(&cmd, tlsflags);
    }
    if (want_sql)
        sb_append(&cmd, " -lsqlite3"); /* the 'sql' native package;
                                          resolves on default cc paths */
    if (want_compress)
        sb_append(&cmd, " -lz"); /* the 'compress' native package; zlib
                                    ships with every supported platform */
    for (int i = 0; i < nlinks; i++) {
        sb_append(&cmd, " -l");
        sb_append(&cmd, link_libs[i]);
    }
    /* Compile, and if the compiler reports a slang function with a large
     * frame, regenerate it behind an entry guard and compile again. */
    int status = 0;
    char *cc_out = NULL;
    const char **guard_syms = NULL;
    int *guard_frames = NULL;
    int nguard = 0;
    for (int round = 0;; round++) {
        status = run_capture(cmd.data, &cc_out);
        if (status != 0)
            break;
        FrameDiag *diags = NULL;
        int nd = parse_frame_diags(cc_out, &diags);
        int changed = 0;
        for (int i = 0; i < nd; i++) {
            char base[256];
            if (!is_slang_symbol(diags[i].name, base, sizeof(base)))
                continue;
            int at = -1;
            for (int k = 0; k < nguard; k++)
                if (!strcmp(guard_syms[k], base))
                    at = k;
            if (at < 0) {
                guard_syms = (const char **)xrealloc(
                    guard_syms, sizeof(char *) * (size_t)(nguard + 1));
                guard_frames = (int *)xrealloc(
                    guard_frames, sizeof(int) * (size_t)(nguard + 1));
                guard_syms[nguard] = xstrdup(base);
                guard_frames[nguard] = diags[i].bytes;
                nguard++;
                changed = 1;
            } else if (diags[i].bytes > guard_frames[at]) {
                guard_frames[at] = diags[i].bytes;
                changed = 1;
            }
        }
        if (!changed || round >= FRAME_ROUNDS_MAX)
            break;
        /* Fresh AST: codegen canonicalizes types in place, so a second run
         * over the same tree is not safe. */
        PkgList pkgs2;
        int main2 = load_packages(input, &pkgs2);
        codegen_set_frame_guards(guard_syms, guard_frames, nguard);
        StrBuf out2;
        sb_init(&out2);
        int t2 = 0, c2 = 0, s2 = 0, z2 = 0;
        codegen_program(pkgs2.items, pkgs2.count, main2, &out2, &t2, &c2, &s2,
                        &z2);
        write_file(gen_path, out2.data, out2.len);
    }
    if (status == 0) {
        /* Every compiler message except the frame report, unchanged. */
        char *rest = strip_frame_diags(cc_out);
        if (rest[0])
            fputs(rest, stderr);
    } else {
        fputs(cc_out, stderr);
    }
    if (status != 0) {
        fputs("slang: C compilation failed; generated code kept at ", stderr);
        fputs(gen_path, stderr);
        fputc(10, stderr);
        if ((want_tls || want_crypto) && !openssl_source)
            /* Worded as a condition, not a diagnosis: slangc could not
               locate OpenSSL, but the compile may have failed for another
               reason, or found headers through a path slangc cannot see. */
            fputs("slang: note: this program uses TLS or crypto, and slangc "
                  "could not locate OpenSSL.\n"
                  "       If the error above is about openssl/ headers, install "
                  "it (macOS: brew install openssl;\n"
                  "       Debian/Ubuntu: apt install libssl-dev) or set "
                  "OPENSSL_DIR=/path/to/openssl.\n",
                  stderr);
        return 1;
    }

    if (!keep_c)
        remove(gen_path);

    if (run) {
        char rcmd[1100];
        /* a bare name (no '/') needs './' to run without relying on
         * PATH; a name that already contains a path (relative or
         * absolute, e.g. from -o /tmp/foo) must be used as-is */
        snprintf(rcmd, sizeof(rcmd), "%s%s", strchr(outname, '/') ? "" : "./",
                 outname);
        status = system(rcmd);
        /* Pass the program's own outcome through rather than flattening
           every failure to 1: `slangc main.sl --run; echo $?` should say
           what the program said, and a signal death -- SIGPIPE's 141 above
           all -- is the clue a failing test most needs. The shell's 128+N
           convention is used for signals. */
        if (status == -1)
            return 1;
        if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            fprintf(stderr, "slang: program killed by signal %d (%s)\n", sig,
                    strsignal(sig));
            return 128 + sig;
        }
        if (WIFEXITED(status))
            return WEXITSTATUS(status);
        return 1;
    }

    fputs("compiled ", stdout);
    fputs(input, stdout);
    fputs(" -> ", stdout);
    fputs(outname, stdout);
    fputc(10, stdout);
    return 0;
}

int main(int argc, char **argv) {
    const char *input = NULL;
    const char *outname = NULL;
    int emit_c = 0, keep_c = 0, run = 0, want_liveness_dump = 0,
        want_mir_dump = 0;

    if (argc >= 2 && !strcmp(argv[1], "get")) {
        sl_compiler_argv0 = argv[0];
        return cmd_get(argc >= 3 ? argv[2] : NULL);
    }
    if (argc >= 2 && !strcmp(argv[1], "test")) {
        sl_compiler_argv0 = argv[0];
        return cmd_test(argc, argv);
    }
    if (argc >= 2 && !strcmp(argv[1], "new")) {
        sl_compiler_argv0 = argv[0];
        return cmd_new(argc >= 3 ? argv[2] : NULL);
    }
    if (argc >= 2 && (!strcmp(argv[1], "--version") ||
                      !strcmp(argv[1], "-V"))) {
        fputs("slangc " SLANG_VERSION "\n", stdout);
        return 0;
    }

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o")) {
            if (i + 1 >= argc) {
                fputs("slang: -o requires a name", stderr);
                fputc(10, stderr);
                return 1;
            }
            outname = argv[++i];
        } else if (!strcmp(argv[i], "--emit-c")) {
            emit_c = 1;
        } else if (!strcmp(argv[i], "--keep-c")) {
            keep_c = 1;
        } else if (!strcmp(argv[i], "--run")) {
            run = 1;
        } else if (!strcmp(argv[i], "--dump-liveness")) {
            want_liveness_dump = 1;
        } else if (!strcmp(argv[i], "--dump-mir")) {
            want_mir_dump = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            print_usage();
            return 0;
        } else if (argv[i][0] == '-') {
            fputs("slang: unknown option: ", stderr);
            fputs(argv[i], stderr);
            fputc(10, stderr);
            print_usage();
            return 1;
        } else if (!input) {
            input = argv[i];
        } else {
            fputs("slang: multiple input files given", stderr);
            fputc(10, stderr);
            return 1;
        }
    }

    sl_compiler_argv0 = argv[0];

    if (!input) {
        print_usage();
        return 1;
    }

    return build(input, outname, emit_c, keep_c, run, want_liveness_dump,
                 want_mir_dump);
}