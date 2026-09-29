// http.read_frame's three-deadline split (idle / header / body), and
// basic read_frame coverage -- the function itself had no dedicated
// test before this (only http2.read_frame, an unrelated HTTP/2
// function of the same name in a different package, was covered).
//
// The three deadlines exist because "how long should this wait" has
// different honest answers depending on connection state: idle (kept
// alive, nothing arrived yet -- should be generous), header (bytes
// have started arriving but aren't a complete request line + headers
// yet), body (headers are in, a declared body hasn't fully arrived).
// idle being generous must not become a loophole for the other two,
// which are the slow-loris-shaped ones.

import "http";
import "time";

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

fn short(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

fn generous() -> until {
    return until_of(time.mono() + 5000000000);
}

// pieces trickled in with a short gap between each, then nothing more
// -- the connection just sits there after the last piece, same shape
// tests/http_chunked's own trickle() uses.
fn trickle(c: link, pieces: [bytes]) {
    let a = arena_new(8192);
    for p in pieces {
        if len(p) == 0 {
            time.sleep(300000000);
            continue;
        }
        let w = a.wire(len(p));
        fill(w, p);
        let sr = c.send(w, until_never());
        guard let _n = sr else { return; }
        time.sleep(3000000);
    }
    time.sleep(300000000);
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

// A complete request arrives well within all three deadlines: the new
// signature must not change ordinary behavior.
fn normal_request() {
    let s = connect_pair([to_bytes("GET /hi HTTP/1.1\r\nHost: t\r\n\r\n")]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let r = http.read_frame(&mut s, buf, 0, generous(), generous(), generous());
    guard let wf = r else let e = err_of(r) { die("normal request: " + e); }
    if wf.method != "GET" { die("normal request method"); }
    if wf.path != "/hi" { die("normal request path"); }
    println("normal_request");
}

// Keep-alive: two requests back to back, the second already sitting
// in the buffer when the first read_frame call returns (matching the
// original read()/read_frame's own leftover-bytes behavior) -- the
// new deadlines must not disturb this.
fn keepalive_two_requests() {
    let s = connect_pair([to_bytes(
        "GET /a HTTP/1.1\r\nHost: t\r\n\r\nGET /b HTTP/1.1\r\nHost: t\r\n\r\n")]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let r1 = http.read_frame(&mut s, buf, 0, generous(), generous(), generous());
    guard let f1 = r1 else let e = err_of(r1) { die("keepalive first: " + e); }
    if f1.path != "/a" { die("keepalive path a"); }
    if f1.filled <= 0 { die("keepalive expected leftover bytes"); }
    let r2 = http.read_frame(&mut s, buf, f1.filled, generous(), generous(),
                             generous());
    guard let f2 = r2 else let e = err_of(r2) { die("keepalive second: " + e); }
    if f2.path != "/b" { die("keepalive path b"); }
    if f2.filled != 0 { die("keepalive expected no leftover after second"); }
    println("keepalive_two_requests");
}

// Nothing sent at all: idle_deadline governs, and a short one fires
// promptly rather than hanging.
fn idle_times_out() {
    let s = connect_pair([]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let t0 = time.mono();
    let r = http.read_frame(&mut s, buf, 0, short(80), generous(), generous());
    let dt = time.mono() - t0;
    guard let _wf = r else let e = err_of(r) {
        if dt > 2000000000 {
            die("idle timeout took too long: " + to_str(dt) + "ns");
        }
        println("idle_times_out: " + e);
        return;
    }
    die("expected idle_deadline to fire with nothing sent");
}

// A request line arrives but never completes (no terminating CRLF, no
// blank line): idle_deadline is generous (bytes DID arrive, so idle
// must not apply), but header_deadline is short and must fire.
fn header_times_out() {
    let s = connect_pair([to_bytes("GET /partial-forever")]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let t0 = time.mono();
    let r = http.read_frame(&mut s, buf, 0, generous(), short(80), generous());
    let dt = time.mono() - t0;
    guard let _wf = r else let e = err_of(r) {
        if dt > 2000000000 {
            die("header timeout took too long: " + to_str(dt) + "ns");
        }
        println("header_times_out: " + e);
        return;
    }
    die("expected header_deadline to fire on a request line that never completes");
}

// Headers complete, Content-Length promises more body than arrives:
// idle and header deadlines are generous (both phases finished fine),
// body_deadline is short and must fire.
fn body_times_out() {
    let s = connect_pair([to_bytes(
        "POST /up HTTP/1.1\r\nHost: t\r\nContent-Length: 20\r\n\r\nonly5")]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let t0 = time.mono();
    let r = http.read_frame(&mut s, buf, 0, generous(), generous(), short(80));
    let dt = time.mono() - t0;
    guard let _wf = r else let e = err_of(r) {
        if dt > 2000000000 {
            die("body timeout took too long: " + to_str(dt) + "ns");
        }
        println("body_times_out: " + e);
        return;
    }
    die("expected body_deadline to fire on a body that never completes");
}

// Headers alone (no blank line ever found) exceed the buffer: a
// distinct message from the body-too-large case below, so a caller
// can answer 431 vs 413 (RFC 9110 10.5.11 vs 6.5.11) rather than the
// same status for two different problems.
fn headers_too_large() {
    let junk = "";
    let i = 0;
    while i < 600 {
        junk = junk + "a";
        i = i + 1;
    }
    let s = connect_pair([to_bytes("GET /x HTTP/1.1\r\nHost: t\r\nX-Long: " + junk)]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let r = http.read_frame(&mut s, buf, 0, generous(), generous(), generous());
    guard let _wf = r else let e = err_of(r) {
        if e != "request headers too large for buffer" {
            die("headers_too_large: wrong message: " + e);
        }
        println("headers_too_large: " + e);
        return;
    }
    die("expected headers-too-large to be refused");
}

// Headers complete and small; Content-Length alone declares a body
// bigger than the whole buffer. Refused immediately (no waiting for
// bytes that could never fit) with the ORIGINAL message, kept
// separate from headers_too_large's -- this is the 413 case, not 431.
fn body_too_large() {
    let s = connect_pair([to_bytes(
        "POST /up HTTP/1.1\r\nHost: t\r\nContent-Length: 10000\r\n\r\n")]);
    let a = arena_new(4096);
    let buf = a.wire(512);
    let r = http.read_frame(&mut s, buf, 0, generous(), generous(), generous());
    guard let _wf = r else let e = err_of(r) {
        if e != "request too large for buffer" {
            die("body_too_large: wrong message: " + e);
        }
        println("body_too_large: " + e);
        return;
    }
    die("expected body-too-large to be refused");
}

normal_request();
keepalive_two_requests();
idle_times_out();
header_times_out();
body_times_out();
headers_too_large();
body_too_large();
println("http_read_frame_deadlines ok");
