import "net";
import "time";

// HTTP/2 connection and stream layer (RFC 9113).
//
// A connection is: verify the client preface, exchange SETTINGS, then
// read frames forever. Requests arrive as HEADERS (possibly continued
// by CONTINUATION frames) followed by zero or more DATA frames, ending
// when END_STREAM is seen.
//
// The connection is addressed by a Transport -- an fd for h2c, or an
// SSL handle for h2 over TLS -- and NOT by a `link`. That is forced and
// it is also better:
//
//   `link` is move-only, so `spawn writer(c)` consumes it and the reader
//   task can no longer use it -- the two-task design is impossible with
//   that type. A Transport is freely copyable, so both tasks can hold
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
// chan[WMsg].
//
// The writer is what makes this safe without a mutex, which slang does
// not expose anyway. Three properties matter:
//
//   1. The writer emits one frame at a time and is the only writer, so
//      no two handlers can interleave inside a frame.
//   2. A HEADERS block and its CONTINUATION frames must not be split by
//      any other frame (RFC 9113 §6.2). Because a handler enqueues its
//      whole block as one message, that holds by construction rather
//      than by careful ordering.
//   3. Flow-control windows are connection-wide state that the read
//      side replenishes and the write side spends. Both meet in this
//      one task, so the accounting needs no lock either.
//
// Frames for different streams still interleave at frame boundaries --
// that is exactly what multiplexing means, and it is legal.

// ---- writer messages -------------------------------------------------
//
// Everything the writer task needs arrives on ONE channel, tagged.
//
// That is not a stylistic choice: slang has no `select` over channels,
// so a writer that had to watch both "here is a response" and "the peer
// granted more window" on two channels could only ever block on one of
// them. Folding both into a single stream makes the writer an ordinary
// state machine with one blocking point, and gives the ordering for
// free -- a grant that arrives before a body is simply an earlier
// message.
pub let W_RAW = 0;       // pre-built frames, not flow controlled
pub let W_BODY = 1;      // a response: HEADERS now, DATA as window allows
pub let W_GRANT = 2;     // peer's WINDOW_UPDATE: `n` octets to `stream`
pub let W_INITIAL = 3;   // peer's SETTINGS_INITIAL_WINDOW_SIZE is now `n`
pub let W_MAXFRAME = 4;  // peer's SETTINGS_MAX_FRAME_SIZE is now `n`

pub gc struct WMsg {
    kind: int,
    stream: int,
    n: int,
    head: bytes,   // W_BODY: the HEADERS frame; W_RAW: the whole thing
    body: bytes,   // W_BODY: the response body, unframed
}

pub fn raw_msg(b: bytes) -> WMsg {
    return WMsg { kind: W_RAW, stream: 0, n: 0, head: b, body: b"" };
}

pub fn grant_msg(stream: int, n: int) -> WMsg {
    return WMsg { kind: W_GRANT, stream: stream, n: n, head: b"", body: b"" };
}

fn setting_msg(kind: int, n: int) -> WMsg {
    return WMsg { kind: kind, stream: 0, n: n, head: b"", body: b"" };
}

// Build a response. The body is handed over UNFRAMED: the writer owns
// the peer's window and its max frame size, so it -- not the handler --
// decides how the body is cut into DATA frames and when each may go.
pub fn response_msg(stream: int, status: str, extra: [Header],
                    body: bytes) -> WMsg {
    let hs: [Header] = [Header { name: ":status", value: status }];
    hs = hs + extra;
    hs = hs + [Header { name: "content-length", value: to_str(len(body)) }];
    let blk = encode_block(hs);
    let hflags = FLAG_END_HEADERS;
    if len(body) == 0 {
        hflags = hflags | FLAG_END_STREAM;
    }
    return WMsg {
        kind: W_BODY,
        stream: stream,
        n: 0,
        head: header_bytes(T_HEADERS, hflags, stream, len(blk)) + blk,
        body: body
    };
}

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
    // How many handlers may run at once on ONE connection. Not a
    // duration like the rest, but it belongs here for the same reason:
    // it is a bound a caller sets per connection, and forgetting it is
    // how a server falls over.
    max_concurrent: int,
}

pub fn default_limits() -> Limits {
    return Limits {
        handshake: 10000000000,     //  10s
        idle: 120000000000,         // 120s
        request: 30000000000,       //  30s
        write: 30000000000,         //  30s
        // Matches what our_settings() advertises. Advertising a limit
        // and not enforcing it is worse than advertising none: peers
        // size their behaviour by it.
        max_concurrent: 100
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

// ---- Rapid Reset (CVE-2023-44487) ------------------------------------
//
// A peer opens a stream and immediately RST_STREAMs it. From its side
// the stream is closed the instant it opens, so a concurrency limit
// never sees it -- while the server has already done the HPACK decode
// and, in most designs, started the work. Repeat and the server is
// driven at whatever rate the attacker can write frames.
//
// Cancelling a request IS legitimate: a browser navigating away resets
// its in-flight streams, and a client that gives up on a slow endpoint
// should. So a flat "no resets" rule would break correct clients. What
// is not legitimate is resetting nearly everything you open, forever.
//
// Hence a burst plus a ratio: RESET_BURST cancellations are free, and
// after that a peer whose resets outnumber half of what it opened is
// ending the connection. A browser that abandons a page load trips
// neither; a Rapid Reset flood resets every stream it opens, so it
// trips both the moment the burst is spent.
pub let RESET_BURST = 100;

pub gc struct Conn {
    dec: Decoder,
    // what the PEER told us it will accept
    peer_max_frame: int,
    // connection-level receive window we still have outstanding
    recv_window: int,
    last_stream: int,
    gone: bool,
    // Rapid Reset accounting (CVE-2023-44487). Both counters are
    // touched only by the single reader task, so they need no lock.
    opened: int,
    resets: int,
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
        gone: false,
        opened: 0,
        resets: 0
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

// ---- the stream gate -------------------------------------------------
//
// The connection layer cannot cap concurrency on its own: it does not
// spawn the handlers, the CALLER does, and slang has no function values
// to hand it a callback. So the bound lives in a token channel the
// caller holds, and this is the mechanism plus the vocabulary for it.
//
// A gate is a chan[bool] holding `n` tokens. gate_enter takes one and
// blocks when none are left; gate_leave puts one back. That blocking IS
// the backpressure -- the reader stops pulling frames while every slot
// is busy, which is the correct answer to "more work than I can do",
// and far better than the alternative measured before this existed:
// 3002 concurrent handler tasks from a peer we had told our limit was
// 100.
//
// It also solves shutdown. Closing the writer channel while handlers
// are still in flight panics them with "send on closed channel", and
// nothing else could tell whether any were left. gate_drain waits for
// every token to come home, so the close is safe by construction.
//
// The one rule: gate_leave must run on EVERY path out of a handler,
// including error returns. A lost token permanently shrinks the
// connection's capacity, and losing all of them wedges that connection
// (only that one -- the failure is bounded and visible, not a crash).
pub fn gate(n: int) -> chan[bool] {
    let cap = n;
    if cap < 1 {
        cap = 1;
    }
    let g: chan[bool] = make_chan(cap);
    let i = 0;
    while i < cap {
        chan_send(g, true);
        i = i + 1;
    }
    return g;
}

pub fn gate_enter(g: chan[bool]) {
    let v = chan_recv(g);
    guard let _t = v else {
        return;   // closed: the connection is going away anyway
    }
}

pub fn gate_leave(g: chan[bool]) {
    chan_send(g, true);
}

// Wait until every handler has finished, by collecting all `n` tokens.
// Call before chan_close on the writer channel.
pub fn gate_drain(g: chan[bool], n: int) {
    let i = 0;
    while i < n {
        let v = chan_recv(g);
        guard let _t = v else {
            return;
        }
        i = i + 1;
    }
}

// ---- transport -------------------------------------------------------
//
// h2 runs over cleartext TCP (h2c, prior knowledge) or over TLS, and the
// two are reached through different runtime calls: net.recv_until on an
// fd, net.tls_recv_until on an SSL handle. Everything above this point
// is identical either way, so the difference is confined to one struct
// and two functions rather than duplicated through the whole layer.
//
// This matters beyond tidiness: browsers speak HTTP/2 ONLY over TLS with
// ALPN, so a connection layer that can only do fds cannot serve a
// browser at all, however conformant the rest of it is.
pub gc struct Transport {
    fd: i32,       // the socket; 0 and unused when ssl is set
    ssl: rawptr,   // nullptr for cleartext
}

// h2c: cleartext, prior knowledge. curl --http2-prior-knowledge, and
// Go's http2.Transport with AllowHTTP.
pub fn transport_fd(fd: i32) -> Transport {
    return Transport { fd: fd, ssl: nullptr };
}

// h2 over TLS. The handle comes from net.tls_accept, and the caller is
// responsible for having negotiated "h2" via ALPN first -- see
// alpn_is_h2 below.
pub fn transport_tls(ssl: rawptr) -> Transport {
    return Transport { fd: 0, ssl: ssl };
}

fn tr_recv(t: Transport, max: int, u: until) -> result[bytes, str] {
    if t.ssl == nullptr {
        return net.recv_until(t.fd, max, u);
    }
    return net.tls_recv_until(t.ssl, max, u);
}

fn tr_send(t: Transport, b: bytes, u: until) -> result[i32, str] {
    if t.ssl == nullptr {
        return net.send_until(t.fd, b, u);
    }
    return net.tls_send_until(t.ssl, b, u);
}

pub fn tr_close(t: Transport) {
    if t.ssl == nullptr {
        net.close(t.fd);
        return;
    }
    net.tls_close(t.ssl);
}

// RFC 7301 §3.1: the peer either selected "h2" or it did not. A server
// that advertised h2 and http/1.1 must look, because a browser offered
// both and may well have picked http/1.1 -- feeding an HTTP/1.1 client
// into this layer produces "bad connection preface", which is true but
// unhelpful.
pub fn alpn_is_h2(proto: str) -> bool {
    return proto == "h2";
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
pub fn read_frame(r: Reader, t: Transport, max_frame: int, u: until)
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
        let rr = tr_recv(t, 16384, u);
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
pub fn accept_preface(r: Reader, t: Transport, wch: chan[WMsg], u: until)
        -> result[bool, str] {
    let want = preface();
    while len(r.buf) < len(want) {
        let rr = tr_recv(t, 16384, u);
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
    chan_send(wch, raw_msg(our_settings()));
    return ok(true);
}

// ---- control frames --------------------------------------------------

fn apply_settings(cn: Conn, wch: chan[WMsg], payload: bytes)
        -> result[bool, str] {
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
            chan_send(wch, setting_msg(W_MAXFRAME, v));
        }
        if id == S_HEADER_TABLE_SIZE {
            table_resize(cn.dec.table, v);
        }
        if id == S_INITIAL_WINDOW_SIZE {
            // §6.5.2: above 2^31-1 is a FLOW_CONTROL_ERROR
            if v > 2147483647 {
                return err("SETTINGS_INITIAL_WINDOW_SIZE out of range");
            }
            chan_send(wch, setting_msg(W_INITIAL, v));
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
fn handle_control(cn: Conn, wch: chan[WMsg], f: Frame)
        -> result[bool, str] {
    if f.ftype == T_SETTINGS {
        if (f.flags & FLAG_ACK) != 0 {
            return ok(true);       // our settings were acknowledged
        }
        let ar = apply_settings(cn, wch, f.payload);
        guard let _a = ar else let e = err_of(ar) {
            return err(e);
        }
        chan_send(wch, raw_msg(settings_ack()));
        return ok(true);
    }
    if f.ftype == T_PING {
        if len(f.payload) != 8 {
            return err("PING payload must be 8 octets");
        }
        if (f.flags & FLAG_ACK) == 0 {
            chan_send(wch, raw_msg(ping_ack(f.payload)));
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
        // The credit is the writer's to spend, and the writer is a
        // different task -- forward it rather than tracking it here.
        chan_send(wch, grant_msg(f.stream, inc));
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
        cn.resets = cn.resets + 1;
        if cn.resets > RESET_BURST && cn.resets * 2 > cn.opened {
            // Deliberately a CONNECTION error, not a stream error: the
            // peer has shown it will keep doing this, and refusing
            // individual streams would leave it free to keep paying the
            // cheap half of the exchange.
            return err("excessive stream resets");
        }
        // A handler task owns its own stream and finishes on its own.
        // Cancelling one mid-flight needs a per-stream registry, so a
        // reset still costs us the work already started -- which is
        // exactly why the counters above exist.
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
pub fn read_request(cn: Conn, r: Reader, t: Transport, wch: chan[WMsg],
                    lim: Limits) -> result[Req, str] {
    let hdr_block = b"";
    let stream = 0;
    let collecting = false;
    let body = b"";
    let want_body = false;
    let in_request = false;
    let deadline = until_of(time.mono() + lim.idle);

    while true {
        let fr = read_frame(r, t, DEFAULT_MAX_FRAME, deadline);
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
            cn.opened = cn.opened + 1;

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
                    chan_send(wch, raw_msg(window_update(0, n)
                                           + window_update(stream, n)));
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
                let br = read_body(cn, r, t, stream, wch, deadline);
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
fn read_body(cn: Conn, r: Reader, t: Transport, stream: int,
             wch: chan[WMsg], u: until) -> result[bytes, str] {
    let body = b"";
    while true {
        let fr = read_frame(r, t, DEFAULT_MAX_FRAME, u);
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
        chan_send(wch, raw_msg(window_update(0, n) + window_update(stream, n)));
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
// One response whose body has not finished going out. `window` is this
// STREAM's remaining send credit; the connection's is tracked once for
// all of them.
gc struct Out {
    stream: int,
    body: bytes,
    off: int,
    window: int,
    done: bool,
}

fn wsend(t: Transport, b: bytes, write_ns: int) -> bool {
    if len(b) == 0 {
        return true;
    }
    let sr = tr_send(t, b, until_of(time.mono() + write_ns));
    guard let _n = sr else {
        return false;
    }
    return true;
}

// The largest window RFC 9113 §6.9.1 permits. A WINDOW_UPDATE that
// pushes a window past it is a FLOW_CONTROL_ERROR, not something to
// clamp: a peer that does it has lost track of our state.
fn window_max() -> int {
    return 2147483647;
}

// Send whatever the two windows currently allow, oldest response first,
// and keep what is left. Returns false if the connection died.
//
// Both windows are decremented by every DATA octet: flow control is
// per-stream AND per-connection, and a stream with plenty of credit
// still cannot send when the connection has none.
fn flush_out(t: Transport, q: [Out], conn_window: int, max_frame: int,
             write_ns: int) -> result[int, str] {
    let i = 0;
    let cw = conn_window;
    while i < len(q) {
        let o = q[i];
        let sending = true;
        while sending {
            sending = false;
            let left = len(o.body) - o.off;
            if left <= 0 {
                // Body fully sent, but the last DATA frame did not carry
                // END_STREAM (the window ran out exactly at the end).
                // A zero-length DATA with END_STREAM is explicitly
                // exempt from flow control (§6.9.1), so it goes out even
                // at a zero window -- otherwise such a response could
                // never be closed.
                if !wsend(t, header_bytes(T_DATA, FLAG_END_STREAM,
                                           o.stream, 0), write_ns) {
                    return err("peer gone");
                }
                o.done = true;
                break;
            }
            let n = left;
            if n > o.window { n = o.window; }
            if n > cw { n = cw; }
            if n > max_frame { n = max_frame; }
            if n <= 0 {
                break;           // blocked; wait for a WINDOW_UPDATE
            }
            let last = (o.off + n) >= len(o.body);
            let dflags = 0;
            if last {
                dflags = FLAG_END_STREAM;
            }
            if !wsend(t, header_bytes(T_DATA, dflags, o.stream, n)
                          + o.body[o.off..o.off + n], write_ns) {
                return err("peer gone");
            }
            o.off = o.off + n;
            o.window = o.window - n;
            cw = cw - n;
            if last {
                o.done = true;
                break;
            }
            sending = true;
        }
        i = i + 1;
    }
    // Drop the finished entries, keeping the rest in order. Lists have
    // no remove-at-index, so survivors are shifted down and the tail
    // popped -- which is what a remove-at-index would do anyway.
    let w = 0;
    let k = 0;
    while k < len(q) {
        if !q[k].done {
            q[w] = q[k];
            w = w + 1;
        }
        k = k + 1;
    }
    while len(q) > w {
        pop(q);
    }
    return ok(cw);
}

// Owns the write side, and with it the peer's send windows.
//
// Flow control has to live here rather than in the handlers. The window
// is a property of the CONNECTION, shared by every concurrent stream,
// so no handler can decide on its own whether it may send -- and the
// WINDOW_UPDATE that grants credit arrives on the read side, in a
// different task entirely. Routing both into this one task is what lets
// the accounting be correct without a lock, which slang does not expose
// anyway.
//
// A blocked stream parks its BODY here, not its task: the handler hands
// the response over and moves on, so a peer with a tiny window costs a
// queue entry rather than a live task.
pub fn writer_task(t: Transport, wch: chan[WMsg], write_ns: int) {
    let conn_window = DEFAULT_WINDOW;
    let initial = DEFAULT_WINDOW;   // peer's SETTINGS_INITIAL_WINDOW_SIZE
    let max_frame = DEFAULT_MAX_FRAME;
    let q: [Out] = [];
    // Stream grants that arrived before we had a body to spend them on.
    // Entries are consumed when the body is queued, so this holds at
    // most one per in-flight request.
    let early: map[int]int = {};

    while true {
        let m = chan_recv(wch);
        guard let msg = m else {
            return;              // channel closed: connection is done
        }

        if msg.kind == W_RAW {
            if !wsend(t, msg.head, write_ns) {
                return;
            }
        }
        if msg.kind == W_MAXFRAME {
            max_frame = msg.n;
        }
        if msg.kind == W_INITIAL {
            // §6.9.2: changing the initial window size adjusts every
            // OPEN stream's window by the delta -- it is not a reset,
            // and it does not touch the connection window.
            let delta = msg.n - initial;
            initial = msg.n;
            let k = 0;
            while k < len(q) {
                q[k].window = q[k].window + delta;
                k = k + 1;
            }
        }
        if msg.kind == W_GRANT {
            if msg.stream == 0 {
                if conn_window > window_max() - msg.n {
                    if !wsend(t, goaway(0, E_FLOW_CONTROL_ERROR,
                                         "connection window overflow"),
                              write_ns) {
                        return;
                    }
                    return;
                }
                conn_window = conn_window + msg.n;
            } else {
                let found = false;
                let k = 0;
                while k < len(q) {
                    if q[k].stream == msg.stream {
                        if q[k].window > window_max() - msg.n {
                            if !wsend(t, goaway(0, E_FLOW_CONTROL_ERROR,
                                                 "stream window overflow"),
                                      write_ns) {
                                return;
                            }
                            return;
                        }
                        q[k].window = q[k].window + msg.n;
                        found = true;
                    }
                    k = k + 1;
                }
                if !found {
                    // The peer is crediting a stream whose body we have
                    // not queued yet. Remember it rather than dropping
                    // it, or the body would start under-credited.
                    let prev = 0;
                    if has(early, msg.stream) {
                        prev = early[msg.stream];
                    }
                    early[msg.stream] = prev + msg.n;
                }
            }
        }
        if msg.kind == W_BODY {
            if !wsend(t, msg.head, write_ns) {
                return;
            }
            if len(msg.body) > 0 {
                let w = initial;
                if has(early, msg.stream) {
                    w = w + early[msg.stream];
                    del(early, msg.stream);
                }
                push(q, Out { stream: msg.stream, body: msg.body,
                              off: 0, window: w, done: false });
            }
        }

        let fr = flush_out(t, q, conn_window, max_frame, write_ns);
        guard let cw = fr else {
            return;              // peer gone, or too slow to read
        }
        conn_window = cw;
    }
}

// ---- responses -------------------------------------------------------

// Enqueue a response for `stream`. Every write on the connection goes
// through the writer task, so there is deliberately no direct-write
// variant: one would be able to interleave with a handler mid-frame.
pub fn respond(cn: Conn, wch: chan[WMsg], stream: int, status: str,
               extra: [Header], body: bytes) {
    chan_send(wch, response_msg(stream, status, extra, body));
}

pub fn send_reset(wch: chan[WMsg], stream: int, code: int) {
    chan_send(wch, raw_msg(rst_stream(stream, code)));
}

pub fn send_goaway(wch: chan[WMsg], last_stream: int, code: int, msg: str) {
    chan_send(wch, raw_msg(goaway(last_stream, code, msg)));
}
