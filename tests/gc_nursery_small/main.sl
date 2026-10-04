// Cheap minors keep the small nursery. Short strings, none kept: each
// minor finds almost nothing live, so it costs far under a sixty-fourth
// of the time between minors, and the adaptive nursery (fix-gc.md 1.2a)
// must not grow -- growing it would only add footprint.
// tests/run_tests.sh ("nursery adaptation") checks the size at exit.
import "strings";

let total = 0;
let i = 0;
while i < 200000 {
    let s = strings.repeat("q", 200) + to_str(i);
    total = total + len(s);
    i = i + 1;
}
println("total: " + to_str(total));
