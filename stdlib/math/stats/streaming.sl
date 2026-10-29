// Streaming statistics: one value at a time, in constant memory, for
// numbers that never all exist at once -- request latencies, queue depths,
// a feed's prices. Each accumulator merges with another of its kind, so
// tasks can accumulate on their own and combine at the end.

import "math";

// Count, mean, variance, min and max of a stream (Welford's algorithm):
// O(1) per value, numerically stable, no samples kept.
//
//     let r = stats.running();
//     r.add(12.5).add(9.0);
//     r.mean(); r.stddev(); r.max();
pub gc struct Running {
    n: int,
    mu: float,
    m2: float,     // sum of squared deviations from the running mean
    lo: float,
    hi: float,
}

pub fn running() -> Running {
    return Running { n: 0, mu: 0.0, m2: 0.0, lo: math.inf, hi: math.neg_inf };
}

impl Running {
    // Adds one value; returns the accumulator so adds chain.
    pub fn add(self: Running, x: float) -> Running {
        self.n += 1;
        let d = x - self.mu;
        self.mu += d / (self.n as float);
        self.m2 += d * (x - self.mu);
        if x < self.lo {
            self.lo = x;
        }
        if x > self.hi {
            self.hi = x;
        }
        return self;
    }

    // Folds another accumulator's values into this one (Chan et al.), as
    // if every value added to `other` had been added here.
    pub fn merge(self: Running, other: Running) -> Running {
        if other.n == 0 {
            return self;
        }
        if self.n == 0 {
            self.n = other.n;
            self.mu = other.mu;
            self.m2 = other.m2;
            self.lo = other.lo;
            self.hi = other.hi;
            return self;
        }
        let n = self.n + other.n;
        let d = other.mu - self.mu;
        let na = self.n as float;
        let nb = other.n as float;
        self.mu += d * nb / (n as float);
        self.m2 += other.m2 + d * d * na * nb / (n as float);
        self.n = n;
        self.lo = math.min(self.lo, other.lo);
        self.hi = math.max(self.hi, other.hi);
        return self;
    }

    pub fn count(self: Running) -> int {
        return self.n;
    }

    // NaN before the first value.
    pub fn mean(self: Running) -> float {
        if self.n == 0 {
            return math.nan;
        }
        return self.mu;
    }

    // mean * count.
    pub fn total(self: Running) -> float {
        return self.mu * (self.n as float);
    }

    // The sample variance; NaN before the second value.
    pub fn variance(self: Running) -> float {
        if self.n < 2 {
            return math.nan;
        }
        return self.m2 / ((self.n - 1) as float);
    }

    // The population variance; NaN before the first value.
    pub fn pvariance(self: Running) -> float {
        if self.n == 0 {
            return math.nan;
        }
        return self.m2 / (self.n as float);
    }

    pub fn stddev(self: Running) -> float {
        return math.sqrt(self.variance());
    }

    // NaN before the first value.
    pub fn min(self: Running) -> float {
        if self.n == 0 {
            return math.nan;
        }
        return self.lo;
    }

    // NaN before the first value.
    pub fn max(self: Running) -> float {
        if self.n == 0 {
            return math.nan;
        }
        return self.hi;
    }
}

// An exponentially weighted moving average: each value moves the average
// a fraction `alpha` of the way toward it, so recent values count most
// and old ones fade. The first value is taken as is.
pub gc struct Ewma {
    alpha: float,
    v: float,
    seen: bool,
}

// alpha in (0, 1]: 0.1 forgets slowly, 0.5 quickly. Clamped into range.
pub fn ewma(alpha: float) -> Ewma {
    return Ewma { alpha: math.clamp(alpha, 0.000001, 1.0), v: math.nan, seen: false };
}

// The average whose weight halves every `n` values: an alpha of
// 1 - 0.5^(1/n), for a decay stated in samples rather than as a fraction.
pub fn ewma_half_life(n: float) -> Ewma {
    return ewma(1.0 - math.pow(0.5, 1.0 / math.max(n, 1.0)));
}

impl Ewma {
    pub fn add(self: Ewma, x: float) -> Ewma {
        if !self.seen {
            self.v = x;
            self.seen = true;
        } else {
            self.v += self.alpha * (x - self.v);
        }
        return self;
    }

    // NaN before the first value.
    pub fn value(self: Ewma) -> float {
        return self.v;
    }
}

// Streaming quantiles: a merging t-digest (Dunning and Ertl, 2019). The
// stream is summarized as at most about `compression` weighted centroids,
// small near the extremes and large in the middle, so p99 and p999 stay
// accurate (to well under 1% of rank at the default 100) where a
// fixed-width histogram would need to know the range up front. Digests
// merge, so each worker can keep its own.
//
//     let d = stats.digest();
//     d.add(latency_ms);
//     d.quantile(0.5); d.quantile(0.99);
pub gc struct Digest {
    compression: float,
    means: [float],      // centroids, ascending by mean
    weights: [float],
    buf: [float],        // values added since the last compress
    buf_w: [float],
    total: float,        // weight of everything, merged or buffered
    lo: float,
    hi: float,
}

// A digest at the default compression, 100.
pub fn digest() -> Digest {
    return digest_with(100.0);
}

// A digest keeping about `compression` centroids: more is more accurate
// and larger (the memory is about 16 bytes a centroid). At least 20.
pub fn digest_with(compression: float) -> Digest {
    let m: [float] = [];
    let w: [float] = [];
    let b: [float] = [];
    let bw: [float] = [];
    return Digest {
        compression: math.max(compression, 20.0),
        means: m,
        weights: w,
        buf: b,
        buf_w: bw,
        total: 0.0,
        lo: math.inf,
        hi: math.neg_inf
    };
}

impl Digest {
    // Adds one value. NaN is ignored: it has no rank.
    pub fn add(self: Digest, x: float) -> Digest {
        return self.add_weighted(x, 1.0);
    }

    // Adds a value standing for `w` observations (w > 0).
    pub fn add_weighted(self: Digest, x: float, w: float) -> Digest {
        if math.is_nan(x) || !(w > 0.0) {
            return self;
        }
        push(self.buf, x);
        push(self.buf_w, w);
        self.total += w;
        if x < self.lo {
            self.lo = x;
        }
        if x > self.hi {
            self.hi = x;
        }
        if (len(self.buf) as float) >= self.compression * 5.0 {
            self.compress();
        }
        return self;
    }

    // Folds another digest into this one, as if its values had been added
    // here (other is not changed).
    pub fn merge(self: Digest, other: Digest) -> Digest {
        for i in 0..len(other.means) {
            self.add_weighted(other.means[i], other.weights[i]);
        }
        for i in 0..len(other.buf) {
            self.add_weighted(other.buf[i], other.buf_w[i]);
        }
        return self;
    }

    // The number of observations, as the sum of their weights.
    pub fn count(self: Digest) -> float {
        return self.total;
    }

    // NaN when empty.
    pub fn min(self: Digest) -> float {
        if self.total == 0.0 {
            return math.nan;
        }
        return self.lo;
    }

    // NaN when empty.
    pub fn max(self: Digest) -> float {
        if self.total == 0.0 {
            return math.nan;
        }
        return self.hi;
    }

    // The estimated q-quantile, q in [0, 1]: min at 0, max at 1, linear
    // between centroid centers. NaN when empty or q is outside [0, 1].
    pub fn quantile(self: Digest, q: float) -> float {
        self.compress();
        let n = len(self.means);
        if n == 0 || !(q >= 0.0 && q <= 1.0) {
            return math.nan;
        }
        if q == 0.0 {
            return self.lo;
        }
        if q == 1.0 {
            return self.hi;
        }
        if n == 1 {
            return math.lerp(self.lo, self.hi, q);
        }
        let t = q * self.total;
        let cum = 0.0;
        for i in 0..n {
            let w = self.weights[i];
            let center = cum + w / 2.0;
            if t < center {
                if i == 0 {
                    return math.lerp(self.lo, self.means[0], t / center);
                }
                let prev = cum - self.weights[i - 1] / 2.0;
                return math.lerp(self.means[i - 1], self.means[i], (t - prev) / (center - prev));
            }
            cum += w;
        }
        let last = self.total - self.weights[n - 1] / 2.0;
        return math.lerp(self.means[n - 1], self.hi, (t - last) / (self.total - last));
    }

    // The estimated fraction of observations at or below x, in [0, 1];
    // NaN when empty.
    pub fn cdf(self: Digest, x: float) -> float {
        self.compress();
        let n = len(self.means);
        if n == 0 {
            return math.nan;
        }
        if x < self.lo {
            return 0.0;
        }
        if x >= self.hi {
            return 1.0;
        }
        let cum = 0.0;
        let prev_mean = self.lo;
        let prev_rank = 0.0;
        for i in 0..n {
            let w = self.weights[i];
            let center = cum + w / 2.0;
            if x < self.means[i] {
                let span = self.means[i] - prev_mean;
                let f = 0.0;
                if span > 0.0 {
                    f = (x - prev_mean) / span;
                }
                return math.lerp(prev_rank, center, f) / self.total;
            }
            prev_mean = self.means[i];
            prev_rank = center;
            cum += w;
        }
        let span = self.hi - prev_mean;
        let f = 1.0;
        if span > 0.0 {
            f = (x - prev_mean) / span;
        }
        return math.lerp(prev_rank, self.total, f) / self.total;
    }

    // Merges the buffer into the centroids. Every centroid but the first
    // and last stays within one unit of the k1 scale function, k(q) =
    // compression / (2 pi) * asin(2q - 1), which is what keeps them small
    // at the tails.
    fn compress(self: Digest) {
        if len(self.buf) == 0 {
            return;
        }
        let ms: [float] = [];
        let ws: [float] = [];
        for i in 0..len(self.means) {
            push(ms, self.means[i]);
            push(ws, self.weights[i]);
        }
        for i in 0..len(self.buf) {
            push(ms, self.buf[i]);
            push(ws, self.buf_w[i]);
        }
        let order = argsort(ms);
        let out_m: [float] = [];
        let out_w: [float] = [];
        let total = self.total;
        let so_far = 0.0;
        let cur_m = ms[order[0]];
        let cur_w = ws[order[0]];
        let limit = total * self.k_inv(self.k(0.0) + 1.0);
        for j in 1..len(order) {
            let m = ms[order[j]];
            let w = ws[order[j]];
            if so_far + cur_w + w <= limit {
                cur_w += w;
                cur_m += (m - cur_m) * w / cur_w;
            } else {
                push(out_m, cur_m);
                push(out_w, cur_w);
                so_far += cur_w;
                limit = total * self.k_inv(self.k(so_far / total) + 1.0);
                cur_m = m;
                cur_w = w;
            }
        }
        push(out_m, cur_m);
        push(out_w, cur_w);
        self.means = out_m;
        self.weights = out_w;
        let b: [float] = [];
        let bw: [float] = [];
        self.buf = b;
        self.buf_w = bw;
    }

    fn k(self: Digest, q: float) -> float {
        return self.compression / math.tau * math.asin(2.0 * math.clamp(q, 0.0, 1.0) - 1.0);
    }

    fn k_inv(self: Digest, k: float) -> float {
        let x = k * math.tau / self.compression;
        if x >= math.pi / 2.0 {
            return 1.0;
        }
        return (math.sin(x) + 1.0) / 2.0;
    }
}
