# math

> Package math.

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
