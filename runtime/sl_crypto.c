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
