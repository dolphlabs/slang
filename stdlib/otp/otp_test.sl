// RFC 4226 Appendix D and RFC 6238 Appendix B.

fn opts(digits: int, alg: str) -> Options {
    let o = totp_options();
    o.digits = digits;
    o.algorithm = alg;
    return o;
}

fn test_should_match_rfc_4226_hotp_vectors() {
    let secret = to_bytes("12345678901234567890");
    let want = ["755224", "287082", "359152", "969429", "338314", "254676", "287922",
                "162583", "399871", "520489"];
    for i in 0..10 {
        let got = hotp(secret, i, opts(6, "SHA1"));
        assert(got == want[i], "counter " + to_str(i) + ": " + got);
    }
}

fn test_should_match_rfc_6238_totp_vectors() {
    let s1 = to_bytes("12345678901234567890");
    let s256 = to_bytes("12345678901234567890123456789012");
    let s512 = to_bytes("1234567890123456789012345678901234567890123456789012345678901234");
    let times = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000];
    let sha1 = ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"];
    let sha256 = ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"];
    let sha512 = ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"];
    for i in 0..len(times) {
        assert(totp(s1, times[i], opts(8, "SHA1")) == sha1[i], "SHA1 at " + to_str(times[i]));
        assert(totp(s256, times[i], opts(8, "SHA256")) == sha256[i], "SHA256 at " + to_str(times[i]));
        assert(totp(s512, times[i], opts(8, "SHA512")) == sha512[i], "SHA512 at " + to_str(times[i]));
    }
}

fn test_should_accept_codes_within_the_skew_and_return_their_step() {
    let secret = to_bytes("12345678901234567890");
    let o = totp_options();
    let now = 1700000000;
    let code = totp(secret, now - 30, o);          // the previous step's code
    let got = verify_totp(secret, code, now, o);
    guard let s = got else { panic("previous step refused within skew 1"); }
    assert(s == step_of(now, o) - 1, "matched step");
    let old = totp(secret, now - 90, o);
    if let _x = verify_totp(secret, old, now, o) { panic("code three steps old accepted"); }
    if let _y = verify_totp(secret, "12345", now, o) { panic("short code accepted"); }
    if let _z = verify_totp(secret, " " + totp(secret, now, o) + " ", now, o) { } else { panic("spaces around the code"); }
}

fn test_should_resynchronise_hotp_within_a_window() {
    let secret = to_bytes("12345678901234567890");
    let o = opts(6, "SHA1");
    assert((verify_hotp(secret, "969429", 0, 5, o) ?? -1) == 3, "found counter 3");
    if let _x = verify_hotp(secret, "520489", 0, 5, o) { panic("counter 9 is outside a window of 5"); }
}

fn test_should_build_and_parse_secrets_and_uris() {
    let secret = to_bytes("12345678901234567890");
    let u = uri(secret, "Acme Co", "ada@example.com", totp_options());
    assert(u == "otpauth://totp/Acme%20Co:ada%40example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Acme%20Co&algorithm=SHA1&digits=6&period=30", u);
    let back = parse_secret("gezd gnbv gy3t qojq gezd gnbv gy3t qojq");
    assert((back ?? b"") == secret, "parse_secret");
    let fresh = new_secret() ?? b"";
    assert(len(fresh) == 20, "secret size");
}
