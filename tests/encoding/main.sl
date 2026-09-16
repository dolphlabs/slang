// encoding: hex, base64, base64url, percent-encoding and query strings.
//
// Every pair is <scheme>_encode / <scheme>_decode. Encoding is
// infallible -- any byte string has a hex form -- so encoders return a
// bare str; decoding takes input the program did not produce, so every
// decoder returns result[_, str] naming what was wrong and where.
//
// The str/bytes split is load-bearing: hex and base64 decode to `bytes`
// because they yield arbitrary data (a zero byte is ordinary), while
// url and form decode to `str` and must therefore REFUSE %00 rather
// than hand back a silently truncated value.

import "encoding";
import "crypto";
import "strings";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// ---- hex -------------------------------------------------------------
println(encoding.hex_encode(b"abc"));              // 616263
println("[" + encoding.hex_encode(b"") + "]");     // []

let hd = encoding.hex_decode("48656c6c6f");
guard let hb = hd else let e = err_of(hd) { die("hex_decode: " + e); }
println(len(hb));                                  // 5
println(hb[0]);                                    // 72 = 'H'

// uppercase in, lowercase out -- hex arrives from other systems too
let hu = encoding.hex_decode("FF00AB");
guard let hub = hu else let e = err_of(hu) { die("hex upper: " + e); }
println(encoding.hex_encode(hub));                 // ff00ab

// a zero byte survives the round trip, because bytes carries a length
println(hub[1]);                                   // 0

// errors name the offset
let hbad = encoding.hex_decode("00zz");
guard let _h1 = hbad else let e = err_of(hbad) { println(e); }
let hodd = encoding.hex_decode("abc");
guard let _h2 = hodd else let e = err_of(hodd) { println(e); }

// The gap this package closes: a digest can now be PRINTED.
// tests/crypto asserts on decimal byte values because it had to.
println(encoding.hex_encode(crypto.sha256(b"abc")));

// ---- base64 ----------------------------------------------------------
// RFC 4648 section 4 test vectors: every padding case.
println(encoding.base64_encode(b""));              //
println(encoding.base64_encode(b"f"));             // Zg==
println(encoding.base64_encode(b"fo"));            // Zm8=
println(encoding.base64_encode(b"foo"));           // Zm9v
println(encoding.base64_encode(b"foob"));          // Zm9vYg==
println(encoding.base64_encode(b"fooba"));         // Zm9vYmE=
println(encoding.base64_encode(b"foobar"));        // Zm9vYmFy

let bd = encoding.base64_decode("Zm9vYmFy");
guard let bb = bd else let e = err_of(bd) { die("base64_decode: " + e); }
println(len(bb));                                  // 6
println(encoding.hex_encode(bb));                  // 666f6f626172

// every padding length round-trips
let b1 = encoding.base64_decode("Zg==");
guard let bb1 = b1 else let e = err_of(b1) { die("b64 1"); }
println(len(bb1));                                 // 1
let b2 = encoding.base64_decode("Zm8=");
guard let bb2 = b2 else let e = err_of(b2) { die("b64 2"); }
println(len(bb2));                                 // 2

// HTTP Basic auth -- impossible before this package
println(encoding.base64_encode(b"aladdin:opensesame"));

// truncated input fails loudly rather than comparing unequal later
let btrunc = encoding.base64_decode("Zm9vYmF");
guard let _b3 = btrunc else let e = err_of(btrunc) { println(e); }

// ---- base64url -------------------------------------------------------
// -_ alphabet, padding omitted. This is what a JWT segment is.
// 0xfb 0xff encodes to +/ in standard and -_ in url: the one input
// that actually distinguishes the two alphabets.
let tricky = encoding.hex_decode("fbff");
guard let tb = tricky else let e = err_of(tricky) { die("tricky"); }
println(encoding.base64_encode(tb));               // +/8=
println(encoding.base64url_encode(tb));            // -_8   (no padding)

let ub = encoding.base64url_decode("-_8");
guard let ubb = ub else let e = err_of(ub) { die("b64url: " + e); }
println(encoding.hex_encode(ubb));                 // fbff

// padding is tolerated on the url form, since producers differ
let ubp = encoding.base64url_decode("-_8=");
guard let ubpb = ubp else let e = err_of(ubp) { die("b64url pad"); }
println(encoding.hex_encode(ubpb));                // fbff

// the alphabets are NOT interchangeable, and the error says so
let xa = encoding.base64_decode("-_8=");
guard let _x1 = xa else let e = err_of(xa) { println(e); }

// ---- percent-encoding ------------------------------------------------
println(encoding.url_encode("hello world"));       // hello%20world
println(encoding.url_encode("a+b&c=d"));           // a%2Bb%26c%3Dd
println(encoding.url_encode("safe-._~"));          // unreserved, unchanged
println(encoding.url_encode("café"));         // UTF-8, two escapes

let ud = encoding.url_decode("hello%20world");
guard let us = ud else let e = err_of(ud) { die("url_decode: " + e); }
println(us);

// url_decode leaves '+' alone; form_decode makes it a space. Getting
// this backwards is silent, which is why they have separate names.
let up = encoding.url_decode("a+b");
guard let ups = up else let e = err_of(up) { die("url plus"); }
println(ups);                                      // a+b
let fp = encoding.form_decode("a+b");
guard let fps = fp else let e = err_of(fp) { die("form plus"); }
println(fps);                                      // a b
println(encoding.form_encode("hello world"));      // hello+world

// round trip through the awkward bytes
let round = encoding.url_decode(encoding.url_encode("a b&c=d%e"));
guard let rs = round else let e = err_of(round) { die("round"); }
println(rs);

// malformed escapes are refused, with the offset
let ubad = encoding.url_decode("a%zz");
guard let _u1 = ubad else let e = err_of(ubad) { println(e); }
let utrunc = encoding.url_decode("a%4");
guard let _u2 = utrunc else let e = err_of(utrunc) { println(e); }

// %00 cannot live in a str, so it is an error rather than a truncation
let unul = encoding.url_decode("a%00b");
guard let _u3 = unul else let e = err_of(unul) { println(e); }

// ---- query strings ---------------------------------------------------
let q = "/search?q=hello+world&page=2&tag=a%26b&debug";

guard let qv = encoding.query_get(q, "q") else { die("q missing"); }
println(qv);                                       // hello world

guard let pv = encoding.query_get(q, "page") else { die("page missing"); }
println(pv);                                       // 2

// a value's own '&' survives, because it arrived percent-encoded
guard let tv = encoding.query_get(q, "tag") else { die("tag missing"); }
println(tv);                                       // a&b

// a bare key is a flag: present with an empty value, not absent
guard let dv = encoding.query_get(q, "debug") else { die("debug missing"); }
println("[" + dv + "]");                           // []

// absent is none -- opt, not result, because a missing parameter is
// absent data rather than bad data
let miss: opt[str] = encoding.query_get(q, "nope");
guard let _m = miss else {
    println("absent key is none");
}

// ?? reads naturally against it, the same way proc.getenv does
println("[" + (encoding.query_get(q, "nope") ?? "fallback") + "]");

// keys come back in order, duplicates included: a map would drop one
let keys = encoding.query_keys(q);
println(len(keys));                                // 4
println(strings.join(keys, ","));

// works on a bare query string and on one with a leading '?'
guard let bq = encoding.query_get("a=1&b=2", "b") else { die("bare"); }
println(bq);
guard let lq = encoding.query_get("?a=1&b=2", "a") else { die("leading"); }
println(lq);

// a repeated key yields the FIRST value, and both are visible in keys
guard let rk = encoding.query_get("x=1&x=2", "x") else { die("repeat"); }
println(rk);                                       // 1
println(len(encoding.query_keys("x=1&x=2")));      // 2

// an encoded key matches its decoded form
guard let ek = encoding.query_get("my+key=v", "my key") else { die("enc key"); }
println(ek);

// a fragment is not part of the query
let frag: opt[str] = encoding.query_get("a=1#b=2", "b");
guard let _f = frag else {
    println("fragment excluded");
}

println("done");
