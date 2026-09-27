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
| cluster | `new_cluster`, `cluster_do`, `cluster_refresh`, `cluster_close`, `c*` typed wrappers, same-slot multi-key checks |
| transactions | `multi`, `queue`, `exec`, `discard`, `watch`, `unwatch` (direct Conns; pool and cluster routing stay out) |
| scripting | `eval`, `evalsha` with NOSCRIPT fallback |

A reply is a `redis.Reply`: `kind` is one of `REPLY_SIMPLE`,
`REPLY_ERROR`, `REPLY_INT`, `REPLY_BULK` or `REPLY_ARRAY`, with the
payload in `text`, `num`, `bulk` (`none` for nil) or `items` (empty
with `is_nil` for a nil array).

**Not supported yet:** pub/sub and streams (phases 7-8), RESP3,
replica reads.

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

Run one command: args[0] is the command name. Exactly one reply is consumed, so at most one command is ever in flight per Conn; hold no lock of your own -- this takes c.lock for the round trip. Refused inside MULTI: queued commands answer +QUEUED, which no typed shape could read -- use queue there.

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

Closes every idle connection. Connections checked out are closed as they are released; acquire fails from now on. Closes every idle connection. Connections checked out are closed as they are released; acquire fails from now on.

### `gc struct Cluster`

### `fn new_cluster(cfg: Config, seeds: [str],`

Connect to a cluster: try each seed until one serves CLUSTER SLOTS. Only database 0 exists in cluster mode. The deadline covers the whole bootstrap.

### `fn cluster_refresh(cl: Cluster, deadline: until) -> result[bool, str]`

Re-learn the whole slot map from a known node (any current pool will do; the first one wins) or a bootstrap seed. Manual recovery for outages the MOVED path cannot see.

### `fn cluster_do(cl: Cluster, key: str, args: [bytes],`

Run args against the node owning key, following MOVED (map update plus retry, up to MAX_REDIRECTS) and ASK (one directed ASKING hop, returned directly). Every other error returns verbatim.

### `fn cluster_close(cl: Cluster)`

### `fn cping(cl: Cluster, deadline: until) -> result[str, str]`

### `fn cecho(cl: Cluster, v: bytes, deadline: until) -> result[bytes, str]`

### `fn cget(cl: Cluster, key: str, deadline: until) -> result[opt[bytes], str]`

### `fn cset(cl: Cluster, key: str, val: bytes,`

### `fn cset_ex(cl: Cluster, key: str, seconds: int, val: bytes,`

### `fn cset_nx(cl: Cluster, key: str, val: bytes,`

### `fn cdel_keys(cl: Cluster, keys: [str],`

### `fn cexists(cl: Cluster, keys: [str],`

### `fn cexpire(cl: Cluster, key: str, seconds: int,`

### `fn cpexpire(cl: Cluster, key: str, ms: int,`

### `fn cttl(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn cpttl(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn cpersist(cl: Cluster, key: str,`

### `fn cincr(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn cdecr(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn cincr_by(cl: Cluster, key: str, n: int,`

### `fn cdecr_by(cl: Cluster, key: str, n: int,`

### `fn cappend(cl: Cluster, key: str, val: bytes,`

### `fn cstrlen(cl: Cluster, key: str,`

### `fn cmget(cl: Cluster, keys: [str],`

### `fn cmset(cl: Cluster, kv: map[str]bytes,`

### `fn chset(cl: Cluster, key: str, field: str, val: bytes,`

### `fn chget(cl: Cluster, key: str, field: str,`

### `fn chdel(cl: Cluster, key: str, fields: [str],`

### `fn chexists(cl: Cluster, key: str, field: str,`

### `fn chlen(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn chincr_by(cl: Cluster, key: str, field: str, n: int,`

### `fn clpush(cl: Cluster, key: str, vals: [bytes],`

### `fn crpush(cl: Cluster, key: str, vals: [bytes],`

### `fn clpop(cl: Cluster, key: str,`

### `fn crpop(cl: Cluster, key: str,`

### `fn cllen(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn csadd(cl: Cluster, key: str, members: [bytes],`

### `fn csrem(cl: Cluster, key: str, members: [bytes],`

### `fn cscard(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn csismember(cl: Cluster, key: str, member: bytes,`

### `fn czadd(cl: Cluster, key: str, members: map[str]float,`

### `fn czrem(cl: Cluster, key: str, members: [bytes],`

### `fn czcard(cl: Cluster, key: str, deadline: until) -> result[int, str]`

### `fn czscore(cl: Cluster, key: str, member: bytes,`

### `fn ckey_type(cl: Cluster, key: str,`

### `fn crename(cl: Cluster, key: str, newkey: str,`

### `fn cscan(cl: Cluster, cursor: int, match: opt[str], count: opt[int],`

SCAN steps one node only (slot 0's owner): cluster-wide iteration fans out per node with cluster_refresh's map in hand.

### `fn multi(c: Conn, deadline: until) -> result[bool, str]`

MULTI: true on +OK. The connection leaves the pool from here until EXEC or DISCARD.

### `fn queue(c: Conn, args: [bytes],`

Queue one command inside MULTI. Anything but +QUEUED aborts the whole transaction server-side; that surfaces here as an err, and a later EXEC answers EXECABORT.

### `fn exec(c: Conn, deadline: until) -> result[[Reply], str]`

EXEC: the queued replies in order, error elements included. A nil array means nothing ran (watched keys changed): an err, since no caller could use an empty success. Always leaves MULTI, even on EXECABORT -- the server does too.

### `fn discard(c: Conn, deadline: until) -> result[bool, str]`

DISCARD: true on +OK, back outside MULTI either way the server answers.

### `fn watch(c: Conn, keys: [str],`

WATCH/UNWATCH for optimistic locking: watch, read, MULTI, queue, EXEC; a nil EXEC (err here) means someone else wrote first, so retry the whole sequence.

### `fn unwatch(c: Conn, deadline: until) -> result[bool, str]`

### `fn eval(c: Conn, script: str, keys: [str], args: [bytes],`

EVAL: the script's raw reply, whose shape depends on what it returns -- bulk, int, array, or error, decoded verbatim.

### `fn evalsha(c: Conn, script: str, keys: [str], args: [bytes],`

EVALSHA with automatic EVAL fallback: the common path sends only 40 hex characters; a server that never saw the script answers NOSCRIPT and the call transparently re-sends the source.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
