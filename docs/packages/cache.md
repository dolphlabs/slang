# cache

> Package cache.

An in-process cache: string keys, any value type, bounded by entry count
(and optionally by bytes), least recently used out first, with an
optional time to live, and a loader that runs once per key however many
tasks ask at the same moment.

```slang
import "cache";

let o = cache.options();
o.max_entries = 50000;
o.ttl_ms = 30000;                                          // 0: never expires
let cr: result[cache.Cache[User], str] = cache.new(o);
guard let users = cr else |e| { panic(e); }

cache.put(users, "u:42", u);
cache.get(users, "u:42");                                  // opt[User]
cache.put_ttl(users, "u:7", u7, 1000);                     // its own time to live
cache.put_sized(users, "u:9", u9, 512);                    // counts towards max_bytes
cache.remove(users, "u:42");
cache.stats(users);                                        // hits, misses, evictions, ...

let r = cache.get_or_load(users, "u:42", db, load_user);   // result[User, str]
fn load_user(db: pg.Pool, key: str) -> result[User, str] { ... }
```

**Shards.** The cache is split into shards (16 by default), each with its
own lock, hash table and recency list, so tasks on different workers
rarely wait for each other. A key is hashed once with `strings.hash`; the
low bits pick its shard. Limits are per shard (`max_entries / shards`), so
the entry evicted is the least recently used of its shard, and a cache
filled to its limit holds slightly fewer than `max_entries` when its keys
spread unevenly (998,222 of 1,000,000 in the benchmark), as in most
sharded caches.

**The table** is the shard's own open-addressing table, not a `map`:
`map`'s `del` keeps insertion order and so takes time linear in the map's
size, and a cache deletes on every eviction. The table deletes by
backward shift in constant time on average, grows at half full, and
reuses the hash that chose the shard.

**Expiry** is checked when an entry is read: an expired entry is dropped
and counted. Entries nobody reads leave as the shard's least recently used.

**Loading once.** On a miss, `get_or_load` runs the loader in its own
task; callers that ask for the same key meanwhile wait for its result. A
loader's error, or its panic's message, goes to every waiter and nothing
is cached. slang has no closures, so what the loader needs comes in as
`ctx`.

**Cost.** Linux container, 4 workers on 4 CPUs, 100,000 keys drawn
skewed, a 10,000-entry cache, 90% reads, medians of 4 rounds against Go's
`hashicorp/golang-lru/v2` (one lock) and `ristretto`:

| | slang `cache` | golang-lru | ristretto |
|---|---|---|---|
| one task, ns/op | 714 | 212 | 268 |
| 8 tasks, ns/op | 320 | 232 | 126 |
| hit rate | 21.0% | 21.0% | 3.1% |
| 1M entries, RSS | 256 MB | 198 MB | -- |

slang's hit rate matches golang-lru's (both are LRU); ristretto admits
few new keys under this skew. Most of slang's single-task gap is below
the cache: a plain `map[str]int` lookup costs 290-400 ns on the same
keys, as `str` is NUL-terminated (length, hashing and `==` walk it).
`bench/cache/run.sh` reproduces this.

## API

### `gc struct Options`

### `fn options() -> Options`

### `gc struct Stats`

### `gc struct Cache[V]`

### `fn new[V](o: Options) -> result[Cache[V], str]`

A cache with options o: an error if max_entries is below 1, max_bytes or ttl_ms negative, or shards over 4096.

### `fn get[V](c: Cache[V], key: str) -> opt[V]`

The value under key, if it is there and has not expired.

### `fn put[V](c: Cache[V], key: str, value: V)`

Puts value under key with the cache's time to live, replacing what was there.

### `fn put_ttl[V](c: Cache[V], key: str, value: V, ttl_ms: int)`

put with this entry's own time to live (0: forever).

### `fn put_sized[V](c: Cache[V], key: str, value: V, size: int)`

put of a value that counts as size bytes towards max_bytes (its key's length is added).

### `fn remove[V](c: Cache[V], key: str) -> bool`

Removes key; true if it was there.

### `fn clear[V](c: Cache[V])`

Removes every entry (the statistics stay).

### `fn len_of[V](c: Cache[V]) -> int`

Entries held, expired ones not yet dropped included.

### `fn stats[V](c: Cache[V]) -> Stats`

### `fn get_or_load[V, C](c: Cache[V], key: str, ctx: C, loader: fn(C, str) -> result[V, str]) -> result[V, str]`

The value under key; on a miss, loader(ctx, key) is run once -- however many tasks ask for key meanwhile -- and its value cached with the cache's time to live. Its error, or its panic's message, is returned to every caller waiting on it, and nothing is cached.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
