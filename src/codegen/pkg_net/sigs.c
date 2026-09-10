/* Signatures for the 'net' package's native functions (including
 * net.tls_*) -- see native.c's native_check/native_gen for the
 * table-driven dispatch these plug into, and internal.h for the
 * NatSig/NatArgKind types. is_tls entries gate TLS_RUNTIME
 * (runtime_tls.c) plus the -lssl/-lcrypto link flags. */

#include "../internal.h"

const NatSig NET_SIGS[] = {
    {"net", "listen", 1, {NA_INT}, "result[i32,str]", 0},
    {"net", "port", 1, {NA_INT}, "result[i32,str]", 0},
    {"net", "accept", 1, {NA_INT}, "result[i32,str]", 0},
    {"net", "dial", 2, {NA_STR, NA_INT}, "result[i32,str]", 0},
    {"net", "send", 2, {NA_INT, NA_BYTES}, "result[i32,str]", 0},
    {"net", "recv", 2, {NA_INT, NA_INT}, "result[bytes,str]", 0},
    /* Deadline-bounded variants. Same result type as the plain calls,
     * with one reserved error string: exactly "timeout" when the
     * deadline passed with the operation incomplete. Without these a
     * server has no defence against a peer that opens a connection and
     * then neither sends nor reads -- the task parks on the reactor
     * forever, holding its stack and its GC roots. */
    {"net", "recv_until", 3, {NA_INT, NA_INT, NA_UNTIL}, "result[bytes,str]", 0},
    {"net", "send_until", 3, {NA_INT, NA_BYTES, NA_UNTIL}, "result[i32,str]", 0},
    {"net", "close", 1, {NA_INT}, NULL, 0},
    {"net", "nonblock", 1, {NA_INT}, "result[bool,str]", 0},
    {"net", "tls_server_ctx", 2, {NA_STR, NA_STR}, "result[rawptr,str]", 1},
    {"net", "tls_client_ctx", 1, {NA_STR}, "result[rawptr,str]", 1},
    {"net", "tls_accept", 2, {NA_INT, NA_RAWPTR}, "result[rawptr,str]", 1},
    {"net", "tls_dial", 3, {NA_STR, NA_INT, NA_RAWPTR}, "result[rawptr,str]",
     1},
    {"net", "tls_send", 2, {NA_RAWPTR, NA_BYTES}, "result[i32,str]", 1},
    {"net", "tls_recv", 2, {NA_RAWPTR, NA_INT}, "result[bytes,str]", 1},
    {"net", "tls_recv_until", 3, {NA_RAWPTR, NA_INT, NA_UNTIL},
     "result[bytes,str]", 1},
    {"net", "tls_send_until", 3, {NA_RAWPTR, NA_BYTES, NA_UNTIL},
     "result[i32,str]", 1},
    {"net", "tls_close", 1, {NA_RAWPTR}, NULL, 1},
    {"net", "tls_ctx_require_client", 2, {NA_RAWPTR, NA_STR}, "result[bool,str]", 1},
    {"net", "tls_ctx_use_cert", 3, {NA_RAWPTR, NA_STR, NA_STR}, "result[bool,str]", 1},
    {"net", "tls_ctx_add_sni", 4, {NA_RAWPTR, NA_STR, NA_STR, NA_STR},
     "result[bool,str]", 1},
    /* ALPN: negotiate h2 vs http/1.1 in the handshake (RFC 7301) */
    {"net", "tls_ctx_alpn", 2, {NA_RAWPTR, NA_STR}, "result[bool,str]", 1},
    {"net", "tls_alpn", 1, {NA_RAWPTR}, "str", 1},
};

const int NET_SIGS_LEN = sizeof(NET_SIGS) / sizeof(NET_SIGS[0]);
