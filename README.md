# slang

A small, statically-typed, garbage-collected programming language that
compiles to native binaries by transpiling to C. The compiler
(`slangc`) is written in C and uses your system C compiler as its
backend — no custom code generator, assembler, or linker required.
Memory is managed by the Boehm-Demers-Weiser conservative GC: slang
strings and allocations are traced and reclaimed automatically,
including cycles.

## Quick start

```sh
brew install libgc   # one-time dependency for compiled programs
make                 # build the slangc compiler
make test            # compile & run the example programs
```

Compile a slang program:

```sh
./slangc examples/hello/main.sl     # produces ./main
./main                              # run it
```

Useful flags:

| Flag        | Effect                                              |
|-------------|-----------------------------------------------------|
| `-o <name>` | Choose the output binary name                       |
| `--emit-c`  | Only write the generated C file (no compilation)    |
| `--keep-c`  | Keep the generated C file after compiling           |
| `--run`     | Compile, then immediately execute the result        |

## Language tour

```slang
// variables with inferred types
let x = 10;              // int  (64-bit)
let pi = 3.14;           // float (double)
let name = "World";      // str
let ok = true;           // bool

// arithmetic: + - * / %   (int/int is integer division)
println(x + y);
println(x / 2.0);        // mixing int and float promotes to float

// strings concatenate with + ; numbers/bools convert automatically
println("Hello, " + name + "! " + x);

// string interpolation with ${expr} (any expression allowed)
println("pi doubled is ${pi * 2}");

// comparisons: == != < <= > >=   logic: && || !
if x > y && ok {
    println("bigger");
} else if x == y {
    println("equal");
} else {
    println("smaller");
}

// loops
let i = 0;
while i < 5 {
    print(i);
    i = i + 1;
}

for j in 0..5 {        // exclusive range: 0,1,2,3,4
    print(j);
}
for k in 1..=3 {       // inclusive range: 1,2,3
    println("tick ${k}");
}

// functions (parameters and return types are annotated)
fn add(a: int, b: int) -> int {
    a + b          // implicit return: last expression is the value
}

fn abs(n: int) -> int {
    guard n >= 0 else {
        return -n; // guard: early exit when the condition fails
    }
    n
}

// void functions just omit the return type
fn shout(msg: str) {
    println(msg + "!!!");
}

// recursion works (functions are forward-declared automatically)
fn fib(n: int) -> int {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}
```

### Built-ins

- `print(expr)` — print a value without a newline
- `println(expr)` — print a value followed by a newline

Both accept any single value of type `int`, any fixed-width integer,
`float`, `f32`, `str`, `bool`, or `bytes` (bytes are written raw, with
no escaping).

- `len(x)` — length of a `str`, `bytes`, `[T]`, or map
- `push(xs, v)` / `pop(xs)` — append to / remove the last element of a list
- `has(m, k)` — does map `m` contain key `k`?
- `del(m, k)` — remove key `k` (and its value) from map `m`
- `to_str(x)` — convert any scalar or bytes value to `str`
- `to_bytes(s)` — convert a `str` to its raw bytes
- `to_le(n)` / `to_be(n)` — integer to 8-byte little/big-endian `bytes`
- `from_le(b)` / `from_be(b)` — 8-byte little/big-endian `bytes` to integer

### Types

| slang type | C type      | Notes                          |
|------------|-------------|--------------------------------|
| `int`      | `long long` | 64-bit signed integer          |
| `float`    | `double`    | IEEE double                    |
| `str`      | `const char *` | NUL-terminated UTF-8 bytes  |
| `bool`     | `bool`      | `true` / `false`               |
| `bytes`    | `sl_bytes *` | binary-safe byte sequence     |
| `i8 i16 i32 i64` | `int8_t` .. `int64_t` | signed fixed-width ints |
| `u8 u16 u32 u64` | `uint8_t` .. `uint64_t` | unsigned fixed-width ints |
| `f32`      | `float`     | IEEE single precision          |
| `[T]`      | `sl_arr *`  | growable array of T            |
| `map[K]V`  | `sl_map *`  | insertion-ordered hash map     |
| struct     | `sl_st_* *` | user-defined record (GC'd)     |

#### Numeric conversion rules

- **Implicit widening** within the integer family: a narrower int may be
  used wherever a strictly wider one is expected (`i32` -> `i64`,
  `u32` -> `u64`, and unsigned into a wider *signed* type). Widening
  toward floats is also implicit (`i32` -> `float`, `f32` -> `float`).
- **Narrowing and sign changes require an explicit cast** with `as`:
  `x as i8`, `n as u32`, `3.9 as i32`. Integer literals that fit the
  target width may initialize/pass without a cast.
- **Wrap on cast/overflow**: casts and arithmetic wrap two's-complement
  style. `(0 as u8) - (1 as u8)` is `255`; `300 as i8` is `44`. Float ->
  int casts truncate toward zero.
- Mixed-width arithmetic promotes to the wider operand; same-width
  signed/unsigned mixes resolve to the unsigned type (C semantics).

#### bytes

```slang
let b = b"raw\x00bytes";   // binary-safe literal; \0 \xHH escapes
println(len(b));           // byte count, not strlen
println(b[0]);             // indexing yields an int (0..255)
b[0] = 65;                 // mutable in place
let head = b[..2];         // slicing: b[a..b], b[..n], b[n..], b[..]
let both = b"ab" + b"cd";  // concatenation
if b == other { ... }      // content equality via ==
for byte in b { ... }      // iterate byte values
```

`bytes` values carry an explicit length and may contain NULs — safe for
network buffers and binary formats.

#### Lists `[T]`

```slang
let xs = [10, 20, 30];         // inferred [int]
let empty: [str] = [];         // empty lists need an annotation
push(xs, 40);                  // grow (amortized O(1))
println(pop(xs));              // shrink from the end
xs[0] = 5;                     // bounds-checked index assignment
for x in xs { println(x); }    // iteration
let ys = xs[0..2] + xs[1..];   // slicing + concatenation
let grid = [[1, 2], [3, 4]];   // nested lists
```

Indexing is bounds-checked at runtime; violations abort with a clear
message.

#### Maps `map[K]V`

```slang
let scores: map[str]int = {"alice": 90, "bob": 85};
scores["carol"] = 78;          // insert or overwrite
println(scores["alice"]);      // lookup (missing key = runtime error)
println(len(scores));          // entry count
if has(scores, "dave") { ... } // membership test (no error)
del(scores, "bob");            // removal

let empty: map[int]str = {};   // empty maps need an annotation
for k, v in scores {           // iteration in insertion order
    println(k + ": " + to_str(v));
}
```

Keys may be any integer type, `str`, or `bool`; values may be any type,
including structs and lists. Backed by an open-addressing hash table
(FNV-1a) that keeps entries in insertion order and grows automatically
at 75% load.

#### Structs

```slang
struct Point {
    x: int,
    y: int,
}

impl Point {
    fn sum(self: Point) -> int {
        return self.x + self.y;
    }

    fn moved(self: Point, dx: int, dy: int) -> Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }
}

let p = Point { x: 3, y: 4 };
println(p.sum());        // method call; self passed implicitly
p.x = 10;                // field mutation
let q = p.moved(1, 2);   // methods can build and return structs

struct Rect {
    tl: Point,
    br: Point,
}
let r = Rect { tl: Point { x: 0, y: 0 }, br: Point { x: 4, y: 5 } };
println(r.tl.y);         // nested field chains
r.br.x = 6;

let pts: [Point] = [p, q];  // structs compose with lists & maps
push(pts, r.tl);
```

Struct literals must supply every field exactly once, with types
checked. Methods live in top-level `impl Name { ... }` blocks; mark a
method `pub fn` to export it to importing packages. Structs are
heap-allocated and garbage-collected; assignment shares references.

## Packages (Go/Odin style)

A **package is a directory**: every `.sl` file inside it is compiled
together into one shared namespace, as if concatenated. Import paths
resolve relative to the importing file's directory.

```slang
import "geometry";   // binds the name "geometry" in this file's scope
import "a/b/util";   // nested paths bind as "util"

println(geometry.area(3.0, 4.0));   // qualified access
println(util.format(x));
```

**Exports are explicit.** Only declarations marked with `pub` are
visible to importers; everything else is private to its package:

```slang
// geometry/shapes.sl
pub fn area(w: float, h: float) -> float { ... }   // exported
fn scale(v: float) -> float { ... }                // private

// geometry/consts.sl
pub let pi = 3.14159;   // exported package constant
let secret = 42;        // private package global
```

Rules:

- Accessing a non-`pub` member from outside is a compile error.
- Within a package, members are used unqualified: `area(1, 2)`.
- In an imported package, top-level `let` becomes a package global;
  its initializer must be a constant literal.
- The entry point is the file you pass to `slangc`; its directory is
  the main package, and its top-level statements run in order in
  `main()`. Other files of the main package share its namespace.
- Duplicate names within a package, duplicate import bindings, and
  import cycles are all compile errors.
- Symbols are mangled per package (`sl_<pkg>_<name>`), so different
  packages can safely use the same names.

See `examples/pkgdemo/` for a complete multi-package project.

## How it works

```
main.sl ──loader──> packages ──lexer/parser──> ASTs ──codegen──> main.gen.c ──cc──> ./main
```

1. **Loader** (`src/loader.c`) — resolves imports relative to each
   importing file, scans package directories for `.sl` files (in
   deterministic sorted order), merges them per package, and detects
   cycles via canonical paths.
2. **Lexer** (`src/lexer.c`) — tokenizes source into identifiers,
   keywords, literals, and operators.
3. **Parser** (`src/parser.c`) — recursive-descent parser producing an
   AST (`src/ast.h`).
4. **Code generator** (`src/codegen.c`) — walks the ASTs, performs type
   inference and semantic checks (including `pub` enforcement), and
   emits readable C. A tiny runtime (string helpers, printing) is
   embedded directly into every generated file so output is fully
   self-contained.
5. **Driver** (`src/main.c`) — glues it together and shells out to
   `cc`. Because GCC/Clang compile the generated C, you get their full
   optimizer for free.

Inspect what slang generates:

```sh
./slangc examples/hello/main.sl --emit-c && cat main.gen.c
```

## Project layout

```
src/
  common.h     allocation helpers, growable string buffer, file I/O
  loader.h/.c  package discovery, merging, cycle detection
  lexer.h/.c   tokenizer
  ast.h        AST node definitions
  parser.h/.c  recursive-descent parser
  codegen.h/.c type checking + C emission
  main.c       driver: flags, invokes cc
examples/      one directory per example program
Makefile       build/test/clean
```

## Known limitations

- No block scoping: variables declared inside an `if`/`while` body
  remain visible afterwards.
- Strings are immutable; concatenation allocates. The Boehm GC reclaims
  unreachable strings automatically (verified: 2M throwaway
  interpolations hold steady at ~27 MB RSS).
- Package globals require constant-literal initializers.
- Implicit returns only apply to the last statement of a function
  body; `if` and `{}` blocks are statements, not expressions yet.
- No closures or error handling yet.
- Package-level lists are not supported yet (scalars and bytes are).
- Map keys are limited to integers, `str`, and `bool`.

## Memory management

Compiled programs link against [libgc](https://www.hboehm.info/gc/)
(Boehm-Demers-Weiser). All runtime allocations (`sl_strdup`,
`sl_str_concat`, conversions) go through `GC_malloc`; `main()` calls
`GC_INIT()` before user code runs. The driver resolves flags via
`pkg-config bdw-gc` and falls back to plain `-lgc`.

What this means in practice:

- No manual memory management in slang; no leaks from string churn.
- Collection is tracing (mark-and-sweep), so reference cycles are
  collected — unlike refcounting.
- Cost: a small external dependency and occasional short GC pauses.
  For most scripts this is imperceptible.

## Roadmap ideas

- Block scoping and shadowing
- If/block expressions (`let max = if a > b { a } else { b }`)
- Range `.step(n)`
- Option/Result types with `??`
- Import aliases (`import "x" as y`)
- A bytecode VM mode for fast iteration without invoking `cc`
