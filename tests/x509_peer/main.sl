// The TLS peer's certificate chain, as mTLS uses it for the client's
// identity: net.tls_peer_certs on handles from tls_accept and tls_dial,
// link.peer_certs() after c.tls_accept, both read with x509.parse_der.
// Certificates are tests/tls's (CN=localhost, self-signed).

import "net";
import "time";
import "x509";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

fn describe(who: str, der: bytes) -> str {
    if len(der) == 0 {
        return who + ": no certificate";
    }
    let r = x509.parse_der(der);
    guard let cs = r else let e = err_of(r) { return who + ": " + e; }
    return who + ": " + to_str(len(cs)) + " cert, CN=" + cs[0].common_name +
           ", issuer " + cs[0].issuer + ", localhost " + to_str(x509.matches_host(cs[0], "localhost"));
}

fn mtls_ctx(require: bool) -> rawptr {
    let sr: result[rawptr, str] = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
    guard let sctx = sr else { die("server ctx"); }
    if require {
        let rr: result[bool, str] = net.tls_ctx_require_client(sctx, "tests/tls/cert.pem");
        guard let _ok = rr else { die("require client"); }
    }
    return sctx;
}

fn client_ctx(with_cert: bool) -> rawptr {
    let cr: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cr else { die("client ctx"); }
    if with_cert {
        let ur: result[bool, str] = net.tls_ctx_use_cert(cctx, "tests/tls/cert.pem", "tests/tls/key.pem");
        guard let _ok = ur else { die("use cert"); }
    }
    return cctx;
}

fn raw_server(lfd: i32, sctx: rawptr, done: chan[str]) {
    let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);
    guard let sconn = ar else { chan_send(done, "server: handshake failed"); return; }
    let msg = describe("server sees client", net.tls_peer_certs(sconn));
    net.tls_send(sconn, b"ok");
    net.tls_close(sconn);
    chan_send(done, msg);
}

fn scenario_raw(require: bool, with_cert: bool) {
    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    let done: chan[str] = make_chan(1);
    spawn raw_server(lfd, mtls_ctx(require), done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, client_ctx(with_cert));
    guard let cconn = dr else { die("dial"); }
    println(describe("client sees server", net.tls_peer_certs(cconn)));
    net.tls_recv(cconn, 16);
    net.tls_close(cconn);
    println(chan_recv(done) ?? "no answer");
}

fn link_server(ln: link, ctx: rawptr, done: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(soon(5000));
    guard let c = ar else { chan_send(done, "accept"); return; }
    let before = c.peer_certs();
    let hr = c.tls_accept(ctx, soon(5000));
    guard let _h = hr else { chan_send(done, "handshake"); return; }
    let msg = "before TLS " + to_str(len(before)) + " bytes; " + describe("link sees client", c.peer_certs());
    let a = arena_new(64);
    let w = a.wire(16);
    let sr = c.send_bytes(b"ok", soon(5000));
    guard let _s = sr else { chan_send(done, "send"); return; }
    c.recv(w, soon(5000));
    chan_send(done, msg);
}

fn scenario_link() {
    let lr = link_listen(0, 1);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let done: chan[str] = make_chan(1);
    spawn link_server(ln, mtls_ctx(true), done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, client_ctx(true));
    guard let cconn = dr else { die("dial"); }
    net.tls_recv(cconn, 16);
    net.tls_close(cconn);
    println(chan_recv(done) ?? "no answer");
}

fn run() {
    println("== mTLS, raw handles");
    scenario_raw(true, true);
    println("== TLS without client certificates");
    scenario_raw(false, false);
    println("== mTLS on a link");
    scenario_link();
}

run();
