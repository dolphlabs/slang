// A str is NUL-terminated, so a zero byte copied into one used to end it:
// to_str(b"admin\x00.evil") compared equal to "admin", and the JSON key
// "id\u0000zz" filled the field "id". Wherever outside bytes become a str,
// each zero byte is now U+FFFD (EF BF BD): nothing is cut short and the
// result never equals the string before the zero.

import "encoding";
import "json";
import "strings";

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn hex(s: str) -> str {
    return encoding.hex_encode(to_bytes(s));
}

fn show(label: str, s: str) {
    println(label + ": len=" + to_str(len(s)) + " hex=" + hex(s));
}

let fffd = to_str(b"\xEF\xBF\xBD");

// to_str: one zero, several, at either end, all zeros, none
show("middle", to_str(b"a\x00b"));
show("ends", to_str(b"\x00a\x00"));
show("run", to_str(b"\x00\x00\x00"));
show("none", to_str(b"plain"));
show("empty", to_str(b""));
let admin = to_str(b"admin\x00.evil");
if admin == "admin" || !strings.has_prefix(admin, "admin") {
    fail("to_str still ends at the zero byte");
}
if admin != "admin" + fffd + ".evil" {
    fail("to_str did not write U+FFFD");
}

// strings.from_bytes and its lowercasing form, over a range
show("from_bytes", strings.from_bytes(b"xA\x00Bx", 1, 4));
show("from_bytes_lower", strings.from_bytes_lower(b"xA\x00Bx", 1, 4));

// percent-decoding already refuses %00 rather than build a str from it
let u: result[str, str] = encoding.url_decode("a%00b");
if let _us = u {
    fail("url_decode accepted %00");
}
println("url_decode: " + err_of(u));
if let _v = encoding.query_get("/p?user=admin%00x&q=1", "user") {
    fail("query_get returned a value holding %00");
}
let ks = encoding.query_keys("?a%00=1&b=2");
println("query_keys: " + to_str(len(ks)) + " " + ks[0]);

// JSON: a \u0000 escape in a value and in a key
let t: result[str, str] = json.decode("\"a\\u0000b\"");
guard let ts = t else let e = err_of(t) { fail("json str " + e); }
show("json value", ts);

gc struct Who {
    id: int,
}
let w: result[Who, str] = json.decode("{\"id\\u0000zz\":7}");
if let _who = w {
    fail("json key cut at its zero byte filled the field id");
}
println("json key: " + err_of(w));
let m: result[map[str]int, str] = json.decode("{\"id\\u0000zz\":7}");
guard let mm = m else let e = err_of(m) { fail("json map " + e); }
for k, v in mm {
    show("json map key", k);
}
println("ok");
