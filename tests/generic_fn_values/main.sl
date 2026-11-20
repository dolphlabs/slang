// A generic function named as a value where a concrete fn type is
// expected takes its type arguments from that type. It used to be refused
// ("cannot be used as a value") even with every type parameter known.
import "gtools";

fn ident[T](x: T) -> T { return x; }
fn first_of[A, B](a: A, b: B) -> A { return a; }
fn twice[T](x: T, f: fn(T) -> T) -> T { return f(f(x)); }
fn shout(s: str) -> str { return s + "!"; }

fn apply(f: fn(int) -> int, v: int) -> int { return f(v); }
fn pick() -> fn(int) -> int { return ident; }

struct Handler { run: fn(str) -> str }

struct Box[T] { v: T }
impl Box[T] {
    fn with(self: Box[T], f: fn(T) -> T) -> T { return f(self.v); }
}

// inside a generic, over its own parameter
fn keep[T](x: T) -> T { return twice(x, ident); }

println(apply(ident, 5));
let g: fn(int) -> int = ident;
println(g(3));
let fo: fn(str, int) -> str = first_of;
println(fo("a", 1));
let w: fn(int) -> [int] = gtools.wrap;
println(len(w(9)));

// a generic function handed to a generic one, at two types: two instances
println(twice(4, ident));
println(twice("x", ident));
println(twice("hey", shout));

println(pick()(8));
let h = Handler { run: ident };
println(h.run("handled"));
let b = Box { v: 41 };
println(b.with(ident));
println(keep(7));
println(keep("k"));
