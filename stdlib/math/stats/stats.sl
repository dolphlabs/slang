// Statistics over lists of numbers, and streaming accumulators for when
// the numbers never all exist at once.
//
//     import "math/stats";
//
//     let xs = [12.5, 9.0, 14.25, 11.0];
//     stats.mean(xs);                     // 11.6875
//     stats.median(xs);                   // 11.75
//     stats.stddev(xs);                   // sample standard deviation
//     stats.quantile(xs, 0.9);            // linear interpolation (R type 7)
//     stats.correlation(xs, ys);          // Pearson's r
//     let fit = stats.linear_regression(xs, ys);   // fit.slope, fit.intercept, fit.r2
//
//     let lat = stats.running();          // count, mean, variance, min, max
//     lat.add(elapsed_ms);                // O(1), no samples kept
//     let p = stats.digest();             // streaming quantiles (t-digest)
//     p.add(elapsed_ms);
//     p.quantile(0.99);
//
// Every list function takes a list of any numeric type ([int], [f32],
// [u8], [float]) and computes in float. A result that has no value for
// the input -- the mean of no numbers, the variance of one -- is NaN, which
// propagates through whatever is computed from it and tests true with
// math.is_nan. Functions that return one of the elements (min, max,
// mode) return an opt of the element type instead.
//
// Sums are compensated (Neumaier), so a mean over a million values is
// still exact to the last digit or two, where a plain loop drifts.
// Variance and the higher moments are two-pass, around the mean, which
// stays accurate where the textbook sum-of-squares formula cancels to
// nonsense (values near 1e9 with a spread of 1).

import "math";
import "sort";

// The sum of xs, compensated: the exact rounding error of each addition
// (Knuth's TwoSum) is carried and added back at the end. 0 for an empty
// list; an infinity or NaN in xs gives the plain sum's inf or NaN.
//
// Two independent running sums take alternate elements, so consecutive
// additions do not wait on each other: one chain held a sum to the
// latency of a float add per element, about half the speed of a plain
// loop. Every list function here sums the same way, in place -- they used
// to collect the terms in a list first and sum that, which for variance
// on a million values made the pushes 90% of the time.
//
// A `for x in xs` loop, not a `while` over indices: the for loop takes
// its safepoint once around the loop and reads elements unchecked, where a
// while loop brackets every iteration and bounds-checks every index --
// twice the time per element.
pub fn sum[T](xs: [T]) -> float {
    let s0 = 0.0;
    let c0 = 0.0;
    let s1 = 0.0;
    let c1 = 0.0;
    let odd = false;
    for x in xs {
        let v = x as float;
        if odd {
            let t1 = s1 + v;
            c1 += two_sum_err(s1, v, t1);
            s1 = t1;
        } else {
            let t0 = s0 + v;
            c0 += two_sum_err(s0, v, t0);
            s0 = t0;
        }
        odd = !odd;
    }
    let s = s0 + s1;
    if !math.is_finite(s) {
        return s;
    }
    return s + (c0 + c1 + two_sum_err(s0, s1, s));
}

// The product of xs; 1 for an empty list.
pub fn product[T](xs: [T]) -> float {
    let p = 1.0;
    for x in xs {
        p *= x as float;
    }
    return p;
}

// The arithmetic mean; NaN for an empty list.
pub fn mean[T](xs: [T]) -> float {
    if len(xs) == 0 {
        return math.nan;
    }
    return sum(xs) / (len(xs) as float);
}

// The mean with weights ws (one per value); NaN when the lengths differ,
// the list is empty, or the weights sum to 0.
pub fn weighted_mean[T, W](xs: [T], ws: [W]) -> float {
    if len(xs) != len(ws) || len(xs) == 0 {
        return math.nan;
    }
    let s = 0.0;
    let c = 0.0;
    for i in 0..len(xs) {
        let v = (xs[i] as float) * (ws[i] as float);
        let t = s + v;
        c += two_sum_err(s, v, t);
        s = t;
    }
    let wsum = sum(ws);
    if wsum == 0.0 {
        return math.nan;
    }
    return (s + c) / wsum;
}

// The geometric mean, exp(mean(log x)): for growth rates and ratios. 0 if
// any value is 0; NaN for an empty list or a negative value.
pub fn geometric_mean[T](xs: [T]) -> float {
    if len(xs) == 0 {
        return math.nan;
    }
    let s = 0.0;
    let c = 0.0;
    for x in xs {
        let v = x as float;
        if v < 0.0 {
            return math.nan;
        }
        if v == 0.0 {
            return 0.0;
        }
        let l = math.log(v);
        let t = s + l;
        c += two_sum_err(s, l, t);
        s = t;
    }
    return math.exp((s + c) / (len(xs) as float));
}

// The harmonic mean, n / sum(1/x): for averaging rates. 0 if any value is
// 0; NaN for an empty list or a negative value.
pub fn harmonic_mean[T](xs: [T]) -> float {
    if len(xs) == 0 {
        return math.nan;
    }
    let s = 0.0;
    let c = 0.0;
    for x in xs {
        let v = x as float;
        if v < 0.0 {
            return math.nan;
        }
        if v == 0.0 {
            return 0.0;
        }
        let r = 1.0 / v;
        let t = s + r;
        c += two_sum_err(s, r, t);
        s = t;
    }
    return (len(xs) as float) / (s + c);
}

// The smallest element; none for an empty list. NaN never compares
// smaller, so a float list's NaNs are passed over.
pub fn min[T](xs: [T]) -> opt[T] {
    if len(xs) == 0 {
        return none;
    }
    let m = xs[0];
    for x in xs {
        if x < m || math.is_nan(m) {
            m = x;
        }
    }
    return some(m);
}

// The largest element; none for an empty list. NaNs are passed over.
pub fn max[T](xs: [T]) -> opt[T] {
    if len(xs) == 0 {
        return none;
    }
    let m = xs[0];
    for x in xs {
        if x > m || math.is_nan(m) {
            m = x;
        }
    }
    return some(m);
}

// max - min, as a float; NaN for an empty list.
pub fn spread[T](xs: [T]) -> float {
    if len(xs) == 0 {
        return math.nan;
    }
    let lo = xs[0] as float;
    let hi = lo;
    for x in xs {
        let v = x as float;
        if v < lo {
            lo = v;
        }
        if v > hi {
            hi = v;
        }
    }
    return hi - lo;
}

// xs as floats, sorted ascending (NaN first, as sort.floats orders it):
// what median and quantile work on. Compute it once and use the _sorted
// variants when asking for several quantiles of one list.
pub fn sorted_floats[T](xs: [T]) -> [float] {
    let s: [float] = [];
    for x in xs {
        push(s, x as float);
    }
    sort.floats(s);
    return s;
}

// The middle value, or the mean of the two middle values; NaN for an
// empty list. Copies and sorts: O(n log n).
pub fn median[T](xs: [T]) -> float {
    return quantile_sorted(sorted_floats(xs), 0.5);
}

// The q-quantile (q in [0, 1]) by linear interpolation between the two
// nearest ranks -- type 7 in Hyndman and Fan, the default of R, NumPy and
// Excel's PERCENTILE.INC. NaN for an empty list or q outside [0, 1].
pub fn quantile[T](xs: [T], q: float) -> float {
    return quantile_sorted(sorted_floats(xs), q);
}

// quantile on a list already sorted ascending (sorted_floats), without
// copying it.
pub fn quantile_sorted(s: [float], q: float) -> float {
    let n = len(s);
    if n == 0 || !(q >= 0.0 && q <= 1.0) {
        return math.nan;
    }
    let h = ((n - 1) as float) * q;
    let lo = math.floor(h) as int;
    if lo >= n - 1 {
        return s[n - 1];
    }
    let frac = h - (lo as float);
    return s[lo] + frac * (s[lo + 1] - s[lo]);
}

// quantile with p in percent: percentile(xs, 95) is quantile(xs, 0.95).
pub fn percentile[T](xs: [T], p: float) -> float {
    return quantile(xs, p / 100.0);
}

pub struct Quartiles {
    q1: float,
    median: float,
    q3: float,
}

// The three quartiles, by quantile's method.
pub fn quartiles[T](xs: [T]) -> Quartiles {
    let s = sorted_floats(xs);
    return Quartiles {
        q1: quantile_sorted(s, 0.25),
        median: quantile_sorted(s, 0.5),
        q3: quantile_sorted(s, 0.75)
    };
}

// The interquartile range, q3 - q1.
pub fn iqr[T](xs: [T]) -> float {
    let q = quartiles(xs);
    return q.q3 - q.q1;
}

// The most frequent value, the smallest of them on a tie; none for an
// empty list. Floats compare exactly, so 0.1 + 0.2 and 0.3 are different
// values.
pub fn mode[T](xs: [T]) -> opt[T] {
    if len(xs) == 0 {
        return none;
    }
    let s = sorted_copy(xs);
    let best = s[0];
    let best_n = 0;
    let i = 0;
    while i < len(s) {
        let j = i;
        while j < len(s) && s[j] == s[i] {
            j += 1;
        }
        if j == i {
            j = i + 1; // a NaN equals nothing, itself included
        }
        if j - i > best_n {
            best = s[i];
            best_n = j - i;
        }
        i = j;
    }
    return some(best);
}

// The sample variance (divided by n - 1): the variance of the population
// the values were drawn from, estimated without bias. NaN for fewer than
// two values. pvariance is the variance of exactly these values.
pub fn variance[T](xs: [T]) -> float {
    let n = len(xs);
    if n < 2 {
        return math.nan;
    }
    return sum_sq_dev(xs) / ((n - 1) as float);
}

// The population variance (divided by n); NaN for an empty list.
pub fn pvariance[T](xs: [T]) -> float {
    let n = len(xs);
    if n == 0 {
        return math.nan;
    }
    return sum_sq_dev(xs) / (n as float);
}

// The sample standard deviation, sqrt(variance).
pub fn stddev[T](xs: [T]) -> float {
    return math.sqrt(variance(xs));
}

// The population standard deviation, sqrt(pvariance).
pub fn pstddev[T](xs: [T]) -> float {
    return math.sqrt(pvariance(xs));
}

// The median absolute deviation, median(|x - median(xs)|): a spread that
// one wild value cannot move, unlike stddev. Unscaled; multiply by 1.4826
// to estimate a normal distribution's stddev.
pub fn mad[T](xs: [T]) -> float {
    let m = median(xs);
    let devs: [float] = [];
    for x in xs {
        push(devs, math.abs((x as float) - m));
    }
    return median(devs);
}

// Each value's distance from the mean in population standard deviations
// (SciPy's zscore). All NaN when every value is the same.
pub fn zscores[T](xs: [T]) -> [float] {
    let m = mean(xs);
    let sd = pstddev(xs);
    let out: [float] = [];
    for x in xs {
        push(out, ((x as float) - m) / sd);
    }
    return out;
}

// The skewness, the population third standardized moment (Fisher-Pearson
// g1): 0 for a symmetric distribution, positive with a long right tail.
// NaN for an empty list or when every value is the same.
pub fn skewness[T](xs: [T]) -> float {
    let m2 = central_moment(xs, 2);
    return central_moment(xs, 3) / math.pow(m2, 1.5);
}

// The excess kurtosis, m4 / m2^2 - 3: 0 for a normal distribution,
// positive for heavier tails. NaN for an empty list or constant values.
pub fn kurtosis[T](xs: [T]) -> float {
    let m2 = central_moment(xs, 2);
    return central_moment(xs, 4) / (m2 * m2) - 3.0;
}

// The sample covariance of xs and ys (divided by n - 1); NaN when the
// lengths differ or there are fewer than two pairs.
pub fn covariance[T, U](xs: [T], ys: [U]) -> float {
    let n = len(xs);
    if n != len(ys) || n < 2 {
        return math.nan;
    }
    let mx = mean(xs);
    let my = mean(ys);
    let s = 0.0;
    let c = 0.0;
    for i in 0..n {
        let v = ((xs[i] as float) - mx) * ((ys[i] as float) - my);
        let t = s + v;
        c += two_sum_err(s, v, t);
        s = t;
    }
    return (s + c) / ((n - 1) as float);
}

// Pearson's correlation coefficient r, in [-1, 1]; NaN when the lengths
// differ, there are fewer than two pairs, or either list is constant.
pub fn correlation[T, U](xs: [T], ys: [U]) -> float {
    let n = len(xs);
    if n != len(ys) || n < 2 {
        return math.nan;
    }
    let r = covariance(xs, ys) / (stddev(xs) * stddev(ys));
    return math.clamp(r, -1.0, 1.0); // rounding can step just past 1
}

// Spearman's rank correlation: Pearson's r of the values' ranks, so any
// monotonic relationship scores 1, not just a straight line. Tied values
// share the mean of their ranks.
pub fn spearman[T, U](xs: [T], ys: [U]) -> float {
    if len(xs) != len(ys) {
        return math.nan;
    }
    return correlation(ranks(xs), ranks(ys));
}

// Each value's rank, 1 for the smallest; tied values share the mean of
// the ranks they span ([10, 20, 20, 30] ranks as [1, 2.5, 2.5, 4]).
pub fn ranks[T](xs: [T]) -> [float] {
    let vals: [float] = [];
    for x in xs {
        push(vals, x as float);
    }
    let order = argsort(vals);
    let out: [float] = [];
    for k in 0..len(vals) {
        push(out, 0.0);
    }
    let i = 0;
    while i < len(order) {
        let j = i + 1;
        while j < len(order) && vals[order[j]] == vals[order[i]] {
            j += 1;
        }
        let r = ((i + j + 1) as float) / 2.0; // mean of ranks i+1 .. j
        for k in i..j {
            out[order[k]] = r;
        }
        i = j;
    }
    return out;
}

pub struct Fit {
    slope: float,
    intercept: float,
    r2: float,      // the coefficient of determination, in [0, 1]
}

impl Fit {
    // The fitted line at x.
    pub fn at(self: Fit, x: float) -> float {
        return self.intercept + self.slope * x;
    }
}

// The least-squares line y = intercept + slope * x through the points.
// Every field is NaN when the lengths differ, there are fewer than two
// points, or every x is the same.
pub fn linear_regression[T, U](xs: [T], ys: [U]) -> Fit {
    let n = len(xs);
    let none_fit = Fit { slope: math.nan, intercept: math.nan, r2: math.nan };
    if n != len(ys) || n < 2 {
        return none_fit;
    }
    let mx = mean(xs);
    let my = mean(ys);
    let sxy = 0.0;
    let cxy = 0.0;
    let sxx = 0.0;
    let cxx = 0.0;
    let syy = 0.0;
    let cyy = 0.0;
    for i in 0..n {
        let dx = (xs[i] as float) - mx;
        let dy = (ys[i] as float) - my;
        let pxy = dx * dy;
        let txy = sxy + pxy;
        cxy += two_sum_err(sxy, pxy, txy);
        sxy = txy;
        let pxx = dx * dx;
        let txx = sxx + pxx;
        cxx += two_sum_err(sxx, pxx, txx);
        sxx = txx;
        let pyy = dy * dy;
        let tyy = syy + pyy;
        cyy += two_sum_err(syy, pyy, tyy);
        syy = tyy;
    }
    let vxx = sxx + cxx;
    if vxx == 0.0 {
        return none_fit;
    }
    let vxy = sxy + cxy;
    let vyy = syy + cyy;
    let slope = vxy / vxx;
    let r2 = 1.0;
    if vyy != 0.0 {
        r2 = math.clamp((vxy * vxy) / (vxx * vyy), 0.0, 1.0);
    }
    return Fit { slope: slope, intercept: my - slope * mx, r2: r2 };
}

pub struct Histogram {
    edges: [float],  // bins + 1 edges, ascending
    counts: [int],   // counts[i] is the values in [edges[i], edges[i+1])
}

// Counts xs into `bins` equal-width bins over [min, max]; the last bin
// also holds max itself. NaNs are not counted. bins below 1 is taken as 1,
// and a list of one repeated value gets one bin of width 1 around it.
pub fn histogram[T](xs: [T], bins: int) -> Histogram {
    let nb = math.max(bins, 1);
    let lo = math.inf;
    let hi = math.neg_inf;
    for x in xs {
        let v = x as float;
        if v < lo {
            lo = v;
        }
        if v > hi {
            hi = v;
        }
    }
    if lo > hi { // empty, or only NaNs
        lo = 0.0;
        hi = 1.0;
    }
    if lo == hi {
        lo = lo - 0.5;
        hi = hi + 0.5;
    }
    let edges: [float] = [];
    let counts: [int] = [];
    let width = (hi - lo) / (nb as float);
    for i in 0..nb {
        push(edges, lo + width * (i as float));
        push(counts, 0);
    }
    push(edges, hi);
    for x in xs {
        let v = x as float;
        if math.is_nan(v) {
            continue;
        }
        let b = math.floor((v - lo) / width) as int;
        b = math.clamp(b, 0, nb - 1);
        counts[b] += 1;
    }
    return Histogram { edges: edges, counts: counts };
}

// ---- helpers ----

// The rounding error of t = a + b, exactly (Knuth's TwoSum): a + b ==
// t + two_sum_err(a, b, t) in real numbers, whatever a's and b's
// magnitudes, with no branch.
fn two_sum_err(a: float, b: float, t: float) -> float {
    let bb = t - a;
    return (a - (t - bb)) + (b - bb);
}

// sum((x - mean)^2), compensated
fn sum_sq_dev[T](xs: [T]) -> float {
    let m = mean(xs);
    let s = 0.0;
    let c = 0.0;
    for x in xs {
        let d = (x as float) - m;
        let v = d * d;
        let t = s + v;
        c += two_sum_err(s, v, t);
        s = t;
    }
    return s + c;
}

// the k-th central moment, mean((x - mean)^k); NaN for an empty list
fn central_moment[T](xs: [T], k: int) -> float {
    if len(xs) == 0 {
        return math.nan;
    }
    let m = mean(xs);
    let s = 0.0;
    let c = 0.0;
    for x in xs {
        let v = math.powi((x as float) - m, k);
        let t = s + v;
        c += two_sum_err(s, v, t);
        s = t;
    }
    return (s + c) / (len(xs) as float);
}

// A sorted copy of xs, for any element type that `<` orders: heapsort,
// O(n log n) and no recursion.
fn sorted_copy[T](xs: [T]) -> [T] {
    let s: [T] = [];
    for x in xs {
        push(s, x);
    }
    let n = len(s);
    let start = n / 2 - 1;
    while start >= 0 {
        sift_down(s, start, n);
        start -= 1;
    }
    let end = n - 1;
    while end > 0 {
        let t = s[0];
        s[0] = s[end];
        s[end] = t;
        sift_down(s, 0, end);
        end -= 1;
    }
    return s;
}

fn sift_down[T](s: [T], root: int, n: int) {
    let r = root;
    while true {
        let child = 2 * r + 1;
        if child >= n {
            return;
        }
        if child + 1 < n && s[child] < s[child + 1] {
            child += 1;
        }
        if !(s[r] < s[child]) {
            return;
        }
        let t = s[r];
        s[r] = s[child];
        s[child] = t;
        r = child;
    }
}

// The indices of vals in ascending order of value (heapsort on indices).
fn argsort(vals: [float]) -> [int] {
    let idx: [int] = [];
    for i in 0..len(vals) {
        push(idx, i);
    }
    let n = len(idx);
    let start = n / 2 - 1;
    while start >= 0 {
        sift_idx(vals, idx, start, n);
        start -= 1;
    }
    let end = n - 1;
    while end > 0 {
        let t = idx[0];
        idx[0] = idx[end];
        idx[end] = t;
        sift_idx(vals, idx, 0, end);
        end -= 1;
    }
    return idx;
}

fn sift_idx(vals: [float], idx: [int], root: int, n: int) {
    let r = root;
    while true {
        let child = 2 * r + 1;
        if child >= n {
            return;
        }
        if child + 1 < n && vals[idx[child]] < vals[idx[child + 1]] {
            child += 1;
        }
        if !(vals[idx[r]] < vals[idx[child]]) {
            return;
        }
        let t = idx[r];
        idx[r] = idx[child];
        idx[child] = t;
        r = child;
    }
}
