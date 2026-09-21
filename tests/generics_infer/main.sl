// A generic struct literal infers its arguments by walking each field's declared
// type alongside the value's type: through another instance, a list, a fn
// type, a map and an opt. And `xs[i] {` before a block is still an index.
struct Box[T] { v: T }
struct Wrap[T] { inner: Box[T], all: [Box[T]] }
struct Fnh[A, B] { f: fn(A) -> B, name: str }
struct M[V] { m: map[str]V, o: opt[V] }

fn dbl(x: int) -> int { return x * 2; }

let w = Wrap { inner: Box { v: 1 }, all: [Box { v: 2 }, Box { v: 3 }] };
println(w.inner.v + w.all[1].v);
let h = Fnh { f: dbl, name: "dbl" };
println(h.f(21));
let m = M { m: {"a": 1}, o: some(5) };
println(m.m["a"] + (m.o ?? 0));

// indexing right before a block still means indexing
let xs = [1, 2, 3];
let i = 1;
if xs[i] == 2 {
    println("index ok");
}
let flags = [true, false];
if flags[0] {
    println("flag ok");
}
let bs = [Box { v: "s" }];
println(bs[0].v);
