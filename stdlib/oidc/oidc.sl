// OAuth 2.0 and OpenID Connect for a client: sign users in with Google,
// Microsoft, Okta, Auth0, Keycloak and the like, and call APIs with
// client credentials.
//
//     import "oidc";
//
//     let pr = oidc.discover("https://accounts.google.com", deadline);
//     guard let provider = pr else { ... }
//     let o = oidc.client(provider, client_id, client_secret, "https://app/callback");
//
//     // 1. send the browser off, keeping state, nonce and verifier in the
//     //    user's session
//     let pk = oidc.pkce() ?? fail();
//     let state = oidc.random_token() ?? "";
//     let nonce = oidc.random_token() ?? "";
//     redirect(oidc.authorize_url(o, ["openid", "email"], state, nonce, pk));
//
//     // 2. on the callback: check state, then trade the code
//     let tr = oidc.exchange(o, code, pk.verifier, deadline);
//     guard let tokens = tr else { ... }
//     let cr = oidc.verify_id_token(o, tokens.id_token, nonce, deadline);
//     guard let who = cr else { ... }           // who.sub, who.email
//
// ID tokens are checked as OpenID Connect Core 3.1.3.7 says: the
// signature (RS256 or ES256 only -- "none" and HMAC are refused) against
// the provider's published keys, the issuer, the audience (and azp when
// there are several), expiry with a minute of leeway, and the nonce. Keys
// are cached by kid and refetched, at most once a minute, when a token
// names a key not seen yet (the provider rotated).

import "builder";
import "crypto";
import "encoding";
import "httpc";
import "strings";
import "time";

pub struct Provider {
    issuer: str,
    authorization_endpoint: str,
    token_endpoint: str,
    jwks_uri: str,
    userinfo_endpoint: str,
}

struct Jwk {
    kty: str,
    n: bytes,
    e: bytes,
    ec_point: bytes,   // 0x04 || x || y for P-256
}

pub gc struct Client {
    p: Provider,
    client_id: str,
    client_secret: str,
    redirect_uri: str,
    http: httpc.Client,
    mu: mutex,
    keys: map[str]Jwk,
    keys_at: int,
    leeway_s: int,
}

pub struct Pkce {
    verifier: str,
    challenge: str,
}

pub struct Tokens {
    access_token: str,
    token_type: str,
    expires_in: int,
    refresh_token: str,
    id_token: str,
    scope: str,
}

pub struct Claims {
    sub: str,
    iss: str,
    aud: [str],
    exp: int,
    iat: int,
    nonce: str,
    email: str,
    email_verified: bool,
    name: str,
    // every claim, for ones not named above
    raw: JValue,
}

// The provider's configuration from its discovery document. Its issuer
// must equal the one asked for, and endpoints must be https (http is
// allowed only on localhost, for tests).
pub fn discover(issuer: str, deadline: until) -> result[Provider, str] {
    let iss = issuer;
    while strings.has_suffix(iss, "/") { iss = strings.slice(iss, 0, len(iss) - 1); }
    let rr = httpc.get(iss + "/.well-known/openid-configuration", deadline);
    guard let resp = rr else let e = err_of(rr) { return err("oidc: discovery: " + e); }
    if resp.status != 200 { return err("oidc: discovery answered " + to_str(resp.status)); }
    let jr = jparse(resp.body);
    guard let doc = jr else let je = err_of(jr) { return err("oidc: discovery: " + je); }
    let p = Provider { issuer: jstr(doc, "issuer"),
                       authorization_endpoint: jstr(doc, "authorization_endpoint"),
                       token_endpoint: jstr(doc, "token_endpoint"),
                       jwks_uri: jstr(doc, "jwks_uri"),
                       userinfo_endpoint: jstr(doc, "userinfo_endpoint") };
    if p.issuer != iss { return err("oidc: discovery issuer " + p.issuer + " is not " + iss); }
    for u in [p.authorization_endpoint, p.token_endpoint, p.jwks_uri] {
        if !secure_url(u) { return err("oidc: endpoint not https: " + u); }
    }
    return ok(p);
}

pub fn client(p: Provider, client_id: str, client_secret: str, redirect_uri: str) -> Client {
    let k: map[str]Jwk = {};
    return Client { p: p, client_id: client_id, client_secret: client_secret,
                    redirect_uri: redirect_uri, http: httpc.new_client(), mu: make_mutex(),
                    keys: k, keys_at: 0, leeway_s: 60 };
}

// A PKCE verifier (keep it in the session) and its S256 challenge.
pub fn pkce() -> result[Pkce, str] {
    let rr = crypto.rand(32);
    guard let raw = rr else let e = err_of(rr) { return err("oidc: " + e); }
    let v = b64url(raw);
    return ok(Pkce { verifier: v, challenge: b64url(crypto.sha256(to_bytes(v))) });
}

// 32 random bytes, base64url: for state and nonce.
pub fn random_token() -> result[str, str] {
    let rr = crypto.rand(32);
    guard let raw = rr else let e = err_of(rr) { return err("oidc: " + e); }
    return ok(b64url(raw));
}

// Where to send the browser to sign in.
pub fn authorize_url(o: Client, scopes: [str], state: str, nonce: str, pk: Pkce) -> str {
    let sep = "?";
    if strings.contains(o.p.authorization_endpoint, "?") { sep = "&"; }
    return o.p.authorization_endpoint + sep + "response_type=code&client_id=" +
           encoding.url_encode(o.client_id) + "&redirect_uri=" + encoding.url_encode(o.redirect_uri) +
           "&scope=" + encoding.url_encode(strings.join(scopes, " ")) + "&state=" +
           encoding.url_encode(state) + "&nonce=" + encoding.url_encode(nonce) +
           "&code_challenge=" + pk.challenge + "&code_challenge_method=S256";
}

// Trades an authorization code (with its PKCE verifier) for tokens.
pub fn exchange(o: Client, code: str, verifier: str, deadline: until) -> result[Tokens, str] {
    return token_request(o, "grant_type=authorization_code&code=" + encoding.url_encode(code) +
                            "&redirect_uri=" + encoding.url_encode(o.redirect_uri) +
                            "&code_verifier=" + encoding.url_encode(verifier), deadline);
}

pub fn refresh(o: Client, refresh_token: str, deadline: until) -> result[Tokens, str] {
    return token_request(o, "grant_type=refresh_token&refresh_token=" +
                            encoding.url_encode(refresh_token), deadline);
}

// Tokens for the client itself (service to service).
pub fn client_credentials(o: Client, scopes: [str], deadline: until) -> result[Tokens, str] {
    let body = "grant_type=client_credentials";
    if len(scopes) > 0 { body = body + "&scope=" + encoding.url_encode(strings.join(scopes, " ")); }
    return token_request(o, body, deadline);
}

// Checks an ID token and returns its claims.
pub fn verify_id_token(o: Client, token: str, nonce: str, deadline: until) -> result[Claims, str] {
    let parts = strings.split(token, ".");
    if len(parts) != 3 { return err("oidc: not a JWT"); }
    let hr = b64url_decode(parts[0]);
    guard let hb = hr else { return err("oidc: bad JWT header"); }
    let hj = jparse(hb);
    guard let head = hj else let he = err_of(hj) { return err("oidc: header: " + he); }
    let alg = jstr(head, "alg");
    if alg != "RS256" && alg != "ES256" { return err("oidc: algorithm " + alg + " is not accepted"); }
    let kid = jstr(head, "kid");
    let kr = key_for(o, kid, deadline);
    guard let key = kr else let ke = err_of(kr) { return err(ke); }
    let sr = b64url_decode(parts[2]);
    guard let sig = sr else { return err("oidc: bad signature encoding"); }
    let signed = to_bytes(parts[0] + "." + parts[1]);
    let good = false;
    if alg == "RS256" {
        if key.kty != "RSA" { return err("oidc: RS256 token, but key " + kid + " is " + key.kty); }
        good = crypto.rsa_verify_sha256(key.n, key.e, signed, sig) ?? false;
    } else {
        if key.kty != "EC" { return err("oidc: ES256 token, but key " + kid + " is " + key.kty); }
        good = crypto.ecdsa_p256_verify_sha256(key.ec_point, signed, sig) ?? false;
    }
    if !good { return err("oidc: signature does not verify"); }
    let pr = b64url_decode(parts[1]);
    guard let pb = pr else { return err("oidc: bad payload encoding"); }
    let cj = jparse(pb);
    guard let c = cj else let ce = err_of(cj) { return err("oidc: claims: " + ce); }
    let aud: [str] = [];
    if let a = jget(c, "aud") {
        if a.kind == J_STR { push(aud, a.s); }
        if a.kind == J_ARR { for x in a.items { if x.kind == J_STR { push(aud, x.s); } } }
    }
    let claims = Claims { sub: jstr(c, "sub"), iss: jstr(c, "iss"), aud: aud, exp: jnum(c, "exp"),
                          iat: jnum(c, "iat"), nonce: jstr(c, "nonce"), email: jstr(c, "email"),
                          email_verified: jbool(c, "email_verified"), name: jstr(c, "name"), raw: c };
    if claims.iss != o.p.issuer { return err("oidc: issuer " + claims.iss + " is not " + o.p.issuer); }
    let mine = false;
    for a in aud { if a == o.client_id { mine = true; } }
    if !mine { return err("oidc: token is not for this client"); }
    if len(aud) > 1 && jstr(c, "azp") != o.client_id { return err("oidc: azp is not this client"); }
    let now = (time.wall() as int) / 1000000000;
    if claims.exp == 0 || now > claims.exp + o.leeway_s { return err("oidc: token expired"); }
    if claims.iat > now + o.leeway_s { return err("oidc: token issued in the future"); }
    if len(nonce) > 0 && !crypto.constant_time_eq(to_bytes(claims.nonce), to_bytes(nonce)) {
        return err("oidc: nonce does not match");
    }
    if len(claims.sub) == 0 { return err("oidc: no subject"); }
    return ok(claims);
}

// ---- internals -----------------------------------------------------------

fn secure_url(u: str) -> bool {
    if strings.has_prefix(u, "https://") { return true; }
    return strings.has_prefix(u, "http://localhost") || strings.has_prefix(u, "http://127.0.0.1");
}

fn b64url(b: bytes) -> str {
    let s = encoding.base64url_encode(b);
    while strings.has_suffix(s, "=") { s = strings.slice(s, 0, len(s) - 1); }
    return s;
}

fn b64url_decode(s: str) -> result[bytes, str] {
    let t = s;
    while len(t) % 4 != 0 { t = t + "="; }
    return encoding.base64url_decode(t);
}

fn token_request(o: Client, form: str, deadline: until) -> result[Tokens, str] {
    let rq = httpc.new_request("POST", o.p.token_endpoint);
    rq.headers["Content-Type"] = "application/x-www-form-urlencoded";
    rq.headers["Accept"] = "application/json";
    // client_secret_basic (RFC 6749 2.3.1): both parts form-encoded first
    let cred = encoding.form_encode(o.client_id) + ":" + encoding.form_encode(o.client_secret);
    rq.headers["Authorization"] = "Basic " + encoding.base64_encode(to_bytes(cred));
    rq.body = to_bytes(form);
    let rr = httpc.client_send(o.http, rq, deadline);
    guard let resp = rr else let e = err_of(rr) { return err("oidc: token request: " + e); }
    let jr = jparse(resp.body);
    guard let doc = jr else { return err("oidc: token endpoint answered " + to_str(resp.status)); }
    if resp.status != 200 {
        let ec = jstr(doc, "error");
        let ed = jstr(doc, "error_description");
        return err("oidc: token endpoint: " + ec + " " + ed);
    }
    return ok(Tokens { access_token: jstr(doc, "access_token"), token_type: jstr(doc, "token_type"),
                       expires_in: jnum(doc, "expires_in"), refresh_token: jstr(doc, "refresh_token"),
                       id_token: jstr(doc, "id_token"), scope: jstr(doc, "scope") });
}

// The key for kid, from the cache or a fresh JWKS (fetched at most once a
// minute, so tokens naming unknown keys cannot make every request fetch).
fn key_for(o: Client, kid: str, deadline: until) -> result[Jwk, str] {
    mutex_lock(o.mu);
    if has(o.keys, kid) {
        let k = o.keys[kid];
        mutex_unlock(o.mu);
        return ok(k);
    }
    let now = time.mono() as int;
    let may_fetch = o.keys_at == 0 || now - o.keys_at >= 60000000000;
    if may_fetch { o.keys_at = now; }
    mutex_unlock(o.mu);
    if !may_fetch { return err("oidc: unknown key " + kid); }
    let rr = httpc.client_get(o.http, o.p.jwks_uri, deadline);
    guard let resp = rr else let e = err_of(rr) { return err("oidc: jwks: " + e); }
    let jr = jparse(resp.body);
    guard let doc = jr else let je = err_of(jr) { return err("oidc: jwks: " + je); }
    let fresh: map[str]Jwk = {};
    if let ks = jget(doc, "keys") {
        for k in ks.items {
            let kty = jstr(k, "kty");
            let use = jstr(k, "use");
            if len(use) > 0 && use != "sig" { continue; }
            if kty == "RSA" {
                let n = b64url_decode(jstr(k, "n")) ?? b"";
                let e = b64url_decode(jstr(k, "e")) ?? b"";
                if len(n) > 0 && len(e) > 0 { fresh[jstr(k, "kid")] = Jwk { kty: kty, n: n, e: e, ec_point: b"" }; }
            } else if kty == "EC" && jstr(k, "crv") == "P-256" {
                let x = b64url_decode(jstr(k, "x")) ?? b"";
                let y = b64url_decode(jstr(k, "y")) ?? b"";
                if len(x) == 32 && len(y) == 32 {
                    fresh[jstr(k, "kid")] = Jwk { kty: kty, n: b"", e: b"", ec_point: b"\x04" + x + y };
                }
            }
        }
    }
    mutex_lock(o.mu);
    o.keys = fresh;
    let found = has(fresh, kid);
    mutex_unlock(o.mu);
    if !found { return err("oidc: unknown key " + kid); }
    return ok(fresh[kid]);
}
