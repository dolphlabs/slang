import "crypto";
import "encoding";
import "net";
import "strings";
import "time";
import "x509";

fn soon() -> until { return until_of(time.mono() + 30000000000); }

gc struct Ca {
    mu: mutex,
    base: str,
    store: Challenges,
    nonces: map[str]bool,
    next: int,
    acct_point: bytes,
    bad_nonce_once: bool,
    authz_valid: bool,
    finalized: int,
    chain: str,
    token: str,
    requests: int,
    refusals: [str],
}

fn b64d(s: str) -> bytes {
    let t = s;
    while len(t) % 4 != 0 { t = t + "="; }
    return encoding.base64url_decode(t) ?? b"";
}

fn send(fd: i32, status: int, headers: str, body: str) {
    let _s = net.send(fd, to_bytes("HTTP/1.1 " + to_str(status) + " X\r\n" + headers +
        "Content-Length: " + to_str(len(to_bytes(body))) + "\r\nConnection: close\r\n\r\n" + body));
}

fn new_nonce(ca: Ca) -> str {
    ca.next = ca.next + 1;
    let n = "nonce" + to_str(ca.next);
    ca.nonces[n] = true;
    return n;
}

// Checks a JWS request: a nonce issued and unused, the url, and the
// signature by the JWK (new account) or the account key (kid).
fn check_jws(ca: Ca, body: str, url: str) -> result[str, str] {
    let jr = jparse(to_bytes(body));
    guard let j = jr else { return err("not JSON"); }
    let prot_b64 = jstr(j, "protected");
    let pay_b64 = jstr(j, "payload");
    let pr = jparse(b64d(prot_b64));
    guard let prot = pr else { return err("bad protected header"); }
    if jstr(prot, "alg") != "ES256" { return err("alg"); }
    let nonce = jstr(prot, "nonce");
    if !has(ca.nonces, nonce) { return err("badNonce"); }
    del(ca.nonces, nonce);
    if ca.bad_nonce_once { ca.bad_nonce_once = false; return err("badNonce"); }
    if jstr(prot, "url") != ca.base + url { return err("url " + jstr(prot, "url")); }
    let point = ca.acct_point;
    if let jwk = jget(prot, "jwk") {
        point = b"\x04" + b64d(jstr(jwk, "x")) + b64d(jstr(jwk, "y"));
        ca.acct_point = point;
    } else if jstr(prot, "kid") != ca.base + "/acct/1" {
        return err("kid");
    }
    let ok_sig = crypto.ecdsa_p256_verify_sha256(point, to_bytes(prot_b64 + "." + pay_b64), b64d(jstr(j, "signature"))) ?? false;
    if !ok_sig { return err("signature"); }
    return ok(to_str(b64d(pay_b64)));
}

fn serve(ca: Ca, fd: i32) {
    let buf = "";
    let he = -1;
    while he < 0 {
        let r = net.recv_until(fd, 65536, soon());
        guard let b = r else { net.close(fd); return; }
        if len(b) == 0 { net.close(fd); return; }
        buf = buf + to_str(b);
        he = strings.find(buf, "\r\n\r\n");
    }
    let head = strings.slice(buf, 0, he);
    let lower = strings.to_lower(head);
    let cl = 0;
    let at = strings.find(lower, "content-length:");
    if at >= 0 {
        let rest = strings.slice(lower, at + 15, len(lower));
        let e = strings.find(rest, "\r\n");
        if e >= 0 { rest = strings.slice(rest, 0, e); }
        cl = to_int(strings.trim(rest)) ?? 0;
    }
    while len(buf) - he - 4 < cl {
        let r = net.recv_until(fd, 65536, soon());
        guard let b = r else { break; }
        if len(b) == 0 { break; }
        buf = buf + to_str(b);
    }
    let body = strings.slice(buf, he + 4, len(buf));
    let line = strings.slice(head, 0, strings.find(head, "\r\n"));
    let parts = strings.split(line, " ");
    let method = parts[0];
    let path = parts[1];
    mutex_lock(ca.mu);
    ca.requests = ca.requests + 1;
    if path == "/dir" {
        let d = "{\"newNonce\":\"" + ca.base + "/nonce\",\"newAccount\":\"" + ca.base + "/new-acct\",\"newOrder\":\"" + ca.base + "/new-order\"}";
        mutex_unlock(ca.mu);
        send(fd, 200, "", d);
        net.close(fd);
        return;
    }
    if path == "/nonce" {
        let n = new_nonce(ca);
        mutex_unlock(ca.mu);
        send(fd, 200, "Replay-Nonce: " + n + "\r\n", "");
        net.close(fd);
        return;
    }
    let pr = check_jws(ca, body, path);
    let nn = new_nonce(ca);
    let nh = "Replay-Nonce: " + nn + "\r\n";
    guard let payload = pr else let pe = err_of(pr) {
        push(ca.refusals, pe);
        mutex_unlock(ca.mu);
        let t = "urn:ietf:params:acme:error:malformed";
        if pe == "badNonce" { t = "urn:ietf:params:acme:error:badNonce"; }
        send(fd, 400, nh, "{\"type\":\"" + t + "\",\"detail\":\"" + pe + "\"}");
        net.close(fd);
        return;
    }
    let status = 200;
    let extra = nh;
    let out = "{}";
    if path == "/new-acct" {
        status = 201;
        extra = extra + "Location: " + ca.base + "/acct/1\r\n";
        out = "{\"status\":\"valid\"}";
    } else if path == "/new-order" {
        status = 201;
        extra = extra + "Location: " + ca.base + "/order/1\r\n";
        out = "{\"status\":\"pending\",\"authorizations\":[\"" + ca.base + "/authz/1\"],\"finalize\":\"" + ca.base + "/finalize/1\"}";
    } else if path == "/authz/1" {
        let st = "pending";
        if ca.authz_valid { st = "valid"; }
        out = "{\"status\":\"" + st + "\",\"challenges\":[{\"type\":\"dns-01\",\"url\":\"" + ca.base + "/dns\",\"token\":\"x\"},{\"type\":\"http-01\",\"url\":\"" + ca.base + "/chal/1\",\"token\":\"" + ca.token + "\"}]}";
    } else if path == "/chal/1" {
        // validate: fetch the key authorization the client publishes
        let jwk = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"" + b64u(ca.acct_point[1..33]) + "\",\"y\":\"" + b64u(ca.acct_point[33..65]) + "\"}";
        let want = ca.token + "." + b64u(crypto.sha256(to_bytes(jwk)));
        let got = http01(ca.store, "/.well-known/acme-challenge/" + ca.token) ?? "";
        ca.authz_valid = got == want;
        if !ca.authz_valid { push(ca.refusals, "key authorization " + got); }
        out = "{\"type\":\"http-01\",\"status\":\"processing\"}";
    } else if path == "/finalize/1" {
        let csr = b64d(jstr(jparse(to_bytes(payload)) ?? jblank(J_NULL), "csr"));
        if len(csr) < 10 || (csr[0] as int) != 0x30 { push(ca.refusals, "csr"); }
        ca.finalized = ca.finalized + 1;
        out = "{\"status\":\"processing\"}";
    } else if path == "/order/1" {
        out = "{\"status\":\"valid\",\"certificate\":\"" + ca.base + "/cert/1\"}";
    } else if path == "/cert/1" {
        out = ca.chain;
    }
    mutex_unlock(ca.mu);
    send(fd, status, extra + "Retry-After: 0\r\n", out);
    net.close(fd);
}

fn accept_all(ca: Ca, lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        spawn serve(ca, fd);
    }
}

fn start(store: Challenges) -> Ca {
    let lfd = net.listen(0) ?? (-1 as i32);
    let k = crypto.ecdsa_p256_generate() ?? b"";
    let pem = crypto.ecdsa_p256_private_to_pem(k) ?? "";
    let chain = x509.self_signed(pem, x509.Request { common_name: "example.com", dns_names: ["example.com"], ip_addrs: [] }, 90) ?? "";
    let n: map[str]bool = {};
    let refusals: [str] = [];
    let ca = Ca { mu: make_mutex(), base: "http://127.0.0.1:" + to_str(net.port(lfd) ?? 0), store: store,
                  nonces: n, next: 0, acct_point: b"", bad_nonce_once: true, authz_valid: false,
                  finalized: 0, chain: chain, token: "tok_0123456789abcdefABCDEF-_", requests: 0,
                  refusals: refusals };
    spawn accept_all(ca, lfd);
    return ca;
}

fn test_should_obtain_a_certificate_end_to_end() {
    let store = challenges();
    let ca = start(store);
    let key = crypto.ecdsa_p256_generate() ?? b"";
    let ar = account(ca.base + "/dir", key, ["mailto:ops@example.com"], soon());
    guard let a = ar else let e = err_of(ar) { panic("account: " + e + " refusals " + strings.join(ca.refusals, ";")); }
    assert(a.kid == ca.base + "/acct/1", "kid");
    let cr = obtain(a, store, ["example.com"], soon());
    guard let cert = cr else let e = err_of(cr) { panic("obtain: " + e + " refusals " + strings.join(ca.refusals, ";")); }
    assert(strings.contains(cert.chain_pem, "BEGIN CERTIFICATE") && strings.contains(cert.key_pem, "PRIVATE KEY"), "chain and key");
    assert(cert.not_after > (time.wall() as int) / 1000000000, "not_after");
    assert(ca.finalized == 1, "finalized");
    // the first request met a badNonce and was retried; nothing else was refused
    assert(len(ca.refusals) == 1 && ca.refusals[0] == "badNonce", "refusals: " + strings.join(ca.refusals, ";"));
    // the challenge is withdrawn once done
    if let _b = http01(store, "/.well-known/acme-challenge/" + ca.token) { panic("challenge left published"); }
    assert(!renew_due(cert.chain_pem, 30), "fresh 90-day certificate due");
    assert(renew_due(cert.chain_pem, 100), "renew_due for 100 days");
}

fn test_should_answer_only_published_challenges() {
    let s = challenges();
    if let _a = http01(s, "/.well-known/acme-challenge/nope") { panic("unknown token answered"); }
    if let _b = http01(s, "/index.html") { panic("other path answered"); }
    s.tokens["abc"] = "abc.thumb";
    assert((http01(s, "/.well-known/acme-challenge/abc") ?? "") == "abc.thumb", "published token");
}

fn test_should_refuse_unsafe_tokens() {
    assert(!token_ok("../../etc/passwd/../../xx"), "path in token");
    assert(!token_ok("short"), "short token");
    assert(token_ok("tok_0123456789abcdefABCDEF-_"), "valid token");
}

fn test_should_refuse_a_nul_in_a_json_string() {
    // A str ends at its first NUL: "https://good.example\u0000.evil" must
    // not read as "https://good.example".
    if let _v = jparse(to_bytes("{\"iss\":\"https://good.example\\u0000.evil\"}")) {
        assert(false, "a NUL in a JSON string was accepted");
    }
    let ok1 = jparse(to_bytes("{\"iss\":\"a\\u0041\"}"));
    guard let v = ok1 else let e = err_of(ok1) { panic(e); }
    assert(jstr(v, "iss") == "aA");
}
