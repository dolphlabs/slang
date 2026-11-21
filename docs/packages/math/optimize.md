# math/optimize

> Package math/optimize.

Solving f(x) = 0, minimising f and integrating it, in one variable:
implied rates, break-even points, the price that maximises revenue, the
area under a curve. Written in slang; every routine stops at a tolerance
or a fixed budget of evaluations and says which in its error, so none
can loop forever whatever f returns (a NaN is an error, not an answer).

```slang
import "math/optimize";

fn f(x: float) -> float { return x * x - 2.0; }
let r = optimize.brent(f, 0.0, 2.0, 1e-12);          // result[Root, str]
(r ?? optimize.no_root()).x;                         // 1.41421356...

// slang has no closures: a function that needs data takes it second
struct Loan { pv: float, pmt: float, n: int }
fn gap(rate: float, l: Loan) -> float { ... }
optimize.brent_with(gap, loan, 0.0001, 0.1, 1e-12);

optimize.brent_min(f, 0.0, 10.0, 1e-9);              // result[Min, str]
optimize.integrate(f, 0.0, math.inf, 1e-10, 1e-10);  // result[Integral, str]
```

- **Roots:** `brent` (Brent's zeroin: superlinear, never slower than
  bisection; the default), `bisect`, `newton` (needs the derivative;
  fast near a simple root, can diverge from a poor start),
  `newton_safe` (Newton kept inside a bracket, bisecting when a step
  would leave it), `bracket` (widens a guess until f changes sign).
- **Minima** of a unimodal f on [a, b]: `brent_min` (parabolic steps with
  golden-section fallbacks, as scipy's `fminbound`), `golden`. x is good
  to about sqrt(machine epsilon) relative, the limit for any minimiser.
- **Integrals:** `integrate` (adaptive 7/15-point Gauss-Kronrod as
  QUADPACK's QAG, with infinite bounds mapped onto finite ones) and
  `simpson` (adaptive, finite bounds). Each returns the value, an error
  estimate and the number of evaluations.

Each routine has a `_with` form whose f takes a context value of any type
as its second argument, for the data a closure would carry.

## API

### `struct Root`

A root: f(x) is (near) zero. fx is f at x; evals counts calls to f.

### `struct Min`

A minimum of f on an interval: f(x) = fx.

### `struct Integral`

An integral, with an estimate of its absolute error.

### `struct Bracket`

A bracket [lo, hi] with f(lo) and f(hi) of opposite signs (or one 0).

### `fn no_root() -> Root`

NaNs, for `??` defaults: (r ?? optimize.no_root()).x is NaN on error.

### `fn no_min() -> Min`

### `fn no_integral() -> Integral`

### `fn bracket(f: fn(float) -> float, lo: float, hi: float) -> result[Bracket, str]`

Widens [lo, hi] geometrically (by 1.6 each side, up to 50 times) until f changes sign across it.

### `fn bracket_with[C](f: fn(float, C) -> float, ctx: C, lo: float, hi: float) -> result[Bracket, str]`

### `fn bisect(f: fn(float) -> float, lo: float, hi: float, tol: float) -> result[Root, str]`

Bisection: halves [lo, hi] until it is within tol. Slow (one bit per step) but certain; prefer brent.

### `fn bisect_with[C](f: fn(float, C) -> float, ctx: C, lo: float, hi: float, tol: float) -> result[Root, str]`

### `fn brent(f: fn(float) -> float, lo: float, hi: float, tol: float) -> result[Root, str]`

Brent's method (Brent 1973, the zeroin of netlib): inverse quadratic interpolation and secant steps, falling back to bisection whenever they would not shrink the bracket fast enough. Superlinear on smooth f, never slower than bisection. The default root finder.

### `fn brent_with[C](f: fn(float, C) -> float, ctx: C, lo: float, hi: float, tol: float) -> result[Root, str]`

### `fn newton(f: fn(float) -> float, df: fn(float) -> float, x0: float, tol: float) -> result[Root, str]`

Newton's method from x0 with derivative df: quadratic convergence near a simple root, but it can diverge from a poor start. Use newton_safe when a bracket is known.

### `fn newton_with[C, D](f: fn(float, C) -> float, df: fn(float, D) -> float, ctx: C, x0: float, tol: float, dctx: D) -> result[Root, str]`

newton with data: f and df each take ctx. (The derivative's own data is passed as dctx, so f and df can differ in what they need.)

### `fn newton_safe(f: fn(float) -> float, df: fn(float) -> float, lo: float, hi: float, tol: float) -> result[Root, str]`

Safeguarded Newton (rtsafe): Newton steps that stay inside a bracket [lo, hi] where f changes sign, with bisection whenever a step would leave it or shrink it too slowly. Fast and certain.

### `fn newton_safe_with[C, D](f: fn(float, C) -> float, df: fn(float, D) -> float, ctx: C, lo: float, hi: float, tol: float, dctx: D) -> result[Root, str]`

### `fn golden(f: fn(float) -> float, a: float, b: float, tol: float) -> result[Min, str]`

Golden-section search for the minimum of a unimodal f on [a, b]: the interval shrinks by 0.618 per evaluation. Needs no derivative and no smoothness; prefer brent_min for smooth f.

### `fn golden_with[C](f: fn(float, C) -> float, ctx: C, a: float, b: float, tol: float) -> result[Min, str]`

### `fn brent_min(f: fn(float) -> float, a: float, b: float, tol: float) -> result[Min, str]`

Brent's minimisation (Brent 1973, localmin; scipy's fminbound): parabolic interpolation through the best three points, golden-section steps when a parabola is not trustworthy. On [a, b], for unimodal f.

### `fn brent_min_with[C](f: fn(float, C) -> float, ctx: C, a0: float, b0: float, tol: float) -> result[Min, str]`

### `fn simpson(f: fn(float) -> float, a: float, b: float, tol: float) -> result[Integral, str]`

Adaptive Simpson's rule: splits wherever the two halves disagree with the whole by more than tol (absolute), with Richardson's correction. For smooth f on a finite interval.

### `fn simpson_with[C](f: fn(float, C) -> float, ctx: C, a: float, b: float, tol: float) -> result[Integral, str]`

### `fn integrate(f: fn(float) -> float, a: float, b: float, abs_tol: float, rel_tol: float) -> result[Integral, str]`

Adaptive Gauss-Kronrod (7-point Gauss, 15-point Kronrod, as QUADPACK's QAG): the interval with the largest error estimate is halved until the total error is within max(abs_tol, rel_tol * |integral|). Infinite bounds are mapped onto a finite interval (x = t / (1 - t^2) and its one-sided forms). The general-purpose integrator.

### `fn integrate_with[C](f: fn(float, C) -> float, ctx: C, a: float, b: float, abs_tol: float, rel_tol: float) -> result[Integral, str]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
