import "proc";

fn test_wait_idle_from_a_test() {
    let c: chan[int] = make_chan(4);
    spawn bump(c);
    spawn bump(c);
    proc.wait_idle();
    assert(proc.active_tasks() == 0);
    let a = chan_recv(c) ?? 0;
    let b = chan_recv(c) ?? 0;
    assert(a + b == 2);
}

fn test_active_tasks_skips_the_test_itself() {
    assert(proc.active_tasks() == 0);
}
