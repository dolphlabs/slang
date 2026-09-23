// http.request / http.headers / http.header_or: the additive API Phase
// 2b's representation swap will be the only way to build/inspect a
// Request through -- added now, non-breaking, so both repos can migrate
// onto it before anything underneath changes.
import "http";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(got: str, want: str, what: str) {
    if got != want {
        die(what + ": got [" + got + "] want [" + want + "]");
    }
}

let h: map[str]str = {};
h["content-type"] = "application/json";
h["x-request-id"] = "abc123";
let rr = http.request("GET", "/x", "HTTP/1.1", h, to_bytes("{}"));
guard let req = rr else { die("request() rejected a good request"); }
expect(req.method, "GET", "method");
expect(req.path, "/x", "path");
expect(http.header_or(req, "content-type", "?"), "application/json", "header_or hit");
expect(http.header_or(req, "missing", "fallback"), "fallback", "header_or miss");
expect(http.header_or(req, "Content-Type", "?"), "application/json",
      "header_or is case-insensitive");

let hm = http.headers(req);
expect(to_str(len(hm)), "2", "headers() count");
expect(hm["x-request-id"], "abc123", "headers() value");
// headers() is a fresh map: mutating it must not reach back into req
hm["x-request-id"] = "mutated";
expect(http.header_or(req, "x-request-id", "?"), "abc123",
      "headers() copy is independent of the request");
println("request/headers/header_or ok");

// header injection guard: CR or LF in a name or value is rejected
fn expect_rejected(headers: map[str]str, what: str) {
    let r = http.request("GET", "/", "HTTP/1.1", headers, b"");
    guard let _v = r else {
        println(what + " rejected");
        return;
    }
    die(what + " should have been rejected");
}

let crlf_value: map[str]str = {};
crlf_value["x-evil"] = "line1\r\nx-injected: yes";
expect_rejected(crlf_value, "CRLF in a header value");

let lf_only: map[str]str = {};
lf_only["x-evil"] = "a\nb";
expect_rejected(lf_only, "bare LF in a header value");

let colon_name: map[str]str = {};
colon_name["x:evil"] = "value";
expect_rejected(colon_name, "':' in a header name");

// a colon INSIDE a value is legitimate (e.g. a time-of-day) and must
// not be rejected -- only names are colon-restricted
let time_value: map[str]str = {};
time_value["date"] = "Wed, 21 Oct 2037 07:28:00 GMT";
let tvr = http.request("GET", "/", "HTTP/1.1", time_value, b"");
guard let _tv = tvr else { die("colon in a header VALUE should be fine"); }
println("injection guard ok");
