// Leaf-loop poll: a tight while loop over a live list must (a) produce
// the right answer, (b) keep the list alive across minors (the poll
// re-snapshots roots every iteration), and (c) still check in for
// collections (the poll's slow path). Runs under the GC stress lists
// with a 16KB nursery + verifier: without the poll's slow path a
// forced collection would sweep the list mid-loop.
fn sum(t: [int]) -> int {
    let total = 0;
    let i = 0;
    while i < len(t) {
        total = total + t[i];
        i = i + 1;
    }
    return total;
}
fn range_sum(n: int, t: [int]) -> int {
    let total = 0;
    for i in 0..n {
        total = total + t[i];
    }
    return total;
}
let t: [int] = [1, 2, 3, 4, 5];
println(to_str(sum(t)));
println(to_str(range_sum(len(t), t)));
