// xs[i].f = v on a list of value structs used to be a C compile error
// ("expression is not assignable"): the element was a copy, not a place.
struct Inner { n: int, tag: str }
struct P { x: int, name: str, inner: Inner }

fn mk(x: int) -> P {
    return P { x: x, name: "p" + to_str(x), inner: Inner { n: 0, tag: "" } };
}

// grows the list it is given, so its buffer moves while the store waits
fn grow(xs: [P]) -> int {
    for i in 0..1000 {
        push(xs, mk(i));
    }
    return 99;
}

let xs: [P] = [mk(1), mk(2)];
xs[1].x = 30;
xs[0].x += 5;
println(xs[0].x);
println(xs[1].x);

// a GC field: the store takes the list's barrier
for i in 0..2000 {
    xs[i % 2].name = "name-" + to_str(i);
}
println(xs[0].name + " " + xs[1].name);

// through a value-struct field
xs[1].inner.n = 7;
xs[1].inner.tag = "t" + to_str(xs[1].inner.n);
println(to_str(xs[1].inner.n) + " " + xs[1].inner.tag);

// the value moves the buffer; the store lands in the new one
xs[0].x = grow(xs);
println(xs[0].x);
println(len(xs));

// a list of lists
let grid: [[P]] = [[mk(0)], [mk(1), mk(2)]];
grid[1][1].x = 42;
grid[1][1].inner.tag = "deep";
println(to_str(grid[1][1].x) + " " + grid[1][1].inner.tag);

// index evaluated once
let k = 0;
fn next(k: int) -> int { return k + 1; }
xs[next(k)].x = 11;
println(xs[1].x);
