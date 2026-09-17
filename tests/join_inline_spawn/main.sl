// join_wait(spawn f()) written inline must run f ONCE.
//
// The generated C used to splice the handle expression into both the wait
// and the error lookup, so when f failed, the error path spawned f a
// second time and asked that fresh, unfinished copy for its error: every
// side effect of a failing f ran twice, and the real message was replaced
// by "task panicked". Found while building `slangc test`, whose runner
// writes exactly this form.

fn noisy_failure() -> int {
    println("ran");
    panic("the real message");
}

fn noisy_success() -> int {
    println("ran");
    return 7;
}

fn report(r: result[int, str]) {
    guard let v = r else let e = err_of(r) {
        println("err: " + e);
        return;
    }
    println("ok: " + to_str(v));
}

report(join_wait(spawn noisy_failure()));
report(join_wait(spawn noisy_success()));

// and bound to a variable, the form that always worked
let r = join_wait(spawn noisy_failure());
report(r);
