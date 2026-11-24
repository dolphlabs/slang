fn f(r: result[int, str]) {
    guard let x = r else |123| {
        return;
    }
    println(x);
}
f(err("x"));
