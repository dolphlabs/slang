// Vectors from AWS's Signature Version 4 test suite and documentation
// (credentials AKIDEXAMPLE / wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY).

import "encoding";
import "strings";

fn suite_signer() -> Signer {
    return new_signer("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "us-east-1", "service");
}

fn empty_hash() -> str { return payload_hash(b""); }

// "Examples of how to derive a signing key": iam, us-east-1, 20150830.
fn test_should_derive_the_documented_signing_key() {
    let k = derive_key("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam");
    assert(encoding.hex_encode(k) == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9",
           encoding.hex_encode(k));
}

// Test suite: get-vanilla.
fn test_should_sign_get_vanilla() {
    let h: map[str]str = {};
    let auth = sign(suite_signer(), "GET", "example.amazonaws.com", "/", {}, h, empty_hash(),
                    "20150830T123600Z");
    assert(auth == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
           "SignedHeaders=host;x-amz-date, " +
           "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", auth);
}

// Test suite: get-vanilla-query-order-key-case (Param2=value2&Param1=value1).
fn test_should_sort_query_parameters() {
    let q: map[str]str = {};
    q["Param2"] = "value2";
    q["Param1"] = "value1";
    let h: map[str]str = {};
    let auth = sign(suite_signer(), "GET", "example.amazonaws.com", "/", q, h, empty_hash(),
                    "20150830T123600Z");
    assert(strings.has_suffix(auth, "Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"), auth);
}

// Test suite: post-x-www-form-urlencoded (a body, its content type signed).
fn test_should_sign_a_form_post() {
    let h: map[str]str = {};
    h["Content-Type"] = "application/x-www-form-urlencoded";
    let auth = sign(suite_signer(), "POST", "example.amazonaws.com", "/", {}, h,
                    payload_hash(b"Param1=value1"), "20150830T123600Z");
    assert(auth == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
           "SignedHeaders=content-type;host;x-amz-date, " +
           "Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a", auth);
}

fn test_should_sign_the_session_token() {
    let s = suite_signer();
    s.session_token = "TOKEN";
    let h: map[str]str = {};
    let auth = sign(s, "GET", "example.amazonaws.com", "/", {}, h, empty_hash(), "20150830T123600Z");
    assert(strings.contains(auth, "SignedHeaders=host;x-amz-date;x-amz-security-token,"), auth);
    assert(!strings.has_suffix(auth, "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"));
}

fn test_should_cache_the_key_per_day() {
    let s = suite_signer();
    let k1 = signing_key(s, "20150830");
    let held = s.cached;
    assert(signing_key(s, "20150830") == k1 && s.cached.date == "20150830");
    let k2 = signing_key(s, "20150831");
    assert(k2 != k1 && s.cached.date == "20150831");
    // The old pair is replaced, never edited: a reader holding it stays consistent.
    assert(held.date == "20150830" && held.key == k1);
}

fn test_should_presign_with_extra_parameters_kept() {
    let q: map[str]str = {};
    q["Action"] = "ListUsers";
    let qs = presign(suite_signer(), "GET", "example.amazonaws.com", "/", q, 60, "20150830T123600Z");
    assert(strings.has_prefix(qs, "Action=ListUsers&X-Amz-Algorithm=AWS4-HMAC-SHA256&" +
           "X-Amz-Credential=AKIDEXAMPLE%2F20150830%2Fus-east-1%2Fservice%2Faws4_request&" +
           "X-Amz-Date=20150830T123600Z&X-Amz-Expires=60&X-Amz-SignedHeaders=host&X-Amz-Signature="), qs);
    assert(len(qs) - strings.find(qs, "X-Amz-Signature=") == 16 + 64);
}

fn test_should_encode_as_sigv4_wants() {
    assert(uri_encode("a b+c/d~e_f.g-h", false) == "a%20b%2Bc%2Fd~e_f.g-h");
    assert(uri_encode("dir one/x", true) == "dir%20one/x");
    assert(uri_encode("café", true) == "caf%C3%A9");
    let q: map[str]str = {};
    q["b"] = "x y";
    q["a"] = "";
    assert(canonical_query(q) == "a=&b=x%20y", canonical_query(q));
}

fn test_amz_date_shape() {
    let d = amz_date_now();
    assert(len(d) == 16 && strings.slice(d, 8, 9) == "T" && strings.has_suffix(d, "Z"), d);
}
