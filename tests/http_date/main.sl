// Every response carries Date (RFC 9110 6.6.1), current to the second, on
// every write path: the fast shape, the general one, both serializers, a
// prebuilt static rendering (its date filled in on each send) and HTTP/2.
// A handler's handler_dated Date is the one sent. 1xx, 204 and 304 carry neither
// Content-Length nor body bytes (RFC 9110 6.4.1, 8.6), even when the
// Response holds a body.
import "http";
import "http2";
import "strings";
import "time";
import "timez";

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// The Date value of a serialized response, "" when there is none.
fn date_of(raw: str) -> str {
    let head_end = strings.find(raw, "\r\n\r\n");
    let head = strings.slice(raw, 0, head_end);
    let n = 0;
    let found = "";
    for line in strings.split(head, "\r\n") {
        if strings.has_prefix(strings.to_lower(line), "date:") {
            n = n + 1;
            found = strings.trim(strings.slice(line, 5, len(line)));
        }
    }
    if n > 1 {
        fail("more than one Date line: " + head);
    }
    return found;
}

fn check_current(label: str, raw: str) {
    let d = date_of(raw);
    let r = timez.parse_http_date(d);
    guard let t = r else {
        fail(label + ": no valid Date: '" + d + "'");
        return;
    }
    let lag = timez.now().unix() - t.unix();
    if lag < 0 || lag > 2 {
        fail(label + ": Date is not current: " + d);
    }
    if len(d) != 29 {
        fail(label + ": Date is not an IMF-fixdate: " + d);
    }
}

fn no_content_framing(label: str, raw: str) {
    if strings.contains(strings.to_lower(raw), "content-length") {
        fail(label + ": Content-Length on a response with no content");
    }
    if !strings.has_suffix(raw, "\r\n\r\n") {
        fail(label + ": body bytes after the head");
    }
}

// What http.write puts on a real connection.
fn written(c: &mut link, s: &mut link, r: http.Response) -> str {
    let sa = arena_new(16384);
    let wr = http.write(c, r, &mut sa, until_never());
    guard let _n = wr else { fail("write"); }
    return received(s);
}

fn written_static(c: &mut link, s: &mut link, b: http.StaticBody, close: bool) -> str {
    let sa = arena_new(16384);
    let wr = http.write_static(c, b, &mut sa, close, until_never());
    guard let _n = wr else { fail("write_static"); }
    return received(s);
}

// Reads until the head is complete and the body Content-Length names (or
// none) has arrived.
fn received(s: &mut link) -> str {
    let ra = arena_new(16384);
    let inb = ra.wire(16384);
    let got = 0;
    while true {
        let rr = s.recv(inb[got..], until_of(time.mono() + 2000000000));
        guard let n = rr else { fail("recv"); }
        if n == 0 { fail("closed"); }
        got = got + n;
        let text = to_str(to_bytes(inb[0..got]));
        let he = strings.find(text, "\r\n\r\n");
        if he >= 0 {
            let want = he + 4;
            let lower = strings.to_lower(text);
            let at = strings.find(lower, "content-length: ");
            if at >= 0 && at < he {
                let eol = strings.find(strings.slice(lower, at, he + 2), "\r\n");
                let cl = to_int(strings.slice(lower, at + 16, at + eol)) ?? 0;
                want = want + cl;
            }
            if got >= want {
                return text;
            }
        }
    }
    return "";
}

let lr = link_listen(0);
guard let ln = lr else { fail("listen"); }
let dr = link_dial("127.0.0.1", ln.port(), until_never());
guard let c = dr else { fail("dial"); }
let ar = ln.accept(until_never());
guard let s = ar else { fail("accept"); }

// the fast shape (text_response) and the general one (extra headers)
check_current("fast", written(&mut c, &mut s, http.ok_json("{}")));
check_current("general", written(&mut c, &mut s, http.with_header(http.ok_json("{}"), "x-a", "1")));
check_current("serialize_sized", to_str(http.serialize_sized(http.ok_text("x"))));
check_current("serialize_builder", to_str(http.serialize_builder(http.ok_text("x"))));
println("date on every write path");

// a handler's handler_dated Date wins, written once
let handler_dated = http.with_header(http.ok_text("x"), "Date", "Wed, 14 Oct 2026 17:46:40 GMT");
if date_of(written(&mut c, &mut s, handler_dated)) != "Wed, 14 Oct 2026 17:46:40 GMT" {
    fail("handler's Date replaced");
}
if date_of(to_str(http.serialize(handler_dated))) != "Wed, 14 Oct 2026 17:46:40 GMT" {
    fail("handler's Date replaced by serialize");
}
println("a handler's Date is kept");

// no content: no Content-Length, no body, whatever the Response holds
let nc = http.text_response(204, "No Content", "", "ignored body");
no_content_framing("204 fast", written(&mut c, &mut s, nc));
no_content_framing("204 general", written(&mut c, &mut s, http.with_header(nc, "x-a", "1")));
no_content_framing("204 serialize", to_str(http.serialize(nc)));
no_content_framing("204 builder", to_str(http.serialize_builder(nc)));
let nm = http.with_header(http.text_response(304, "Not Modified", "", "stale"), "etag", "\"v1\"");
let nmw = written(&mut c, &mut s, nm);
no_content_framing("304", nmw);
check_current("304", nmw);
// the connection is still in step: the next response reads cleanly
if !strings.has_suffix(written(&mut c, &mut s, http.ok_text("after")), "after") {
    fail("next response after a 304 is misframed");
}
println("204 and 304 carry no content");

// static renderings: the date is filled in on every send, never frozen
let body = to_bytes("static body");
let ka = http.static_render(200, "text/plain", body);
let sb = http.StaticBody { status: 200, content_type: "text/plain", body: body, keep_alive: ka };
let first = written_static(&mut c, &mut s, sb, false);
check_current("static", first);
if !strings.has_suffix(first, "static body") {
    fail("static body");
}
time.sleep(1100000000);
let second = written_static(&mut c, &mut s, sb, false);
check_current("static, a second later", second);
if date_of(first) == date_of(second) {
    fail("static Date frozen at render time");
}
check_current("static close", written_static(&mut c, &mut s, sb, true));
// a rendering made elsewhere, without the date line, is sent as it is
let plain = to_bytes("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nContent-Length: 2\r\n\r\nhi");
let pb = http.StaticBody { status: 200, content_type: "text/plain", body: to_bytes("hi"), keep_alive: plain };
if written_static(&mut c, &mut s, pb, false) != to_str(plain) {
    fail("a rendering without the date line was changed");
}
let nc_static = http.static_render(204, "text/plain", to_bytes("x"));
let ncb = http.StaticBody { status: 204, content_type: "text/plain", body: to_bytes("x"), keep_alive: nc_static };
let ncw = written_static(&mut c, &mut s, ncb, false);
no_content_framing("static 204", ncw);
check_current("static 204", ncw);
println("static renderings get a fresh date");

// HTTP/2
let m = http2.response_msg(1, "200", [http2.Header { name: "x-a", value: "1" }], to_bytes("hi"));
let d = http2.decoder_new(4096);
let hr = http2.decode_block(d, m.head[9..], 64);
guard let hs = hr else { fail("h2 decode"); }
let h2date = "";
let h2len = "";
for h in hs {
    if h.name == "date" { h2date = h.value; }
    if h.name == "content-length" { h2len = h.value; }
}
check_current("h2", "date: " + h2date + "\r\n\r\n");
if h2len != "2" { fail("h2 content-length " + h2len); }
let m304 = http2.response_msg(3, "304", [], to_bytes("stale"));
let d2 = http2.decoder_new(4096);
let hr2 = http2.decode_block(d2, m304.head[9..], 64);
guard let hs2 = hr2 else { fail("h2 304 decode"); }
for h in hs2 {
    if h.name == "content-length" { fail("h2 304 has content-length"); }
}
if len(m304.body) != 0 { fail("h2 304 has a body"); }
println("http2 too");
