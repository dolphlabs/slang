# nats

> Package nats.

A client for [NATS](https://nats.io): publish, subscribe (plain and queue
groups), headers, request/reply, flush and drain, keepalive, and automatic
reconnection with resubscription. It covers core NATS, not JetStream.

```slang
import "nats";

let r = nats.connect("nats://127.0.0.1:4222", deadline);
guard let nc = r else let e = err_of(r) { panic(e); }

let sr = nats.subscribe(nc, "orders.*");                  // or queue_subscribe(nc, subj, "workers")
guard let sub = sr else let e = err_of(sr) { panic(e); }
nats.publish(nc, "orders.new", b"{\"id\":1}");
let m = nats.next_msg(sub, deadline);                     // result[opt[Msg], str]: none at the deadline

let h: map[str][str] = {};
h["Trace-Id"] = ["abc"];
nats.publish_headers(nc, "audit", h, body);

let reply = nats.request(nc, "pricing.quote", b"BTC", deadline);   // result[Msg, str]
nats.respond(nc, request_msg, b"42");
nats.drain(nc, deadline);                                 // unsubscribe, let in-flight arrive, close
```

URLs are `nats://host:port` or `tls://host:port`, optionally with
`user:pass@` or `token@`. `options(url)` gives an `Options` to adjust before
`connect_with`:
- **Servers and identity:** `servers` (tried in turn), `name`.
- **Authentication:** `user`/`pass`, `token`, `nkey_seed`, or a user JWT and
  seed via `with_creds(o, creds_file_text)`. NKeys sign the server's nonce
  with Ed25519.
- **TLS:** `tls`, `ca_path`, and `tls_first` for servers with
  `handshake_first`. By default `INFO` arrives in clear and the client
  upgrades before sending `CONNECT`, so credentials travel only over TLS.
- **Delivery and keepalive:** `pending` (see below), `ping_interval`,
  `max_pings_out`.
- **Reconnection:** `reconnect`, `max_reconnects`, `reconnect_wait`,
  `reconnect_buffer`.

**One connection, one reader.** A reader task parses what the server sends
and hands each message to its subscription's channel, so `next_msg` parks
rather than polls. A subscriber that falls more than `pending` (default
1,024) messages behind loses the newest ones and counts them in
`sub.dropped`, rather than stalling every other subscription. This is the
NATS "slow consumer" rule.

**Deadlines.** Each connection has one timer task that is parked while
nothing waits on a deadline; deadlines resolve to within 10 ms.

**Writes coalesce.** Publishes append to one buffer, and a flusher task
writes it out after a short wait (20 µs, or 200 µs while a publisher is
streaming). A publisher that fills 32 KB first writes it itself.

**Reconnection.** When the connection breaks, or the server stops answering
pings, the reader redials the servers in turn with jittered backoff, sends
`CONNECT` and every live `SUB` again, then replays what was published in
the meantime, up to `reconnect_buffer` (8 MiB). Delivery is at most once,
as in core NATS: a message written into a connection just as it broke is
lost. `reconnects(nc)`, `is_connected(nc)` and `last_error(nc)` report the
state.

`request` uses one shared inbox subscription for every request on the
connection. If no subscriber is listening, the server's "no responders"
status makes it fail at once rather than at its deadline. A `-ERR
'Permissions Violation'` leaves the connection up; any other `-ERR` or a
malformed frame drops and redials it. Subjects are validated (no
whitespace, no empty tokens, no wildcards in a publish), and header names
and values are refused if they would inject protocol lines.

## API

### `gc struct Options`

### `fn options(url: str) -> Options`

Defaults for one server URL: nats://host:port, tls://host:port (TLS from the first byte) or nats://user:pass@host:port / nats://token@host.

### `fn with_creds(o: Options, creds_text: str) -> result[Options, str]`

Options with the user JWT and nkey seed of a .creds file.

### `gc struct Msg`

### `gc struct Sub`

### `gc struct Conn`

### `fn connect(url: str, deadline: until) -> result[Conn, str]`

Connect to url (see options).

### `fn connect_with(o: Options, deadline: until) -> result[Conn, str]`

### `fn publish(nc: Conn, subject: str, data: bytes) -> result[bool, str]`

### `fn publish_reply(nc: Conn, subject: str, reply: str, data: bytes) -> result[bool, str]`

### `fn publish_headers(nc: Conn, subject: str, headers: map[str][str], data: bytes) -> result[bool, str]`

Publish with headers (each key may carry several values).

### `fn publish_full(nc: Conn, subject: str, reply: str, headers: map[str][str], data: bytes) -> result[bool, str]`

### `fn subscribe(nc: Conn, subject: str) -> result[Sub, str]`

### `fn queue_subscribe(nc: Conn, subject: str, queue: str) -> result[Sub, str]`

Members of one queue group share the messages: each goes to one of them.

### `fn next_msg(sub: Sub, deadline: until) -> result[opt[Msg], str]`

The next message, waiting until deadline: none when the deadline passes or the subscription has ended (unsubscribed, max reached, connection closed).

### `fn unsubscribe(sub: Sub) -> result[bool, str]`

### `fn auto_unsubscribe(sub: Sub, max: int) -> result[bool, str]`

End the subscription by itself after max more messages.

### `fn request(nc: Conn, subject: str, data: bytes, deadline: until) -> result[Msg, str]`

Publish data to subject with a fresh reply subject and wait for the first reply. "no responders" (status 503, when nothing listens) is an error at once instead of a timeout.

### `fn request_headers(nc: Conn, subject: str, headers: map[str][str], data: bytes, deadline: until) -> result[Msg, str]`

### `fn respond(nc: Conn, req: Msg, data: bytes) -> result[bool, str]`

Reply to a request message.

### `fn flush(nc: Conn, deadline: until) -> result[bool, str]`

Wait until the server has processed everything sent so far (a PING round trip).

### `fn drain(nc: Conn, deadline: until) -> result[bool, str]`

Unsubscribe everything, let what is in flight arrive, then close.

### `fn close(nc: Conn)`

### `fn last_error(nc: Conn) -> str`

Why the connection is closed or last broke ("" while healthy).

### `fn is_connected(nc: Conn) -> bool`

### `fn reconnects(nc: Conn) -> int`

### `fn nkey_seed_raw(seed: str) -> result[bytes, str]`

The 32-byte Ed25519 seed inside a user seed ("SU...").

### `fn nkey_public(seed: str) -> result[str, str]`

The public key ("U...") for a user seed.

### `fn nkey_encode_seed(raw: bytes) -> result[str, str]`

A user seed ("SU...") for a 32-byte Ed25519 seed: for tests and tools.

### `fn nkey_sign_nonce(seed: str, nonce: str) -> result[str, str]`

The base64url signature of a server nonce, for CONNECT's "sig".

### `fn parse_creds(text: str) -> result[[str], str]`

The user JWT and the seed from a .creds file (two armoured blocks).

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
