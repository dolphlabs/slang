#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/evp.h>
#include <openssl/core_names.h>
#include <openssl/kdf.h>
#include <openssl/params.h>
#include <openssl/crypto.h>
#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/param_build.h>
#include <openssl/pem.h>
#include <openssl/ec.h>
#include <openssl/rsa.h>
#include <openssl/obj_mac.h>
#include <pthread.h>
#include <errno.h>
#include <stdlib.h>
#if defined(__linux__)
#include <sys/random.h>
#endif

/* OpenSSL loads providers lazily, and on this platform that reaches
 * DSO_load -> dlopen -> dyld, which needs far more stack than a green
 * task starts with. Before task stacks had a guard page this overflowed
 * SILENTLY into whatever heap block sat below -- routinely another
 * task's stack. It only became visible when the guard page turned it
 * into a fault at the instant it happened.
 *
 * Same mechanism sl_tls.c and sl_sql.c already use, with a size chosen
 * for dyld rather than for OpenSSL's own frames. */
#define SL_CRYPTO_STACK() sl_rt_need_stack(SL_TASK_DYLD_STACK_SIZE)

static sl_res_bytes_str *sl_crypto_ok_bytes(sl_bytes *b) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = true;
    r->v = b;
    return r;
}

static sl_res_bytes_str *sl_crypto_err_bytes(const char *msg) {
    sl_res_bytes_str *r = (sl_res_bytes_str *)sl_gc_alloc(
        sizeof(sl_res_bytes_str), sl_gc_trace_sl_res_bytes_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* Ciphers and digests, fetched once: an implicit fetch (EVP_sha512() and
 * friends) is a provider lookup on every call in OpenSSL 3, which costs
 * more than hashing a cookie. */
enum { SL_MD_SHA256, SL_MD_SHA384, SL_MD_SHA512, SL_MD_COUNT };
enum { SL_CIPHER_AES256GCM, SL_CIPHER_CHACHA, SL_CIPHER_COUNT };

static EVP_MD *sl_crypto_mds[SL_MD_COUNT];
static EVP_CIPHER *sl_crypto_ciphers[SL_CIPHER_COUNT];
static pthread_once_t sl_crypto_fetch_once = PTHREAD_ONCE_INIT;

static void sl_crypto_fetch_all(void) {
    sl_crypto_mds[SL_MD_SHA256] = EVP_MD_fetch(NULL, "SHA256", NULL);
    sl_crypto_mds[SL_MD_SHA384] = EVP_MD_fetch(NULL, "SHA384", NULL);
    sl_crypto_mds[SL_MD_SHA512] = EVP_MD_fetch(NULL, "SHA512", NULL);
    sl_crypto_ciphers[SL_CIPHER_AES256GCM] =
        EVP_CIPHER_fetch(NULL, "AES-256-GCM", NULL);
    sl_crypto_ciphers[SL_CIPHER_CHACHA] =
        EVP_CIPHER_fetch(NULL, "ChaCha20-Poly1305", NULL);
}

/* Callers hold the preempt bracket. */
static const EVP_MD *sl_crypto_md(int which) {
    pthread_once(&sl_crypto_fetch_once, sl_crypto_fetch_all);
    return sl_crypto_mds[which];
}

static const EVP_CIPHER *sl_crypto_cipher(int which) {
    pthread_once(&sl_crypto_fetch_once, sl_crypto_fetch_all);
    return sl_crypto_ciphers[which];
}

/* HMAC (RFC 2104) written over the cached digest: H(K ^ opad, H(K ^ ipad,
 * m)). OpenSSL 3's one-shot HMAC() fetches the MAC and the digest by name
 * on every call, which was most of its cost (4.5 us against 2 us for Go
 * on a 64-byte message). Callers hold the preempt bracket. 0 on success. */
static int sl_crypto_hmac_raw(int which, const unsigned char *key, size_t klen,
                              const unsigned char *msg, size_t mlen,
                              unsigned char *out, unsigned int *outlen) {
    const EVP_MD *md = sl_crypto_md(which);
    int block = EVP_MD_get_block_size(md);
    unsigned char k[128], pad[128], inner[EVP_MAX_MD_SIZE];
    unsigned int ilen = 0;
    int ok = 0;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx || block <= 0 || block > (int)sizeof k)
        goto done;
    memset(k, 0, sizeof k);
    if ((int)klen > block) {
        unsigned int hl = 0;
        if (EVP_DigestInit_ex2(ctx, md, NULL) != 1 ||
            EVP_DigestUpdate(ctx, key, klen) != 1 ||
            EVP_DigestFinal_ex(ctx, k, &hl) != 1)
            goto done;
    } else if (klen) {
        memcpy(k, key, klen);
    }
    for (int i = 0; i < block; i++) pad[i] = k[i] ^ 0x36;
    if (EVP_DigestInit_ex2(ctx, md, NULL) != 1 ||
        EVP_DigestUpdate(ctx, pad, (size_t)block) != 1 ||
        (mlen && EVP_DigestUpdate(ctx, msg, mlen) != 1) ||
        EVP_DigestFinal_ex(ctx, inner, &ilen) != 1)
        goto done;
    for (int i = 0; i < block; i++) pad[i] = k[i] ^ 0x5c;
    if (EVP_DigestInit_ex2(ctx, md, NULL) != 1 ||
        EVP_DigestUpdate(ctx, pad, (size_t)block) != 1 ||
        EVP_DigestUpdate(ctx, inner, ilen) != 1 ||
        EVP_DigestFinal_ex(ctx, out, outlen) != 1)
        goto done;
    ok = 1;
done:
    OPENSSL_cleanse(k, sizeof k);
    OPENSSL_cleanse(pad, sizeof pad);
    EVP_MD_CTX_free(ctx);
    return ok ? 0 : -1;
}

static sl_bytes *sl_crypto_hmac(int which, sl_bytes *key, sl_bytes *message) {
    SL_CRYPTO_STACK();
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    sl_rt_preempt_disable();
    int rc = sl_crypto_hmac_raw(which, key->ptr, (size_t)key->len, message->ptr,
                                (size_t)message->len, out, &n);
    sl_rt_preempt_enable();
    if (rc)
        return NULL;
    return sl_bytes_new(out, (long long)n);
}

static sl_bytes *sl_crypto_sha256(sl_bytes *input) {
    SL_CRYPTO_STACK();
    unsigned char hash[SHA256_DIGEST_LENGTH];
    sl_rt_preempt_disable();
    SHA256(input->ptr, (size_t)input->len, hash);
    sl_rt_preempt_enable();
    return sl_bytes_new(hash, SHA256_DIGEST_LENGTH);
}

static sl_bytes *sl_crypto_hmac_sha256(sl_bytes *key, sl_bytes *message) {
    return sl_crypto_hmac(SL_MD_SHA256, key, message);
}

/* The kernel's CSPRNG, straight into `p`: getrandom(2) on Linux,
 * arc4random_buf(3) on macOS and the BSDs. 0 on success. */
static int sl_crypto_os_random(unsigned char *p, size_t n) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    /* arc4random_buf takes libSystem's own lock: a task preempted
     * inside it and resumed on another OS thread would release that
     * lock from the wrong thread, the way a preempted free corrupts the
     * allocator. */
    sl_rt_preempt_disable();
    arc4random_buf(p, n);
    sl_rt_preempt_enable();
    return 0;
#else
    /* getrandom returns at most 32 MiB per call and can be interrupted;
     * flags 0 blocks only until the pool is first seeded, at boot. */
    while (n > 0) {
        ssize_t got = getrandom(p, n, 0);
        if (got < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += got;
        n -= (size_t)got;
    }
    return 0;
#endif
}

/* From the OS, not OpenSSL's RAND_bytes. OpenSSL 3's RAND_bytes had to
 * run under one process-wide mutex -- its lazily built DRBG deadlocked
 * when two threads reached the construction together (the case
 * tests/crypto_rand_concurrent keeps) -- and that mutex plus OpenSSL's
 * own per-call work made crypto.rand(16) about a sixth of a zokor
 * server's CPU, since every request draws an id from it. The kernel's
 * generator is the one RAND_bytes seeds from anyway, needs no lock, and
 * fills the result's buffer directly, so there is no malloc either. */
static sl_res_bytes_str *sl_crypto_rand(long long n) {
    if (n < 0 || n > 1024 * 1024)
        return sl_crypto_err_bytes("invalid size: must be between 0 and 1MB");
    if (n == 0)
        return sl_crypto_ok_bytes(sl_bytes_new(NULL, 0));
    sl_bytes *out = sl_bytes_alloc_uninit(n);
    if (sl_crypto_os_random(out->ptr, (size_t)n) != 0)
        return sl_crypto_err_bytes("the OS random source failed");
    return sl_crypto_ok_bytes(out);
}

/* SHA-1 is broken for collision resistance. It is here for the
 * protocols that still specify it and cannot be changed -- the
 * WebSocket handshake (RFC 6455) hashes the client's key with a fixed
 * GUID, Git object ids, older TOTP -- and must not be used to protect
 * anything new. EVP rather than SHA1(), which OpenSSL 3 deprecates. */
static sl_bytes *sl_crypto_sha1(sl_bytes *input) {
    SL_CRYPTO_STACK();
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    sl_rt_preempt_disable();
    int ok = EVP_Digest(input->ptr, (size_t)input->len, hash, &n, EVP_sha1(),
                        NULL);
    sl_rt_preempt_enable();
    if (!ok)
        return NULL;
    return sl_bytes_new(hash, n);
}

/* MD5 is broken for collision resistance. It is here for the protocols
 * that still specify it -- Postgres md5 authentication, Content-MD5,
 * legacy ETags -- and must not be used to protect anything new. EVP
 * rather than MD5(), which OpenSSL 3 deprecates. */
static sl_bytes *sl_crypto_md5(sl_bytes *input) {
    SL_CRYPTO_STACK();
    unsigned char hash[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    sl_rt_preempt_disable();
    int ok = EVP_Digest(input->ptr, (size_t)input->len, hash, &n, EVP_md5(),
                        NULL);
    sl_rt_preempt_enable();
    if (!ok)
        return NULL;
    return sl_bytes_new(hash, n);
}

/* PBKDF2-HMAC-SHA256 (RFC 8018). The iteration count is often chosen by
 * the OTHER side -- a SCRAM server sends it -- so it is capped: without a
 * cap a hostile server could pin a worker thread for as long as it
 * liked. 10M iterations is several seconds of CPU; real deployments use
 * 4096 (Postgres) to 600000 (OWASP's current guidance for storage). */
#define SL_PBKDF2_MAX_ITER 10000000LL
#define SL_PBKDF2_MAX_LEN 1024LL

static sl_res_bytes_str *sl_crypto_pbkdf2_sha256(sl_bytes *password,
                                                 sl_bytes *salt,
                                                 long long iterations,
                                                 long long keylen) {
    SL_CRYPTO_STACK();
    if (iterations < 1 || iterations > SL_PBKDF2_MAX_ITER)
        return sl_crypto_err_bytes(
            "invalid iterations: must be between 1 and 10000000");
    if (keylen < 1 || keylen > SL_PBKDF2_MAX_LEN)
        return sl_crypto_err_bytes("invalid key length: must be between 1 and 1024");
    unsigned char out[SL_PBKDF2_MAX_LEN];
    sl_rt_preempt_disable();
    int ok = PKCS5_PBKDF2_HMAC((const char *)password->ptr, (int)password->len,
                               salt->ptr, (int)salt->len, (int)iterations,
                               EVP_sha256(), (int)keylen, out);
    sl_rt_preempt_enable();
    if (!ok)
        return sl_crypto_err_bytes("PKCS5_PBKDF2_HMAC failed");
    return sl_crypto_ok_bytes(sl_bytes_new(out, keylen));
}

/* Argon2id's memory and time inputs may come from a stored PHC string.
 * Validate them before entering OpenSSL so an untrusted hash cannot ask
 * one verification to allocate unbounded memory or run unbounded passes. */
#define SL_ARGON2ID_MAX_PASSWORD (1024LL * 1024)
#define SL_ARGON2ID_MAX_MEMORY_KIB 262144LL
#define SL_ARGON2ID_MAX_ITERATIONS 10LL
#define SL_ARGON2ID_MAX_PARALLELISM 4LL
#define SL_ARGON2ID_MIN_SALT 8LL
#define SL_ARGON2ID_MAX_SALT 64LL
#define SL_ARGON2ID_MIN_TAG 16LL
#define SL_ARGON2ID_MAX_TAG 64LL

static sl_res_bool_str *sl_crypto_ok_bool(bool value) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = true;
    r->v = value;
    return r;
}

static sl_res_bool_str *sl_crypto_err_bool(const char *msg) {
    sl_res_bool_str *r = (sl_res_bool_str *)sl_gc_alloc(
        sizeof(sl_res_bool_str), sl_gc_trace_sl_res_bool_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

static const char *sl_crypto_argon2id_validate(sl_bytes *password,
                                               sl_bytes *salt,
                                               long long iterations,
                                               long long memory_kib,
                                               long long parallelism,
                                               long long tag_len) {
    if (password->len > SL_ARGON2ID_MAX_PASSWORD)
        return "Argon2id password exceeds the 1 MiB limit";
    if (salt->len < SL_ARGON2ID_MIN_SALT ||
        salt->len > SL_ARGON2ID_MAX_SALT)
        return "Argon2id salt must contain 8 to 64 bytes";
    if (parallelism < 1 || parallelism > SL_ARGON2ID_MAX_PARALLELISM)
        return "Argon2id parallelism must be between 1 and 4";
    if (iterations < 1 || iterations > SL_ARGON2ID_MAX_ITERATIONS)
        return "Argon2id iterations must be between 1 and 10";
    if (memory_kib < 8 * parallelism ||
        memory_kib > SL_ARGON2ID_MAX_MEMORY_KIB)
        return "Argon2id memory must be between 8 * parallelism and 262144 KiB";
    if (tag_len < SL_ARGON2ID_MIN_TAG || tag_len > SL_ARGON2ID_MAX_TAG)
        return "Argon2id tag must contain 16 to 64 bytes";
    return NULL;
}

static EVP_KDF *sl_crypto_argon2id_kdf;
static pthread_once_t sl_crypto_argon2id_once = PTHREAD_ONCE_INIT;

static void sl_crypto_argon2id_load(void) {
    sl_crypto_argon2id_kdf = EVP_KDF_fetch(NULL, "ARGON2ID", NULL);
}

/* OpenSSL added this provider in 3.2. The generic EVP_KDF API is present in
 * OpenSSL 3.0, so older builds still compile and return a useful error when
 * the algorithm fetch is unavailable. One KDF descriptor is shared; each
 * concurrent call owns its context and its bounded work memory.
 *
 * Touches no collected memory and no task state, so it runs equally on a
 * pool worker (inside a preempt bracket) or on a kdf thread. */
static int sl_crypto_argon2id_derive_raw(const unsigned char *password,
                                         size_t password_len,
                                         const unsigned char *salt,
                                         size_t salt_len,
                                         uint32_t iterations,
                                         uint32_t memory_kib,
                                         uint32_t parallelism,
                                         unsigned char *out,
                                         size_t out_len) {
    static const unsigned char empty = 0;
    if (!password)
        password = &empty;

    uint32_t version = 0x13;
    /* Clear password and secret context data as soon as OpenSSL consumes it. */
    uint32_t early_clean = 1;
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_PASSWORD,
                                          (void *)password, password_len),
        OSSL_PARAM_construct_octet_string(OSSL_KDF_PARAM_SALT, (void *)salt,
                                          salt_len),
        OSSL_PARAM_construct_uint32(OSSL_KDF_PARAM_ITER, &iterations),
        OSSL_PARAM_construct_uint32("lanes", &parallelism),
        OSSL_PARAM_construct_uint32("memcost", &memory_kib),
        OSSL_PARAM_construct_uint32("version", &version),
        OSSL_PARAM_construct_uint32("early_clean", &early_clean),
        OSSL_PARAM_construct_end(),
    };

    int once_rc = pthread_once(&sl_crypto_argon2id_once,
                               sl_crypto_argon2id_load);
    if (once_rc != 0 || !sl_crypto_argon2id_kdf)
        return -2;
    EVP_KDF_CTX *ctx = EVP_KDF_CTX_new(sl_crypto_argon2id_kdf);
    if (!ctx)
        return -1;
    int ok = EVP_KDF_derive(ctx, out, out_len, params) == 1;
    EVP_KDF_CTX_free(ctx);
    return ok ? 1 : 0;
}


/* ---- bcrypt and scrypt ---------------------------------------------------
 *
 * For verifying password hashes carried over from other systems (Rails,
 * Laravel and Django store bcrypt; Django also scrypt). New hashes should
 * be Argon2id. OpenSSL has scrypt; it has no bcrypt (and its Blowfish is a
 * deprecated low-level API), so eksblowfish is here. Blowfish's initial
 * state is the hexadecimal fraction of pi, generated rather than typed. */
static const uint32_t sl_bf_init_p[18] = {
    0x243f6a88u, 0x85a308d3u, 0x13198a2eu, 0x03707344u, 0xa4093822u, 0x299f31d0u,
    0x082efa98u, 0xec4e6c89u, 0x452821e6u, 0x38d01377u, 0xbe5466cfu, 0x34e90c6cu,
    0xc0ac29b7u, 0xc97c50ddu, 0x3f84d5b5u, 0xb5470917u, 0x9216d5d9u, 0x8979fb1bu,
};
static const uint32_t sl_bf_init_s[4][256] = {
    {
        0xd1310ba6u, 0x98dfb5acu, 0x2ffd72dbu, 0xd01adfb7u, 0xb8e1afedu, 0x6a267e96u,
        0xba7c9045u, 0xf12c7f99u, 0x24a19947u, 0xb3916cf7u, 0x0801f2e2u, 0x858efc16u,
        0x636920d8u, 0x71574e69u, 0xa458fea3u, 0xf4933d7eu, 0x0d95748fu, 0x728eb658u,
        0x718bcd58u, 0x82154aeeu, 0x7b54a41du, 0xc25a59b5u, 0x9c30d539u, 0x2af26013u,
        0xc5d1b023u, 0x286085f0u, 0xca417918u, 0xb8db38efu, 0x8e79dcb0u, 0x603a180eu,
        0x6c9e0e8bu, 0xb01e8a3eu, 0xd71577c1u, 0xbd314b27u, 0x78af2fdau, 0x55605c60u,
        0xe65525f3u, 0xaa55ab94u, 0x57489862u, 0x63e81440u, 0x55ca396au, 0x2aab10b6u,
        0xb4cc5c34u, 0x1141e8ceu, 0xa15486afu, 0x7c72e993u, 0xb3ee1411u, 0x636fbc2au,
        0x2ba9c55du, 0x741831f6u, 0xce5c3e16u, 0x9b87931eu, 0xafd6ba33u, 0x6c24cf5cu,
        0x7a325381u, 0x28958677u, 0x3b8f4898u, 0x6b4bb9afu, 0xc4bfe81bu, 0x66282193u,
        0x61d809ccu, 0xfb21a991u, 0x487cac60u, 0x5dec8032u, 0xef845d5du, 0xe98575b1u,
        0xdc262302u, 0xeb651b88u, 0x23893e81u, 0xd396acc5u, 0x0f6d6ff3u, 0x83f44239u,
        0x2e0b4482u, 0xa4842004u, 0x69c8f04au, 0x9e1f9b5eu, 0x21c66842u, 0xf6e96c9au,
        0x670c9c61u, 0xabd388f0u, 0x6a51a0d2u, 0xd8542f68u, 0x960fa728u, 0xab5133a3u,
        0x6eef0b6cu, 0x137a3be4u, 0xba3bf050u, 0x7efb2a98u, 0xa1f1651du, 0x39af0176u,
        0x66ca593eu, 0x82430e88u, 0x8cee8619u, 0x456f9fb4u, 0x7d84a5c3u, 0x3b8b5ebeu,
        0xe06f75d8u, 0x85c12073u, 0x401a449fu, 0x56c16aa6u, 0x4ed3aa62u, 0x363f7706u,
        0x1bfedf72u, 0x429b023du, 0x37d0d724u, 0xd00a1248u, 0xdb0fead3u, 0x49f1c09bu,
        0x075372c9u, 0x80991b7bu, 0x25d479d8u, 0xf6e8def7u, 0xe3fe501au, 0xb6794c3bu,
        0x976ce0bdu, 0x04c006bau, 0xc1a94fb6u, 0x409f60c4u, 0x5e5c9ec2u, 0x196a2463u,
        0x68fb6fafu, 0x3e6c53b5u, 0x1339b2ebu, 0x3b52ec6fu, 0x6dfc511fu, 0x9b30952cu,
        0xcc814544u, 0xaf5ebd09u, 0xbee3d004u, 0xde334afdu, 0x660f2807u, 0x192e4bb3u,
        0xc0cba857u, 0x45c8740fu, 0xd20b5f39u, 0xb9d3fbdbu, 0x5579c0bdu, 0x1a60320au,
        0xd6a100c6u, 0x402c7279u, 0x679f25feu, 0xfb1fa3ccu, 0x8ea5e9f8u, 0xdb3222f8u,
        0x3c7516dfu, 0xfd616b15u, 0x2f501ec8u, 0xad0552abu, 0x323db5fau, 0xfd238760u,
        0x53317b48u, 0x3e00df82u, 0x9e5c57bbu, 0xca6f8ca0u, 0x1a87562eu, 0xdf1769dbu,
        0xd542a8f6u, 0x287effc3u, 0xac6732c6u, 0x8c4f5573u, 0x695b27b0u, 0xbbca58c8u,
        0xe1ffa35du, 0xb8f011a0u, 0x10fa3d98u, 0xfd2183b8u, 0x4afcb56cu, 0x2dd1d35bu,
        0x9a53e479u, 0xb6f84565u, 0xd28e49bcu, 0x4bfb9790u, 0xe1ddf2dau, 0xa4cb7e33u,
        0x62fb1341u, 0xcee4c6e8u, 0xef20cadau, 0x36774c01u, 0xd07e9efeu, 0x2bf11fb4u,
        0x95dbda4du, 0xae909198u, 0xeaad8e71u, 0x6b93d5a0u, 0xd08ed1d0u, 0xafc725e0u,
        0x8e3c5b2fu, 0x8e7594b7u, 0x8ff6e2fbu, 0xf2122b64u, 0x8888b812u, 0x900df01cu,
        0x4fad5ea0u, 0x688fc31cu, 0xd1cff191u, 0xb3a8c1adu, 0x2f2f2218u, 0xbe0e1777u,
        0xea752dfeu, 0x8b021fa1u, 0xe5a0cc0fu, 0xb56f74e8u, 0x18acf3d6u, 0xce89e299u,
        0xb4a84fe0u, 0xfd13e0b7u, 0x7cc43b81u, 0xd2ada8d9u, 0x165fa266u, 0x80957705u,
        0x93cc7314u, 0x211a1477u, 0xe6ad2065u, 0x77b5fa86u, 0xc75442f5u, 0xfb9d35cfu,
        0xebcdaf0cu, 0x7b3e89a0u, 0xd6411bd3u, 0xae1e7e49u, 0x00250e2du, 0x2071b35eu,
        0x226800bbu, 0x57b8e0afu, 0x2464369bu, 0xf009b91eu, 0x5563911du, 0x59dfa6aau,
        0x78c14389u, 0xd95a537fu, 0x207d5ba2u, 0x02e5b9c5u, 0x83260376u, 0x6295cfa9u,
        0x11c81968u, 0x4e734a41u, 0xb3472dcau, 0x7b14a94au, 0x1b510052u, 0x9a532915u,
        0xd60f573fu, 0xbc9bc6e4u, 0x2b60a476u, 0x81e67400u, 0x08ba6fb5u, 0x571be91fu,
        0xf296ec6bu, 0x2a0dd915u, 0xb6636521u, 0xe7b9f9b6u, 0xff34052eu, 0xc5855664u,
        0x53b02d5du, 0xa99f8fa1u, 0x08ba4799u, 0x6e85076au,
    },
    {
        0x4b7a70e9u, 0xb5b32944u, 0xdb75092eu, 0xc4192623u, 0xad6ea6b0u, 0x49a7df7du,
        0x9cee60b8u, 0x8fedb266u, 0xecaa8c71u, 0x699a17ffu, 0x5664526cu, 0xc2b19ee1u,
        0x193602a5u, 0x75094c29u, 0xa0591340u, 0xe4183a3eu, 0x3f54989au, 0x5b429d65u,
        0x6b8fe4d6u, 0x99f73fd6u, 0xa1d29c07u, 0xefe830f5u, 0x4d2d38e6u, 0xf0255dc1u,
        0x4cdd2086u, 0x8470eb26u, 0x6382e9c6u, 0x021ecc5eu, 0x09686b3fu, 0x3ebaefc9u,
        0x3c971814u, 0x6b6a70a1u, 0x687f3584u, 0x52a0e286u, 0xb79c5305u, 0xaa500737u,
        0x3e07841cu, 0x7fdeae5cu, 0x8e7d44ecu, 0x5716f2b8u, 0xb03ada37u, 0xf0500c0du,
        0xf01c1f04u, 0x0200b3ffu, 0xae0cf51au, 0x3cb574b2u, 0x25837a58u, 0xdc0921bdu,
        0xd19113f9u, 0x7ca92ff6u, 0x94324773u, 0x22f54701u, 0x3ae5e581u, 0x37c2dadcu,
        0xc8b57634u, 0x9af3dda7u, 0xa9446146u, 0x0fd0030eu, 0xecc8c73eu, 0xa4751e41u,
        0xe238cd99u, 0x3bea0e2fu, 0x3280bba1u, 0x183eb331u, 0x4e548b38u, 0x4f6db908u,
        0x6f420d03u, 0xf60a04bfu, 0x2cb81290u, 0x24977c79u, 0x5679b072u, 0xbcaf89afu,
        0xde9a771fu, 0xd9930810u, 0xb38bae12u, 0xdccf3f2eu, 0x5512721fu, 0x2e6b7124u,
        0x501adde6u, 0x9f84cd87u, 0x7a584718u, 0x7408da17u, 0xbc9f9abcu, 0xe94b7d8cu,
        0xec7aec3au, 0xdb851dfau, 0x63094366u, 0xc464c3d2u, 0xef1c1847u, 0x3215d908u,
        0xdd433b37u, 0x24c2ba16u, 0x12a14d43u, 0x2a65c451u, 0x50940002u, 0x133ae4ddu,
        0x71dff89eu, 0x10314e55u, 0x81ac77d6u, 0x5f11199bu, 0x043556f1u, 0xd7a3c76bu,
        0x3c11183bu, 0x5924a509u, 0xf28fe6edu, 0x97f1fbfau, 0x9ebabf2cu, 0x1e153c6eu,
        0x86e34570u, 0xeae96fb1u, 0x860e5e0au, 0x5a3e2ab3u, 0x771fe71cu, 0x4e3d06fau,
        0x2965dcb9u, 0x99e71d0fu, 0x803e89d6u, 0x5266c825u, 0x2e4cc978u, 0x9c10b36au,
        0xc6150ebau, 0x94e2ea78u, 0xa5fc3c53u, 0x1e0a2df4u, 0xf2f74ea7u, 0x361d2b3du,
        0x1939260fu, 0x19c27960u, 0x5223a708u, 0xf71312b6u, 0xebadfe6eu, 0xeac31f66u,
        0xe3bc4595u, 0xa67bc883u, 0xb17f37d1u, 0x018cff28u, 0xc332ddefu, 0xbe6c5aa5u,
        0x65582185u, 0x68ab9802u, 0xeecea50fu, 0xdb2f953bu, 0x2aef7dadu, 0x5b6e2f84u,
        0x1521b628u, 0x29076170u, 0xecdd4775u, 0x619f1510u, 0x13cca830u, 0xeb61bd96u,
        0x0334fe1eu, 0xaa0363cfu, 0xb5735c90u, 0x4c70a239u, 0xd59e9e0bu, 0xcbaade14u,
        0xeecc86bcu, 0x60622ca7u, 0x9cab5cabu, 0xb2f3846eu, 0x648b1eafu, 0x19bdf0cau,
        0xa02369b9u, 0x655abb50u, 0x40685a32u, 0x3c2ab4b3u, 0x319ee9d5u, 0xc021b8f7u,
        0x9b540b19u, 0x875fa099u, 0x95f7997eu, 0x623d7da8u, 0xf837889au, 0x97e32d77u,
        0x11ed935fu, 0x16681281u, 0x0e358829u, 0xc7e61fd6u, 0x96dedfa1u, 0x7858ba99u,
        0x57f584a5u, 0x1b227263u, 0x9b83c3ffu, 0x1ac24696u, 0xcdb30aebu, 0x532e3054u,
        0x8fd948e4u, 0x6dbc3128u, 0x58ebf2efu, 0x34c6ffeau, 0xfe28ed61u, 0xee7c3c73u,
        0x5d4a14d9u, 0xe864b7e3u, 0x42105d14u, 0x203e13e0u, 0x45eee2b6u, 0xa3aaabeau,
        0xdb6c4f15u, 0xfacb4fd0u, 0xc742f442u, 0xef6abbb5u, 0x654f3b1du, 0x41cd2105u,
        0xd81e799eu, 0x86854dc7u, 0xe44b476au, 0x3d816250u, 0xcf62a1f2u, 0x5b8d2646u,
        0xfc8883a0u, 0xc1c7b6a3u, 0x7f1524c3u, 0x69cb7492u, 0x47848a0bu, 0x5692b285u,
        0x095bbf00u, 0xad19489du, 0x1462b174u, 0x23820e00u, 0x58428d2au, 0x0c55f5eau,
        0x1dadf43eu, 0x233f7061u, 0x3372f092u, 0x8d937e41u, 0xd65fecf1u, 0x6c223bdbu,
        0x7cde3759u, 0xcbee7460u, 0x4085f2a7u, 0xce77326eu, 0xa6078084u, 0x19f8509eu,
        0xe8efd855u, 0x61d99735u, 0xa969a7aau, 0xc50c06c2u, 0x5a04abfcu, 0x800bcadcu,
        0x9e447a2eu, 0xc3453484u, 0xfdd56705u, 0x0e1e9ec9u, 0xdb73dbd3u, 0x105588cdu,
        0x675fda79u, 0xe3674340u, 0xc5c43465u, 0x713e38d8u, 0x3d28f89eu, 0xf16dff20u,
        0x153e21e7u, 0x8fb03d4au, 0xe6e39f2bu, 0xdb83adf7u,
    },
    {
        0xe93d5a68u, 0x948140f7u, 0xf64c261cu, 0x94692934u, 0x411520f7u, 0x7602d4f7u,
        0xbcf46b2eu, 0xd4a20068u, 0xd4082471u, 0x3320f46au, 0x43b7d4b7u, 0x500061afu,
        0x1e39f62eu, 0x97244546u, 0x14214f74u, 0xbf8b8840u, 0x4d95fc1du, 0x96b591afu,
        0x70f4ddd3u, 0x66a02f45u, 0xbfbc09ecu, 0x03bd9785u, 0x7fac6dd0u, 0x31cb8504u,
        0x96eb27b3u, 0x55fd3941u, 0xda2547e6u, 0xabca0a9au, 0x28507825u, 0x530429f4u,
        0x0a2c86dau, 0xe9b66dfbu, 0x68dc1462u, 0xd7486900u, 0x680ec0a4u, 0x27a18deeu,
        0x4f3ffea2u, 0xe887ad8cu, 0xb58ce006u, 0x7af4d6b6u, 0xaace1e7cu, 0xd3375fecu,
        0xce78a399u, 0x406b2a42u, 0x20fe9e35u, 0xd9f385b9u, 0xee39d7abu, 0x3b124e8bu,
        0x1dc9faf7u, 0x4b6d1856u, 0x26a36631u, 0xeae397b2u, 0x3a6efa74u, 0xdd5b4332u,
        0x6841e7f7u, 0xca7820fbu, 0xfb0af54eu, 0xd8feb397u, 0x454056acu, 0xba489527u,
        0x55533a3au, 0x20838d87u, 0xfe6ba9b7u, 0xd096954bu, 0x55a867bcu, 0xa1159a58u,
        0xcca92963u, 0x99e1db33u, 0xa62a4a56u, 0x3f3125f9u, 0x5ef47e1cu, 0x9029317cu,
        0xfdf8e802u, 0x04272f70u, 0x80bb155cu, 0x05282ce3u, 0x95c11548u, 0xe4c66d22u,
        0x48c1133fu, 0xc70f86dcu, 0x07f9c9eeu, 0x41041f0fu, 0x404779a4u, 0x5d886e17u,
        0x325f51ebu, 0xd59bc0d1u, 0xf2bcc18fu, 0x41113564u, 0x257b7834u, 0x602a9c60u,
        0xdff8e8a3u, 0x1f636c1bu, 0x0e12b4c2u, 0x02e1329eu, 0xaf664fd1u, 0xcad18115u,
        0x6b2395e0u, 0x333e92e1u, 0x3b240b62u, 0xeebeb922u, 0x85b2a20eu, 0xe6ba0d99u,
        0xde720c8cu, 0x2da2f728u, 0xd0127845u, 0x95b794fdu, 0x647d0862u, 0xe7ccf5f0u,
        0x5449a36fu, 0x877d48fau, 0xc39dfd27u, 0xf33e8d1eu, 0x0a476341u, 0x992eff74u,
        0x3a6f6eabu, 0xf4f8fd37u, 0xa812dc60u, 0xa1ebddf8u, 0x991be14cu, 0xdb6e6b0du,
        0xc67b5510u, 0x6d672c37u, 0x2765d43bu, 0xdcd0e804u, 0xf1290dc7u, 0xcc00ffa3u,
        0xb5390f92u, 0x690fed0bu, 0x667b9ffbu, 0xcedb7d9cu, 0xa091cf0bu, 0xd9155ea3u,
        0xbb132f88u, 0x515bad24u, 0x7b9479bfu, 0x763bd6ebu, 0x37392eb3u, 0xcc115979u,
        0x8026e297u, 0xf42e312du, 0x6842ada7u, 0xc66a2b3bu, 0x12754cccu, 0x782ef11cu,
        0x6a124237u, 0xb79251e7u, 0x06a1bbe6u, 0x4bfb6350u, 0x1a6b1018u, 0x11caedfau,
        0x3d25bdd8u, 0xe2e1c3c9u, 0x44421659u, 0x0a121386u, 0xd90cec6eu, 0xd5abea2au,
        0x64af674eu, 0xda86a85fu, 0xbebfe988u, 0x64e4c3feu, 0x9dbc8057u, 0xf0f7c086u,
        0x60787bf8u, 0x6003604du, 0xd1fd8346u, 0xf6381fb0u, 0x7745ae04u, 0xd736fcccu,
        0x83426b33u, 0xf01eab71u, 0xb0804187u, 0x3c005e5fu, 0x77a057beu, 0xbde8ae24u,
        0x55464299u, 0xbf582e61u, 0x4e58f48fu, 0xf2ddfda2u, 0xf474ef38u, 0x8789bdc2u,
        0x5366f9c3u, 0xc8b38e74u, 0xb475f255u, 0x46fcd9b9u, 0x7aeb2661u, 0x8b1ddf84u,
        0x846a0e79u, 0x915f95e2u, 0x466e598eu, 0x20b45770u, 0x8cd55591u, 0xc902de4cu,
        0xb90bace1u, 0xbb8205d0u, 0x11a86248u, 0x7574a99eu, 0xb77f19b6u, 0xe0a9dc09u,
        0x662d09a1u, 0xc4324633u, 0xe85a1f02u, 0x09f0be8cu, 0x4a99a025u, 0x1d6efe10u,
        0x1ab93d1du, 0x0ba5a4dfu, 0xa186f20fu, 0x2868f169u, 0xdcb7da83u, 0x573906feu,
        0xa1e2ce9bu, 0x4fcd7f52u, 0x50115e01u, 0xa70683fau, 0xa002b5c4u, 0x0de6d027u,
        0x9af88c27u, 0x773f8641u, 0xc3604c06u, 0x61a806b5u, 0xf0177a28u, 0xc0f586e0u,
        0x006058aau, 0x30dc7d62u, 0x11e69ed7u, 0x2338ea63u, 0x53c2dd94u, 0xc2c21634u,
        0xbbcbee56u, 0x90bcb6deu, 0xebfc7da1u, 0xce591d76u, 0x6f05e409u, 0x4b7c0188u,
        0x39720a3du, 0x7c927c24u, 0x86e3725fu, 0x724d9db9u, 0x1ac15bb4u, 0xd39eb8fcu,
        0xed545578u, 0x08fca5b5u, 0xd83d7cd3u, 0x4dad0fc4u, 0x1e50ef5eu, 0xb161e6f8u,
        0xa28514d9u, 0x6c51133cu, 0x6fd5c7e7u, 0x56e14ec4u, 0x362abfceu, 0xddc6c837u,
        0xd79a3234u, 0x92638212u, 0x670efa8eu, 0x406000e0u,
    },
    {
        0x3a39ce37u, 0xd3faf5cfu, 0xabc27737u, 0x5ac52d1bu, 0x5cb0679eu, 0x4fa33742u,
        0xd3822740u, 0x99bc9bbeu, 0xd5118e9du, 0xbf0f7315u, 0xd62d1c7eu, 0xc700c47bu,
        0xb78c1b6bu, 0x21a19045u, 0xb26eb1beu, 0x6a366eb4u, 0x5748ab2fu, 0xbc946e79u,
        0xc6a376d2u, 0x6549c2c8u, 0x530ff8eeu, 0x468dde7du, 0xd5730a1du, 0x4cd04dc6u,
        0x2939bbdbu, 0xa9ba4650u, 0xac9526e8u, 0xbe5ee304u, 0xa1fad5f0u, 0x6a2d519au,
        0x63ef8ce2u, 0x9a86ee22u, 0xc089c2b8u, 0x43242ef6u, 0xa51e03aau, 0x9cf2d0a4u,
        0x83c061bau, 0x9be96a4du, 0x8fe51550u, 0xba645bd6u, 0x2826a2f9u, 0xa73a3ae1u,
        0x4ba99586u, 0xef5562e9u, 0xc72fefd3u, 0xf752f7dau, 0x3f046f69u, 0x77fa0a59u,
        0x80e4a915u, 0x87b08601u, 0x9b09e6adu, 0x3b3ee593u, 0xe990fd5au, 0x9e34d797u,
        0x2cf0b7d9u, 0x022b8b51u, 0x96d5ac3au, 0x017da67du, 0xd1cf3ed6u, 0x7c7d2d28u,
        0x1f9f25cfu, 0xadf2b89bu, 0x5ad6b472u, 0x5a88f54cu, 0xe029ac71u, 0xe019a5e6u,
        0x47b0acfdu, 0xed93fa9bu, 0xe8d3c48du, 0x283b57ccu, 0xf8d56629u, 0x79132e28u,
        0x785f0191u, 0xed756055u, 0xf7960e44u, 0xe3d35e8cu, 0x15056dd4u, 0x88f46dbau,
        0x03a16125u, 0x0564f0bdu, 0xc3eb9e15u, 0x3c9057a2u, 0x97271aecu, 0xa93a072au,
        0x1b3f6d9bu, 0x1e6321f5u, 0xf59c66fbu, 0x26dcf319u, 0x7533d928u, 0xb155fdf5u,
        0x03563482u, 0x8aba3cbbu, 0x28517711u, 0xc20ad9f8u, 0xabcc5167u, 0xccad925fu,
        0x4de81751u, 0x3830dc8eu, 0x379d5862u, 0x9320f991u, 0xea7a90c2u, 0xfb3e7bceu,
        0x5121ce64u, 0x774fbe32u, 0xa8b6e37eu, 0xc3293d46u, 0x48de5369u, 0x6413e680u,
        0xa2ae0810u, 0xdd6db224u, 0x69852dfdu, 0x09072166u, 0xb39a460au, 0x6445c0ddu,
        0x586cdecfu, 0x1c20c8aeu, 0x5bbef7ddu, 0x1b588d40u, 0xccd2017fu, 0x6bb4e3bbu,
        0xdda26a7eu, 0x3a59ff45u, 0x3e350a44u, 0xbcb4cdd5u, 0x72eacea8u, 0xfa6484bbu,
        0x8d6612aeu, 0xbf3c6f47u, 0xd29be463u, 0x542f5d9eu, 0xaec2771bu, 0xf64e6370u,
        0x740e0d8du, 0xe75b1357u, 0xf8721671u, 0xaf537d5du, 0x4040cb08u, 0x4eb4e2ccu,
        0x34d2466au, 0x0115af84u, 0xe1b00428u, 0x95983a1du, 0x06b89fb4u, 0xce6ea048u,
        0x6f3f3b82u, 0x3520ab82u, 0x011a1d4bu, 0x277227f8u, 0x611560b1u, 0xe7933fdcu,
        0xbb3a792bu, 0x344525bdu, 0xa08839e1u, 0x51ce794bu, 0x2f32c9b7u, 0xa01fbac9u,
        0xe01cc87eu, 0xbcc7d1f6u, 0xcf0111c3u, 0xa1e8aac7u, 0x1a908749u, 0xd44fbd9au,
        0xd0dadecbu, 0xd50ada38u, 0x0339c32au, 0xc6913667u, 0x8df9317cu, 0xe0b12b4fu,
        0xf79e59b7u, 0x43f5bb3au, 0xf2d519ffu, 0x27d9459cu, 0xbf97222cu, 0x15e6fc2au,
        0x0f91fc71u, 0x9b941525u, 0xfae59361u, 0xceb69cebu, 0xc2a86459u, 0x12baa8d1u,
        0xb6c1075eu, 0xe3056a0cu, 0x10d25065u, 0xcb03a442u, 0xe0ec6e0eu, 0x1698db3bu,
        0x4c98a0beu, 0x3278e964u, 0x9f1f9532u, 0xe0d392dfu, 0xd3a0342bu, 0x8971f21eu,
        0x1b0a7441u, 0x4ba3348cu, 0xc5be7120u, 0xc37632d8u, 0xdf359f8du, 0x9b992f2eu,
        0xe60b6f47u, 0x0fe3f11du, 0xe54cda54u, 0x1edad891u, 0xce6279cfu, 0xcd3e7e6fu,
        0x1618b166u, 0xfd2c1d05u, 0x848fd2c5u, 0xf6fb2299u, 0xf523f357u, 0xa6327623u,
        0x93a83531u, 0x56cccd02u, 0xacf08162u, 0x5a75ebb5u, 0x6e163697u, 0x88d273ccu,
        0xde966292u, 0x81b949d0u, 0x4c50901bu, 0x71c65614u, 0xe6c6c7bdu, 0x327a140au,
        0x45e1d006u, 0xc3f27b9au, 0xc9aa53fdu, 0x62a80f00u, 0xbb25bfe2u, 0x35bdd2f6u,
        0x71126905u, 0xb2040222u, 0xb6cbcf7cu, 0xcd769c2bu, 0x53113ec0u, 0x1640e3d3u,
        0x38abbd60u, 0x2547adf0u, 0xba38209cu, 0xf746ce76u, 0x77afa1c5u, 0x20756060u,
        0x85cbfe4eu, 0x8ae88dd8u, 0x7aaaf9b0u, 0x4cf9aa7eu, 0x1948c25cu, 0x02fb8a8cu,
        0x01c36ae4u, 0xd6ebe1f9u, 0x90d4f869u, 0xa65cdea0u, 0x3f09252du, 0xc208e69fu,
        0xb74e6132u, 0xce77e25bu, 0x578fdfe3u, 0x3ac372e6u,
    },
};

typedef struct {
    uint32_t p[18];
    uint32_t s[4][256];
} sl_bf_state;

#define SL_BF_F(st, x) \
    ((((st)->s[0][(x) >> 24] + (st)->s[1][((x) >> 16) & 0xff]) ^ \
      (st)->s[2][((x) >> 8) & 0xff]) + (st)->s[3][(x) & 0xff])

__attribute__((noinline)) static void sl_bf_encrypt(const sl_bf_state *st, uint32_t *lp, uint32_t *rp) {
    uint32_t l = *lp, r = *rp;
    for (int i = 0; i < 16; i += 2) {
        l ^= st->p[i];
        r ^= SL_BF_F(st, l);
        r ^= st->p[i + 1];
        l ^= SL_BF_F(st, r);
    }
    l ^= st->p[16];
    r ^= st->p[17];
    *lp = r;
    *rp = l;
}

/* The next 32 bits of `data`, cycling through it (the key schedule's
 * stream2word). */
static uint32_t sl_bf_word(const unsigned char *data, size_t len, size_t *pos) {
    uint32_t w = 0;
    for (int i = 0; i < 4; i++) {
        w = (w << 8) | data[*pos];
        *pos = (*pos + 1) % len;
    }
    return w;
}

/* ExpandKey(state, salt, key); salt NULL is the unsalted form. */
__attribute__((noinline)) static void sl_bf_expand(sl_bf_state *st, const unsigned char *salt,
                         const unsigned char *key, size_t key_len) {
    size_t kpos = 0, spos = 0;
    for (int i = 0; i < 18; i++)
        st->p[i] ^= sl_bf_word(key, key_len, &kpos);
    uint32_t l = 0, r = 0;
    for (int i = 0; i < 18; i += 2) {
        if (salt) {
            l ^= sl_bf_word(salt, 16, &spos);
            r ^= sl_bf_word(salt, 16, &spos);
        }
        sl_bf_encrypt(st, &l, &r);
        st->p[i] = l;
        st->p[i + 1] = r;
    }
    for (int b = 0; b < 4; b++) {
        for (int i = 0; i < 256; i += 2) {
            if (salt) {
                l ^= sl_bf_word(salt, 16, &spos);
                r ^= sl_bf_word(salt, 16, &spos);
            }
            sl_bf_encrypt(st, &l, &r);
            st->s[b][i] = l;
            st->s[b][i + 1] = r;
        }
    }
}

#define SL_BCRYPT_MIN_COST 4
/* 2^18 rounds is several seconds of CPU. A stored hash names its own
 * cost, so without a cap one row could pin a thread for hours; real
 * deployments use 10 to 14. */
#define SL_BCRYPT_MAX_COST 18
#define SL_BCRYPT_MAX_KEY 72

/* eksblowfish (Provos and Mazieres, 1999), as $2b$ and $2y$ compute it:
 * the key is the password and its NUL, cut at 72 bytes. Writes the 24
 * bytes of "OrpheanBeholderScryDoubt" encrypted 64 times. Touches no
 * collected memory and no task state, so it runs on a pool worker or a
 * kdf thread alike. Returns 1, or -1 when the state cannot be allocated.
 *
 * Not in a preempt bracket on a worker: it calls nothing that locks, so a
 * preemption or a collection may stop it anywhere -- which matters,
 * because at cost 12 it runs for a quarter of a second. Only its malloc
 * and free are bracketed. */
__attribute__((noinline)) static int sl_bcrypt_raw(const unsigned char *password, size_t password_len,
                         const unsigned char salt[16], uint32_t cost,
                         unsigned char out[24]) {
    unsigned char key[SL_BCRYPT_MAX_KEY];
    size_t key_len = password_len + 1;
    if (key_len > SL_BCRYPT_MAX_KEY)
        key_len = SL_BCRYPT_MAX_KEY;
    for (size_t i = 0; i < key_len; i++)
        key[i] = i < password_len ? password[i] : 0;

    sl_rt_preempt_disable();
    sl_bf_state *st = (sl_bf_state *)malloc(sizeof(sl_bf_state));
    sl_rt_preempt_enable();
    if (!st) {
        OPENSSL_cleanse(key, sizeof(key));
        return -1;
    }
    memcpy(st->p, sl_bf_init_p, sizeof(st->p));
    memcpy(st->s, sl_bf_init_s, sizeof(st->s));
    sl_bf_expand(st, salt, key, key_len);
    uint64_t rounds = 1ULL << cost;
    for (uint64_t i = 0; i < rounds; i++) {
        sl_bf_expand(st, NULL, key, key_len);
        sl_bf_expand(st, NULL, salt, 16);
    }
    static const unsigned char magic[24] = "OrpheanBeholderScryDoubt";
    uint32_t c[6];
    for (int i = 0; i < 6; i++)
        c[i] = ((uint32_t)magic[4 * i] << 24) | ((uint32_t)magic[4 * i + 1] << 16) |
               ((uint32_t)magic[4 * i + 2] << 8) | (uint32_t)magic[4 * i + 3];
    for (int k = 0; k < 64; k++)
        for (int i = 0; i < 6; i += 2)
            sl_bf_encrypt(st, &c[i], &c[i + 1]);
    for (int i = 0; i < 6; i++) {
        out[4 * i] = (unsigned char)(c[i] >> 24);
        out[4 * i + 1] = (unsigned char)(c[i] >> 16);
        out[4 * i + 2] = (unsigned char)(c[i] >> 8);
        out[4 * i + 3] = (unsigned char)c[i];
    }
    OPENSSL_cleanse(st, sizeof(*st));
    OPENSSL_cleanse(key, sizeof(key));
    OPENSSL_cleanse(c, sizeof(c));
    sl_rt_preempt_disable();
    free(st);
    sl_rt_preempt_enable();
    return 1;
}

/* scrypt (RFC 7914) bounds: a stored hash names N, r and p, so they are
 * checked before OpenSSL allocates 128 * N * r bytes for them. */
#define SL_SCRYPT_MAX_N (1LL << 20)
#define SL_SCRYPT_MAX_R 32LL
#define SL_SCRYPT_MAX_P 16LL
#define SL_SCRYPT_MAX_MEM (256LL * 1024 * 1024)
#define SL_SCRYPT_MAX_PASSWORD (1024LL * 1024)
#define SL_SCRYPT_MAX_SALT 1024LL
#define SL_SCRYPT_MAX_LEN 64LL

/* OpenSSL work: on a worker, the caller brackets it. Returns 1 or 0. */
static int sl_scrypt_raw(const unsigned char *password, size_t password_len,
                         const unsigned char *salt, size_t salt_len,
                         uint64_t n, uint32_t r, uint32_t p,
                         unsigned char *out, size_t out_len) {
    static const unsigned char empty = 0;
    /* OpenSSL's own allowance: the V array plus the p blocks, with room. */
    uint64_t maxmem = 128ULL * n * r + 128ULL * r * p + 1024ULL * 1024;
    return EVP_PBE_scrypt((const char *)(password ? password : &empty),
                          password_len, salt ? salt : &empty, salt_len, n, r, p,
                          maxmem, out, out_len) == 1;
}

enum { SL_KDF_ARGON2ID, SL_KDF_SCRYPT, SL_KDF_BCRYPT };

/* One slow derivation, by kind. The numeric inputs: Argon2id's
 * iterations, memory (KiB) and lanes; scrypt's N, r and p; bcrypt's cost
 * in `a` alone. */
static int sl_kdf_run(int kind, const unsigned char *password,
                      size_t password_len, const unsigned char *salt,
                      size_t salt_len, uint64_t a, uint32_t b, uint32_t c,
                      unsigned char *out, size_t out_len) {
    switch (kind) {
    case SL_KDF_SCRYPT:
        return sl_scrypt_raw(password, password_len, salt, salt_len, a, b, c,
                             out, out_len);
    case SL_KDF_BCRYPT:
        return sl_bcrypt_raw(password, password_len, salt, (uint32_t)a, out);
    default:
        return sl_crypto_argon2id_derive_raw(password, password_len, salt,
                                             salt_len, (uint32_t)a, b, c, out,
                                             out_len);
    }
}

#define SL_KDF_NO_OFFLOAD (-100)

#ifdef SL_HAVE_REACTOR
/* A derivation takes tens of milliseconds of uninterruptible OpenSSL work.
 * On a pool worker it pins that worker for the whole time (it cannot be
 * preempted), and a stop-the-world collection waits for it, so every task
 * in the process waits too. When the reactor is linked in, the work goes
 * to dedicated kdf threads instead, which the collector never waits for,
 * and the calling task parks on a pipe like a DNS lookup does. The inputs
 * are copied out of collected memory first, so a kdf thread never reads
 * the heap. SLANG_KDF_THREADS sets the pool size; the default is one per
 * pool worker. */
typedef struct sl_kdf_job {
    struct sl_kdf_job *next;
    int kind;
    unsigned char *password;
    size_t password_len;
    unsigned char *salt;
    size_t salt_len;
    uint64_t a;
    uint32_t b;
    uint32_t c;
    unsigned char tag[SL_ARGON2ID_MAX_TAG];
    size_t tag_len;
    int rc;
    int wake_wr;
} sl_kdf_job;

static pthread_mutex_t sl_kdf_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sl_kdf_cv = PTHREAD_COND_INITIALIZER;
static sl_kdf_job *sl_kdf_head;
static sl_kdf_job *sl_kdf_tail;
static pthread_once_t sl_kdf_start_once = PTHREAD_ONCE_INIT;
static int sl_kdf_started;

static void *sl_kdf_thread(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&sl_kdf_mu);
        while (!sl_kdf_head)
            pthread_cond_wait(&sl_kdf_cv, &sl_kdf_mu);
        sl_kdf_job *j = sl_kdf_head;
        sl_kdf_head = j->next;
        if (!sl_kdf_head)
            sl_kdf_tail = NULL;
        j->next = NULL;
        pthread_mutex_unlock(&sl_kdf_mu);
        j->rc = sl_kdf_run(j->kind, j->password, j->password_len, j->salt,
                           j->salt_len, j->a, j->b, j->c, j->tag, j->tag_len);
        /* The caller frees the job as soon as the byte lands: read the fd
           first and touch nothing after the write. */
        int wake_wr = j->wake_wr;
        char x = 1;
        sl_net_nudge(wake_wr, &x, 1);
        close(wake_wr);
    }
    return NULL;
}

static void sl_kdf_start(void) {
    long n = sl_pool_nworkers;
    const char *env = getenv("SLANG_KDF_THREADS");
    long v = env ? strtol(env, NULL, 10) : 0;
    if (v > 0)
        n = v;
    if (n < 1)
        n = 1;
    if (n > 64)
        n = 64;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    /* OpenSSL's first provider load goes through dlopen, which wants more
       than the 512 KiB macOS gives a secondary thread by default. */
    pthread_attr_setstacksize(&attr, 2u * 1024u * 1024u);
    int started = 0;
    for (long i = 0; i < n; i++) {
        pthread_t th;
        if (pthread_create(&th, &attr, sl_kdf_thread, NULL) == 0)
            started++;
    }
    pthread_attr_destroy(&attr);
    sl_kdf_started = started;
}

static void sl_kdf_job_free(sl_kdf_job *j) {
    if (j->password) {
        OPENSSL_cleanse(j->password, j->password_len);
        free(j->password);
    }
    free(j->salt);
    OPENSSL_cleanse(j->tag, sizeof(j->tag));
    free(j);
}

static int sl_kdf_offload(int kind, const unsigned char *password,
                          size_t password_len, const unsigned char *salt,
                          size_t salt_len, uint64_t a, uint32_t b, uint32_t c,
                          unsigned char *out, size_t out_len) {
    sl_rt_preempt_disable();
    pthread_once(&sl_kdf_start_once, sl_kdf_start);
    int have_threads = sl_kdf_started > 0;
    sl_kdf_job *job = have_threads
        ? (sl_kdf_job *)calloc(1, sizeof(sl_kdf_job)) : NULL;
    if (job) {
        job->password = (unsigned char *)malloc(password_len ? password_len : 1);
        job->salt = (unsigned char *)malloc(salt_len ? salt_len : 1);
    }
    sl_rt_preempt_enable();
    if (!job)
        return SL_KDF_NO_OFFLOAD;
    if (!job->password || !job->salt) {
        sl_kdf_job_free(job);
        return SL_KDF_NO_OFFLOAD;
    }
    if (password_len)
        memcpy(job->password, password, password_len);
    job->password_len = password_len;
    memcpy(job->salt, salt, salt_len);
    job->salt_len = salt_len;
    job->kind = kind;
    job->a = a;
    job->b = b;
    job->c = c;
    job->tag_len = out_len;
    int pfd[2];
    if (pipe(pfd) != 0) {
        sl_kdf_job_free(job);
        return SL_KDF_NO_OFFLOAD;
    }
    fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pfd[1], F_SETFD, FD_CLOEXEC);
    sl_net_set_nonblocking(pfd[0]);
    job->wake_wr = pfd[1];
    sl_rt_preempt_disable();
    pthread_mutex_lock(&sl_kdf_mu);
    if (sl_kdf_tail)
        sl_kdf_tail->next = job;
    else
        sl_kdf_head = job;
    sl_kdf_tail = job;
    pthread_cond_signal(&sl_kdf_cv);
    pthread_mutex_unlock(&sl_kdf_mu);
    sl_rt_preempt_enable();
    /* No deadline: the job cannot be abandoned, so it is always this
       task's to free once the byte arrives. */
    for (;;) {
        sl_reactor_wait_until(pfd[0], SL_REACTOR_READ, 0, 0);
        char x;
        ssize_t nr = read(pfd[0], &x, 1);
        if (nr == 1)
            break;
        if (nr < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
            continue;
        /* EOF without the byte cannot happen: the thread writes, then
           closes. Treat anything else as fatal rather than free a job a
           thread may still hold. */
        sl_rt_panic("crypto: kdf thread wake failed", "crypto");
    }
    close(pfd[0]);
    int rc = job->rc;
    if (rc == 1)
        memcpy(out, job->tag, out_len);
    sl_kdf_job_free(job);
    return rc;
}
#endif

/* A slow derivation on a kdf thread when the reactor is linked in, else
 * here: OpenSSL's inside a preempt bracket, bcrypt (which locks nothing)
 * outside one so it can still be preempted. */
static int sl_kdf_derive(int kind, const unsigned char *password,
                         size_t password_len, const unsigned char *salt,
                         size_t salt_len, uint64_t a, uint32_t b, uint32_t c,
                         unsigned char *out, size_t out_len) {
#ifdef SL_HAVE_REACTOR
    int off = sl_kdf_offload(kind, password, password_len, salt, salt_len, a,
                             b, c, out, out_len);
    if (off != SL_KDF_NO_OFFLOAD)
        return off;
#endif
    if (kind == SL_KDF_BCRYPT)
        return sl_kdf_run(kind, password, password_len, salt, salt_len, a, b,
                          c, out, out_len);
    sl_rt_preempt_disable();
    int rc = sl_kdf_run(kind, password, password_len, salt, salt_len, a, b, c,
                        out, out_len);
    sl_rt_preempt_enable();
    return rc;
}

static int sl_crypto_argon2id_derive(const unsigned char *password,
                                     size_t password_len,
                                     const unsigned char *salt,
                                     size_t salt_len,
                                     uint32_t iterations,
                                     uint32_t memory_kib,
                                     uint32_t parallelism,
                                     unsigned char *out,
                                     size_t out_len) {
    return sl_kdf_derive(SL_KDF_ARGON2ID, password, password_len, salt,
                         salt_len, iterations, memory_kib, parallelism, out,
                         out_len);
}

static sl_res_bytes_str *sl_crypto_argon2id_raw(sl_bytes *password,
                                                sl_bytes *salt,
                                                long long iterations,
                                                long long memory_kib,
                                                long long parallelism,
                                                long long tag_len) {
    SL_CRYPTO_STACK();
    const char *invalid = sl_crypto_argon2id_validate(
        password, salt, iterations, memory_kib, parallelism, tag_len);
    if (invalid)
        return sl_crypto_err_bytes(invalid);

    unsigned char tag[SL_ARGON2ID_MAX_TAG];
    int rc = sl_crypto_argon2id_derive(
        password->ptr, (size_t)password->len, salt->ptr, (size_t)salt->len,
        (uint32_t)iterations, (uint32_t)memory_kib, (uint32_t)parallelism,
        tag, (size_t)tag_len);
    if (rc != 1) {
        OPENSSL_cleanse(tag, sizeof(tag));
        if (rc == -2)
            return sl_crypto_err_bytes(
                "Argon2id requires OpenSSL 3.2 or newer with Argon2 support");
        if (rc == -1)
            return sl_crypto_err_bytes("could not allocate Argon2id context");
        return sl_crypto_err_bytes("OpenSSL Argon2id derivation failed");
    }
    sl_bytes *derived = sl_bytes_new(tag, tag_len);
    OPENSSL_cleanse(tag, sizeof(tag));
    return sl_crypto_ok_bytes(derived);
}

static sl_res_bool_str *sl_crypto_argon2id_verify(sl_bytes *password,
                                                  sl_bytes *salt,
                                                  sl_bytes *expected,
                                                  long long iterations,
                                                  long long memory_kib,
                                                  long long parallelism) {
    SL_CRYPTO_STACK();
    const char *invalid = sl_crypto_argon2id_validate(
        password, salt, iterations, memory_kib, parallelism, expected->len);
    if (invalid)
        return sl_crypto_err_bool(invalid);

    unsigned char tag[SL_ARGON2ID_MAX_TAG];
    int rc = sl_crypto_argon2id_derive(
        password->ptr, (size_t)password->len, salt->ptr, (size_t)salt->len,
        (uint32_t)iterations, (uint32_t)memory_kib, (uint32_t)parallelism,
        tag, (size_t)expected->len);
    if (rc != 1) {
        OPENSSL_cleanse(tag, sizeof(tag));
        if (rc == -2)
            return sl_crypto_err_bool(
                "Argon2id requires OpenSSL 3.2 or newer with Argon2 support");
        if (rc == -1)
            return sl_crypto_err_bool("could not allocate Argon2id context");
        return sl_crypto_err_bool("OpenSSL Argon2id verification failed");
    }
    int equal = CRYPTO_memcmp(tag, expected->ptr, (size_t)expected->len) == 0;
    OPENSSL_cleanse(tag, sizeof(tag));
    return sl_crypto_ok_bool(equal != 0);
}

/* scrypt (RFC 7914): N a power of two from 2 to 2^20, r up to 32, p up
 * to 16, at most 256 MiB of work memory, 1 to 64 bytes out. */
static sl_res_bytes_str *sl_crypto_scrypt(sl_bytes *password, sl_bytes *salt,
                                          long long n, long long r,
                                          long long p, long long keylen) {
    SL_CRYPTO_STACK();
    if (n < 2 || n > SL_SCRYPT_MAX_N || (n & (n - 1)) != 0)
        return sl_crypto_err_bytes("scrypt N must be a power of two from 2 to 1048576");
    if (r < 1 || r > SL_SCRYPT_MAX_R)
        return sl_crypto_err_bytes("scrypt r must be between 1 and 32");
    if (p < 1 || p > SL_SCRYPT_MAX_P)
        return sl_crypto_err_bytes("scrypt p must be between 1 and 16");
    if (128LL * n * r > SL_SCRYPT_MAX_MEM)
        return sl_crypto_err_bytes("scrypt N * r needs more than 256 MiB (128 * N * r bytes)");
    if (keylen < 1 || keylen > SL_SCRYPT_MAX_LEN)
        return sl_crypto_err_bytes("scrypt key length must be between 1 and 64");
    if (password->len > SL_SCRYPT_MAX_PASSWORD)
        return sl_crypto_err_bytes("scrypt password exceeds the 1 MiB limit");
    if (salt->len > SL_SCRYPT_MAX_SALT)
        return sl_crypto_err_bytes("scrypt salt exceeds 1024 bytes");
    unsigned char out[SL_SCRYPT_MAX_LEN];
    int rc = sl_kdf_derive(SL_KDF_SCRYPT, password->ptr, (size_t)password->len,
                           salt->ptr, (size_t)salt->len, (uint64_t)n,
                           (uint32_t)r, (uint32_t)p, out, (size_t)keylen);
    if (rc != 1) {
        OPENSSL_cleanse(out, sizeof(out));
        return sl_crypto_err_bytes("OpenSSL scrypt derivation failed");
    }
    sl_bytes *derived = sl_bytes_new(out, keylen);
    OPENSSL_cleanse(out, sizeof(out));
    return sl_crypto_ok_bytes(derived);
}

/* bcrypt's base64: its own alphabet, no padding. -1 for a byte outside it. */
static int sl_bcrypt_b64_value(unsigned char ch) {
    static const char alphabet[] =
        "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    for (int i = 0; i < 64; i++)
        if ((unsigned char)alphabet[i] == ch)
            return i;
    return -1;
}

/* Decodes `chars` characters into `n` bytes; 0 on a bad character. */
static int sl_bcrypt_b64_decode(const char *in, size_t chars, unsigned char *out,
                                size_t n) {
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < chars; i++) {
        int v = sl_bcrypt_b64_value((unsigned char)in[i]);
        if (v < 0)
            return 0;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o < n)
                out[o++] = (unsigned char)(acc >> bits);
            acc &= (1u << bits) - 1;
        }
    }
    return o == n;
}

/* Whether `password` matches a bcrypt hash: $2a$, $2b$ or $2y$, two cost
 * digits, then 22 characters of salt and 31 of hash. For a 72-byte or
 * shorter password, as every one in practice is, the three prefixes
 * compute the same thing; past 72 bytes bcrypt reads only the first 72.
 * $2x$ (crypt_blowfish's flagged buggy hashes) and the original $2$ are
 * refused. ok(false) is a wrong password; err is a hash this cannot read. */
static sl_res_bool_str *sl_crypto_bcrypt_verify(sl_bytes *password,
                                                const char *hash) {
    size_t hlen = hash ? strlen(hash) : 0;
    if (hlen != 60 || hash[0] != '$' || hash[1] != '2' || hash[3] != '$' ||
        hash[6] != '$')
        return sl_crypto_err_bool("not a bcrypt hash: expected $2b$<cost>$ and 53 characters");
    if (hash[2] != 'a' && hash[2] != 'b' && hash[2] != 'y')
        return sl_crypto_err_bool("bcrypt variant must be $2a$, $2b$ or $2y$");
    if (hash[4] < '0' || hash[4] > '9' || hash[5] < '0' || hash[5] > '9')
        return sl_crypto_err_bool("bcrypt cost must be two digits");
    int cost = (hash[4] - '0') * 10 + (hash[5] - '0');
    if (cost < SL_BCRYPT_MIN_COST || cost > SL_BCRYPT_MAX_COST)
        return sl_crypto_err_bool("bcrypt cost must be between 04 and 18");
    unsigned char salt[16];
    unsigned char want[23];
    if (!sl_bcrypt_b64_decode(hash + 7, 22, salt, 16) ||
        !sl_bcrypt_b64_decode(hash + 29, 31, want, 23))
        return sl_crypto_err_bool("bcrypt salt or hash has a character outside ./A-Za-z0-9");
    /* Only the first 72 bytes count; copying no more also bounds the copy
       a kdf thread makes. */
    size_t plen = password->len > SL_BCRYPT_MAX_KEY ? SL_BCRYPT_MAX_KEY
                                                     : (size_t)password->len;
    unsigned char got[24];
    int rc = sl_kdf_derive(SL_KDF_BCRYPT, password->ptr, plen, salt, 16,
                           (uint64_t)cost, 0, 0, got, 24);
    if (rc != 1) {
        OPENSSL_cleanse(got, sizeof(got));
        return sl_crypto_err_bool("bcrypt could not allocate its state");
    }
    int equal = CRYPTO_memcmp(got, want, 23) == 0;
    OPENSSL_cleanse(got, sizeof(got));
    return sl_crypto_ok_bool(equal != 0);
}

/* RSASSA-PKCS1-v1_5 with SHA-256 (JWS "RS256"), the key given as its raw
 * big-endian modulus and exponent: exactly what a JWKS entry's `n` and `e`
 * decode to, so no PEM or DER parsing is needed. The modulus is bounded so
 * a key fetched from someone else's server cannot ask for unbounded work. */
#define SL_RSA_MIN_MODULUS_BYTES 256
#define SL_RSA_MAX_MODULUS_BYTES 1024
#define SL_RSA_MAX_EXPONENT_BYTES 8

static sl_res_bool_str *sl_crypto_rsa_verify(sl_bytes *n, sl_bytes *e,
                                             sl_bytes *msg, sl_bytes *sig,
                                             int pss) {
    SL_CRYPTO_STACK();
    const unsigned char *np = n->ptr;
    long long nlen = n->len;
    while (nlen > 0 && np[0] == 0) {
        np++;
        nlen--;
    }
    if (nlen < SL_RSA_MIN_MODULUS_BYTES || nlen > SL_RSA_MAX_MODULUS_BYTES)
        return sl_crypto_err_bool("RSA modulus must be 2048 to 8192 bits");
    if (e->len < 1 || e->len > SL_RSA_MAX_EXPONENT_BYTES)
        return sl_crypto_err_bool("RSA exponent must be 1 to 8 bytes");
    /* A signature is exactly as long as the modulus; anything else cannot
       verify, and is a mismatch rather than a malformed key. */
    if (sig->len != nlen)
        return sl_crypto_ok_bool(false);

    sl_rt_preempt_disable();
    const char *fail = NULL;
    int verified = 0;
    BIGNUM *bn_n = BN_bin2bn(np, (int)nlen, NULL);
    BIGNUM *bn_e = BN_bin2bn(e->ptr, (int)e->len, NULL);
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new();
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *kctx = NULL;
    EVP_PKEY *pkey = NULL;
    EVP_MD_CTX *mctx = NULL;
    if (!bn_n || !bn_e || !bld ||
        !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_RSA_N, bn_n) ||
        !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_RSA_E, bn_e) ||
        !(params = OSSL_PARAM_BLD_to_param(bld))) {
        fail = "could not build RSA key parameters";
        goto done;
    }
    kctx = EVP_PKEY_CTX_new_from_name(NULL, "RSA", NULL);
    if (!kctx || EVP_PKEY_fromdata_init(kctx) != 1 ||
        EVP_PKEY_fromdata(kctx, &pkey, EVP_PKEY_PUBLIC_KEY, params) != 1) {
        fail = "invalid RSA public key";
        goto done;
    }
    mctx = EVP_MD_CTX_new();
    if (!mctx ||
        EVP_DigestVerifyInit_ex(mctx, NULL, "SHA256", NULL, NULL, pkey,
                                NULL) != 1) {
        fail = "could not start RSA verification";
        goto done;
    }
    if (pss) {
        /* JWS PS256: MGF1 with SHA-256 and a salt as long as the digest,
           exactly (RFC 7518 3.5); other salt lengths do not verify. */
        EVP_PKEY_CTX *pctx = EVP_MD_CTX_get_pkey_ctx(mctx);
        if (!pctx ||
            EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) != 1 ||
            EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) != 1) {
            fail = "could not select RSA-PSS";
            goto done;
        }
    }
    {
        static const unsigned char empty = 0;
        const unsigned char *mp = msg->len ? msg->ptr : &empty;
        int rc = EVP_DigestVerify(mctx, sig->ptr, (size_t)sig->len, mp,
                                  (size_t)msg->len);
        verified = rc == 1;
        /* 0 is a bad signature; a negative return is also only ever a
           signature that does not verify for this key. */
        ERR_clear_error();
    }
done:
    EVP_MD_CTX_free(mctx);
    EVP_PKEY_free(pkey);
    EVP_PKEY_CTX_free(kctx);
    OSSL_PARAM_free(params);
    OSSL_PARAM_BLD_free(bld);
    BN_free(bn_n);
    BN_free(bn_e);
    if (fail)
        ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail)
        return sl_crypto_err_bool(fail);
    return sl_crypto_ok_bool(verified != 0);
}

static sl_res_bool_str *sl_crypto_rsa_verify_sha256(sl_bytes *n, sl_bytes *e,
                                                    sl_bytes *msg,
                                                    sl_bytes *sig) {
    return sl_crypto_rsa_verify(n, e, msg, sig, 0);
}

static sl_res_bool_str *sl_crypto_rsa_verify_pss_sha256(sl_bytes *n, sl_bytes *e,
                                                        sl_bytes *msg,
                                                        sl_bytes *sig) {
    return sl_crypto_rsa_verify(n, e, msg, sig, 1);
}

/* ---- SHA-384/512, HMAC, HKDF, constant-time compare, AEAD, Ed25519,
 *      ECDSA P-256, RSA signing ----
 *
 * Everything below goes through OpenSSL 3's EVP interface. Ciphers and
 * digests are fetched once and kept: an implicit fetch (EVP_aes_256_gcm()
 * and friends) is a provider lookup on every call in OpenSSL 3, which
 * costs more than sealing a cookie. Keys cross the boundary in their raw
 * standard forms -- a 32-byte Ed25519 seed, a 32-byte P-256 scalar and a
 * 65-byte uncompressed point, RSA as PEM -- which is what JWK, JWS and
 * most key stores use; PEM readers cover the rest. Every call is
 * preempt-bracketed (OpenSSL allocates and takes locks) and grows the
 * task stack first (SL_CRYPTO_STACK). */


static sl_res_bytes_str *sl_crypto_errf_bytes(const char *fmt, long long a,
                                              long long b) {
    char msg[160];
    snprintf(msg, sizeof msg, fmt, a, b);
    return sl_crypto_err_bytes(msg);
}

/* ---- hashes and MACs ---- */

static sl_bytes *sl_crypto_digest(int which, sl_bytes *input) {
    SL_CRYPTO_STACK();
    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int n = 0;
    static const unsigned char empty = 0;
    sl_rt_preempt_disable();
    int ok = EVP_Digest(input->len ? input->ptr : &empty, (size_t)input->len,
                        out, &n, sl_crypto_md(which), NULL) == 1;
    sl_rt_preempt_enable();
    if (!ok)
        return NULL;
    return sl_bytes_new(out, (long long)n);
}

static sl_bytes *sl_crypto_sha384(sl_bytes *input) {
    return sl_crypto_digest(SL_MD_SHA384, input);
}

static sl_bytes *sl_crypto_sha512(sl_bytes *input) {
    return sl_crypto_digest(SL_MD_SHA512, input);
}

static sl_bytes *sl_crypto_hmac_sha384(sl_bytes *key, sl_bytes *message) {
    return sl_crypto_hmac(SL_MD_SHA384, key, message);
}

static sl_bytes *sl_crypto_hmac_sha512(sl_bytes *key, sl_bytes *message) {
    return sl_crypto_hmac(SL_MD_SHA512, key, message);
}

/* RFC 5869. length is at most 255 hash lengths (the RFC's limit). */
static sl_res_bytes_str *sl_crypto_hkdf(int which, const char *mdname,
                                        sl_bytes *ikm, sl_bytes *salt,
                                        sl_bytes *info, long long length) {
    SL_CRYPTO_STACK();
    long long hlen = which == SL_MD_SHA512 ? 64 : 32;
    if (length < 1 || length > 255 * hlen)
        return sl_crypto_errf_bytes("hkdf: length must be 1 to %lld bytes, got %lld",
                                    255 * hlen, length);
    unsigned char *out = (unsigned char *)sl_gc_alloc_leaf_uninit((size_t)length, NULL);
    static unsigned char empty = 0;
    sl_rt_preempt_disable();
    EVP_KDF *kdf = EVP_KDF_fetch(NULL, "HKDF", NULL);
    EVP_KDF_CTX *kctx = kdf ? EVP_KDF_CTX_new(kdf) : NULL;
    OSSL_PARAM params[5];
    int p = 0;
    params[p++] = OSSL_PARAM_construct_utf8_string(OSSL_KDF_PARAM_DIGEST,
                                                   (char *)mdname, 0);
    params[p++] = OSSL_PARAM_construct_octet_string(
        OSSL_KDF_PARAM_KEY, ikm->len ? ikm->ptr : &empty, (size_t)ikm->len);
    if (salt->len)
        params[p++] = OSSL_PARAM_construct_octet_string(
            OSSL_KDF_PARAM_SALT, salt->ptr, (size_t)salt->len);
    if (info->len)
        params[p++] = OSSL_PARAM_construct_octet_string(
            OSSL_KDF_PARAM_INFO, info->ptr, (size_t)info->len);
    params[p] = OSSL_PARAM_construct_end();
    int ok = kctx && EVP_KDF_derive(kctx, out, (size_t)length, params) == 1;
    EVP_KDF_CTX_free(kctx);
    EVP_KDF_free(kdf);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok)
        return sl_crypto_err_bytes("hkdf: derivation failed");
    sl_bytes *b = sl_bytes_new(out, length);
    return sl_crypto_ok_bytes(b);
}

static sl_res_bytes_str *sl_crypto_hkdf_sha256(sl_bytes *ikm, sl_bytes *salt,
                                               sl_bytes *info, long long length) {
    return sl_crypto_hkdf(SL_MD_SHA256, "SHA256", ikm, salt, info, length);
}

static sl_res_bytes_str *sl_crypto_hkdf_sha512(sl_bytes *ikm, sl_bytes *salt,
                                               sl_bytes *info, long long length) {
    return sl_crypto_hkdf(SL_MD_SHA512, "SHA512", ikm, salt, info, length);
}

/* Equal contents, in time that depends only on the length: for MACs,
   tokens and anything else an attacker could probe byte by byte. The
   length itself is not secret (a MAC's length is public), so different
   lengths answer at once. */
static bool sl_crypto_constant_time_eq(sl_bytes *a, sl_bytes *b) {
    if (a->len != b->len)
        return false;
    if (a->len == 0)
        return true;
    return CRYPTO_memcmp(a->ptr, b->ptr, (size_t)a->len) == 0;
}

/* ---- authenticated encryption ---- */

#define SL_AEAD_KEY 32
#define SL_AEAD_NONCE 12
#define SL_AEAD_TAG 16

/* Encrypt into out (ciphertext then tag). 0 on success. */
static int sl_crypto_aead_seal_raw(int which, const unsigned char *key,
                                   const unsigned char *nonce,
                                   const unsigned char *pt, size_t ptlen,
                                   const unsigned char *aad, size_t aadlen,
                                   unsigned char *out) {
    int ok = 0, len = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) goto done;
    if (EVP_EncryptInit_ex2(ctx, sl_crypto_cipher(which), NULL, NULL, NULL) != 1)
        goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, SL_AEAD_NONCE, NULL) != 1)
        goto done;
    if (EVP_EncryptInit_ex2(ctx, NULL, key, nonce, NULL) != 1)
        goto done;
    if (aadlen && EVP_EncryptUpdate(ctx, NULL, &len, aad, (int)aadlen) != 1)
        goto done;
    if (ptlen && EVP_EncryptUpdate(ctx, out, &len, pt, (int)ptlen) != 1)
        goto done;
    if (EVP_EncryptFinal_ex(ctx, out + ptlen, &len) != 1)
        goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, SL_AEAD_TAG,
                            out + ptlen) != 1)
        goto done;
    ok = 1;
done:
    EVP_CIPHER_CTX_free(ctx);
    ERR_clear_error();
    return ok ? 0 : -1;
}

/* Decrypt sealed (ciphertext then tag) into out. 0 on success, 1 when the
   tag does not verify, -1 on an internal failure. */
static int sl_crypto_aead_open_raw(int which, const unsigned char *key,
                                   const unsigned char *nonce,
                                   const unsigned char *ct, size_t ctlen,
                                   const unsigned char *tag,
                                   const unsigned char *aad, size_t aadlen,
                                   unsigned char *out) {
    int rc = -1, len = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) goto done;
    if (EVP_DecryptInit_ex2(ctx, sl_crypto_cipher(which), NULL, NULL, NULL) != 1)
        goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, SL_AEAD_NONCE, NULL) != 1)
        goto done;
    if (EVP_DecryptInit_ex2(ctx, NULL, key, nonce, NULL) != 1)
        goto done;
    if (aadlen && EVP_DecryptUpdate(ctx, NULL, &len, aad, (int)aadlen) != 1)
        goto done;
    if (ctlen && EVP_DecryptUpdate(ctx, out, &len, ct, (int)ctlen) != 1)
        goto done;
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, SL_AEAD_TAG,
                            (void *)tag) != 1)
        goto done;
    rc = EVP_DecryptFinal_ex(ctx, out + ctlen, &len) == 1 ? 0 : 1;
done:
    EVP_CIPHER_CTX_free(ctx);
    ERR_clear_error();
    return rc;
}

/* The cap keeps a length in an int for OpenSSL and a sealed message in
   one allocation: 1 GiB, far past any cookie, token or record. */
#define SL_AEAD_MAX ((long long)1 << 30)

static const char *sl_crypto_aead_check(const char *name, sl_bytes *key,
                                        sl_bytes *nonce, long long datalen,
                                        sl_bytes *aad, char *buf, size_t cap) {
    if (key->len != SL_AEAD_KEY) {
        snprintf(buf, cap, "%s: key must be 32 bytes, got %lld", name, key->len);
        return buf;
    }
    if (nonce && nonce->len != SL_AEAD_NONCE) {
        snprintf(buf, cap, "%s: nonce must be 12 bytes, got %lld", name, nonce->len);
        return buf;
    }
    if (datalen > SL_AEAD_MAX || aad->len > SL_AEAD_MAX) {
        snprintf(buf, cap, "%s: message or associated data over 1 GiB", name);
        return buf;
    }
    return NULL;
}

static sl_res_bytes_str *sl_crypto_aead_seal(int which, const char *name,
                                             sl_bytes *key, sl_bytes *nonce,
                                             sl_bytes *pt, sl_bytes *aad) {
    SL_CRYPTO_STACK();
    char buf[128];
    const char *bad = sl_crypto_aead_check(name, key, nonce, pt->len, aad, buf,
                                           sizeof buf);
    if (bad)
        return sl_crypto_err_bytes(bad);
    long long n = pt->len + SL_AEAD_TAG;
    unsigned char *out = (unsigned char *)sl_gc_alloc_leaf_uninit((size_t)n, NULL);
    sl_rt_preempt_disable();
    int rc = sl_crypto_aead_seal_raw(which, key->ptr, nonce->ptr, pt->ptr,
                                     (size_t)pt->len, aad->ptr, (size_t)aad->len,
                                     out);
    sl_rt_preempt_enable();
    if (rc)
        return sl_crypto_err_bytes("encryption failed");
    return sl_crypto_ok_bytes(sl_bytes_new(out, n));
}

static const char sl_crypto_open_failed[] =
    "decryption failed: the message or its associated data was altered, "
    "or the key or nonce is wrong";

static sl_res_bytes_str *sl_crypto_aead_open(int which, const char *name,
                                             sl_bytes *key, sl_bytes *nonce,
                                             sl_bytes *sealed, sl_bytes *aad) {
    SL_CRYPTO_STACK();
    char buf[128];
    const char *bad = sl_crypto_aead_check(name, key, nonce, sealed->len, aad,
                                           buf, sizeof buf);
    if (bad)
        return sl_crypto_err_bytes(bad);
    if (sealed->len < SL_AEAD_TAG)
        return sl_crypto_err_bytes(sl_crypto_open_failed);
    long long n = sealed->len - SL_AEAD_TAG;
    unsigned char *out =
        (unsigned char *)sl_gc_alloc_leaf_uninit((size_t)(n ? n : 1), NULL);
    sl_rt_preempt_disable();
    int rc = sl_crypto_aead_open_raw(which, key->ptr, nonce->ptr, sealed->ptr,
                                     (size_t)n, sealed->ptr + n, aad->ptr,
                                     (size_t)aad->len, out);
    sl_rt_preempt_enable();
    if (rc == 1)
        return sl_crypto_err_bytes(sl_crypto_open_failed);
    if (rc)
        return sl_crypto_err_bytes("decryption failed");
    return sl_crypto_ok_bytes(sl_bytes_new(out, n));
}

static sl_res_bytes_str *sl_crypto_aes256gcm_seal(sl_bytes *key, sl_bytes *nonce,
                                                  sl_bytes *pt, sl_bytes *aad) {
    return sl_crypto_aead_seal(SL_CIPHER_AES256GCM, "aes256gcm", key, nonce, pt, aad);
}

static sl_res_bytes_str *sl_crypto_aes256gcm_open(sl_bytes *key, sl_bytes *nonce,
                                                  sl_bytes *sealed, sl_bytes *aad) {
    return sl_crypto_aead_open(SL_CIPHER_AES256GCM, "aes256gcm", key, nonce, sealed, aad);
}

static sl_res_bytes_str *sl_crypto_chacha20poly1305_seal(sl_bytes *key,
                                                         sl_bytes *nonce,
                                                         sl_bytes *pt,
                                                         sl_bytes *aad) {
    return sl_crypto_aead_seal(SL_CIPHER_CHACHA, "chacha20poly1305", key, nonce, pt, aad);
}

static sl_res_bytes_str *sl_crypto_chacha20poly1305_open(sl_bytes *key,
                                                         sl_bytes *nonce,
                                                         sl_bytes *sealed,
                                                         sl_bytes *aad) {
    return sl_crypto_aead_open(SL_CIPHER_CHACHA, "chacha20poly1305", key, nonce, sealed, aad);
}

/* AES-256-GCM with a fresh random nonce, sent in front: nonce (12) then
   ciphertext then tag (16). The caller never picks a nonce, so cannot
   reuse one -- the mistake that breaks GCM outright. A key should seal
   fewer than 2^32 messages this way (the random-nonce collision bound). */
static sl_res_bytes_str *sl_crypto_seal(sl_bytes *key, sl_bytes *pt, sl_bytes *aad) {
    SL_CRYPTO_STACK();
    char buf[128];
    const char *bad = sl_crypto_aead_check("seal", key, NULL, pt->len, aad, buf,
                                           sizeof buf);
    if (bad)
        return sl_crypto_err_bytes(bad);
    long long n = SL_AEAD_NONCE + pt->len + SL_AEAD_TAG;
    unsigned char *out = (unsigned char *)sl_gc_alloc_leaf_uninit((size_t)n, NULL);
    if (sl_crypto_os_random(out, SL_AEAD_NONCE) != 0)
        return sl_crypto_err_bytes("seal: no randomness from the OS");
    sl_rt_preempt_disable();
    int rc = sl_crypto_aead_seal_raw(SL_CIPHER_AES256GCM, key->ptr, out, pt->ptr,
                                     (size_t)pt->len, aad->ptr, (size_t)aad->len,
                                     out + SL_AEAD_NONCE);
    sl_rt_preempt_enable();
    if (rc)
        return sl_crypto_err_bytes("seal: encryption failed");
    return sl_crypto_ok_bytes(sl_bytes_new(out, n));
}

static sl_res_bytes_str *sl_crypto_open(sl_bytes *key, sl_bytes *box, sl_bytes *aad) {
    SL_CRYPTO_STACK();
    char buf[128];
    const char *bad = sl_crypto_aead_check("open", key, NULL, box->len, aad, buf,
                                           sizeof buf);
    if (bad)
        return sl_crypto_err_bytes(bad);
    if (box->len < SL_AEAD_NONCE + SL_AEAD_TAG)
        return sl_crypto_err_bytes(sl_crypto_open_failed);
    long long n = box->len - SL_AEAD_NONCE - SL_AEAD_TAG;
    unsigned char *out =
        (unsigned char *)sl_gc_alloc_leaf_uninit((size_t)(n ? n : 1), NULL);
    sl_rt_preempt_disable();
    int rc = sl_crypto_aead_open_raw(SL_CIPHER_AES256GCM, key->ptr, box->ptr,
                                     box->ptr + SL_AEAD_NONCE, (size_t)n,
                                     box->ptr + SL_AEAD_NONCE + n, aad->ptr,
                                     (size_t)aad->len, out);
    sl_rt_preempt_enable();
    if (rc == 1)
        return sl_crypto_err_bytes(sl_crypto_open_failed);
    if (rc)
        return sl_crypto_err_bytes("open: decryption failed");
    return sl_crypto_ok_bytes(sl_bytes_new(out, n));
}

/* ---- PEM ---- */

/* The key in a PEM text: a private key (PKCS#8, or the traditional
   per-algorithm forms) when want_private, else a public key (SPKI),
   falling back to the public half of a private key. Callers hold the
   preempt bracket. */
static EVP_PKEY *sl_crypto_pem_key(const char *pem, int want_private) {
    if (!pem)
        return NULL;
    /* The first fetch fills OpenSSL's name map. Done concurrently from a
     * key decode, every worker blocked on its write lock and none
     * returned (tests/crypto_oaep_task); the one-time fetch does it once. */
    pthread_once(&sl_crypto_fetch_once, sl_crypto_fetch_all);
    BIO *bio = BIO_new_mem_buf(pem, -1);
    if (!bio)
        return NULL;
    EVP_PKEY *k = NULL;
    if (want_private) {
        k = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    } else {
        k = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
        if (!k) {
            (void)BIO_reset(bio);
            k = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
        }
    }
    BIO_free(bio);
    ERR_clear_error();
    return k;
}

/* ---- prepared keys ----
 *
 * Making an EVP_PKEY from raw bytes is most of a signature's cost: a
 * private Ed25519 or P-256 key derives its public point (a full scalar
 * multiplication) and a public P-256 point is validated on the curve. A
 * server signs and verifies with the same few keys -- its JWT signing
 * key, a JWKS -- so prepared keys are kept here, keyed by kind and bytes,
 * and handed out with a reference each. OpenSSL 3 allows concurrent use
 * of an EVP_PKEY that is not modified. Round-robin eviction of a small
 * table: no allocation per lookup, and a key churned past it is just
 * prepared again. Callers hold the preempt bracket. */

#define SL_KEYCACHE 16
enum { SL_KC_ED_PRIV, SL_KC_ED_PUB, SL_KC_P256_PRIV, SL_KC_P256_PUB };

static struct {
    int kind;
    size_t len;
    unsigned char key[65];
    EVP_PKEY *pkey;
} sl_keycache[SL_KEYCACHE];
static int sl_keycache_next;
static pthread_mutex_t sl_keycache_mu = PTHREAD_MUTEX_INITIALIZER;

static EVP_PKEY *sl_keycache_get(int kind, const unsigned char *key, size_t len) {
    EVP_PKEY *k = NULL;
    pthread_mutex_lock(&sl_keycache_mu);
    for (int i = 0; i < SL_KEYCACHE; i++) {
        if (sl_keycache[i].pkey && sl_keycache[i].kind == kind &&
            sl_keycache[i].len == len &&
            CRYPTO_memcmp(sl_keycache[i].key, key, len) == 0) {
            k = sl_keycache[i].pkey;
            EVP_PKEY_up_ref(k);
            break;
        }
    }
    pthread_mutex_unlock(&sl_keycache_mu);
    return k;
}

/* Remember k (the caller keeps its own reference). */
static void sl_keycache_put(int kind, const unsigned char *key, size_t len,
                            EVP_PKEY *k) {
    if (!k || len > sizeof sl_keycache[0].key)
        return;
    EVP_PKEY_up_ref(k);
    EVP_PKEY *old = NULL;
    pthread_mutex_lock(&sl_keycache_mu);
    int i = sl_keycache_next;
    sl_keycache_next = (sl_keycache_next + 1) % SL_KEYCACHE;
    old = sl_keycache[i].pkey;
    sl_keycache[i].kind = kind;
    sl_keycache[i].len = len;
    memcpy(sl_keycache[i].key, key, len);
    sl_keycache[i].pkey = k;
    pthread_mutex_unlock(&sl_keycache_mu);
    EVP_PKEY_free(old);
}

/* ---- Ed25519 ---- */

static sl_res_bytes_str *sl_crypto_ed25519_generate(void) {
    unsigned char seed[32];
    if (sl_crypto_os_random(seed, sizeof seed) != 0)
        return sl_crypto_err_bytes("ed25519: no randomness from the OS");
    sl_bytes *b = sl_bytes_new(seed, 32);
    OPENSSL_cleanse(seed, sizeof seed);
    return sl_crypto_ok_bytes(b);
}

static EVP_PKEY *sl_crypto_ed25519_private(sl_bytes *seed) {
    EVP_PKEY *k = sl_keycache_get(SL_KC_ED_PRIV, seed->ptr, 32);
    if (k)
        return k;
    k = EVP_PKEY_new_raw_private_key_ex(NULL, "ED25519", NULL, seed->ptr, 32);
    sl_keycache_put(SL_KC_ED_PRIV, seed->ptr, 32, k);
    return k;
}

static EVP_PKEY *sl_crypto_ed25519_public(const unsigned char *pub) {
    EVP_PKEY *k = sl_keycache_get(SL_KC_ED_PUB, pub, 32);
    if (k)
        return k;
    k = EVP_PKEY_new_raw_public_key_ex(NULL, "ED25519", NULL, pub, 32);
    sl_keycache_put(SL_KC_ED_PUB, pub, 32, k);
    return k;
}

static sl_res_bytes_str *sl_crypto_ed25519_public_key(sl_bytes *seed) {
    SL_CRYPTO_STACK();
    if (seed->len != 32)
        return sl_crypto_errf_bytes("ed25519: private key must be 32 bytes, got %lld",
                                    seed->len, 0);
    unsigned char pub[32];
    size_t n = sizeof pub;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_ed25519_private(seed);
    int ok = k && EVP_PKEY_get_raw_public_key(k, pub, &n) == 1 && n == 32;
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok)
        return sl_crypto_err_bytes("ed25519: invalid private key");
    return sl_crypto_ok_bytes(sl_bytes_new(pub, 32));
}

static sl_res_bytes_str *sl_crypto_ed25519_sign(sl_bytes *seed, sl_bytes *msg) {
    SL_CRYPTO_STACK();
    if (seed->len != 32)
        return sl_crypto_errf_bytes("ed25519: private key must be 32 bytes, got %lld",
                                    seed->len, 0);
    unsigned char sig[64];
    size_t n = sizeof sig;
    static const unsigned char empty = 0;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_ed25519_private(seed);
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int ok = k && ctx && EVP_DigestSignInit_ex(ctx, NULL, NULL, NULL, NULL, k, NULL) == 1 &&
             EVP_DigestSign(ctx, sig, &n, msg->len ? msg->ptr : &empty,
                            (size_t)msg->len) == 1 && n == 64;
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok)
        return sl_crypto_err_bytes("ed25519: signing failed");
    return sl_crypto_ok_bytes(sl_bytes_new(sig, 64));
}

static sl_res_bool_str *sl_crypto_ed25519_verify(sl_bytes *pub, sl_bytes *msg,
                                                 sl_bytes *sig) {
    SL_CRYPTO_STACK();
    if (pub->len != 32)
        return sl_crypto_err_bool("ed25519: public key must be 32 bytes");
    if (sig->len != 64)
        return sl_crypto_ok_bool(false);
    static const unsigned char empty = 0;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_ed25519_public(pub->ptr);
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int keyok = k != NULL;
    int ok = keyok && ctx &&
             EVP_DigestVerifyInit_ex(ctx, NULL, NULL, NULL, NULL, k, NULL) == 1 &&
             EVP_DigestVerify(ctx, sig->ptr, 64, msg->len ? msg->ptr : &empty,
                              (size_t)msg->len) == 1;
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!keyok)
        return sl_crypto_err_bool("ed25519: invalid public key");
    return sl_crypto_ok_bool(ok);
}

static sl_res_bytes_str *sl_crypto_ed25519_raw_from_pem(const char *pem, int priv) {
    SL_CRYPTO_STACK();
    unsigned char raw[32];
    size_t n = sizeof raw;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(pem, priv);
    int is_ed = k && EVP_PKEY_is_a(k, "ED25519");
    int ok = is_ed && (priv ? EVP_PKEY_get_raw_private_key(k, raw, &n)
                            : EVP_PKEY_get_raw_public_key(k, raw, &n)) == 1 &&
             n == 32;
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok) {
        OPENSSL_cleanse(raw, sizeof raw);
        return sl_crypto_err_bytes(is_ed ? "ed25519: could not read the key"
                                         : "ed25519: not an Ed25519 key in PEM form");
    }
    sl_bytes *b = sl_bytes_new(raw, 32);
    OPENSSL_cleanse(raw, sizeof raw);
    return sl_crypto_ok_bytes(b);
}

static sl_res_bytes_str *sl_crypto_ed25519_private_from_pem(const char *pem) {
    return sl_crypto_ed25519_raw_from_pem(pem, 1);
}

static sl_res_bytes_str *sl_crypto_ed25519_public_from_pem(const char *pem) {
    return sl_crypto_ed25519_raw_from_pem(pem, 0);
}

/* ---- ECDSA P-256 ---- */

/* The uncompressed point (65 bytes) for scalar d, or -1. */
static int sl_crypto_p256_point(const unsigned char *d, unsigned char *pub) {
    int ok = 0;
    EC_GROUP *g = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    BIGNUM *k = BN_bin2bn(d, 32, NULL);
    EC_POINT *pt = g ? EC_POINT_new(g) : NULL;
    if (g && k && pt && !BN_is_zero(k) && BN_cmp(k, EC_GROUP_get0_order(g)) < 0 &&
        EC_POINT_mul(g, pt, k, NULL, NULL, NULL) == 1 &&
        EC_POINT_point2oct(g, pt, POINT_CONVERSION_UNCOMPRESSED, pub, 65, NULL) == 65)
        ok = 1;
    EC_POINT_free(pt);
    BN_clear_free(k);
    EC_GROUP_free(g);
    return ok ? 0 : -1;
}

/* A P-256 key from a scalar (32 bytes) and/or a point (65 bytes). */
static EVP_PKEY *sl_crypto_p256_key(const unsigned char *d, const unsigned char *pub) {
    EVP_PKEY *pkey = NULL;
    BIGNUM *bn = d ? BN_bin2bn(d, 32, NULL) : NULL;
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new();
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *ctx = NULL;
    if (!bld || (d && !bn))
        goto done;
    if (!OSSL_PARAM_BLD_push_utf8_string(bld, OSSL_PKEY_PARAM_GROUP_NAME, "P-256", 0))
        goto done;
    if (pub && !OSSL_PARAM_BLD_push_octet_string(bld, OSSL_PKEY_PARAM_PUB_KEY, pub, 65))
        goto done;
    if (bn && !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_PRIV_KEY, bn))
        goto done;
    params = OSSL_PARAM_BLD_to_param(bld);
    ctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL);
    if (!params || !ctx || EVP_PKEY_fromdata_init(ctx) != 1 ||
        EVP_PKEY_fromdata(ctx, &pkey, d ? EVP_PKEY_KEYPAIR : EVP_PKEY_PUBLIC_KEY,
                          params) != 1)
        pkey = NULL;
done:
    EVP_PKEY_CTX_free(ctx);
    OSSL_PARAM_free(params);
    OSSL_PARAM_BLD_free(bld);
    BN_clear_free(bn);
    return pkey;
}

static sl_res_bytes_str *sl_crypto_ecdsa_p256_generate(void) {
    SL_CRYPTO_STACK();
    unsigned char d[32];
    sl_rt_preempt_disable();
    EVP_PKEY *k = EVP_PKEY_Q_keygen(NULL, NULL, "EC", "P-256");
    BIGNUM *bn = NULL;
    int ok = k && EVP_PKEY_get_bn_param(k, OSSL_PKEY_PARAM_PRIV_KEY, &bn) == 1 &&
             BN_bn2binpad(bn, d, 32) == 32;
    BN_clear_free(bn);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok)
        return sl_crypto_err_bytes("ecdsa: key generation failed");
    sl_bytes *b = sl_bytes_new(d, 32);
    OPENSSL_cleanse(d, sizeof d);
    return sl_crypto_ok_bytes(b);
}

static sl_res_bytes_str *sl_crypto_ecdsa_p256_public_key(sl_bytes *priv) {
    SL_CRYPTO_STACK();
    if (priv->len != 32)
        return sl_crypto_errf_bytes("ecdsa: P-256 private key must be 32 bytes, got %lld",
                                    priv->len, 0);
    unsigned char pub[65];
    sl_rt_preempt_disable();
    int rc = sl_crypto_p256_point(priv->ptr, pub);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (rc)
        return sl_crypto_err_bytes("ecdsa: invalid P-256 private key");
    return sl_crypto_ok_bytes(sl_bytes_new(pub, 65));
}

/* r || s, each 32 bytes big-endian: the JWS (ES256) and WebCrypto form. */
static sl_res_bytes_str *sl_crypto_ecdsa_p256_sign_sha256(sl_bytes *priv, sl_bytes *msg) {
    SL_CRYPTO_STACK();
    if (priv->len != 32)
        return sl_crypto_errf_bytes("ecdsa: P-256 private key must be 32 bytes, got %lld",
                                    priv->len, 0);
    unsigned char raw[64];
    const char *fail = NULL;
    static const unsigned char empty = 0;
    sl_rt_preempt_disable();
    unsigned char pub[65];
    EVP_PKEY *k = NULL;
    EVP_MD_CTX *ctx = NULL;
    unsigned char *der = NULL;
    ECDSA_SIG *es = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    size_t dlen = 0;
    k = sl_keycache_get(SL_KC_P256_PRIV, priv->ptr, 32);
    if (!k) {
        if (sl_crypto_p256_point(priv->ptr, pub) != 0 ||
            !(k = sl_crypto_p256_key(priv->ptr, pub))) {
            fail = "ecdsa: invalid P-256 private key";
            goto done;
        }
        sl_keycache_put(SL_KC_P256_PRIV, priv->ptr, 32, k);
    }
    ctx = EVP_MD_CTX_new();
    if (!ctx || EVP_DigestSignInit_ex(ctx, &pctx, "SHA256", NULL, NULL, k, NULL) != 1) {
        fail = "ecdsa: could not start signing";
        goto done;
    }
#if OPENSSL_VERSION_NUMBER >= 0x30200000L
    {
        /* RFC 6979: the nonce derives from the key and the message, so a
           weak or failing RNG cannot leak the key through a signature. */
        unsigned int det = 1;
        OSSL_PARAM p[2];
        p[0] = OSSL_PARAM_construct_uint(OSSL_SIGNATURE_PARAM_NONCE_TYPE, &det);
        p[1] = OSSL_PARAM_construct_end();
        if (EVP_PKEY_CTX_set_params(pctx, p) != 1) {
            fail = "ecdsa: could not select deterministic nonces";
            goto done;
        }
    }
#endif
    if (EVP_DigestSign(ctx, NULL, &dlen, msg->len ? msg->ptr : &empty,
                       (size_t)msg->len) != 1 ||
        !(der = OPENSSL_malloc(dlen)) ||
        EVP_DigestSign(ctx, der, &dlen, msg->len ? msg->ptr : &empty,
                       (size_t)msg->len) != 1) {
        fail = "ecdsa: signing failed";
        goto done;
    }
    {
        const unsigned char *pp = der;
        es = d2i_ECDSA_SIG(NULL, &pp, (long)dlen);
        const BIGNUM *r = NULL, *s = NULL;
        if (es)
            ECDSA_SIG_get0(es, &r, &s);
        if (!es || BN_bn2binpad(r, raw, 32) != 32 || BN_bn2binpad(s, raw + 32, 32) != 32)
            fail = "ecdsa: could not encode the signature";
    }
done:
    ECDSA_SIG_free(es);
    OPENSSL_free(der);
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail)
        return sl_crypto_err_bytes(fail);
    return sl_crypto_ok_bytes(sl_bytes_new(raw, 64));
}

static sl_res_bool_str *sl_crypto_ecdsa_p256_verify_sha256(sl_bytes *pub, sl_bytes *msg,
                                                           sl_bytes *sig) {
    SL_CRYPTO_STACK();
    if (pub->len != 65 || pub->ptr[0] != 0x04)
        return sl_crypto_err_bool("ecdsa: P-256 public key must be 65 bytes, uncompressed (0x04 || x || y)");
    if (sig->len != 64)
        return sl_crypto_ok_bool(false);
    static const unsigned char empty = 0;
    int keyok = 0, ok = 0;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_keycache_get(SL_KC_P256_PUB, pub->ptr, 65);
    if (!k) {
        k = sl_crypto_p256_key(NULL, pub->ptr);
        sl_keycache_put(SL_KC_P256_PUB, pub->ptr, 65, k);
    }
    EVP_MD_CTX *ctx = NULL;
    ECDSA_SIG *es = ECDSA_SIG_new();
    BIGNUM *r = BN_bin2bn(sig->ptr, 32, NULL);
    BIGNUM *s = BN_bin2bn(sig->ptr + 32, 32, NULL);
    unsigned char *der = NULL;
    int dlen = 0;
    keyok = k != NULL;
    if (keyok && es && r && s && ECDSA_SIG_set0(es, r, s) == 1) {
        r = s = NULL; /* owned by es now */
        dlen = i2d_ECDSA_SIG(es, &der);
        ctx = EVP_MD_CTX_new();
        ok = dlen > 0 && ctx &&
             EVP_DigestVerifyInit_ex(ctx, NULL, "SHA256", NULL, NULL, k, NULL) == 1 &&
             EVP_DigestVerify(ctx, der, (size_t)dlen, msg->len ? msg->ptr : &empty,
                              (size_t)msg->len) == 1;
    }
    BN_free(r);
    BN_free(s);
    OPENSSL_free(der);
    ECDSA_SIG_free(es);
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!keyok)
        return sl_crypto_err_bool("ecdsa: invalid P-256 public key (not on the curve)");
    return sl_crypto_ok_bool(ok);
}

static int sl_crypto_is_p256(EVP_PKEY *k) {
    char name[32];
    size_t n = 0;
    return k && EVP_PKEY_is_a(k, "EC") &&
           EVP_PKEY_get_utf8_string_param(k, OSSL_PKEY_PARAM_GROUP_NAME, name,
                                          sizeof name, &n) == 1 &&
           (!strcmp(name, "prime256v1") || !strcmp(name, "P-256"));
}

static sl_res_bytes_str *sl_crypto_ecdsa_p256_private_from_pem(const char *pem) {
    SL_CRYPTO_STACK();
    unsigned char d[32];
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(pem, 1);
    BIGNUM *bn = NULL;
    int is = sl_crypto_is_p256(k);
    int ok = is && EVP_PKEY_get_bn_param(k, OSSL_PKEY_PARAM_PRIV_KEY, &bn) == 1 &&
             BN_bn2binpad(bn, d, 32) == 32;
    BN_clear_free(bn);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok) {
        OPENSSL_cleanse(d, sizeof d);
        return sl_crypto_err_bytes(is ? "ecdsa: could not read the key"
                                      : "ecdsa: not a P-256 private key in PEM form");
    }
    sl_bytes *b = sl_bytes_new(d, 32);
    OPENSSL_cleanse(d, sizeof d);
    return sl_crypto_ok_bytes(b);
}

static sl_res_bytes_str *sl_crypto_ecdsa_p256_public_from_pem(const char *pem) {
    SL_CRYPTO_STACK();
    unsigned char pub[65];
    size_t n = 0;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(pem, 0);
    int is = sl_crypto_is_p256(k);
    int ok = 0;
    if (is) {
        /* the stored point may be compressed: ask for it uncompressed */
        EVP_PKEY_set_utf8_string_param(k, OSSL_PKEY_PARAM_EC_POINT_CONVERSION_FORMAT,
                                       "uncompressed");
        ok = EVP_PKEY_get_octet_string_param(k, OSSL_PKEY_PARAM_PUB_KEY, pub,
                                             sizeof pub, &n) == 1 &&
             n == 65 && pub[0] == 0x04;
    }
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!ok)
        return sl_crypto_err_bytes(is ? "ecdsa: could not read the key"
                                      : "ecdsa: not a P-256 key in PEM form");
    return sl_crypto_ok_bytes(sl_bytes_new(pub, 65));
}

/* ---- RSA ---- */

static sl_res_str_str *sl_crypto_ok_str(const char *s) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(sizeof(sl_res_str_str),
                                                      sl_gc_trace_sl_res_str_str);
    r->ok = true;
    r->v = s;
    return r;
}

static sl_res_str_str *sl_crypto_err_str(const char *msg) {
    sl_res_str_str *r = (sl_res_str_str *)sl_gc_alloc(sizeof(sl_res_str_str),
                                                      sl_gc_trace_sl_res_str_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* A new key, as a PKCS#8 PEM private key. Generation takes tens of
   milliseconds at 2048 bits and seconds at 4096, without yielding: do it
   at startup or in a tool, not per request. */
static sl_res_str_str *sl_crypto_rsa_generate(long long bits) {
    SL_CRYPTO_STACK();
    if (bits < 2048 || bits > 8192 || bits % 8)
        return sl_crypto_err_str("rsa: key size must be a multiple of 8 from 2048 to 8192 bits");
    char *pem = NULL;
    sl_rt_preempt_disable();
    EVP_PKEY *k = EVP_PKEY_Q_keygen(NULL, NULL, "RSA", (size_t)bits);
    BIO *bio = BIO_new(BIO_s_mem());
    char *data = NULL;
    long len = 0;
    if (k && bio && PEM_write_bio_PrivateKey(bio, k, NULL, NULL, 0, NULL, NULL) == 1)
        len = BIO_get_mem_data(bio, &data);
    if (len > 0) {
        pem = (char *)malloc((size_t)len + 1);
        if (pem) {
            memcpy(pem, data, (size_t)len);
            pem[len] = 0;
        }
    }
    BIO_free(bio);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!pem)
        return sl_crypto_err_str("rsa: key generation failed");
    char *out = (char *)sl_gc_alloc_leaf_uninit((size_t)len + 1, NULL);
    memcpy(out, pem, (size_t)len + 1);
    sl_rt_preempt_disable();
    OPENSSL_cleanse(pem, (size_t)len);
    free(pem);
    sl_rt_preempt_enable();
    return sl_crypto_ok_str(out);
}

/* A raw private key as PKCS#8 PEM ("PRIVATE KEY"), the form
   net.tls_ctx_use_cert, x509 and *_from_pem take. ecdsa_p256_generate and
   ed25519_generate return raw keys because the signing calls take them;
   this is the way from one to the other. */
static sl_res_str_str *sl_crypto_key_pem(EVP_PKEY *k, const char *what) {
    char *pem = NULL;
    long len = 0;
    BIO *b = k ? BIO_new(BIO_s_mem()) : NULL;
    if (b && PEM_write_bio_PrivateKey(b, k, NULL, NULL, 0, NULL, NULL) == 1) {
        char *p = NULL;
        len = BIO_get_mem_data(b, &p);
        if (len > 0 && (pem = (char *)malloc((size_t)len + 1)) != NULL) {
            memcpy(pem, p, (size_t)len);
            pem[len] = '\0';
        }
        OPENSSL_cleanse(p, (size_t)len);
    }
    BIO_free(b);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (!pem)
        return sl_crypto_err_str(what);
    char *out = (char *)sl_gc_alloc_leaf_uninit((size_t)len + 1, NULL);
    memcpy(out, pem, (size_t)len + 1);
    sl_rt_preempt_disable();
    OPENSSL_cleanse(pem, (size_t)len);
    free(pem);
    sl_rt_preempt_enable();
    return sl_crypto_ok_str(out);
}

static sl_res_str_str *sl_crypto_ecdsa_p256_private_to_pem(sl_bytes *d) {
    SL_CRYPTO_STACK();
    if (d->len != 32)
        return sl_crypto_err_str("ecdsa: private key must be 32 bytes");
    unsigned char pub[65];
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_p256_point(d->ptr, pub) == 0 ? sl_crypto_p256_key(d->ptr, pub) : NULL;
    return sl_crypto_key_pem(k, "ecdsa: not a valid P-256 private key");
}

static sl_res_str_str *sl_crypto_ed25519_private_to_pem(sl_bytes *seed) {
    SL_CRYPTO_STACK();
    if (seed->len != 32)
        return sl_crypto_err_str("ed25519: private key must be 32 bytes");
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_ed25519_private(seed);
    return sl_crypto_key_pem(k, "ed25519: could not encode the key");
}

/* The modulus (which = 0) or public exponent (1) of an RSA key in PEM,
   big-endian: what a JWKS entry's n and e encode. */
static sl_res_bytes_str *sl_crypto_rsa_public_part(const char *pem, int which) {
    SL_CRYPTO_STACK();
    unsigned char buf[1024];
    int n = -1;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(pem, 0);
    BIGNUM *bn = NULL;
    int is = k && EVP_PKEY_is_a(k, "RSA");
    if (is && EVP_PKEY_get_bn_param(k, which ? OSSL_PKEY_PARAM_RSA_E : OSSL_PKEY_PARAM_RSA_N,
                                    &bn) == 1 &&
        BN_num_bytes(bn) <= (int)sizeof buf)
        n = BN_bn2bin(bn, buf);
    BN_free(bn);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (n <= 0)
        return sl_crypto_err_bytes(is ? "rsa: could not read the key"
                                      : "rsa: not an RSA key in PEM form");
    return sl_crypto_ok_bytes(sl_bytes_new(buf, n));
}

static sl_res_bytes_str *sl_crypto_rsa_public_n(const char *pem) {
    return sl_crypto_rsa_public_part(pem, 0);
}

static sl_res_bytes_str *sl_crypto_rsa_public_e(const char *pem) {
    return sl_crypto_rsa_public_part(pem, 1);
}

/* SHA-256 signature with an RSA private key in PEM: PKCS#1 v1.5 (JWS
   RS256) or PSS with MGF1-SHA256 and a 32-byte salt (JWS PS256). */
static sl_res_bytes_str *sl_crypto_rsa_sign(const char *pem, sl_bytes *msg, int pss) {
    SL_CRYPTO_STACK();
    const char *fail = NULL;
    unsigned char *sig = NULL;
    size_t slen = 0;
    static const unsigned char empty = 0;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(pem, 1);
    EVP_MD_CTX *ctx = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    if (!k || !EVP_PKEY_is_a(k, "RSA")) {
        fail = "rsa: not an RSA private key in PEM form";
        goto done;
    }
    if (EVP_PKEY_get_bits(k) < 2048 || EVP_PKEY_get_bits(k) > 8192) {
        fail = "rsa: key must be 2048 to 8192 bits";
        goto done;
    }
    ctx = EVP_MD_CTX_new();
    if (!ctx || EVP_DigestSignInit_ex(ctx, &pctx, "SHA256", NULL, NULL, k, NULL) != 1) {
        fail = "rsa: could not start signing";
        goto done;
    }
    if (pss && (EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) != 1 ||
                EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) != 1)) {
        fail = "rsa: could not select PSS";
        goto done;
    }
    if (EVP_DigestSign(ctx, NULL, &slen, msg->len ? msg->ptr : &empty,
                       (size_t)msg->len) != 1 ||
        !(sig = OPENSSL_malloc(slen)) ||
        EVP_DigestSign(ctx, sig, &slen, msg->len ? msg->ptr : &empty,
                       (size_t)msg->len) != 1) {
        fail = "rsa: signing failed";
        goto done;
    }
done:
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail) {
        if (sig) {
            sl_rt_preempt_disable();
            OPENSSL_free(sig);
            sl_rt_preempt_enable();
        }
        return sl_crypto_err_bytes(fail);
    }
    sl_bytes *b = sl_bytes_new(sig, (long long)slen);
    sl_rt_preempt_disable();
    OPENSSL_free(sig);
    sl_rt_preempt_enable();
    return sl_crypto_ok_bytes(b);
}

static sl_res_bytes_str *sl_crypto_rsa_sign_sha256(const char *pem, sl_bytes *msg) {
    return sl_crypto_rsa_sign(pem, msg, 0);
}

static sl_res_bytes_str *sl_crypto_rsa_sign_pss_sha256(const char *pem, sl_bytes *msg) {
    return sl_crypto_rsa_sign(pem, msg, 1);
}

/* ---- RSA-OAEP ----
 *
 * Encryption to an RSA public key, and decryption with the private one,
 * with OAEP padding over SHA-1 or SHA-256 (the hash used for both the
 * label and MGF1). SHA-1 OAEP is what MySQL's caching_sha2_password and
 * sha256_password expect for the password they encrypt to the server's
 * key; SHA-256 is the choice for anything new. OAEP's own security does
 * not rest on the hash's collision resistance, so SHA-1 here is not the
 * weakness it is in a signature. */
static sl_res_bytes_str *sl_crypto_rsa_oaep(const char *pem, sl_bytes *data, int decrypt,
                                            const char *md) {
    SL_CRYPTO_STACK();
    const char *fail = NULL;
    unsigned char *out = NULL;
    size_t olen = 0;
    static const unsigned char empty = 0;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(pem, decrypt);
    EVP_PKEY_CTX *ctx = NULL;
    if (!k || !EVP_PKEY_is_a(k, "RSA")) {
        fail = decrypt ? "rsa: not an RSA private key in PEM form" : "rsa: not an RSA public key in PEM form";
        goto done;
    }
    if (EVP_PKEY_get_bits(k) < 1024 || EVP_PKEY_get_bits(k) > 16384) {
        fail = "rsa: key must be 1024 to 16384 bits";
        goto done;
    }
    ctx = EVP_PKEY_CTX_new(k, NULL);
    if (!ctx || (decrypt ? EVP_PKEY_decrypt_init(ctx) : EVP_PKEY_encrypt_init(ctx)) != 1 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING) != 1 ||
        EVP_PKEY_CTX_set_rsa_oaep_md_name(ctx, md, NULL) != 1 ||
        EVP_PKEY_CTX_set_rsa_mgf1_md_name(ctx, md, NULL) != 1) {
        fail = "rsa: could not set up OAEP";
        goto done;
    }
    const unsigned char *in = data && data->len ? data->ptr : &empty;
    size_t inlen = data ? (size_t)data->len : 0;
    int rc = decrypt ? EVP_PKEY_decrypt(ctx, NULL, &olen, in, inlen)
                     : EVP_PKEY_encrypt(ctx, NULL, &olen, in, inlen);
    if (rc != 1 || !(out = OPENSSL_malloc(olen ? olen : 1))) {
        fail = decrypt ? "rsa: decryption failed" : "rsa: the message is too long for the key";
        goto done;
    }
    rc = decrypt ? EVP_PKEY_decrypt(ctx, out, &olen, in, inlen)
                 : EVP_PKEY_encrypt(ctx, out, &olen, in, inlen);
    if (rc != 1)
        fail = decrypt ? "rsa: decryption failed" : "rsa: the message is too long for the key";
done:
    EVP_PKEY_CTX_free(ctx);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail) {
        if (out) {
            sl_rt_preempt_disable();
            OPENSSL_free(out);
            sl_rt_preempt_enable();
        }
        return sl_crypto_err_bytes(fail);
    }
    sl_bytes *b = sl_bytes_new(out, (long long)olen);
    sl_rt_preempt_disable();
    OPENSSL_free(out);
    sl_rt_preempt_enable();
    return sl_crypto_ok_bytes(b);
}

static sl_res_bytes_str *sl_crypto_rsa_encrypt_oaep_sha1(const char *pem, sl_bytes *data) {
    return sl_crypto_rsa_oaep(pem, data, 0, "SHA1");
}
static sl_res_bytes_str *sl_crypto_rsa_decrypt_oaep_sha1(const char *pem, sl_bytes *data) {
    return sl_crypto_rsa_oaep(pem, data, 1, "SHA1");
}
static sl_res_bytes_str *sl_crypto_rsa_encrypt_oaep_sha256(const char *pem, sl_bytes *data) {
    return sl_crypto_rsa_oaep(pem, data, 0, "SHA256");
}
static sl_res_bytes_str *sl_crypto_rsa_decrypt_oaep_sha256(const char *pem, sl_bytes *data) {
    return sl_crypto_rsa_oaep(pem, data, 1, "SHA256");
}
