/* ---- math (src/codegen/pkg_math/) ------------------------------------
 *
 * Every function here is instantiated once per type it takes, named by
 * the type's suffix (sl_math_abs_i32, sl_math_sqrt_f64): codegen picks the
 * instance from the call's T (pkg_math/dispatch.c). They are static inline
 * and compute only, so a call is usually the instruction itself after
 * inlining (sqrt, a compare for min) and never a safepoint
 * (native_is_leaf). The format* family at the end is the exception: it
 * builds a str.
 *
 * Integer edge cases are all defined, none of them C's undefined
 * behavior: MIN / -1 wraps to MIN (as slang's `/` does), MIN % -1 is 0,
 * and a shift or rotate count is taken modulo the width. A function that
 * returns an opt writes *out and returns true, or returns false and
 * leaves *out alone. */

#include <limits.h>
#include <math.h>

/* The reentrant lgamma (see sl_math_lgamma_*): in libm on Linux and macOS
 * alike, but macOS's <math.h> declares it only under _REENTRANT. */
extern double lgamma_r(double, int *);
extern float lgammaf_r(float, int *);

#define SL_MATH_PI 3.141592653589793

/* ---- any numeric type: abs, min, max, clamp, sign ---- */

#define SL_MATH_ANY_INT(S, T, SIGNED)                                         \
    static inline T sl_math_abs_##S(T x) {                                    \
        return (SIGNED && x < 0) ? (T)-x : x;                                 \
    }                                                                         \
    static inline T sl_math_min_##S(T a, T b) { return a < b ? a : b; }       \
    static inline T sl_math_max_##S(T a, T b) { return a > b ? a : b; }       \
    static inline T sl_math_clamp_##S(T x, T lo, T hi) {                      \
        return x < lo ? lo : x > hi ? hi : x;                                 \
    }                                                                         \
    static inline T sl_math_sign_##S(T x) {                                   \
        return (T)((x > 0) - (SIGNED && x < 0));                              \
    }

/* NaN propagates through min, max and clamp (as Go's math.Min does), and
 * -0.0 orders below +0.0, so min(-0.0, 0.0) is -0.0. */
#define SL_MATH_ANY_FLT(S, T, F)                                              \
    static inline T sl_math_abs_##S(T x) { return fabs##F(x); }               \
    static inline T sl_math_min_##S(T a, T b) {                               \
        if (isnan(a) || isnan(b))                                             \
            return a + b;                                                     \
        if (a == b)                                                           \
            return signbit(a) ? a : b;                                        \
        return a < b ? a : b;                                                 \
    }                                                                         \
    static inline T sl_math_max_##S(T a, T b) {                               \
        if (isnan(a) || isnan(b))                                             \
            return a + b;                                                     \
        if (a == b)                                                           \
            return signbit(a) ? b : a;                                        \
        return a > b ? a : b;                                                 \
    }                                                                         \
    static inline T sl_math_clamp_##S(T x, T lo, T hi) {                      \
        if (isnan(x))                                                         \
            return x;                                                         \
        return x < lo ? lo : x > hi ? hi : x;                                 \
    }                                                                         \
    static inline T sl_math_sign_##S(T x) {                                   \
        if (isnan(x) || x == 0)                                               \
            return x; /* NaN, and +-0 keeping its sign */                     \
        return copysign##F((T)1, x);                                          \
    }

/* ---- floats ---- */

#define SL_MATH_FLT(S, T, F, U, BITS)                                         \
    static inline bool sl_math_is_nan_##S(T x) { return isnan(x); }           \
    static inline bool sl_math_is_inf_##S(T x) { return isinf(x); }           \
    static inline bool sl_math_is_finite_##S(T x) { return isfinite(x); }     \
    static inline bool sl_math_is_normal_##S(T x) { return isnormal(x); }     \
    static inline bool sl_math_signbit_##S(T x) { return signbit(x) != 0; }   \
    static inline T sl_math_copysign_##S(T a, T b) { return copysign##F(a, b); } \
    static inline T sl_math_nextafter_##S(T a, T b) {                         \
        return nextafter##F(a, b);                                            \
    }                                                                         \
    static inline T sl_math_nextup_##S(T x) {                                 \
        return nextafter##F(x, (T)INFINITY);                                  \
    }                                                                         \
    static inline T sl_math_nextdown_##S(T x) {                               \
        return nextafter##F(x, (T)-INFINITY);                                 \
    }                                                                         \
    /* the gap from |x| to the next float away from zero (toward zero at   \
       the largest finite value); NaN for NaN, inf for inf */              \
    static inline T sl_math_ulp_##S(T x) {                                    \
        if (!isfinite(x))                                                     \
            return fabs##F(x);                                                \
        T ax = fabs##F(x);                                                    \
        T up = nextafter##F(ax, (T)INFINITY);                                 \
        if (isinf(up))                                                        \
            return ax - nextafter##F(ax, (T)0);                               \
        return up - ax;                                                       \
    }                                                                         \
    static inline T sl_math_frexp_mantissa_##S(T x) {                         \
        int e;                                                                \
        return frexp##F(x, &e);                                               \
    }                                                                         \
    static inline long long sl_math_frexp_exponent_##S(T x) {                 \
        int e = 0;                                                            \
        (void)frexp##F(x, &e);                                                \
        return e;                                                             \
    }                                                                         \
    static inline T sl_math_ldexp_##S(T x, long long n) {                     \
        int e = n > 100000 ? 100000 : n < -100000 ? -100000 : (int)n;         \
        return ldexp##F(x, e);                                                \
    }                                                                         \
    static inline long long sl_math_ilogb_##S(T x) { return ilogb##F(x); }    \
    /* IEEE 754 totalOrder: -NaN < -inf < ... < -0 < +0 < ... < inf < NaN */ \
    static inline long long sl_math_total_cmp_##S(T a, T b) {                 \
        U ua, ub;                                                             \
        memcpy(&ua, &a, sizeof ua);                                           \
        memcpy(&ub, &b, sizeof ub);                                           \
        ua ^= (U)((U)(ua >> (BITS - 1)) * ((U)~(U)0 >> 1)) | ((U)1 << (BITS - 1)); \
        ub ^= (U)((U)(ub >> (BITS - 1)) * ((U)~(U)0 >> 1)) | ((U)1 << (BITS - 1)); \
        return (ua > ub) - (ua < ub);                                         \
    }                                                                         \
    static inline bool sl_math_approx_eq_##S(T a, T b, T rel, T abs_tol) {    \
        if (a == b)                                                           \
            return true;                                                      \
        if (!isfinite(a) || !isfinite(b))                                     \
            return false;                                                     \
        T d = fabs##F(a - b);                                                 \
        T m = fmax##F(fabs##F(a), fabs##F(b));                                \
        return d <= fmax##F(rel * m, abs_tol);                                \
    }                                                                         \
    static inline T sl_math_floor_##S(T x) { return floor##F(x); }            \
    static inline T sl_math_ceil_##S(T x) { return ceil##F(x); }              \
    static inline T sl_math_trunc_##S(T x) { return trunc##F(x); }            \
    static inline T sl_math_round_##S(T x) { return round##F(x); }            \
    /* ties to even, whatever the rounding mode is set to */               \
    static inline T sl_math_round_even_##S(T x) {                             \
        T r = round##F(x);                                                    \
        if (fabs##F(x - trunc##F(x)) == (T)0.5)                               \
            r = (T)2 * round##F(x / (T)2);                                    \
        return r;                                                             \
    }                                                                         \
    /* x rounded to `d` decimal places (negative d: to tens, hundreds...), \
       half away from zero, as the nearest float to that decimal */        \
    static inline T sl_math_round_to_##S(T x, long long d) {                  \
        if (!isfinite(x) || d > 300 || d < -300)                              \
            return x;                                                         \
        double p = pow(10.0, (double)(d < 0 ? -d : d));                       \
        double y = d >= 0 ? (double)x * p : (double)x / p;                    \
        if (!isfinite(y))                                                     \
            return x;                                                         \
        y = round(y);                                                         \
        return (T)(d >= 0 ? y / p : y * p);                                   \
    }                                                                         \
    static inline T sl_math_round_to_multiple_##S(T x, T m) {                 \
        if (m == 0 || !isfinite(m))                                           \
            return x;                                                         \
        return round##F(x / m) * m;                                           \
    }                                                                         \
    /* the part after the point, with x's sign: fract(-1.25) is -0.25 */   \
    static inline T sl_math_fract_##S(T x) {                                  \
        if (isinf(x))                                                         \
            return copysign##F((T)0, x);                                      \
        return x - trunc##F(x);                                               \
    }                                                                         \
    static inline T sl_math_sqrt_##S(T x) { return sqrt##F(x); }              \
    static inline T sl_math_cbrt_##S(T x) { return cbrt##F(x); }              \
    static inline T sl_math_hypot_##S(T a, T b) { return hypot##F(a, b); }    \
    static inline T sl_math_pow_##S(T a, T b) { return pow##F(a, b); }        \
    /* x to an integer power, by squaring: exact while the result fits */  \
    static inline T sl_math_powi_##S(T x, long long n) {                      \
        unsigned long long k = n < 0 ? 0ULL - (unsigned long long)n           \
                                     : (unsigned long long)n;                 \
        T r = 1, b = x;                                                       \
        while (k) {                                                           \
            if (k & 1)                                                        \
                r *= b;                                                       \
            b *= b;                                                           \
            k >>= 1;                                                          \
        }                                                                     \
        return n < 0 ? (T)1 / r : r;                                          \
    }                                                                         \
    static inline T sl_math_fma_##S(T a, T b, T c) { return fma##F(a, b, c); } \
    static inline T sl_math_fmod_##S(T a, T b) { return fmod##F(a, b); }      \
    static inline T sl_math_remainder_##S(T a, T b) {                         \
        return remainder##F(a, b);                                            \
    }                                                                         \
    /* in [0, |b|): the remainder of a floored-toward-the-sign division */ \
    static inline T sl_math_mod_euclid_##S(T a, T b) {                        \
        T r = fmod##F(a, b);                                                  \
        if (r < 0)                                                            \
            r += fabs##F(b);                                                  \
        return r;                                                             \
    }                                                                         \
    static inline T sl_math_exp_##S(T x) { return exp##F(x); }                \
    static inline T sl_math_exp2_##S(T x) { return exp2##F(x); }              \
    static inline T sl_math_expm1_##S(T x) { return expm1##F(x); }            \
    static inline T sl_math_log_##S(T x) { return log##F(x); }                \
    static inline T sl_math_log2_##S(T x) { return log2##F(x); }              \
    static inline T sl_math_log10_##S(T x) { return log10##F(x); }            \
    static inline T sl_math_log1p_##S(T x) { return log1p##F(x); }            \
    static inline T sl_math_log_base_##S(T x, T b) {                          \
        return log##F(x) / log##F(b);                                         \
    }                                                                         \
    static inline T sl_math_sin_##S(T x) { return sin##F(x); }                \
    static inline T sl_math_cos_##S(T x) { return cos##F(x); }                \
    static inline T sl_math_tan_##S(T x) { return tan##F(x); }                \
    static inline T sl_math_asin_##S(T x) { return asin##F(x); }              \
    static inline T sl_math_acos_##S(T x) { return acos##F(x); }              \
    static inline T sl_math_atan_##S(T x) { return atan##F(x); }              \
    static inline T sl_math_atan2_##S(T y, T x) { return atan2##F(y, x); }    \
    static inline T sl_math_sinh_##S(T x) { return sinh##F(x); }              \
    static inline T sl_math_cosh_##S(T x) { return cosh##F(x); }              \
    static inline T sl_math_tanh_##S(T x) { return tanh##F(x); }              \
    static inline T sl_math_asinh_##S(T x) { return asinh##F(x); }            \
    static inline T sl_math_acosh_##S(T x) { return acosh##F(x); }            \
    static inline T sl_math_atanh_##S(T x) { return atanh##F(x); }            \
    static inline T sl_math_to_radians_##S(T x) {                             \
        return x * (T)(SL_MATH_PI / 180.0);                                   \
    }                                                                         \
    static inline T sl_math_to_degrees_##S(T x) {                             \
        return x * (T)(180.0 / SL_MATH_PI);                                   \
    }                                                                         \
    /* the same angle in (-pi, pi] */                                      \
    static inline T sl_math_wrap_angle_##S(T x) {                             \
        T r = remainder##F(x, (T)(2.0 * SL_MATH_PI));                         \
        return r <= (T)-SL_MATH_PI ? r + (T)(2.0 * SL_MATH_PI) : r;           \
    }                                                                         \
    /* sin(pi * x) and cos(pi * x), exact at the integers and halves,      \
       where sin(math.pi * n) is not quite 0 */                            \
    static inline T sl_math_sin_pi_##S(T x) {                                 \
        if (!isfinite(x))                                                     \
            return (T)NAN;                                                    \
        T r = remainder##F(x, (T)2);                                          \
        if (r == 0 || fabs##F(r) == (T)1)                                     \
            return copysign##F((T)0, x);                                      \
        if (r == (T)0.5)                                                      \
            return (T)1;                                                      \
        if (r == (T)-0.5)                                                     \
            return (T)-1;                                                     \
        return sin##F((T)SL_MATH_PI * r);                                     \
    }                                                                         \
    static inline T sl_math_cos_pi_##S(T x) {                                 \
        if (!isfinite(x))                                                     \
            return (T)NAN;                                                    \
        T r = fabs##F(remainder##F(x, (T)2));                                 \
        if (r == (T)0.5)                                                      \
            return (T)0;                                                      \
        if (r == 0)                                                           \
            return (T)1;                                                      \
        if (r == (T)1)                                                        \
            return (T)-1;                                                     \
        return cos##F((T)SL_MATH_PI * r);                                     \
    }                                                                         \
    static inline T sl_math_gamma_##S(T x) { return tgamma##F(x); }           \
    /* ln|gamma(x)|. lgamma itself writes the global signgam, a data race  \
       between tasks on different workers, so the sign goes to a local. */ \
    static inline T sl_math_lgamma_##S(T x) {                                 \
        int sg;                                                               \
        return lgamma##F##_r(x, &sg);                                         \
    }                                                                         \
    static inline T sl_math_erf_##S(T x) { return erf##F(x); }                \
    static inline T sl_math_erfc_##S(T x) { return erfc##F(x); }              \
    static inline T sl_math_erf_inv_##S(T y) {                                \
        return (T)sl_math_erf_inv_d((double)y);                               \
    }                                                                         \
    static inline T sl_math_beta_##S(T a, T b) {                              \
        if (a > 0 && b > 0) {                                                 \
            int s1, s2, s3;                                                   \
            return (T)exp(lgamma_r((double)a, &s1) + lgamma_r((double)b, &s2) - \
                          lgamma_r((double)a + (double)b, &s3));              \
        }                                                                     \
        return (T)(tgamma((double)a) * tgamma((double)b) /                    \
                   tgamma((double)a + (double)b));                            \
    }                                                                         \
    /* (1-t)*a + t*b: exactly a at t = 0 and b at t = 1 */                 \
    static inline T sl_math_lerp_##S(T a, T b, T t) {                         \
        return ((T)1 - t) * a + t * b;                                        \
    }                                                                         \
    static inline T sl_math_inverse_lerp_##S(T a, T b, T v) {                 \
        return (v - a) / (b - a);                                             \
    }                                                                         \
    static inline T sl_math_remap_##S(T x, T a0, T a1, T b0, T b1) {          \
        return sl_math_lerp_##S(b0, b1, (x - a0) / (a1 - a0));                \
    }                                                                         \
    static inline T sl_math_smoothstep_##S(T e0, T e1, T x) {                 \
        T t = (x - e0) / (e1 - e0);                                           \
        t = t < 0 ? 0 : t > 1 ? 1 : t;                                        \
        return t * t * ((T)3 - (T)2 * t);                                     \
    }                                                                         \
    static inline T sl_math_smootherstep_##S(T e0, T e1, T x) {               \
        T t = (x - e0) / (e1 - e0);                                           \
        t = t < 0 ? 0 : t > 1 ? 1 : t;                                        \
        return t * t * t * (t * (t * (T)6 - (T)15) + (T)10);                  \
    }

/* Inverse error function. A starting point from Giles' approximation
 * ("Approximating the erfinv function", 2010), then Newton steps on erf
 * itself, which bring it to full double precision. */
static inline double sl_math_erf_inv_d(double y) {
    if (isnan(y) || y < -1 || y > 1)
        return NAN;
    if (y == 1)
        return INFINITY;
    if (y == -1)
        return -INFINITY;
    if (y == 0)
        return y;
    double w = -log((1.0 - y) * (1.0 + y)), x;
    if (w < 5.0) {
        w -= 2.5;
        x = 2.81022636e-08;
        x = 3.43273939e-07 + x * w;
        x = -3.5233877e-06 + x * w;
        x = -4.39150654e-06 + x * w;
        x = 0.00021858087 + x * w;
        x = -0.00125372503 + x * w;
        x = -0.00417768164 + x * w;
        x = 0.246640727 + x * w;
        x = 1.50140941 + x * w;
    } else {
        w = sqrt(w) - 3.0;
        x = -0.000200214257;
        x = 0.000100950558 + x * w;
        x = 0.00134934322 + x * w;
        x = -0.00367342844 + x * w;
        x = 0.00573950773 + x * w;
        x = -0.0076224613 + x * w;
        x = 0.00943887047 + x * w;
        x = 1.00167406 + x * w;
        x = 2.83297682 + x * w;
    }
    x *= y;
    for (int i = 0; i < 3; i++) {
        double err = erf(x) - y;
        double d = 1.1283791670955126 * exp(-x * x); /* 2/sqrt(pi) e^-x^2 */
        if (d == 0)
            break;
        x -= err / d;
    }
    return x;
}

SL_MATH_ANY_FLT(f32, float, f)
SL_MATH_ANY_FLT(f64, double, )
SL_MATH_FLT(f32, float, f, uint32_t, 32)
SL_MATH_FLT(f64, double, , uint64_t, 64)

/* ---- integers ----
 * S suffix, T type, U its unsigned type, W a type twice as wide (for
 * mul_div and mul_hi; __int128 for the 64-bit ones), BITS, SIGNED,
 * TMIN/TMAX its bounds. */

#define SL_MATH_INT(S, T, U, W, BITS, SIGNED, TMIN, TMAX)                     \
    static inline bool sl_math_checked_add_##S(T a, T b, T *out) {            \
        return !__builtin_add_overflow(a, b, out);                            \
    }                                                                         \
    static inline bool sl_math_checked_sub_##S(T a, T b, T *out) {            \
        return !__builtin_sub_overflow(a, b, out);                            \
    }                                                                         \
    static inline bool sl_math_checked_mul_##S(T a, T b, T *out) {            \
        return !__builtin_mul_overflow(a, b, out);                            \
    }                                                                         \
    static inline bool sl_math_checked_div_##S(T a, T b, T *out) {            \
        if (b == 0 || (SIGNED && a == TMIN && b == (T)-1))                    \
            return false;                                                     \
        *out = a / b;                                                         \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_checked_rem_##S(T a, T b, T *out) {            \
        if (b == 0 || (SIGNED && a == TMIN && b == (T)-1))                    \
            return false;                                                     \
        *out = a % b;                                                         \
        return true;                                                          \
    }                                                                         \
    /* unsigned: only 0 has a negation */                                  \
    static inline bool sl_math_checked_neg_##S(T a, T *out) {                 \
        if (SIGNED ? a == TMIN : a != 0)                                      \
            return false;                                                     \
        *out = (T)((U)0 - (U)a);                                              \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_checked_abs_##S(T a, T *out) {                 \
        if (SIGNED && a == TMIN)                                              \
            return false;                                                     \
        *out = (SIGNED && a < 0) ? (T)((U)0 - (U)a) : a;                      \
        return true;                                                          \
    }                                                                         \
    /* x to a negative power is the truncated result: 1 and -1 keep a      \
       magnitude of 1, everything else is 0 */                             \
    static inline T sl_math_neg_pow_##S(T x, long long e) {                   \
        if (x == 1)                                                           \
            return 1;                                                         \
        if (SIGNED && x == (T)-1)                                             \
            return (e & 1) ? (T)-1 : (T)1;                                    \
        return 0;                                                             \
    }                                                                         \
    static inline bool sl_math_checked_pow_##S(T x, long long e, T *out) {    \
        if (e < 0) {                                                          \
            if (x == 0)                                                       \
                return false; /* 1/0 */                                       \
            *out = sl_math_neg_pow_##S(x, e);                                 \
            return true;                                                      \
        }                                                                     \
        T r = 1, b = x;                                                       \
        while (e) {                                                           \
            if ((e & 1) && __builtin_mul_overflow(r, b, &r))                  \
                return false;                                                 \
            e >>= 1;                                                          \
            if (e && __builtin_mul_overflow(b, b, &b))                        \
                return false;                                                 \
        }                                                                     \
        *out = r;                                                             \
        return true;                                                          \
    }                                                                         \
    static inline T sl_math_wrapping_pow_##S(T x, long long e) {              \
        if (e < 0)                                                            \
            return sl_math_neg_pow_##S(x, e);                                 \
        U r = 1, b = (U)x;                                                    \
        while (e) {                                                           \
            if (e & 1)                                                        \
                r = (U)(r * b);                                               \
            b = (U)(b * b);                                                   \
            e >>= 1;                                                          \
        }                                                                     \
        return (T)r;                                                          \
    }                                                                         \
    /* none when the count is outside 0..BITS-1 or a set bit (or, signed,  \
       the sign) would be shifted out */                                   \
    static inline bool sl_math_checked_shl_##S(T x, long long n, T *out) {    \
        if (n < 0 || n >= BITS)                                               \
            return false;                                                     \
        T r = (T)((U)x << n);                                                 \
        if ((T)(r >> n) != x)                                                 \
            return false;                                                     \
        *out = r;                                                             \
        return true;                                                          \
    }                                                                         \
    static inline T sl_math_saturating_add_##S(T a, T b) {                    \
        T r;                                                                  \
        if (!__builtin_add_overflow(a, b, &r))                                \
            return r;                                                         \
        return (SIGNED && b < 0) ? TMIN : TMAX;                               \
    }                                                                         \
    static inline T sl_math_saturating_sub_##S(T a, T b) {                    \
        T r;                                                                  \
        if (!__builtin_sub_overflow(a, b, &r))                                \
            return r;                                                         \
        return (SIGNED && b < 0) ? TMAX : TMIN;                               \
    }                                                                         \
    static inline T sl_math_saturating_mul_##S(T a, T b) {                    \
        T r;                                                                  \
        if (!__builtin_mul_overflow(a, b, &r))                                \
            return r;                                                         \
        return (SIGNED && ((a < 0) != (b < 0))) ? TMIN : TMAX;                \
    }                                                                         \
    static inline T sl_math_wrapping_add_##S(T a, T b) {                      \
        return (T)((U)a + (U)b);                                              \
    }                                                                         \
    static inline T sl_math_wrapping_sub_##S(T a, T b) {                      \
        return (T)((U)a - (U)b);                                              \
    }                                                                         \
    static inline T sl_math_wrapping_mul_##S(T a, T b) {                      \
        return (T)((U)a * (U)b);                                              \
    }                                                                         \
    static inline T sl_math_wrapping_neg_##S(T a) { return (T)((U)0 - (U)a); } \
    /* truncating quotient and remainder, with C's two traps defined:      \
       MIN / -1 wraps to MIN and MIN % -1 is 0 */                          \
    static inline T sl_math_tdiv_##S(T a, T b) {                              \
        return (SIGNED && b == (T)-1) ? (T)((U)0 - (U)a) : a / b;             \
    }                                                                         \
    static inline T sl_math_trem_##S(T a, T b) {                              \
        return (SIGNED && b == (T)-1) ? (T)0 : a % b;                         \
    }                                                                         \
    static inline T sl_math_div_floor_##S(T a, T b, const char *at) {         \
        if (b == 0)                                                           \
            sl_rt_fail("division by zero", at, "");                     \
        T q = sl_math_tdiv_##S(a, b), r = sl_math_trem_##S(a, b);             \
        return (r != 0 && SIGNED && ((r < 0) != (b < 0))) ? (T)(q - 1) : q;   \
    }                                                                         \
    static inline T sl_math_div_ceil_##S(T a, T b, const char *at) {          \
        if (b == 0)                                                           \
            sl_rt_fail("division by zero", at, "");                     \
        T q = sl_math_tdiv_##S(a, b), r = sl_math_trem_##S(a, b);             \
        return (r != 0 && (!SIGNED || ((r < 0) == (b < 0)))) ? (T)(q + 1) : q; \
    }                                                                         \
    static inline T sl_math_div_euclid_##S(T a, T b, const char *at) {        \
        if (b == 0)                                                           \
            sl_rt_fail("division by zero", at, "");                     \
        T q = sl_math_tdiv_##S(a, b), r = sl_math_trem_##S(a, b);             \
        if (SIGNED && r < 0)                                                  \
            return b > 0 ? (T)(q - 1) : (T)(q + 1);                           \
        return q;                                                             \
    }                                                                         \
    static inline T sl_math_rem_euclid_##S(T a, T b, const char *at) {        \
        if (b == 0)                                                           \
            sl_rt_fail("division by zero", at, "");                     \
        T r = sl_math_trem_##S(a, b);                                         \
        if (SIGNED && r < 0) /* r + |b|, in U: |MIN| is not a T */            \
            return (T)((U)r + (b < 0 ? (U)0 - (U)b : (U)b));                  \
        return r;                                                             \
    }                                                                         \
    static inline uint64_t sl_math_abs_diff_##S(T a, T b) {                   \
        return a > b ? (uint64_t)(U)((U)a - (U)b) : (uint64_t)(U)((U)b - (U)a); \
    }                                                                         \
    /* (a + b) / 2 without overflow, rounded down */                       \
    static inline T sl_math_midpoint_##S(T a, T b) {                          \
        return (T)((a & b) + ((a ^ b) >> 1));                                 \
    }                                                                         \
    static inline T sl_math_isqrt_##S(T x, const char *at) {                  \
        if (SIGNED && x < 0)                                                  \
            sl_rt_fail("isqrt of a negative number", at, "");           \
        uint64_t v = (uint64_t)x;                                             \
        uint64_t r = (uint64_t)sqrt((double)v);                               \
        while (r > 0 && r > v / r)                                            \
            r--;                                                              \
        while (r + 1 <= v / (r + 1))                                          \
            r++;                                                              \
        return (T)r;                                                          \
    }                                                                         \
    static inline bool sl_math_ilog2_##S(T x, long long *out) {               \
        if (x <= 0)                                                           \
            return false;                                                     \
        *out = 63 - __builtin_clzll((unsigned long long)x);                   \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_ilog10_##S(T x, long long *out) {              \
        if (x <= 0)                                                           \
            return false;                                                     \
        long long n = 0;                                                      \
        for (U v = (U)x; v >= 10; v /= 10)                                    \
            n++;                                                              \
        *out = n;                                                             \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_is_pow2_##S(T x) {                             \
        return x > 0 && (x & (T)(x - 1)) == 0;                                \
    }                                                                         \
    /* the smallest power of two >= x (1 for x <= 1); none past TMAX */    \
    static inline bool sl_math_next_pow2_##S(T x, T *out) {                   \
        if (x <= 1) {                                                         \
            *out = 1;                                                         \
            return true;                                                      \
        }                                                                     \
        U v = (U)x - 1;                                                       \
        int n = BITS - (v ? (int)(__builtin_clzll((unsigned long long)v) - (64 - BITS)) : BITS); \
        if (n >= BITS - SIGNED)                                               \
            return false;                                                     \
        *out = (T)((U)1 << n);                                                \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_align_up_##S(T x, T a, const char *at, T *out) { \
        if (a <= 0 || (a & (T)(a - 1)) != 0)                                  \
            sl_rt_fail("alignment is not a power of two", at, "");      \
        T r;                                                                  \
        if (__builtin_add_overflow(x, (T)(a - 1), &r))                        \
            return false;                                                     \
        *out = (T)(r & (T)~(T)(a - 1));                                       \
        return true;                                                          \
    }                                                                         \
    static inline T sl_math_align_down_##S(T x, T a, const char *at) {        \
        if (a <= 0 || (a & (T)(a - 1)) != 0)                                  \
            sl_rt_fail("alignment is not a power of two", at, "");      \
        return (T)(x & (T)~(T)(a - 1));                                       \
    }                                                                         \
    /* |gcd|, computed on magnitudes; gcd(MIN, 0) is |MIN|, which wraps    \
       back to MIN in a signed T */                                        \
    static inline T sl_math_gcd_##S(T a, T b) {                               \
        U x = (SIGNED && a < 0) ? (U)0 - (U)a : (U)a;                         \
        U y = (SIGNED && b < 0) ? (U)0 - (U)b : (U)b;                         \
        while (y) {                                                           \
            U t = x % y;                                                      \
            x = y;                                                            \
            y = t;                                                            \
        }                                                                     \
        return (T)x;                                                          \
    }                                                                         \
    static inline bool sl_math_lcm_##S(T a, T b, T *out) {                    \
        if (a == 0 || b == 0) {                                               \
            *out = 0;                                                         \
            return true;                                                      \
        }                                                                     \
        U x = (SIGNED && a < 0) ? (U)0 - (U)a : (U)a;                         \
        U y = (SIGNED && b < 0) ? (U)0 - (U)b : (U)b;                         \
        U g = (U)sl_math_gcd_##S(a, b);                                       \
        U l;                                                                  \
        if (__builtin_mul_overflow((U)(x / g), y, &l) || (SIGNED && l > (U)TMAX)) \
            return false;                                                     \
        *out = (T)l;                                                          \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_mul_div_##S(T a, T b, T c, T *out) {           \
        if (c == 0)                                                           \
            return false;                                                     \
        W q = ((W)a * (W)b) / (W)c;                                           \
        if (q < (W)TMIN || q > (W)TMAX)                                       \
            return false;                                                     \
        *out = (T)q;                                                          \
        return true;                                                          \
    }                                                                         \
    static inline bool sl_math_mul_mod_##S(T a, T b, T m, T *out) {           \
        if (m == 0)                                                           \
            return false;                                                     \
        W r = ((W)a * (W)b) % (W)m;                                           \
        if (r != 0 && ((r < 0) != ((W)m < 0)))                                \
            r += (W)m;                                                        \
        *out = (T)r;                                                          \
        return true;                                                          \
    }                                                                         \
    static inline T sl_math_mul_hi_##S(T a, T b) {                            \
        return (T)(((W)a * (W)b) >> BITS);                                    \
    }                                                                         \
    static inline long long sl_math_leading_zeros_##S(T x) {                  \
        U v = (U)x;                                                           \
        return v ? __builtin_clzll((unsigned long long)v) - (64 - BITS) : BITS; \
    }                                                                         \
    static inline long long sl_math_trailing_zeros_##S(T x) {                 \
        U v = (U)x;                                                           \
        return v ? __builtin_ctzll((unsigned long long)v) : BITS;             \
    }                                                                         \
    static inline long long sl_math_popcount_##S(T x) {                       \
        return __builtin_popcountll((unsigned long long)(U)x);                \
    }                                                                         \
    static inline long long sl_math_bit_len_##S(T x) {                        \
        return BITS - sl_math_leading_zeros_##S(x);                           \
    }                                                                         \
    static inline T sl_math_rotate_left_##S(T x, long long n) {               \
        unsigned k = (unsigned)(((n % BITS) + BITS) % BITS);                  \
        U v = (U)x;                                                           \
        return k ? (T)(U)((U)(v << k) | (U)(v >> (BITS - k))) : x;            \
    }                                                                         \
    static inline T sl_math_rotate_right_##S(T x, long long n) {              \
        unsigned k = (unsigned)(((n % BITS) + BITS) % BITS);                  \
        U v = (U)x;                                                           \
        return k ? (T)(U)((U)(v >> k) | (U)(v << (BITS - k))) : x;            \
    }                                                                         \
    static inline T sl_math_swap_bytes_##S(T x) {                             \
        U v = (U)x, r = 0;                                                    \
        for (int i = 0; i < BITS / 8; i++) {                                  \
            r = (U)((U)(r << 8) | (U)(v & 0xff));                             \
            v = (U)(v >> 8);                                                  \
        }                                                                     \
        return (T)r;                                                          \
    }                                                                         \
    static inline T sl_math_reverse_bits_##S(T x) {                           \
        uint64_t v = (uint64_t)(U)x;                                          \
        v = ((v >> 1) & 0x5555555555555555ULL) | ((v & 0x5555555555555555ULL) << 1); \
        v = ((v >> 2) & 0x3333333333333333ULL) | ((v & 0x3333333333333333ULL) << 2); \
        v = ((v >> 4) & 0x0F0F0F0F0F0F0F0FULL) | ((v & 0x0F0F0F0F0F0F0F0FULL) << 4); \
        v = __builtin_bswap64(v);                                             \
        return (T)(U)(v >> (64 - BITS));                                      \
    }

#define SL_MATH_INT_ALL(S, T, U, W, BITS, SIGNED, TMIN, TMAX)                 \
    SL_MATH_ANY_INT(S, T, SIGNED)                                             \
    SL_MATH_INT(S, T, U, W, BITS, SIGNED, TMIN, TMAX)

SL_MATH_INT_ALL(i8, int8_t, uint8_t, int32_t, 8, 1, INT8_MIN, INT8_MAX)
SL_MATH_INT_ALL(i16, int16_t, uint16_t, int32_t, 16, 1, INT16_MIN, INT16_MAX)
SL_MATH_INT_ALL(i32, int32_t, uint32_t, int64_t, 32, 1, INT32_MIN, INT32_MAX)
SL_MATH_INT_ALL(i64, int64_t, uint64_t, __int128, 64, 1, INT64_MIN, INT64_MAX)
SL_MATH_INT_ALL(int, long long, unsigned long long, __int128, 64, 1, LLONG_MIN,
                LLONG_MAX)
SL_MATH_INT_ALL(u8, uint8_t, uint8_t, uint32_t, 8, 0, 0, UINT8_MAX)
SL_MATH_INT_ALL(u16, uint16_t, uint16_t, uint32_t, 16, 0, 0, UINT16_MAX)
SL_MATH_INT_ALL(u32, uint32_t, uint32_t, uint64_t, 32, 0, 0, UINT32_MAX)
SL_MATH_INT_ALL(u64, uint64_t, uint64_t, unsigned __int128, 64, 0, 0, UINT64_MAX)

/* ---- fixed types ---- */

static inline uint64_t sl_math_float_bits(double x) {
    uint64_t u;
    memcpy(&u, &x, sizeof u);
    return u;
}

static inline double sl_math_float_from_bits(long long b) {
    uint64_t u = (uint64_t)b;
    double x;
    memcpy(&x, &u, sizeof x);
    return x;
}

static inline uint32_t sl_math_f32_bits(double x) {
    float f = (float)x;
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

static inline float sl_math_f32_from_bits(long long b) {
    uint32_t u = (uint32_t)b;
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}

/* A float to an int when it is one: false for NaN, the infinities and
 * anything outside int's range (2^63 itself is outside). */
static inline bool sl_math_to_int_checked(double r, long long *out) {
    if (!(r >= -9223372036854775808.0 && r < 9223372036854775808.0))
        return false;
    *out = (long long)r;
    return true;
}

static inline bool sl_math_floor_int(double x, long long *out) {
    return sl_math_to_int_checked(floor(x), out);
}

static inline bool sl_math_ceil_int(double x, long long *out) {
    return sl_math_to_int_checked(ceil(x), out);
}

static inline bool sl_math_round_int(double x, long long *out) {
    return sl_math_to_int_checked(round(x), out);
}

static inline bool sl_math_trunc_int(double x, long long *out) {
    return sl_math_to_int_checked(trunc(x), out);
}

/* n!, exact through 22! (the last that fits a double's mantissa), then
 * gamma(n + 1); inf past 170!, NaN for a negative n */
static inline double sl_math_factorial(long long n) {
    if (n < 0)
        return NAN;
    if (n > 170)
        return INFINITY;
    if (n <= 22) {
        double r = 1;
        for (long long i = 2; i <= n; i++)
            r *= (double)i;
        return r;
    }
    return tgamma((double)n + 1.0);
}

/* n choose k: 0 outside 0 <= k <= n; exact while the result fits 2^53 */
static inline double sl_math_binomial(long long n, long long k) {
    if (k < 0 || n < 0 || k > n)
        return 0;
    if (k > n - k)
        k = n - k;
    if (k > 1000) {
        int s1, s2, s3;
        return round(exp(lgamma_r((double)n + 1, &s1) -
                         lgamma_r((double)k + 1, &s2) -
                         lgamma_r((double)(n - k) + 1, &s3)));
    }
    double r = 1;
    for (long long i = 1; i <= k; i++)
        r = r * (double)(n - k + i) / (double)i;
    return round(r);
}

/* ---- formatting: the functions here that allocate ---- */

static inline char *sl_math_format_with(const char *fmt, int prec, double x) {
    sl_rt_preempt_disable();
    int n = snprintf(NULL, 0, fmt, prec, x);
    char small[64];
    char *buf = n < (int)sizeof small ? small : (char *)malloc((size_t)n + 1);
    snprintf(buf, (size_t)n + 1, fmt, prec, x);
    sl_rt_preempt_enable();
    char *s = sl_strdup(buf);
    if (buf != small)
        free(buf);
    return s;
}

/* `digits` significant digits (1..17), %g's style */
static inline char *sl_math_format(double x, long long digits) {
    int d = digits < 1 ? 1 : digits > 17 ? 17 : (int)digits;
    return sl_math_format_with("%.*g", d, x);
}

/* `decimals` places after the point (0..100), never an exponent */
static inline char *sl_math_format_fixed(double x, long long decimals) {
    int d = decimals < 0 ? 0 : decimals > 100 ? 100 : (int)decimals;
    return sl_math_format_with("%.*f", d, x);
}

/* scientific, `digits` after the point (0..40): 1.25e+03 */
static inline char *sl_math_format_sci(double x, long long digits) {
    int d = digits < 0 ? 0 : digits > 40 ? 40 : (int)digits;
    return sl_math_format_with("%.*e", d, x);
}
