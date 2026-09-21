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
guard let unused = many else let e = err_of(many) {
    if e != "invalid iterations: must be between 1 and 10000000" {
        die("pbkdf2 cap msg: " + e);
    }
    println("pbkdf2 ok");
}

let bad = crypto.rand(-1);
guard let x = bad else let e = err_of(bad) {
    if e != "invalid size: must be between 0 and 1MB" {
        die("rand neg msg");
    }
    println("rand neg ok");
}
