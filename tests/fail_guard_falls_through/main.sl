// A guard's else that falls through would run the rest of the block
// with the bound name holding no value: for an opt[str], a NULL string.
fn name_len(o: opt[str]) -> int {
    guard let s = o else {
        println("none");
    }
    return len(s);
}

let n: opt[str] = none;
println(name_len(n));
