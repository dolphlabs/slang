fn f() {
    guard let x = 5 else |e| {
        return;
    }
    println(x);
}
f();
