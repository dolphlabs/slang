fn bad() -> &mut int {
    let a = arena_new(64);
    return a.alloc(1);
}
