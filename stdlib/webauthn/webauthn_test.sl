import "builder";
import "cbor";
import "crypto";
import "encoding";
import "strings";

// ---- a software authenticator ---------------------------------------------

gc struct Auth {
    alg: int,
    key: bytes,
    pem: str,
    cose: bytes,
    id: bytes,
    count: int,
}

fn rp() -> RelyingParty {
    return relying_party("example.test", "Example", ["https://example.test", "https://login.example.test"]);
}

fn must(r: result[bytes, str]) -> bytes {
    guard let b = r else let e = err_of(r) { panic(e); }
    return b;
}

fn cose_for(alg: int, a: Auth) -> bytes {
    let w = cbor.writer();
    if alg == ES256 {
        let pubk = must(crypto.ecdsa_p256_public_key(a.key));
        cbor.write_map(w, 5);
        cbor.write_int(w, 1); cbor.write_int(w, 2);
        cbor.write_int(w, 3); cbor.write_int(w, -7);
        cbor.write_int(w, -1); cbor.write_int(w, 1);
        cbor.write_int(w, -2); cbor.write_bytes(w, pubk[1..33]);
        cbor.write_int(w, -3); cbor.write_bytes(w, pubk[33..65]);
    } else if alg == EDDSA {
        cbor.write_map(w, 4);
        cbor.write_int(w, 1); cbor.write_int(w, 1);
        cbor.write_int(w, 3); cbor.write_int(w, -8);
        cbor.write_int(w, -1); cbor.write_int(w, 6);
        cbor.write_int(w, -2); cbor.write_bytes(w, must(crypto.ed25519_public_key(a.key)));
    } else {
        cbor.write_map(w, 4);
        cbor.write_int(w, 1); cbor.write_int(w, 3);
        cbor.write_int(w, 3); cbor.write_int(w, -257);
        cbor.write_int(w, -1); cbor.write_bytes(w, must(crypto.rsa_public_n(a.pem)));
        cbor.write_int(w, -2); cbor.write_bytes(w, must(crypto.rsa_public_e(a.pem)));
    }
    return cbor.finish(w);
}

fn authenticator(alg: int) -> Auth {
    let a = Auth { alg: alg, key: b"", pem: "", cose: b"", id: must(crypto.rand(16)), count: 0 };
    if alg == ES256 {
        a.key = must(crypto.ecdsa_p256_generate());
    } else if alg == EDDSA {
        a.key = must(crypto.ed25519_generate());
    } else {
        let pr = crypto.rsa_generate(2048);
        guard let pem = pr else let e = err_of(pr) { panic(e); }
        a.pem = pem;
    }
    a.cose = cose_for(alg, a);
    return a;
}

fn w16(b: builder.Bytes, v: int) { b.write_byte((v >> 8) & 255); b.write_byte(v & 255); }

fn auth_data(rp_id: str, flags: int, count: int, a: opt[Auth]) -> bytes {
    let b = builder.new_bytes();
    b.write(crypto.sha256(to_bytes(rp_id)));
    b.write_byte(flags);
    w16(b, (count >> 16) & 65535);
    w16(b, count & 65535);
    if let au = a {
        b.write(strings.bytes_zero(16));
        w16(b, len(au.id));
        b.write(au.id);
        b.write(au.cose);
    }
    return b.finish();
}

fn att_obj(fmt: str, ad: bytes) -> bytes {
    let w = cbor.writer();
    cbor.write_map(w, 3);
    cbor.write_text(w, "fmt"); cbor.write_text(w, fmt);
    cbor.write_text(w, "attStmt"); cbor.write_map(w, 0);
    cbor.write_text(w, "authData"); cbor.write_bytes(w, ad);
    return cbor.finish(w);
}

fn client_data(kind: str, challenge: bytes, origin: str, extra: str) -> bytes {
    return to_bytes("{\"type\":\"" + kind + "\",\"challenge\":\"" + encoding.base64url_encode(challenge) +
                    "\",\"origin\":\"" + origin + "\"" + extra + "}");
}

fn reg_json(id: bytes, cd: bytes, ao: bytes) -> str {
    return "{\"id\":\"" + b64(id) + "\",\"rawId\":\"" + b64(id) + "\",\"type\":\"public-key\"," +
           "\"response\":{\"clientDataJSON\":\"" + b64(cd) + "\",\"attestationObject\":\"" + b64(ao) +
           "\",\"transports\":[\"internal\"]},\"clientExtensionResults\":{}}";
}

fn raw_to_der(raw: bytes) -> bytes {
    let parts: [bytes] = [];
    for half in [raw[0..32], raw[32..64]] {
        let v = half;
        while len(v) > 1 && v[0] == 0 && (v[1] as int) < 0x80 { v = v[1..]; }
        if (v[0] as int) >= 0x80 { v = b"\x00" + v; }
        let ib = builder.new_bytes();
        ib.write_byte(2); ib.write_byte(len(v)); ib.write(v);
        push(parts, ib.finish());
    }
    let body = parts[0] + parts[1];
    let out = builder.new_bytes();
    out.write_byte(0x30); out.write_byte(len(body)); out.write(body);
    return out.finish();
}

fn sign(a: Auth, msg: bytes) -> bytes {
    if a.alg == ES256 { return raw_to_der(must(crypto.ecdsa_p256_sign_sha256(a.key, msg))); }
    if a.alg == EDDSA { return must(crypto.ed25519_sign(a.key, msg)); }
    return must(crypto.rsa_sign_sha256(a.pem, msg));
}

fn login_json(id: bytes, cd: bytes, ad: bytes, sig: bytes, handle: bytes) -> str {
    return "{\"id\":\"" + b64(id) + "\",\"rawId\":\"" + b64(id) + "\",\"type\":\"public-key\"," +
           "\"response\":{\"clientDataJSON\":\"" + b64(cd) + "\",\"authenticatorData\":\"" + b64(ad) +
           "\",\"signature\":\"" + b64(sig) + "\",\"userHandle\":\"" + b64(handle) + "\"}}";
}

fn register(a: Auth, challenge: bytes) -> result[Credential, str] {
    let ad = auth_data("example.test", 0x45, a.count, some(a));
    let cd = client_data("webauthn.create", challenge, "https://example.test", "");
    return finish_registration(rp(), challenge, reg_json(a.id, cd, att_obj("none", ad)));
}

fn login(a: Auth, cred: Credential, challenge: bytes, flags: int) -> result[Login, str] {
    a.count = a.count + 1;
    let ad = auth_data("example.test", flags, a.count, none);
    let cd = client_data("webauthn.get", challenge, "https://login.example.test", ",\"crossOrigin\":false");
    let sig = sign(a, ad + crypto.sha256(cd));
    return finish_login(rp(), challenge, cred, login_json(a.id, cd, ad, sig, b"user-7"));
}

fn fails_with[T](r: result[T, str], part: str) -> bool {
    if let _v = r { return false; } else let e = err_of(r) {
        if !strings.contains(e, part) { println("  got: " + e); return false; }
    }
    return true;
}

// ---- options --------------------------------------------------------------

fn test_registration_options() {
    let existing = Credential { id: b"\x01\x02\x03", public_key: b"", alg: ES256, sign_count: 0,
                                aaguid: b"", user_verified: false, backup_eligible: false,
                                backed_up: false, format: "none" };
    let cr = begin_registration(rp(), User { id: b"user-7", name: "ada@example.test",
                                             display_name: "Ada \"A\" Lovelace" }, [existing]);
    guard let ch = cr else let e = err_of(cr) { panic(e); }
    assert(len(ch.value) == 32);
    let pr = jparse(to_bytes(ch.options));
    guard let o = pr else let e = err_of(pr) { panic(e + ": " + ch.options); }
    assert(jstr(o, "challenge") == b64(ch.value));
    assert(jstr(o, "attestation") == "none");
    assert(jnum(o, "timeout") == 300000);
    let rpo = jget(o, "rp") ?? jblank(J_NULL);
    assert(jstr(rpo, "id") == "example.test");
    let user = jget(o, "user") ?? jblank(J_NULL);
    assert(jstr(user, "id") == b64(b"user-7"));
    assert(jstr(user, "displayName") == "Ada \"A\" Lovelace");
    let ex = jget(o, "excludeCredentials") ?? jblank(J_NULL);
    assert(len(ex.items) == 1 && jstr(ex.items[0], "id") == b64(b"\x01\x02\x03"));
    let params = jget(o, "pubKeyCredParams") ?? jblank(J_NULL);
    assert(len(params.items) == 3);
    let again = begin_registration(rp(), User { id: b"user-7", name: "a", display_name: "a" }, []) ?? ch;
    assert(again.value != ch.value);
}

fn test_registration_options_refuse_a_bad_user_id_or_setting() {
    assert(fails_with(begin_registration(rp(), User { id: b"", name: "a", display_name: "a" }, []), "user id"));
    assert(fails_with(begin_registration(rp(), User { id: strings.bytes_zero(65), name: "a", display_name: "a" }, []),
                      "user id"));
    let r = rp();
    r.user_verification = "always";
    assert(fails_with(begin_login(r, []), "user_verification"));
}

fn test_login_options() {
    let cr = begin_login(rp(), []);
    guard let ch = cr else let e = err_of(cr) { panic(e); }
    let o = jparse(to_bytes(ch.options)) ?? jblank(J_NULL);
    assert(jstr(o, "rpId") == "example.test" && jstr(o, "userVerification") == "preferred");
    assert(jstr(o, "challenge") == b64(ch.value));
    assert(len((jget(o, "allowCredentials") ?? jblank(J_NULL)).items) == 0);
}

// ---- registration and login, each algorithm --------------------------------

fn round_trip(alg: int) {
    let a = authenticator(alg);
    let challenge = must(crypto.rand(32));
    let rr = register(a, challenge);
    guard let cred = rr else let e = err_of(rr) { panic(e); }
    assert(cred.alg == alg && cred.id == a.id && cred.format == "none");
    assert(cred.user_verified && !cred.backup_eligible && cred.public_key == a.cose);
    let lc = must(crypto.rand(32));
    let lr = login(a, cred, lc, 0x05);
    guard let l = lr else let e = err_of(lr) { panic(e); }
    assert(l.sign_count == 1 && l.user_verified && l.user_handle == b"user-7");
    cred.sign_count = l.sign_count;
    let l2 = login(a, cred, must(crypto.rand(32)), 0x01) ?? l;
    assert(l2.sign_count == 2 && !l2.user_verified);
}

fn test_es256_round_trip() { round_trip(ES256); }

fn test_eddsa_round_trip() { round_trip(EDDSA); }

fn test_rs256_round_trip() { round_trip(RS256); }

fn test_login_credential_id_names_the_credential() {
    let a = authenticator(ES256);
    let js = login_json(a.id, b"{}", b"", b"", b"");
    assert((login_credential_id(js) ?? b"") == a.id);
    assert(fails_with(login_credential_id("{\"type\":\"public-key\",\"rawId\":\"" + b64(a.id) +
                                          "\",\"id\":\"other\",\"response\":{}}"), "differ"));
    assert(fails_with(login_credential_id("{\"type\":\"password\"}"), "public-key"));
    assert(fails_with(login_credential_id("not json"), "response"));
}

// ---- what registration refuses ---------------------------------------------

fn reg_with(a: Auth, challenge: bytes, ad: bytes, cd: bytes) -> result[Credential, str] {
    return finish_registration(rp(), challenge, reg_json(a.id, cd, att_obj("packed", ad)));
}

fn test_registration_refuses_the_wrong_client_data() {
    let a = authenticator(ES256);
    let ch = must(crypto.rand(32));
    let ad = auth_data("example.test", 0x45, 0, some(a));
    assert(fails_with(reg_with(a, ch, ad, client_data("webauthn.get", ch, "https://example.test", "")),
                      "not webauthn.create"));
    assert(fails_with(reg_with(a, ch, ad, client_data("webauthn.create", must(crypto.rand(32)),
                                                       "https://example.test", "")), "challenge"));
    assert(fails_with(reg_with(a, ch, ad, client_data("webauthn.create", ch, "https://evil.test", "")),
                      "origin"));
    assert(fails_with(reg_with(a, ch, ad, client_data("webauthn.create", ch, "http://example.test", "")),
                      "origin"));
    assert(fails_with(reg_with(a, ch, ad, client_data("webauthn.create", ch, "https://example.test",
                                                       ",\"crossOrigin\":true")), "cross-origin"));
    assert(fails_with(reg_with(a, ch, ad, client_data("webauthn.create", ch, "https://example.test",
                                                       ",\"topOrigin\":\"https://evil.test\"")), "cross-origin"));
    // A NUL cannot cut an origin short.
    assert(fails_with(reg_with(a, ch, ad, to_bytes("{\"type\":\"webauthn.create\",\"challenge\":\"" + b64(ch) +
                                                   "\",\"origin\":\"https://example.test\\u0000.evil\"}")), "NUL"));
    // An empty challenge on our side never matches.
    assert(fails_with(reg_with(a, b"", ad, client_data("webauthn.create", b"", "https://example.test", "")),
                      "challenge"));
}

fn test_registration_refuses_bad_authenticator_data() {
    let a = authenticator(ES256);
    let ch = must(crypto.rand(32));
    let cd = client_data("webauthn.create", ch, "https://example.test", "");
    assert(fails_with(reg_with(a, ch, auth_data("evil.test", 0x45, 0, some(a)), cd), "another RP ID"));
    assert(fails_with(reg_with(a, ch, auth_data("example.test", 0x44, 0, some(a)), cd), "not present"));
    assert(fails_with(reg_with(a, ch, auth_data("example.test", 0x05, 0, none), cd), "without a credential"));
    assert(fails_with(reg_with(a, ch, auth_data("example.test", 0x55, 0, some(a)), cd), "backup-eligible"));
    assert(fails_with(reg_with(a, ch, auth_data("example.test", 0x45, 0, some(a)) + b"\x00", cd), "bytes after"));
    let whole = auth_data("example.test", 0x45, 0, some(a));
    assert(fails_with(reg_with(a, ch, whole[0..len(whole) - 5], cd), "public key"));
    assert(fails_with(reg_with(a, ch, whole[0..60], cd), "credential id"));
    let strict = rp();
    strict.user_verification = "required";
    let no_uv = auth_data("example.test", 0x41, 0, some(a));
    assert(fails_with(finish_registration(strict, ch, reg_json(a.id, cd, att_obj("none", no_uv))), "not verified"));
}

fn test_registration_refuses_a_mismatched_credential_id() {
    let a = authenticator(ES256);
    let ch = must(crypto.rand(32));
    let ad = auth_data("example.test", 0x45, 0, some(a));
    let cd = client_data("webauthn.create", ch, "https://example.test", "");
    let other = must(crypto.rand(16));
    assert(fails_with(finish_registration(rp(), ch, reg_json(other, cd, att_obj("none", ad))), "credential id"));
}

fn test_registration_refuses_keys_it_cannot_use() {
    let a = authenticator(ES256);
    let ch = must(crypto.rand(32));
    let cd = client_data("webauthn.create", ch, "https://example.test", "");
    // ES384 (-35): not offered, not accepted.
    let w = cbor.writer();
    cbor.write_map(w, 3);
    cbor.write_int(w, 1); cbor.write_int(w, 2);
    cbor.write_int(w, 3); cbor.write_int(w, -35);
    cbor.write_int(w, -1); cbor.write_int(w, 2);
    a.cose = cbor.finish(w);
    assert(fails_with(reg_with(a, ch, auth_data("example.test", 0x45, 0, some(a)), cd), "not supported"));
    // ES256 with a short x coordinate.
    let w2 = cbor.writer();
    cbor.write_map(w2, 5);
    cbor.write_int(w2, 1); cbor.write_int(w2, 2);
    cbor.write_int(w2, 3); cbor.write_int(w2, -7);
    cbor.write_int(w2, -1); cbor.write_int(w2, 1);
    cbor.write_int(w2, -2); cbor.write_bytes(w2, strings.bytes_zero(31));
    cbor.write_int(w2, -3); cbor.write_bytes(w2, strings.bytes_zero(32));
    a.cose = cbor.finish(w2);
    assert(fails_with(reg_with(a, ch, auth_data("example.test", 0x45, 0, some(a)), cd), "P-256"));
}

fn test_registration_skips_extensions_and_unknown_cose_members() {
    let a = authenticator(EDDSA);
    // The key with an extra member (a text label), then an extensions
    // map after it (flag ED).
    let pubk = must(crypto.ed25519_public_key(a.key));
    let w = cbor.writer();
    cbor.write_map(w, 5);
    cbor.write_int(w, 1); cbor.write_int(w, 1);
    cbor.write_int(w, 3); cbor.write_int(w, -8);
    cbor.write_int(w, -1); cbor.write_int(w, 6);
    cbor.write_int(w, -2); cbor.write_bytes(w, pubk);
    cbor.write_int(w, 7); cbor.write_array(w, 2); cbor.write_text(w, "x"); cbor.write_bool(w, true);
    a.cose = cbor.finish(w);
    let ext = cbor.writer();
    cbor.write_map(ext, 1);
    cbor.write_text(ext, "credProtect"); cbor.write_int(ext, 2);
    let ad = auth_data("example.test", 0xC5, 0, some(a)) + cbor.finish(ext);
    let ch = must(crypto.rand(32));
    let cd = client_data("webauthn.create", ch, "https://example.test", "");
    let rr = reg_with(a, ch, ad, cd);
    guard let cred = rr else let e = err_of(rr) { panic(e); }
    assert(cred.alg == EDDSA && cred.format == "packed");
    let l = login(a, cred, must(crypto.rand(32)), 0x05) ?? Login { credential_id: b"", user_handle: b"",
                                                                    sign_count: 0, user_verified: false, backed_up: false };
    assert(l.sign_count == 1);
}

// ---- what login refuses ------------------------------------------------------

fn registered(alg: int) -> Credential {
    let a = authenticator(alg);
    let rr = register(a, must(crypto.rand(32)));
    guard let cred = rr else let e = err_of(rr) { panic(e); }
    return cred;
}

fn test_login_refuses_a_bad_signature() {
    let a = authenticator(ES256);
    let cred = register(a, must(crypto.rand(32))) ?? registered(ES256);
    let ch = must(crypto.rand(32));
    let ad = auth_data("example.test", 0x05, 1, none);
    let cd = client_data("webauthn.get", ch, "https://example.test", "");
    let sig = sign(a, ad + crypto.sha256(cd));
    // Signed over other client data.
    let cd2 = client_data("webauthn.get", ch, "https://login.example.test", "");
    assert(fails_with(finish_login(rp(), ch, cred, login_json(a.id, cd2, ad, sig, b"")), "does not verify"));
    // Another authenticator's key.
    let b = authenticator(ES256);
    let forged = sign(b, ad + crypto.sha256(cd));
    assert(fails_with(finish_login(rp(), ch, cred, login_json(a.id, cd, ad, forged, b"")), "does not verify"));
    // A signature that is not DER.
    assert(fails_with(finish_login(rp(), ch, cred, login_json(a.id, cd, ad, sig[0..20], b"")), "DER"));
    assert(fails_with(finish_login(rp(), ch, cred, login_json(a.id, cd, ad, sig + b"\x00", b"")), "DER"));
    // The right one still works.
    let good = finish_login(rp(), ch, cred, login_json(a.id, cd, ad, sig, b""));
    guard let l = good else let e = err_of(good) { panic(e); }
    assert(len(l.user_handle) == 0);
}

fn test_login_refuses_a_counter_that_did_not_go_up() {
    let a = authenticator(ES256);
    let cred = register(a, must(crypto.rand(32))) ?? registered(ES256);
    cred.sign_count = 5;
    a.count = 4;
    assert(fails_with(login(a, cred, must(crypto.rand(32)), 0x05), "cloned"));
    // Zero on both sides: an authenticator without a counter.
    let z = authenticator(ES256);
    let zc = register(z, must(crypto.rand(32))) ?? registered(ES256);
    let ch = must(crypto.rand(32));
    let ad = auth_data("example.test", 0x05, 0, none);
    let cd = client_data("webauthn.get", ch, "https://example.test", "");
    let lr = finish_login(rp(), ch, zc, login_json(z.id, cd, ad, sign(z, ad + crypto.sha256(cd)), b""));
    guard let l = lr else let e = err_of(lr) { panic(e); }
    assert(l.sign_count == 0);
}

fn test_login_refuses_another_credential_or_wrong_type() {
    let a = authenticator(ES256);
    let cred = register(a, must(crypto.rand(32))) ?? registered(ES256);
    let ch = must(crypto.rand(32));
    let ad = auth_data("example.test", 0x05, 1, none);
    let cd = client_data("webauthn.get", ch, "https://example.test", "");
    let sig = sign(a, ad + crypto.sha256(cd));
    assert(fails_with(finish_login(rp(), ch, cred, login_json(must(crypto.rand(16)), cd, ad, sig, b"")),
                      "another credential"));
    let cdc = client_data("webauthn.create", ch, "https://example.test", "");
    assert(fails_with(finish_login(rp(), ch, cred, login_json(a.id, cdc, ad, sign(a, ad + crypto.sha256(cdc)), b"")),
                      "not webauthn.get"));
    let strict = rp();
    strict.user_verification = "required";
    assert(fails_with(finish_login(strict, ch, cred, login_json(a.id, cd, auth_data("example.test", 0x01, 1, none),
                                                                sig, b"")), "not verified"));
}

fn test_der_signatures_are_strict() {
    // r with an unneeded leading zero, and a negative s.
    let bad1 = b"\x30\x08\x02\x02\x00\x01\x02\x02\x00\x01";
    if let _r = der_to_raw(bad1) { assert(false, "accepted a padded integer"); }
    let bad2 = b"\x30\x06\x02\x01\x01\x02\x01\x80";
    if let _r = der_to_raw(bad2) { assert(false, "accepted a negative integer"); }
    let good = b"\x30\x07\x02\x01\x01\x02\x02\x00\x80";
    let rr = der_to_raw(good);
    guard let raw = rr else let e = err_of(rr) { panic(e); }
    assert(len(raw) == 64 && raw[31] == 1 && raw[63] == 0x80 && raw[62] == 0);
}
