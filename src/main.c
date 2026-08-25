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
 */

#include "common.h"
#include "loader.h"
#include "codegen.h"

static void print_usage(void) {
    fputs("usage: slangc <file.sl> [-o <name>] [--emit-c] [--keep-c] [--run]",
          stderr);
    fputc(10, stderr);
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

int main(int argc, char **argv) {
    const char *input = NULL;
    const char *outname = NULL;
    int emit_c = 0, keep_c = 0, run = 0;

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

    if (!input) {
        print_usage();
        return 1;
    }

    /* ---- frontend: load the main package and all imports ---- */
    PkgList pkgs;
    int main_index = load_packages(input, &pkgs);

    StrBuf out;
    sb_init(&out);
    codegen_program(pkgs.items, pkgs.count, main_index, &out);

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
     * Resolve Boehm GC flags via pkg-config; fall back to plain
     * -lgc (works when the library is on the default search path). */
    char gcflags[1024] = "-lgc";
    FILE *pc = popen("pkg-config --cflags --libs bdw-gc 2>/dev/null", "r");
    if (pc) {
        if (fgets(gcflags, sizeof(gcflags), pc)) {
            size_t n = strlen(gcflags);
            while (n && (gcflags[n - 1] == 10 || gcflags[n - 1] == 13))
                gcflags[--n] = '\0';
            if (n == 0)
                snprintf(gcflags, sizeof(gcflags), "-lgc");
        } else {
            snprintf(gcflags, sizeof(gcflags), "-lgc");
        }
        pclose(pc);
    }

    char cmd[2048];
    snprintf(cmd, sizeof(cmd), "cc %s -o %s %s", gen_path, outname,
             gcflags);
    int status = system(cmd);
    if (status != 0) {
        fputs("slang: C compilation failed; generated code kept at ", stderr);
        fputs(gen_path, stderr);
        fputc(10, stderr);
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
        return status == 0 ? 0 : 1;
    }

    fputs("compiled ", stdout);
    fputs(input, stdout);
    fputs(" -> ", stdout);
    fputs(outname, stdout);
    fputc(10, stdout);
    return 0;
}