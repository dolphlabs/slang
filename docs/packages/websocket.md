# websocket

> Package websocket.

A WebSocket client (RFC 6455) over `ws://` and `wss://`, with
permessage-deflate (RFC 7692) when asked for. In the Autobahn
TestSuite's client run (`tests/live/websocket`, 517 cases), 440 cases
are OK, 3 INFORMATIONAL and 2 NON-STRICT, with no failures. The NON-STRICT
two are invalid UTF-8 inside one frame, caught when the frame is whole
rather than byte by byte. The 72 UNIMPLEMENTED are window-size variants
of permessage-deflate this client does not offer.

```slang
import "websocket";

let o = websocket.options();
o.protocols = ["v2.chat"];                       // offered; Conn.protocol is the server's pick
o.headers = ["Authorization: Bearer " + token];
o.ping_every = 20000000000;                      // keepalive: a ping every 20 s
o.compress = true;                               // permessage-deflate
let r = websocket.dial_with("wss://example.com/live", o, deadline);
guard let ws = r else let e = err_of(r) { panic(e); }

websocket.send_text(ws, "{\"subscribe\":\"prices\"}", deadline);
websocket.send_binary(ws, frame, deadline);
let mr = websocket.recv(ws, deadline);           // result[opt[Message], str]; none: the deadline passed
guard let got = mr else let e = err_of(mr) { panic(e); }
guard let m = got else { return; }
if m.kind == websocket.Kind.Text { handle(websocket.text(m)); }
websocket.close(ws, 1000, "bye", deadline);      // the close handshake
```

`recv` returns `Text`, `Binary` or `Close` messages, reassembled from
their fragments. It answers pings and consumes pongs as they arrive, and
answers the server's close before returning it. A deadline that passes
loses nothing: the next `recv` carries on, even partway through a frame.
One task reads at a time; any number may send, and a send is one whole
frame written under a lock, so frames from different tasks never
interleave.

**What it refuses.** Masked or reserved-bit frames, unknown opcodes,
fragmented or oversized control frames, lengths not in their shortest
form, continuations with nothing to continue, text that is not UTF-8
(checked per fragment as it arrives), close codes a peer may not send,
and messages over `max_message` (32 MiB by default, counted after
inflation, so a compression bomb is cut off). Each fails the connection
with the matching close code (1002, 1007, 1009). In the handshake: a
wrong `Sec-WebSocket-Accept`, a subprotocol or extension that was not
offered, and redirects. A redirect would send the handshake, and any
credentials in it, somewhere the caller did not name.

**Keepalive.** With `ping_every` set, a ping goes out each interval and a
connection whose ping goes a whole interval unanswered is closed;
`recv` then reports why. Pongs arrive through `recv`, so a connection
nobody reads cannot keep itself alive.

**Compression** is offered without context takeover in either direction.
The server must accept `server_no_context_takeover`, so each message it
sends inflates on its own. Each message this client sends is compressed
on its own too, as a sync-flushed stream with no final block
(`compress.deflate_raw_flush`), which a server keeping one decompressor
for the whole connection reads correctly. No 32 KiB window per direction
stays alive between messages. A message is sent compressed only when
that makes it smaller.

**Text with U+0000.** A `str` ends at its first zero byte, so
`websocket.text(m)` stops there. `m.data` holds every byte, and
`send_text_bytes` sends one.

Frames are masked with keys drawn from a 4 KiB pool of `crypto.rand`
bytes, refilled as it empties. A frame is built in one allocation by
`encoding.xor_mask`. Large frames are read in chunks and joined once.

## API

### `gc struct Message`

### `gc struct Options`

### `fn options() -> Options`

The defaults: no extra headers or subprotocols, 32 MiB messages, no compression, no keepalive pings.

### `gc struct Conn`

### `fn dial(url: str, deadline: until) -> result[Conn, str]`

Connect to url (ws:// or wss://) with the default options.

### `fn dial_with(url: str, o: Options, deadline: until) -> result[Conn, str]`

Connect, send the opening handshake, and check the server's answer.

### `fn send_text(c: Conn, text: str, deadline: until) -> result[bool, str]`

Send a text message.

### `fn send_text_bytes(c: Conn, data: bytes, deadline: until) -> result[bool, str]`

Send a text message given as bytes, checked to be UTF-8 first: for text holding U+0000, which a str cannot (it ends at the first zero byte), and for text already in a byte buffer.

### `fn send_binary(c: Conn, data: bytes, deadline: until) -> result[bool, str]`

Send a binary message.

### `fn ping(c: Conn, payload: bytes, deadline: until) -> result[bool, str]`

Send a ping (payload up to 125 bytes); the server's pong is consumed by recv. options().ping_every sends them on a schedule instead.

### `fn recv(c: Conn, deadline: until) -> result[opt[Message], str]`

The next message, or none when the deadline passes first (nothing is lost: a later call carries on). Pings are answered and pongs consumed on the way. A Close message means the server ended the connection; the handshake is answered and the next call is an error.

### `fn text(m: Message) -> str`

The text of a text message. A str ends at its first zero byte, so text holding U+0000 is cut there: m.data has every byte.

### `fn close(c: Conn, code: int, reason: str, deadline: until) -> result[bool, str]`

The close handshake: send a close frame with code (1000 normal, or 3000-4999 for applications) and a reason of at most 123 bytes, then wait for the server's close (until deadline) and close the socket. If another task is in recv, that task sees the server's answer as a Close message and this call returns once the frame is sent.

### `fn close_now(c: Conn)`

Close the socket now, with no close handshake: for a connection that is already broken or must stop at once.

### `fn is_open(c: Conn) -> bool`

Whether the connection is open (not closing or closed).

### `fn reason(c: Conn) -> str`

Why the connection ended, or "" while it is open.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
