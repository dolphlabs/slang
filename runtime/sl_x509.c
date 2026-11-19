/* sl_x509.c -- X.509 natives behind stdlib/x509: parse, check a host,
 * verify a chain, and make CSRs and self-signed certificates.
 *
 * Emitted after sl_crypto.c, and only when a program calls a
 * crypto.x509_* function (codegen's want_x509), so it shares that file's
 * helpers: SL_CRYPTO_STACK, the result constructors, the one-time fetch
 * and sl_crypto_pem_key. OpenSSL does every byte of ASN.1; nothing here
 * parses DER itself.
 *
 * Every native reserves the dyld-sized stack first and runs the
 * one-time fetch before the first decode (see sl_crypto_pem_key for why
 * that order matters), then works inside the preempt bracket. Strings
 * for the collector are made only after the bracket closes, from C
 * copies taken inside it. */

#include <arpa/inet.h>
#include <ctype.h>
#include <strings.h>
#include <sys/socket.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

/* OpenSSL 4.1 deprecated ASN1_STRING_length and ASN1_STRING_set for
 * size_t replacements that 3.x does not have. */
#if OPENSSL_VERSION_NUMBER >= 0x40100000L
#define SL_ASN1_LEN(s) ((int)ASN1_STRING_get_length(s))
#define SL_ASN1_SET(s, p, n) ASN1_STRING_set1_data((s), (const uint8_t *)(p), (size_t)(n))
#else
#define SL_ASN1_LEN(s) ASN1_STRING_length(s)
#define SL_ASN1_SET(s, p, n) ASN1_STRING_set((s), (p), (int)(n))
#endif

static void sl_x509_init(void) {
    pthread_once(&sl_crypto_fetch_once, sl_crypto_fetch_all);
}

/* ---- growable C buffers, used inside the bracket ---- */

typedef struct {
    char **v;
    int n, cap;
    int oom;
} sl_x509_strs;

static void sl_x509_strs_push(sl_x509_strs *s, char *str) {
    if (!str) {
        s->oom = 1;
        return;
    }
    if (s->n == s->cap) {
        int cap = s->cap ? s->cap * 2 : 32;
        char **v = (char **)realloc(s->v, (size_t)cap * sizeof(char *));
        if (!v) {
            free(str);
            s->oom = 1;
            return;
        }
        s->v = v;
        s->cap = cap;
    }
    s->v[s->n++] = str;
}

static void sl_x509_strs_pushf(sl_x509_strs *s, const char *prefix,
                               const char *body, size_t blen) {
    size_t plen = strlen(prefix);
    char *str = (char *)malloc(plen + blen + 1);
    if (str) {
        memcpy(str, prefix, plen);
        memcpy(str + plen, body, blen);
        str[plen + blen] = '\0';
    }
    sl_x509_strs_push(s, str);
}

static void sl_x509_strs_free(sl_x509_strs *s) {
    for (int i = 0; i < s->n; i++)
        free(s->v[i]);
    free(s->v);
}

/* The list result, built after the bracket: the array is rooted while
 * each string is copied into the collector's heap. */
static sl_res__str__str *sl_x509_ok_list(sl_x509_strs *s) {
    sl_arr *a = sl_arr_new(sizeof(char *), 1);
    void *roots[] = {(void *)a};
    sl_safepoint sp;
    sl_rt_safepoint_enter(&sp, roots, 1);
    for (int i = 0; i < s->n; i++) {
        char *g = sl_strdup(s->v[i]);
        sl_arr_push(a, &g, sizeof(char *));
    }
    sl_rt_safepoint_exit();
    sl_res__str__str *r = (sl_res__str__str *)sl_gc_alloc(
        sizeof(sl_res__str__str), sl_gc_trace_sl_res__str__str);
    r->ok = true;
    r->v = a;
    return r;
}

static sl_res__str__str *sl_x509_err_list(const char *msg) {
    sl_res__str__str *r = (sl_res__str__str *)sl_gc_alloc(
        sizeof(sl_res__str__str), sl_gc_trace_sl_res__str__str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* A memory BIO's contents as a malloc'd NUL-terminated string. */
static char *sl_x509_bio_str(BIO *b) {
    char *p = NULL;
    long n = BIO_get_mem_data(b, &p);
    char *s = (char *)malloc((size_t)(n > 0 ? n : 0) + 1);
    if (!s)
        return NULL;
    if (n > 0)
        memcpy(s, p, (size_t)n);
    s[n > 0 ? n : 0] = '\0';
    return s;
}

/* Days from 1970-01-01 to y-m-d (proleptic Gregorian). timegm is not in
 * C11 and needs feature macros on glibc. */
static long long sl_x509_days(long long y, unsigned m, unsigned d) {
    y -= m <= 2;
    long long era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long long)doe - 719468;
}

static int sl_x509_unix(const ASN1_TIME *t, long long *out) {
    struct tm tm;
    if (!t || ASN1_TIME_to_tm(t, &tm) != 1)
        return 0;
    long long days = sl_x509_days((long long)tm.tm_year + 1900,
                                  (unsigned)tm.tm_mon + 1, (unsigned)tm.tm_mday);
    *out = days * 86400 + tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec;
    return 1;
}

/* RFC 4514 text of a name: most specific attribute first, UTF-8 left
 * as UTF-8. */
static char *sl_x509_name(const X509_NAME *n) {
    BIO *b = BIO_new(BIO_s_mem());
    if (!b)
        return NULL;
    char *s = NULL;
    if (X509_NAME_print_ex(b, n, 0, XN_FLAG_RFC2253 & ~ASN1_STRFLGS_ESC_MSB) >= 0)
        s = sl_x509_bio_str(b);
    BIO_free(b);
    return s;
}

static char *sl_x509_cn(const X509_NAME *n) {
    int at = -1, i;
    while ((i = X509_NAME_get_index_by_NID(n, NID_commonName, at)) >= 0)
        at = i;
    if (at < 0)
        return strdup("");
    unsigned char *u = NULL;
    int len = ASN1_STRING_to_UTF8(&u, X509_NAME_ENTRY_get_data(X509_NAME_get_entry(n, at)));
    if (len < 0)
        return strdup("");
    char *s = (char *)malloc((size_t)len + 1);
    if (s) {
        memcpy(s, u, (size_t)len);
        s[len] = '\0';
    }
    OPENSSL_free(u);
    return s;
}

static char *sl_x509_serial(X509 *x) {
    BIGNUM *bn = ASN1_INTEGER_to_BN(X509_get0_serialNumber(x), NULL);
    char *hex = bn ? BN_bn2hex(bn) : NULL;
    BN_free(bn);
    if (!hex)
        return NULL;
    char *s = strdup(hex);
    OPENSSL_free(hex);
    if (s)
        for (char *p = s; *p; p++)
            *p = (char)tolower((unsigned char)*p);
    return s;
}

static char *sl_x509_key_type(EVP_PKEY *k) {
    if (EVP_PKEY_is_a(k, "RSA"))
        return strdup("rsa");
    if (EVP_PKEY_is_a(k, "ED25519"))
        return strdup("ed25519");
    if (EVP_PKEY_is_a(k, "ED448"))
        return strdup("ed448");
    if (EVP_PKEY_is_a(k, "EC")) {
        char g[64];
        size_t gl = 0;
        if (EVP_PKEY_get_group_name(k, g, sizeof g, &gl) != 1)
            return strdup("ec");
        if (!strcmp(g, "prime256v1") || !strcmp(g, "P-256"))
            return strdup("ec-p256");
        if (!strcmp(g, "secp384r1") || !strcmp(g, "P-384"))
            return strdup("ec-p384");
        if (!strcmp(g, "secp521r1") || !strcmp(g, "P-521"))
            return strdup("ec-p521");
        char *s = (char *)malloc(strlen(g) + 4);
        if (s)
            sprintf(s, "ec-%s", g);
        return s;
    }
    const char *n = EVP_PKEY_get0_type_name(k);
    return strdup(n ? n : "unknown");
}

static const char *sl_x509_eku_name(int nid) {
    switch (nid) {
    case NID_server_auth: return "server_auth";
    case NID_client_auth: return "client_auth";
    case NID_code_sign: return "code_signing";
    case NID_email_protect: return "email_protection";
    case NID_time_stamp: return "time_stamping";
    case NID_OCSP_sign: return "ocsp_signing";
    case NID_anyExtendedKeyUsage: return "any";
    default: return NULL;
    }
}

static void sl_x509_push_sans(sl_x509_strs *s, X509 *x) {
    GENERAL_NAMES *gens = (GENERAL_NAMES *)X509_get_ext_d2i(x, NID_subject_alt_name, NULL, NULL);
    if (!gens)
        return;
    for (int i = 0; i < sk_GENERAL_NAME_num(gens); i++) {
        const GENERAL_NAME *g = sk_GENERAL_NAME_value(gens, i);
        const ASN1_STRING *str = NULL;
        const char *tag = NULL;
        switch (g->type) {
        case GEN_DNS: tag = "dns:"; str = g->d.dNSName; break;
        case GEN_EMAIL: tag = "email:"; str = g->d.rfc822Name; break;
        case GEN_URI: tag = "uri:"; str = g->d.uniformResourceIdentifier; break;
        case GEN_IPADD: {
            char ip[INET6_ADDRSTRLEN];
            int len = SL_ASN1_LEN(g->d.iPAddress);
            const unsigned char *b = ASN1_STRING_get0_data(g->d.iPAddress);
            if ((len == 4 && inet_ntop(AF_INET, b, ip, sizeof ip)) ||
                (len == 16 && inet_ntop(AF_INET6, b, ip, sizeof ip)))
                sl_x509_strs_pushf(s, "ip:", ip, strlen(ip));
            continue;
        }
        default: continue;
        }
        sl_x509_strs_pushf(s, tag, (const char *)ASN1_STRING_get0_data(str),
                           (size_t)SL_ASN1_LEN(str));
    }
    GENERAL_NAMES_free(gens);
}

static void sl_x509_push_usages(sl_x509_strs *s, X509 *x) {
    static const struct { uint32_t bit; const char *name; } ku[] = {
        {KU_DIGITAL_SIGNATURE, "digital_signature"},
        {KU_NON_REPUDIATION, "content_commitment"},
        {KU_KEY_ENCIPHERMENT, "key_encipherment"},
        {KU_DATA_ENCIPHERMENT, "data_encipherment"},
        {KU_KEY_AGREEMENT, "key_agreement"},
        {KU_KEY_CERT_SIGN, "cert_sign"},
        {KU_CRL_SIGN, "crl_sign"},
        {KU_ENCIPHER_ONLY, "encipher_only"},
        {KU_DECIPHER_ONLY, "decipher_only"},
    };
    uint32_t bits = X509_get_key_usage(x);
    if (bits != UINT32_MAX)
        for (size_t i = 0; i < sizeof ku / sizeof ku[0]; i++)
            if (bits & ku[i].bit)
                sl_x509_strs_pushf(s, "ku:", ku[i].name, strlen(ku[i].name));
    EXTENDED_KEY_USAGE *eku = (EXTENDED_KEY_USAGE *)X509_get_ext_d2i(x, NID_ext_key_usage, NULL, NULL);
    if (!eku)
        return;
    for (int i = 0; i < sk_ASN1_OBJECT_num(eku); i++) {
        const ASN1_OBJECT *o = sk_ASN1_OBJECT_value(eku, i);
        const char *n = sl_x509_eku_name(OBJ_obj2nid(o));
        char oid[128];
        if (!n && OBJ_obj2txt(oid, sizeof oid, o, 1) > 0)
            n = oid;
        if (n)
            sl_x509_strs_pushf(s, "eku:", n, strlen(n));
    }
    EXTENDED_KEY_USAGE_free(eku);
}

static char *sl_x509_fmt_ll(long long v) {
    char b[32];
    snprintf(b, sizeof b, "%lld", v);
    return strdup(b);
}

/* ---- crypto.x509_der ---- */

/* Every CERTIFICATE block of a PEM text, as concatenated DER. Text
 * outside the blocks (comments, other block types) is skipped, as
 * OpenSSL's PEM reader does; a block that does not decode is an error. */
static sl_res_bytes_str *sl_crypto_x509_der(const char *pem) {
    SL_CRYPTO_STACK();
    if (!pem)
        return sl_crypto_err_bytes("x509: no CERTIFICATE block in the PEM");
    sl_x509_init();
    const char *fail = NULL;
    unsigned char *buf = NULL;
    size_t len = 0, cap = 0;
    int count = 0;
    sl_rt_preempt_disable();
    BIO *b = BIO_new_mem_buf(pem, -1);
    for (X509 *x; b && (x = PEM_read_bio_X509(b, NULL, NULL, NULL)) != NULL;) {
        int n = i2d_X509(x, NULL);
        if (n > 0 && len + (size_t)n > cap) {
            size_t nc = cap ? cap : 4096;
            while (nc < len + (size_t)n)
                nc *= 2;
            unsigned char *nb = (unsigned char *)realloc(buf, nc);
            if (!nb)
                n = -1;
            else {
                buf = nb;
                cap = nc;
            }
        }
        unsigned char *p = buf + len;
        if (n <= 0 || i2d_X509(x, &p) != n) {
            X509_free(x);
            fail = "x509: could not encode a certificate";
            break;
        }
        len += (size_t)n;
        count++;
        X509_free(x);
    }
    if (!fail) {
        unsigned long e = ERR_peek_last_error();
        if (!b)
            fail = "x509: out of memory";
        else if (e && !(ERR_GET_LIB(e) == ERR_LIB_PEM && ERR_GET_REASON(e) == PEM_R_NO_START_LINE))
            fail = "x509: a CERTIFICATE block does not decode";
        else if (count == 0)
            fail = "x509: no CERTIFICATE block in the PEM";
    }
    BIO_free(b);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail) {
        free(buf);
        return sl_crypto_err_bytes(fail);
    }
    sl_bytes *out = sl_bytes_new(buf, (long long)len);
    free(buf);
    return sl_crypto_ok_bytes(out);
}

/* ---- crypto.x509_fields ---- */

/* The first certificate in `der`, as stdlib/x509 reads it: fourteen
 * fixed fields (its DER length, subject, common name, issuer, serial,
 * not_before, not_after, is_ca, max_path_len, key_type, key_bits,
 * public_key_pem, signature_alg, fingerprint), then tagged entries --
 * "dns:", "ip:", "email:", "uri:" for subjectAltName and "ku:", "eku:"
 * for key usages. */
static sl_res__str__str *sl_crypto_x509_fields(sl_bytes *der) {
    SL_CRYPTO_STACK();
    if (!der || der->len <= 0)
        return sl_x509_err_list("x509: empty DER");
    sl_x509_init();
    sl_x509_strs s = {0};
    const char *fail = NULL;
    sl_rt_preempt_disable();
    const unsigned char *p = der->ptr;
    X509 *x = d2i_X509(NULL, &p, (long)der->len);
    if (!x) {
        fail = "x509: not a DER certificate";
    } else {
        long long nb = 0, na = 0;
        EVP_PKEY *k = X509_get0_pubkey(x);
        unsigned char fp[EVP_MAX_MD_SIZE];
        unsigned int fpl = 0;
        if (!sl_x509_unix(X509_get0_notBefore(x), &nb) ||
            !sl_x509_unix(X509_get0_notAfter(x), &na)) {
            fail = "x509: unreadable validity dates";
        } else if (!k) {
            fail = "x509: unsupported public key";
        } else if (X509_digest(x, sl_crypto_md(SL_MD_SHA256), fp, &fpl) != 1) {
            fail = "x509: could not hash the certificate";
        } else {
            sl_x509_strs_push(&s, sl_x509_fmt_ll((long long)(p - der->ptr)));
            sl_x509_strs_push(&s, sl_x509_name(X509_get_subject_name(x)));
            sl_x509_strs_push(&s, sl_x509_cn(X509_get_subject_name(x)));
            sl_x509_strs_push(&s, sl_x509_name(X509_get_issuer_name(x)));
            sl_x509_strs_push(&s, sl_x509_serial(x));
            sl_x509_strs_push(&s, sl_x509_fmt_ll(nb));
            sl_x509_strs_push(&s, sl_x509_fmt_ll(na));
            sl_x509_strs_push(&s, strdup((X509_get_extension_flags(x) & EXFLAG_CA) ? "1" : "0"));
            long pl = X509_get_pathlen(x);
            sl_x509_strs_push(&s, sl_x509_fmt_ll(pl < 0 ? -1 : pl));
            sl_x509_strs_push(&s, sl_x509_key_type(k));
            sl_x509_strs_push(&s, sl_x509_fmt_ll(EVP_PKEY_get_bits(k)));
            BIO *pb = BIO_new(BIO_s_mem());
            sl_x509_strs_push(&s, pb && PEM_write_bio_PUBKEY(pb, k) == 1 ? sl_x509_bio_str(pb) : NULL);
            BIO_free(pb);
            const char *sig = OBJ_nid2ln(X509_get_signature_nid(x));
            sl_x509_strs_push(&s, strdup(sig ? sig : "unknown"));
            char hex[2 * EVP_MAX_MD_SIZE + 1];
            for (unsigned int i = 0; i < fpl; i++)
                snprintf(hex + 2 * i, 3, "%02x", fp[i]);
            hex[2 * fpl] = '\0';
            sl_x509_strs_push(&s, strdup(hex));
            sl_x509_push_sans(&s, x);
            sl_x509_push_usages(&s, x);
            if (s.oom)
                fail = "x509: out of memory";
        }
    }
    X509_free(x);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail) {
        sl_x509_strs_free(&s);
        return sl_x509_err_list(fail);
    }
    sl_res__str__str *r = sl_x509_ok_list(&s);
    sl_x509_strs_free(&s);
    return r;
}

/* ---- crypto.x509_check_host ---- */

static int sl_x509_is_ip(const char *h) {
    unsigned char b[16];
    return inet_pton(AF_INET, h, b) == 1 || inet_pton(AF_INET6, h, b) == 1;
}

/* One DNS SAN against a host, RFC 6125 6.4: ASCII case-insensitive; a
 * wildcard only as the whole left-most label ("*.example.com"), standing
 * for exactly one non-empty label, and never directly under a single
 * label ("*.com"). A trailing dot on the host is ignored. */
static int sl_x509_dns_match(const char *pat, size_t plen, const char *host, size_t hlen) {
    if (plen == 0 || memchr(pat, '\0', plen))
        return 0; /* an embedded NUL is a forged name */
    if (plen >= 2 && pat[0] == '*' && pat[1] == '.') {
        const char *suffix = pat + 1; /* ".example.com" */
        size_t slen = plen - 1;
        if (!memchr(suffix + 1, '.', slen - 1))
            return 0;
        const char *dot = memchr(host, '.', hlen);
        if (!dot || dot == host)
            return 0;
        return (size_t)(host + hlen - dot) == slen && strncasecmp(dot, suffix, slen) == 0;
    }
    return plen == hlen && strncasecmp(pat, host, hlen) == 0;
}

/* subjectAltName only, never the subject CN, which browsers and Go no
 * longer trust for names. An IP literal matches IP entries only, byte
 * for byte, so "::1" and "0:0::1" are one address. OpenSSL 4.1
 * deprecated X509_check_host without a replacement, so this is ours. */
static bool sl_crypto_x509_check_host(sl_bytes *der, const char *host) {
    SL_CRYPTO_STACK();
    if (!der || der->len <= 0 || !host || !host[0] || strchr(host, '*'))
        return false;
    size_t hlen = strlen(host);
    if (host[hlen - 1] == '.')
        hlen--;
    unsigned char ip[16];
    int iplen = inet_pton(AF_INET, host, ip) == 1 ? 4 : inet_pton(AF_INET6, host, ip) == 1 ? 16 : 0;
    sl_x509_init();
    int ok = 0;
    sl_rt_preempt_disable();
    const unsigned char *p = der->ptr;
    X509 *x = d2i_X509(NULL, &p, (long)der->len);
    GENERAL_NAMES *gens = x ? (GENERAL_NAMES *)X509_get_ext_d2i(x, NID_subject_alt_name, NULL, NULL) : NULL;
    for (int i = 0; !ok && gens && i < sk_GENERAL_NAME_num(gens); i++) {
        const GENERAL_NAME *g = sk_GENERAL_NAME_value(gens, i);
        if (iplen && g->type == GEN_IPADD)
            ok = SL_ASN1_LEN(g->d.iPAddress) == iplen &&
                 memcmp(ASN1_STRING_get0_data(g->d.iPAddress), ip, (size_t)iplen) == 0;
        else if (!iplen && hlen && g->type == GEN_DNS)
            ok = sl_x509_dns_match((const char *)ASN1_STRING_get0_data(g->d.dNSName),
                                   (size_t)SL_ASN1_LEN(g->d.dNSName), host, hlen);
    }
    GENERAL_NAMES_free(gens);
    X509_free(x);
    ERR_clear_error();
    sl_rt_preempt_enable();
    return ok;
}

/* ---- crypto.x509_verify ---- */

/* Trust stores, built once and shared: the system's, and the most
 * recent explicit roots. Loading the system bundle parses ~150
 * certificates, far more than one verification costs, and a server
 * checking client certificates passes the same roots every time.
 * X509_STORE is safe to share for verification once built. */
static pthread_mutex_t sl_x509_store_mu = PTHREAD_MUTEX_INITIALIZER;
static X509_STORE *sl_x509_sys_store;
static X509_STORE *sl_x509_roots_store;
static char *sl_x509_roots_pem;

/* A new reference to a store for `roots_pem` ("" for the system's), or
 * NULL with *why set. Called inside the preempt bracket. */
static X509_STORE *sl_x509_store(const char *roots_pem, const char **why) {
    X509_STORE *st = NULL;
    pthread_mutex_lock(&sl_x509_store_mu);
    if (!roots_pem[0]) {
        if (!sl_x509_sys_store) {
            X509_STORE *n = X509_STORE_new();
            if (n && X509_STORE_set_default_paths(n) == 1)
                sl_x509_sys_store = n;
            else
                X509_STORE_free(n);
        }
        st = sl_x509_sys_store;
        if (!st)
            *why = "x509: could not load the system's root certificates";
    } else if (sl_x509_roots_pem && !strcmp(sl_x509_roots_pem, roots_pem)) {
        st = sl_x509_roots_store;
    } else {
        X509_STORE *n = X509_STORE_new();
        BIO *b = BIO_new_mem_buf(roots_pem, -1);
        int count = 0;
        for (X509 *x; n && b && (x = PEM_read_bio_X509(b, NULL, NULL, NULL)) != NULL;) {
            if (X509_STORE_add_cert(n, x) == 1)
                count++;
            X509_free(x);
        }
        BIO_free(b);
        char *copy = strdup(roots_pem);
        if (count == 0 || !copy) {
            X509_STORE_free(n);
            free(copy);
            *why = "x509: no usable CERTIFICATE block in the roots";
        } else {
            X509_STORE_free(sl_x509_roots_store);
            free(sl_x509_roots_pem);
            sl_x509_roots_store = n;
            sl_x509_roots_pem = copy;
            st = n;
        }
    }
    if (st && X509_STORE_up_ref(st) != 1) {
        st = NULL;
        *why = "x509: out of memory";
    }
    pthread_mutex_unlock(&sl_x509_store_mu);
    ERR_clear_error();
    return st;
}

/* Our own words for the failures callers branch on and show: OpenSSL
 * rewords its reason strings between versions (4.1's "unsuitable
 * certificate purpose" was 3.0's "unsupported"), and a message that
 * changes with the machine's OpenSSL is no contract. Anything rarer
 * keeps OpenSSL's text. */
static const char *sl_x509_reason(int code) {
    switch (code) {
    case X509_V_ERR_CERT_HAS_EXPIRED: return "certificate has expired";
    case X509_V_ERR_CERT_NOT_YET_VALID: return "certificate is not yet valid";
    case X509_V_ERR_HOSTNAME_MISMATCH: return "hostname mismatch";
    case X509_V_ERR_IP_ADDRESS_MISMATCH: return "IP address mismatch";
    case X509_V_ERR_INVALID_PURPOSE: return "certificate is not for this purpose";
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT:
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
        return "certificate signed by unknown authority";
    case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
    case X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN:
        return "self-signed certificate not in the roots";
    case X509_V_ERR_CERT_SIGNATURE_FAILURE: return "certificate signature does not verify";
    case X509_V_ERR_INVALID_CA: return "issuer is not a CA";
    case X509_V_ERR_PATH_LENGTH_EXCEEDED: return "path length constraint exceeded";
    default: return X509_verify_cert_error_string(code);
    }
}

/* `chain` is the leaf's DER followed by any intermediates'. ok(true), or
 * OpenSSL's reason the chain does not verify. `at` 0 checks validity
 * now; `purpose` is "server", "client" or "" for none. */
static sl_res_bool_str *sl_crypto_x509_verify(sl_bytes *chain, const char *roots_pem,
                                              const char *host, long long at,
                                              const char *purpose) {
    SL_CRYPTO_STACK();
    int pid = 0;
    if (!purpose || !purpose[0])
        pid = 0;
    else if (!strcmp(purpose, "server"))
        pid = X509_PURPOSE_SSL_SERVER;
    else if (!strcmp(purpose, "client"))
        pid = X509_PURPOSE_SSL_CLIENT;
    else
        return sl_crypto_err_bool("x509: purpose must be \"server\", \"client\" or \"\"");
    if (!chain || chain->len <= 0)
        return sl_crypto_err_bool("x509: no certificate to verify");
    if (at < 0)
        return sl_crypto_err_bool("x509: at must be unix seconds, or 0 for now");
    sl_x509_init();
    const char *fail = NULL;
    char reason[256];
    sl_rt_preempt_disable();
    X509 *leaf = NULL;
    STACK_OF(X509) *rest = sk_X509_new_null();
    const unsigned char *p = chain->ptr, *end = chain->ptr + chain->len;
    while (!fail && p < end) {
        X509 *x = d2i_X509(NULL, &p, (long)(end - p));
        if (!x)
            fail = "x509: the chain holds bytes that are not a DER certificate";
        else if (!leaf)
            leaf = x;
        else if (!rest || !sk_X509_push(rest, x)) {
            X509_free(x);
            fail = "x509: out of memory";
        }
    }
    X509_STORE *st = fail ? NULL : sl_x509_store(roots_pem ? roots_pem : "", &fail);
    X509_STORE_CTX *ctx = st ? X509_STORE_CTX_new() : NULL;
    if (!fail && (!ctx || X509_STORE_CTX_init(ctx, st, leaf, rest) != 1))
        fail = "x509: out of memory";
    if (!fail) {
        X509_VERIFY_PARAM *vp = X509_STORE_CTX_get0_param(ctx);
        if (at > 0)
            X509_VERIFY_PARAM_set_time(vp, (time_t)at);
        if (host && host[0]) {
            int ok = sl_x509_is_ip(host)
                         ? X509_VERIFY_PARAM_set1_ip_asc(vp, host)
                         : X509_VERIFY_PARAM_set1_host(vp, host, strlen(host));
            X509_VERIFY_PARAM_set_hostflags(vp, X509_CHECK_FLAG_NEVER_CHECK_SUBJECT |
                                                    X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
            if (ok != 1)
                fail = "x509: host is not a hostname or IP address";
        }
        if (!fail && pid && X509_STORE_CTX_set_purpose(ctx, pid) != 1)
            fail = "x509: could not set the purpose";
        if (!fail && X509_verify_cert(ctx) != 1) {
            /* Prefixed like every other error here; a local buffer, as
             * another task may fail a verification at the same time. */
            snprintf(reason, sizeof reason, "x509: %s",
                     sl_x509_reason(X509_STORE_CTX_get_error(ctx)));
            fail = reason;
        }
    }
    char msg[256];
    if (fail)
        snprintf(msg, sizeof msg, "%s", fail);
    X509_STORE_CTX_free(ctx);
    X509_STORE_free(st);
    X509_free(leaf);
    sk_X509_pop_free(rest, X509_free);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail)
        return sl_crypto_err_bool(msg);
    return sl_crypto_ok_bool(true);
}

/* ---- crypto.x509_csr, crypto.x509_self_signed ---- */

/* subjectAltName from "DNS:name" and "IP:addr" entries. NULL with *why
 * set on an entry that is neither. */
static GENERAL_NAMES *sl_x509_gens(sl_arr *sans, const char **why) {
    GENERAL_NAMES *gens = sk_GENERAL_NAME_new_null();
    if (!gens) {
        *why = "x509: out of memory";
        return NULL;
    }
    for (long long i = 0; sans && i < sans->len; i++) {
        const char *e = ((char **)sans->data)[i];
        GENERAL_NAME *g = NULL;
        if (e && !strncmp(e, "DNS:", 4) && e[4]) {
            ASN1_IA5STRING *ia5 = ASN1_IA5STRING_new();
            if (ia5 && SL_ASN1_SET(ia5, e + 4, strlen(e + 4)) == 1 &&
                (g = GENERAL_NAME_new()) != NULL)
                GENERAL_NAME_set0_value(g, GEN_DNS, ia5);
            else
                ASN1_IA5STRING_free(ia5);
        } else if (e && !strncmp(e, "IP:", 3)) {
            ASN1_OCTET_STRING *ip = a2i_IPADDRESS(e + 3);
            if (!ip) {
                *why = "x509: not an IP address in ip_addrs";
                GENERAL_NAMES_free(gens);
                return NULL;
            }
            if ((g = GENERAL_NAME_new()) != NULL)
                GENERAL_NAME_set0_value(g, GEN_IPADD, ip);
            else
                ASN1_OCTET_STRING_free(ip);
        } else {
            *why = "x509: a name must be a non-empty DNS name or an IP address";
            GENERAL_NAMES_free(gens);
            return NULL;
        }
        if (!g || !sk_GENERAL_NAME_push(gens, g)) {
            GENERAL_NAME_free(g);
            GENERAL_NAMES_free(gens);
            *why = "x509: out of memory";
            return NULL;
        }
    }
    return gens;
}

static X509_NAME *sl_x509_subject(const char *cn) {
    X509_NAME *n = X509_NAME_new();
    if (n && cn && cn[0] &&
        X509_NAME_add_entry_by_NID(n, NID_commonName, MBSTRING_UTF8,
                                   (const unsigned char *)cn, -1, -1, 0) != 1) {
        X509_NAME_free(n);
        return NULL;
    }
    return n;
}

/* Ed25519 and Ed448 sign the message itself: no digest. */
static const EVP_MD *sl_x509_sign_md(EVP_PKEY *k) {
    if (EVP_PKEY_is_a(k, "ED25519") || EVP_PKEY_is_a(k, "ED448"))
        return NULL;
    return sl_crypto_md(SL_MD_SHA256);
}

static int sl_x509_key_ok(EVP_PKEY *k) {
    return k && (EVP_PKEY_is_a(k, "RSA") || EVP_PKEY_is_a(k, "EC") ||
                 EVP_PKEY_is_a(k, "ED25519") || EVP_PKEY_is_a(k, "ED448"));
}

/* A PKCS#10 request for `cn` and `sans`, signed with `key_pem`. What an
 * ACME server (or any CA) is sent; it takes the names from here and the
 * public key the request carries. */
static sl_res_str_str *sl_crypto_x509_csr(const char *key_pem, const char *cn, sl_arr *sans) {
    SL_CRYPTO_STACK();
    sl_x509_init();
    const char *fail = NULL;
    char *out = NULL;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(key_pem, 1);
    X509_REQ *req = NULL;
    X509_NAME *name = NULL;
    GENERAL_NAMES *gens = NULL;
    STACK_OF(X509_EXTENSION) *exts = NULL;
    if (!sl_x509_key_ok(k))
        fail = "x509: key must be an RSA, EC or Ed25519 private key in PEM form";
    else if ((!cn || !cn[0]) && (!sans || sans->len == 0))
        fail = "x509: a request needs a common name or at least one name";
    else
        gens = sl_x509_gens(sans, &fail);
    if (!fail &&
        (!(req = X509_REQ_new()) || !(name = sl_x509_subject(cn)) ||
         X509_REQ_set_version(req, 0) != 1 || X509_REQ_set_subject_name(req, name) != 1 ||
         X509_REQ_set_pubkey(req, k) != 1))
        fail = "x509: could not build the request";
    if (!fail && sk_GENERAL_NAME_num(gens) > 0) {
        X509_EXTENSION *ext = X509V3_EXT_i2d(NID_subject_alt_name, 0, gens);
        int owned = 0; /* once pushed, exts frees it */
        if (ext && (exts = sk_X509_EXTENSION_new_null()) != NULL &&
            sk_X509_EXTENSION_push(exts, ext))
            owned = 1;
        if (!owned)
            X509_EXTENSION_free(ext);
        if (!owned || X509_REQ_add_extensions(req, exts) != 1)
            fail = "x509: could not add the names";
    }
    if (!fail && X509_REQ_sign(req, k, sl_x509_sign_md(k)) <= 0)
        fail = "x509: could not sign the request";
    if (!fail) {
        BIO *b = BIO_new(BIO_s_mem());
        if (!b || PEM_write_bio_X509_REQ(b, req) != 1 || !(out = sl_x509_bio_str(b)))
            fail = "x509: could not encode the request";
        BIO_free(b);
    }
    sk_X509_EXTENSION_pop_free(exts, X509_EXTENSION_free);
    GENERAL_NAMES_free(gens);
    X509_NAME_free(name);
    X509_REQ_free(req);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail) {
        free(out);
        return sl_crypto_err_str(fail);
    }
    char *g = sl_strdup(out);
    free(out);
    return sl_crypto_ok_str(g);
}

static int sl_x509_add_ext(X509 *x, int nid, const char *value) {
    X509V3_CTX c;
    X509V3_set_ctx_nodb(&c);
    X509V3_set_ctx(&c, x, x, NULL, NULL, 0);
    X509_EXTENSION *e = X509V3_EXT_conf_nid(NULL, &c, nid, value);
    int ok = e && X509_add_ext(x, e, -1) == 1;
    X509_EXTENSION_free(e);
    return ok;
}

/* A certificate for `cn` and `sans` that `key_pem` signs itself, valid
 * from now for `days`: for development TLS and tests, and as the
 * placeholder an ACME client serves before its first certificate. It
 * is a leaf (CA:FALSE) good for server and client auth; verify it by
 * passing its own PEM as the roots. */
static sl_res_str_str *sl_crypto_x509_self_signed(const char *key_pem, const char *cn,
                                                  sl_arr *sans, long long days) {
    SL_CRYPTO_STACK();
    if (days < 1 || days > 36500)
        return sl_crypto_err_str("x509: days must be 1 to 36500");
    unsigned char serial[16];
    if (sl_crypto_os_random(serial, sizeof serial) != 0)
        return sl_crypto_err_str("x509: no randomness from the OS");
    serial[0] &= 0x7f; /* positive, as RFC 5280 requires */
    serial[0] |= 0x01; /* and 16 bytes long, never shorter */
    sl_x509_init();
    const char *fail = NULL;
    char *out = NULL;
    sl_rt_preempt_disable();
    EVP_PKEY *k = sl_crypto_pem_key(key_pem, 1);
    X509 *x = NULL;
    X509_NAME *name = NULL;
    GENERAL_NAMES *gens = NULL;
    BIGNUM *sn = NULL;
    if (!sl_x509_key_ok(k))
        fail = "x509: key must be an RSA, EC or Ed25519 private key in PEM form";
    else if ((!cn || !cn[0]) && (!sans || sans->len == 0))
        fail = "x509: a certificate needs a common name or at least one name";
    else
        gens = sl_x509_gens(sans, &fail);
    if (!fail && (!(x = X509_new()) || !(name = sl_x509_subject(cn)) ||
             !(sn = BN_bin2bn(serial, sizeof serial, NULL)) ||
             X509_set_version(x, X509_VERSION_3) != 1 ||
             !BN_to_ASN1_INTEGER(sn, X509_get_serialNumber(x)) ||
             !X509_gmtime_adj(X509_getm_notBefore(x), 0) ||
             !X509_gmtime_adj(X509_getm_notAfter(x), (long)(days * 86400)) ||
             X509_set_subject_name(x, name) != 1 || X509_set_issuer_name(x, name) != 1 ||
             X509_set_pubkey(x, k) != 1))
        fail = "x509: could not build the certificate";
    if (!fail &&
        (!sl_x509_add_ext(x, NID_basic_constraints, "critical,CA:FALSE") ||
         !sl_x509_add_ext(x, NID_key_usage,
                          EVP_PKEY_is_a(k, "RSA") ? "critical,digitalSignature,keyEncipherment"
                                                  : "critical,digitalSignature") ||
         !sl_x509_add_ext(x, NID_ext_key_usage, "serverAuth,clientAuth") ||
         !sl_x509_add_ext(x, NID_subject_key_identifier, "hash") ||
         (sk_GENERAL_NAME_num(gens) > 0 &&
          X509_add1_ext_i2d(x, NID_subject_alt_name, gens, 0, X509V3_ADD_DEFAULT) != 1)))
        fail = "x509: could not add the extensions";
    if (!fail && X509_sign(x, k, sl_x509_sign_md(k)) <= 0)
        fail = "x509: could not sign the certificate";
    if (!fail) {
        BIO *b = BIO_new(BIO_s_mem());
        if (!b || PEM_write_bio_X509(b, x) != 1 || !(out = sl_x509_bio_str(b)))
            fail = "x509: could not encode the certificate";
        BIO_free(b);
    }
    BN_free(sn);
    GENERAL_NAMES_free(gens);
    X509_NAME_free(name);
    X509_free(x);
    EVP_PKEY_free(k);
    ERR_clear_error();
    sl_rt_preempt_enable();
    if (fail) {
        free(out);
        return sl_crypto_err_str(fail);
    }
    char *g = sl_strdup(out);
    free(out);
    return sl_crypto_ok_str(g);
}
