# proxyproto

> Package proxyproto.

The PROXY protocol, versions 1 and 2: the header HAProxy, AWS NLB and
other balancers put in front of a connection so the server sees the
real client address instead of the balancer's.

```slang
import "net";
import "proxyproto";
import "time";

guard let h = proxyproto.read_until(fd, until_of(time.mono() + 5000000000)) else |e| { net.close(fd); return; }
println(h.src_addr + ":" + to_str(h.src_port));   // the real client
// h.rest: bytes that came after the header, the start of the stream
```

- `parse(b)` reads a header from the start of `b`: `some(header)`,
  `none` when `b` is a prefix of one and more bytes are needed, or an
  error when `b` is not a PROXY header. `header.size` is its length.
- `read_until(fd, deadline)` reads one off a socket and keeps any bytes
  that arrived after it in `header.rest`.
- A `Header` has `version`, `family` (`tcp4`, `tcp6`, `udp4`, `udp6`,
  `unix`, `unknown`), the source and destination addresses and ports, and
  v2's `tlvs` (`kind`, `value`): ALPN, the TLS server name (0x02), AWS's
  VPC endpoint id (0xEA) and so on. `local` is true for a v2 LOCAL
  header, a balancer's health check, which carries no addresses.
- `encode_v1(h)` and `encode_v2(h)` build headers, for a proxy written
  in slang or a test. IPv6 addresses are printed in RFC 5952 form.

The header is only bytes the peer sent. Require it on a listener that
only the balancer can reach, or check the peer address first: otherwise
any client can claim any address. The header comes before any TLS
handshake, and `net.tls_accept` does its own accept on the listener, so
a PROXY header in front of TLS needs a server-side TLS upgrade of an
accepted fd, which `net` does not have yet.

## API

### `struct Tlv`

One v2 type-length-value field: ALPN (0x01), authority (0x02, the TLS SNI name), unique id (0x05), SSL details (0x20), AWS VPC endpoint id (0xEA), and so on.

### `struct Header`

### `fn parse(b: bytes) -> result[opt[Header], str]`

The header at the start of b; none if b is a prefix of one and more bytes are needed; an error if b does not start with a PROXY header.

### `fn read_until(fd: i32, deadline: until) -> result[Header, str]`

Reads a header from fd, then stops: whatever arrived after it is in rest. Bounded by deadline as a whole.

### `fn encode_v1(h: Header) -> bytes`

The v1 (text) header for h: "PROXY TCP4 1.2.3.4 5.6.7.8 1111 443\r\n". Families other than tcp4 and tcp6 are sent as UNKNOWN.

### `fn encode_v2(h: Header) -> result[bytes, str]`

The v2 (binary) header for h, TLVs included. An error for an address that does not match h.family.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
