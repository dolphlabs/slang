# Language guide

> Values, types, and the shape of a slang program.

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
| `enum`     | `int32_t`   | closed set of named constants (see below) |
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

Keys may be any integer type, `str`, `bool`, or `enum`; values may be any type,
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
checked. A struct may be declared after one that holds it by value. Methods live in top-level `impl Name { ... }` blocks; mark a
method `pub fn` to export it to importing packages. A method's name
belongs to its struct: it may match a package-level function or another
struct's method (`impl Client { fn get }` beside `fn get`), and a bare
call `get(x)` always means the function. Structs are
values: assignment copies, including any `str` / list / map /
`opt` / `result` / `gc struct` fields (shallow — the heap objects
are shared). Use `gc struct` when the record itself should be a
shared heap object.
A method can be called on any expression, not only on a variable, so calls
chain: `p.moved(1, 2).sum()`, `make().sum()`, `points[0].sum()`,
`scores["ann"].sum()`, `line.tl.sum()`. The receiver is evaluated exactly once,
before the arguments, which run left to right. Two things are not allowed on
such a receiver, and both say what to do instead: a method that returns a
reference (`fn get(self: &Bag) -> &int`) — the reference would have no owner,
so bind the receiver to a variable first — and the `arena`, `link` and `trip`
methods (`a.alloc(..)`, `conn.send(..)`, `t.pull()`), which are only callable on
a variable.

`own T` is uniquely owned: assignment and passing **move**, and
use-after-move is a compile error. A moved binding can be reinitialized.
`own` is freed when its binding goes out of scope unless it was moved.

#### Generic structs

A struct can take type parameters, written in brackets like the built-in
`opt[T]` and `map[K]V`:

```slang
struct Box[T] {
    v: T,
}

struct Pair[K, V] {
    k: K,
    v: V,
}

gc struct Node[T] {
    val: T,
    next: opt[Node[T]],      // a list: recursion goes through opt
}

let a = Box { v: 41 };                      // T inferred from the field: Box[int]
let b: Box[str] = Box[str] { v: "hi" };     // or written out
let p = Pair { k: 1, v: Point { x: 3, y: 4 } };
let n = Box { v: Box { v: 7 } };            // Box[Box[int]]

fn unwrap(b: Box[int]) -> int { return b.v; }
```

`Box[int]` is an ordinary struct that the compiler writes out the first
time the program names it, so it costs exactly what a hand-written `IntBox`
does: the same layout, the same C, no boxing and no runtime type
information. Two instances of one template are two different types
(`Box[int]` is not `Box[str]`), and instances work anywhere a type does,
including inside `[T]`, `map`, `opt`, `result`, `chan`, `fn` types,
`json.encode` / `json.decode` (of a `gc struct`), and across packages
(`stash.Stack[Thing]`, where `Thing` is the importing package's own type).

A literal infers its arguments from its fields, so it needs at least one
field whose value fixes each parameter. `Box { v: none }` or
`Bag { items: [] }` cannot say what `T` is; write `Box[int] { v: none }`.
Type arguments are never written at a call site or on a literal's name
unless the inference has nothing to go on.

Each instance is checked when it is made, with the arguments in place: a
parameter is unconstrained, and what a field can do with it is decided by
the type it turns out to be. An error inside a template therefore names the
instance and where it was asked for
(`... (in main.Keyed[float], requested at line 9)`), and a template nobody
instantiates is not checked at all.

A generic struct has methods like any other, in an `impl` block that
declares the parameters:

```slang
impl Box[T] {
    fn get(self: Box[T]) -> T {
        return self.v;
    }

    pub fn apply(self: Box[T], f: fn(T) -> T) -> Box[T] {
        return Box[T] { v: f(self.v) };
    }

    fn doubled(self: Box[T]) -> int {
        return self.v * 2;       // only ever asked for on a Box of numbers
    }
}

println(Box { v: 21 }.doubled());        // 42
println(Box { v: "hi" }.get());          // "hi" -- doubled is never checked here
```

The `impl` block may name its parameters whatever it likes (`impl Pair[A, B]`
for `struct Pair[K, V]`); they match by position. `pub fn` exports a method,
as it does elsewhere.

**A method is checked when an instance asks for it**, not when it is
declared. `doubled` above multiplies, which `Box[str]` cannot do — and that
is fine, because nothing calls `doubled` on a `Box[str]`. This is what makes
unbounded type parameters usable without interfaces, and it is why an error
in a method body names the instance and the line that asked for it:

```
error at line 5: unsupported operand types for '*': str and int
  (in main.Box[str].doubled, requested at line 9)
```

Not yet supported, and each says so when used: generic functions
(`fn first[T](xs: [T]) -> T`), lifetime parameters on a generic struct or on
one of its methods, and a generic method's own extra parameters
(`fn map[U](self: Box[T]) -> Box[U]`).

#### Enums

A closed, `i32`-backed set of named constants:

```slang
enum Status {
    Pending,
    Paid,
    Shipped,
    Delivered,
    Cancelled,
}

// explicit values are allowed per variant; unwritten ones auto-increment
// from the previous one (0-based). Duplicate variant names and duplicate
// explicit values within one enum are both compile errors.
enum PgType {
    Bool = 16,
    Bytea = 17,
    Int8 = 20,
}

let s: Status = Status.Paid;      // Type.Variant access
println(s == Status.Paid);        // true -- == is only defined between
                                   // the same enum type (no <, <=, >, >=)
println(s);                       // "Paid" -- to_str/println/+ all render
                                   // the exact declared variant name
println(s as i32);                // 1 -- enum -> its backing i32 is a
                                   // safe, total `as` cast (one direction
                                   // only: not every int is a valid variant,
                                   // so int -> enum goes through from_int
                                   // below instead, which can fail)

// fallible, like to_int(s): a result, not a silent wrap
let r: result[Status, str] = Status.from_int(2);
guard let s2 = r else let e = err_of(r) {
    log.error("bad status: " + e);      // "2 is not a valid Status" (approx)
    return;
}
let r2: result[Status, str] = Status.from_str("Shipped");
```

An enum works as a struct field and as a `map[K]V` key (alongside
integers, `str` and `bool`), and `json.encode`/`json.decode` support it
as a field type, on the wire as the exact variant name string:

```slang
import "json";

gc struct Order { id: int, status: Status }
let o = Order{ id: 1, status: Status.Shipped };
json.encode(o);   // {"id":1,"status":"Shipped"}

let counts: map[Status]int = {};
counts[Status.Paid] = 3;
```

There is no per-variant wire label yet (`to_str`/JSON always use the
declared name as written), no explicit backing-width syntax
(`enum Name: i64 { ... }`), and no payload-carrying variants or a
`match` statement — enums here are a closed set of names, not a tagged
union.

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

## Built-ins

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

## Types

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
| `enum`     | `int32_t`   | closed set of named constants (see below) |
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

Keys may be any integer type, `str`, `bool`, or `enum`; values may be any type,
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
checked. A struct may be declared after one that holds it by value. Methods live in top-level `impl Name { ... }` blocks; mark a
method `pub fn` to export it to importing packages. A method's name
belongs to its struct: it may match a package-level function or another
struct's method (`impl Client { fn get }` beside `fn get`), and a bare
call `get(x)` always means the function. Structs are
values: assignment copies, including any `str` / list / map /
`opt` / `result` / `gc struct` fields (shallow — the heap objects
are shared). Use `gc struct` when the record itself should be a
shared heap object.
A method can be called on any expression, not only on a variable, so calls
chain: `p.moved(1, 2).sum()`, `make().sum()`, `points[0].sum()`,
`scores["ann"].sum()`, `line.tl.sum()`. The receiver is evaluated exactly once,
before the arguments, which run left to right. Two things are not allowed on
such a receiver, and both say what to do instead: a method that returns a
reference (`fn get(self: &Bag) -> &int`) — the reference would have no owner,
so bind the receiver to a variable first — and the `arena`, `link` and `trip`
methods (`a.alloc(..)`, `conn.send(..)`, `t.pull()`), which are only callable on
a variable.

`own T` is uniquely owned: assignment and passing **move**, and
use-after-move is a compile error. A moved binding can be reinitialized.
`own` is freed when its binding goes out of scope unless it was moved.

#### Generic structs

A struct can take type parameters, written in brackets like the built-in
`opt[T]` and `map[K]V`:

```slang
struct Box[T] {
    v: T,
}

struct Pair[K, V] {
    k: K,
    v: V,
}

gc struct Node[T] {
    val: T,
    next: opt[Node[T]],      // a list: recursion goes through opt
}

let a = Box { v: 41 };                      // T inferred from the field: Box[int]
let b: Box[str] = Box[str] { v: "hi" };     // or written out
let p = Pair { k: 1, v: Point { x: 3, y: 4 } };
let n = Box { v: Box { v: 7 } };            // Box[Box[int]]

fn unwrap(b: Box[int]) -> int { return b.v; }
```

`Box[int]` is an ordinary struct that the compiler writes out the first
time the program names it, so it costs exactly what a hand-written `IntBox`
does: the same layout, the same C, no boxing and no runtime type
information. Two instances of one template are two different types
(`Box[int]` is not `Box[str]`), and instances work anywhere a type does,
including inside `[T]`, `map`, `opt`, `result`, `chan`, `fn` types,
`json.encode` / `json.decode` (of a `gc struct`), and across packages
(`stash.Stack[Thing]`, where `Thing` is the importing package's own type).

A literal infers its arguments from its fields, so it needs at least one
field whose value fixes each parameter. `Box { v: none }` or
`Bag { items: [] }` cannot say what `T` is; write `Box[int] { v: none }`.
Type arguments are never written at a call site or on a literal's name
unless the inference has nothing to go on.

Each instance is checked when it is made, with the arguments in place: a
parameter is unconstrained, and what a field can do with it is decided by
the type it turns out to be. An error inside a template therefore names the
instance and where it was asked for
(`... (in main.Keyed[float], requested at line 9)`), and a template nobody
instantiates is not checked at all.

A generic struct has methods like any other, in an `impl` block that
declares the parameters:

```slang
impl Box[T] {
    fn get(self: Box[T]) -> T {
        return self.v;
    }

    pub fn apply(self: Box[T], f: fn(T) -> T) -> Box[T] {
        return Box[T] { v: f(self.v) };
    }

    fn doubled(self: Box[T]) -> int {
        return self.v * 2;       // only ever asked for on a Box of numbers
    }
}

println(Box { v: 21 }.doubled());        // 42
println(Box { v: "hi" }.get());          // "hi" -- doubled is never checked here
```

The `impl` block may name its parameters whatever it likes (`impl Pair[A, B]`
for `struct Pair[K, V]`); they match by position. `pub fn` exports a method,
as it does elsewhere.

**A method is checked when an instance asks for it**, not when it is
declared. `doubled` above multiplies, which `Box[str]` cannot do — and that
is fine, because nothing calls `doubled` on a `Box[str]`. This is what makes
unbounded type parameters usable without interfaces, and it is why an error
in a method body names the instance and the line that asked for it:

```
error at line 5: unsupported operand types for '*': str and int
  (in main.Box[str].doubled, requested at line 9)
```

Not yet supported, and each says so when used: generic functions
(`fn first[T](xs: [T]) -> T`), lifetime parameters on a generic struct or on
one of its methods, and a generic method's own extra parameters
(`fn map[U](self: Box[T]) -> Box[U]`).

#### Enums

A closed, `i32`-backed set of named constants:

```slang
enum Status {
    Pending,
    Paid,
    Shipped,
    Delivered,
    Cancelled,
}

// explicit values are allowed per variant; unwritten ones auto-increment
// from the previous one (0-based). Duplicate variant names and duplicate
// explicit values within one enum are both compile errors.
enum PgType {
    Bool = 16,
    Bytea = 17,
    Int8 = 20,
}

let s: Status = Status.Paid;      // Type.Variant access
println(s == Status.Paid);        // true -- == is only defined between
                                   // the same enum type (no <, <=, >, >=)
println(s);                       // "Paid" -- to_str/println/+ all render
                                   // the exact declared variant name
println(s as i32);                // 1 -- enum -> its backing i32 is a
                                   // safe, total `as` cast (one direction
                                   // only: not every int is a valid variant,
                                   // so int -> enum goes through from_int
                                   // below instead, which can fail)

// fallible, like to_int(s): a result, not a silent wrap
let r: result[Status, str] = Status.from_int(2);
guard let s2 = r else let e = err_of(r) {
    log.error("bad status: " + e);      // "2 is not a valid Status" (approx)
    return;
}
let r2: result[Status, str] = Status.from_str("Shipped");
```

An enum works as a struct field and as a `map[K]V` key (alongside
integers, `str` and `bool`), and `json.encode`/`json.decode` support it
as a field type, on the wire as the exact variant name string:

```slang
import "json";

gc struct Order { id: int, status: Status }
let o = Order{ id: 1, status: Status.Shipped };
json.encode(o);   // {"id":1,"status":"Shipped"}

let counts: map[Status]int = {};
counts[Status.Paid] = 3;
```

There is no per-variant wire label yet (`to_str`/JSON always use the
declared name as written), no explicit backing-width syntax
(`enum Name: i64 { ... }`), and no payload-carrying variants or a
`match` statement — enums here are a closed set of names, not a tagged
union.

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

## Numeric conversion rules

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

## Bitwise operations and integer literals

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

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
