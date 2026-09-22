#include "../internal.h"

const NatSig CRYPTO_SIGS[] = {
    {"crypto", "sha256", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "hmac_sha256", 2, {NA_BYTES, NA_BYTES}, "bytes", 0},
    {"crypto", "rand", 1, {NA_INT}, "result[bytes,str]", 0},
    {"crypto", "sha1", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "md5", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "pbkdf2_sha256", 4, {NA_BYTES, NA_BYTES, NA_I64, NA_I64},
     "result[bytes,str]", 0},
};

const int CRYPTO_SIGS_LEN = sizeof(CRYPTO_SIGS) / sizeof(CRYPTO_SIGS[0]);

