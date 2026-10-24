// A million fallible calls whose result carries a str error. A result is a
// value, so ok()/err() allocate nothing: run_tests.sh holds the whole run
// under 100 GC allocations (it was one per call, 1,000,005, while a result
// with a GC payload was boxed).
fn read(xs: [int], i: int) -> result[int, str] {
    if i >= len(xs) {
        return err("past the end");
    }
    return ok(xs[i]);
}

let xs: [int] = [1, 2, 3, 4];
let total = 0;
for n in 0..1000000 {
    total += read(xs, n % 5) ?? 0;
}
println(total);
