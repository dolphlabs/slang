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
| strings | `ping`, `echo`, `get`, `set`, `set_ex`, `set_nx`, `del_keys`, `exists`, `expire`, `pexpire`, `ttl`, `pttl`, `persist`, `incr`, `decr`, `incr_by`, `decr_by`, `append`, `strlen`, `mget`, `mset` |
| hashes | `hset`, `hget`, `hgetall`, `hdel`, `hexists`, `hkeys`, `hvals`, `hlen`, `hincr_by` |
| lists | `lpush`, `rpush`, `lpop`, `rpop`, `llen`, `lrange`, `ltrim`, `lindex`, `lrem` |
| sets | `sadd`, `smembers`, `srem`, `scard`, `sismember`, `spop` |
| sorted sets | `zadd`, `zrange`, `zrange_scores`, `zrank`, `zscore`, `zrem`, `zcard`, `zincr_by` |
| keys | `key_type`, `rename`, `rename_nx`, `scan` (`KEYS` omitted on purpose) |
| pool | `new_pool`, `new_pool_config`, `acquire`, `release`, `pool_do`, `pool_close` |

A reply is a `redis.Reply`: `kind` is one of `REPLY_SIMPLE`,
`REPLY_ERROR`, `REPLY_INT`, `REPLY_BULK` or `REPLY_ARRAY`, with the
payload in `text`, `num`, `bulk` (`none` for nil) or `items` (empty
with `is_nil` for a nil array).

**Not supported yet:** cluster routing and pub/sub (phases 5-7), RESP3,
server-side sharding beyond standalone.

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

### `fn ping(c: Conn, deadline: until) -> result[str, str]`

PING, expecting PONG back.

### `fn echo(c: Conn, v: bytes, deadline: until) -> result[bytes, str]`

ECHO, expecting the value back byte-identical.

### `fn get(c: Conn, key: str, deadline: until) -> result[opt[bytes], str]`

GET: the value, or none when the key is absent. A missing key is absent data (opt), not an error.

### `fn set(c: Conn, key: str, val: bytes,`

SET: true when the server answers +OK.

### `fn set_ex(c: Conn, key: str, seconds: int, val: bytes,`

SET with a TTL in seconds. True on +OK.

### `fn set_nx(c: Conn, key: str, val: bytes,`

SETNX: true when the key was absent and is now set.

### `fn del_keys(c: Conn, keys: [str], deadline: until) -> result[int, str]`

DEL_KEYS: how many of the keys existed. Named with a suffix because `del` itself removes map entries -- it is a builtin.

### `fn exists(c: Conn, keys: [str], deadline: until) -> result[int, str]`

EXISTS: how many of the keys exist.

### `fn expire(c: Conn, key: str, seconds: int,`

EXPIRE: true when the timeout was set (false: missing key).

### `fn pexpire(c: Conn, key: str, ms: int,`

PEXPIRE: like EXPIRE with a millisecond TTL.

### `fn ttl(c: Conn, key: str, deadline: until) -> result[int, str]`

TTL in seconds: -2 missing key, -1 no TTL, else seconds left.

### `fn pttl(c: Conn, key: str, deadline: until) -> result[int, str]`

PTTL: like TTL in milliseconds.

### `fn persist(c: Conn, key: str, deadline: until) -> result[bool, str]`

PERSIST: true when a TTL was removed (false: missing key or none).

### `fn incr(c: Conn, key: str, deadline: until) -> result[int, str]`

INCR/DECR: the value after the change.

### `fn decr(c: Conn, key: str, deadline: until) -> result[int, str]`

### `fn incr_by(c: Conn, key: str, n: int,`

### `fn decr_by(c: Conn, key: str, n: int,`

### `fn append(c: Conn, key: str, val: bytes,`

APPEND: the length after appending. STRLEN: the current length.

### `fn strlen(c: Conn, key: str, deadline: until) -> result[int, str]`

### `fn mget(c: Conn, keys: [str],`

MGET: one slot per key, none for the missing ones.

### `fn mset(c: Conn, kv: map[str]bytes,`

MSET: field iteration order is insertion order, so the wire order is deterministic for a literally-built map.

### `fn hset(c: Conn, key: str, field: str, val: bytes,`

HSET: how many fields were newly added.

### `fn hget(c: Conn, key: str, field: str,`

HGET: the value, or none when key or field is absent.

### `fn hgetall(c: Conn, key: str,`

HGETALL: the whole hash. Field names decode to str; binary field names a program did not put there itself come back lossy.

### `fn hdel(c: Conn, key: str, fields: [str],`

HDEL: how many fields were removed.

### `fn hexists(c: Conn, key: str, field: str,`

### `fn hkeys(c: Conn, key: str,`

### `fn hvals(c: Conn, key: str,`

### `fn hlen(c: Conn, key: str, deadline: until) -> result[int, str]`

### `fn hincr_by(c: Conn, key: str, field: str, n: int,`

### `fn lpush(c: Conn, key: str, vals: [bytes],`

LPUSH/RPUSH: the length after pushing.

### `fn rpush(c: Conn, key: str, vals: [bytes],`

### `fn lpop(c: Conn, key: str, deadline: until) -> result[opt[bytes], str]`

LPOP/RPOP: the element, or none when the list is absent or drained.

### `fn rpop(c: Conn, key: str, deadline: until) -> result[opt[bytes], str]`

### `fn llen(c: Conn, key: str, deadline: until) -> result[int, str]`

### `fn lrange(c: Conn, key: str, start: int, stop: int,`

LRANGE: elements from start to stop inclusive; negative indexes count from the tail, exactly as Redis documents.

### `fn ltrim(c: Conn, key: str, start: int, stop: int,`

### `fn lindex(c: Conn, key: str, i: int,`

### `fn lrem(c: Conn, key: str, count: int, val: bytes,`

LREM: removes count occurrences of val, returns how many went.

### `fn sadd(c: Conn, key: str, members: [bytes],`

SADD: how many members were newly added.

### `fn smembers(c: Conn, key: str,`

### `fn srem(c: Conn, key: str, members: [bytes],`

SREM: how many members were removed.

### `fn scard(c: Conn, key: str, deadline: until) -> result[int, str]`

### `fn sismember(c: Conn, key: str, member: bytes,`

### `fn spop(c: Conn, key: str, deadline: until) -> result[opt[bytes], str]`

SPOP: a removed member, or none when the set is absent or drained.

### `gc struct ZMember`

### `fn zadd(c: Conn, key: str, members: map[str]float,`

ZADD: how many members were newly added.

### `fn zrange(c: Conn, key: str, start: int, stop: int,`

ZRANGE/ZREVRANGE without scores.

### `fn zrange_scores(c: Conn, key: str, start: int, stop: int,`

ZRANGE WITHSCORES: member/score pairs in range order.

### `fn zrank(c: Conn, key: str, member: bytes,`

ZRANK: the rank, or none when key or member is absent.

### `fn zscore(c: Conn, key: str, member: bytes,`

ZSCORE: the score, or none when key or member is absent.

### `fn zrem(c: Conn, key: str, members: [bytes],`

ZREM: how many members were removed.

### `fn zcard(c: Conn, key: str, deadline: until) -> result[int, str]`

### `fn zincr_by(c: Conn, key: str, n: float, member: bytes,`

### `fn key_type(c: Conn, key: str, deadline: until) -> result[str, str]`

TYPE: the key's type name ("none" when absent).

### `fn rename(c: Conn, key: str, newkey: str,`

RENAME: true on +OK. RENAMENX: true only when newkey was absent.

### `fn rename_nx(c: Conn, key: str, newkey: str,`

### `gc struct ScanOut`

### `fn scan(c: Conn, cursor: int, match: opt[str], count: opt[int],`

SCAN: one cursor step. Thread cursor back in until it returns 0; match and count are server hints, both optional. KEYS is deliberately absent: it blocks the server for the whole keyspace.

### `gc struct Pool`

### `fn new_pool(url: str, max_open: int) -> result[Pool, str]`

Parses the url; connects nothing until the first acquire.

### `fn new_pool_config(cfg: Config, max_open: int) -> result[Pool, str]`

Same, from a Config built by hand (pool_size is ignored: max_open says it here, once, where the pool is made).

### `fn acquire(p: Pool, deadline: until) -> result[Conn, str]`

A connection for the caller's exclusive use, until release().

### `fn release(p: Pool, c: Conn)`

Returns a connection to the pool. One that is broken, closed, or inside MULTI is closed instead: handing those to the next caller would fail its first command, or run it inside someone else's uncommitted transaction.

### `fn pool_do(p: Pool, args: [bytes],`

One command on a pooled connection: acquire, run, release. The connection goes back even when the command fails.

### `fn pool_close(p: Pool)`

Closes every idle connection. Connections checked out are closed as they are released; acquire fails from now on.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
