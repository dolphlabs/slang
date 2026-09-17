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
#include "codegen.h"
#include "codegen/liveness.h"
#include "codegen/mir.h"
#include "rtpath.h"
#include "project.h"

#include <ctype.h>
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
          "       slangc --version",
          stderr);
    fputc(10, stderr);
}

static void write_file(const char *path, const char *data, size_t len);

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

int main(int argc, char **argv) {
    const char *input = NULL;
    const char *outname = NULL;
    int emit_c = 0, keep_c = 0, run = 0, want_liveness_dump = 0,
        want_mir_dump = 0;

    if (argc >= 2 && !strcmp(argv[1], "get")) {
        sl_compiler_argv0 = argv[0];
        return cmd_get(argc >= 3 ? argv[2] : NULL);
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
    int status = system(cmd.data);
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