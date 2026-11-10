# decimal

> Package decimal.

Exact decimal arithmetic for money: up to 38 significant digits (SQL's
`DECIMAL(38)`), an explicit scale, seven rounding modes, and overflow as
`none` or an error, never a wrap.

```slang
import "decimal";

let r = decimal.parse("19.99");                // result[Decimal, str]
guard let price = r else let e = err_of(r) { panic(e); }
let total = decimal.mul(price, decimal.from_int(3)) ?? decimal.zero();   // 59.97
let rate = decimal.parse("0.075") ?? decimal.zero();
let vat = decimal.mul_round(total, rate, 2, decimal.Rounding.HalfEven)
          ?? decimal.zero();                    // 4.50
decimal.format(vat);                            // "4.50"
decimal.div(total, decimal.from_int(7), 2, decimal.Rounding.HalfEven);  // ok(8.57)
decimal.split(total, 2);                        // [29.99, 29.98]: no cent lost
decimal.allocate(total, [1, 2]);                // ok([19.99, 39.98])
decimal.to_units(total, 2, decimal.Rounding.HalfEven) ?? 0;   // 5997
decimal.eq(decimal.parse("1.5") ?? total, decimal.parse("1.50") ?? total);  // true
```

A `Decimal` is a coefficient and a scale (digits after the point, 0 to
38), kept as Postgres's `numeric` keeps it: `"1.50"` stays 1.50, `add`
keeps the larger scale, `mul` adds the two. It is a value (five base-10^9
limbs), so arithmetic allocates nothing; only `format`, `split` and
`allocate` build something on the heap.

- **Exact unless you ask.** `add`, `sub` and `mul` are exact and return
  `none` when the result needs more than 38 digits (or `mul`, a scale past
  38: use `mul_round`). `mul_round`, `div` and `round` round to the scale
  you give, by the `Rounding` you give: `HalfEven` (banker's, the usual
  choice for money), `HalfUp`, `HalfDown`, `Down` and `Up` (toward and
  away from zero), `Floor`, `Ceiling`. `div` is an error for a zero
  divisor.
- **Parsing is strict**, like `to_int`: an optional sign, digits, an
  optional fraction and exponent (`"1.5e3"`). No spaces, separators,
  leading or trailing point, NaN or infinity. `parse_bytes(b, lo, hi)`
  reads a number inside a buffer without making a str. `from_float`
  goes through the float's shortest text, so `0.1` is 0.1, not
  0.1000000000000000055511151231257827.
- **Comparing:** `cmp`, `eq`, `lt`, `le`, `gt`, `ge`, `min`, `max` compare
  values, so 1.5 equals 1.50. Structs have no `==`. Use `normalize` (strip
  trailing zeros) before a Decimal becomes a map key.
- **Splitting money:** `split(d, n)` and `allocate(d, weights)` divide an
  amount at its own scale so the parts add up to it exactly. The
  leftover smallest units go to the parts with the largest remainders,
  earlier ones first.
- **JSON and Postgres.** A `decimal.Decimal` field is written by
  `json.encode` as a string holding its exact text (`"19.90"`), which is
  safe for JavaScript clients, whose numbers lose digits past 2^53.
  `json.decode` reads one from a string or a number, exactly, without a
  float in between. `pg.arg_decimal(d)` binds one for a `numeric`
  parameter, and `pg.get_decimal(rows, r, c)` reads a `numeric` or
  integer column at the scale Postgres reports. NaN and infinity are
  errors.

## API

### `let MAX_DIGITS = 38;`

The most significant digits a Decimal holds, and the largest scale.

### `let MAX_SCALE = 38;`

### `struct Decimal`

A decimal number. Its fields are the representation, not an API: make one with parse, from_int, from_units or from_float.

### `fn zero() -> Decimal`

0, at scale 0.

### `fn from_int(n: int) -> Decimal`

n, at scale 0. Every int fits.

### `fn from_units(units: int, scale: int) -> opt[Decimal]`

units * 10^-scale: from_units(1999, 2) is 19.99. none if scale is outside 0 to 38.

### `fn parse(s: str) -> result[Decimal, str]`

The decimal written in s: an optional sign, digits, an optional fraction after a point, and an optional exponent ("1.5e3", "2E-4"). Strict, like to_int: no spaces, no thousands separators, no leading or trailing point, no NaN or infinity. The scale is the number of fraction digits less the exponent ("1.50" has scale 2, "1.5e3" scale 0); trailing zeros past scale 38 are dropped when they are exact.

### `fn parse_bytes(b: bytes, lo: int, hi: int) -> result[Decimal, str]`

parse over b[lo..hi], with no str made: for a number inside a request body or a wire buffer.

### `fn from_float(f: float, scale: int, mode: Rounding) -> opt[Decimal]`

The decimal nearest to f, rounded to `scale` digits by `mode`; none for NaN, an infinity, a scale outside 0 to 38, or a value past 38 digits. f is read through its shortest round-trip text, so 0.1 gives exactly 0.1, not the binary fraction nearest it.

### `fn scale_of(d: Decimal) -> int`

The digits after the point.

### `fn precision(d: Decimal) -> int`

How many significant digits the coefficient has (0 has 1).

### `fn is_zero(d: Decimal) -> bool`

### `fn is_neg(d: Decimal) -> bool`

### `fn sign(d: Decimal) -> int`

-1, 0 or 1.

### `fn format(d: Decimal) -> str`

Plain notation, every digit of the scale kept: "-19.90", "0.005", "42".

### `fn to_units(d: Decimal, scale: int, mode: Rounding) -> opt[int]`

d in units of 10^-scale, rounded by mode: to_units(19.999, 2, HalfUp) is 2000. none if scale is outside 0 to 38 or the units do not fit an int.

### `fn int_of(d: Decimal, mode: Rounding) -> opt[int]`

d rounded to a whole number by mode, as an int; none past an int.

### `fn float_of(d: Decimal) -> float`

The float nearest to d. Floats cannot hold most decimals exactly: use this for display or statistics, never to compute money.

### `fn cmp(a: Decimal, b: Decimal) -> int`

-1, 0 or 1 as a is less than, equal to or greater than b, by value: cmp(1.5, 1.50) is 0.

### `fn eq(a: Decimal, b: Decimal) -> bool`

a and b are the same number, whatever their scales.

### `fn lt(a: Decimal, b: Decimal) -> bool`

### `fn le(a: Decimal, b: Decimal) -> bool`

### `fn gt(a: Decimal, b: Decimal) -> bool`

### `fn ge(a: Decimal, b: Decimal) -> bool`

### `fn min(a: Decimal, b: Decimal) -> Decimal`

### `fn max(a: Decimal, b: Decimal) -> Decimal`

### `fn neg(d: Decimal) -> Decimal`

### `fn abs(d: Decimal) -> Decimal`

### `fn add(a: Decimal, b: Decimal) -> opt[Decimal]`

a + b, exactly, at the larger of the two scales; none past 38 digits.

### `fn sub(a: Decimal, b: Decimal) -> opt[Decimal]`

a - b, exactly, at the larger of the two scales; none past 38 digits.

### `fn mul(a: Decimal, b: Decimal) -> opt[Decimal]`

a * b, exactly, at the sum of the scales; none if the product needs more than 38 digits or a scale past 38 (use mul_round for those).

### `fn mul_round(a: Decimal, b: Decimal, scale: int, mode: Rounding) -> opt[Decimal]`

a * b rounded to `scale` digits by mode; none if scale is outside 0 to 38 or the rounded product needs more than 38 digits.

### `fn div(a: Decimal, b: Decimal, scale: int, mode: Rounding) -> result[Decimal, str]`

a / b rounded to `scale` digits by mode. An error for division by zero, a scale outside 0 to 38, or a quotient past 38 digits.

### `fn round(d: Decimal, scale: int, mode: Rounding) -> opt[Decimal]`

d with exactly `scale` digits after the point: rounded by mode when that is fewer than it has, padded with zeros when more. none if scale is outside 0 to 38 or the result needs more than 38 digits.

### `fn normalize(d: Decimal) -> Decimal`

d with trailing fraction zeros removed: 1.500 becomes 1.5, 2.00 becomes 2. Use it before a Decimal becomes a map key.

### `fn split(d: Decimal, n: int) -> [Decimal]`

d in n parts at d's scale that add up to d exactly, as equal as they can be: the first ones take the leftover smallest units. split(100.00, 3) is [33.34, 33.33, 33.33]. Empty when n is not positive.

### `fn allocate(d: Decimal, weights: [int]) -> result[[Decimal], str]`

d divided in proportion to weights, at d's scale, adding up to d exactly: each part is rounded down and the leftover smallest units go to the parts with the largest remainders (earlier ones first on a tie). allocate(10.00, [1, 2]) is [3.33, 6.67]. An error for an empty list, a negative weight or weights summing to zero.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
