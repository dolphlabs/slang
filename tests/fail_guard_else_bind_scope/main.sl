fn f(r: result[int, str]) {
    guard let x = r else |e| {
        return;
    }
    println(x);
    println(e);
}
f(ok(1));
