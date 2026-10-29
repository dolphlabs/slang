# math/numtheory

> Package math/numtheory.

Modular arithmetic, primes and factorization on `int`, over
`math.mul_mod` so a modulus near 2^62 is as safe as a small one.

```slang
import "math/numtheory";

numtheory.mod_pow(2, 100, 1000000007);       // 976371285
numtheory.mod_inv(3, 7) ?? 0;                // 5
numtheory.is_prime(9223372036854775783);     // true: exact for every int
numtheory.factorize(360);                    // [{p: 2, k: 3}, {p: 3, k: 2}, {p: 5, k: 1}]
numtheory.primes_below(30);                  // [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
numtheory.crt([2, 3, 2], [3, 5, 7]) ?? -1;   // 23
```

`mod_pow`, `mod_mul`, `mod_inv`, `ext_gcd` (a `Bezout { g, x, y }`),
`is_prime` (deterministic Miller-Rabin with the seven bases proven for
64 bits), `next_prime`, `prev_prime`, `primes_below` (a sieve over the
odd numbers), `factorize` (trial division, then Pollard's rho with
Brent's cycle detection), `divisors`, `totient`, `crt` (moduli need not
be coprime), `binomial_mod` (Lucas, for a prime modulus) and
`fibonacci` (exact through F(92)). A modulus must be positive: a
function given one <= 0 returns `none`, 0 or `false` rather than
panicking, and no result is negative.

## API

### `fn mod_pow(b: int, e: int, m: int) -> int`

b^e mod m, by squaring: O(log e). 0 when m <= 0 or e < 0 (a negative power needs mod_inv first); 1 mod m for e = 0.

### `fn mod_mul(a: int, b: int, m: int) -> int`

(a * b) mod m, in [0, m), without overflow; 0 when m <= 0.

### `struct Bezout`

### `fn ext_gcd(a: int, b: int) -> Bezout`

The extended Euclidean algorithm: g = gcd(a, b) and x, y with a * x + b * y = g.

### `fn mod_inv(a: int, m: int) -> opt[int]`

The x in [0, m) with a * x = 1 (mod m); none when a and m share a factor (no inverse exists) or m <= 0.

### `fn is_prime(n: int) -> bool`

Whether n is prime: exact for every int (deterministic Miller-Rabin with the seven bases Jim Sinclair found to cover all of 64 bits), after trial division by the small primes. false for n < 2.

### `fn next_prime(n: int) -> opt[int]`

The smallest prime >= n (2 for n <= 2); none past the largest int prime.

### `fn prev_prime(n: int) -> opt[int]`

The largest prime <= n; none for n < 2.

### `fn primes_below(n: int) -> [int]`

Every prime below n, ascending: the sieve of Eratosthenes over the odd numbers, n / 2 bytes of memory. Empty for n <= 2.

### `struct Factor`

### `fn factorize(n: int) -> [Factor]`

The prime factorization of |n|, ascending by prime: 360 is [{2, 3}, {3, 2}, {5, 1}]. Empty for 0, 1 and -1. Trial division by the small primes, then Pollard's rho (Brent's variant) on what is left, with is_prime deciding each part: fast for any int whose second-largest prime factor is below about 10^12.

### `fn divisors(n: int) -> [int]`

Every positive divisor of |n|, ascending; empty for 0.

### `fn totient(n: int) -> int`

Euler's totient: how many integers in [1, n] share no factor with n. 0 for n <= 0.

### `fn crt(residues: [int], moduli: [int]) -> opt[int]`

The Chinese remainder theorem: the x in [0, lcm(moduli)) with x = residues[i] (mod moduli[i]) for every i. The moduli need not be coprime; none when the congruences contradict each other, a modulus is <= 0, the lists differ in length, or the lcm overflows an int.

### `fn binomial_mod(n: int, k: int, p: int) -> int`

n choose k modulo a prime p (Lucas's theorem), for n and k too large to compute the coefficient itself; 0 for k outside [0, n]. p must be prime (it is not checked: a composite p gives a wrong answer, not an error).

### `fn fibonacci(n: int) -> opt[int]`

The n-th Fibonacci number (F(0) = 0, F(1) = 1) by fast doubling; none for n < 0 or past F(92), the last that fits an int.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
