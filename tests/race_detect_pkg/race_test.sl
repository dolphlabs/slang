// Intentional unsynchronized data race across two spawned tasks;
// `slangc test --race` must fail and report ThreadSanitizer: data race.

gc struct Box {
    val: int,
}

fn bump(b: Box, n: int) -> int {
    for i in 0..n {
        b.val = b.val + 1;
    }
    return b.val;
}

fn test_intentional_race() {
    let b = Box { val: 0 };
    let h1 = spawn bump(b, 50000);
    let h2 = spawn bump(b, 50000);
    let _r1 = join_wait(h1);
    let _r2 = join_wait(h2);
    assert(b.val >= 0);
}
