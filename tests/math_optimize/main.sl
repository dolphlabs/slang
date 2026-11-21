// math/optimize against closed forms: roots of polynomials and
// transcendental equations, minima of known functions, integrals with
// known values (finite and infinite ranges), and every error path.
import "math/optimize";
import "math";

fn sq2(x: float) -> float { return x * x - 2.0; }
fn dsq2(x: float) -> float { return 2.0 * x; }
fn cosx(x: float) -> float { return math.cos(x) - x; }
fn dcosx(x: float) -> float { return -math.sin(x) - 1.0; }
fn flat(x: float) -> float { return 1.0 + x * x; }
fn nanf(x: float) -> float { return math.nan; }
fn cubic(x: float) -> float { return (x - 1.0) * (x - 1.0) * (x - 1.0); }
fn para(x: float) -> float { return (x - 3.0) * (x - 3.0) + 1.0; }
fn wave(x: float) -> float { return math.sin(x); }
fn gauss(x: float) -> float { return math.exp(-x * x); }
fn inv_sq(x: float) -> float { return 1.0 / (x * x); }
fn sqrtx(x: float) -> float { return math.sqrt(x); }
fn poly(x: float) -> float { return 3.0 * x * x + 2.0 * x + 1.0; }

struct Loan { pv: float, pmt: float, n: int }
// the rate at which n payments of pmt repay pv
fn loan_gap(rate: float, l: Loan) -> float {
    return l.pv - l.pmt * (1.0 - math.pow(1.0 + rate, -(l.n as float))) / rate;
}

fn near(a: float, b: float, tol: float) -> bool {
    return math.abs(a - b) <= tol;
}

let r1 = optimize.brent(sq2, 0.0, 2.0, 1e-14);
if let r = r1 { println(near(r.x, math.sqrt2, 1e-14)); println(r.evals < 15); }
let r2 = optimize.bisect(sq2, 0.0, 2.0, 1e-12);
if let r = r2 { println(near(r.x, math.sqrt2, 1e-12)); }
let r3 = optimize.newton(cosx, dcosx, 1.0, 1e-15);
if let r = r3 { println(near(r.x, 0.7390851332151607, 1e-15)); }
let r4 = optimize.newton_safe(sq2, dsq2, 0.0, 5.0, 1e-15);
if let r = r4 { println(near(r.x, math.sqrt2, 1e-15)); }
let r5 = optimize.brent(cubic, -3.0, 4.0, 1e-12);
if let r = r5 { println(near(r.x, 1.0, 1e-4)); }   // a triple root is flat
let e1 = optimize.brent(flat, -1.0, 1.0, 1e-12);
if let r = e1 { println("no!"); } else let e = err_of(e1) { println(e); }
let e2 = optimize.brent(nanf, -1.0, 1.0, 1e-12);
if let r = e2 { println("no!"); } else let e = err_of(e2) { println(e); }
let e3 = optimize.newton(sq2, dsq2, 0.0, 1e-12);
if let r = e3 { println("no!"); } else let e = err_of(e3) { println(e); }
let b1 = optimize.bracket(sq2, 5.0, 6.0);
if let b = b1 { println(b.lo < math.sqrt2 && b.hi > math.sqrt2); }
let b2 = optimize.bracket(flat, 0.0, 1.0);
if let b = b2 { println("no!"); } else let e = err_of(b2) { println(e); }
let loan = Loan { pv: 250000.0, pmt: 1342.05, n: 360 };
let rr = optimize.brent_with(loan_gap, loan, 0.0001, 0.1, 1e-14);
if let r = rr { println(near(r.x * 12.0, 0.05, 1e-6)); }
println(math.is_nan((e1 ?? optimize.no_root()).x));

let m1 = optimize.brent_min(para, 0.0, 10.0, 1e-10);
if let m = m1 { println(near(m.x, 3.0, 1e-7)); println(near(m.fx, 1.0, 1e-12)); }
let m2 = optimize.golden(para, 0.0, 10.0, 1e-9);
if let m = m2 { println(near(m.x, 3.0, 1e-7)); }
let m3 = optimize.brent_min(wave, 3.0, 6.0, 1e-10);
if let m = m3 { println(near(m.x, 1.5 * math.pi, 1e-7)); }

let i1 = optimize.integrate(poly, 0.0, 2.0, 1e-12, 1e-12);
if let v = i1 { println(near(v.value, 14.0, 1e-12)); }
let i2 = optimize.integrate(gauss, math.neg_inf, math.inf, 1e-12, 1e-12);
if let v = i2 { println(near(v.value, math.sqrt(math.pi), 1e-10)); }
let i3 = optimize.integrate(inv_sq, 1.0, math.inf, 1e-12, 1e-12);
if let v = i3 { println(near(v.value, 1.0, 1e-10)); }
let i4 = optimize.integrate(gauss, math.neg_inf, 0.0, 1e-12, 1e-12);
if let v = i4 { println(near(v.value, 0.5 * math.sqrt(math.pi), 1e-10)); }
let i5 = optimize.integrate(sqrtx, 0.0, 1.0, 1e-10, 1e-10);
if let v = i5 { println(near(v.value, 2.0 / 3.0, 1e-9)); }
let i6 = optimize.integrate(wave, math.pi, 0.0, 1e-12, 1e-12);
if let v = i6 { println(near(v.value, -2.0, 1e-12)); }
let s1 = optimize.simpson(wave, 0.0, math.pi, 1e-12);
if let v = s1 { println(near(v.value, 2.0, 1e-11)); }
let s2 = optimize.simpson(gauss, 0.0, math.inf, 1e-9);
if let v = s2 { println("no!"); } else let e = err_of(s2) { println(e); }
let i7 = optimize.integrate(nanf, 0.0, 1.0, 1e-9, 1e-9);
if let v = i7 { println("no!"); } else let e = err_of(i7) { println(e); }
