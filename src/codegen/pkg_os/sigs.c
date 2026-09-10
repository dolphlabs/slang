/* Signatures for the 'os' package's native functions -- see native.c's
 * native_check/native_gen for the table-driven dispatch these plug
 * into, and internal.h for the NatSig/NatArgKind types.
 *
 * The fs/os boundary: `fs` owns open file HANDLES and their contents
 * (open/create/read/write/close). `os` owns everything you can ask or
 * do about a path WITHOUT opening it, plus the environment and the
 * process itself. fs.mkdir predates that split and stays where it is
 * rather than breaking existing programs.
 *
 * Nothing here needs a link flag: it is all libc, so unlike crypto and
 * sql the `os` import adds no dependency. */

#include "../internal.h"

const NatSig OS_SIGS[] = {
    /* environment. proc.getenv already reads one variable and stays
       there; these are the operations proc has no answer for. */
    {"os", "setenv", 2, {NA_STR, NA_STR}, "result[bool,str]", 0},
    {"os", "unsetenv", 1, {NA_STR}, "result[bool,str]", 0},
    {"os", "environ", 0, {0}, "[str]", 0},

    /* the process itself */
    {"os", "pid", 0, {0}, "int", 0},
    {"os", "hostname", 0, {0}, "result[str,str]", 0},
    {"os", "tmpdir", 0, {0}, "str", 0},

    /* path metadata. The three predicates answer "can I" questions and
       cannot fail in a way a caller can act on -- a missing path and an
       unreadable parent are both "no" -- so they are bare bools. The
       two accessors return a value that has to come from somewhere, so
       they carry the errno text. */
    {"os", "exists", 1, {NA_STR}, "bool", 0},
    {"os", "is_dir", 1, {NA_STR}, "bool", 0},
    {"os", "is_file", 1, {NA_STR}, "bool", 0},
    {"os", "size", 1, {NA_STR}, "result[int,str]", 0},
    {"os", "mtime", 1, {NA_STR}, "result[int,str]", 0},

    /* directories and the namespace */
    {"os", "read_dir", 1, {NA_STR}, "result[[str],str]", 0},
    {"os", "remove", 1, {NA_STR}, "result[bool,str]", 0},
    {"os", "rename", 2, {NA_STR, NA_STR}, "result[bool,str]", 0},
};

const int OS_SIGS_LEN = sizeof(OS_SIGS) / sizeof(OS_SIGS[0]);
