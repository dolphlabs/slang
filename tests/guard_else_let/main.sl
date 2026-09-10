// `else let e = err_of(r)` binds e for the WHOLE else block, including
// inside a `let`.
//
// The MIR pass lowered the else block without declaring that binding --
// liveness, escape and move all did, MIR was the one that did not. A
// `let` resolves its initializer's type through the var table, so
//
//     guard let v = r else let e = err_of(r) {
//         let msg = to_str(e);      // "undefined variable 'e'"
//     }
//
// was rejected, while using e directly in a call argument worked. That
// asymmetry is why it went unnoticed: every existing use happened to be
// the working shape.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn failing() -> result[int, str] {
    return err("boom");
}

fn ok_one() -> result[int, str] {
    return ok(7);
}

fn run() {
    // 1. a plain `let` reading the error binding
    let a = failing();
    guard let _v = a else let e = err_of(a) {
        let msg = to_str(e);
        if msg != "boom" { die("wrong error: " + msg); }
        println("let sees the binding");
        return;
    }
    die("guard should not have fallen through");
}

fn run2() {
    // 2. several lets, and one derived from another
    let a = failing();
    guard let _v = a else let e = err_of(a) {
        let first = e;
        let second = first + "!";
        let n = len(second);
        if n != 5 { die("wrong length ${n}"); }
        println("chained lets ok");
        return;
    }
}

fn run3() {
    // 3. the success path still binds normally and the else block is
    //    skipped entirely
    let a = ok_one();
    guard let v = a else let e = err_of(a) {
        let unused = to_str(e);
        die("took the else branch: " + unused);
    }
    if v != 7 { die("wrong value"); }
    println("success path ok");
}

run2();
run3();
run();
