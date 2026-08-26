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
    {"net", "close", 1, {NA_INT}, NULL, 0},
    {"net", "nonblock", 1, {NA_INT}, "result[bool,str]", 0},
    {"net", "tls_server_ctx", 2, {NA_STR, NA_STR}, "result[rawptr,str]", 1},
    {"net", "tls_client_ctx", 1, {NA_STR}, "result[rawptr,str]", 1},
    {"net", "tls_accept", 2, {NA_INT, NA_RAWPTR}, "result[rawptr,str]", 1},
    {"net", "tls_dial", 3, {NA_STR, NA_INT, NA_RAWPTR}, "result[rawptr,str]",
     1},
    {"net", "tls_send", 2, {NA_RAWPTR, NA_BYTES}, "result[i32,str]", 1},
    {"net", "tls_recv", 2, {NA_RAWPTR, NA_INT}, "result[bytes,str]", 1},
    {"net", "tls_close", 1, {NA_RAWPTR}, NULL, 1},
};

const int NET_SIGS_LEN = sizeof(NET_SIGS) / sizeof(NET_SIGS[0]);
