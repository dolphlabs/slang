/* Signatures for the 'math' package -- see native.c's native_check and
 * native_gen for the table-driven dispatch, and dispatch.c here for what
 * is particular to math: one type parameter shared by the arguments, its
 * constants, and the by-value opt results.
 *
 * Why native rather than slang over `extern fn`: an extern call reaches
 * libm through an asm label (sl_x_sqrt __asm__("sqrt")), which C
 * compilers do not recognize as the builtin, so sqrt was a real call
 * instead of one instruction, never constant-folded or vectorized; and a
 * call with a live GC value in scope paid a safepoint bracket. Here every
 * function except the format* family is a leaf (native_is_leaf): the C
 * reads its arguments, never allocates and never parks.
 *
 * NA_NUM, NA_NUM_INT and NA_NUM_FLT are one type parameter T, chosen per
 * call from the arguments (math_type_of_call, dispatch.c): any numeric
 * type, an integer type, or a float type (an integer argument makes it
 * `float`). A return of "@" is T, and "opt[@]" an opt of it, so
 * math.abs(x) on an i32 is an i32 and math.checked_add(a, b) on two u8s
 * is an opt[u8]. Without one parameter for every width, each of these
 * would need ten spellings (abs_i8 .. abs_u64, abs_f32), and slang has no
 * overloading to hide them.
 *
 * Floats follow IEEE 754: NaN propagates (min and max included), -0.0 is
 * kept, and no float function panics. An integer operation that can fail
 * returns an opt; a division by zero panics with the caller's location,
 * as `/` does. */

#include "../internal.h"

const NatSig MATH_SIGS[] = {
    /* --- any numeric type --- */
    {"math", "abs", 1, {NA_NUM}, "@", 0},
    {"math", "min", 2, {NA_NUM, NA_NUM}, "@", 0},
    {"math", "max", 2, {NA_NUM, NA_NUM}, "@", 0},
    {"math", "clamp", 3, {NA_NUM, NA_NUM, NA_NUM}, "@", 0},
    {"math", "sign", 1, {NA_NUM}, "@", 0},

    /* --- float classification and representation --- */
    {"math", "is_nan", 1, {NA_NUM_FLT}, "bool", 0},
    {"math", "is_inf", 1, {NA_NUM_FLT}, "bool", 0},
    {"math", "is_finite", 1, {NA_NUM_FLT}, "bool", 0},
    {"math", "is_normal", 1, {NA_NUM_FLT}, "bool", 0},
    {"math", "signbit", 1, {NA_NUM_FLT}, "bool", 0},
    {"math", "copysign", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "nextafter", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "nextup", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "nextdown", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "ulp", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "frexp_mantissa", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "frexp_exponent", 1, {NA_NUM_FLT}, "int", 0},
    {"math", "ldexp", 2, {NA_NUM_FLT, NA_I64}, "@", 0},
    {"math", "ilogb", 1, {NA_NUM_FLT}, "int", 0},
    {"math", "float_bits", 1, {NA_F64}, "u64", 0},
    {"math", "float_from_bits", 1, {NA_I64}, "float", 0},
    {"math", "f32_bits", 1, {NA_F64}, "u32", 0},
    {"math", "f32_from_bits", 1, {NA_I64}, "f32", 0},
    {"math", "total_cmp", 2, {NA_NUM_FLT, NA_NUM_FLT}, "int", 0},
    {"math", "approx_eq", 4, {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT},
     "bool", 0},

    /* --- rounding --- */
    {"math", "floor", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "ceil", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "trunc", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "round", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "round_even", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "round_to", 2, {NA_NUM_FLT, NA_I64}, "@", 0},
    {"math", "round_to_multiple", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "fract", 1, {NA_NUM_FLT}, "@", 0},
    /* A float to an int when it is one: none for NaN, the infinities and
       anything outside int's range, where `as` silently gives garbage. */
    {"math", "floor_int", 1, {NA_F64}, "opt[int]", 0},
    {"math", "ceil_int", 1, {NA_F64}, "opt[int]", 0},
    {"math", "round_int", 1, {NA_F64}, "opt[int]", 0},
    {"math", "trunc_int", 1, {NA_F64}, "opt[int]", 0},

    /* --- powers, roots, remainders --- */
    {"math", "sqrt", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "cbrt", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "hypot", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "pow", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "powi", 2, {NA_NUM_FLT, NA_I64}, "@", 0},
    {"math", "fma", 3, {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "fmod", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "remainder", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "mod_euclid", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},

    /* --- exponentials and logarithms --- */
    {"math", "exp", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "exp2", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "expm1", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "log", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "log2", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "log10", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "log1p", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "log_base", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},

    /* --- trigonometry --- */
    {"math", "sin", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "cos", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "tan", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "asin", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "acos", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "atan", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "atan2", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "sinh", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "cosh", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "tanh", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "asinh", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "acosh", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "atanh", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "to_radians", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "to_degrees", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "wrap_angle", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "sin_pi", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "cos_pi", 1, {NA_NUM_FLT}, "@", 0},

    /* --- special functions --- */
    {"math", "gamma", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "lgamma", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "erf", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "erfc", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "erf_inv", 1, {NA_NUM_FLT}, "@", 0},
    {"math", "beta", 2, {NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "factorial", 1, {NA_I64}, "float", 0},
    {"math", "binomial", 2, {NA_I64, NA_I64}, "float", 0},

    /* --- interpolation --- */
    {"math", "lerp", 3, {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "inverse_lerp", 3, {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "remap", 5,
     {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "smoothstep", 3, {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT}, "@", 0},
    {"math", "smootherstep", 3, {NA_NUM_FLT, NA_NUM_FLT, NA_NUM_FLT}, "@", 0},

    /* --- integer arithmetic. checked_* is none on overflow (and on a
       zero divisor), saturating_* stops at the type's bounds, and
       wrapping_* is what + - * already do, named so code can say it
       means it. --- */
    {"math", "checked_add", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_sub", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_mul", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_div", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_rem", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_neg", 1, {NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_abs", 1, {NA_NUM_INT}, "opt[@]", 0},
    {"math", "checked_pow", 2, {NA_NUM_INT, NA_I64}, "opt[@]", 0},
    {"math", "checked_shl", 2, {NA_NUM_INT, NA_I64}, "opt[@]", 0},
    {"math", "saturating_add", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "saturating_sub", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "saturating_mul", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "wrapping_add", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "wrapping_sub", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "wrapping_mul", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "wrapping_neg", 1, {NA_NUM_INT}, "@", 0},
    {"math", "wrapping_pow", 2, {NA_NUM_INT, NA_I64}, "@", 0},
    /* Division rounding toward -inf, toward +inf, and Euclidean (the
       remainder is never negative). A zero divisor panics, as `/` does. */
    {"math", "div_floor", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "div_ceil", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "div_euclid", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "rem_euclid", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "abs_diff", 2, {NA_NUM_INT, NA_NUM_INT}, "u64", 0},
    {"math", "midpoint", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    /* isqrt panics on a negative argument; ilog2/ilog10 are none for
       x <= 0. */
    {"math", "isqrt", 1, {NA_NUM_INT}, "@", 0},
    {"math", "ilog2", 1, {NA_NUM_INT}, "opt[int]", 0},
    {"math", "ilog10", 1, {NA_NUM_INT}, "opt[int]", 0},
    {"math", "is_pow2", 1, {NA_NUM_INT}, "bool", 0},
    {"math", "next_pow2", 1, {NA_NUM_INT}, "opt[@]", 0},
    /* align must be a power of two (it panics otherwise) */
    {"math", "align_up", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    {"math", "align_down", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "gcd", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    {"math", "lcm", 2, {NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    /* a * b / c with the product held at twice the width: none when c is
       0 or the quotient does not fit. */
    {"math", "mul_div", 3, {NA_NUM_INT, NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},
    /* the high half of the full product a * b */
    {"math", "mul_hi", 2, {NA_NUM_INT, NA_NUM_INT}, "@", 0},
    /* (a * b) mod m, the product held at twice the width, so modular
       arithmetic near the type's limit cannot overflow (math/numtheory's
       mod_pow, Miller-Rabin). The result has m's sign, as rem_euclid's
       does for a positive m; none when m is 0. */
    {"math", "mul_mod", 3, {NA_NUM_INT, NA_NUM_INT, NA_NUM_INT}, "opt[@]", 0},

    /* --- bits, on the argument's own width --- */
    {"math", "popcount", 1, {NA_NUM_INT}, "int", 0},
    {"math", "leading_zeros", 1, {NA_NUM_INT}, "int", 0},
    {"math", "trailing_zeros", 1, {NA_NUM_INT}, "int", 0},
    {"math", "bit_len", 1, {NA_NUM_INT}, "int", 0},
    {"math", "rotate_left", 2, {NA_NUM_INT, NA_I64}, "@", 0},
    {"math", "rotate_right", 2, {NA_NUM_INT, NA_I64}, "@", 0},
    {"math", "swap_bytes", 1, {NA_NUM_INT}, "@", 0},
    {"math", "reverse_bits", 1, {NA_NUM_INT}, "@", 0},

    /* --- formatting: the only functions here that allocate. format is
       `digits` significant digits, format_fixed `decimals` after the
       point, format_sci scientific with `digits` after the point. --- */
    {"math", "format", 2, {NA_F64, NA_I64}, "str", 0},
    {"math", "format_fixed", 2, {NA_F64, NA_I64}, "str", 0},
    {"math", "format_sci", 2, {NA_F64, NA_I64}, "str", 0},
};

const int MATH_SIGS_LEN = sizeof(MATH_SIGS) / sizeof(MATH_SIGS[0]);

/* Constants: math.pi and the rest, read like a package variable. The C is
 * a literal (or a <math.h>/<stdint.h> macro the runtime section includes),
 * so the compiler folds it. */
const MathConst MATH_CONSTS[] = {
    {"pi", "float", "3.141592653589793"},
    {"tau", "float", "6.283185307179586"},
    {"e", "float", "2.718281828459045"},
    {"phi", "float", "1.618033988749895"},
    {"sqrt2", "float", "1.4142135623730951"},
    {"sqrt3", "float", "1.7320508075688772"},
    {"ln2", "float", "0.6931471805599453"},
    {"ln10", "float", "2.302585092994046"},
    {"log2e", "float", "1.4426950408889634"},
    {"log10e", "float", "0.4342944819032518"},
    {"inf", "float", "(__builtin_inf())"},
    {"neg_inf", "float", "(-__builtin_inf())"},
    {"nan", "float", "(__builtin_nan(\"\"))"},
    {"max_float", "float", "1.7976931348623157e308"},
    {"min_normal", "float", "2.2250738585072014e-308"},
    {"min_subnormal", "float", "4.9406564584124654e-324"},
    {"epsilon", "float", "2.220446049250313e-16"},
    {"f32_max", "f32", "3.40282347e38f"},
    {"f32_min_normal", "f32", "1.17549435e-38f"},
    {"f32_epsilon", "f32", "1.1920929e-7f"},
    {"max_int", "int", "9223372036854775807LL"},
    {"min_int", "int", "(-9223372036854775807LL - 1)"},
    {"max_i8", "i8", "((int8_t)127)"},
    {"min_i8", "i8", "((int8_t)-128)"},
    {"max_i16", "i16", "((int16_t)32767)"},
    {"min_i16", "i16", "((int16_t)-32768)"},
    {"max_i32", "i32", "((int32_t)2147483647)"},
    {"min_i32", "i32", "((int32_t)(-2147483647 - 1))"},
    {"max_i64", "i64", "((int64_t)9223372036854775807LL)"},
    {"min_i64", "i64", "((int64_t)(-9223372036854775807LL - 1))"},
    {"max_u8", "u8", "((uint8_t)255)"},
    {"max_u16", "u16", "((uint16_t)65535)"},
    {"max_u32", "u32", "((uint32_t)4294967295U)"},
    {"max_u64", "u64", "((uint64_t)18446744073709551615ULL)"},
};

const int MATH_CONSTS_LEN = sizeof(MATH_CONSTS) / sizeof(MATH_CONSTS[0]);
