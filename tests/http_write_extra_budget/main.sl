// http.write of a response that carries extra headers -- a request id,
// CORS, a cookie: what most real API responses look like. Those used to
// leave the fixed fast path for the general emit, which rebuilt every
// header name twice per line (bytes, slice, str, lowercase copy) in
// each of its two passes: about 25 allocations a pass for one header.
//
// Normal mode checks the bytes on the wire for each shape. ALLOC_BUDGET_N
// is the allocation-budget mode tests/run_tests.sh drives: N writes of
// a JSON response with one extra header.

import "http";
import "proc";
import "strings";
import "time";

fn drain(s: link, done: chan[int]) {
    let a = arena_new(65536);
    let w = a.wire(65536);
    let total = 0;
    while true {
        let rr = s.recv(w, until_never());
        guard let n = rr else { break; }
        if n == 0 { break; }
        total = total + n;
    }
    chan_send(done, total);
}

fn with_id(id: str) -> http.Response {
    return http.with_header(http.text_response_bytes(200, "OK",
                                "application/json", b"{\"ok\":true}"),
                            "x-request-id", id);
}

fn run_budget(c: link, s: link, n: int) {
    let done: chan[int] = make_chan(1);
    spawn drain(s, done);
    let sa = arena_new(16384);
    let resp = with_id("req_0123456789abcdef0123456789abcdef");
    let k = 0;
    while k < n {
        let wr = http.write(&mut c, resp, &mut sa, until_never());
        guard let _n = wr else { exit(1); }
        sa.reset();
        k = k + 1;
    }
}

// Each shape, as it arrives on the wire, against serialize() -- the
// reference the arena path must match byte for byte.
// The Date value changes every second; byte comparisons replace it with
// a fixed one of the same length (tests/http_date checks the real one).
fn masked_date(b: bytes) -> bytes {
    let s = to_str(b);
    let at = strings.find(s, "\r\ndate: ");
    if at < 0 {
        return b;
    }
    return to_bytes(strings.slice(s, 0, at + 8) + "Thu, 01 Jan 1970 00:00:00 GMT" +
                    strings.slice(s, at + 37, len(s)));
}

fn run_shapes(c: link, s: link) {
    let shapes = [
        with_id("abc"),
        http.with_header(with_id("abc"), "Connection", "close"),
        http.with_headers(http.text_response(201, "Created", "text/plain", "x"),
                          ["X-Trace: 1", "content-length: 99", "Cache-Control: no-store"]),
        http.with_header(http.text_response(302, "Found", "text/plain", ""),
                         "location", "/next"),
        http.with_headers(http.text_response(200, "OK", "text/plain", "y"),
                          ["Content-Type: text/html", "CONNECTION:   close"])
    ];
    let sa = arena_new(16384);
    let ra = arena_new(8192);
    let inb = ra.wire(8192);
    for r in shapes {
        let want = http.serialize(r);
        let wr = http.write(&mut c, r, &mut sa, until_never());
        guard let _n = wr else { println("FAIL write"); exit(1); }
        sa.reset();
        let got = 0;
        while got < len(want) {
            let rr = s.recv(inb[got..], until_of(time.mono() + 2000000000));
            guard let n = rr else { println("FAIL recv"); exit(1); }
            if n == 0 { println("FAIL closed"); exit(1); }
            got = got + n;
        }
        if got != len(want) || to_str(masked_date(to_bytes(inb[0..got]))) != to_str(masked_date(want)) {
            println("FAIL wire differs from serialize: " + to_str(inb[0..got]));
            exit(1);
        }
        println(strings.replace(to_str(masked_date(want)), "\r\n", " | "));
    }
}

let budget_n = to_int(proc.getenv("ALLOC_BUDGET_N") ?? "") ?? -1;
let lr = link_listen(0);
guard let ln = lr else { println("FAIL listen"); exit(1); }
let dr = link_dial("127.0.0.1", ln.port(), until_never());
guard let c = dr else { println("FAIL dial"); exit(1); }
let ar = ln.accept(until_never());
guard let s = ar else { println("FAIL accept"); exit(1); }
if budget_n >= 0 {
    run_budget(c, s, budget_n);
} else {
    run_shapes(c, s);
}
