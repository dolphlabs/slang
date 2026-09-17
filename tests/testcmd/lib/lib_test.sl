fn test_scaled() {
    assert(scaled(3) == 30, "scaled(3)");
}

// a test reaches the package's PRIVATE functions and globals
fn test_clamp_private() {
    assert(clamp(500, 0, 100) == 100);
    assert(SCALE == 10);
}

fn test_fails_on_purpose() {
    let got = scaled(2);
    assert(got == 99, "expected 99, got " + to_str(got));
}

// runs after a failure: a failing test must not end the run
fn test_after_failure() {
    assert(true);
}

// not a test: no test_ prefix, so never called by the runner
fn helper_not_a_test() {
    panic("helper_not_a_test must never run");
}
