/* ---- shortest float digits: Ryu (Ulf Adams, PLDI 2018) ----------------
 *
 * The fewest significant digits that read back as exactly the float given,
 * for to_str, println, inspect and json.encode (sl_fmt_f64/sl_fmt_f32,
 * sl_containers.c). Those used to find them by printing with snprintf at
 * 15, 16 and 17 digits and reading each back with strtod: correct, and
 * about 920 ns a float, seven times strconv.FormatFloat. Ryu computes the
 * digits directly from the float's bits with 128-bit multiplications by
 * the tables in sl_ryu_tables.c: no division by anything but 10, no
 * bignum, no retry.
 *
 * This is the reference algorithm (github.com/ulfjack/ryu, d2s.c) with one
 * generalization: the mantissa width and exponent bias are parameters, so
 * an f32 goes through the same code with its own neighbours, and its
 * digits are as short as an f32 needs. The proof's bounds hold for any
 * mantissa up to a double's 53 bits.
 *
 * Checked against the snprintf/strtod search it replaced, byte for byte
 * on the formatted text, over random bit patterns, powers of two and ten,
 * subnormals and the boundaries (tests/float_format, and the harness the
 * change was made with). */

#define SL_RYU_POW5_INV_BITCOUNT 125
#define SL_RYU_POW5_BITCOUNT 125

/* bitlength(5^e) = ceil(log2(5^e)) for e >= 1; 1 for e = 0 (e <= 3528) */
static inline int32_t sl_ryu_pow5bits(int32_t e) {
    return (int32_t)(((uint32_t)e * 1217359u) >> 19) + 1;
}

/* floor(log10(2^e)) and floor(log10(5^e)), e in [0, 1650] / [0, 2620] */
static inline uint32_t sl_ryu_log10pow2(int32_t e) {
    return ((uint32_t)e * 78913u) >> 18;
}

static inline uint32_t sl_ryu_log10pow5(int32_t e) {
    return ((uint32_t)e * 732923u) >> 20;
}

static inline uint32_t sl_ryu_pow5factor(uint64_t v) {
    uint32_t n = 0;
    for (;;) {
        uint64_t q = v / 5;
        if (v - 5 * q != 0)
            break;
        v = q;
        n++;
    }
    return n;
}

static inline bool sl_ryu_multiple_of_pow5(uint64_t v, uint32_t p) {
    return sl_ryu_pow5factor(v) >= p;
}

static inline bool sl_ryu_multiple_of_pow2(uint64_t v, uint32_t p) {
    return (v & ((1ull << p) - 1)) == 0;
}

/* (m * mul) >> j, mul a 128-bit {low, high}, j >= 64 */
static inline uint64_t sl_ryu_mulshift(uint64_t m, const uint64_t *mul,
                                       int32_t j) {
    unsigned __int128 b0 = (unsigned __int128)m * mul[0];
    unsigned __int128 b2 = (unsigned __int128)m * mul[1];
    return (uint64_t)(((b0 >> 64) + b2) >> (j - 64));
}

/* The shortest decimal m * 10^e10 in the rounding interval of the float
 * with the given biased exponent and mantissa (no implicit bit), mbits and
 * bias describing its format. Rounds to nearest, ties to even, as strtod
 * reads it back. Zero is handled by the caller. */
static void sl_ryu_shortest(uint64_t ieee_m, uint32_t ieee_e, int mbits,
                            int bias, uint64_t *out_m, int32_t *out_e) {
    int32_t e2;
    uint64_t m2;
    if (ieee_e == 0) {
        e2 = 1 - bias - mbits - 2;
        m2 = ieee_m;
    } else {
        e2 = (int32_t)ieee_e - bias - mbits - 2;
        m2 = (1ull << mbits) | ieee_m;
    }
    const bool accept_bounds = (m2 & 1) == 0;
    const uint64_t mv = 4 * m2;
    /* the lower neighbour is half as far when the mantissa is a power of
       two (except at the smallest exponent) */
    const uint32_t mm_shift = ieee_m != 0 || ieee_e <= 1;

    uint64_t vr, vp, vm;
    int32_t e10;
    bool vm_trailing_zeros = false, vr_trailing_zeros = false;
    if (e2 >= 0) {
        const uint32_t q = sl_ryu_log10pow2(e2) - (e2 > 3);
        e10 = (int32_t)q;
        const int32_t k = SL_RYU_POW5_INV_BITCOUNT + sl_ryu_pow5bits((int32_t)q) - 1;
        const int32_t i = -e2 + (int32_t)q + k;
        vr = sl_ryu_mulshift(4 * m2, SL_RYU_POW5_INV_SPLIT[q], i);
        vp = sl_ryu_mulshift(4 * m2 + 2, SL_RYU_POW5_INV_SPLIT[q], i);
        vm = sl_ryu_mulshift(4 * m2 - 1 - mm_shift, SL_RYU_POW5_INV_SPLIT[q], i);
        if (q <= 21) {
            /* only then can the exact values have q trailing zeros */
            if (mv % 5 == 0)
                vr_trailing_zeros = sl_ryu_multiple_of_pow5(mv, q);
            else if (accept_bounds)
                vm_trailing_zeros = sl_ryu_multiple_of_pow5(mv - 1 - mm_shift, q);
            else
                vp -= sl_ryu_multiple_of_pow5(mv + 2, q);
        }
    } else {
        const uint32_t q = sl_ryu_log10pow5(-e2) - (-e2 > 1);
        e10 = (int32_t)q + e2;
        const int32_t i = -e2 - (int32_t)q;
        const int32_t k = sl_ryu_pow5bits(i) - SL_RYU_POW5_BITCOUNT;
        const int32_t j = (int32_t)q - k;
        vr = sl_ryu_mulshift(4 * m2, SL_RYU_POW5_SPLIT[i], j);
        vp = sl_ryu_mulshift(4 * m2 + 2, SL_RYU_POW5_SPLIT[i], j);
        vm = sl_ryu_mulshift(4 * m2 - 1 - mm_shift, SL_RYU_POW5_SPLIT[i], j);
        if (q <= 1) {
            /* mv has at least q trailing 0 bits: {vr,vp,vm} are exact */
            vr_trailing_zeros = true;
            if (accept_bounds)
                vm_trailing_zeros = mm_shift == 1;
            else
                vp--;
        } else if (q < 63) {
            vr_trailing_zeros = sl_ryu_multiple_of_pow2(mv, q);
        }
    }

    /* Drop digits while the interval still has a shorter member. */
    int32_t removed = 0;
    uint8_t last_removed = 0;
    uint64_t output;
    if (vm_trailing_zeros || vr_trailing_zeros) {
        for (;;) {
            const uint64_t vp10 = vp / 10, vm10 = vm / 10;
            if (vp10 <= vm10)
                break;
            const uint32_t vm_mod = (uint32_t)(vm - 10 * vm10);
            const uint64_t vr10 = vr / 10;
            const uint32_t vr_mod = (uint32_t)(vr - 10 * vr10);
            vm_trailing_zeros &= vm_mod == 0;
            vr_trailing_zeros &= last_removed == 0;
            last_removed = (uint8_t)vr_mod;
            vr = vr10;
            vp = vp10;
            vm = vm10;
            removed++;
        }
        if (vm_trailing_zeros) {
            for (;;) {
                const uint64_t vm10 = vm / 10;
                if (vm - 10 * vm10 != 0)
                    break;
                const uint64_t vp10 = vp / 10, vr10 = vr / 10;
                const uint32_t vr_mod = (uint32_t)(vr - 10 * vr10);
                vr_trailing_zeros &= last_removed == 0;
                last_removed = (uint8_t)vr_mod;
                vr = vr10;
                vp = vp10;
                vm = vm10;
                removed++;
            }
        }
        if (vr_trailing_zeros && last_removed == 5 && vr % 2 == 0)
            last_removed = 4; /* exactly halfway: round to even */
        output = vr + ((vr == vm && (!accept_bounds || !vm_trailing_zeros)) ||
                       last_removed >= 5);
    } else {
        /* the common case: no trailing zeros to track */
        bool round_up = false;
        const uint64_t vp100 = vp / 100, vm100 = vm / 100;
        if (vp100 > vm100) {
            const uint64_t vr100 = vr / 100;
            round_up = vr - 100 * vr100 >= 50;
            vr = vr100;
            vp = vp100;
            vm = vm100;
            removed += 2;
        }
        for (;;) {
            const uint64_t vp10 = vp / 10, vm10 = vm / 10;
            if (vp10 <= vm10)
                break;
            const uint64_t vr10 = vr / 10;
            round_up = vr - 10 * vr10 >= 5;
            vr = vr10;
            vp = vp10;
            vm = vm10;
            removed++;
        }
        output = vr + (vr == vm || round_up);
    }
    *out_m = output;
    *out_e = e10 + removed;
}

/* The digits m * 10^e as %.<P>g writes them, where P is max(min_prec,
 * the digit count): what the old search produced, since it settled on the
 * first precision from min_prec up that read back. Plain notation while
 * the leading digit's exponent X is in [-4, P), "d.ddde+XX" otherwise;
 * no trailing zeros, no trailing point. */
static void sl_ryu_format(char *buf, size_t cap, bool neg, uint64_t m,
                          int32_t e, int min_prec) {
    char digits[24];
    int nd = 0;
    char tmp[24];
    do {
        tmp[nd++] = (char)('0' + m % 10);
        m /= 10;
    } while (m);
    for (int i = 0; i < nd; i++)
        digits[i] = tmp[nd - 1 - i];
    while (nd > 1 && digits[nd - 1] == '0') { /* m may end in zeros */
        nd--;
        e++;
    }
    const int x = e + nd - 1;
    const int p = nd > min_prec ? nd : min_prec;
    char out[64];
    int n = 0;
    if (neg)
        out[n++] = '-';
    if (x < -4 || x >= p) {
        out[n++] = digits[0];
        if (nd > 1) {
            out[n++] = '.';
            for (int i = 1; i < nd; i++)
                out[n++] = digits[i];
        }
        out[n++] = 'e';
        int ax = x;
        if (x < 0) {
            out[n++] = '-';
            ax = -x;
        } else {
            out[n++] = '+';
        }
        if (ax >= 100)
            out[n++] = (char)('0' + ax / 100);
        out[n++] = (char)('0' + ax / 10 % 10);
        out[n++] = (char)('0' + ax % 10);
    } else if (x >= 0) {
        for (int i = 0; i <= x; i++)
            out[n++] = i < nd ? digits[i] : '0';
        if (nd > x + 1) {
            out[n++] = '.';
            for (int i = x + 1; i < nd; i++)
                out[n++] = digits[i];
        }
    } else {
        out[n++] = '0';
        out[n++] = '.';
        for (int i = 0; i < -x - 1; i++)
            out[n++] = '0';
        for (int i = 0; i < nd; i++)
            out[n++] = digits[i];
    }
    if ((size_t)n >= cap)
        n = (int)cap - 1;
    memcpy(buf, out, (size_t)n);
    buf[n] = '\0';
}

/* A finite double's shortest text, in %g's style. */
static void sl_ryu_f64(char *buf, size_t cap, double v) {
    uint64_t bits;
    memcpy(&bits, &v, sizeof bits);
    const bool neg = (bits >> 63) != 0;
    const uint64_t ieee_m = bits & ((1ull << 52) - 1);
    const uint32_t ieee_e = (uint32_t)((bits >> 52) & 0x7ff);
    if (ieee_m == 0 && ieee_e == 0) {
        snprintf(buf, cap, neg ? "-0" : "0");
        return;
    }
    uint64_t m;
    int32_t e;
    sl_ryu_shortest(ieee_m, ieee_e, 52, 1023, &m, &e);
    sl_ryu_format(buf, cap, neg, m, e, 15);
}

/* A finite f32's: as short as an f32 needs, 0.1 and not 0.100000001 */
static void sl_ryu_f32(char *buf, size_t cap, float v) {
    uint32_t bits;
    memcpy(&bits, &v, sizeof bits);
    const bool neg = (bits >> 31) != 0;
    const uint64_t ieee_m = bits & ((1u << 23) - 1);
    const uint32_t ieee_e = (bits >> 23) & 0xff;
    if (ieee_m == 0 && ieee_e == 0) {
        snprintf(buf, cap, neg ? "-0" : "0");
        return;
    }
    uint64_t m;
    int32_t e;
    sl_ryu_shortest(ieee_m, ieee_e, 23, 127, &m, &e);
    sl_ryu_format(buf, cap, neg, m, e, 6);
}
