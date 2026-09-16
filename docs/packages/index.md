# Packages

> The standard library, and how imports resolve.

## Standard packages

`time`, `net`, `json`, `proc`, `fs`, `log`, `crypto`, `sql`, `regex`,
`os`, `strings`, `encoding` and `compress` are compiler-provided native packages — no source files, just
`import "time";` / `import "net";` / `import "json";` / `import "proc";`
/ `import "fs";` / `import "log";` / `import "crypto";` / `import "sql";`
/ `import "regex";` / `import "encoding";` like any other package.

`http`, `httpc`, `http2` and `byteutil` are slang-source stdlib packages under `stdlib/`.
`import "http"` / `import "byteutil"` resolve to a local directory first,
then a native package, then `stdlib/<path>` (`SLANG_STDLIB` or the
compiler's `SLANG_STDLIB_DIR`).

#### `time`

```slang
import "time";

let t0 = time.mono();     // monotonic clock; a `duration` (int64 ns)
time.sleep(20000000);     // sleep for a duration (ns)
let elapsed = time.mono() - t0;   // duration arithmetic
let deadline = time.mono() + 5000000;  // timeout math for net calls

let wall = time.wall();   // unix epoch time in nanoseconds
```

#### `net`

TCP listener/dialer built on `bytes` and fixed-width ints; every
fallible call returns a `result[_, str]` unwrapped with `guard let`.

```slang
import "net";

let lr: result[i32, str] = net.listen(8080);   // 0 = ephemeral port
guard let lfd = lr else { exit(1); }

let pr: result[i32, str] = net.port(lfd);      // assigned port number

let ar: result[i32, str] = net.accept(lfd);    // blocks until a peer connects
guard let cfd = ar else { exit(1); }

net.send(cfd, b"hello");
let rr: result[bytes, str] = net.recv(cfd, 4096);
let data: bytes = rr ?? b"";

net.nonblock(cfd);                              // switch to non-blocking mode
let wr: result[bytes, str] = net.recv(cfd, 16); // "would block" err if idle
net.close(cfd);
```


`net.idle_alive(fd) -> bool` and `net.tls_idle_alive(ssl) -> bool`
report whether an IDLE connection is still reusable: true only when the
peer has neither closed nor sent anything. One non-blocking `MSG_PEEK`,
nothing consumed; the TLS form is also false when OpenSSL holds
decrypted-but-unread bytes. They exist for connection pools, and they
are a primitive rather than a `recv_until` with an expired deadline
because `recv_until` checks its deadline *before* touching the socket —
it would report every dead connection as alive.

##### Deadlines

`net.recv` and `net.send` wait for as long as the peer takes, which on
a public listener is indefinitely: a client that connects and then
neither sends nor reads parks the serving task on the reactor forever,
holding its stack and its GC roots. That is slowloris, and the defence
is `recv_until` / `send_until`, which take an `until` — an absolute
monotonic instant, not a duration:

```slang
import "net";
import "time";

let deadline = until_of(time.mono() + 5000000000);   // 5s from now
let rr = net.recv_until(cfd, 4096, deadline);
guard let data = rr else let e = err_of(rr) {
    if e == "timeout" { net.close(cfd); return; }    // peer went quiet
    log.error("recv: " + e);                         // peer broke
    return;
}
```

`"timeout"` is a reserved error string: it means the deadline passed,
and it is the only error text these calls invent rather than take from
the OS. Every other error is `strerror`/OpenSSL text as before.

One asymmetry worth knowing: a `send_until` that times out **has
already written some bytes**, and `result[i32, str]` has no room to
report both "timed out" and "wrote this much". A `"timeout"` from
`send_until` therefore means the stream is at an unknown offset and the
connection must be closed, not retried. For a framed protocol that is
the right contract regardless — a half-written frame is unrecoverable.

`net.tls_recv_until` / `net.tls_send_until` are the same thing over
TLS, with the same reserved string. The `link` API takes an `until` on
`accept`/`send`/`recv` already.

See `examples/httpd/` for a minimal HTTP server on `link` plus the
`http` stdlib package.

#### TLS

`net.tls_*` adds a TLS listener/dialer on top of the plain `net`
primitives above, built on OpenSSL (linked automatically, and only
when a program actually calls one of these — a plain-TCP `net`
program stays dependency-free). A `SSL_CTX`-equivalent config is
created once (`tls_server_ctx` / `tls_client_ctx`) and reused across
many connections; each connection is a separate `rawptr` handle.

```slang
import "net";

// server: load a cert + key once, reuse the context for every connection
let sctx_r: result[rawptr, str] = net.tls_server_ctx("cert.pem", "key.pem");
guard let sctx = sctx_r else { exit(1); }

let lr: result[i32, str] = net.listen(8443);
guard let lfd = lr else { exit(1); }
let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);  // TCP accept + handshake
guard let sconn = ar else { exit(1); }
net.tls_send(sconn, b"hello");
net.tls_close(sconn);

// client: verify against a CA file, or "" for the system trust store
let cctx_r: result[rawptr, str] = net.tls_client_ctx("");
guard let cctx = cctx_r else { exit(1); }
let dr: result[rawptr, str] = net.tls_dial("example.com", 443, cctx);
guard let cconn = dr else { exit(1); }
let rr: result[bytes, str] = net.tls_recv(cconn, 4096);
net.tls_close(cconn);
```

Client verification is strict by default: `tls_client_ctx` enables
peer verification, and `tls_dial` checks the certificate against
*both* the CA and the hostname you asked for (`SSL_set1_host` — the
check that's easy to forget and, if skipped, leaves you with "TLS"
that validates a certificate chain without checking it belongs to
the host you're actually talking to). Sending/receiving is blocking,
same as plain `net` — call these from a `spawn`ed task if you need a
connection handled without stalling anything else.

**ALPN** (RFC 7301) negotiates the protocol during the handshake, which
is how HTTP/2 over TLS is selected — there is no in-band upgrade.
`tls_ctx_alpn(ctx, "h2,http/1.1")` sets the list on a server context (in
preference order, so the *server* decides) or the offer on a client one,
and `tls_alpn(conn)` returns what was actually negotiated, or `""` if
the peer offered nothing that overlapped. The list is comma-separated,
not the length-prefixed wire form; building that by hand is an easy way
to produce a subtly broken handshake. A client offering no protocol we
support completes the handshake without ALPN rather than failing, so it
simply falls back to HTTP/1.1.

```slang
net.tls_ctx_alpn(sctx, "h2,http/1.1");
let conn = ...;                  // after tls_accept
if net.tls_alpn(conn) == "h2" { serve_h2(conn); } else { serve_h1(conn); }
```

Mutual TLS: `tls_ctx_require_client(sctx, client_ca)` on the server
context demands a client certificate chained to that CA
(`SSL_VERIFY_FAIL_IF_NO_PEER_CERT`). The client presents one with
`tls_ctx_use_cert(cctx, cert, key)`. Extra server names on one
listener: `tls_ctx_add_sni(sctx, host, cert, key)` swaps in that
cert when the ClientHello SNI matches; unmatched names keep the
default `tls_server_ctx` cert. `require_client` applies to SNI
certs too, regardless of call order. TLS 1.3 can let `tls_dial`
return before the server has rejected a missing client certificate;
the first send or recv then fails.

#### `json`

`json.decode`/`json.encode` (de)serialize `str`/`bytes` against a
concrete slang type — the target type for `decode` is inferred from
the binding's annotation, the same mechanism `ok()`/`err()` already
use to infer `result[T,E]`. There is no dynamic "JSON value" type:
every decode is checked field-by-field against the struct shape you
asked for, and a mismatch is a `result` error, not a silent `null` or
a runtime panic.

```slang
import "json";

gc struct Address { city: str, zip: str }
gc struct Person {
    name: str,
    age: i32,
    email: opt[str],      // JSON null / missing key <-> none
    tags: [str],
    addr: Address,         // structs nest
}

let p = Person{ name: "Ada", age: 36, email: some("ada@example.com"),
                tags: ["math"], addr: Address{ city: "London", zip: "SW1" } };
let s: str = json.encode(p);

let r: result[Person, str] = json.decode(s);
guard let p2 = r else { exit(1); }
```

Supported: `struct`, `opt[T]`, `[T]`, `map[str, V]` (JSON object keys
are always strings — a map with any other key type is a compile
error), every scalar, and `bytes` (RFC 4648 base64 strings on the
wire). `rawptr`, `chan[T]`, and
`result[T,E]` can't appear anywhere in a decode/encode target type. A
missing JSON key defaults an `opt[T]` field to `none`; for any other
field type it's a decode error. Unknown JSON keys are ignored. Every
decode error names where it happened, composed through nesting —
`json.decode` on `{"addr":{"city":5}}` against the `Person` shape
above fails with `field 'addr': field 'city': expected a string, got
a number`. Malformed input is a decode error, never a crash — the
parser caps nesting depth at 512 so adversarial input can't blow the
C stack.

#### `proc`

Graceful shutdown and environment variables. `proc.shutdown_requested()`
turns true once the process receives `SIGTERM` or `SIGINT`; a blocked
`net.accept()`/`net.recv()`/`net.dial()` on the main thread is
interrupted the instant the signal arrives (an `err` result, not a
hang), so a listener loop notices without needing `select` or a
timeout. `proc.active_tasks()` counts currently-running `spawn`ed
tasks. `proc.wait_idle()` parks until that count is zero, so a
shutting-down program can drain in-flight work without polling.

```slang
import "net";
import "proc";
import "time";

fn accept_and_serve(lfd: i32) {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return; } // interrupted, or a real error
    spawn serve(cfd);
}

let lr: result[i32, str] = net.listen(8080);
guard let lfd = lr else { exit(1); }

while !proc.shutdown_requested() {
    accept_and_serve(lfd);
}

proc.wait_idle();
```

`proc.getenv(name)` reads an environment variable, returning
`opt[str]` (`none` if unset). `proc.args()` is the process argument
list (`[str]`); `args[0]` is the executable path. `proc.cwd()` is the
working directory as `result[str, str]`.

#### `fs`

POSIX file I/O on integer fds. `open` is read-only; `create` is
write/trunc. `read`/`write`/`close` use the fd. `mkdir` creates one
directory. Every call returns `result[_, str]`. These calls block the
worker — use them for config and small files, not the accept loop.

```slang
import "fs";

let cr = fs.create("/tmp/note");
guard let fd = cr else { exit(1); }
fs.write(fd, b"hi");
fs.close(fd);

let or = fs.open("/tmp/note");
guard let in_fd = or else { exit(1); }
let rr = fs.read(in_fd, 16);
guard let data = rr else { exit(1); }
fs.close(in_fd);
```

#### `os`

The operating system *around* a program: the environment, the process,
and everything you can ask or do about a path without opening it. Pure
libc, so importing `os` adds no link flag.

**The `fs`/`os` boundary**: `fs` owns open file **handles** and their
contents; `os` owns paths you have not opened. `fs.mkdir` predates that
split and stays where it is rather than breaking existing programs.

| | |
|---|---|
| `os.setenv(k, v)` / `os.unsetenv(k)` | `result[bool, str]` |
| `os.environ()` | `[str]` of `KEY=VALUE` |
| `os.pid()` / `os.tmpdir()` | `int` / `str` |
| `os.hostname()` | `result[str, str]` |
| `os.exists(p)` / `os.is_dir(p)` / `os.is_file(p)` | `bool` |
| `os.size(p)` / `os.mtime(p)` | `result[int, str]` |
| `os.read_dir(p)` | `result[[str], str]` |
| `os.remove(p)` / `os.rename(a, b)` | `result[bool, str]` |

```slang
import "os";

// serve a static file, the shape this package exists for
if !os.is_file(path) {
    return not_found();
}
let sr = os.size(path);
guard let n = sr else let e = err_of(sr) {
    log.error("stat " + path + ": " + e);      // "No such file or directory"
    return server_error();
}
```

The three predicates are bare `bool` on purpose. "Does this exist" has
two useful answers: a missing path and an unreadable parent are both
"no, you cannot use it", and code branching on the difference is racing
anyway — the answer can change between the check and the use. The
accessors return a value that has to come from somewhere, so those
carry the errno text.

`environ()` is a list rather than a map because an environment may
legally hold a repeated key, and a map would silently drop one.
`read_dir` returns entry names without `.` and `..`, since forgetting
to filter those is how a directory walk becomes an infinite loop.
`remove` takes files and empty directories alike, so a caller need not
know which it has.

`proc.getenv`, `proc.args` and `proc.cwd` stay in `proc`; `os` adds
what `proc` has no answer for rather than duplicating it.

#### `log`

Stderr logging with a timestamp and level. Each function accepts a
`str` or a `fault` (`to_str`/`+` already convert faults the same way),
so `err_of` bindings and `fault` values log without manual conversion.

```slang
import "log";

log.debug("cache miss for key foo");
log.info("listening on :8080");
log.warn("retrying dial after timeout");
log.error("could not load config: " + e);
log.warn(fault_timeout());
```

#### `crypto`

SHA-256, HMAC-SHA256, and a CSPRNG over OpenSSL. Hash and HMAC are
infallible on valid inputs and return `bytes` directly; `rand` can fail
and returns `result[bytes, str]`.

```slang
import "crypto";

let h: bytes = crypto.sha256(b"abc");              // 32 bytes
let m: bytes = crypto.hmac_sha256(key, msg);       // 32 bytes
let r = crypto.rand(32);
guard let b = r else let e = err_of(r) {
    log.error("rand failed: " + e);
}
```

#### `sql`

A SQLite driver (linked automatically, only when a program imports
`sql`). Connections and prepared statements are opaque `rawptr`
handles, exactly like `net.tls_*`; free them with `sql.close` /
`sql.finalize`. **Every fallible call returns `result[_, str]` whose
error is SQLite's own message** — `no such table: users`, `near
"SELCT": syntax error`, `UNIQUE constraint failed: users.id` — so a
bad query stays as visible as a bad socket read (`guard let … else
let e = err_of(r)`), never a silent `null`. The column getters are
infallible (SQLite coerces types; an out-of-range index is a
programming error, returning `0` / `""`), so they return bare values.

| Function | Signature |
|----------|-----------|
| `sql.open(path)` | `result[rawptr, str]` — `":memory:"` for in-memory |
| `sql.close(db)` | — |
| `sql.exec(db, sql)` | `result[int, str]` — runs statement(s), returns rows changed |
| `sql.last_insert_id(db)` | `int` |
| `sql.prepare(db, sql)` | `result[rawptr, str]` |
| `sql.finalize(st)` | — |
| `sql.reset(st)` | `result[bool, str]` — clears bindings, re-run |
| `sql.bind_int/bind_float/bind_text/bind_blob(st, idx, v)` | `result[bool, str]` — `idx` is 1-based |
| `sql.bind_null(st, idx)` | `result[bool, str]` |
| `sql.step(st)` | `result[bool, str]` — `true` = row ready, `false` = done |
| `sql.col_count(st)` | `int` |
| `sql.col_name(st, i)` / `col_text(st, i)` | `str` — `i` is 0-based |
| `sql.col_int(st, i)` | `int` |
| `sql.col_float(st, i)` | `float` |
| `sql.col_blob(st, i)` | `bytes` |
| `sql.col_is_null(st, i)` | `bool` |

```slang
import "sql";
import "log";

let dr = sql.open("app.db");
guard let db = dr else let e = err_of(dr) {
    log.error("db open: " + e);
    exit(1);
}
sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

let pr = sql.prepare(db, "SELECT id, name FROM users WHERE id > ?");
guard let st = pr else let e = err_of(pr) {
    log.error("prepare: " + e);          // e.g. "no such table: users"
    exit(1);
}
sql.bind_int(st, 1, 0);
while true {
    let sr = sql.step(st);
    guard let more = sr else let e = err_of(sr) { log.error("step: " + e); break; }
    if !more { break; }
    println(to_str(sql.col_int(st, 0)) + " " + sql.col_text(st, 1));
}
sql.finalize(st);
sql.close(db);
```

SQLite calls block the worker — use them for real work off the accept
loop (wrap in a `spawn`ed task), the same caveat as `fs`. One
connection per `rawptr`; there is no pool, no networked backend
(Postgres/MySQL), and no async stepping.

Query complexity is capped per connection so SQLite's recursion stays
inside the task stack: at most **50 terms in a compound `SELECT`**
(`UNION`/`INTERSECT`/`EXCEPT`) and an **expression depth of 400**
(roughly, terms in one `AND`/`OR` chain). SQLite's stock limits of 500
and 1000 allow a single legal query to want ~325KB of C stack, which
would force a task stack far too fat to spawn per connection. Long
`IN` lists, wide result sets, and recursive CTEs are *not* affected —
they don't recurse. Exceeding a cap is a normal error through
`result[_, str]` (`too many terms in compound SELECT`), not a crash.

#### `regex`

Regular expressions on `str` or `bytes`, matched by slang's own
Thompson NFA — no external library, so a program that matches text
stays as dependency-free as a plain TCP one. `compile` returns an
opaque `rawptr` handle (freed with `regex.free`, like `net.tls_*` and
`sql`), and a bad pattern comes back as a descriptive
`result[rawptr, str]`.

**Matching is linear time, always.** There is no backtracking, so the
classic catastrophic pattern `(a+)+$` — which makes a backtracking
engine take exponential time on a hostile input — runs in the same
microseconds here as any other pattern. That is the point of choosing
this engine for a server language: patterns and subjects both arrive
from the network. The price is the RE2/Go one, and it is not
negotiable: **no backreferences and no lookaround**. Both require
backtracking; `(?=...)` and friends are a compile error, not a silent
mis-parse.

| Function | Signature |
|----------|-----------|
| `regex.compile(pat)` | `result[rawptr, str]` |
| `regex.free(re)` | — |
| `regex.groups(re)` | `int` — number of capture groups |
| `regex.is_match(re, s)` | `bool` — `s` is a `str` |
| `regex.is_match_bytes(re, b)` | `bool` — `b` is `bytes` |
| `regex.find(re, s)` / `find_bytes(re, b)` | `[int]` |
| `regex.find_at(re, s, from)` / `find_bytes_at(re, b, from)` | `[int]` |

`find` returns byte offsets as `[start, end, g1start, g1end, ...]`, or
an **empty list** when there is no match — so the result is GC-owned
and there is no match handle to leak. `find_at` starts at an offset,
which is how you walk every match.

```slang
import "regex";

let cr = regex.compile("(\\d{4})-(\\d{2})-(\\d{2})");
guard let re = cr else let e = err_of(cr) {
    log.error("bad pattern: " + e);   // e.g. "missing ) at offset 9"
    exit(1);
}

if regex.is_match(re, "due 2026-09-09") {
    let m = regex.find(re, "due 2026-09-09");
    println(to_str(m[0]) + ".." + to_str(m[1]));   // whole match: 4..14
    println(to_str(m[2]) + ".." + to_str(m[3]));   // year:        4..8
}
regex.free(re);
```

Supported: literals, `.`, classes `[a-z]` `[^...]` `[[:digit:]]`,
escapes `\d \D \w \W \s \S \b \B \A \z \xHH`, quantifiers
`* + ? {n} {n,} {n,m}` and their lazy `?` forms, groups `(...)` and
`(?:...)`, alternation `|`, anchors `^ $`. Matching is leftmost-first
(Perl-style priority), and `.` does not match `\n`.

Subjects are matched with an explicit length, so a `bytes` containing
NUL matches correctly rather than stopping at the NUL — and `\D`
matches a NUL byte like any other non-digit.

Bounds, so a hostile pattern can't exhaust memory or stack: 4096
compiled instructions, 100 nesting levels, 32 capture groups, and
`{n,m}` counts up to 1000. Each is a descriptive compile error, never
a crash.

A compiled regex is safe to share across tasks, and is meant to be:
it carries a small pool of reusable match buffers, so concurrent
matchers allocate nothing per match. Compiling is the expensive part
(it is also the only part that grows the task stack) — compile once,
match many times, ideally not once per request.

**Where this lands on speed.** Measured single-threaded on
`^(GET|POST|PUT) (/[a-z0-9/_-]*) HTTP/1\.([01])$` against a 26-byte
subject, 200k iterations:

| engine | matches/sec | on `(a+)+$` vs a hostile input |
|--------|-------------|-------------------------------|
| slang `regex` | ~721k | 2µs, correct answer |
| POSIX `regexec` | ~372k | fast here, but no limits |
| PCRE2 (interpreted) | ~2.4M | 0.2s, then gives up (`MATCHLIMIT`) |
| PCRE2 (JIT) | ~8.6M | same — JIT does not save it |

So: ~1.9x faster than libc's POSIX engine, and several times slower
than PCRE2 on *benign* input — PCRE2's interpreter and especially its
JIT are very good, and this is an honest gap. The trade is deliberate:
on adversarial input the ordering inverts completely, because linear
time is a guarantee here and a hope there. `is_match` is markedly
cheaper than `find` (it binds no capture slots at all), so prefer it
when you only need a yes/no. Matching scales with tasks — ~3.2M/sec
across 16.

Because matching never grows the task stack, regex is cheap to use per
connection: 600 concurrently-live tasks each matching and then parking
peak at **3.9MB RSS** — about 17x lighter than the same shape holding
`sql` connections (65.9MB), which does grow every task's stack.

#### `http2`

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

#### `strings`

Search, trim, case, split and join on `str`. The package cannot be named
`str` because that token is the type — the same reason Go calls its own
`strings`.

```slang
import "strings";

strings.find("hello world", "world");   // 6, or -1
strings.rfind("a/b/c", "/");            // 3
strings.contains("hello", "ell");
strings.has_prefix("hello", "he");
strings.has_suffix("hello", "lo");
strings.count("a,b,c", ",");            // 2

strings.trim("  hi \r\n");              // "hi" (space/tab/CR/LF)
strings.trim_start(s); strings.trim_end(s);
strings.to_upper("hi"); strings.to_lower("HI");   // ASCII only

strings.slice("hello", 1, 3);           // "el"
strings.slice("hello", -3, 5);          // "llo" — negative counts back
strings.repeat("ab", 3);                // "ababab"
strings.replace("a,b,c", ",", " | ");

strings.split("a,b,,c", ",");           // ["a", "b", "", "c"]
strings.join(parts, ",");               // the inverse of split
```

This is a compiler-provided native package, and it has to be: `str`
supports `len`, `+` and `==` and nothing else — it cannot be indexed or
sliced — so none of it could be written in slang without converting to
`bytes` and back on every call. `byteutil` covers the `bytes` side.

Three behaviours worth knowing:

- **Indices are byte offsets and the case operations are ASCII-only.**
  `str` is UTF-8 bytes; doing better means shipping a Unicode table and
  a normalisation policy, which is a different project. Treat these as
  byte operations, because that is what they are.
- **`slice` clamps rather than panics.** Slicing is how you narrow a
  string you just searched, and a `find` that returned -1 on the line
  above should not turn the next line into a crash. A negative index
  counts from the end.
- **`split` and `join` are exact inverses.** Adjacent separators produce
  empty elements, so the result always has `count(s, sep) + 1` elements
  and `join(split(s, sep), sep) == s` for any non-empty separator. An
  empty separator splits into single bytes.

#### `encoding`

Hex, base64, base64url, percent-encoding and query strings — the four
ways arbitrary bytes travel through a channel that only carries text.

```slang
import "encoding";

encoding.hex_encode(crypto.sha256(b"abc"));   // "ba7816bf8f01cfea..."
encoding.base64_encode(b"aladdin:opensesame");// HTTP Basic credentials
encoding.base64url_encode(sig);               // a JWT segment: -_ alphabet, no padding
encoding.url_encode("a b&c");                 // "a%20b%26c"
encoding.form_encode("a b&c");                // "a+b%26c"

let q = "/search?q=hello+world&page=2";
guard let term = encoding.query_get(q, "q") else { return; }   // "hello world"
encoding.query_keys(q);                                        // ["q", "page"]
```

| Function | Signature |
|---|---|
| `encoding.hex_encode` | `(b: bytes) -> str` |
| `encoding.hex_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.base64_encode` | `(b: bytes) -> str` |
| `encoding.base64_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.base64url_encode` | `(b: bytes) -> str` |
| `encoding.base64url_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.url_encode` | `(s: str) -> str` |
| `encoding.url_decode` | `(s: str) -> result[str, str]` |
| `encoding.form_encode` | `(s: str) -> str` |
| `encoding.form_decode` | `(s: str) -> result[str, str]` |
| `encoding.query_get` | `(url: str, key: str) -> opt[str]` |
| `encoding.query_keys` | `(url: str) -> [str]` |

Like `regex`, `strings` and `os` — and unlike `crypto` and `sql` — this
is pure computation, so importing it adds no link flag.

Four things worth knowing:

- **Encoders are infallible; decoders are not.** Any byte string has a
  hex form, so `hex_encode` returns a bare `str`. Decoding takes input
  the program did not produce — a query string, a header, a token — so
  every decoder returns `result[_, str]`, and the message names the byte
  offset it gave up at. "invalid base64" about a 400-character token is
  not a diagnosis.

- **`url_*` and `form_*` differ only in `+`, and that is exactly why
  they have separate names.** In `application/x-www-form-urlencoded` a
  space is `+`; in a URI it is `%20`. Decoding a form body with
  `url_decode` leaves literal `+` where every space belongs, and nothing
  reports it — the failure surfaces later as a lookup that does not
  match. One function with a flag would make that the default mistake.

- **`%00` is an error, not a truncation.** `url_decode` and
  `form_decode` return `str`, which is NUL-terminated, so a decoded zero
  byte would silently cut the value short. They refuse it and say so.
  `hex_decode` and `base64_decode` return `bytes`, which carries an
  explicit length, so a zero byte there is ordinary data and round-trips
  exactly.

- **`query_get` is `opt`, and `query_keys` is a list.** A missing
  parameter is absent data, not bad data, so it is `opt[str]` — the
  README rule above. Keys come back as a list rather than a map because
  a query may legally repeat a key and a map would have to drop one,
  the same reason `os.environ` is a list. `query_get` takes the first
  value; a bare `?debug` is present with an empty value, not absent.

Percent-escapes are emitted uppercase (RFC 3986 §2.1) and hex digests
lowercase (what `sha256sum`, git and every API that returns one use).
Both decoders accept either case.

#### `httpc`

An HTTP/1.1 **client** — the mirror of `http`, which serves. Speaks
`http://` and `https://`, follows redirects, and decodes chunked
responses.

```slang
import "httpc";
import "time";

let dl = until_of(time.mono() + 5000000000);   // 5s for the whole request

let r = httpc.get("https://api.example.com/users?id=1", dl);
guard let resp = r else let e = err_of(r) {
    log.error("request failed: " + e);
    return;
}
println(to_str(resp.status) + " " + to_str(len(resp.body)) + " bytes");

// a POST, and a header the request owns
let req = httpc.new_request("POST", "https://api.example.com/users");
req.headers["Authorization"] = "Bearer " + token;
req.body = to_bytes(payload);
let r2 = httpc.send(req, dl);
```

| Function | Signature |
|---|---|
| `httpc.get` | `(url: str, deadline: until) -> result[Response, str]` |
| `httpc.head` | `(url: str, deadline: until) -> result[Response, str]` |
| `httpc.post` | `(url: str, content_type: str, body: bytes, deadline: until) -> result[Response, str]` |
| `httpc.send` | `(req: Request, deadline: until) -> result[Response, str]` |
| `httpc.new_request` | `(method: str, url: str) -> Request` |
| `httpc.header` | `(r: Response, name: str) -> opt[str]` |
| `httpc.parse_url` | `(url: str) -> result[Url, str]` |
| `httpc.new_client` | `() -> Client` |
| `httpc.client_get` / `client_head` | `(c: Client, url: str, deadline: until) -> result[Response, str]` |
| `httpc.client_post` | `(c: Client, url: str, content_type: str, body: bytes, deadline: until) -> result[Response, str]` |
| `httpc.client_send` | `(c: Client, req: Request, deadline: until) -> result[Response, str]` |
| `httpc.idle_count` | `(c: Client) -> int` |
| `httpc.close_idle` | `(c: Client)` |

`Request` carries `method`, `url`, `headers`, `body`, `max_redirects`
(default 5, `0` disables following) and `ca_path` (`""` = the system
trust store). `Response` carries `status`, `status_text`, `headers`,
`body` and `url` — the last being the URL that actually answered, which
after a redirect is not the one you asked for.

Separate from `http` rather than folded into it because `http` imports
only `byteutil`, while a client necessarily imports `net` — and for a
TLS request that drags `-lssl`/`-lcrypto` onto the link line of every
program that merely wanted to serve HTTP.

Five things worth knowing:

- **A 404 is a `Response`, not an `err`.** The `result` is about whether
  the exchange happened — DNS, connect, TLS, framing. A server that
  answers "no" answered. Collapsing the two would make a 404 and a
  connection refusal indistinguishable at the call site, and they need
  different handling.

- **Certificates are verified, and there is no flag to stop that.**
  Verified against `expired`, `self-signed` and `wrong.host` on
  badssl.com: all three are refused, a valid one is accepted. For an
  internal service signed by a private CA, set `ca_path` to that
  bundle — the answer is a different trust anchor, never a disabled
  check.

- **Credentials do not survive a cross-origin redirect.** `Authorization`,
  `Cookie` and `Proxy-Authorization` are dropped when the scheme, host
  or port changes, because the server that sent the `Location` chose
  where it points, and that is exactly how a token gets exfiltrated.
  Same-origin redirects keep them.

- **Redirect method rules follow browsers, not the RFC's original
  wording.** 303 always becomes GET; 301 and 302 after a POST also
  become GET and drop the body, which is what every browser and curl do
  and therefore what servers expect. 307 and 308 exist to preserve the
  method, so they do. A redirect loop stops at `max_redirects` and hands
  back the last 3xx rather than spinning.

- **Everything a server can make you allocate has a ceiling** — 64 KiB
  of headers, 32 MiB of body, and a bounded chunk-size line. A client
  talks to servers it does not control, so a buffer sized on their
  say-so is a denial of service arriving through an ordinary call.

##### Connection pooling

`httpc.get` and friends are one-shot: a connection per request, closed
afterwards, with `Connection: close` sent so the server does not hold
it open. A **`Client`** keeps idle connections and reuses them — up to
`max_idle_per_host` per origin (default 4), for `idle_timeout`
nanoseconds (default 30s), and 64 across all origins.

```slang
let c = httpc.new_client();          // share one across tasks
let r = httpc.client_get(c, "https://api.example.com/v1/items", dl);
```

The one-shot functions ARE a client — one that keeps nothing — so
framing, redirects, decompression and every security rule are one code
path, and cannot drift between the two.

A `Client` is safe to share between tasks: the pool is behind a
`mutex`. Its `dials` and `reuses` fields and `httpc.idle_count(c)` make
its behaviour checkable rather than asserted.

- **Every pooled connection is probed before use.** Servers close idle
  connections on their own timers (Node's default is 5 seconds), and a
  request written onto one fails indistinguishably from the server
  failing mid-request. The probe is `net.idle_alive` — one non-blocking
  `MSG_PEEK`, no latency, nothing consumed.
- **A dropped request is retried once, and only if it is idempotent.**
  If a reused connection dies before a single response byte arrives,
  GET/HEAD/PUT/DELETE/OPTIONS/TRACE retry on a fresh connection. POST
  does not: it may already have been acted on, and sending it twice
  could charge a card twice. The probe is what protects a POST; the
  retry is the backstop for the race between probe and write.
- **The pool key includes `ca_path`.** A connection verified against
  one trust anchor is never handed to a request that asked for another —
  tested over real TLS: the second request, demanding a different CA,
  fails verification instead of riding the verified connection.
- **Reuse requires a clean end:** HTTP/1.1, no `Connection: close`, a
  framed body read exactly, and nothing left over. A body delimited by
  the connection closing is never reused.

Client operations are handle-first package functions — `client_get(c,
...)`, the same idiom as `sql.exec(db, ...)` — rather than methods,
because a method cannot currently share a name with a package function
(`impl Client { fn get }` collides with `httpc.get`).

##### Decompression

Requests carry `Accept-Encoding: gzip, deflate` and responses are
decoded transparently — **unless the caller set `Accept-Encoding`
themselves**, in which case the body comes back exactly as sent. A
caller who asked for gzip wants the gzip (to proxy it, to store it), and
decompressing behind their back would hand them something else.

- The decoded size is held to the same 32 MiB ceiling as a plain body.
  Without that the wire limit would mean nothing: 32 MiB of gzip holds
  tens of gigabytes.
- `deflate` is tried as zlib (what RFC 9110 says it means) and then as
  raw DEFLATE (what a real share of servers send under that name).
- After decoding, `Content-Encoding` and `Content-Length` are removed:
  both describe the bytes that crossed the wire, not the body in hand.
- An encoding the client did not ask for and cannot read is left alone,
  header included — visible, not silent.

**Not done, deliberately:** no cookie jar, no HTTP/2 client, no
multipart bodies, no proxy support.

#### `byteutil`

Search, trim, and split on the `bytes` type — no new syntax. The
package cannot be named `bytes` because that token is the type.

```slang
import "byteutil";

byteutil.find(b"hello", 0, 108);     // 2, or -1
byteutil.has_prefix(b"hello", b"he");
byteutil.has_suffix(b"hello", b"lo");
byteutil.trim(b"  hi\r\n");          // b"hi" (space/tab/CR/LF)
byteutil.split(b"a,b", 44);          // [b"a", b"b"]
```

#### `http`

HTTP/1.1 over `link` / `wire` / `until` / `fault`. Parse a request
from `bytes`, or `read` from a connection into a caller-sized `wire`
(the max request size). `read` takes the unconsumed prefix length and
returns `Incoming` with leftover compacted to the front of the wire,
so one connection can carry many requests. `write` serializes a
`Response` through an arena. Headers are stored lowercased;
`header(req, name)` looks up case-insensitively. `Content-Length` is
honored; chunked `Transfer-Encoding` is rejected. `wants_close`
follows HTTP/1.1 keep-alive (and HTTP/1.0 close-by-default).

```slang
import "http";

fn serve(c: link) {
    let ra = arena_new(16384);
    let sa = arena_new(16384);
    let buf = ra.wire(8192);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, http.ok_text(got.req.path), &mut sa,
                            until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) { return; }
        filled = got.filled;
    }
}
```

See `examples/httpd/` for a listener loop on this package.

This works because every `spawn`ed thread has `SIGTERM`/`SIGINT`
blocked in its own signal mask from birth (inherited at creation,
restored in the spawning thread right after) — so the OS can only
ever pick the main thread to run the handler, which is what lets the
main thread's blocked `accept()` call reliably observe the
interruption instead of the signal silently landing on some unrelated
connection's worker thread mid-request. There's a narrow startup race
inherent to this: a signal that arrives in the brief window before
`main()` installs the handler gets the OS's default disposition
(immediate termination) instead of graceful handling, same as any
signal-handling program.

## All packages

- [byteutil](packages/byteutil.md) -- source package, 5 public items
- [compress](packages/compress.md) -- compiler-provided, 7 public items
- [crypto](packages/crypto.md) -- compiler-provided, 3 public items
- [encoding](packages/encoding.md) -- compiler-provided, 12 public items
- [fs](packages/fs.md) -- compiler-provided, 6 public items
- [http](packages/http.md) -- source package, 19 public items
- [http2](packages/http2.md) -- source package, 122 public items
- [httpc](packages/httpc.md) -- source package, 18 public items
- [json](packages/json.md) -- compiler-provided, 0 public items
- [log](packages/log.md) -- compiler-provided, 4 public items
- [net](packages/net.md) -- compiler-provided, 26 public items
- [os](packages/os.md) -- compiler-provided, 14 public items
- [proc](packages/proc.md) -- compiler-provided, 6 public items
- [regex](packages/regex.md) -- compiler-provided, 9 public items
- [sql](packages/sql.md) -- compiler-provided, 20 public items
- [strings](packages/strings.md) -- compiler-provided, 16 public items
- [time](packages/time.md) -- compiler-provided, 3 public items

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
