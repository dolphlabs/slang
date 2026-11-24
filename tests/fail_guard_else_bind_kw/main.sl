fn f(r: result[int, str]) {
    guard let x = r else |in| {
        return;
    }
    println(x);
}
f(err("x"));
