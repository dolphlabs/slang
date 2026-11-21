# math/sketch

> Package math/sketch.

Fixed-memory, mergeable estimates for live servers: how many distinct
users, how often each key, which keys are heaviest, have we seen this
before, and latency percentiles, without keeping the items. Written in
slang; every sketch of a kind merges with another built with the same
parameters, so tasks and hosts each keep their own and combine.

```slang
import "math/sketch";

let users = sketch.hyperloglog(14);          // 16 KB, 0.81% error
users.add_str(user_id);
users.count();

let hits = sketch.count_min(0.001, 0.01);    // within 0.1% of the total, 99% of the time
hits.add_str(ip, 1);
hits.estimate_str(ip);

let heavy = sketch.top_k(100);               // Space-Saving
heavy.add(path);
heavy.top();                                 // [Item { key, count, error }]

let seen = sketch.bloom(1000000, 0.01);      // 1.2 MB
seen.add_str(key);
seen.contains_str(key);                      // false: certainly not added

let live = sketch.cuckoo(100000);            // like a Bloom filter, with remove
live.add_str(id); live.remove_str(id);

let lat = sketch.histogram(60000000, 7);     // 1 us .. 60 s, 0.8% precision
lat.record(elapsed_us);
lat.quantile(0.99);
lat.buckets(sketch.exponential_bounds(1000, 2.0, 12));   // Prometheus le= counts

let keep: [Event] = [];                      // a uniform sample of 100
let rs = sketch.reservoir(100, rand.new(7));
if let slot = rs.offer() {
    if slot == len(keep) { push(keep, e); } else { keep[slot] = e; }
}
```

- **`HyperLogLog`** (Flajolet et al. with Ertl's 2017 estimator, no bias
  tables): `add_str`/`add_int`/`add_bytes`/`add_hash`, `count`,
  `estimate`, `merge`, `encode`/`decode_hyperloglog`. Precision 4 to 18;
  the error is 1.04/sqrt(2^p).
- **`CountMin`** (Cormode and Muthukrishnan): never under the true count,
  at most epsilon * total over it with probability 1 - delta;
  `set_conservative(true)` tightens skewed data. `count_min_sized(w, d)`,
  `total`, `merge`, `clear`, `encode`/`decode_count_min`.
- **`TopK`** (Space-Saving, Metwally et al.): every key above total/k is
  kept; each count carries its maximum error. O(log k) per add; `merge`
  follows Agarwal et al.
- **`Bloom`**: the split-block layout Parquet and Impala use, one 32-byte
  block per key, so an add or a lookup touches one cache line. `fill`,
  `fpp` (the false-positive rate it has now), `merge`, `encode`.
- **`Cuckoo`** (Fan et al.): 16-bit fingerprints in buckets of four,
  0.012% false positives at 95% load, with `remove`. A fingerprint that
  finds no room is kept aside, so a full filter refuses new keys rather
  than losing an old one.
- **`Histogram`**: HdrHistogram's log-linear buckets: exact below
  2^precision, then 2^(precision-1) buckets per power of two. Exact
  `count`, `sum`, `mean`, `min`, `max`; `quantile`, `rank_of`, `buckets`,
  `merge`; `exponential_bounds` and `linear_bounds` for Prometheus.
- **`Reservoir`** (Algorithm L, Li 1994): the sample is your own list of
  any type; most items cost a counter increment and no random draw.

Keys hash with `hash_str` (over `strings.hash`), `hash_int` or
`hash_bytes`, or pass your own 64-bit hash to the `*_hash` methods. The
hashes are fixed across releases on little-endian CPUs, so `encode`d
sketches merge across hosts. None of the sketches locks: one per task,
then `merge`.

## API

### `gc struct Bloom`

"Have I seen this key?" in about 10 bits per key at 1% false positives, never a false negative. The split-block layout (Putze et al. 2007, as Parquet and Impala use it): each key sets one bit in each of the eight 32-bit words of a single 256-bit block, so an add or a lookup touches one cache line instead of seven scattered ones. Use it in front of a database or a cache to skip lookups that would miss, or to remember idempotency keys cheaply.

### `fn bloom(n: int, fpp: float) -> Bloom`

A filter sized for `n` keys at a false-positive rate of `fpp`: the bits Parquet's formula gives, -8n / ln(1 - fpp^(1/8)), in whole blocks. n is at least 1; fpp is clamped to [1e-6, 0.5]. bloom(1000000, 0.01) is 1.2 MB. Past `n` keys the rate climbs: size for the peak.

### `fn bloom_blocks(blocks: int) -> Bloom`

A filter of exactly `blocks` 32-byte blocks (clamped to [1, 2^27]).

### `fn decode_bloom(b: bytes) -> result[Bloom, str]`

A filter read back from encode().

### `fn add_hash(self: Bloom, h: u64) -> Bloom`

Adds the key with this hash. The high 32 bits pick the block, the low 32 the eight bits within it.

### `fn contains_hash(self: Bloom, h: u64) -> bool`

False means the key was certainly never added; true means it probably was.

### `fn add_str(self: Bloom, s: str) -> Bloom`

### `fn add_int(self: Bloom, x: int) -> Bloom`

### `fn add_bytes(self: Bloom, b: bytes) -> Bloom`

### `fn contains_str(self: Bloom, s: str) -> bool`

### `fn contains_int(self: Bloom, x: int) -> bool`

### `fn contains_bytes(self: Bloom, b: bytes) -> bool`

### `fn merge(self: Bloom, other: Bloom) -> bool`

Folds `other` in (bitwise OR): the filter of both key sets. False, and no change, when the sizes differ.

### `fn clear(self: Bloom)`

### `fn size_bytes(self: Bloom) -> int`

The memory the bits take.

### `fn fill(self: Bloom) -> float`

The share of bits set, 0 to 1: about 1 - e^(-8n/m) after n keys.

### `fn fpp(self: Bloom) -> float`

The false-positive rate the filter has now, estimated from its fill: a lookup is a false positive when all eight of its bits are set, about fill^8. Compare it with the rate it was sized for to tell when it has taken more keys than planned.

### `fn encode(self: Bloom) -> bytes`

9 + 32 * blocks bytes, little-endian.

### `gc struct CountMin`

How often each key occurred, in fixed memory (Cormode and Muthukrishnan 2005): `depth` rows of `width` counters, each key adding to one counter per row and reading the smallest. An estimate is never below the true count, and with probability 1 - delta is at most epsilon * total above it. For rate limiting, abuse detection, and finding heavy keys among millions without a map entry each.

### `fn count_min(epsilon: float, delta: float) -> CountMin`

A sketch whose estimates are within epsilon * total of the truth with probability 1 - delta: width e / epsilon (rounded up to a power of two), depth ln(1 / delta). count_min(0.001, 0.01) is 4096 x 5 counters, 160 KB. epsilon is clamped to [1e-7, 0.5], delta to [1e-9, 0.5].

### `fn count_min_sized(width: int, depth: int) -> CountMin`

A sketch of exactly `depth` rows (clamped to [1, 16]) of `width` counters (rounded up to a power of two, clamped to [2, 2^26]).

### `fn decode_count_min(b: bytes) -> result[CountMin, str]`

A sketch read back from encode().

### `fn set_conservative(self: CountMin, on: bool) -> CountMin`

Conservative update (Estan and Varghese): raise each of a key's counters only as far as its new estimate. Estimates stay upper bounds and get much tighter on skewed data, at the price of merge being an upper bound too. Set it before the first add.

### `fn add_hash(self: CountMin, h: u64, n: int) -> CountMin`

Adds n (ignored unless positive) to the key with this hash.

### `fn estimate_hash(self: CountMin, h: u64) -> int`

An upper bound on the key's total, usually exact for heavy keys.

### `fn add_str(self: CountMin, s: str, n: int) -> CountMin`

### `fn add_int(self: CountMin, x: int, n: int) -> CountMin`

### `fn add_bytes(self: CountMin, b: bytes, n: int) -> CountMin`

### `fn estimate_str(self: CountMin, s: str) -> int`

### `fn estimate_int(self: CountMin, x: int) -> int`

### `fn estimate_bytes(self: CountMin, b: bytes) -> int`

### `fn total(self: CountMin) -> int`

The sum of every n added.

### `fn width(self: CountMin) -> int`

### `fn depth(self: CountMin) -> int`

### `fn merge(self: CountMin, other: CountMin) -> bool`

Adds `other`'s counts to this sketch's. False, and no change, when the two differ in width or depth.

### `fn clear(self: CountMin)`

Zeroes every counter, keeping the memory. A rate limiter clears (or swaps in a fresh sketch) at each window boundary.

### `fn encode(self: CountMin) -> bytes`

19 + 8 * width * depth bytes, little-endian.

### `gc struct Cuckoo`

A set membership filter that can also delete (Fan et al. 2014): each key keeps a 16-bit fingerprint in one of two buckets of four slots. About 17 bits per key at 95% load with a 0.012% false-positive rate, and a lookup reads two cache lines at most. Unlike a Bloom filter it can remove a key, so it fits sets that change: active sessions, in-flight job ids, revoked tokens.  Remove only keys that were added: removing a key that never was can evict a different key sharing its fingerprint.

### `fn cuckoo(capacity: int) -> Cuckoo`

A filter with room for about `capacity` keys (at 95% load). At least one bucket; capacity is clamped to 2^30.

### `fn add_hash(self: Cuckoo, h: u64) -> bool`

Adds the key with this hash. False when the filter is full (the key is then not added and nothing else is lost).

### `fn contains_hash(self: Cuckoo, h: u64) -> bool`

False means the key is certainly not in the filter.

### `fn remove_hash(self: Cuckoo, h: u64) -> bool`

Removes one copy of the key. False when it was not found.

### `fn add_str(self: Cuckoo, s: str) -> bool`

### `fn add_int(self: Cuckoo, x: int) -> bool`

### `fn add_bytes(self: Cuckoo, b: bytes) -> bool`

### `fn contains_str(self: Cuckoo, s: str) -> bool`

### `fn contains_int(self: Cuckoo, x: int) -> bool`

### `fn contains_bytes(self: Cuckoo, b: bytes) -> bool`

### `fn remove_str(self: Cuckoo, s: str) -> bool`

### `fn remove_int(self: Cuckoo, x: int) -> bool`

### `fn remove_bytes(self: Cuckoo, b: bytes) -> bool`

### `fn count(self: Cuckoo) -> int`

Keys held.

### `fn load(self: Cuckoo) -> float`

Keys held over slots: past about 0.95 adds start to fail.

### `fn size_bytes(self: Cuckoo) -> int`

### `fn clear(self: Cuckoo)`

### `fn hash_int(x: int) -> u64`

A 64-bit hash of an int, every bit well mixed.

### `fn hash_str(s: str) -> u64`

A 64-bit hash of a str (strings.hash, widened and remixed to 64 bits).

### `fn hash_bytes(b: bytes) -> u64`

A 64-bit hash of bytes: FNV-1a over the bytes, then the finaliser.

### `gc struct Histogram`

Latency (or any non-negative int) percentiles in fixed memory, to a stated relative precision, merging exactly: the log-linear bucketing of HdrHistogram. Values below 2^precision are counted exactly; above that, each power of two is split into 2^(precision-1) equal buckets, so a reported quantile is within 2^-precision of the true one (precision 7: 0.8%). histogram(60000000, 7) covers 1 us to 60 s in 1,344 counters, 10.5 KB, however many values are recorded.  let h = sketch.histogram(60000000, 7); h.record(elapsed_us); h.quantile(0.99); h.mean(); h.max(); h.buckets([1000, 5000, 25000, 100000]);   // Prometheus le= counts

### `fn histogram(max: int, precision: int) -> Histogram`

A histogram for values in [0, max] at the given precision in bits (clamped to [1, 16]; max is at least 1 and at most 2^62). Larger values are counted in the top bucket, and min, max and mean stay exact.

### `fn record(self: Histogram, v: int) -> Histogram`

Records one value. A negative value counts as 0.

### `fn record_n(self: Histogram, value: int, n: int) -> Histogram`

Records `n` (ignored unless positive) occurrences of v.

### `fn quantile(self: Histogram, q: float) -> int`

The value at quantile q in [0, 1] (nearest rank: the smallest recorded value with at least q of the values at or below it), reported as its bucket's midpoint and clamped to [min, max]. 0 before the first value.

### `fn rank_of(self: Histogram, v: int) -> float`

The share of values at or below v, 0 to 1 (to bucket precision).

### `fn buckets(self: Histogram, bounds: [int]) -> [int]`

Cumulative counts at each upper bound (ascending), the shape of a Prometheus histogram's `le` buckets: element i counts the values at or below bounds[i], to bucket precision. The +Inf bucket is count().

### `fn count(self: Histogram) -> int`

### `fn sum(self: Histogram) -> float`

The exact sum of recorded values (as a float, so it cannot wrap).

### `fn mean(self: Histogram) -> float`

The exact mean; NaN before the first value.

### `fn min(self: Histogram) -> int`

The exact smallest value; 0 before the first.

### `fn max(self: Histogram) -> int`

The exact largest value; 0 before the first.

### `fn overflow(self: Histogram) -> int`

Values recorded above the range given at creation.

### `fn merge(self: Histogram, other: Histogram) -> bool`

Adds `other`'s counts to this one's, exactly. False, and no change, when the range or precision differ.

### `fn clear(self: Histogram)`

Empties the histogram, keeping its memory.

### `fn exponential_bounds(start: int, factor: float, count: int) -> [int]`

Upper bounds start, start*factor, start*factor^2, ... (count of them), for buckets(): Prometheus's ExponentialBuckets. Each is at least one above the last, so a small start with a small factor still ascends.

### `fn linear_bounds(start: int, width: int, count: int) -> [int]`

Upper bounds start, start+width, ... (count of them): LinearBuckets.

### `gc struct HyperLogLog`

Counts distinct items in fixed memory (Flajolet et al., with Ertl's 2017 estimator, which is unbiased from 0 to billions with no lookup tables). Precision p uses 2^p bytes and has a relative standard error of 1.04 / sqrt(2^p):  p = 10:  1 KB, 3.3%     p = 14: 16 KB, 0.81% p = 12:  4 KB, 1.6%     p = 16: 64 KB, 0.41%  Adding the same item twice changes nothing, and two sketches merge into the sketch of the union of their items.

### `fn hyperloglog(precision: int) -> HyperLogLog`

A sketch with 2^precision registers; precision is clamped to [4, 18].

### `fn decode_hyperloglog(b: bytes) -> result[HyperLogLog, str]`

A sketch read back from encode(). Refuses a wrong length, an unknown version or a register no sketch could hold.

### `fn add_hash(self: HyperLogLog, h: u64) -> HyperLogLog`

Adds an item by its 64-bit hash (hash_str, hash_int, hash_bytes, or any well-mixed hash). The top p bits pick a register; the rest give the rank.

### `fn add_str(self: HyperLogLog, s: str) -> HyperLogLog`

### `fn add_int(self: HyperLogLog, x: int) -> HyperLogLog`

### `fn add_bytes(self: HyperLogLog, b: bytes) -> HyperLogLog`

### `fn estimate(self: HyperLogLog) -> float`

The estimated number of distinct items, as a float.

### `fn count(self: HyperLogLog) -> int`

The estimate rounded to the nearest int.

### `fn precision(self: HyperLogLog) -> int`

### `fn merge(self: HyperLogLog, other: HyperLogLog) -> bool`

Folds `other` in, so this sketch counts the union of both. False, and no change, when the precisions differ.

### `fn clear(self: HyperLogLog)`

Empties the sketch, keeping its memory.

### `fn encode(self: HyperLogLog) -> bytes`

2 + 2^p bytes: a version byte, the precision, then the registers.

### `gc struct Reservoir`

A uniform random sample of k items from a stream of unknown length, in O(k) memory: every item seen so far is in the sample with the same probability. Algorithm L (Li 1994) skips ahead between replacements, so most items cost a counter increment and no random draw.  The sample is your own list, of any type: offer() says where the current item goes.  let keep: [Event] = []; let rs = sketch.reservoir(100, rand.new(7)); for e in events { if let slot = rs.offer() { if slot == len(keep) { push(keep, e); } else { keep[slot] = e; } } }

### `fn reservoir(k: int, r: rand.Rng) -> Reservoir`

A reservoir of k items (at least 1), drawing from r.

### `fn offer(self: Reservoir) -> opt[int]`

Counts one more item and says what to do with it: some(slot) to store it at keep[slot] (slot == len(keep) while the sample fills: push it), none to drop it.

### `fn seen(self: Reservoir) -> int`

Items offered so far.

### `fn size(self: Reservoir) -> int`

### `fn reset(self: Reservoir)`

Starts over for a new stream, keeping the generator.

### `struct Item`

One of the heaviest keys: `count` overestimates the key's true count by at most `error` (count - error is a guaranteed lower bound).

### `gc struct TopK`

The k heaviest keys of a stream in O(k) memory (Space-Saving, Metwally et al. 2005): every key whose true count is above total / k is in the list. A key not being tracked replaces the one with the smallest count and inherits that count as its possible error. O(log k) per add.  Each key lives in a fixed slot; the min-heap orders slot numbers, so a heap swap moves two ints and the key map is touched once or twice per add, never per swap.

### `fn top_k(k: int) -> TopK`

Tracks up to k keys (k at least 1).

### `fn add(self: TopK, key: str) -> TopK`

### `fn add_n(self: TopK, key: str, n: int) -> TopK`

Adds n (ignored unless positive) occurrences of key.

### `fn top(self: TopK) -> [Item]`

The tracked keys, heaviest first (ties by key).

### `fn count(self: TopK, key: str) -> opt[int]`

The estimated count of key, or none if it is not tracked (then its true count is at most the smallest tracked count).

### `fn total(self: TopK) -> int`

The total of every n added.

### `fn size(self: TopK) -> int`

### `fn merge(self: TopK, other: TopK)`

Combines `other` into this summary (Agarwal et al. 2012): a key's counts add, and a key one side does not track is credited with that side's smallest count when it is full, the most it could have had. The heaviest `k` of the combined keys are kept.

### `fn clear(self: TopK)`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
