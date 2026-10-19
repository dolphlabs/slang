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
    unsigned char *password;
    size_t password_len;
    unsigned char *salt;
    size_t salt_len;
    uint32_t iterations;
    uint32_t memory_kib;
    uint32_t parallelism;
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
        j->rc = sl_crypto_argon2id_derive_raw(
            j->password, j->password_len, j->salt, j->salt_len,
            j->iterations, j->memory_kib, j->parallelism, j->tag, j->tag_len);
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

static int sl_crypto_argon2id_offload(const unsigned char *password,
                                      size_t password_len,
                                      const unsigned char *salt,
                                      size_t salt_len,
                                      uint32_t iterations,
                                      uint32_t memory_kib,
                                      uint32_t parallelism,
                                      unsigned char *out,
                                      size_t out_len) {
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
    job->iterations = iterations;
    job->memory_kib = memory_kib;
    job->parallelism = parallelism;
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
        sl_rt_panic("argon2id: kdf thread wake failed", "crypto");
    }
    close(pfd[0]);
    int rc = job->rc;
    if (rc == 1)
        memcpy(out, job->tag, out_len);
    sl_kdf_job_free(job);
    return rc;
}
#endif

static int sl_crypto_argon2id_derive(const unsigned char *password,
                                     size_t password_len,
                                     const unsigned char *salt,
                                     size_t salt_len,
                                     uint32_t iterations,
                                     uint32_t memory_kib,
                                     uint32_t parallelism,
                                     unsigned char *out,
                                     size_t out_len) {
#ifdef SL_HAVE_REACTOR
    int off = sl_crypto_argon2id_offload(password, password_len, salt,
                                         salt_len, iterations, memory_kib,
                                         parallelism, out, out_len);
    if (off != SL_KDF_NO_OFFLOAD)
        return off;
#endif
    sl_rt_preempt_disable();
    int rc = sl_crypto_argon2id_derive_raw(password, password_len, salt,
                                           salt_len, iterations, memory_kib,
                                           parallelism, out, out_len);
    sl_rt_preempt_enable();
    return rc;
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

/* RSASSA-PKCS1-v1_5 with SHA-256 (JWS "RS256"), the key given as its raw
 * big-endian modulus and exponent: exactly what a JWKS entry's `n` and `e`
 * decode to, so no PEM or DER parsing is needed. The modulus is bounded so
 * a key fetched from someone else's server cannot ask for unbounded work. */
#define SL_RSA_MIN_MODULUS_BYTES 256
#define SL_RSA_MAX_MODULUS_BYTES 1024
#define SL_RSA_MAX_EXPONENT_BYTES 8

static sl_res_bool_str *sl_crypto_rsa_verify_sha256(sl_bytes *n, sl_bytes *e,
                                                    sl_bytes *msg,
                                                    sl_bytes *sig) {
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
