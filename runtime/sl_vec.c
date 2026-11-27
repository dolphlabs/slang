/* math/vec: bulk kernels over [float] and [f32], for embedding search,
 * recommendations and scoring. Native, because a slang loop pays a bounds
 * check per element and keeps C's strict left-to-right summation, which
 * no compiler may vectorize; here each reduction runs eight independent
 * accumulators over raw pointers, which the C compiler turns into SIMD
 * (SSE2 or NEON at the baseline target). The partial sums are combined
 * pairwise at the end, which is also more accurate than one running sum.
 *
 * Every kernel exists for double (_f64, a [float]) and float (_f32, an
 * [f32]); codegen picks one by the list's element type
 * (pkg_vec/sigs.c). f32 kernels accumulate in float lanes, as BLAS and
 * FAISS do, then combine in double.
 *
 * Nothing here parks or collects except the functions that return a new
 * list or bytes (top_k*, scores, quantize, dequantize, to_f32, to_f64);
 * the rest are leaves (native_is_leaf). Stores into an existing list are
 * of numbers, so they need no write barrier. */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SL_VEC_DATA(T, a) ((T *)(void *)(a)->data)

static void sl_vec_need_same(const sl_arr *a, const sl_arr *b, const char *at) {
    if (a->len != b->len) {
        char d[80];
        snprintf(d, sizeof d, "(lengths %lld and %lld)", a->len, b->len);
        sl_rt_fail("math/vec: the vectors differ in length", at, d);
    }
}

/* ---- AVX2 + FMA, chosen at run time on x86-64 ----
 *
 * slang's C targets the baseline x86-64 (SSE2), so the portable kernels
 * below use 128-bit vectors. On a CPU with AVX2 and FMA (nearly every
 * x86 server since 2013) the hot loops run 256-bit fused multiply-adds
 * instead: about 4x faster on a 1536-float dot product. The check runs
 * once; arm64 has NEON in its baseline and needs none. A sum computed on
 * one path can differ from the other's in its last bits (a different
 * order of additions), as numpy's results do between machines. */
#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#define SL_VEC_X86 1
static int sl_vec_avx2_state = -1;

static int sl_vec_avx2(void) {
    int v = __atomic_load_n(&sl_vec_avx2_state, __ATOMIC_RELAXED);
    if (v < 0) {
        __builtin_cpu_init();
        v = __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");
        __atomic_store_n(&sl_vec_avx2_state, v, __ATOMIC_RELAXED);
    }
    return v;
}

/* Sixteen double or thirty-two float accumulators: four and four 256-bit
 * registers, enough to hide the FMA latency. */
#define SL_VEC_AVX(S, T, W)                                                   \
    __attribute__((target("avx2,fma"))) static double                         \
    sl_vec_dot_avx_##S(const T *restrict x, const T *restrict y, long long n) \
    {                                                                         \
        T acc[W] = {0};                                                       \
        long long i = 0;                                                      \
        for (; i + W <= n; i += W)                                            \
            for (int k = 0; k < W; k++) acc[k] += x[i + k] * y[i + k];        \
        double s = 0.0;                                                       \
        for (int k = 0; k < W; k++) s += acc[k];                              \
        for (; i < n; i++) s += (double)x[i] * y[i];                          \
        return s;                                                             \
    }                                                                         \
    __attribute__((target("avx2,fma"))) static double                         \
    sl_vec_sqdist_avx_##S(const T *restrict x, const T *restrict y,           \
                          long long n) {                                      \
        T acc[W] = {0};                                                       \
        long long i = 0;                                                      \
        for (; i + W <= n; i += W)                                            \
            for (int k = 0; k < W; k++) {                                     \
                T d = x[i + k] - y[i + k];                                    \
                acc[k] += d * d;                                              \
            }                                                                 \
        double s = 0.0;                                                       \
        for (int k = 0; k < W; k++) s += acc[k];                              \
        for (; i < n; i++) {                                                  \
            double d = (double)x[i] - y[i];                                   \
            s += d * d;                                                       \
        }                                                                     \
        return s;                                                             \
    }

SL_VEC_AVX(f64, double, 16)
SL_VEC_AVX(f32, float, 32)

/* q . r and r . r in one pass over r, for cosine search: the row is read
 * once instead of twice. */
#define SL_VEC_AVX2X(S, T, W)                                                 \
    __attribute__((target("avx2,fma"))) static double                         \
    sl_vec_dot2_avx_##S(const T *restrict q, const T *restrict r,             \
                        long long n, double *rr) {                            \
        T d[W] = {0}, e[W] = {0};                                             \
        long long i = 0;                                                      \
        for (; i + W <= n; i += W)                                            \
            for (int k = 0; k < W; k++) {                                     \
                d[k] += q[i + k] * r[i + k];                                  \
                e[k] += r[i + k] * r[i + k];                                  \
            }                                                                 \
        double sd = 0.0, se = 0.0;                                            \
        for (int k = 0; k < W; k++) {                                         \
            sd += d[k];                                                       \
            se += e[k];                                                       \
        }                                                                     \
        for (; i < n; i++) {                                                  \
            sd += (double)q[i] * r[i];                                        \
            se += (double)r[i] * r[i];                                        \
        }                                                                     \
        *rr = se;                                                             \
        return sd;                                                            \
    }

SL_VEC_AVX2X(f64, double, 8)
SL_VEC_AVX2X(f32, float, 16)
#define SL_VEC_TRY_AVX(call)                                                  \
    do {                                                                      \
        if (n >= 32 && sl_vec_avx2()) return call;                            \
    } while (0)
#else
#define SL_VEC_TRY_AVX(call) do { } while (0)
#endif

/* ---- reductions, generated for both element types ---- */

#define SL_VEC_REDUCE(S, T, ACC)                                              \
    static double sl_vec_dot_raw_##S(const T *restrict x,                     \
                                     const T *restrict y, long long n);       \
    SL_API double sl_math_vec_dot_##S(sl_arr *a, sl_arr *b, const char *at) {  \
        sl_vec_need_same(a, b, at);                                           \
        return sl_vec_dot_raw_##S(SL_VEC_DATA(T, a), SL_VEC_DATA(T, b),       \
                                  a->len);                                    \
    }                                                                         \
    SL_API double sl_math_vec_sum_##S(sl_arr *a) {                            \
        const T *restrict x = SL_VEC_DATA(T, a);                              \
        long long n = a->len, i = 0;                                          \
        ACC s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;   \
        for (; i + 8 <= n; i += 8) {                                          \
            s0 += x[i];     s1 += x[i + 1]; s2 += x[i + 2]; s3 += x[i + 3];   \
            s4 += x[i + 4]; s5 += x[i + 5]; s6 += x[i + 6]; s7 += x[i + 7];   \
        }                                                                     \
        double s = (((double)s0 + s1) + ((double)s2 + s3)) +                  \
                   (((double)s4 + s5) + ((double)s6 + s7));                   \
        for (; i < n; i++) s += x[i];                                         \
        return s;                                                             \
    }                                                                         \
    static double sl_vec_sqdist_raw_##S(const T *restrict x,                  \
                                        const T *restrict y, long long n) {   \
        SL_VEC_TRY_AVX(sl_vec_sqdist_avx_##S(x, y, n));                       \
        long long i = 0;                                                      \
        ACC s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;   \
        for (; i + 8 <= n; i += 8) {                                          \
            ACC d0 = x[i] - y[i], d1 = x[i + 1] - y[i + 1];                   \
            ACC d2 = x[i + 2] - y[i + 2], d3 = x[i + 3] - y[i + 3];           \
            ACC d4 = x[i + 4] - y[i + 4], d5 = x[i + 5] - y[i + 5];           \
            ACC d6 = x[i + 6] - y[i + 6], d7 = x[i + 7] - y[i + 7];           \
            s0 += d0 * d0; s1 += d1 * d1; s2 += d2 * d2; s3 += d3 * d3;       \
            s4 += d4 * d4; s5 += d5 * d5; s6 += d6 * d6; s7 += d7 * d7;       \
        }                                                                     \
        double s = (((double)s0 + s1) + ((double)s2 + s3)) +                  \
                   (((double)s4 + s5) + ((double)s6 + s7));                   \
        for (; i < n; i++) {                                                  \
            double d = (double)x[i] - y[i];                                   \
            s += d * d;                                                       \
        }                                                                     \
        return s;                                                             \
    }                                                                         \
    static double sl_vec_dot_raw_##S(const T *restrict x,                     \
                                     const T *restrict y, long long n) {      \
        SL_VEC_TRY_AVX(sl_vec_dot_avx_##S(x, y, n));                          \
        long long i = 0;                                                      \
        ACC s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;   \
        for (; i + 8 <= n; i += 8) {                                          \
            s0 += x[i] * y[i];         s1 += x[i + 1] * y[i + 1];             \
            s2 += x[i + 2] * y[i + 2]; s3 += x[i + 3] * y[i + 3];             \
            s4 += x[i + 4] * y[i + 4]; s5 += x[i + 5] * y[i + 5];             \
            s6 += x[i + 6] * y[i + 6]; s7 += x[i + 7] * y[i + 7];             \
        }                                                                     \
        double s = (((double)s0 + s1) + ((double)s2 + s3)) +                  \
                   (((double)s4 + s5) + ((double)s6 + s7));                   \
        for (; i < n; i++) s += (double)x[i] * y[i];                          \
        return s;                                                             \
    }                                                                         \
    static double sl_vec_dot2_raw_##S(const T *restrict q,                    \
                                      const T *restrict r, long long n,       \
                                      double *rr) {                           \
        SL_VEC_TRY_AVX(sl_vec_dot2_avx_##S(q, r, n, rr));                     \
        long long i = 0;                                                      \
        ACC d0 = 0, d1 = 0, d2 = 0, d3 = 0, e0 = 0, e1 = 0, e2 = 0, e3 = 0;   \
        for (; i + 4 <= n; i += 4) {                                          \
            d0 += q[i] * r[i];         e0 += r[i] * r[i];                     \
            d1 += q[i + 1] * r[i + 1]; e1 += r[i + 1] * r[i + 1];             \
            d2 += q[i + 2] * r[i + 2]; e2 += r[i + 2] * r[i + 2];             \
            d3 += q[i + 3] * r[i + 3]; e3 += r[i + 3] * r[i + 3];             \
        }                                                                     \
        double sd = ((double)d0 + d1) + ((double)d2 + d3);                    \
        double se = ((double)e0 + e1) + ((double)e2 + e3);                    \
        for (; i < n; i++) {                                                  \
            sd += (double)q[i] * r[i];                                        \
            se += (double)r[i] * r[i];                                        \
        }                                                                     \
        *rr = se;                                                             \
        return sd;                                                            \
    }                                                                         \
    SL_API double sl_math_vec_norm_##S(sl_arr *a) {                           \
        const T *x = SL_VEC_DATA(T, a);                                       \
        return sqrt(sl_vec_dot_raw_##S(x, x, a->len));                        \
    }                                                                         \
    SL_API double sl_math_vec_distance_##S(sl_arr *a, sl_arr *b,              \
                                           const char *at) {                  \
        sl_vec_need_same(a, b, at);                                           \
        return sqrt(sl_vec_sqdist_raw_##S(SL_VEC_DATA(T, a),                  \
                                          SL_VEC_DATA(T, b), a->len));        \
    }                                                                         \
    SL_API double sl_math_vec_distance2_##S(sl_arr *a, sl_arr *b,             \
                                            const char *at) {                 \
        sl_vec_need_same(a, b, at);                                           \
        return sl_vec_sqdist_raw_##S(SL_VEC_DATA(T, a), SL_VEC_DATA(T, b),    \
                                     a->len);                                 \
    }                                                                         \
    SL_API double sl_math_vec_cosine_##S(sl_arr *a, sl_arr *b,                \
                                         const char *at) {                    \
        sl_vec_need_same(a, b, at);                                           \
        const T *x = SL_VEC_DATA(T, a), *y = SL_VEC_DATA(T, b);               \
        double d = sl_vec_dot_raw_##S(x, y, a->len);                          \
        double nn = sqrt(sl_vec_dot_raw_##S(x, x, a->len) *                   \
                         sl_vec_dot_raw_##S(y, y, b->len));                   \
        return nn == 0.0 ? NAN : d / nn;                                      \
    }                                                                         \
    /* ---- in place ---- */                                                 \
    SL_API void sl_math_vec_scale_##S(sl_arr *a, double s) {                  \
        T *restrict x = SL_VEC_DATA(T, a);                                    \
        T f = (T)s;                                                           \
        for (long long i = 0; i < a->len; i++) x[i] *= f;                     \
    }                                                                         \
    SL_API void sl_math_vec_axpy_##S(double alpha, sl_arr *xa, sl_arr *ya,    \
                                     const char *at) {                        \
        sl_vec_need_same(xa, ya, at);                                         \
        const T *restrict x = SL_VEC_DATA(T, xa);                             \
        T *restrict y = SL_VEC_DATA(T, ya);                                   \
        T f = (T)alpha;                                                       \
        for (long long i = 0; i < ya->len; i++) y[i] += f * x[i];             \
    }                                                                         \
    SL_API void sl_math_vec_add_##S(sl_arr *ya, sl_arr *xa, const char *at) { \
        sl_vec_need_same(xa, ya, at);                                         \
        const T *restrict x = SL_VEC_DATA(T, xa);                             \
        T *restrict y = SL_VEC_DATA(T, ya);                                   \
        for (long long i = 0; i < ya->len; i++) y[i] += x[i];                 \
    }                                                                         \
    SL_API void sl_math_vec_sub_##S(sl_arr *ya, sl_arr *xa, const char *at) { \
        sl_vec_need_same(xa, ya, at);                                         \
        const T *restrict x = SL_VEC_DATA(T, xa);                             \
        T *restrict y = SL_VEC_DATA(T, ya);                                   \
        for (long long i = 0; i < ya->len; i++) y[i] -= x[i];                 \
    }                                                                         \
    SL_API void sl_math_vec_mul_##S(sl_arr *ya, sl_arr *xa, const char *at) { \
        sl_vec_need_same(xa, ya, at);                                         \
        const T *restrict x = SL_VEC_DATA(T, xa);                             \
        T *restrict y = SL_VEC_DATA(T, ya);                                   \
        for (long long i = 0; i < ya->len; i++) y[i] *= x[i];                 \
    }                                                                         \
    /* divides rather than multiplying by 1/norm: each element correctly  \
       rounded, so [3, 4] becomes exactly [0.6, 0.8] */                      \
    SL_API double sl_math_vec_normalize_##S(sl_arr *a) {                      \
        double nrm = sl_math_vec_norm_##S(a);                                 \
        if (nrm > 0.0 && isfinite(nrm)) {                                     \
            T *restrict x = SL_VEC_DATA(T, a);                                \
            for (long long i = 0; i < a->len; i++)                            \
                x[i] = (T)((double)x[i] / nrm);                               \
        }                                                                     \
        return nrm;                                                           \
    }                                                                         \
    SL_API long long sl_math_vec_argmax_##S(sl_arr *a) {                      \
        const T *x = SL_VEC_DATA(T, a);                                       \
        long long best = -1;                                                  \
        for (long long i = 0; i < a->len; i++)                                \
            if (x[i] == x[i] && (best < 0 || x[i] > x[best])) best = i;       \
        return best;                                                          \
    }                                                                         \
    SL_API long long sl_math_vec_argmin_##S(sl_arr *a) {                      \
        const T *x = SL_VEC_DATA(T, a);                                       \
        long long best = -1;                                                  \
        for (long long i = 0; i < a->len; i++)                                \
            if (x[i] == x[i] && (best < 0 || x[i] < x[best])) best = i;       \
        return best;                                                          \
    }

SL_VEC_REDUCE(f64, double, double)
SL_VEC_REDUCE(f32, float, float)

/* ---- top k ---- */

/* A min-heap of (score, index) holding the best k so far: the root is the
 * worst kept, replaced by anything better. O(n log k), k slots of memory,
 * no copy of the scores. Ties keep the lower index. */
typedef struct {
    double s;
    long long i;
} sl_vec_hit;

static int sl_vec_worse(const sl_vec_hit *a, const sl_vec_hit *b) {
    return a->s < b->s || (a->s == b->s && a->i > b->i);
}

static void sl_vec_sift_down(sl_vec_hit *h, long long n, long long at) {
    for (;;) {
        long long l = 2 * at + 1, m = at;
        if (l < n && sl_vec_worse(&h[l], &h[m])) m = l;
        if (l + 1 < n && sl_vec_worse(&h[l + 1], &h[m])) m = l + 1;
        if (m == at) return;
        sl_vec_hit t = h[at];
        h[at] = h[m];
        h[m] = t;
        at = m;
    }
}

static void sl_vec_offer(sl_vec_hit *h, long long *n, long long k, double s,
                         long long i) {
    if (s != s) return; /* NaN never ranks */
    sl_vec_hit c = {s, i};
    if (*n < k) {
        long long at = (*n)++;
        h[at] = c;
        while (at > 0) {
            long long p = (at - 1) / 2;
            if (!sl_vec_worse(&h[at], &h[p])) break;
            sl_vec_hit t = h[at];
            h[at] = h[p];
            h[p] = t;
            at = p;
        }
    } else if (sl_vec_worse(&h[0], &c)) {
        h[0] = c;
        sl_vec_sift_down(h, *n, 0);
    }
}

/* The heap's indexes, best first, as a new [int]. Frees the heap. */
static sl_arr *sl_vec_hits_out(sl_vec_hit *h, long long n) {
    /* heapsort the min-heap: repeatedly move the worst to the end */
    for (long long end = n - 1; end > 0; end--) {
        sl_vec_hit t = h[0];
        h[0] = h[end];
        h[end] = t;
        sl_vec_sift_down(h, end, 0);
    }
    sl_arr *out = sl_arr_new(sizeof(long long), SL_ELEM_NOPTR);
    sl_arr_reserve(out, n > 0 ? n : 1);
    long long *o = SL_VEC_DATA(long long, out);
    for (long long j = 0; j < n; j++) o[j] = h[j].i;
    out->len = n;
    sl_rt_preempt_disable();
    free(h);
    sl_rt_preempt_enable();
    return out;
}

static sl_vec_hit *sl_vec_heap(long long k) {
    sl_rt_preempt_disable();
    sl_vec_hit *h = (sl_vec_hit *)malloc(sizeof(sl_vec_hit) * (size_t)(k > 0 ? k : 1));
    sl_rt_preempt_enable();
    if (!h) sl_rt_fail("math/vec: out of memory", "", "");
    return h;
}

static void sl_vec_rows_check(sl_arr *q, sl_arr *rows, long long dim,
                              const char *at) {
    if (dim <= 0 || dim != q->len) {
        char d[96];
        snprintf(d, sizeof d, "(dim %lld, query length %lld)", dim, q->len);
        sl_rt_fail("math/vec: dim must be the query's length", at, d);
    }
    if (rows->len % dim != 0) {
        char d[96];
        snprintf(d, sizeof d, "(rows length %lld, dim %lld)", rows->len, dim);
        sl_rt_fail("math/vec: rows is not a whole number of vectors", at, d);
    }
}

#define SL_VEC_TOPK(S, T)                                                     \
    SL_API sl_arr *sl_math_vec_top_k_##S(sl_arr *a, long long k) {            \
        const T *x = SL_VEC_DATA(T, a);                                       \
        if (k > a->len) k = a->len;                                           \
        if (k < 0) k = 0;                                                     \
        sl_vec_hit *h = sl_vec_heap(k);                                       \
        long long n = 0;                                                      \
        if (k > 0)                                                            \
            for (long long i = 0; i < a->len; i++)                            \
                sl_vec_offer(h, &n, k, (double)x[i], i);                      \
        return sl_vec_hits_out(h, n);                                         \
    }                                                                         \
    SL_API sl_arr *sl_math_vec_scores_##S(sl_arr *q, sl_arr *rows,            \
                                          long long dim, const char *at) {    \
        sl_vec_rows_check(q, rows, dim, at);                                  \
        long long nrows = rows->len / dim;                                    \
        sl_arr *out = sl_arr_new(sizeof(double), SL_ELEM_NOPTR);              \
        sl_arr_reserve(out, nrows > 0 ? nrows : 1);                           \
        double *o = SL_VEC_DATA(double, out);                                 \
        const T *qv = SL_VEC_DATA(T, q), *r = SL_VEC_DATA(T, rows);           \
        for (long long j = 0; j < nrows; j++)                                 \
            o[j] = sl_vec_dot_raw_##S(qv, r + j * dim, dim);                  \
        out->len = nrows;                                                     \
        return out;                                                           \
    }                                                                         \
    SL_API sl_arr *sl_math_vec_top_k_dot_##S(sl_arr *q, sl_arr *rows,         \
                                             long long dim, long long k,      \
                                             const char *at) {                \
        sl_vec_rows_check(q, rows, dim, at);                                  \
        long long nrows = rows->len / dim;                                    \
        if (k > nrows) k = nrows;                                             \
        if (k < 0) k = 0;                                                     \
        sl_vec_hit *h = sl_vec_heap(k);                                       \
        long long n = 0;                                                      \
        const T *qv = SL_VEC_DATA(T, q), *r = SL_VEC_DATA(T, rows);           \
        if (k > 0)                                                            \
            for (long long j = 0; j < nrows; j++)                             \
                sl_vec_offer(h, &n, k, sl_vec_dot_raw_##S(qv, r + j * dim, dim), j); \
        return sl_vec_hits_out(h, n);                                         \
    }                                                                         \
    SL_API sl_arr *sl_math_vec_top_k_cosine_##S(sl_arr *q, sl_arr *rows,      \
                                                long long dim, long long k,   \
                                                const char *at) {             \
        sl_vec_rows_check(q, rows, dim, at);                                  \
        long long nrows = rows->len / dim;                                    \
        if (k > nrows) k = nrows;                                             \
        if (k < 0) k = 0;                                                     \
        sl_vec_hit *h = sl_vec_heap(k);                                       \
        long long n = 0;                                                      \
        const T *qv = SL_VEC_DATA(T, q), *r = SL_VEC_DATA(T, rows);           \
        double qn = sqrt(sl_vec_dot_raw_##S(qv, qv, dim));                    \
        if (k > 0 && qn > 0.0)                                                \
            for (long long j = 0; j < nrows; j++) {                           \
                double rr;                                                    \
                double d = sl_vec_dot2_raw_##S(qv, r + j * dim, dim, &rr);    \
                if (rr > 0.0)                                                 \
                    sl_vec_offer(h, &n, k, d / (qn * sqrt(rr)), j);           \
            }                                                                 \
        return sl_vec_hits_out(h, n);                                         \
    }

SL_VEC_TOPK(f64, double)
SL_VEC_TOPK(f32, float)

/* ---- conversion and int8 quantization ---- */

SL_API sl_arr *sl_math_vec_to_f32(sl_arr *a) {
    sl_arr *out = sl_arr_new(sizeof(float), SL_ELEM_NOPTR);
    sl_arr_reserve(out, a->len > 0 ? a->len : 1);
    const double *x = SL_VEC_DATA(double, a);
    float *o = SL_VEC_DATA(float, out);
    for (long long i = 0; i < a->len; i++) o[i] = (float)x[i];
    out->len = a->len;
    return out;
}

SL_API sl_arr *sl_math_vec_to_f64(sl_arr *a) {
    sl_arr *out = sl_arr_new(sizeof(double), SL_ELEM_NOPTR);
    sl_arr_reserve(out, a->len > 0 ? a->len : 1);
    const float *x = SL_VEC_DATA(float, a);
    double *o = SL_VEC_DATA(double, out);
    for (long long i = 0; i < a->len; i++) o[i] = x[i];
    out->len = a->len;
    return out;
}

/* Symmetric int8: code = round(x / scale), scale = max|x| / 127, stored
 * as 4 bytes of little-endian f32 scale then one byte per element: a
 * quarter of an [f32]'s memory, an eighth of a [float]'s. */
#define SL_VEC_QUANT(S, T)                                                    \
    SL_API sl_bytes *sl_math_vec_quantize_##S(sl_arr *a) {                    \
        const T *x = SL_VEC_DATA(T, a);                                       \
        double mx = 0.0;                                                      \
        for (long long i = 0; i < a->len; i++) {                              \
            double v = fabs((double)x[i]);                                    \
            if (v > mx && isfinite(v)) mx = v;                                \
        }                                                                     \
        float scale = mx > 0.0 ? (float)(mx / 127.0) : 1.0f;                  \
        sl_bytes *b = sl_bytes_alloc_uninit(4 + a->len);                      \
        uint32_t bits;                                                        \
        memcpy(&bits, &scale, 4);                                             \
        b->ptr[0] = (unsigned char)bits;                                      \
        b->ptr[1] = (unsigned char)(bits >> 8);                               \
        b->ptr[2] = (unsigned char)(bits >> 16);                              \
        b->ptr[3] = (unsigned char)(bits >> 24);                              \
        double inv = 1.0 / scale;                                             \
        for (long long i = 0; i < a->len; i++) {                              \
            double v = (double)x[i] * inv;                                    \
            long long c = (v != v) ? 0 : (long long)lrint(v);                 \
            if (c > 127) c = 127;                                             \
            if (c < -127) c = -127;                                           \
            b->ptr[4 + i] = (unsigned char)(int8_t)c;                         \
        }                                                                     \
        return b;                                                             \
    }

SL_VEC_QUANT(f64, double)
SL_VEC_QUANT(f32, float)

static float sl_vec_qscale(const sl_bytes *q) {
    uint32_t bits = (uint32_t)q->ptr[0] | ((uint32_t)q->ptr[1] << 8) |
                    ((uint32_t)q->ptr[2] << 16) | ((uint32_t)q->ptr[3] << 24);
    float s;
    memcpy(&s, &bits, 4);
    return s;
}

static void sl_vec_need_q(const sl_bytes *q, const char *at) {
    if (q->len < 4)
        sl_rt_fail("math/vec: not a quantized vector (shorter than its 4-byte scale)", at, "");
}

SL_API sl_arr *sl_math_vec_dequantize(sl_bytes *q, const char *at) {
    sl_vec_need_q(q, at);
    long long n = q->len - 4;
    float s = sl_vec_qscale(q);
    sl_arr *out = sl_arr_new(sizeof(double), SL_ELEM_NOPTR);
    sl_arr_reserve(out, n > 0 ? n : 1);
    double *o = SL_VEC_DATA(double, out);
    for (long long i = 0; i < n; i++) o[i] = (double)(int8_t)q->ptr[4 + i] * s;
    out->len = n;
    return out;
}

/* The dot product of two quantized vectors: an exact int32 sum of code
 * products (at most 127 * 127 * 2^17 per lane before overflow, so lanes
 * are flushed into a 64-bit total every 65536 elements), times both
 * scales. */
SL_API double sl_math_vec_dot_q(sl_bytes *a, sl_bytes *b, const char *at) {
    sl_vec_need_q(a, at);
    sl_vec_need_q(b, at);
    if (a->len != b->len) {
        char d[80];
        snprintf(d, sizeof d, "(lengths %lld and %lld)", a->len - 4, b->len - 4);
        sl_rt_fail("math/vec: the vectors differ in length", at, d);
    }
    const int8_t *restrict x = (const int8_t *)(a->ptr + 4);
    const int8_t *restrict y = (const int8_t *)(b->ptr + 4);
    long long n = a->len - 4, i = 0, total = 0;
    while (i < n) {
        long long end = i + 65536 < n ? i + 65536 : n;
        int32_t s = 0;
        for (; i < end; i++) s += (int32_t)x[i] * (int32_t)y[i];
        total += s;
    }
    return (double)total * (double)sl_vec_qscale(a) * (double)sl_vec_qscale(b);
}
/* SL_DEV_DECL_BEGIN */
#define SL_VEC_API_DECL(S, T)                                               \
    SL_API_DECL double sl_math_vec_dot_##S(sl_arr *a, sl_arr *b, const char *at); \
    SL_API_DECL double sl_math_vec_sum_##S(sl_arr *a);                        \
    SL_API_DECL double sl_math_vec_norm_##S(sl_arr *a);                       \
    SL_API_DECL double sl_math_vec_distance_##S(sl_arr *a, sl_arr *b, const char *at); \
    SL_API_DECL double sl_math_vec_distance2_##S(sl_arr *a, sl_arr *b, const char *at); \
    SL_API_DECL double sl_math_vec_cosine_##S(sl_arr *a, sl_arr *b, const char *at); \
    SL_API_DECL void sl_math_vec_scale_##S(sl_arr *a, double s);              \
    SL_API_DECL void sl_math_vec_axpy_##S(double alpha, sl_arr *xa, sl_arr *ya, const char *at); \
    SL_API_DECL void sl_math_vec_add_##S(sl_arr *ya, sl_arr *xa, const char *at); \
    SL_API_DECL void sl_math_vec_sub_##S(sl_arr *ya, sl_arr *xa, const char *at); \
    SL_API_DECL void sl_math_vec_mul_##S(sl_arr *ya, sl_arr *xa, const char *at); \
    SL_API_DECL double sl_math_vec_normalize_##S(sl_arr *a);                  \
    SL_API_DECL long long sl_math_vec_argmax_##S(sl_arr *a);                  \
    SL_API_DECL long long sl_math_vec_argmin_##S(sl_arr *a);                  \
    SL_API_DECL sl_arr *sl_math_vec_top_k_##S(sl_arr *a, long long k);        \
    SL_API_DECL sl_arr *sl_math_vec_scores_##S(sl_arr *q, sl_arr *rows, long long dim, const char *at); \
    SL_API_DECL sl_arr *sl_math_vec_top_k_dot_##S(sl_arr *q, sl_arr *rows, long long dim, long long k, const char *at); \
    SL_API_DECL sl_arr *sl_math_vec_top_k_cosine_##S(sl_arr *q, sl_arr *rows, long long dim, long long k, const char *at); \
    SL_API_DECL sl_bytes *sl_math_vec_quantize_##S(sl_arr *a);
SL_VEC_API_DECL(f64, double)
SL_VEC_API_DECL(f32, float)
/* SL_DEV_DECL_END */
