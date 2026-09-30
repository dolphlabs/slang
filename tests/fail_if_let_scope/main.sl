// An if let binding exists only inside its own branch.
let o: opt[int] = some(4);
if let v = o {
    println(v);
}
println(v);
