# Data types

> bytes, lists, maps, structs and generic structs.

## bytes

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

## Lists [T]

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

## Maps map[K]V

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

`println` only prints scalars — a list or map passed to it is a compile
error. `inspect(x)` renders any value as a `str` in the style of a
JavaScript console, so composite data can be logged, asserted on, or
embedded in messages:

```slang
println(inspect([1, 2, 3]));              // [1, 2, 3]
println(inspect({"name": "ada"}));        // {"name": "ada"}
println(inspect(Point { x: 1, y: 2 }));   // {x: 1, y: 2}
println(inspect(some(7)));                // some(7), none for the empty case
println(inspect(Color.Red));              // Red — enums print bare
```

Strings render double-quoted with escapes (`"a\"b"`), so text never
reads as a number and emptiness is visible (`""`). `bytes` render as
quoted base64, and faults name themselves (`fault("timeout")`).

## Structs

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

## Generic structs

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

Not yet supported, and each says so when used: lifetime parameters on a
generic struct or on one of its methods, and a generic method's own extra
parameters (`fn map[U](self: Box[T]) -> Box[U]`).

## Generic functions

A plain function can take type parameters too. There is no `first[int](xs)`
at a call site — a type argument is only ever written in a type position —
so every one is inferred, by unifying each parameter's declared type against
the argument's actual type:

```slang
fn first[T](xs: [T]) -> T {
    return xs[0];
}

fn choose_second[A, B](a: A, b: B) -> B {
    return b;
}

println(first([1, 2, 3]));            // 1, T = int
println(first(["a", "b", "c"]));      // "a" -- a different instance, T = str
println(choose_second(1, "two"));     // "two"
```

Unification walks through containers, not just a bare parameter, so `T` is
found inside `[T]`, `Box[T]`, `opt[T]` and the rest exactly where it sits:

```slang
struct Box[T] {
    v: T,
}
fn unbox[T](b: Box[T]) -> T {
    return b.v;
}
fn zip_first[A, B](pairs: [Box[A]], extra: B) -> A {
    return pairs[0].v;
}
```

A type parameter that only the return type mentions cannot be found in any
argument, so it is inferred from the expected type instead, the same
mechanism `none` and `[]` already use — which means it only reaches a
return type shaped like `opt[T]` / `result` / `[T]` / `chan` / `join`:

```slang
fn empty_of[T]() -> [T] {
    return [];
}
let xs: [int] = empty_of();           // T = int, from the let's type
```

A parameter only a scalar or struct return type mentions has nothing to
infer it from; write a plain function that calls the generic one with a
concrete type argument, and use that instead.

Each combination of argument types is its own instance, checked the first
time the program calls it that way — same rule as a generic struct's
methods, including the instantiation note on an error inside one. A generic
function can call another, including itself, and two instances of one
template used in the same expression do not share type parameters
(`first([identity(1), identity(2)]) + first([identity(3)])` is two separate
`identity` instances and two separate `first` instances).

`spawn` takes a generic function like any other call — the arguments fix
the type parameters first, and what is spawned is the one instance they
resolve to:

```slang
fn handle[T](conn: T, id: int) { ... }

spawn handle(conn, 1);           // spawns handle[Conn], not a template
```

A spawn has no annotated `let` to infer from, so a parameter only the
return type mentions cannot be resolved there, and says so.

Not yet supported: `extern fn` cannot be generic, and neither can it declare
lifetime parameters. A generic function is not one function until its type
is chosen, so it cannot be used as a bare value — write a plain function
that calls it with a concrete type, and use that instead. `spawn` does not
take a method, generic or not.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
