// The math package: each family on the edge cases that decide whether it is
// right -- NaN, the infinities, -0.0, each width's MIN and MAX, a zero
// divisor -- and T, the one type a call's numeric arguments share
// (math.abs on an i32 is an i32; a literal takes the other arguments' type).
import "math";

fn show(label: str, v: str) {
    println(label + " " + v);
}

fn opt_i(o: opt[int]) -> str {
    guard let v = o else { return "none"; }
    return to_str(v);
}

fn opt_u8(o: opt[u8]) -> str {
    guard let v = o else { return "none"; }
    return to_str(v);
}

fn opt_i8(o: opt[i8]) -> str {
    guard let v = o else { return "none"; }
    return to_str(v);
}

fn opt_u64(o: opt[u64]) -> str {
    guard let v = o else { return "none"; }
    return to_str(v);
}

// --- T ---
let small: i32 = -7;
let byte: u8 = 250;
let tiny: i8 = -128;
let f: f32 = 2.0;
let abs_small: i32 = math.abs(small);          // an i32, not an int
let clamped: u8 = math.clamp(byte, 0, 100);    // literals take u8
show("abs i32", to_str(abs_small));
show("clamp u8", to_str(clamped));
show("min mixed", to_str(math.min(small, 3)));
show("sqrt int", to_str(math.sqrt(2)));       // an int argument makes it float
let rf: f32 = math.sqrt(f);
show("sqrt f32", to_str(rf));
show("sign", to_str(math.sign(-3)) + " " + to_str(math.sign(0)) + " " + to_str(math.sign(byte)));

// --- constants ---
show("pi", to_str(math.pi));
show("e", to_str(math.e));
show("max_i8", to_str(math.max_i8) + " " + to_str(math.min_i8));
show("max_u64", to_str(math.max_u64));
show("min_int", to_str(math.min_int));
show("epsilon", to_str(math.epsilon));

// --- floats: classification and IEEE edges ---
let z = 0.0;
let nz = -0.0;
show("nan", to_str(math.is_nan(math.nan)) + " " + to_str(math.is_nan(1.0)));
show("inf", to_str(math.is_inf(math.inf)) + " " + to_str(math.is_finite(math.inf)));
show("signbit -0", to_str(math.signbit(nz)) + " " + to_str(math.signbit(z)));
show("min -0", to_str(math.signbit(math.min(z, nz))) + " " + to_str(math.signbit(math.max(nz, z))));
show("min nan", to_str(math.is_nan(math.min(1.0, math.nan))));
show("clamp nan", to_str(math.is_nan(math.clamp(math.nan, 0.0, 1.0))));
show("abs -0", to_str(math.signbit(math.abs(nz))));
show("copysign", to_str(math.copysign(3.0, -1.0)));
show("nextup 1", to_str(math.nextup(1.0) - 1.0));
show("ulp 1", to_str(math.ulp(1.0)));
show("ulp max", to_str(math.ulp(math.max_float)));
show("frexp", to_str(math.frexp_mantissa(8.0)) + " " + to_str(math.frexp_exponent(8.0)));
show("ldexp", to_str(math.ldexp(0.5, 4)));
show("total_cmp", to_str(math.total_cmp(nz, z)) + " " + to_str(math.total_cmp(math.nan, math.inf)) + " " + to_str(math.total_cmp(1.0, 1.0)));
show("approx_eq", to_str(math.approx_eq(0.1 + 0.2, 0.3, 0.000000001, 0.0)) + " " + to_str(math.approx_eq(1.0, 1.1, 0.01, 0.0)));
show("float_bits", to_str(math.float_bits(1.0)) + " " + to_str(math.float_from_bits(4607182418800017408)));
show("f32_bits", to_str(math.f32_bits(1.0)));

// --- rounding ---
show("round", to_str(math.round(2.5)) + " " + to_str(math.round(-2.5)));
show("round_even", to_str(math.round_even(2.5)) + " " + to_str(math.round_even(3.5)) + " " + to_str(math.round_even(-2.5)));
show("floor ceil trunc", to_str(math.floor(-1.5)) + " " + to_str(math.ceil(-1.5)) + " " + to_str(math.trunc(-1.5)));
show("round_to", to_str(math.round_to(3.14159, 2)) + " " + to_str(math.round_to(1234.5, -2)));
show("round_to_multiple", to_str(math.round_to_multiple(17.0, 5.0)));
show("fract", to_str(math.fract(-1.25)));
show("floor_int", opt_i(math.floor_int(-1.5)) + " " + opt_i(math.floor_int(math.nan)) + " " + opt_i(math.round_int(math.inf)));
show("trunc_int big", opt_i(math.trunc_int(9223372036854775807.0)));

// --- powers, logs, trig ---
show("pow", to_str(math.pow(2.0, 10.0)) + " " + to_str(math.powi(2.0, -2)) + " " + to_str(math.powi(3.0, 5)));
show("cbrt hypot", to_str(math.cbrt(27.0)) + " " + to_str(math.hypot(3.0, 4.0)));
show("fmod", to_str(math.fmod(-7.0, 3.0)) + " " + to_str(math.mod_euclid(-7.0, 3.0)) + " " + to_str(math.remainder(7.0, 4.0)));
show("log", to_str(math.log(math.e)) + " " + to_str(math.log2(8.0)) + " " + to_str(math.log10(1000.0)) + " " + to_str(math.log_base(81.0, 3.0)));
show("exp", to_str(math.exp(0.0)) + " " + to_str(math.exp2(10.0)) + " " + to_str(math.expm1(0.0)));
show("trig", to_str(math.sin(0.0)) + " " + to_str(math.cos(0.0)) + " " + to_str(math.atan2(1.0, 1.0)));
show("sin_pi", to_str(math.sin_pi(1.0)) + " " + to_str(math.sin_pi(0.5)) + " " + to_str(math.cos_pi(0.5)) + " " + to_str(math.cos_pi(1.0)));
show("degrees", to_str(math.to_degrees(math.pi)) + " " + to_str(math.to_radians(180.0)));
show("wrap_angle", to_str(math.wrap_angle(math.pi)) + " " + to_str(math.wrap_angle(-math.pi)) + " " + to_str(math.wrap_angle(0.5)));

// --- special functions ---
show("gamma", to_str(math.gamma(5.0)) + " " + to_str(math.lgamma(1.0)));
show("erf", to_str(math.erf(0.0)) + " " + to_str(math.erfc(0.0)));
show("erf_inv", to_str(math.approx_eq(math.erf(math.erf_inv(0.7)), 0.7, 0.000000000000001, 0.0)) + " " + to_str(math.is_inf(math.erf_inv(1.0))) + " " + to_str(math.is_nan(math.erf_inv(2.0))));
show("beta", to_str(math.approx_eq(math.beta(2.0, 3.0), 1.0 / 12.0, 0.000000000001, 0.0)));
show("factorial", to_str(math.factorial(10)) + " " + to_str(math.factorial(22)) + " " + to_str(math.is_inf(math.factorial(171))));
show("binomial", to_str(math.binomial(52, 5)) + " " + to_str(math.binomial(5, 7)) + " " + to_str(math.binomial(60, 30)));

// --- interpolation ---
show("lerp", to_str(math.lerp(10.0, 20.0, 0.25)) + " " + to_str(math.lerp(1.0, 3.0, 1.0)));
show("inverse_lerp", to_str(math.inverse_lerp(10.0, 20.0, 15.0)));
show("remap", to_str(math.remap(5.0, 0.0, 10.0, 100.0, 200.0)));
show("smoothstep", to_str(math.smoothstep(0.0, 1.0, 0.5)) + " " + to_str(math.smoothstep(0.0, 1.0, 2.0)) + " " + to_str(math.smootherstep(0.0, 1.0, 0.25)));

// --- integers: checked, saturating, wrapping ---
show("checked_add u8", opt_u8(math.checked_add(byte, 5)) + " " + opt_u8(math.checked_add(byte, 6)));
show("checked_sub i8", opt_i8(math.checked_sub(tiny, 1)) + " " + opt_i8(math.checked_sub(tiny, -1)));
show("checked_mul", opt_i(math.checked_mul(math.max_int, 2)) + " " + opt_i(math.checked_mul(3037000499, 3037000499)));
show("checked_div", opt_i(math.checked_div(7, 0)) + " " + opt_i(math.checked_div(math.min_int, -1)) + " " + opt_i(math.checked_div(-7, 2)));
show("checked_rem", opt_i(math.checked_rem(math.min_int, -1)) + " " + opt_i(math.checked_rem(-7, 3)));
show("checked_neg", opt_i8(math.checked_neg(tiny)) + " " + opt_u8(math.checked_neg(byte)));
show("checked_abs", opt_i8(math.checked_abs(tiny)));
show("checked_pow", opt_i(math.checked_pow(2, 62)) + " " + opt_i(math.checked_pow(2, 63)) + " " + opt_i(math.checked_pow(-1, -3)) + " " + opt_i(math.checked_pow(0, -1)));
show("checked_shl", opt_u8(math.checked_shl(byte, 0)) + " " + opt_u8(math.checked_shl(byte, 1)) + " " + opt_i(math.checked_shl(1, 62)) + " " + opt_i(math.checked_shl(1, 63)) + " " + opt_i(math.checked_shl(1, 64)));
show("saturating", to_str(math.saturating_add(byte, 10)) + " " + to_str(math.saturating_sub(tiny, 1)) + " " + to_str(math.saturating_mul(math.min_int, 2)));
show("wrapping", to_str(math.wrapping_add(byte, 10)) + " " + to_str(math.wrapping_neg(tiny)) + " " + to_str(math.wrapping_pow(3, 41)));
show("div_floor", to_str(math.div_floor(-7, 2)) + " " + to_str(math.div_floor(7, -2)) + " " + to_str(math.div_floor(math.min_int, -1)));
show("div_ceil", to_str(math.div_ceil(7, 2)) + " " + to_str(math.div_ceil(-7, 2)) + " " + to_str(math.div_ceil(byte, 100)));
show("euclid", to_str(math.div_euclid(-7, 3)) + " " + to_str(math.rem_euclid(-7, 3)) + " " + to_str(math.div_euclid(-7, -3)) + " " + to_str(math.rem_euclid(-7, -3)) + " " + to_str(math.rem_euclid(math.min_int, -1)));
show("abs_diff", to_str(math.abs_diff(math.min_int, math.max_int)) + " " + to_str(math.abs_diff(byte, 0)));
show("midpoint", to_str(math.midpoint(math.max_int, math.max_int - 2)) + " " + to_str(math.midpoint(-3, 0)) + " " + to_str(math.midpoint(byte, 255)));
show("isqrt", to_str(math.isqrt(99)) + " " + to_str(math.isqrt(100)) + " " + to_str(math.isqrt(math.max_int)) + " " + to_str(math.isqrt(math.max_u64)));
show("ilog", opt_i(math.ilog2(1)) + " " + opt_i(math.ilog2(1024)) + " " + opt_i(math.ilog2(0)) + " " + opt_i(math.ilog10(999)) + " " + opt_i(math.ilog10(-5)));
show("pow2", to_str(math.is_pow2(64)) + " " + to_str(math.is_pow2(0)) + " " + opt_u8(math.next_pow2(byte)) + " " + opt_i(math.next_pow2(1000)) + " " + opt_i(math.next_pow2(0)));
show("align", opt_i(math.align_up(13, 8)) + " " + to_str(math.align_down(13, 8)) + " " + opt_i(math.align_up(-13, 8)) + " " + opt_u8(math.align_up(byte, 16)));
show("gcd lcm", to_str(math.gcd(48, 18)) + " " + to_str(math.gcd(-48, 18)) + " " + to_str(math.gcd(0, 0)) + " " + opt_i(math.lcm(4, 6)) + " " + opt_i(math.lcm(math.max_int, 2)));
show("mul_div", opt_i(math.mul_div(math.max_int, 3, 4)) + " " + opt_i(math.mul_div(math.max_int, 2, 1)) + " " + opt_i(math.mul_div(5, 5, 0)));
show("mul_hi", to_str(math.mul_hi(math.max_u64, math.max_u64)) + " " + to_str(math.mul_hi(-1, 1)) + " " + to_str(math.mul_hi(byte, byte)));

// --- bits ---
let one: u32 = 1;
show("popcount", to_str(math.popcount(byte)) + " " + to_str(math.popcount(-1)) + " " + to_str(math.popcount(tiny)));
show("zeros", to_str(math.leading_zeros(one)) + " " + to_str(math.trailing_zeros(one)) + " " + to_str(math.leading_zeros(0)) + " " + to_str(math.trailing_zeros(byte)));
show("bit_len", to_str(math.bit_len(byte)) + " " + to_str(math.bit_len(0)) + " " + to_str(math.bit_len(-1)));
show("rotate", to_str(math.rotate_left(byte, 1)) + " " + to_str(math.rotate_right(byte, 1)) + " " + to_str(math.rotate_left(byte, -1)) + " " + to_str(math.rotate_left(one, 33)));
show("swap_bytes", to_str(math.swap_bytes(one)) + " " + to_str(math.swap_bytes(byte)));
show("reverse_bits", to_str(math.reverse_bits(one)) + " " + to_str(math.reverse_bits(byte)));

// --- formatting ---
show("format", math.format(math.pi, 3) + " " + math.format(1234567.0, 2));
show("format_fixed", math.format_fixed(math.pi, 4) + " " + math.format_fixed(2.5, 0) + " " + math.format_fixed(1000000000000000000000.0, 1));
show("format_sci", math.format_sci(1234.5, 2) + " " + math.format_sci(0.0, 0));
