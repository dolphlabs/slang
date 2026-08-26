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

Want to see everything at once instead of one feature at a time? See
**[`demo/`](demo/)** — a full server (dice game, guestbook wall, live
dashboard) exercising every tier: `net`/`net.tls_*`, `json`,
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
- `exit(code)` — terminate the process immediately with the given status
- `some(v)` / `none` / `ok(v)` / `err(e)` — construct `opt`/`result` values
  (see below)
- `bytes_ptr(b)` — raw `rawptr` to a `bytes` buffer, for passing to
  `extern fn`s (see C interop below)
- `make_chan(n)` / `chan_send(ch, v)` / `chan_recv(ch)` / `chan_close(ch)`
  — construct and use a `chan[T]` (see Concurrency below)

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
| `opt[T]`   | `sl_opt_* *` | optional value: `some(v)` / `none` |
| `result[T,E]` | `sl_res_* *` | fallible value: `ok(v)` / `err(e)` |
| `duration` | `int64_t`   | nanosecond count (see `time`)  |
| `rawptr`   | `void *`    | opaque foreign pointer (C interop) |
| `chan[T]`  | `sl_chan *` | bounded thread-safe queue (see Concurrency) |

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
// bound name has no value to fall back to
fn safe_div(n: int) -> int {
    guard let v = div10(n) else {
        return -1;
    }
    return v;
}

// ?? recovers from none / err with a fallback value
println(div10(41) ?? -1);              // -1 (none)
println(parse_small("big") ?? -1);     // -1 (err)

// bare 'none' / 'err(...)' need an annotated binding to infer their
// other type parameter
let nothing: opt[str] = none;
let bad: result[str, str] = err("boom");
```

`opt[T]` and `result[T, E]` are monomorphized per distinct type
argument (one C struct per instantiation actually used). Constructing
`none`/`err(...)` without enough context to infer the missing type
parameter is a compile error.

## Standard packages

`time`, `net`, `json`, and `proc` are compiler-provided native
packages — no source files, just `import "time";` / `import "net";`
/ `import "json";` / `import "proc";` like any other package.

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

See `examples/httpd/` for a minimal HTTP server built entirely on
these primitives.

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

struct Address { city: str, zip: str }
struct Person {
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
error), and every scalar type except `bytes` (no implicit
base64-or-similar encoding is applied). `rawptr`, `chan[T]`, and
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
tasks, so a shutting-down program can wait for in-flight work to
finish instead of dropping it.

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

// drain: let in-flight connections finish before actually exiting
while proc.active_tasks() > 0 {
    time.sleep(20000000); // 20ms
}
```

`proc.getenv(name)` reads an environment variable, returning
`opt[str]` (`none` if unset).

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

`spawn` runs a function on a real OS thread; `chan[T]` is a bounded,
thread-safe queue for getting values back out. Blocking-looking code
stays blocking-looking — `net.accept`, `net.recv`, `time.sleep`, and
friends need no special "async" form to be usable from a spawned
task, and a spawned task's own function calls need no annotation
either. There is no colored-function split to design around.

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
  context (no closures — nothing is captured implicitly) and starts
  `f` running on a new thread. `f` must be a plain top-level function
  or an `extern fn`, not a method and not a builtin. There is no
  `spawn` on `net.*`/`time.*` calls directly; wrap the native call in
  a plain function and spawn that instead.
- **`chan[T]`**, built with `make_chan(capacity)` (element type
  inferred from an annotated binding, same as `none`): `chan_send(ch,
  v)` blocks while full, `chan_recv(ch) -> opt[T]` blocks while empty
  and returns `none` once the channel is closed and drained (instead
  of inventing a second return-value convention, it reuses `opt[T]`),
  `chan_close(ch)` wakes every blocked sender/receiver. Sending on a
  closed channel is a checked runtime error, not undefined behavior.
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
Java: nothing currently stops you, so don't. There's also no `select`
over multiple channels yet, and no way to join/await a *specific*
spawned task's completion other than coordinating through a channel
yourselves — `proc.active_tasks()` (see the `proc` section) only
gives you the aggregate count of everything currently in flight,
useful for draining on shutdown but not for waiting on one task in
particular.

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
  `extern fn` boundary: numeric types, `bool`, `str`, `bytes`, and
  `rawptr`. GC'd containers (`opt`, `result`, `map`, structs, arrays)
  are rejected at compile time — their internal layout isn't
  something arbitrary C code should ever see.

**C++ is out of scope for the compiler itself.** There's no
name-mangling/ABI support planned. Wrap the C++ library in your own
`extern "C"` shim (catching every exception at that boundary — an
uncaught C++ exception unwinding into C is undefined behavior) and
consume the shim exactly like any other C library above.

**Safety notes:**

- Boehm GC is conservative and generally sees pointers handed to C
  just fine, but a slang value whose *only* remaining reference lives
  in memory the GC can't scan (rare, but possible with some C
  libraries) could theoretically be collected while C still holds it.
  Keep a live slang-side reference for the duration of any call that
  retains a pointer beyond that call.
- Callback function pointers — C calling back into slang — aren't
  supported yet.

See `tests/ffi/` for a complete example: a small hand-written C
fixture library (`lib.c`) built as a static archive, linked and called
from a slang program exercising `extern fn`, `link`, `rawptr`,
`bytes_ptr`, and `nullptr`.

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
4. **Code generator** (`src/codegen/`) — walks the ASTs, performs type
   inference and semantic checks (including `pub` enforcement), and
   emits readable C. A tiny runtime (string helpers, printing) is
   embedded directly into every generated file so output is fully
   self-contained. Split by concern rather than one monolithic file:
   `core.c` (CG state, symbol tables, type helpers), `infer.c` (type
   inference), `expr.c`/`stmt.c` (expression/statement codegen),
   `program.c` (top-level orchestration and `codegen_program`'s entry
   point), `runtime_core.c` (the always-on embedded prelude: strings,
   lists, maps, `opt`/`result`, channels), and `native.c` (the
   fixed-signature dispatch — `native_check`/`native_gen` — that
   every simple native function like `time.sleep`/`net.recv` goes
   through). `internal.h` holds the shared `CG` struct and
   cross-file declarations.

   Every native package lives entirely under its own
   `src/codegen/pkg_<name>/`: a `sigs.c` with that package's `NatSig`
   table (what `native.c` searches), a `runtime*.c` with its embedded
   C source as a plain string array, and a tiny `pkg_<name>.h` that
   just `#define`s the package's import name (`loader.c` pulls these
   together into its native-package list, so a package's name is
   declared once, next to its implementation, rather than in a
   separate file three steps removed from it). `pkg_net/` also holds
   `runtime_tls.c` for `net.tls_*`. A package whose functions are
   generic over a target type — `json.decode`/`json.encode`, which
   can't be expressed as one of `native.c`'s fixed-arity `NatSig`
   rows — gets its own `dispatch.c` instead of a `sigs.c`, e.g.
   `pkg_json/dispatch.c`. Adding a package means a new `pkg_<name>/`
   directory and one line in `loader.c`, not edits to the
   inference/codegen core — `pkg_proc/` (`proc`) followed exactly
   this shape, needing no changes to `core.c`/`infer.c`/`expr.c`
   beyond the one place it genuinely needed to touch shared state:
   `stmt.c`'s `spawn` codegen, which blocks `SIGTERM`/`SIGINT` in
   every spawned thread's mask so `proc`'s signal handler only ever
   runs on the main thread (see the `proc` section above) — gated on
   `proc` actually being imported, same as everything else here.
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
  codegen.h      public codegen API (one function: codegen_program)
  codegen/       type checking + C emission, split by concern:
    internal.h     shared CG state + cross-file declarations
    core.c         CG state, symbol tables, type helpers
    infer.c        type inference
    expr.c/stmt.c  expression/statement codegen
    program.c      top-level orchestration, codegen_program's entry point
    native.c       fixed-signature native-function dispatch
    runtime_core.c always-on embedded prelude (strings, lists, maps, opt/result, chan)
    pkg_time/      the 'time' package: sigs.c + runtime.c
    pkg_net/       the 'net' package: sigs.c + runtime_net.c + runtime_tls.c
    pkg_json/      the 'json' package: dispatch.c + runtime.c
    pkg_proc/      the 'proc' package: sigs.c + runtime.c
  main.c         driver: flags, invokes cc
examples/      one directory per example program
tests/         one directory per test case; run via `tests/run_tests.sh`
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
- No closures, and no `break`/`continue` — restructure a loop body
  into a helper function and `return` early instead.
- Package-level lists are not supported yet (scalars and bytes are).
- Map keys are limited to integers, `str`, and `bool`.
- No data-race protection: `spawn` gives you real concurrency and
  per-task failure isolation, not an ownership/borrow checker.
  Mutating a shared struct/list/map from more than one task is on
  you, same as Go or Java. No `select` over channels, no way to
  join/await a spawned task's completion besides a channel.
- TLS: no client certificates (mutual TLS), no SNI-based multi-cert
  virtual hosting on one listener, no session resumption tuning.
  Blocking only — call `net.tls_*` from a `spawn`ed task for a
  server, same as plain `net`.
- JSON: no dynamic/unknown-shape decoding (every decode target is a
  concrete slang type known at compile time — see the `json` section
  above), no `bytes` fields, and JSON object keys map to struct field
  names verbatim (no camelCase/snake_case conversion).
- `proc`: only `SIGTERM`/`SIGINT` are handled (there's no general
  signal-registration API); a signal that arrives in the narrow
  window before `main()` installs the handler gets the OS's default
  disposition (immediate termination) rather than graceful handling.
  `proc.active_tasks()` is a poll-based counter, not a wait-with-
  timeout primitive — compose it with `time.sleep` for draining.

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
- Every `spawn`ed OS thread is registered with the collector
  automatically (`GC_THREADS`/`GC_PTHREADS`); a collection pause
  stops and scans every live task's stack, not just the main one.

## Roadmap ideas

- Block scoping and shadowing
- If/block expressions (`let max = if a > b { a } else { b }`)
- Range `.step(n)`
- `break` / `continue`
- Import aliases (`import "x" as y`)
- A bytecode VM mode for fast iteration without invoking `cc`
- `ptr[T]` typed pointers and `extern struct` layouts, for passing C
  structs by value instead of only through opaque `rawptr` handles
- Callback function pointers (C calling back into slang)
- `select` over multiple channels
- A join handle for `spawn`, so a task's completion (and any value)
  can be awaited without hand-rolling it over a channel
- Mutual TLS (client certificates) and SNI-based virtual hosting
