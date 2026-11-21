// Statistics for experiments: did variant B beat A, how sure are we, and
// how many users does a test need. With the t and chi-square
// distributions they rest on.
//
//     let t = stats.two_proportion_z(120, 2400, 156, 2380);
//     t.p_value < 0.05                          // significant at 5%
//     stats.wilson(156, 2380, 0.95)             // Interval { lo, hi }
//     stats.sample_size_proportions(0.05, 0.06, 0.05, 0.8)   // users per arm
//     let s = stats.sprt(0.05, 0.06, 0.05, 0.2);
//     s.add(converted)                          // Decision: stop early when sure
//
// Every p-value is two-sided. The tests assume independent observations:
// count each user once, not each page view.

import "math";

// A test statistic, its two-sided p-value, and its degrees of freedom
// (NaN for a z-test).
pub struct TestResult {
    statistic: float,
    p_value: float,
    df: float,
}

// A confidence interval.
pub struct Interval {
    lo: float,
    hi: float,
}

fn nan_result() -> TestResult {
    return TestResult { statistic: math.nan, p_value: math.nan, df: math.nan };
}

// ---- special functions -------------------------------------------------

// The regularized incomplete beta function I_x(a, b) (the cdf of a beta
// distribution), by Lentz's continued fraction on whichever side
// converges fast (Numerical Recipes 6.4).
pub fn inc_beta(a: float, b: float, x: float) -> float {
    if !(a > 0.0) || !(b > 0.0) || math.is_nan(x) {
        return math.nan;
    }
    if x <= 0.0 {
        return 0.0;
    }
    if x >= 1.0 {
        return 1.0;
    }
    let lbt = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) +
              a * math.log(x) + b * math.log1p(-x);
    let front = math.exp(lbt);
    if x < (a + 1.0) / (a + b + 2.0) {
        return front * beta_cf(a, b, x) / a;
    }
    return 1.0 - front * beta_cf(b, a, 1.0 - x) / b;
}

fn beta_cf(a: float, b: float, x: float) -> float {
    let tiny = 1e-300;
    let qab = a + b;
    let qap = a + 1.0;
    let qam = a - 1.0;
    let c = 1.0;
    let d = 1.0 - qab * x / qap;
    if math.abs(d) < tiny {
        d = tiny;
    }
    d = 1.0 / d;
    let h = d;
    for m in 1..400 {
        let mf = m as float;
        let m2 = 2.0 * mf;
        let aa = mf * (b - mf) * x / ((qam + m2) * (a + m2));
        d = 1.0 + aa * d;
        if math.abs(d) < tiny { d = tiny; }
        c = 1.0 + aa / c;
        if math.abs(c) < tiny { c = tiny; }
        d = 1.0 / d;
        h *= d * c;
        aa = -(a + mf) * (qab + mf) * x / ((a + m2) * (qap + m2));
        d = 1.0 + aa * d;
        if math.abs(d) < tiny { d = tiny; }
        c = 1.0 + aa / c;
        if math.abs(c) < tiny { c = tiny; }
        d = 1.0 / d;
        let del = d * c;
        h *= del;
        if math.abs(del - 1.0) < 1e-15 {
            return h;
        }
    }
    return h;
}

// The regularized lower incomplete gamma function P(a, x) (the cdf of a
// gamma distribution): its series below a + 1, its continued fraction
// above (Numerical Recipes 6.2).
pub fn inc_gamma(a: float, x: float) -> float {
    if !(a > 0.0) || math.is_nan(x) {
        return math.nan;
    }
    if x <= 0.0 {
        return 0.0;
    }
    if math.is_inf(x) {
        return 1.0;
    }
    let lead = a * math.log(x) - x - math.lgamma(a);
    if x < a + 1.0 {
        let ap = a;
        let del = 1.0 / a;
        let sum = del;
        for n in 0..1000 {
            ap += 1.0;
            del *= x / ap;
            sum += del;
            if math.abs(del) < math.abs(sum) * 1e-16 {
                break;
            }
        }
        return math.min(1.0, sum * math.exp(lead));
    }
    let tiny = 1e-300;
    let b = x + 1.0 - a;
    let c = 1.0 / tiny;
    let d = 1.0 / b;
    let h = d;
    for i in 1..1000 {
        let an = -(i as float) * ((i as float) - a);
        b += 2.0;
        d = an * d + b;
        if math.abs(d) < tiny { d = tiny; }
        c = b + an / c;
        if math.abs(c) < tiny { c = tiny; }
        d = 1.0 / d;
        let del = d * c;
        h *= del;
        if math.abs(del - 1.0) < 1e-16 {
            break;
        }
    }
    return math.max(0.0, 1.0 - math.exp(lead) * h);
}

// ---- Student's t and chi-square ----------------------------------------

pub struct StudentT {
    df: float,
}

// Student's t distribution with df degrees of freedom (df > 0).
pub fn student_t(df: float) -> StudentT {
    return StudentT { df: df };
}

impl StudentT {
    pub fn pdf(self: StudentT, x: float) -> float {
        let v = self.df;
        if !(v > 0.0) {
            return math.nan;
        }
        let lc = math.lgamma(0.5 * (v + 1.0)) - math.lgamma(0.5 * v) - 0.5 * math.log(v * math.pi);
        return math.exp(lc - 0.5 * (v + 1.0) * math.log1p(x * x / v));
    }

    pub fn cdf(self: StudentT, x: float) -> float {
        let v = self.df;
        if !(v > 0.0) || math.is_nan(x) {
            return math.nan;
        }
        if math.is_inf(x) {
            if x > 0.0 { return 1.0; }
            return 0.0;
        }
        let tail = 0.5 * inc_beta(0.5 * v, 0.5, v / (v + x * x));
        if x > 0.0 {
            return 1.0 - tail;
        }
        return tail;
    }

    // The x with cdf(x) = p: Newton's method from the normal quantile,
    // guarded by bisection, to full double precision.
    pub fn quantile(self: StudentT, p: float) -> float {
        if !(self.df > 0.0) || !(p >= 0.0 && p <= 1.0) {
            return math.nan;
        }
        if p == 0.0 {
            return math.neg_inf;
        }
        if p == 1.0 {
            return math.inf;
        }
        if p == 0.5 {
            return 0.0;
        }
        return invert_cdf_t(self, p);
    }
}

fn invert_cdf_t(d: StudentT, p: float) -> float {
    let x = normal(0.0, 1.0).quantile(p);
    let lo = -1e300;
    let hi = 1e300;
    for i in 0..200 {
        let f = d.cdf(x) - p;
        if f == 0.0 {
            return x;
        }
        if f < 0.0 { lo = x; } else { hi = x; }
        let step = f / d.pdf(x);
        let nx = x - step;
        if !(nx > lo && nx < hi) || math.is_nan(nx) {
            nx = 0.5 * (math.max(lo, -1e15) + math.min(hi, 1e15));
        }
        if math.abs(nx - x) <= 1e-15 * math.max(1.0, math.abs(x)) {
            return nx;
        }
        x = nx;
    }
    return x;
}

pub struct ChiSquared {
    k: float,
}

// The chi-square distribution with k degrees of freedom (k > 0).
pub fn chi_squared(k: float) -> ChiSquared {
    return ChiSquared { k: k };
}

impl ChiSquared {
    pub fn pdf(self: ChiSquared, x: float) -> float {
        if !(self.k > 0.0) {
            return math.nan;
        }
        if x < 0.0 {
            return 0.0;
        }
        if x == 0.0 {
            if self.k < 2.0 { return math.inf; }
            if self.k == 2.0 { return 0.5; }
            return 0.0;
        }
        let h = 0.5 * self.k;
        return math.exp((h - 1.0) * math.log(x) - 0.5 * x - h * math.ln2 - math.lgamma(h));
    }

    pub fn cdf(self: ChiSquared, x: float) -> float {
        if !(self.k > 0.0) {
            return math.nan;
        }
        return inc_gamma(0.5 * self.k, 0.5 * x);
    }

    // The x with cdf(x) = p: Newton's method from the Wilson-Hilferty
    // approximation, guarded by bisection.
    pub fn quantile(self: ChiSquared, p: float) -> float {
        if !(self.k > 0.0) || !(p >= 0.0 && p <= 1.0) {
            return math.nan;
        }
        if p == 0.0 {
            return 0.0;
        }
        if p == 1.0 {
            return math.inf;
        }
        let z = normal(0.0, 1.0).quantile(p);
        let c = 2.0 / (9.0 * self.k);
        let x = self.k * math.powi(1.0 - c + z * math.sqrt(c), 3);
        if !(x > 0.0) {
            x = math.max(1e-10, self.k * 0.1);
        }
        let lo = 0.0;
        let hi = math.inf;
        for i in 0..200 {
            let f = self.cdf(x) - p;
            if f == 0.0 {
                return x;
            }
            if f < 0.0 { lo = x; } else { hi = x; }
            let nx = x - f / self.pdf(x);
            if !(nx > lo && nx < hi) || math.is_nan(nx) {
                if math.is_inf(hi) {
                    nx = 2.0 * x;
                } else {
                    nx = 0.5 * (lo + hi);
                }
            }
            if math.abs(nx - x) <= 1e-15 * math.max(1.0, x) {
                return nx;
            }
            x = nx;
        }
        return x;
    }
}

// ---- tests -----------------------------------------------------------

// Two-sided p-value of a standard normal statistic, through erfc so tiny
// p-values keep their precision.
fn p_two_sided_z(z: float) -> float {
    return math.erfc(math.abs(z) / math.sqrt2);
}

// Whether two conversion rates differ: the pooled two-proportion z-test,
// for successes_a of n_a against successes_b of n_b. The statistic is
// positive when B's rate is higher.
pub fn two_proportion_z(successes_a: int, n_a: int, successes_b: int, n_b: int) -> TestResult {
    if n_a <= 0 || n_b <= 0 || successes_a < 0 || successes_b < 0 ||
       successes_a > n_a || successes_b > n_b {
        return nan_result();
    }
    let pa = (successes_a as float) / (n_a as float);
    let pb = (successes_b as float) / (n_b as float);
    let pool = ((successes_a + successes_b) as float) / ((n_a + n_b) as float);
    let se = math.sqrt(pool * (1.0 - pool) * (1.0 / (n_a as float) + 1.0 / (n_b as float)));
    if se == 0.0 {
        return TestResult { statistic: 0.0, p_value: 1.0, df: math.nan };
    }
    let z = (pb - pa) / se;
    return TestResult { statistic: z, p_value: p_two_sided_z(z), df: math.nan };
}

// Whether two means differ, without assuming equal variances: Welch's
// t-test with Welch-Satterthwaite degrees of freedom. Positive when ys'
// mean is higher. NaN with fewer than two values on a side.
pub fn welch_t[T, U](xs: [T], ys: [U]) -> TestResult {
    let na = len(xs);
    let nb = len(ys);
    if na < 2 || nb < 2 {
        return nan_result();
    }
    let ma = mean(xs);
    let mb = mean(ys);
    let va = variance(xs) / (na as float);
    let vb = variance(ys) / (nb as float);
    let se2 = va + vb;
    if se2 == 0.0 {
        if ma == mb {
            return TestResult { statistic: 0.0, p_value: 1.0, df: ((na + nb - 2) as float) };
        }
        return TestResult { statistic: math.copysign(math.inf, mb - ma), p_value: 0.0, df: ((na + nb - 2) as float) };
    }
    let t = (mb - ma) / math.sqrt(se2);
    let df = se2 * se2 / (va * va / ((na - 1) as float) + vb * vb / ((nb - 1) as float));
    let p = 2.0 * student_t(df).cdf(-math.abs(t));
    return TestResult { statistic: t, p_value: math.min(p, 1.0), df: df };
}

// Whether the mean of xs differs from mu: the one-sample t-test.
pub fn t_test[T](xs: [T], mu: float) -> TestResult {
    let n = len(xs);
    if n < 2 {
        return nan_result();
    }
    let se = math.sqrt(variance(xs) / (n as float));
    let df = (n - 1) as float;
    if se == 0.0 {
        if mean(xs) == mu {
            return TestResult { statistic: 0.0, p_value: 1.0, df: df };
        }
        return TestResult { statistic: math.copysign(math.inf, mean(xs) - mu), p_value: 0.0, df: df };
    }
    let t = (mean(xs) - mu) / se;
    return TestResult { statistic: t, p_value: math.min(2.0 * student_t(df).cdf(-math.abs(t)), 1.0), df: df };
}

// Whether counts in a table of rows (variants) by columns (outcomes) are
// independent: Pearson's chi-square test. Every row has the same number
// of columns; NaN for a table smaller than 2 x 2, ragged, negative, or
// with an empty row or column.
pub fn chi_square_test(table: [[int]]) -> TestResult {
    let r = len(table);
    if r < 2 {
        return nan_result();
    }
    let c = len(table[0]);
    if c < 2 {
        return nan_result();
    }
    let rows: [float] = [];
    let cols: [float] = [];
    for j in 0..c {
        push(cols, 0.0);
    }
    let total = 0.0;
    for i in 0..r {
        if len(table[i]) != c {
            return nan_result();
        }
        let s = 0.0;
        for j in 0..c {
            let v = table[i][j];
            if v < 0 {
                return nan_result();
            }
            s += v as float;
            cols[j] += v as float;
        }
        push(rows, s);
        total += s;
    }
    let x = 0.0;
    for i in 0..r {
        for j in 0..c {
            let e = rows[i] * cols[j] / total;
            if e == 0.0 {
                return nan_result();
            }
            let d = (table[i][j] as float) - e;
            x += d * d / e;
        }
    }
    let df = ((r - 1) * (c - 1)) as float;
    return TestResult { statistic: x, p_value: 1.0 - chi_squared(df).cdf(x), df: df };
}

// Whether observed counts fit expected ones (same total, or scaled to
// it): the chi-square goodness-of-fit test, df = bins - 1.
pub fn chi_square_fit(observed: [int], expected: [float]) -> TestResult {
    let n = len(observed);
    if n < 2 || len(expected) != n {
        return nan_result();
    }
    let so = 0.0;
    let se = 0.0;
    for i in 0..n {
        if observed[i] < 0 || !(expected[i] > 0.0) {
            return nan_result();
        }
        so += observed[i] as float;
        se += expected[i];
    }
    let x = 0.0;
    for i in 0..n {
        let e = expected[i] * so / se;
        let d = (observed[i] as float) - e;
        x += d * d / e;
    }
    let df = (n - 1) as float;
    return TestResult { statistic: x, p_value: 1.0 - chi_squared(df).cdf(x), df: df };
}

// ---- intervals and planning -----------------------------------------

// The Wilson score interval for a proportion: successes of n at the given
// confidence (0.95). Unlike the textbook p +- z*se it stays inside [0, 1]
// and behaves at 0 or n successes.
pub fn wilson(successes: int, n: int, confidence: float) -> Interval {
    if n <= 0 || successes < 0 || successes > n || !(confidence > 0.0 && confidence < 1.0) {
        return Interval { lo: math.nan, hi: math.nan };
    }
    let z = normal(0.0, 1.0).quantile(0.5 + 0.5 * confidence);
    let nf = n as float;
    let p = (successes as float) / nf;
    let z2 = z * z;
    let den = 1.0 + z2 / nf;
    let centre = (p + z2 / (2.0 * nf)) / den;
    let half = z * math.sqrt(p * (1.0 - p) / nf + z2 / (4.0 * nf * nf)) / den;
    return Interval { lo: math.max(0.0, centre - half), hi: math.min(1.0, centre + half) };
}

// The t interval for the mean of xs at the given confidence.
pub fn mean_interval[T](xs: [T], confidence: float) -> Interval {
    let n = len(xs);
    if n < 2 || !(confidence > 0.0 && confidence < 1.0) {
        return Interval { lo: math.nan, hi: math.nan };
    }
    let m = mean(xs);
    let se = math.sqrt(variance(xs) / (n as float));
    let t = student_t((n - 1) as float).quantile(0.5 + 0.5 * confidence);
    return Interval { lo: m - t * se, hi: m + t * se };
}

// Users needed in EACH arm to detect a change in conversion from p1 to p2
// with a two-sided test at significance alpha (0.05) and the given power
// (0.8): the normal-approximation formula. -1 for invalid input.
pub fn sample_size_proportions(p1: float, p2: float, alpha: float, power: float) -> int {
    if !(p1 > 0.0 && p1 < 1.0) || !(p2 > 0.0 && p2 < 1.0) || p1 == p2 ||
       !(alpha > 0.0 && alpha < 1.0) || !(power > 0.0 && power < 1.0) {
        return -1;
    }
    let n0 = normal(0.0, 1.0);
    let za = n0.quantile(1.0 - alpha / 2.0);
    let zb = n0.quantile(power);
    let pbar = 0.5 * (p1 + p2);
    let a = za * math.sqrt(2.0 * pbar * (1.0 - pbar));
    let b = zb * math.sqrt(p1 * (1.0 - p1) + p2 * (1.0 - p2));
    let d = p2 - p1;
    return math.ceil_int((a + b) * (a + b) / (d * d)) ?? -1;
}

// The power of that test with n users per arm.
pub fn power_proportions(p1: float, p2: float, n: int, alpha: float) -> float {
    if !(p1 > 0.0 && p1 < 1.0) || !(p2 > 0.0 && p2 < 1.0) || n <= 0 ||
       !(alpha > 0.0 && alpha < 1.0) {
        return math.nan;
    }
    let n0 = normal(0.0, 1.0);
    let za = n0.quantile(1.0 - alpha / 2.0);
    let nf = n as float;
    let pbar = 0.5 * (p1 + p2);
    let se0 = math.sqrt(2.0 * pbar * (1.0 - pbar) / nf);
    let se1 = math.sqrt((p1 * (1.0 - p1) + p2 * (1.0 - p2)) / nf);
    let d = math.abs(p2 - p1);
    return n0.cdf((d - za * se0) / se1) + n0.cdf((-d - za * se0) / se1);
}

// Values needed in EACH arm to detect a difference `delta` between two
// means with common standard deviation sd, two-sided at alpha with the
// given power. -1 for invalid input.
pub fn sample_size_means(delta: float, sd: float, alpha: float, power: float) -> int {
    if delta == 0.0 || !(sd > 0.0) || !(alpha > 0.0 && alpha < 1.0) || !(power > 0.0 && power < 1.0) {
        return -1;
    }
    let n0 = normal(0.0, 1.0);
    let z = n0.quantile(1.0 - alpha / 2.0) + n0.quantile(power);
    return math.ceil_int(2.0 * z * z * sd * sd / (delta * delta)) ?? -1;
}

// ---- sequential testing ----------------------------------------------

pub enum Decision { Continue, AcceptNull, AcceptAlternative }

// Wald's sequential probability ratio test for a conversion rate: is it p0
// (the null) or p1 (the alternative)? Feed outcomes one at a time and stop
// as soon as it decides; on average it needs far fewer observations than
// a fixed-size test with the same error rates (alpha: deciding p1 when it
// is p0; beta: deciding p0 when it is p1). Peeking is part of the design,
// so stopping early does not inflate the error rate.
pub gc struct Sprt {
    upper: float,    // log((1 - beta) / alpha)
    lower: float,    // log(beta / (1 - alpha))
    win: float,      // log(p1 / p0): the step for a success
    loss: float,     // log((1 - p1) / (1 - p0)): the step for a failure
    llr: float,
    n: int,
    done: Decision,
}

// A test of p0 against p1 (both in (0, 1), different) with error rates
// alpha and beta (in (0, 1)); invalid input decides nothing ever.
pub fn sprt(p0: float, p1: float, alpha: float, beta: float) -> Sprt {
    let ok_in = p0 > 0.0 && p0 < 1.0 && p1 > 0.0 && p1 < 1.0 && p0 != p1 &&
                alpha > 0.0 && alpha < 1.0 && beta > 0.0 && beta < 1.0;
    if !ok_in {
        return Sprt {
            upper: math.inf, lower: math.neg_inf, win: 0.0, loss: 0.0, llr: 0.0, n: 0,
            done: Decision.Continue
        };
    }
    return Sprt {
        upper: math.log((1.0 - beta) / alpha), lower: math.log(beta / (1.0 - alpha)),
        win: math.log(p1 / p0), loss: math.log((1.0 - p1) / (1.0 - p0)), llr: 0.0, n: 0,
        done: Decision.Continue
    };
}

impl Sprt {
    // One observation. Once decided, further observations change nothing.
    pub fn add(self: Sprt, success: bool) -> Decision {
        if success {
            return self.add_n(1, 1);
        }
        return self.add_n(0, 1);
    }

    // A batch: successes of n.
    pub fn add_n(self: Sprt, successes: int, n: int) -> Decision {
        if self.done != Decision.Continue || n <= 0 || successes < 0 || successes > n {
            return self.done;
        }
        self.llr += (successes as float) * self.win + ((n - successes) as float) * self.loss;
        self.n += n;
        if self.llr >= self.upper {
            self.done = Decision.AcceptAlternative;
        } else if self.llr <= self.lower {
            self.done = Decision.AcceptNull;
        }
        return self.done;
    }

    pub fn decision(self: Sprt) -> Decision {
        return self.done;
    }

    // Observations taken.
    pub fn count(self: Sprt) -> int {
        return self.n;
    }

    // The log-likelihood ratio so far: positive leans to p1.
    pub fn log_ratio(self: Sprt) -> float {
        return self.llr;
    }
}
