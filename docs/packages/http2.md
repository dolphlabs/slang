# http2

> Package http2.

HTTP/2 framing and HPACK header compression (RFC 9113, RFC 7541),
written in slang — the frame codec is what the bitwise operators were
added for.

```slang
import "http2";

let f = http2.decode(buf, 0, 16384);        // one frame, bounds-checked
guard let fr = f else let e = err_of(f) { return; }

let d = http2.decoder_new(4096);            // per-connection HPACK state
let hr = http2.decode_block(d, fr.payload, 64);
guard let hs = hr else let e = err_of(hr) { return; }
for i in 0..len(hs) {
    println(hs[i].name + ": " + hs[i].value);
}
```

Frame layer: `decode` / `encode` / `header_bytes`, the reserved bit
masked off the stream id as the RFC requires, `strip_padding`, and the
common control frames (`settings_frame`, `settings_ack`, `ping_ack`,
`rst_stream`, `goaway`, `window_update`).

HPACK: prefix integers, string literals, the 61-entry static table, a
dynamic table with the RFC's +32-per-entry accounting and eviction, and
a **canonical Huffman decoder**. Header blocks decode through
`decode_block`; `encode_block` builds one.

The encoder is deliberately **stateless** — every field goes out as a
static-table index or a literal *without* indexing, and nothing is added
to a dynamic table on the encode side. That is conformant and it removes
a whole bug class: an encoder's dynamic table must stay in lockstep with
the peer's decoder table, and any drift silently corrupts every later
block on the connection.

Bounds against hostile peers: a frame longer than the advertised
`SETTINGS_MAX_FRAME_SIZE` is refused before allocating, `decode_block`
takes a `max_headers` cap (a small compressed block can otherwise expand
without limit), a Dynamic Table Size Update above the agreed maximum is
rejected, and NUL in a field name or value is the protocol error RFC
9113 §8.2.1 says it is. Huffman padding must be under 8 bits and all
ones, and EOS inside a string is refused.

Validated against **nghttp2** — the HPACK implementation curl and the
browser stacks use — in both directions: blocks it produces decode here,
and blocks produced here inflate there. Those fixtures are baked into
`tests/http2` as literals, so the suite needs no nghttp2 to run.

**Connection layer, with concurrent streams.** One task reads frames and
dispatches each request to its own `spawn`ed handler; every byte leaving
the connection goes through a single writer task fed by a `chan[bytes]`.
No mutex is involved, and none is needed: each channel message is a
complete frame sequence written with one `net.send`, so handlers cannot
interleave inside a frame, and a HEADERS block plus its CONTINUATIONs
stays contiguous by construction (RFC 9113 §6.2) rather than by careful
ordering. Frames for different streams interleave at frame boundaries,
which is what multiplexing means.

Measured: four 500ms requests multiplexed on one connection complete in
**0.53s**; served one at a time they would take about 2.0s.

The connection is addressed by a **`Transport`**, not a `link`. `link`
is move-only, so `spawn writer_task(c)` consumes it and the reader can
no longer use it — the two-task design is impossible with that type. A
`Transport` is freely copyable, and one reader plus one writer in
opposite directions on a socket is safe. `net.recv` also returns
`bytes` directly, so no byte-at-a-time copy sits on the read path.

A `Transport` is either a plain fd or a TLS handle, and everything above
it is identical either way:

```slang
http2.transport_fd(fd)     // h2c: cleartext, prior knowledge
http2.transport_tls(ssl)   // h2 over TLS, from net.tls_accept
```

```slang
fn handle(stream: i32, path: str, wch: chan[http2.WMsg]) {
    let hs: [http2.Header] = [];
    // The body goes over UNFRAMED: the writer owns the peer's windows,
    // so it decides how it is cut into DATA frames and when each may go.
    chan_send(wch, http2.response_msg(stream as int, "200", hs,
                                      to_bytes("hello")));
}

fn serve(fd: i32) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(32);
    let lim = http2.default_limits();
    spawn http2.writer_task(fd, wch, lim.write);

    guard let _p = http2.accept_preface(rd, fd, wch,
            until_of(time.mono() + lim.handshake)) else { return; }
    while true {
        let rr = http2.read_request(cn, rd, fd, wch, lim);
        guard let req = rr else let e = err_of(rr) {
            if http2.is_timeout(e) { /* slow peer; shed it */ }
            chan_close(wch);
            return;
        }
        spawn handle(req.stream as i32, req.path, wch);
    }
}
```

Verified against real `curl --http2-prior-knowledge`: GET, POST with a
body, five requests multiplexed on one connection, and a 64KB upload
that exercises DATA chunking and flow-control `WINDOW_UPDATE`.

##### Deadlines

Every read and every write is bounded, so a peer that connects and then
dribbles — or one that stops reading our responses — is disconnected
rather than left holding a task forever. `http2.Limits` carries four
separate budgets because they defend against four different peers:

| Budget | Covers |
|---|---|
| `handshake` | connect → valid client preface |
| `idle` | no request in flight, waiting for the next frame |
| `request` | first HEADERS octet → END_STREAM |
| `write` | one `writer_task` send |

`idle` is deliberately generous (2 minutes by default): an HTTP/2
connection sitting open with no streams is completely normal, and timing
it out aggressively breaks correct clients. `request` is the strict one
and applies to the request **as a whole** — it is never refreshed by
incoming frames, so dribbling DATA one octet at a time cannot extend it.
That distinction is the whole defence; a per-read timeout would never
fire against a slowloris, because every individual read makes progress.

`http2.is_timeout(e)` distinguishes a slow peer from a broken one, so a
server can answer the first with `GOAWAY` / `E_ENHANCE_YOUR_CALM`.
`tests/http2_deadline` runs all three attacker shapes — silent,
idle-after-handshake, and octet-at-a-time dribbling — against a server
with sub-second budgets and requires all three to be shed.

##### Flow control

DATA is flow-controlled at two levels, per-stream and per-connection
(RFC 9113 §5.2), and the server may not exceed either. Both windows live
in the writer task, because they are connection-wide state that the
**read** side replenishes (`WINDOW_UPDATE` arrives there) and the
**write** side spends — routing both into one task is what makes the
accounting correct without a lock.

A handler therefore hands over its body unframed and moves on. If the
peer's window is too small, the *body* waits in the writer's queue, not
the handler's task — a peer advertising a tiny window costs a queue
entry rather than a parked task.

`SETTINGS_INITIAL_WINDOW_SIZE` adjusts every open stream's window by the
delta rather than resetting it, and does not touch the connection window
(§6.9.2). A `WINDOW_UPDATE` that would push a window past 2³¹−1 is a
`FLOW_CONTROL_ERROR` and ends the connection with a `GOAWAY` rather than
being clamped.

`tests/http2_flow` drives both levels: a client advertising a 100-octet
stream window against a 5000-octet body, and a client with a large
stream window against a 100000-octet body where the default 65535
connection window is what binds. Each phase checks the exact octet the
server stops at, that it resumes for exactly the credit granted, and
that the resumed bytes carry the right content for their absolute offset
in the body.

##### TLS and ALPN

Browsers speak HTTP/2 **only** over TLS, and only when ALPN negotiates
it — there is no in-band upgrade in a browser. So h2c alone, however
conformant, cannot serve one.

The server advertises what it can speak, and then checks what was
actually chosen:

```slang
net.tls_ctx_alpn(sctx, "h2,http/1.1");     // offer both, h2 preferred
// ... net.tls_accept(lfd, sctx) -> ssl
if !http2.alpn_is_h2(net.tls_alpn(ssl)) {
    // the peer picked http/1.1; serve it as HTTP/1.1 or hang up
}
let t = http2.transport_tls(ssl);
```

Checking is not optional politeness. A server that offers `http/1.1`
must expect to get it, and feeding an HTTP/1.1 client into the frame
parser produces `bad connection preface` — true, but a poor explanation
of what went wrong.

`tests/http2_tls` runs both halves over a real handshake: h2 frames
across `SSL_read`/`SSL_write`, and an http/1.1-only client being
declined rather than misparsed.

##### Interop

Checked against **Go's `golang.org/x/net/http2`**, which shares no
ancestry with nghttp2 (curl's stack, and where the HPACK fixtures came
from) — agreement between two implementations that share code proves
less than it appears to. It covers a GET, a 50KB POST, a 200KB response
verified byte-for-byte against its absolute offset, and six concurrent
streams on one connection. Run it with `sh tests/http2_interop/run.sh`;
it skips cleanly without a Go toolchain.

##### Stream floods

The connection layer cannot cap concurrency by itself: it does not spawn
the handlers, *you* do. (slang has function values now, so handing it a
callback would compile — but a callback would only move the same
question inside, and the gate below is the answer either way.) So the
bound is a **gate** — a token channel you hold.
`gate_enter` takes a token and blocks when none are left, `gate_leave`
returns one, and that blocking is the backpressure: the reader stops
pulling frames while every slot is busy.

Without it, a peer that sends 1000 requests down one connection gets
1000 concurrent handler tasks — measured, against a
`SETTINGS_MAX_CONCURRENT_STREAMS` of 100 that we were advertising and
not keeping. Advertising a limit you do not enforce is worse than
advertising none, because peers size their behaviour by it.

`gate_drain` also makes shutdown safe. Closing the writer channel while
handlers are still in flight panics them with *send on closed channel*,
and draining is what knows when none are left.

**The one rule: `gate_leave` must run on every path out of a handler**,
error returns included. A lost token permanently shrinks that
connection's capacity; losing all of them wedges that one connection —
bounded and visible, not a crash, but not something to leave in.

Separately, `RST_STREAM` is counted. A peer that opens a stream and
cancels it immediately (CVE-2023-44487, *Rapid Reset*) never looks
concurrent, so a cap alone never trips; after a burst of 100 free
cancellations, a peer whose resets outnumber half of what it opened
ends the connection. Cancelling is legitimate — a browser navigating
away resets its in-flight streams — so the burst and the ratio are both
needed to tell a normal client from a flood.

`tests/http2_flood` drives both shapes, resetting and not, and fails if
either exceeds the cap.

##### Known gaps

`PRIORITY` is validated but not acted on: it is deprecated in RFC 9113
§5.3.2, so ignoring the prioritisation is conformant, but a malformed
frame is still rejected as the connection error it is (§6.3) rather than
waved through to desync the stream. No browser has been run against the
TLS path yet — the machinery is there and tested against slang's own
client, but a real browser is different evidence.

## API

### `let W_RAW = 0;       // pre-built frames, not flow controlled`

---- writer messages -------------------------------------------------  Everything the writer task needs arrives on ONE channel, tagged.  When this was written slang had no `select`, so a writer watching both "here is a response" and "the peer granted more window" on two channels could only ever block on one of them. `select` exists now and would compile -- but the single tagged stream is still the better design here, and stays. Two channels would make the ORDER between a grant and a body a race the writer has to reason about; one channel makes it the order they were sent, for free, and leaves the writer an ordinary state machine with a single blocking point.

### `let W_BODY = 1;      // a response: HEADERS now, DATA as window allows`

### `let W_GRANT = 2;     // peer's WINDOW_UPDATE: `n` octets to `stream``

### `let W_INITIAL = 3;   // peer's SETTINGS_INITIAL_WINDOW_SIZE is now `n``

### `let W_MAXFRAME = 4;  // peer's SETTINGS_MAX_FRAME_SIZE is now `n``

### `gc struct WMsg`

### `fn raw_msg(b: bytes) -> WMsg`

### `fn grant_msg(stream: int, n: int) -> WMsg`

### `fn response_msg(stream: int, status: str, extra: [Header],`

Build a response. The body is handed over UNFRAMED: the writer owns the peer's window and its max frame size, so it -- not the handler -- decides how the body is cut into DATA frames and when each may go.

### `gc struct Limits`

---- deadlines -------------------------------------------------------  Four separate budgets, in nanoseconds, because they defend against four different peers and want wildly different numbers.  `idle` is the generous one on purpose: an HTTP/2 connection sitting open with no streams is completely normal -- that is the whole point of connection reuse -- so timing it out aggressively breaks correct clients. `request` is the strict one: once a client has started a request it must finish it, and dribbling DATA forever is exactly the slowloris shape.

### `fn default_limits() -> Limits`

### `fn is_timeout(e: str) -> bool`

The reserved error string net.recv_until / net.send_until return when a deadline passes. Exposed as a predicate so callers can react to a slow peer (GOAWAY with ENHANCE_YOUR_CALM) differently from a broken one, without hardcoding the text.

### `let DEFAULT_MAX_FRAME = 16384;`

### `let DEFAULT_WINDOW = 65535;`

### `let MAX_HEADER_FIELDS = 128;`

Our own limits, advertised in SETTINGS and enforced on receipt.

### `let MAX_BODY = 1048576;`

### `let RESET_BURST = 100;`

---- Rapid Reset (CVE-2023-44487) ------------------------------------  A peer opens a stream and immediately RST_STREAMs it. From its side the stream is closed the instant it opens, so a concurrency limit never sees it -- while the server has already done the HPACK decode and, in most designs, started the work. Repeat and the server is driven at whatever rate the attacker can write frames.  Cancelling a request IS legitimate: a browser navigating away resets its in-flight streams, and a client that gives up on a slow endpoint should. So a flat "no resets" rule would break correct clients. What is not legitimate is resetting nearly everything you open, forever.  Hence a burst plus a ratio: RESET_BURST cancellations are free, and after that a peer whose resets outnumber half of what it opened is ending the connection. A browser that abandons a page load trips neither; a Rapid Reset flood resets every stream it opens, so it trips both the moment the burst is spent.

### `gc struct Conn`

### `gc struct Req`

### `fn conn_new() -> Conn`

### `fn our_settings() -> bytes`

Our SETTINGS: a modest frame size, and push disabled because server push is deprecated and no current client wants it.

### `fn gate(n: int) -> chan[bool]`

---- the stream gate -------------------------------------------------  The connection layer cannot cap concurrency on its own: it does not spawn the handlers, the CALLER does. (slang has function values now, so handing it a callback would compile -- but that only moves the same question inside, and the answer would still be this.) So the bound lives in a token channel the caller holds, and this is the mechanism plus the vocabulary for it.  A gate is a chan[bool] holding `n` tokens. gate_enter takes one and blocks when none are left; gate_leave puts one back. That blocking IS the backpressure -- the reader stops pulling frames while every slot is busy, which is the correct answer to "more work than I can do", and far better than the alternative measured before this existed: 3002 concurrent handler tasks from a peer we had told our limit was 100.  It also solves shutdown. Closing the writer channel while handlers are still in flight panics them with "send on closed channel", and nothing else could tell whether any were left. gate_drain waits for every token to come home, so the close is safe by construction.  The one rule: gate_leave must run on EVERY path out of a handler, including error returns. A lost token permanently shrinks the connection's capacity, and losing all of them wedges that connection (only that one -- the failure is bounded and visible, not a crash).

### `fn gate_enter(g: chan[bool])`

### `fn gate_leave(g: chan[bool])`

### `fn gate_drain(g: chan[bool], n: int)`

Wait until every handler has finished, by collecting all `n` tokens. Call before chan_close on the writer channel.

### `gc struct Transport`

---- transport -------------------------------------------------------  h2 runs over cleartext TCP (h2c, prior knowledge) or over TLS, and the two are reached through different runtime calls: net.recv_until on an fd, net.tls_recv_until on an SSL handle. Everything above this point is identical either way, so the difference is confined to one struct and two functions rather than duplicated through the whole layer.  This matters beyond tidiness: browsers speak HTTP/2 ONLY over TLS with ALPN, so a connection layer that can only do fds cannot serve a browser at all, however conformant the rest of it is.

### `fn transport_fd(fd: i32) -> Transport`

h2c: cleartext, prior knowledge. curl --http2-prior-knowledge, and Go's http2.Transport with AllowHTTP.

### `fn transport_tls(ssl: rawptr) -> Transport`

h2 over TLS. The handle comes from net.tls_accept, and the caller is responsible for having negotiated "h2" via ALPN first -- see alpn_is_h2 below.

### `fn tr_close(t: Transport)`

### `fn alpn_is_h2(proto: str) -> bool`

RFC 7301 §3.1: the peer either selected "h2" or it did not. A server that advertised h2 and http/1.1 must look, because a browser offered both and may well have picked http/1.1 -- feeding an HTTP/1.1 client into this layer produces "bad connection preface", which is true but unhelpful.

### `gc struct Reader`

### `fn reader_new() -> Reader`

### `fn read_frame(r: Reader, t: Transport, max_frame: int, u: until)`

Pull bytes until at least one complete frame is buffered, then return it and keep the remainder. Note the `&mut *c` at every site below that forwards this borrow: passing `c` directly MOVES it, so the second call would fail with "use of moved value". Reborrowing keeps the caller's borrow usable.  `u` bounds the WHOLE call, not each recv: a peer that sends one octet every second must still finish the frame inside the budget, which is what makes this a slowloris defence rather than a keepalive check. Pass until_never() only where blocking forever is genuinely intended.

### `fn accept_preface(r: Reader, t: Transport, wch: chan[WMsg], u: until)`

Verify the 24-byte client connection preface and send ours.

### `fn read_request(cn: Conn, r: Reader, t: Transport, wch: chan[WMsg],`

Read frames until one complete request has arrived.  Two clocks, switched at the first HEADERS. Before it the connection is idle and gets the generous `idle` budget, refreshed by each control frame that arrives -- a client PINGing a kept-alive connection is behaving correctly and must not be disconnected. After it the strict `request` budget applies to the request as a WHOLE and is never refreshed, so no amount of dribbled DATA or CONTINUATION can extend it.

### `fn writer_task(t: Transport, wch: chan[WMsg], write_ns: int)`

Owns the write side, and with it the peer's send windows.  Flow control has to live here rather than in the handlers. The window is a property of the CONNECTION, shared by every concurrent stream, so no handler can decide on its own whether it may send -- and the WINDOW_UPDATE that grants credit arrives on the read side, in a different task entirely. Routing both into this one task is what lets the accounting be correct without a lock at all. slang does have a mutex now, but reaching for one here would be the worse design: it would serialise the writers without making the window arithmetic any less shared.  A blocked stream parks its BODY here, not its task: the handler hands the response over and moves on, so a peer with a tiny window costs a queue entry rather than a live task.

### `fn respond(cn: Conn, wch: chan[WMsg], stream: int, status: str,`

Enqueue a response for `stream`. Every write on the connection goes through the writer task, so there is deliberately no direct-write variant: one would be able to interleave with a handler mid-frame.

### `fn send_reset(wch: chan[WMsg], stream: int, code: int)`

### `fn send_goaway(wch: chan[WMsg], last_stream: int, code: int, msg: str)`

### `let FRAME_HEADER_LEN = 9;`

### `let T_DATA = 0x0;`

Frame types (RFC 9113 §6). PUSH_PROMISE is parsed but never sent: server push is deprecated and no major client accepts it any more.

### `let T_HEADERS = 0x1;`

### `let T_PRIORITY = 0x2;`

### `let T_RST_STREAM = 0x3;`

### `let T_SETTINGS = 0x4;`

### `let T_PUSH_PROMISE = 0x5;`

### `let T_PING = 0x6;`

### `let T_GOAWAY = 0x7;`

### `let T_WINDOW_UPDATE = 0x8;`

### `let T_CONTINUATION = 0x9;`

### `let FLAG_END_STREAM = 0x1;`

Flags. The same bit means different things per frame type, which is why these are named by type: 0x1 is END_STREAM on DATA/HEADERS but ACK on SETTINGS/PING.

### `let FLAG_ACK = 0x1;`

### `let FLAG_END_HEADERS = 0x4;`

### `let FLAG_PADDED = 0x8;`

### `let FLAG_PRIORITY = 0x20;`

### `let E_NO_ERROR = 0x0;`

Error codes (RFC 9113 §7).

### `let E_PROTOCOL_ERROR = 0x1;`

### `let E_INTERNAL_ERROR = 0x2;`

### `let E_FLOW_CONTROL_ERROR = 0x3;`

### `let E_SETTINGS_TIMEOUT = 0x4;`

### `let E_STREAM_CLOSED = 0x5;`

### `let E_FRAME_SIZE_ERROR = 0x6;`

### `let E_REFUSED_STREAM = 0x7;`

### `let E_CANCEL = 0x8;`

### `let E_COMPRESSION_ERROR = 0x9;`

### `let E_CONNECT_ERROR = 0xa;`

### `let E_ENHANCE_YOUR_CALM = 0xb;`

### `let E_INADEQUATE_SECURITY = 0xc;`

### `let E_HTTP_1_1_REQUIRED = 0xd;`

### `let S_HEADER_TABLE_SIZE = 0x1;`

Settings parameters (RFC 9113 §6.5.2).

### `let S_ENABLE_PUSH = 0x2;`

### `let S_MAX_CONCURRENT_STREAMS = 0x3;`

### `let S_INITIAL_WINDOW_SIZE = 0x4;`

### `let S_MAX_FRAME_SIZE = 0x5;`

### `let S_MAX_HEADER_LIST_SIZE = 0x6;`

### `fn preface() -> bytes`

The connection preface a client must send first (RFC 9113 §3.4).

### `gc struct Frame`

### `fn be16(b: bytes, off: int) -> int`

### `fn be24(b: bytes, off: int) -> int`

### `fn be32(b: bytes, off: int) -> int`

### `fn put16(v: int) -> bytes`

### `fn put24(v: int) -> bytes`

### `fn put32(v: int) -> bytes`

### `fn header_bytes(ftype: int, flags: int, stream: int, plen: int) -> bytes`

Serialize a frame header. The caller appends the payload.

### `fn encode(f: Frame) -> bytes`

### `fn peek_length(b: bytes, off: int) -> int`

Payload length of the frame starting at `off`, or -1 if the 9-byte header is not fully buffered yet.

### `fn decode(b: bytes, off: int, max_frame: int) -> result[Frame, str]`

Decode one frame at `off`. `max_frame` is our advertised SETTINGS_MAX_FRAME_SIZE: a peer exceeding it is a connection error, and checking here keeps a bogus length from driving a huge allocation.

### `fn strip_padding(payload: bytes, flags: int) -> result[bytes, str]`

Strip padding from a DATA or HEADERS payload when FLAG_PADDED is set: one length octet, then the field, then that many padding octets.

### `fn settings_ack() -> bytes`

### `fn ping_ack(opaque: bytes) -> bytes`

### `fn rst_stream(stream: int, code: int) -> bytes`

### `fn goaway(last_stream: int, code: int, debug: str) -> bytes`

### `fn window_update(stream: int, increment: int) -> bytes`

### `fn settings_frame(ids: [int], vals: [int]) -> bytes`

One SETTINGS entry is a 16-bit identifier and a 32-bit value.

### `gc struct Decoder`

### `fn decoder_new(cap: int) -> Decoder`

### `fn decode_block(d: Decoder, b: bytes, max_headers: int)`

Decode one complete header block. `max_headers` caps how many fields a peer may send: without it a small compressed block can expand into an unbounded list, which is the HPACK bomb.

### `fn encode_header(name: str, value: str) -> bytes`

### `fn encode_block(hs: [Header]) -> bytes`

### `gc struct Header`

### `gc struct Table`

A decoder's dynamic table. Bounded by `cap` octets, where each entry costs len(name) + len(value) + 32 (RFC 7541 §4.1); the constant accounts for per-entry overhead so a peer cannot exhaust memory with many tiny headers.

### `fn table_new(cap: int) -> Table`

### `fn table_add(t: Table, name: str, value: str)`

### `fn table_resize(t: Table, cap: int)`

### `gc struct IntRead`

### `fn read_int(b: bytes, off: int, prefix_bits: int) -> result[IntRead, str]`

### `fn write_int(v: int, prefix_bits: int, first: int) -> bytes`

`first` supplies the bits ABOVE the prefix (the representation tag).

### `gc struct StrRead`

### `fn read_string(h: Huff, b: bytes, off: int) -> result[StrRead, str]`

### `fn write_string(s: str) -> bytes`

Always emitted as a raw literal, never Huffman-coded. That is fully legal (the H bit says which), costs a few bytes per response, and avoids shipping an encoder table for a saving the transport layer mostly recovers anyway.

### `gc struct Huff`

### `fn huff_new() -> Huff`

### `fn huff_decode(h: Huff, src: bytes) -> result[bytes, str]`

Decode a Huffman-coded byte string to BYTES, not str.  Returning str here would be a silent data-loss bug: symbol 0 is NUL, and to_str truncates there, so a value containing \x00 came back empty. Header field values are byte sequences on the wire; the caller decides whether to reject NUL (read_string does) rather than having the codec quietly drop everything after it.  Padding rules (RFC 7541 §5.2) are enforced rather than ignored: the tail must be fewer than 8 bits, must be all ones, and must not encode a symbol. A decoder that skips these accepts streams a conforming one rejects, which is how HPACK implementations end up disagreeing.

### `let HUFF_MAX_BITS = 30;`

### `let HUFF_EOS = 256;`

### `fn huff_counts() -> [int]`

counts[l] = number of codes of length l (index 0..30; 0..4 are zero)

### `fn huff_symbols() -> [int]`

symbols in canonical order: all 5-bit codes, then 6-bit, and so on

### `let STATIC_LEN = 61;`

### `fn static_name(idx: int) -> str`

### `fn static_value(idx: int) -> str`

### `fn static_find(name: str, value: str) -> int`

Index of an exact name+value match, or 0. Used by the encoder to send a one-byte indexed field for the common cases (:status 200, :method GET) instead of a literal.

### `fn static_find_name(name: str) -> int`

Index of any entry with this name, or 0 -- lets the encoder reference a known name and send only the value as a literal.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
