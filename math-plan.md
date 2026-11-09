# The math library: plan

**Status (2026-11-09):** phases 0 to 2 have landed: `math` (#477, #485),
`math/stats` and `math/numtheory` (#481, #483). Phases 3 to 5
(`math/complex`, `math/linalg`, `math/big`) are not started. The text
below is the plan as written, before any of it was built.

When this plan was written, slang had no math. There is no `sqrt`, `floor` or `abs`, and no
checked integer arithmetic, so programs hand-roll it: `say` writes its own
`checked_add`/`checked_mul` (`ledger/domain/money.sl`), `gcd`
(`portfolio/domain/valuation.sl`), `clamp` and `abs_int`
(`treasury/domain/quoting.sl`). This plan covers the whole library:
scalar functions, integer and number theory, statistics, big numbers,
complex numbers and linear algebra. It is laid out as Go-style
subpackages, so a program compiles only what it imports.

| Import | Kind | What it holds |
|---|---|---|
| `math` | native (C, `<math.h>`) | constants, float functions, rounding, integer and bit operations |
| `math/numtheory` | slang source | primes, modular arithmetic, factorization |
| `math/stats` | slang source | descriptive statistics, streaming accumulators, regression, distributions |
| `math/complex` | slang source | complex numbers (and FFT, phase 5) |
| `math/linalg` | slang source | fixed-size vectors, matrices and quaternions; dense matrices and decompositions |
| `math/big` | slang source | arbitrary-precision `Int` and `Rat` |

`rand` (seeded, non-cryptographic) and `decimal` (money) stay separate
packages, as `missing-libraries.md` has them. `decimal` can build on
`big.Int`, and sampling from `stats` distributions takes a `rand` source.

---

## Phase 0: what the compiler and runtime need first

Four findings from probing the current compiler (slang 0.2.5) decide the
design.

1. **`extern fn` is the wrong road for core math.**
   `extern fn sqrt(x: float) -> float;` compiles to
   `sl_x_sqrt(...) __asm__("sqrt")`. C compilers recognize a builtin by
   its declared name, not its asm label, so this is probably a real
   function call every time: no single `sqrt` instruction, no constant
   folding, no vectorization. A call that has a live GC value in scope
   also gets a full safepoint bracket. `cbrt(8.0)` did, and that is the
   ~16 ns per call `native_is_leaf` was written to avoid. So `math` is a
   **native package**: `runtime/sl_math.c` calls `sqrt` directly through
   `<math.h>`, and every function goes on the leaf list, since none of
   them allocates.

2. **Native signatures are single-type; `abs`, `min` and `max` need every
   numeric type.** `NatSig` takes `NA_I64`/`NA_F64` and returns one fixed
   type. Add **`NA_NUM`** (any numeric type) with a return of "same as
   argument 0". Codegen then picks the C function by the argument's type
   (`math.abs(x: i32)` → `sl_math_abs_i32`), the way `len` dispatches on
   what it is given. This one feature covers `abs`, `min`, `max`, `clamp`,
   `sign`, every checked, saturating and wrapping operation, and the bit
   operations on every width. Without it each function needs eight
   spellings (`abs_i8` … `abs_u64`), and slang has no overloading to hide
   them.

3. **Linking libm.** On Linux, glibc needs `-lm` for most of `<math.h>`.
   Add `want_math` alongside `want_sql`/`want_compress` in
   `src/main.c`, adding ` -lm` when `math` is imported. macOS needs
   nothing.

4. **Float printing loses precision. This is a behavior change and needs
   your decision.** `println(t)` printed `5.00002e+11` for
   500002000000.0: `to_str(float)` uses six significant digits (`%g`), so
   printing a float and parsing it back does not give the same number.
   Proposal: `to_str(float)` prints the **shortest text that parses back
   to the same float** (what Go, Rust, JS and Python do), and
   `math.format(x, digits)` / `math.format_fixed(x, decimals)` give
   explicit control. This changes the output of existing programs that
   print floats, so it would go in its own release note.

The subpackages need no compiler change: `import "math/stats"` already
resolves to `stdlib/math/stats` even while `math` itself is native,
because native matching is by exact name.

There is no operator overloading, so `big.Int`, `Vec3`, `Complex` and
`Matrix` use methods (`a.add(b)`, `m.mul(v)`). Generic functions are
instantiated per type, so `stats.mean(xs)` works on `[int]`, `[f32]` and
`[float]` from one source.

---

## Phase 1: `math` (native)

Every function is a leaf: no allocation and no safepoint. It follows IEEE
754: NaN propagates, `-0.0` is kept, and nothing panics on a float input.
Integer operations that can fail return `opt[T]` instead of panicking.

### Constants (`pub let`)
- `pi`, `tau`, `e`, `phi`, `sqrt2`, `sqrt3`, `ln2`, `ln10`, `log2e`, `log10e`
- `inf`, `neg_inf`, `nan`
- `max_float`, `min_normal`, `min_subnormal`, `epsilon` (and `f32_` versions)
- `max_i8` … `max_i64`, `min_i8` … `min_i64`, `max_u8` … `max_u64`

### Classification and representation
- `is_nan`, `is_inf`, `is_finite`, `is_normal`, `signbit`
- `copysign`, `nextafter`, `nextup`, `nextdown`, `ulp`
- `frexp_mantissa`, `frexp_exponent`, `ldexp`, `ilogb`, `scalbn`
  (two functions instead of one returning a pair)
- `float_bits(x) -> u64`, `float_from_bits(u64)`, and `f32_bits`/`f32_from_bits`

### Rounding
- `floor`, `ceil`, `trunc`, `round` (half away from zero), `round_even` (banker's)
- `round_to(x, decimals)` and `round_to_multiple(x, m)`
- `fract`, `int_part`
- `floor_int`, `ceil_int`, `round_int` and `trunc_int` return `opt[int]`
  (`none` for NaN, infinities and out of range; `as` silently truncates)

### Basic and power functions
- `abs`, `min`, `max`, `clamp`, `sign` (all `NA_NUM`)
- `sqrt`, `cbrt`, `hypot`, `pow`, `powi(x, n: int)`, `fma`
- `fmod`, `remainder`, `mod_euclid` (result never negative)

### Exponentials and logarithms
- `exp`, `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p`, `log_base(x, b)`

### Trigonometry
- `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`
- `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`
- `to_radians`, `to_degrees`, `wrap_angle` (to (-pi, pi]), `sin_pi`, `cos_pi`

### Special functions
- `gamma`, `lgamma`, `erf`, `erfc`, `erf_inv`, `beta`
- `factorial(n) -> float`, `binomial(n, k) -> float`

### Interpolation and comparison
- `lerp`, `inverse_lerp`, `remap`, `smoothstep`, `smootherstep`
- `approx_eq(a, b, rel_tol, abs_tol)` (like Python's `math.isclose`)
- `total_cmp(a, b) -> int` (a total order on floats, NaN included, for sorting)

### Integer arithmetic (every width, `NA_NUM`)
- `checked_add`, `checked_sub`, `checked_mul`, `checked_div`, `checked_rem`,
  `checked_neg`, `checked_pow`, `checked_shl`, all `-> opt[T]`
  (`__builtin_*_overflow`; this replaces `say`'s money helpers)
- `saturating_add`, `saturating_sub`, `saturating_mul`
- `wrapping_add`, `wrapping_sub`, `wrapping_mul` (the default today; named
  so code can say it means it)
- `div_floor`, `div_ceil`, `div_euclid`, `rem_euclid`, `abs_diff`, `midpoint`
- `ipow`, `isqrt`, `ilog2`, `ilog10`
- `is_pow2`, `next_pow2`, `align_up`, `align_down`
- `gcd`, `lcm`
- `mul_div(a, b, c)`: `a*b/c` without intermediate overflow (128-bit inside)
- `mul_hi(a, b)`: the high 64 bits of a 64×64 product (also used by `big`)

### Bits (every width)
- `popcount`, `leading_zeros`, `trailing_zeros`, `bit_len`
- `rotate_left`, `rotate_right`, `swap_bytes`, `reverse_bits`

### Formatting (if Phase 0's item 4 is accepted)
- `format(x, digits)`, `format_fixed(x, decimals)`, `format_sci(x, digits)`

---

## Phase 2: `math/numtheory` and `math/stats`

### `math/numtheory`
- `mod_pow(b, e, m)`, `mod_inv(a, m) -> opt[int]`, `mod_mul` (via `mul_hi`, no overflow)
- `ext_gcd(a, b) -> Bezout { g, x, y }`
- `is_prime(n: u64)`: deterministic Miller-Rabin, using the 7-base set proven for 64-bit
- `next_prime`, `prev_prime`, `primes_below(n) -> [int]` (segmented sieve)
- `factorize(n) -> [Factor { p, k }]` (trial division plus Pollard's rho)
- `divisors`, `totient`, `crt(residues, moduli) -> opt[int]`
- `binomial_mod(n, k, p)`, `fibonacci(n) -> opt[int]`

### `math/stats` (generic over int and float lists)
- **Sums:** `sum` (Neumaier-compensated for floats), `product`
- **Center:** `mean`, `weighted_mean`, `geometric_mean`, `harmonic_mean`,
  `median`, `mode`
- **Spread:** `variance`, `stddev` (sample and population), `range`, `mad`
- **Quantiles:** `quantile(xs, q)` (default type 7, the R/NumPy default, with
  the others selectable), `percentile`, `quartiles`, `iqr`
- **Shape:** `skewness`, `kurtosis`, `zscore`
- **Relation:** `covariance`, `correlation` (Pearson), `spearman`
- **Regression:** `linear_regression(xs, ys) -> Fit { slope, intercept, r2 }`
- **Binning:** `histogram(xs, bins) -> Histogram { edges, counts }`
- **Streaming:**
  - `Running`: Welford accumulator with count, mean, variance, min and
    max, plus `merge`, so tasks can each accumulate and combine (a
    request-latency monitor without keeping samples)
  - `Ewma`: exponentially weighted moving average
  - `Quantiles`: streaming quantile sketch, t-digest, mergeable (for
    p50/p99 of a live server)
- **Distributions** (pdf/pmf, cdf, quantile):
  - `Normal`, `Uniform`, `Exponential`, `LogNormal`, `Poisson`,
    `Binomial`
  - `StudentT`, `ChiSquared`, `Gamma` and `Beta` in phase 5
  - `sample(rng)` once `rand` exists

---

## Phase 3: `math/complex` and fixed-size `math/linalg`

### `math/complex`
- `Complex { re, im }` with `add`, `sub`, `mul`, `div` (Smith's algorithm,
  no needless overflow), `neg`, `conj`, `scale`
- `abs` (hypot), `arg`, `from_polar`, `to_polar`
- `exp`, `log`, `sqrt`, `pow`, and the trigonometric and hyperbolic functions
- `is_nan`, `is_inf`, `approx_eq`, `to_str`, `parse`

### `math/linalg`, fixed size (value structs, no allocation)
- **Vectors:** `Vec2`, `Vec3`, `Vec4`
  - `add`, `sub`, `scale`, `dot`, `cross`, `length`, `distance`,
    `normalize`, `lerp`, `reflect`, `project`, `angle`, `min`, `max`,
    `approx_eq`
- **Matrices:** `Mat2`, `Mat3`, `Mat4` (column-major, as OpenGL uses)
  - `mul`, `mul_vec`, `transpose`, `determinant`, `inverse -> opt[Mat]`
  - `identity`, `translate`, `rotate`, `scale`, `look_at`, `perspective`,
    `ortho`
- **Quaternions:** `Quat`
  - `from_axis_angle`, `mul`, `rotate_vec`, `slerp`, `to_mat`, `normalize`

---

## Phase 4: `math/big`

- **`Int`:** sign plus magnitude, with `u32` limbs in a `[u32]`. 64-bit
  products are native slang. Move to `u64` limbs on `math.mul_hi` once it
  is measured.
  - **Arithmetic:** `add`, `sub`, `mul` (schoolbook, Karatsuba above about
    40 limbs), `div_rem`/`div_floor`/`mod` (Knuth algorithm D), `pow`,
    `mod_pow`, `mod_inv`, `gcd`, `sqrt`
  - **Comparison:** `cmp`, `sign`, `is_zero`
  - **Bits:** `and`, `or`, `xor`, `not` (two's-complement semantics, as in
    Go), `shl`, `shr`, `bit_len`, `bit`
  - **Conversion:** `from_int`, `to_int -> opt[int]`, `to_float`,
    `parse(s, base) -> result`, `to_str(base)` for bases 2..36,
    `to_bytes`/`from_bytes` big-endian
  - **Interop:** `json` and Postgres `numeric` round-trips
- **`Rat`:** an exact fraction of two `Int`s, always reduced
  - `add`, `sub`, `mul`, `div`, `cmp`, `floor`, `round`, `to_float`
  - `parse("3/4")`, `parse("0.125")`
- **`Float`** (arbitrary-precision binary float) is deferred: little
  backend code needs it, and `decimal` covers money.

---

## Phase 5: depth

- **`linalg` dense:**
  - `Vector` and `Matrix { rows, cols, data: [float] }` (row-major)
  - `matmul` (cache-blocked), `transpose`, `add`, `scale`, `norm`
    (1, 2, inf, Frobenius)
  - decompositions: `lu` (partial pivoting), `qr` (Householder),
    `cholesky`, `eigen_symmetric` (Jacobi), `svd`
  - `solve`, `inverse`, `determinant`, `least_squares`, `rank`
- **`complex`:** `fft`/`ifft` (radix-2 plus Bluestein for any length),
  `convolve`
- **`stats`:** the remaining distributions, `t_test`, `chi_square_test`,
  bootstrap confidence intervals
- **`numtheory`:** Montgomery multiplication for `big` `mod_pow`

---

## How each phase is built

- **Tests:** each function is tested on its edge cases: NaN, ±inf, ±0,
  subnormals, `min_i64`, `-1`, and each width's maximum. Floats are
  checked against libm and published tables within a stated ULP bound.
  Integer functions are checked exhaustively on `i8`/`u8` and by property
  (`checked_mul` against `big.Int`) on the wide types.
  - `stats` is checked against NumPy/R results committed as fixtures.
  - `big` is checked by round-trip and cross-check properties with fixed
    seeds, so tests stay deterministic.
- **Benchmarks:** compared with C and Go for the hot paths: `sqrt` in a
  loop, `checked_mul`, `stats.Running`, `big` multiplication and
  `mod_pow`, `Mat4` multiplication, `lu` on 256×256.
- **Docs:** every `pub` item is documented in the comment above it (the
  `www/` standard), plus a README section per package and examples in
  `llms-small.md`.
- **Order:** one PR per phase, each with the suite green on Linux and
  macOS before the next starts. Phase 1 is the largest and unblocks the
  rest, because `isqrt`, `mul_hi`, `gcd` and `NA_NUM` are used everywhere
  after it.
- **`say`:** once phase 1 merges, its hand-written `checked_add`,
  `checked_mul`, `gcd`, `clamp` and `abs_int` are replaced by `math`.

## Decisions needed

1. **Float printing** (Phase 0, item 4): switch `to_str(float)` to the
   shortest round-trip text, which changes existing output, or leave it and
   only add `math.format*`. Recommended: switch.
2. **`NA_NUM`** (Phase 0, item 2): one generic native kind, or a typed name
   per width. Recommended: `NA_NUM`.
