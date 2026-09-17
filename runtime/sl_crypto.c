#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/evp.h>

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

static sl_res_bytes_str *sl_crypto_rand(long long n) {
    SL_CRYPTO_STACK();
    if (n < 0 || n > 1024 * 1024)
        return sl_crypto_err_bytes("invalid size: must be between 0 and 1MB");
    if (n == 0)
        return sl_crypto_ok_bytes(sl_bytes_new(NULL, 0));

    sl_rt_preempt_disable();
    unsigned char *tmp = (unsigned char *)malloc((size_t)n);
    sl_rt_preempt_enable();
    if (!tmp)
        return sl_crypto_err_bytes("out of memory");
    sl_rt_preempt_disable();
    int rc = RAND_bytes(tmp, (int)n);
    sl_rt_preempt_enable();
    if (rc != 1) {
        free(tmp);
        return sl_crypto_err_bytes("RAND_bytes failed");
    }
    sl_bytes *out = sl_bytes_new(tmp, n);
    free(tmp);
    return sl_crypto_ok_bytes(out);
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
