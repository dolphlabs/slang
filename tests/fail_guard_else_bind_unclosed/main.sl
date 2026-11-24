fn f(r: result[int, str]) {
    guard let x = r else |e {
        return;
    }
    println(x);
}
f(err("x"));
