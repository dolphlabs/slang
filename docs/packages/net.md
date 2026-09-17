# net

> Package net.

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

`net.dial_until(host, port, deadline)` bounds connecting: the DNS lookup
and the TCP connect together. A lookup still running when the deadline
passes is abandoned to the resolver thread (`getaddrinfo` cannot be
interrupted), so the caller gets `"timeout"` on time. Every address the
name resolves to is tried in turn — `net.dial` does the same, without a
deadline.

##### Unix-domain sockets

`net.dial_unix(path, deadline)` connects to a Unix-domain stream socket
and `net.listen_unix(path)` listens on one (accept with `net.accept`).
The fds work with every fd-based call — `send`/`recv` and their `_until`
forms, `close`, `idle_alive`. `listen_unix` refuses a path that already
exists rather than deleting it, since the file may belong to a server
that is still running; remove a stale one with `os.remove` first. A path
longer than the platform allows (104 bytes on macOS, 108 on Linux) is an
error, not truncated.

See `examples/httpd/` for a minimal HTTP server on `link` plus the
`http` stdlib package.

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

**STARTTLS**: `tls_upgrade(fd, host, ctx)` runs a client handshake on a
socket from `net.dial` that has already spoken cleartext — how Postgres,
SMTP and IMAP switch to TLS. Verification is exactly `tls_dial`'s,
hostname included, which is why the host is an argument: an fd does not
remember what was dialled. On failure the fd is left open for the caller
to close; on success it belongs to the returned handle and `tls_close`
closes it. Read no further than the server's go-ahead before upgrading:
anything a man in the middle queued behind it would otherwise be trusted
as if it had arrived encrypted (libpq's CVE-2021-23222).
`tls_upgrade_until(fd, host, ctx, deadline)` bounds the handshake; a
server that stops answering part way through gives `"timeout"`.

## API

### `net.listen(int) -> result[i32,str]`

### `net.port(int) -> result[i32,str]`

### `net.accept(int) -> result[i32,str]`

### `net.dial(str, int) -> result[i32,str]`

### `net.dial_until(str, int, until) -> result[i32,str]`

### `net.dial_unix(str, until) -> result[i32,str]`

### `net.listen_unix(str) -> result[i32,str]`

### `net.send(int, bytes) -> result[i32,str]`

### `net.recv(int, int) -> result[bytes,str]`

### `net.recv_until(int, int, until) -> result[bytes,str]`

### `net.send_until(int, bytes, until) -> result[i32,str]`

### `net.close(int)`

### `net.idle_alive(int) -> bool`

### `net.nonblock(int) -> result[bool,str]`

### `net.tls_server_ctx(str, str) -> result[rawptr,str]`

### `net.tls_client_ctx(str) -> result[rawptr,str]`

### `net.tls_accept(int, rawptr) -> result[rawptr,str]`

### `net.tls_dial(str, int, rawptr) -> result[rawptr,str]`

### `net.tls_upgrade(int, str, rawptr) -> result[rawptr,str]`

### `net.tls_upgrade_until(int, str, rawptr, until) -> result[rawptr,str]`

### `net.tls_send(rawptr, bytes) -> result[i32,str]`

### `net.tls_recv(rawptr, int) -> result[bytes,str]`

### `net.tls_recv_until(rawptr, int, until) -> result[bytes,str]`

### `net.tls_send_until(rawptr, bytes, until) -> result[i32,str]`

### `net.tls_close(rawptr)`

### `net.tls_idle_alive(rawptr) -> bool`

### `net.tls_ctx_require_client(rawptr, str) -> result[bool,str]`

### `net.tls_ctx_use_cert(rawptr, str, str) -> result[bool,str]`

### `net.tls_ctx_add_sni(rawptr, str, str, str) -> result[bool,str]`

### `net.tls_ctx_alpn(rawptr, str) -> result[bool,str]`

### `net.tls_alpn(rawptr) -> str`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
