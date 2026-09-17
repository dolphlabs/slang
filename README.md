# slang

A statically typed language built primarily for server-side and
network programming.
`spawn` is M:N — green tasks on a worker pool, not a thread per
connection. Accept, recv, and send park. Memory is a precise,
non-moving, stop-the-world mark-sweep collector (`runtime/sl_gc.c`);
cycles are collected. `slangc` emits C and your system `cc` builds the
binary.

**Built and maintained by [Dolphlabs](https://dolphlabs.com)** — Dolph
Tech Limited.

## Documentation

Full documentation site: **<https://slang.dolphlabs.com/>**

Build it locally with `make docs` (dependency-free Python 3) and serve
with `make docs-serve`. The site is generated from this repository --
these README sections, the compiler's own signature tables, and the
`pub` declarations in `stdlib/` -- so it cannot drift from the code.
See [`www/README.md`](www/README.md) for the documentation convention
every slang package follows.

Reading with an agent? Every page has a Markdown twin at the same path,
`/llms.txt` indexes the site, `/llms-full.txt` is the whole thing as one
document, and `/api.json` is the machine-readable API index.

## Quick start

Install the compiler, then start a project:

```sh
git clone https://github.com/dolphlabs/slang && cd slang
sudo make install            # /usr/local by default; PREFIX=~/.local works too

slangc new hello
cd hello
slangc main.sl --run         # hello from hello
```

`make install` puts `slangc` in `$(PREFIX)/bin` and the runtime and
standard library in `$(PREFIX)/lib/slang` — both are needed, because
`slangc` splices its runtime C into every program it compiles. Remove it
all with `make uninstall`. `make dist` builds a relocatable tarball with
the same layout, which can be unpacked anywhere and run in place.

**Platforms.** CI builds and runs the full test suite on every merge to
`main` on Linux x86_64 (GCC), Linux arm64 (GCC) and macOS on Apple Silicon
(clang), and it is developed on macOS x86_64. Building needs a C compiler;
`net` over TLS, `crypto` and `httpc` over https also need OpenSSL (macOS:
`brew install openssl`; Debian/Ubuntu: `apt install libssl-dev`).

slangc finds OpenSSL itself: `OPENSSL_DIR` if set, then `pkg-config`, then
the standard Homebrew and MacPorts locations, then `brew --prefix`, then the
system headers. If none of those finds it and compilation fails, slangc says
so and suggests the fix, rather than leaving only the compiler's
"openssl/… file not found".

Working on the compiler itself:

```sh
make                 # build ./slangc against this working tree
make test            # compile & run the example programs
make docs            # rebuild the documentation site
```

Tests live in `*_test.sl` files and run with `slangc test` — covered in
the Testing section.

### Starting a project

```sh
slangc new myapp     # creates myapp/ with slang.project, main.sl, .gitignore
slangc new .         # same, in the directory you are already in
```

`slangc new` writes `slang.project` but **not** `slang.lock`. The lock is
derived: `slangc get` generates it from the `pkg` lines in
`slang.project`, and a lock file for a project with no dependencies
records nothing. Cargo and Go draw the same line — `cargo new` writes
`Cargo.toml` and not `Cargo.lock`.

Scaffolding lives in `slangc` rather than a companion tool because the
compiler already owns both formats: it parses `slang.project` and writes
`slang.lock`. A separate tool would have to reimplement a grammar it
does not control.

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
| `--run`     | Compile, then run it; exit with the program's own status |
| `get`       | Fetch `slang.project` pins and write `slang.lock`   |

Want to see everything at once instead of one feature at a time? See
**[`demo/`](demo/)** — a full server (dice game, guestbook wall, live
dashboard) exercising every tier: `http`/`link`, `net.tls_*`, `json`,
`spawn`/`chan[T]`, `proc` graceful shutdown, local package imports,
and C interop, with a real HTML/CSS/JS frontend. `cd demo && ./run.sh`.

## Language tour

```slang
// variables with inferred types
let x = 10;              // int  (64-bit)
let pi = 3.14;           // float (double)
let name = "World";      // str
let ok = true;           // bool

// arithmetic: + - * / %   (int/int is integer division)
// bitwise:    & | ^ ~ << >>   (integers only; see below)

// compound assignment for every binary operator above
let mut_acc = 0;
mut_acc += 5;
mut_acc |= 1 << 3;
xs[i] *= 2;
p.count += 1;
println(x + y);
println(x / 2.0);        // mixing int and float promotes to float

// strings concatenate with + ; numbers/bools convert automatically
println("Hello, " + name + "! " + x);

// string interpolation with ${expr} (any expression allowed)
println("pi doubled is ${pi * 2}");

// comparisons: == != < <= > >=   (bools: == and != only)   logic: && || !
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
- `to_bytes(x)` — copy a `str` or a `wire` into new `bytes`
- `to_int(s)` / `to_float(s)` — parse a `str`, returning
  `result[int, str]` / `result[float, str]` (see below)
- `to_le(n)` / `to_be(n)` — integer to 8-byte little/big-endian `bytes`
- `from_le(b)` / `from_be(b)` — 8-byte little/big-endian `bytes` to integer
- `exit(code)` — terminate the process immediately with the given status
- `assert(cond)` / `assert(cond, msg)` — fail if `cond` is false, with
  `msg` (built only when the assertion fails) and the location
- `panic(msg)` — fail unconditionally with `msg` and the location

`assert` and `panic` end the **current task**. In a spawned task, the
message becomes the `err` of its `join_wait`, e.g.
`x must be positive, got -3 at shapes.area:9`; in the main task the program
exits with status 1. `panic` never returns, so it can be the only thing in
a function that must return a value, and it satisfies `guard`'s requirement
that `else` leave the scope:

```slang
guard let user = find(id) else {
    panic("user " + to_str(id) + " vanished between check and use");
}
```
- `some(v)` / `none` / `ok(v)` / `err(e)` — construct `opt`/`result` values
  (see below)
- `bytes_ptr(b)` — raw `rawptr` to a `bytes` buffer, for passing to
  `extern fn`s (see C interop below)
- `make_chan(n)` / `chan_send(ch, v)` / `chan_recv(ch)` / `chan_close(ch)`
  — construct and use a `chan[T]` (see Concurrency below)
- `make_mutex()` / `mutex_lock(m)` / `mutex_unlock(m)` /
  `mutex_trylock(m)` — construct and use a `mutex` (see Concurrency
  below)
- `join_wait(h)` — wait for a `join[T]` from `spawn f(...)` (see
  Concurrency below)

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
| struct     | `sl_st_*`   | value record (copied)          |
| `gc struct` | `sl_st_* *` | GC'd heap record (shared)     |
| `opt[T]`   | `sl_opt_* *` | optional value: `some(v)` / `none` |
| `result[T,E]` | `sl_res_* *` | fallible value: `ok(v)` / `err(e)` |
| `duration` | `int64_t`   | nanosecond count (see `time`)  |
| `rawptr`   | `void *`    | opaque foreign pointer (C interop) |
| `ptr[T]`   | `T *`       | typed FFI pointer                  |
| `&T`       | `const T *` | shared borrow                      |
| `&mut T`   | `T *`       | unique borrow                      |
| `own T`    | `T *`       | unique heap box (no drop yet)      |
| `gc T`     | `T *`       | traced heap box of a value type    |
| `*T` / `*mut T` | `T *`  | raw pointer                        |
| `chan[T]`  | `sl_chan *` | bounded thread-safe queue (see Concurrency) |
| `join[T]`  | `sl_join *` | handle for a spawned task's result          |
| `mutex`    | `sl_mutex *` | task-parking lock (see Concurrency)        |
| `fn(A)->R` | `R (*)(A)`  | function value (see Function values)       |

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

#### Parsing numbers from text

`to_int(s)` and `to_float(s)` are the inverse of `to_str`, and they are
**fallible**, because parsing is:

```slang
let r = to_int(proc.getenv("PORT") ?? "8080");
guard let port = r else let e = err_of(r) {
    log.error("PORT is not a number: " + e);
    exit(2);
}
```

They are strict on purpose. Every one of these is an error, with a
message saying which:

| input | `to_int` | C's `atoi` would give |
|---|---|---|
| `"8080"` | `8080` | 8080 |
| `"abc"` | err: not a base-10 integer | **0** |
| `"80x80"` | err: not a base-10 integer | **80** |
| `""` | err: cannot parse an empty string as int | **0** |
| `"  12"` | err: not a base-10 integer | 12 |
| `"9223372036854775808"` | err: out of range for int | undefined |

Surrounding whitespace, `1_000`, `0x10` and trailing characters are all
rejected. A caller who wants leniency can `strings.trim` first; a caller
who gets leniency they did not ask for cannot undo it. `to_float`
likewise rejects `inf` and `nan`, which `strtod` would accept and which
are almost never what a config value meant.

The error message does not echo the offending input — the caller already
has it, and building that string would mean another allocation on the
failure path.

#### Bitwise operations and integer literals

Binary protocols are most of network programming, so the bit operators
are first-class: `&` `|` `^` `~` `<<` `>>`, on any integer type.

```slang
// an HTTP/2 frame header, straight off the wire
let flen  = (b[0] << 16) | (b[1] << 8) | b[2];
let ftype = b[3];
let flags = b[4];
let sid   = ((b[5] & 0x7f) << 24) | (b[6] << 16) | (b[7] << 8) | b[8];

if flags & 0x01 != 0 { /* END_STREAM */ }
```

Integer literals come in decimal, hex (`0xff`, `0xFF`) and binary
(`0b1010`), and `_` may be used anywhere as a digit separator:
`1_000_000`, `0xff_ff`, `0b1010_1010`.

A literal too large for `i64` **is a `u64`**, not an overflowing `int`:
`let mask = 18446744073709551615;` gives a `u64` holding that exact
value, and `let x: int = 18446744073709551615;` is a compile error
rather than a surprise. Anything past `u64` is rejected at the point of
writing — `integer literal does not fit in 64 bits`. (Before this,
decimal literals ran through `strtoll`, which saturates: those two
literals and `99999999999999999999999` all silently became
`9223372036854775807`.)

**Precedence follows C exactly**, so an expression lifted from an RFC or
a C reference implementation means the same thing here:

```
||  <  &&  <  |  <  ^  <  &  <  == !=  <  < <= > >=  <  << >>  <  + -  <  * / %  <  unary
```

Three things differ from C, all deliberately:

- **`&` is never ambiguous.** Infix `&` is bitwise AND; the borrow forms
  `&x` / `&mut x` are prefix-only, so the parser can always tell them apart.
- **C's `x & 1 == 1` footgun is a compile error.** C parses that as
  `x & (1 == 1)` and accepts it because `bool` is an `int`; slang rejects
  it with "'&' requires integer operands (got int and bool)". Parenthesize
  what you meant.
- **An out-of-range shift count panics** instead of being undefined
  behaviour. `x << n` where `n` is negative or at least the width of `x`
  reports `shift count out of range at pkg.func:line`, the same way
  division by zero and an out-of-bounds index do — this matters when the
  count came off the network. When the count is a constant already in
  range (`b[0] << 16`, the normal case) the check is compiled out
  entirely, so protocol code pays nothing for it.

**Compound assignment** exists for every one of these: `+= -= *= /= %=`
and `&= |= ^= <<= >>=`. `x op= v` means `x = x op v`, which evaluates the
target twice, so a side-effecting **index** is hoisted into a temporary
first and runs exactly once — `xs[pop(q)] += 1` pops once, not twice.
Only the value being indexed has to be re-nameable: `f()[0] += 1` is a
compile error, since naming `f()` twice would call it twice, and hoisting
it would mutate a copy for a value-type struct. Write that one out.

`>>` follows the operand's signedness: arithmetic (sign-preserving) on a
signed type, logical (zero-filling) on an unsigned one, exactly as in C.
`&` `|` `^` promote to the wider operand; a shift keeps the width of the
value being shifted, so `x << n` never silently widens a narrow `x`
because `n` happens to be an `int`.

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
let empty: [str] = [];         // an empty list needs a type from context
push(xs, 40);                  // grow (amortized O(1))
println(pop(xs));              // shrink from the end
xs[0] = 5;                     // bounds-checked index assignment
for x in xs { println(x); }    // iteration
let ys = xs[0..2] + xs[1..];   // slicing + concatenation
let grid = [[1, 2], [3, 4]];   // nested lists
```

Indexing is bounds-checked at runtime; violations abort with a clear
message.

`[]` has no element type of its own, so it takes one from what is
expected of it — the same way `none` does: an annotated `let`, a function
or method parameter, a struct field, a `return`, an assignment,
`ok([])`/`some([])`, `push(grid, [])`, or an element of an outer list.
With nothing expected (`let xs = [];`) it is a compile error.

```slang
fn total(xs: [int]) -> int { return len(xs); }
total([]);                          // [int], from the parameter
let b = Basket { items: [] };       // from the field
```

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
values: assignment copies, including any `str` / list / map /
`opt` / `result` / `gc struct` fields (shallow — the heap objects
are shared). Use `gc struct` when the record itself should be a
shared heap object.
`own T` is uniquely owned: assignment and passing **move**, and
use-after-move is a compile error. A moved binding can be reinitialized.
`own` is freed when its binding goes out of scope unless it was moved.

#### Option / Result

```slang
fn div10(n: int) -> opt[int] {
    if n % 10 == 0 { return some(n / 10); }
    return none;
}

fn parse_small(s: str) -> result[i32, str] {
    if s == "big" { return err("value too large"); }
    return ok(7);
}

// guard let unwraps the happy path and binds it for the rest of the
// block; the else branch must exit (return, or exit()) since the
// bound name has no value to fall back to. `else let e = err_of(r)`
// binds the error value for `result[T, E]` so failures stay visible.
fn safe_div(n: int) -> int {
    guard let v = div10(n) else {
        return -1;
    }
    return v;
}

fn load_config(path: str) -> str {
    let r: result[str, str] = read_file(path);
    guard let body = r else let e = err_of(r) {
        log.warn("config load failed: " + e);
        return "";
    }
    return body;
}

// ?? recovers from none / err with a fallback value
println(div10(41) ?? -1);              // -1 (none)
println(parse_small("big") ?? -1);     // -1 (err)

// `fault` is the closed 5-kind network/runtime failure enum:
// fault_timeout / fault_reset / fault_closed / fault_io / fault_refused.
// `==` and `fault_kind` only see the kind. `fault_op` and `fault_code`
// carry context: the op name ("recv", "connect", "dial", ...) and the
// errno value (0 when none applies). `to_str` / `+` / `println` render
// the full "op detail (code N)" form, so failures stay debuggable.
let f = fault_io();
println(fault_kind(f));                // 4
println(fault_op(f));                  // "" (hand-built, no op)
println(fault_code(f));                // 0

// bare 'none' / 'err(...)' need an annotated binding to infer their
// other type parameter
let nothing: opt[str] = none;
let bad: result[str, str] = err("boom");
```

Panics (out-of-bounds index, division by zero, `err_of` on ok, missing
map key) carry `pkg.func:line`: `list index out of bounds at
main.foo:12`. A panicking `spawn`ed task reports through stderr and its
`join_wait` surfaces the same string as `err`, so failures stay visible
across task boundaries.

`opt[T]` and `result[T, E]` are monomorphized per distinct type
argument (one C struct per instantiation actually used). Constructing
`none`/`err(...)` without enough context to infer the missing type
parameter is a compile error.

#### Error model: `opt` vs `result` vs `fault`

- `opt[T]` — the value may legitimately be absent (`none`). Lookup
  misses, optional config, end of a drained channel. Absence is not
  failure; `??` supplies the default.
- `result[T, E]` — the operation can fail with a *descriptive* error
  (`err(e)`). Parsing, validation, anything where the caller needs to
  know *why*. `E` is usually `str`; `guard let x = r else let e =
  err_of(r)` keeps the reason visible.
- `fault` — the operation hit the *environment*: timeout, reset,
  closed connection, refused dial, IO error. A closed 5-kind enum
  (`fault_timeout` / `fault_reset` / `fault_closed` / `fault_io` /
  `fault_refused`), comparable with `==` and convertible with
  `to_str` / `+`. Use it when the failure is about the world, not
  the data.

Rule of thumb: absent data is `opt`, bad data is `result[_, str]`,
bad world is `result[_, fault]`. Never collapse a descriptive `str`
error into a bare `fault_io()` at a boundary — that is where
debuggability goes to die (see `http.read` below).

### Function values

A `fn` type holds a function. `fn(A, B) -> R` for one that returns a
value, `fn(A)` for one that returns nothing:

```slang
fn double(x: int) -> int { return x * 2; }
fn triple(x: int) -> int { return x * 3; }

let f: fn(int) -> int = double;   // annotated
let g = triple;                   // or inferred from the function
println(f(21));                   // 42
```

They work as parameters, return values, struct fields, list and map
elements — which is what makes a dispatch table possible instead of a
chain of string comparisons (`demo/samplex/server.sl` routes this way):

```slang
gc struct Route {
    method: str,
    path: str,
    handler: fn(State, http.Request, int) -> http.Response,
}

let routes: [Route] = [
    Route { method: "GET",  path: "/api/tasks", handler: list_tasks },
    Route { method: "POST", path: "/api/tasks", handler: create_task }
];

for i in 0..len(routes) {
    if routes[i].method == req.method && routes[i].path == req.path {
        return routes[i].handler(st, req, -1);
    }
}
```

Anything holding a function value is callable directly —
`routes[i].handler(...)`, `by_name["parse"](...)`, `pick(true)(4)`.

**These are not closures, and that is the point.** A function value
always names a top-level function; nothing is captured. There is no
environment to allocate, trace, or reason about, so a `fn` value is
exactly a C function pointer — it names code, never the heap, and the
collector ignores it entirely. Anything a handler needs is passed to
it, which is the same rule `spawn` already follows.

Two consequences worth knowing:

- **Methods cannot be used as function values.** A method takes a
  receiver the type does not name, so `fn(Counter) -> int` would be a
  lie about its arity. Wrap it in a plain function.
- **A binding shadows a function of the same name.** `let scale = ...`
  in scope means `scale` refers to the binding, never to `fn scale`.

`spawn` takes a function value too — `spawn handlers[i](job);` — see
Concurrency below.

## Standard packages

`time`, `net`, `json`, `proc`, `fs`, `log`, `crypto`, `sql`, `regex`,
`os`, `strings`, `encoding` and `compress` are compiler-provided native packages — no source files, just
`import "time";` / `import "net";` / `import "json";` / `import "proc";`
/ `import "fs";` / `import "log";` / `import "crypto";` / `import "sql";`
/ `import "regex";` / `import "encoding";` like any other package.

`http`, `httpc`, `http2`, `pg` and `byteutil` are slang-source stdlib packages under `stdlib/`.
`import "http"` / `import "byteutil"` resolve to a local directory first,
then a native package, then `stdlib/<path>` (`SLANG_STDLIB` or the
compiler's `SLANG_STDLIB_DIR`).

#### `time`

```slang
import "time";

let t0 = time.mono();     // monotonic clock; a `duration` (int64 ns)
time.sleep(20000000);     // sleep for a duration (ns)
let elapsed = time.mono() - t0;   // duration arithmetic
let deadline = time.mono() + 5000000;  // timeout math for net calls

let wall = time.wall();   // unix epoch time in nanoseconds
```

#### `net`

TCP listener/dialer built on `bytes` and fixed-width ints; every
fallible call returns a `result[_, str]` unwrapped with `guard let`.

```slang
import "net";

let lr: result[i32, str] = net.listen(8080);   // 0 = ephemeral port
guard let lfd = lr else { exit(1); }

let pr: result[i32, str] = net.port(lfd);      // assigned port number

let ar: result[i32, str] = net.accept(lfd);    // blocks until a peer connects
guard let cfd = ar else { exit(1); }

net.send(cfd, b"hello");
let rr: result[bytes, str] = net.recv(cfd, 4096);
let data: bytes = rr ?? b"";

net.nonblock(cfd);                              // switch to non-blocking mode
let wr: result[bytes, str] = net.recv(cfd, 16); // "would block" err if idle
net.close(cfd);
```


`net.idle_alive(fd) -> bool` and `net.tls_idle_alive(ssl) -> bool`
report whether an IDLE connection is still reusable: true only when the
peer has neither closed nor sent anything. One non-blocking `MSG_PEEK`,
nothing consumed; the TLS form is also false when OpenSSL holds
decrypted-but-unread bytes. They exist for connection pools, and they
are a primitive rather than a `recv_until` with an expired deadline
because `recv_until` checks its deadline *before* touching the socket —
it would report every dead connection as alive.

##### Deadlines

`net.recv` and `net.send` wait for as long as the peer takes, which on
a public listener is indefinitely: a client that connects and then
neither sends nor reads parks the serving task on the reactor forever,
holding its stack and its GC roots. That is slowloris, and the defence
is `recv_until` / `send_until`, which take an `until` — an absolute
monotonic instant, not a duration:

```slang
import "net";
import "time";

let deadline = until_of(time.mono() + 5000000000);   // 5s from now
let rr = net.recv_until(cfd, 4096, deadline);
guard let data = rr else let e = err_of(rr) {
    if e == "timeout" { net.close(cfd); return; }    // peer went quiet
    log.error("recv: " + e);                         // peer broke
    return;
}
```

`"timeout"` is a reserved error string: it means the deadline passed,
and it is the only error text these calls invent rather than take from
the OS. Every other error is `strerror`/OpenSSL text as before.

One asymmetry worth knowing: a `send_until` that times out **has
already written some bytes**, and `result[i32, str]` has no room to
report both "timed out" and "wrote this much". A `"timeout"` from
`send_until` therefore means the stream is at an unknown offset and the
connection must be closed, not retried. For a framed protocol that is
the right contract regardless — a half-written frame is unrecoverable.

`net.tls_recv_until` / `net.tls_send_until` are the same thing over
TLS, with the same reserved string. The `link` API takes an `until` on
`accept`/`send`/`recv` already.

`net.dial_until(host, port, deadline)` bounds connecting: the DNS lookup
and the TCP connect together. A lookup still running when the deadline
passes is abandoned to the resolver thread (`getaddrinfo` cannot be
interrupted), so the caller gets `"timeout"` on time. Every address the
name resolves to is tried in turn — `net.dial` does the same, without a
deadline.

##### Unix-domain sockets

`net.dial_unix(path, deadline)` connects to a Unix-domain stream socket
and `net.listen_unix(path)` listens on one (accept with `net.accept`).
The fds work with every fd-based call — `send`/`recv` and their `_until`
forms, `close`, `idle_alive`. `listen_unix` refuses a path that already
exists rather than deleting it, since the file may belong to a server
that is still running; remove a stale one with `os.remove` first. A path
longer than the platform allows (104 bytes on macOS, 108 on Linux) is an
error, not truncated.

See `examples/httpd/` for a minimal HTTP server on `link` plus the
`http` stdlib package.

#### TLS

`net.tls_*` adds a TLS listener/dialer on top of the plain `net`
primitives above, built on OpenSSL (linked automatically, and only
when a program actually calls one of these — a plain-TCP `net`
program stays dependency-free). A `SSL_CTX`-equivalent config is
created once (`tls_server_ctx` / `tls_client_ctx`) and reused across
many connections; each connection is a separate `rawptr` handle.

```slang
import "net";

// server: load a cert + key once, reuse the context for every connection
let sctx_r: result[rawptr, str] = net.tls_server_ctx("cert.pem", "key.pem");
guard let sctx = sctx_r else { exit(1); }

let lr: result[i32, str] = net.listen(8443);
guard let lfd = lr else { exit(1); }
let ar: result[rawptr, str] = net.tls_accept(lfd, sctx);  // TCP accept + handshake
guard let sconn = ar else { exit(1); }
net.tls_send(sconn, b"hello");
net.tls_close(sconn);

// client: verify against a CA file, or "" for the system trust store
let cctx_r: result[rawptr, str] = net.tls_client_ctx("");
guard let cctx = cctx_r else { exit(1); }
let dr: result[rawptr, str] = net.tls_dial("example.com", 443, cctx);
guard let cconn = dr else { exit(1); }
let rr: result[bytes, str] = net.tls_recv(cconn, 4096);
net.tls_close(cconn);
```

Client verification is strict by default: `tls_client_ctx` enables
peer verification, and `tls_dial` checks the certificate against
*both* the CA and the hostname you asked for (`SSL_set1_host` — the
check that's easy to forget and, if skipped, leaves you with "TLS"
that validates a certificate chain without checking it belongs to
the host you're actually talking to). Sending/receiving is blocking,
same as plain `net` — call these from a `spawn`ed task if you need a
connection handled without stalling anything else.

**ALPN** (RFC 7301) negotiates the protocol during the handshake, which
is how HTTP/2 over TLS is selected — there is no in-band upgrade.
`tls_ctx_alpn(ctx, "h2,http/1.1")` sets the list on a server context (in
preference order, so the *server* decides) or the offer on a client one,
and `tls_alpn(conn)` returns what was actually negotiated, or `""` if
the peer offered nothing that overlapped. The list is comma-separated,
not the length-prefixed wire form; building that by hand is an easy way
to produce a subtly broken handshake. A client offering no protocol we
support completes the handshake without ALPN rather than failing, so it
simply falls back to HTTP/1.1.

```slang
net.tls_ctx_alpn(sctx, "h2,http/1.1");
let conn = ...;                  // after tls_accept
if net.tls_alpn(conn) == "h2" { serve_h2(conn); } else { serve_h1(conn); }
```

Mutual TLS: `tls_ctx_require_client(sctx, client_ca)` on the server
context demands a client certificate chained to that CA
(`SSL_VERIFY_FAIL_IF_NO_PEER_CERT`). The client presents one with
`tls_ctx_use_cert(cctx, cert, key)`. Extra server names on one
listener: `tls_ctx_add_sni(sctx, host, cert, key)` swaps in that
cert when the ClientHello SNI matches; unmatched names keep the
default `tls_server_ctx` cert. `require_client` applies to SNI
certs too, regardless of call order. TLS 1.3 can let `tls_dial`
return before the server has rejected a missing client certificate;
the first send or recv then fails.

**STARTTLS**: `tls_upgrade(fd, host, ctx)` runs a client handshake on a
socket from `net.dial` that has already spoken cleartext — how Postgres,
SMTP and IMAP switch to TLS. Verification is exactly `tls_dial`'s,
hostname included, which is why the host is an argument: an fd does not
remember what was dialled. On failure the fd is left open for the caller
to close; on success it belongs to the returned handle and `tls_close`
closes it. Read no further than the server's go-ahead before upgrading:
anything a man in the middle queued behind it would otherwise be trusted
as if it had arrived encrypted (libpq's CVE-2021-23222).
`tls_upgrade_until(fd, host, ctx, deadline)` bounds the handshake; a
server that stops answering part way through gives `"timeout"`.

#### `json`

`json.decode`/`json.encode` (de)serialize `str`/`bytes` against a
concrete slang type — the target type for `decode` is inferred from
the binding's annotation, the same mechanism `ok()`/`err()` already
use to infer `result[T,E]`. There is no dynamic "JSON value" type:
every decode is checked field-by-field against the struct shape you
asked for, and a mismatch is a `result` error, not a silent `null` or
a runtime panic.

```slang
import "json";

gc struct Address { city: str, zip: str }
gc struct Person {
    name: str,
    age: i32,
    email: opt[str],      // JSON null / missing key <-> none
    tags: [str],
    addr: Address,         // structs nest
}

let p = Person{ name: "Ada", age: 36, email: some("ada@example.com"),
                tags: ["math"], addr: Address{ city: "London", zip: "SW1" } };
let s: str = json.encode(p);

let r: result[Person, str] = json.decode(s);
guard let p2 = r else { exit(1); }
```

Supported: `struct`, `opt[T]`, `[T]`, `map[str, V]` (JSON object keys
are always strings — a map with any other key type is a compile
error), every scalar, and `bytes` (RFC 4648 base64 strings on the
wire). `rawptr`, `chan[T]`, and
`result[T,E]` can't appear anywhere in a decode/encode target type. A
missing JSON key defaults an `opt[T]` field to `none`; for any other
field type it's a decode error. Unknown JSON keys are ignored. Every
decode error names where it happened, composed through nesting —
`json.decode` on `{"addr":{"city":5}}` against the `Person` shape
above fails with `field 'addr': field 'city': expected a string, got
a number`. Malformed input is a decode error, never a crash — the
parser caps nesting depth at 512 so adversarial input can't blow the
C stack.

#### `proc`

Graceful shutdown and environment variables. `proc.shutdown_requested()`
turns true once the process receives `SIGTERM` or `SIGINT`; a blocked
`net.accept()`/`net.recv()`/`net.dial()` on the main thread is
interrupted the instant the signal arrives (an `err` result, not a
hang), so a listener loop notices without needing `select` or a
timeout. `proc.active_tasks()` counts currently-running `spawn`ed
tasks. `proc.wait_idle()` parks until that count is zero, so a
shutting-down program can drain in-flight work without polling.

```slang
import "net";
import "proc";
import "time";

fn accept_and_serve(lfd: i32) {
    let ar: result[i32, str] = net.accept(lfd);
    guard let cfd = ar else { return; } // interrupted, or a real error
    spawn serve(cfd);
}

let lr: result[i32, str] = net.listen(8080);
guard let lfd = lr else { exit(1); }

while !proc.shutdown_requested() {
    accept_and_serve(lfd);
}

proc.wait_idle();
```

`proc.getenv(name)` reads an environment variable, returning
`opt[str]` (`none` if unset). `proc.args()` is the process argument
list (`[str]`); `args[0]` is the executable path. `proc.cwd()` is the
working directory as `result[str, str]`.

#### `fs`

POSIX file I/O on integer fds. `open` is read-only; `create` is
write/trunc. `read`/`write`/`close` use the fd. `mkdir` creates one
directory. Every call returns `result[_, str]`. These calls block the
worker — use them for config and small files, not the accept loop.

```slang
import "fs";

let cr = fs.create("/tmp/note");
guard let fd = cr else { exit(1); }
fs.write(fd, b"hi");
fs.close(fd);

let or = fs.open("/tmp/note");
guard let in_fd = or else { exit(1); }
let rr = fs.read(in_fd, 16);
guard let data = rr else { exit(1); }
fs.close(in_fd);
```

#### `os`

The operating system *around* a program: the environment, the process,
and everything you can ask or do about a path without opening it. Pure
libc, so importing `os` adds no link flag.

**The `fs`/`os` boundary**: `fs` owns open file **handles** and their
contents; `os` owns paths you have not opened. `fs.mkdir` predates that
split and stays where it is rather than breaking existing programs.

| | |
|---|---|
| `os.setenv(k, v)` / `os.unsetenv(k)` | `result[bool, str]` |
| `os.environ()` | `[str]` of `KEY=VALUE` |
| `os.pid()` / `os.tmpdir()` | `int` / `str` |
| `os.hostname()` | `result[str, str]` |
| `os.exists(p)` / `os.is_dir(p)` / `os.is_file(p)` | `bool` |
| `os.size(p)` / `os.mtime(p)` | `result[int, str]` |
| `os.read_dir(p)` | `result[[str], str]` |
| `os.remove(p)` / `os.rename(a, b)` | `result[bool, str]` |

```slang
import "os";

// serve a static file, the shape this package exists for
if !os.is_file(path) {
    return not_found();
}
let sr = os.size(path);
guard let n = sr else let e = err_of(sr) {
    log.error("stat " + path + ": " + e);      // "No such file or directory"
    return server_error();
}
```

The three predicates are bare `bool` on purpose. "Does this exist" has
two useful answers: a missing path and an unreadable parent are both
"no, you cannot use it", and code branching on the difference is racing
anyway — the answer can change between the check and the use. The
accessors return a value that has to come from somewhere, so those
carry the errno text.

`environ()` is a list rather than a map because an environment may
legally hold a repeated key, and a map would silently drop one.
`read_dir` returns entry names without `.` and `..`, since forgetting
to filter those is how a directory walk becomes an infinite loop.
`remove` takes files and empty directories alike, so a caller need not
know which it has.

`proc.getenv`, `proc.args` and `proc.cwd` stay in `proc`; `os` adds
what `proc` has no answer for rather than duplicating it.

#### `log`

Stderr logging with a timestamp and level. Each function accepts a
`str` or a `fault` (`to_str`/`+` already convert faults the same way),
so `err_of` bindings and `fault` values log without manual conversion.

```slang
import "log";

log.debug("cache miss for key foo");
log.info("listening on :8080");
log.warn("retrying dial after timeout");
log.error("could not load config: " + e);
log.warn(fault_timeout());
```

#### `crypto`

SHA-256, HMAC-SHA256, PBKDF2, MD5 and a CSPRNG over OpenSSL. Hashes and
HMAC are infallible on valid inputs and return `bytes` directly; `rand`
and `pbkdf2_sha256` can fail and return `result[bytes, str]`.

```slang
import "crypto";

let h: bytes = crypto.sha256(b"abc");              // 32 bytes
let m: bytes = crypto.hmac_sha256(key, msg);       // 32 bytes
let r = crypto.rand(32);
guard let b = r else let e = err_of(r) {
    log.error("rand failed: " + e);
}
let k = crypto.pbkdf2_sha256(password, salt, 600000, 32);   // RFC 8018
let d: bytes = crypto.md5(b"abc");                 // 16 bytes
```

`pbkdf2_sha256(password, salt, iterations, length)` accepts 1 to
10,000,000 iterations and a length of 1 to 1024 bytes; anything else is
an `err`. The iteration count is capped because it is often chosen by the
other side of a protocol (a SCRAM server sends it) and the whole
derivation runs without yielding the worker thread.

`md5` is broken for collision resistance. It exists for the protocols
that still specify it -- Postgres md5 authentication, `Content-MD5`,
legacy ETags -- and must not protect anything new.

#### `sql`

A SQLite driver (linked automatically, only when a program imports
`sql`). Connections and prepared statements are opaque `rawptr`
handles, exactly like `net.tls_*`; free them with `sql.close` /
`sql.finalize`. **Every fallible call returns `result[_, str]` whose
error is SQLite's own message** — `no such table: users`, `near
"SELCT": syntax error`, `UNIQUE constraint failed: users.id` — so a
bad query stays as visible as a bad socket read (`guard let … else
let e = err_of(r)`), never a silent `null`. The column getters are
infallible (SQLite coerces types; an out-of-range index is a
programming error, returning `0` / `""`), so they return bare values.

| Function | Signature |
|----------|-----------|
| `sql.open(path)` | `result[rawptr, str]` — `":memory:"` for in-memory |
| `sql.close(db)` | — |
| `sql.exec(db, sql)` | `result[int, str]` — runs statement(s), returns rows changed |
| `sql.last_insert_id(db)` | `int` |
| `sql.prepare(db, sql)` | `result[rawptr, str]` |
| `sql.finalize(st)` | — |
| `sql.reset(st)` | `result[bool, str]` — clears bindings, re-run |
| `sql.bind_int/bind_float/bind_text/bind_blob(st, idx, v)` | `result[bool, str]` — `idx` is 1-based |
| `sql.bind_null(st, idx)` | `result[bool, str]` |
| `sql.step(st)` | `result[bool, str]` — `true` = row ready, `false` = done |
| `sql.col_count(st)` | `int` |
| `sql.col_name(st, i)` / `col_text(st, i)` | `str` — `i` is 0-based |
| `sql.col_int(st, i)` | `int` |
| `sql.col_float(st, i)` | `float` |
| `sql.col_blob(st, i)` | `bytes` |
| `sql.col_is_null(st, i)` | `bool` |

```slang
import "sql";
import "log";

let dr = sql.open("app.db");
guard let db = dr else let e = err_of(dr) {
    log.error("db open: " + e);
    exit(1);
}
sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

let pr = sql.prepare(db, "SELECT id, name FROM users WHERE id > ?");
guard let st = pr else let e = err_of(pr) {
    log.error("prepare: " + e);          // e.g. "no such table: users"
    exit(1);
}
sql.bind_int(st, 1, 0);
while true {
    let sr = sql.step(st);
    guard let more = sr else let e = err_of(sr) { log.error("step: " + e); break; }
    if !more { break; }
    println(to_str(sql.col_int(st, 0)) + " " + sql.col_text(st, 1));
}
sql.finalize(st);
sql.close(db);
```

SQLite calls block the worker — use them for real work off the accept
loop (wrap in a `spawn`ed task), the same caveat as `fs`. One
connection per `rawptr`; there is no pool and no async stepping. For
Postgres, see [`pg`](#pg), which runs on the scheduler instead.

Query complexity is capped per connection so SQLite's recursion stays
inside the task stack: at most **50 terms in a compound `SELECT`**
(`UNION`/`INTERSECT`/`EXCEPT`) and an **expression depth of 400**
(roughly, terms in one `AND`/`OR` chain). SQLite's stock limits of 500
and 1000 allow a single legal query to want ~325KB of C stack, which
would force a task stack far too fat to spawn per connection. Long
`IN` lists, wide result sets, and recursive CTEs are *not* affected —
they don't recurse. Exceeding a cap is a normal error through
`result[_, str]` (`too many terms in compound SELECT`), not a crash.

#### `pg`

A **PostgreSQL** client, written in slang over `net`. A query waiting on
the server parks its task like any socket read, so unlike `sql` it does
not block a worker thread: a server can hold many database connections
on a handful of threads. Errors keep the server's own text and SQLSTATE,
through the same `result[_, str]` story as every other package.

```slang
import "pg";
import "time";
import "log";

let dl = until_of(time.mono() + 5000000000);

let pr = pg.new_pool("postgres://app:secret@db.internal/shop", 10);
guard let pool = pr else let e = err_of(pr) {
    log.error("db url: " + e);
    exit(1);
}

let r = pg.pool_query(pool,
    "SELECT id, name, price FROM products WHERE price < $1 ORDER BY id",
    [pg.arg_float(20.0)], dl);
guard let rows = r else let e = err_of(r) {
    log.error("query: " + e);   // ERROR: relation "products" does not exist (SQLSTATE 42P01)
    exit(1);
}
let i = 0;
while i < rows.count {
    println(to_str(pg.get_int(rows, i, 0)) + " " + pg.get_text(rows, i, 1));
    i = i + 1;
}
```

Every call that talks to the server takes a deadline (`until`), like
`httpc`; `until_of(0)` waits indefinitely. For `connect` it covers the
whole connection: DNS lookup, TCP connect, TLS handshake and login.

| Function | Signature |
|---|---|
| `pg.connect(url, deadline)` | `result[Conn, str]` |
| `pg.parse_url(url)` / `pg.connect_config(cfg, deadline)` | `result[Config, str]` / `result[Conn, str]` |
| `pg.query(c, sql, args, deadline)` | `result[Rows, str]` — one statement, `$1`, `$2`… parameters |
| `pg.exec(c, sql, deadline)` | `result[int, str]` — several `;`-separated statements, no parameters; rows affected by the last |
| `pg.close(c)` | — sends Terminate and closes |
| `pg.usable(c)` / `pg.in_transaction(c)` | `bool` |
| `pg.server_param(c, name)` | `opt[str]` — `server_version`, `TimeZone`, … |
| `pg.sqlstate(e)` | `str` — the SQLSTATE in an error, or `""` if it did not come from the server |

**Parameters** travel separately from the SQL text, so a value can never
be parsed as SQL, whatever it contains. Build them with `pg.arg_text(s)`,
`arg_int(n)`, `arg_float(x)` (sent exactly, not rounded), `arg_bool(b)`,
`arg_bytes(b)` (binary, for `bytea`) and `arg_null()`. A query with none
takes `[]`.

**Results** from `query` are buffered whole in a `Rows` (for one too big
for that, see [Streaming](#streaming)): `rows.count`, `rows.columns`
(names), `rows.affected` (from the command tag, so an `INSERT` or
`UPDATE` through `query` reports its row count) and `rows.tag`. Read
cells by row and column index; `pg.col(rows, "name")` finds an index.

| Getter | Reads |
|---|---|
| `pg.get_text(rows, r, c)` | any column, in Postgres's text form (dates, `numeric`, `uuid`, `json`) |
| `pg.get_int(rows, r, c)` | `int2`, `int4`, `int8`, `oid`, and a whole-number `numeric` (what `sum()` of an integer column returns) |
| `pg.get_float(rows, r, c)` | `float4`, `float8`, `numeric`, the integer types |
| `pg.get_bool(rows, r, c)` | `bool` |
| `pg.get_bytes(rows, r, c)` | `bytea` |
| `pg.is_null(rows, r, c)` | whether the cell is NULL |

The getters **panic** on NULL, on a column of a type they do not read,
on an unknown column name and on an index out of range, with a message
naming the column (`column 'email' is NULL in row 3; check pg.is_null
before pg.get_text`). Those are disagreements between the query and the
code reading it — bugs to see, not conditions to handle — and inventing a
`0` or `""` would hide them. A nullable column is checked with `is_null`
first. Like sqlx's `get`, not Go's `Scan`.

##### Pool

`pg.new_pool(url, max_open)` parses the url and connects nothing until
first use. `pool_query` and `pool_exec` take a connection, run, and give
it back, so they cannot leak one. A transaction needs several statements
on one connection, so it uses `acquire` and `release`:

```slang
let cr = pg.acquire(pool, dl);
guard let c = cr else let e = err_of(cr) { return; }
pg.exec(c, "BEGIN", dl);
let moved = pg.query(c, "UPDATE accounts SET balance = balance - $1 WHERE id = $2",
                     [pg.arg_int(100), pg.arg_int(from)], dl);
guard let m = moved else {
    pg.release(pool, c);    // still in the transaction: closed, never reused
    return;
}
pg.exec(c, "COMMIT", dl);
pg.release(pool, c);
```

At most `max_open` connections exist at once; a task that needs one while
all are in use waits, up to its deadline. Idle connections are probed
before reuse and closed after `pool.idle_timeout` (5 minutes). A
connection released while broken, closed or **still inside a
transaction** is closed rather than handed on — the next caller would
otherwise run its statements inside someone else's uncommitted work.
Releasing the same connection twice panics. `pool.dials` and
`pool.reuses` count what the pool did.

##### URLs and TLS

`postgres://user:password@host:port/database?param=value`, with `%`
escapes in any part. The port defaults to 5432 and the database to the
user name. Recognised parameters are `sslmode`, `sslrootcert` (a CA
bundle to verify against, for providers that sign with their own CA) and
`application_name`, plus `host` and `port`, which override the ones in the
authority, as in libpq. **Anything else is an error, not ignored**: a
misspelt `sslmdoe=require` that was quietly dropped would connect in
cleartext and nothing would ever say so.

| `sslmode` | |
|---|---|
| `disable` | cleartext |
| `require`, `verify-full` | TLS, with the certificate chain **and hostname verified** |
| `prefer`, `allow` | refused: they fall back to cleartext when TLS fails, which is exactly what a man in the middle arranges |
| `verify-ca` | refused: it does not check the hostname |

This differs from libpq on purpose: libpq's `require` encrypts without
checking who answered. Without `sslmode`, the default is `require` —
except for a loopback host (`localhost`, `127.x`, `::1`), where it is
`disable`, because traffic that never leaves the machine gains nothing
from TLS and local servers rarely have it set up. A server that does not
offer TLS gets a message saying to add `sslmode=disable`.

**Unix-domain sockets** are named by their directory, as libpq does:
`postgres://app@%2Fvar%2Frun%2Fpostgresql/shop` (the host
percent-encoded) or `postgres://app@/shop?host=/var/run/postgresql`. The
socket file is `<dir>/.s.PGSQL.<port>`. Postgres does not use TLS over a
socket, so `sslmode` defaults to `disable` there and `require` is an
error.

Authentication: SCRAM-SHA-256 (the default since Postgres 14), md5 and
cleartext password. SCRAM checks that the **server** knows the password
too: a server that skips its proof, or sends a wrong one, is refused.

##### Timeouts and errors

A server-side error — a syntax error, a constraint violation — leaves the
connection usable. Anything that leaves the stream at an unknown point
breaks it: an I/O error, a protocol violation, a deadline. After a
`"timeout"` the server may still be running the query, so the driver asks
it to stop with a cancel request on a separate connection, from its own
task, and returns immediately. A broken connection only returns
`connection is broken: <why>`.

```slang
let r = pg.query(c, "INSERT INTO users (email) VALUES ($1)", [pg.arg_text(email)], dl);
guard let ok_ = r else let e = err_of(r) {
    if pg.sqlstate(e) == "23505" {     // unique_violation
        return respond(409, "email already registered");
    }
    return respond(500, "database error");
}
```

A `Conn` is safe to share between tasks (calls take turns), but a pool is
the better tool for that.

##### Streaming

`pg.stream` runs a query like `query` but hands the rows over one at a
time, so memory holds one row however large the result, and the server
is held back by TCP flow control rather than the client reading ahead:

```slang
let sr = pg.stream(c, "SELECT id, body FROM events ORDER BY id", [], dl);
guard let rows = sr else let e = err_of(sr) { return; }
while true {
    let nr = pg.next_row(c, rows, dl);
    guard let more = nr else let e = err_of(nr) { log.error(e); break; }
    if !more { break; }
    archive(pg.get_int(rows, 0, 0), pg.get_text(rows, 0, 1));   // always row 0
}
```

Each `next_row` replaces the row in `rows`, read at index 0; after the
last, `rows.affected` and `rows.tag` are set. A server error part way
through comes from `next_row`, after the rows before it. While a stream
is open the connection serves nothing else — other calls fail with
`connection is busy` — so read it to the end or call
`pg.stream_close(c, rows, dl)`. That asks the server to cancel the query,
waits until the request has been delivered (so it cannot hit a *later*
query on the same connection), then drops whatever was already sent. A
connection released to a pool mid-stream is closed.

| Function | Signature |
|---|---|
| `pg.stream(c, sql, args, deadline)` | `result[Rows, str]` |
| `pg.next_row(c, rows, deadline)` | `result[bool, str]` — `false` after the last row |
| `pg.stream_close(c, rows, deadline)` | `result[bool, str]` |

##### COPY

`COPY … FROM STDIN` bulk-loads data in COPY's text or CSV format, far
faster than one `INSERT` per row; `COPY … TO STDOUT` dumps it.

```slang
let n = pg.copy_from(c, "COPY users (id, email) FROM STDIN (FORMAT csv)",
                     to_bytes("1,a@example.com\n2,b@example.com\n"), dl);
let dump = pg.copy_to(c, "COPY users TO STDOUT (FORMAT csv)", dl);
```

| Function | Signature |
|---|---|
| `pg.copy_from(c, sql, data, deadline)` | `result[int, str]` — rows loaded |
| `pg.copy_in_start(c, sql, deadline)` | `result[bool, str]` |
| `pg.copy_in_send(c, data, deadline)` | `result[bool, str]` — any split, not only whole rows |
| `pg.copy_in_end(c, deadline)` | `result[int, str]` — rows loaded |
| `pg.copy_in_abort(c, reason, deadline)` | `result[bool, str]` — the server discards everything |
| `pg.copy_to(c, sql, deadline)` | `result[bytes, str]` — buffered, up to the 256 MiB limit |
| `pg.copy_out_start(c, sql, deadline)` | `result[bool, str]` |
| `pg.copy_out_next(c, deadline)` | `result[opt[bytes], str]` — a row's worth, `none` at the end |

The start/send/end and start/next forms stream, for data that should not
be held in memory at once. A bad row fails the whole COPY — the error
comes from `copy_in_end` (or `copy_from`) with its SQLSTATE, and nothing
was loaded. A COPY of the wrong direction is refused with `not a COPY …
FROM STDIN statement`, and a COPY through `query` or `exec` fails with a
message pointing here, the connection intact either way. Only the text
and CSV formats are meant: binary COPY data passes through untouched but
this package does not build or parse it.

##### LISTEN / NOTIFY

```slang
pg.listen(c, "jobs", dl);
while true {
    let wr = pg.wait_notification(c, until_of(time.mono() + 30000000000));
    guard let got = wr else let e = err_of(wr) { log.error(e); break; }
    guard let note = got else { continue; }        // 30s with nothing: none
    run_job(note.payload);
}
```

| Function | Signature |
|---|---|
| `pg.listen(c, channel, deadline)` / `pg.unlisten(c, channel, deadline)` | `result[bool, str]` — `unlisten(c, "*", dl)` for all |
| `pg.notify(c, channel, payload, deadline)` | `result[bool, str]` |
| `pg.wait_notification(c, deadline)` | `result[opt[Notification], str]` — `pid`, `channel`, `payload` |

Channel names are quoted as identifiers, so any name is safe to pass.
Notifications that arrive during other calls — even in the middle of a
query's result — are queued on the connection (up to 10,000;
`c.notes_dropped` counts any beyond that) and handed out oldest first.
**Reaching the deadline in `wait_notification` returns `none` and leaves
the connection usable**, unlike every other call: waiting is the point,
and a message cut off by the deadline is kept and completed by the next
wait. A server that ends the session while one waits (an administrator's
`pg_terminate_backend`, a restart) is an error with its SQLSTATE. Listen
on a connection of its own, not a pooled one: a pooled connection with a
notification waiting fails the pool's idle probe and is closed.

##### Limits

A driver trusts the server with its memory, so what it will buffer is
capped: one protocol message at 256 MiB, and one result at 256 MiB of
cell data, which is an error rather than an allocation. A SCRAM server may
ask for at most 1,000,000 PBKDF2 iterations (Postgres uses 4096).

Measured against Postgres 16 in Docker on the development Mac: 1M rows
of two columns in about 2.1s and 150MB, a single 20MB value in about
0.3s.

**Not supported:** named prepared statements, binary result format,
building or parsing binary COPY data, Kerberos/GSSAPI, SCRAM channel
binding (`SCRAM-SHA-256-PLUS`), multiple hosts in one url, and SASLprep
normalisation of non-ASCII passwords (an ASCII password is unaffected).

#### `regex`

Regular expressions on `str` or `bytes`, matched by slang's own
Thompson NFA — no external library, so a program that matches text
stays as dependency-free as a plain TCP one. `compile` returns an
opaque `rawptr` handle (freed with `regex.free`, like `net.tls_*` and
`sql`), and a bad pattern comes back as a descriptive
`result[rawptr, str]`.

**Matching is linear time, always.** There is no backtracking, so the
classic catastrophic pattern `(a+)+$` — which makes a backtracking
engine take exponential time on a hostile input — runs in the same
microseconds here as any other pattern. That is the point of choosing
this engine for a server language: patterns and subjects both arrive
from the network. The price is the RE2/Go one, and it is not
negotiable: **no backreferences and no lookaround**. Both require
backtracking; `(?=...)` and friends are a compile error, not a silent
mis-parse.

| Function | Signature |
|----------|-----------|
| `regex.compile(pat)` | `result[rawptr, str]` |
| `regex.free(re)` | — |
| `regex.groups(re)` | `int` — number of capture groups |
| `regex.is_match(re, s)` | `bool` — `s` is a `str` |
| `regex.is_match_bytes(re, b)` | `bool` — `b` is `bytes` |
| `regex.find(re, s)` / `find_bytes(re, b)` | `[int]` |
| `regex.find_at(re, s, from)` / `find_bytes_at(re, b, from)` | `[int]` |

`find` returns byte offsets as `[start, end, g1start, g1end, ...]`, or
an **empty list** when there is no match — so the result is GC-owned
and there is no match handle to leak. `find_at` starts at an offset,
which is how you walk every match.

```slang
import "regex";

let cr = regex.compile("(\\d{4})-(\\d{2})-(\\d{2})");
guard let re = cr else let e = err_of(cr) {
    log.error("bad pattern: " + e);   // e.g. "missing ) at offset 9"
    exit(1);
}

if regex.is_match(re, "due 2026-09-09") {
    let m = regex.find(re, "due 2026-09-09");
    println(to_str(m[0]) + ".." + to_str(m[1]));   // whole match: 4..14
    println(to_str(m[2]) + ".." + to_str(m[3]));   // year:        4..8
}
regex.free(re);
```

Supported: literals, `.`, classes `[a-z]` `[^...]` `[[:digit:]]`,
escapes `\d \D \w \W \s \S \b \B \A \z \xHH`, quantifiers
`* + ? {n} {n,} {n,m}` and their lazy `?` forms, groups `(...)` and
`(?:...)`, alternation `|`, anchors `^ $`. Matching is leftmost-first
(Perl-style priority), and `.` does not match `\n`.

Subjects are matched with an explicit length, so a `bytes` containing
NUL matches correctly rather than stopping at the NUL — and `\D`
matches a NUL byte like any other non-digit.

Bounds, so a hostile pattern can't exhaust memory or stack: 4096
compiled instructions, 100 nesting levels, 32 capture groups, and
`{n,m}` counts up to 1000. Each is a descriptive compile error, never
a crash.

A compiled regex is safe to share across tasks, and is meant to be:
it carries a small pool of reusable match buffers, so concurrent
matchers allocate nothing per match. Compiling is the expensive part
(it is also the only part that grows the task stack) — compile once,
match many times, ideally not once per request.

**Where this lands on speed.** Measured single-threaded on
`^(GET|POST|PUT) (/[a-z0-9/_-]*) HTTP/1\.([01])$` against a 26-byte
subject, 200k iterations:

| engine | matches/sec | on `(a+)+$` vs a hostile input |
|--------|-------------|-------------------------------|
| slang `regex` | ~721k | 2µs, correct answer |
| POSIX `regexec` | ~372k | fast here, but no limits |
| PCRE2 (interpreted) | ~2.4M | 0.2s, then gives up (`MATCHLIMIT`) |
| PCRE2 (JIT) | ~8.6M | same — JIT does not save it |

So: ~1.9x faster than libc's POSIX engine, and several times slower
than PCRE2 on *benign* input — PCRE2's interpreter and especially its
JIT are very good, and this is an honest gap. The trade is deliberate:
on adversarial input the ordering inverts completely, because linear
time is a guarantee here and a hope there. `is_match` is markedly
cheaper than `find` (it binds no capture slots at all), so prefer it
when you only need a yes/no. Matching scales with tasks — ~3.2M/sec
across 16.

Because matching never grows the task stack, regex is cheap to use per
connection: 600 concurrently-live tasks each matching and then parking
peak at **3.9MB RSS** — about 17x lighter than the same shape holding
`sql` connections (65.9MB), which does grow every task's stack.

#### `http2`

HTTP/2 framing and HPACK header compression (RFC 9113, RFC 7541),
written in slang — the frame codec is what the bitwise operators were
added for.

```slang
import "http2";

let f = http2.decode(buf, 0, 16384);        // one frame, bounds-checked
guard let fr = f else let e = err_of(f) { return; }

let d = http2.decoder_new(4096);            // per-connection HPACK state
let hr = http2.decode_block(d, fr.payload, 64);
guard let hs = hr else let e = err_of(hr) { return; }
for i in 0..len(hs) {
    println(hs[i].name + ": " + hs[i].value);
}
```

Frame layer: `decode` / `encode` / `header_bytes`, the reserved bit
masked off the stream id as the RFC requires, `strip_padding`, and the
common control frames (`settings_frame`, `settings_ack`, `ping_ack`,
`rst_stream`, `goaway`, `window_update`).

HPACK: prefix integers, string literals, the 61-entry static table, a
dynamic table with the RFC's +32-per-entry accounting and eviction, and
a **canonical Huffman decoder**. Header blocks decode through
`decode_block`; `encode_block` builds one.

The encoder is deliberately **stateless** — every field goes out as a
static-table index or a literal *without* indexing, and nothing is added
to a dynamic table on the encode side. That is conformant and it removes
a whole bug class: an encoder's dynamic table must stay in lockstep with
the peer's decoder table, and any drift silently corrupts every later
block on the connection.

Bounds against hostile peers: a frame longer than the advertised
`SETTINGS_MAX_FRAME_SIZE` is refused before allocating, `decode_block`
takes a `max_headers` cap (a small compressed block can otherwise expand
without limit), a Dynamic Table Size Update above the agreed maximum is
rejected, and NUL in a field name or value is the protocol error RFC
9113 §8.2.1 says it is. Huffman padding must be under 8 bits and all
ones, and EOS inside a string is refused.

Validated against **nghttp2** — the HPACK implementation curl and the
browser stacks use — in both directions: blocks it produces decode here,
and blocks produced here inflate there. Those fixtures are baked into
`tests/http2` as literals, so the suite needs no nghttp2 to run.

**Connection layer, with concurrent streams.** One task reads frames and
dispatches each request to its own `spawn`ed handler; every byte leaving
the connection goes through a single writer task fed by a `chan[bytes]`.
No mutex is involved, and none is needed: each channel message is a
complete frame sequence written with one `net.send`, so handlers cannot
interleave inside a frame, and a HEADERS block plus its CONTINUATIONs
stays contiguous by construction (RFC 9113 §6.2) rather than by careful
ordering. Frames for different streams interleave at frame boundaries,
which is what multiplexing means.

Measured: four 500ms requests multiplexed on one connection complete in
**0.53s**; served one at a time they would take about 2.0s.

The connection is addressed by a **`Transport`**, not a `link`. `link`
is move-only, so `spawn writer_task(c)` consumes it and the reader can
no longer use it — the two-task design is impossible with that type. A
`Transport` is freely copyable, and one reader plus one writer in
opposite directions on a socket is safe. `net.recv` also returns
`bytes` directly, so no byte-at-a-time copy sits on the read path.

A `Transport` is either a plain fd or a TLS handle, and everything above
it is identical either way:

```slang
http2.transport_fd(fd)     // h2c: cleartext, prior knowledge
http2.transport_tls(ssl)   // h2 over TLS, from net.tls_accept
```

```slang
fn handle(stream: i32, path: str, wch: chan[http2.WMsg]) {
    let hs: [http2.Header] = [];
    // The body goes over UNFRAMED: the writer owns the peer's windows,
    // so it decides how it is cut into DATA frames and when each may go.
    chan_send(wch, http2.response_msg(stream as int, "200", hs,
                                      to_bytes("hello")));
}

fn serve(fd: i32) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(32);
    let lim = http2.default_limits();
    spawn http2.writer_task(fd, wch, lim.write);

    guard let _p = http2.accept_preface(rd, fd, wch,
            until_of(time.mono() + lim.handshake)) else { return; }
    while true {
        let rr = http2.read_request(cn, rd, fd, wch, lim);
        guard let req = rr else let e = err_of(rr) {
            if http2.is_timeout(e) { /* slow peer; shed it */ }
            chan_close(wch);
            return;
        }
        spawn handle(req.stream as i32, req.path, wch);
    }
}
```

Verified against real `curl --http2-prior-knowledge`: GET, POST with a
body, five requests multiplexed on one connection, and a 64KB upload
that exercises DATA chunking and flow-control `WINDOW_UPDATE`.

##### Deadlines

Every read and every write is bounded, so a peer that connects and then
dribbles — or one that stops reading our responses — is disconnected
rather than left holding a task forever. `http2.Limits` carries four
separate budgets because they defend against four different peers:

| Budget | Covers |
|---|---|
| `handshake` | connect → valid client preface |
| `idle` | no request in flight, waiting for the next frame |
| `request` | first HEADERS octet → END_STREAM |
| `write` | one `writer_task` send |

`idle` is deliberately generous (2 minutes by default): an HTTP/2
connection sitting open with no streams is completely normal, and timing
it out aggressively breaks correct clients. `request` is the strict one
and applies to the request **as a whole** — it is never refreshed by
incoming frames, so dribbling DATA one octet at a time cannot extend it.
That distinction is the whole defence; a per-read timeout would never
fire against a slowloris, because every individual read makes progress.

`http2.is_timeout(e)` distinguishes a slow peer from a broken one, so a
server can answer the first with `GOAWAY` / `E_ENHANCE_YOUR_CALM`.
`tests/http2_deadline` runs all three attacker shapes — silent,
idle-after-handshake, and octet-at-a-time dribbling — against a server
with sub-second budgets and requires all three to be shed.

##### Flow control

DATA is flow-controlled at two levels, per-stream and per-connection
(RFC 9113 §5.2), and the server may not exceed either. Both windows live
in the writer task, because they are connection-wide state that the
**read** side replenishes (`WINDOW_UPDATE` arrives there) and the
**write** side spends — routing both into one task is what makes the
accounting correct without a lock.

A handler therefore hands over its body unframed and moves on. If the
peer's window is too small, the *body* waits in the writer's queue, not
the handler's task — a peer advertising a tiny window costs a queue
entry rather than a parked task.

`SETTINGS_INITIAL_WINDOW_SIZE` adjusts every open stream's window by the
delta rather than resetting it, and does not touch the connection window
(§6.9.2). A `WINDOW_UPDATE` that would push a window past 2³¹−1 is a
`FLOW_CONTROL_ERROR` and ends the connection with a `GOAWAY` rather than
being clamped.

`tests/http2_flow` drives both levels: a client advertising a 100-octet
stream window against a 5000-octet body, and a client with a large
stream window against a 100000-octet body where the default 65535
connection window is what binds. Each phase checks the exact octet the
server stops at, that it resumes for exactly the credit granted, and
that the resumed bytes carry the right content for their absolute offset
in the body.

##### TLS and ALPN

Browsers speak HTTP/2 **only** over TLS, and only when ALPN negotiates
it — there is no in-band upgrade in a browser. So h2c alone, however
conformant, cannot serve one.

The server advertises what it can speak, and then checks what was
actually chosen:

```slang
net.tls_ctx_alpn(sctx, "h2,http/1.1");     // offer both, h2 preferred
// ... net.tls_accept(lfd, sctx) -> ssl
if !http2.alpn_is_h2(net.tls_alpn(ssl)) {
    // the peer picked http/1.1; serve it as HTTP/1.1 or hang up
}
let t = http2.transport_tls(ssl);
```

Checking is not optional politeness. A server that offers `http/1.1`
must expect to get it, and feeding an HTTP/1.1 client into the frame
parser produces `bad connection preface` — true, but a poor explanation
of what went wrong.

`tests/http2_tls` runs both halves over a real handshake: h2 frames
across `SSL_read`/`SSL_write`, and an http/1.1-only client being
declined rather than misparsed.

##### Interop

Checked against **Go's `golang.org/x/net/http2`**, which shares no
ancestry with nghttp2 (curl's stack, and where the HPACK fixtures came
from) — agreement between two implementations that share code proves
less than it appears to. It covers a GET, a 50KB POST, a 200KB response
verified byte-for-byte against its absolute offset, and six concurrent
streams on one connection. Run it with `sh tests/http2_interop/run.sh`;
it skips cleanly without a Go toolchain.

##### Stream floods

The connection layer cannot cap concurrency by itself: it does not spawn
the handlers, *you* do. (slang has function values now, so handing it a
callback would compile — but a callback would only move the same
question inside, and the gate below is the answer either way.) So the
bound is a **gate** — a token channel you hold.
`gate_enter` takes a token and blocks when none are left, `gate_leave`
returns one, and that blocking is the backpressure: the reader stops
pulling frames while every slot is busy.

Without it, a peer that sends 1000 requests down one connection gets
1000 concurrent handler tasks — measured, against a
`SETTINGS_MAX_CONCURRENT_STREAMS` of 100 that we were advertising and
not keeping. Advertising a limit you do not enforce is worse than
advertising none, because peers size their behaviour by it.

`gate_drain` also makes shutdown safe. Closing the writer channel while
handlers are still in flight panics them with *send on closed channel*,
and draining is what knows when none are left.

**The one rule: `gate_leave` must run on every path out of a handler**,
error returns included. A lost token permanently shrinks that
connection's capacity; losing all of them wedges that one connection —
bounded and visible, not a crash, but not something to leave in.

Separately, `RST_STREAM` is counted. A peer that opens a stream and
cancels it immediately (CVE-2023-44487, *Rapid Reset*) never looks
concurrent, so a cap alone never trips; after a burst of 100 free
cancellations, a peer whose resets outnumber half of what it opened
ends the connection. Cancelling is legitimate — a browser navigating
away resets its in-flight streams — so the burst and the ratio are both
needed to tell a normal client from a flood.

`tests/http2_flood` drives both shapes, resetting and not, and fails if
either exceeds the cap.

##### Known gaps

`PRIORITY` is validated but not acted on: it is deprecated in RFC 9113
§5.3.2, so ignoring the prioritisation is conformant, but a malformed
frame is still rejected as the connection error it is (§6.3) rather than
waved through to desync the stream. No browser has been run against the
TLS path yet — the machinery is there and tested against slang's own
client, but a real browser is different evidence.

#### `strings`

Search, trim, case, split and join on `str`. The package cannot be named
`str` because that token is the type — the same reason Go calls its own
`strings`.

```slang
import "strings";

strings.find("hello world", "world");   // 6, or -1
strings.rfind("a/b/c", "/");            // 3
strings.contains("hello", "ell");
strings.has_prefix("hello", "he");
strings.has_suffix("hello", "lo");
strings.count("a,b,c", ",");            // 2

strings.trim("  hi \r\n");              // "hi" (space/tab/CR/LF)
strings.trim_start(s); strings.trim_end(s);
strings.to_upper("hi"); strings.to_lower("HI");   // ASCII only

strings.slice("hello", 1, 3);           // "el"
strings.slice("hello", -3, 5);          // "llo" — negative counts back
strings.repeat("ab", 3);                // "ababab"
strings.replace("a,b,c", ",", " | ");

strings.split("a,b,,c", ",");           // ["a", "b", "", "c"]
strings.join(parts, ",");               // the inverse of split

strings.from_float(0.1 + 0.2);          // "0.30000000000000004"
```

`to_str` prints a float with six significant digits, which suits output
and loses information: `to_str(123456789.125)` is `"1.23457e+08"`.
`from_float` returns the shortest text that `to_float` reads back as
exactly the same number — use it whenever a float is stored or sent.
NaN and the infinities come out as `NaN`, `Infinity` and `-Infinity`.

This is a compiler-provided native package, and it has to be: `str`
supports `len`, `+` and `==` and nothing else — it cannot be indexed or
sliced — so none of it could be written in slang without converting to
`bytes` and back on every call. `byteutil` covers the `bytes` side.

Three behaviours worth knowing:

- **Indices are byte offsets and the case operations are ASCII-only.**
  `str` is UTF-8 bytes; doing better means shipping a Unicode table and
  a normalisation policy, which is a different project. Treat these as
  byte operations, because that is what they are.
- **`slice` clamps rather than panics.** Slicing is how you narrow a
  string you just searched, and a `find` that returned -1 on the line
  above should not turn the next line into a crash. A negative index
  counts from the end.
- **`split` and `join` are exact inverses.** Adjacent separators produce
  empty elements, so the result always has `count(s, sep) + 1` elements
  and `join(split(s, sep), sep) == s` for any non-empty separator. An
  empty separator splits into single bytes.

#### `encoding`

Hex, base64, base64url, percent-encoding and query strings — the four
ways arbitrary bytes travel through a channel that only carries text.

```slang
import "encoding";

encoding.hex_encode(crypto.sha256(b"abc"));   // "ba7816bf8f01cfea..."
encoding.base64_encode(b"aladdin:opensesame");// HTTP Basic credentials
encoding.base64url_encode(sig);               // a JWT segment: -_ alphabet, no padding
encoding.url_encode("a b&c");                 // "a%20b%26c"
encoding.form_encode("a b&c");                // "a+b%26c"

let q = "/search?q=hello+world&page=2";
guard let term = encoding.query_get(q, "q") else { return; }   // "hello world"
encoding.query_keys(q);                                        // ["q", "page"]
```

| Function | Signature |
|---|---|
| `encoding.hex_encode` | `(b: bytes) -> str` |
| `encoding.hex_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.base64_encode` | `(b: bytes) -> str` |
| `encoding.base64_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.base64url_encode` | `(b: bytes) -> str` |
| `encoding.base64url_decode` | `(s: str) -> result[bytes, str]` |
| `encoding.url_encode` | `(s: str) -> str` |
| `encoding.url_decode` | `(s: str) -> result[str, str]` |
| `encoding.form_encode` | `(s: str) -> str` |
| `encoding.form_decode` | `(s: str) -> result[str, str]` |
| `encoding.query_get` | `(url: str, key: str) -> opt[str]` |
| `encoding.query_keys` | `(url: str) -> [str]` |

Like `regex`, `strings` and `os` — and unlike `crypto` and `sql` — this
is pure computation, so importing it adds no link flag.

Four things worth knowing:

- **Encoders are infallible; decoders are not.** Any byte string has a
  hex form, so `hex_encode` returns a bare `str`. Decoding takes input
  the program did not produce — a query string, a header, a token — so
  every decoder returns `result[_, str]`, and the message names the byte
  offset it gave up at. "invalid base64" about a 400-character token is
  not a diagnosis.

- **`url_*` and `form_*` differ only in `+`, and that is exactly why
  they have separate names.** In `application/x-www-form-urlencoded` a
  space is `+`; in a URI it is `%20`. Decoding a form body with
  `url_decode` leaves literal `+` where every space belongs, and nothing
  reports it — the failure surfaces later as a lookup that does not
  match. One function with a flag would make that the default mistake.

- **`%00` is an error, not a truncation.** `url_decode` and
  `form_decode` return `str`, which is NUL-terminated, so a decoded zero
  byte would silently cut the value short. They refuse it and say so.
  `hex_decode` and `base64_decode` return `bytes`, which carries an
  explicit length, so a zero byte there is ordinary data and round-trips
  exactly.

- **`query_get` is `opt`, and `query_keys` is a list.** A missing
  parameter is absent data, not bad data, so it is `opt[str]` — the
  README rule above. Keys come back as a list rather than a map because
  a query may legally repeat a key and a map would have to drop one,
  the same reason `os.environ` is a list. `query_get` takes the first
  value; a bare `?debug` is present with an empty value, not absent.

Percent-escapes are emitted uppercase (RFC 3986 §2.1) and hex digests
lowercase (what `sha256sum`, git and every API that returns one use).
Both decoders accept either case.

#### `httpc`

An HTTP/1.1 **client** — the mirror of `http`, which serves. Speaks
`http://` and `https://`, follows redirects, and decodes chunked
responses.

```slang
import "httpc";
import "time";

let dl = until_of(time.mono() + 5000000000);   // 5s for the whole request

let r = httpc.get("https://api.example.com/users?id=1", dl);
guard let resp = r else let e = err_of(r) {
    log.error("request failed: " + e);
    return;
}
println(to_str(resp.status) + " " + to_str(len(resp.body)) + " bytes");

// a POST, and a header the request owns
let req = httpc.new_request("POST", "https://api.example.com/users");
req.headers["Authorization"] = "Bearer " + token;
req.body = to_bytes(payload);
let r2 = httpc.send(req, dl);
```

| Function | Signature |
|---|---|
| `httpc.get` | `(url: str, deadline: until) -> result[Response, str]` |
| `httpc.head` | `(url: str, deadline: until) -> result[Response, str]` |
| `httpc.post` | `(url: str, content_type: str, body: bytes, deadline: until) -> result[Response, str]` |
| `httpc.send` | `(req: Request, deadline: until) -> result[Response, str]` |
| `httpc.new_request` | `(method: str, url: str) -> Request` |
| `httpc.header` | `(r: Response, name: str) -> opt[str]` |
| `httpc.parse_url` | `(url: str) -> result[Url, str]` |
| `httpc.new_client` | `() -> Client` |
| `httpc.client_get` / `client_head` | `(c: Client, url: str, deadline: until) -> result[Response, str]` |
| `httpc.client_post` | `(c: Client, url: str, content_type: str, body: bytes, deadline: until) -> result[Response, str]` |
| `httpc.client_send` | `(c: Client, req: Request, deadline: until) -> result[Response, str]` |
| `httpc.idle_count` | `(c: Client) -> int` |
| `httpc.close_idle` | `(c: Client)` |
| `httpc.enable_cookies` / `clear_cookies` | `(c: Client)` |
| `httpc.set_cookie` | `(c: Client, url: str, set_cookie_line: str)` |
| `httpc.cookies` | `(c: Client, url: str) -> [Cookie]` |
| `httpc.parse_cookie_date` | `(s: str) -> int` (unix ns, or -1) |

`Request` carries `method`, `url`, `headers`, `body`, `max_redirects`
(default 5, `0` disables following) and `ca_path` (`""` = the system
trust store). `Response` carries `status`, `status_text`, `headers`,
`body` and `url` — the last being the URL that actually answered, which
after a redirect is not the one you asked for.

Separate from `http` rather than folded into it because `http` imports
only `byteutil`, while a client necessarily imports `net` — and for a
TLS request that drags `-lssl`/`-lcrypto` onto the link line of every
program that merely wanted to serve HTTP.

Five things worth knowing:

- **A 404 is a `Response`, not an `err`.** The `result` is about whether
  the exchange happened — DNS, connect, TLS, framing. A server that
  answers "no" answered. Collapsing the two would make a 404 and a
  connection refusal indistinguishable at the call site, and they need
  different handling.

- **Certificates are verified, and there is no flag to stop that.**
  Verified against `expired`, `self-signed` and `wrong.host` on
  badssl.com: all three are refused, a valid one is accepted. For an
  internal service signed by a private CA, set `ca_path` to that
  bundle — the answer is a different trust anchor, never a disabled
  check.

- **Credentials do not survive a cross-origin redirect.** `Authorization`,
  `Cookie` and `Proxy-Authorization` are dropped when the scheme, host
  or port changes, because the server that sent the `Location` chose
  where it points, and that is exactly how a token gets exfiltrated.
  Same-origin redirects keep them.

- **Redirect method rules follow browsers, not the RFC's original
  wording.** 303 always becomes GET; 301 and 302 after a POST also
  become GET and drop the body, which is what every browser and curl do
  and therefore what servers expect. 307 and 308 exist to preserve the
  method, so they do. A redirect loop stops at `max_redirects` and hands
  back the last 3xx rather than spinning.

- **Everything a server can make you allocate has a ceiling** — 64 KiB
  of headers, 32 MiB of body, and a bounded chunk-size line. A client
  talks to servers it does not control, so a buffer sized on their
  say-so is a denial of service arriving through an ordinary call.

##### Connection pooling

`httpc.get` and friends are one-shot: a connection per request, closed
afterwards, with `Connection: close` sent so the server does not hold
it open. A **`Client`** keeps idle connections and reuses them — up to
`max_idle_per_host` per origin (default 4), for `idle_timeout`
nanoseconds (default 30s), and 64 across all origins.

```slang
let c = httpc.new_client();          // share one across tasks
let r = httpc.client_get(c, "https://api.example.com/v1/items", dl);
```

The one-shot functions ARE a client — one that keeps nothing — so
framing, redirects, decompression and every security rule are one code
path, and cannot drift between the two.

A `Client` is safe to share between tasks: the pool is behind a
`mutex`. Its `dials` and `reuses` fields and `httpc.idle_count(c)` make
its behaviour checkable rather than asserted.

- **Every pooled connection is probed before use.** Servers close idle
  connections on their own timers (Node's default is 5 seconds), and a
  request written onto one fails indistinguishably from the server
  failing mid-request. The probe is `net.idle_alive` — one non-blocking
  `MSG_PEEK`, no latency, nothing consumed.
- **A dropped request is retried once, and only if it is idempotent.**
  If a reused connection dies before a single response byte arrives,
  GET/HEAD/PUT/DELETE/OPTIONS/TRACE retry on a fresh connection. POST
  does not: it may already have been acted on, and sending it twice
  could charge a card twice. The probe is what protects a POST; the
  retry is the backstop for the race between probe and write.
- **The pool key includes `ca_path`.** A connection verified against
  one trust anchor is never handed to a request that asked for another —
  tested over real TLS: the second request, demanding a different CA,
  fails verification instead of riding the verified connection.
- **Reuse requires a clean end:** HTTP/1.1, no `Connection: close`, a
  framed body read exactly, and nothing left over. A body delimited by
  the connection closing is never reused.

Client operations are handle-first package functions — `client_get(c,
...)`, the same idiom as `sql.exec(db, ...)` — rather than methods,
because a method cannot currently share a name with a package function
(`impl Client { fn get }` collides with `httpc.get`).

##### Decompression

Requests carry `Accept-Encoding: gzip, deflate` and responses are
decoded transparently — **unless the caller set `Accept-Encoding`
themselves**, in which case the body comes back exactly as sent. A
caller who asked for gzip wants the gzip (to proxy it, to store it), and
decompressing behind their back would hand them something else.

- The decoded size is held to the same 32 MiB ceiling as a plain body.
  Without that the wire limit would mean nothing: 32 MiB of gzip holds
  tens of gigabytes.
- `deflate` is tried as zlib (what RFC 9110 says it means) and then as
  raw DEFLATE (what a real share of servers send under that name).
- After decoding, `Content-Encoding` and `Content-Length` are removed:
  both describe the bytes that crossed the wire, not the body in hand.
- An encoding the client did not ask for and cannot read is left alone,
  header included — visible, not silent.

##### Cookies

RFC 6265, with RFC 6265bis's rules for `Secure` and the `__Secure-` /
`__Host-` prefixes. **Off by default** — the opposite of a browser, on
purpose:

```slang
let c = httpc.new_client();
httpc.enable_cookies(c);             // this Client now acts as ONE identity
```

A browser's jar belongs to one person. A server's `Client` is usually
shared, one per process, used on behalf of every user it serves, and a
jar there would store user A's session cookie and send it on user B's
request. Go's `http.Client` makes the same call. Turn the jar on for a
`Client` that represents one identity: a scraper, a test driver, an
integration with a login-based API.

- **Cookies are applied per redirect hop.** A cookie set by a `302` reaches
  the page it points to, which is how nearly every login works; a
  redirect to another host carries that host's cookies, not the first
  one's.
- **Refused:** a `Secure` cookie from `http://` (a network attacker could
  otherwise overwrite an https session); a `Domain` the host does not
  belong to; a bare single-label `Domain` such as `com`; a `Domain` that
  is part of an IP address; `__Host-` without `Secure`, or with a
  `Domain`, or with a path other than `/`; a line with no `=`; anything
  over 4096 bytes. `Secure` cookies are only ever sent over https.
- **Scoping:** a cookie set without `Domain` goes back to *exactly* that
  host (`127.0.0.1` and `localhost` are different scopes); `Path=/p`
  matches `/p` and `/p/x` but not `/pathx`. Longer paths are sent first.
- **Expiry:** `Max-Age` wins over `Expires` whatever order they arrive
  in, and a past date or `Max-Age=0` deletes. Dates are parsed with RFC
  6265's lenient algorithm, since servers send RFC 1123, RFC 850 with
  two-digit years and asctime alike; `httpc.parse_cookie_date` exposes it.
- **Limits:** 50 cookies per domain and 3000 in total, evicting the oldest,
  so a server flooding the jar pushes out its own cookies first.
- **`Response.set_cookies`** holds each `Set-Cookie` line separately. Use
  it rather than `headers["set-cookie"]`: repeated headers are joined
  with `", "`, and an `Expires` date contains a comma, so two joined
  lines cannot be split apart again.

**No public-suffix list is applied**, and the consequence is stated
rather than left to be discovered: a response from `a.example.co.uk` may
set a cookie for `Domain=co.uk`, and this jar will then send it to every
`*.co.uk` host. Nothing in slang ships a suffix list, and an embedded
copy goes stale. The bare-TLD rule stops `Domain=com`; it does not stop
that case.

**Not done, deliberately:** no HTTP/2 client, no multipart bodies, no
proxy support, no public-suffix list.

#### `compress`

gzip, zlib and raw DEFLATE, over zlib (`-lz`, added only when a program
imports `compress`).

```slang
import "compress";

let gr = compress.gzip(body);
guard let gz = gr else let e = err_of(gr) { log.error(e); return; }

// decompression ALWAYS takes a ceiling -- see below
let ur = compress.gunzip(payload, 4194304);        // 4 MiB
guard let plain = ur else let e = err_of(ur) {
    log.warn("rejected: " + e);                     // names the limit
    return;
}
```

| Function | Signature |
|---|---|
| `compress.gzip` | `(b: bytes) -> result[bytes, str]` |
| `compress.gzip_level` | `(b: bytes, level: int) -> result[bytes, str]` |
| `compress.gunzip` | `(b: bytes, max_out: int) -> result[bytes, str]` |
| `compress.deflate` | `(b: bytes) -> result[bytes, str]` |
| `compress.inflate` | `(b: bytes, max_out: int) -> result[bytes, str]` |
| `compress.deflate_raw` | `(b: bytes) -> result[bytes, str]` |
| `compress.inflate_raw` | `(b: bytes, max_out: int) -> result[bytes, str]` |

**Decompression takes a mandatory output limit.** `max_out` is a
required argument, not an optional one with a generous default. The
expansion ratio is unbounded — 65 KB of gzip holds 64 MB of output, and
that ratio goes much further — so a program that decompresses anything
it did not itself produce is one hostile input away from the OOM killer.
The ceiling is enforced *before* the allocation that would cross it, not
by inspecting the result afterwards: rejecting a 64 MB bomb was measured
at 3.9 MB peak RSS against a 0.86 MB baseline. A default here would be a
number nobody chose, applied at every call site that never thought about
it.

**Three containers, because HTTP needs all three.** They are the same
compressed bits under different headers: `gzip` (RFC 1952) is what
servers send; `zlib` (RFC 1950) is what the `deflate` content-coding is
*supposed* to mean; raw (RFC 1951, no header) is what the servers that
get it wrong send instead — which is why `inflate_raw` exists rather
than being a purist's omission. They are not interchangeable, and each
decoder says so rather than producing garbage.

**Backed by zlib rather than written here**, unlike `regex`. That
package was written in-house because a backtracking engine has a
catastrophic input class and being immune to it by construction was the
point. DEFLATE has no equivalent argument — what it has is thirty years
of hostile input and a reference implementation on every platform slang
targets. A hand-written inflate would be a memory-safety surface with no
upside, since every bug in one is a buffer overrun driven by
attacker-controlled input.

#### `byteutil`

Search, trim, and split on the `bytes` type — no new syntax. The
package cannot be named `bytes` because that token is the type.

```slang
import "byteutil";

byteutil.find(b"hello", 0, 108);     // 2, or -1
byteutil.has_prefix(b"hello", b"he");
byteutil.has_suffix(b"hello", b"lo");
byteutil.trim(b"  hi\r\n");          // b"hi" (space/tab/CR/LF)
byteutil.split(b"a,b", 44);          // [b"a", b"b"]
```

#### `http`

HTTP/1.1 over `link` / `wire` / `until` / `fault`. Parse a request
from `bytes`, or `read` from a connection into a caller-sized `wire`
(the max request size). `read` takes the unconsumed prefix length and
returns `Incoming` with leftover compacted to the front of the wire,
so one connection can carry many requests. `write` serializes a
`Response` through an arena. Headers are stored lowercased;
`header(req, name)` looks up case-insensitively. A body is framed by
`Content-Length` or by `Transfer-Encoding: chunked` (chunk extensions
ignored, trailers read and discarded). `wants_close` follows HTTP/1.1
keep-alive (and HTTP/1.0 close-by-default).

Framing decides where a request ENDS, so it is a security boundary: if a
proxy in front and this server frame the same bytes differently, the
leftover is read as a second request the proxy never saw (request
smuggling). `read` and `parse` therefore refuse, rather than guess at:

- `Transfer-Encoding` together with `Content-Length`, or in an HTTP/1.0
  request;
- any coding but exactly `chunked` (no lists such as `gzip, chunked`);
- a repeated `Content-Length` or `Transfer-Encoding` header;
- a `Content-Length` longer than 18 digits, or not all digits;
- chunk-size lines over 1KB, sizes over 15 hex digits, bare LFs, chunk data
  not followed by CRLF, or trailers over 8KB.

**After `read` returns an error, close the connection** (the examples all
`return`). The error means this server could not tell where the request
ended, so it cannot tell where the next one begins either.

```slang
import "http";

fn serve(c: link) {
    let ra = arena_new(16384);
    let sa = arena_new(16384);
    let buf = ra.wire(8192);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, http.ok_text(got.req.path), &mut sa,
                            until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) { return; }
        filled = got.filled;
    }
}
```

See `examples/httpd/` for a listener loop on this package.

This works because every `spawn`ed thread has `SIGTERM`/`SIGINT`
blocked in its own signal mask from birth (inherited at creation,
restored in the spawning thread right after) — so the OS can only
ever pick the main thread to run the handler, which is what lets the
main thread's blocked `accept()` call reliably observe the
interruption instead of the signal silently landing on some unrelated
connection's worker thread mid-request. There's a narrow startup race
inherent to this: a signal that arrives in the brief window before
`main()` installs the handler gets the OS's default disposition
(immediate termination) instead of graceful handling, same as any
signal-handling program.

## Concurrency

`spawn` submits a function as an `sl_task` on the M:N worker pool
(sized `ncpu`); `chan[T]` is a bounded, park-aware queue.
Blocking-looking code stays blocking-looking — `net.accept`,
`net.recv`, `time.sleep`, and `chan_send`/`chan_recv` park the task
and return the OS thread to the pool. There is no colored-function
split. TLS handshake and I/O park on the same reactor as TCP
  (`SSL_ERROR_WANT_READ`/`WANT_WRITE`). DNS (`getaddrinfo`) runs on
  a dedicated thread; the dialing task parks until it finishes.

```slang
fn worker(id: i32, results: chan[i32]) {
    chan_send(results, (id * 10) as i32);
}

let results: chan[i32] = make_chan(3);
spawn worker(1, results);
spawn worker(2, results);
spawn worker(3, results);

let mut_sum = 0;
for i in 0..3 {
    let v = chan_recv(results);       // blocks until a value or close
    guard let x = v else {
        println("channel closed early");
        exit(1);
    }
    mut_sum = mut_sum + x;
}
println(mut_sum); // 60

chan_close(results);
chan_recv(results) ?? -1;  // none after close+drain -> -1
```

- **`spawn f(args...);`** evaluates every argument in the spawning
  context (no closures — nothing is captured implicitly) and submits
  `f` as a growable-stack task on the striped run queues (16 hashed
  stripes with work-stealing, plus a global doorbell for sleepers).
  `f` may be a plain top-level function, an `extern fn`, or a
  **function value** (`spawn w(1, out);`, `spawn job.run(x);`) — not a
  method and not a builtin. There is no `spawn` on `net.*`/`time.*`
  calls directly; wrap the native call in a plain function and spawn
  that instead.
  As a statement, the result is discarded. As an expression,
  `let h = spawn f(...)` has type `join[T]` when `f` returns `T`.
  `join_wait(h) -> result[T, str]` parks until `f` finishes; a panic
  in that task is `err`, not process death.
- **`chan[T]`**, built with `make_chan(capacity)` (element type
  inferred from an annotated binding, same as `none`): `chan_send(ch,
  v)` blocks while full, `chan_recv(ch) -> opt[T]` blocks while empty
  and returns `none` once the channel is closed and drained (instead
  of inventing a second return-value convention, it reuses `opt[T]`),
  `chan_close(ch)` wakes every blocked sender/receiver. Sending on a
  closed channel is a checked runtime error, not undefined behavior.
- **`select`** waits on several channels at once and runs the arm that
  becomes ready first:

  ```slang
  while running {
      select {
          case let job = chan_recv(work) {
              handle(job ?? 0);
          }
          case let q = chan_recv(quit) {
              running = false;
          }
          default {
              // optional: runs when no arm is ready, instead of blocking
          }
      }
  }
  ```

  A `case let v = chan_recv(ch)` arm binds `v` to `opt[T]` for that
  arm's body, exactly as a plain `chan_recv` would — `none` means the
  channel is closed and drained. A `case chan_send(ch, v)` arm is ready
  when the channel has buffer space and binds nothing. Sending on a
  closed channel from a send arm is the same checked runtime error as
  `chan_send` itself.

  Every arm's channel expression (and a send arm's value) is evaluated
  **once**, before the select blocks. With no `default` and nothing ever
  ready, `select` parks forever — the same as `chan_recv` on a channel
  nobody sends to. Which arm wins when several are ready is not
  specified: polling starts at a rotating offset, so a busy first
  channel cannot starve the later arms.

  **A closed channel is permanently ready.** Its recv arm fires
  immediately and forever, with `none`. This is the same as Go, but Go
  lets you disable an arm by setting its channel to `nil` and slang has
  no nil channel — so a loop that keeps selecting on a closed channel
  will spin. Structure the loop to stop instead (count the items you
  expect, or take the close as the exit condition), as
  `tests/select/main.sl` does.

- **`mutex`**, built with `make_mutex()`: `mutex_lock(m)` /
  `mutex_unlock(m)` around whatever the lock protects, and
  `mutex_trylock(m) -> bool` when you would rather do something else
  than wait. A contended lock parks the *task*, not the worker thread,
  so a handler waiting its turn costs a queue slot rather than one of
  the pool's OS threads — the same reason `chan` parks. A `mutex` is a
  handle: copying the binding aliases the same lock.

  Two things are checked rather than left to chance, because both
  otherwise present as something other than what they are:

  - Locking a mutex this task already holds is a runtime error.
    slang's mutexes are **not** recursive, and without the check the
    task would park forever on itself — a hang is the least useful
    diagnosis available.
  - Unlocking a mutex this task does not hold is a runtime error. The
    alternative is corruption in whatever the lock was protecting,
    discovered much later and somewhere else.

  There is no scope guard (no `defer`, no closures), so an early
  `return` between lock and unlock leaks the lock. Keep the critical
  section small enough to see both ends of it at once:

  ```slang
  gc struct State { tasks: [Task], next_id: int, lock: mutex }

  fn create(st: State, title: str) -> Task {
      mutex_lock(st.lock);
      let t = Task { id: st.next_id, title: title, done: false };
      st.next_id = st.next_id + 1;
      push(st.tasks, t);
      mutex_unlock(st.lock);
      return t;                 // unlock BEFORE the return, every path
  }
  ```

  A mutex is not always the right tool. `demo/samplex/server.sl` uses
  one because many handlers touch one list. `stdlib/http2/conn.sl`
  deliberately does not: its single writer task also guarantees that a
  HEADERS block and its CONTINUATION frames are never split by another
  frame, which a lock would not give.
- **Failure isolation**: a runtime error (an out-of-bounds index, a
  missing map key, integer division by zero, ...) inside a spawned
  task ends *that task* — printed to stderr as `task panicked: ...` —
  not the whole process. The same error in the main task still ends
  the process, same as today; there is no isolation boundary around
  top-level code. `exit(code)` always ends the whole process
  regardless of which task calls it — it means what it always means.

**What this does not give you.** There is no ownership/borrow checker
here — slang's answer to "many tasks, no data races" is thread
isolation plus channels for the values that need to move between
tasks, not a type system that forbids sharing mutable state. Passing
a struct, list, or map into a spawned task and mutating it from more
than one task concurrently is exactly as unsafe as it is in Go or
Java: nothing currently stops you, so don't — `mutex` is there when
you need it. `join_wait` waits for one spawned task.
`proc.active_tasks()` (see the `proc` section) is the aggregate count
of everything currently in flight,
useful for draining on shutdown but not for waiting on one task in
particular.

## Testing

Tests live next to the code they test, Go-style: files named `*_test.sl`
hold functions named `test_*`, taking nothing and returning nothing, which
fail through `assert` or `panic`.

```slang
// calc_test.sl
fn test_add() {
    assert(add(2, 3) == 5);
}

fn test_clamp() {
    let got = clamp(15, 0, 10);       // private functions are reachable:
    assert(got == 10, "got " + to_str(got));   // tests are in the package
}
```

```sh
slangc test                 # the package in the current directory
slangc test path/to/pkg     # another one
slangc test --run clamp     # only tests whose name contains "clamp"
```

```
ok   test_add (52us)
FAIL test_clamp (30us)
     got 15 at calc.test_clamp:7
FAIL: 1 of 2 failed (190us)
```

- **Each test runs in its own task**, so a failing test is reported with
  its message and location and the run carries on. Tests run one at a
  time, so output stays in order.
- **`*_test.sl` files never reach a normal build.** Test helpers can't leak
  into a program, and a test file's imports can't add link flags to one.
- **Programs are testable too.** When the package is a program rather than
  a library, `slangc test` does not run its top-level statements: the test
  runner is `main`. Functions, structs and methods are all there.
- Exit status is 0 when every test passes, 1 when any fails, and 2 when the
  tests cannot be run (a `test_` function with parameters, say). A package
  with no test files exits 0 and says so.
- `--keep` keeps the generated runner and prints where it is.

## C interop

slang already transpiles to C and shells out to `cc`, so calling into
existing C libraries is a thin layer on top of that, not a new
ecosystem: declare the C function's signature, tell the linker which
library to pull in, and call it like any other function.

```slang
link "sqlite3";   // -> '-lsqlite3' on the final cc invocation

extern fn sqlite3_libversion() -> str;
println(sqlite3_libversion());
```

- **`extern fn name(params) -> ret;`** declares a C function with no
  body — it calls the real, unmangled C symbol directly. `int`,
  `i8..u64`, `f32`, `float`, `bool`, and `str` already share their C
  representation, so they marshal for free. `bytes` does not
  auto-decay (it is a boxed struct internally); pass `bytes_ptr(b)`
  and `len(b)` as two separate `rawptr`/`i32` arguments instead of
  inventing implicit multi-argument expansion for one type.
- **`rawptr`** is an opaque foreign pointer (`void *`) for handles a C
  library owns, like `sqlite3*` or `FILE*`. It can be passed around
  and compared against **`nullptr`**, nothing else — no arithmetic,
  no field access, no dereference. A `rawptr` is never GC-owned: if a
  C library allocated it, free it through another `extern fn`, not by
  letting it go out of scope.
- **`link "name";`** is a top-level directive (parsed like `import`)
  that adds `-lname` to the `cc` invocation. Non-default search paths
  go through `LIBRARY_PATH`/`CPATH`, which `cc` already honors — no
  separate slangc flag for that.
- Only types with an unambiguous C representation may cross an
  `extern fn` boundary: numeric types, `bool`, `str`, `bytes`,
  `rawptr`, and `ptr[T]` of those types. GC'd containers (`opt`,
  `result`, `map`, structs, arrays) are rejected at compile time —
  their internal layout isn't something arbitrary C code should ever
  see.

**C++ is out of scope for the compiler itself.** There's no
name-mangling/ABI support planned. Wrap the C++ library in your own
`extern "C"` shim (catching every exception at that boundary — an
uncaught C++ exception unwinding into C is undefined behavior) and
consume the shim exactly like any other C library above.

**Safety notes:**

- The collector is precise for slang values rooted at safepoints. A
  slang value whose *only* remaining reference lives in memory the GC
  cannot scan (possible with some C libraries) can be collected while
  C still holds it. Keep a live slang-side reference for the duration
  of any call that retains a pointer beyond that call.
- Callback function pointers — C calling back into slang — aren't
  supported yet.
- **Deep C libraries and the task stack.** A task's stack starts at
  8KB and grows only at slang checkpoints, which C code has none of.
  A C function that recurses or holds large locals can therefore run
  off the end of the stack buffer and corrupt the heap — a silent
  `abort()` from `malloc`, not a clean crash. The compiler-provided
  packages that wrap deep libraries grow the stack up front
  (`sl_rt_need_stack`, used by `net.tls_*` for OpenSSL and by `sql`
  for SQLite); an `extern fn` into a comparably deep library has no
  such protection, so keep C-side recursion and stack buffers small.

See `tests/ffi/` for a complete example: a small hand-written C
fixture library (`lib.c`) built as a static archive, linked and called
from a slang program exercising `extern fn`, `link`, `rawptr`,
`bytes_ptr`, and `nullptr`.

## Packages (Go/Odin style)

A **package is a directory**: every `.sl` file inside it is compiled
together into one shared namespace, as if concatenated. Import paths
resolve to a directory next to the importer, then a native package,
then `stdlib/<path>`, then a pin in `slang.project`.

```slang
import "geometry";   // binds the name "geometry" in this file's scope
import "a/b/util";   // nested paths bind as "util"
import "geometry" as geo;   // optional alias; call as geo.area(...)

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

External packages are pinned in `slang.project` (walked up from the
entry file). Imports stay short. `slang.lock` holds content hashes
and is written by `slangc get`, never by hand.

```
name myserver
version 0.1.0

pkg foo git https://github.com/dolphlabs/foo tag v0.1.0
```

```slang
import "foo";
```

`slangc get` clones each `pkg` line into `$SLANG_CACHE/pkg/<name>/<hash>`
(`~/.cache/slang` if unset). If a fetched package has its own
`slang.project`, those pins are fetched too and recorded only in
`slang.lock`. Compile does not hit the network. A missing lock, missing
cache, or hash mismatch is an error. Same short name at two git/tag
pairs is an error.

## How it works

```
main.sl ──loader──> packages ──lexer/parser──> ASTs ──codegen──> main.gen.c ──cc──> ./main
```

1. **Loader** (`src/loader.c`) — resolves imports (local directory,
   native package, stdlib, then `slang.project` pins), scans package directories for `.sl`
   files (in deterministic sorted order), merges them per package, and
   detects cycles via canonical paths.
2. **Lexer** (`src/lexer.c`) — tokenizes source into identifiers,
   keywords, literals, and operators.
3. **Parser** (`src/parser.c`) — recursive-descent parser producing an
   AST (`src/ast.h`).
4. **Code generator** (`src/codegen/`) — walks the ASTs, performs type
   inference and semantic checks (including `pub` enforcement), and
   emits readable C. The runtime in `runtime/` (GC, scheduler, pool,
   containers, native packages) is real C, spliced into every
   generated file so the binary stays self-contained. Split by
   concern: `core.c`, `infer.c`, `expr.c`/`stmt.c`, `program.c`,
   `liveness.c` (GC safepoint roots), and `native.c` (`NatSig`
   dispatch). `internal.h` holds the shared `CG` struct.

   Native-package *signatures* live under `src/codegen/pkg_<name>/`.
   Their C runtimes are `runtime/sl_<name>.c`. `json` uses
   `dispatch.c` because decode/encode are generic over the target
   type. Adding a fixed-signature package is a `pkg_<name>/` directory,
   a `runtime/sl_<name>.c` file, and one line in `loader.c`.
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
  common.h       allocation helpers, growable string buffer, file I/O
  loader.h/.c    package discovery, merging, cycle detection
  lexer.h/.c     tokenizer
  ast.h          AST node definitions
  parser.h/.c    recursive-descent parser
  rtpath.h/.c    locate runtime/ next to slangc
  codegen.h      public codegen API (one function: codegen_program)
  codegen/       type checking + C emission
  main.c         driver: flags, invokes cc
runtime/       real C runtime spliced into generated programs
  sl_core.c sl_gc.c sl_containers.c sl_sched.c sl_pool.c
  sl_time.c sl_net.c sl_tls.c sl_json.c sl_proc.c sl_fs.c
stdlib/        slang-source packages (`import "http"`, `import "byteutil"`;
             `import "log"` is a native package — no source files)
examples/      one directory per example program
tests/         language tests plus tests/runtime/ (no slangc)
Makefile       build/test/clean
```

## Known limitations

- Block scoping: a `let` inside `if`/`else`/`while`/`for` is not
  visible afterwards. Loop bindings (`for i in ...`) are scoped to
  the loop. Redeclaring a name in the same scope is an error;
  inner blocks may shadow. `guard let` still binds for the rest of
  its enclosing block.
- Strings are immutable; concatenation allocates. The collector
  reclaims unreachable strings automatically.
- Package globals require constant-literal initializers.
- Implicit returns only apply to the last statement of a function
  body; `if` and `{}` blocks are statements, not expressions yet.
- No closures. Functions are values (`fn(int) -> int`), but they
  capture nothing — a function value always names a top-level
  function, never an environment. `break`/`continue` work inside
  loops.
- Package-level lists are not supported yet (scalars and bytes are).
- Map keys are limited to integers, `str`, and `bool`.
- No data-race protection: `spawn` gives you real concurrency and
  per-task failure isolation, not an ownership/borrow checker.
  Mutating a shared struct/list/map from more than one task is on
  you, same as Go or Java — `mutex` is available for it, but nothing
  makes you reach for one.
- `select` has no timeout arm and no way to disable an arm. A closed
  channel's recv arm is ready forever (see Concurrency above), and
  there is no nil channel to switch it off with; for a deadline, feed
  a channel from a spawned timer task.
- `mutex` has no scope guard: without closures or `defer`, an early
  `return` between `mutex_lock` and `mutex_unlock` leaks the lock.
  Mutexes are also not recursive (locking one twice from the same
  task is a checked error, not a hang).
- TLS: no session resumption tuning. Handshake and send/recv park;
  `getaddrinfo` in `tls_dial` parks the task while a dedicated
  thread resolves. mTLS (`tls_ctx_require_client` /
  `tls_ctx_use_cert`) and SNI extra certs (`tls_ctx_add_sni`) are
  supported.
- JSON: no dynamic/unknown-shape decoding (every decode target is a
  concrete slang type known at compile time — see the `json` section
  above), and JSON object keys map to struct field names verbatim
  (no camelCase/snake_case conversion). `bytes` fields are base64
  strings (RFC 4648).
- `proc`: only `SIGTERM`/`SIGINT` are handled (there's no general
  signal-registration API); a signal that arrives in the narrow
  window before `main()` installs the handler gets the OS's default
  disposition (immediate termination) rather than graceful handling.
  `proc.wait_idle()` parks until `proc.active_tasks()` is zero.

## Memory management

Compiled programs embed a precise mark-sweep collector
(`runtime/sl_gc.c`). Allocations go through `sl_gc_alloc`. `main()`
registers the thread, starts the worker pool, and switches into the
main task. There is no `libgc` dependency.

What this means in practice:

- No manual memory management in slang; no leaks from string churn.
- Collection is tracing (mark-and-sweep), so reference cycles are
  collected — unlike refcounting.
- Cost: stop-the-world pauses. The allocator still serializes on a
  mutex (batched); that is the current throughput ceiling.
- Every pool worker is registered with the collector. A collection
  stops the world, walks safepoint roots, the run queue, parked
  tasks, and (for async-preempted tasks) a conservative stack scan.
- Pacing follows the live heap, like Go's default (`GOGC=100`): the next
  collection comes after allocating as much as survived the last one,
  and never before 8MB. The heap peaks near twice what is live, however
  much garbage a program makes — streaming three million database rows
  runs in under 20MB.
- `SLANG_GC_STAT=1` prints collection counts and pause times at exit.
  `SLANG_GC_THRESHOLD_KB=n` collects every n KB instead, with no pacing:
  for tests, since a rooting bug only shows when a collection lands at
  the one safepoint where an object is unrooted.

## Roadmap ideas

- Block scoping and shadowing
- If/block expressions (`let max = if a > b { a } else { b }`)
- Range `.step(n)`
- A bytecode VM mode for fast iteration without invoking `cc`
- `extern struct` layouts, for passing C structs by value instead of
  only through opaque `rawptr` handles
- Callback function pointers (C calling back into slang)
- `select` over multiple channels
