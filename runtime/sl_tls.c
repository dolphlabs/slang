#include <openssl/err.h>
#include <openssl/ssl.h>

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

static int sl_tls_park(SSL *ssl, int ssl_err, int abort_on_shutdown) {
    int fd = SSL_get_fd(ssl);
    if (fd < 0) return -2;
    if (ssl_err == SSL_ERROR_WANT_READ)
        return sl_reactor_wait(fd, SL_REACTOR_READ, abort_on_shutdown);
    if (ssl_err == SSL_ERROR_WANT_WRITE)
        return sl_reactor_wait(fd, SL_REACTOR_WRITE, abort_on_shutdown);
    return -2;
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
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(host, portstr, &hints, &res);
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

static sl_res_i32_str *sl_net_tls_send(void *sslv, sl_bytes *data) {
    sl_rt_need_fat_stack();
    SSL *ssl = (SSL *)sslv;
    long long off = 0;
    while (off < data->len) {
        int n = SSL_write(ssl, data->ptr + off, (int)(data->len - off));
        if (n > 0) { off += n; continue; }
        int err = SSL_get_error(ssl, n);
        int w = sl_tls_park(ssl, err, 0);
        if (w == 0) continue;
        return sl_net_err_i32(sl_tls_last_error());
    }
    return sl_net_ok_i32((int32_t)data->len);
}

static sl_res_bytes_str *sl_net_tls_recv(void *sslv, int max) {
    sl_rt_need_fat_stack();
    if (max <= 0) max = 4096;
    SSL *ssl = (SSL *)sslv;
    sl_bytes *b = (sl_bytes *)sl_gc_alloc(sizeof(sl_bytes), sl_gc_trace_bytes);
    b->ptr = (unsigned char *)sl_gc_alloc((size_t)max, NULL);
    void *_sl_rcv_roots[] = { (void *)b };
    sl_safepoint _sl_rcv_sp;
    sl_rt_safepoint_enter(&_sl_rcv_sp, _sl_rcv_roots, 1);
    for (;;) {
        int n = SSL_read(ssl, b->ptr, max);
        if (n > 0) {
            b->len = n;
            sl_rt_safepoint_exit();
            return sl_net_ok_bytes(b);
        }
        int err = SSL_get_error(ssl, n);
        if (err == SSL_ERROR_ZERO_RETURN) {
            b->len = 0;
            sl_rt_safepoint_exit();
            return sl_net_ok_bytes(b);
        }
        int w = sl_tls_park(ssl, err, 1);
        if (w == 0) continue;
        sl_rt_safepoint_exit();
        if (w == -1) return sl_net_err_bytes("interrupted");
        return sl_net_err_bytes(sl_tls_last_error());
    }
}

static void sl_net_tls_close(void *sslv) {
    sl_rt_need_fat_stack();
    SSL *ssl = (SSL *)sslv;
    int fd = SSL_get_fd(ssl);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    if (fd >= 0) close(fd);
}

