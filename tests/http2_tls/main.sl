import "http2";
import "net";
import "time";

// HTTP/2 over TLS, with the protocol chosen by ALPN (RFC 7301).
//
// This is the shape every browser uses and the only one they will use:
// there is no in-band upgrade to h2 in a browser, so a server that can
// only do cleartext h2c cannot serve one at all. The connection layer
// used to be fd-only, which meant the ALPN primitives had existed since
// the TLS work landed with nothing in the tree calling them.
//
// Two things are under test, and the second is the one worth having:
//
//   1. h2 frames survive the TLS transport unchanged -- request in,
//      response out, over SSL_read/SSL_write instead of recv/send.
//   2. When the server offers "h2,http/1.1" and the client offers only
//      "http/1.1", they agree on http/1.1 and the server DECLINES to
//      speak h2 rather than feeding an HTTP/1.1 client into the frame
//      parser and reporting a confusing "bad connection preface".

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn handle(stream: i32, path: str, wch: chan[http2.WMsg], g: chan[bool]) {
    let extra: [http2.Header] = [
        http2.Header { name: "content-type", value: "text/plain" }
    ];
    chan_send(wch, http2.response_msg(stream as int, "200", extra,
                                      to_bytes("secure=" + path)));
    http2.gate_leave(g);
}

// One TLS connection, served as h2 only if ALPN actually said so.
fn serve(ssl: rawptr, out: chan[str]) {
    let proto = net.tls_alpn(ssl);
    if !http2.alpn_is_h2(proto) {
        // The honest outcome for a peer that did not ask for h2.
        net.tls_close(ssl);
        chan_send(out, "declined:" + proto);
        return;
    }

    let t = http2.transport_tls(ssl);
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(16);
    let lim = http2.default_limits();
    let g = http2.gate(lim.max_concurrent);
    spawn http2.writer_task(t, wch, lim.write);

    let pr = http2.accept_preface(rd, t, wch,
                                  until_of(time.mono() + lim.handshake));
    guard let _p = pr else let e = err_of(pr) {
        chan_close(wch);
        http2.tr_close(t);
        chan_send(out, "preface:" + e);
        return;
    }
    let rr = http2.read_request(cn, rd, t, wch, lim);
    guard let req = rr else let e = err_of(rr) {
        chan_close(wch);
        http2.tr_close(t);
        chan_send(out, "request:" + e);
        return;
    }
    http2.gate_enter(g);
    spawn handle(req.stream as i32, req.path, wch, g);
    chan_send(out, "served:" + req.path);
}

fn accept_one(lfd: i32, sctx: rawptr, out: chan[str]) {
    let ar = net.tls_accept(lfd, sctx);
    guard let ssl = ar else let e = err_of(ar) {
        chan_send(out, "accept:" + e);
        return;
    }
    serve(ssl, out);
}

fn request_frames(stream: int, path: str) -> bytes {
    let hs: [http2.Header] = [
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "https" },
        http2.Header { name: ":path", value: path },
        http2.Header { name: ":authority", value: "localhost" }
    ];
    let blk = http2.encode_block(hs);
    let flags = http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM;
    return http2.header_bytes(http2.T_HEADERS, flags, stream, len(blk)) + blk;
}

// A client that offers h2 and then speaks it over TLS.
fn h2_client(port: int, out: chan[str]) {
    let cr = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cr else let e = err_of(cr) {
        chan_send(out, "client ctx:" + e);
        return;
    }
    let ar = net.tls_ctx_alpn(cctx, "h2");
    guard let _a = ar else let e = err_of(ar) {
        chan_send(out, "client alpn:" + e);
        return;
    }
    let dr = net.tls_dial("localhost", port, cctx);
    guard let ssl = dr else let e = err_of(dr) {
        chan_send(out, "dial:" + e);
        return;
    }
    if !http2.alpn_is_h2(net.tls_alpn(ssl)) {
        chan_send(out, "client did not negotiate h2");
        net.tls_close(ssl);
        return;
    }

    let t = http2.transport_tls(ssl);
    let sr = net.tls_send(ssl, http2.preface() + http2.our_settings()
                               + request_frames(1, "/over-tls"));
    guard let _s = sr else let e = err_of(sr) {
        chan_send(out, "send:" + e);
        return;
    }

    // Read until the response DATA arrives, which proves the whole
    // frame path works over SSL_read rather than recv.
    let rd = http2.reader_new();
    let body = b"";
    while true {
        let fr = http2.read_frame(rd, t, 16384,
                                  until_of(time.mono() + 5000000000));
        guard let f = fr else let e = err_of(fr) {
            chan_send(out, "client read:" + e);
            net.tls_close(ssl);
            return;
        }
        if f.ftype == http2.T_DATA {
            body = body + f.payload;
            if (f.flags & http2.FLAG_END_STREAM) != 0 {
                net.tls_close(ssl);
                chan_send(out, "client got:" + to_str(body));
                return;
            }
        }
    }
}

// A client that offers ONLY http/1.1 against the same h2-capable server.
fn h1_client(port: int, out: chan[str]) {
    let cr = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cr else { chan_send(out, "h1 ctx failed"); return; }
    let ar = net.tls_ctx_alpn(cctx, "http/1.1");
    guard let _a = ar else { chan_send(out, "h1 alpn failed"); return; }
    let dr = net.tls_dial("localhost", port, cctx);
    guard let ssl = dr else { chan_send(out, "h1 dial failed"); return; }
    let got = net.tls_alpn(ssl);
    net.tls_close(ssl);
    chan_send(out, "h1 negotiated:" + got);
}

fn run() {
    let sr = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
    guard let sctx = sr else let e = err_of(sr) { die("server ctx: " + e); }
    // Offer both, h2 preferred. This is what a real server advertises.
    let ar = net.tls_ctx_alpn(sctx, "h2,http/1.1");
    guard let _a = ar else let e = err_of(ar) { die("server alpn: " + e); }

    let lr = net.listen(0);
    guard let lfd = lr else let e = err_of(lr) { die("listen: " + e); }
    let pr = net.port(lfd);
    guard let port = pr else { die("port"); }

    let out: chan[str] = make_chan(8);

    // 1. h2 client: ALPN picks h2, frames flow over TLS.
    spawn accept_one(lfd, sctx, out);
    spawn h2_client(port, out);

    let seen_served = false;
    let seen_body = false;
    let i = 0;
    while i < 2 {
        let rv = chan_recv(out);
        guard let v = rv else { die("channel closed"); }
        if v == "served:/over-tls" {
            seen_served = true;
        } else {
            if v == "client got:secure=/over-tls" {
                seen_body = true;
            } else {
                die("unexpected: " + v);
            }
        }
        i = i + 1;
    }
    if !seen_served { die("server never served over TLS"); }
    if !seen_body { die("client never got the body"); }
    println("h2 over TLS ok");

    // 2. http/1.1-only client: the server must decline rather than try
    //    to parse HTTP/1.1 as h2 frames.
    spawn accept_one(lfd, sctx, out);
    spawn h1_client(port, out);

    let seen_decline = false;
    let seen_h1 = false;
    let k = 0;
    while k < 2 {
        let rv2 = chan_recv(out);
        guard let v2 = rv2 else { die("channel closed"); }
        if v2 == "declined:http/1.1" {
            seen_decline = true;
        } else {
            if v2 == "h1 negotiated:http/1.1" {
                seen_h1 = true;
            } else {
                die("unexpected: " + v2);
            }
        }
        k = k + 1;
    }
    if !seen_h1 { die("ALPN did not settle on http/1.1"); }
    if !seen_decline { die("server did not decline a non-h2 peer"); }
    println("non-h2 peer declined");

    net.close(lfd);
}

run();
