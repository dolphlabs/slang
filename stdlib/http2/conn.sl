// HTTP/2 connection and stream layer (RFC 9113).
//
// A connection is: verify the client preface, exchange SETTINGS, then
// read frames forever. Requests arrive as HEADERS (possibly continued
// by CONTINUATION frames) followed by zero or more DATA frames, ending
// when END_STREAM is seen.
//
// Streams are handled one complete request at a time. That is
// conformant -- a server may process requests in any order, including
// serially -- and it keeps a single task per connection with no writer
// lock. True concurrent stream processing needs a serialised writer and
// is deliberately left for later rather than half-built here.

pub let DEFAULT_MAX_FRAME = 16384;
pub let DEFAULT_WINDOW = 65535;
// Our own limits, advertised in SETTINGS and enforced on receipt.
pub let MAX_HEADER_FIELDS = 128;
pub let MAX_BODY = 1048576;

pub gc struct Conn {
    dec: Decoder,
    // what the PEER told us it will accept
    peer_max_frame: int,
    // connection-level receive window we still have outstanding
    recv_window: int,
    last_stream: int,
    gone: bool,
}

pub gc struct Req {
    stream: int,
    method: str,
    path: str,
    scheme: str,
    authority: str,
    headers: [Header],
    body: bytes,
}

pub fn conn_new() -> Conn {
    return Conn {
        dec: decoder_new(4096),
        peer_max_frame: DEFAULT_MAX_FRAME,
        recv_window: DEFAULT_WINDOW,
        last_stream: 0,
        gone: false
    };
}

// Our SETTINGS: a modest frame size, and push disabled because server
// push is deprecated and no current client wants it.
pub fn our_settings() -> bytes {
    let ids = [S_MAX_FRAME_SIZE, S_ENABLE_PUSH, S_MAX_CONCURRENT_STREAMS,
               S_MAX_HEADER_LIST_SIZE];
    let vals = [DEFAULT_MAX_FRAME, 0, 100, 16384];
    return settings_frame(ids, vals);
}

// ---- buffered frame reader ------------------------------------------
//
// Frames straddle recv boundaries, so bytes are accumulated until a
// whole frame is present. `buf` carries the leftover between calls.

pub gc struct Reader {
    buf: bytes,
}

pub fn reader_new() -> Reader {
    return Reader { buf: b"" };
}

fn wire_to_bytes(w: wire, n: int) -> bytes {
    let out = b"";
    let i = 0;
    while i < n {
        out = out + to_le(w[i])[0..1];
        i = i + 1;
    }
    return out;
}

// Pull bytes until at least one complete frame is buffered, then return
// it and keep the remainder.
// Note the `&mut *c` at every site below that forwards this borrow:
// passing `c` directly MOVES it, so the second call would fail with
// "use of moved value". Reborrowing keeps the caller's borrow usable.
pub fn read_frame(r: Reader, c: &mut link, scratch: wire, max_frame: int,
                  deadline: until) -> result[Frame, str] {
    while true {
        if len(r.buf) >= FRAME_HEADER_LEN {
            let plen = be24(r.buf, 0);
            if plen > max_frame {
                return err("peer sent a frame larger than our max frame size");
            }
            let total = FRAME_HEADER_LEN + plen;
            if len(r.buf) >= total {
                let fr = decode(r.buf, 0, max_frame);
                guard let f = fr else let e = err_of(fr) {
                    return err(e);
                }
                r.buf = r.buf[total..];
                return ok(f);
            }
        }
        let rr = c.recv(scratch, deadline);
        guard let n = rr else let e = err_of(rr) {
            return err("recv: " + to_str(e));
        }
        if n == 0 {
            return err("connection closed");
        }
        r.buf = r.buf + wire_to_bytes(scratch, n);
    }
}

// ---- handshake -------------------------------------------------------

// Verify the 24-byte client connection preface and send ours.
pub fn accept_preface(r: Reader, c: &mut link, scratch: wire,
                      deadline: until) -> result[bool, str] {
    let want = preface();
    while len(r.buf) < len(want) {
        let rr = c.recv(scratch, deadline);
        guard let n = rr else let e = err_of(rr) {
            return err("preface recv: " + to_str(e));
        }
        if n == 0 {
            return err("connection closed before preface");
        }
        r.buf = r.buf + wire_to_bytes(scratch, n);
    }
    if r.buf[0..len(want)] != want {
        // Almost always an HTTP/1.1 client that reached an h2-only port.
        return err("bad connection preface (not an HTTP/2 client)");
    }
    r.buf = r.buf[len(want)..];
    let sr = c.send_bytes(our_settings(), deadline);
    guard let _n = sr else let e = err_of(sr) {
        return err("settings send: " + to_str(e));
    }
    return ok(true);
}

// ---- control frames --------------------------------------------------

fn apply_settings(cn: Conn, payload: bytes) -> result[bool, str] {
    if len(payload) % 6 != 0 {
        return err("SETTINGS payload is not a multiple of 6");
    }
    let i = 0;
    while i < len(payload) {
        let id = be16(payload, i);
        // a SETTINGS entry is a 16-bit id then a 32-bit value,
        // so the value starts 2 octets in, not 4
        let v = be32(payload, i + 2);
        if id == S_MAX_FRAME_SIZE {
            // RFC 9113 §6.5.2: outside this range is a connection error
            if v < 16384 || v > 16777215 {
                return err("SETTINGS_MAX_FRAME_SIZE out of range");
            }
            cn.peer_max_frame = v;
        }
        if id == S_HEADER_TABLE_SIZE {
            table_resize(cn.dec.table, v);
        }
        i = i + 6;
    }
    return ok(true);
}

// Handle a frame that is not part of a request. Returns true if it was
// consumed here, so the caller only sees HEADERS/DATA/CONTINUATION.
fn handle_control(cn: Conn, c: &mut link, f: Frame, deadline: until)
        -> result[bool, str] {
    if f.ftype == T_SETTINGS {
        if (f.flags & FLAG_ACK) != 0 {
            return ok(true);       // our settings were acknowledged
        }
        let ar = apply_settings(cn, f.payload);
        guard let _a = ar else let e = err_of(ar) {
            return err(e);
        }
        let sr = c.send_bytes(settings_ack(), deadline);
        guard let _n = sr else let e = err_of(sr) {
            return err("settings ack: " + to_str(e));
        }
        return ok(true);
    }
    if f.ftype == T_PING {
        if len(f.payload) != 8 {
            return err("PING payload must be 8 octets");
        }
        if (f.flags & FLAG_ACK) == 0 {
            let sr = c.send_bytes(ping_ack(f.payload), deadline);
            guard let _n = sr else let e = err_of(sr) {
                return err("ping ack: " + to_str(e));
            }
        }
        return ok(true);
    }
    if f.ftype == T_WINDOW_UPDATE {
        if len(f.payload) != 4 {
            return err("WINDOW_UPDATE payload must be 4 octets");
        }
        let inc = be32(f.payload, 0) & 0x7fffffff;
        if inc == 0 {
            return err("WINDOW_UPDATE increment of 0");
        }
        return ok(true);
    }
    if f.ftype == T_GOAWAY {
        cn.gone = true;
        return ok(true);
    }
    if f.ftype == T_RST_STREAM || f.ftype == T_PRIORITY {
        return ok(true);           // nothing to unwind while serving serially
    }
    if f.ftype == T_PUSH_PROMISE {
        return err("client sent PUSH_PROMISE");
    }
    return ok(false);              // HEADERS / DATA / CONTINUATION
}

// ---- request assembly ------------------------------------------------

fn pseudo(hs: [Header], name: str) -> str {
    for i in 0..len(hs) {
        if hs[i].name == name {
            return hs[i].value;
        }
    }
    return "";
}

// Read frames until one complete request has arrived.
pub fn read_request(cn: Conn, r: Reader, c: &mut link, scratch: wire,
                    deadline: until) -> result[Req, str] {
    let hdr_block = b"";
    let stream = 0;
    let collecting = false;
    let body = b"";
    let want_body = false;

    while true {
        let fr = read_frame(r, &mut *c, scratch, DEFAULT_MAX_FRAME, deadline);
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }

        let cr = handle_control(cn, &mut *c, f, deadline);
        guard let consumed = cr else let e = err_of(cr) {
            return err(e);
        }
        if consumed {
            if cn.gone {
                return err("peer sent GOAWAY");
            }
            continue;
        }

        if f.ftype == T_HEADERS {
            if collecting {
                return err("HEADERS while another header block was open");
            }
            if f.stream == 0 {
                return err("HEADERS on stream 0");
            }
            // Client streams are odd and must increase (RFC 9113 §5.1.1)
            if (f.stream & 1) == 0 {
                return err("client used an even stream id");
            }
            if f.stream <= cn.last_stream {
                return err("stream id did not increase");
            }
            stream = f.stream;
            cn.last_stream = stream;

            let pr = strip_padding(f.payload, f.flags);
            guard let pay = pr else let e = err_of(pr) {
                return err(e);
            }
            // A PRIORITY block, if present, precedes the header data
            if (f.flags & FLAG_PRIORITY) != 0 {
                if len(pay) < 5 {
                    return err("HEADERS with PRIORITY but no priority field");
                }
                pay = pay[5..];
            }
            hdr_block = pay;
            want_body = (f.flags & FLAG_END_STREAM) == 0;
            collecting = (f.flags & FLAG_END_HEADERS) == 0;
            if collecting {
                continue;
            }
        } else {
            if f.ftype == T_CONTINUATION {
                if !collecting || f.stream != stream {
                    return err("unexpected CONTINUATION");
                }
                hdr_block = hdr_block + f.payload;
                if len(hdr_block) > 65536 {
                    return err("header block too large");
                }
                collecting = (f.flags & FLAG_END_HEADERS) == 0;
                if collecting {
                    continue;
                }
            } else {
                if f.ftype == T_DATA {
                    if f.stream != stream {
                        return err("DATA on an unexpected stream");
                    }
                    let dr = strip_padding(f.payload, f.flags);
                    guard let dat = dr else let e = err_of(dr) {
                        return err(e);
                    }
                    body = body + dat;
                    if len(body) > MAX_BODY {
                        return err("request body too large");
                    }
                    // Give the window back so the peer can keep sending.
                    // Both levels must be replenished: connection and stream.
                    let n = len(f.payload);
                    let wr = c.send_bytes(window_update(0, n)
                                          + window_update(stream, n),
                                          deadline);
                    guard let _w = wr else let e = err_of(wr) {
                        return err("window update: " + to_str(e));
                    }
                    if (f.flags & FLAG_END_STREAM) != 0 {
                        want_body = false;
                    }
                    if want_body {
                        continue;
                    }
                } else {
                    return err("unexpected frame type in request");
                }
            }
        }

        // header block complete; decode it
        if !collecting && len(hdr_block) > 0 {
            let dr2 = decode_block(cn.dec, hdr_block, MAX_HEADER_FIELDS);
            guard let hs = dr2 else let e = err_of(dr2) {
                return err("hpack: " + e);
            }
            if want_body {
                // remember the decoded headers while DATA arrives
                hdr_block = b"";
                let m = pseudo(hs, ":method");
                let p = pseudo(hs, ":path");
                let s = pseudo(hs, ":scheme");
                let a = pseudo(hs, ":authority");
                // keep reading DATA, then return below
                let pending = Req {
                    stream: stream, method: m, path: p, scheme: s,
                    authority: a, headers: hs, body: b""
                };
                let br = read_body(cn, r, &mut *c, scratch, stream, deadline);
                guard let bd = br else let e = err_of(br) {
                    return err(e);
                }
                pending.body = bd;
                return ok(pending);
            }
            let m2 = pseudo(hs, ":method");
            let p2 = pseudo(hs, ":path");
            let s2 = pseudo(hs, ":scheme");
            let a2 = pseudo(hs, ":authority");
            if len(m2) == 0 || len(p2) == 0 {
                return err("request missing :method or :path");
            }
            return ok(Req {
                stream: stream, method: m2, path: p2, scheme: s2,
                authority: a2, headers: hs, body: body
            });
        }
    }
}

// Read DATA frames for `stream` until END_STREAM.
fn read_body(cn: Conn, r: Reader, c: &mut link, scratch: wire, stream: int,
             deadline: until) -> result[bytes, str] {
    let body = b"";
    while true {
        let fr = read_frame(r, &mut *c, scratch, DEFAULT_MAX_FRAME, deadline);
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }
        let cr = handle_control(cn, &mut *c, f, deadline);
        guard let consumed = cr else let e = err_of(cr) {
            return err(e);
        }
        if consumed {
            continue;
        }
        if f.ftype != T_DATA || f.stream != stream {
            return err("expected DATA while reading a request body");
        }
        let dr = strip_padding(f.payload, f.flags);
        guard let dat = dr else let e = err_of(dr) {
            return err(e);
        }
        body = body + dat;
        if len(body) > MAX_BODY {
            return err("request body too large");
        }
        let n = len(f.payload);
        let wr = c.send_bytes(window_update(0, n) + window_update(stream, n),
                              deadline);
        guard let _w = wr else let e = err_of(wr) {
            return err("window update: " + to_str(e));
        }
        if (f.flags & FLAG_END_STREAM) != 0 {
            return ok(body);
        }
    }
}

// ---- responses -------------------------------------------------------

// Send a response on `stream`. DATA is split to the peer's advertised
// max frame size rather than assuming ours: exceeding it is a
// connection error, and the peer may have set it lower than 16KB.
pub fn respond(cn: Conn, c: &mut link, stream: int, status: str,
               extra: [Header], body: bytes, deadline: until)
        -> result[bool, str] {
    let hs: [Header] = [Header { name: ":status", value: status }];
    hs = hs + extra;
    hs = hs + [Header { name: "content-length", value: to_str(len(body)) }];
    let blk = encode_block(hs);

    let end_now = len(body) == 0;
    let hflags = FLAG_END_HEADERS;
    if end_now {
        hflags = hflags | FLAG_END_STREAM;
    }
    let out = header_bytes(T_HEADERS, hflags, stream, len(blk)) + blk;
    let hr = c.send_bytes(out, deadline);
    guard let _h = hr else let e = err_of(hr) {
        return err("headers send: " + to_str(e));
    }
    if end_now {
        return ok(true);
    }

    let off = 0;
    let cap = cn.peer_max_frame;
    while off < len(body) {
        let n = len(body) - off;
        if n > cap {
            n = cap;
        }
        let last = (off + n) >= len(body);
        let dflags = 0;
        if last {
            dflags = FLAG_END_STREAM;
        }
        let chunk = header_bytes(T_DATA, dflags, stream, n)
                  + body[off..off + n];
        let dr = c.send_bytes(chunk, deadline);
        guard let _d = dr else let e = err_of(dr) {
            return err("data send: " + to_str(e));
        }
        off = off + n;
    }
    return ok(true);
}

pub fn send_goaway(c: &mut link, last_stream: int, code: int, msg: str,
                   deadline: until) {
    let g = c.send_bytes(goaway(last_stream, code, msg), deadline);
    guard let _n = g else { return; }
}
