import "math";

// Latency (or any non-negative int) percentiles in fixed memory, to a
// stated relative precision, merging exactly: the log-linear bucketing of
// HdrHistogram. Values below 2^precision are counted exactly; above that,
// each power of two is split into 2^(precision-1) equal buckets, so a
// reported quantile is within 2^-precision of the true one (precision 7:
// 0.8%). histogram(60000000, 7) covers 1 us to 60 s in 1,344 counters,
// 10.5 KB, however many values are recorded.
//
//     let h = sketch.histogram(60000000, 7);
//     h.record(elapsed_us);
//     h.quantile(0.99); h.mean(); h.max();
//     h.buckets([1000, 5000, 25000, 100000]);   // Prometheus le= counts
pub gc struct Histogram {
    sub: int,          // precision: sub-bucket bits
    top: int,          // the largest value with its own bucket
    counts: [int],
    n: int,
    over: int,         // values above `top`, counted in the last bucket
    total: float,      // the exact sum, as a float
    lo: int,
    hi: int,
}

// A histogram for values in [0, max] at the given precision in bits
// (clamped to [1, 16]; max is at least 1 and at most 2^62). Larger values
// are counted in the top bucket, and min, max and mean stay exact.
pub fn histogram(max: int, precision: int) -> Histogram {
    let s = math.clamp(precision, 1, 16);
    let top = math.clamp(max, 1, 4611686018427387904);
    let h = Histogram {
        sub: s, top: top, counts: [], n: 0, over: 0, total: 0.0,
        lo: 0, hi: 0
    };
    for i in 0..h.index_of(top) + 1 {
        push(h.counts, 0);
    }
    return h;
}

impl Histogram {
    // Records one value. A negative value counts as 0.
    pub fn record(self: Histogram, v: int) -> Histogram {
        return self.record_n(v, 1);
    }

    // Records `n` (ignored unless positive) occurrences of v.
    pub fn record_n(self: Histogram, value: int, n: int) -> Histogram {
        if n <= 0 {
            return self;
        }
        let v = value;
        if v < 0 {
            v = 0;
        }
        if self.n == 0 || v < self.lo {
            self.lo = v;
        }
        if self.n == 0 || v > self.hi {
            self.hi = v;
        }
        self.n += n;
        self.total += (v as float) * (n as float);
        let at = v;
        if at > self.top {
            at = self.top;
            self.over += n;
        }
        self.counts[self.index_of(at)] += n;
        return self;
    }

    // The value at quantile q in [0, 1] (nearest rank: the smallest
    // recorded value with at least q of the values at or below it),
    // reported as its bucket's midpoint and clamped to [min, max]. 0
    // before the first value.
    pub fn quantile(self: Histogram, q: float) -> int {
        if self.n == 0 {
            return 0;
        }
        if !(q > 0.0) {
            return self.lo;
        }
        if q >= 1.0 {
            return self.hi;
        }
        let rank = math.ceil_int(q * (self.n as float)) ?? 1;
        if rank < 1 {
            rank = 1;
        }
        let seen = 0;
        for i in 0..len(self.counts) {
            seen += self.counts[i];
            if seen >= rank {
                let mid = self.lower_of(i) + (self.width_of(i) - 1) / 2;
                return math.clamp(mid, self.lo, self.hi);
            }
        }
        return self.hi;
    }

    // The share of values at or below v, 0 to 1 (to bucket precision).
    pub fn rank_of(self: Histogram, v: int) -> float {
        if self.n == 0 {
            return 0.0;
        }
        if v >= self.hi {
            return 1.0;
        }
        if v < self.lo {
            return 0.0;
        }
        let last = self.index_of(math.clamp(v, 0, self.top));
        let seen = 0;
        for i in 0..last + 1 {
            seen += self.counts[i];
        }
        return (seen as float) / (self.n as float);
    }

    // Cumulative counts at each upper bound (ascending), the shape of a
    // Prometheus histogram's `le` buckets: element i counts the values at
    // or below bounds[i], to bucket precision. The +Inf bucket is count().
    pub fn buckets(self: Histogram, bounds: [int]) -> [int] {
        let out: [int] = [];
        let seen = 0;
        let i = 0;
        for b in bounds {
            let last = -1;
            if b >= 0 {
                last = self.index_of(math.clamp(b, 0, self.top));
            }
            while i <= last {
                seen += self.counts[i];
                i += 1;
            }
            push(out, seen);
        }
        return out;
    }

    pub fn count(self: Histogram) -> int {
        return self.n;
    }

    // The exact sum of recorded values (as a float, so it cannot wrap).
    pub fn sum(self: Histogram) -> float {
        return self.total;
    }

    // The exact mean; NaN before the first value.
    pub fn mean(self: Histogram) -> float {
        if self.n == 0 {
            return math.nan;
        }
        return self.total / (self.n as float);
    }

    // The exact smallest value; 0 before the first.
    pub fn min(self: Histogram) -> int {
        return self.lo;
    }

    // The exact largest value; 0 before the first.
    pub fn max(self: Histogram) -> int {
        return self.hi;
    }

    // Values recorded above the range given at creation.
    pub fn overflow(self: Histogram) -> int {
        return self.over;
    }

    // Adds `other`'s counts to this one's, exactly. False, and no change,
    // when the range or precision differ.
    pub fn merge(self: Histogram, other: Histogram) -> bool {
        if other.sub != self.sub || other.top != self.top {
            return false;
        }
        if other.n == 0 {
            return true;
        }
        for i in 0..len(self.counts) {
            self.counts[i] += other.counts[i];
        }
        if self.n == 0 || other.lo < self.lo {
            self.lo = other.lo;
        }
        if self.n == 0 || other.hi > self.hi {
            self.hi = other.hi;
        }
        self.n += other.n;
        self.over += other.over;
        self.total += other.total;
        return true;
    }

    // Empties the histogram, keeping its memory.
    pub fn clear(self: Histogram) {
        for i in 0..len(self.counts) {
            self.counts[i] = 0;
        }
        self.n = 0;
        self.over = 0;
        self.total = 0.0;
        self.lo = 0;
        self.hi = 0;
    }

    // The bucket of v in [0, top]: v itself below 2^sub; above, the
    // power of two (e) and the top sub bits under it.
    fn index_of(self: Histogram, v: int) -> int {
        let s = self.sub;
        if v < (1 << s) {
            return v;
        }
        let e = math.bit_len(v) - s;
        let half = 1 << (s - 1);
        return (1 << s) + (e - 1) * half + ((v >> e) - half);
    }

    // The smallest value in bucket i.
    fn lower_of(self: Histogram, i: int) -> int {
        let s = self.sub;
        if i < (1 << s) {
            return i;
        }
        let half = 1 << (s - 1);
        let e = (i - (1 << s)) / half + 1;
        let m = (i - (1 << s)) % half + half;
        return m << e;
    }

    // How many values bucket i spans.
    fn width_of(self: Histogram, i: int) -> int {
        let s = self.sub;
        if i < (1 << s) {
            return 1;
        }
        let half = 1 << (s - 1);
        return 1 << ((i - (1 << s)) / half + 1);
    }
}

// Upper bounds start, start*factor, start*factor^2, ... (count of them),
// for buckets(): Prometheus's ExponentialBuckets. Each is at least one
// above the last, so a small start with a small factor still ascends.
pub fn exponential_bounds(start: int, factor: float, count: int) -> [int] {
    let out: [int] = [];
    let v = math.max(start, 1) as float;
    let f = math.max(factor, 1.0);
    let last = -1;
    for i in 0..count {
        let b = math.round_int(v) ?? 4611686018427387904;
        if b <= last {
            b = last + 1;
        }
        push(out, b);
        last = b;
        v *= f;
    }
    return out;
}

// Upper bounds start, start+width, ... (count of them): LinearBuckets.
pub fn linear_bounds(start: int, width: int, count: int) -> [int] {
    let out: [int] = [];
    let w = math.max(width, 1);
    for i in 0..count {
        push(out, start + i * w);
    }
    return out;
}
