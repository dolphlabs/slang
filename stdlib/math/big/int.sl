// Arbitrary-precision integers and exact fractions: cryptography, ids
// and amounts past 64 bits, exact combinatorics, and checking int
// arithmetic against the truth.
//
//     import "math/big";
//
//     let a = big.parse("123456789012345678901234567890", 10) ?? big.zero();
//     let b = big.from_int(987654321);
//     a.mul(b).add(big.from_int(1)).format(10)
//     big.from_int(2).pow(521).sub(big.one())      // a Mersenne prime
//     a.mod_pow(e, m)                              // modular exponentiation
//     let r = big.rat_parse("0.125") ?? big.rat_zero();   // 1/8, exact
//
// An Int is immutable: every operation returns a new one, and a value can
// be shared between tasks. Division truncates toward zero (div, rem, as
// slang's / and % do); div_floor and modulo floor toward negative
// infinity, and modulo is never negative for a positive modulus. Bitwise
// operations act on the infinite two's-complement form, as Go's
// math/big and Python do.
//
// Limbs are 32 bits, so every partial product fits a u64. Multiplication
// is schoolbook below 256 limbs (8192 bits) and Karatsuba above; division
// is Knuth's algorithm D; mod_pow with an odd modulus is Montgomery
// multiplication with a 4-bit window.

import "builder";
import "math";

pub gc struct Int {
    neg: bool,
    mag: [u32],
}

fn make(neg: bool, mag: [u32]) -> Int {
    let m = trim(mag);
    return Int { neg: neg && len(m) > 0, mag: m };
}

pub fn zero() -> Int {
    let m: [u32] = [];
    return Int { neg: false, mag: m };
}

pub fn one() -> Int {
    return from_int(1);
}

pub fn from_int(n: int) -> Int {
    if n >= 0 {
        return make(false, mag_from_u64(n as u64));
    }
    // -n overflows for the minimum int; its magnitude is 2^63 either way
    return make(true, mag_from_u64((0 - (n as u64))));
}

pub fn from_u64(n: u64) -> Int {
    return make(false, mag_from_u64(n));
}

// An Int from text in `base` (2 to 36): an optional sign, then digits
// (either case for letters), with `_` allowed between digits. For base 16,
// 8 and 2 a 0x, 0o or 0b prefix is accepted too. Text longer than 100,000
// characters is refused, to bound the work an input can ask for.
pub fn parse(s: str, base: int) -> result[Int, str] {
    if base < 2 || base > 36 {
        return err("big: base must be between 2 and 36");
    }
    let b = to_bytes(s);
    let n = len(b);
    if n > 100000 {
        return err("big: number is longer than 100000 characters");
    }
    let i = 0;
    let neg = false;
    if i < n && (b[i] == 43 || b[i] == 45) {
        neg = b[i] == 45;
        i += 1;
    }
    if i + 1 < n && b[i] == 48 {
        let p = b[i + 1] | 32;
        if (base == 16 && p == 120) || (base == 8 && p == 111) || (base == 2 && p == 98) {
            i += 2;
        }
    }
    if i >= n {
        return err("big: no digits in '" + s + "'");
    }
    // Horner over chunks: as many digits as fit one limb at a time
    let per = 1;
    let chunk_mul: u64 = base as u64;
    while chunk_mul * (base as u64) <= 4294967295 {
        chunk_mul *= base as u64;
        per += 1;
    }
    let mag: [u32] = [];
    let acc: u64 = 0;
    let mul: u64 = 1;
    let count = 0;
    let prev_us = true;
    while i < n {
        let c = b[i];
        i += 1;
        if c == 95 {
            if prev_us {
                return err("big: misplaced '_' in '" + s + "'");
            }
            prev_us = true;
            continue;
        }
        let d = digit_value(c);
        if d < 0 || d >= base {
            return err("big: '" + s + "' is not a base-" + to_str(base) + " integer");
        }
        prev_us = false;
        acc = acc * (base as u64) + (d as u64);
        mul *= base as u64;
        count += 1;
        if count == per {
            mag = mag_mul_small(mag, mul as u32, acc as u32);
            acc = 0;
            mul = 1;
            count = 0;
        }
    }
    if prev_us {
        return err("big: misplaced '_' in '" + s + "'");
    }
    if count > 0 {
        mag = mag_mul_small(mag, mul as u32, acc as u32);
    }
    return ok(make(neg, mag));
}

fn digit_value(c: int) -> int {
    if c >= 48 && c <= 57 {
        return c - 48;
    }
    if c >= 97 && c <= 122 {
        return c - 87;
    }
    if c >= 65 && c <= 90 {
        return c - 55;
    }
    return -1;
}

fn digit_char(d: int) -> int {
    if d < 10 {
        return 48 + d;
    }
    return 87 + d;
}

// From big-endian unsigned bytes (as a key or a hash is written).
pub fn from_bytes_be(b: bytes) -> Int {
    let mag: [u32] = [];
    let n = len(b);
    let i = n;
    while i > 0 {
        let lo = math.max(i - 4, 0);
        let w: u64 = 0;
        for k in lo..i {
            w = (w << 8) | (b[k] as u64);
        }
        push(mag, w as u32);
        i = lo;
    }
    return make(false, mag);
}

impl Int {
    pub fn sign(self: Int) -> int {
        if len(self.mag) == 0 {
            return 0;
        }
        if self.neg {
            return -1;
        }
        return 1;
    }

    pub fn is_zero(self: Int) -> bool {
        return len(self.mag) == 0;
    }

    // -1, 0 or 1 as self is below, equal to or above other.
    pub fn cmp(self: Int, other: Int) -> int {
        if self.neg != other.neg {
            if self.neg {
                return -1;
            }
            return 1;
        }
        let c = mag_cmp(self.mag, other.mag);
        if self.neg {
            return -c;
        }
        return c;
    }

    pub fn eq(self: Int, other: Int) -> bool {
        return self.cmp(other) == 0;
    }

    pub fn neg(self: Int) -> Int {
        return Int { neg: !self.neg && len(self.mag) > 0, mag: self.mag };
    }

    pub fn abs(self: Int) -> Int {
        return Int { neg: false, mag: self.mag };
    }

    pub fn add(self: Int, other: Int) -> Int {
        if self.neg == other.neg {
            return make(self.neg, mag_add(self.mag, other.mag));
        }
        let c = mag_cmp(self.mag, other.mag);
        if c == 0 {
            return zero();
        }
        if c > 0 {
            return make(self.neg, mag_sub(self.mag, other.mag));
        }
        return make(other.neg, mag_sub(other.mag, self.mag));
    }

    pub fn sub(self: Int, other: Int) -> Int {
        return self.add(other.neg());
    }

    pub fn mul(self: Int, other: Int) -> Int {
        return make(self.neg != other.neg, mag_mul(self.mag, other.mag));
    }

    // The quotient truncated toward zero; none for a zero divisor.
    pub fn div(self: Int, d: Int) -> opt[Int] {
        if d.is_zero() {
            return none;
        }
        let q: [u32] = [];
        let r: [u32] = [];
        mag_divmod(self.mag, d.mag, q, r);
        return some(make(self.neg != d.neg, q));
    }

    // The remainder of div: it has self's sign. none for a zero divisor.
    pub fn rem(self: Int, d: Int) -> opt[Int] {
        if d.is_zero() {
            return none;
        }
        let q: [u32] = [];
        let r: [u32] = [];
        mag_divmod(self.mag, d.mag, q, r);
        return some(make(self.neg, r));
    }

    // The quotient rounded toward negative infinity.
    pub fn div_floor(self: Int, d: Int) -> opt[Int] {
        if d.is_zero() {
            return none;
        }
        let q: [u32] = [];
        let r: [u32] = [];
        mag_divmod(self.mag, d.mag, q, r);
        let quo = make(self.neg != d.neg, q);
        if self.neg != d.neg && len(trim(r)) > 0 {
            quo = quo.sub(one());
        }
        return some(quo);
    }

    // self mod m in [0, |m|): never negative. none for a zero modulus.
    pub fn modulo(self: Int, m: Int) -> opt[Int] {
        if m.is_zero() {
            return none;
        }
        let q: [u32] = [];
        let r: [u32] = [];
        mag_divmod(self.mag, m.mag, q, r);
        let rr = make(false, r);
        if self.neg && !rr.is_zero() {
            return some(make(false, mag_sub(m.mag, rr.mag)));
        }
        return some(rr);
    }

    // self^e for e >= 0 (square-and-multiply). Panics for a negative e,
    // and for a result above 2^16,000,000 bits, which no program means.
    pub fn pow(self: Int, e: int) -> Int {
        if e < 0 {
            panic("big: pow with a negative exponent");
        }
        if (mag_bit_len(self.mag) as float) * (e as float) > 16000000.0 {
            panic("big: pow result would exceed 16 million bits");
        }
        let acc = one();
        let base = self;
        let k = e;
        while k > 0 {
            if (k & 1) == 1 {
                acc = acc.mul(base);
            }
            k = k >> 1;
            if k > 0 {
                base = base.mul(base);
            }
        }
        return acc;
    }

    // self^e mod m for e >= 0 and m > 0; none otherwise. An odd modulus
    // (RSA, Diffie-Hellman, most primes) runs Montgomery multiplication
    // with a 4-bit window, no division per step; an even one squares and
    // multiplies with a reduction after each.
    pub fn mod_pow(self: Int, e: Int, m: Int) -> opt[Int] {
        if m.sign() <= 0 || e.neg {
            return none;
        }
        if mag_cmp(m.mag, one().mag) == 0 {
            return some(zero());
        }
        let base = self.modulo(m) ?? zero();
        if len(m.mag) >= 2 && (m.mag[0] & 1) == 1 {
            if e.is_zero() {
                return some(one());
            }
            return some(make(false, mag_mod_pow_odd(base.mag, e.mag, m.mag)));
        }
        let acc = one();
        let bits = mag_bit_len(e.mag);
        let i = bits - 1;
        while i >= 0 {
            acc = acc.mul(acc).modulo(m) ?? zero();
            if e.bit(i) {
                acc = acc.mul(base).modulo(m) ?? zero();
            }
            i -= 1;
        }
        return some(acc);
    }

    // The greatest common divisor (never negative; gcd(0, 0) is 0).
    pub fn gcd(self: Int, other: Int) -> Int {
        let a = self.abs();
        let b = other.abs();
        while !b.is_zero() {
            let r = a.modulo(b) ?? zero();
            a = b;
            b = r;
        }
        return a;
    }

    // The inverse of self mod m (x with self * x = 1 mod m), in [0, m);
    // none when it does not exist (m <= 0, or self and m share a factor).
    pub fn mod_inv(self: Int, m: Int) -> opt[Int] {
        if m.sign() <= 0 {
            return none;
        }
        let a = self.modulo(m) ?? zero();
        let b = m;
        let x0 = one();
        let x1 = zero();
        while !b.is_zero() {
            let q = a.div_floor(b) ?? zero();
            let t = a.sub(q.mul(b));
            a = b;
            b = t;
            let tx = x0.sub(q.mul(x1));
            x0 = x1;
            x1 = tx;
        }
        if !a.eq(one()) {
            return none;
        }
        return x0.modulo(m);
    }

    // The integer square root: the largest r with r * r <= self (Newton
    // from above). none for a negative self.
    pub fn sqrt(self: Int) -> opt[Int] {
        if self.neg {
            return none;
        }
        if self.is_zero() {
            return some(zero());
        }
        let x = make(false, mag_shl(one().mag, (mag_bit_len(self.mag) + 1) / 2 + 1));
        while true {
            let y = x.add(self.div(x) ?? zero()).shr(1);
            if y.cmp(x) >= 0 {
                return some(x);
            }
            x = y;
        }
        return some(x);
    }

    // self * 2^n (n >= 0).
    pub fn shl(self: Int, n: int) -> Int {
        if n <= 0 {
            return self;
        }
        return make(self.neg, mag_shl(self.mag, n));
    }

    // self / 2^n rounded toward negative infinity (an arithmetic shift).
    pub fn shr(self: Int, n: int) -> Int {
        if n <= 0 {
            return self;
        }
        let m = mag_shr(self.mag, n);
        if self.neg && mag_low_bits_set(self.mag, n) {
            return make(true, mag_add(m, one().mag));
        }
        return make(self.neg, m);
    }

    // The number of bits in |self| (0 for zero).
    pub fn bit_len(self: Int) -> int {
        return mag_bit_len(self.mag);
    }

    // Bit i of the two's-complement form.
    pub fn bit(self: Int, i: int) -> bool {
        if i < 0 {
            return false;
        }
        if !self.neg {
            let limb = i / 32;
            if limb >= len(self.mag) {
                return false;
            }
            let one32: u32 = 1;
            return (self.mag[limb] & (one32 << (i % 32))) != 0;
        }
        // -x = ~(x - 1): the bit of x - 1, inverted
        let m1 = mag_sub(self.mag, one().mag);
        let limb = i / 32;
        if limb >= len(m1) {
            return true;
        }
        let one32: u32 = 1;
        return (m1[limb] & (one32 << (i % 32))) == 0;
    }

    pub fn and(self: Int, other: Int) -> Int {
        return bitwise(self, other, 0);
    }

    pub fn or(self: Int, other: Int) -> Int {
        return bitwise(self, other, 1);
    }

    pub fn xor(self: Int, other: Int) -> Int {
        return bitwise(self, other, 2);
    }

    // ~self = -self - 1.
    pub fn not(self: Int) -> Int {
        return self.neg().sub(one());
    }

    // self as an int, none when it does not fit.
    pub fn int_of(self: Int) -> opt[int] {
        if len(self.mag) > 2 {
            return none;
        }
        let v: u64 = 0;
        if len(self.mag) > 0 {
            v = self.mag[0] as u64;
        }
        if len(self.mag) > 1 {
            v = v | ((self.mag[1] as u64) << 32);
        }
        if !self.neg {
            if v > 9223372036854775807 {
                return none;
            }
            return some(v as int);
        }
        if v > 9223372036854775808 {
            return none;
        }
        return some((0 - v) as int);
    }

    // The nearest float (rounding the top 64 bits; huge values give
    // infinity).
    pub fn float_of(self: Int) -> float {
        let bl = mag_bit_len(self.mag);
        if bl == 0 {
            return 0.0;
        }
        let shift = math.max(bl - 64, 0);
        let top = mag_shr(self.mag, shift);
        let v: u64 = 0;
        if len(top) > 0 {
            v = top[0] as u64;
        }
        if len(top) > 1 {
            v = v | ((top[1] as u64) << 32);
        }
        // a sticky bit for the shifted-out part keeps the rounding right
        if shift > 0 && mag_low_bits_set(self.mag, shift) {
            v = v | 1;
        }
        let f = math.ldexp(v as float, shift);
        if self.neg {
            return -f;
        }
        return f;
    }

    // The digits in `base` (2 to 36, lowercase letters), with a leading
    // '-' when negative.
    pub fn format(self: Int, base: int) -> str {
        let bs = math.clamp(base, 2, 36);
        if len(self.mag) == 0 {
            return "0";
        }
        // peel chunks of digits that fit a limb, then emit each chunk
        let per = 1;
        let chunk: u64 = bs as u64;
        while chunk * (bs as u64) <= 4294967295 {
            chunk *= bs as u64;
            per += 1;
        }
        let parts: [u32] = [];
        let cur = self.mag;
        while len(cur) > 0 {
            let q: [u32] = [];
            let r = mag_divmod_small(cur, chunk as u32, q);
            push(parts, r);
            cur = q;
        }
        let out = builder.new_bytes();
        if self.neg {
            out.write_byte(45);
        }
        let i = len(parts) - 1;
        let first = true;
        let digits: [int] = [];
        while i >= 0 {
            let v = parts[i] as u64;
            for k in 0..per {
                push(digits, 0);
            }
            let k = per - 1;
            while k >= 0 {
                digits[len(digits) - per + k] = (v % (bs as u64)) as int;
                v = v / (bs as u64);
                k -= 1;
            }
            i -= 1;
        }
        let started = false;
        for d in digits {
            if d != 0 || started {
                started = true;
                out.write_byte(digit_char(d));
            }
        }
        let text = out.finish();
        return bytes_to_str(text);
    }

    // |self| as big-endian bytes, no leading zero byte (empty for 0).
    pub fn bytes_be(self: Int) -> bytes {
        let out = builder.new_bytes();
        let started = false;
        let i = len(self.mag) - 1;
        while i >= 0 {
            let w = self.mag[i];
            let sh = 24;
            while sh >= 0 {
                let byte = ((w >> sh) & 255) as int;
                if byte != 0 || started {
                    started = true;
                    out.write_byte(byte);
                }
                sh -= 8;
            }
            i -= 1;
        }
        return out.finish();
    }
}

fn bytes_to_str(b: bytes) -> str {
    return to_str(b);
}

// and (0), or (1), xor (2) on two's-complement forms, limb by limb with
// the sign extended past the shorter operand.
fn bitwise(a: Int, b: Int, op: int) -> Int {
    let n = math.max(len(a.mag), len(b.mag)) + 1;
    let x = twos(a, n);
    let y = twos(b, n);
    let out: [u32] = [];
    for i in 0..n {
        if op == 0 {
            push(out, x[i] & y[i]);
        } else if op == 1 {
            push(out, x[i] | y[i]);
        } else {
            push(out, x[i] ^ y[i]);
        }
    }
    // the top limb's high bit is the result's sign
    if (out[n - 1] >> 31) == 0 {
        return make(false, out);
    }
    // negative: magnitude is ~out + 1
    let inv: [u32] = [];
    for w in out {
        push(inv, ~w);
    }
    return make(true, mag_add(trim(inv), one().mag));
}

// n limbs of the two's-complement form of a.
fn twos(a: Int, n: int) -> [u32] {
    let out: [u32] = [];
    for i in 0..n {
        if i < len(a.mag) {
            push(out, a.mag[i]);
        } else {
            push(out, 0);
        }
    }
    if !a.neg {
        return out;
    }
    // ~mag + 1
    let carry: u64 = 1;
    for i in 0..n {
        let v = ((~out[i]) as u64) + carry;
        out[i] = (v & MASK32) as u32;
        carry = v >> 32;
    }
    return out;
}
