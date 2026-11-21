# math/vec

> Package math/vec.

Bulk arithmetic on `[float]` and `[f32]` vectors, for embedding search,
recommendations and scoring. Native: each kernel runs eight to
thirty-two accumulators over raw memory, with 256-bit fused
multiply-adds on x86-64 CPUs that have AVX2 and FMA (chosen at run
time), which a slang loop cannot do.

```slang
import "math/vec";

let a = [0.1, 0.7, 0.2];
let b = [0.3, 0.5, 0.2];
vec.dot(a, b);                       // 0.42
vec.cosine(a, b);                    // in [-1, 1]
vec.distance(a, b);                  // Euclidean
vec.normalize(a);                    // in place; returns the old norm

// search: rows is n vectors of `dim` numbers, one after another
let best = vec.top_k_cosine(query, rows, 384, 10);   // [int], best first

let small = vec.to_f32(a);           // half the memory
let q8 = vec.quantize(small);        // bytes: a quarter of an [f32]
vec.dot_q(q8, vec.quantize(vec.to_f32(b)));
```

- **Reductions:** `dot`, `sum`, `norm`, `distance`, `distance2`
  (squared), `cosine` (NaN for a zero vector), `argmax`, `argmin`
  (NaN skipped; -1 for an empty list).
- **In place:** `scale(a, s)`, `axpy(alpha, x, y)` (`y += alpha * x`),
  `add(y, x)`, `sub(y, x)`, `mul(y, x)` (elementwise), `normalize(a)`.
- **Search:** `top_k(a, k)` (indexes of the k largest, best first, ties
  to the lower index), `scores(query, rows, dim)` (every row's dot
  product), `top_k_dot` and `top_k_cosine(query, rows, dim, k)`: a
  k-entry heap, no copy of the scores, one pass over each row.
- **Storage:** `to_f32`, `to_f64`, `quantize` (symmetric int8: a
  4-byte scale, then a byte per element), `dequantize`, `dot_q` (an
  exact integer sum, times both scales).

The vectors of one call must have the same element type (a compile
error otherwise, naming `to_f32`/`to_f64`) and the same length (a
panic naming the call otherwise). Nothing allocates except the
functions that return a new list or bytes. On a 1536-float dot product
`vec.dot` takes 112 ns for `[f32]` and 195 ns for `[float]`, against
1600 ns for the same loop written in slang. Sums are taken in a
different order from a left-to-right loop, and on x86-64 in a different
order with and without AVX2, so results can differ in their last bits
between machines.

## API

### `math/vec.dot([float]|[f32], [float]|[f32]) -> float`

### `math/vec.sum([float]|[f32]) -> float`

### `math/vec.norm([float]|[f32]) -> float`

### `math/vec.distance([float]|[f32], [float]|[f32]) -> float`

### `math/vec.distance2([float]|[f32], [float]|[f32]) -> float`

### `math/vec.cosine([float]|[f32], [float]|[f32]) -> float`

### `math/vec.argmax([float]|[f32]) -> int`

### `math/vec.argmin([float]|[f32]) -> int`

### `math/vec.scale([float]|[f32], float)`

### `math/vec.axpy(float, [float]|[f32], [float]|[f32])`

### `math/vec.add([float]|[f32], [float]|[f32])`

### `math/vec.sub([float]|[f32], [float]|[f32])`

### `math/vec.mul([float]|[f32], [float]|[f32])`

### `math/vec.normalize([float]|[f32]) -> float`

### `math/vec.top_k([float]|[f32], int) -> [int]`

### `math/vec.scores([float]|[f32], [float]|[f32], int) -> [float]`

### `math/vec.top_k_dot([float]|[f32], [float]|[f32], int, int) -> [int]`

### `math/vec.top_k_cosine([float]|[f32], [float]|[f32], int, int) -> [int]`

### `math/vec.to_f32([float]|[f32]) -> [f32]`

### `math/vec.to_f64([float]|[f32]) -> [float]`

### `math/vec.quantize([float]|[f32]) -> bytes`

### `math/vec.dequantize(bytes) -> [float]`

### `math/vec.dot_q(bytes, bytes) -> float`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
