# math

> Package math.

Constants, float functions, rounding, and checked integer arithmetic,
compiled to C's `<math.h>` and compiler builtins: `math.sqrt(x)` is the
instruction, not a call, and no function here is a safepoint.

```slang
import "math";

let r = math.sqrt(2.0);                  // 1.4142135623730951
let a = math.atan2(1.0, 1.0) * 4.0;      // math.pi
let x = math.clamp(v, 0.0, 1.0);
let n = math.round_to(3.14159, 2);       // 3.14
let i = math.floor_int(f) ?? 0;          // none for NaN, inf, out of range

// One function for every numeric type: T is the arguments' type.
let b: u8 = 250;
let s = math.checked_add(b, 10);         // opt[u8]: none, 260 does not fit
let w = math.saturating_add(b, 10);      // u8 255
let m = math.min(b, 100);                // u8: a literal takes b's type
let total = math.checked_mul(price, qty) ?? 0;   // money: overflow is none

math.div_floor(-7, 2);                   // -4, where -7 / 2 is -3
math.rem_euclid(-7, 3);                  // 2, never negative
math.gcd(48, 18);                        // 6
math.isqrt(99);                          // 9
math.mul_div(a, b, c);                   // a * b / c with no overflow in between
math.popcount(b);                        // 6, on b's own width
math.format_fixed(math.pi, 4);           // "3.1416"
```

**Every numeric argument of a call shares one type, T**, so `math.abs` of
an `i32` is an `i32`, and `math.checked_add` of two `u8`s is an
`opt[u8]`. T is what `a + b` of the arguments would be, except that a
literal takes the other arguments' type (`math.min(b, 100)` is a `u8`)
and must fit it. Float functions make an integer argument `float`;
integer functions reject a float. One name covers all ten numeric types
because slang has no overloading.

- **Constants:** `pi`, `tau`, `e`, `phi`, `sqrt2`, `sqrt3`, `ln2`, `ln10`,
  `log2e`, `log10e`, `inf`, `neg_inf`, `nan`, `max_float`, `min_normal`,
  `min_subnormal`, `epsilon`, `f32_max`, `f32_min_normal`, `f32_epsilon`,
  `max_int`, `min_int`, and `max_`/`min_` of each fixed-width integer.
- **Any number:** `abs`, `min`, `max`, `clamp`, `sign`.
- **Floats:** `is_nan`, `is_inf`, `is_finite`, `is_normal`, `signbit`,
  `copysign`, `nextafter`, `nextup`, `nextdown`, `ulp`, `frexp_mantissa`,
  `frexp_exponent`, `ldexp`, `ilogb`, `float_bits`/`float_from_bits`,
  `f32_bits`/`f32_from_bits`, `total_cmp` (a total order, NaN included),
  `approx_eq(a, b, rel_tol, abs_tol)`.
- **Rounding:** `floor`, `ceil`, `trunc`, `round` (half away from zero),
  `round_even` (half to even), `round_to(x, decimals)`,
  `round_to_multiple`, `fract`; `floor_int`, `ceil_int`, `round_int`,
  `trunc_int` give an `opt[int]`.
- **Powers and logs:** `sqrt`, `cbrt`, `hypot`, `pow`, `powi(x, n)`,
  `fma`, `fmod`, `remainder`, `mod_euclid`, `exp`, `exp2`, `expm1`, `log`,
  `log2`, `log10`, `log1p`, `log_base`.
- **Trigonometry:** `sin` … `atanh`, `atan2`, `to_radians`, `to_degrees`,
  `wrap_angle` (into (-pi, pi]), `sin_pi`/`cos_pi` (exact at integers and
  halves).
- **Special:** `gamma`, `lgamma`, `erf`, `erfc`, `erf_inv`, `beta`,
  `factorial`, `binomial`.
- **Interpolation:** `lerp`, `inverse_lerp`, `remap`, `smoothstep`,
  `smootherstep`.
- **Integers:** `checked_add`/`sub`/`mul`/`div`/`rem`/`neg`/`abs`/`pow`/`shl`
  (an `opt`), `saturating_add`/`sub`/`mul`, `wrapping_add`/`sub`/`mul`/`neg`/`pow`,
  `div_floor`, `div_ceil`, `div_euclid`, `rem_euclid`, `abs_diff`,
  `midpoint`, `isqrt`, `ilog2`, `ilog10`, `is_pow2`, `next_pow2`,
  `align_up`, `align_down`, `gcd`, `lcm`, `mul_div`, `mul_hi`.
- **Bits:** `popcount`, `leading_zeros`, `trailing_zeros`, `bit_len`,
  `rotate_left`, `rotate_right`, `swap_bytes`, `reverse_bits`.
- **Formatting:** `format(x, digits)` (significant digits),
  `format_fixed(x, decimals)`, `format_sci(x, digits)`. These are the
  only functions here that allocate; `format_fixed` rounds an exact tie
  to even, as C's printf does (`format_fixed(2.5, 0)` is `"2"`).

Floats follow IEEE 754: NaN propagates (through `min`, `max` and `clamp`
too), `-0.0` is kept and orders below `0.0`, and no float function
panics. An integer operation that can fail returns an `opt`: overflow, a
zero divisor, `MIN / -1`. `div_floor`, `div_ceil`, `div_euclid` and
`rem_euclid` panic on a zero divisor as `/` does, `isqrt` on a negative
argument, and `align_up`/`align_down` on an alignment that is not a
power of two. Programs link libm (`-lm`) whether or not they import
`math`; on macOS that is libSystem.

## API

### `math.abs(T) -> T`

### `math.min(T, T) -> T`

### `math.max(T, T) -> T`

### `math.clamp(T, T, T) -> T`

### `math.sign(T) -> T`

### `math.is_nan(T) -> bool`

### `math.is_inf(T) -> bool`

### `math.is_finite(T) -> bool`

### `math.is_normal(T) -> bool`

### `math.signbit(T) -> bool`

### `math.copysign(T, T) -> T`

### `math.nextafter(T, T) -> T`

### `math.nextup(T) -> T`

### `math.nextdown(T) -> T`

### `math.ulp(T) -> T`

### `math.frexp_mantissa(T) -> T`

### `math.frexp_exponent(T) -> int`

### `math.ldexp(T, int) -> T`

### `math.ilogb(T) -> int`

### `math.float_bits(float) -> u64`

### `math.float_from_bits(int) -> float`

### `math.f32_bits(float) -> u32`

### `math.f32_from_bits(int) -> f32`

### `math.total_cmp(T, T) -> int`

### `math.approx_eq(T, T, T, T) -> bool`

### `math.floor(T) -> T`

### `math.ceil(T) -> T`

### `math.trunc(T) -> T`

### `math.round(T) -> T`

### `math.round_even(T) -> T`

### `math.round_to(T, int) -> T`

### `math.round_to_multiple(T, T) -> T`

### `math.fract(T) -> T`

### `math.floor_int(float) -> opt[int]`

### `math.ceil_int(float) -> opt[int]`

### `math.round_int(float) -> opt[int]`

### `math.trunc_int(float) -> opt[int]`

### `math.sqrt(T) -> T`

### `math.cbrt(T) -> T`

### `math.hypot(T, T) -> T`

### `math.pow(T, T) -> T`

### `math.powi(T, int) -> T`

### `math.fma(T, T, T) -> T`

### `math.fmod(T, T) -> T`

### `math.remainder(T, T) -> T`

### `math.mod_euclid(T, T) -> T`

### `math.exp(T) -> T`

### `math.exp2(T) -> T`

### `math.expm1(T) -> T`

### `math.log(T) -> T`

### `math.log2(T) -> T`

### `math.log10(T) -> T`

### `math.log1p(T) -> T`

### `math.log_base(T, T) -> T`

### `math.sin(T) -> T`

### `math.cos(T) -> T`

### `math.tan(T) -> T`

### `math.asin(T) -> T`

### `math.acos(T) -> T`

### `math.atan(T) -> T`

### `math.atan2(T, T) -> T`

### `math.sinh(T) -> T`

### `math.cosh(T) -> T`

### `math.tanh(T) -> T`

### `math.asinh(T) -> T`

### `math.acosh(T) -> T`

### `math.atanh(T) -> T`

### `math.to_radians(T) -> T`

### `math.to_degrees(T) -> T`

### `math.wrap_angle(T) -> T`

### `math.sin_pi(T) -> T`

### `math.cos_pi(T) -> T`

### `math.gamma(T) -> T`

### `math.lgamma(T) -> T`

### `math.erf(T) -> T`

### `math.erfc(T) -> T`

### `math.erf_inv(T) -> T`

### `math.beta(T, T) -> T`

### `math.factorial(int) -> float`

### `math.binomial(int, int) -> float`

### `math.lerp(T, T, T) -> T`

### `math.inverse_lerp(T, T, T) -> T`

### `math.remap(T, T, T, T, T) -> T`

### `math.smoothstep(T, T, T) -> T`

### `math.smootherstep(T, T, T) -> T`

### `math.checked_add(T, T) -> opt[T]`

### `math.checked_sub(T, T) -> opt[T]`

### `math.checked_mul(T, T) -> opt[T]`

### `math.checked_div(T, T) -> opt[T]`

### `math.checked_rem(T, T) -> opt[T]`

### `math.checked_neg(T) -> opt[T]`

### `math.checked_abs(T) -> opt[T]`

### `math.checked_pow(T, int) -> opt[T]`

### `math.checked_shl(T, int) -> opt[T]`

### `math.saturating_add(T, T) -> T`

### `math.saturating_sub(T, T) -> T`

### `math.saturating_mul(T, T) -> T`

### `math.wrapping_add(T, T) -> T`

### `math.wrapping_sub(T, T) -> T`

### `math.wrapping_mul(T, T) -> T`

### `math.wrapping_neg(T) -> T`

### `math.wrapping_pow(T, int) -> T`

### `math.div_floor(T, T) -> T`

### `math.div_ceil(T, T) -> T`

### `math.div_euclid(T, T) -> T`

### `math.rem_euclid(T, T) -> T`

### `math.abs_diff(T, T) -> u64`

### `math.midpoint(T, T) -> T`

### `math.isqrt(T) -> T`

### `math.ilog2(T) -> opt[int]`

### `math.ilog10(T) -> opt[int]`

### `math.is_pow2(T) -> bool`

### `math.next_pow2(T) -> opt[T]`

### `math.align_up(T, T) -> opt[T]`

### `math.align_down(T, T) -> T`

### `math.gcd(T, T) -> T`

### `math.lcm(T, T) -> opt[T]`

### `math.mul_div(T, T, T) -> opt[T]`

### `math.mul_hi(T, T) -> T`

### `math.popcount(T) -> int`

### `math.leading_zeros(T) -> int`

### `math.trailing_zeros(T) -> int`

### `math.bit_len(T) -> int`

### `math.rotate_left(T, int) -> T`

### `math.rotate_right(T, int) -> T`

### `math.swap_bytes(T) -> T`

### `math.reverse_bits(T) -> T`

### `math.format(float, int) -> str`

### `math.format_fixed(float, int) -> str`

### `math.format_sci(float, int) -> str`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
