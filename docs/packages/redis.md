# redis

> Package redis.

A **Redis** client, written in slang over `net` like `pg`: commands
waiting on the server park the task on the reactor instead of
blocking a worker thread. Errors keep the server's own text through
the same `result[_, str]` story as every other package.

The protocol core is usable now; pooling, cluster
routing and pub/sub arrive in later phases. Connections are here:
`connect` dials with a deadline, runs `AUTH` and `SELECT`, and hands
back a `Conn` that any task may share -- one round trip at a time,
serialized by an internal lock. `do` runs one command; a reply that
violates the protocol breaks the connection for good, while a
server-side command error only fails that call.

```slang
import "redis";
import "time";

let dl = until_of(time.mono() + 5000000000);
let cr = redis.connect("redis://:secret@cache.internal:6380/2", dl);
guard let c = cr else let e = err_of(cr) {
    log.error("connect: " + e);
    exit(1);
}

// encode a command to wire bytes (binary-safe values pass through)
let wire: bytes = redis.encode([to_bytes("SET"), to_bytes("k"),
                                to_bytes("v")]);

// run it; at most one command is ever in flight per Conn
let r = redis.do(c, [to_bytes("PING")], dl);

// decode one reply; ok(none) means feed more bytes and retry,
// err means the bytes violate the protocol
let dr: result[opt[redis.Decoded], str] = redis.decode(wire);

// cluster hash slot of a key (0..16383), honouring {...} hash tags
let s: int = redis.slot("{user1000}.following");

// connection strings for the coming phases
let ur = redis.parse_url("redis://alice:secret@cache.internal:6380/2");

redis.close(c);
```

| Function | Signature |
|---|---|
| `redis.encode(args)` | `bytes` — one command as a RESP2 array of bulk strings |
| `redis.decode(buf)` / `redis.decode_at(buf, pos)` | `result[opt[Decoded], str]` — one reply plus bytes consumed |
| `redis.slot(key)` | `int` — cluster hash slot with `{...}` tag support |
| `redis.parse_url(url)` | `result[Config, str]` — `redis://` / `rediss://` |
| `redis.connect(url, deadline)` / `redis.connect_config(cfg, deadline)` | `result[Conn, str]` — dial, `AUTH`, `SELECT` |
| `redis.do(c, args, deadline)` | `result[Reply, str]` — one command round trip |
| `redis.close(c)` / `redis.usable(c)` | — shutdown / may commands still be attempted |

A reply is a `redis.Reply`: `kind` is one of `REPLY_SIMPLE`,
`REPLY_ERROR`, `REPLY_INT`, `REPLY_BULK` or `REPLY_ARRAY`, with the
payload in `text`, `num`, `bulk` (`none` for nil) or `items` (empty
with `is_nil` for a nil array).

**Not supported yet:** pooling and commands (phases 3-4), RESP3,
server-side sharding.

## API

### `let REPLY_SIMPLE = 0;   // +str           (text holds the text)`

The five RESP2 reply types. A reply is always one of exactly one.

### `let REPLY_ERROR = 1;    // -err           (text holds the text)`

### `let REPLY_INT = 2;      // :num           (num holds the value)`

### `let REPLY_BULK = 3;     // $len\r\n<bytes> (bulk holds it, none when nil)`

### `let REPLY_ARRAY = 4;    // *n\r\n...      (items holds them)`

### `gc struct Reply`

### `gc struct Decoded`

A decoded reply plus how many bytes of the input it consumed, so a connection holding a read buffer knows what to keep.

### `fn encode(args: [bytes]) -> bytes`

Encode one command invocation as a RESP2 array of bulk strings: SET key value  ->  *3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n Takes already-encoded argument bytes, so binary-safe values pass through untouched. Pure: no I/O, no allocation beyond the result.

### `fn decode(buf: bytes) -> result[opt[Decoded], str]`

Decode one RESP2 reply from the front of `buf`. ok(none) means the buffer ends mid-message -- feed more bytes and retry. ok(some(d)) consumed d.consumed bytes; anything after them is the next message. err means the bytes violate the protocol: never retry on the same connection.

### `fn decode_at(buf: bytes, pos: int) -> result[opt[Decoded], str]`

Decode one reply starting at `pos` instead of 0, for readers that keep one long-lived buffer and an offset into it (see Conn): no slicing, so no per-recv copy of everything already buffered. consumed counts from `pos`.

### `fn slot(key: str) -> int`

The hash slot of a key, 0..16383. `{...}` hash tags force colocation: only what sits between the first `{` and the next `}` is hashed. Empty tags hash the whole key, and a `{` with no `}` is literal.

### `gc struct Config`

### `fn parse_url(url: str) -> result[Config, str]`

Parse redis://[[username:]password@]host[:port][/db][?sslmode=...]. rediss:// forces sslmode=require. Percent-escapes in credentials and database decode the same way pg's URLs do.

### `gc struct Conn`

One server connection: exactly one round trip in flight at a time, serialized by lock. A Conn is safe to share between tasks; every public call below takes the lock for its whole exchange.

### `fn connect_config(cfg: Config, deadline: until) -> result[Conn, str]`

Open a connection from a parsed Config and run the handshake (AUTH when a password is set, SELECT when db is not 0). The deadline covers everything: DNS, TCP connect, TLS upgrade, login.

### `fn connect(url: str, deadline: until) -> result[Conn, str]`

Open a connection from a URL. See parse_url for the shape.

### `fn do(c: Conn, args: [bytes], deadline: until) -> result[Reply, str]`

Run one command: args[0] is the command name. Exactly one reply is consumed, so at most one command is ever in flight per Conn; hold no lock of your own -- this takes c.lock for the round trip.

### `fn close(c: Conn)`

Shut the connection down. In-flight calls on other tasks finish (or hit their own deadlines) first; close waits for the lock.

### `fn usable(c: Conn) -> bool`

True while commands may still be attempted: not closed, not broken. A server-side idle close is discovered on use, which marks the connection broken then.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
