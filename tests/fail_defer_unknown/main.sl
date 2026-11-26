fn f() {
    defer does_not_exist();
}
f();
