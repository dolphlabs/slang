// A million optional lookups returning opt[str]. An opt is a value, so
// some()/none allocate nothing: run_tests.sh holds the run under 100 GC
// allocations (a boxed opt was one per call).
fn find(names: [str], i: int) -> opt[str] {
    if i >= len(names) {
        return none;
    }
    return some(names[i]);
}

let names = ["ada", "grace", "barbara"];
let total = 0;
for n in 0..1000000 {
    total += len(find(names, n % 4) ?? "");
}
println(total);
