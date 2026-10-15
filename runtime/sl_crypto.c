#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/evp.h>
#include <openssl/core_names.h>
#include <openssl/kdf.h>
#include <openssl/params.h>
#include <openssl/crypto.h>
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

static sl_bytes *sl_crypto_sha256(sl_bytes *input) {
    SL_CRYPTO_STACK();
    unsigned char hash[SHA256_DIGEST_LENGTH];
    sl_rt_preempt_disable();
    SHA256(input->ptr, (size_t)input->len, hash);
    sl_rt_preempt_enable();
    return sl_bytes_new(hash, SHA256_DIGEST_LENGTH);
}

static sl_bytes *sl_crypto_hmac_sha256(sl_bytes *key, sl_bytes *message) {
    SL_CRYPTO_STACK();
    unsigned char hash[SHA256_DIGEST_LENGTH];
    sl_rt_preempt_disable();
    int ok = HMAC(EVP_sha256(), key->ptr, (int)key->len, message->ptr,
                  (size_t)message->len, hash, NULL) != NULL;
    sl_rt_preempt_enable();
    if (!ok)
        return NULL;
    return sl_bytes_new(hash, SHA256_DIGEST_LENGTH);
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
 * concurrent call owns its context and its bounded work memory. */
static int sl_crypto_argon2id_derive(const unsigned char *password,
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

    sl_rt_preempt_disable();
    int once_rc = pthread_once(&sl_crypto_argon2id_once,
                               sl_crypto_argon2id_load);
    if (once_rc != 0 || !sl_crypto_argon2id_kdf) {
        sl_rt_preempt_enable();
        return -2;
    }
    EVP_KDF_CTX *ctx = EVP_KDF_CTX_new(sl_crypto_argon2id_kdf);
    if (!ctx) {
        sl_rt_preempt_enable();
        return -1;
    }
    int ok = EVP_KDF_derive(ctx, out, out_len, params) == 1;
    EVP_KDF_CTX_free(ctx);
    sl_rt_preempt_enable();
    return ok ? 1 : 0;
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
