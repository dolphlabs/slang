// Race-free concurrent package tests verified under `slangc test --race`.

gc struct Shared {
    sum: int,
}

fn worker_chan(ch: chan[int], n: int) -> bool {
    let acc = 0;
    for i in 0..n {
        acc = acc + i;
    }
    chan_send(ch, acc);
    return true;
}

fn worker_mutex(m: mutex, s: Shared, n: int) -> bool {
    for i in 0..n {
        mutex_lock(m);
        s.sum = s.sum + 1;
        mutex_unlock(m);
    }
    return true;
}

fn test_chan_sum() {
    let ch: chan[int] = make_chan(4);
    let h1 = spawn worker_chan(ch, 500);
    let h2 = spawn worker_chan(ch, 500);
    let a = chan_recv(ch) ?? -1;
    let b = chan_recv(ch) ?? -1;
    let _r1 = join_wait(h1);
    let _r2 = join_wait(h2);
    assert(a + b == 249500);
}

fn test_mutex_shared() {
    let m = make_mutex();
    let s = Shared { sum: 0 };
    let h1 = spawn worker_mutex(m, s, 2000);
    let h2 = spawn worker_mutex(m, s, 2000);
    let _r1 = join_wait(h1);
    let _r2 = join_wait(h2);
    mutex_lock(m);
    let got = s.sum;
    mutex_unlock(m);
    assert(got == 4000);
}
