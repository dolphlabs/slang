// A duration is not an int: the error must say how to convert it, not
// only that the types differ. Its expected_error.txt is the line the
// compiler printed without the fix, plus the fix.
import "time";

let t0 = time.mono();
let elapsed = time.mono() - t0;
let ns: int = elapsed;
println(to_str(ns));
