// Solving f(x) = 0, minimising f(x) and integrating f over an interval,
// for one real variable: implied rates, break-even points, the price that
// maximises revenue, the area under a demand curve.
//
//     import "math/optimize";
//
//     fn f(x: float) -> float { return x * x - 2.0; }
//     let r = optimize.brent(f, 0.0, 2.0, 1e-12);        // result[Root, str]
//     (r ?? optimize.no_root()).x                        // 1.41421356...
//
// slang has no closures, so a function that needs data takes it as a
// second parameter, and the `_with` form passes it through:
//
//     struct Loan { pv: float, pmt: float, n: int }
//     fn gap(rate: float, l: Loan) -> float { ... }
//     optimize.brent_with(gap, loan, 0.0, 1.0, 1e-12)
//
// Root finders need a bracket [lo, hi] where f changes sign; bracket()
// widens a guess into one. Every routine stops at a tolerance in x or a
// fixed budget of evaluations, and reports which in its error: none of
// them can loop forever, whatever f returns (a NaN is an error).

import "math";

// A root: f(x) is (near) zero. fx is f at x; evals counts calls to f.
pub struct Root {
    x: float,
    fx: float,
    evals: int,
}

// A minimum of f on an interval: f(x) = fx.
pub struct Min {
    x: float,
    fx: float,
    evals: int,
}

// An integral, with an estimate of its absolute error.
pub struct Integral {
    value: float,
    error: float,
    evals: int,
}

// A bracket [lo, hi] with f(lo) and f(hi) of opposite signs (or one 0).
pub struct Bracket {
    lo: float,
    hi: float,
}

// NaNs, for `??` defaults: (r ?? optimize.no_root()).x is NaN on error.
pub fn no_root() -> Root {
    return Root { x: math.nan, fx: math.nan, evals: 0 };
}

pub fn no_min() -> Min {
    return Min { x: math.nan, fx: math.nan, evals: 0 };
}

pub fn no_integral() -> Integral {
    return Integral { value: math.nan, error: math.nan, evals: 0 };
}

let MAX_EVALS = 500;
let EPS = 2.220446049250313e-16;

fn plain(x: float, f: fn(float) -> float) -> float {
    return f(x);
}

fn same_sign(a: float, b: float) -> bool {
    return (a > 0.0 && b > 0.0) || (a < 0.0 && b < 0.0);
}

// ---- brackets ----------------------------------------------------------

// Widens [lo, hi] geometrically (by 1.6 each side, up to 50 times) until f
// changes sign across it.
pub fn bracket(f: fn(float) -> float, lo: float, hi: float) -> result[Bracket, str] {
    return bracket_with(plain, f, lo, hi);
}

pub fn bracket_with[C](f: fn(float, C) -> float, ctx: C, lo: float, hi: float) -> result[Bracket, str] {
    let a = math.min(lo, hi);
    let b = math.max(lo, hi);
    if !(b > a) {
        b = a + 1.0;
    }
    let fa = f(a, ctx);
    let fb = f(b, ctx);
    for i in 0..50 {
        if math.is_nan(fa) || math.is_nan(fb) {
            return err("optimize: f is NaN while bracketing");
        }
        if !same_sign(fa, fb) {
            return ok(Bracket { lo: a, hi: b });
        }
        // grow toward the side whose value is smaller in magnitude
        if math.abs(fa) < math.abs(fb) {
            a += 1.6 * (a - b);
            fa = f(a, ctx);
        } else {
            b += 1.6 * (b - a);
            fb = f(b, ctx);
        }
    }
    return err("optimize: no sign change found while widening the bracket");
}

// ---- roots ---------------------------------------------------------------

// Bisection: halves [lo, hi] until it is within tol. Slow (one bit per
// step) but certain; prefer brent.
pub fn bisect(f: fn(float) -> float, lo: float, hi: float, tol: float) -> result[Root, str] {
    return bisect_with(plain, f, lo, hi, tol);
}

pub fn bisect_with[C](f: fn(float, C) -> float, ctx: C, lo: float, hi: float, tol: float) -> result[Root, str] {
    let a = lo;
    let b = hi;
    let fa = f(a, ctx);
    let fb = f(b, ctx);
    let evals = 2;
    if math.is_nan(fa) || math.is_nan(fb) {
        return err("optimize: f is NaN at the bracket");
    }
    if fa == 0.0 {
        return ok(Root { x: a, fx: fa, evals: evals });
    }
    if fb == 0.0 {
        return ok(Root { x: b, fx: fb, evals: evals });
    }
    if same_sign(fa, fb) {
        return err("optimize: f does not change sign on [lo, hi]");
    }
    let t = math.max(tol, 0.0);
    while evals < MAX_EVALS {
        let m = a + 0.5 * (b - a);
        let fm = f(m, ctx);
        evals += 1;
        if math.is_nan(fm) {
            return err("optimize: f is NaN at " + to_str(m));
        }
        if fm == 0.0 || math.abs(b - a) * 0.5 <= t + 4.0 * EPS * math.abs(m) {
            return ok(Root { x: m, fx: fm, evals: evals });
        }
        if same_sign(fa, fm) {
            a = m;
            fa = fm;
        } else {
            b = m;
        }
    }
    return err("optimize: bisection did not reach the tolerance");
}

// Brent's method (Brent 1973, the zeroin of netlib): inverse quadratic
// interpolation and secant steps, falling back to bisection whenever they
// would not shrink the bracket fast enough. Superlinear on smooth f,
// never slower than bisection. The default root finder.
pub fn brent(f: fn(float) -> float, lo: float, hi: float, tol: float) -> result[Root, str] {
    return brent_with(plain, f, lo, hi, tol);
}

pub fn brent_with[C](f: fn(float, C) -> float, ctx: C, lo: float, hi: float, tol: float) -> result[Root, str] {
    let a = lo;
    let b = hi;
    let fa = f(a, ctx);
    let fb = f(b, ctx);
    let evals = 2;
    if math.is_nan(fa) || math.is_nan(fb) {
        return err("optimize: f is NaN at the bracket");
    }
    if fa == 0.0 {
        return ok(Root { x: a, fx: fa, evals: evals });
    }
    if fb == 0.0 {
        return ok(Root { x: b, fx: fb, evals: evals });
    }
    if same_sign(fa, fb) {
        return err("optimize: f does not change sign on [lo, hi]");
    }
    let t = math.max(tol, 0.0);
    let c = b;
    let fc = fb;
    let d = b - a;
    let e = d;
    while evals < MAX_EVALS {
        if same_sign(fb, fc) {
            c = a;
            fc = fa;
            d = b - a;
            e = d;
        }
        if math.abs(fc) < math.abs(fb) {
            a = b;
            b = c;
            c = a;
            fa = fb;
            fb = fc;
            fc = fa;
        }
        let tol1 = 2.0 * EPS * math.abs(b) + 0.5 * t;
        let xm = 0.5 * (c - b);
        if math.abs(xm) <= tol1 || fb == 0.0 {
            return ok(Root { x: b, fx: fb, evals: evals });
        }
        if math.abs(e) >= tol1 && math.abs(fa) > math.abs(fb) {
            let s = fb / fa;
            let p = 0.0;
            let q = 0.0;
            if a == c {
                p = 2.0 * xm * s;
                q = 1.0 - s;
            } else {
                let qq = fa / fc;
                let r = fb / fc;
                p = s * (2.0 * xm * qq * (qq - r) - (b - a) * (r - 1.0));
                q = (qq - 1.0) * (r - 1.0) * (s - 1.0);
            }
            if p > 0.0 {
                q = -q;
            }
            p = math.abs(p);
            let m1 = 3.0 * xm * q - math.abs(tol1 * q);
            let m2 = math.abs(e * q);
            if 2.0 * p < math.min(m1, m2) {
                e = d;
                d = p / q;
            } else {
                d = xm;
                e = d;
            }
        } else {
            d = xm;
            e = d;
        }
        a = b;
        fa = fb;
        if math.abs(d) > tol1 {
            b += d;
        } else {
            b += math.copysign(tol1, xm);
        }
        fb = f(b, ctx);
        evals += 1;
        if math.is_nan(fb) {
            return err("optimize: f is NaN at " + to_str(b));
        }
    }
    return err("optimize: Brent's method did not reach the tolerance");
}

// Newton's method from x0 with derivative df: quadratic convergence near
// a simple root, but it can diverge from a poor start. Use newton_safe
// when a bracket is known.
pub fn newton(f: fn(float) -> float, df: fn(float) -> float, x0: float, tol: float) -> result[Root, str] {
    return newton_with(plain, plain, f, x0, tol, df);
}

// newton with data: f and df each take ctx. (The derivative's own data
// is passed as dctx, so f and df can differ in what they need.)
pub fn newton_with[C, D](f: fn(float, C) -> float, df: fn(float, D) -> float, ctx: C, x0: float, tol: float, dctx: D) -> result[Root, str] {
    let x = x0;
    let t = math.max(tol, 0.0);
    let evals = 0;
    while evals < MAX_EVALS {
        let fx = f(x, ctx);
        let d = df(x, dctx);
        evals += 2;
        if math.is_nan(fx) || math.is_nan(d) {
            return err("optimize: f or its derivative is NaN at " + to_str(x));
        }
        if fx == 0.0 {
            return ok(Root { x: x, fx: fx, evals: evals });
        }
        if d == 0.0 {
            return err("optimize: the derivative is 0 at " + to_str(x));
        }
        let step = fx / d;
        x -= step;
        if math.abs(step) <= t + 4.0 * EPS * math.abs(x) {
            return ok(Root { x: x, fx: f(x, ctx), evals: evals + 1 });
        }
        if !math.is_finite(x) {
            return err("optimize: Newton's method diverged");
        }
    }
    return err("optimize: Newton's method did not reach the tolerance");
}

// Safeguarded Newton (rtsafe): Newton steps that stay inside a bracket
// [lo, hi] where f changes sign, with bisection whenever a step would
// leave it or shrink it too slowly. Fast and certain.
pub fn newton_safe(f: fn(float) -> float, df: fn(float) -> float, lo: float, hi: float, tol: float) -> result[Root, str] {
    return newton_safe_with(plain, plain, f, lo, hi, tol, df);
}

pub fn newton_safe_with[C, D](f: fn(float, C) -> float, df: fn(float, D) -> float, ctx: C, lo: float, hi: float, tol: float, dctx: D) -> result[Root, str] {
    let flo = f(lo, ctx);
    let fhi = f(hi, ctx);
    let evals = 2;
    if math.is_nan(flo) || math.is_nan(fhi) {
        return err("optimize: f is NaN at the bracket");
    }
    if flo == 0.0 {
        return ok(Root { x: lo, fx: flo, evals: evals });
    }
    if fhi == 0.0 {
        return ok(Root { x: hi, fx: fhi, evals: evals });
    }
    if same_sign(flo, fhi) {
        return err("optimize: f does not change sign on [lo, hi]");
    }
    // orient so f(xl) < 0 < f(xh)
    let xl = lo;
    let xh = hi;
    if flo > 0.0 {
        xl = hi;
        xh = lo;
    }
    let t = math.max(tol, 0.0);
    let x = 0.5 * (lo + hi);
    let dxold = math.abs(hi - lo);
    let dx = dxold;
    let fx = f(x, ctx);
    let d = df(x, dctx);
    evals += 2;
    while evals < MAX_EVALS {
        if math.is_nan(fx) || math.is_nan(d) {
            return err("optimize: f or its derivative is NaN at " + to_str(x));
        }
        let newton_out = ((x - xh) * d - fx) * ((x - xl) * d - fx) > 0.0;
        if newton_out || math.abs(2.0 * fx) > math.abs(dxold * d) {
            dxold = dx;
            dx = 0.5 * (xh - xl);
            x = xl + dx;
        } else {
            dxold = dx;
            dx = fx / d;
            x -= dx;
        }
        if math.abs(dx) <= t + 4.0 * EPS * math.abs(x) {
            return ok(Root { x: x, fx: f(x, ctx), evals: evals + 1 });
        }
        fx = f(x, ctx);
        d = df(x, dctx);
        evals += 2;
        if fx == 0.0 {
            return ok(Root { x: x, fx: fx, evals: evals });
        }
        if fx < 0.0 {
            xl = x;
        } else {
            xh = x;
        }
    }
    return err("optimize: safeguarded Newton did not reach the tolerance");
}

// ---- minimisation ----------------------------------------------------

// Golden-section search for the minimum of a unimodal f on [a, b]: the
// interval shrinks by 0.618 per evaluation. Needs no derivative and no
// smoothness; prefer brent_min for smooth f.
pub fn golden(f: fn(float) -> float, a: float, b: float, tol: float) -> result[Min, str] {
    return golden_with(plain, f, a, b, tol);
}

pub fn golden_with[C](f: fn(float, C) -> float, ctx: C, a: float, b: float, tol: float) -> result[Min, str] {
    let invphi = 0.6180339887498949;
    let lo = math.min(a, b);
    let hi = math.max(a, b);
    let t = math.max(tol, 0.0);
    let x1 = hi - invphi * (hi - lo);
    let x2 = lo + invphi * (hi - lo);
    let f1 = f(x1, ctx);
    let f2 = f(x2, ctx);
    let evals = 2;
    while evals < MAX_EVALS {
        if math.is_nan(f1) || math.is_nan(f2) {
            return err("optimize: f is NaN during the search");
        }
        if hi - lo <= t + 4.0 * EPS * math.abs(x1) {
            if f1 <= f2 {
                return ok(Min { x: x1, fx: f1, evals: evals });
            }
            return ok(Min { x: x2, fx: f2, evals: evals });
        }
        if f1 <= f2 {
            hi = x2;
            x2 = x1;
            f2 = f1;
            x1 = hi - invphi * (hi - lo);
            f1 = f(x1, ctx);
        } else {
            lo = x1;
            x1 = x2;
            f1 = f2;
            x2 = lo + invphi * (hi - lo);
            f2 = f(x2, ctx);
        }
        evals += 1;
    }
    return err("optimize: golden-section search did not reach the tolerance");
}

// Brent's minimisation (Brent 1973, localmin; scipy's fminbound):
// parabolic interpolation through the best three points, golden-section
// steps when a parabola is not trustworthy. On [a, b], for unimodal f.
pub fn brent_min(f: fn(float) -> float, a: float, b: float, tol: float) -> result[Min, str] {
    return brent_min_with(plain, f, a, b, tol);
}

pub fn brent_min_with[C](f: fn(float, C) -> float, ctx: C, a0: float, b0: float, tol: float) -> result[Min, str] {
    let cgold = 0.3819660112501051;
    let a = math.min(a0, b0);
    let b = math.max(a0, b0);
    let t = math.max(tol, 0.0);
    let x = a + cgold * (b - a);
    let w = x;
    let v = x;
    let fx = f(x, ctx);
    let fw = fx;
    let fv = fx;
    let d = 0.0;
    let e = 0.0;
    let evals = 1;
    while evals < MAX_EVALS {
        if math.is_nan(fx) {
            return err("optimize: f is NaN at " + to_str(x));
        }
        let xm = 0.5 * (a + b);
        let tol1 = math.sqrt(EPS) * math.abs(x) + t / 3.0;
        let tol2 = 2.0 * tol1;
        if math.abs(x - xm) <= tol2 - 0.5 * (b - a) {
            return ok(Min { x: x, fx: fx, evals: evals });
        }
        let golden_step = true;
        if math.abs(e) > tol1 {
            let r = (x - w) * (fx - fv);
            let q = (x - v) * (fx - fw);
            let p = (x - v) * q - (x - w) * r;
            q = 2.0 * (q - r);
            if q > 0.0 {
                p = -p;
            }
            q = math.abs(q);
            let etemp = e;
            e = d;
            if !(math.abs(p) >= math.abs(0.5 * q * etemp) || p <= q * (a - x) || p >= q * (b - x)) {
                d = p / q;
                let u = x + d;
                if u - a < tol2 || b - u < tol2 {
                    d = math.copysign(tol1, xm - x);
                }
                golden_step = false;
            }
        }
        if golden_step {
            if x >= xm {
                e = a - x;
            } else {
                e = b - x;
            }
            d = cgold * e;
        }
        let u = x + math.copysign(tol1, d);
        if math.abs(d) >= tol1 {
            u = x + d;
        }
        let fu = f(u, ctx);
        evals += 1;
        if fu <= fx {
            if u >= x {
                a = x;
            } else {
                b = x;
            }
            v = w;
            fv = fw;
            w = x;
            fw = fx;
            x = u;
            fx = fu;
        } else {
            if u < x {
                a = u;
            } else {
                b = u;
            }
            if fu <= fw || w == x {
                v = w;
                fv = fw;
                w = u;
                fw = fu;
            } else if fu <= fv || v == x || v == w {
                v = u;
                fv = fu;
            }
        }
    }
    return err("optimize: Brent's minimisation did not reach the tolerance");
}

// ---- integration -----------------------------------------------------

// Adaptive Simpson's rule: splits wherever the two halves disagree with
// the whole by more than tol (absolute), with Richardson's correction.
// For smooth f on a finite interval.
pub fn simpson(f: fn(float) -> float, a: float, b: float, tol: float) -> result[Integral, str] {
    return simpson_with(plain, f, a, b, tol);
}

pub fn simpson_with[C](f: fn(float, C) -> float, ctx: C, a: float, b: float, tol: float) -> result[Integral, str] {
    if !math.is_finite(a) || !math.is_finite(b) {
        return err("optimize: simpson needs finite bounds; use integrate");
    }
    let fa = f(a, ctx);
    let fb = f(b, ctx);
    let m = 0.5 * (a + b);
    let fm = f(m, ctx);
    let whole = (b - a) / 6.0 * (fa + 4.0 * fm + fb);
    // an explicit stack of intervals: no recursion on an 8 KB task stack
    let st_a: [float] = [a];
    let st_b: [float] = [b];
    let st_fa: [float] = [fa];
    let st_fm: [float] = [fm];
    let st_fb: [float] = [fb];
    let st_s: [float] = [whole];
    let st_tol: [float] = [math.max(tol, 1e-300)];
    let st_depth: [int] = [0];
    let total = 0.0;
    let error = 0.0;
    let evals = 3;
    while len(st_a) > 0 {
        let lo = pop(st_a);
        let hi = pop(st_b);
        let flo = pop(st_fa);
        let fmid = pop(st_fm);
        let fhi = pop(st_fb);
        let s = pop(st_s);
        let tl = pop(st_tol);
        let depth = pop(st_depth);
        let mid = 0.5 * (lo + hi);
        let lm = 0.5 * (lo + mid);
        let rm = 0.5 * (mid + hi);
        let flm = f(lm, ctx);
        let frm = f(rm, ctx);
        evals += 2;
        if math.is_nan(flm) || math.is_nan(frm) {
            return err("optimize: f is NaN on [" + to_str(lo) + ", " + to_str(hi) + "]");
        }
        let left = (mid - lo) / 6.0 * (flo + 4.0 * flm + fmid);
        let right = (hi - mid) / 6.0 * (fmid + 4.0 * frm + fhi);
        let delta = left + right - s;
        if depth >= 50 || math.abs(delta) <= 15.0 * tl || evals > 200000 {
            if depth >= 50 || evals > 200000 {
                if math.abs(delta) > 15.0 * tl {
                    return err("optimize: simpson could not reach the tolerance (a singularity?)");
                }
            }
            total += left + right + delta / 15.0;
            error += math.abs(delta) / 15.0;
            continue;
        }
        push(st_a, lo);
        push(st_b, mid);
        push(st_fa, flo);
        push(st_fm, flm);
        push(st_fb, fmid);
        push(st_s, left);
        push(st_tol, tl / 2.0);
        push(st_depth, depth + 1);
        push(st_a, mid);
        push(st_b, hi);
        push(st_fa, fmid);
        push(st_fm, frm);
        push(st_fb, fhi);
        push(st_s, right);
        push(st_tol, tl / 2.0);
        push(st_depth, depth + 1);
    }
    return ok(Integral { value: total, error: error, evals: evals });
}

// Adaptive Gauss-Kronrod (7-point Gauss, 15-point Kronrod, as QUADPACK's
// QAG): the interval with the largest error estimate is halved until the
// total error is within max(abs_tol, rel_tol * |integral|). Infinite
// bounds are mapped onto a finite interval (x = t / (1 - t^2) and its
// one-sided forms). The general-purpose integrator.
pub fn integrate(f: fn(float) -> float, a: float, b: float, abs_tol: float, rel_tol: float) -> result[Integral, str] {
    return integrate_with(plain, f, a, b, abs_tol, rel_tol);
}

pub fn integrate_with[C](f: fn(float, C) -> float, ctx: C, a: float, b: float, abs_tol: float, rel_tol: float) -> result[Integral, str] {
    if math.is_nan(a) || math.is_nan(b) {
        return err("optimize: a bound is NaN");
    }
    if a == b {
        return ok(Integral { value: 0.0, error: 0.0, evals: 0 });
    }
    if a > b {
        let r = integrate_with(f, ctx, b, a, abs_tol, rel_tol);
        guard let v = r else let e = err_of(r) {
            return err(e);
        }
        return ok(Integral { value: -v.value, error: v.error, evals: v.evals });
    }
    // mode: 0 finite, 1 [a, inf), 2 (-inf, b], 3 (-inf, inf)
    let mode = 0;
    let lo = a;
    let hi = b;
    if math.is_inf(a) && math.is_inf(b) {
        mode = 3;
        lo = -1.0;
        hi = 1.0;
    } else if math.is_inf(b) {
        mode = 1;
        lo = 0.0;
        hi = 1.0;
    } else if math.is_inf(a) {
        mode = 2;
        lo = 0.0;
        hi = 1.0;
    }
    let ia: [float] = [];
    let ib: [float] = [];
    let iv: [float] = [];
    let ie: [float] = [];
    let first = gk15(f, ctx, mode, a, b, lo, hi);
    if math.is_nan(first.value) {
        return err("optimize: f is NaN on the interval");
    }
    push(ia, lo);
    push(ib, hi);
    push(iv, first.value);
    push(ie, first.error);
    let total = first.value;
    let error = first.error;
    let evals = 15;
    let at = math.max(abs_tol, 0.0);
    let rt = math.max(rel_tol, 0.0);
    while error > math.max(at, rt * math.abs(total)) {
        if len(ia) >= 1000 {
            return err("optimize: integrate could not reach the tolerance in 1000 intervals");
        }
        // the interval with the largest error estimate
        let worst = 0;
        for i in 1..len(ie) {
            if ie[i] > ie[worst] {
                worst = i;
            }
        }
        let l = ia[worst];
        let h = ib[worst];
        let m = 0.5 * (l + h);
        if !(m > l && m < h) {
            return err("optimize: integrate hit the limit of float resolution (a singularity?)");
        }
        let left = gk15(f, ctx, mode, a, b, l, m);
        let right = gk15(f, ctx, mode, a, b, m, h);
        evals += 30;
        if math.is_nan(left.value) || math.is_nan(right.value) {
            return err("optimize: f is NaN on [" + to_str(l) + ", " + to_str(h) + "]");
        }
        total += left.value + right.value - iv[worst];
        error += left.error + right.error - ie[worst];
        ib[worst] = m;
        iv[worst] = left.value;
        ie[worst] = left.error;
        push(ia, m);
        push(ib, h);
        push(iv, right.value);
        push(ie, right.error);
    }
    // re-sum to shed the drift of the running updates
    let sum = 0.0;
    let esum = 0.0;
    for i in 0..len(iv) {
        sum += iv[i];
        esum += ie[i];
    }
    return ok(Integral { value: sum, error: esum, evals: evals });
}

// f at the point t of the mapped interval, times the mapping's Jacobian.
fn mapped[C](f: fn(float, C) -> float, ctx: C, mode: int, a: float, b: float, t: float) -> float {
    if mode == 0 {
        return f(t, ctx);
    }
    if mode == 1 {
        // x = a + t / (1 - t), dx = dt / (1 - t)^2
        let u = 1.0 - t;
        if u <= 0.0 {
            return 0.0;
        }
        return f(a + t / u, ctx) / (u * u);
    }
    if mode == 2 {
        let u = 1.0 - t;
        if u <= 0.0 {
            return 0.0;
        }
        return f(b - t / u, ctx) / (u * u);
    }
    // x = t / (1 - t^2), dx = (1 + t^2) / (1 - t^2)^2 dt
    let u = 1.0 - t * t;
    if u <= 0.0 {
        return 0.0;
    }
    return f(t / u, ctx) * (1.0 + t * t) / (u * u);
}

// One 15-point Kronrod estimate on [lo, hi], its error from the embedded
// 7-point Gauss rule: QUADPACK's (200 |K - G| / s)^1.5 scaling, with s the
// integral of |f| (QUADPACK uses |f - mean|, which is smaller, so this
// estimate is the more cautious), and its floor of 50 ulps of s.
fn gk15[C](f: fn(float, C) -> float, ctx: C, mode: int, a: float, b: float, lo: float, hi: float) -> Integral {
    let c = 0.5 * (lo + hi);
    let h = 0.5 * (hi - lo);
    let fc = mapped(f, ctx, mode, a, b, c);
    let resk = fc * kron_w(7);
    let resg = fc * gauss_w(3);
    let resabs = math.abs(resk);
    for j in 0..7 {
        let dx = h * kron_x(j);
        let f1 = mapped(f, ctx, mode, a, b, c - dx);
        let f2 = mapped(f, ctx, mode, a, b, c + dx);
        resk += kron_w(j) * (f1 + f2);
        resabs += kron_w(j) * (math.abs(f1) + math.abs(f2));
        if j % 2 == 1 {
            resg += gauss_w(j / 2) * (f1 + f2);
        }
    }
    let err_est = math.abs((resk - resg) * h);
    let scale = resabs * h;
    if scale != 0.0 && err_est != 0.0 {
        err_est = scale * math.min(1.0, math.pow(200.0 * err_est / scale, 1.5));
    }
    if scale > 1e-290 {
        err_est = math.max(err_est, 50.0 * EPS * scale);
    }
    return Integral { value: resk * h, error: err_est, evals: 15 };
}

// Kronrod nodes, outermost first (QUADPACK's xgk); index 7 is the centre.
fn kron_x(j: int) -> float {
    return switch j {
        case 0 { 0.9914553711208126 }
        case 1 { 0.9491079123427585 }
        case 2 { 0.8648644233597691 }
        case 3 { 0.7415311855993945 }
        case 4 { 0.5860872354676911 }
        case 5 { 0.4058451513773972 }
        case 6 { 0.2077849550078985 }
        default { 0.0 }
    };
}

fn kron_w(j: int) -> float {
    return switch j {
        case 0 { 0.02293532201052922 }
        case 1 { 0.06309209262997855 }
        case 2 { 0.1047900103222502 }
        case 3 { 0.1406532597155259 }
        case 4 { 0.1690047266392679 }
        case 5 { 0.1903505780647854 }
        case 6 { 0.2044329400752989 }
        default { 0.2094821410847278 }
    };
}

// Gauss weights for Kronrod nodes 1, 3, 5 and the centre.
fn gauss_w(j: int) -> float {
    return switch j {
        case 0 { 0.1294849661688697 }
        case 1 { 0.2797053914892767 }
        case 2 { 0.3818300505051189 }
        default { 0.4179591836734694 }
    };
}
