/* Signatures for the 'strings' package -- see native.c's
 * native_check/native_gen for the table-driven dispatch these plug
 * into, and internal.h for the NatSig/NatArgKind types.
 *
 * Why this is native rather than a slang source package: `str` supports
 * len, +, == and nothing else -- it cannot be indexed or sliced -- so
 * none of this can be written in slang without converting to `bytes`
 * and back on every call. byteutil already covers the bytes side; this
 * covers `str` directly, with no round trip.
 *
 * Everything here is pure libc, so unlike crypto and sql the `strings`
 * import adds no link flag.
 *
 * Indices are BYTE offsets, and the ASCII case operations only touch
 * A-Z / a-z. slang's `str` is UTF-8 bytes (see the README's Types
 * table); pretending otherwise would mean shipping a Unicode table and
 * a normalisation policy, which is a different project. Callers working
 * in other scripts should treat these as byte operations, because that
 * is what they are. */

#include "../internal.h"

const NatSig STRINGS_SIGS[] = {
    /* search. find returns a byte offset, or -1 -- the same convention
       byteutil.find uses, so the two read alike. */
    {"strings", "find", 2, {NA_STR, NA_STR}, "int", 0},
    {"strings", "rfind", 2, {NA_STR, NA_STR}, "int", 0},
    {"strings", "contains", 2, {NA_STR, NA_STR}, "bool", 0},
    {"strings", "has_prefix", 2, {NA_STR, NA_STR}, "bool", 0},
    {"strings", "has_suffix", 2, {NA_STR, NA_STR}, "bool", 0},
    {"strings", "count", 2, {NA_STR, NA_STR}, "int", 0},

    /* trimming. trim removes ASCII space, tab, CR and LF -- the set
       that shows up at the ends of header lines and config values. */
    {"strings", "trim", 1, {NA_STR}, "str", 0},
    {"strings", "trim_start", 1, {NA_STR}, "str", 0},
    {"strings", "trim_end", 1, {NA_STR}, "str", 0},

    /* case: ASCII only, deliberately. See the header comment. */
    {"strings", "to_upper", 1, {NA_STR}, "str", 0},
    {"strings", "to_lower", 1, {NA_STR}, "str", 0},

    /* shaping */
    {"strings", "slice", 3, {NA_STR, NA_I64, NA_I64}, "str", 0},
    {"strings", "repeat", 2, {NA_STR, NA_I64}, "str", 0},
    {"strings", "replace", 3, {NA_STR, NA_STR, NA_STR}, "str", 0},

    /* split/join are inverses and belong together: splitting a config
       value and putting it back together is one round trip, not two
       unrelated operations. */
    {"strings", "split", 2, {NA_STR, NA_STR}, "[str]", 0},
    {"strings", "join", 2, {NA_ARR_STR, NA_STR}, "str", 0},
    /* The bytes counterpart. Concatenating bytes with `+` copies both
       sides, so assembling n pieces that way costs O(n^2); this sizes
       the result once and copies each piece once. */
    {"strings", "join_bytes", 2, {NA_ARR_BYTES, NA_BYTES}, "bytes", 0},

    /* the shortest text that parses back to exactly this float.
       to_str uses %g, six significant digits, which is right for
       printing and wrong for anything that must round-trip. */
    {"strings", "from_float", 1, {NA_F64}, "str", 0},
};

const int STRINGS_SIGS_LEN = sizeof(STRINGS_SIGS) / sizeof(STRINGS_SIGS[0]);
