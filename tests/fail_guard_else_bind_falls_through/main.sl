fn f(r: result[int, str]) {
    guard let x = r else |e| {
        println(e);
    }
    println(x);
}
f(err("x"));
