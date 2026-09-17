// assert(cond[, msg]) and panic(msg).
//
// Both end the current task with a message that names where it happened.
// In a spawned task that message becomes the err of join_wait, which is
// what `slangc test` builds on; in the main task the program exits 1 (see
// tests/fail_assert_main).

fn positive(x: int) -> int {
    assert(x > 0, "x must be positive, got " + to_str(x));
    return x;
}

// A function whose only way out is panic still type-checks: panic never
// returns, so no value is missing.
fn unreachable_value() -> int {
    panic("this path was supposed to be impossible");
}

// guard's else must leave the scope, and panic does.
fn must_have(r: result[int, str]) -> int {
    guard let v = r else {
        panic("must_have: no value");
    }
    return v;
}

fn default_message() -> int {
    assert(1 > 2);
    return 0;
}

fn report(r: result[int, str]) {
    guard let v = r else let e = err_of(r) {
        println("err: " + e);
        return;
    }
    println("ok: " + to_str(v));
}

report(join_wait(spawn positive(7)));
report(join_wait(spawn positive(-3)));
report(join_wait(spawn unreachable_value()));
report(join_wait(spawn must_have(ok(5))));
report(join_wait(spawn must_have(err("nope"))));
report(join_wait(spawn default_message()));

// The message is built only when the assertion FAILS. A passing assert
// must not evaluate it: this would print if it did.
fn loud() -> str {
    println("BUG: message built for a passing assert");
    return "unused";
}
assert(true, loud());
println("passing assert built no message");
