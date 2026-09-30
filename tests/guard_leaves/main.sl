// Every way a guard's else may leave its scope. Each call below takes the
// else branch at least once, so a form that fell through would print a
// line that expected.txt does not have.
import "fatal";

fn die(msg: str) {
    println("die: " + msg);
    exit(1);
}

// Never returns because die() never returns: found to a fixed point.
fn fail(msg: str) {
    die("fail: " + msg);
}

// Never returns on either branch.
fn stop(msg: str, code: int) {
    if code == 0 {
        exit(0);
    } else {
        panic(msg);
    }
}

fn by_return(o: opt[int]) -> int {
    guard let v = o else { return -1; }
    return v;
}

fn by_if_else(o: opt[int], k: int) -> int {
    guard let v = o else {
        if k > 0 { return 1; } else { return 2; }
    }
    return v;
}

fn by_switch(o: opt[int], k: int) -> int {
    guard let v = o else {
        switch k {
            case 1 { return 10; }
            default { return 20; }
        }
    }
    return v;
}

fn by_if_let(o: opt[int], r: result[int, str]) -> int {
    guard let v = o else {
        if let w = r { return w; } else { return -2; }
    }
    return v;
}

fn by_helper(o: opt[int]) -> int {
    guard let v = o else { fail("never taken"); }
    return v;
}

fn by_stop(o: opt[int]) -> int {
    guard let v = o else { stop("never taken", 1); }
    return v;
}

let none_int: opt[int] = none;
println(by_return(none_int));
println(by_if_else(none_int, 1));
println(by_if_else(none_int, 0));
println(by_switch(none_int, 1));
println(by_switch(none_int, 5));
println(by_if_let(none_int, ok(7)));
let bad: result[int, str] = err("x");
println(by_if_let(none_int, bad));
println(by_helper(some(8)));
println(by_stop(some(9)));

// break and continue leave a loop body's scope
let seen = 0;
for i in 0..6 {
    let o: opt[int] = none;
    if i % 2 == 0 { o = some(i); }
    guard let v = o else { continue; }
    guard v < 4 else { break; }
    seen += v;
}
println(seen);

// continue inside a switch still reaches the loop
let odd = 0;
for i in 0..4 {
    let o: opt[int] = none;
    if i % 2 == 1 { o = some(i); }
    guard let v = o else {
        switch i {
            case 0 { continue; }
            default { continue; }
        }
    }
    odd += v;
}
println(odd);

// the plain form, and a helper from another package
let x = 3;
guard x > 1 else { exit(1); }
let missing: opt[str] = none;
guard let s = missing else { fatal.bail("missing, as expected"); }
println(s);
