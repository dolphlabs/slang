/* Signatures for the 'compress' package -- see native.c's
 * native_check/native_gen for the table-driven dispatch these plug
 * into, and internal.h for the NatSig/NatArgKind types.
 *
 * Backed by zlib, linked as -lz and added only when a program imports
 * `compress` -- the same gating crypto (-lcrypto) and sql (-lsqlite3)
 * use.
 *
 * WHY ZLIB RATHER THAN OUR OWN, when `regex` went the other way
 *
 * regex was written in-house for a reason that does not apply here: a
 * backtracking engine has a catastrophic input class, and being immune
 * to it by construction was the whole point. DEFLATE has no equivalent
 * argument. What it does have is thirty years of hostile input and a
 * reference implementation on every machine slang targets. A hand-
 * written inflate would be a memory-safety surface with no upside --
 * every bug in one is a buffer overrun driven by attacker-controlled
 * input, which is the worst trade in this codebase.
 *
 * THE THREE FORMATS, AND WHY ALL THREE ARE HERE
 *
 * They are the same compressed bits under different headers, and HTTP
 * manages to need all three:
 *
 *   gzip    RFC 1952. Content-Encoding: gzip. What servers actually
 *           send, and the only one worth generating.
 *   zlib    RFC 1950. What the "deflate" content-coding is SUPPOSED to
 *           mean, and what most servers sending it produce.
 *   raw     RFC 1951, no header at all. What the remaining servers
 *           sending "deflate" produce, in violation of RFC 9110 --
 *           which is why inflate_raw exists rather than being a
 *           purist's omission.
 *
 * DECOMPRESSION TAKES A MANDATORY OUTPUT LIMIT
 *
 * Every decompressing entry point takes max_out, and it is a required
 * argument rather than an optional one with a generous default. The
 * ratio is unbounded: a few hundred kilobytes of gzip expands to
 * gigabytes of zeroes, so a program that decompresses anything it did
 * not itself produce -- an HTTP response, an upload, a stored blob --
 * is one hostile input away from the OOM killer. Making the ceiling a
 * parameter forces the caller to have an answer. A default would be a
 * number nobody chose, applied to every call site that never thought
 * about it. */

#include "../internal.h"

const NatSig COMPRESS_SIGS[] = {
    /* Compression is fallible only through zlib itself (an allocation
       failure, an impossible level), never through its input -- any
       byte string compresses -- but it allocates, so it reports rather
       than aborts. */
    {"compress", "gzip", 1, {NA_BYTES}, "result[bytes,str]", 0},
    {"compress", "gzip_level", 2, {NA_BYTES, NA_I64}, "result[bytes,str]", 0},
    {"compress", "deflate", 1, {NA_BYTES}, "result[bytes,str]", 0},
    /* Raw compression exists so inflate_raw has an inverse to be tested
       against, and because permessage-deflate (RFC 7692) needs it. */
    {"compress", "deflate_raw", 1, {NA_BYTES}, "result[bytes,str]", 0},

    /* max_out is the second argument everywhere, and it is not
       optional. See the header. */
    {"compress", "gunzip", 2, {NA_BYTES, NA_I64}, "result[bytes,str]", 0},
    {"compress", "inflate", 2, {NA_BYTES, NA_I64}, "result[bytes,str]", 0},
    {"compress", "inflate_raw", 2, {NA_BYTES, NA_I64}, "result[bytes,str]", 0},
};

const int COMPRESS_SIGS_LEN =
    sizeof(COMPRESS_SIGS) / sizeof(COMPRESS_SIGS[0]);
