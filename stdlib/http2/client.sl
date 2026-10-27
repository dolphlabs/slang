import "strings";
import "time";

// HTTP/2 client (RFC 9113): the connection layer of conn.sl seen from the
// other end. The same three pieces are used -- a Transport, one writer
// task fed by a chan[WMsg], one reader -- and every rule that made the
// server safe without a lock holds here too: only the writer writes, and
// a whole HEADERS block is one writer message.
//
// Two ways to use it:
//
//   - One stream at a time: client_preface, then client_request_msg sent
//     to the writer and client_read_response for that stream. The caller
//     owns stream ids and must not read two streams at once.
//   - Many at once: client_start returns a Client whose own reader task
//     routes each response to the task that asked for it. client_call is
//     safe from any number of tasks; it allocates stream ids, respects the
//     peer's concurrency limit, and times each call out on its own.
//
// Both reject what RFC 9113 calls malformed rather than guess: a response
// without :status, a pseudo-header in trailers, a content-length the body
// does not match, PUSH_PROMISE (we disable push).

pub gc struct Response {
    status: str,
    headers: [Header],
    body: bytes,
    trailers: [Header],
}

// Ours: push off, no server-initiated streams, the same frame and header
// list limits the server side advertises.
pub fn client_settings() -> bytes {
    let ids = [S_ENABLE_PUSH, S_MAX_CONCURRENT_STREAMS, S_MAX_FRAME_SIZE,
               S_MAX_HEADER_LIST_SIZE];
    let vals = [0, 0, DEFAULT_MAX_FRAME, 16384];
    return settings_frame(ids, vals);
}

// Send our preface and SETTINGS, then wait for the server's. RFC 9113
// §3.4: the server's preface is a SETTINGS frame, and it must be the
// first frame it sends -- anything else is not an HTTP/2 server.
pub fn client_preface(cn: Conn, r: Reader, t: Transport, wch: chan[WMsg],
                      lim: Limits) -> result[bool, str] {
    chan_send(wch, raw_msg(preface() + client_settings()));
    let deadline = until_of(time.mono() + lim.handshake);
    let fr = read_frame(r, t, DEFAULT_MAX_FRAME, deadline);
    guard let f = fr else let e = err_of(fr) {
        return err("server preface: " + e);
    }
    if f.ftype != T_SETTINGS || (f.flags & FLAG_ACK) != 0 || f.stream != 0 {
        return err("server preface: first frame was not SETTINGS");
    }
    let ar = apply_settings(cn, wch, f.payload);
    guard let _a = ar else let e = err_of(ar) {
        return err("server preface: " + e);
    }
    chan_send(wch, raw_msg(settings_ack()));
    return ok(true);
}

fn client_header_value_ok(v: str) -> bool {
    return !strings.contains(v, "\r") && !strings.contains(v, "\n");
}

// RFC 9110 token characters, lowercase only: HTTP/2 field names must be
// lowercase (RFC 9113 §8.2.1), and anything else is malformed.
fn client_name_ok(name: str) -> bool {
    if len(name) == 0 {
        return false;
    }
    let b = to_bytes(name);
    let i = 0;
    while i < len(b) {
        let c = b[i];
        let ok = (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
                 c == 33 || c == 35 || c == 36 || c == 37 || c == 38 ||
                 c == 39 || c == 42 || c == 43 || c == 45 || c == 46 ||
                 c == 94 || c == 95 || c == 96 || c == 124 || c == 126;
        if !ok {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// Connection-specific fields are forbidden in HTTP/2 (RFC 9113 §8.2.2);
// `te` is allowed only as "trailers".
fn client_header_problem(h: Header) -> str {
    if !client_name_ok(h.name) {
        return "header name " + h.name + " is not a lowercase token";
    }
    if !client_header_value_ok(h.value) {
        return "header " + h.name + " has CR or LF in its value";
    }
    if h.name == "connection" || h.name == "keep-alive" ||
       h.name == "proxy-connection" || h.name == "transfer-encoding" ||
       h.name == "upgrade" || h.name == "host" {
        return "header " + h.name + " is not allowed in HTTP/2 (use :authority for host)";
    }
    if h.name == "te" && h.value != "trailers" {
        return "header te may only be \"trailers\" in HTTP/2";
    }
    return "";
}

// One request as a writer message: its HEADERS (END_STREAM when there is
// no body) and its body, which the writer frames under the peer's flow
// control windows. Stream ids are odd and must increase on a connection
// (RFC 9113 §5.1.1); this checks and records that.
pub fn client_request_msg(cn: Conn, stream: int, method: str, scheme: str,
                          authority: str, path: str, headers: [Header],
                          body: bytes) -> result[WMsg, str] {
    if stream < 1 || stream > 2147483647 || (stream & 1) == 0 {
        return err("http2 request: stream id must be odd and 1..2147483647");
    }
    if stream <= cn.local_stream {
        return err("http2 request: stream id must increase on a connection");
    }
    if len(method) == 0 || len(scheme) == 0 || len(path) == 0 {
        return err("http2 request: :method, :scheme and :path are required");
    }
    let pseudo_values = [method, scheme, authority, path];
    for v in pseudo_values {
        if !client_header_value_ok(v) || strings.contains(v, " ") {
            return err("http2 request: pseudo-header values may not contain spaces, CR or LF");
        }
    }
    let hs: [Header] = [
        Header { name: ":method", value: method },
        Header { name: ":scheme", value: scheme },
        Header { name: ":path", value: path }
    ];
    if len(authority) > 0 {
        hs = hs + [Header { name: ":authority", value: authority }];
    }
    for h in headers {
        let problem = client_header_problem(h);
        if len(problem) > 0 {
            return err("http2 request: " + problem);
        }
    }
    hs = hs + headers;
    let blk = encode_block(hs);
    if len(blk) > DEFAULT_MAX_FRAME {
        return err("http2 request: header block exceeds 16384 octets");
    }
    let flags = FLAG_END_HEADERS;
    if len(body) == 0 {
        flags = flags | FLAG_END_STREAM;
    }
    cn.local_stream = stream;
    return ok(WMsg {
        kind: W_BODY,
        stream: stream,
        n: 0,
        head: header_bytes(T_HEADERS, flags, stream, len(blk)) + blk,
        body: body,
        tail: b""
    });
}

// ---- assembling one stream's response ----------------------------------
//
// Frames for a stream arrive as: HEADERS (any 1xx first, each its own
// block), the final response HEADERS, DATA, then optionally a trailers
// HEADERS with END_STREAM. Each block may continue over CONTINUATION
// frames. Pending holds one stream's progress; the single- and
// multi-stream readers both feed it frames in arrival order, which is
// also the order HPACK requires blocks to be decoded in.

gc struct Pending {
    stream: int,
    status: str,
    headers: [Header],
    body: bytes,
    trailers: [Header],
    got_final: bool,
    block: bytes,
    block_ends_stream: bool,
    collecting: bool,
    max_body: int,
}

fn pending_new(stream: int, max_body: int) -> Pending {
    let none_h: [Header] = [];
    let none_t: [Header] = [];
    return Pending {
        stream: stream, status: "", headers: none_h, body: b"",
        trailers: none_t, got_final: false, block: b"",
        block_ends_stream: false, collecting: false, max_body: max_body
    };
}

fn pending_response(p: Pending) -> Response {
    return Response { status: p.status, headers: p.headers, body: p.body,
                      trailers: p.trailers };
}

fn status_ok(s: str) -> bool {
    if len(s) != 3 {
        return false;
    }
    let b = to_bytes(s);
    return b[0] >= 49 && b[0] <= 53 && b[1] >= 48 && b[1] <= 57 &&
           b[2] >= 48 && b[2] <= 57;
}

// A completed header block for this stream: 1xx headers are skipped, the
// first non-1xx block is the response, a block after the body is the
// trailers. Returns whether the stream is finished.
fn pending_block(cn: Conn, p: Pending, ends_stream: bool) -> result[bool, str] {
    let dr = decode_block(cn.dec, p.block, MAX_HEADER_FIELDS);
    p.block = b"";
    guard let hs = dr else let e = err_of(dr) {
        return err("hpack: " + e);
    }
    if !p.got_final {
        let status = "";
        let fields: [Header] = [];
        for h in hs {
            if h.name == ":status" {
                if len(status) > 0 {
                    return err("response has two :status fields");
                }
                status = h.value;
            } else if strings.has_prefix(h.name, ":") {
                return err("response has request pseudo-header " + h.name);
            } else {
                push(fields, h);
            }
        }
        if !status_ok(status) {
            return err("response :status is missing or not three digits");
        }
        if strings.has_prefix(status, "1") {
            if ends_stream {
                return err("informational response ended the stream");
            }
            return ok(false);     // 1xx: the real response follows
        }
        p.status = status;
        p.headers = fields;
        p.got_final = true;
        if ends_stream {
            return pending_finish(p);
        }
        return ok(false);
    }
    // After the final response, a header block can only be trailers, and
    // trailers end the stream.
    if !ends_stream {
        return err("trailers did not end the stream");
    }
    for h in hs {
        if strings.has_prefix(h.name, ":") {
            return err("trailers carry pseudo-header " + h.name);
        }
    }
    p.trailers = hs;
    return pending_finish(p);
}

// RFC 9113 §8.1.1: a content-length the DATA does not add up to makes the
// response malformed.
fn pending_finish(p: Pending) -> result[bool, str] {
    for h in p.headers {
        if h.name == "content-length" {
            let n = to_int(h.value);
            guard let want = n else {
                return err("response content-length is not a number");
            }
            if want != len(p.body) {
                return err("response body length does not match content-length");
            }
        }
    }
    return ok(true);
}

// Feed one HEADERS, CONTINUATION or DATA frame for p's stream. DATA gives
// its octets back to both windows, as the server side does, so a large
// response keeps flowing. Returns whether the stream is finished.
fn pending_frame(cn: Conn, wch: chan[WMsg], p: Pending, f: Frame)
        -> result[bool, str] {
    if f.ftype == T_HEADERS {
        if p.collecting {
            return err("HEADERS while a header block was open");
        }
        let pr = strip_padding(f.payload, f.flags);
        guard let pay = pr else let e = err_of(pr) { return err(e); }
        if (f.flags & FLAG_PRIORITY) != 0 {
            if len(pay) < 5 {
                return err("HEADERS with PRIORITY but no priority field");
            }
            pay = pay[5..];
        }
        p.block = pay;
        p.block_ends_stream = (f.flags & FLAG_END_STREAM) != 0;
        p.collecting = (f.flags & FLAG_END_HEADERS) == 0;
        if p.collecting {
            return ok(false);
        }
        return pending_block(cn, p, p.block_ends_stream);
    }
    if f.ftype == T_CONTINUATION {
        if !p.collecting {
            return err("unexpected CONTINUATION");
        }
        p.block = p.block + f.payload;
        if len(p.block) > 65536 {
            return err("header block too large");
        }
        p.collecting = (f.flags & FLAG_END_HEADERS) == 0;
        if p.collecting {
            return ok(false);
        }
        return pending_block(cn, p, p.block_ends_stream);
    }
    if f.ftype == T_DATA {
        if !p.got_final || p.collecting {
            return err("DATA before the response headers");
        }
        let dr = strip_padding(f.payload, f.flags);
        guard let dat = dr else let e = err_of(dr) { return err(e); }
        if len(p.body) + len(dat) > p.max_body {
            return err("response body exceeds the caller's limit");
        }
        p.body = p.body + dat;
        let n = len(f.payload);
        let ends = (f.flags & FLAG_END_STREAM) != 0;
        if n > 0 {
            if ends {
                chan_send(wch, raw_msg(window_update(0, n)));
            } else {
                chan_send(wch, raw_msg(window_update(0, n) + window_update(p.stream, n)));
            }
        }
        if ends {
            return pending_finish(p);
        }
        return ok(false);
    }
    return err("unexpected frame type on a response stream");
}

// GOAWAY's last-stream-id: streams above it were never processed and may
// be retried on a new connection; at or below it they may still finish.
fn goaway_last(f: Frame) -> result[int, str] {
    if f.stream != 0 || len(f.payload) < 8 {
        return err("malformed GOAWAY");
    }
    return ok(be32(f.payload, 0) & 0x7fffffff);
}

// A connection-level frame on the client side. SETTINGS, PING and
// WINDOW_UPDATE are shared with the server (handle_control); the rest
// means something different to a client.
fn client_control(cn: Conn, wch: chan[WMsg], f: Frame) -> result[bool, str] {
    if f.ftype == T_PUSH_PROMISE {
        return err("server sent PUSH_PROMISE although push is disabled");
    }
    if f.ftype == T_SETTINGS || f.ftype == T_PING || f.ftype == T_PRIORITY ||
       (f.ftype == T_WINDOW_UPDATE) {
        return handle_control(cn, wch, f);
    }
    return ok(false);
}

// Read frames until `stream`'s response is complete. For a connection
// carrying one stream at a time; use client_start/client_call for more.
// `timeout_ns` bounds the whole response, and `max_body` its DATA.
pub fn client_read_response(cn: Conn, r: Reader, t: Transport,
                            wch: chan[WMsg], stream: int, timeout_ns: int,
                            max_body: int) -> result[Response, str] {
    if timeout_ns <= 0 || max_body < 0 {
        return err("http2 response: timeout must be positive and max_body non-negative");
    }
    let deadline = until_of(time.mono() + timeout_ns);
    let p = pending_new(stream, max_body);
    while true {
        let fr = read_frame(r, t, DEFAULT_MAX_FRAME, deadline);
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }
        let cr = client_control(cn, wch, f);
        guard let consumed = cr else let e = err_of(cr) {
            return err(e);
        }
        if consumed {
            continue;
        }
        if f.ftype == T_GOAWAY {
            let gl = goaway_last(f);
            guard let last = gl else let e = err_of(gl) { return err(e); }
            cn.gone = true;
            if stream > last {
                return err("http2 response: refused by GOAWAY; retry on a new connection");
            }
            continue;
        }
        if f.ftype == T_RST_STREAM {
            if f.stream == stream {
                if len(f.payload) != 4 {
                    return err("RST_STREAM payload must be 4 octets");
                }
                return err("http2 response: stream reset by peer, code " + to_str(be32(f.payload, 0)));
            }
            continue;
        }
        if f.stream != stream {
            return err("http2 response: frame for stream " + to_str(f.stream) +
                       " while reading stream " + to_str(stream));
        }
        let pr = pending_frame(cn, wch, p, f);
        guard let done = pr else let e = err_of(pr) {
            return err(e);
        }
        if done {
            return ok(pending_response(p));
        }
    }
    return err("unreachable");
}

// ---- many streams on one connection ------------------------------------
//
// One reader task per Client routes every frame to the stream it belongs
// to and hands each finished response to the task waiting for it, over
// that call's own channel. `lock` guards the call table and is held only
// to register, look up or remove a call. `send_lock` orders requests:
// stream ids must reach the wire in increasing order (RFC 9113 §5.1.1),
// so allocating an id and handing its HEADERS to the writer are one step.
// The reader never takes `send_lock`, so a slow writer delays callers,
// never the routing of responses; and the writer takes every message even
// after it fails (writer_drain), so no sender waits on it forever.

gc struct Call {
    p: Pending,
    reply: chan[result[Response, str]],
    deadline: int,
}

pub gc struct Client {
    cn: Conn,
    r: Reader,
    t: Transport,
    wch: chan[WMsg],
    lim: Limits,
    lock: mutex,
    send_lock: mutex,
    // Set by client_close: the reader stops at its next tick.
    stopping: bool,
    // The writer task signals its end here, and the reader closes this
    // when it has finished with the connection (see client_shut_down).
    writer_done: chan[bool],
    reader_done: chan[bool],
    calls: map[int]Call,
    slots: chan[bool],
    max_streams: int,
    closed: bool,
    failure: str,
}

// How often the reader wakes with no frame to read, to time calls out.
fn client_tick_ns() -> int {
    return 100000000;
}

// The connection's writer, signalling when it has stopped writing: the
// transport may be closed only after that, or bytes it still had queued
// could go out on a new connection that reused the fd number.
fn client_writer(t: Transport, wch: chan[WMsg], write_ns: int, done: chan[bool]) {
    writer_task(t, wch, write_ns);
    chan_send(done, true);
}

// Handshake on `t` and start the connection's writer and reader tasks.
// From here the Client owns `t`: its reader closes it, once, after both
// tasks have stopped (client_close waits for that). If the handshake
// fails, the writer has stopped before this returns and the caller still
// owns `t`.
pub fn client_start(t: Transport, lim: Limits) -> result[Client, str] {
    if lim.max_concurrent < 1 || lim.handshake <= 0 || lim.write <= 0 {
        return err("http2 client: max_concurrent, handshake and write limits must be positive");
    }
    let cn = conn_new();
    let r = reader_new();
    let wch: chan[WMsg] = make_chan(64);
    let writer_done: chan[bool] = make_chan(1);
    spawn client_writer(t, wch, lim.write, writer_done);
    let pr = client_preface(cn, r, t, wch, lim);
    guard let _p = pr else let e = err_of(pr) {
        chan_close(wch);
        chan_recv(writer_done);
        return err(e);
    }
    // The peer's limit as of its preface, capped by ours. A later SETTINGS
    // that lowers it is honoured by the peer refusing streams
    // (REFUSED_STREAM), which fails just those calls.
    let n = lim.max_concurrent;
    if cn.peer_max_streams >= 0 && cn.peer_max_streams < n {
        n = cn.peer_max_streams;
    }
    if n < 1 {
        chan_close(wch);
        chan_recv(writer_done);
        return err("http2 client: the server allows no concurrent streams");
    }
    let reader_done: chan[bool] = make_chan(1);
    let c = Client {
        cn: cn, r: r, t: t, wch: wch, lim: lim, lock: make_mutex(),
        send_lock: make_mutex(), stopping: false, writer_done: writer_done,
        reader_done: reader_done, calls: {}, slots: gate(n), max_streams: n,
        closed: false, failure: ""
    };
    spawn client_reader(c);
    return ok(c);
}

pub fn client_max_streams(c: Client) -> int {
    return c.max_streams;
}

// One request/response exchange on `c`, safe to call from many tasks at
// once. Waits for a free stream slot first. `timeout_ns` bounds the
// exchange from the moment its HEADERS are queued; `max_body` bounds the
// response DATA. Never retried: a transport error can arrive after the
// server acted, and only the caller knows whether that is safe to repeat.
pub fn client_call(c: Client, method: str, scheme: str, authority: str,
                   path: str, headers: [Header], body: bytes,
                   timeout_ns: int, max_body: int) -> result[Response, str] {
    if timeout_ns <= 0 || max_body < 0 {
        return err("http2 call: timeout must be positive and max_body non-negative");
    }
    gate_enter(c.slots);
    let reply: chan[result[Response, str]] = make_chan(1);
    mutex_lock(c.send_lock);
    mutex_lock(c.lock);
    let refused = c.closed;
    let problem = c.failure;
    let stream = c.cn.local_stream + 2;
    if c.cn.local_stream == 0 {
        stream = 1;
    }
    let made: result[WMsg, str] = err("http2 call: client is closed: " + problem);
    if !refused {
        made = client_request_msg(c.cn, stream, method, scheme, authority,
                                  path, headers, body);
    }
    if let _m = made {
        // Registered before the HEADERS leave, so the reader always finds
        // the call its response belongs to.
        c.calls[stream] = Call { p: pending_new(stream, max_body), reply: reply,
                                 deadline: (time.mono() as int) + timeout_ns };
    }
    mutex_unlock(c.lock);
    if let msg = made {
        chan_send(c.wch, msg);
    }
    mutex_unlock(c.send_lock);
    guard let _queued = made else let e = err_of(made) {
        gate_leave(c.slots);
        return err(e);
    }
    let got = chan_recv(reply);
    gate_leave(c.slots);
    guard let answer = got else {
        return err("http2 call: connection closed");
    }
    return answer;
}

// Stop taking calls, send GOAWAY and close the connection; calls in flight
// fail with "closed by the client". Returns once the connection is fully
// closed -- its reader and writer stopped and the transport closed -- so the
// fd number is free for reuse only then. Closing the fd while the reader was
// still parked on it let a new connection reuse the number under a waiter
// that was not its own, and that connection's reads stopped waking. Safe to
// call more than once, and after the connection failed on its own.
pub fn client_close(c: Client) {
    mutex_lock(c.send_lock);
    mutex_lock(c.lock);
    let was_open = !c.closed;
    c.closed = true;
    c.stopping = true;
    if was_open {
        c.failure = "closed by the client";
    }
    mutex_unlock(c.lock);
    if was_open {
        // An ordinary frame: the writer sends it before the reader closes
        // the channel, and the reader closes the transport only after the
        // writer has stopped.
        chan_send(c.wch, raw_msg(goaway(0, E_NO_ERROR, "")));
    }
    mutex_unlock(c.send_lock);
    // The reader sees `stopping` at its next tick (client_tick_ns).
    chan_recv(c.reader_done);
}

// Remove and answer one call. The lock is taken here, never held across
// the send: the reply channel has room for exactly this one answer.
fn client_finish(c: Client, stream: int, answer: result[Response, str]) {
    mutex_lock(c.lock);
    let found = has(c.calls, stream);
    let reply: chan[result[Response, str]] = make_chan(1);
    if found {
        reply = c.calls[stream].reply;
        del(c.calls, stream);
    }
    mutex_unlock(c.lock);
    if found {
        chan_send(reply, answer);
    }
}

// Fail every call still waiting, stop the client, and release the writer.
// Only the reader runs this, and once: callers check `closed` under the
// lock before sending, so after it nothing else sends to the writer. The
// GOAWAY's last-stream-id is 0 elsewhere for the same reason it is here:
// a client processes no server-initiated streams.
fn client_fail_all(c: Client, why: str) {
    mutex_lock(c.lock);
    c.closed = true;
    if len(c.failure) == 0 {
        c.failure = why;
    }
    let streams: [int] = [];
    for s, _call in c.calls {
        push(streams, s);
    }
    mutex_unlock(c.lock);
    for s in streams {
        client_finish(c, s, err("http2 call: " + why));
    }
    // Under send_lock: a client_close that saw the client open may be
    // about to queue its GOAWAY, and a send on a closed channel panics.
    mutex_lock(c.send_lock);
    chan_close(c.wch);
    mutex_unlock(c.send_lock);
}

// The reader's only way out: fail what is pending, let the writer finish
// (closing its channel ends it after whatever was queued, a GOAWAY
// included), and only then close the transport -- one task, after both
// have stopped -- and tell client_close.
fn client_shut_down(c: Client, why: str) {
    client_fail_all(c, why);
    chan_recv(c.writer_done);
    tr_close(c.t);
    chan_close(c.reader_done);
}

// Calls past their deadline: cancel the stream and answer with a timeout.
fn client_expire(c: Client) {
    let now = time.mono() as int;
    mutex_lock(c.lock);
    let late: [int] = [];
    for s, call in c.calls {
        if call.deadline <= now {
            push(late, s);
        }
    }
    mutex_unlock(c.lock);
    for s in late {
        chan_send(c.wch, raw_msg(rst_stream(s, E_CANCEL)));
        client_finish(c, s, err("timeout"));
    }
}

fn client_pending_of(c: Client, stream: int) -> opt[Pending] {
    mutex_lock(c.lock);
    let out: opt[Pending] = none;
    if has(c.calls, stream) {
        out = some(c.calls[stream].p);
    }
    mutex_unlock(c.lock);
    return out;
}

fn client_is_stopping(c: Client) -> bool {
    mutex_lock(c.lock);
    let stop = c.stopping;
    mutex_unlock(c.lock);
    return stop;
}

fn client_reader(c: Client) {
    // A header block for a stream nobody is waiting for any more (it
    // timed out) is still decoded, or HPACK state would drift and every
    // later response on the connection would decode wrongly.
    let orphan = pending_new(0, MAX_BODY);
    // The stream whose header block is open: CONTINUATION must follow it.
    let open_block = 0;
    while true {
        let fr = read_frame(c.r, c.t, DEFAULT_MAX_FRAME,
                            until_of(time.mono() + client_tick_ns()));
        if client_is_stopping(c) {
            client_shut_down(c, "closed by the client");
            return;
        }
        guard let f = fr else let e = err_of(fr) {
            if is_timeout(e) {
                client_expire(c);
                continue;
            }
            client_shut_down(c, e);
            return;
        }
        client_expire(c);
        let cr = client_control(c.cn, c.wch, f);
        guard let consumed = cr else let e = err_of(cr) {
            chan_send(c.wch, raw_msg(goaway(0, E_PROTOCOL_ERROR, e)));
            client_shut_down(c, e);
            return;
        }
        if consumed {
            continue;
        }
        if f.ftype == T_GOAWAY {
            let gl = goaway_last(f);
            guard let last = gl else let e = err_of(gl) {
                client_shut_down(c, e);
                return;
            }
            mutex_lock(c.lock);
            c.closed = true;
            c.failure = "server sent GOAWAY";
            let refused: [int] = [];
            for s, _call in c.calls {
                if s > last {
                    push(refused, s);
                }
            }
            mutex_unlock(c.lock);
            for s in refused {
                client_finish(c, s, err("http2 call: refused by GOAWAY; retry on a new connection"));
            }
            continue;
        }
        if f.ftype == T_RST_STREAM {
            if f.stream == 0 || len(f.payload) != 4 {
                client_shut_down(c, "malformed RST_STREAM");
                return;
            }
            client_finish(c, f.stream, err("http2 call: stream reset by peer, code " +
                                           to_str(be32(f.payload, 0))));
            continue;
        }
        if f.stream == 0 || (f.stream & 1) == 0 || f.stream > c.cn.local_stream {
            client_shut_down(c, "frame on a stream this client never opened");
            return;
        }
        if f.ftype == T_CONTINUATION && f.stream != open_block {
            client_shut_down(c, "CONTINUATION for a stream whose block is not open");
            return;
        }
        if open_block != 0 && f.stream != open_block {
            client_shut_down(c, "frame interleaved inside a header block");
            return;
        }
        let target = orphan;
        let found = client_pending_of(c, f.stream);
        if let p = found {
            target = p;
        } else {
            orphan.stream = f.stream;
            if f.ftype == T_DATA {
                // Nobody wants the octets, but the connection window
                // still has to be given back.
                if len(f.payload) > 0 {
                    chan_send(c.wch, raw_msg(window_update(0, len(f.payload))));
                }
                continue;
            }
            // Orphan header blocks are decoded and dropped, whatever their
            // position in the stream: reset the orphan so a block is
            // never mistaken for trailers or rejected for ordering.
            orphan.got_final = false;
        }
        let pr = pending_frame(c.cn, c.wch, target, f);
        open_block = 0;
        if target.collecting {
            open_block = f.stream;
        }
        guard let done = pr else let e = err_of(pr) {
            if let _w = found {
                chan_send(c.wch, raw_msg(rst_stream(f.stream, E_PROTOCOL_ERROR)));
                client_finish(c, f.stream, err("http2 call: " + e));
                continue;
            }
            // An orphan's 1xx or bad block is no one's problem but HPACK's,
            // and a decode failure there is a connection error.
            if strings.has_prefix(e, "hpack") {
                client_shut_down(c, e);
                return;
            }
            continue;
        }
        if done {
            if let _w = found {
                client_finish(c, f.stream, ok(pending_response(target)));
            }
        }
    }
}
