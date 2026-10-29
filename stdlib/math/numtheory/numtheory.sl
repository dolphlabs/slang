// Number theory on int: modular arithmetic, primes, factorization.
//
//     import "math/numtheory";
//
//     numtheory.mod_pow(2, 100, 1000000007);    // 976371285
//     numtheory.mod_inv(3, 7) ?? 0;             // 5: 3 * 5 = 15 = 1 (mod 7)
//     numtheory.is_prime(1000000007);           // true, exactly, for any int
//     numtheory.factorize(360);                 // [2^3, 3^2, 5^1] as Factors
//     numtheory.primes_below(30);               // [2, 3, 5, 7, 11, 13, ...]
//
// Products are taken modulo with math.mul_mod, which holds them at 128
// bits, so a modulus near 2^62 is as safe as a small one. A modulus must be
// positive: functions that take one return none (or 0, or false) for
// m <= 0 rather than panic. Results are never negative.

import "math";

// b^e mod m, by squaring: O(log e). 0 when m <= 0 or e < 0 (a negative
// power needs mod_inv first); 1 mod m for e = 0.
pub fn mod_pow(b: int, e: int, m: int) -> int {
    if m <= 0 || e < 0 {
        return 0;
    }
    if m == 1 {
        return 0;
    }
    let r = 1;
    let base = math.rem_euclid(b, m);
    let k = e;
    while k > 0 {
        if k % 2 == 1 {
            r = math.mul_mod(r, base, m) ?? 0;
        }
        base = math.mul_mod(base, base, m) ?? 0;
        k = k / 2;
    }
    return r;
}

// (a * b) mod m, in [0, m), without overflow; 0 when m <= 0.
pub fn mod_mul(a: int, b: int, m: int) -> int {
    if m <= 0 {
        return 0;
    }
    return math.mul_mod(a, b, m) ?? 0;
}

pub struct Bezout {
    g: int,   // gcd(a, b), never negative
    x: int,   // a * x + b * y == g
    y: int,
}

// The extended Euclidean algorithm: g = gcd(a, b) and x, y with
// a * x + b * y = g.
pub fn ext_gcd(a: int, b: int) -> Bezout {
    let old_r = a;
    let r = b;
    let old_s = 1;
    let s = 0;
    let old_t = 0;
    let t = 1;
    while r != 0 {
        let q = old_r / r;
        let tmp = r;
        r = old_r - q * r;
        old_r = tmp;
        tmp = s;
        s = old_s - q * s;
        old_s = tmp;
        tmp = t;
        t = old_t - q * t;
        old_t = tmp;
    }
    if old_r < 0 {
        return Bezout { g: -old_r, x: -old_s, y: -old_t };
    }
    return Bezout { g: old_r, x: old_s, y: old_t };
}

// The x in [0, m) with a * x = 1 (mod m); none when a and m share a
// factor (no inverse exists) or m <= 0.
pub fn mod_inv(a: int, m: int) -> opt[int] {
    if m <= 0 {
        return none;
    }
    let bz = ext_gcd(math.rem_euclid(a, m), m);
    if bz.g != 1 {
        return none;
    }
    return some(math.rem_euclid(bz.x, m));
}

// Whether n is prime: exact for every int (deterministic Miller-Rabin
// with the seven bases Jim Sinclair found to cover all of 64 bits), after
// trial division by the small primes. false for n < 2.
pub fn is_prime(n: int) -> bool {
    if n < 2 {
        return false;
    }
    let small = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37];
    for p in small {
        if n % p == 0 {
            return n == p;
        }
    }
    if n < 1369 { // 37^2: no factor up to 37, so prime
        return true;
    }
    let d = n - 1;
    let s = 0;
    while d % 2 == 0 {
        d = d / 2;
        s += 1;
    }
    let bases = [2, 325, 9375, 28178, 450775, 9780504, 1795265022];
    for a in bases {
        if !strong_probable_prime(n, a, d, s) {
            return false;
        }
    }
    return true;
}

// The smallest prime >= n (2 for n <= 2); none past the largest int prime.
pub fn next_prime(n: int) -> opt[int] {
    if n <= 2 {
        return some(2);
    }
    let c = n;
    if c % 2 == 0 {
        c += 1;
    }
    while true {
        if is_prime(c) {
            return some(c);
        }
        guard let nc = math.checked_add(c, 2) else {
            return none;
        }
        c = nc;
    }
    return none;
}

// The largest prime <= n; none for n < 2.
pub fn prev_prime(n: int) -> opt[int] {
    if n < 2 {
        return none;
    }
    if n == 2 {
        return some(2);
    }
    let c = n;
    if c % 2 == 0 {
        c -= 1;
    }
    while c >= 3 {
        if is_prime(c) {
            return some(c);
        }
        c -= 2;
    }
    return some(2);
}

// Every prime below n, ascending: the sieve of Eratosthenes over the odd
// numbers, n / 2 bytes of memory. Empty for n <= 2.
pub fn primes_below(n: int) -> [int] {
    let out: [int] = [];
    if n <= 2 {
        return out;
    }
    push(out, 2);
    let half = (n - 1) / 2;          // index i stands for 2i + 1
    let composite: [bool] = [];
    for i in 0..half + 1 {
        push(composite, false);
    }
    let i = 1;
    while (2 * i + 1) * (2 * i + 1) < n {
        if !composite[i] {
            let p = 2 * i + 1;
            let j = (p * p - 1) / 2;
            while j <= half {
                composite[j] = true;
                j += p;
            }
        }
        i += 1;
    }
    for k in 1..half + 1 {
        let v = 2 * k + 1;
        if v < n && !composite[k] {
            push(out, v);
        }
    }
    return out;
}

pub struct Factor {
    p: int,   // a prime
    k: int,   // its exponent
}

// The prime factorization of |n|, ascending by prime: 360 is
// [{2, 3}, {3, 2}, {5, 1}]. Empty for 0, 1 and -1. Trial division by the
// small primes, then Pollard's rho (Brent's variant) on what is left, with
// is_prime deciding each part: fast for any int whose second-largest
// prime factor is below about 10^12.
pub fn factorize(n: int) -> [Factor] {
    let out: [Factor] = [];
    if n == 0 {
        return out;
    }
    let primes: [int] = [];
    let m = n;
    if m < 0 {
        if m == math.min_int { // -2^63: |n| is not an int
            for i in 0..63 {
                push(primes, 2);
            }
            m = 1;
        } else {
            m = -m;
        }
    }
    for p in [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47] {
        while m % p == 0 {
            push(primes, p);
            m = m / p;
        }
    }
    split_into(m, primes);
    let sorted = sorted_ints(primes);
    let i = 0;
    while i < len(sorted) {
        let j = i;
        while j < len(sorted) && sorted[j] == sorted[i] {
            j += 1;
        }
        push(out, Factor { p: sorted[i], k: j - i });
        i = j;
    }
    return out;
}

// Every positive divisor of |n|, ascending; empty for 0.
pub fn divisors(n: int) -> [int] {
    let ds: [int] = [];
    if n == 0 {
        return ds;
    }
    push(ds, 1);
    for f in factorize(n) {
        let count = len(ds);
        let pk = 1;
        for e in 0..f.k {
            pk = pk * f.p;
            for i in 0..count {
                push(ds, ds[i] * pk);
            }
        }
    }
    return sorted_ints(ds);
}

// Euler's totient: how many integers in [1, n] share no factor with n.
// 0 for n <= 0.
pub fn totient(n: int) -> int {
    if n <= 0 {
        return 0;
    }
    let r = n;
    for f in factorize(n) {
        r = r / f.p * (f.p - 1);
    }
    return r;
}

// The Chinese remainder theorem: the x in [0, lcm(moduli)) with
// x = residues[i] (mod moduli[i]) for every i. The moduli need not be
// coprime; none when the congruences contradict each other, a modulus is
// <= 0, the lists differ in length, or the lcm overflows an int.
pub fn crt(residues: [int], moduli: [int]) -> opt[int] {
    if len(residues) != len(moduli) {
        return none;
    }
    let x = 0;
    let m = 1;
    for i in 0..len(moduli) {
        let mi = moduli[i];
        if mi <= 0 {
            return none;
        }
        let ri = math.rem_euclid(residues[i], mi);
        let bz = ext_gcd(m, mi);
        let g = bz.g;
        if math.rem_euclid(ri - x, g) != 0 {
            return none;
        }
        guard let l = math.checked_mul(m / g, mi) else {
            return none;
        }
        // x += m * ((ri - x) / g * bz.x mod (mi / g))
        let step_mod = mi / g;
        let t = mod_mul(math.rem_euclid((ri - x) / g, step_mod), math.rem_euclid(bz.x, step_mod), step_mod);
        x = math.rem_euclid(x + (math.mul_mod(m, t, l) ?? 0), l);
        m = l;
    }
    return some(x);
}

// n choose k modulo a prime p (Lucas's theorem), for n and k too large to
// compute the coefficient itself; 0 for k outside [0, n]. p must be prime
// (it is not checked: a composite p gives a wrong answer, not an error).
pub fn binomial_mod(n: int, k: int, p: int) -> int {
    if k < 0 || k > n || p <= 1 {
        return 0;
    }
    let r = 1;
    let a = n;
    let b = k;
    while b > 0 {
        let ai = a % p;
        let bi = b % p;
        if bi > ai {
            return 0;
        }
        r = mod_mul(r, small_binomial_mod(ai, bi, p), p);
        a = a / p;
        b = b / p;
    }
    return r;
}

// The n-th Fibonacci number (F(0) = 0, F(1) = 1) by fast doubling; none
// for n < 0 or past F(92), the last that fits an int.
pub fn fibonacci(n: int) -> opt[int] {
    if n < 0 || n > 92 {
        return none;
    }
    let a = 0; // F(i)
    let b = 1; // F(i + 1)
    let bit = 62;
    while bit >= 0 {
        // F(2i) = F(i) (2 F(i+1) - F(i)); F(2i+1) = F(i)^2 + F(i+1)^2
        let c = a * (2 * b - a);
        let d = a * a + b * b;
        if ((n >> bit) & 1) == 1 {
            a = d;
            b = c + d;
        } else {
            a = c;
            b = d;
        }
        bit -= 1;
    }
    return some(a);
}

// ---- helpers ----

// One Miller-Rabin round: whether n passes as a strong probable prime to
// base a, with n - 1 = d * 2^s, d odd.
fn strong_probable_prime(n: int, a: int, d: int, s: int) -> bool {
    let b = a % n;
    if b == 0 {
        return true; // a is a multiple of n: says nothing
    }
    let x = mod_pow(b, d, n);
    if x == 1 || x == n - 1 {
        return true;
    }
    for r in 1..s {
        x = mod_mul(x, x, n);
        if x == n - 1 {
            return true;
        }
        if x == 1 {
            return false;
        }
    }
    return false;
}

// Appends the prime factors of m (> 0, no factor below 53) to out.
fn split_into(m: int, out: [int]) {
    if m == 1 {
        return;
    }
    if is_prime(m) {
        push(out, m);
        return;
    }
    let s = isqrt_exact(m);
    if s > 0 {
        split_into(s, out);
        split_into(s, out);
        return;
    }
    let d = rho(m);
    split_into(d, out);
    split_into(m / d, out);
}

// s if m == s * s, else 0. Rho is slow on a perfect square of a prime.
fn isqrt_exact(m: int) -> int {
    let s = math.isqrt(m);
    if s * s == m {
        return s;
    }
    return 0;
}

// A nontrivial factor of the composite m: Pollard's rho, Brent's cycle
// detection, with products batched before each gcd. Retries with another
// constant when one walk closes without finding a factor.
fn rho(m: int) -> int {
    let c = 1;
    while true {
        let y = 2;
        let r = 1;
        let q = 1;
        let g = 1;
        let x = 2;
        let ys = 2;
        while g == 1 {
            x = y;
            for i in 0..r {
                y = rho_step(y, c, m);
            }
            let k = 0;
            while k < r && g == 1 {
                ys = y;
                let batch = math.min(128, r - k);
                for i in 0..batch {
                    y = rho_step(y, c, m);
                    q = mod_mul(q, math.abs_diff(x, y) as int, m);
                }
                g = math.gcd(q, m);
                k += 128;
            }
            r *= 2;
        }
        if g == m {
            // the batch overshot: step one at a time from its start
            g = 1;
            while g == 1 {
                ys = rho_step(ys, c, m);
                g = math.gcd(math.abs_diff(x, ys) as int, m);
            }
        }
        if g != m {
            return g;
        }
        c += 1;
    }
    return m;
}

fn rho_step(y: int, c: int, m: int) -> int {
    return math.rem_euclid((math.mul_mod(y, y, m) ?? 0) + c, m);
}

// n choose k mod p for 0 <= k <= n < p, through modular inverses
fn small_binomial_mod(n: int, k: int, p: int) -> int {
    let num = 1;
    let den = 1;
    let kk = math.min(k, n - k);
    for i in 0..kk {
        num = mod_mul(num, n - i, p);
        den = mod_mul(den, i + 1, p);
    }
    return mod_mul(num, mod_inv(den, p) ?? 0, p);
}

// ints sorted ascending (heapsort)
fn sorted_ints(xs: [int]) -> [int] {
    let s: [int] = [];
    for x in xs {
        push(s, x);
    }
    let n = len(s);
    let start = n / 2 - 1;
    while start >= 0 {
        sift(s, start, n);
        start -= 1;
    }
    let end = n - 1;
    while end > 0 {
        let t = s[0];
        s[0] = s[end];
        s[end] = t;
        sift(s, 0, end);
        end -= 1;
    }
    return s;
}

fn sift(s: [int], root: int, n: int) {
    let r = root;
    while true {
        let child = 2 * r + 1;
        if child >= n {
            return;
        }
        if child + 1 < n && s[child] < s[child + 1] {
            child += 1;
        }
        if s[r] >= s[child] {
            return;
        }
        let t = s[r];
        s[r] = s[child];
        s[child] = t;
        r = child;
    }
}
