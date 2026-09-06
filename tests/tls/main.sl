// TLS listener/dialer on top of OpenSSL: a real handshake over
// loopback, plus the two checks that actually matter for MITM
// protection -- an untrusted CA is rejected, and a certificate valid
// for a different hostname than the one requested is rejected too
// (checking the chain without checking the name is a classic way to
// end up with "TLS" that doesn't actually stop an attacker).

import "net";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn echo_server(lfd: i32, sctx: rawptr) {
    let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);
    guard let sconn = ar else { return; }
    let rr: result[bytes, str] = net.tls_recv(sconn, 64);
    guard let data = rr else { return; }
    if data == b"ping" {
        net.tls_send(sconn, b"pong");
    }
    net.tls_close(sconn);
}

fn reject_server(lfd: i32, sctx: rawptr) {
    let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);
    guard let sconn = ar else { return; } // handshake fails server-side too
    net.tls_close(sconn);
}

// scenario 1: correct CA, correct hostname -> a real encrypted round trip
fn scenario_round_trip(sctx: rawptr) {
    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    spawn echo_server(lfd, sctx);

    let cctx_r: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cctx_r else { die("client ctx"); }
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cconn = dr else { die("dial"); }
    net.tls_send(cconn, b"ping");
    let rr: result[bytes, str] = net.tls_recv(cconn, 64);
    guard let resp = rr else { die("recv"); }
    if resp == b"pong" {
        println("tls round-trip ok");
    } else {
        die("bad response");
    }
    net.tls_close(cconn);
}

// scenario 2: self-signed cert isn't in the system trust store -> rejected
fn scenario_untrusted_ca(sctx: rawptr) {
    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    spawn reject_server(lfd, sctx);

    let sys_ctx_r: result[rawptr, str] = net.tls_client_ctx("");
    guard let sys_ctx = sys_ctx_r else { die("system ctx"); }
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, sys_ctx);
    guard let _cconn = dr else {
        println("correctly rejected: untrusted CA");
        return;
    }
    die("expected verification failure but connection succeeded");
}

// scenario 3: trusted CA, but the cert (CN=localhost) doesn't cover
// "127.0.0.1" -- the actual TCP connection succeeds (it's the same
// server), so this isolates hostname *verification* failure from a
// DNS/connect failure
fn scenario_hostname_mismatch(sctx: rawptr) {
    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    spawn reject_server(lfd, sctx);

    let cctx_r: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cctx_r else { die("client ctx"); }
    let dr: result[rawptr, str] = net.tls_dial("127.0.0.1", port, cctx);
    guard let _cconn = dr else {
        println("correctly rejected: hostname mismatch");
        return;
    }
    die("expected hostname verification failure but connection succeeded");
}

// scenario 4: server requires a client cert; client presents one
fn scenario_mtls_ok() {
    let sr: result[rawptr, str] = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
    guard let sctx = sr else { die("mtls server ctx"); }
    let req: result[bool, str] = net.tls_ctx_require_client(sctx, "tests/tls/cert.pem");
    guard let _req = req else { die("require client"); }

    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    spawn echo_server(lfd, sctx);

    let cr: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cr else { die("mtls client ctx"); }
    let use: result[bool, str] = net.tls_ctx_use_cert(cctx, "tests/tls/cert.pem", "tests/tls/key.pem");
    guard let _use = use else { die("use cert"); }
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cconn = dr else { die("mtls dial"); }
    net.tls_send(cconn, b"ping");
    let rr: result[bytes, str] = net.tls_recv(cconn, 64);
    guard let resp = rr else { die("mtls recv"); }
    if resp == b"pong" {
        println("mtls round-trip ok");
    } else {
        die("mtls bad response");
    }
    net.tls_close(cconn);
}

// scenario 5: server requires a client cert; client sends none
fn scenario_mtls_no_cert() {
    let sr: result[rawptr, str] = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
    guard let sctx = sr else { die("mtls-no server ctx"); }
    let req: result[bool, str] = net.tls_ctx_require_client(sctx, "tests/tls/cert.pem");
    guard let _req = req else { die("require client"); }

    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    spawn reject_server(lfd, sctx);

    let cr: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cr else { die("mtls-no client ctx"); }
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cconn = dr else {
        println("correctly rejected: missing client cert");
        return;
    }
    let sendr: result[i32, str] = net.tls_send(cconn, b"ping");
    guard let _n = sendr else {
        println("correctly rejected: missing client cert");
        net.tls_close(cconn);
        return;
    }
    let recvr: result[bytes, str] = net.tls_recv(cconn, 64);
    guard let _data = recvr else {
        println("correctly rejected: missing client cert");
        net.tls_close(cconn);
        return;
    }
    die("expected client-cert failure but connection succeeded");
}

// scenario 6: default cert is CN=other; SNI "localhost" selects the
// localhost cert. If SNI selection failed the client would see CN=other
// and hostname verification would reject.
fn scenario_sni() {
    let sr: result[rawptr, str] = net.tls_server_ctx("tests/tls/other.pem", "tests/tls/other-key.pem");
    guard let sctx = sr else { die("sni server ctx"); }
    let add: result[bool, str] = net.tls_ctx_add_sni(sctx, "localhost", "tests/tls/cert.pem", "tests/tls/key.pem");
    guard let _add = add else { die("add sni"); }

    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { die("listen"); }
    let pr: result[i32, str] = net.port(lfd);
    guard let port = pr else { die("port"); }
    spawn echo_server(lfd, sctx);

    let cr: result[rawptr, str] = net.tls_client_ctx("tests/tls/cert.pem");
    guard let cctx = cr else { die("sni client ctx"); }
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cconn = dr else { die("sni dial"); }
    net.tls_send(cconn, b"ping");
    let rr: result[bytes, str] = net.tls_recv(cconn, 64);
    guard let resp = rr else { die("sni recv"); }
    if resp == b"pong" {
        println("sni extra cert ok");
    } else {
        die("sni bad response");
    }
    net.tls_close(cconn);
}

let sctx_r: result[rawptr, str] = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
guard let sctx = sctx_r else { die("server ctx"); }

scenario_round_trip(sctx);
scenario_untrusted_ca(sctx);
scenario_hostname_mismatch(sctx);
scenario_mtls_ok();
scenario_mtls_no_cert();
scenario_sni();
