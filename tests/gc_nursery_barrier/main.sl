gc struct Box {
    label: str,
    count: int,
}

fn fresh_label(n: int) -> str {
    return "box-" + to_str(n);
}

// Direct-assignment barrier path: mutate an OLD object's field via
// ordinary `p.x = v` to point at a freshly allocated object, force a
// minor GC, assert the new object survived. THE test for a missing or
// buggy direct write barrier.
let holder = Box { label: "seed", count: 0 };

// Grow old: allocate enough garbage that `holder` (still rooted)
// survives into the old generation, then drop the garbage.
let g = 0;
while g < 20000 {
    let tmp = "garbage-" + to_str(g);
    if len(tmp) < 0 {
        println("unreachable");
    }
    g = g + 1;
}

// Fresh object linked from the (now old) holder via direct assignment.
holder.label = fresh_label(42);
holder.count = 42;

// Force allocations to trigger a minor GC of the nursery.
let f = 0;
while f < 5000 {
    let tmp2 = "fill-" + to_str(f);
    if len(tmp2) < 0 {
        println("unreachable");
    }
    f = f + 1;
}

if holder.label != "box-42" {
    println("FAIL direct barrier: label is " + holder.label);
    exit(1);
}
if holder.count != 42 {
    println("FAIL direct barrier: count corrupted");
    exit(1);
}
println("direct barrier ok");

// Interior &mut barrier path: the same old->young edge, but created
// through a mutable interior reference (`*r = v`) instead of direct
// assignment. A test exercising only the path above would NOT catch a
// bug in the reference-creation barrier (different codegen site:
// expr.c &mut creation vs stmt.c direct assignment).
let r = &mut holder.label;
*r = fresh_label(99);

let h = 0;
while h < 5000 {
    let tmp3 = "fill2-" + to_str(h);
    if len(tmp3) < 0 {
        println("unreachable");
    }
    h = h + 1;
}

if holder.label != "box-99" {
    println("FAIL &mut barrier: label is " + holder.label);
    exit(1);
}
println("&mut barrier ok");
println("done");
