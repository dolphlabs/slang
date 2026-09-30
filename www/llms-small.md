# slang in one page

> slang is a statically typed language for servers, with Go-like
> simplicity. It compiles to C, so programs are fast and small. It has green
> threads, channels, a garbage collector, generics, and no exceptions, nulls,
> closures or interfaces. This page is enough to write correct slang. Every
> code block below compiles and runs as shown; the test suite checks that.

Commands: `slangc main.sl --run` (compile and run), `slangc main.sl -o app`
(build), `slangc new app` (new project), `slangc test` (run `*_test.sl`),
`slangc get` (fetch pinned packages). Errors read `file.sl:12: error: ...`,
list the first error of every function in one compile, and often end with
`(did you mean 'x'?)`; `--json` gives one JSON object per error. Package
APIs: `slangc doc http` lists a package's signatures with their comments,
`slangc doc builder.Str` shows one item in full (also `/packages/<name>.md`
and `/api.json` on the docs site). HTTP services: use the zokor framework
and its own `llms-small.txt`.

## Basics

```slang
// Top-level statements are the program; functions may come in any order.
let n = 10;                  // int (64-bit); every `let` can be reassigned
let pi = 3.14;               // float
let name = "slang";          // str (UTF-8)
let ok = true;               // bool
n = n + 1;
n += 1;                      // compound assignment
let half = n / 2;            // int / int is integer division
let small = n as i32;        // narrowing needs `as`
println("${name} has ${n} and ${half}");   // interpolation: any expression
println("also " + name + " " + n);         // + converts scalars to str

fn add(a: int, b: int) -> int {
    return a + b;
}

fn sign(x: int) -> str {
    if x < 0 {
        return "negative";
    } else if x == 0 {
        return "zero";
    }
    return "positive";
}

for i in 0..3 { print(i); }   // 0 1 2 (exclusive); 1..=3 is inclusive
println("");
let k = 0;
while k < 2 { k += 1; }
println(add(small, 1) + k);
println(sign(-5));
let code = 404;
let label = switch code {
    case 200, 201 { "ok" }
    case 404 { "missing" }
    default { "other" }
};
println(label);
```

Semicolons end statements. No `var`, `const`, `null` or `nil`. Fixed-width
ints: `i8..i64`, `u8..u64`; `f32`. Casts go through `as`.

## Lists, maps, bytes

```slang
let xs = [3, 1, 2];                  // [int]
let names: [str] = [];               // an empty literal needs a type
push(xs, 4);
let last = pop(xs);
xs[0] = 9;                           // bounds-checked
for x in xs { print(x); }
println(" len=${len(xs)} last=${last}");
let part = xs[0..2];                 // slice

let ages: map[str]int = {"ada": 36};
ages["alan"] = 41;                   // insert or overwrite
if has(ages, "ada") { println(ages["ada"]); }
del(ages, "alan");
for key, v in ages { println(key + "=" + to_str(v)); }   // insertion order

let raw = b"hi";                     // bytes: binary-safe
println(len(raw));
println(inspect(part));              // [9, 1]; println only takes scalars
push(names, "x");
```

A missing map key is a runtime error: check with `has` first. Build large
strings with `import "builder";` (`builder.new_str().write(..).finish()`), not
`+` in a loop, which is quadratic.

## Structs, methods, enums, generics

```slang
struct Point { x: int, y: int }          // value: assignment copies

impl Point {
    fn sum(self: Point) -> int { return self.x + self.y; }
}

gc struct Account {                      // heap object: shared by reference
    id: int,
    owner: str,
    tags: [str],
}

enum Status { Pending, Paid, Shipped }

struct Box[T] { v: T }

fn first[T](xs: [T]) -> T { return xs[0]; }   // T is inferred at the call

let p = Point { x: 1, y: 2 };            // every field, exactly once
println(p.sum());
let a = Account { id: 1, owner: "ada", tags: [] };
let alias = a;
alias.owner = "grace";                   // a.owner is now "grace" too
println(a.owner);
let s = Status.Paid;
println(s);                              // Paid
switch s {
    case Status.Pending { println("wait"); }
    case Status.Paid, Status.Shipped { println("done"); }
}
println(Box { v: 41 }.v + 1);
println(first(["a", "b"]));
```

`pub` exports a function, type, method or constant from its package. A
`switch` on an enum must cover every variant or have `default`.

## Errors: opt, result, guard let, ??

```slang
fn find(ids: [int], want: int) -> opt[int] {
    for i in 0..len(ids) {
        if ids[i] == want { return some(i); }
    }
    return none;
}

fn parse_port(s: str) -> result[int, str] {
    let r = to_int(s);
    guard let port = r else let e = err_of(r) {
        return err("PORT: " + e);
    }
    if port < 1 || port > 65535 {
        return err("PORT out of range: " + to_str(port));
    }
    return ok(port);
}

let idx = find([4, 5, 6], 5) ?? -1;      // ?? gives a default on none/err
println(idx);
guard let port = parse_port("8080") else {
    println("bad port");
    exit(2);                             // guard's else must leave the scope
}
println(port);
let bad = parse_port("x");
if let p = bad {                         // if let: handle both, carry on
    println(p);
} else let e = err_of(bad) {
    println(e);                          // PORT: not a base-10 integer
}
```

Absent data is `opt[T]`; bad data is `result[T, str]` with a reason; a
failing network or file operation is `result[T, fault]` (timeout, reset,
closed, refused, io). There are no exceptions. `assert(cond, msg)` and
`panic(msg)` end the current task with the message and location. A guard's
`else` must leave the scope (`return`, `break`, `continue`, `exit`, `panic`,
or a function of yours that always exits); `if let` is for when both
outcomes carry on, and each of its bindings lives only in its branch. A bare
`none`, `err(..)`, `[]` or `{}` takes its type from where it goes: an
annotated binding, a parameter, a return type, a field, or the list or map
it sits in (`let xs: [opt[int]] = [some(1), none];`).

## Concurrency

```slang
fn worker(jobs: chan[int], results: chan[int]) {
    while true {
        let j = chan_recv(jobs);             // opt[int]: none once closed
        guard let n = j else { return; }
        chan_send(results, n * n);
    }
}

fn square(n: int) -> int { return n * n; }

let jobs: chan[int] = make_chan(16);
let results: chan[int] = make_chan(16);
for w in 0..4 { spawn worker(jobs, results); }
for n in 1..=5 { chan_send(jobs, n); }
chan_close(jobs);
let total = 0;
for i in 0..5 { total += chan_recv(results) ?? 0; }
println(total);                              // 55

let h = spawn square(7);                     // join[int]
let r = join_wait(h);                        // result[int, str]; err if it panicked
println(r ?? -1);

let m = make_mutex();
mutex_lock(m);
total += 1;                                  // no defer: unlock on every path
mutex_unlock(m);
```

`spawn f(args)` runs `f` on a green thread; arguments are evaluated first and
nothing is captured. Blocking calls (`chan_recv`, `net.*`, `time.sleep`) park
the task, not the OS thread, so there is no async/await. `select { case let v
= chan_recv(a) { .. } case chan_send(b, x) { .. } default { .. } }` waits on
several channels.

## Functions as values

```slang
fn double(x: int) -> int { return x * 2; }
fn apply(f: fn(int) -> int, x: int) -> int { return f(x); }

let ops: map[str]fn(int) -> int = {"double": double};
println(apply(double, 4));
println(ops["double"](5));
```

A function value names a top-level function. There are no closures and no
lambdas: pass what a function needs as parameters. A method cannot be a
function value; wrap it in a plain function.

## Packages, JSON, environment

```slang
import "json";
import "proc";

gc struct User {
    name: str,
    age: i32,
    email: opt[str],                 // missing or null in JSON is none
}

let u = User { name: "ada", age: 36, email: none };
let text = json.encode(u);
println(text);
let r: result[User, str] = json.decode("{\"name\":\"bo\",\"age\":7}");
guard let back = r else let e = err_of(r) {
    println("decode: " + e);         // errors name the field
    exit(1);
}
println(back.name);
let home = proc.getenv("HOME") ?? "/";
println(len(home) > 0);
```

A package is a directory: its `.sl` files share one namespace. `import
"geometry";` finds `./geometry/`, then a standard package, then a `pkg` pin in
`slang.project` (`pkg name git <url> tag v1.2.0`, then `slangc get`). JSON
works on `gc struct` types only; the decode target comes from the annotation.
Standard packages: `time net json proc fs os io log crypto sql pg redis regex
strings encoding compress builder byteutil flags http http2 httpc`.

## Tests

Tests live next to the code in `*_test.sl`, as `fn test_*()` that fail
through `assert` or `panic`. They can reach private functions. `slangc test`
runs them and prints only failures and a count (`-v` lists every test);
`--run name` filters.

```slang
fn clamp(v: int, lo: int, hi: int) -> int {
    if v < lo { return lo; }
    if v > hi { return hi; }
    return v;
}

fn test_clamp() {
    assert(clamp(15, 0, 10) == 10, "got " + to_str(clamp(15, 0, 10)));
    assert(clamp(-1, 0, 10) == 0);
}

test_clamp();
println("ok");
```

## Mistakes that cost a retry

- `println(list)`: use `println(inspect(list))`.
- `let xs = [];` or `let m = {};`: annotate, `let xs: [int] = [];`.
- `json.encode` on a plain `struct`: declare it `gc struct`.
- `m[k]` on a missing key panics: check `has(m, k)`.
- A closure or lambda: write a top-level function and pass its state in.
- `return` between `mutex_lock` and `mutex_unlock`: unlock first.
- A `guard` whose `else` falls through is rejected: leave the scope, or use
  `if let v = x { .. } else { .. }` when both paths continue.
- `let v = chan_recv(c);` is `opt[T]`: unwrap with `guard let` or `??`.
- Mixing `i32` and `int`: widening is implicit; narrowing needs `as`.
