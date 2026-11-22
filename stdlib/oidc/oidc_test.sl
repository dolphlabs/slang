import "crypto";
import "encoding";
import "net";
import "strings";
import "time";

fn soon() -> until { return until_of(time.mono() + 10000000000); }

gc struct Fake {
    mu: mutex,
    issuer: str,
    jwks: str,
    seen_auth: str,
    seen_form: str,
    token_reply: str,
    token_status: int,
    jwks_fetches: int,
    bad_endpoint: bool,
}

fn respond(fd: i32, status: int, body: str) {
    let _s = net.send(fd, to_bytes("HTTP/1.1 " + to_str(status) + " X\r\nContent-Type: application/json\r\n" +
                                   "Content-Length: " + to_str(len(to_bytes(body))) + "\r\nConnection: close\r\n\r\n" + body));
}

fn serve(f: Fake, fd: i32) {
    let buf = "";
    let head_end = -1;
    while head_end < 0 {
        let r = net.recv_until(fd, 65536, soon());
        guard let b = r else { net.close(fd); return; }
        if len(b) == 0 { net.close(fd); return; }
        buf = buf + to_str(b);
        head_end = strings.find(buf, "\r\n\r\n");
    }
    let head = strings.slice(buf, 0, head_end);
    let lower = strings.to_lower(head);
    let cl = 0;
    let at = strings.find(lower, "content-length:");
    if at >= 0 {
        let rest = strings.slice(lower, at + 15, len(lower));
        let e = strings.find(rest, "\r\n");
        if e >= 0 { rest = strings.slice(rest, 0, e); }
        cl = to_int(strings.trim(rest)) ?? 0;
    }
    while len(buf) - head_end - 4 < cl {
        let r = net.recv_until(fd, 65536, soon());
        guard let b = r else { break; }
        if len(b) == 0 { break; }
        buf = buf + to_str(b);
    }
    let body = strings.slice(buf, head_end + 4, len(buf));
    let line = strings.slice(head, 0, strings.find(head, "\r\n"));
    mutex_lock(f.mu);
    if strings.contains(line, "/.well-known/openid-configuration") {
        let tok = f.issuer + "/token";
        if f.bad_endpoint { tok = "http://evil.example/token"; }
        let doc = "{\"issuer\":\"" + f.issuer + "\",\"authorization_endpoint\":\"" + f.issuer +
                  "/auth\",\"token_endpoint\":\"" + tok + "\",\"jwks_uri\":\"" + f.issuer + "/jwks\"}";
        mutex_unlock(f.mu);
        respond(fd, 200, doc);
    } else if strings.contains(line, "/jwks") {
        f.jwks_fetches = f.jwks_fetches + 1;
        let j = f.jwks;
        mutex_unlock(f.mu);
        respond(fd, 200, j);
    } else if strings.contains(line, "/token") {
        let ai = strings.find(lower, "authorization: ");
        if ai >= 0 {
            let rest = strings.slice(head, ai + 15, len(head));
            let e = strings.find(rest, "\r\n");
            if e >= 0 { rest = strings.slice(rest, 0, e); }
            f.seen_auth = rest;
        }
        f.seen_form = body;
        let st = f.token_status;
        let rep = f.token_reply;
        mutex_unlock(f.mu);
        respond(fd, st, rep);
    } else {
        mutex_unlock(f.mu);
        respond(fd, 404, "{}");
    }
    net.close(fd);
}

fn accept_all(f: Fake, lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        spawn serve(f, fd);
    }
}

fn b64u(b: bytes) -> str {
    let s = encoding.base64url_encode(b);
    while strings.has_suffix(s, "=") { s = strings.slice(s, 0, len(s) - 1); }
    return s;
}

gc struct Keys {
    rsa_pem: str,
    ec_priv: bytes,
    jwks: str,
}

fn make_keys(rsa_kid: str, ec_kid: str) -> Keys {
    let pem = crypto.rsa_generate(2048) ?? "";
    let n = crypto.rsa_public_n(pem) ?? b"";
    let e = crypto.rsa_public_e(pem) ?? b"";
    let ec = crypto.ecdsa_p256_generate() ?? b"";
    let pt = crypto.ecdsa_p256_public_key(ec) ?? b"";
    let jwks = "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"" + rsa_kid + "\",\"use\":\"sig\",\"n\":\"" + b64u(n) +
               "\",\"e\":\"" + b64u(e) + "\"},{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"" + ec_kid +
               "\",\"x\":\"" + b64u(pt[1..33]) + "\",\"y\":\"" + b64u(pt[33..65]) + "\"}]}";
    return Keys { rsa_pem: pem, ec_priv: ec, jwks: jwks };
}

fn jwt(k: Keys, alg: str, kid: str, claims: str) -> str {
    let h = b64u(to_bytes("{\"alg\":\"" + alg + "\",\"kid\":\"" + kid + "\",\"typ\":\"JWT\"}"));
    let p = b64u(to_bytes(claims));
    let msg = to_bytes(h + "." + p);
    let sig = b"";
    if alg == "RS256" { sig = crypto.rsa_sign_sha256(k.rsa_pem, msg) ?? b""; }
    else if alg == "ES256" { sig = crypto.ecdsa_p256_sign_sha256(k.ec_priv, msg) ?? b""; }
    else { sig = crypto.hmac_sha256(b"secret", msg); }
    return h + "." + p + "." + b64u(sig);
}

fn now_s() -> int { return (time.wall() as int) / 1000000000; }

fn claims(iss: str, aud: str, nonce: str, exp_in: int) -> str {
    return "{\"iss\":\"" + iss + "\",\"sub\":\"user-1\",\"aud\":" + aud + ",\"exp\":" + to_str(now_s() + exp_in) +
           ",\"iat\":" + to_str(now_s()) + ",\"nonce\":\"" + nonce + "\",\"email\":\"ada@example.com\",\"email_verified\":true}";
}

fn setup(k: Keys) -> Fake {
    let lfd = net.listen(0) ?? (-1 as i32);
    let f = Fake { mu: make_mutex(), issuer: "http://127.0.0.1:" + to_str(net.port(lfd) ?? 0), jwks: k.jwks,
                   seen_auth: "", seen_form: "", token_reply: "{}", token_status: 200, jwks_fetches: 0,
                   bad_endpoint: false };
    spawn accept_all(f, lfd);
    return f;
}

fn connect(f: Fake) -> Client {
    let pr = discover(f.issuer + "/", soon());
    guard let p = pr else let e = err_of(pr) { panic("discover: " + e); }
    return client(p, "my client", "s3cr:et", "https://app.example/cb");
}

fn test_should_discover_and_refuse_bad_documents() {
    let k = make_keys("r1", "e1");
    let f = setup(k);
    let o = connect(f);
    assert(o.p.token_endpoint == f.issuer + "/token", "token endpoint");
    if let _x = discover("http://127.0.0.1:1", soon()) { panic("dead issuer"); }
    f.bad_endpoint = true;
    let bad = discover(f.issuer, soon());
    assert(strings.contains(err_of(bad), "not https"), "http endpoint accepted: " + err_of(bad));
}

fn test_should_build_the_authorization_url_with_pkce() {
    let k = make_keys("r1", "e1");
    let o = connect(setup(k));
    let pk = pkce() ?? Pkce { verifier: "", challenge: "" };
    assert(len(pk.verifier) == 43 && !strings.contains(pk.verifier, "="), "verifier");
    assert(pk.challenge == b64u(crypto.sha256(to_bytes(pk.verifier))), "S256 challenge");
    let u = authorize_url(o, ["openid", "email"], "st", "nc", pk);
    for want in ["/auth?response_type=code&client_id=my%20client", "redirect_uri=https%3A%2F%2Fapp.example%2Fcb",
                 "scope=openid%20email", "state=st", "nonce=nc", "code_challenge_method=S256"] {
        assert(strings.contains(u, want), "url lacks " + want + ": " + u);
    }
}

fn test_should_exchange_a_code_with_client_secret_basic() {
    let k = make_keys("r1", "e1");
    let f = setup(k);
    let o = connect(f);
    f.token_reply = "{\"access_token\":\"at\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"rt\",\"id_token\":\"x.y.z\"}";
    let tr = exchange(o, "the-code", "the-verifier", soon());
    guard let t = tr else let e = err_of(tr) { panic(e); }
    assert(t.access_token == "at" && t.expires_in == 3600 && t.refresh_token == "rt", "tokens");
    assert(f.seen_auth == "Basic " + encoding.base64_encode(to_bytes("my+client:s3cr%3Aet")), "auth: " + f.seen_auth);
    assert(strings.contains(f.seen_form, "grant_type=authorization_code") && strings.contains(f.seen_form, "code_verifier=the-verifier"), f.seen_form);
    f.token_status = 400;
    f.token_reply = "{\"error\":\"invalid_grant\",\"error_description\":\"code used\"}";
    assert(strings.contains(err_of(refresh(o, "rt", soon())), "invalid_grant code used"), "error surfaced");
}

fn test_should_verify_rs256_and_es256_id_tokens() {
    let k = make_keys("r1", "e1");
    let f = setup(k);
    let o = connect(f);
    let aud = "\"my client\"";
    let cr = verify_id_token(o, jwt(k, "RS256", "r1", claims(f.issuer, aud, "n1", 300)), "n1", soon());
    guard let c = cr else let e = err_of(cr) { panic("RS256: " + e); }
    assert(c.sub == "user-1" && c.email == "ada@example.com" && c.email_verified, "claims");
    let er = verify_id_token(o, jwt(k, "ES256", "e1", claims(f.issuer, aud, "n1", 300)), "n1", soon());
    assert(is_ok(er), "ES256: " + err_of(er));
    assert(f.jwks_fetches == 1, "keys fetched " + to_str(f.jwks_fetches) + " times");
}

fn is_ok(r: result[Claims, str]) -> bool {
    if let _c = r { return true; }
    return false;
}

fn test_should_refuse_bad_id_tokens() {
    let k = make_keys("r1", "e1");
    let f = setup(k);
    let o = connect(f);
    let aud = "\"my client\"";
    let good = jwt(k, "RS256", "r1", claims(f.issuer, aud, "n1", 300));
    let parts = strings.split(good, ".");
    let tampered = parts[0] + "." + b64u(to_bytes(claims(f.issuer, aud, "n1", 99999))) + "." + parts[2];
    let cases = [jwt(k, "HS256", "r1", claims(f.issuer, aud, "n1", 300)),
                 b64u(to_bytes("{\"alg\":\"none\"}")) + "." + parts[1] + ".",
                 tampered,
                 jwt(k, "RS256", "r1", claims(f.issuer, aud, "other-nonce", 300)),
                 jwt(k, "RS256", "r1", claims(f.issuer, "\"someone else\"", "n1", 300)),
                 jwt(k, "RS256", "r1", claims(f.issuer, "[\"my client\",\"other\"]", "n1", 300)),
                 jwt(k, "RS256", "r1", claims("https://evil.example", aud, "n1", 300)),
                 jwt(k, "RS256", "r1", claims(f.issuer, aud, "n1", -400)),
                 jwt(k, "ES256", "r1", claims(f.issuer, aud, "n1", 300))];
    let names = ["HS256", "alg none", "tampered", "nonce", "audience", "azp missing", "issuer", "expired", "key type"];
    for i in 0..len(cases) {
        if let _c = verify_id_token(o, cases[i], "n1", soon()) { panic("accepted: " + names[i]); }
    }
}

fn test_should_refetch_keys_when_the_provider_rotates() {
    let k = make_keys("r1", "e1");
    let f = setup(k);
    let o = connect(f);
    let aud = "\"my client\"";
    assert(is_ok(verify_id_token(o, jwt(k, "RS256", "r1", claims(f.issuer, aud, "n", 300)), "n", soon())), "first key");
    let k2 = make_keys("r2", "e2");
    f.jwks = k2.jwks;
    o.keys_at = 1;              // as if the last fetch was long ago
    assert(is_ok(verify_id_token(o, jwt(k2, "RS256", "r2", claims(f.issuer, aud, "n", 300)), "n", soon())), "rotated key");
    assert(f.jwks_fetches == 2, "fetches " + to_str(f.jwks_fetches));
    // an unknown kid right after a fetch does not fetch again
    if let _x = verify_id_token(o, jwt(k2, "RS256", "nope", claims(f.issuer, aud, "n", 300)), "n", soon()) { panic("unknown kid"); }
    assert(f.jwks_fetches == 2, "refetched within the minute");
}
