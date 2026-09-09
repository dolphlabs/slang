#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

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
    unsigned char hash[SHA256_DIGEST_LENGTH];
    sl_rt_preempt_disable();
    SHA256(input->ptr, (size_t)input->len, hash);
    sl_rt_preempt_enable();
    return sl_bytes_new(hash, SHA256_DIGEST_LENGTH);
}

static sl_bytes *sl_crypto_hmac_sha256(sl_bytes *key, sl_bytes *message) {
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