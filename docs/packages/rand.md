# rand

> Package rand.

Seeded, non-cryptographic random numbers for tests, simulations, sampling
and retry jitter. One seed fixes the whole sequence on every platform, so
a test that draws random inputs fails the same way on CI and on a laptop.

```slang
import "rand";

let r = rand.new(42);                  // same seed, same sequence
rand.below(r, 10);                     // int in [0, 10)
rand.between(r, 1, 6);                 // int in [1, 6], ends included
rand.unit(r);                          // float in [0, 1)
rand.chance(r, 0.25);                  // true about one time in four
rand.shuffle(r, xs);                   // reorders xs in place
rand.pick(r, xs) ?? fallback;          // none when xs is empty

// retry number `attempt` (0 first): uniform in [0, min(cap, base * 2^attempt)]
time.sleep(rand.backoff(r, attempt, 100000000, 30000000000));
rand.jitter(r, 60000000000, 0.1);      // 60s, give or take 10%
```

The generator is `xoshiro256**`, seeded through `splitmix64`. The tests pin
its exact outputs against the authors' C code, so a seed means the same
sequence in every slang release. Draws are unbiased: `below` and `between`
redraw rather than take a plain modulo, and `between` covers the full
`int` range. `below(r, 0)` and `between(r, 5, 1)` panic, like an index out
of range, since there is no value to return. `backoff` uses full jitter,
which spreads clients that failed together across the whole interval, and
saturates at `cap` rather than overflowing. An `Rng` is not locked: give
each spawned task its own with `rand.fork(r)`, which stays reproducible
from the parent's seed. `rand.from_os()` seeds from the OS when runs
should differ. Neither is for secrets: tokens, keys and salts come from
`crypto.rand`, because this generator's outputs reveal its state.

## API

### `gc struct Rng`

A random number generator. Make one with `new` or `from_os`.

### `fn new(seed: int) -> Rng`

A generator whose sequence is fixed by `seed`. Every int is a good seed, 0 and -1 included: splitmix64 spreads it over all 256 bits of state.

### `fn from_os() -> result[Rng, str]`

A generator seeded from the operating system's CSPRNG, for when runs should differ (load generators, sampling in production). Its outputs are still predictable from earlier ones: this is not a source of secrets.

### `fn fork(r: Rng) -> Rng`

A new generator seeded from `r`, for handing to a spawned task. Seeded parents give seeded children, so a whole run still replays from one seed. `r` advances by one step.

### `fn next_u64(r: Rng) -> u64`

The next 64 random bits.

### `fn below(r: Rng, n: int) -> int`

An int in [0, n), each value equally likely. Panics if n is not positive: there is no int to return, as with an index out of range.

### `fn between(r: Rng, lo: int, hi: int) -> int`

An int in [lo, hi], both ends included, each value equally likely. Panics if lo > hi. The full range, between(r, MIN, MAX), works.

### `fn unit(r: Rng) -> float`

A float in the unit interval [0, 1): one of 2^53 evenly spaced values, so every float it returns is exact and 1.0 never appears.

### `fn chance(r: Rng, p: float) -> bool`

True with probability `p`. p at or below 0 (or NaN) is never, p at or above 1 is always.

### `fn shuffle[T](r: Rng, xs: [T])`

Reorders `xs` in place, every order equally likely (Fisher-Yates).

### `fn pick[T](r: Rng, xs: [T]) -> opt[T]`

One element of `xs`, each equally likely; none if `xs` is empty.

### `fn backoff(r: Rng, attempt: int, base: int, cap: int) -> int`

How long to wait before retry number `attempt` (0 for the first retry): a uniform draw from [0, min(cap, base * 2^attempt)], the "full jitter" strategy. Spreading over the whole interval, not just its top, is what stops a crowd of clients that failed together from retrying together. Units are whatever `base` and `cap` use, nanoseconds for a duration. A negative attempt counts as 0; a base or cap at or below 0 gives 0.

### `fn jitter(r: Rng, d: int, frac: float) -> int`

`d` scaled by a uniform factor in [1 - frac, 1 + frac]: jitter(r, d, 0.1) lands within 10% of d. frac is clamped to [0, 1] (NaN counts as 0), so the result is never negative. A d at or below 0 gives 0.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
