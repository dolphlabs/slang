/* Signatures for the 'encoding' package -- see native.c's
 * native_check/native_gen for the table-driven dispatch these plug
 * into, and internal.h for the NatSig/NatArgKind types.
 *
 * Everything here is pure computation, so like `regex`, `strings` and
 * `os` -- and unlike crypto (-lcrypto) and sql (-lsqlite3) -- importing
 * `encoding` adds no link flag.
 *
 * WHY THESE LIVE TOGETHER
 *
 * Every one of them answers the same question: how do arbitrary bytes
 * travel through a channel that only carries text? A header value, a
 * URL, a form body and a JSON string are all such channels, and a
 * program that speaks HTTP needs all four in the same breath -- read a
 * form body, percent-decode a field, base64 a credential, hex a digest
 * for the log line. Splitting them into four packages would mean four
 * imports to serve one request.
 *
 * NAMING: every pair is <scheme>_encode / <scheme>_decode, in that
 * order, so the direction is never in question. `hex(x)` would have
 * been shorter and would have read ambiguously at every call site.
 *
 * DIRECTION OF FALLIBILITY: encoding never fails -- any byte string has
 * a hex form -- so the encoders return a bare `str`. Decoding takes
 * input a program did not produce (a query string, a header, a token)
 * and so is fallible everywhere, returning result[_, str] with a
 * message naming what was wrong and where. That asymmetry is the whole
 * shape of this table. */

#include "../internal.h"

const NatSig ENCODING_SIGS[] = {
    /* hex: lowercase out, either case in. The gap this closes is
       visible in tests/crypto/main.sl, which asserts on a SHA-256
       digest byte by DECIMAL value (186, 120, 22, ...) because until
       now a digest could be computed but never displayed or stored. */
    {"encoding", "hex_encode", 1, {NA_BYTES}, "str", 0},
    {"encoding", "hex_decode", 1, {NA_STR}, "result[bytes,str]", 0},

    /* base64, RFC 4648 section 4: +/ alphabet, always padded. This is
       the one HTTP Basic auth and every "binary in a JSON field" use.
       sl_json.c has had an internal implementation since json landed;
       it was never callable from slang. */
    {"encoding", "base64_encode", 1, {NA_BYTES}, "str", 0},
    {"encoding", "base64_decode", 1, {NA_STR}, "result[bytes,str]", 0},

    /* base64url, RFC 4648 section 5: -_ alphabet, padding OMITTED.
       Separate entry points rather than a flag because the two are not
       interchangeable -- a JWT segment fed to base64_decode fails on
       the first '-', and the error should say so rather than being
       papered over by accepting both alphabets everywhere. */
    {"encoding", "base64url_encode", 1, {NA_BYTES}, "str", 0},
    {"encoding", "base64url_decode", 1, {NA_STR}, "result[bytes,str]", 0},

    /* percent-encoding, RFC 3986: space becomes %20, and only
       A-Za-z0-9-._~ pass through. For a path segment or a header. */
    {"encoding", "url_encode", 1, {NA_STR}, "str", 0},
    {"encoding", "url_decode", 1, {NA_STR}, "result[str,str]", 0},

    /* application/x-www-form-urlencoded: identical EXCEPT that space is
       '+'. It is a different encoding, not a dialect -- decoding a form
       body with url_decode leaves literal '+' where spaces belong, and
       that bug is silent, so the two get separate names. */
    {"encoding", "form_encode", 1, {NA_STR}, "str", 0},
    {"encoding", "form_decode", 1, {NA_STR}, "result[str,str]", 0},

    /* query strings. query_get takes the FIRST value for a key and
       form-decodes it; query_keys lists every key in order, duplicates
       included, so a caller who needs the repeats can see them. A map
       return would have had to silently drop one -- the same reason
       os.environ is a list (pkg_os/sigs.c). Both accept a full URL or a
       bare query string, with or without a leading '?'. */
    {"encoding", "query_get", 2, {NA_STR, NA_STR}, "opt[str]", 0},
    {"encoding", "query_keys", 1, {NA_STR}, "[str]", 0},
};

const int ENCODING_SIGS_LEN =
    sizeof(ENCODING_SIGS) / sizeof(ENCODING_SIGS[0]);
