// A CR or LF inside a header field must never reach the wire as a line
// break: it would end the line early and let the rest become a header of
// its own (response splitting, request header injection). Each writer is
// checked with input a handler could have copied from a request.

import "http";
import "httpc";
import "http2";
import "strings";
import "time";

fn evil() -> str {
    return "a\r\nSet-Cookie: session=attacker";
}

fn split(raw: str) -> bool {
    return strings.contains(raw, "\r\nSet-Cookie:") || strings.contains(raw, "\nSet-Cookie:");
}

fn report(what: str, raw: str) {
    if split(raw) {
        println(what + ": SPLIT");
    } else {
        println(what + ": clean");
    }
}

fn drain_into(c: link, out: chan[str]) {
    let a = arena_new(65536);
    let buf = a.wire(65536);
    let mut_c = c;
    let total = "";
    while true {
        let r = mut_c.recv(buf, until_of(time.mono() + 500000000));
        guard let n = r else { break; }
        if n == 0 { break; }
        total = total + to_str(buf[0..n]);
    }
    chan_send(out, total);
}

fn wire_text(resp: http.Response) -> str {
    let lr = link_listen(0);
    guard let ln = lr else { exit(1); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let client = dr else { exit(1); }
    let ar = ln.accept(until_never());
    guard let server = ar else { exit(1); }
    let got: chan[str] = make_chan(1);
    spawn drain_into(client, got);
    write_and_close(server, resp);
    return chan_recv(got) ?? "";
}

fn write_and_close(c: link, resp: http.Response) {
    let sa = arena_new(16384);
    let mut_c = c;
    let _w = http.write(&mut mut_c, resp, &mut sa, until_never());
}

fn base() -> http.Response {
    return http.text_response(200, "OK", "text/plain", "hi");
}

// --- http responses -------------------------------------------------------

let shared = http.with_header(base(), "x-echo", evil());
report("with_header, serialize", to_str(http.serialize(shared)));
report("with_header, write", wire_text(shared));
report("with_header, serialize_builder", to_str(http.serialize_builder(shared)));
println("caller's response untouched: " + to_str(strings.contains(shared.extra[0], "\r\n")));

let raw_line = http.with_headers(base(), ["x-raw: " + evil()]);
report("with_headers line, write", wire_text(raw_line));

let loc = http.with_header(base(), "location", "/next" + "\r\nSet-Cookie: session=attacker");
report("location, write", wire_text(loc));

// The fixed fast path: content type and status text only, no extra lines.
report("content type, write", wire_text(http.text_response(200, "OK", "text/plain" + "\r\nSet-Cookie: s=1", "hi")));
report("status text, write", wire_text(http.text_response(200, "OK\r\nSet-Cookie: s=1", "text/plain", "hi")));

report("static_render", to_str(http.static_render(200, "text/plain\r\nSet-Cookie: s=1", b"hi")));

let clean = to_str(http.serialize(http.with_header(base(), "x-ok", "plain value")));
println("clean header kept as is: " + to_str(strings.contains(clean, "x-ok: plain value\r\n")));

// --- httpc requests ---------------------------------------------------------

fn capture_request(ln: link, out: chan[str]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(until_never());
    guard let c = ar else { chan_send(out, ""); return; }
    let a = arena_new(70000);
    let buf = a.wire(65536);
    let mut_c = c;
    let r = mut_c.recv(buf, until_of(time.mono() + 2000000000));
    guard let n = r else { chan_send(out, ""); return; }
    chan_send(out, to_str(buf[0..n]));
    let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    let w = a.wire(len(resp));
    wire_put(w, 0, resp);
    let _s = mut_c.send(w, until_never());
}

let lr = link_listen(0);
guard let ln = lr else { exit(1); }
let port = ln.port();
let seen: chan[str] = make_chan(1);
spawn capture_request(ln, seen);
let req = httpc.new_request("GET", "http://127.0.0.1:" + to_str(port) + "/p");
req.headers["X-Echo"] = evil();
let _resp = httpc.send(req, until_of(time.mono() + 3000000000));
report("httpc request header", chan_recv(seen) ?? "");

// --- http2 ------------------------------------------------------------------

let block = http2.encode_header("x-echo", evil());
let d = http2.decoder_new(4096);
let hs = http2.decode_block(d, block, 16);
guard let fields = hs else let e = err_of(hs) {
    println("http2 decode failed: " + e);
    exit(1);
}
println("http2 value without CR/LF: " + to_str(!strings.contains(fields[0].value, "\r") &&
                                               !strings.contains(fields[0].value, "\n")));
