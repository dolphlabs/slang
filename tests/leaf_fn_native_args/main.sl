// A leaf function emits no safepoint, even for a builtin among a native
// call's arguments: top_bits reads len(a) inside math.bit_len(a[...]),
// where the native's ambient roots used to keep a bracket around len().
// Callers skip their own bracket on a leaf call, so a collection at that
// inner bracket freed the caller's live lists (math/big's mod_pow hit
// it). run_tests.sh checks top_bits' generated C has no safepoint; this
// program keeps fresh lists live across the calls under the GC lists'
// small nursery and threshold, and checks every one survives intact.
import "math";

fn top_bits(a: [u32]) -> int {
    if len(a) == 0 {
        return 0;
    }
    return 32 * (len(a) - 1) + math.bit_len(a[len(a) - 1]);
}

fn limbs(n: int, top: u32) -> [u32] {
    let xs: [u32] = [];
    for i in 0..n {
        let v: u32 = (i as u32) | (1 as u32);
        push(xs, v);
    }
    push(xs, top);
    return xs;
}

let kept: [[u32]] = [];
let total = 0;
let i = 0;
while i < 20000 {
    let a = limbs(i % 7, ((i % 31) + 1) as u32);
    let b = limbs(i % 5, 1 as u32);
    // a and b are live across both leaf calls and the allocation between
    total = total + top_bits(a);
    let c = limbs(3, 7 as u32);
    total = total + top_bits(b) + top_bits(c);
    if i % 1000 == 0 {
        push(kept, a);
    }
    if len(a) != i % 7 + 1 || a[len(a) - 1] != ((i % 31) + 1) as u32 || len(b) != i % 5 + 1 {
        println("corrupt at " + to_str(i));
    }
    i = i + 1;
}
println(total);
println(len(kept));
println(top_bits(kept[19]) + top_bits([]));
