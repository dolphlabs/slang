fn f(r: result[int, str]) {
    guard let x = r else || {
        return;
    }
    println(x);
}
f(err("x"));
