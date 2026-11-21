/* Signatures for 'math/vec' -- see native.c's native_check/native_gen,
 * and runtime/sl_vec.c for the kernels.
 *
 * NA_VEC is a [float] or an [f32]. Every NA_VEC argument of one call has
 * the same element type, and codegen calls the kernel for it
 * (sl_math_vec_dot_f64 or _f32). Native because a slang loop checks the
 * bounds of every element and must keep C's strict summation order, so
 * no compiler may vectorize it; the kernels run eight accumulators over
 * raw pointers instead. Pure C and libm: the import adds no link flag. */

#include "../internal.h"

const NatSig VEC_SIGS[] = {
    /* reductions: no allocation, no safepoint (native_is_leaf). A pair
       of vectors of different lengths panics, naming the call. */
    {"math/vec", "dot", 2, {NA_VEC, NA_VEC}, "float", 0},
    {"math/vec", "sum", 1, {NA_VEC}, "float", 0},
    {"math/vec", "norm", 1, {NA_VEC}, "float", 0},
    {"math/vec", "distance", 2, {NA_VEC, NA_VEC}, "float", 0},
    {"math/vec", "distance2", 2, {NA_VEC, NA_VEC}, "float", 0},
    {"math/vec", "cosine", 2, {NA_VEC, NA_VEC}, "float", 0},
    {"math/vec", "argmax", 1, {NA_VEC}, "int", 0},
    {"math/vec", "argmin", 1, {NA_VEC}, "int", 0},

    /* in place: the first list changes */
    {"math/vec", "scale", 2, {NA_VEC, NA_F64}, NULL, 0},
    {"math/vec", "axpy", 3, {NA_F64, NA_VEC, NA_VEC}, NULL, 0},
    {"math/vec", "add", 2, {NA_VEC, NA_VEC}, NULL, 0},
    {"math/vec", "sub", 2, {NA_VEC, NA_VEC}, NULL, 0},
    {"math/vec", "mul", 2, {NA_VEC, NA_VEC}, NULL, 0},
    {"math/vec", "normalize", 1, {NA_VEC}, "float", 0},

    /* search: these return a new list */
    {"math/vec", "top_k", 2, {NA_VEC, NA_I64}, "[int]", 0},
    {"math/vec", "scores", 3, {NA_VEC, NA_VEC, NA_I64}, "[float]", 0},
    {"math/vec", "top_k_dot", 4, {NA_VEC, NA_VEC, NA_I64, NA_I64}, "[int]", 0},
    {"math/vec", "top_k_cosine", 4, {NA_VEC, NA_VEC, NA_I64, NA_I64}, "[int]", 0},

    /* storage: f32 halves a [float]; int8 quarters an [f32] */
    {"math/vec", "to_f32", 1, {NA_VEC}, "[f32]", 0},
    {"math/vec", "to_f64", 1, {NA_VEC}, "[float]", 0},
    {"math/vec", "quantize", 1, {NA_VEC}, "bytes", 0},
    {"math/vec", "dequantize", 1, {NA_BYTES}, "[float]", 0},
    {"math/vec", "dot_q", 2, {NA_BYTES, NA_BYTES}, "float", 0},
};

const int VEC_SIGS_LEN = (int)(sizeof(VEC_SIGS) / sizeof(VEC_SIGS[0]));
