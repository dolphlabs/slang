fn f(o: opt[int]) {
    guard let x = o else |e| {
        println(e);
        return;
    }
    println(x);
}
f(none);
