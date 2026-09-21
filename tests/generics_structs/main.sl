// Generic structs: `struct Box[T] { v: T }` is a template, and `Box[int]`
// is a real struct made from it. Every use below is checked by the C
// compiler as an ordinary struct, so a wrong layout or a missing
// definition would not build.

struct Box[T] {
    v: T,
}

struct Pair[K, V] {
    k: K,
    v: V,
}

struct Point {
    x: int,
    y: int,
}

// declared BEFORE the instance it holds by value: the struct bodies have
// to come out dependencies first, wherever they were declared
struct Holder {
    p: Pair[Point, Point],
    tag: str,
}

// and a plain struct that names one declared after it
struct Early {
    late: Late,
}
struct Late {
    n: int,
}

// recursion through opt[...], which is a pointer, is how a list is built
gc struct Node[T] {
    val: T,
    next: opt[Node[T]],
}

gc struct Cell[T] {
    v: T,
}

struct Bag[T] {
    items: [T],
    label: str,
}

fn unwrap_int(b: Box[int]) -> int {
    return b.v;
}

fn wrap_str(s: str) -> Box[str] {
    return Box[str] { v: s };
}

fn sum(n: Node[int]) -> int {
    guard let nx = n.next else {
        return n.val;
    }
    return n.val + sum(nx);
}

fn total(b: Bag[int]) -> int {
    let t = 0;
    for x in b.items {
        t = t + x;
    }
    return t;
}

fn first_or(bs: [Box[int]], d: int) -> int {
    if len(bs) == 0 {
        return d;
    }
    return bs[0].v;
}

fn try_wrap(ok_it: bool) -> result[Box[int], str] {
    if ok_it {
        return ok(Box[int] { v: 9 });
    }
    return err("no");
}

fn pair_result(ok_it: bool) -> result[Pair[int, str], str] {
    if ok_it {
        return ok(Pair[int, str] { k: 3, v: "three" });
    }
    return err("no pair");
}

fn swap_pair(f: fn(Pair[int, str]) -> Pair[str, int], p: Pair[int, str]) -> Pair[str, int] {
    return f(p);
}

fn flip(p: Pair[int, str]) -> Pair[str, int] {
    return Pair[str, int] { k: p.v, v: p.k };
}

fn twice(f: fn(Box[int]) -> Box[int], b: Box[int]) -> Box[int] {
    return f(f(b));
}

fn bump(b: Box[int]) -> Box[int] {
    return Box[int] { v: b.v + 1 };
}

// the arguments are inferred from the fields ...
let a = Box { v: 41 };
println(unwrap_int(a) + 1);
// ... or written, and either spelling is the same type
let a2: Box[int] = Box[int] { v: 5 };
println(unwrap_int(a2));
println(wrap_str("hi").v);

// two instances of one template are two types
let b = Box { v: "text" };
println(b.v + "!");

// several parameters, each inferred from its own field
let p = Pair { k: 1, v: Point { x: 3, y: 4 } };
println(p.k + p.v.y);

// an argument that is itself an instance
let n: Box[Box[int]] = Box { v: Box { v: 7 } };
println(n.v.v);
let deep = Box { v: Box { v: Box { v: "deep" } } };
println(deep.v.v.v);

let h = Holder {
    p: Pair[Point, Point] {
        k: Point { x: 1, y: 2 },
        v: Point { x: 5, y: 6 }
    },
    tag: "h"
};
println(h.p.k.x + h.p.v.x);
println(Early { late: Late { n: 11 } }.late.n);

// recursion through opt[...]
let third = Node[int] { val: 3, next: none };
let second = Node[int] { val: 2, next: some(third) };
let first = Node[int] { val: 1, next: some(second) };
println(sum(first));

// a list of the parameter, and a list OF instances
let bag = Bag { items: [1, 2, 3], label: "bag" };
push(bag.items, 4);
println(total(bag));
let boxes: [Box[int]] = [Box { v: 8 }, Box { v: 9 }];
println(first_or(boxes, 0));
let none_yet: [Box[int]] = [];
println(first_or(none_yet, -1));

// instances inside the built-in containers. A two-argument instance puts a
// comma INSIDE the result's or the fn's own list -- result[Pair[int,str],str],
// fn(Pair[int,str])->Pair[str,int] -- and only the outer commas separate
let good = try_wrap(true) ?? Box[int] { v: 0 };
println(good.v);
let bad = try_wrap(false) ?? Box[int] { v: -1 };
println(bad.v);
println(twice(bump, Box[int] { v: 0 }).v);
let pr = pair_result(true) ?? Pair[int, str] { k: 0, v: "" };
println(pr.v + "=" + to_str(pr.k));
let no_pr = pair_result(false) ?? Pair[int, str] { k: -1, v: "none" };
println(no_pr.v);
let fl = swap_pair(flip, Pair[int, str] { k: 8, v: "eight" });
println(fl.k + to_str(fl.v));
let by_name: map[str]Box[int] = {"a": Box[int] { v: 4 }};
println(by_name["a"].v);
let maybe: opt[Box[int]] = some(Box[int] { v: 6 });
println((maybe ?? Box[int] { v: 0 }).v);

// a struct value is a value: copying and changing one leaves the other
let c1 = Box { v: 1 };
let c2 = c1;
c2.v = 2;
println(c1.v + c2.v * 10);

let inner = Cell { v: "gc" };
let outer = Cell { v: inner };
println(outer.v.v);
