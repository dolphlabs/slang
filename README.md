# slang

A statically typed language for server-side and network programming.
`spawn` is M:N — green tasks on a worker pool, not a thread per
connection. Accept, recv, and send park. Memory is a precise,
non-moving, stop-the-world mark-sweep collector (`runtime/sl_gc.c`);
cycles are collected. `slangc` emits C and your system `cc` builds the
binary.

## Quick start

```sh
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

## Standard packages

`time`, `net`, `json`, `proc`, `fs`, and `log` are compiler-provided native
packages — no source files, just `import "time";` / `import "net";`
/ `import "json";` / `import "proc";` / `import "fs";` / `import "log";`
like any other package.

`http` and `byteutil` are slang-source stdlib packages under `stdlib/`.
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
`header(req, name)` looks up case-insensitively. `Content-Length` is
honored; chunked `Transfer-Encoding` is rejected. `wants_close`
follows HTTP/1.1 keep-alive (and HTTP/1.0 close-by-default).

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
  `f` must be a
  plain top-level function or an `extern fn`, not a method and not a
  builtin. There is no `spawn` on `net.*`/`time.*` calls directly;
  wrap the native call in a plain function and spawn that instead.
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
over multiple channels yet. `join_wait` waits for one spawned task.
`proc.active_tasks()` (see the `proc` section) is the aggregate count
of everything currently in flight,
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
- No closures. `break`/`continue` work inside loops.
- Package-level lists are not supported yet (scalars and bytes are).
- Map keys are limited to integers, `str`, and `bool`.
- No data-race protection: `spawn` gives you real concurrency and
  per-task failure isolation, not an ownership/borrow checker.
  Mutating a shared struct/list/map from more than one task is on
  you, same as Go or Java. No `select` over channels.
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

## Roadmap ideas

- Block scoping and shadowing
- If/block expressions (`let max = if a > b { a } else { b }`)
- Range `.step(n)`
- A bytecode VM mode for fast iteration without invoking `cc`
- `extern struct` layouts, for passing C structs by value instead of
  only through opaque `rawptr` handles
- Callback function pointers (C calling back into slang)
- `select` over multiple channels
