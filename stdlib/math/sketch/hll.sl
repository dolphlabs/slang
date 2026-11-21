import "builder";
import "math";

// Counts distinct items in fixed memory (Flajolet et al., with Ertl's
// 2017 estimator, which is unbiased from 0 to billions with no lookup
// tables). Precision p uses 2^p bytes and has a relative standard error
// of 1.04 / sqrt(2^p):
//
//     p = 10:  1 KB, 3.3%     p = 14: 16 KB, 0.81%
//     p = 12:  4 KB, 1.6%     p = 16: 64 KB, 0.41%
//
// Adding the same item twice changes nothing, and two sketches merge into
// the sketch of the union of their items.
pub gc struct HyperLogLog {
    p: int,
    regs: [u8],   // per register: the longest run of leading zeros seen, + 1
}

// A sketch with 2^precision registers; precision is clamped to [4, 18].
pub fn hyperloglog(precision: int) -> HyperLogLog {
    let p = math.clamp(precision, 4, 18);
    let regs: [u8] = [];
    for i in 0..(1 << p) {
        push(regs, 0);
    }
    return HyperLogLog { p: p, regs: regs };
}

// A sketch read back from encode(). Refuses a wrong length, an unknown
// version or a register no sketch could hold.
pub fn decode_hyperloglog(b: bytes) -> result[HyperLogLog, str] {
    if len(b) < 2 || b[0] != 1 {
        return err("sketch: not a HyperLogLog (version 1)");
    }
    let p = b[1] as int;
    if p < 4 || p > 18 || len(b) != 2 + (1 << p) {
        return err("sketch: HyperLogLog length does not match its precision");
    }
    let cap = 65 - p;
    let regs: [u8] = [];
    for i in 0..(1 << p) {
        let v = b[2 + i];
        if (v as int) > cap {
            return err("sketch: HyperLogLog register out of range");
        }
        push(regs, v as u8);
    }
    return ok(HyperLogLog { p: p, regs: regs });
}

impl HyperLogLog {
    // Adds an item by its 64-bit hash (hash_str, hash_int, hash_bytes, or
    // any well-mixed hash). The top p bits pick a register; the rest
    // give the rank.
    pub fn add_hash(self: HyperLogLog, h: u64) -> HyperLogLog {
        let idx = (h >> (64 - self.p)) as int;
        // the guard bit caps the rank at 65 - p when the rest is all zero
        let one: u64 = 1;
        let w = (h << self.p) | (one << (self.p - 1));
        let rank = (math.leading_zeros(w) + 1) as u8;
        if rank > self.regs[idx] {
            self.regs[idx] = rank;
        }
        return self;
    }

    pub fn add_str(self: HyperLogLog, s: str) -> HyperLogLog {
        return self.add_hash(hash_str(s));
    }

    pub fn add_int(self: HyperLogLog, x: int) -> HyperLogLog {
        return self.add_hash(hash_int(x));
    }

    pub fn add_bytes(self: HyperLogLog, b: bytes) -> HyperLogLog {
        return self.add_hash(hash_bytes(b));
    }

    // The estimated number of distinct items, as a float.
    pub fn estimate(self: HyperLogLog) -> float {
        let q = 64 - self.p;
        let m = (1 << self.p) as float;
        let hist: [int] = [];
        for k in 0..q + 2 {
            push(hist, 0);
        }
        for i in 0..len(self.regs) {
            hist[self.regs[i] as int] += 1;
        }
        let z = m * ertl_tau(1.0 - (hist[q + 1] as float) / m);
        let k = q;
        while k >= 1 {
            z = 0.5 * (z + (hist[k] as float));
            k -= 1;
        }
        z += m * ertl_sigma((hist[0] as float) / m);
        return m * m / (2.0 * math.ln2 * z);
    }

    // The estimate rounded to the nearest int.
    pub fn count(self: HyperLogLog) -> int {
        return math.round_int(self.estimate()) ?? 0;
    }

    pub fn precision(self: HyperLogLog) -> int {
        return self.p;
    }

    // Folds `other` in, so this sketch counts the union of both. False,
    // and no change, when the precisions differ.
    pub fn merge(self: HyperLogLog, other: HyperLogLog) -> bool {
        if other.p != self.p {
            return false;
        }
        for i in 0..len(self.regs) {
            if other.regs[i] > self.regs[i] {
                self.regs[i] = other.regs[i];
            }
        }
        return true;
    }

    // Empties the sketch, keeping its memory.
    pub fn clear(self: HyperLogLog) {
        for i in 0..len(self.regs) {
            self.regs[i] = 0;
        }
    }

    // 2 + 2^p bytes: a version byte, the precision, then the registers.
    pub fn encode(self: HyperLogLog) -> bytes {
        let b = builder.new_bytes();
        b.write_byte(1);
        b.write_byte(self.p);
        for i in 0..len(self.regs) {
            b.write_byte(self.regs[i] as int);
        }
        return b.finish();
    }
}

// Ertl's sigma(x) = x + sum_k x^(2^k) 2^(k-1), for the empty registers.
fn ertl_sigma(x0: float) -> float {
    if x0 == 1.0 {
        return math.inf;
    }
    let x = x0;
    let y = 1.0;
    let z = x;
    while true {
        x = x * x;
        let prev = z;
        z += x * y;
        y += y;
        if z == prev {
            return z;
        }
    }
    return z;
}

// Ertl's tau(x), for the registers at the cap.
fn ertl_tau(x0: float) -> float {
    if x0 == 0.0 || x0 == 1.0 {
        return 0.0;
    }
    let x = x0;
    let y = 1.0;
    let z = 1.0 - x;
    while true {
        x = math.sqrt(x);
        let prev = z;
        y *= 0.5;
        z -= (1.0 - x) * (1.0 - x) * y;
        if z == prev {
            return z / 3.0;
        }
    }
    return z / 3.0;
}
