// X.509 certificates: read them, check them, and make requests for them.
//
//     import "x509";
//
//     let r = x509.parse_pem(pem);              // result[[Cert], str]: every CERTIFICATE block
//     guard let certs = r else let e = err_of(r) { panic(e); }
//     let c = certs[0];
//     c.not_after                               // unix seconds: when it expires
//     c.dns_names                               // ["api.example.com", "*.example.com"]
//     x509.matches_host(c, "www.example.com")   // true: SANs only, never the CN
//     x509.verify(certs, x509.Verify { roots_pem: "", host: "api.example.com",
//                                     at: 0, purpose: "server" })   // ok(true), or why not
//
//     let k = crypto.ecdsa_p256_private_to_pem(crypto.ecdsa_p256_generate() ?? b"") ?? "";
//     let names = x509.Request { common_name: "api.example.com",
//                                dns_names: ["api.example.com"], ip_addrs: [] };
//     x509.csr(k, names)                        // result[str, str]: a PKCS#10 request, PEM
//     x509.self_signed(k, names, 90)            // result[str, str]: a certificate, PEM
//
// A server checking client certificates (mTLS) reads the client's chain
// from the connection and parses it: `x509.parse_der(c.peer_certs())` on a
// link after c.tls_accept, or `x509.parse_der(net.tls_peer_certs(ssl))` for
// a handle from net.tls_accept. With net.tls_ctx_require_client the
// handshake has already verified it, so the fields are the client's
// identity. (This package does not import net, so a program that only
// reads certificates does not link TLS.)
//
// OpenSSL does all the ASN.1 (crypto.x509_*); nothing here parses DER by
// hand. Names follow RFC 4514, times are unix seconds, and errors start
// with "x509: ".

import "crypto";
import "strings";
import "time";

// One certificate, as parsed. `der` is exactly the bytes it came from, so
// a chain can be passed back to verify or stored without re-encoding.
pub gc struct Cert {
    der: bytes,
    subject: str,          // RFC 4514: "CN=api.example.com,O=Example"
    common_name: str,      // the subject's CN, "" if it has none
    issuer: str,
    serial: str,           // lowercase hex
    not_before: int,       // unix seconds
    not_after: int,
    dns_names: [str],      // subjectAltName entries, by type
    ip_addrs: [str],
    emails: [str],
    uris: [str],
    is_ca: bool,
    max_path_len: int,     // -1 when the certificate sets none
    key_usage: [str],      // "digital_signature", "key_encipherment", "cert_sign", ...
    ext_key_usage: [str],  // "server_auth", "client_auth", ...; others as dotted OIDs
    key_type: str,         // "rsa", "ec-p256", "ec-p384", "ed25519", ...
    key_bits: int,
    public_key_pem: str,   // SPKI PEM, as crypto's *_from_pem and verify functions take
    signature_alg: str,    // "sha256WithRSAEncryption", "ecdsa-with-SHA256", ...
    fingerprint: str,      // SHA-256 of der, lowercase hex
}

// What verify checks besides the signatures and the chain to a root.
pub struct Verify {
    roots_pem: str,        // trusted roots as PEM; "" for the system's
    host: str,             // a hostname or IP the leaf must name; "" for no check
    at: int,               // unix seconds to check validity at; 0 for now
    purpose: str,          // "server", "client", or "" for no check
}

// The names a CSR or self-signed certificate is for.
pub struct Request {
    common_name: str,
    dns_names: [str],
    ip_addrs: [str],
}

// The fourteen fixed fields crypto.x509_fields returns before its tagged
// entries.
let FIXED = 14;

// Every CERTIFICATE block of a PEM text, in order. Other blocks and text
// between them are skipped; a block that does not decode is an error.
pub fn parse_pem(pem: str) -> result[[Cert], str] {
    let r = crypto.x509_der(pem);
    guard let der = r else let e = err_of(r) {
        return err(e);
    }
    return parse_der(der);
}

// One DER certificate, or several concatenated (as a TLS chain and
// net.tls_peer_certs give them).
pub fn parse_der(der: bytes) -> result[[Cert], str] {
    let out: [Cert] = [];
    let off = 0;
    while off < len(der) {
        let rest = der;
        if off > 0 {
            rest = der[off..];
        }
        let r = crypto.x509_fields(rest);
        guard let f = r else let e = err_of(r) {
            return err(e);
        }
        let n = to_int(f[0]) ?? 0;
        if n <= 0 || n > len(rest) {
            return err("x509: bad certificate length");
        }
        push(out, cert_of(rest[0..n], f));
        off = off + n;
    }
    if len(out) == 0 {
        return err("x509: no certificate in the DER");
    }
    return ok(out);
}

fn cert_of(der: bytes, f: [str]) -> Cert {
    let c = Cert {
        der: der,
        subject: f[1],
        common_name: f[2],
        issuer: f[3],
        serial: f[4],
        not_before: to_int(f[5]) ?? 0,
        not_after: to_int(f[6]) ?? 0,
        dns_names: [],
        ip_addrs: [],
        emails: [],
        uris: [],
        is_ca: f[7] == "1",
        max_path_len: to_int(f[8]) ?? -1,
        key_usage: [],
        ext_key_usage: [],
        key_type: f[9],
        key_bits: to_int(f[10]) ?? 0,
        public_key_pem: f[11],
        signature_alg: f[12],
        fingerprint: f[13]
    };
    let i = FIXED;
    while i < len(f) {
        let t = f[i];
        if strings.has_prefix(t, "dns:") {
            push(c.dns_names, strings.slice(t, 4, len(t)));
        } else if strings.has_prefix(t, "ip:") {
            push(c.ip_addrs, strings.slice(t, 3, len(t)));
        } else if strings.has_prefix(t, "email:") {
            push(c.emails, strings.slice(t, 6, len(t)));
        } else if strings.has_prefix(t, "uri:") {
            push(c.uris, strings.slice(t, 4, len(t)));
        } else if strings.has_prefix(t, "ku:") {
            push(c.key_usage, strings.slice(t, 3, len(t)));
        } else if strings.has_prefix(t, "eku:") {
            push(c.ext_key_usage, strings.slice(t, 4, len(t)));
        }
        i = i + 1;
    }
    return c;
}

// Does the certificate name `host`? RFC 6125: subjectAltName entries only,
// never the subject CN; a wildcard only as the whole left-most label, for
// exactly one label ("*.example.com" matches "a.example.com", not
// "example.com" or "a.b.example.com"). An IP literal matches IP entries.
pub fn matches_host(c: Cert, host: str) -> bool {
    return crypto.x509_check_host(c.der, host);
}

// Is `unix` (seconds) inside the certificate's validity period?
pub fn valid_at(c: Cert, unix: int) -> bool {
    return unix >= c.not_before && unix <= c.not_after;
}

// Seconds until the certificate expires; negative once it has.
pub fn expires_in(c: Cert) -> int {
    return c.not_after - time.wall() / 1000000000;
}

// Checks `chain` (the leaf first, then any intermediates) up to one of
// the roots: every signature, validity at `v.at`, and the host and
// purpose when set. ok(true), or why not, in words that do not change
// with the OpenSSL version: "x509: certificate has expired", "x509:
// certificate is not yet valid", "x509: hostname mismatch", "x509: IP
// address mismatch", "x509: certificate is not for this purpose", "x509:
// certificate signed by unknown authority", "x509: self-signed
// certificate not in the roots", "x509: certificate signature does not
// verify", "x509: issuer is not a CA", "x509: path length constraint
// exceeded"; rarer failures carry OpenSSL's own reason.
pub fn verify(chain: [Cert], v: Verify) -> result[bool, str] {
    if len(chain) == 0 {
        return err("x509: no certificate to verify");
    }
    let ders: [bytes] = [];
    for c in chain {
        push(ders, c.der);
    }
    return crypto.x509_verify(strings.join_bytes(ders, b""), v.roots_pem, v.host,
                              v.at, v.purpose);
}

fn sans_of(r: Request) -> [str] {
    let out: [str] = [];
    for d in r.dns_names {
        push(out, "DNS:" + d);
    }
    for ip in r.ip_addrs {
        push(out, "IP:" + ip);
    }
    return out;
}

// A certificate signing request (PKCS#10, PEM) for `r`'s names, signed
// with `key_pem` (an RSA, EC or Ed25519 private key in PEM). It is what an
// ACME server, or any CA, is sent: it carries the names and the public
// key, and proves the sender holds the private key.
pub fn csr(key_pem: str, r: Request) -> result[str, str] {
    return crypto.x509_csr(key_pem, r.common_name, sans_of(r));
}

// A certificate for `r`'s names, signed by its own key and valid from now
// for `days` (1 to 36500): for development TLS and tests. It is a leaf
// (not a CA) for server and client auth; to verify it, pass its own PEM as
// `roots_pem`.
pub fn self_signed(key_pem: str, r: Request, days: int) -> result[str, str] {
    return crypto.x509_self_signed(key_pem, r.common_name, sans_of(r), days);
}
