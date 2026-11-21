// Map a key to one of n nodes so that each node gets an even share and
// adding or removing a node moves as few keys as possible: for sharding
// databases and caches, partitioning a queue, sticky load balancing.
//
//     import "math/shard";
//
//     shard.jump_str(user_id, 16)              // bucket in [0, 16)
//
//     let r = shard.rendezvous(["db-a", "db-b", "db-c"]);
//     r.pick_str(user_id)                      // index of the node
//     r.pick_n_str(user_id, 2)                 // primary and replica
//
//     let ring = shard.ring(160);              // 160 points per weight unit
//     ring.add("cache-1", 1); ring.add("cache-2", 2);
//     ring.get_str(key) ?? ""                  // node name
//
//     let m = shard.maglev(["lb-1", "lb-2", "lb-3"], 65537);
//     m.pick_str(flow_id)                      // O(1): one table read
//
// Which to use:
//
// - jump: no memory and no setup, perfectly even, but buckets are numbered
//   0..n-1 and only the last one can be removed. For a fixed or growing
//   count of shards.
// - rendezvous: any node can leave and only its keys move; weights; the
//   top-n for replicas. O(nodes) per lookup: up to a few hundred nodes.
// - ring: any node can leave; weights; O(log points) per lookup, for many
//   nodes; less even than the others (more points, more even).
// - maglev: O(1) lookups and near-perfect balance, rebuilt when the set
//   changes, with minimal (not zero) extra movement. For load balancers.
//
// All of them hash with a fixed function, so every process maps a key the
// same way: a key hashes to the same node on every host and release.

import "math";
import "strings";

let SEED: u64 = 0x9e3779b97f4a7c15;

// MurmurHash3's finaliser (see math/sketch).
fn mix64(x: u64) -> u64 {
    let h = x ^ (x >> 33);
    h = h * 0xff51afd7ed558ccd;
    h = h ^ (h >> 33);
    h = h * 0xc4ceb9fe1a85ec53;
    return h ^ (h >> 33);
}

// A 64-bit hash of a str: strings.hash widened and remixed.
pub fn hash_str(s: str) -> u64 {
    return mix64((strings.hash(s) as u64) ^ SEED);
}

// A 64-bit hash of an int.
pub fn hash_int(x: int) -> u64 {
    return mix64((x as u64) + SEED);
}

// ---- jump consistent hash ---------------------------------------------

// The bucket in [0, buckets) for a 64-bit key (Lamping and Veach 2014):
// each bucket gets 1/buckets of the keys, and going from n to n+1 buckets
// moves only the 1/(n+1) that the new bucket takes. O(log n), no memory.
// buckets below 1 count as 1.
pub fn jump(key: u64, buckets: int) -> int {
    let n = math.max(buckets, 1);
    let k = key;
    let b = -1;
    let j = 0;
    while j < n {
        b = j;
        k = k * 2862933555777941757 + 1;
        j = (((b + 1) as float) * (2147483648.0 / (((k >> 33) + 1) as float))) as int;
    }
    return b;
}

// jump() of a str key.
pub fn jump_str(s: str, buckets: int) -> int {
    return jump(hash_str(s), buckets);
}

// jump() of an int key.
pub fn jump_int(x: int, buckets: int) -> int {
    return jump(hash_int(x), buckets);
}

// ---- rendezvous (highest random weight) -------------------------------

// Rendezvous hashing (Thaler and Ravishankar 1996): each node scores the
// key, and the highest score wins. A node leaving moves only its own keys,
// spread evenly over the rest. Weighted scores follow Schindelhauer and
// Schomaker: -weight / ln(u) for u the node's hash of the key in (0, 1),
// which gives each node keys in proportion to its weight.
pub gc struct Rendezvous {
    names: [str],
    seeds: [u64],
    weights: [float],
    weighted: bool,
}

// Nodes of equal weight. Their order does not matter to the mapping;
// pick() returns an index into this list.
pub fn rendezvous(nodes: [str]) -> Rendezvous {
    let ws: [float] = [];
    for i in 0..len(nodes) {
        push(ws, 1.0);
    }
    return rendezvous_weighted(nodes, ws);
}

// Nodes with weights (a weight at or below 0, or NaN, means the node gets
// nothing). A missing weight counts as 1.
pub fn rendezvous_weighted(nodes: [str], weights: [float]) -> Rendezvous {
    let names: [str] = [];
    let seeds: [u64] = [];
    let ws: [float] = [];
    let weighted = false;
    for i in 0..len(nodes) {
        push(names, nodes[i]);
        push(seeds, hash_str(nodes[i]));
        let w = 1.0;
        if i < len(weights) {
            w = weights[i];
        }
        if !(w > 0.0) {
            w = 0.0;
        }
        if w != 1.0 {
            weighted = true;
        }
        push(ws, w);
    }
    return Rendezvous { names: names, seeds: seeds, weights: ws, weighted: weighted };
}

impl Rendezvous {
    // The index of the node for this key hash; none when there are no
    // nodes (or every weight is 0).
    pub fn pick(self: Rendezvous, key: u64) -> opt[int] {
        let best = -1;
        let top = 0.0;
        let topu: u64 = 0;
        for i in 0..len(self.seeds) {
            let h = mix64(key ^ self.seeds[i]);
            if !self.weighted {
                if best < 0 || h > topu {
                    best = i;
                    topu = h;
                }
            } else {
                let s = score(h, self.weights[i]);
                if s > top {
                    best = i;
                    top = s;
                }
            }
        }
        if best < 0 {
            return none;
        }
        return some(best);
    }

    // The indexes of the n highest-scoring nodes, best first: the primary
    // and then its replicas, each a different node. Fewer when there are
    // fewer nodes.
    pub fn pick_n(self: Rendezvous, key: u64, n: int) -> [int] {
        let idx: [int] = [];
        let sc: [float] = [];
        for i in 0..len(self.seeds) {
            let h = mix64(key ^ self.seeds[i]);
            let s = 0.0;
            if self.weighted {
                s = score(h, self.weights[i]);
                if !(s > 0.0) {
                    continue;
                }
            } else {
                s = (h >> 11) as float;
            }
            // insertion into the running top n (n is small)
            push(idx, i);
            push(sc, s);
            let j = len(idx) - 1;
            while j > 0 && sc[j - 1] < sc[j] {
                let ti = idx[j];
                idx[j] = idx[j - 1];
                idx[j - 1] = ti;
                let ts = sc[j];
                sc[j] = sc[j - 1];
                sc[j - 1] = ts;
                j -= 1;
            }
            if len(idx) > n {
                pop(idx);
                pop(sc);
            }
        }
        return idx;
    }

    pub fn pick_str(self: Rendezvous, key: str) -> opt[int] {
        return self.pick(hash_str(key));
    }

    pub fn pick_int(self: Rendezvous, key: int) -> opt[int] {
        return self.pick(hash_int(key));
    }

    pub fn pick_n_str(self: Rendezvous, key: str, n: int) -> [int] {
        return self.pick_n(hash_str(key), n);
    }

    // The name of node i (as given).
    pub fn node(self: Rendezvous, i: int) -> str {
        return self.names[i];
    }

    pub fn size(self: Rendezvous) -> int {
        return len(self.names);
    }
}

// -w / ln(u) with u = h mapped into (0, 1): larger for larger weights.
fn score(h: u64, w: float) -> float {
    let u = ((h >> 11) as float + 0.5) * 1.1102230246251565e-16;
    return -w / math.log(u);
}

// ---- consistent-hash ring ---------------------------------------------

// A consistent-hash ring (Karger et al. 1997) with virtual nodes: each
// node puts `points * weight` markers on a 64-bit circle, and a key
// belongs to the first marker clockwise from its hash. Adding or removing
// a node moves only the keys next to its markers.
pub gc struct Ring {
    per: int,
    names: [str],      // live node names, by node id
    weights: [int],
    alive: [bool],
    hashes: [u64],     // markers, ascending
    owners: [int],     // node id of each marker
}

// An empty ring putting `points_per_weight` markers per unit of weight
// (100 to 200 keeps the share of each node within a few percent).
pub fn ring(points_per_weight: int) -> Ring {
    return Ring {
        per: math.clamp(points_per_weight, 1, 100000), names: [], weights: [],
        alive: [], hashes: [], owners: []
    };
}

impl Ring {
    // Adds a node (or changes its weight, 1 to 1000). False for an empty
    // name.
    pub fn add(self: Ring, name: str, weight: int) -> bool {
        if len(name) == 0 {
            return false;
        }
        let w = math.clamp(weight, 1, 1000);
        let id = self.id_of(name);
        if id >= 0 && self.alive[id] {
            if self.weights[id] == w {
                return true;
            }
            self.weights[id] = w;
            self.rebuild();
            return true;
        }
        if id < 0 {
            push(self.names, name);
            push(self.weights, w);
            push(self.alive, true);
        } else {
            self.weights[id] = w;
            self.alive[id] = true;
        }
        self.rebuild();
        return true;
    }

    // Removes a node; its keys move to the next markers. False when it
    // was not on the ring.
    pub fn remove(self: Ring, name: str) -> bool {
        let id = self.id_of(name);
        if id < 0 || !self.alive[id] {
            return false;
        }
        self.alive[id] = false;
        self.rebuild();
        return true;
    }

    // The node for this key hash; none on an empty ring.
    pub fn get(self: Ring, key: u64) -> opt[str] {
        let n = len(self.hashes);
        if n == 0 {
            return none;
        }
        return some(self.names[self.owners[self.first_at(key)]]);
    }

    // Up to n distinct nodes for this key hash, clockwise from it: a
    // primary and its replicas.
    pub fn get_n(self: Ring, key: u64, n: int) -> [str] {
        let out: [str] = [];
        let total = len(self.hashes);
        if total == 0 || n <= 0 {
            return out;
        }
        let ids: [int] = [];
        let at = self.first_at(key);
        for step in 0..total {
            let id = self.owners[(at + step) % total];
            let dup = false;
            for x in ids {
                if x == id {
                    dup = true;
                }
            }
            if !dup {
                push(ids, id);
                push(out, self.names[id]);
                if len(out) == n {
                    return out;
                }
            }
        }
        return out;
    }

    pub fn get_str(self: Ring, key: str) -> opt[str] {
        return self.get(hash_str(key));
    }

    pub fn get_int(self: Ring, key: int) -> opt[str] {
        return self.get(hash_int(key));
    }

    pub fn get_n_str(self: Ring, key: str, n: int) -> [str] {
        return self.get_n(hash_str(key), n);
    }

    // Live nodes.
    pub fn nodes(self: Ring) -> [str] {
        let out: [str] = [];
        for i in 0..len(self.names) {
            if self.alive[i] {
                push(out, self.names[i]);
            }
        }
        return out;
    }

    // Markers on the ring.
    pub fn points(self: Ring) -> int {
        return len(self.hashes);
    }

    // The index of the first marker at or after h, wrapping to 0.
    fn first_at(self: Ring, h: u64) -> int {
        let lo = 0;
        let hi = len(self.hashes);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.hashes[mid] < h {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if lo == len(self.hashes) {
            return 0;
        }
        return lo;
    }

    fn id_of(self: Ring, name: str) -> int {
        for i in 0..len(self.names) {
            if self.names[i] == name {
                return i;
            }
        }
        return -1;
    }

    // Markers are a pure function of (name, index), so a node's markers
    // are the same on every host and after every rebuild.
    fn rebuild(self: Ring) {
        let hs: [u64] = [];
        let os: [int] = [];
        for id in 0..len(self.names) {
            if !self.alive[id] {
                continue;
            }
            let base = hash_str(self.names[id]);
            for v in 0..self.per * self.weights[id] {
                push(hs, mix64(base + (v as u64) * SEED));
                push(os, id);
            }
        }
        // sort markers by hash, carrying owners: indexes sorted by key
        let order: [int] = [];
        for i in 0..len(hs) {
            push(order, i);
        }
        sort_by_u64(order, hs);
        let sh: [u64] = [];
        let so: [int] = [];
        for i in order {
            push(sh, hs[i]);
            push(so, os[i]);
        }
        self.hashes = sh;
        self.owners = so;
    }
}

// Sorts idx so that keys[idx[i]] ascends: heapsort, O(n log n), no
// allocation.
fn sort_by_u64(idx: [int], keys: [u64]) {
    let n = len(idx);
    let start = n / 2 - 1;
    while start >= 0 {
        sift(idx, keys, start, n);
        start -= 1;
    }
    let end = n - 1;
    while end > 0 {
        let t = idx[0];
        idx[0] = idx[end];
        idx[end] = t;
        sift(idx, keys, 0, end);
        end -= 1;
    }
}

fn sift(idx: [int], keys: [u64], at: int, n: int) {
    let root = at;
    while true {
        let child = 2 * root + 1;
        if child >= n {
            return;
        }
        if child + 1 < n && keys[idx[child]] < keys[idx[child + 1]] {
            child += 1;
        }
        if keys[idx[root]] >= keys[idx[child]] {
            return;
        }
        let t = idx[root];
        idx[root] = idx[child];
        idx[child] = t;
        root = child;
    }
}

// ---- Maglev -----------------------------------------------------------

// Maglev hashing (Eisenbud et al. 2016, Google's load balancer): a lookup
// table of `size` entries, a prime well above the node count (65537 is
// usual; 2039 for small sets), filled so each node owns an equal share.
// A lookup is one hash and one table read. Rebuild with a new node list;
// keys of nodes that stay mostly stay put.
pub gc struct Maglev {
    names: [str],
    table: [i32],
}

// A table over `nodes` of `size` entries (raised to the next prime, at
// least 7 and at least the node count). Duplicate names share nothing:
// each entry is one slot. An empty list gives an empty table.
pub fn maglev(nodes: [str], size: int) -> Maglev {
    let names: [str] = [];
    for n in nodes {
        push(names, n);
    }
    let m = next_prime(math.max(math.max(size, 7), len(names)));
    let table: [i32] = [];
    let nn = len(names);
    if nn == 0 {
        return Maglev { names: names, table: table };
    }
    for i in 0..m {
        push(table, -1);
    }
    let offset: [int] = [];
    let skip: [int] = [];
    let next: [int] = [];
    for i in 0..nn {
        let h = hash_str(names[i]);
        push(offset, ((h % (m as u64)) as int));
        push(skip, ((mix64(h ^ SEED) % ((m - 1) as u64)) as int) + 1);
        push(next, 0);
    }
    let filled = 0;
    while true {
        for i in 0..nn {
            // the next slot in node i's permutation that is still free
            let c = (offset[i] + next[i] * skip[i]) % m;
            while table[c] >= 0 {
                next[i] += 1;
                c = (offset[i] + next[i] * skip[i]) % m;
            }
            table[c] = i as i32;
            next[i] += 1;
            filled += 1;
            if filled == m {
                return Maglev { names: names, table: table };
            }
        }
    }
    return Maglev { names: names, table: table };
}

impl Maglev {
    // The index of the node for this key hash; none for an empty table.
    pub fn pick(self: Maglev, key: u64) -> opt[int] {
        let m = len(self.table);
        if m == 0 {
            return none;
        }
        return some(self.table[(key % (m as u64)) as int] as int);
    }

    pub fn pick_str(self: Maglev, key: str) -> opt[int] {
        return self.pick(hash_str(key));
    }

    pub fn pick_int(self: Maglev, key: int) -> opt[int] {
        return self.pick(hash_int(key));
    }

    pub fn node(self: Maglev, i: int) -> str {
        return self.names[i];
    }

    pub fn size(self: Maglev) -> int {
        return len(self.table);
    }
}

fn next_prime(n: int) -> int {
    let p = n;
    if p <= 2 {
        return 2;
    }
    if p % 2 == 0 {
        p += 1;
    }
    while !is_prime(p) {
        p += 2;
    }
    return p;
}

fn is_prime(n: int) -> bool {
    if n < 2 {
        return false;
    }
    if n % 2 == 0 {
        return n == 2;
    }
    let d = 3;
    while d * d <= n {
        if n % d == 0 {
            return false;
        }
        d += 2;
    }
    return true;
}
