import "math";

// A set membership filter that can also delete (Fan et al. 2014): each key
// keeps a 16-bit fingerprint in one of two buckets of four slots. About
// 17 bits per key at 95% load with a 0.012% false-positive rate, and a
// lookup reads two cache lines at most. Unlike a Bloom filter it can
// remove a key, so it fits sets that change: active sessions, in-flight
// job ids, revoked tokens.
//
// Remove only keys that were added: removing a key that never was can
// evict a different key sharing its fingerprint.
pub gc struct Cuckoo {
    mask: u64,         // buckets - 1; buckets is a power of two
    slots: [u16],      // 4 per bucket, 0 for empty
    n: int,
    // One fingerprint that found no room: kept aside rather than lost, so
    // the filter never has a false negative. While it is held, adds fail.
    victim_fp: u16,
    victim_at: u64,
    has_victim: bool,
    rng: u64,          // xorshift state for choosing which slot to kick
}

// A filter with room for about `capacity` keys (at 95% load). At least
// one bucket; capacity is clamped to 2^30.
pub fn cuckoo(capacity: int) -> Cuckoo {
    let want = math.clamp(capacity, 1, 1073741824) as float / (4.0 * 0.95);
    let buckets = math.next_pow2(math.ceil_int(want) ?? 1) ?? 1;
    let slots: [u16] = [];
    for i in 0..buckets * 4 {
        push(slots, 0);
    }
    return Cuckoo {
        mask: (buckets - 1) as u64, slots: slots, n: 0, victim_fp: 0,
        victim_at: 0, has_victim: false, rng: 0x2545f4914f6cdd1d
    };
}

impl Cuckoo {
    // Adds the key with this hash. False when the filter is full (the
    // key is then not added and nothing else is lost).
    pub fn add_hash(self: Cuckoo, h: u64) -> bool {
        if self.has_victim {
            return false;
        }
        let fp = fingerprint(h);
        let i1 = h & self.mask;
        let i2 = alt_bucket(i1, fp, self.mask);
        if self.put(i1, fp) || self.put(i2, fp) {
            self.n += 1;
            return true;
        }
        // Kick a random resident to its other bucket, up to 500 times.
        let i = i1;
        if (self.next_rand() & 1) == 1 {
            i = i2;
        }
        let cur = fp;
        for kick in 0..500 {
            let slot = (i as int) * 4 + ((self.next_rand() & 3) as int);
            let evicted = self.slots[slot];
            self.slots[slot] = cur;
            cur = evicted;
            i = alt_bucket(i, cur, self.mask);
            if self.put(i, cur) {
                self.n += 1;
                return true;
            }
        }
        // `fp` is in the table now and `cur` is the one left over: keep
        // it, so its key still tests present.
        self.victim_fp = cur;
        self.victim_at = i;
        self.has_victim = true;
        self.n += 1;
        return true;
    }

    // False means the key is certainly not in the filter.
    pub fn contains_hash(self: Cuckoo, h: u64) -> bool {
        let fp = fingerprint(h);
        let i1 = h & self.mask;
        let i2 = alt_bucket(i1, fp, self.mask);
        if self.has_victim && self.victim_fp == fp &&
           (self.victim_at == i1 || self.victim_at == i2) {
            return true;
        }
        return self.holds(i1, fp) || self.holds(i2, fp);
    }

    // Removes one copy of the key. False when it was not found.
    pub fn remove_hash(self: Cuckoo, h: u64) -> bool {
        let fp = fingerprint(h);
        let i1 = h & self.mask;
        let i2 = alt_bucket(i1, fp, self.mask);
        if self.has_victim && self.victim_fp == fp &&
           (self.victim_at == i1 || self.victim_at == i2) {
            self.has_victim = false;
            self.n -= 1;
            return true;
        }
        if self.take(i1, fp) || self.take(i2, fp) {
            self.n -= 1;
            // Room may have opened for the victim.
            if self.has_victim {
                let vi = self.victim_at;
                let vf = self.victim_fp;
                if self.put(vi, vf) || self.put(alt_bucket(vi, vf, self.mask), vf) {
                    self.has_victim = false;
                }
            }
            return true;
        }
        return false;
    }

    pub fn add_str(self: Cuckoo, s: str) -> bool {
        return self.add_hash(hash_str(s));
    }

    pub fn add_int(self: Cuckoo, x: int) -> bool {
        return self.add_hash(hash_int(x));
    }

    pub fn add_bytes(self: Cuckoo, b: bytes) -> bool {
        return self.add_hash(hash_bytes(b));
    }

    pub fn contains_str(self: Cuckoo, s: str) -> bool {
        return self.contains_hash(hash_str(s));
    }

    pub fn contains_int(self: Cuckoo, x: int) -> bool {
        return self.contains_hash(hash_int(x));
    }

    pub fn contains_bytes(self: Cuckoo, b: bytes) -> bool {
        return self.contains_hash(hash_bytes(b));
    }

    pub fn remove_str(self: Cuckoo, s: str) -> bool {
        return self.remove_hash(hash_str(s));
    }

    pub fn remove_int(self: Cuckoo, x: int) -> bool {
        return self.remove_hash(hash_int(x));
    }

    pub fn remove_bytes(self: Cuckoo, b: bytes) -> bool {
        return self.remove_hash(hash_bytes(b));
    }

    // Keys held.
    pub fn count(self: Cuckoo) -> int {
        return self.n;
    }

    // Keys held over slots: past about 0.95 adds start to fail.
    pub fn load(self: Cuckoo) -> float {
        return (self.n as float) / (len(self.slots) as float);
    }

    pub fn size_bytes(self: Cuckoo) -> int {
        return len(self.slots) * 2;
    }

    pub fn clear(self: Cuckoo) {
        for i in 0..len(self.slots) {
            self.slots[i] = 0;
        }
        self.n = 0;
        self.has_victim = false;
    }

    // Unrolled over the four slots: no loop, so a leaf.
    fn put(self: Cuckoo, bucket: u64, fp: u16) -> bool {
        let at = (bucket as int) * 4;
        if self.slots[at] == 0 {
            self.slots[at] = fp;
            return true;
        }
        if self.slots[at + 1] == 0 {
            self.slots[at + 1] = fp;
            return true;
        }
        if self.slots[at + 2] == 0 {
            self.slots[at + 2] = fp;
            return true;
        }
        if self.slots[at + 3] == 0 {
            self.slots[at + 3] = fp;
            return true;
        }
        return false;
    }

    fn holds(self: Cuckoo, bucket: u64, fp: u16) -> bool {
        let at = (bucket as int) * 4;
        return self.slots[at] == fp || self.slots[at + 1] == fp ||
               self.slots[at + 2] == fp || self.slots[at + 3] == fp;
    }

    fn take(self: Cuckoo, bucket: u64, fp: u16) -> bool {
        let at = (bucket as int) * 4;
        if self.slots[at] == fp {
            self.slots[at] = 0;
            return true;
        }
        if self.slots[at + 1] == fp {
            self.slots[at + 1] = 0;
            return true;
        }
        if self.slots[at + 2] == fp {
            self.slots[at + 2] = 0;
            return true;
        }
        if self.slots[at + 3] == fp {
            self.slots[at + 3] = 0;
            return true;
        }
        return false;
    }

    fn next_rand(self: Cuckoo) -> u64 {
        let x = self.rng;
        x = x ^ (x << 13);
        x = x ^ (x >> 7);
        x = x ^ (x << 17);
        self.rng = x;
        return x;
    }
}

// The top 16 bits of the hash, never 0 (0 marks an empty slot). The low
// bits pick the bucket, so the two are independent.
fn fingerprint(h: u64) -> u16 {
    let f = (h >> 48) as u16;
    if f == 0 {
        return 1;
    }
    return f;
}

// The other bucket a fingerprint may live in: i XOR hash(fp), its own
// inverse, so either bucket finds the other from the fingerprint alone.
fn alt_bucket(i: u64, fp: u16, mask: u64) -> u64 {
    return (i ^ ((fp as u64) * 0xc6a4a7935bd1e995)) & mask;
}
