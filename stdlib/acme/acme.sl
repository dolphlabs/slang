// ACME (RFC 8555): certificates from Let's Encrypt or any ACME CA,
// obtained and renewed by the program itself, with http-01 challenges.
//
//     import "acme";
//
//     let store = acme.challenges();     // the HTTP server answers from it
//     // in the port-80 handler:
//     //   if let body = acme.http01(store, path) { answer 200 with body }
//
//     let ar = acme.account(acme.LETSENCRYPT, account_key, ["mailto:ops@example.com"], deadline);
//     guard let acct = ar else { ... }
//     let cr = acme.obtain(acct, store, ["example.com", "www.example.com"], deadline);
//     guard let cert = cr else { ... }
//     // cert.chain_pem and cert.key_pem: hand them to net.tls_ctx_add_sni
//
// The account key is a P-256 key (crypto.ecdsa_p256_generate); keep it, as
// the account is tied to it. Each certificate gets a fresh P-256 key.
// renew_due(chain_pem, days) says when to renew (Let's Encrypt suggests a
// third of the lifetime before expiry: 30 days for a 90-day certificate).

import "builder";
import "crypto";
import "encoding";
import "httpc";
import "strings";
import "time";
import "x509";

pub let LETSENCRYPT = "https://acme-v02.api.letsencrypt.org/directory";
pub let LETSENCRYPT_STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory";

pub gc struct Account {
    directory: Dir,
    key: bytes,         // P-256 private key
    jwk: str,           // its public JWK, canonical (RFC 7638) member order
    thumbprint: str,    // base64url SHA-256 of jwk
    kid: str,           // the account URL
    nonce: str,
    http: httpc.Client,
}

pub struct Dir {
    new_nonce: str,
    new_account: str,
    new_order: str,
}

pub struct Certificate {
    chain_pem: str,     // the certificate, then its issuers
    key_pem: str,       // its private key
    not_after: int,     // unix seconds
}

pub gc struct Challenges {
    mu: mutex,
    tokens: map[str]str,
}

pub fn challenges() -> Challenges {
    let m: map[str]str = {};
    return Challenges { mu: make_mutex(), tokens: m };
}

// The body to answer a GET for path with, if it is a pending http-01
// challenge ("/.well-known/acme-challenge/<token>").
pub fn http01(c: Challenges, path: str) -> opt[str] {
    let prefix = "/.well-known/acme-challenge/";
    if !strings.has_prefix(path, prefix) { return none; }
    let token = strings.slice(path, len(prefix), len(path));
    mutex_lock(c.mu);
    let have = has(c.tokens, token);
    let body = "";
    if have { body = c.tokens[token]; }
    mutex_unlock(c.mu);
    if have { return some(body); }
    return none;
}

// Registers (or finds) the account for key at the CA, agreeing to its
// terms of service.
pub fn account(directory_url: str, key: bytes, contact: [str], deadline: until) -> result[Account, str] {
    let dr = httpc.get(directory_url, deadline);
    guard let resp = dr else let e = err_of(dr) { return err("acme: directory: " + e); }
    let jr = jparse(resp.body);
    guard let d = jr else let je = err_of(jr) { return err("acme: directory: " + je); }
    let dir = Dir { new_nonce: jstr(d, "newNonce"), new_account: jstr(d, "newAccount"),
                    new_order: jstr(d, "newOrder") };
    if len(dir.new_nonce) == 0 || len(dir.new_account) == 0 || len(dir.new_order) == 0 {
        return err("acme: directory lacks newNonce/newAccount/newOrder");
    }
    let pr = crypto.ecdsa_p256_public_key(key);
    guard let pt = pr else let pe = err_of(pr) { return err("acme: account key: " + pe); }
    let jwk = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"" + b64u(pt[1..33]) + "\",\"y\":\"" + b64u(pt[33..65]) + "\"}";
    let a = Account { directory: dir, key: key, jwk: jwk, thumbprint: b64u(crypto.sha256(to_bytes(jwk))),
                      kid: "", nonce: "", http: httpc.new_client() };
    let contacts: [str] = [];
    for c in contact { push(contacts, json_str(c)); }
    let payload = "{\"termsOfServiceAgreed\":true,\"contact\":[" + strings.join(contacts, ",") + "]}";
    let rr = post(a, dir.new_account, payload, deadline);
    guard let r = rr else let e = err_of(rr) { return err(e); }
    if r.status != 200 && r.status != 201 { return err("acme: newAccount: " + problem(r)); }
    a.kid = httpc.header(r, "Location") ?? "";
    if len(a.kid) == 0 { return err("acme: newAccount gave no account URL"); }
    return ok(a);
}

// Orders a certificate for names (DNS names), answers their http-01
// challenges through store, and returns the issued chain with its new key.
pub fn obtain(a: Account, store: Challenges, names: [str], deadline: until) -> result[Certificate, str] {
    if len(names) == 0 { return err("acme: no names"); }
    let ids: [str] = [];
    for n in names { push(ids, "{\"type\":\"dns\",\"value\":" + json_str(n) + "}"); }
    let or = post(a, a.directory.new_order, "{\"identifiers\":[" + strings.join(ids, ",") + "]}", deadline);
    guard let ord = or else let oe = err_of(or) { return err(oe); }
    if ord.status != 201 { return err("acme: newOrder: " + problem(ord)); }
    let order_url = httpc.header(ord, "Location") ?? "";
    let odr = jparse(ord.body);
    guard let order = odr else let ode = err_of(odr) { return err("acme: order: " + ode); }
    let finalize_url = jstr(order, "finalize");
    let authz_urls: [str] = [];
    if let az = jget(order, "authorizations") {
        for u in az.items { push(authz_urls, u.s); }
    }
    let used: [str] = [];
    for au in authz_urls {
        let r = authorize(a, store, au, deadline, used);
        guard let _ok = r else let e = err_of(r) { forget(store, used); return err(e); }
    }
    forget(store, used);
    // a fresh key for the certificate, and the CSR for the names
    let kr = crypto.ecdsa_p256_generate();
    guard let ck = kr else let ke = err_of(kr) { return err("acme: " + ke); }
    let kpr = crypto.ecdsa_p256_private_to_pem(ck);
    guard let key_pem = kpr else let kpe = err_of(kpr) { return err("acme: " + kpe); }
    let csr_r = x509.csr(key_pem, x509.Request { common_name: names[0], dns_names: names, ip_addrs: [] });
    guard let csr_pem = csr_r else let cse = err_of(csr_r) { return err("acme: csr: " + cse); }
    let der_r = pem_body(csr_pem);
    guard let der = der_r else let de = err_of(der_r) { return err(de); }
    let fr = post(a, finalize_url, "{\"csr\":\"" + b64u(der) + "\"}", deadline);
    guard let fin = fr else let fe = err_of(fr) { return err(fe); }
    if fin.status != 200 { return err("acme: finalize: " + problem(fin)); }
    // poll the order until the certificate is ready
    let url = order_url;
    let doc = jparse(fin.body) ?? jblank(J_NULL);
    while jstr(doc, "status") != "valid" {
        let st = jstr(doc, "status");
        if st == "invalid" { return err("acme: order became invalid"); }
        if until_hit(deadline) { return err("acme: timeout waiting for the certificate"); }
        time.sleep(retry_after(fin));
        let pr = post(a, url, "", deadline);
        guard let p = pr else let pe = err_of(pr) { return err(pe); }
        doc = jparse(p.body) ?? jblank(J_NULL);
    }
    let cr = post(a, jstr(doc, "certificate"), "", deadline);
    guard let cert = cr else let ce = err_of(cr) { return err(ce); }
    if cert.status != 200 { return err("acme: certificate: " + problem(cert)); }
    let chain = to_str(cert.body);
    let parsed = x509.parse_pem(chain);
    guard let certs = parsed else let xe = err_of(parsed) { return err("acme: issued chain: " + xe); }
    if len(certs) == 0 { return err("acme: empty chain"); }
    return ok(Certificate { chain_pem: chain, key_pem: key_pem, not_after: certs[0].not_after });
}

// Whether a certificate expires within days.
pub fn renew_due(chain_pem: str, days: int) -> bool {
    let pr = x509.parse_pem(chain_pem);
    guard let certs = pr else { return true; }
    if len(certs) == 0 { return true; }
    let now = (time.wall() as int) / 1000000000;
    return certs[0].not_after - now < days * 86400;
}

// ---- internals -------------------------------------------------------------

fn authorize(a: Account, store: Challenges, url: str, deadline: until, used: [str]) -> result[bool, str] {
    let rr = post(a, url, "", deadline);
    guard let r = rr else let e = err_of(rr) { return err(e); }
    let jr = jparse(r.body);
    guard let authz = jr else let je = err_of(jr) { return err("acme: authorization: " + je); }
    if jstr(authz, "status") == "valid" { return ok(true); }
    let chal_url = "";
    let token = "";
    if let cs = jget(authz, "challenges") {
        for c in cs.items {
            if jstr(c, "type") == "http-01" { chal_url = jstr(c, "url"); token = jstr(c, "token"); }
        }
    }
    if len(chal_url) == 0 { return err("acme: no http-01 challenge offered"); }
    if !token_ok(token) { return err("acme: bad challenge token"); }
    mutex_lock(store.mu);
    store.tokens[token] = token + "." + a.thumbprint;
    mutex_unlock(store.mu);
    push(used, token);
    let cr = post(a, chal_url, "{}", deadline);
    guard let c = cr else let ce = err_of(cr) { return err(ce); }
    if c.status != 200 { return err("acme: challenge: " + problem(c)); }
    while true {
        if until_hit(deadline) { return err("acme: timeout waiting for validation"); }
        time.sleep(retry_after(c));
        let pr = post(a, url, "", deadline);
        guard let p = pr else let pe = err_of(pr) { return err(pe); }
        let dr = jparse(p.body);
        guard let d = dr else { return err("acme: unreadable authorization"); }
        let st = jstr(d, "status");
        if st == "valid" { return ok(true); }
        if st == "invalid" { return err("acme: validation failed for " + url); }
    }
    return err("acme: unreachable");
}

fn forget(store: Challenges, tokens: [str]) {
    mutex_lock(store.mu);
    for t in tokens { if has(store.tokens, t) { del(store.tokens, t); } }
    mutex_unlock(store.mu);
}

// base64url characters only: the token becomes part of a URL path served
// from our own handler.
fn token_ok(t: str) -> bool {
    let b = to_bytes(t);
    if len(b) < 16 { return false; }
    for i in 0..len(b) {
        let c = b[i] as int;
        let good = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95;
        if !good { return false; }
    }
    return true;
}

// A signed POST (a JWS, RFC 8555 6.2), retried once on badNonce. An empty
// payload is a POST-as-GET.
fn post(a: Account, url: str, payload: str, deadline: until) -> result[httpc.Response, str] {
    for attempt in 0..2 {
        if len(a.nonce) == 0 {
            let nr = httpc.client_send(a.http, httpc.new_request("HEAD", a.directory.new_nonce), deadline);
            guard let n = nr else let ne = err_of(nr) { return err("acme: newNonce: " + ne); }
            a.nonce = httpc.header(n, "Replay-Nonce") ?? "";
            if len(a.nonce) == 0 { return err("acme: no Replay-Nonce"); }
        }
        let prot = "{\"alg\":\"ES256\",\"nonce\":" + json_str(a.nonce) + ",\"url\":" + json_str(url);
        if len(a.kid) > 0 { prot = prot + ",\"kid\":" + json_str(a.kid) + "}"; }
        else { prot = prot + ",\"jwk\":" + a.jwk + "}"; }
        let p64 = b64u(to_bytes(prot));
        let body64 = "";
        if len(payload) > 0 { body64 = b64u(to_bytes(payload)); }
        let sr = crypto.ecdsa_p256_sign_sha256(a.key, to_bytes(p64 + "." + body64));
        guard let sig = sr else let se = err_of(sr) { return err("acme: sign: " + se); }
        let rq = httpc.new_request("POST", url);
        rq.headers["Content-Type"] = "application/jose+json";
        rq.body = to_bytes("{\"protected\":\"" + p64 + "\",\"payload\":\"" + body64 + "\",\"signature\":\"" + b64u(sig) + "\"}");
        a.nonce = "";
        let rr = httpc.client_send(a.http, rq, deadline);
        guard let r = rr else let e = err_of(rr) { return err("acme: " + e); }
        a.nonce = httpc.header(r, "Replay-Nonce") ?? "";
        if r.status == 400 && strings.contains(to_str(r.body), "urn:ietf:params:acme:error:badNonce") && attempt == 0 {
            continue;
        }
        return ok(r);
    }
    return err("acme: badNonce twice");
}

fn problem(r: httpc.Response) -> str {
    let jr = jparse(r.body);
    guard let p = jr else { return "status " + to_str(r.status); }
    return to_str(r.status) + " " + jstr(p, "type") + ": " + jstr(p, "detail");
}

fn retry_after(r: httpc.Response) -> int {
    let s = to_int(httpc.header(r, "Retry-After") ?? "") ?? 1;
    if s < 1 { s = 1; }
    if s > 30 { s = 30; }
    return s * 1000000000;
}

fn b64u(b: bytes) -> str {
    let s = encoding.base64url_encode(b);
    while strings.has_suffix(s, "=") { s = strings.slice(s, 0, len(s) - 1); }
    return s;
}

fn json_str(s: str) -> str {
    let out = builder.new_bytes();
    out.write_byte(34);
    let b = to_bytes(s);
    for i in 0..len(b) {
        let c = b[i] as int;
        if c == 34 || c == 92 { out.write_byte(92); out.write_byte(c); }
        else if c < 32 { out.write_str("\\u00"); out.write_str(strings.slice("0123456789abcdef", c >> 4, (c >> 4) + 1)); out.write_str(strings.slice("0123456789abcdef", c & 15, (c & 15) + 1)); }
        else { out.write_byte(c); }
    }
    out.write_byte(34);
    return to_str(out.finish());
}

// The DER inside a PEM block.
fn pem_body(pem: str) -> result[bytes, str] {
    let lines = strings.split(strings.replace(pem, "\r", ""), "\n");
    let b64 = "";
    for l in lines {
        if strings.has_prefix(l, "-----") || len(l) == 0 { continue; }
        b64 = b64 + strings.trim(l);
    }
    let dr = encoding.base64_decode(b64);
    guard let d = dr else { return err("acme: bad PEM"); }
    return ok(d);
}
