# math/big

> Package math/big.

Arbitrary-precision integers and exact fractions: cryptography, ids and
amounts past 64 bits, exact combinatorics, checking int arithmetic
against the truth. Written in slang.

```slang
import "math/big";

let a = big.parse("123456789012345678901234567890", 10) ?? big.zero();
a.mul(big.from_int(987654321)).format(10);   // 121932631124828532112482853211126352690
big.from_int(2).pow(127).sub(big.one());     // a Mersenne prime
a.mod_pow(e, m) ?? big.zero();               // none for m <= 0
a.mod_inv(m);                                // opt
big.from_bytes_be(key_bytes);

let r = big.rat_parse("0.125") ?? big.rat_zero();   // 1/8: exact, not a float
r.add(big.rat_parse("1/3") ?? big.rat_zero()).format();   // 11/24
```

- **`Int`:** `add`, `sub`, `mul`, `div`/`rem` (truncating, as `/` and
  `%`), `div_floor`/`modulo` (flooring; `modulo` is never negative),
  `pow`, `mod_pow`, `mod_inv`, `gcd`, `sqrt` (integer), `cmp`, `eq`,
  `sign`; `shl`, `shr` (arithmetic), `and`, `or`, `xor`, `not` and
  `bit` on the two's-complement form, as Go and Python define them;
  `parse(s, base)` (2 to 36, `_` separators, `0x`/`0o`/`0b`),
  `format(base)`, `int_of` (opt), `float_of`, `bytes_be`,
  `from_bytes_be`.
- **`Rat`:** always reduced with a positive denominator. `rat`,
  `rat_parse` ("3/4", "-12.75", "2.5e-3", exact), `add`, `sub`, `mul`,
  `div`, `cmp`, `floor`, `ceil`, `round` (half to even), `float_of`,
  `format`, `format_decimal(places)`.

An `Int` is immutable and can be shared between tasks. Limbs are 32
bits, so every partial product fits a `u64`; multiplication is
schoolbook below 256 limbs (8192 bits, where it measured as fast) and
Karatsuba above, division is Knuth's algorithm D, and `mod_pow` with an
odd modulus uses Montgomery multiplication with a 4-bit window, so no
step divides. A 2048-bit product takes about 9 us and a 2048-bit
modular power with a 1024-bit exponent about 26 ms; this is a portable
library, not a constant-time one, so keep secret-key cryptography in
`crypto`. `parse` refuses text over 100,000 characters and `pow` a
result over 16 million bits, to bound the work an input can ask for.
The tests check every operation against Python's integers on 300
random pairs up to 5000 bits, and modular powers on 100 moduli.

## API

### `gc struct Int`

### `fn zero() -> Int`

### `fn one() -> Int`

### `fn from_int(n: int) -> Int`

### `fn from_u64(n: u64) -> Int`

### `fn parse(s: str, base: int) -> result[Int, str]`

An Int from text in `base` (2 to 36): an optional sign, then digits (either case for letters), with `_` allowed between digits. For base 16, 8 and 2 a 0x, 0o or 0b prefix is accepted too. Text longer than 100,000 characters is refused, to bound the work an input can ask for.

### `fn from_bytes_be(b: bytes) -> Int`

From big-endian unsigned bytes (as a key or a hash is written).

### `fn sign(self: Int) -> int`

### `fn is_zero(self: Int) -> bool`

### `fn cmp(self: Int, other: Int) -> int`

-1, 0 or 1 as self is below, equal to or above other.

### `fn eq(self: Int, other: Int) -> bool`

### `fn neg(self: Int) -> Int`

### `fn abs(self: Int) -> Int`

### `fn add(self: Int, other: Int) -> Int`

### `fn sub(self: Int, other: Int) -> Int`

### `fn mul(self: Int, other: Int) -> Int`

### `fn div(self: Int, d: Int) -> opt[Int]`

The quotient truncated toward zero; none for a zero divisor.

### `fn rem(self: Int, d: Int) -> opt[Int]`

The remainder of div: it has self's sign. none for a zero divisor.

### `fn div_floor(self: Int, d: Int) -> opt[Int]`

The quotient rounded toward negative infinity.

### `fn modulo(self: Int, m: Int) -> opt[Int]`

self mod m in [0, |m|): never negative. none for a zero modulus.

### `fn pow(self: Int, e: int) -> Int`

self^e for e >= 0 (square-and-multiply). Panics for a negative e, and for a result above 2^16,000,000 bits, which no program means.

### `fn mod_pow(self: Int, e: Int, m: Int) -> opt[Int]`

self^e mod m for e >= 0 and m > 0; none otherwise. An odd modulus (RSA, Diffie-Hellman, most primes) runs Montgomery multiplication with a 4-bit window, no division per step; an even one squares and multiplies with a reduction after each.

### `fn gcd(self: Int, other: Int) -> Int`

The greatest common divisor (never negative; gcd(0, 0) is 0).

### `fn mod_inv(self: Int, m: Int) -> opt[Int]`

The inverse of self mod m (x with self * x = 1 mod m), in [0, m); none when it does not exist (m <= 0, or self and m share a factor).

### `fn sqrt(self: Int) -> opt[Int]`

The integer square root: the largest r with r * r <= self (Newton from above). none for a negative self.

### `fn shl(self: Int, n: int) -> Int`

self * 2^n (n >= 0).

### `fn shr(self: Int, n: int) -> Int`

self / 2^n rounded toward negative infinity (an arithmetic shift).

### `fn bit_len(self: Int) -> int`

The number of bits in |self| (0 for zero).

### `fn bit(self: Int, i: int) -> bool`

Bit i of the two's-complement form.

### `fn and(self: Int, other: Int) -> Int`

### `fn or(self: Int, other: Int) -> Int`

### `fn xor(self: Int, other: Int) -> Int`

### `fn not(self: Int) -> Int`

~self = -self - 1.

### `fn int_of(self: Int) -> opt[int]`

self as an int, none when it does not fit.

### `fn float_of(self: Int) -> float`

The nearest float (rounding the top 64 bits; huge values give infinity).

### `fn format(self: Int, base: int) -> str`

The digits in `base` (2 to 36, lowercase letters), with a leading '-' when negative.

### `fn bytes_be(self: Int) -> bytes`

|self| as big-endian bytes, no leading zero byte (empty for 0).

### `gc struct Rat`

### `fn rat_zero() -> Rat`

### `fn rat(n: Int, d: Int) -> opt[Rat]`

n / d, reduced; none for a zero denominator.

### `fn rat_from_int(n: int) -> Rat`

### `fn rat_parse(s: str) -> result[Rat, str]`

A fraction from "3/4", "-7", "0.125" or "-2.5e-3" (exact: 0.1 is 1/10, not the float nearest it). Exponents are limited to +-10000.

### `fn numerator(self: Rat) -> Int`

### `fn denominator(self: Rat) -> Int`

Always positive.

### `fn add(self: Rat, o: Rat) -> Rat`

### `fn sub(self: Rat, o: Rat) -> Rat`

### `fn mul(self: Rat, o: Rat) -> Rat`

### `fn div(self: Rat, o: Rat) -> opt[Rat]`

none when dividing by zero.

### `fn neg(self: Rat) -> Rat`

### `fn cmp(self: Rat, o: Rat) -> int`

### `fn eq(self: Rat, o: Rat) -> bool`

### `fn sign(self: Rat) -> int`

### `fn is_int(self: Rat) -> bool`

### `fn floor(self: Rat) -> Int`

The largest Int at or below the fraction.

### `fn ceil(self: Rat) -> Int`

The smallest Int at or above it.

### `fn round(self: Rat) -> Int`

The nearest Int, halves to even.

### `fn float_of(self: Rat) -> float`

The nearest float (num and den each rounded once: within a few ulps; exact for fractions whose parts fit 53 bits).

### `fn format(self: Rat) -> str`

"n/d", or "n" for a whole number.

### `fn format_decimal(self: Rat, places: int) -> str`

The decimal expansion to `places` digits after the point, rounded half to even.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
