# bench/sort — sort vs Go's sort

One scene matrix, two programs, byte-identical inputs.

- `main.sl` — the slang package (`sort.ints/floats/strings/by/by_stable`)
- `go/main.go` — the same scenes on Go's standard library (`sort.Ints`,
  `sort.Float64s`, `sort.Strings`, `sort.Slice`, `sort.SliceStable`)
- `run.sh` — builds both, runs ABBA (slang, go, go, slang) per round,
  prints per-scene medians and each binary's peak RSS

## Method

Every scene builds its inputs once, then times 5 sorts over a fresh
copy each round and prints the median milliseconds; the sorted result
is verified outside the timed section, so a broken sort cannot look
like a fast one. The shell keeps the raw logs in `.build/runs/` and
aggregates medians over ABBA rounds twice that deep.

Inputs are generated at index — element `i` reads `mix(seed + 3*i + k)`
— where `mix` is a two-step Lehmer walk (multiplier 48271, mod 2^31-1)
followed by a **square-and-mod step**: `(t*t) % 2147483647`, which
cannot overflow int64. The square is not a detail: a purely
multiplicative chain mod a prime stays linear in the index, and its
values mod small numbers repeat with short periods — the first cut of
this benchmark had `lcf(x) % 4` cycling with period ~20, which made
the duplicate-heavy scenes measure an unreal input and Go look inhuman
on them. With the square in place: no period up to 64, and bucket
occupancy within 0.4% of uniform across mod 4, 6, 26 and 1000003
(language-independent property, checkable against either program).

## Results

macOS (arm64, Apple clang -O3 -flto, Go 1.22), Oct 2026. Two
consecutive ABBA sets on this host agreed within ~10% per scene.

```
scene                       slang ms     go ms  slang/go
by_int_250k                   247.81     62.07      3.99
by_int_sorted_250k              2.96      0.89      3.31
by_stable_100k                130.76     68.20      1.92
by_str_100k                    14.27      5.90      2.42
floats_random_1m              393.42    114.38      3.44
ints_desc_1m                    8.25      1.71      4.81
ints_equal_1m                  28.10      9.35      3.00
ints_random_100k               32.09      7.51      4.27
ints_random_1k                  0.18      0.04      4.26
ints_random_1m                384.98     90.19      4.27
ints_sorted_1m                  3.09      1.16      2.65
strings_random_100k           111.91     25.95      4.31

peak RSS (slang): 84238336
peak RSS (go):    46993408
```

## What the table says

The package holds its shape: sorted and descending one-million-int
lists answer in 3 ms and 8 ms on the adaptive pass, duplicate-heavy
one-million-int (four values) sorts in 28 ms because the three-way
partition settles each value class in one pass, and the stable sort
lands within 2x of Go's `SliceStable`, which is the closest ratio in
the table.

The standing gap on the wide-random scenes (roughly 3-4x) divides into
two causes, neither of which is the partition code:

1. **Engine machinery.** Go's pdqsort runs a one-comparison-per-element
   Hoare partition on wide data and adds ninther pivots, adversary
   breaking, and partial-insertion-sort repair; this package's
   three-way partition pays a second comparison per element on
   wide-ranged data (measured: Hoare 260 ms vs three-way 324 ms on one
   million random ints — cheap insurance, since Hoare doubles on
   duplicate data: 264 ms -> 25 ms with the three-way or the 32x gap
   stands). The next iteration on the sort engine is a
   Bentley-McIlroy-style fat partition: one comparison per element on
   wide data AND parked equal zones.
2. **Per-comparison runtime cost.** slang's comparisons in generated C
   pay bounds-checked element reads, a GC safepoint poll per loop
   iteration, and safe expression staging; that overhead is on every
   comparison and every list access in every slang program, and at
   one million elements it is the difference between 4.3x and parity.
   Improving THAT is compiler work (the poll density in scan loops,
   bounds-check lifting on monotone index variables), not package
   work, and it will pay off across the whole stdlib.

Peak RSS reads 1.4-1.8x Go's across the run (84 MB vs 47 MB on the
worst scene): the benchmark holds a source list plus a per-round copy
of the largest list at once (8 MB + 8 MB for one million ints), and
slang's generational GC keeps a larger working buffer before shrink.
`/usr/bin/time -l` reports KB on Linux and bytes on macOS; the numbers
above are bytes.
