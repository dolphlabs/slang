# httpc

> Package httpc.

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
| `httpc.enable_cookies` / `clear_cookies` | `(c: Client)` |
| `httpc.set_cookie` | `(c: Client, url: str, set_cookie_line: str)` |
| `httpc.cookies` | `(c: Client, url: str) -> [Cookie]` |
| `httpc.parse_cookie_date` | `(s: str) -> int` (unix ns, or -1) |

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

Client operations come in two equivalent forms: handle-first package
functions — `httpc.client_get(c, url, dl)`, the same idiom as
`sql.exec(db, ...)` — and methods, `c.get(url, dl)`. The methods are
`get`, `head`, `post`, `send`, `idle_count`, `close_idle`,
`enable_cookies`, `clear_cookies`, `set_cookie` and `cookies` on `Client`,
and `header` on `Response`. `c.get` and the one-shot `httpc.get` share a
name; the method is the pooled client's, the function is not.

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

##### Cookies

RFC 6265, with RFC 6265bis's rules for `Secure` and the `__Secure-` /
`__Host-` prefixes. **Off by default** — the opposite of a browser, on
purpose:

```slang
let c = httpc.new_client();
httpc.enable_cookies(c);             // this Client now acts as ONE identity
```

A browser's jar belongs to one person. A server's `Client` is usually
shared, one per process, used on behalf of every user it serves, and a
jar there would store user A's session cookie and send it on user B's
request. Go's `http.Client` makes the same call. Turn the jar on for a
`Client` that represents one identity: a scraper, a test driver, an
integration with a login-based API.

- **Cookies are applied per redirect hop.** A cookie set by a `302` reaches
  the page it points to, which is how nearly every login works; a
  redirect to another host carries that host's cookies, not the first
  one's.
- **Refused:** a `Secure` cookie from `http://` (a network attacker could
  otherwise overwrite an https session); a `Domain` the host does not
  belong to; a bare single-label `Domain` such as `com`; a `Domain` that
  is part of an IP address; `__Host-` without `Secure`, or with a
  `Domain`, or with a path other than `/`; a line with no `=`; anything
  over 4096 bytes. `Secure` cookies are only ever sent over https.
- **Scoping:** a cookie set without `Domain` goes back to *exactly* that
  host (`127.0.0.1` and `localhost` are different scopes); `Path=/p`
  matches `/p` and `/p/x` but not `/pathx`. Longer paths are sent first.
- **Expiry:** `Max-Age` wins over `Expires` whatever order they arrive
  in, and a past date or `Max-Age=0` deletes. Dates are parsed with RFC
  6265's lenient algorithm, since servers send RFC 1123, RFC 850 with
  two-digit years and asctime alike; `httpc.parse_cookie_date` exposes it.
- **Limits:** 50 cookies per domain and 3000 in total, evicting the oldest,
  so a server flooding the jar pushes out its own cookies first.
- **`Response.set_cookies`** holds each `Set-Cookie` line separately. Use
  it rather than `headers["set-cookie"]`: repeated headers are joined
  with `", "`, and an `Expires` date contains a comma, so two joined
  lines cannot be split apart again.

**No public-suffix list is applied**, and the consequence is stated
rather than left to be discovered: a response from `a.example.co.uk` may
set a cookie for `Domain=co.uk`, and this jar will then send it to every
`*.co.uk` host. Nothing in slang ships a suffix list, and an embedded
copy goes stale. The bare-TLD rule stops `Domain=com`; it does not stop
that case.

**Not done, deliberately:** no HTTP/2 client, no multipart bodies, no
proxy support, no public-suffix list.

## API

### `gc struct Url`

### `gc struct Request`

### `gc struct Response`

### `fn parse_url(u: str) -> result[Url, str]`

### `fn header(r: Response, name: str) -> opt[str]`

### `gc struct Client`

### `fn new_client() -> Client`

### `gc struct Cookie`

### `fn enable_cookies(c: Client)`

### `fn clear_cookies(c: Client)`

### `fn parse_cookie_date(s: str) -> int`

Unix nanoseconds, or -1 when the string is not a cookie date.

### `fn set_cookie(c: Client, url: str, line: str)`

Record a Set-Cookie line as if `url` had sent it, under exactly the rules a real response gets -- the same function does both. For a program restoring a session it saved, or seeding a jar for a test. Has no effect unless enable_cookies was called, the same as a response would not.

### `fn cookies(c: Client, url: str) -> [Cookie]`

What the jar would send to `url` right now. For inspection and tests; a request does this itself.

### `fn new_request(method: str, url: str) -> Request`

### `fn client_send(c: Client, req: Request, deadline: until)`

### `fn client_get(c: Client, url: str, deadline: until)`

### `fn client_head(c: Client, url: str, deadline: until)`

### `fn client_post(c: Client, url: str, content_type: str, body: bytes,`

### `fn idle_count(c: Client) -> int`

How many connections are idle in the pool right now. With dials and reuses, the third number that makes the pool's behaviour checkable rather than asserted -- and the only one that shows a reuse DECISION before the server's own close can mask it.

### `fn close_idle(c: Client)`

Close every idle connection now. A long-lived service does not need this -- idle_timeout reaps them -- but a program about to exit, or a test counting connections, does.

### `fn send(req: Request, deadline: until) -> result[Response, str]`

### `fn get(url: str, deadline: until) -> result[Response, str]`

### `fn head(url: str, deadline: until) -> result[Response, str]`

### `fn post(url: str, content_type: str, body: bytes,`

### `fn send(self: Client, req: Request, deadline: until)`

### `fn get(self: Client, url: str, deadline: until)`

### `fn head(self: Client, url: str, deadline: until)`

### `fn post(self: Client, url: str, content_type: str, body: bytes,`

### `fn idle_count(self: Client) -> int`

### `fn close_idle(self: Client)`

### `fn enable_cookies(self: Client)`

### `fn clear_cookies(self: Client)`

### `fn set_cookie(self: Client, url: str, line: str)`

### `fn cookies(self: Client, url: str) -> [Cookie]`

### `fn header(self: Response, name: str) -> opt[str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
