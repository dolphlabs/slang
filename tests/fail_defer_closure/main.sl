fn f() {
    defer fn() {
        println("no");
    };
}
f();
