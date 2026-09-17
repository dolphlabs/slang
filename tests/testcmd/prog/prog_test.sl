fn test_greet() {
    assert(greet("tests") == "hello tests");
}

// exists only in the test file; a normal build must not contain it
fn test_only_symbol_marker() {
    assert(true);
}
