import "http2";
import "net";
import "strings";
import "time";

// The HTTP/2 client (stdlib/http2/client.sl) against this package's own
// server, over loopback h2c, plus a raw-frame server for what the server
// API cannot produce (a 1xx, a bad content-length, PUSH_PROMISE).
//
//   1. one stream at a time: client_preface, client_request_msg,
//      client_read_response;
//   2. twenty concurrent calls on one Client, each body distinct, so a
//      response routed to the wrong caller is caught;
//   3. a 200000-octet response, past both default windows, so the
//      client's WINDOW_UPDATEs are what keep it flowing;
//   4. trailers (response_trailers_msg), with and without a body;
//   5. a call that times out, then calls that still work: the late
//      response's header block must still be decoded or HPACK drifts;
//   6. the caller's max_body, and request validation;
//   7. close;
//   8. raw server: 1xx then 200, content-length mismatch, PUSH_PROMISE;
//   9. the server keeps its HPACK decoder table when the peer advertises
//      SETTINGS_HEADER_TABLE_SIZE 0 (that setting bounds the PEER's
//      decoder; resizing ours broke the next indexed header);
//  10. a writer whose send failed still takes every message, so a
//      producer is never left blocked on a channel nobody reads.

fn ms(n: int) -> int { return n * 1000000; }

fn lim() -> http2.Limits {
    return http2.Limits {
        handshake: ms(3000), idle: ms(5000),
        request: ms(5000), write: ms(3000),
        max_concurrent: 100
    };
}

fn big_body() -> bytes {
    let out = b"0123456789";
    while len(out) < 200000 {
        out = out + out;
    }
    return out[0..200000];
}

fn handle(req: http2.Req, wch: chan[http2.WMsg], g: chan[bool]) {
    let none_h: [http2.Header] = [];
    let s = req.stream;
    if req.path == "/echo" {
        chan_send(wch, http2.response_msg(s, "200", none_h, req.body));
    } else if req.path == "/big" {
        chan_send(wch, http2.response_msg(s, "200", none_h, big_body()));
    } else if req.path == "/slow" {
        time.sleep(ms(400));
        chan_send(wch, http2.response_msg(s, "200",
            [http2.Header { name: "x-late", value: "yes" }], b"late"));
    } else if req.path == "/trailers" || req.path == "/trailers-empty" {
        let body = b"abc";
        if req.path == "/trailers-empty" {
            body = b"";
        }
        let made = http2.response_trailers_msg(s, "200",
            [http2.Header { name: "content-type", value: "application/grpc" }],
            body, [http2.Header { name: "grpc-status", value: "0" }]);
        guard let msg = made else let e = err_of(made) {
            println("FAIL trailers msg: " + e);
            exit(1);
        }
        chan_send(wch, msg);
    } else {
        chan_send(wch, http2.response_msg(s, "404", none_h, b""));
    }
    http2.gate_leave(g);
}

fn serve(fd: i32, done: chan[str]) {
    let t = http2.transport_fd(fd);
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(64);
    let l = lim();
    let g = http2.gate(l.max_concurrent);
    spawn http2.writer_task(t, wch, l.write);
    let pr = http2.accept_preface(rd, t, wch, until_of(time.mono() + l.handshake));
    guard let _p = pr else let e = err_of(pr) {
        chan_send(done, "preface: " + e);
        return;
    }
    while true {
        let rr = http2.read_request(cn, rd, t, wch, l);
        guard let req = rr else let e = err_of(rr) {
            http2.gate_drain(g, l.max_concurrent);
            chan_close(wch);
            chan_send(done, e);
            return;
        }
        http2.gate_enter(g);
        spawn handle(req, wch, g);
    }
}

fn accept_loop(lfd: i32, done: chan[str]) {
    while true {
        let a = net.accept(lfd as int);
        guard let fd = a else { return; }
        spawn serve(fd, done);
    }
}

fn fail(what: str) {
    println("FAIL " + what);
    exit(1);
}

fn dial(port: int) -> http2.Transport {
    let d = net.dial("127.0.0.1", port);
    guard let fd = d else { fail("dial"); return http2.transport_fd(0); }
    return http2.transport_fd(fd);
}

fn call(c: http2.Client, path: str, body: bytes, timeout: int,
        max_body: int) -> result[http2.Response, str] {
    let none_h: [http2.Header] = [];
    let method = "GET";
    if len(body) > 0 {
        method = "POST";
    }
    return http2.client_call(c, method, "http", "localhost", path, none_h,
                             body, timeout, max_body);
}

fn header_of(hs: [http2.Header], name: str) -> str {
    for h in hs {
        if h.name == name { return h.value; }
    }
    return "";
}

// ---- 1. one stream at a time ---------------------------------------------
fn phase_single(port: int) {
    let t = dial(port);
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(16);
    spawn http2.writer_task(t, wch, lim().write);
    let pr = http2.client_preface(cn, rd, t, wch, lim());
    guard let _p = pr else let e = err_of(pr) { fail("preface: " + e); return; }
    let none_h: [http2.Header] = [];
    let mr = http2.client_request_msg(cn, 1, "POST", "http", "localhost",
                                      "/echo", none_h, b"hello");
    guard let msg = mr else let e = err_of(mr) { fail("request: " + e); return; }
    chan_send(wch, msg);
    let rr = http2.client_read_response(cn, rd, t, wch, 1, ms(3000), 1024);
    guard let resp = rr else let e = err_of(rr) { fail("response: " + e); return; }
    if resp.status != "200" || resp.body != b"hello" {
        fail("single echo: " + resp.status);
    }
    let again = http2.client_request_msg(cn, 1, "GET", "http", "localhost",
                                         "/echo", none_h, b"");
    if let _a = again { fail("reused stream id accepted"); }
    let even = http2.client_request_msg(cn, 4, "GET", "http", "localhost",
                                        "/echo", none_h, b"");
    if let _e = even { fail("even stream id accepted"); }
    chan_close(wch);
    http2.tr_close(t);
    println("single stream ok");
}

// ---- 2. concurrent calls on one Client -----------------------------------
fn concurrent_one(c: http2.Client, i: int, out: chan[str]) {
    let body = to_bytes("body-" + to_str(i) + "-" + strings.repeat("x", i * 37));
    let r = call(c, "/echo", body, ms(5000), 65536);
    guard let resp = r else let e = err_of(r) {
        chan_send(out, "call " + to_str(i) + ": " + e);
        return;
    }
    if resp.body != body {
        chan_send(out, "call " + to_str(i) + " got another call's body");
        return;
    }
    chan_send(out, "");
}

fn phase_concurrent(c: http2.Client) {
    let out: chan[str] = make_chan(32);
    for i in 0..20 {
        spawn concurrent_one(c, i, out);
    }
    for i in 0..20 {
        let got = chan_recv(out) ?? "closed";
        if len(got) > 0 { fail(got); }
    }
    println("20 concurrent calls routed");
}

fn main_phases(port: int) {
    phase_single(port);

    let sr = http2.client_start(dial(port), lim());
    guard let c = sr else let e = err_of(sr) { fail("client_start: " + e); return; }
    if http2.client_max_streams(c) != 100 { fail("max streams"); }
    phase_concurrent(c);

    // ---- 3. large response under flow control
    let br = call(c, "/big", b"", ms(5000), 300000);
    guard let big = br else let e = err_of(br) { fail("big: " + e); return; }
    if big.body != big_body() { fail("big body mismatch"); }
    println("200000-octet response ok");

    // ---- 4. trailers
    let tr = call(c, "/trailers", b"", ms(3000), 1024);
    guard let tresp = tr else let e = err_of(tr) { fail("trailers: " + e); return; }
    if tresp.body != b"abc" || header_of(tresp.trailers, "grpc-status") != "0" ||
       header_of(tresp.headers, "content-type") != "application/grpc" ||
       header_of(tresp.headers, "content-length") != "" {
        fail("trailers response");
    }
    let te = call(c, "/trailers-empty", b"", ms(3000), 1024);
    guard let teresp = te else let e = err_of(te) { fail("trailers-empty: " + e); return; }
    if len(teresp.body) != 0 || header_of(teresp.trailers, "grpc-status") != "0" {
        fail("empty-body trailers response");
    }
    println("trailers ok");

    // ---- 5. timeout, then the connection still works
    let slow = call(c, "/slow", b"", ms(50), 1024);
    if let _s = slow {
        fail("slow call did not time out");
    } else let e = err_of(slow) {
        if e != "timeout" { fail("slow call: " + e); }
    }
    time.sleep(ms(500));   // the late response arrives and is discarded
    let after = call(c, "/echo", b"after", ms(3000), 1024);
    guard let aresp = after else let e = err_of(after) { fail("after timeout: " + e); return; }
    if aresp.body != b"after" { fail("after timeout body"); }
    let late = call(c, "/slow", b"", ms(3000), 1024);
    guard let lresp = late else let e = err_of(late) { fail("late call: " + e); return; }
    if header_of(lresp.headers, "x-late") != "yes" { fail("headers after an orphaned block"); }
    println("timeout isolated");

    // ---- 6. max_body and validation
    let capped = call(c, "/big", b"", ms(3000), 1000);
    if let _cp = capped { fail("max_body not enforced"); }
    let still = call(c, "/echo", b"ok", ms(3000), 1024);
    guard let sresp = still else let e = err_of(still) { fail("after max_body: " + e); return; }
    if sresp.body != b"ok" { fail("after max_body body"); }
    let bad_names = ["Connection", "connection", "x-Upper", "host", "te"];
    let bad_values = ["close", "close", "1", "example.com", "gzip"];
    for i in 0..len(bad_names) {
        let r = http2.client_call(c, "GET", "http", "localhost", "/echo",
            [http2.Header { name: bad_names[i], value: bad_values[i] }], b"",
            ms(1000), 1024);
        if let _r = r { fail("header " + bad_names[i] + " accepted"); }
    }
    let crlf = http2.client_call(c, "GET", "http", "localhost", "/echo",
        [http2.Header { name: "x-a", value: "1\r\nx-b: 2" }], b"", ms(1000), 1024);
    if let _cr = crlf { fail("CR LF in a header value accepted"); }
    let te_ok = http2.client_call(c, "GET", "http", "localhost", "/echo",
        [http2.Header { name: "te", value: "trailers" }], b"", ms(1000), 1024);
    guard let _t = te_ok else let e = err_of(te_ok) { fail("te: trailers refused: " + e); return; }
    println("limits and validation ok");

    // ---- 7. close
    http2.client_close(c);
    let closed = call(c, "/echo", b"x", ms(1000), 1024);
    if let _cl = closed { fail("call after close succeeded"); }
    http2.client_close(c);
    println("close ok");
}

// ---- 8. raw server ---------------------------------------------------------
fn raw_headers(stream: int, hs: [http2.Header], end: bool) -> bytes {
    let blk = http2.encode_block(hs);
    let flags = http2.FLAG_END_HEADERS;
    if end { flags = flags | http2.FLAG_END_STREAM; }
    return http2.header_bytes(http2.T_HEADERS, flags, stream, len(blk)) + blk;
}

// One connection per reply: read the client's preface, send our
// SETTINGS, wait for its request, then send the canned `reply`.
fn raw_serve(lfd: i32, replies: [bytes]) {
    for reply in replies {
        let a = net.accept(lfd as int);
        guard let fd = a else { return; }
        let t = http2.transport_fd(fd);
        let rd = http2.reader_new();
        let wch: chan[http2.WMsg] = make_chan(8);
        let pr = http2.accept_preface(rd, t, wch, until_of(time.mono() + ms(3000)));
        guard let _p = pr else { return; }
        let first = chan_recv(wch);
        guard let settings = first else { return; }
        // Our SETTINGS first: the client waits for them before it sends
        // a request. Then answer once the request HEADERS arrive.
        net.send(fd, settings.head);
        while true {
            let fr = http2.read_frame(rd, t, 16384, until_of(time.mono() + ms(3000)));
            guard let f = fr else { break; }
            if f.ftype == http2.T_HEADERS { break; }
        }
        net.send(fd, reply);
        time.sleep(ms(100));
        net.close(fd);
    }
}

fn raw_call(port: int) -> result[http2.Response, str] {
    let sr = http2.client_start(dial(port), lim());
    guard let c = sr else let e = err_of(sr) { return err(e); }
    let r = call(c, "/", b"", ms(2000), 1024);
    http2.client_close(c);
    return r;
}

fn phase_raw() {
    let lr = net.listen(0);
    guard let lfd = lr else { fail("raw listen"); return; }
    let pr = net.port(lfd as int);
    guard let port = pr else { fail("raw port"); return; }
    let ok_info = raw_headers(1, [http2.Header { name: ":status", value: "103" },
                                  http2.Header { name: "link", value: "</a>" }], false) +
                  raw_headers(1, [http2.Header { name: ":status", value: "200" }], true);
    let bad_length = raw_headers(1, [http2.Header { name: ":status", value: "200" },
                                     http2.Header { name: "content-length", value: "5" }], false) +
                     http2.header_bytes(http2.T_DATA, http2.FLAG_END_STREAM, 1, 2) + b"hi";
    let push = http2.header_bytes(http2.T_PUSH_PROMISE, http2.FLAG_END_HEADERS, 1, 4) +
               b"\x00\x00\x00\x02";
    let no_status = raw_headers(1, [http2.Header { name: "x-a", value: "1" }], true);
    spawn raw_serve(lfd, [ok_info, bad_length, push, no_status]);

    let r1 = raw_call(port as int);
    guard let info = r1 else let e = err_of(r1) { fail("1xx then 200: " + e); return; }
    if info.status != "200" || header_of(info.headers, "link") != "" {
        fail("1xx headers leaked into the response");
    }
    let r2 = raw_call(port as int);
    if let _b = r2 { fail("content-length mismatch accepted"); }
    let r3 = raw_call(port as int);
    if let _p = r3 { fail("PUSH_PROMISE accepted"); }
    let r4 = raw_call(port as int);
    if let _n = r4 { fail("response without :status accepted"); }
    println("malformed responses refused");
}

// ---- 9. HPACK table size from the peer ------------------------------------
fn phase_table_size(port: int) {
    let t = dial(port);
    let rd = http2.reader_new();
    // HEADER_TABLE_SIZE 0 from us, then two requests: the first inserts
    // "x-k: v" into the server's decoder table (literal with incremental
    // indexing, new name), the second refers to it by index 62.
    let settings = http2.settings_frame([http2.S_HEADER_TABLE_SIZE], [0]);
    let base = http2.encode_block([
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "http" },
        http2.Header { name: ":path", value: "/echo" },
        http2.Header { name: ":authority", value: "localhost" }
    ]);
    let insert = base + b"\x40\x03x-k\x01v";
    let index = base + b"\xbe";
    let flags = http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM;
    let wire = http2.preface() + settings +
               http2.header_bytes(http2.T_HEADERS, flags, 1, len(insert)) + insert +
               http2.header_bytes(http2.T_HEADERS, flags, 3, len(index)) + index;
    let sent = net.send(t.fd as int, wire);
    guard let _s = sent else { fail("table-size send"); return; }
    let answered = 0;
    while answered < 2 {
        let fr = http2.read_frame(rd, t, 16384, until_of(time.mono() + ms(3000)));
        guard let f = fr else let e = err_of(fr) {
            fail("server stopped after HEADER_TABLE_SIZE 0: " + e);
            return;
        }
        if f.ftype == http2.T_GOAWAY { fail("server sent GOAWAY after HEADER_TABLE_SIZE 0"); }
        if f.ftype == http2.T_HEADERS { answered = answered + 1; }
    }
    http2.tr_close(t);
    println("decoder table kept its size");
}

// ---- 10. a failed writer drains ---------------------------------------------
fn drain_sender(wch: chan[http2.WMsg], out: chan[str]) {
    for i in 0..10 {
        chan_send(wch, http2.raw_msg(b"x"));
    }
    chan_send(out, "sent");
}

fn drain_timer(out: chan[str]) {
    time.sleep(ms(3000));
    chan_send(out, "stuck");
}

fn phase_writer_drain() {
    let lr = net.listen(0);
    guard let lfd = lr else { fail("drain listen"); return; }
    let pr = net.port(lfd as int);
    guard let port = pr else { fail("drain port"); return; }
    let d = net.dial("127.0.0.1", port as int);
    guard let fd = d else { fail("drain dial"); return; }
    let a = net.accept(lfd as int);
    guard let _peer = a else { fail("drain accept"); return; }
    // The peer never reads: an 8 MB frame outlasts the socket buffers, so
    // the writer's send times out and it gives up on the connection.
    let wch: chan[http2.WMsg] = make_chan(2);
    spawn http2.writer_task(http2.transport_fd(fd), wch, ms(300));
    chan_send(wch, http2.raw_msg(strings.bytes_zero(8388608)));
    let out: chan[str] = make_chan(2);
    spawn drain_sender(wch, out);
    spawn drain_timer(out);
    let first = chan_recv(out) ?? "closed";
    if first != "sent" { fail("producers blocked behind a failed writer"); }
    chan_close(wch);
    println("failed writer drains");
}

let lr = net.listen(0);
guard let lfd = lr else { println("listen failed"); exit(1); }
let pr = net.port(lfd as int);
guard let port = pr else { println("port failed"); exit(1); }
let done: chan[str] = make_chan(64);
spawn accept_loop(lfd, done);
main_phases(port as int);
phase_raw();
phase_table_size(port as int);
phase_writer_drain();
println("http2 client ok");
exit(0);
