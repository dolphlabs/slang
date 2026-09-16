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

**Not done, deliberately:** no connection pooling (every request opens a
connection and sends `Connection: close`), no gzip (nothing links zlib,
and advertising an encoding you cannot decode is worse than not asking),
no cookie jar, no HTTP/2, no multipart bodies. All additive; none of
them changes the shapes above.

## API

### `gc struct Url`

### `gc struct Request`

### `gc struct Response`

### `fn parse_url(u: str) -> result[Url, str]`

### `fn header(r: Response, name: str) -> opt[str]`

### `fn new_request(method: str, url: str) -> Request`

### `fn send(req: Request, deadline: until) -> result[Response, str]`

### `fn get(url: str, deadline: until) -> result[Response, str]`

### `fn head(url: str, deadline: until) -> result[Response, str]`

### `fn post(url: str, content_type: str, body: bytes,`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
