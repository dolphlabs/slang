import "crypto";

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

let bad = crypto.rand(-1);
guard let x = bad else let e = err_of(bad) {
    if e != "invalid size: must be between 0 and 1MB" {
        die("rand neg msg");
    }
    println("rand neg ok");
}
