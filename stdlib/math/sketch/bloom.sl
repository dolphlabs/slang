import "builder";
import "math";

// "Have I seen this key?" in about 10 bits per key at 1% false positives,
// never a false negative. The split-block layout (Putze et al. 2007, as
// Parquet and Impala use it): each key sets one bit in each of the eight
// 32-bit words of a single 256-bit block, so an add or a lookup touches
// one cache line instead of seven scattered ones. Use it in front of a
// database or a cache to skip lookups that would miss, or to remember
// idempotency keys cheaply.
pub gc struct Bloom {
    nblocks: u64,
    words: [u32],     // 8 per block
}

// A filter sized for `n` keys at a false-positive rate of `fpp`: the
// bits Parquet's formula gives, -8n / ln(1 - fpp^(1/8)), in whole blocks.
// n is at least 1; fpp is clamped to [1e-6, 0.5]. bloom(1000000, 0.01)
// is 1.2 MB. Past `n` keys the rate climbs: size for the peak.
pub fn bloom(n: int, fpp: float) -> Bloom {
    let keys = math.max(n, 1) as float;
    let p = math.clamp(fpp, 0.000001, 0.5);
    let bits = -8.0 * keys / math.log(1.0 - math.pow(p, 0.125));
    let blocks = math.ceil_int(bits / 256.0) ?? 1;
    return bloom_blocks(blocks);
}

// A filter of exactly `blocks` 32-byte blocks (clamped to [1, 2^27]).
pub fn bloom_blocks(blocks: int) -> Bloom {
    let nb = math.clamp(blocks, 1, 134217728);
    let words: [u32] = [];
    for i in 0..nb * 8 {
        push(words, 0);
    }
    return Bloom { nblocks: nb as u64, words: words };
}

// A filter read back from encode().
pub fn decode_bloom(b: bytes) -> result[Bloom, str] {
    if len(b) < 9 || b[0] != 3 {
        return err("sketch: not a Bloom filter (version 3)");
    }
    let nb = from_le(b[1..9]);
    if nb < 1 || nb > 134217728 || len(b) != 9 + 32 * nb {
        return err("sketch: Bloom header does not match its length");
    }
    let f = bloom_blocks(nb);
    for i in 0..nb * 8 {
        let at = 9 + 4 * i;
        f.words[i] = ((b[at] as u32) | ((b[at + 1] as u32) << 8) |
                      ((b[at + 2] as u32) << 16) | ((b[at + 3] as u32) << 24));
    }
    return ok(f);
}

impl Bloom {
    // Adds the key with this hash. The high 32 bits pick the block, the
    // low 32 the eight bits within it.
    pub fn add_hash(self: Bloom, h: u64) -> Bloom {
        let base = block_of(h, self.nblocks);
        let key = (h & 0xffffffff) as u32;
        self.words[base] = self.words[base] | block_bit(key, 0x47b6137b);
        self.words[base + 1] = self.words[base + 1] | block_bit(key, 0x44974d91);
        self.words[base + 2] = self.words[base + 2] | block_bit(key, 0x8824ad5b);
        self.words[base + 3] = self.words[base + 3] | block_bit(key, 0xa2b7289d);
        self.words[base + 4] = self.words[base + 4] | block_bit(key, 0x705495c7);
        self.words[base + 5] = self.words[base + 5] | block_bit(key, 0x2df1424b);
        self.words[base + 6] = self.words[base + 6] | block_bit(key, 0x9efc4947);
        self.words[base + 7] = self.words[base + 7] | block_bit(key, 0x5c6bfb31);
        return self;
    }

    // False means the key was certainly never added; true means it
    // probably was.
    pub fn contains_hash(self: Bloom, h: u64) -> bool {
        let base = block_of(h, self.nblocks);
        let key = (h & 0xffffffff) as u32;
        return (self.words[base] & block_bit(key, 0x47b6137b)) != 0 &&
               (self.words[base + 1] & block_bit(key, 0x44974d91)) != 0 &&
               (self.words[base + 2] & block_bit(key, 0x8824ad5b)) != 0 &&
               (self.words[base + 3] & block_bit(key, 0xa2b7289d)) != 0 &&
               (self.words[base + 4] & block_bit(key, 0x705495c7)) != 0 &&
               (self.words[base + 5] & block_bit(key, 0x2df1424b)) != 0 &&
               (self.words[base + 6] & block_bit(key, 0x9efc4947)) != 0 &&
               (self.words[base + 7] & block_bit(key, 0x5c6bfb31)) != 0;
    }

    pub fn add_str(self: Bloom, s: str) -> Bloom {
        return self.add_hash(hash_str(s));
    }

    pub fn add_int(self: Bloom, x: int) -> Bloom {
        return self.add_hash(hash_int(x));
    }

    pub fn add_bytes(self: Bloom, b: bytes) -> Bloom {
        return self.add_hash(hash_bytes(b));
    }

    pub fn contains_str(self: Bloom, s: str) -> bool {
        return self.contains_hash(hash_str(s));
    }

    pub fn contains_int(self: Bloom, x: int) -> bool {
        return self.contains_hash(hash_int(x));
    }

    pub fn contains_bytes(self: Bloom, b: bytes) -> bool {
        return self.contains_hash(hash_bytes(b));
    }

    // Folds `other` in (bitwise OR): the filter of both key sets. False,
    // and no change, when the sizes differ.
    pub fn merge(self: Bloom, other: Bloom) -> bool {
        if other.nblocks != self.nblocks {
            return false;
        }
        for i in 0..len(self.words) {
            self.words[i] = self.words[i] | other.words[i];
        }
        return true;
    }

    pub fn clear(self: Bloom) {
        for i in 0..len(self.words) {
            self.words[i] = 0;
        }
    }

    // The memory the bits take.
    pub fn size_bytes(self: Bloom) -> int {
        return len(self.words) * 4;
    }

    // The share of bits set, 0 to 1: about 1 - e^(-8n/m) after n keys.
    pub fn fill(self: Bloom) -> float {
        let set = 0;
        for i in 0..len(self.words) {
            set += math.popcount(self.words[i]);
        }
        return (set as float) / ((len(self.words) * 32) as float);
    }

    // The false-positive rate the filter has now, estimated from its
    // fill: a lookup is a false positive when all eight of its bits are
    // set, about fill^8. Compare it with the rate it was sized for to
    // tell when it has taken more keys than planned.
    pub fn fpp(self: Bloom) -> float {
        return math.powi(self.fill(), 8);
    }

    // 9 + 32 * blocks bytes, little-endian.
    pub fn encode(self: Bloom) -> bytes {
        let b = builder.new_bytes();
        b.write_byte(3);
        b.write(to_le(self.nblocks as int));
        for i in 0..len(self.words) {
            let w = self.words[i];
            b.write_byte((w & 255) as int);
            b.write_byte(((w >> 8) & 255) as int);
            b.write_byte(((w >> 16) & 255) as int);
            b.write_byte((w >> 24) as int);
        }
        return b.finish();
    }
}

// The first word of the block for h: Lemire's multiply-shift maps the
// high 32 bits onto [0, nblocks) without a division.
fn block_of(h: u64, nblocks: u64) -> int {
    return ((((h >> 32) * nblocks) >> 32) as int) * 8;
}

// The one bit a key sets in a block's word with this salt: the top five
// bits of key * salt.
fn block_bit(key: u32, salt: u32) -> u32 {
    let one: u32 = 1;
    return one << ((key * salt) >> 27);
}
