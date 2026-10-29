// Probability distributions: density (pdf) or mass (pmf), cumulative
// probability (cdf), and for the continuous ones the quantile, its
// inverse.
//
//     let n = stats.normal(100.0, 15.0);
//     n.cdf(130.0);          // 0.977...: P(X <= 130)
//     n.quantile(0.95);      // 124.67...
//     stats.poisson(3.0).pmf(5);
//
// A parameter outside its range (a stddev <= 0, a probability outside
// [0, 1]) makes every function of that distribution NaN.

import "math";

pub struct Normal {
    mu: float,
    sigma: float,
}

// The normal (Gaussian) distribution with mean mu and stddev sigma.
pub fn normal(mu: float, sigma: float) -> Normal {
    return Normal { mu: mu, sigma: sigma };
}

impl Normal {
    pub fn pdf(self: Normal, x: float) -> float {
        if !(self.sigma > 0.0) {
            return math.nan;
        }
        let z = (x - self.mu) / self.sigma;
        return math.exp(-0.5 * z * z) / (self.sigma * math.sqrt(math.tau));
    }

    // Through erfc, which keeps precision far into the lower tail where
    // 1 + erf would round to 0.
    pub fn cdf(self: Normal, x: float) -> float {
        if !(self.sigma > 0.0) {
            return math.nan;
        }
        return 0.5 * math.erfc(-(x - self.mu) / (self.sigma * math.sqrt2));
    }

    // The x with cdf(x) = p; -inf at 0, inf at 1, NaN outside [0, 1].
    pub fn quantile(self: Normal, p: float) -> float {
        if !(self.sigma > 0.0) || !(p >= 0.0 && p <= 1.0) {
            return math.nan;
        }
        return self.mu + self.sigma * math.sqrt2 * math.erf_inv(2.0 * p - 1.0);
    }
}

pub struct LogNormal {
    mu: float,       // of the logarithm
    sigma: float,
}

// The distribution of exp(X) for X normal(mu, sigma): response times and
// sizes, which are positive and skewed right.
pub fn log_normal(mu: float, sigma: float) -> LogNormal {
    return LogNormal { mu: mu, sigma: sigma };
}

impl LogNormal {
    pub fn pdf(self: LogNormal, x: float) -> float {
        if !(self.sigma > 0.0) {
            return math.nan;
        }
        if x <= 0.0 {
            return 0.0;
        }
        return normal(self.mu, self.sigma).pdf(math.log(x)) / x;
    }

    pub fn cdf(self: LogNormal, x: float) -> float {
        if !(self.sigma > 0.0) {
            return math.nan;
        }
        if x <= 0.0 {
            return 0.0;
        }
        return normal(self.mu, self.sigma).cdf(math.log(x));
    }

    pub fn quantile(self: LogNormal, p: float) -> float {
        return math.exp(normal(self.mu, self.sigma).quantile(p));
    }
}

pub struct Uniform {
    lo: float,
    hi: float,
}

// The continuous uniform distribution on [lo, hi].
pub fn uniform(lo: float, hi: float) -> Uniform {
    return Uniform { lo: lo, hi: hi };
}

impl Uniform {
    pub fn pdf(self: Uniform, x: float) -> float {
        if !(self.hi > self.lo) {
            return math.nan;
        }
        if x < self.lo || x > self.hi {
            return 0.0;
        }
        return 1.0 / (self.hi - self.lo);
    }

    pub fn cdf(self: Uniform, x: float) -> float {
        if !(self.hi > self.lo) {
            return math.nan;
        }
        return math.clamp((x - self.lo) / (self.hi - self.lo), 0.0, 1.0);
    }

    pub fn quantile(self: Uniform, p: float) -> float {
        if !(self.hi > self.lo) || !(p >= 0.0 && p <= 1.0) {
            return math.nan;
        }
        return math.lerp(self.lo, self.hi, p);
    }
}

pub struct Exponential {
    rate: float,
}

// The waiting time between events arriving at `rate` per unit time.
pub fn exponential(rate: float) -> Exponential {
    return Exponential { rate: rate };
}

impl Exponential {
    pub fn pdf(self: Exponential, x: float) -> float {
        if !(self.rate > 0.0) {
            return math.nan;
        }
        if x < 0.0 {
            return 0.0;
        }
        return self.rate * math.exp(-self.rate * x);
    }

    // 1 - exp(-rate x), through expm1 so a tiny x keeps its precision.
    pub fn cdf(self: Exponential, x: float) -> float {
        if !(self.rate > 0.0) {
            return math.nan;
        }
        if x < 0.0 {
            return 0.0;
        }
        return -math.expm1(-self.rate * x);
    }

    pub fn quantile(self: Exponential, p: float) -> float {
        if !(self.rate > 0.0) || !(p >= 0.0 && p <= 1.0) {
            return math.nan;
        }
        return -math.log1p(-p) / self.rate;
    }
}

pub struct Poisson {
    lambda: float,
}

// The number of events in an interval where `lambda` are expected.
pub fn poisson(lambda: float) -> Poisson {
    return Poisson { lambda: lambda };
}

impl Poisson {
    // P(X = k): directly while k! is exact (k <= 20) and lambda^k cannot
    // overflow, otherwise in log space, where lgamma costs a few ulps.
    pub fn pmf(self: Poisson, k: int) -> float {
        if !(self.lambda >= 0.0) {
            return math.nan;
        }
        if k < 0 {
            return 0.0;
        }
        if self.lambda == 0.0 {
            if k == 0 {
                return 1.0;
            }
            return 0.0;
        }
        let kf = k as float;
        if k <= 20 && self.lambda < 100.0 {
            return math.exp(-self.lambda) * math.powi(self.lambda, k) / math.factorial(k);
        }
        return math.exp(kf * math.log(self.lambda) - self.lambda - math.lgamma(kf + 1.0));
    }

    // P(X <= k).
    pub fn cdf(self: Poisson, k: int) -> float {
        if !(self.lambda >= 0.0) {
            return math.nan;
        }
        if k < 0 {
            return 0.0;
        }
        let terms: [float] = [];
        for i in 0..k + 1 {
            push(terms, self.pmf(i));
        }
        return math.min(sum(terms), 1.0);
    }
}

pub struct Binomial {
    n: int,
    p: float,
}

// The number of successes in n independent trials, each succeeding with
// probability p.
pub fn binomial(n: int, p: float) -> Binomial {
    return Binomial { n: n, p: p };
}

impl Binomial {
    // P(X = k): directly while the binomial coefficient is exact (n up to
    // 1000, as math.binomial computes it), otherwise in log space.
    pub fn pmf(self: Binomial, k: int) -> float {
        if self.n < 0 || !(self.p >= 0.0 && self.p <= 1.0) {
            return math.nan;
        }
        if k < 0 || k > self.n {
            return 0.0;
        }
        if self.p == 0.0 {
            if k == 0 {
                return 1.0;
            }
            return 0.0;
        }
        if self.p == 1.0 {
            if k == self.n {
                return 1.0;
            }
            return 0.0;
        }
        let nf = self.n as float;
        let kf = k as float;
        if self.n <= 1000 {
            let c = math.binomial(self.n, k);
            if c < 9007199254740992.0 { // 2^53: exact
                return c * math.powi(self.p, k) * math.powi(1.0 - self.p, self.n - k);
            }
        }
        let lc = math.lgamma(nf + 1.0) - math.lgamma(kf + 1.0) - math.lgamma(nf - kf + 1.0);
        return math.exp(lc + kf * math.log(self.p) + (nf - kf) * math.log1p(-self.p));
    }

    // P(X <= k).
    pub fn cdf(self: Binomial, k: int) -> float {
        if self.n < 0 || !(self.p >= 0.0 && self.p <= 1.0) {
            return math.nan;
        }
        if k < 0 {
            return 0.0;
        }
        if k >= self.n {
            return 1.0;
        }
        let terms: [float] = [];
        for i in 0..k + 1 {
            push(terms, self.pmf(i));
        }
        return math.min(sum(terms), 1.0);
    }
}
