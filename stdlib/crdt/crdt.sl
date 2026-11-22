// Conflict-free replicated data types: state that replicas update on
// their own and merge in any order, any number of times, and always agree
// on afterwards. For counters, sets and maps shared between nodes without
// a coordinator -- feature flags, presence, rate counts across a cluster.
//
//     import "crdt";
//
//     let a = crdt.gcounter();
//     let b = crdt.gcounter();
//     crdt.gc_inc(a, "node-a", 3);
//     crdt.gc_inc(b, "node-b", 4);
//     crdt.gc_merge(a, b);         // a now holds both
//     crdt.gc_value(a)             // 7
//
// Every merge is commutative, associative and idempotent. Each node uses
// its own id for its updates. State is plain data (maps of ints and
// strings), so json.encode / json.decode ship it between nodes.
//
// The OR-set is the "optimized" one (ORSWOT): no tombstones, so its size
// follows the elements present plus one counter per node, however many
// adds and removes it has seen.

// ---- G-Counter: grow-only ----------------------------------------------------

pub gc struct GCounter {
    counts: map[str]int,
}

pub fn gcounter() -> GCounter {
    let m: map[str]int = {};
    return GCounter { counts: m };
}

// Adds n (n >= 0) to node's count.
pub fn gc_inc(c: GCounter, node: str, n: int) {
    if n < 0 { panic("crdt: a G-counter cannot decrease"); }
    let cur = 0;
    if has(c.counts, node) { cur = c.counts[node]; }
    c.counts[node] = cur + n;
}

pub fn gc_value(c: GCounter) -> int {
    let total = 0;
    for _k, v in c.counts { total = total + v; }
    return total;
}

// c takes in everything other has seen.
pub fn gc_merge(c: GCounter, other: GCounter) {
    for k, v in other.counts {
        if !has(c.counts, k) || c.counts[k] < v { c.counts[k] = v; }
    }
}

// ---- PN-Counter: up and down -------------------------------------------------

pub gc struct PNCounter {
    p: GCounter,
    n: GCounter,
}

pub fn pncounter() -> PNCounter {
    return PNCounter { p: gcounter(), n: gcounter() };
}

pub fn pn_add(c: PNCounter, node: str, delta: int) {
    if delta >= 0 { gc_inc(c.p, node, delta); } else { gc_inc(c.n, node, -delta); }
}

pub fn pn_value(c: PNCounter) -> int {
    return gc_value(c.p) - gc_value(c.n);
}

pub fn pn_merge(c: PNCounter, other: PNCounter) {
    gc_merge(c.p, other.p);
    gc_merge(c.n, other.n);
}

// ---- OR-Set (ORSWOT): add wins over a concurrent remove ------------------------

// Each element carries the dots ("node:n") of the adds that are still
// live; clock holds the highest n seen from each node. A dot the clock has
// seen but the element lacks was removed.
pub gc struct ORSet {
    entries: map[str][str],
    clock: map[str]int,
}

pub fn orset() -> ORSet {
    let e: map[str][str] = {};
    let k: map[str]int = {};
    return ORSet { entries: e, clock: k };
}

pub fn set_add(s: ORSet, node: str, elem: str) {
    let n = 1;
    if has(s.clock, node) { n = s.clock[node] + 1; }
    s.clock[node] = n;
    // the new dot replaces this node's earlier ones for the element: it
    // covers them
    s.entries[elem] = [node + ":" + to_str(n)];
}

// Removes elem as this replica sees it; an add elsewhere that this
// replica has not seen survives the merge (add wins).
pub fn set_remove(s: ORSet, elem: str) {
    if has(s.entries, elem) { del(s.entries, elem); }
}

pub fn set_has(s: ORSet, elem: str) -> bool {
    return has(s.entries, elem);
}

// The elements, sorted.
pub fn set_items(s: ORSet) -> [str] {
    let out: [str] = [];
    for k, _v in s.entries { push(out, k); }
    sort_strs(out);
    return out;
}

pub fn set_merge(s: ORSet, other: ORSet) {
    let merged: map[str][str] = {};
    // elements on this side: keep a dot if the other side has it too, or
    // has not yet seen it (it was added here after the other last heard)
    for elem, dots in s.entries {
        let keep: [str] = [];
        let theirs: [str] = [];
        if has(other.entries, elem) { theirs = other.entries[elem]; }
        for d in dots {
            if contains(theirs, d) || !seen(other.clock, d) { push(keep, d); }
        }
        // and dots only the other side has that this side has not seen
        for d in theirs {
            if !contains(dots, d) && !seen(s.clock, d) { push(keep, d); }
        }
        if len(keep) > 0 { merged[elem] = keep; }
    }
    for elem, dots in other.entries {
        if has(s.entries, elem) { continue; }
        let keep: [str] = [];
        for d in dots {
            if !seen(s.clock, d) { push(keep, d); }
        }
        if len(keep) > 0 { merged[elem] = keep; }
    }
    s.entries = merged;
    for node, n in other.clock {
        if !has(s.clock, node) || s.clock[node] < n { s.clock[node] = n; }
    }
}

fn seen(clock: map[str]int, dot: str) -> bool {
    let c = rfind_colon(dot);
    let node = slice_str(dot, 0, c);
    let n = to_int(slice_str(dot, c + 1, len(dot))) ?? 0;
    return has(clock, node) && clock[node] >= n;
}

// ---- LWW-Map: last writer wins per key -------------------------------------

// A value with the time it was written and by whom. A delete is a
// tombstone, so a merge cannot bring the value back.
pub struct Entry {
    value: str,
    ts: int,
    node: str,
    deleted: bool,
}

pub gc struct LWWMap {
    entries: map[str]Entry,
}

pub fn lwwmap() -> LWWMap {
    let m: map[str]Entry = {};
    return LWWMap { entries: m };
}

// Sets key at time ts (any clock that only moves forward on each node,
// such as time.wall()); ties go to the larger node id, so every replica
// picks the same winner.
pub fn map_set(m: LWWMap, node: str, key: str, value: str, ts: int) {
    put(m, key, Entry { value: value, ts: ts, node: node, deleted: false });
}

pub fn map_delete(m: LWWMap, node: str, key: str, ts: int) {
    put(m, key, Entry { value: "", ts: ts, node: node, deleted: true });
}

pub fn map_get(m: LWWMap, key: str) -> opt[str] {
    if !has(m.entries, key) { return none; }
    let e = m.entries[key];
    if e.deleted { return none; }
    return some(e.value);
}

// The live keys, sorted.
pub fn map_keys(m: LWWMap) -> [str] {
    let out: [str] = [];
    for k, e in m.entries {
        if !e.deleted { push(out, k); }
    }
    sort_strs(out);
    return out;
}

pub fn map_merge(m: LWWMap, other: LWWMap) {
    for k, e in other.entries { put(m, k, e); }
}

// Drops tombstones older than before_ts, once every replica has merged
// past it (a caller's knowledge: merging an older replica afterwards
// could bring a deleted value back).
pub fn map_compact(m: LWWMap, before_ts: int) {
    let drop: [str] = [];
    for k, e in m.entries {
        if e.deleted && e.ts < before_ts { push(drop, k); }
    }
    for k in drop { del(m.entries, k); }
}

fn put(m: LWWMap, key: str, e: Entry) {
    if has(m.entries, key) {
        let cur = m.entries[key];
        if cur.ts > e.ts || (cur.ts == e.ts && cur.node >= e.node) { return; }
    }
    m.entries[key] = e;
}

// ---- helpers -----------------------------------------------------------------

fn contains(xs: [str], x: str) -> bool {
    for y in xs { if y == x { return true; } }
    return false;
}

fn rfind_colon(s: str) -> int {
    let b = to_bytes(s);
    let i = len(b) - 1;
    while i >= 0 {
        if (b[i] as int) == 58 { return i; }
        i = i - 1;
    }
    return -1;
}

fn slice_str(s: str, a: int, b: int) -> str {
    return to_str(to_bytes(s)[a..b]);
}

fn sort_strs(xs: [str]) {
    for i in 1..len(xs) {
        let x = xs[i];
        let j = i - 1;
        while j >= 0 && xs[j] > x {
            xs[j + 1] = xs[j];
            j = j - 1;
        }
        xs[j + 1] = x;
    }
}
