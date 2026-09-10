#include <openssl/err.h>
#include <openssl/ssl.h>
#include <strings.h>

/* ---- net: TLS listener/dialer built on OpenSSL ---- */

static sl_res_rawptr_str *sl_net_ok_rawptr(void *v) {
    sl_res_rawptr_str *r = (sl_res_rawptr_str *)sl_gc_alloc(
        sizeof(sl_res_rawptr_str), sl_gc_trace_sl_res_rawptr_str);
    r->ok = true;
    r->v = v;
    return r;
}

static sl_res_rawptr_str *sl_net_err_rawptr(const char *msg) {
    sl_res_rawptr_str *r = (sl_res_rawptr_str *)sl_gc_alloc(
        sizeof(sl_res_rawptr_str), sl_gc_trace_sl_res_rawptr_str);
    r->ok = false;
    r->e = sl_strdup(msg);
    return r;
}

/* Tier 11 eighth slice: the snprintf branch bracketed for the same
 * reason as sl_gc_alloc's own comment (runtime_gc.c) -- locale-
 * internal locking. ERR_error_string_n itself not separately
 * addressed here: OpenSSL 1.1.0+'s error queue is thread-local, not
 * behind a shared lock, so it doesn't share the same crash-class
 * risk -- an async-preempted task migrating mid-call could still, in
 * principle, read a DIFFERENT thread's error state on resume (a
 * correctness nuance, not the crash-class bug this slice's other
 * brackets close), not chased further here. */
static char *sl_tls_last_error(void) {
    unsigned long e = ERR_get_error();
    char buf[256];
    if (e == 0) {
        sl_rt_preempt_disable();
        snprintf(buf, sizeof(buf), "unknown TLS error");
        sl_rt_preempt_enable();
    } else {
        ERR_error_string_n(e, buf, sizeof(buf));
    }
    return sl_strdup(buf);
}

typedef struct { unsigned char *wire; unsigned int len; } sl_alpn_list;

static sl_res_rawptr_str *sl_net_tls_server_ctx(const char *cert_path,
                                                const char *key_path) {
    sl_rt_need_fat_stack();
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) return sl_net_err_rawptr(sl_tls_last_error());
    if (SSL_CTX_use_certificate_file(ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
        char *m = sl_tls_last_error();
        SSL_CTX_free(ctx);
        return sl_net_err_rawptr(m);
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        char *m = sl_tls_last_error();
        SSL_CTX_free(ctx);
        return sl_net_err_rawptr(m);
    }
    if (SSL_CTX_check_private_key(ctx) != 1) {
        SSL_CTX_free(ctx);
        return sl_net_err_rawptr("certificate/key mismatch");
    }
    return sl_net_ok_rawptr(ctx);
}

static sl_res_rawptr_str *sl_net_tls_client_ctx(const char *ca_path) {
    sl_rt_need_fat_stack();
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return sl_net_err_rawptr(sl_tls_last_error());
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    if (ca_path[0] != '\0') {
        if (SSL_CTX_load_verify_locations(ctx, ca_path, NULL) != 1) {
            char *m = sl_tls_last_error();
            SSL_CTX_free(ctx);
            return sl_net_err_rawptr(m);
        }
    } else {
        SSL_CTX_set_default_verify_paths(ctx);
    }
    return sl_net_ok_rawptr(ctx);
}

/* Returns 0 to retry, -1 shutdown, -2 a real SSL error, and -3 the
 * deadline passed. -3 rather than reusing -2 because the two need
 * different error text and callers already branch on -2 meaning "ask
 * OpenSSL what went wrong", which would report a stale or empty error
 * queue for a timeout. `u` of 0 disables the deadline entirely, so
 * sl_tls_park below is exactly the original function. */
static int sl_tls_park_until(SSL *ssl, int ssl_err, int abort_on_shutdown,
                             sl_until u) {
    int fd = SSL_get_fd(ssl);
    int rw;
    if (fd < 0) return -2;
    if (ssl_err == SSL_ERROR_WANT_READ)
        rw = SL_REACTOR_READ;
    else if (ssl_err == SSL_ERROR_WANT_WRITE)
        rw = SL_REACTOR_WRITE;
    else
        return -2;
    int w = sl_reactor_wait_until(fd, rw, abort_on_shutdown, u);
    return w == -2 ? -3 : w;
}

static int sl_tls_park(SSL *ssl, int ssl_err, int abort_on_shutdown) {
    return sl_tls_park_until(ssl, ssl_err, abort_on_shutdown, 0);
}

/* Is this read error just "the peer went away", rather than a fault?
 *
 * A well-behaved peer sends TLS close_notify and OpenSSL reports
 * SSL_ERROR_ZERO_RETURN. Browsers routinely do NOT: Chrome closes the
 * TCP connection outright, which OpenSSL 3.x reports as SSL_ERROR_SSL
 * with reason UNEXPECTED_EOF_WHILE_READING, and older versions as
 * SSL_ERROR_SYSCALL with errno 0.
 *
 * Treating that as an error means every ordinary browser disconnect
 * surfaces as
 *
 *     recv: error:0A000126:SSL routines::unexpected eof while reading
 *
 * which is alarming, entirely normal, and would bury real failures in
 * any server's logs. It is a truncation attack only if the application
 * cares about a length it cannot otherwise verify; HTTP/2 frames each
 * carry their own length and an incomplete one is already rejected, so
 * here it is simply end-of-stream. */
static int sl_tls_clean_eof(int ssl_err) {
    if (ssl_err == SSL_ERROR_ZERO_RETURN)
        return 1;
    if (ssl_err == SSL_ERROR_SYSCALL && errno == 0)
        return 1; /* pre-3.0 spelling of the same event */
#ifdef SSL_R_UNEXPECTED_EOF_WHILE_READING
    if (ssl_err == SSL_ERROR_SSL) {
        unsigned long e = ERR_peek_error();
        if (ERR_GET_REASON(e) == SSL_R_UNEXPECTED_EOF_WHILE_READING) {
            ERR_clear_error(); /* consumed: leaving it queued would make
                                  the NEXT unrelated failure report this
                                  one's text instead of its own */
            return 1;
        }
    }
#endif
    return 0;
}

static int sl_tls_handshake(SSL *ssl, int server) {
    for (;;) {
        int n = server ? SSL_accept(ssl) : SSL_connect(ssl);
        if (n == 1) return 0;
        int err = SSL_get_error(ssl, n);
        int w = sl_tls_park(ssl, err, 1);
        if (w == 0) continue;
        if (w == -1) return -1;
        return -2;
    }
}

static sl_res_rawptr_str *sl_net_tls_accept(int lfd, void *ctxv) {
    sl_rt_need_fat_stack();
    int cfd;
    for (;;) {
        cfd = accept(lfd, NULL, NULL);
        if (cfd >= 0) break;
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            return sl_net_err_rawptr(strerror(errno));
        if (sl_net_user_nonblock_contains((void *)(intptr_t)lfd))
            return sl_net_err_rawptr("would block");
        if (sl_reactor_wait(lfd, SL_REACTOR_READ, 1) < 0)
            return sl_net_err_rawptr("interrupted");
    }
    sl_net_set_nonblocking(cfd);
    SSL *ssl = SSL_new((SSL_CTX *)ctxv);
    if (!ssl) {
        close(cfd);
        return sl_net_err_rawptr(sl_tls_last_error());
    }
    SSL_set_fd(ssl, cfd);
    SSL_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE);
    int hs = sl_tls_handshake(ssl, 1);
    if (hs == 0 && (SSL_get_verify_mode(ssl) & SSL_VERIFY_PEER)) {
        X509 *peer = SSL_get_peer_certificate(ssl);
        if (!peer) {
            SSL_free(ssl);
            close(cfd);
            return sl_net_err_rawptr("client certificate required");
        }
        X509_free(peer);
        if (SSL_get_verify_result(ssl) != X509_V_OK) {
            SSL_free(ssl);
            close(cfd);
            return sl_net_err_rawptr(sl_tls_last_error());
        }
    }
    if (hs != 0) {
        char *m = hs == -1 ? sl_strdup("interrupted") : sl_tls_last_error();
        SSL_free(ssl);
        close(cfd);
        return sl_net_err_rawptr(m);
    }
    return sl_net_ok_rawptr(ssl);
}

static sl_res_rawptr_str *sl_net_tls_dial(const char *host, int port,
                                          void *ctxv) {
    sl_rt_need_fat_stack();
    char portstr[16];
    sl_rt_preempt_disable();
    snprintf(portstr, sizeof(portstr), "%d", port);
    sl_rt_preempt_enable();
    struct addrinfo *res = NULL;
    int rc = sl_dns_lookup(host, portstr, &res);
    if (rc != 0 || !res) return sl_net_err_rawptr(gai_strerror(rc));
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return sl_net_err_rawptr(strerror(errno));
    }
    sl_net_set_nonblocking(fd);
    int cres = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (cres != 0 && errno != EINPROGRESS) {
        int e = errno;
        close(fd);
        return sl_net_err_rawptr(strerror(e));
    }
    if (cres != 0) {
        if (sl_reactor_wait(fd, SL_REACTOR_WRITE, 1) < 0) {
            close(fd);
            return sl_net_err_rawptr("interrupted");
        }
        int so_err = 0;
        socklen_t slen = sizeof(so_err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &slen);
        if (so_err != 0) {
            close(fd);
            return sl_net_err_rawptr(strerror(so_err));
        }
    }
    SSL *ssl = SSL_new((SSL_CTX *)ctxv);
    if (!ssl) {
        close(fd);
        return sl_net_err_rawptr(sl_tls_last_error());
    }
    SSL_set_fd(ssl, fd);
    SSL_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE);
    SSL_set1_host(ssl, host);
    SSL_set_tlsext_host_name(ssl, host);
    int hs = sl_tls_handshake(ssl, 0);
    if (hs != 0 || SSL_get_verify_result(ssl) != X509_V_OK) {
        char *m = hs == -1 ? sl_strdup("interrupted") : sl_tls_last_error();
        SSL_free(ssl);
        close(fd);
        return sl_net_err_rawptr(m);
    }
    return sl_net_ok_rawptr(ssl);
}

/* See sl_net_send_u in sl_net.c for the partial-write contract a
 * "timeout" carries: bytes may already be on the wire, so the session
 * must be closed rather than retried. */
static sl_res_i32_str *sl_net_tls_send_u(void *sslv, sl_bytes *data,
                                         sl_until u) {
    sl_rt_need_fat_stack();
    SSL *ssl = (SSL *)sslv;
    long long off = 0;
    if (u && sl_until_hit(u) && data->len > 0)
        return sl_net_err_i32("timeout");
    while (off < data->len) {
        int n = SSL_write(ssl, data->ptr + off, (int)(data->len - off));
        if (n > 0) { off += n; continue; }
        int err = SSL_get_error(ssl, n);
        int w = sl_tls_park_until(ssl, err, 0, u);
        if (w == 0) continue;
        if (w == -3) return sl_net_err_i32("timeout");
        return sl_net_err_i32(sl_tls_last_error());
    }
    return sl_net_ok_i32((int32_t)data->len);
}

static sl_res_i32_str *sl_net_tls_send(void *sslv, sl_bytes *data) {
    return sl_net_tls_send_u(sslv, data, 0);
}

static sl_res_i32_str *sl_net_tls_send_until(void *sslv, sl_bytes *data,
                                             sl_until u) {
    return sl_net_tls_send_u(sslv, data, u);
}

static sl_res_bytes_str *sl_net_tls_recv_u(void *sslv, int max, sl_until u) {
    sl_rt_need_fat_stack();
    if (u && sl_until_hit(u))
        return sl_net_err_bytes("timeout");
    if (max <= 0) max = 4096;
    SSL *ssl = (SSL *)sslv;
    unsigned char *scratch = (unsigned char *)sl_recv_buf_get((size_t)max);
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    void *_sl_rcv_roots[] = { (void *)b };
    sl_safepoint _sl_rcv_sp;
    sl_rt_safepoint_enter(&_sl_rcv_sp, _sl_rcv_roots, 1);
    for (;;) {
        int n = SSL_read(ssl, scratch, max);
        if (n > 0) {
            sl_net_recv_copy(b, scratch, n);
            sl_rt_safepoint_exit();
            sl_recv_buf_put(scratch);
            return sl_net_ok_bytes(b);
        }
        int err = SSL_get_error(ssl, n);
        if (sl_tls_clean_eof(err)) {
            /* Zero bytes is how this API already spells end-of-stream on
               the plain path, so callers need no new case. */
            sl_net_recv_copy(b, scratch, 0);
            sl_rt_safepoint_exit();
            sl_recv_buf_put(scratch);
            return sl_net_ok_bytes(b);
        }
        int w = sl_tls_park_until(ssl, err, 1, u);
        if (w == 0) continue;
        sl_rt_safepoint_exit();
        sl_recv_buf_put(scratch);
        if (w == -1) return sl_net_err_bytes("interrupted");
        if (w == -3) return sl_net_err_bytes("timeout");
        return sl_net_err_bytes(sl_tls_last_error());
    }
}

static sl_res_bytes_str *sl_net_tls_recv(void *sslv, int max) {
    return sl_net_tls_recv_u(sslv, max, 0);
}

static sl_res_bytes_str *sl_net_tls_recv_until(void *sslv, int max,
                                               sl_until u) {
    return sl_net_tls_recv_u(sslv, max, u);
}

typedef struct sl_sni_cert {
    char *host;
    SSL_CTX *ctx;
    struct sl_sni_cert *next;
} sl_sni_cert;

static int sl_sni_ex = -1;

static void sl_tls_copy_verify(SSL_CTX *dst, SSL_CTX *src) {
    SSL_CTX_set_verify(dst, SSL_CTX_get_verify_mode(src),
                       SSL_CTX_get_verify_callback(src));
    X509_STORE *store = SSL_CTX_get_cert_store(src);
    if (store)
        SSL_CTX_set1_verify_cert_store(dst, store);
    SSL_CTX_set_session_cache_mode(dst, SSL_CTX_get_session_cache_mode(src));
}

static sl_res_bool_str *sl_net_tls_ctx_require_client(void *ctxv,
                                                      const char *ca_path) {
    sl_rt_need_fat_stack();
    SSL_CTX *ctx = (SSL_CTX *)ctxv;
    if (!ctx) return sl_net_err_bool("nil tls context");
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
                       NULL);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);
    if (SSL_CTX_load_verify_locations(ctx, ca_path, NULL) != 1)
        return sl_net_err_bool(sl_tls_last_error());
    if (sl_sni_ex >= 0) {
        sl_sni_cert *list = (sl_sni_cert *)SSL_CTX_get_ex_data(ctx, sl_sni_ex);
        for (; list; list = list->next)
            sl_tls_copy_verify(list->ctx, ctx);
    }
    return sl_net_ok_bool(true);
}

static sl_res_bool_str *sl_net_tls_ctx_use_cert(void *ctxv, const char *cert,
                                               const char *key) {
    sl_rt_need_fat_stack();
    SSL_CTX *ctx = (SSL_CTX *)ctxv;
    if (!ctx) return sl_net_err_bool("nil tls context");
    if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) != 1)
        return sl_net_err_bool(sl_tls_last_error());
    if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1)
        return sl_net_err_bool(sl_tls_last_error());
    if (SSL_CTX_check_private_key(ctx) != 1)
        return sl_net_err_bool("certificate/key mismatch");
    return sl_net_ok_bool(true);
}

static int sl_tls_sni_cb(SSL *ssl, int *ad, void *arg) {
    (void)ad;
    (void)arg;
    const char *name = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
    SSL_CTX *base = SSL_get_SSL_CTX(ssl);
    sl_sni_cert *list = (sl_sni_cert *)SSL_CTX_get_ex_data(base, sl_sni_ex);
    if (!name)
        return SSL_TLSEXT_ERR_OK;
    for (; list; list = list->next) {
        if (strcasecmp(list->host, name) == 0) {
            SSL_set_SSL_CTX(ssl, list->ctx);
            return SSL_TLSEXT_ERR_OK;
        }
    }
    return SSL_TLSEXT_ERR_OK;
}

static sl_res_bool_str *sl_net_tls_ctx_add_sni(void *ctxv, const char *host,
                                              const char *cert,
                                              const char *key) {
    sl_rt_need_fat_stack();
    SSL_CTX *base = (SSL_CTX *)ctxv;
    if (!base) return sl_net_err_bool("nil tls context");
    if (!host[0]) return sl_net_err_bool("empty SNI hostname");
    sl_res_rawptr_str *made = sl_net_tls_server_ctx(cert, key);
    if (!made->ok) return sl_net_err_bool(made->e);
    SSL_CTX *leaf = (SSL_CTX *)made->v;
    if (sl_sni_ex < 0)
        sl_sni_ex = SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, NULL);
    sl_sni_cert *ent = (sl_sni_cert *)malloc(sizeof(sl_sni_cert));
    if (!ent) {
        SSL_CTX_free(leaf);
        return sl_net_err_bool("out of memory");
    }
    ent->host = strdup(host);
    if (!ent->host) {
        SSL_CTX_free(leaf);
        free(ent);
        return sl_net_err_bool("out of memory");
    }
    sl_tls_copy_verify(leaf, base);
    ent->ctx = leaf;
    ent->next = (sl_sni_cert *)SSL_CTX_get_ex_data(base, sl_sni_ex);
    SSL_CTX_set_ex_data(base, sl_sni_ex, ent);
    SSL_CTX_set_tlsext_servername_callback(base, sl_tls_sni_cb);
    return sl_net_ok_bool(true);
}

static void sl_net_tls_close(void *sslv) {
    sl_rt_need_fat_stack();
    SSL *ssl = (SSL *)sslv;
    int fd = SSL_get_fd(ssl);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    if (fd >= 0) close(fd);
}


/* ---- ALPN (RFC 7301) ------------------------------------------------
 *
 * HTTP/2 over TLS is negotiated here, not in-band: the client offers a
 * protocol list in the handshake and the server picks one. Without this
 * a client that speaks h2 silently falls back to HTTP/1.1, which looks
 * like "h2 doesn't work" with no error anywhere.
 *
 * Protocol lists are stored on the wire as length-prefixed items
 * ("\x02h2\x08http/1.1"), but that is a bad shape for a slang caller,
 * so these take a comma-separated string ("h2,http/1.1") and do the
 * conversion here. */

/* Convert "h2,http/1.1" to the wire form. Returns malloc'd bytes and
 * sets *outlen, or NULL if any item is empty or longer than 255. */
static unsigned char *sl_alpn_wire(const char *csv, unsigned int *outlen) {
    size_t n = strlen(csv);
    unsigned char *buf = (unsigned char *)malloc(n + 2);
    if (!buf) return NULL;
    size_t w = 0, start = 0;
    for (size_t i = 0; i <= n; i++) {
        if (i == n || csv[i] == ',') {
            size_t itemlen = i - start;
            if (itemlen == 0 || itemlen > 255) { free(buf); return NULL; }
            buf[w++] = (unsigned char)itemlen;
            memcpy(buf + w, csv + start, itemlen);
            w += itemlen;
            start = i + 1;
        }
    }
    *outlen = (unsigned int)w;
    return buf;
}

/* Server-side selection callback. SSL_select_next_proto picks the first
 * of OUR list that the client also offered -- server preference, which
 * is what lets an operator decide h2 beats http/1.1 rather than leaving
 * it to the client. */
static int sl_alpn_select_cb(SSL *ssl, const unsigned char **out,
                             unsigned char *outlen,
                             const unsigned char *in, unsigned int inlen,
                             void *arg) {
    (void)ssl;
    sl_alpn_list *l = (sl_alpn_list *)arg;
    if (!l || !l->wire) return SSL_TLSEXT_ERR_NOACK;
    unsigned char *chosen = NULL;
    if (SSL_select_next_proto(&chosen, outlen, l->wire, l->len, in, inlen) !=
        OPENSSL_NPN_NEGOTIATED)
        return SSL_TLSEXT_ERR_NOACK;   /* no overlap: proceed without ALPN */
    *out = chosen;
    return SSL_TLSEXT_ERR_OK;
}

/* Offer a protocol list on a CLIENT context, or advertise one on a
 * SERVER context. The list is owned by the context for its lifetime. */
static sl_res_bool_str *sl_net_tls_ctx_alpn(void *ctxv, const char *protos) {
    SSL_CTX *ctx = (SSL_CTX *)ctxv;
    if (!ctx) return sl_net_err_bool("nil TLS context");
    if (!protos || !protos[0]) return sl_net_err_bool("empty protocol list");
    unsigned int wlen = 0;
    unsigned char *wire = sl_alpn_wire(protos, &wlen);
    if (!wire)
        return sl_net_err_bool("bad ALPN list (items must be 1..255 bytes)");

    /* Client side: this is the offer sent in the ClientHello. Harmless on
     * a server context, where the select callback below does the work. */
    if (SSL_CTX_set_alpn_protos(ctx, wire, wlen) != 0) {
        free(wire);
        return sl_net_err_bool("SSL_CTX_set_alpn_protos failed");
    }

    sl_alpn_list *l = (sl_alpn_list *)malloc(sizeof(sl_alpn_list));
    if (!l) { free(wire); return sl_net_err_bool("out of memory"); }
    l->wire = wire;
    l->len = wlen;
    SSL_CTX_set_alpn_select_cb(ctx, sl_alpn_select_cb, l);
    return sl_net_ok_bool(true);
}

/* The protocol actually negotiated on a connection, or "" if the peer
 * offered none or nothing overlapped. Callers branch on this to decide
 * whether to speak h2 or fall back to HTTP/1.1. */
static const char *sl_net_tls_alpn(void *sslv) {
    SSL *ssl = (SSL *)sslv;
    if (!ssl) return sl_strdup("");
    const unsigned char *p = NULL;
    unsigned int plen = 0;
    sl_rt_preempt_disable();
    SSL_get0_alpn_selected(ssl, &p, &plen);
    sl_rt_preempt_enable();
    if (!p || plen == 0) return sl_strdup("");
    char tmp[256];
    if (plen > sizeof(tmp) - 1) plen = sizeof(tmp) - 1;
    memcpy(tmp, p, plen);
    tmp[plen] = '\0';
    return sl_strdup(tmp);
}
