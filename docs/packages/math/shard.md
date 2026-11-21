# math/shard

> Package math/shard.

Map a key to one of n nodes so each node gets an even share and a change
in the node set moves as few keys as possible: sharding databases and
caches, partitioning queues, sticky load balancing.

```slang
import "math/shard";

shard.jump_str(user_id, 16);                 // bucket in [0, 16)

let r = shard.rendezvous(["db-a", "db-b", "db-c"]);
r.node(r.pick_str(user_id) ?? 0);            // the node's name
r.pick_n_str(user_id, 2);                    // primary and a replica

let ring = shard.ring(160);                  // 160 points per unit of weight
ring.add("cache-1", 1);
ring.add("cache-2", 2);                      // twice the keys
ring.get_str(key) ?? "";

let m = shard.maglev(["lb-1", "lb-2", "lb-3"], 65537);
m.pick_str(flow_id);                         // O(1): one table read
```

| Scheme | Lookup | Memory | Remove any node | Weights | Use for |
|---|---|---|---|---|---|
| `jump` (Lamping and Veach) | O(log n) | none | only the last | no | a growing count of shards |
| `rendezvous` (HRW) | O(nodes) | names | yes, only its keys move | yes | up to a few hundred nodes, replicas |
| `ring` (Karger) | O(log points) | 16 B per point | yes | yes | many nodes |
| `maglev` (Google) | O(1) | 4 B per entry | rebuild; little extra movement | no | load balancers |

Every scheme hashes with a fixed function (`shard.hash_str`,
`hash_int`), so every process and host maps a key to the same node.
Rendezvous weights follow Schindelhauer and Schomaker (`-w / ln(u)`), so
a node gets keys in proportion to its weight; a ring's markers depend
only on the node's name, so they are the same after every rebuild.

## API

### `fn hash_str(s: str) -> u64`

A 64-bit hash of a str: strings.hash widened and remixed.

### `fn hash_int(x: int) -> u64`

A 64-bit hash of an int.

### `fn jump(key: u64, buckets: int) -> int`

The bucket in [0, buckets) for a 64-bit key (Lamping and Veach 2014): each bucket gets 1/buckets of the keys, and going from n to n+1 buckets moves only the 1/(n+1) that the new bucket takes. O(log n), no memory. buckets below 1 count as 1.

### `fn jump_str(s: str, buckets: int) -> int`

jump() of a str key.

### `fn jump_int(x: int, buckets: int) -> int`

jump() of an int key.

### `gc struct Rendezvous`

Rendezvous hashing (Thaler and Ravishankar 1996): each node scores the key, and the highest score wins. A node leaving moves only its own keys, spread evenly over the rest. Weighted scores follow Schindelhauer and Schomaker: -weight / ln(u) for u the node's hash of the key in (0, 1), which gives each node keys in proportion to its weight.

### `fn rendezvous(nodes: [str]) -> Rendezvous`

Nodes of equal weight. Their order does not matter to the mapping; pick() returns an index into this list.

### `fn rendezvous_weighted(nodes: [str], weights: [float]) -> Rendezvous`

Nodes with weights (a weight at or below 0, or NaN, means the node gets nothing). A missing weight counts as 1.

### `fn pick(self: Rendezvous, key: u64) -> opt[int]`

The index of the node for this key hash; none when there are no nodes (or every weight is 0).

### `fn pick_n(self: Rendezvous, key: u64, n: int) -> [int]`

The indexes of the n highest-scoring nodes, best first: the primary and then its replicas, each a different node. Fewer when there are fewer nodes.

### `fn pick_str(self: Rendezvous, key: str) -> opt[int]`

### `fn pick_int(self: Rendezvous, key: int) -> opt[int]`

### `fn pick_n_str(self: Rendezvous, key: str, n: int) -> [int]`

### `fn node(self: Rendezvous, i: int) -> str`

The name of node i (as given).

### `fn size(self: Rendezvous) -> int`

### `gc struct Ring`

A consistent-hash ring (Karger et al. 1997) with virtual nodes: each node puts `points * weight` markers on a 64-bit circle, and a key belongs to the first marker clockwise from its hash. Adding or removing a node moves only the keys next to its markers.

### `fn ring(points_per_weight: int) -> Ring`

An empty ring putting `points_per_weight` markers per unit of weight (100 to 200 keeps the share of each node within a few percent).

### `fn add(self: Ring, name: str, weight: int) -> bool`

Adds a node (or changes its weight, 1 to 1000). False for an empty name.

### `fn remove(self: Ring, name: str) -> bool`

Removes a node; its keys move to the next markers. False when it was not on the ring.

### `fn get(self: Ring, key: u64) -> opt[str]`

The node for this key hash; none on an empty ring.

### `fn get_n(self: Ring, key: u64, n: int) -> [str]`

Up to n distinct nodes for this key hash, clockwise from it: a primary and its replicas.

### `fn get_str(self: Ring, key: str) -> opt[str]`

### `fn get_int(self: Ring, key: int) -> opt[str]`

### `fn get_n_str(self: Ring, key: str, n: int) -> [str]`

### `fn nodes(self: Ring) -> [str]`

Live nodes.

### `fn points(self: Ring) -> int`

Markers on the ring.

### `gc struct Maglev`

Maglev hashing (Eisenbud et al. 2016, Google's load balancer): a lookup table of `size` entries, a prime well above the node count (65537 is usual; 2039 for small sets), filled so each node owns an equal share. A lookup is one hash and one table read. Rebuild with a new node list; keys of nodes that stay mostly stay put.

### `fn maglev(nodes: [str], size: int) -> Maglev`

A table over `nodes` of `size` entries (raised to the next prime, at least 7 and at least the node count). Duplicate names share nothing: each entry is one slot. An empty list gives an empty table.

### `fn pick(self: Maglev, key: u64) -> opt[int]`

The index of the node for this key hash; none for an empty table.

### `fn pick_str(self: Maglev, key: str) -> opt[int]`

### `fn pick_int(self: Maglev, key: int) -> opt[int]`

### `fn node(self: Maglev, i: int) -> str`

### `fn size(self: Maglev) -> int`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
