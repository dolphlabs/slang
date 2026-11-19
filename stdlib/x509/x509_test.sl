import "crypto";
import "strings";

fn fields(tagged: [str]) -> [str] {
    let f = ["412", "CN=a,O=b", "a", "CN=root", "0f", "100", "200", "1", "2",
             "ec-p256", "256", "-----BEGIN PUBLIC KEY-----\n", "ecdsa-with-SHA256", "ab"];
    for t in tagged {
        push(f, t);
    }
    return f;
}

fn key() -> str {
    let r = crypto.ecdsa_p256_private_to_pem(crypto.ecdsa_p256_generate() ?? b"");
    guard let k = r else let e = err_of(r) { panic(e); }
    return k;
}

// ---- cert_of ----------------------------------------------------------

fn test_should_read_fixed_fields_in_order() {
    let c = cert_of(b"x", fields([]));
    assert(c.subject == "CN=a,O=b" && c.common_name == "a" && c.issuer == "CN=root", c.subject);
    assert(c.serial == "0f", c.serial);
    assert(c.not_before == 100 && c.not_after == 200, "validity");
    assert(c.is_ca, "is_ca");
    assert(c.max_path_len == 2, "path len");
    assert(c.key_type == "ec-p256" && c.key_bits == 256, c.key_type);
    assert(c.signature_alg == "ecdsa-with-SHA256" && c.fingerprint == "ab", c.fingerprint);
    assert(len(c.dns_names) == 0 && len(c.key_usage) == 0, "no tagged entries");
}

fn test_should_sort_tagged_entries_by_kind_keeping_order() {
    let c = cert_of(b"x", fields(["dns:a.test", "ip:::1", "dns:*.a.test", "email:x@a.test",
                                  "uri:spiffe://a/b", "ku:cert_sign", "eku:1.2.3.4",
                                  "ip:10.0.0.1", "eku:server_auth"]));
    assert(strings.join(c.dns_names, " ") == "a.test *.a.test", strings.join(c.dns_names, " "));
    assert(strings.join(c.ip_addrs, " ") == "::1 10.0.0.1", strings.join(c.ip_addrs, " "));
    assert(c.emails[0] == "x@a.test" && c.uris[0] == "spiffe://a/b", "email, uri");
    assert(c.key_usage[0] == "cert_sign", "ku");
    assert(strings.join(c.ext_key_usage, " ") == "1.2.3.4 server_auth", "eku");
}

fn test_should_keep_a_colon_inside_a_value() {
    let c = cert_of(b"x", fields(["uri:https://a.test:8443/x"]));
    assert(c.uris[0] == "https://a.test:8443/x", c.uris[0]);
}

fn test_should_ignore_unknown_tags() {
    let c = cert_of(b"x", fields(["rid:1.2", "dns:a.test"]));
    assert(len(c.dns_names) == 1, "unknown tag dropped");
}

// ---- valid_at, sans_of ------------------------------------------------

fn test_should_include_both_ends_of_validity() {
    let c = cert_of(b"x", fields([]));
    assert(valid_at(c, 100) && valid_at(c, 200), "ends");
    assert(!valid_at(c, 99) && !valid_at(c, 201), "outside");
}

fn test_should_prefix_names_for_the_natives() {
    let s = sans_of(Request { common_name: "", dns_names: ["a.test"], ip_addrs: ["::1", "10.0.0.1"] });
    assert(strings.join(s, ",") == "DNS:a.test,IP:::1,IP:10.0.0.1", strings.join(s, ","));
}

// ---- parse, verify ----------------------------------------------------

fn test_should_return_an_error_for_an_empty_chain() {
    let r = verify([], Verify { roots_pem: "", host: "", at: 0, purpose: "" });
    assert(err_of(r) == "x509: no certificate to verify", err_of(r));
}

fn test_should_round_trip_a_self_signed_certificate_through_der() {
    let r = self_signed(key(), Request { common_name: "t", dns_names: ["t.test"], ip_addrs: [] }, 2);
    guard let pem = r else let e = err_of(r) { panic(e); }
    let pr = parse_pem(pem);
    guard let a = pr else let e = err_of(pr) { panic(e); }
    let dr = parse_der(a[0].der + a[0].der);
    guard let b = dr else let e = err_of(dr) { panic(e); }
    assert(len(b) == 2, "two from concatenated DER");
    assert(b[1].fingerprint == a[0].fingerprint && b[1].der == a[0].der, "same certificate");
    assert(expires_in(a[0]) > 86400 && expires_in(a[0]) <= 2 * 86400, "two days left");
    assert(matches_host(a[0], "t.test") && !matches_host(a[0], "t"), "SAN, never CN");
}

fn test_should_refuse_trailing_garbage_after_a_certificate() {
    let r = self_signed(key(), Request { common_name: "t", dns_names: [], ip_addrs: [] }, 1);
    guard let pem = r else let e = err_of(r) { panic(e); }
    let pr = parse_pem(pem);
    guard let a = pr else let e = err_of(pr) { panic(e); }
    let bad = parse_der(a[0].der + b"\x30");
    assert(strings.has_prefix(err_of(bad), "x509: "), err_of(bad));
}
