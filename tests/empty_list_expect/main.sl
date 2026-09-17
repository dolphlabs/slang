import "geo";

// An empty list literal takes its type from what is expected of it, the
// way `none` does: a parameter, a struct field, a return, an assignment,
// ok()/some(), a pushed value, and an element of an outer list.

gc struct Box { items: [str], n: int }
struct Pair { xs: [int], label: str }

fn count(xs: [int]) -> int { return len(xs); }
fn names(prefix: str, xs: [str]) -> str {
    let out = prefix;
    for x in xs { out = out + x; }
    return out;
}
fn fresh() -> [Box] { return []; }
fn wrap() -> result[[int], str] { return ok([]); }
fn maybe() -> opt[[str]] { return some([]); }
fn worker(xs: [int]) -> int { return len(xs); }
fn nested(xss: [[int]]) -> int { return len(xss); }

println(count([]));
println(names("none:", []));
println(names("two:", ["a", "b"]));

let b = Box { items: [], n: 0 };
push(b.items, "x");
println(len(b.items));
let p = Pair { xs: [], label: "p" };
println(len(p.xs));

let f = fresh();
push(f, b);
println(len(f));

let ys: [int] = [1, 2];
ys = [];
println(len(ys));

let r: result[[int], str] = ok([]);
println(len(r ?? [7]));
println(len(wrap() ?? [9]));
println(len(maybe() ?? ["x"]));

let s = geo.Shape { pts: [] };
println(s.add_all([]));
println(s.add_all([1, 2]));
println(geo.total([]));

let h = spawn worker([]);
println(join_wait(h) ?? -1);

println(nested([]));
println(nested([[], [1]]));
let grid: [[int]] = [];
push(grid, []);
push(grid[0], 5);
println(grid[0][0]);
