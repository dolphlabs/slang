// Values between known points: fee schedules, tiered rates, pricing and
// yield curves, calibration tables, sensor lookups.
//
//     import "math/interp";
//
//     let fees = interp.linear([0.0, 1000.0, 10000.0], [2.5, 1.8, 0.9]) ?? interp.empty();
//     fees.at(4200.0)                              // 1.48
//     let tiers = interp.step([0.0, 100.0, 500.0], [10.0, 8.0, 5.0]) ?? interp.empty();
//     tiers.at(250.0)                              // 8.0: the tier it falls in
//     let curve = interp.monotone(days, rates) ?? interp.empty();   // no overshoot
//     curve.at(45.0); curve.slope(45.0)
//
// Every constructor checks its input: as many ys as xs, at least one
// point, xs strictly increasing, no NaN or infinity. Outside the knots a
// curve holds its end value (Extrapolate.Clamp, the default), continues
// its end segment (Linear), or gives NaN (None): set_extrapolate.
//
// Lookups are a binary search, but a curve remembers the last segment it
// used, so querying in ascending order (a schedule, a plot, a sweep) costs
// O(1) per point. That memory makes a Curve unsafe to share between tasks
// that query it at once: give each its own copy() (the knots are shared).

import "math";

pub enum Extrapolate { Clamp, Linear, None }

// Kinds of curve.
let K_LINEAR = 0;
let K_STEP = 1;
let K_HERMITE = 2;   // monotone cubic: ms are the slopes at the knots
let K_SPLINE = 3;    // natural cubic spline: ms are the second derivatives

pub gc struct Curve {
    kind: int,
    xs: [float],
    ys: [float],
    ms: [float],
    ext: Extrapolate,
    last: int,       // the segment of the previous lookup
}

// A curve with no points, for `??` defaults: every value is NaN.
pub fn empty() -> Curve {
    return Curve { kind: K_LINEAR, xs: [], ys: [], ms: [], ext: Extrapolate.None, last: 0 };
}

// Straight lines between the points.
pub fn linear(xs: [float], ys: [float]) -> result[Curve, str] {
    return make(K_LINEAR, xs, ys);
}

// A staircase: the value of the last point at or below x (the tier a
// quantity falls in). Before the first point: its value under Clamp,
// NaN under None.
pub fn step(xs: [float], ys: [float]) -> result[Curve, str] {
    return make(K_STEP, xs, ys);
}

// A monotone cubic (Fritsch and Carlson 1980, with Fritsch-Butland
// slopes): smooth, through every point, and never rising above or
// dipping below its neighbours, so a monotone table stays monotone. The
// safe choice for rates and prices.
pub fn monotone(xs: [float], ys: [float]) -> result[Curve, str] {
    return make(K_HERMITE, xs, ys);
}

// The natural cubic spline: the smoothest curve through the points (a
// continuous second derivative, zero at the ends). It can overshoot
// between points; use monotone when that matters.
pub fn spline(xs: [float], ys: [float]) -> result[Curve, str] {
    return make(K_SPLINE, xs, ys);
}

fn make(kind: int, xs: [float], ys: [float]) -> result[Curve, str] {
    let n = len(xs);
    if n == 0 {
        return err("interp: no points");
    }
    if len(ys) != n {
        return err("interp: " + to_str(n) + " xs but " + to_str(len(ys)) + " ys");
    }
    for i in 0..n {
        if !math.is_finite(xs[i]) || !math.is_finite(ys[i]) {
            return err("interp: point " + to_str(i) + " is not finite");
        }
        if i > 0 && !(xs[i] > xs[i - 1]) {
            return err("interp: xs must increase strictly (at index " + to_str(i) + ")");
        }
    }
    let cx: [float] = [];
    let cy: [float] = [];
    for i in 0..n {
        push(cx, xs[i]);
        push(cy, ys[i]);
    }
    let ms: [float] = [];
    if kind == K_HERMITE {
        ms = hermite_slopes(cx, cy);
    } else if kind == K_SPLINE {
        ms = spline_second(cx, cy);
    }
    return ok(Curve { kind: kind, xs: cx, ys: cy, ms: ms, ext: Extrapolate.Clamp, last: 0 });
}

// Fritsch-Butland: the weighted harmonic mean of the neighbouring secant
// slopes where they agree in sign, 0 where they do not (a local extreme
// stays flat). Ends use the one-sided three-point estimate, limited the
// same way.
fn hermite_slopes(xs: [float], ys: [float]) -> [float] {
    let n = len(xs);
    let m: [float] = [];
    if n == 1 {
        push(m, 0.0);
        return m;
    }
    let d: [float] = [];
    for i in 0..n - 1 {
        push(d, (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
    }
    if n == 2 {
        push(m, d[0]);
        push(m, d[0]);
        return m;
    }
    push(m, end_slope(xs[1] - xs[0], xs[2] - xs[1], d[0], d[1]));
    for i in 1..n - 1 {
        let h0 = xs[i] - xs[i - 1];
        let h1 = xs[i + 1] - xs[i];
        if d[i - 1] * d[i] <= 0.0 {
            push(m, 0.0);
        } else {
            let w1 = 2.0 * h1 + h0;
            let w2 = h1 + 2.0 * h0;
            push(m, (w1 + w2) / (w1 / d[i - 1] + w2 / d[i]));
        }
    }
    push(m, end_slope(xs[n - 1] - xs[n - 2], xs[n - 2] - xs[n - 3], d[n - 2], d[n - 3]));
    return m;
}

fn end_slope(h0: float, h1: float, d0: float, d1: float) -> float {
    let s = ((2.0 * h0 + h1) * d0 - h0 * d1) / (h0 + h1);
    if s * d0 <= 0.0 {
        return 0.0;
    }
    if d0 * d1 <= 0.0 && math.abs(s) > math.abs(3.0 * d0) {
        return 3.0 * d0;
    }
    return s;
}

// Second derivatives of the natural spline: the tridiagonal system solved
// by the Thomas algorithm, O(n).
fn spline_second(xs: [float], ys: [float]) -> [float] {
    let n = len(xs);
    let m: [float] = [];
    for i in 0..n {
        push(m, 0.0);
    }
    if n < 3 {
        return m;
    }
    let c: [float] = [];   // modified super-diagonal
    let r: [float] = [];   // modified right-hand side
    for i in 0..n {
        push(c, 0.0);
        push(r, 0.0);
    }
    for i in 1..n - 1 {
        let h0 = xs[i] - xs[i - 1];
        let h1 = xs[i + 1] - xs[i];
        let rhs = 6.0 * ((ys[i + 1] - ys[i]) / h1 - (ys[i] - ys[i - 1]) / h0);
        let diag = 2.0 * (h0 + h1) - h0 * c[i - 1];
        c[i] = h1 / diag;
        r[i] = (rhs - h0 * r[i - 1]) / diag;
    }
    let i = n - 2;
    while i >= 1 {
        m[i] = r[i] - c[i] * m[i + 1];
        i -= 1;
    }
    return m;
}

impl Curve {
    // The value at x.
    pub fn at(self: Curve, x: float) -> float {
        let n = len(self.xs);
        if n == 0 || math.is_nan(x) {
            return math.nan;
        }
        if x < self.xs[0] || x > self.xs[n - 1] {
            return self.outside(x);
        }
        if n == 1 {
            return self.ys[0];
        }
        let i = self.segment(x);
        return self.eval(i, x);
    }

    // The values at each of xs, in one pass when xs ascend.
    pub fn at_all(self: Curve, xs: [float]) -> [float] {
        let out: [float] = [];
        for x in xs {
            push(out, self.at(x));
        }
        return out;
    }

    // The derivative at x (0 on a step curve, and outside the knots under
    // Clamp).
    pub fn slope(self: Curve, x: float) -> float {
        let n = len(self.xs);
        if n == 0 || math.is_nan(x) {
            return math.nan;
        }
        if n == 1 || self.kind == K_STEP {
            return 0.0;
        }
        if x < self.xs[0] || x > self.xs[n - 1] {
            if self.ext == Extrapolate.None {
                return math.nan;
            }
            if self.ext == Extrapolate.Clamp {
                return 0.0;
            }
            if x < self.xs[0] {
                return self.end_slope_at(0);
            }
            return self.end_slope_at(n - 2);
        }
        let i = self.segment(x);
        let x0 = self.xs[i];
        let x1 = self.xs[i + 1];
        let h = x1 - x0;
        let y0 = self.ys[i];
        let y1 = self.ys[i + 1];
        if self.kind == K_LINEAR {
            return (y1 - y0) / h;
        }
        let t = (x - x0) / h;
        if self.kind == K_HERMITE {
            let m0 = self.ms[i];
            let m1 = self.ms[i + 1];
            let dh00 = 6.0 * t * t - 6.0 * t;
            let dh10 = 3.0 * t * t - 4.0 * t + 1.0;
            let dh01 = -dh00;
            let dh11 = 3.0 * t * t - 2.0 * t;
            return (dh00 * y0 + dh01 * y1) / h + dh10 * m0 + dh11 * m1;
        }
        let a = x1 - x;
        let b = x - x0;
        let s0 = self.ms[i];
        let s1 = self.ms[i + 1];
        return (y1 - y0) / h - (3.0 * a * a - h * h) / (6.0 * h) * s0 +
               (3.0 * b * b - h * h) / (6.0 * h) * s1;
    }

    pub fn set_extrapolate(self: Curve, mode: Extrapolate) -> Curve {
        self.ext = mode;
        return self;
    }

    // A curve over the same knots with its own lookup memory, for
    // another task.
    pub fn copy(self: Curve) -> Curve {
        return Curve {
            kind: self.kind, xs: self.xs, ys: self.ys, ms: self.ms, ext: self.ext, last: 0
        };
    }

    pub fn size(self: Curve) -> int {
        return len(self.xs);
    }

    // The segment [xs[i], xs[i+1]] holding x, for x within the knots:
    // the remembered one or its successor first, else binary search.
    fn segment(self: Curve, x: float) -> int {
        let n = len(self.xs);
        let i = self.last;
        if i < n - 1 && x >= self.xs[i] && x <= self.xs[i + 1] {
            return i;
        }
        if i + 2 < n && x >= self.xs[i + 1] && x <= self.xs[i + 2] {
            self.last = i + 1;
            return i + 1;
        }
        let lo = 0;
        let hi = n - 1;
        while hi - lo > 1 {
            let mid = (lo + hi) / 2;
            if self.xs[mid] <= x {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        self.last = lo;
        return lo;
    }

    fn eval(self: Curve, i: int, x: float) -> float {
        let x0 = self.xs[i];
        let x1 = self.xs[i + 1];
        let y0 = self.ys[i];
        let y1 = self.ys[i + 1];
        if self.kind == K_STEP {
            if x >= x1 {
                return y1;
            }
            return y0;
        }
        let h = x1 - x0;
        if self.kind == K_LINEAR {
            return y0 + (y1 - y0) * ((x - x0) / h);
        }
        if self.kind == K_HERMITE {
            let t = (x - x0) / h;
            let t2 = t * t;
            let t3 = t2 * t;
            let h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
            let h10 = t3 - 2.0 * t2 + t;
            let h01 = -2.0 * t3 + 3.0 * t2;
            let h11 = t3 - t2;
            return h00 * y0 + h10 * h * self.ms[i] + h01 * y1 + h11 * h * self.ms[i + 1];
        }
        let a = (x1 - x) / h;
        let b = (x - x0) / h;
        return a * y0 + b * y1 +
               ((a * a * a - a) * self.ms[i] + (b * b * b - b) * self.ms[i + 1]) * h * h / 6.0;
    }

    fn outside(self: Curve, x: float) -> float {
        let n = len(self.xs);
        if self.ext == Extrapolate.None {
            return math.nan;
        }
        if self.kind == K_STEP {
            if x > self.xs[n - 1] {
                return self.ys[n - 1];
            }
            if self.ext == Extrapolate.Clamp {
                return self.ys[0];
            }
            return math.nan;
        }
        if self.ext == Extrapolate.Clamp || n == 1 {
            if x < self.xs[0] {
                return self.ys[0];
            }
            return self.ys[n - 1];
        }
        if x < self.xs[0] {
            return self.ys[0] + self.end_slope_at(0) * (x - self.xs[0]);
        }
        return self.ys[n - 1] + self.end_slope_at(n - 2) * (x - self.xs[n - 1]);
    }

    // The slope at the outer end of segment i (0 or the last), for
    // linear extrapolation.
    fn end_slope_at(self: Curve, i: int) -> float {
        let n = len(self.xs);
        if self.kind == K_HERMITE {
            if i == 0 {
                return self.ms[0];
            }
            return self.ms[n - 1];
        }
        let h = self.xs[i + 1] - self.xs[i];
        let sec = (self.ys[i + 1] - self.ys[i]) / h;
        if self.kind == K_SPLINE {
            if i == 0 {
                return sec - h * (2.0 * self.ms[0] + self.ms[1]) / 6.0;
            }
            return sec + h * (self.ms[i] + 2.0 * self.ms[i + 1]) / 6.0;
        }
        return sec;
    }
}

// A table of values over a rectangular grid, read by bilinear
// interpolation: prices by (weight, distance), rates by (term, amount).
pub gc struct Grid {
    xs: [float],
    ys: [float],
    zs: [float],     // row-major: zs[i * len(ys) + j] is the value at (xs[i], ys[j])
}

// A grid over ascending xs and ys with len(xs) * len(ys) values, row by
// row. Outside the grid the nearest edge value is used.
pub fn grid(xs: [float], ys: [float], values: [float]) -> result[Grid, str] {
    if len(xs) == 0 || len(ys) == 0 {
        return err("interp: a grid needs at least one x and one y");
    }
    if len(values) != len(xs) * len(ys) {
        return err("interp: a " + to_str(len(xs)) + " x " + to_str(len(ys)) + " grid needs " +
                   to_str(len(xs) * len(ys)) + " values, got " + to_str(len(values)));
    }
    for i in 0..len(xs) {
        if !math.is_finite(xs[i]) || (i > 0 && !(xs[i] > xs[i - 1])) {
            return err("interp: grid xs must be finite and increase strictly");
        }
    }
    for j in 0..len(ys) {
        if !math.is_finite(ys[j]) || (j > 0 && !(ys[j] > ys[j - 1])) {
            return err("interp: grid ys must be finite and increase strictly");
        }
    }
    for v in values {
        if !math.is_finite(v) {
            return err("interp: grid values must be finite");
        }
    }
    let cx: [float] = [];
    let cy: [float] = [];
    let cz: [float] = [];
    for x in xs { push(cx, x); }
    for y in ys { push(cy, y); }
    for v in values { push(cz, v); }
    return ok(Grid { xs: cx, ys: cy, zs: cz });
}

impl Grid {
    pub fn at(self: Grid, x: float, y: float) -> float {
        if math.is_nan(x) || math.is_nan(y) {
            return math.nan;
        }
        let ny = len(self.ys);
        let i = bracket_of(self.xs, x);
        let j = bracket_of(self.ys, y);
        let tx = frac_of(self.xs, i, x);
        let ty = frac_of(self.ys, j, y);
        let i1 = math.min(i + 1, len(self.xs) - 1);
        let j1 = math.min(j + 1, ny - 1);
        let z00 = self.zs[i * ny + j];
        let z01 = self.zs[i * ny + j1];
        let z10 = self.zs[i1 * ny + j];
        let z11 = self.zs[i1 * ny + j1];
        let top = z00 + (z01 - z00) * ty;
        let bottom = z10 + (z11 - z10) * ty;
        return top + (bottom - top) * tx;
    }
}

// The index i with xs[i] <= x < xs[i+1], clamped to the ends.
fn bracket_of(xs: [float], x: float) -> int {
    let n = len(xs);
    if n == 1 || x <= xs[0] {
        return 0;
    }
    if x >= xs[n - 1] {
        return n - 1;
    }
    let lo = 0;
    let hi = n - 1;
    while hi - lo > 1 {
        let mid = (lo + hi) / 2;
        if xs[mid] <= x {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo;
}

// Where x sits between xs[i] and xs[i+1], 0 to 1 (0 at the ends).
fn frac_of(xs: [float], i: int, x: float) -> float {
    if i + 1 >= len(xs) {
        return 0.0;
    }
    return math.clamp((x - xs[i]) / (xs[i + 1] - xs[i]), 0.0, 1.0);
}
