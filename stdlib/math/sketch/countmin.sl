import "builder";
import "math";

// How often each key occurred, in fixed memory (Cormode and Muthukrishnan
// 2005): `depth` rows of `width` counters, each key adding to one counter
// per row and reading the smallest. An estimate is never below the true
// count, and with probability 1 - delta is at most epsilon * total above
// it. For rate limiting, abuse detection, and finding heavy keys among
// millions without a map entry each.
pub gc struct CountMin {
    w: int,           // a power of two
    d: int,
    mask: u64,
    cells: [int],     // row-major: row r holds cells[r * w .. (r + 1) * w]
    sum: int,
    conservative: bool,
}

// A sketch whose estimates are within epsilon * total of the truth with
// probability 1 - delta: width e / epsilon (rounded up to a power of two),
// depth ln(1 / delta). count_min(0.001, 0.01) is 4096 x 5 counters, 160 KB.
// epsilon is clamped to [1e-7, 0.5], delta to [1e-9, 0.5].
pub fn count_min(epsilon: float, delta: float) -> CountMin {
    let eps = math.clamp(epsilon, 0.0000001, 0.5);
    let dl = math.clamp(delta, 0.000000001, 0.5);
    let w = math.ceil_int(math.e / eps) ?? 2;
    let d = math.ceil_int(math.log(1.0 / dl)) ?? 1;
    return count_min_sized(w, d);
}

// A sketch of exactly `depth` rows (clamped to [1, 16]) of `width`
// counters (rounded up to a power of two, clamped to [2, 2^26]).
pub fn count_min_sized(width: int, depth: int) -> CountMin {
    let w = math.next_pow2(math.clamp(width, 2, 67108864)) ?? 67108864;
    let d = math.clamp(depth, 1, 16);
    let cells: [int] = [];
    for i in 0..w * d {
        push(cells, 0);
    }
    return CountMin {
        w: w, d: d, mask: (w - 1) as u64, cells: cells, sum: 0, conservative: false
    };
}

// A sketch read back from encode().
pub fn decode_count_min(b: bytes) -> result[CountMin, str] {
    if len(b) < 20 || b[0] != 2 {
        return err("sketch: not a CountMin (version 2)");
    }
    let w = from_le(b[2..10]);
    let d = b[1] as int;
    if w < 2 || w > 67108864 || !math.is_pow2(w) || d < 1 || d > 16 ||
       len(b) != 19 + 8 * w * d {
        return err("sketch: CountMin header does not match its length");
    }
    let c = count_min_sized(w, d);
    c.sum = from_le(b[10..18]);
    c.conservative = b[18] == 1;
    for i in 0..w * d {
        let at = 19 + 8 * i;
        c.cells[i] = from_le(b[at..at + 8]);
    }
    return ok(c);
}

impl CountMin {
    // Conservative update (Estan and Varghese): raise each of a key's
    // counters only as far as its new estimate. Estimates stay upper
    // bounds and get much tighter on skewed data, at the price of merge
    // being an upper bound too. Set it before the first add.
    pub fn set_conservative(self: CountMin, on: bool) -> CountMin {
        self.conservative = on;
        return self;
    }

    // Adds n (ignored unless positive) to the key with this hash.
    pub fn add_hash(self: CountMin, h: u64, n: int) -> CountMin {
        if n <= 0 {
            return self;
        }
        self.sum += n;
        // Kirsch-Mitzenmacher: row r uses h1 + r * h2, as good as d
        // independent hashes for this purpose and one hash to compute.
        let h2 = mix64(h) | 1;
        if !self.conservative {
            let g = h;
            for r in 0..self.d {
                self.cells[r * self.w + ((g & self.mask) as int)] += n;
                g += h2;
            }
            return self;
        }
        let target = self.estimate_hash(h) + n;
        let g = h;
        for r in 0..self.d {
            let at = r * self.w + ((g & self.mask) as int);
            if self.cells[at] < target {
                self.cells[at] = target;
            }
            g += h2;
        }
        return self;
    }

    // An upper bound on the key's total, usually exact for heavy keys.
    pub fn estimate_hash(self: CountMin, h: u64) -> int {
        let h2 = mix64(h) | 1;
        let g = h;
        let best = self.cells[(g & self.mask) as int];
        for r in 1..self.d {
            g += h2;
            let v = self.cells[r * self.w + ((g & self.mask) as int)];
            if v < best {
                best = v;
            }
        }
        return best;
    }

    pub fn add_str(self: CountMin, s: str, n: int) -> CountMin {
        return self.add_hash(hash_str(s), n);
    }

    pub fn add_int(self: CountMin, x: int, n: int) -> CountMin {
        return self.add_hash(hash_int(x), n);
    }

    pub fn add_bytes(self: CountMin, b: bytes, n: int) -> CountMin {
        return self.add_hash(hash_bytes(b), n);
    }

    pub fn estimate_str(self: CountMin, s: str) -> int {
        return self.estimate_hash(hash_str(s));
    }

    pub fn estimate_int(self: CountMin, x: int) -> int {
        return self.estimate_hash(hash_int(x));
    }

    pub fn estimate_bytes(self: CountMin, b: bytes) -> int {
        return self.estimate_hash(hash_bytes(b));
    }

    // The sum of every n added.
    pub fn total(self: CountMin) -> int {
        return self.sum;
    }

    pub fn width(self: CountMin) -> int {
        return self.w;
    }

    pub fn depth(self: CountMin) -> int {
        return self.d;
    }

    // Adds `other`'s counts to this sketch's. False, and no change, when
    // the two differ in width or depth.
    pub fn merge(self: CountMin, other: CountMin) -> bool {
        if other.w != self.w || other.d != self.d {
            return false;
        }
        for i in 0..len(self.cells) {
            self.cells[i] += other.cells[i];
        }
        self.sum += other.sum;
        return true;
    }

    // Zeroes every counter, keeping the memory. A rate limiter clears
    // (or swaps in a fresh sketch) at each window boundary.
    pub fn clear(self: CountMin) {
        for i in 0..len(self.cells) {
            self.cells[i] = 0;
        }
        self.sum = 0;
    }

    // 19 + 8 * width * depth bytes, little-endian.
    pub fn encode(self: CountMin) -> bytes {
        let b = builder.new_bytes();
        b.write_byte(2);
        b.write_byte(self.d);
        b.write(to_le(self.w));
        b.write(to_le(self.sum));
        if self.conservative {
            b.write_byte(1);
        } else {
            b.write_byte(0);
        }
        for i in 0..len(self.cells) {
            b.write(to_le(self.cells[i]));
        }
        return b.finish();
    }
}
