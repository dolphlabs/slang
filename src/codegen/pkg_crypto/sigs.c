#include "../internal.h"

const NatSig CRYPTO_SIGS[] = {
    {"crypto", "sha256", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "hmac_sha256", 2, {NA_BYTES, NA_BYTES}, "bytes", 0},
    {"crypto", "rand", 1, {NA_INT}, "result[bytes,str]", 0},
    {"crypto", "sha1", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "md5", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "pbkdf2_sha256", 4, {NA_BYTES, NA_BYTES, NA_I64, NA_I64},
     "result[bytes,str]", 0},
    {"crypto", "argon2id_raw", 6,
     {NA_BYTES, NA_BYTES, NA_I64, NA_I64, NA_I64, NA_I64},
     "result[bytes,str]", 0},
    {"crypto", "argon2id_verify", 6,
     {NA_BYTES, NA_BYTES, NA_BYTES, NA_I64, NA_I64, NA_I64},
     "result[bool,str]", 0},
    {"crypto", "rsa_verify_sha256", 4,
     {NA_BYTES, NA_BYTES, NA_BYTES, NA_BYTES},
     "result[bool,str]", 0},

    /* SHA-2 beyond 256, and their HMACs (JWS HS384 / HS512) */
    {"crypto", "sha384", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "sha512", 1, {NA_BYTES}, "bytes", 0},
    {"crypto", "hmac_sha384", 2, {NA_BYTES, NA_BYTES}, "bytes", 0},
    {"crypto", "hmac_sha512", 2, {NA_BYTES, NA_BYTES}, "bytes", 0},
    /* RFC 5869: (ikm, salt, info, length) */
    {"crypto", "hkdf_sha256", 4, {NA_BYTES, NA_BYTES, NA_BYTES, NA_I64},
     "result[bytes,str]", 0},
    {"crypto", "hkdf_sha512", 4, {NA_BYTES, NA_BYTES, NA_BYTES, NA_I64},
     "result[bytes,str]", 0},
    {"crypto", "constant_time_eq", 2, {NA_BYTES, NA_BYTES}, "bool", 0},

    /* authenticated encryption. The explicit-nonce forms take (key,
       nonce, data, aad) and produce/consume ciphertext || 16-byte tag;
       seal/open choose the nonce themselves and carry it in front. */
    {"crypto", "aes256gcm_seal", 4, {NA_BYTES, NA_BYTES, NA_BYTES, NA_BYTES},
     "result[bytes,str]", 0},
    {"crypto", "aes256gcm_open", 4, {NA_BYTES, NA_BYTES, NA_BYTES, NA_BYTES},
     "result[bytes,str]", 0},
    {"crypto", "chacha20poly1305_seal", 4,
     {NA_BYTES, NA_BYTES, NA_BYTES, NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "chacha20poly1305_open", 4,
     {NA_BYTES, NA_BYTES, NA_BYTES, NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "seal", 3, {NA_BYTES, NA_BYTES, NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "open", 3, {NA_BYTES, NA_BYTES, NA_BYTES}, "result[bytes,str]", 0},

    /* Ed25519: 32-byte private seed, 32-byte public key, 64-byte signature */
    {"crypto", "ed25519_generate", 0, {0}, "result[bytes,str]", 0},
    {"crypto", "ed25519_public_key", 1, {NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "ed25519_sign", 2, {NA_BYTES, NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "ed25519_verify", 3, {NA_BYTES, NA_BYTES, NA_BYTES},
     "result[bool,str]", 0},
    {"crypto", "ed25519_private_from_pem", 1, {NA_STR}, "result[bytes,str]", 0},
    {"crypto", "ed25519_public_from_pem", 1, {NA_STR}, "result[bytes,str]", 0},

    /* ECDSA P-256 with SHA-256 (JWS ES256): 32-byte private scalar,
       65-byte uncompressed public point, 64-byte r || s signature */
    {"crypto", "ecdsa_p256_generate", 0, {0}, "result[bytes,str]", 0},
    {"crypto", "ecdsa_p256_public_key", 1, {NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "ecdsa_p256_sign_sha256", 2, {NA_BYTES, NA_BYTES},
     "result[bytes,str]", 0},
    {"crypto", "ecdsa_p256_verify_sha256", 3, {NA_BYTES, NA_BYTES, NA_BYTES},
     "result[bool,str]", 0},
    {"crypto", "ecdsa_p256_private_from_pem", 1, {NA_STR}, "result[bytes,str]", 0},
    {"crypto", "ecdsa_p256_public_from_pem", 1, {NA_STR}, "result[bytes,str]", 0},

    /* RSA with SHA-256: keys as PEM; PKCS#1 v1.5 (RS256) and PSS (PS256) */
    {"crypto", "rsa_generate", 1, {NA_I64}, "result[str,str]", 0},
    {"crypto", "rsa_public_n", 1, {NA_STR}, "result[bytes,str]", 0},
    {"crypto", "rsa_public_e", 1, {NA_STR}, "result[bytes,str]", 0},
    {"crypto", "rsa_sign_sha256", 2, {NA_STR, NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "rsa_sign_pss_sha256", 2, {NA_STR, NA_BYTES}, "result[bytes,str]", 0},
    {"crypto", "rsa_verify_pss_sha256", 4,
     {NA_BYTES, NA_BYTES, NA_BYTES, NA_BYTES}, "result[bool,str]", 0},
};

const int CRYPTO_SIGS_LEN = sizeof(CRYPTO_SIGS) / sizeof(CRYPTO_SIGS[0]);

