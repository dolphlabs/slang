// header()/header_or()/headers() against REAL wire-parsed requests (not
// just http.request()-constructed ones -- tests/http_request_ctor covers
// that path). This is where a boundary bug in scan_headers actually
// surfaced: the last header's own "\r\n" is the same bytes as the first
// half of the blank line's "\r\n\r\n" (find_blank_line's match sits
// exactly there), and a naive raw[start..sep] slice silently drops it.
// Every case below goes through http.parse(), the real wire path.
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

fn parsed(raw: str) -> http.Request {
    let r = http.parse(to_bytes(raw));
    guard let req = r else let e = err_of(r) { die("parse: " + e); }
    return req;
}

// zero headers
let z = parsed("GET / HTTP/1.1\r\n\r\n");
expect(to_str(len(http.headers(z))), "0", "zero headers: count");
expect(http.header_or(z, "anything", "d"), "d", "zero headers: header_or fallback");

// one header (the boundary case: this header's own \r\n IS the blank
// line's leading \r\n)
let one = parsed("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
expect(to_str(len(http.headers(one))), "1", "one header: count");
expect(http.header_or(one, "host", "?"), "t", "one header: value");

// two headers
let two = parsed("GET /hi HTTP/1.1\r\nHost: t\r\nX-A: B\r\n\r\n");
expect(http.header_or(two, "host", "?"), "t", "two headers: first");
expect(http.header_or(two, "x-a", "?"), "B", "two headers: last (boundary header)");
expect(to_str(len(http.headers(two))), "2", "two headers: count");

// many headers, each checked, including the LAST one (the one that sits
// on the boundary with the blank line)
let many = parsed(
    "GET /x HTTP/1.1\r\n" +
    "Host: example.com\r\n" +
    "Accept: */*\r\n" +
    "X-One: 1\r\n" +
    "X-Two: 2\r\n" +
    "X-Three: 3\r\n" +
    "X-Last: the-last-one\r\n" +
    "\r\n"
);
expect(http.header_or(many, "host", "?"), "example.com", "many: host");
expect(http.header_or(many, "accept", "?"), "*/*", "many: accept");
expect(http.header_or(many, "x-one", "?"), "1", "many: x-one");
expect(http.header_or(many, "x-two", "?"), "2", "many: x-two");
expect(http.header_or(many, "x-three", "?"), "3", "many: x-three");
expect(http.header_or(many, "x-last", "?"), "the-last-one",
      "many: x-last (the boundary header)");
expect(to_str(len(http.headers(many))), "6", "many: count");

// a repeated ordinary header: last value wins, same as the old map did
let rep = parsed("GET / HTTP/1.1\r\nX-Dup: first\r\nX-Dup: second\r\n\r\n");
expect(http.header_or(rep, "x-dup", "?"), "second", "repeated header: last wins");
expect(to_str(len(http.headers(rep))), "1", "repeated header: one map entry");

// Content-Length still frames a body correctly (exercises the
// range-based parse_digits and frame() reading hs.cl_lo/cl_hi from the
// ORIGINAL raw, not from raw_headers -- a mismatch there would frame
// the body at the wrong offset or reject a valid length)
let withbody = parsed("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello");
expect(to_str(withbody.body), "hello", "content-length body");
expect(http.header_or(withbody, "content-length", "?"), "5",
      "content-length header still readable via header_or");



// content-length/transfer-encoding are compared byte-for-byte, not via
// header_name(); a near-miss must NOT be confused with the real thing --
// exactly where a typo in the hand-written byte comparisons would hide.
let near_miss = parsed(
    "GET / HTTP/1.1\r\n" +
    "Content-Type: text/plain\r\n" +      // shares the "content-" prefix
    "Content-Length: 11\r\n" +
    "Content-Lengths: bogus\r\n" +          // one byte too long
    "Transform-Encoding: x\r\n" +           // same length, wrong letters
    "X-Transfer-Encoding: y\r\n" +           // real name with a prefix
    "\r\n" +
    "hello world"                         // 11 bytes, matching Content-Length
);
expect(http.header_or(near_miss, "content-type", "?"), "text/plain",
      "near-miss: content-type is its own header, not folded into content-length");
expect(http.header_or(near_miss, "content-length", "?"), "11",
      "near-miss: the real content-length is still found exactly");
expect(http.header_or(near_miss, "content-lengths", "?"), "bogus",
      "near-miss: content-lengths (longer) is its own header");
expect(http.header_or(near_miss, "transform-encoding", "?"), "x",
      "near-miss: transform-encoding is not mistaken for transfer-encoding");
expect(http.header_or(near_miss, "x-transfer-encoding", "?"), "y",
      "near-miss: x-transfer-encoding is not mistaken for transfer-encoding");
expect(to_str(len(http.headers(near_miss))), "5", "near-miss: all five kept distinct");

println("near-miss ok");

println("http_lazy_headers ok");
