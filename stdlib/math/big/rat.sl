// Exact fractions of two Ints, always in lowest terms with a positive
// denominator: rates and ratios that must not round, such as 1/3 of a
// share or an exchange rate quoted as a fraction.

import "math";

pub gc struct Rat {
    num: Int,
    den: Int,
}

fn rat_make(n: Int, d: Int) -> Rat {
    if n.is_zero() {
        return Rat { num: zero(), den: one() };
    }
    let g = n.gcd(d);
    let nn = n.div(g) ?? n;
    let dd = d.div(g) ?? d;
    if dd.neg {
        nn = nn.neg();
        dd = dd.neg();
    }
    return Rat { num: nn, den: dd };
}

pub fn rat_zero() -> Rat {
    return Rat { num: zero(), den: one() };
}

// n / d, reduced; none for a zero denominator.
pub fn rat(n: Int, d: Int) -> opt[Rat] {
    if d.is_zero() {
        return none;
    }
    return some(rat_make(n, d));
}

pub fn rat_from_int(n: int) -> Rat {
    return Rat { num: from_int(n), den: one() };
}

// A fraction from "3/4", "-7", "0.125" or "-2.5e-3" (exact: 0.1 is 1/10,
// not the float nearest it). Exponents are limited to +-10000.
pub fn rat_parse(s: str) -> result[Rat, str] {
    let b = to_bytes(s);
    let slash = -1;
    for i in 0..len(b) {
        if b[i] == 47 {
            slash = i;
        }
    }
    if slash >= 0 {
        let nr = parse(slice_str(b, 0, slash), 10);
        guard let n = nr else let e = err_of(nr) {
            return err(e);
        }
        let dr = parse(slice_str(b, slash + 1, len(b)), 10);
        guard let d = dr else let e = err_of(dr) {
            return err(e);
        }
        if d.is_zero() {
            return err("big: zero denominator in '" + s + "'");
        }
        return ok(rat_make(n, d));
    }
    // decimal: digits, an optional fraction, an optional exponent
    let epos = -1;
    for i in 0..len(b) {
        if b[i] == 101 || b[i] == 69 {
            epos = i;
        }
    }
    let mant_end = len(b);
    let exp = 0;
    if epos >= 0 {
        mant_end = epos;
        let er = to_int(slice_str(b, epos + 1, len(b)));
        guard let ev = er else {
            return err("big: bad exponent in '" + s + "'");
        }
        if ev > 10000 || ev < -10000 {
            return err("big: exponent out of range in '" + s + "'");
        }
        exp = ev;
    }
    let dot = -1;
    for i in 0..mant_end {
        if b[i] == 46 {
            dot = i;
        }
    }
    let digits = slice_str(b, 0, mant_end);
    let frac = 0;
    if dot >= 0 {
        digits = slice_str(b, 0, dot) + slice_str(b, dot + 1, mant_end);
        frac = mant_end - dot - 1;
        if frac == 0 || dot == 0 || (dot == 1 && (b[0] == 45 || b[0] == 43)) {
            return err("big: '" + s + "' is not a number");
        }
    }
    let mr = parse(digits, 10);
    guard let m = mr else let e = err_of(mr) {
        return err(e);
    }
    let scale = exp - frac;
    let ten = from_int(10);
    if scale >= 0 {
        return ok(Rat { num: m.mul(ten.pow(scale)), den: one() });
    }
    return ok(rat_make(m, ten.pow(-scale)));
}

fn slice_str(b: bytes, lo: int, hi: int) -> str {
    return to_str(b[lo..hi]);
}

impl Rat {
    pub fn numerator(self: Rat) -> Int {
        return self.num;
    }

    // Always positive.
    pub fn denominator(self: Rat) -> Int {
        return self.den;
    }

    pub fn add(self: Rat, o: Rat) -> Rat {
        return rat_make(self.num.mul(o.den).add(o.num.mul(self.den)), self.den.mul(o.den));
    }

    pub fn sub(self: Rat, o: Rat) -> Rat {
        return rat_make(self.num.mul(o.den).sub(o.num.mul(self.den)), self.den.mul(o.den));
    }

    pub fn mul(self: Rat, o: Rat) -> Rat {
        return rat_make(self.num.mul(o.num), self.den.mul(o.den));
    }

    // none when dividing by zero.
    pub fn div(self: Rat, o: Rat) -> opt[Rat] {
        if o.num.is_zero() {
            return none;
        }
        return some(rat_make(self.num.mul(o.den), self.den.mul(o.num)));
    }

    pub fn neg(self: Rat) -> Rat {
        return Rat { num: self.num.neg(), den: self.den };
    }

    pub fn cmp(self: Rat, o: Rat) -> int {
        return self.num.mul(o.den).cmp(o.num.mul(self.den));
    }

    pub fn eq(self: Rat, o: Rat) -> bool {
        return self.num.eq(o.num) && self.den.eq(o.den);
    }

    pub fn sign(self: Rat) -> int {
        return self.num.sign();
    }

    pub fn is_int(self: Rat) -> bool {
        return self.den.eq(one());
    }

    // The largest Int at or below the fraction.
    pub fn floor(self: Rat) -> Int {
        return self.num.div_floor(self.den) ?? zero();
    }

    // The smallest Int at or above it.
    pub fn ceil(self: Rat) -> Int {
        let q = self.num.neg().div_floor(self.den) ?? zero();
        return q.neg();
    }

    // The nearest Int, halves to even.
    pub fn round(self: Rat) -> Int {
        let f = self.floor();
        let rest = self.sub(Rat { num: f, den: one() });
        let c = rest.cmp(Rat { num: one(), den: from_int(2) });
        if c > 0 || (c == 0 && f.bit(0)) {
            return f.add(one());
        }
        return f;
    }

    // The nearest float (num and den each rounded once: within a few
    // ulps; exact for fractions whose parts fit 53 bits).
    pub fn float_of(self: Rat) -> float {
        let nb = self.num.bit_len();
        let db = self.den.bit_len();
        // scale so the quotient keeps 64 significant bits
        let shift = 64 - (nb - db);
        let n = self.num;
        let d = self.den;
        if shift > 0 {
            n = n.shl(shift);
        } else {
            d = d.shl(-shift);
        }
        let q = n.div(d) ?? zero();
        return math.ldexp(q.float_of(), -shift);
    }

    // "n/d", or "n" for a whole number.
    pub fn format(self: Rat) -> str {
        if self.is_int() {
            return self.num.format(10);
        }
        return self.num.format(10) + "/" + self.den.format(10);
    }

    // The decimal expansion to `places` digits after the point, rounded
    // half to even.
    pub fn format_decimal(self: Rat, places: int) -> str {
        let p = math.clamp(places, 0, 10000);
        let scaled = Rat { num: self.num.mul(from_int(10).pow(p)), den: self.den }.round();
        let neg = scaled.neg;
        let digits = scaled.abs().format(10);
        if p == 0 {
            if neg {
                return "-" + digits;
            }
            return digits;
        }
        while len(digits) <= p {
            digits = "0" + digits;
        }
        let raw = to_bytes(digits);
        let head = to_str(raw[0..len(raw) - p]);
        let tail = to_str(raw[len(raw) - p..len(raw)]);
        let out = head + "." + tail;
        if neg {
            return "-" + out;
        }
        return out;
    }
}

