// Seeded, non-cryptographic random numbers: dice, sampling, shuffles and
// retry jitter that a test can replay exactly.
//
//     import "rand";
//
//     let r = rand.new(42);                 // same seed, same sequence
//     rand.below(r, 10)                     // int in [0, 10)
//     rand.between(r, 1, 6)                 // int in [1, 6], ends included
//     rand.unit(r)                          // float in [0, 1)
//     rand.chance(r, 0.25)                  // true about one time in four
//     rand.shuffle(r, xs)                   // xs reordered in place
//     rand.pick(r, xs) ?? fallback          // one element, none if xs is empty
//     rand.backoff(r, attempt, base, cap)   // retry delay with full jitter
//     rand.jitter(r, d, 0.1)                // d spread by up to 10% either way
//
// Not for secrets. Anything an attacker must not predict (tokens, keys,
// session ids, password salts) comes from crypto.rand. This generator is
// fast and statistically good, but its whole future follows from 256 bits
// of state, which can be recovered from its outputs.
//
// The generator is xoshiro256** (Blackman and Vigna), seeded through
// splitmix64, the seeding its authors recommend. A seed fixes the sequence
// on every platform and in every slang release: the tests pin exact
// outputs, so changing the algorithm breaks them on purpose, and a failing
// test seen on CI can be replayed from its seed on a laptop.
//
// An Rng is not locked. Give each task its own, from `fork`, rather than
// sharing one between tasks.

import "crypto";

// A random number generator. Make one with `new` or `from_os`.
pub gc struct Rng {
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
}

// A generator whose sequence is fixed by `seed`. Every int is a good seed,
// 0 and -1 included: splitmix64 spreads it over all 256 bits of state.
pub fn new(seed: int) -> Rng {
    let sm = seed as u64;
    let s0 = splitmix(sm);
    sm = sm + GOLDEN;
    let s1 = splitmix(sm);
    sm = sm + GOLDEN;
    let s2 = splitmix(sm);
    sm = sm + GOLDEN;
    let s3 = splitmix(sm);
    return Rng { s0: s0, s1: s1, s2: s2, s3: s3 };
}

// A generator seeded from the operating system's CSPRNG, for when runs
// should differ (load generators, sampling in production). Its outputs are
// still predictable from earlier ones: this is not a source of secrets.
pub fn from_os() -> result[Rng, str] {
    let res = crypto.rand(32);
    guard let b = res else let e = err_of(res) {
        return err("rand: no randomness from the OS: " + e);
    }
    let r = Rng {
        s0: word(b, 0), s1: word(b, 8), s2: word(b, 16), s3: word(b, 24)
    };
    // xoshiro's one bad state: all zero bits stay zero forever. The odds
    // are 2^-256, but a broken OS source returning zeros is not that rare.
    if r.s0 == 0 && r.s1 == 0 && r.s2 == 0 && r.s3 == 0 {
        return err("rand: the OS returned 32 zero bytes");
    }
    return ok(r);
}

// A new generator seeded from `r`, for handing to a spawned task. Seeded
// parents give seeded children, so a whole run still replays from one
// seed. `r` advances by one step.
pub fn fork(r: Rng) -> Rng {
    return new(next_u64(r) as int);
}

// The next 64 random bits.
pub fn next_u64(r: Rng) -> u64 {
    let out = rotl(r.s1 * 5, 7) * 9;
    let t = r.s1 << 17;
    r.s2 = r.s2 ^ r.s0;
    r.s3 = r.s3 ^ r.s1;
    r.s1 = r.s1 ^ r.s2;
    r.s0 = r.s0 ^ r.s3;
    r.s2 = r.s2 ^ t;
    r.s3 = rotl(r.s3, 45);
    return out;
}

// An int in [0, n), each value equally likely. Panics if n is not
// positive: there is no int to return, as with an index out of range.
pub fn below(r: Rng, n: int) -> int {
    if n <= 0 {
        panic("rand.below: n must be positive, got " + to_str(n));
    }
    return uniform(r, n as u64) as int;
}

// An int in [lo, hi], both ends included, each value equally likely.
// Panics if lo > hi. The full range, between(r, MIN, MAX), works.
pub fn between(r: Rng, lo: int, hi: int) -> int {
    if lo > hi {
        panic("rand.between: lo " + to_str(lo) + " is above hi " + to_str(hi));
    }
    // In u64 the span cannot overflow; it wraps to 0 only for the full
    // range, where every 64-bit value is already a valid answer.
    let span = (hi as u64) - (lo as u64) + 1;
    if span == 0 {
        return next_u64(r) as int;
    }
    return ((lo as u64) + uniform(r, span)) as int;
}

// A float in the unit interval [0, 1): one of 2^53 evenly spaced values,
// so every float it returns is exact and 1.0 never appears.
pub fn unit(r: Rng) -> float {
    return (next_u64(r) >> 11) as float * TWO_POW_MINUS_53;
}

// True with probability `p`. p at or below 0 (or NaN) is never, p at or
// above 1 is always.
pub fn chance(r: Rng, p: float) -> bool {
    if !(p > 0.0) {
        return false;
    }
    if p >= 1.0 {
        return true;
    }
    return unit(r) < p;
}

// Reorders `xs` in place, every order equally likely (Fisher-Yates).
pub fn shuffle[T](r: Rng, xs: [T]) {
    let i = len(xs) - 1;
    while i > 0 {
        let j = uniform(r, (i + 1) as u64) as int;
        let tmp = xs[i];
        xs[i] = xs[j];
        xs[j] = tmp;
        i = i - 1;
    }
}

// One element of `xs`, each equally likely; none if `xs` is empty.
pub fn pick[T](r: Rng, xs: [T]) -> opt[T] {
    if len(xs) == 0 {
        return none;
    }
    return some(xs[uniform(r, len(xs) as u64) as int]);
}

// How long to wait before retry number `attempt` (0 for the first retry):
// a uniform draw from [0, min(cap, base * 2^attempt)], the "full jitter"
// strategy. Spreading over the whole interval, not just its top, is what
// stops a crowd of clients that failed together from retrying together.
// Units are whatever `base` and `cap` use, nanoseconds for a duration. A
// negative attempt counts as 0; a base or cap at or below 0 gives 0.
pub fn backoff(r: Rng, attempt: int, base: int, cap: int) -> int {
    if base <= 0 || cap <= 0 {
        return 0;
    }
    let ceiling = base;
    if ceiling > cap {
        ceiling = cap;
    }
    let n = 0;
    while n < attempt && ceiling < cap {
        // Doubling saturates at cap instead of overflowing.
        if ceiling > cap / 2 {
            ceiling = cap;
        } else {
            ceiling = ceiling * 2;
        }
        n = n + 1;
    }
    return between(r, 0, ceiling);
}

// `d` scaled by a uniform factor in [1 - frac, 1 + frac]: jitter(r, d, 0.1)
// lands within 10% of d. frac is clamped to [0, 1] (NaN counts as 0), so
// the result is never negative. A d at or below 0 gives 0.
pub fn jitter(r: Rng, d: int, frac: float) -> int {
    if d <= 0 {
        return 0;
    }
    let f = frac;
    if !(f > 0.0) {
        return d;
    }
    if f > 1.0 {
        f = 1.0;
    }
    let scaled = d as float * (1.0 - f + 2.0 * f * unit(r));
    // d near the int limit times a factor above 1 can pass it; a float
    // above 2^63 has no int, so clamp before converting.
    if scaled >= INT_LIMIT {
        return MAX_INT;
    }
    return scaled as int;
}

// ---- internals -----------------------------------------------------------

// splitmix64's increment, the 64-bit golden ratio.
let GOLDEN: u64 = 0x9e3779b97f4a7c15;
// 2^-53, exactly: the gap between neighbouring floats in [0.5, 1).
let TWO_POW_MINUS_53 = 1.1102230246251565e-16;
// 2^63 as a float, the first value past the largest int.
let INT_LIMIT = 9223372036854775808.0;
let MAX_INT = 9223372036854775807;

// One splitmix64 output for state `x` (the state after its increment).
fn splitmix(x: u64) -> u64 {
    let z = x + GOLDEN;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn rotl(x: u64, k: int) -> u64 {
    return (x << k) | (x >> (64 - k));
}

// A uniform value in [0, n) for n > 0, without modulo bias: a raw draw
// below `cut` would make the low residues more likely, so it is redrawn.
// cut = 2^64 mod n is under n, so less than half of draws are ever
// redrawn and usually almost none are.
fn uniform(r: Rng, n: u64) -> u64 {
    let cut = (0 - n) % n;
    while true {
        let x = next_u64(r);
        if x >= cut {
            return x % n;
        }
    }
    return 0;
}

// Eight bytes of `b` from `at`, little-endian.
fn word(b: bytes, at: int) -> u64 {
    let w: u64 = 0;
    for i in 0..8 {
        w = w | ((b[at + i] as u64) << (8 * i));
    }
    return w;
}
