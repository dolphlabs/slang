import "net";
import "time";

// HTTP/2 connection and stream layer (RFC 9113).
//
// A connection is: verify the client preface, exchange SETTINGS, then
// read frames forever. Requests arrive as HEADERS (possibly continued
// by CONTINUATION frames) followed by zero or more DATA frames, ending
// when END_STREAM is seen.
//
// The connection is addressed by its FILE DESCRIPTOR, not by a `link`.
// That is forced and it is also better:
//
//   `link` is move-only, so `spawn writer(c)` consumes it and the reader
//   task can no longer use it -- the two-task design is impossible with
//   that type. An i32 fd is an ordinary integer, so both tasks can hold
//   it, which is exactly what a socket allows: one reader, one writer,
//   opposite directions.
//
//   net.recv also hands back `bytes` directly, so the byte-at-a-time
//   wire copy the `link` path needed disappears from the read path.
//
// Every read and every write is bounded by a deadline -- see Limits
// below. A peer that opens a connection and then dribbles, or one that
// stops reading our responses, is disconnected rather than allowed to
// hold a task forever.
//
// Streams are served CONCURRENTLY. One task reads frames and dispatches
// each complete request to its own spawned handler; every byte that
// leaves the connection goes through a single writer task fed by a
// chan[bytes].
//
// The writer is what makes this safe without a mutex, which slang does
// not expose anyway. Two properties matter:
//
//   1. Each message on the channel is a COMPLETE frame sequence, and the
//      writer sends one message per send_bytes, so no two handlers can
//      interleave inside a frame.
//   2. A HEADERS block and its CONTINUATION frames must not be split by
//      any other frame (RFC 9113 §6.2). Because a handler enqueues its
//      whole block as one message, that holds by construction rather
//      than by careful ordering.
//
// Frames for different streams still interleave at frame boundaries --
// that is exactly what multiplexing means, and it is legal.

// ---- deadlines -------------------------------------------------------
//
// Four separate budgets, in nanoseconds, because they defend against
// four different peers and want wildly different numbers.
//
// `idle` is the generous one on purpose: an HTTP/2 connection sitting
// open with no streams is completely normal -- that is the whole point
// of connection reuse -- so timing it out aggressively breaks correct
// clients. `request` is the strict one: once a client has started a
// request it must finish it, and dribbling DATA forever is exactly the
// slowloris shape.
pub gc struct Limits {
    handshake: int,   // connect -> valid preface received
    idle: int,        // no request in flight, waiting for the next frame
    request: int,     // first HEADERS octet -> END_STREAM
    write: int,       // one writer_task send
}

pub fn default_limits() -> Limits {
    return Limits {
        handshake: 10000000000,     //  10s
        idle: 120000000000,         // 120s
        request: 30000000000,       //  30s
        write: 30000000000          //  30s
    };
}

// The reserved error string net.recv_until / net.send_until return when
// a deadline passes. Exposed as a predicate so callers can react to a
// slow peer (GOAWAY with ENHANCE_YOUR_CALM) differently from a broken
// one, without hardcoding the text.
pub fn is_timeout(e: str) -> bool {
    return e == "timeout";
}

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

// Pull bytes until at least one complete frame is buffered, then return
// it and keep the remainder.
// Note the `&mut *c` at every site below that forwards this borrow:
// passing `c` directly MOVES it, so the second call would fail with
// "use of moved value". Reborrowing keeps the caller's borrow usable.
//
// `u` bounds the WHOLE call, not each recv: a peer that sends one octet
// every second must still finish the frame inside the budget, which is
// what makes this a slowloris defence rather than a keepalive check.
// Pass until_never() only where blocking forever is genuinely intended.
pub fn read_frame(r: Reader, fd: i32, max_frame: int, u: until)
        -> result[Frame, str] {
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
        let rr = net.recv_until(fd, 16384, u);
        guard let chunk = rr else let e = err_of(rr) {
            // Passed through unprefixed so is_timeout() still matches;
            // every other error keeps the "recv: " context.
            if is_timeout(e) {
                return err(e);
            }
            return err("recv: " + e);
        }
        if len(chunk) == 0 {
            return err("connection closed");
        }
        r.buf = r.buf + chunk;
    }
}

// ---- handshake -------------------------------------------------------

// Verify the 24-byte client connection preface and send ours.
pub fn accept_preface(r: Reader, fd: i32, wch: chan[bytes], u: until)
        -> result[bool, str] {
    let want = preface();
    while len(r.buf) < len(want) {
        let rr = net.recv_until(fd, 16384, u);
        guard let chunk = rr else let e = err_of(rr) {
            if is_timeout(e) {
                return err(e);
            }
            return err("preface recv: " + e);
        }
        if len(chunk) == 0 {
            return err("connection closed before preface");
        }
        r.buf = r.buf + chunk;
    }
    if r.buf[0..len(want)] != want {
        // Almost always an HTTP/1.1 client that reached an h2-only port.
        return err("bad connection preface (not an HTTP/2 client)");
    }
    r.buf = r.buf[len(want)..];
    // First message on the channel, so it is the first thing the peer
    // sees -- the writer preserves order.
    chan_send(wch, our_settings());
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
// Control frames go through the writer channel too, not straight to the
// socket: a SETTINGS ack written directly could land in the middle of a
// handler's HEADERS block.
fn handle_control(cn: Conn, wch: chan[bytes], f: Frame)
        -> result[bool, str] {
    if f.ftype == T_SETTINGS {
        if (f.flags & FLAG_ACK) != 0 {
            return ok(true);       // our settings were acknowledged
        }
        let ar = apply_settings(cn, f.payload);
        guard let _a = ar else let e = err_of(ar) {
            return err(e);
        }
        chan_send(wch, settings_ack());
        return ok(true);
    }
    if f.ftype == T_PING {
        if len(f.payload) != 8 {
            return err("PING payload must be 8 octets");
        }
        if (f.flags & FLAG_ACK) == 0 {
            chan_send(wch, ping_ack(f.payload));
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
    // PRIORITY is deprecated (RFC 9113 §5.3.2) and we act on none of
    // it, but "ignore" means ignore the PRIORITISATION -- the frame
    // itself still has to be well-formed, or a malformed one becomes an
    // undetected desync rather than the connection error it is.
    if f.ftype == T_PRIORITY {
        if f.stream == 0 {
            return err("PRIORITY on stream 0");
        }
        if len(f.payload) != 5 {
            return err("PRIORITY payload must be 5 octets");
        }
        // The dependency is the low 31 bits; the top bit is exclusive.
        let dep = be32(f.payload, 0) & 0x7fffffff;
        if dep == f.stream {
            return err("PRIORITY: stream depends on itself");
        }
        return ok(true);
    }
    if f.ftype == T_RST_STREAM {
        if f.stream == 0 {
            return err("RST_STREAM on stream 0");
        }
        if len(f.payload) != 4 {
            return err("RST_STREAM payload must be 4 octets");
        }
        // Nothing to unwind here: a handler task owns its own stream and
        // finishes on its own. Cancelling it mid-flight needs a
        // per-stream registry, which flow control will want anyway.
        return ok(true);
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
//
// Two clocks, switched at the first HEADERS. Before it the connection
// is idle and gets the generous `idle` budget, refreshed by each
// control frame that arrives -- a client PINGing a kept-alive
// connection is behaving correctly and must not be disconnected. After
// it the strict `request` budget applies to the request as a WHOLE and
// is never refreshed, so no amount of dribbled DATA or CONTINUATION can
// extend it.
pub fn read_request(cn: Conn, r: Reader, fd: i32, wch: chan[bytes],
                    lim: Limits) -> result[Req, str] {
    let hdr_block = b"";
    let stream = 0;
    let collecting = false;
    let body = b"";
    let want_body = false;
    let in_request = false;
    let deadline = until_of(time.mono() + lim.idle);

    while true {
        let fr = read_frame(r, fd, DEFAULT_MAX_FRAME, deadline);
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }

        let cr = handle_control(cn, wch, f);
        guard let consumed = cr else let e = err_of(cr) {
            return err(e);
        }
        if consumed {
            if cn.gone {
                return err("peer sent GOAWAY");
            }
            if !in_request {
                deadline = until_of(time.mono() + lim.idle);
            }
            continue;
        }

        if !in_request {
            in_request = true;
            deadline = until_of(time.mono() + lim.request);
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
                // Same self-dependency rule as a PRIORITY frame: the
                // prioritisation is ignored, the well-formedness is not.
                if (be32(pay, 0) & 0x7fffffff) == f.stream {
                    return err("HEADERS priority: stream depends on itself");
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
                    chan_send(wch, window_update(0, n)
                                   + window_update(stream, n));
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
                let br = read_body(cn, r, fd, stream, wch, deadline);
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
//
// `u` is the caller's request deadline, passed straight through rather
// than refreshed: the body is part of the same request, and a budget
// that restarted per DATA frame would defend against nothing.
fn read_body(cn: Conn, r: Reader, fd: i32, stream: int,
             wch: chan[bytes], u: until) -> result[bytes, str] {
    let body = b"";
    while true {
        let fr = read_frame(r, fd, DEFAULT_MAX_FRAME, u);
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }
        let cr = handle_control(cn, wch, f);
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
        chan_send(wch, window_update(0, n) + window_update(stream, n));
        if (f.flags & FLAG_END_STREAM) != 0 {
            return ok(body);
        }
    }
}

// ---- serialised writer ----------------------------------------------

// Owns the write side of the connection. Spawn one per connection and
// hand every producer the channel. Exits when the channel is closed, or
// when the peer goes away.
//
// Takes the fd, which both this task and the reader hold: one reads, one
// writes, opposite directions on the same socket, which is safe. Two
// tasks WRITING would not be, and that is the whole reason this task
// exists.
// The write deadline matters as much as the read one and defends
// against the mirror-image peer: one that sends requests and then stops
// reading. Its receive window fills, our send blocks, and this task --
// the only writer for the connection -- parks forever while every
// handler behind it piles up on the channel. Bounding the send turns
// that from a permanent leak into a dropped connection.
//
// A timed-out send has already put an unknown number of octets on the
// wire, so there is nothing to do but abandon the connection; retrying
// would resume mid-frame. Returning is exactly that.
pub fn writer_task(fd: i32, wch: chan[bytes], write_ns: int) {
    while true {
        let m = chan_recv(wch);
        guard let frames = m else {
            return;              // channel closed: connection is done
        }
        let sr = net.send_until(fd, frames, until_of(time.mono() + write_ns));
        guard let _n = sr else {
            return;              // peer gone, or too slow to read
        }
    }
}

// Build a complete response as one byte sequence, ready to hand to the
// writer. Pure, so a handler task can build it without touching the
// connection.
//
// DATA is split to the PEER's advertised max frame size, not ours:
// exceeding what the peer announced is a connection error, and a peer
// may set it below the 16KB default.
pub fn response_frames(peer_max_frame: int, stream: int, status: str,
                       extra: [Header], body: bytes) -> bytes {
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
    if end_now {
        return out;
    }
    let off = 0;
    let cap = peer_max_frame;
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
        out = out + header_bytes(T_DATA, dflags, stream, n)
                  + body[off..off + n];
        off = off + n;
    }
    return out;
}

// ---- responses -------------------------------------------------------

// Enqueue a response for `stream`. Every write on the connection goes
// through the writer task, so there is deliberately no direct-write
// variant: one would be able to interleave with a handler mid-frame.
pub fn respond(cn: Conn, wch: chan[bytes], stream: int, status: str,
               extra: [Header], body: bytes) {
    chan_send(wch, response_frames(cn.peer_max_frame, stream, status,
                                   extra, body));
}

pub fn send_reset(wch: chan[bytes], stream: int, code: int) {
    chan_send(wch, rst_stream(stream, code));
}

pub fn send_goaway(wch: chan[bytes], last_stream: int, code: int, msg: str) {
    chan_send(wch, goaway(last_stream, code, msg));
}
