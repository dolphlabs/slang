# slang roadmap — data types for server-side & network programming

Track progress top to bottom; tick items off as they land.

## Tier 1 — foundations

- [x] `bytes` type: length-prefixed, binary-safe byte sequences
  - [x] Lexer/parser: `bytes` type keyword
  - [x] Literals: `b"..."` byte-string syntax (binary-safe, no NUL termination)
  - [x] Runtime: `sl_bytes` struct { len, ptr } allocated via GC
  - [x] Builtins: `len(b)`, indexing `b[i]`, slicing `b[a..b]`
  - [x] Concatenation `+`, equality `==`/`!=`, printing
  - [x] Conversions: str <-> bytes, int -> bytes (LE/BE helpers)

- [x] Fixed-width integers & float
  - [x] Lexer/parser: `i8 i16 i32 i64 u8 u16 u32 u64 f32` type keywords
  - [x] Codegen: C type mapping (`int8_t` .. `uint64_t`, `float`)
  - [x] Type checker: widening rules within the int family, explicit-only narrowing
  - [x] Overflow/wrap semantics documented (wrap on cast)
  - [x] print/println + string interpolation support for all widths

- [x] Arrays / lists `[T]`
  - [x] Parser: `[T]` type syntax, `[a, b, c]` literals
  - [x] Runtime: growable array struct over GC memory
  - [x] Builtins: `len()`, push/pop, indexing with bounds checks
  - [x] Iteration: `for x in list { ... }`
  - [x] Slicing and concatenation

## Tier 2 — server workhorses

- [x] Maps `map[K]V`
  - [x] Parser: `map[K]V` type syntax, `{k: v}` literals (annotated & inferred)
  - [x] Runtime: open-addressing hash table over GC memory (FNV-1a hashing,
        insertion-order iteration, automatic growth at 75% load)
  - [x] Operations: get/set/delete (`m[k]`, `m[k] = v`), `len()`,
        `has(m, k)`, `del(m, k)`; missing-key reads are runtime errors
  - [x] Iteration: `for k, v in m { ... }` in insertion order
  - [x] Key types restricted to integers, `str`, `bool`; values may be any
        type incl. structs and lists

- [x] Structs
  - [x] Parser: `struct Name { field: T, ... }` declarations (top level only)
  - [x] Construction: `Name { field: value, ... }` literals (all fields
        required, no extras, types checked)
  - [x] Field access `p.x`, nested chains `r.tl.y`, mutation `p.x = v`
  - [x] Methods via `impl Name { fn ... }` blocks with `self` receiver;
        methods may return structs (chained construction works)
  - [x] Integration with packages (`pub struct`, qualified access,
        exported-method visibility) and lists of structs (`[Point]`)

## Tier 3 — reliability & differentiators

- [ ] Option / Result types
  - [ ] `Option[T]` with `some(v)` / `none`
  - [ ] `Result[T, E]` with `ok(v)` / `err(e)`
  - [ ] Null-coalescing operator `??`
  - [ ] Pattern-friendly unwrapping (`guard let x = opt else { ... }`)

- [ ] Time types
  - [ ] `time.Duration` as first-class value
  - [ ] Monotonic clock + wall-clock timestamps
  - [ ] Timeout arithmetic for future net package

- [ ] `net` standard package
  - [ ] TCP listener / dialer built on bytes + fixed ints
  - [ ] Non-blocking I/O primitives
  - [ ] Example: minimal HTTP server in slang