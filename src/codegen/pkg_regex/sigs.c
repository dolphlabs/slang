/* Signatures for the 'regex' package -- slang's own Thompson NFA
 * (runtime/sl_regex.c), no external library, so unlike crypto/sql
 * this package adds no link flag at all.
 *
 * compile returns an opaque rawptr in a result[rawptr, str] carrying
 * a descriptive parse error, matching sl_sql.c's visibility story.
 * find returns byte offsets as [int] (empty == no match) so the GC
 * owns the result and there is no match handle to leak. Every
 * subject is matched with an explicit length, so bytes containing
 * NUL match correctly rather than being cut short. */

#include "../internal.h"

const NatSig REGEX_SIGS[] = {
    {"regex", "compile", 1, {NA_STR}, "result[rawptr,str]", 0},
    {"regex", "free", 1, {NA_RAWPTR}, NULL, 0},
    {"regex", "groups", 1, {NA_RAWPTR}, "int", 0},

    {"regex", "is_match", 2, {NA_RAWPTR, NA_STR}, "bool", 0},
    {"regex", "is_match_bytes", 2, {NA_RAWPTR, NA_BYTES}, "bool", 0},

    {"regex", "find", 2, {NA_RAWPTR, NA_STR}, "[int]", 0},
    {"regex", "find_at", 3, {NA_RAWPTR, NA_STR, NA_I64}, "[int]", 0},
    {"regex", "find_bytes", 2, {NA_RAWPTR, NA_BYTES}, "[int]", 0},
    {"regex", "find_bytes_at", 3, {NA_RAWPTR, NA_BYTES, NA_I64}, "[int]", 0},
};

const int REGEX_SIGS_LEN = sizeof(REGEX_SIGS) / sizeof(REGEX_SIGS[0]);
