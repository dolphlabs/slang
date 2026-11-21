// Magnitudes: unsigned integers as little-endian [u32] limbs with no
// leading zero limb (zero is the empty list). Every routine here returns
// a fresh list and never changes its arguments, so an Int can share its
// limbs freely.

import "math";

let BASE: u64 = 4294967296;          // 2^32
let MASK32: u64 = 4294967295;
// Below this many limbs (8192 bits) schoolbook multiplication beats
// Karatsuba here: measured, schoolbook is as fast up to 16384 bits and
// Karatsuba 20% faster at 32768.
let KARATSUBA = 256;

fn zeros(n: int) -> [u32] {
    let out: [u32] = [];
    for i in 0..n {
        push(out, 0);
    }
    return out;
}

// Drops leading zero limbs in place.
fn trim(a: [u32]) -> [u32] {
    while len(a) > 0 && a[len(a) - 1] == 0 {
        pop(a);
    }
    return a;
}

fn copy_mag(a: [u32]) -> [u32] {
    let out: [u32] = [];
    for x in a {
        push(out, x);
    }
    return out;
}

fn mag_from_u64(v: u64) -> [u32] {
    let out: [u32] = [];
    if v == 0 {
        return out;
    }
    push(out, (v & MASK32) as u32);
    let hi = v >> 32;
    if hi != 0 {
        push(out, hi as u32);
    }
    return out;
}

// -1, 0 or 1.
fn mag_cmp(a: [u32], b: [u32]) -> int {
    if len(a) != len(b) {
        if len(a) < len(b) {
            return -1;
        }
        return 1;
    }
    let i = len(a) - 1;
    while i >= 0 {
        if a[i] != b[i] {
            if a[i] < b[i] {
                return -1;
            }
            return 1;
        }
        i -= 1;
    }
    return 0;
}

fn mag_add(a: [u32], b: [u32]) -> [u32] {
    let x = a;
    let y = b;
    if len(x) < len(y) {
        x = b;
        y = a;
    }
    let out: [u32] = [];
    let carry: u64 = 0;
    for i in 0..len(x) {
        let s = (x[i] as u64) + carry;
        if i < len(y) {
            s += y[i] as u64;
        }
        push(out, (s & MASK32) as u32);
        carry = s >> 32;
    }
    if carry != 0 {
        push(out, carry as u32);
    }
    return out;
}

// a - b for a >= b.
fn mag_sub(a: [u32], b: [u32]) -> [u32] {
    let out: [u32] = [];
    let borrow: u64 = 0;
    for i in 0..len(a) {
        let sub = borrow;
        if i < len(b) {
            sub += b[i] as u64;
        }
        let ai = a[i] as u64;
        if ai >= sub {
            push(out, (ai - sub) as u32);
            borrow = 0;
        } else {
            push(out, (ai + BASE - sub) as u32);
            borrow = 1;
        }
    }
    return trim(out);
}

// a * m + add for a one-limb m.
fn mag_mul_small(a: [u32], m: u32, add: u32) -> [u32] {
    let out: [u32] = [];
    let carry = add as u64;
    let mm = m as u64;
    for x in a {
        let p = (x as u64) * mm + carry;
        push(out, (p & MASK32) as u32);
        carry = p >> 32;
    }
    if carry != 0 {
        push(out, carry as u32);
    }
    return trim(out);
}

fn mag_mul(a: [u32], b: [u32]) -> [u32] {
    if len(a) == 0 || len(b) == 0 {
        let z: [u32] = [];
        return z;
    }
    if len(a) >= KARATSUBA && len(b) >= KARATSUBA {
        return karatsuba(a, b);
    }
    return school(a, 0, len(a), b, 0, len(b));
}

// The product of a[ao..ao+an] and b[bo..bo+bn], schoolbook: each partial
// product and carry fits in 64 bits ((2^32-1)^2 + 2 * (2^32-1) < 2^64).
fn school(a: [u32], ao: int, an: int, b: [u32], bo: int, bn: int) -> [u32] {
    let out = zeros(an + bn);
    for i in 0..an {
        let ai = a[ao + i] as u64;
        if ai == 0 {
            continue;
        }
        let carry: u64 = 0;
        for j in 0..bn {
            let t = ai * (b[bo + j] as u64) + (out[i + j] as u64) + carry;
            out[i + j] = (t & MASK32) as u32;
            carry = t >> 32;
        }
        out[i + bn] = carry as u32;
    }
    return trim(out);
}

// Karatsuba (1962): three half-size products instead of four, O(n^1.585).
fn karatsuba(a: [u32], b: [u32]) -> [u32] {
    let n = math.max(len(a), len(b));
    if len(a) < KARATSUBA || len(b) < KARATSUBA {
        return school(a, 0, len(a), b, 0, len(b));
    }
    let h = n / 2;
    let a0 = slice_mag(a, 0, h);
    let a1 = slice_mag(a, h, len(a));
    let b0 = slice_mag(b, 0, h);
    let b1 = slice_mag(b, h, len(b));
    let z0 = mag_mul(a0, b0);
    let z2 = mag_mul(a1, b1);
    let z1 = mag_sub(mag_sub(mag_mul(mag_add(a0, a1), mag_add(b0, b1)), z0), z2);
    let out = zeros(len(a) + len(b) + 1);
    add_into(out, z0, 0);
    add_into(out, z1, h);
    add_into(out, z2, 2 * h);
    return trim(out);
}

// a[lo..hi] as a trimmed magnitude (empty past the end).
fn slice_mag(a: [u32], lo: int, hi: int) -> [u32] {
    let out: [u32] = [];
    let end = math.min(hi, len(a));
    for i in lo..end {
        push(out, a[i]);
    }
    return trim(out);
}

// out += x << (32 * at), out long enough to hold the result.
fn add_into(out: [u32], x: [u32], at: int) {
    let carry: u64 = 0;
    let i = 0;
    while i < len(x) || carry != 0 {
        let s = (out[at + i] as u64) + carry;
        if i < len(x) {
            s += x[i] as u64;
        }
        out[at + i] = (s & MASK32) as u32;
        carry = s >> 32;
        i += 1;
    }
}

fn mag_shl(a: [u32], bits: int) -> [u32] {
    if len(a) == 0 {
        return copy_mag(a);
    }
    let limbs = bits / 32;
    let s = bits % 32;
    let out = zeros(limbs);
    if s == 0 {
        for x in a {
            push(out, x);
        }
        return out;
    }
    let carry: u64 = 0;
    for x in a {
        let v = ((x as u64) << s) | carry;
        push(out, (v & MASK32) as u32);
        carry = v >> 32;
    }
    if carry != 0 {
        push(out, carry as u32);
    }
    return out;
}

// a >> bits, the bits shifted out discarded.
fn mag_shr(a: [u32], bits: int) -> [u32] {
    let limbs = bits / 32;
    let s = bits % 32;
    let out: [u32] = [];
    if limbs >= len(a) {
        return out;
    }
    for i in limbs..len(a) {
        let lo = (a[i] as u64) >> s;
        let hi: u64 = 0;
        if s != 0 && i + 1 < len(a) {
            hi = ((a[i + 1] as u64) << (32 - s)) & MASK32;
        }
        push(out, (lo | hi) as u32);
    }
    return trim(out);
}

// Whether any of the low `bits` bits of a is set.
fn mag_low_bits_set(a: [u32], bits: int) -> bool {
    let limbs = bits / 32;
    for i in 0..math.min(limbs, len(a)) {
        if a[i] != 0 {
            return true;
        }
    }
    let s = bits % 32;
    if s != 0 && limbs < len(a) {
        let one: u32 = 1;
        return (a[limbs] & ((one << s) - 1)) != 0;
    }
    return false;
}

fn mag_bit_len(a: [u32]) -> int {
    if len(a) == 0 {
        return 0;
    }
    return 32 * (len(a) - 1) + math.bit_len(a[len(a) - 1]);
}

// a / d and a % d for a one-limb d > 0, the quotient into q (fresh).
fn mag_divmod_small(a: [u32], d: u32, q: [u32]) -> u32 {
    let dd = d as u64;
    let rem: u64 = 0;
    for i in 0..len(a) {
        push(q, 0);
    }
    let i = len(a) - 1;
    while i >= 0 {
        let cur = (rem << 32) | (a[i] as u64);
        q[i] = (cur / dd) as u32;
        rem = cur % dd;
        i -= 1;
    }
    trim(q);
    return rem as u32;
}

// The quotient and remainder of u / v (v not zero): Knuth's algorithm D
// (TAOCP 4.3.1), in the form of Hacker's Delight's divmnu. Written to q
// and r, both empty on entry.
fn mag_divmod(u: [u32], v: [u32], q: [u32], r: [u32]) {
    if mag_cmp(u, v) < 0 {
        for x in u {
            push(r, x);
        }
        return;
    }
    if len(v) == 1 {
        let rem = mag_divmod_small(u, v[0], q);
        if rem != 0 {
            push(r, rem);
        }
        return;
    }
    let n = len(v);
    let m = len(u) - n;
    // normalise: the divisor's top limb has its high bit set
    let s = 32 - math.bit_len(v[n - 1]);
    let vn = mag_shl(v, s);
    let un = mag_shl(u, s);
    while len(un) < len(u) + 1 {
        push(un, 0);
    }
    for i in 0..m + 1 {
        push(q, 0);
    }
    let vtop = vn[n - 1] as u64;
    let vnext = vn[n - 2] as u64;
    let j = m;
    while j >= 0 {
        let num = ((un[j + n] as u64) << 32) | (un[j + n - 1] as u64);
        let qhat = num / vtop;
        let rhat = num % vtop;
        while qhat >= BASE || qhat * vnext > ((rhat << 32) | (un[j + n - 2] as u64)) {
            qhat -= 1;
            rhat += vtop;
            if rhat >= BASE {
                break;
            }
        }
        // un[j..j+n] -= qhat * vn, tracking the borrow in signed 64 bits
        let borrow = 0;
        for i in 0..n {
            let p = qhat * (vn[i] as u64);
            let t = (un[i + j] as int) - borrow - ((p & MASK32) as int);
            un[i + j] = ((t as u64) & MASK32) as u32;
            borrow = ((p >> 32) as int) - (t >> 32);
        }
        let t = (un[j + n] as int) - borrow;
        un[j + n] = ((t as u64) & MASK32) as u32;
        if t < 0 {
            // qhat was one too large (rare): add the divisor back
            qhat -= 1;
            let carry: u64 = 0;
            for i in 0..n {
                let s2 = (un[i + j] as u64) + (vn[i] as u64) + carry;
                un[i + j] = (s2 & MASK32) as u32;
                carry = s2 >> 32;
            }
            un[j + n] = (((un[j + n] as u64) + carry) & MASK32) as u32;
        }
        q[j] = qhat as u32;
        j -= 1;
    }
    trim(q);
    let rem = mag_shr(trim(slice_mag(un, 0, n)), s);
    for x in rem {
        push(r, x);
    }
}

// ---- Montgomery multiplication, for mod_pow with an odd modulus ---------

// -m0^-1 mod 2^32 for an odd m0: Newton's iteration doubles the correct
// low bits each step, from the 3 that m0 itself gets right.
fn mont_neg_inv(m0: u32) -> u32 {
    let two: u32 = 2;
    let zero32: u32 = 0;
    let x = m0;
    for i in 0..4 {
        x = x * (two - m0 * x);
    }
    return zero32 - x;
}

// out = a * b * R^-1 mod m, R = 2^(32n), for a, b < m held in n limbs
// (zero-padded): the CIOS method (Koc, Acar and Kaliski 1996), one pass
// of multiply and reduce per limb of b, no division. t is scratch of
// n + 2 limbs; out must not be a or b.
fn mont_mul(a: [u32], b: [u32], m: [u32], minv: u32, n: int, t: [u32], out: [u32]) {
    for k in 0..n + 2 {
        t[k] = 0;
    }
    for i in 0..n {
        let bi = b[i] as u64;
        let c: u64 = 0;
        for j in 0..n {
            let s = (t[j] as u64) + (a[j] as u64) * bi + c;
            t[j] = (s & MASK32) as u32;
            c = s >> 32;
        }
        let s = (t[n] as u64) + c;
        t[n] = (s & MASK32) as u32;
        t[n + 1] = (s >> 32) as u32;
        let mm = ((t[0] as u64) * (minv as u64)) & MASK32;
        c = ((t[0] as u64) + mm * (m[0] as u64)) >> 32;
        for j in 1..n {
            let s1 = (t[j] as u64) + mm * (m[j] as u64) + c;
            t[j - 1] = (s1 & MASK32) as u32;
            c = s1 >> 32;
        }
        let s2 = (t[n] as u64) + c;
        t[n - 1] = (s2 & MASK32) as u32;
        t[n] = ((t[n + 1] as u64) + (s2 >> 32)) as u32;
    }
    // the result is below 2m: subtract m once if it is not below m
    let ge = t[n] != 0;
    if !ge {
        ge = true;
        let k = n - 1;
        while k >= 0 {
            if t[k] != m[k] {
                ge = t[k] > m[k];
                break;
            }
            k -= 1;
        }
    }
    if ge {
        let borrow: u64 = 0;
        for k in 0..n {
            let sub = (m[k] as u64) + borrow;
            let tk = t[k] as u64;
            if tk >= sub {
                out[k] = (tk - sub) as u32;
                borrow = 0;
            } else {
                out[k] = (tk + BASE - sub) as u32;
                borrow = 1;
            }
        }
        return;
    }
    for k in 0..n {
        out[k] = t[k];
    }
}

// x zero-padded (or cut) to n limbs, as a fresh list.
fn padded(x: [u32], n: int) -> [u32] {
    let out = zeros(n);
    for i in 0..math.min(len(x), n) {
        out[i] = x[i];
    }
    return out;
}

// base^e mod m for an odd m of at least two limbs and base < m, with a
// fixed 4-bit window: about bits(e) squarings and bits(e)/4 multiplies,
// each a Montgomery product.
fn mag_mod_pow_odd(base: [u32], e: [u32], m: [u32]) -> [u32] {
    let n = len(m);
    let minv = mont_neg_inv(m[0]);
    // R^2 mod m converts into Montgomery form: x * R^2 * R^-1 = x R
    let q: [u32] = [];
    let r2: [u32] = [];
    mag_divmod(mag_shl(mag_from_u64(1), 64 * n), m, q, r2);
    let rr = padded(r2, n);
    let t = zeros(n + 2);
    let one_plain = padded(mag_from_u64(1), n);
    // table[k] = base^k in Montgomery form
    let table: [[u32]] = [];
    let one_m = zeros(n);
    mont_mul(one_plain, rr, m, minv, n, t, one_m);
    push(table, one_m);
    let b_m = zeros(n);
    mont_mul(padded(base, n), rr, m, minv, n, t, b_m);
    push(table, b_m);
    for k in 2..16 {
        let next = zeros(n);
        mont_mul(table[k - 1], b_m, m, minv, n, t, next);
        push(table, next);
    }
    let acc = padded(one_m, n);
    let tmp = zeros(n);
    let bits = mag_bit_len(e);
    // the top window may be short: start at a multiple of 4 above it
    let top = ((bits + 3) / 4) * 4 - 4;
    let pos = top;
    while pos >= 0 {
        for s in 0..4 {
            mont_mul(acc, acc, m, minv, n, t, tmp);
            let sw = acc;
            acc = tmp;
            tmp = sw;
        }
        let limb = pos / 32;
        let nib = 0;
        if limb < len(e) {
            nib = ((e[limb] >> (pos % 32)) & 15) as int;
        }
        if nib != 0 {
            mont_mul(acc, table[nib], m, minv, n, t, tmp);
            let sw = acc;
            acc = tmp;
            tmp = sw;
        }
        pos -= 4;
    }
    // out of Montgomery form: multiply by 1
    mont_mul(acc, one_plain, m, minv, n, t, tmp);
    return trim(tmp);
}
