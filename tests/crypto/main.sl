import "crypto";
import "encoding";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect_byte(h: bytes, i: int, want: int) {
    if h[i] != want {
        die("byte mismatch");
    }
}

let h = crypto.sha256(b"abc");
if len(h) != 32 {
    die("sha256 length");
}
expect_byte(h, 0, 186);
expect_byte(h, 1, 120);
expect_byte(h, 2, 22);
expect_byte(h, 31, 173);
println("sha256 ok");

let m = crypto.hmac_sha256(b"key", b"The quick brown fox jumps over the lazy dog");
if len(m) != 32 {
    die("hmac length");
}
expect_byte(m, 0, 247);
expect_byte(m, 1, 188);
expect_byte(m, 2, 131);
println("hmac ok");

let r = crypto.rand(32);
guard let b = r else {
    die("rand");
}
if len(b) != 32 {
    die("rand length");
}
// Two draws differ, and a large one is filled to its end, not just its
// first chunk (getrandom may return short).
let r2 = crypto.rand(32);
guard let b2 = r2 else {
    die("rand again");
}
if b == b2 {
    die("rand repeated itself");
}
let big = crypto.rand(1024 * 1024);
guard let bb = big else {
    die("rand 1MB");
}
if len(bb) != 1024 * 1024 {
    die("rand 1MB length");
}
let tail_zero = 0;
let k = len(bb) - 4096;
while k < len(bb) {
    if bb[k] == 0 {
        tail_zero = tail_zero + 1;
    }
    k = k + 1;
}
// 4096 random bytes hold ~16 zeros; all of them zero means unfilled.
if tail_zero > 200 {
    die("rand 1MB tail looks unfilled");
}
let empty = crypto.rand(0);
guard let nb = empty else {
    die("rand 0");
}
if len(nb) != 0 {
    die("rand 0 length");
}
println("rand ok");

// RFC 1321 appendix A.5
// SHA-1: the two standard vectors, plus RFC 6455's own WebSocket
// handshake example, which is the reason this hash is here at all.
if len(crypto.sha1(b"abc")) != 20 {
    die("sha1 length");
}
if encoding.hex_encode(crypto.sha1(b"")) != "da39a3ee5e6b4b0d3255bfef95601890afd80709" {
    die("sha1 empty");
}
if encoding.hex_encode(crypto.sha1(b"abc")) != "a9993e364706816aba3e25717850c26c9cd0d89d" {
    die("sha1 abc");
}
let ws_key = "dGhlIHNhbXBsZSBub25jZQ==";
let ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
if encoding.base64_encode(crypto.sha1(to_bytes(ws_key + ws_guid))) !=
   "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
    die("sha1 websocket accept");
}
println("sha1 ok");

if encoding.hex_encode(crypto.md5(b"")) != "d41d8cd98f00b204e9800998ecf8427e" {
    die("md5 empty");
}
if encoding.hex_encode(crypto.md5(b"abc")) != "900150983cd24fb0d6963f7d28e17f72" {
    die("md5 abc");
}
println("md5 ok");

// PBKDF2-HMAC-SHA256 vectors (RFC 7914 section 11 and the widely
// published c=1 / c=4096 set for P="password", S="salt")
fn pbkdf2_hex(p: bytes, s: bytes, c: int, n: int) -> str {
    let r = crypto.pbkdf2_sha256(p, s, c, n);
    guard let k = r else let e = err_of(r) {
        die("pbkdf2: " + e);
        return "";
    }
    return encoding.hex_encode(k);
}
if pbkdf2_hex(b"password", b"salt", 1, 32) !=
   "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b" {
    die("pbkdf2 c=1");
}
if pbkdf2_hex(b"password", b"salt", 4096, 32) !=
   "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a" {
    die("pbkdf2 c=4096");
}
if pbkdf2_hex(b"passwd", b"salt", 1, 64) !=
   "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783" {
    die("pbkdf2 rfc7914");
}
let many = crypto.pbkdf2_sha256(b"p", b"s", 10000001, 32);
if let unused = many { } else let e = err_of(many) {
    if e != "invalid iterations: must be between 1 and 10000000" {
        die("pbkdf2 cap msg: " + e);
    }
    println("pbkdf2 ok");
}

let bad = crypto.rand(-1);
if let x = bad { } else let e = err_of(bad) {
    if e != "invalid size: must be between 0 and 1MB" {
        die("rand neg msg");
    }
    println("rand neg ok");
}

fn test_argon2id() {
    // A fixed vector is checked when the linked OpenSSL has the provider
    // (3.2+). Older builds fail closed while leaving the rest of crypto usable.
    let argon_result = crypto.argon2id_raw(
        b"password", b"1234567890abcdef", 2, 19456, 1, 32);
    if let argon_tag = argon_result {
        if encoding.hex_encode(argon_tag) !=
           "65eeb6d97a29f68d1c93c9e4e20049cacb7a5df8985b1db60c5772d48cc65ac6" {
            die("argon2id known answer");
        }
        let same = crypto.argon2id_verify(
            b"password", b"1234567890abcdef", argon_tag, 2, 19456, 1);
        guard let same_password = same else let message = err_of(same) {
            die("argon2id verify: " + message);
            return;
        }
        if !same_password { die("argon2id verify match"); }
        let different = crypto.argon2id_verify(
            b"wrong", b"1234567890abcdef", argon_tag, 2, 19456, 1);
        guard let different_password = different else let message = err_of(different) {
            die("argon2id mismatch: " + message);
            return;
        }
        if different_password { die("argon2id mismatch accepted"); }
    } else let message = err_of(argon_result) {
        if message != "Argon2id requires OpenSSL 3.2 or newer with Argon2 support" {
            die("argon2id unavailable: " + message);
        }
    }

    let invalid_argon = crypto.argon2id_raw(
        b"password", b"1234567890abcdef", 2, 7, 1, 32);
    if let invalid = invalid_argon {
        die("argon2id accepted below-minimum memory");
    } else let message = err_of(invalid_argon) {
        if message != "Argon2id memory must be between 8 * parallelism and 262144 KiB" {
            die("argon2id memory bound: " + message);
        }
    }
    println("argon2id ok");
}

test_argon2id();

fn hex(s: str) -> bytes {
    let r = encoding.hex_decode(s);
    guard let b = r else {
        die("hex fixture");
        return b"";
    }
    return b;
}

fn rsa_ok(n: bytes, e: bytes, msg: bytes, sig: bytes) -> bool {
    let r = crypto.rsa_verify_sha256(n, e, msg, sig);
    guard let v = r else let message = err_of(r) {
        die("rsa_verify_sha256: " + message);
        return false;
    }
    return v;
}

// A 2048-bit key and an RS256 signature made by `openssl dgst -sha256
// -sign`, given as a JWKS entry gives them: raw modulus and exponent.
fn test_rsa_verify_sha256() {
    let n = hex(
        "9f57994687d5e494304ffe5ab578dc6b8b3242ef270455b8db52aac470bff7af" +
        "296ac6d7a2651ac3377371b1858f214a29e86bb069a8902cd1c2e76cf5efb2ba" +
        "ea1d57700cec39526cc56fed992ddcfb07e2d6a0338fdd2bd0ca082f56ab12dd" +
        "2d1789779bda62a855c6574a2663544b7d4644eccfbc94de8280684abb8c4a28" +
        "55d6387be0ae1c9691cf2f42ee76c3dd5d0d2fd7a597b44d899ac5a62a4d9149" +
        "d805279b4807b34e0e92b89434899848be9df6d5e36b8bc32524386c8b722639" +
        "f594a603bd5b98b0d17cfdd3676826e5276c92c385702c245ea96f7e37ce4264" +
        "fb833e6e1e39023dfe8e6776e9c8ea6abb2c1f4392e8bcd973e10f4af7c5774d"    );
    let e = hex("010001");
    let msg = to_bytes("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzbGFuZyJ9");
    let sig = hex(
        "4f7418437bf60ca3869e342876c87b3a6dfe8be970f3b85d5d5295ccde6d5da8" +
        "61d4950a551b882d2f3d3823bd1f9176d7556fb5839228ca50a938126956db4b" +
        "7965f1eabf0cd60a2bc723decb616c42b8ae4b29024300b558295ad8008aee49" +
        "8b5419f04841a5a61b4d63b580eaf34278f02c4a2d411627b5ce8ffa25c3c395" +
        "1f275ebb702dd59dbb8dbcdfcb9725440b48f29c635be9464f96ef1b0068db42" +
        "dbb07603a8ace906cca8526fba676db9b64eeb3010b1d0ff5fbfc8eb78aed837" +
        "61f026bb08b45be0c2dd516b25aa24eb79b2e8712741a5a785772e7c0c3175c6" +
        "028029356e76a4945ca02d697e8420889cdb0a462c6e3ad18b1c0ad28c82de24"    );
    if !rsa_ok(n, e, msg, sig) { die("rsa valid signature rejected"); }
    if rsa_ok(n, e, to_bytes("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJvdGhlciJ9"), sig) {
        die("rsa accepted a different message");
    }
    let bent = hex(encoding.hex_encode(sig));
    bent[10] = (bent[10] + 1) % 256;
    if rsa_ok(n, e, msg, bent) { die("rsa accepted a changed signature"); }
    if rsa_ok(n, hex("03"), msg, sig) { die("rsa accepted the wrong exponent"); }
    if rsa_ok(n, e, msg, sig[0..100]) { die("rsa accepted a short signature"); }
    // A leading zero byte, as some encoders emit, is the same modulus.
    let padded = hex("00" + encoding.hex_encode(n));
    if !rsa_ok(padded, e, msg, sig) { die("rsa rejected a zero-padded modulus"); }

    let small = crypto.rsa_verify_sha256(n[0..128], e, msg, sig);
    if let _v = small {
        die("rsa accepted a 1024-bit key");
    } else let message = err_of(small) {
        if message != "RSA modulus must be 2048 to 8192 bits" { die("rsa bound: " + message); }
    }
    let no_e = crypto.rsa_verify_sha256(n, b"", msg, sig);
    if let _v = no_e {
        die("rsa accepted an empty exponent");
    }
    println("rsa ok");
}

test_rsa_verify_sha256();
