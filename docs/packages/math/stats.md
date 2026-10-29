# math/stats

> Package math/stats.

Statistics over lists of any numeric type, and streaming accumulators
for numbers that never all exist at once. Written in slang over `math`.

```slang
import "math/stats";

let xs = [12.5, 9.0, 14.25, 11.0];
stats.mean(xs);                      // 11.6875
stats.median(xs);                    // 11.75
stats.stddev(xs);                    // sample (n - 1); pstddev is population
stats.quantile(xs, 0.9);             // R type 7 / NumPy's default
stats.correlation(xs, ys);           // Pearson's r; spearman for ranks
let fit = stats.linear_regression(xs, ys);   // fit.slope, fit.intercept, fit.r2, fit.at(x)
let h = stats.histogram(xs, 10);     // h.edges, h.counts

// Streaming, O(1) per value, mergeable across tasks:
let lat = stats.running();           // count, mean, variance, min, max
lat.add(elapsed_ms);
let p = stats.digest();              // quantiles of a stream (t-digest)
p.add(elapsed_ms);
p.quantile(0.99);

stats.normal(100.0, 15.0).cdf(130.0);        // 0.9772498680518208
stats.normal(0.0, 1.0).quantile(0.975);      // 1.9599639845400538
stats.poisson(3.0).pmf(5);
```

- **Center and spread:** `sum` (compensated), `product`, `mean`,
  `weighted_mean`, `geometric_mean`, `harmonic_mean`, `median`, `mode`,
  `min`, `max`, `spread`, `variance`/`pvariance`, `stddev`/`pstddev`,
  `mad`, `zscores`, `skewness`, `kurtosis` (excess).
- **Order:** `quantile`, `percentile`, `quartiles`, `iqr`, `ranks`;
  `sorted_floats` and `quantile_sorted` to sort once and ask many times.
- **Two lists:** `covariance`, `correlation`, `spearman`,
  `linear_regression`.
- **Streaming:** `running()` (Welford), `ewma(alpha)` and
  `ewma_half_life(n)`, `digest()` (a merging t-digest: p99 and p999 stay
  accurate in about 100 centroids). Each has `add`, and `running` and
  `digest` `merge`.
- **Distributions:** `normal`, `log_normal`, `uniform`, `exponential`
  (`pdf`, `cdf`, `quantile`), `poisson` and `binomial` (`pmf`, `cdf`).

A result with no value for its input -- the mean of no numbers, the
variance of one, a correlation with a constant list -- is NaN, which
propagates and tests true with `math.is_nan`; functions that return one
of the elements (`min`, `max`, `mode`) return an `opt` of the element
type. Sums are compensated (Neumaier) and variances are two-pass around
the mean, so neither drifts on long or offset data: `stats.sum([0.1,
0.2, 0.3])` is `0.6`.

## API

### `struct Normal`

### `fn normal(mu: float, sigma: float) -> Normal`

The normal (Gaussian) distribution with mean mu and stddev sigma.

### `fn pdf(self: Normal, x: float) -> float`

### `fn cdf(self: Normal, x: float) -> float`

Through erfc, which keeps precision far into the lower tail where 1 + erf would round to 0.

### `fn quantile(self: Normal, p: float) -> float`

The x with cdf(x) = p; -inf at 0, inf at 1, NaN outside [0, 1].

### `struct LogNormal`

### `fn log_normal(mu: float, sigma: float) -> LogNormal`

The distribution of exp(X) for X normal(mu, sigma): response times and sizes, which are positive and skewed right.

### `fn pdf(self: LogNormal, x: float) -> float`

### `fn cdf(self: LogNormal, x: float) -> float`

### `fn quantile(self: LogNormal, p: float) -> float`

### `struct Uniform`

### `fn uniform(lo: float, hi: float) -> Uniform`

The continuous uniform distribution on [lo, hi].

### `fn pdf(self: Uniform, x: float) -> float`

### `fn cdf(self: Uniform, x: float) -> float`

### `fn quantile(self: Uniform, p: float) -> float`

### `struct Exponential`

### `fn exponential(rate: float) -> Exponential`

The waiting time between events arriving at `rate` per unit time.

### `fn pdf(self: Exponential, x: float) -> float`

### `fn cdf(self: Exponential, x: float) -> float`

1 - exp(-rate x), through expm1 so a tiny x keeps its precision.

### `fn quantile(self: Exponential, p: float) -> float`

### `struct Poisson`

### `fn poisson(lambda: float) -> Poisson`

The number of events in an interval where `lambda` are expected.

### `fn pmf(self: Poisson, k: int) -> float`

P(X = k): directly while k! is exact (k <= 20) and lambda^k cannot overflow, otherwise in log space, where lgamma costs a few ulps.

### `fn cdf(self: Poisson, k: int) -> float`

P(X <= k).

### `struct Binomial`

### `fn binomial(n: int, p: float) -> Binomial`

The number of successes in n independent trials, each succeeding with probability p.

### `fn pmf(self: Binomial, k: int) -> float`

P(X = k): directly while the binomial coefficient is exact (n up to 1000, as math.binomial computes it), otherwise in log space.

### `fn cdf(self: Binomial, k: int) -> float`

P(X <= k).

### `fn sum[T](xs: [T]) -> float`

The sum of xs, compensated (Neumaier): the rounding error of each addition is carried and added back at the end. 0 for an empty list; an infinity or NaN in xs gives the plain sum's inf or NaN.

### `fn product[T](xs: [T]) -> float`

The product of xs; 1 for an empty list.

### `fn mean[T](xs: [T]) -> float`

The arithmetic mean; NaN for an empty list.

### `fn weighted_mean[T, W](xs: [T], ws: [W]) -> float`

The mean with weights ws (one per value); NaN when the lengths differ, the list is empty, or the weights sum to 0.

### `fn geometric_mean[T](xs: [T]) -> float`

The geometric mean, exp(mean(log x)): for growth rates and ratios. 0 if any value is 0; NaN for an empty list or a negative value.

### `fn harmonic_mean[T](xs: [T]) -> float`

The harmonic mean, n / sum(1/x): for averaging rates. 0 if any value is 0; NaN for an empty list or a negative value.

### `fn min[T](xs: [T]) -> opt[T]`

The smallest element; none for an empty list. NaN never compares smaller, so a float list's NaNs are passed over.

### `fn max[T](xs: [T]) -> opt[T]`

The largest element; none for an empty list. NaNs are passed over.

### `fn spread[T](xs: [T]) -> float`

max - min, as a float; NaN for an empty list.

### `fn sorted_floats[T](xs: [T]) -> [float]`

xs as floats, sorted ascending (NaN first, as sort.floats orders it): what median and quantile work on. Compute it once and use the _sorted variants when asking for several quantiles of one list.

### `fn median[T](xs: [T]) -> float`

The middle value, or the mean of the two middle values; NaN for an empty list. Copies and sorts: O(n log n).

### `fn quantile[T](xs: [T], q: float) -> float`

The q-quantile (q in [0, 1]) by linear interpolation between the two nearest ranks -- type 7 in Hyndman and Fan, the default of R, NumPy and Excel's PERCENTILE.INC. NaN for an empty list or q outside [0, 1].

### `fn quantile_sorted(s: [float], q: float) -> float`

quantile on a list already sorted ascending (sorted_floats), without copying it.

### `fn percentile[T](xs: [T], p: float) -> float`

quantile with p in percent: percentile(xs, 95) is quantile(xs, 0.95).

### `struct Quartiles`

### `fn quartiles[T](xs: [T]) -> Quartiles`

The three quartiles, by quantile's method.

### `fn iqr[T](xs: [T]) -> float`

The interquartile range, q3 - q1.

### `fn mode[T](xs: [T]) -> opt[T]`

The most frequent value, the smallest of them on a tie; none for an empty list. Floats compare exactly, so 0.1 + 0.2 and 0.3 are different values.

### `fn variance[T](xs: [T]) -> float`

The sample variance (divided by n - 1): the variance of the population the values were drawn from, estimated without bias. NaN for fewer than two values. pvariance is the variance of exactly these values.

### `fn pvariance[T](xs: [T]) -> float`

The population variance (divided by n); NaN for an empty list.

### `fn stddev[T](xs: [T]) -> float`

The sample standard deviation, sqrt(variance).

### `fn pstddev[T](xs: [T]) -> float`

The population standard deviation, sqrt(pvariance).

### `fn mad[T](xs: [T]) -> float`

The median absolute deviation, median(|x - median(xs)|): a spread that one wild value cannot move, unlike stddev. Unscaled; multiply by 1.4826 to estimate a normal distribution's stddev.

### `fn zscores[T](xs: [T]) -> [float]`

Each value's distance from the mean in population standard deviations (SciPy's zscore). All NaN when every value is the same.

### `fn skewness[T](xs: [T]) -> float`

The skewness, the population third standardized moment (Fisher-Pearson g1): 0 for a symmetric distribution, positive with a long right tail. NaN for an empty list or when every value is the same.

### `fn kurtosis[T](xs: [T]) -> float`

The excess kurtosis, m4 / m2^2 - 3: 0 for a normal distribution, positive for heavier tails. NaN for an empty list or constant values.

### `fn covariance[T, U](xs: [T], ys: [U]) -> float`

The sample covariance of xs and ys (divided by n - 1); NaN when the lengths differ or there are fewer than two pairs.

### `fn correlation[T, U](xs: [T], ys: [U]) -> float`

Pearson's correlation coefficient r, in [-1, 1]; NaN when the lengths differ, there are fewer than two pairs, or either list is constant.

### `fn spearman[T, U](xs: [T], ys: [U]) -> float`

Spearman's rank correlation: Pearson's r of the values' ranks, so any monotonic relationship scores 1, not just a straight line. Tied values share the mean of their ranks.

### `fn ranks[T](xs: [T]) -> [float]`

Each value's rank, 1 for the smallest; tied values share the mean of the ranks they span ([10, 20, 20, 30] ranks as [1, 2.5, 2.5, 4]).

### `struct Fit`

### `fn at(self: Fit, x: float) -> float`

The fitted line at x.

### `fn linear_regression[T, U](xs: [T], ys: [U]) -> Fit`

The least-squares line y = intercept + slope * x through the points. Every field is NaN when the lengths differ, there are fewer than two points, or every x is the same.

### `struct Histogram`

### `fn histogram[T](xs: [T], bins: int) -> Histogram`

Counts xs into `bins` equal-width bins over [min, max]; the last bin also holds max itself. NaNs are not counted. bins below 1 is taken as 1, and a list of one repeated value gets one bin of width 1 around it.

### `gc struct Running`

Count, mean, variance, min and max of a stream (Welford's algorithm): O(1) per value, numerically stable, no samples kept.  let r = stats.running(); r.add(12.5).add(9.0); r.mean(); r.stddev(); r.max();

### `fn running() -> Running`

### `fn add(self: Running, x: float) -> Running`

Adds one value; returns the accumulator so adds chain.

### `fn merge(self: Running, other: Running) -> Running`

Folds another accumulator's values into this one (Chan et al.), as if every value added to `other` had been added here.

### `fn count(self: Running) -> int`

### `fn mean(self: Running) -> float`

NaN before the first value.

### `fn total(self: Running) -> float`

mean * count.

### `fn variance(self: Running) -> float`

The sample variance; NaN before the second value.

### `fn pvariance(self: Running) -> float`

The population variance; NaN before the first value.

### `fn stddev(self: Running) -> float`

### `fn min(self: Running) -> float`

NaN before the first value.

### `fn max(self: Running) -> float`

NaN before the first value.

### `gc struct Ewma`

An exponentially weighted moving average: each value moves the average a fraction `alpha` of the way toward it, so recent values count most and old ones fade. The first value is taken as is.

### `fn ewma(alpha: float) -> Ewma`

alpha in (0, 1]: 0.1 forgets slowly, 0.5 quickly. Clamped into range.

### `fn ewma_half_life(n: float) -> Ewma`

The average whose weight halves every `n` values: an alpha of 1 - 0.5^(1/n), for a decay stated in samples rather than as a fraction.

### `fn add(self: Ewma, x: float) -> Ewma`

### `fn value(self: Ewma) -> float`

NaN before the first value.

### `gc struct Digest`

Streaming quantiles: a merging t-digest (Dunning and Ertl, 2019). The stream is summarized as at most about `compression` weighted centroids, small near the extremes and large in the middle, so p99 and p999 stay accurate (to well under 1% of rank at the default 100) where a fixed-width histogram would need to know the range up front. Digests merge, so each worker can keep its own.  let d = stats.digest(); d.add(latency_ms); d.quantile(0.5); d.quantile(0.99);

### `fn digest() -> Digest`

A digest at the default compression, 100.

### `fn digest_with(compression: float) -> Digest`

A digest keeping about `compression` centroids: more is more accurate and larger (the memory is about 16 bytes a centroid). At least 20.

### `fn add(self: Digest, x: float) -> Digest`

Adds one value. NaN is ignored: it has no rank.

### `fn add_weighted(self: Digest, x: float, w: float) -> Digest`

Adds a value standing for `w` observations (w > 0).

### `fn merge(self: Digest, other: Digest) -> Digest`

Folds another digest into this one, as if its values had been added here (other is not changed).

### `fn count(self: Digest) -> float`

The number of observations, as the sum of their weights.

### `fn min(self: Digest) -> float`

NaN when empty.

### `fn max(self: Digest) -> float`

NaN when empty.

### `fn quantile(self: Digest, q: float) -> float`

The estimated q-quantile, q in [0, 1]: min at 0, max at 1, linear between centroid centers. NaN when empty or q is outside [0, 1].

### `fn cdf(self: Digest, x: float) -> float`

The estimated fraction of observations at or below x, in [0, 1]; NaN when empty.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
