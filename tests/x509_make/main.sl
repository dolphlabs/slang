// x509.csr and x509.self_signed from P-256, Ed25519 and RSA keys, read
// back with parse_pem and verified against themselves; the raw-key to
// PEM conversions they need; and the ways a request is refused.

import "crypto";
import "strings";
import "x509";

fn must(r: result[str, str]) -> str {
    guard let v = r else let e = err_of(r) { panic(e); }
    return v;
}

fn names() -> x509.Request {
    return x509.Request { common_name: "svc.internal",
                          dns_names: ["svc.internal", "*.svc.internal"],
                          ip_addrs: ["10.0.0.7", "fd00::7"] };
}

fn exercise(label: str, key: str) {
    let csr = must(x509.csr(key, names()));
    println(label + " csr " + to_str(strings.has_prefix(csr, "-----BEGIN CERTIFICATE REQUEST-----\n")));
    let pem = must(x509.self_signed(key, names(), 30));
    let r = x509.parse_pem(pem);
    guard let cs = r else let e = err_of(r) { panic(e); }
    let c = cs[0];
    println(label + " " + c.subject + " " + c.key_type + " ca=" + to_str(c.is_ca) +
            " days=" + to_str((c.not_after - c.not_before) / 86400) +
            " serial=" + to_str(len(c.serial)) + " self=" + to_str(c.subject == c.issuer));
    println(label + " dns=" + strings.join(c.dns_names, ",") + " ip=" + strings.join(c.ip_addrs, ",") +
            " ku=" + strings.join(c.key_usage, ",") + " eku=" + strings.join(c.ext_key_usage, ","));
    let v = x509.verify(cs, x509.Verify { roots_pem: pem, host: "a.svc.internal", at: 0, purpose: "server" });
    println(label + " verify " + to_str(v ?? false));
    let vc = x509.verify(cs, x509.Verify { roots_pem: pem, host: "fd00::7", at: 0, purpose: "client" });
    println(label + " verify client ip " + to_str(vc ?? false));
    let other = must(x509.self_signed(key, names(), 30));
    println(label + " fresh serial " + to_str(other != pem));
}

fn run() {
    let p256 = crypto.ecdsa_p256_generate() ?? b"";
    let ppem = must(crypto.ecdsa_p256_private_to_pem(p256));
    println("p256 pem " + to_str(strings.has_prefix(ppem, "-----BEGIN PRIVATE KEY-----\n")) +
            " round trip " + to_str((crypto.ecdsa_p256_private_from_pem(ppem) ?? b"") == p256));
    exercise("p256", ppem);

    let seed = crypto.ed25519_generate() ?? b"";
    let epem = must(crypto.ed25519_private_to_pem(seed));
    println("ed25519 round trip " + to_str((crypto.ed25519_private_from_pem(epem) ?? b"") == seed));
    exercise("ed25519", epem);

    exercise("rsa", must(crypto.rsa_generate(2048)));

    println("== refused");
    println(err_of(crypto.ecdsa_p256_private_to_pem(b"short")));
    println(err_of(crypto.ed25519_private_to_pem(b"")));
    let zero = b"";
    for _ in 0..32 { zero = zero + b"\x00"; }
    println(err_of(crypto.ecdsa_p256_private_to_pem(zero)));
    println(err_of(x509.csr("not a key", names())));
    println(err_of(x509.self_signed(ppem, names(), 0)));
    println(err_of(x509.self_signed(ppem, names(), 36501)));
    let empty = x509.Request { common_name: "", dns_names: [], ip_addrs: [] };
    println(err_of(x509.csr(ppem, empty)));
    println(err_of(x509.self_signed(ppem, empty, 1)));
    let bad_ip = x509.Request { common_name: "x", dns_names: [], ip_addrs: ["10.0.0.300"] };
    println(err_of(x509.csr(ppem, bad_ip)));
    let bad_dns = x509.Request { common_name: "x", dns_names: [""], ip_addrs: [] };
    println(err_of(x509.self_signed(ppem, bad_dns, 1)));
    let cn_only = x509.Request { common_name: "just-a-cn", dns_names: [], ip_addrs: [] };
    println("cn only " + to_str(strings.has_prefix(must(x509.csr(ppem, cn_only)), "-----BEGIN")));
}

run();
