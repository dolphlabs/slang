# math/interp

> Package math/interp.

Values between known points: fee schedules, tiered rates, pricing and
yield curves, calibration tables.

```slang
import "math/interp";

let fees = interp.linear([0.0, 1000.0, 10000.0], [2.5, 1.8, 0.9]) ?? interp.empty();
fees.at(4200.0);                     // 1.48
let tier = interp.step([0.0, 100.0, 500.0], [10.0, 8.0, 5.0]) ?? interp.empty();
tier.at(250.0);                      // 8: the tier 250 falls in
let curve = interp.monotone(days, rates) ?? interp.empty();   // smooth, no overshoot
curve.at(45.0);
curve.slope(45.0);
curve.set_extrapolate(interp.Extrapolate.Linear);

let gr = interp.grid([1.0, 5.0], [0.0, 100.0, 500.0], prices);  // 2 x 3 values
if let g = gr { g.at(2.5, 140.0); }                           // bilinear
```

- `linear`, `step`, `monotone` (Fritsch-Carlson cubic with
  Fritsch-Butland slopes: smooth, through every point, and never
  overshooting, so monotone data stays monotone) and `spline` (the
  natural cubic spline: the smoothest curve, which can overshoot).
- `at`, `at_all`, `slope`; outside the knots `Extrapolate.Clamp` (the
  default), `Linear` or `None` (NaN).
- `grid(xs, ys, values)`: bilinear interpolation over a rectangular
  table, clamped at its edges.

Constructors check their input (equal lengths, at least one point,
strictly increasing finite xs) and return a `result`. A lookup is a
binary search, but a curve remembers its last segment, so ascending
queries cost O(1) each; that memory makes a curve unsafe to share
between tasks querying at once, so give each its own `copy()` (the knots
are shared, not copied).

## API

### `gc struct Curve`

### `fn empty() -> Curve`

A curve with no points, for `??` defaults: every value is NaN.

### `fn linear(xs: [float], ys: [float]) -> result[Curve, str]`

Straight lines between the points.

### `fn step(xs: [float], ys: [float]) -> result[Curve, str]`

A staircase: the value of the last point at or below x (the tier a quantity falls in). Before the first point: its value under Clamp, NaN under None.

### `fn monotone(xs: [float], ys: [float]) -> result[Curve, str]`

A monotone cubic (Fritsch and Carlson 1980, with Fritsch-Butland slopes): smooth, through every point, and never rising above or dipping below its neighbours, so a monotone table stays monotone. The safe choice for rates and prices.

### `fn spline(xs: [float], ys: [float]) -> result[Curve, str]`

The natural cubic spline: the smoothest curve through the points (a continuous second derivative, zero at the ends). It can overshoot between points; use monotone when that matters.

### `fn at(self: Curve, x: float) -> float`

The value at x.

### `fn at_all(self: Curve, xs: [float]) -> [float]`

The values at each of xs, in one pass when xs ascend.

### `fn slope(self: Curve, x: float) -> float`

The derivative at x (0 on a step curve, and outside the knots under Clamp).

### `fn set_extrapolate(self: Curve, mode: Extrapolate) -> Curve`

### `fn copy(self: Curve) -> Curve`

A curve over the same knots with its own lookup memory, for another task.

### `fn size(self: Curve) -> int`

### `gc struct Grid`

A table of values over a rectangular grid, read by bilinear interpolation: prices by (weight, distance), rates by (term, amount).

### `fn grid(xs: [float], ys: [float], values: [float]) -> result[Grid, str]`

A grid over ascending xs and ys with len(xs) * len(ys) values, row by row. Outside the grid the nearest edge value is used.

### `fn at(self: Grid, x: float, y: float) -> float`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
