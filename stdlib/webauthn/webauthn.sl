// WebAuthn for a relying party: passkey and security-key registration
// and login (WebAuthn Level 2/3), checked on the server.
//
//     import "webauthn";
//
//     let rp = webauthn.relying_party("example.com", "Example", ["https://example.com"]);
//
//     // Registration: send ch.options to the browser, keep ch.value in the session.
//     let ch = webauthn.begin_registration(rp, user, existing) ?? fail;
//     //   browser: navigator.credentials.create({ publicKey:
//     //              PublicKeyCredential.parseCreationOptionsFromJSON(options) })
//     //   then POST JSON.stringify(credential) back
//     let cr = webauthn.finish_registration(rp, ch.value, posted_json);
//     guard let cred = cr else let e = err_of(cr) { ... }   // store cred
//
//     // Login: the same shape.
//     let lc = webauthn.begin_login(rp, []) ?? fail;          // [] = any passkey
//     let id = webauthn.login_credential_id(posted_json) ?? fail;  // find the stored credential
//     let lr = webauthn.finish_login(rp, lc.value, cred, posted_json);
//     guard let login = lr else let e = err_of(lr) { ... }
//     cred.sign_count = login.sign_count;                     // store it back
//
// What is checked: the client data's type, challenge and origin (one of
// rp.origins; cross-origin iframes are refused), the authenticator
// data's RP ID hash and user-present flag, user verification when
// rp.user_verification is "required", the signature (ES256, EdDSA or
// RS256), and that the signature counter went up when the authenticator
// keeps one. Attestation is not verified: options ask for "none", and
// whatever format arrives is recorded in Credential.format and trusted
// no further. Challenges are 32 random bytes; keeping one per session
// and using it once is the caller's.

import "builder";
import "cbor";
import "crypto";
import "encoding";
import "json";
import "strings";

// COSE algorithm ids.
pub let ES256 = -7;
pub let EDDSA = -8;
pub let RS256 = -257;

let FLAG_UP = 0x01;
let FLAG_UV = 0x04;
let FLAG_BE = 0x08;
let FLAG_BS = 0x10;
let FLAG_AT = 0x40;
let FLAG_ED = 0x80;

pub gc struct RelyingParty {
    // The RP ID: the site's registrable domain or a host under it, with
    // no scheme or port ("example.com").
    id: str,
    name: str,
    // Every origin allowed to use it, exactly as a browser reports one
    // ("https://example.com", "https://login.example.com").
    origins: [str],
    // "preferred" (the default), "required" or "discouraged".
    user_verification: str,
    // How long the browser gives the user, in milliseconds.
    timeout_ms: int,
}

pub fn relying_party(id: str, name: str, origins: [str]) -> RelyingParty {
    return RelyingParty { id: id, name: name, origins: origins,
                          user_verification: "preferred", timeout_ms: 300000 };
}

// The account a credential is made for. `id` is an opaque handle of at
// most 64 bytes, never an email or a name: authenticators show `name`
// and `display_name`, and may keep `id` where anyone holding the device
// can read it.
pub gc struct User {
    id: bytes,
    name: str,
    display_name: str,
}

// A challenge to keep (value) and the options to send (options: JSON
// for parseCreationOptionsFromJSON / parseRequestOptionsFromJSON).
pub gc struct Challenge {
    value: bytes,
    options: str,
}

// A registered credential: what to store for the user. public_key is the
// COSE key as the authenticator sent it.
pub gc struct Credential {
    id: bytes,
    public_key: bytes,
    alg: int,
    sign_count: int,
    aaguid: bytes,
    user_verified: bool,
    // Whether the credential may be synced to other devices (a passkey
    // in a password manager), and whether it is.
    backup_eligible: bool,
    backed_up: bool,
    // The attestation format the authenticator used. Not verified.
    format: str,
}

// A login that checked out. user_handle is the User.id the authenticator
// keeps for a passkey ("" for a security key that does not): when it is
// not empty it must name the account the credential belongs to.
pub gc struct Login {
    credential_id: bytes,
    user_handle: bytes,
    sign_count: int,
    user_verified: bool,
    backed_up: bool,
}

// ---- options -------------------------------------------------------------

fn b64(b: bytes) -> str {
    return encoding.base64url_encode(b);
}

fn quoted(s: str) -> str {
    return json.encode(s);
}

fn new_challenge() -> result[bytes, str] {
    let rr = crypto.rand(32);
    guard let b = rr else let e = err_of(rr) {
        return err("webauthn: no random challenge: " + e);
    }
    return ok(b);
}

fn credential_list(w: builder.Str, key: str, creds: [Credential]) {
    w.write(",\"" + key + "\":[");
    let i = 0;
    while i < len(creds) {
        if i > 0 { w.write(","); }
        w.write("{\"type\":\"public-key\",\"id\":" + quoted(b64(creds[i].id)) + "}");
        i = i + 1;
    }
    w.write("]");
}

fn uv_ok(v: str) -> bool {
    return v == "preferred" || v == "required" || v == "discouraged";
}

// Options for navigator.credentials.create: ES256, EdDSA and RS256 keys,
// a discoverable credential (a passkey) preferred, no attestation, and
// `exclude` (the user's existing credentials) so one authenticator is
// not registered twice.
pub fn begin_registration(rp: RelyingParty, user: User, exclude: [Credential]) -> result[Challenge, str] {
    if len(user.id) == 0 || len(user.id) > 64 {
        return err("webauthn: a user id is 1 to 64 bytes");
    }
    if !uv_ok(rp.user_verification) {
        return err("webauthn: user_verification is preferred, required or discouraged");
    }
    let cr = new_challenge();
    guard let c = cr else let e = err_of(cr) {
        return err(e);
    }
    let w = builder.new_str();
    w.write("{\"rp\":{\"id\":" + quoted(rp.id) + ",\"name\":" + quoted(rp.name) + "}");
    w.write(",\"user\":{\"id\":" + quoted(b64(user.id)) + ",\"name\":" + quoted(user.name) +
            ",\"displayName\":" + quoted(user.display_name) + "}");
    w.write(",\"challenge\":" + quoted(b64(c)));
    w.write(",\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-8}," +
            "{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}]");
    w.write(",\"timeout\":" + to_str(rp.timeout_ms));
    credential_list(w, "excludeCredentials", exclude);
    w.write(",\"authenticatorSelection\":{\"residentKey\":\"preferred\",\"requireResidentKey\":false," +
            "\"userVerification\":" + quoted(rp.user_verification) + "}");
    w.write(",\"attestation\":\"none\"}");
    return ok(Challenge { value: c, options: w.finish() });
}

// Options for navigator.credentials.get. `allow` lists the credentials
// that may answer; empty lets the user pick any passkey for this site.
pub fn begin_login(rp: RelyingParty, allow: [Credential]) -> result[Challenge, str] {
    if !uv_ok(rp.user_verification) {
        return err("webauthn: user_verification is preferred, required or discouraged");
    }
    let cr = new_challenge();
    guard let c = cr else let e = err_of(cr) {
        return err(e);
    }
    let w = builder.new_str();
    w.write("{\"challenge\":" + quoted(b64(c)) + ",\"rpId\":" + quoted(rp.id));
    w.write(",\"timeout\":" + to_str(rp.timeout_ms));
    w.write(",\"userVerification\":" + quoted(rp.user_verification));
    credential_list(w, "allowCredentials", allow);
    w.write("}");
    return ok(Challenge { value: c, options: w.finish() });
}

// ---- client data ---------------------------------------------------------

fn check_client_data(rp: RelyingParty, client_data: bytes, want_type: str,
                     challenge: bytes) -> result[int, str] {
    let pr = jparse(client_data);
    guard let cd = pr else let e = err_of(pr) {
        return err("webauthn: client data: " + e);
    }
    if jstr(cd, "type") != want_type {
        return err("webauthn: client data is for " + jstr(cd, "type") + ", not " + want_type);
    }
    let gr = encoding.base64url_decode(jstr(cd, "challenge"));
    guard let got = gr else {
        return err("webauthn: the client data's challenge is not base64url");
    }
    if len(challenge) == 0 || !crypto.constant_time_eq(got, challenge) {
        return err("webauthn: the challenge does not match");
    }
    let origin = jstr(cd, "origin");
    let allowed = false;
    for o in rp.origins {
        if o == origin {
            allowed = true;
        }
    }
    if !allowed {
        return err("webauthn: origin " + origin + " is not one of the relying party's");
    }
    if jbool(cd, "crossOrigin") {
        return err("webauthn: a cross-origin request (from an iframe) is refused");
    }
    if let _t = jget(cd, "topOrigin") {
        return err("webauthn: a cross-origin request (from an iframe) is refused");
    }
    return ok(0);
}

// ---- CBOR helpers --------------------------------------------------------

// Steps over one CBOR item of any kind.
fn skip_item(r: cbor.Reader, depth: int) -> result[int, str] {
    if depth > 16 {
        return err("webauthn: CBOR nested too deeply");
    }
    let m = cbor.peek_major(r);
    if m == 0 {
        let x = cbor.read_uint(r);
        guard let _v = x else let e = err_of(x) { return err(e); }
        return ok(0);
    }
    if m == 1 {
        let x = cbor.read_int(r);
        guard let _v = x else let e = err_of(x) { return err(e); }
        return ok(0);
    }
    if m == 2 {
        let x = cbor.read_bytes(r);
        guard let _v = x else let e = err_of(x) { return err(e); }
        return ok(0);
    }
    if m == 3 {
        let x = cbor.read_text(r);
        guard let _v = x else let e = err_of(x) { return err(e); }
        return ok(0);
    }
    if m == 4 || m == 5 {
        let nr = cbor.read_array(r);
        if m == 5 {
            nr = cbor.read_map(r);
        }
        guard let n = nr else let e = err_of(nr) { return err(e); }
        let per = 1;
        if m == 5 { per = 2; }
        if n < 0 {
            while !cbor.at_break(r) {
                if cbor.remaining(r) == 0 {
                    return err("webauthn: CBOR item runs past its input");
                }
                let sr = skip_item(r, depth + 1);
                guard let _s = sr else let e = err_of(sr) { return err(e); }
            }
            let br = cbor.read_break(r);
            guard let _b = br else let e = err_of(br) { return err(e); }
            return ok(0);
        }
        let i = 0;
        while i < n * per {
            let sr = skip_item(r, depth + 1);
            guard let _s = sr else let e = err_of(sr) { return err(e); }
            i = i + 1;
        }
        return ok(0);
    }
    if m == 6 {
        let tr = cbor.read_tag(r);
        guard let _t = tr else let e = err_of(tr) { return err(e); }
        return skip_item(r, depth + 1);
    }
    if m == 7 {
        let at = r.at;
        if let _b = cbor.read_bool(r) { return ok(0); }
        r.at = at;
        if let _n = cbor.read_null(r) { return ok(0); }
        r.at = at;
        if let _f = cbor.read_float(r) { return ok(0); }
        r.at = at;
        return err("webauthn: an unknown CBOR simple value");
    }
    return err("webauthn: CBOR runs past its input");
}

// ---- COSE keys -----------------------------------------------------------

gc struct CoseKey {
    kty: int,
    alg: int,
    crv: int,
    x: bytes,
    y: bytes,
    n: bytes,
}

fn parse_cose(b: bytes) -> result[CoseKey, str] {
    let r = cbor.reader(b);
    let mr = cbor.read_map(r);
    guard let n = mr else let e = err_of(mr) {
        return err("webauthn: public key: " + e);
    }
    if n < 0 {
        return err("webauthn: public key: an indefinite-length map");
    }
    let k = CoseKey { kty: 0, alg: 0, crv: 0, x: b"", y: b"", n: b"" };
    let i = 0;
    while i < n {
        let kr = cbor.read_int(r);
        guard let key = kr else let e = err_of(kr) {
            return err("webauthn: public key: " + e);
        }
        if key == 1 || key == 3 {
            let vr = cbor.read_int(r);
            guard let v = vr else let e = err_of(vr) { return err("webauthn: public key: " + e); }
            if key == 1 { k.kty = v; } else { k.alg = v; }
        } else if key == -1 && cbor.peek_major(r) == 2 {
            let vr = cbor.read_bytes(r);
            guard let v = vr else let e = err_of(vr) { return err("webauthn: public key: " + e); }
            k.n = v;
        } else if key == -1 {
            let vr = cbor.read_int(r);
            guard let v = vr else let e = err_of(vr) { return err("webauthn: public key: " + e); }
            k.crv = v;
        } else if key == -2 || key == -3 {
            let vr = cbor.read_bytes(r);
            guard let v = vr else let e = err_of(vr) { return err("webauthn: public key: " + e); }
            if key == -2 { k.x = v; } else { k.y = v; }
        } else {
            let sr = skip_item(r, 0);
            guard let _s = sr else let e = err_of(sr) { return err(e); }
        }
        i = i + 1;
    }
    if cbor.remaining(r) != 0 {
        return err("webauthn: public key: bytes after the key");
    }
    return ok(k);
}

// That the key is one this package verifies with, and well formed for
// its algorithm.
fn check_key(k: CoseKey) -> result[int, str] {
    if k.alg == ES256 {
        if k.kty != 2 || k.crv != 1 || len(k.x) != 32 || len(k.y) != 32 {
            return err("webauthn: an ES256 key that is not a P-256 point");
        }
        return ok(0);
    }
    if k.alg == EDDSA {
        if k.kty != 1 || k.crv != 6 || len(k.x) != 32 {
            return err("webauthn: an EdDSA key that is not Ed25519");
        }
        return ok(0);
    }
    if k.alg == RS256 {
        if k.kty != 3 || len(k.n) < 256 || len(k.x) == 0 {
            return err("webauthn: an RS256 key shorter than 2048 bits");
        }
        return ok(0);
    }
    return err("webauthn: algorithm " + to_str(k.alg) + " is not supported");
}

// An ASN.1 DER INTEGER at `at`, as exactly 32 big-endian bytes.
struct IntAt {
    v: bytes,
    next: int,
    fail: bool,
}

fn der_int(b: bytes, at: int) -> IntAt {
    let bad = IntAt { v: b"", next: 0, fail: true };
    if at + 2 > len(b) || b[at] != 0x02 {
        return bad;
    }
    let l = b[at + 1] as int;
    let s = at + 2;
    if l == 0 || l > 33 || s + l > len(b) {
        return bad;
    }
    // DER: no negative values, and no leading zero that is not needed.
    if (b[s] as int) >= 0x80 {
        return bad;
    }
    if l > 1 && b[s] == 0 && (b[s + 1] as int) < 0x80 {
        return bad;
    }
    let v = b[s..s + l];
    if l == 33 {
        v = b[s + 1..s + l];
    }
    let out = builder.new_bytes();
    let pad = 32 - len(v);
    while pad > 0 {
        out.write_byte(0);
        pad = pad - 1;
    }
    out.write(v);
    return IntAt { v: out.finish(), next: s + l, fail: false };
}

// An ECDSA signature as WebAuthn sends it (DER) to r || s.
fn der_to_raw(sig: bytes) -> result[bytes, str] {
    if len(sig) < 8 || sig[0] != 0x30 || (sig[1] as int) != len(sig) - 2 {
        return err("webauthn: an ES256 signature that is not DER");
    }
    let r = der_int(sig, 2);
    if r.fail {
        return err("webauthn: an ES256 signature that is not DER");
    }
    let s = der_int(sig, r.next);
    if s.fail || s.next != len(sig) {
        return err("webauthn: an ES256 signature that is not DER");
    }
    return ok(r.v + s.v);
}

fn verify_signature(k: CoseKey, msg: bytes, sig: bytes) -> result[bool, str] {
    if k.alg == ES256 {
        let rr = der_to_raw(sig);
        guard let raw = rr else let e = err_of(rr) {
            return err(e);
        }
        return crypto.ecdsa_p256_verify_sha256(b"\x04" + k.x + k.y, msg, raw);
    }
    if k.alg == EDDSA {
        return crypto.ed25519_verify(k.x, msg, sig);
    }
    if k.alg == RS256 {
        return crypto.rsa_verify_sha256(k.n, k.x, msg, sig);
    }
    return err("webauthn: algorithm " + to_str(k.alg) + " is not supported");
}

// ---- authenticator data --------------------------------------------------

gc struct AuthData {
    flags: int,
    sign_count: int,
    aaguid: bytes,
    cred_id: bytes,
    cose: bytes,
}

fn get16(b: bytes, at: int) -> int {
    return ((b[at] as int) << 8) | (b[at + 1] as int);
}

fn parse_auth_data(rp: RelyingParty, b: bytes) -> result[AuthData, str] {
    if len(b) < 37 {
        return err("webauthn: authenticator data shorter than 37 bytes");
    }
    if !crypto.constant_time_eq(b[0..32], crypto.sha256(to_bytes(rp.id))) {
        return err("webauthn: authenticator data is for another RP ID");
    }
    let flags = b[32] as int;
    if (flags & FLAG_UP) == 0 {
        return err("webauthn: the user was not present");
    }
    if rp.user_verification == "required" && (flags & FLAG_UV) == 0 {
        return err("webauthn: the user was not verified");
    }
    if (flags & FLAG_BS) != 0 && (flags & FLAG_BE) == 0 {
        return err("webauthn: backed up but not backup-eligible");
    }
    let count = (get16(b, 33) << 16) | get16(b, 35);
    let ad = AuthData { flags: flags, sign_count: count, aaguid: b"", cred_id: b"", cose: b"" };
    let at = 37;
    if (flags & FLAG_AT) != 0 {
        if at + 18 > len(b) {
            return err("webauthn: attested credential data runs past its input");
        }
        ad.aaguid = b[at..at + 16];
        let l = get16(b, at + 16);
        let start = at + 18;
        if l == 0 || l > 1023 || start + l > len(b) {
            return err("webauthn: a credential id that is empty, too long, or past its input");
        }
        ad.cred_id = b[start..start + l];
        let key_at = start + l;
        let r = cbor.reader(b[key_at..]);
        let sr = skip_item(r, 0);
        guard let _s = sr else let e = err_of(sr) {
            return err("webauthn: public key: " + e);
        }
        ad.cose = b[key_at..key_at + r.at];
        at = key_at + r.at;
    }
    if (flags & FLAG_ED) != 0 {
        let r = cbor.reader(b[at..]);
        let sr = skip_item(r, 0);
        guard let _s = sr else let e = err_of(sr) {
            return err("webauthn: extensions: " + e);
        }
        at = at + r.at;
    }
    if at != len(b) {
        return err("webauthn: bytes after the authenticator data");
    }
    return ok(ad);
}

// ---- registration --------------------------------------------------------

// Checks a registration from its parts: the client data JSON and the
// attestation object, both raw bytes (not base64url).
pub fn verify_registration(rp: RelyingParty, challenge: bytes, client_data: bytes,
                           attestation_object: bytes) -> result[Credential, str] {
    let cr = check_client_data(rp, client_data, "webauthn.create", challenge);
    guard let _c = cr else let e = err_of(cr) {
        return err(e);
    }
    let r = cbor.reader(attestation_object);
    let mr = cbor.read_map(r);
    guard let n = mr else let e = err_of(mr) {
        return err("webauthn: attestation object: " + e);
    }
    if n < 0 {
        return err("webauthn: attestation object: an indefinite-length map");
    }
    let fmt = "";
    let auth: opt[bytes] = none;
    let i = 0;
    while i < n {
        let kr = cbor.read_text(r);
        guard let key = kr else let e = err_of(kr) {
            return err("webauthn: attestation object: " + e);
        }
        if key == "fmt" {
            let fr = cbor.read_text(r);
            guard let f = fr else let e = err_of(fr) { return err("webauthn: attestation object: " + e); }
            fmt = f;
        } else if key == "authData" {
            let ar = cbor.read_bytes(r);
            guard let a = ar else let e = err_of(ar) { return err("webauthn: attestation object: " + e); }
            auth = some(a);
        } else {
            let sr = skip_item(r, 0);
            guard let _s = sr else let e = err_of(sr) { return err(e); }
        }
        i = i + 1;
    }
    if cbor.remaining(r) != 0 {
        return err("webauthn: attestation object: bytes after it");
    }
    guard let raw = auth else {
        return err("webauthn: attestation object without authenticator data");
    }
    let pr = parse_auth_data(rp, raw);
    guard let ad = pr else let e = err_of(pr) {
        return err(e);
    }
    if (ad.flags & FLAG_AT) == 0 {
        return err("webauthn: a registration without a credential");
    }
    let kr = parse_cose(ad.cose);
    guard let key = kr else let e = err_of(kr) {
        return err(e);
    }
    let ck = check_key(key);
    guard let _k = ck else let e = err_of(ck) {
        return err(e);
    }
    return ok(Credential {
        id: ad.cred_id, public_key: ad.cose, alg: key.alg, sign_count: ad.sign_count,
        aaguid: ad.aaguid, user_verified: (ad.flags & FLAG_UV) != 0,
        backup_eligible: (ad.flags & FLAG_BE) != 0, backed_up: (ad.flags & FLAG_BS) != 0,
        format: fmt
    });
}

fn field_b64(o: JValue, key: str) -> result[bytes, str] {
    let v = jget(o, key);
    guard let got = v else {
        return err("webauthn: the response has no " + key);
    }
    if got.kind != J_STR {
        return err("webauthn: the response's " + key + " is not a string");
    }
    let dr = encoding.base64url_decode(got.s);
    guard let b = dr else {
        return err("webauthn: the response's " + key + " is not base64url");
    }
    return ok(b);
}

struct Posted {
    id: bytes,
    response: JValue,
    fail: str,
}

fn posted(response_json: str) -> Posted {
    let empty = jblank(J_NULL);
    let pr = jparse(to_bytes(response_json));
    guard let top = pr else let e = err_of(pr) {
        return Posted { id: b"", response: empty, fail: "webauthn: response: " + e };
    }
    if jstr(top, "type") != "public-key" {
        return Posted { id: b"", response: empty, fail: "webauthn: not a public-key credential" };
    }
    let ir = field_b64(top, "rawId");
    guard let id = ir else let e = err_of(ir) {
        return Posted { id: b"", response: empty, fail: e };
    }
    // id is rawId in base64url; a browser that sent both sent the same.
    if let named = jget(top, "id") {
        if named.kind != J_STR || named.s != b64(id) {
            return Posted { id: b"", response: empty, fail: "webauthn: id and rawId differ" };
        }
    }
    let rr = jget(top, "response");
    guard let resp = rr else {
        return Posted { id: b"", response: empty, fail: "webauthn: the credential has no response" };
    }
    return Posted { id: id, response: resp, fail: "" };
}

// Checks a registration as the browser posts it: JSON.stringify of the
// PublicKeyCredential (its toJSON()).
pub fn finish_registration(rp: RelyingParty, challenge: bytes, response_json: str) -> result[Credential, str] {
    let p = posted(response_json);
    if len(p.fail) > 0 {
        return err(p.fail);
    }
    let cr = field_b64(p.response, "clientDataJSON");
    guard let cd = cr else let e = err_of(cr) {
        return err(e);
    }
    let ar = field_b64(p.response, "attestationObject");
    guard let ao = ar else let e = err_of(ar) {
        return err(e);
    }
    let vr = verify_registration(rp, challenge, cd, ao);
    guard let cred = vr else let e = err_of(vr) {
        return err(e);
    }
    if !crypto.constant_time_eq(cred.id, p.id) {
        return err("webauthn: the credential id does not match the authenticator data");
    }
    return ok(cred);
}

// ---- login ---------------------------------------------------------------

// Checks a login from its parts, all raw bytes: the client data JSON,
// the authenticator data and the signature over both. The caller looked
// up `cred` by the credential id the browser sent.
pub fn verify_login(rp: RelyingParty, challenge: bytes, cred: Credential, client_data: bytes,
                    authenticator_data: bytes, signature: bytes) -> result[Login, str] {
    let cr = check_client_data(rp, client_data, "webauthn.get", challenge);
    guard let _c = cr else let e = err_of(cr) {
        return err(e);
    }
    let pr = parse_auth_data(rp, authenticator_data);
    guard let ad = pr else let e = err_of(pr) {
        return err(e);
    }
    let kr = parse_cose(cred.public_key);
    guard let key = kr else let e = err_of(kr) {
        return err(e);
    }
    if key.alg != cred.alg {
        return err("webauthn: the stored key's algorithm does not match the credential's");
    }
    let ck = check_key(key);
    guard let _k = ck else let e = err_of(ck) {
        return err(e);
    }
    let signed = authenticator_data + crypto.sha256(client_data);
    let sr = verify_signature(key, signed, signature);
    guard let good = sr else let e = err_of(sr) {
        return err(e);
    }
    if !good {
        return err("webauthn: the signature does not verify");
    }
    // A counter that does not go up means two authenticators hold one
    // key: a clone. Zero on both sides is an authenticator with none.
    if (ad.sign_count != 0 || cred.sign_count != 0) && ad.sign_count <= cred.sign_count {
        return err("webauthn: the signature counter did not increase (a cloned authenticator?)");
    }
    return ok(Login { credential_id: cred.id, user_handle: b"", sign_count: ad.sign_count,
                      user_verified: (ad.flags & FLAG_UV) != 0,
                      backed_up: (ad.flags & FLAG_BS) != 0 });
}

// The credential id a posted login names, to look the stored credential
// up by before finish_login.
pub fn login_credential_id(response_json: str) -> result[bytes, str] {
    let p = posted(response_json);
    if len(p.fail) > 0 {
        return err(p.fail);
    }
    return ok(p.id);
}

// Checks a login as the browser posts it: JSON.stringify of the
// PublicKeyCredential.
pub fn finish_login(rp: RelyingParty, challenge: bytes, cred: Credential,
                    response_json: str) -> result[Login, str] {
    let p = posted(response_json);
    if len(p.fail) > 0 {
        return err(p.fail);
    }
    if !crypto.constant_time_eq(p.id, cred.id) {
        return err("webauthn: the login is for another credential");
    }
    let cr = field_b64(p.response, "clientDataJSON");
    guard let cd = cr else let e = err_of(cr) {
        return err(e);
    }
    let ar = field_b64(p.response, "authenticatorData");
    guard let ad = ar else let e = err_of(ar) {
        return err(e);
    }
    let sr = field_b64(p.response, "signature");
    guard let sig = sr else let e = err_of(sr) {
        return err(e);
    }
    let lr = verify_login(rp, challenge, cred, cd, ad, sig);
    guard let login = lr else let e = err_of(lr) {
        return err(e);
    }
    if let uh = jget(p.response, "userHandle") {
        if uh.kind == J_STR && len(uh.s) > 0 {
            let hr = encoding.base64url_decode(uh.s);
            guard let handle = hr else {
                return err("webauthn: the response's userHandle is not base64url");
            }
            login.user_handle = handle;
        }
    }
    return ok(login);
}
