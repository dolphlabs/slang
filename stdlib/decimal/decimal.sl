// Exact decimal arithmetic for money: up to 38 significant digits, an
// explicit scale, seven rounding modes, overflow as none or an error and
// never a wrap.
//
//     import "decimal";
//
//     let r = decimal.parse("19.99");            // result[Decimal, str]
//     guard let price = r else let e = err_of(r) { panic(e); }
//     let qty = decimal.from_int(3);
//     let total = decimal.mul(price, qty) ?? decimal.zero();      // 59.97
//     let vat = decimal.mul_round(total, decimal.parse("0.075") ?? decimal.zero(),
//                                 2, decimal.Rounding.HalfEven) ?? decimal.zero();
//     decimal.format(vat)                         // "4.50"
//     decimal.split(total, 2)                     // [29.99, 29.98]: no cent lost
//     decimal.to_units(total, 2, decimal.Rounding.HalfEven) ?? 0   // 5997
//
// A Decimal is a value: a coefficient of up to 38 digits and a scale
// (digits after the point, 0 to 38), so 59.97 is 5997 at scale 2. It is
// held by value, as five base-10^9 limbs, and no operation on it touches
// the GC heap except formatting (which builds a str), split and allocate
// (which build a list) and division by a divisor of ten or more digits.
// Build one with parse, from_int, from_units or from_float, not by hand.
//
// Scale is kept, as in Postgres's numeric: "1.50" stays 1.50, add keeps
// the larger scale, mul adds them. Compare with `eq` and `cmp`, which go
// by value (1.5 eq 1.50); structs have no `==`.
//
// Exactness. add, sub and mul are exact: none means the exact result
// needs more than 38 digits. mul_round, div and round round to the
// scale asked for, by the mode asked for; nothing rounds silently.
//
// In JSON a Decimal field is written as a string ("59.97", exact, safe
// for JavaScript clients) and read from a string or a number, exactly,
// without passing through a float. pg.arg_decimal and pg.get_decimal
// carry one to and from a numeric column.

import "strings";

// The most significant digits a Decimal holds, and the largest scale.
pub let MAX_DIGITS = 38;
pub let MAX_SCALE = 38;

// A decimal number. Its fields are the representation, not an API:
// make one with parse, from_int, from_units or from_float.
pub struct Decimal {
    l0: int,
    l1: int,
    l2: int,
    l3: int,
    l4: int,
    scale: int,
    neg: bool,
}

// How to round when a result has more digits than the scale allows.
// Down and Up are toward and away from zero; Floor and Ceiling toward
// negative and positive infinity. HalfEven (banker's rounding) is the
// usual choice for money: it does not drift up over many roundings.
pub enum Rounding {
    HalfEven,
    HalfUp,
    HalfDown,
    Down,
    Up,
    Floor,
    Ceiling,
}

// ---- making one ------------------------------------------------------------

// 0, at scale 0.
pub fn zero() -> Decimal {
    return Decimal { l0: 0, l1: 0, l2: 0, l3: 0, l4: 0, scale: 0, neg: false };
}

// n, at scale 0. Every int fits.
pub fn from_int(n: int) -> Decimal {
    return from_units(n, 0) ?? zero();
}

// units * 10^-scale: from_units(1999, 2) is 19.99. none if scale is
// outside 0 to 38.
pub fn from_units(units: int, scale: int) -> opt[Decimal] {
    if scale < 0 || scale > MAX_SCALE {
        return none;
    }
    let neg = units < 0;
    // The magnitude, as u64 so that the smallest int (whose negation does
    // not fit an int) comes out right.
    let m = units as u64;
    if neg {
        m = (0 - m);
    }
    let l0 = (m % (BASE as u64)) as int;
    m = m / (BASE as u64);
    let l1 = (m % (BASE as u64)) as int;
    let l2 = (m / (BASE as u64)) as int;
    return some(Decimal { l0: l0, l1: l1, l2: l2, l3: 0, l4: 0, scale: scale,
                          neg: neg && (l0 != 0 || l1 != 0 || l2 != 0) });
}

// The decimal written in s: an optional sign, digits, an optional
// fraction after a point, and an optional exponent ("1.5e3", "2E-4").
// Strict, like to_int: no spaces, no thousands separators, no leading or
// trailing point, no NaN or infinity. The scale is the number of
// fraction digits less the exponent ("1.50" has scale 2, "1.5e3" scale
// 0); trailing zeros past scale 38 are dropped when they are exact.
pub fn parse(s: str) -> result[Decimal, str] {
    return parse_bytes(to_bytes(s), 0, len(s));
}

// parse over b[lo..hi], with no str made: for a number inside a request
// body or a wire buffer.
pub fn parse_bytes(b: bytes, lo: int, hi: int) -> result[Decimal, str] {
    if lo < 0 || hi > len(b) || lo > hi {
        return err("decimal: range " + to_str(lo) + ".." + to_str(hi)
                   + " is outside the " + to_str(len(b)) + " bytes given");
    }
    if lo == hi {
        return err("decimal: cannot parse an empty string");
    }
    let i = lo;
    let neg = false;
    if b[i] == 45 || b[i] == 43 {   // - +
        neg = b[i] == 45;
        i += 1;
    }
    let acc = Acc { w: wzero(), chunk: 0, clen: 0, sig: 0, dropped: 0 };
    let int_digits = 0;
    let frac_digits = 0;
    while i < hi && b[i] >= 48 && b[i] <= 57 {
        if take_digit(&mut acc, b[i] - 48) {
            acc_push(&mut acc);
        }
        int_digits += 1;
        i += 1;
    }
    if int_digits == 0 {
        if i < hi && b[i] == 46 {
            return err("decimal: a number needs a digit before the point, as in 0.5");
        }
        return err("decimal: '" + shown(b, lo, hi) + "' is not a number");
    }
    if i < hi && b[i] == 46 {       // .
        i += 1;
        while i < hi && b[i] >= 48 && b[i] <= 57 {
            if take_digit(&mut acc, b[i] - 48) {
                acc_push(&mut acc);
            }
            frac_digits += 1;
            i += 1;
        }
        if frac_digits == 0 {
            return err("decimal: a number needs a digit after the point, as in 5.0");
        }
    }
    let exp = 0;
    if i < hi && (b[i] == 101 || b[i] == 69) {   // e E
        i += 1;
        let eneg = false;
        if i < hi && (b[i] == 45 || b[i] == 43) {
            eneg = b[i] == 45;
            i += 1;
        }
        let edigits = 0;
        while i < hi && b[i] >= 48 && b[i] <= 57 {
            if exp < 100000 {
                exp = exp * 10 + (b[i] - 48);
            }
            edigits += 1;
            i += 1;
        }
        if edigits == 0 {
            return err("decimal: an exponent needs digits, as in 1e3");
        }
        if eneg {
            exp = 0 - exp;
        }
    }
    if i != hi {
        return err("decimal: '" + shown(b, lo, hi) + "' is not a number (unexpected '"
                   + shown(b, i, i + 1) + "' at " + to_str(i - lo) + ")");
    }
    if acc.dropped > 0 {
        return err("decimal: '" + shown(b, lo, hi) + "' has more than 38 significant digits");
    }
    // Digits past 38 that were all zeros were not stored: they still
    // count toward the scale (or, in the integer part, as a factor of 10).
    let w = acc_value(&mut acc);
    let scale = frac_digits - exp;
    scale -= digits_not_stored(acc.sig);
    if scale < 0 {
        let grew = w_mul10k(&mut w, 0 - scale);
        if !grew || !w_fits(&w) {
            return err("decimal: '" + shown(b, lo, hi) + "' needs more than 38 digits");
        }
        scale = 0;
    }
    if scale > MAX_SCALE {
        // exact only if the excess digits are zeros
        let excess = scale - MAX_SCALE;
        if !w_div10k_exact(&mut w, excess) {
            return err("decimal: '" + shown(b, lo, hi) + "' has more than 38 digits after the point");
        }
        scale = MAX_SCALE;
    }
    return ok(from_wide(&w, scale, neg));
}

// The decimal nearest to f, rounded to `scale` digits by `mode`; none
// for NaN, an infinity, a scale outside 0 to 38, or a value past 38
// digits. f is read through its shortest round-trip text, so 0.1 gives
// exactly 0.1, not the binary fraction nearest it.
pub fn from_float(f: float, scale: int, mode: Rounding) -> opt[Decimal] {
    if f != f || f - f != 0.0 || scale < 0 || scale > MAX_SCALE {
        return none;
    }
    let r = parse(strings.from_float(f));
    guard let d = r else {
        return none;
    }
    return round(d, scale, mode);
}

// ---- reading one -----------------------------------------------------------

// The digits after the point.
pub fn scale_of(d: Decimal) -> int {
    return d.scale;
}

// How many significant digits the coefficient has (0 has 1).
pub fn precision(d: Decimal) -> int {
    return d_digits(d);
}

pub fn is_zero(d: Decimal) -> bool {
    return d.l0 == 0 && d.l1 == 0 && d.l2 == 0 && d.l3 == 0 && d.l4 == 0;
}

pub fn is_neg(d: Decimal) -> bool {
    return d.neg;
}

// -1, 0 or 1.
pub fn sign(d: Decimal) -> int {
    if (d.l0 | d.l1 | d.l2 | d.l3 | d.l4) == 0 {
        return 0;
    }
    if d.neg {
        return -1;
    }
    return 1;
}

// Plain notation, every digit of the scale kept: "-19.90", "0.005", "42".
pub fn format(d: Decimal) -> str {
    let nd = d_digits(d);
    let body = nd;
    if d.scale >= nd {
        body = d.scale + 1;      // "0.00ddd"
    }
    let n = body;
    if d.scale > 0 {
        n += 1;
    }
    if d.neg {
        n += 1;
    }
    let b = strings.bytes_zero(n);
    // digits from the right, nine per limb
    let pos = n - 1;
    let written = 0;
    let li = 0;
    let limb = d.l0;
    let left = 9;
    while written < body {
        if d.scale > 0 && written == d.scale {
            b[pos] = 46;
            pos -= 1;
        }
        if left == 0 {
            li += 1;
            limb = d_limb(d, li);
            left = 9;
        }
        b[pos] = 48 + limb % 10;
        limb /= 10;
        left -= 1;
        pos -= 1;
        written += 1;
    }
    if d.neg {
        b[0] = 45;
    }
    return strings.from_bytes(b, 0, n);
}

// d in units of 10^-scale, rounded by mode: to_units(19.999, 2, HalfUp)
// is 2000. none if scale is outside 0 to 38 or the units do not fit an
// int.
pub fn to_units(d: Decimal, scale: int, mode: Rounding) -> opt[int] {
    let r = round(d, scale, mode);
    guard let x = r else {
        return none;
    }
    if x.l4 != 0 || x.l3 != 0 || x.l2 > 9 {
        return none;
    }
    // at most 9223372036854775807 (8 below the most negative int)
    let hi = x.l2 * BASE + x.l1;              // < 1e10, fits
    if hi > 9223372036 || (hi == 9223372036 && x.l0 > 854775807 + bool_int(x.neg)) {
        return none;
    }
    if x.neg {
        // build the negative value directly: its magnitude may be 2^63
        return some(0 - hi * BASE - x.l0);
    }
    return some(hi * BASE + x.l0);
}

// d rounded to a whole number by mode, as an int; none past an int.
pub fn int_of(d: Decimal, mode: Rounding) -> opt[int] {
    return to_units(d, 0, mode);
}

// The float nearest to d. Floats cannot hold most decimals exactly: use
// this for display or statistics, never to compute money.
pub fn float_of(d: Decimal) -> float {
    return to_float_text(format(d));
}

// ---- comparing -------------------------------------------------------------

// -1, 0 or 1 as a is less than, equal to or greater than b, by value:
// cmp(1.5, 1.50) is 0.
pub fn cmp(a: Decimal, b: Decimal) -> int {
    let sa = sign(a);
    let sb = sign(b);
    if sa != sb {
        if sa < sb {
            return -1;
        }
        return 1;
    }
    if sa == 0 {
        return 0;
    }
    let c = mag_cmp(a, b);
    if a.neg {
        return 0 - c;
    }
    return c;
}

// a and b are the same number, whatever their scales.
pub fn eq(a: Decimal, b: Decimal) -> bool {
    return cmp(a, b) == 0;
}

pub fn lt(a: Decimal, b: Decimal) -> bool {
    return cmp(a, b) < 0;
}

pub fn le(a: Decimal, b: Decimal) -> bool {
    return cmp(a, b) <= 0;
}

pub fn gt(a: Decimal, b: Decimal) -> bool {
    return cmp(a, b) > 0;
}

pub fn ge(a: Decimal, b: Decimal) -> bool {
    return cmp(a, b) >= 0;
}

pub fn min(a: Decimal, b: Decimal) -> Decimal {
    if cmp(b, a) < 0 {
        return b;
    }
    return a;
}

pub fn max(a: Decimal, b: Decimal) -> Decimal {
    if cmp(b, a) > 0 {
        return b;
    }
    return a;
}

// ---- arithmetic ------------------------------------------------------------

pub fn neg(d: Decimal) -> Decimal {
    let r = d;
    r.neg = !d.neg && (d.l0 | d.l1 | d.l2 | d.l3 | d.l4) != 0;
    return r;
}

pub fn abs(d: Decimal) -> Decimal {
    let r = d;
    r.neg = false;
    return r;
}

// a + b, exactly, at the larger of the two scales; none past 38 digits.
pub fn add(a: Decimal, b: Decimal) -> opt[Decimal] {
    if a.scale == b.scale {
        // The common case, amounts in one currency: the five limbs
        // directly, through leaf helpers (no alignment, no Wide).
        if a.neg == b.neg {
            return d_add5(a, b, a.neg);
        }
        if d_cmp5(a, b) >= 0 {
            return some(d_sub5(a, b, a.neg));
        }
        return some(d_sub5(b, a, b.neg));
    }
    return add_signed(a, b, b.neg);
}

// a - b, exactly, at the larger of the two scales; none past 38 digits.
pub fn sub(a: Decimal, b: Decimal) -> opt[Decimal] {
    let bneg = !b.neg && (b.l0 | b.l1 | b.l2 | b.l3 | b.l4) != 0;
    if a.scale == b.scale {
        if a.neg == bneg {
            return d_add5(a, b, a.neg);
        }
        if d_cmp5(a, b) >= 0 {
            return some(d_sub5(a, b, a.neg));
        }
        return some(d_sub5(b, a, bneg));
    }
    return add_signed(a, b, bneg);
}

// a * b, exactly, at the sum of the scales; none if the product needs
// more than 38 digits or a scale past 38 (use mul_round for those).
pub fn mul(a: Decimal, b: Decimal) -> opt[Decimal] {
    let scale = a.scale + b.scale;
    if scale > MAX_SCALE {
        return none;
    }
    let p = mag_mul(a, b);
    if !w_fits(&p) {
        return none;
    }
    return some(from_wide(&p, scale, a.neg != b.neg));
}

// a * b rounded to `scale` digits by mode; none if scale is outside 0 to
// 38 or the rounded product needs more than 38 digits.
pub fn mul_round(a: Decimal, b: Decimal, scale: int, mode: Rounding) -> opt[Decimal] {
    if scale < 0 || scale > MAX_SCALE {
        return none;
    }
    let p = mag_mul(a, b);
    let neg = a.neg != b.neg;
    let exact = a.scale + b.scale;
    if exact > scale {
        w_div10k_round(&mut p, exact - scale, neg, mode);
    } else if exact < scale {
        if !w_mul10k(&mut p, scale - exact) {
            return none;
        }
    }
    if !w_fits(&p) {
        return none;
    }
    return some(from_wide(&p, scale, neg));
}

// a / b rounded to `scale` digits by mode. An error for division by
// zero, a scale outside 0 to 38, or a quotient past 38 digits.
pub fn div(a: Decimal, b: Decimal, scale: int, mode: Rounding) -> result[Decimal, str] {
    if is_zero(b) {
        return err("decimal: division by zero");
    }
    if scale < 0 || scale > MAX_SCALE {
        return err("decimal: scale " + to_str_int(scale) + " is outside 0 to 38");
    }
    let neg = a.neg != b.neg;
    // q = (A * 10^-sa) / (B * 10^-sb) * 10^scale = A * 10^e / B
    let e = scale + b.scale - a.scale;
    let n = to_wide(a);
    let d = to_wide(b);
    if e >= 0 {
        // A quotient past 38 digits shows in the operands' lengths first:
        // reject it before building a numerator wider than Wide holds.
        if w_digits(&n) + e - w_digits(&d) > MAX_DIGITS + 1 {
            return err("decimal: the quotient needs more than 38 digits");
        }
        w_mul10k(&mut n, e);
    } else {
        w_mul10k(&mut d, 0 - e);
    }
    let q = wzero();
    let r = wzero();
    w_divmod(&n, &d, &mut q, &mut r);
    if !w_is_zero(&r) {
        // compare 2r with d: above, at or below half
        w_mul_small(&mut r, 2);
        let half = w_cmp(&r, &d);
        if round_up(mode, neg, half, true, w_is_odd(&q)) {
            w_add_small(&mut q, 1);
        }
    }
    if !w_fits(&q) {
        return err("decimal: the quotient needs more than 38 digits");
    }
    return ok(from_wide(&q, scale, neg));
}

// d with exactly `scale` digits after the point: rounded by mode when
// that is fewer than it has, padded with zeros when more. none if scale
// is outside 0 to 38 or the result needs more than 38 digits.
pub fn round(d: Decimal, scale: int, mode: Rounding) -> opt[Decimal] {
    if scale < 0 || scale > MAX_SCALE {
        return none;
    }
    if scale == d.scale {
        return some(d);
    }
    let w = to_wide(d);
    if scale < d.scale {
        w_div10k_round(&mut w, d.scale - scale, d.neg, mode);
    } else if !w_mul10k(&mut w, scale - d.scale) {
        return none;
    }
    if !w_fits(&w) {
        return none;
    }
    return some(from_wide(&w, scale, d.neg));
}

// d with trailing fraction zeros removed: 1.500 becomes 1.5, 2.00
// becomes 2. Use it before a Decimal becomes a map key.
pub fn normalize(d: Decimal) -> Decimal {
    let w = to_wide(d);
    let scale = d.scale;
    while scale > 0 && w_mod_small(&w, 10) == 0 && !w_is_zero(&w) {
        w_div_small(&mut w, 10);
        scale -= 1;
    }
    if w_is_zero(&w) {
        scale = 0;
    }
    return from_wide(&w, scale, d.neg);
}

// ---- splitting money -------------------------------------------------------

// d in n parts at d's scale that add up to d exactly, as equal as they
// can be: the first ones take the leftover smallest units. split(100.00,
// 3) is [33.34, 33.33, 33.33]. Empty when n is not positive.
pub fn split(d: Decimal, n: int) -> [Decimal] {
    let weights: [int] = [];
    for _ in 0..math_max(n, 0) {
        push(weights, 1);
    }
    return allocate(d, weights) ?? [];
}

// d divided in proportion to weights, at d's scale, adding up to d
// exactly: each part is rounded down and the leftover smallest units go
// to the parts with the largest remainders (earlier ones first on a
// tie). allocate(10.00, [1, 2]) is [3.33, 6.67]. An error for an empty
// list, a negative weight or weights summing to zero.
pub fn allocate(d: Decimal, weights: [int]) -> result[[Decimal], str] {
    if len(weights) == 0 {
        return err("decimal: allocate needs at least one weight");
    }
    let total = wzero();
    for w in weights {
        if w < 0 {
            return err("decimal: weight " + to_str_int(w) + " is negative");
        }
        let one = wzero();
        set_int(&mut one, w);
        w_add(&mut total, &one);
    }
    if w_is_zero(&total) {
        return err("decimal: weights sum to zero");
    }
    let units = to_wide(d);
    let parts: [Decimal] = [];
    let rems: [Wide] = [];
    let given = wzero();
    for w in weights {
        let p = units;
        w_mul_small_any(&mut p, w);
        let q = wzero();
        let r = wzero();
        w_divmod(&p, &total, &mut q, &mut r);
        w_add(&mut given, &q);
        push(parts, from_wide(&q, d.scale, d.neg));
        push(rems, r);
    }
    // leftover smallest units: fewer than len(weights)
    let left = units;
    w_sub(&mut left, &given);
    let extra = w_low_int(&left);
    for _ in 0..extra {
        let best = -1;
        for i in 0..len(rems) {
            if best < 0 {
                best = i;
                continue;
            }
            let ri = rems[i];
            let rb = rems[best];
            if w_cmp(&ri, &rb) > 0 {
                best = i;
            }
        }
        // take this part's remainder out of the running
        rems[best] = wzero();
        let pw = to_wide(parts[best]);
        w_add_small(&mut pw, 1);
        parts[best] = from_wide(&pw, d.scale, d.neg);
    }
    return ok(parts);
}

// ---- internals: limbs ------------------------------------------------------

let BASE = 1000000000;

// A coefficient of up to 108 digits, as twelve base-10^9 limbs, least
// significant first: room for a product of two 38-digit coefficients
// scaled by up to 10^38, and for long division's normalisation limb.
// A value struct, so the arithmetic below allocates nothing.
struct Wide {
    w0: int, w1: int, w2: int, w3: int, w4: int, w5: int,
    w6: int, w7: int, w8: int, w9: int, w10: int, w11: int,
}

let WLIMBS = 12;

fn wzero() -> Wide {
    return Wide { w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0,
                  w6: 0, w7: 0, w8: 0, w9: 0, w10: 0, w11: 0 };
}

fn wget(w: &Wide, i: int) -> int {
    return switch i {
        case 0 { w.w0 }
        case 1 { w.w1 }
        case 2 { w.w2 }
        case 3 { w.w3 }
        case 4 { w.w4 }
        case 5 { w.w5 }
        case 6 { w.w6 }
        case 7 { w.w7 }
        case 8 { w.w8 }
        case 9 { w.w9 }
        case 10 { w.w10 }
        case 11 { w.w11 }
        default { 0 }
    };
}

fn wset(w: &mut Wide, i: int, v: int) {
    switch i {
        case 0 { w.w0 = v; }
        case 1 { w.w1 = v; }
        case 2 { w.w2 = v; }
        case 3 { w.w3 = v; }
        case 4 { w.w4 = v; }
        case 5 { w.w5 = v; }
        case 6 { w.w6 = v; }
        case 7 { w.w7 = v; }
        case 8 { w.w8 = v; }
        case 9 { w.w9 = v; }
        case 10 { w.w10 = v; }
        case 11 { w.w11 = v; }
        default { }
    }
}

fn to_wide(d: Decimal) -> Wide {
    return Wide { w0: d.l0, w1: d.l1, w2: d.l2, w3: d.l3, w4: d.l4, w5: 0,
                  w6: 0, w7: 0, w8: 0, w9: 0, w10: 0, w11: 0 };
}

// The caller has checked w_fits.
fn from_wide(w: &Wide, scale: int, neg: bool) -> Decimal {
    let z = w.w0 == 0 && w.w1 == 0 && w.w2 == 0 && w.w3 == 0 && w.w4 == 0;
    return Decimal { l0: w.w0, l1: w.w1, l2: w.w2, l3: w.w3, l4: w.w4,
                     scale: scale, neg: neg && !z };
}

// Below 10^38: limbs 5 and up are zero and limb 4 is under 100.
fn w_fits(w: &Wide) -> bool {
    return w.w4 < 100 && w.w5 == 0 && w.w6 == 0 && w.w7 == 0 && w.w8 == 0
        && w.w9 == 0 && w.w10 == 0 && w.w11 == 0;
}

fn w_is_odd(w: &Wide) -> bool {
    return w.w0 % 2 == 1;
}

// Decimal digits in w (1 for zero).
fn w_digits(w: &Wide) -> int {
    let t = w_top(&*w);
    if t < 0 {
        return 1;
    }
    let top = wget(&*w, t);
    let n = t * 9;
    while top > 0 {
        n += 1;
        top /= 10;
    }
    return n;
}

// a *= m for any m >= 0 (split into base-10^9 pieces).
fn w_mul_small_any(a: &mut Wide, m: int) {
    if m < BASE {
        w_mul_small(&mut *a, m);
        return;
    }
    let mw = wzero();
    set_int(&mut mw, m);
    let p = w_mul_coef(&*a, &mw);
    *a = p;
}

fn set_int(w: &mut Wide, v: int) {
    let x = v;
    let i = 0;
    while x > 0 {
        wset(&mut *w, i, x % BASE);
        x /= BASE;
        i += 1;
    }
}

// The low limbs of a small Wide as an int (the caller knows it fits).
fn w_low_int(w: &Wide) -> int {
    return w.w1 * BASE + w.w0;
}

// 10^k for 0 <= k <= 8.
fn pow10(k: int) -> int {
    return switch k {
        case 0 { 1 }
        case 1 { 10 }
        case 2 { 100 }
        case 3 { 1000 }
        case 4 { 10000 }
        case 5 { 100000 }
        case 6 { 1000000 }
        case 7 { 10000000 }
        default { 100000000 }
    };
}

// a *= 10^k; false past 12 limbs.
fn w_mul10k(a: &mut Wide, k: int) -> bool {
    if k <= 0 {
        return true;
    }
    for _ in 0..(k / 9) {
        if !w_shl_limb(&mut *a) {
            return false;
        }
    }
    return w_mul_small(&mut *a, pow10(k % 9));
}

// a /= 10^k, truncating; returns whether anything nonzero was dropped.
fn w_div10k(a: &mut Wide, k: int) -> bool {
    if k <= 0 {
        return false;
    }
    let dropped = false;
    for _ in 0..(k / 9) {
        if w_shr_limb(&mut *a) != 0 {
            dropped = true;
        }
    }
    let r = w_div_small(&mut *a, pow10(k % 9));
    return dropped || r != 0;
}

// a /= 10^k only if that drops nothing but zeros; false (a unchanged
// in value terms) otherwise.
fn w_div10k_exact(a: &mut Wide, k: int) -> bool {
    let probe = *a;
    if w_div10k(&mut probe, k) {
        return false;
    }
    *a = probe;
    return true;
}

// a /= 10^k, rounded by mode; neg is the sign of the value a is the
// magnitude of.
fn w_div10k_round(a: &mut Wide, k: int, neg: bool, mode: Rounding) {
    if k <= 0 {
        return;
    }
    // The first dropped digit and whether anything below it is nonzero
    // decide every mode.
    let sticky = w_div10k(&mut *a, k - 1);
    let digit = w_div_small(&mut *a, 10);
    let half = 0;
    if digit > 5 || (digit == 5 && sticky) {
        half = 1;
    } else if digit < 5 {
        half = -1;
    }
    if round_up(mode, neg, half, digit != 0 || sticky, w_is_odd(&*a)) {
        w_add_small(&mut *a, 1);
    }
}

// Whether a truncated magnitude goes up one unit. half is the dropped
// part against one half unit (-1 below, 0 at, 1 above); inexact is
// whether anything was dropped at all.
fn round_up(mode: Rounding, neg: bool, half: int, inexact: bool, odd: bool) -> bool {
    if !inexact {
        return false;
    }
    return switch mode {
        case Rounding.Down { false }
        case Rounding.Up { true }
        case Rounding.Floor { neg }
        case Rounding.Ceiling { !neg }
        case Rounding.HalfUp { half >= 0 }
        case Rounding.HalfDown { half > 0 }
        case Rounding.HalfEven { half > 0 || (half == 0 && odd) }
    };
}

// q, r = n / d, n % d (d nonzero): Knuth's algorithm D in base 10^9.
// Every intermediate product is under 10^18, so it runs in int.
fn w_divmod(n: &Wide, d: &Wide, q: &mut Wide, r: &mut Wide) {
    *q = wzero();
    *r = wzero();
    let dt = w_top(&*d);
    if w_cmp(&*n, &*d) < 0 {
        *r = *n;
        return;
    }
    if dt == 0 {
        let u = *n;
        let rem = w_div_small(&mut u, d.w0);
        *q = u;
        r.w0 = rem;
        return;
    }
    let dn = dt + 1;                 // divisor limbs
    // normalise so the divisor's top limb is at least BASE / 2
    let f = BASE / (wget(&*d, dt) + 1);
    let u = *n;
    let v = *d;
    w_mul_small(&mut u, f);
    w_mul_small(&mut v, f);
    let ut = w_top(&u);
    let m = ut - dn + 1;             // quotient limbs, perhaps one more
    if m < 0 {
        m = 0;
    }
    let vtop = wget(&v, dt);
    let vnext = wget(&v, dt - 1);
    let j = m;
    while j >= 0 {
        // estimate this quotient limb from the top two limbs of u
        let hi = wget(&u, j + dn);
        let num = hi * BASE + wget(&u, j + dn - 1);
        let qhat = num / vtop;
        let rhat = num % vtop;
        while qhat >= BASE || qhat * vnext > rhat * BASE + wget(&u, j + dn - 2) {
            qhat -= 1;
            rhat += vtop;
            if rhat >= BASE {
                break;
            }
        }
        // u[j .. j+dn] -= qhat * v
        let carry = 0;
        let borrow = 0;
        for i in 0..dn {
            let p = qhat * wget(&v, i) + carry;
            carry = p / BASE;
            let t = wget(&u, i + j) - p % BASE - borrow;
            borrow = 0;
            if t < 0 {
                t += BASE;
                borrow = 1;
            }
            wset(&mut u, i + j, t);
        }
        let t = wget(&u, j + dn) - carry - borrow;
        if t < 0 {
            // qhat was one too large (rare): add v back
            wset(&mut u, j + dn, t + BASE);
            qhat -= 1;
            let c = 0;
            for i in 0..dn {
                let s = wget(&u, i + j) + wget(&v, i) + c;
                c = 0;
                if s >= BASE {
                    s -= BASE;
                    c = 1;
                }
                wset(&mut u, i + j, s);
            }
            let top = wget(&u, j + dn) + c;
            wset(&mut u, j + dn, top % BASE);
        } else {
            wset(&mut u, j + dn, t);
        }
        if j < WLIMBS {
            wset(&mut *q, j, qhat);
        }
        j -= 1;
    }
    // the remainder is u's low limbs, un-normalised
    let rr = wzero();
    for i in 0..dn {
        wset(&mut rr, i, wget(&u, i));
    }
    w_div_small(&mut rr, f);
    *r = rr;
}

// ---- internals: signed helpers ---------------------------------------------

fn mag_cmp(a: Decimal, b: Decimal) -> int {
    if a.scale == b.scale {
        return d_cmp5(a, b);
    }
    let x = to_wide(a);
    let y = to_wide(b);
    if a.scale < b.scale {
        w_mul10k(&mut x, b.scale - a.scale);
    } else {
        w_mul10k(&mut y, a.scale - b.scale);
    }
    return w_cmp(&x, &y);
}

fn mag_mul(a: Decimal, b: Decimal) -> Wide {
    let x = to_wide(a);
    let y = to_wide(b);
    return w_mul_coef(&x, &y);
}

// a + (b with sign bneg), exact, at the larger scale.
fn add_signed(a: Decimal, b: Decimal, bneg: bool) -> opt[Decimal] {
    if a.scale == b.scale {
        // The common case (amounts in one currency): straight on the five
        // limbs, no alignment and no Wide.
        if a.neg == bneg {
            return d_add5(a, b, a.neg);
        }
        let c = d_cmp5(a, b);
        if c >= 0 {
            return some(d_sub5(a, b, a.neg));
        }
        return some(d_sub5(b, a, bneg));
    }
    let scale = a.scale;
    if b.scale > scale {
        scale = b.scale;
    }
    let x = to_wide(a);
    let y = to_wide(b);
    // Aligning to the larger scale is exact; 38 + 38 digits fit a Wide.
    w_mul10k(&mut x, scale - a.scale);
    w_mul10k(&mut y, scale - b.scale);
    let neg = a.neg;
    if a.neg == bneg {
        w_add(&mut x, &y);
    } else if w_cmp(&x, &y) >= 0 {
        w_sub(&mut x, &y);
    } else {
        w_sub(&mut y, &x);
        x = y;
        neg = bneg;
    }
    if !w_fits(&x) {
        return none;
    }
    return some(from_wide(&x, scale, neg));
}

// ---- internals: the five limbs of a Decimal --------------------------------

fn d_limb(d: Decimal, i: int) -> int {
    return switch i {
        case 0 { d.l0 }
        case 1 { d.l1 }
        case 2 { d.l2 }
        case 3 { d.l3 }
        case 4 { d.l4 }
        default { 0 }
    };
}

// Decimal digits in the coefficient (1 for zero).
fn d_digits(d: Decimal) -> int {
    let top = 0;
    let t = d.l0;
    if d.l4 != 0 {
        top = 4;
        t = d.l4;
    } else if d.l3 != 0 {
        top = 3;
        t = d.l3;
    } else if d.l2 != 0 {
        top = 2;
        t = d.l2;
    } else if d.l1 != 0 {
        top = 1;
        t = d.l1;
    }
    let n = top * 9 + 1;
    while t >= 10 {
        n += 1;
        t /= 10;
    }
    return n;
}

fn d_cmp5(a: Decimal, b: Decimal) -> int {
    if a.l4 != b.l4 { if a.l4 < b.l4 { return -1; } return 1; }
    if a.l3 != b.l3 { if a.l3 < b.l3 { return -1; } return 1; }
    if a.l2 != b.l2 { if a.l2 < b.l2 { return -1; } return 1; }
    if a.l1 != b.l1 { if a.l1 < b.l1 { return -1; } return 1; }
    if a.l0 != b.l0 { if a.l0 < b.l0 { return -1; } return 1; }
    return 0;
}

// |a| + |b| at a's scale, with sign neg; none past 38 digits.
fn d_add5(a: Decimal, b: Decimal, neg: bool) -> opt[Decimal] {
    let s0 = a.l0 + b.l0;
    let c = 0;
    if s0 >= 1000000000 { s0 -= 1000000000; c = 1; }
    let s1 = a.l1 + b.l1 + c;
    c = 0;
    if s1 >= 1000000000 { s1 -= 1000000000; c = 1; }
    let s2 = a.l2 + b.l2 + c;
    c = 0;
    if s2 >= 1000000000 { s2 -= 1000000000; c = 1; }
    let s3 = a.l3 + b.l3 + c;
    c = 0;
    if s3 >= 1000000000 { s3 -= 1000000000; c = 1; }
    let s4 = a.l4 + b.l4 + c;
    if s4 >= 100 {
        return none;
    }
    let z = (s0 | s1 | s2 | s3 | s4) == 0;
    return some(Decimal { l0: s0, l1: s1, l2: s2, l3: s3, l4: s4, scale: a.scale,
                          neg: neg && !z });
}

// |a| - |b| for |a| >= |b|, at a's scale, with sign neg.
fn d_sub5(a: Decimal, b: Decimal, neg: bool) -> Decimal {
    let s0 = a.l0 - b.l0;
    let c = 0;
    if s0 < 0 { s0 += 1000000000; c = 1; }
    let s1 = a.l1 - b.l1 - c;
    c = 0;
    if s1 < 0 { s1 += 1000000000; c = 1; }
    let s2 = a.l2 - b.l2 - c;
    c = 0;
    if s2 < 0 { s2 += 1000000000; c = 1; }
    let s3 = a.l3 - b.l3 - c;
    c = 0;
    if s3 < 0 { s3 += 1000000000; c = 1; }
    let s4 = a.l4 - b.l4 - c;
    let z = (s0 | s1 | s2 | s3 | s4) == 0;
    return Decimal { l0: s0, l1: s1, l2: s2, l3: s3, l4: s4, scale: a.scale,
                     neg: neg && !z };
}

// ---- internals: parsing ----------------------------------------------------

// A coefficient being parsed: digits gather in `chunk` and enter the
// Wide nine at a time, one limb shift each, instead of a 12-limb
// multiply per digit. Leading zeros are not significant; a nonzero digit
// past 38 significant ones is counted in `dropped` (the parse fails); a
// zero past them is left out and accounted for by digits_not_stored.
struct Acc {
    w: Wide,
    chunk: int,
    clen: int,
    sig: int,
    dropped: int,
}

// A leaf (scalar stores through the borrow, no call), so the per-digit
// call costs no safepoint; it says when nine digits are ready for
// acc_push, which moves them into the Wide.
fn take_digit(a: &mut Acc, dg: int) -> bool {
    if a.sig == 0 && dg == 0 {
        return false;
    }
    if a.sig >= 38 {
        if dg != 0 {
            a.dropped += 1;
        }
        a.sig += 1;
        return false;
    }
    a.chunk = a.chunk * 10 + dg;
    a.clen += 1;
    a.sig += 1;
    return a.clen == 9;
}

fn acc_push(a: &mut Acc) {
    let w = a.w;
    w_shl_limb(&mut w);
    w.w0 = a.chunk;
    a.w = w;
    a.chunk = 0;
    a.clen = 0;
}

// The coefficient once every digit is in.
fn acc_value(a: &mut Acc) -> Wide {
    let w = a.w;
    if a.clen > 0 {
        w_mul_small(&mut w, pow10(a.clen));
        w_add_small(&mut w, a.chunk);
    }
    return w;
}

// How many significant digits were read but not stored (all zeros, past
// the 38th): the stored coefficient is the number divided by 10^that.
fn digits_not_stored(sig: int) -> int {
    if sig > MAX_DIGITS {
        return sig - MAX_DIGITS;
    }
    return 0;
}

// b[lo..hi] for an error message: printable ASCII kept, the rest as
// '?', at most 40 characters.
fn shown(b: bytes, lo: int, hi: int) -> str {
    let n = hi - lo;
    let more = false;
    if n > 40 {
        n = 40;
        more = true;
    }
    let out = strings.bytes_zero(n);
    for i in 0..n {
        let c = b[lo + i];
        if c >= 32 && c < 127 {
            out[i] = c;
        } else {
            out[i] = 63;
        }
    }
    let s = strings.from_bytes(out, 0, n);
    if more {
        return s + "...";
    }
    return s;
}

// ---- internals: small helpers ----------------------------------------------

fn bool_int(b: bool) -> int {
    if b {
        return 1;
    }
    return 0;
}

fn math_max(a: int, b: int) -> int {
    if a > b {
        return a;
    }
    return b;
}

fn to_str_int(n: int) -> str {
    return "" + n;
}

fn to_float_text(s: str) -> float {
    let r = to_float(s);
    return r ?? 0.0;
}
