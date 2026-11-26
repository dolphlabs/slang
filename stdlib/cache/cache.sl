// An in-process cache: string keys, any value type, bounded by entry
// count (and, optionally, by bytes), least recently used out first, with
// an optional time to live.
//
//     import "cache";
//
//     let o = cache.options();
//     o.max_entries = 50000;
//     o.ttl_ms = 30000;                                   // 0: entries never expire
//     let cr: result[cache.Cache[User], str] = cache.new(o);
//     guard let users = cr else |e| { panic(e); }
//
//     cache.put(users, "u:42", u);
//     let hit = cache.get(users, "u:42");                 // opt[User]
//     cache.remove(users, "u:42");
//
//     // a miss loads once, however many tasks ask at the same moment
//     let r = cache.get_or_load(users, "u:42", db, load_user);   // result[User, str]
//     fn load_user(db: pg.Pool, key: str) -> result[User, str] { ... }
//
// The cache is split into shards, each with its own lock, hash table and
// recency list, so tasks on different workers rarely wait for each other.
// A key is hashed once (strings.hash): the low bits pick its shard, the
// rest its slot in the shard's open-addressing table, whose deletes are
// constant time (backward shift, no tombstones) -- a cache deletes on
// every eviction. The limits are per shard (max_entries / shards each),
// as in most sharded caches.
// When a shard is full, its least recently used entry goes. (CLOCK, which
// marks a hit instead of moving it, measured no faster here and evicts a
// new entry first when everything else is hot, so this is plain LRU.)
//
// Expired entries are dropped when read, and the oldest go first when a
// shard is full, so a cache full of expired entries holds them until it
// is written to again.
//
// get_or_load runs the loader once per key at a time: the first caller
// runs it in its own task, the others wait for its result. A loader that
// panics fails every waiter with the panic's message instead of leaving
// them waiting; an error is returned to all of them and nothing is cached.
// slang has no closures, so what the loader needs comes in as ctx.

import "strings";
import "time";

pub gc struct Options {
    // the most entries the cache holds
    max_entries: int,
    // the most bytes it holds, counting each key's length and the size
    // given to put_sized; 0 is no byte limit
    max_bytes: int,
    // milliseconds an entry lives after it is put; 0 is forever
    ttl_ms: int,
    // a power of two; 0 picks 16
    shards: int,
}

pub fn options() -> Options {
    return Options { max_entries: 10000, max_bytes: 0, ttl_ms: 0, shards: 0 };
}

pub gc struct Stats {
    hits: int,
    misses: int,
    // entries pushed out by the limits
    evictions: int,
    // entries found expired
    expirations: int,
    entries: int,
    used_bytes: int,
}

gc struct Entry[V] {
    key: str,
    hash: int,
    val: V,
    // monotonic ns; 0 never expires
    expires: int,
    size: int,
    prev: opt[Entry[V]],
    next: opt[Entry[V]],
}

// A load in progress: done closes when res is set.
gc struct Flight[V] {
    done: chan[bool],
    res: result[V, str],
}

gc struct Shard[V] {
    mu: mutex,
    // open addressing, linear probing, a power of two at most half full
    table: [opt[Entry[V]]],
    tmask: int,
    // most recently used first; evictions take from the tail
    head: opt[Entry[V]],
    tail: opt[Entry[V]],
    count: int,
    used_bytes: int,
    max_entries: int,
    max_bytes: int,
    flights: map[str]Flight[V],
    hits: int,
    misses: int,
    evictions: int,
    expirations: int,
}

pub gc struct Cache[V] {
    shards: [Shard[V]],
    mask: int,
    // bits of the hash the shard index uses
    shift: int,
    // ns; 0 is forever
    ttl: int,
}

// A cache with options o: an error if max_entries is below 1, max_bytes
// or ttl_ms negative, or shards over 4096.
pub fn new[V](o: Options) -> result[Cache[V], str] {
    if o.max_entries < 1 || o.max_bytes < 0 || o.ttl_ms < 0 || o.shards > 4096 {
        return err("cache: max_entries must be at least 1, max_bytes and ttl_ms at least 0, shards at most 4096");
    }
    let n = o.shards;
    if n <= 0 {
        n = 16;
    }
    let p = 1;
    let shift = 0;
    while p < n {
        p = p * 2;
        shift += 1;
    }
    let per_entries = (o.max_entries + p - 1) / p;
    if per_entries < 1 {
        per_entries = 1;
    }
    let per_bytes = 0;
    if o.max_bytes > 0 {
        per_bytes = (o.max_bytes + p - 1) / p;
    }
    let shards: [Shard[V]] = [];
    for _i in 0..p {
        let fl: map[str]Flight[V] = {};
        push(shards, Shard[V] { mu: make_mutex(), table: empty_table(16), tmask: 15, head: none, tail: none, count: 0,
                                used_bytes: 0, max_entries: per_entries, max_bytes: per_bytes, flights: fl, hits: 0,
                                misses: 0, evictions: 0, expirations: 0 });
    }
    let ttl = 0;
    if o.ttl_ms > 0 {
        ttl = o.ttl_ms * 1000000;
    }
    return ok(Cache[V] { shards: shards, mask: p - 1, shift: shift, ttl: ttl });
}

fn empty_table[V](n: int) -> [opt[Entry[V]]] {
    let t: [opt[Entry[V]]] = [];
    let nothing: opt[Entry[V]] = none;
    for _i in 0..n {
        push(t, nothing);
    }
    return t;
}

fn now() -> int {
    return time.mono() as int;
}

// ---- the shard's table -----------------------------------------------------

// The slot holding key, or -1. h is the key's hash.
fn find_slot[V](s: Shard[V], key: str, h: int) -> int {
    let i = (h >> 16) & s.tmask;
    while true {
        guard let e = s.table[i] else { return -1; }
        if e.hash == h && e.key == key {
            return i;
        }
        i = (i + 1) & s.tmask;
    }
    return -1;
}

fn table_add[V](s: Shard[V], e: Entry[V]) {
    if (s.count + 1) * 2 > len(s.table) {
        grow(s);
    }
    let i = (e.hash >> 16) & s.tmask;
    while true {
        guard let _occupied = s.table[i] else { break; }
        i = (i + 1) & s.tmask;
    }
    s.table[i] = some(e);
}

fn grow[V](s: Shard[V]) {
    let old = s.table;
    let n = len(old) * 2;
    s.table = empty_table(n);
    s.tmask = n - 1;
    for slot in old {
        if let e = slot {
            let i = (e.hash >> 16) & s.tmask;
            while true {
                guard let _occupied = s.table[i] else { break; }
                i = (i + 1) & s.tmask;
            }
            s.table[i] = some(e);
        }
    }
}

// Empties slot i and shifts the probe run after it back, so every key
// stays reachable without tombstones.
fn table_remove_at[V](s: Shard[V], i: int) {
    let hole = i;
    let j = (i + 1) & s.tmask;
    while true {
        guard let e = s.table[j] else { break; }
        let home = (e.hash >> 16) & s.tmask;
        // e may fill the hole if its home is not between the hole and j
        // (cyclically): moving it back keeps it on its probe path
        let dist_j = (j - home) & s.tmask;
        let dist_hole = (hole - home) & s.tmask;
        if dist_hole <= dist_j {
            s.table[hole] = some(e);
            hole = j;
        }
        j = (j + 1) & s.tmask;
    }
    let nothing: opt[Entry[V]] = none;
    s.table[hole] = nothing;
}

fn shard_of[V](c: Cache[V], h: int) -> Shard[V] {
    return c.shards[h & c.mask];
}

// ---- reading and writing ------------------------------------------------

// The value under key, if it is there and has not expired.
pub fn get[V](c: Cache[V], key: str) -> opt[V] {
    let h = strings.hash(key);
    let s = shard_of(c, h);
    mutex_lock(s.mu);
    let out = lookup(s, key, h);
    mutex_unlock(s.mu);
    return out;
}

// With s locked: the live entry's value, counted as a hit or a miss.
fn lookup[V](s: Shard[V], key: str, h: int) -> opt[V] {
    let i = find_slot(s, key, h);
    if i < 0 {
        s.misses += 1;
        return none;
    }
    guard let e = s.table[i] else { return none; }
    if e.expires != 0 && now() >= e.expires {
        drop_at(s, e, i);
        s.expirations += 1;
        s.misses += 1;
        return none;
    }
    s.hits += 1;
    if let hd = s.head {
        if hd.hash != e.hash || hd.key != e.key {
            unlink(s, e);
            push_front(s, e);
        }
    }
    return some(e.val);
}

// Puts value under key with the cache's time to live, replacing what was
// there.
pub fn put[V](c: Cache[V], key: str, value: V) {
    put_entry(c, key, value, 0, c.ttl);
}

// put with this entry's own time to live (0: forever).
pub fn put_ttl[V](c: Cache[V], key: str, value: V, ttl_ms: int) {
    put_entry(c, key, value, 0, ttl_ms * 1000000);
}

// put of a value that counts as size bytes towards max_bytes (its key's
// length is added).
pub fn put_sized[V](c: Cache[V], key: str, value: V, size: int) {
    put_entry(c, key, value, size, c.ttl);
}

fn put_entry[V](c: Cache[V], key: str, value: V, size: int, ttl: int) {
    let h = strings.hash(key);
    let s = shard_of(c, h);
    mutex_lock(s.mu);
    insert(s, key, h, value, size, ttl);
    mutex_unlock(s.mu);
}

// With s locked: key set to value, and the limits enforced.
fn insert[V](s: Shard[V], key: str, h: int, value: V, size: int, ttl: int) {
    let expires = 0;
    if ttl > 0 {
        expires = now() + ttl;
    }
    let total = len(key) + size;
    let i = find_slot(s, key, h);
    if i >= 0 {
        guard let e = s.table[i] else { return; }
        s.used_bytes += total - e.size;
        e.val = value;
        e.size = total;
        e.expires = expires;
        unlink(s, e);
        push_front(s, e);
    } else {
        let e = Entry[V] { key: key, hash: h, val: value, expires: expires, size: total, prev: none,
                           next: none };
        table_add(s, e);
        s.count += 1;
        s.used_bytes += total;
        push_front(s, e);
    }
    evict(s);
}

// While over a limit, the least recently used entry goes.
fn evict[V](s: Shard[V]) {
    while s.count > s.max_entries || (s.max_bytes > 0 && s.used_bytes > s.max_bytes && s.count > 1) {
        guard let last = s.tail else { break; }
        drop_at(s, last, find_slot(s, last.key, last.hash));
        s.evictions += 1;
    }
}

// Removes key; true if it was there.
pub fn remove[V](c: Cache[V], key: str) -> bool {
    let h = strings.hash(key);
    let s = shard_of(c, h);
    mutex_lock(s.mu);
    let i = find_slot(s, key, h);
    if i >= 0 {
        if let e = s.table[i] {
            drop_at(s, e, i);
        }
    }
    mutex_unlock(s.mu);
    return i >= 0;
}

// Removes every entry (the statistics stay).
pub fn clear[V](c: Cache[V]) {
    for s in c.shards {
        mutex_lock(s.mu);
        s.table = empty_table(16);
        s.tmask = 15;
        s.head = none;
        s.tail = none;
        s.count = 0;
        s.used_bytes = 0;
        mutex_unlock(s.mu);
    }
}

// Entries held, expired ones not yet dropped included.
pub fn len_of[V](c: Cache[V]) -> int {
    let n = 0;
    for s in c.shards {
        mutex_lock(s.mu);
        n += s.count;
        mutex_unlock(s.mu);
    }
    return n;
}

pub fn stats[V](c: Cache[V]) -> Stats {
    let st = Stats { hits: 0, misses: 0, evictions: 0, expirations: 0, entries: 0, used_bytes: 0 };
    for s in c.shards {
        mutex_lock(s.mu);
        st.hits += s.hits;
        st.misses += s.misses;
        st.evictions += s.evictions;
        st.expirations += s.expirations;
        st.entries += s.count;
        st.used_bytes += s.used_bytes;
        mutex_unlock(s.mu);
    }
    return st;
}

// ---- loading once ----------------------------------------------------------

// The value under key; on a miss, loader(ctx, key) is run once -- however
// many tasks ask for key meanwhile -- and its value cached with the
// cache's time to live. Its error, or its panic's message, is returned to
// every caller waiting on it, and nothing is cached.
pub fn get_or_load[V, C](c: Cache[V], key: str, ctx: C, loader: fn(C, str) -> result[V, str]) -> result[V, str] {
    let h = strings.hash(key);
    let s = shard_of(c, h);
    mutex_lock(s.mu);
    let hit = lookup(s, key, h);
    if let v = hit {
        mutex_unlock(s.mu);
        return ok(v);
    }
    if has(s.flights, key) {
        let f = s.flights[key];
        mutex_unlock(s.mu);
        chan_recv(f.done);
        return f.res;
    }
    let started: result[V, str] = err("cache: the load has not finished");
    let f = Flight[V] { done: make_chan(1), res: started };
    s.flights[key] = f;
    mutex_unlock(s.mu);
    // in its own task, so a panic comes back as an error, not a waiter
    // left waiting forever
    let task = spawn run_loader(loader, ctx, key);
    let jr = join_wait(task);
    let res: result[V, str] = err("cache: the loader for " + key + " failed");
    if let inner = jr {
        res = inner;
    } else {
        res = err("cache: the loader for " + key + " panicked: " + err_of(jr));
    }
    mutex_lock(s.mu);
    del(s.flights, key);
    if let v = res {
        insert(s, key, h, v, 0, c.ttl);
    }
    mutex_unlock(s.mu);
    f.res = res;
    chan_close(f.done);
    return res;
}

fn run_loader[V, C](loader: fn(C, str) -> result[V, str], ctx: C, key: str) -> result[V, str] {
    return loader(ctx, key);
}

// ---- the LRU list ------------------------------------------------------------

fn unlink[V](s: Shard[V], e: Entry[V]) {
    if let p = e.prev {
        p.next = e.next;
    } else {
        s.head = e.next;
    }
    if let n = e.next {
        n.prev = e.prev;
    } else {
        s.tail = e.prev;
    }
    e.prev = none;
    e.next = none;
}

fn push_front[V](s: Shard[V], e: Entry[V]) {
    e.prev = none;
    e.next = s.head;
    if let h = s.head {
        h.prev = some(e);
    } else {
        s.tail = some(e);
    }
    s.head = some(e);
}

// Entry e, in slot i, out of the table and the list.
fn drop_at[V](s: Shard[V], e: Entry[V], i: int) {
    unlink(s, e);
    if i >= 0 {
        table_remove_at(s, i);
    }
    s.count -= 1;
    s.used_bytes -= e.size;
}
