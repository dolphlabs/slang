// A leaf function -- no allocation, park, loop, or call but to builtins
// and leaf natives -- is no collection point, so a call to it gets no
// safepoint bracket (run_tests.sh counts the brackets in the generated C:
// put_str's calls have none; every other function here keeps its own).
// Values live across the calls must survive collections elsewhere: under
// the GC stress lists, the loop below churns while they are held.
fn put_str(w: wire, off: int, s: str) -> int {
    wire_put(w, off, s);
    return off + len(s);
}
fn concat(a: str, b: str) -> str {
    return a + b;
}
fn loops(n: int) -> int {
    let i = 0;
    while i < n { i = i + 1; }
    return i;
}
fn calls_user(w: wire, s: str) -> int {
    return put_str(w, 0, s);
}
fn allocs(n: int) -> [int] {
    return [n, n];
}
fn guards(x: opt[int]) -> int {
    guard let v = x else { return 0; }
    return v;
}
fn indexes(xs: [int]) -> int {
    return xs[0];
}
// Values are leaf-safe to build: an opt and a value struct of scalars
// are C values. A gc struct literal allocates, and a struct with a str
// field is left to the general path: those two keep their brackets.
struct Pt { x: int, y: float, ok: bool }
struct Named { name: str, n: int }
gc struct Boxed { n: int }
fn wraps(x: int) -> opt[int] {
    if x < 0 {
        return none;
    }
    return some(x * 2);
}
fn point(x: int) -> Pt {
    return Pt { x: x + 1, y: 2.5, ok: x > 0 };
}
fn moved(p: Pt) -> opt[Pt] {
    return some(Pt { x: p.x * 10, y: p.y, ok: !p.ok });
}
fn boxed(n: int) -> Boxed {
    return Boxed { n: n };
}
fn named(n: int) -> Named {
    return Named { name: "x", n: n };
}
// `tag` is live across every call, so a call that is not a leaf needs a
// bracket to root it: the counts in run_tests.sh see exactly which do.
fn values(tag: str) -> str {
    let pt = moved(point(4)) ?? point(0);
    let w1 = wraps(21) ?? 0;
    let w2 = wraps(-1) ?? -1;
    let b = boxed(3);
    let nm = named(4);
    return tag + " " + to_str(w1) + " " + to_str(w2) + " " + to_str(pt.x) + " " +
           to_str(pt.ok) + " " + to_str(b.n + nm.n);
}
let keep: [str] = ["held across the calls"];
let a = arena_new(4096);
let w = a.wire(64);
let off = put_str(w, 0, "abc");
off = put_str(w, off, keep[0]);
let f = put_str;
off = f(w, off, "via a value");
println(off);
println(concat("a", "b") + to_str(loops(3)) + to_str(calls_user(w, "x")) + to_str(len(allocs(1))) + to_str(guards(some(2))) + to_str(indexes([4])));
println(keep[0]);
println(values("held"));
let held: [str] = [];
let i = 0;
while i < 20000 {
    push(held, "item-" + to_str(i));
    let o = put_str(w, 0, held[i]);
    if o != len(held[i]) {
        println("wrong at " + to_str(i));
    }
    i = i + 1;
}
println(held[19999]);
