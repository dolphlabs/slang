// wire_put / wire_put_bytes / arena.left() / to_str(wire): the primitives
// that make bulk assembly into a wire possible, where before this every
// bytes-or-str into a wire was a byte-at-a-time slang loop.

fn left_of(n: int) -> int {
    let a = arena_new(n);
    return a.left();
}
println(to_str(left_of(64)));

let a = arena_new(64);
let w = a.wire(20);

let n1 = wire_put(w, 0, "Hello, ");
let n2 = wire_put(w, n1, "World!");
println(to_str(n1));
println(to_str(n2));
println(to_str(w[0..n1 + n2]));

let n3 = wire_put_bytes(w, 0, to_bytes("XY"));
println(to_str(n3));
println(to_str(w[0..n3]));

// to_str(wire) on a full wire and on a zero-copy slice of one
println(to_str(w));
println(to_str(w[0..2]));

fn empty_str() -> str {
    let ea = arena_new(8);
    let ew = ea.wire(0);
    return to_str(ew);
}
println("[" + empty_str() + "]");

// overflow: writes only what fits, never panics
fn overflow_write() -> str {
    let sa = arena_new(8);
    let small = sa.wire(3);
    let n4 = wire_put(small, 0, "abcdefgh");
    return to_str(n4) + " " + to_str(small);
}
println(overflow_write());

// off beyond the wire, and off exactly at the end: room is 0, no write,
// no panic -- not exceptional inputs for a caller that already checked
// capacity, just the boundary
fn boundary_writes() -> str {
    let ba = arena_new(8);
    let small = ba.wire(3);
    let r1 = wire_put(small, 10, "x");
    let r2 = wire_put(small, 3, "x");
    let r3 = wire_put_bytes(small, 3, to_bytes("x"));
    return to_str(r1) + " " + to_str(r2) + " " + to_str(r3);
}
println(boundary_writes());

println("wire_put ok");
