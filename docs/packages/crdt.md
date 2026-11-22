# crdt

> Package crdt.

Conflict-free replicated data types: state that replicas update on their
own and merge in any order, any number of times, and then agree on.
They suit counters, sets and maps shared between nodes without a
coordinator.

```slang
import "crdt";

let a = crdt.gcounter();
let b = crdt.gcounter();
crdt.gc_inc(a, "node-a", 3);
crdt.gc_inc(b, "node-b", 4);
crdt.gc_merge(a, b);
crdt.gc_value(a)            // 7, on whichever node merges both
```

- `gcounter` (grow-only) and `pncounter` (up and down).
- `orset`: a set where an add the remover had not seen survives the
  remove. It is the optimized OR-set, with no tombstones: its size follows
  the elements present plus one counter per node, however many adds and
  removes it has seen.
- `lwwmap`: last writer wins per key, by timestamp, with ties going to
  the larger node id so every replica picks the same winner. Deletes
  are tombstones; `map_compact` drops old ones once every replica is
  known to have merged past them.

Each node passes its own id with its updates. The state is plain data, so
`json.encode`/`json.decode` ship it.

## API

### `gc struct GCounter`

### `fn gcounter() -> GCounter`

### `fn gc_inc(c: GCounter, node: str, n: int)`

Adds n (n >= 0) to node's count.

### `fn gc_value(c: GCounter) -> int`

### `fn gc_merge(c: GCounter, other: GCounter)`

c takes in everything other has seen.

### `gc struct PNCounter`

### `fn pncounter() -> PNCounter`

### `fn pn_add(c: PNCounter, node: str, delta: int)`

### `fn pn_value(c: PNCounter) -> int`

### `fn pn_merge(c: PNCounter, other: PNCounter)`

### `gc struct ORSet`

Each element carries the dots ("node:n") of the adds that are still live; clock holds the highest n seen from each node. A dot the clock has seen but the element lacks was removed.

### `fn orset() -> ORSet`

### `fn set_add(s: ORSet, node: str, elem: str)`

### `fn set_remove(s: ORSet, elem: str)`

Removes elem as this replica sees it; an add elsewhere that this replica has not seen survives the merge (add wins).

### `fn set_has(s: ORSet, elem: str) -> bool`

### `fn set_items(s: ORSet) -> [str]`

The elements, sorted.

### `fn set_merge(s: ORSet, other: ORSet)`

### `struct Entry`

A value with the time it was written and by whom. A delete is a tombstone, so a merge cannot bring the value back.

### `gc struct LWWMap`

### `fn lwwmap() -> LWWMap`

### `fn map_set(m: LWWMap, node: str, key: str, value: str, ts: int)`

Sets key at time ts (any clock that only moves forward on each node, such as time.wall()); ties go to the larger node id, so every replica picks the same winner.

### `fn map_delete(m: LWWMap, node: str, key: str, ts: int)`

### `fn map_get(m: LWWMap, key: str) -> opt[str]`

### `fn map_keys(m: LWWMap) -> [str]`

The live keys, sorted.

### `fn map_merge(m: LWWMap, other: LWWMap)`

### `fn map_compact(m: LWWMap, before_ts: int)`

Drops tombstones older than before_ts, once every replica has merged past it (a caller's knowledge: merging an older replica afterwards could bring a deleted value back).

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
