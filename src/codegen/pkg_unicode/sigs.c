/* Signatures for the 'unicode' package -- see native.c's
 * native_check/native_gen for the table-driven dispatch these plug
 * into, and runtime/sl_unicode.c for the implementation.
 *
 * Native for the reason `strings` is: `str` cannot be indexed in slang,
 * so a slang package would copy every string to bytes before reading
 * it. Here the checks read the str in place and allocate nothing, and
 * the transforms return their input itself when it is already in the
 * requested form.
 *
 * Pure libc, so the import adds no link flag. The tables
 * (runtime/sl_unicode_tables.c, about 125 KB of code) are compiled in
 * only when a program imports the package. */

#include "../internal.h"

const NatSig UNICODE_SIGS[] = {
    /* checks: no allocation, no safepoint (native_is_leaf) */
    {"unicode", "valid", 1, {NA_STR}, "bool", 0},
    {"unicode", "valid_bytes", 1, {NA_BYTES}, "bool", 0},
    {"unicode", "count", 1, {NA_STR}, "int", 0},

    /* code points. encode is an opt: a negative value, a surrogate,
       anything past U+10FFFF and U+0000 (which a NUL-terminated str
       cannot hold) have no str. */
    {"unicode", "runes", 1, {NA_STR}, "[int]", 0},
    {"unicode", "encode", 1, {NA_INT}, "opt[str]", 0},
    {"unicode", "truncate", 2, {NA_STR, NA_INT}, "str", 0},

    /* case-insensitive comparison: full case folding (CaseFolding.txt
       C + F), and the canonical caseless match of Unicode D145 */
    {"unicode", "fold", 1, {NA_STR}, "str", 0},
    {"unicode", "equal_fold", 2, {NA_STR, NA_STR}, "bool", 0},

    /* canonical normalisation (UAX #15) */
    {"unicode", "nfc", 1, {NA_STR}, "str", 0},
    {"unicode", "nfd", 1, {NA_STR}, "str", 0},
    {"unicode", "is_nfc", 1, {NA_STR}, "bool", 0},
};

const int UNICODE_SIGS_LEN = sizeof(UNICODE_SIGS) / sizeof(UNICODE_SIGS[0]);
