// Function values: a `fn` type whose values name top-level functions.
//
// Deliberately NOT closures. Nothing is captured, so a function value is
// exactly a C function pointer -- no environment to allocate, trace, or
// borrow-check. That is the same line `spawn` already draws, and it is
// what keeps this a small feature rather than a large one.

import "byteutil";

fn double(x: int) -> int { return x * 2; }
fn triple(x: int) -> int { return x * 3; }
fn shout(s: str) { println("! " + s); }

// annotated, and reassignable
let f: fn(int) -> int = double;
println(f(21));
f = triple;
println(f(21));

// inferred from the function itself
let g = double;
println(g(5));

// returning nothing
let v: fn(str) = shout;
v("hi");

// as a parameter, and as a return value
fn apply(h: fn(int) -> int, x: int) -> int { return h(x); }
fn pick(big: bool) -> fn(int) -> int {
    if big { return triple; }
    return double;
}
println(apply(triple, 7));
println(pick(true)(4));
println(apply(pick(false), 9));

// ---- the shape this exists for: a dispatch table --------------------

gc struct Op {
    name: str,
    run: fn(int) -> int,
}

let ops: [Op] = [
    Op { name: "double", run: double },
    Op { name: "triple", run: triple }
];
for i in 0..len(ops) {
    println(ops[i].name + " " + to_str(ops[i].run(10)));
}

// through a single-dot field access too -- the parser folds one dot
// into the call name, so this takes a different path from ops[i].run(x)
let one = ops[0];
println(one.run(100));

// in a map
let by_name: map[str]fn(int) -> int = {};
by_name["double"] = double;
by_name["triple"] = triple;
println(by_name["triple"](6));

// ---- precedence: a binding shadows a function of the same name ------

fn scale(x: int) -> int { return x * 10; }
let scale2: fn(int) -> int = double;
println(scale2(3));   // the binding, not `scale`
println(scale(3));    // the function

// ---- a function value from another package --------------------------

let hp: fn(bytes, bytes) -> bool = byteutil.has_prefix;
println(hp(to_bytes("hello"), to_bytes("he")));
println("done");
