// mutex: task-level mutual exclusion.
//
// The counter below is the reason the type exists. `c.n = c.n + 1` is a
// read-modify-write, and a task can be preempted between the read and
// the write, so eight tasks racing on it lose increments. Holding the
// mutex across the pair makes the total exact -- 8 * 2000 every run,
// not "usually 16000".
//
// Contention here is real, not theoretical: 16000 lock acquisitions
// across 8 concurrent tasks means most of them park and get resumed by
// whoever unlocks next.

gc struct Counter {
    n: int,
    m: mutex,
}

fn bump(c: Counter, times: int, done: chan[bool]) {
    for _i in 0..times {
        mutex_lock(c.m);
        c.n = c.n + 1;
        mutex_unlock(c.m);
    }
    chan_send(done, true);
}

let c = Counter { n: 0, m: make_mutex() };
let done: chan[bool] = make_chan(8);

for _t in 0..8 {
    spawn bump(c, 2000, done);
}
for _t in 0..8 {
    let v = chan_recv(done);
    guard let _ok = v else {
        println("FAIL: done channel closed early");
        exit(1);
    }
}
println(c.n);

// trylock reports rather than parks. The lock is free here, so it is
// taken; the second call sees it held -- by this very task, which is
// exactly the case a blocking lock would have to diagnose instead.
let got = mutex_trylock(c.m);
println(got);
println(mutex_trylock(c.m));
mutex_unlock(c.m);

// released again, so it is available once more
println(mutex_trylock(c.m));
mutex_unlock(c.m);

// a mutex is a handle: copying the binding aliases the same lock, it
// does not clone one
let alias = c.m;
mutex_lock(c.m);
println(mutex_trylock(alias));
mutex_unlock(alias);
println("done");
