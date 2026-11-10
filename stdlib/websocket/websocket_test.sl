// Unit tests: `slangc test stdlib/websocket`. Each test runs a scripted
// server in the same program, on an ephemeral port, that reads the
// client's frames byte for byte. The client against independent server
// implementations is tests/live/websocket (Autobahn's fuzzing server).

import "compress";
import "crypto";
import "encoding";
import "net";
import "strings";
import "time";

fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

fn after_ms(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

// ---- the scripted server ------------------------------------------------------------------

gc struct Srv {
    lfd: int,
    port: int,
    fd: int,
    data: bytes,
    pos: int,
    // the request head the client sent
    request: str,
}

fn listen() -> Srv {
    let lr = net.listen(0);
    guard let lfd = lr else let e = err_of(lr) { panic("listen: " + e); }
    let pr = net.port(lfd as int);
    guard let port = pr else let e = err_of(pr) { panic("port: " + e); }
    return Srv { lfd: lfd as int, port: port as int, fd: -1, data: b"", pos: 0, request: "" };
}

fn url_of(s: Srv) -> str {
    return "ws://127.0.0.1:" + to_str(s.port) + "/chat?room=1";
}

fn srv_more(s: Srv) -> bool {
    let r = net.recv_until(s.fd, 65536, soon());
    guard let b = r else { return false; }
    if len(b) == 0 {
        return false;
    }
    let parts: [bytes] = [s.data[s.pos..], b];
    s.data = strings.join_bytes(parts, b"");
    s.pos = 0;
    return true;
}

fn srv_need(s: Srv, n: int) -> bool {
    while len(s.data) - s.pos < n {
        if !srv_more(s) {
            return false;
        }
    }
    return true;
}

// Accepts the connection and reads the request head.
fn srv_accept(s: Srv) -> str {
    let ar = net.accept(s.lfd);
    guard let fd = ar else let e = err_of(ar) { panic("accept: " + e); }
    s.fd = fd as int;
    while true {
        let text = to_str(s.data);
        let end = strings.find(text, "\r\n\r\n");
        if end >= 0 {
            s.request = strings.slice(text, 0, end);
            s.pos = end + 4;
            return s.request;
        }
        if !srv_more(s) {
            panic("server: no request head");
        }
    }
    return "";
}

fn req_header(req: str, name: str) -> str {
    for line in strings.split(req, "\r\n") {
        let colon = strings.find(line, ":");
        if colon > 0 && strings.to_lower(strings.slice(line, 0, colon)) == strings.to_lower(name) {
            return strings.trim(strings.slice(line, colon + 1, len(line)));
        }
    }
    return "";
}

fn srv_send(s: Srv, b: bytes) {
    net.send_until(s.fd, b, soon());
}

// The 101 answer for the request, with extra header lines.
fn srv_upgrade(s: Srv, extra: str) {
    let key = req_header(s.request, "Sec-WebSocket-Key");
    srv_send(s, to_bytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                         "Sec-WebSocket-Accept: " + accept_for(key) + "\r\n" + extra + "\r\n"));
}

// A server frame: unmasked.
fn srv_frame(fin: bool, rsv: int, op: int, payload: bytes) -> bytes {
    let n = len(payload);
    let hl = 2;
    if n > 65535 {
        hl = 10;
    } else if n > 125 {
        hl = 4;
    }
    let h = strings.bytes_zero(hl);
    let b0 = op | (rsv << 4);
    if fin {
        b0 = b0 | 128;
    }
    h[0] = b0;
    if hl == 2 {
        h[1] = n;
    } else if hl == 4 {
        h[1] = 126;
        h[2] = n >> 8;
        h[3] = n & 255;
    } else {
        h[1] = 127;
        for k in 0..8 {
            h[2 + k] = (n >> (56 - 8 * k)) & 255;
        }
    }
    let parts: [bytes] = [h, payload];
    return strings.join_bytes(parts, b"");
}

gc struct CFrame {
    fin: bool,
    rsv: int,
    op: int,
    masked: bool,
    payload: bytes,
}

// A client frame, unmasked here.
fn srv_read_frame(s: Srv) -> opt[CFrame] {
    if !srv_need(s, 2) {
        return none;
    }
    let b0 = s.data[s.pos];
    let b1 = s.data[s.pos + 1];
    let n = b1 & 127;
    let hl = 2;
    if n == 126 {
        hl = 4;
    } else if n == 127 {
        hl = 10;
    }
    let masked = (b1 & 128) != 0;
    let ml = 0;
    if masked {
        ml = 4;
    }
    if !srv_need(s, hl + ml) {
        return none;
    }
    if n == 126 {
        n = (s.data[s.pos + 2] << 8) | s.data[s.pos + 3];
    } else if n == 127 {
        n = 0;
        for k in 0..8 {
            n = (n << 8) | s.data[s.pos + 2 + k];
        }
    }
    if !srv_need(s, hl + ml + n) {
        return none;
    }
    let key = s.data[s.pos + hl..s.pos + hl + ml];
    let raw = s.data[s.pos + hl + ml..s.pos + hl + ml + n];
    s.pos = s.pos + hl + ml + n;
    let payload = raw;
    if masked {
        // unmasked byte by byte here, independently of encoding.xor_mask
        payload = strings.bytes_zero(n);
        for k in 0..n {
            payload[k] = raw[k] ^ key[k % 4];
        }
    }
    return some(CFrame { fin: (b0 & 128) != 0, rsv: (b0 >> 4) & 7, op: b0 & 15, masked: masked, payload: payload });
}

fn close_body(code: int, reason: str) -> bytes {
    let h = strings.bytes_zero(2);
    h[0] = code >> 8;
    h[1] = code & 255;
    let parts: [bytes] = [h, to_bytes(reason)];
    return strings.join_bytes(parts, b"");
}

fn code_of(p: bytes) -> int {
    if len(p) < 2 {
        return -1;
    }
    return (p[0] << 8) | p[1];
}

fn dial_ok(s: Srv, o: Options) -> Conn {
    let r = dial_with(url_of(s), o, soon());
    guard let c = r else let e = err_of(r) { panic("dial: " + e); }
    return c;
}

fn next(c: Conn) -> Message {
    let r = recv(c, soon());
    guard let got = r else let e = err_of(r) { panic("recv: " + e); }
    guard let m = got else { panic("recv: timed out"); }
    return m;
}

fn recv_error(c: Conn) -> str {
    let r = recv(c, soon());
    guard let got = r else let e = err_of(r) { return e; }
    guard let m = got else { return "timed out"; }
    if m.kind == Kind.Close {
        return "close " + to_str(m.code);
    }
    return "message " + text(m);
}

// ---- pure pieces --------------------------------------------------------------------------

fn test_should_compute_the_accept_key_from_rfc_6455() {
    // RFC 6455 section 1.3's worked example
    assert(accept_for("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_for("dGhlIHNhbXBsZSBub25jZQ=="));
}

fn test_should_write_each_length_form_in_its_shortest_encoding() {
    let key = b"abcd";
    assert(encoding.hex_encode(frame_head(true, false, 1, 0, key)) == "818061626364", "0");
    assert(encoding.hex_encode(frame_head(true, false, 2, 125, key)) == "82fd61626364", "125");
    assert(encoding.hex_encode(frame_head(true, false, 1, 126, key)) == "81fe007e61626364", "126");
    assert(encoding.hex_encode(frame_head(true, true, 1, 65535, key)) == "c1feffff61626364", "65535 with rsv1");
    assert(encoding.hex_encode(frame_head(true, false, 2, 65536, key)) == "82ff000000000001000061626364", "65536");
    assert(encoding.hex_encode(frame_head(true, false, 9, 3, key)) == "898361626364", "ping");
}

fn test_should_mask_like_the_byte_at_a_time_definition() {
    let data = strings.bytes_zero(1000);
    for k in 0..1000 {
        data[k] = (k * 37 + 11) & 255;
    }
    for kl in [1, 2, 3, 4, 5, 8] {
        let key = strings.bytes_zero(kl);
        for k in 0..kl {
            key[k] = 200 + k;
        }
        for n in [0, 1, 7, 8, 9, 15, 16, 17, 999, 1000] {
            let d = data[0..n];
            let got = encoding.xor_mask(b"HD", d, key);
            assert(len(got) == n + 2 && got[0] == 72 && got[1] == 68, "head");
            for k in 0..n {
                assert(got[2 + k] == (d[k] ^ key[k % kl]), "byte " + to_str(k) + " key " + to_str(kl));
            }
        }
    }
    assert(to_str(encoding.xor_mask(b"", b"same", b"")) == "same", "empty key copies");
}

fn test_should_refuse_bad_urls_and_options() {
    let cases = ["http://x/", "ws://", "ws://h/#frag", "wss://u:p@h/", "ws://h:99999/"];
    for u in cases {
        let r = dial(u, soon());
        guard let _c = r else let e = err_of(r) {
            assert(strings.has_prefix(e, "websocket: "), e);
            continue;
        }
        panic("accepted " + u);
    }
    let o = options();
    o.protocols = ["bad name"];
    assert(strings.contains(err_of(dial_with("ws://127.0.0.1:1/", o, soon())), "subprotocol"), "protocol token");
    let o2 = options();
    o2.headers = ["X-Evil: a\r\nInjected: b"];
    assert(strings.contains(err_of(dial_with("ws://127.0.0.1:1/", o2, soon())), "bad header"), "header injection");
}

// ---- the opening handshake ------------------------------------------------------------------

fn hs_server(s: Srv, extra: str, done: chan[str]) {
    let req = srv_accept(s);
    srv_upgrade(s, extra);
    chan_send(done, req);
    // hold the connection until the client goes
    srv_read_frame(s);
    net.close(s.fd);
}

fn test_should_send_a_complete_opening_handshake() {
    let s = listen();
    let done: chan[str] = make_chan(1);
    spawn hs_server(s, "Sec-WebSocket-Protocol: v2.chat\r\n", done);
    let o = options();
    o.protocols = ["v1.chat", "v2.chat"];
    o.origin = "https://app.example";
    o.headers = ["Authorization: Bearer t0k"];
    let c = dial_ok(s, o);
    let req = chan_recv(done) ?? "";
    assert(strings.has_prefix(req, "GET /chat?room=1 HTTP/1.1\r\n"), req);
    assert(req_header(req, "Host") == "127.0.0.1:" + to_str(s.port), "host");
    assert(strings.to_lower(req_header(req, "Upgrade")) == "websocket", "upgrade");
    assert(strings.to_lower(req_header(req, "Connection")) == "upgrade", "connection");
    assert(req_header(req, "Sec-WebSocket-Version") == "13", "version");
    let key = req_header(req, "Sec-WebSocket-Key");
    let kr = encoding.base64_decode(key);
    guard let kb = kr else { panic("key is not base64"); }
    assert(len(kb) == 16, "a 16-byte nonce");
    assert(req_header(req, "Sec-WebSocket-Protocol") == "v1.chat, v2.chat", "protocols");
    assert(req_header(req, "Origin") == "https://app.example", "origin");
    assert(req_header(req, "Authorization") == "Bearer t0k", "custom header");
    assert(req_header(req, "Sec-WebSocket-Extensions") == "", "no extensions unless asked");
    assert(c.protocol == "v2.chat", c.protocol);
    close_now(c);
}

fn bad_answer(answer: str, done: chan[bool], s: Srv) {
    srv_accept(s);
    let key = req_header(s.request, "Sec-WebSocket-Key");
    srv_send(s, to_bytes(strings.replace(answer, "ACCEPT", accept_for(key))));
    time.sleep(100000000);
    net.close(s.fd);
    chan_send(done, true);
}

fn handshake_error(answer: str, o: Options) -> str {
    let s = listen();
    let done: chan[bool] = make_chan(1);
    spawn bad_answer(answer, done, s);
    let r = dial_with(url_of(s), o, soon());
    chan_recv(done);
    net.close(s.lfd);
    guard let c = r else let e = err_of(r) { return e; }
    close_now(c);
    return "accepted";
}

fn test_should_refuse_a_handshake_answer_that_is_wrong() {
    let o = options();
    let ok_head = "HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ACCEPT\r\n";
    assert(handshake_error(ok_head + "\r\n", o) == "accepted", "the good answer");
    assert(strings.contains(handshake_error("HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                                            "Sec-WebSocket-Accept: AAAA\r\n\r\n", o), "does not match"), "accept");
    assert(strings.contains(handshake_error("HTTP/1.1 302 Found\r\nLocation: wss://elsewhere/\r\n\r\n", o),
                            "redirect to wss://elsewhere/"), "redirect");
    assert(strings.contains(handshake_error("HTTP/1.1 101 OK\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n" +
                                            "Sec-WebSocket-Accept: ACCEPT\r\n\r\n", o), "Upgrade header"), "upgrade");
    assert(strings.contains(handshake_error("HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nConnection: keep-alive\r\n" +
                                            "Sec-WebSocket-Accept: ACCEPT\r\n\r\n", o), "Connection header"), "connection");
    assert(strings.contains(handshake_error(ok_head + "Sec-WebSocket-Protocol: other\r\n\r\n", o), "not offered"), "protocol");
    assert(strings.contains(handshake_error(ok_head + "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n", o),
                            "not offered"), "extension not offered");
    let oc = options();
    oc.compress = true;
    assert(strings.contains(handshake_error(ok_head + "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n", oc),
                            "server_no_context_takeover"), "context takeover");
    assert(strings.contains(handshake_error(ok_head + "Sec-WebSocket-Extensions: permessage-deflate; " +
                                            "server_no_context_takeover; client_max_window_bits=10\r\n\r\n", oc),
                            "not offered"), "client window");
    assert(handshake_error(ok_head + "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; " +
                           "client_no_context_takeover; server_max_window_bits=12\r\n\r\n", oc) == "accepted",
           "an acceptable deflate answer");
    assert(strings.contains(handshake_error("SSH-2.0-OpenSSH\r\n\r\n", o), "not an HTTP response"), "not http");
}

// ---- messages both ways -------------------------------------------------------------------

fn echo_server(s: Srv, frames: chan[CFrame]) {
    srv_accept(s);
    srv_upgrade(s, "");
    while true {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        chan_send(frames, f);
        if f.op == 8 {
            srv_send(s, srv_frame(true, 0, 8, f.payload));
            break;
        }
        srv_send(s, srv_frame(true, 0, f.op, f.payload));
    }
    net.close(s.fd);
}

fn test_should_echo_messages_of_every_length_form() {
    let s = listen();
    let frames: chan[CFrame] = make_chan(64);
    spawn echo_server(s, frames);
    let c = dial_ok(s, options());
    let sizes = [0, 1, 125, 126, 127, 65535, 65536, 1048576];
    for n in sizes {
        let payload = strings.bytes_zero(n);
        for k in 0..n {
            payload[k] = (k * 7 + n) & 255;
        }
        let wr = send_binary(c, payload, soon());
        guard let _w = wr else let e = err_of(wr) { panic(e); }
        let f = chan_recv(frames) ?? CFrame { fin: false, rsv: 0, op: 0, masked: false, payload: b"" };
        assert(f.masked && f.fin && f.op == 2 && f.rsv == 0, "a whole masked binary frame of " + to_str(n));
        assert(len(f.payload) == n && f.payload == payload, "payload of " + to_str(n));
        let m = next(c);
        assert(m.kind == Kind.Binary && m.data == payload, "echo of " + to_str(n));
    }
    send_text(c, "héllo ☃", soon());
    let ft = chan_recv(frames) ?? CFrame { fin: false, rsv: 0, op: 0, masked: false, payload: b"" };
    assert(ft.op == 1 && to_str(ft.payload) == "héllo ☃", "text frame");
    let mt = next(c);
    assert(mt.kind == Kind.Text && text(mt) == "héllo ☃", text(mt));
    let cr = close(c, 1000, "done", soon());
    guard let _cl = cr else let e = err_of(cr) { panic(e); }
    let fc = chan_recv(frames) ?? CFrame { fin: false, rsv: 0, op: 0, masked: false, payload: b"" };
    assert(fc.op == 8 && code_of(fc.payload) == 1000 && to_str(fc.payload[2..]) == "done", "close frame");
    assert(!is_open(c), "closed");
    assert(strings.contains(err_of(send_text(c, "late", soon())), "closed"), "send after close");
}

fn masks_server(s: Srv, keys: chan[str]) {
    srv_accept(s);
    srv_upgrade(s, "");
    for k in 0..200 {
        // the mask key is the 4 bytes after a short header
        if !srv_need(s, 6) {
            break;
        }
        push_key(keys, encoding.hex_encode(s.data[s.pos + 2..s.pos + 6]));
        srv_read_frame(s);
    }
    net.close(s.fd);
}

fn push_key(keys: chan[str], k: str) {
    chan_send(keys, k);
}

fn test_should_mask_every_frame_with_a_fresh_key() {
    let s = listen();
    let keys: chan[str] = make_chan(256);
    spawn masks_server(s, keys);
    let c = dial_ok(s, options());
    for k in 0..200 {
        send_text(c, "x", soon());
    }
    let seen: map[str]bool = {};
    for k in 0..200 {
        seen[chan_recv(keys) ?? ""] = true;
    }
    // 200 random 32-bit keys collide with odds of about 5 in a million
    assert(len(seen) >= 199, to_str(len(seen)));
    close_now(c);
}

// ---- what the server sends ------------------------------------------------------------------

fn script_server(s: Srv, out: bytes, frames: chan[CFrame]) {
    srv_accept(s);
    srv_upgrade(s, "");
    srv_send(s, out);
    while true {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        chan_send(frames, f);
        if f.op == 8 {
            break;
        }
    }
    net.close(s.fd);
}

fn scripted(out: bytes) -> Conn {
    let s = listen();
    let frames: chan[CFrame] = make_chan(16);
    spawn script_server(s, out, frames);
    return dial_ok(s, options());
}

gc struct Scripted {
    c: Conn,
    frames: chan[CFrame],
}

fn scripted_with(out: bytes, o: Options) -> Scripted {
    let s = listen();
    let frames: chan[CFrame] = make_chan(16);
    spawn script_server(s, out, frames);
    return Scripted { c: dial_ok(s, o), frames: frames };
}

fn cat(xs: [bytes]) -> bytes {
    return strings.join_bytes(xs, b"");
}

fn frame_from(frames: chan[CFrame]) -> CFrame {
    return chan_recv(frames) ?? CFrame { fin: false, rsv: 0, op: -1, masked: false, payload: b"" };
}

fn test_should_reassemble_fragments_and_answer_pings_between_them() {
    let out = cat([srv_frame(false, 0, 1, b"frag"), srv_frame(true, 0, 9, b"are you there"),
                   srv_frame(false, 0, 0, b"men"), srv_frame(true, 0, 0, b"ted"),
                   srv_frame(true, 0, 10, b"unsolicited pong"), srv_frame(true, 0, 2, b"\x00\x01")]);
    let sc = scripted_with(out, options());
    let m = next(sc.c);
    assert(m.kind == Kind.Text && text(m) == "fragmented", text(m));
    let pong = frame_from(sc.frames);
    assert(pong.op == 10 && to_str(pong.payload) == "are you there" && pong.masked, "pong echoes the ping");
    let b = next(sc.c);
    assert(b.kind == Kind.Binary && len(b.data) == 2, "the pong is consumed, the next message arrives");
    close_now(sc.c);
}

fn test_should_return_the_servers_close_and_answer_it() {
    let sc = scripted_with(cat([srv_frame(true, 0, 1, b"last words"), srv_frame(true, 0, 8, close_body(1001, "going away"))]),
                           options());
    assert(text(next(sc.c)) == "last words", "data before the close");
    let m = next(sc.c);
    assert(m.kind == Kind.Close && m.code == 1001 && m.reason == "going away", m.reason);
    let echo = frame_from(sc.frames);
    assert(echo.op == 8 && code_of(echo.payload) == 1001, "the close is answered with its code");
    assert(strings.contains(recv_error(sc.c), "closed by the server (1001 going away)"), recv_error(sc.c));
    assert(!is_open(sc.c), "closed");
    // an empty close is code 1005 and is answered empty
    let sc2 = scripted_with(srv_frame(true, 0, 8, b""), options());
    let m2 = next(sc2.c);
    assert(m2.kind == Kind.Close && m2.code == 1005, to_str(m2.code));
    assert(len(frame_from(sc2.frames).payload) == 0, "empty answer");
}

fn violation(out: bytes, o: Options) -> str {
    let sc = scripted_with(out, o);
    let e = recv_error(sc.c);
    let f = frame_from(sc.frames);
    return e + " | " + to_str(code_of(f.payload));
}

fn test_should_fail_the_connection_on_protocol_violations() {
    let o = options();
    let masked = cat([b"\x81\x82abcd", b"\x00\x00"]);
    assert(strings.contains(violation(masked, o), "must not be masked | 1002"), violation(masked, o));
    let v2 = violation(srv_frame(true, 2, 1, b"x"), o);
    assert(strings.contains(v2, "reserved bit is set | 1002"), v2);
    assert(strings.contains(violation(srv_frame(true, 4, 1, b"x"), o), "RSV1 set without a compressed message | 1002"), "rsv1 without deflate");
    assert(strings.contains(violation(srv_frame(true, 0, 3, b"x"), o), "unknown opcode 3 | 1002"), "opcode 3");
    assert(strings.contains(violation(srv_frame(true, 0, 11, b""), o), "unknown opcode 11 | 1002"), "opcode 11");
    assert(strings.contains(violation(srv_frame(false, 0, 9, b"x"), o), "at most 125 bytes | 1002"), "fragmented ping");
    assert(strings.contains(violation(srv_frame(true, 0, 9, strings.bytes_zero(126)), o), "at most 125 bytes | 1002"), "long ping");
    assert(strings.contains(violation(srv_frame(true, 0, 0, b"x"), o), "no message to continue | 1002"), "lone continuation");
    assert(strings.contains(violation(cat([srv_frame(false, 0, 1, b"a"), srv_frame(true, 0, 1, b"b")]), o),
                            "before the last one finished | 1002"), "interleaved messages");
    assert(strings.contains(violation(srv_frame(true, 0, 1, b"\xff\xfe"), o), "not UTF-8 | 1007"), "bad utf-8");
    assert(strings.contains(violation(srv_frame(true, 0, 8, b"\x03"), o), "one-byte body | 1002"), "short close");
    assert(strings.contains(violation(srv_frame(true, 0, 8, close_body(1005, "")), o), "close code 1005 is not one a peer may send | 1002"), "1005");
    assert(strings.contains(violation(srv_frame(true, 0, 8, close_body(2000, "")), o), "close code 2000 is not one a peer may send | 1002"), "2000");
    assert(strings.contains(violation(srv_frame(true, 0, 8, cat([close_body(1000, ""), b"\xff"])), o), "not UTF-8 | 1007"),
           "close reason");
    assert(strings.contains(violation(b"\x81\x7e\x00\x05hello", o), "shortest form | 1002"), "16-bit length for 5");
    let small = options();
    small.max_message = 100;
    assert(strings.contains(violation(srv_frame(true, 0, 2, strings.bytes_zero(101)), small), "over 100 bytes | 1009"), "max");
    assert(strings.contains(violation(cat([srv_frame(false, 0, 2, strings.bytes_zero(60)), srv_frame(true, 0, 0, strings.bytes_zero(60))]),
                                      small), "over 100 bytes | 1009"), "max across fragments");
}

fn test_should_accept_utf8_split_across_fragments() {
    let sc = scripted_with(cat([srv_frame(false, 0, 1, b"\xe2\x98"), srv_frame(true, 0, 0, b"\x83")]), options());
    assert(text(next(sc.c)) == "☃", "a character split between frames");
    close_now(sc.c);
}

// ---- deadlines --------------------------------------------------------------------------

fn slow_server(s: Srv, go: chan[bool]) {
    srv_accept(s);
    srv_upgrade(s, "");
    let f = srv_frame(true, 0, 1, to_bytes(strings.repeat("z", 1000)));
    // half a frame, then the rest when told
    srv_send(s, f[0..500]);
    chan_recv(go);
    srv_send(s, f[500..]);
    srv_read_frame(s);
    net.close(s.fd);
}

fn test_should_resume_after_a_deadline_passes_mid_frame() {
    let s = listen();
    let go: chan[bool] = make_chan(1);
    spawn slow_server(s, go);
    let c = dial_ok(s, options());
    let r = recv(c, after_ms(100));
    guard let got = r else let e = err_of(r) { panic(e); }
    guard let _early = got else {
        chan_send(go, true);
        let m = next(c);
        assert(text(m) == strings.repeat("z", 1000), "the frame read across the deadline is whole");
        close_now(c);
        return;
    }
    panic("a message arrived before it was whole");
}

// ---- compression ------------------------------------------------------------------------

fn deflate_server(s: Srv, out: bytes, frames: chan[CFrame]) {
    srv_accept(s);
    srv_upgrade(s, "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n");
    srv_send(s, out);
    while true {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        chan_send(frames, f);
        if f.op == 8 {
            break;
        }
    }
    net.close(s.fd);
}

// A deflate stream ending at a sync flush, as RFC 7692 servers send it:
// one stored block, not final, then the empty stored block a sync flush
// adds, of which only the 3 header bits (padded to a byte) are left once
// its trailing 00 00 ff ff is removed.
fn stored_block(data: bytes) -> bytes {
    let n = len(data);
    let h = strings.bytes_zero(5);
    h[0] = 0;
    h[1] = n & 255;
    h[2] = n >> 8;
    h[3] = (n & 255) ^ 255;
    h[4] = (n >> 8) ^ 255;
    return cat([h, data, b"\x00"]);
}

fn test_should_inflate_and_deflate_with_permessage_deflate() {
    let s = listen();
    let frames: chan[CFrame] = make_chan(16);
    let big = to_bytes(strings.repeat("compressible text ", 500));
    let zr = compress.deflate_raw(big);
    guard let z = zr else let e = err_of(zr) { panic(e); }
    let out = cat([srv_frame(true, 4, 1, stored_block(b"sync flushed")), srv_frame(true, 4, 1, z),
                   srv_frame(false, 4, 2, z[0..10]), srv_frame(true, 0, 0, z[10..]),
                   srv_frame(true, 0, 1, b"plain")]);
    spawn deflate_server(s, out, frames);
    let o = options();
    o.compress = true;
    let c = dial_ok(s, o);
    assert(c.deflate, "negotiated");
    assert(text(next(c)) == "sync flushed", "a stream that ends at a sync flush");
    assert(next(c).data == big, "a stream that ends with a final block");
    let frag = next(c);
    assert(frag.kind == Kind.Binary && frag.data == big, "compressed and fragmented");
    assert(text(next(c)) == "plain", "an uncompressed message on the same connection");
    // sending: compressed when it helps, RSV1 set
    send_binary(c, big, soon());
    let f = frame_from(frames);
    assert(f.rsv == 4 && len(f.payload) < len(big), "compressed on the wire");
    let back = compress.inflate_raw(cat([f.payload, deflate_tail()]), 1000000) ?? b"";
    assert(back == big, "what was sent inflates to the message");
    send_text(c, "tiny", soon());
    let t = frame_from(frames);
    assert(t.rsv == 0 && to_str(t.payload) == "tiny", "short messages go uncompressed");
    close_now(c);
}

fn test_should_bound_a_compressed_message_after_inflating() {
    let s = listen();
    let frames: chan[CFrame] = make_chan(16);
    let bomb = strings.bytes_zero(1000000);
    let zr = compress.deflate_raw(bomb);
    guard let z = zr else let e = err_of(zr) { panic(e); }
    spawn deflate_server(s, srv_frame(true, 4, 2, z), frames);
    let o = options();
    o.compress = true;
    o.max_message = 4096;
    let c = dial_ok(s, o);
    let e = recv_error(c);
    assert(strings.contains(e, "did not inflate"), e);
    let f = frame_from(frames);
    assert(f.op == 8 && (code_of(f.payload) == 1009 || code_of(f.payload) == 1007), to_str(code_of(f.payload)));
}

// ---- keepalive and concurrency ----------------------------------------------------------

fn silent_server(s: Srv, pings: chan[int]) {
    srv_accept(s);
    srv_upgrade(s, "");
    let n = 0;
    while true {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        if f.op == 9 {
            n += 1;
        }
    }
    chan_send(pings, n);
    net.close(s.fd);
}

fn test_should_drop_a_connection_whose_pings_go_unanswered() {
    let s = listen();
    let pings: chan[int] = make_chan(1);
    spawn silent_server(s, pings);
    let o = options();
    o.ping_every = 100000000;
    let c = dial_ok(s, o);
    let e = recv_error(c);
    assert(strings.contains(e, "no pong within 100 ms"), e);
    assert((chan_recv(pings) ?? 0) >= 1, "pinged");
}

fn pong_server(s: Srv, done: chan[int]) {
    srv_accept(s);
    srv_upgrade(s, "");
    let n = 0;
    while n < 3 {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        if f.op == 9 {
            n += 1;
            srv_send(s, srv_frame(true, 0, 10, f.payload));
        }
    }
    srv_send(s, srv_frame(true, 0, 1, b"still here"));
    chan_send(done, n);
    srv_read_frame(s);
    net.close(s.fd);
}

fn test_should_keep_a_connection_whose_pings_are_answered() {
    let s = listen();
    let done: chan[int] = make_chan(1);
    spawn pong_server(s, done);
    let o = options();
    o.ping_every = 50000000;
    let c = dial_ok(s, o);
    assert(text(next(c)) == "still here", "alive after three pings");
    assert((chan_recv(done) ?? 0) == 3, "three pings answered");
    close_now(c);
}

fn sender(c: Conn, id: int, done: chan[bool]) {
    for k in 0..50 {
        send_text(c, "task " + to_str(id) + " message " + to_str(k), soon());
    }
    chan_send(done, true);
}

fn counting_server(s: Srv, total: int, got: chan[int]) {
    srv_accept(s);
    srv_upgrade(s, "");
    let n = 0;
    while n < total {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        if f.op == 1 && f.masked && strings.has_prefix(to_str(f.payload), "task ") {
            n += 1;
        }
    }
    chan_send(got, n);
    net.close(s.fd);
}

fn test_should_keep_frames_whole_when_many_tasks_send() {
    let s = listen();
    let got: chan[int] = make_chan(1);
    spawn counting_server(s, 400, got);
    let c = dial_ok(s, options());
    let done: chan[bool] = make_chan(8);
    for t in 0..8 {
        spawn sender(c, t, done);
    }
    for t in 0..8 {
        chan_recv(done);
    }
    assert((chan_recv(got) ?? 0) == 400, "every frame parsed whole");
    close_now(c);
}

fn reader_task(c: Conn, out: chan[str]) {
    let r = recv(c, soon());
    guard let got = r else let e = err_of(r) {
        chan_send(out, "error " + e);
        return;
    }
    guard let m = got else {
        chan_send(out, "timeout");
        return;
    }
    if m.kind == Kind.Close {
        chan_send(out, "close " + to_str(m.code));
        return;
    }
    chan_send(out, "message");
}

fn closing_echo(s: Srv) {
    srv_accept(s);
    srv_upgrade(s, "");
    while true {
        let fr = srv_read_frame(s);
        guard let f = fr else { break; }
        if f.op == 8 {
            srv_send(s, srv_frame(true, 0, 8, f.payload));
            break;
        }
    }
    net.close(s.fd);
}

fn test_should_close_while_another_task_is_reading() {
    let s = listen();
    spawn closing_echo(s);
    let c = dial_ok(s, options());
    let out: chan[str] = make_chan(1);
    spawn reader_task(c, out);
    time.sleep(50000000);
    let cr = close(c, 4000, "app shutdown", soon());
    guard let _c = cr else let e = err_of(cr) { panic(e); }
    let seen = chan_recv(out) ?? "";
    assert(seen == "close 4000", seen);
    assert(!is_open(c), "closed");
    let again = close(c, 1000, "", soon());
    guard let _a = again else let e = err_of(again) { panic("closing twice: " + e); }
    assert(strings.contains(err_of(close(c, 1006, "", soon())), "cannot be sent"), "1006 is never sent");
}

// A text message that goes bad in its first fragment is refused then,
// before the server sends the rest (it never does here).
fn test_should_refuse_bad_utf8_in_a_fragment_before_the_message_ends() {
    let cases = [b"ok \xff", b"ok \xf4\x90", b"\xc0", b"\xed\xa0"];
    for p in cases {
        let v = violation(srv_frame(false, 0, 1, p), options());
        assert(strings.contains(v, "not UTF-8 | 1007"), encoding.hex_encode(p) + ": " + v);
    }
    // an unfinished but possible character waits for the next fragment
    let sc = scripted_with(cat([srv_frame(false, 0, 1, b"\xf0\x9f"), srv_frame(false, 0, 0, b"\x98"),
                               srv_frame(true, 0, 0, b"\x80!")]), options());
    assert(text(next(sc.c)) == "😀!", "a character in three fragments");
    close_now(sc.c);
    // and the last fragment may not leave one unfinished
    let v = violation(cat([srv_frame(false, 0, 1, b"a"), srv_frame(true, 0, 0, b"\xe2\x98")]), options());
    assert(strings.contains(v, "not UTF-8 | 1007"), v);
}

fn test_should_send_text_bytes_with_nul_and_refuse_invalid_utf8() {
    let s = listen();
    let frames: chan[CFrame] = make_chan(8);
    spawn echo_server(s, frames);
    let c = dial_ok(s, options());
    let wr = send_text_bytes(c, b"a\x00b", soon());
    guard let _w = wr else let e = err_of(wr) { panic(e); }
    let f = frame_from(frames);
    assert(f.op == 1 && f.payload == b"a\x00b", "the NUL is sent");
    let m = next(c);
    assert(m.kind == Kind.Text && m.data == b"a\x00b" && text(m) == "a", "data keeps it; text() stops at it");
    assert(strings.contains(err_of(send_text_bytes(c, b"\xff", soon())), "must be UTF-8"), "invalid");
    close_now(c);
}
