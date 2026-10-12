// Which spawns codegen submits as joined (no worker woken: the spawner
// parks at once and runs the child itself). Only a spawn whose task does
// nothing before join_wait on it qualifies; anything in between could
// run long while the child waits, unwoken, in this worker's slot.
// tests/run_tests.sh counts the two submit calls in the generated C:
// the three forms marked JOINED, and the four marked plain.

fn sq(x: int) -> int {
    return x * x;
}

fn noop(x: int) {
}

fn joined_let() -> int {
    let h = spawn sq(2);            // JOINED: join_wait(h) is next
    let r = join_wait(h);
    return r ?? -1;
}

fn joined_inline() -> int {
    let r = join_wait(spawn sq(3)); // JOINED
    return r ?? -1;
}

fn joined_guard() -> int {
    let h = spawn sq(4);            // JOINED: the guard starts with it
    guard let v = join_wait(h) else { return -1; }
    return v;
}

fn work_between() -> int {
    let h = spawn sq(5);            // plain: sq(6) runs first
    let x = sq(6);
    let r = join_wait(h);
    return (r ?? -1) + x;
}

fn other_handle() -> int {
    let a = spawn sq(7);            // plain: the next join is b's
    let b = spawn sq(8);            // plain: not followed by a join
    let rb = join_wait(a);
    let ra = join_wait(b);
    return (ra ?? -1) + (rb ?? -1);
}

spawn noop(1);                      // plain: a spawn statement, no join
println(to_str(joined_let() + joined_inline() + joined_guard() +
               work_between() + other_handle()));
