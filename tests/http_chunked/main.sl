// Chunked request bodies in the http server, and the framing rules around
// them.
//
// Framing -- where a request ENDS -- is a security boundary, not just
// parsing: if a front proxy and this server frame the same bytes
// differently, the leftover bytes are read as a second request the proxy
// never saw (request smuggling). So most of this file is refusals.
//
// Two of them were live holes found while adding chunked support, both
// confirmed against the old code before fixing: two disagreeing
// Content-Length headers were accepted with the last one silently winning,
// and "Content-Length: 18446744073709551619" (2^64 + 3) wrapped to 3.

import "http";
import "time";
import "strings";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn fill(dst: wire, src: bytes) {
    let i = 0;
    for b in src {
        dst[i] = b;
        i = i + 1;
    }
}

fn body_of(raw: str, what: str) -> str {
    let pr = http.parse(to_bytes(raw));
    guard let req = pr else let e = err_of(pr) {
        die(what + ": " + e);
    }
    return to_str(req.body);
}

fn refused(raw: str, want: str, what: str) {
    let pr = http.parse(to_bytes(raw));
    guard let _req = pr else let e = err_of(pr) {
        if !strings.contains(e, want) {
            die(what + ": refused, but with [" + e + "], wanted [" + want + "]");
        }
        return;
    }
    die(what + ": ACCEPTED");
}

let H = "POST /up HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n";

// ---- decoding ---------------------------------------------------------------

if body_of(H + "5\r\nhello\r\n0\r\n\r\n", "one chunk") != "hello" { die("one chunk body"); }
if body_of(H + "3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n", "two chunks") != "abcdefg" { die("two chunks body"); }
if body_of(H + "0\r\n\r\n", "empty body") != "" { die("empty chunked body"); }
if body_of(H + "A\r\n0123456789\r\n0\r\n\r\n", "uppercase hex") != "0123456789" { die("uppercase hex"); }
if body_of(H + "a\r\n0123456789\r\n0\r\n\r\n", "lowercase hex") != "0123456789" { die("lowercase hex"); }
if body_of(H + "000005\r\nhello\r\n0\r\n\r\n", "leading zeros") != "hello" { die("leading zeros"); }
if body_of(H + "5;name=value\r\nhello\r\n0;x\r\n\r\n", "extensions") != "hello" { die("extensions ignored"); }
if body_of("POST / HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n", "case") != "ok" { die("coding name is case-insensitive"); }
println("chunked bodies decode, with extensions ignored and hex in either case");

// Trailers are read and DISCARDED: merged into the headers, a trailer could
// rewrite a header after the handler had already checked it.
let tr = http.parse(to_bytes(H + "2\r\nhi\r\n0\r\nX-Late: evil\r\nX-Other: 1\r\n\r\n"));
guard let treq = tr else let e = err_of(tr) { die("trailers: " + e); }
if to_str(treq.body) != "hi" { die("body before trailers"); }
guard let _late = http.header(treq, "x-late") else {
    println("trailers are consumed and discarded, never merged into headers");
}

// Many tiny chunks: joined pairwise, not copied once per chunk.
let many = strings.repeat("1\r\nx\r\n", 2000);
if len(body_of(H + many + "0\r\n\r\n", "many chunks")) != 2000 { die("2000 one-byte chunks"); }
println("2000 one-byte chunks assemble correctly");

// ---- framing refusals -----------------------------------------------------------

refused("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        "both Transfer-Encoding and Content-Length", "TE and CL together");
refused("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
        "unsupported Transfer-Encoding", "a list of codings");
refused("POST / HTTP/1.1\r\nTransfer-Encoding: chunked, identity\r\n\r\n0\r\n\r\n",
        "unsupported Transfer-Encoding", "chunked not last");
refused("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "HTTP/1.0", "Transfer-Encoding in HTTP/1.0");
refused("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "repeated transfer-encoding", "repeated Transfer-Encoding");
refused("POST / HTTP/1.1\r\nContent-Length: 50\r\nContent-Length: 3\r\n\r\nabc",
        "repeated content-length", "disagreeing Content-Lengths (was accepted)");
refused("POST / HTTP/1.1\r\nContent-Length: 18446744073709551619\r\n\r\nabc",
        "number too large", "Content-Length 2^64+3 (wrapped to 3)");
refused("POST / HTTP/1.1\r\nContent-Length: -3\r\n\r\nabc",
        "bad Content-Length", "negative Content-Length");
println("refused: TE with CL, coding lists, TE in HTTP/1.0, repeated framing headers, overflowing and negative lengths");

// ---- malformed chunks ----------------------------------------------------------

refused(H + "zz\r\nhello\r\n0\r\n\r\n", "malformed chunk size", "non-hex size");
refused(H + "5x\r\nhello\r\n0\r\n\r\n", "malformed chunk size", "junk after size");
refused(H + "\r\nhello\r\n0\r\n\r\n", "malformed chunk size", "empty size line");
refused(H + "5\r\nhelloXX0\r\n\r\n", "not followed by CRLF", "data longer than its size");
refused(H + "1000000000000000\r\nx\r\n0\r\n\r\n", "chunk size too large", "16 hex digits");
refused(H + "5\nhello\r\n0\r\n\r\n", "bare LF", "bare LF after size");
refused(H + "5;" + strings.repeat("e", 1100) + "\r\nhello\r\n0\r\n\r\n", "too long", "size line over 1KB");
refused(H + "0\r\nX: " + strings.repeat("v", 9000) + "\r\n\r\n", "trailers too large", "trailers over 8KB");
refused(H + "5\r\nhello\r\n", "truncated body", "no last chunk");
refused(H + "5\r\nhel", "truncated body", "data cut short");
println("refused: bad or oversized sizes, missing CRLFs, bare LFs, oversized trailers, truncation");

// ---- over a real connection ------------------------------------------------------

fn trickle(c: link, pieces: [bytes]) {
    let a = arena_new(8192);
    for p in pieces {
        let w = a.wire(len(p));
        fill(w, p);
        let sr = c.send(w, until_never());
        guard let _n = sr else { return; }
        time.sleep(3000000);
    }
    time.sleep(50000000);
}

fn connect_pair(pieces: [bytes]) -> link {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let c = dr else { die("dial"); }
    spawn trickle(c, pieces);
    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }
    return s;
}

// A chunked body arriving in pieces that split the size line, the data and
// the terminator: read() must wait for the whole message.
let s1 = connect_pair([to_bytes("POST /t HTTP/1.1\r\nHost: t\r\nTransfer-Enc"),
                       to_bytes("oding: chunked\r\n\r\n"),
                       to_bytes("7\r\nchu"),
                       to_bytes("nked\r\n"),
                       to_bytes("7\r\n body!!\r\n0"),
                       to_bytes("\r\n\r")]
                       + [to_bytes("\n")]);
let a1 = arena_new(4096);
let b1 = a1.wire(512);
let r1 = http.read(&mut s1, b1, 0, until_of(time.mono() + 5000000000));
guard let got1 = r1 else let e = err_of(r1) { die("trickled read: " + e); }
if to_str(got1.req.body) != "chunked body!!" { die("trickled body: [" + to_str(got1.req.body) + "]"); }
if got1.filled != 0 { die("trickled leftover"); }
println("a chunked body split across seven sends is read whole");

// Pipelined: a chunked request and the next request in ONE send. The
// chunked framing must end exactly at its terminator.
let s2 = connect_pair([to_bytes(H + "3\r\nabc\r\n0\r\n\r\nGET /next HTTP/1.1\r\nHost: t\r\n\r\n")]);
let b2 = a1.wire(512);
let r2a = http.read(&mut s2, b2, 0, until_of(time.mono() + 5000000000));
guard let first = r2a else let e = err_of(r2a) { die("pipelined first: " + e); }
if to_str(first.req.body) != "abc" { die("pipelined chunked body"); }
if first.filled <= 0 { die("pipelined: the next request was swallowed"); }
let r2b = http.read(&mut s2, b2, first.filled, until_of(time.mono() + 5000000000));
guard let second = r2b else let e = err_of(r2b) { die("pipelined second: " + e); }
if second.req.path != "/next" { die("pipelined second path: " + second.req.path); }
println("a chunked request followed by another in one send: both framed exactly");

// Larger than the buffer: refused, not overrun.
let s3 = connect_pair([to_bytes(H + "400\r\n" + strings.repeat("z", 1024) + "\r\n0\r\n\r\n")]);
let b3 = a1.wire(256);
let r3 = http.read(&mut s3, b3, 0, until_of(time.mono() + 5000000000));
guard let _big = r3 else let e = err_of(r3) {
    if !strings.contains(e, "too large") { die("oversized: " + e); }
    println("a chunked body larger than the buffer is refused");
}

println("done");
