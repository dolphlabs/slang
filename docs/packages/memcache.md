# memcache

> Package memcache.

A memcached client over the text protocol, across one or more servers.

```slang
import "memcache";

let mc = memcache.new(["cache-1:11211", "cache-2:11211"]);
memcache.set(mc, "user:42", to_bytes(body), 300, deadline);   // 5 minutes
let gr = memcache.get(mc, "user:42", deadline);
guard let found = gr else let e = err_of(gr) { return err(e); }  // I/O error
if let v = found { use(v); } else { /* a miss */ }
```

The client has `get`, `gets` (with the cas token), `get_multi` (one
request per server), `set`, `add`, `replace`, `cas`, `delete`, `incr`,
`decr`, `touch` and `close`. Keys spread over servers by rendezvous
hashing, so adding or removing a server moves only its share. Up to
`max_idle` connections per server are kept and reused, and a connection
that saw any error is closed rather than reused. Keys are checked (1 to
250 bytes, no spaces or control characters) and values are limited to
`max_value` (1 MB, memcached's default item size).

## API

### `gc struct Client`

### `fn new(servers: [str]) -> Client`

### `struct Item`

### `fn get(c: Client, key: str, deadline: until) -> result[opt[bytes], str]`

The value for key, or none on a miss.

### `fn gets(c: Client, key: str, deadline: until) -> result[opt[Item], str]`

The item for key with its cas token, or none on a miss.

### `fn get_multi(c: Client, keys: [str], deadline: until) -> result[map[str]bytes, str]`

The values of every key found, one request per server.

### `fn set(c: Client, key: str, value: bytes, ttl: int, deadline: until) -> result[bool, str]`

Stores value for ttl seconds (0: no expiry; over 30 days is read by memcached as a unix time).

### `fn add(c: Client, key: str, value: bytes, ttl: int, deadline: until) -> result[bool, str]`

Stores only if the key is absent: false if it was there.

### `fn replace(c: Client, key: str, value: bytes, ttl: int, deadline: until) -> result[bool, str]`

Stores only if the key is present: false if it was not.

### `fn cas(c: Client, key: str, value: bytes, ttl: int, cas_token: int, deadline: until) -> result[bool, str]`

Stores only if the item is unchanged since gets returned cas: false if another writer got there first (or the key is gone).

### `fn delete(c: Client, key: str, deadline: until) -> result[bool, str]`

Deletes key: false if it was not there.

### `fn incr(c: Client, key: str, delta: int, deadline: until) -> result[opt[int], str]`

Adds delta to a numeric value: the new value, or none if the key is absent.

### `fn decr(c: Client, key: str, delta: int, deadline: until) -> result[opt[int], str]`

Subtracts delta, stopping at 0 as memcached does.

### `fn touch(c: Client, key: str, ttl: int, deadline: until) -> result[bool, str]`

Gives key a new ttl: false if it was not there.

### `fn close(c: Client)`

Closes every idle connection.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
