// tls_accept takes the context net.tls_server_ctx returns, not a path:
// passing the certificate file itself is the mistake this catches.
fn serve(c: link) {
    let _r = c.tls_accept("cert.pem", until_never());
}
