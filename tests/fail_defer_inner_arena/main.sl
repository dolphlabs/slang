fn f(cond: bool) {
    if cond {
        let a = arena_new(128);
        defer a.reset();
    }
}
f(true);
