let o: opt[int] = none;
if let x = o {
    println(x);
} else |e| {
    println(e);
}
