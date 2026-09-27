# redis

> Package redis.

A **Redis** client, written in slang over `net` like `pg`: commands
waiting on the server park the task on the reactor instead of
blocking a worker thread. Errors keep the server's own text through
the same `result[_, str]` story as every other package.

The protocol core is usable now; connections, pooling, cluster
routing and pub/sub arrive in later phases:

```slang
import "redis";

// encode a command to wire bytes (binary-safe values pass through)
let wire: bytes = redis.encode([to_bytes("SET"), to_bytes("k"),
                                to_bytes("v")]);

// decode one reply; ok(none) means feed more bytes and retry,
// err means the bytes violate the protocol
let r: result[opt[redis.Decoded], str] = redis.decode(wire);

// cluster hash slot of a key (0..16383), honouring {...} hash tags
let s: int = redis.slot("{user1000}.following");

// connection strings for the coming phases
let cr = redis.parse_url("redis://alice:secret@cache.internal:6380/2");
```

| Function | Signature |
|---|---|
| `redis.encode(args)` | `bytes` — one command as a RESP2 array of bulk strings |
| `redis.decode(buf)` | `result[opt[Decoded], str]` — one reply plus bytes consumed |
| `redis.slot(key)` | `int` — cluster hash slot with `{...}` tag support |
| `redis.parse_url(url)` | `result[Config, str]` — `redis://` / `rediss://` |

A reply is a `redis.Reply`: `kind` is one of `REPLY_SIMPLE`,
`REPLY_ERROR`, `REPLY_INT`, `REPLY_BULK` or `REPLY_ARRAY`, with the
payload in `text`, `num`, `bulk` (`none` for nil) or `items` (empty
with `is_nil` for a nil array).

**Not supported yet:** connections and commands (phase 2+), RESP3,
server-side sharding.

## API

### `gc struct Reply`

### `gc struct Decoded`

A decoded reply plus how many bytes of the input it consumed, so a connection holding a read buffer knows what to keep.

### `fn encode(args: [bytes]) -> bytes`

Encode one command invocation as a RESP2 array of bulk strings: SET key value  ->  *3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n Takes already-encoded argument bytes, so binary-safe values pass through untouched. Pure: no I/O, no allocation beyond the result.

### `fn decode(buf: bytes) -> result[opt[Decoded], str]`

Decode one RESP2 reply from the front of `buf`. ok(none) means the buffer ends mid-message -- feed more bytes and retry. ok(some(d)) consumed d.consumed bytes; anything after them is the next message. err means the bytes violate the protocol: never retry on the same connection.

### `fn slot(key: str) -> int`

The hash slot of a key, 0..16383. `{...}` hash tags force colocation: only what sits between the first `{` and the next `}` is hashed. Empty tags hash the whole key, and a `{` with no `}` is literal.

### `gc struct Config`

### `fn parse_url(url: str) -> result[Config, str]`

Parse redis://[[username:]password@]host[:port][/db][?sslmode=...]. rediss:// forces sslmode=require. Percent-escapes in credentials and database decode the same way pg's URLs do.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
