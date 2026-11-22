import "time";

fn ms(n: int) -> int { return n * 1000000; }
fn soon() -> until { return until_of(time.mono() + ms(5000)); }

// dial fails on a deadline already passed, as a real dial would
fn dial_int(u: until) -> result[int, str] {
    if until_hit(u) { return err("dial timeout"); }
    return ok(time.mono() as int);
}
fn close_int(v: int) { }
fn alive(v: int) -> bool { return true; }
fn dead(v: int) -> bool { return false; }

fn must[T](r: result[Lease[T], str]) -> Lease[T] {
    guard let l = r else let e = err_of(r) { panic("acquire: " + e); }
    return l;
}

fn test_should_reuse_a_released_connection() {
    let p = new(options(4), dial_int, close_int, alive);
    let a = must(acquire(p, soon()));
    release(p, a);
    let b = must(acquire(p, soon()));
    assert(a.v == b.v, "not the same connection");
    release(p, b);
    let s = stats(p);
    assert(s.dials == 1 && s.reuses == 1 && s.open == 1 && s.idle == 1, "stats");
}

fn holder(p: Pool[int], id: int, order: chan[int]) {
    let l = must(acquire(p, soon()));
    chan_send(order, id);
    time.sleep(ms(5));
    release(p, l);
}

fn test_should_serve_waiters_in_arrival_order() {
    let p = new(options(1), dial_int, close_int, alive);
    let first = must(acquire(p, soon()));
    let order: chan[int] = make_chan(8);
    for id in 0..5 {
        spawn holder(p, id, order);
        time.sleep(ms(10));       // queued one after another
    }
    assert(stats(p).waiting == 5, "waiting " + to_str(stats(p).waiting));
    release(p, first);
    for want in 0..5 {
        let got = chan_recv(order) ?? -1;
        assert(got == want, "served " + to_str(got) + " where " + to_str(want) + " arrived");
    }
    assert(stats(p).open == 1 && stats(p).dials == 1, "more than one connection");
}

fn test_should_time_out_a_waiter_at_its_deadline() {
    let p = new(options(1), dial_int, close_int, alive);
    let held = must(acquire(p, soon()));
    let t0 = time.mono();
    let r = acquire(p, until_of(time.mono() + ms(30)));
    let waited = time.mono() - t0;
    if let _l = r { panic("acquired a held connection"); } else let e = err_of(r) {
        assert(e == "timeout", e);
    }
    assert(waited >= ms(25), "gave up early");
    assert(stats(p).timeouts == 1 && stats(p).waiting == 0, "timeout stats");
    release(p, held);
    // the slot still works afterwards
    release(p, must(acquire(p, soon())));
}

fn test_should_free_the_slot_of_a_failed_dial() {
    let p = new(options(1), dial_int, close_int, alive);
    let r = acquire(p, until_of(time.mono()));
    if let _l = r { panic("dial with an expired deadline succeeded"); }
    assert(stats(p).open == 0, "failed dial kept its slot");
    release(p, must(acquire(p, soon())));
}

fn test_should_probe_and_replace_a_dead_idle_connection() {
    let o = options(2);
    o.probe_after = 0;
    let p = new(o, dial_int, close_int, dead);
    release(p, must(acquire(p, soon())));
    release(p, must(acquire(p, soon())));
    let s = stats(p);
    assert(s.dials == 2 && s.reuses == 0 && s.open == 1, "dead connection reused");
}

fn test_should_close_connections_past_max_lifetime_and_beyond_max_idle() {
    let o = options(4);
    o.max_lifetime = 1;
    let p = new(o, dial_int, close_int, alive);
    let young = must(acquire(p, soon()));
    time.sleep(ms(1));                  // past its 1 ns lifetime on any clock
    release(p, young);
    assert(stats(p).open == 0 && stats(p).idle == 0, "kept past its lifetime");
    let o2 = options(4);
    o2.max_idle = 1;
    let q = new(o2, dial_int, close_int, alive);
    let a = must(acquire(q, soon()));
    let b = must(acquire(q, soon()));
    let c = must(acquire(q, soon()));
    release(q, a);
    release(q, b);
    release(q, c);
    assert(stats(q).idle == 1 && stats(q).open == 1, "kept more than max_idle");
}

fn twice(p: Pool[int]) -> int {
    let l = must(acquire(p, soon()));
    release(p, l);
    release(p, l);
    return 0;
}

fn test_should_panic_on_a_double_release() {
    let p = new(options(2), dial_int, close_int, alive);
    let h = spawn twice(p);
    let r = join_wait(h);
    if let _v = r { panic("double release went unnoticed"); }
}

fn wait_then_report(p: Pool[int], out: chan[str]) {
    let r = acquire(p, soon());
    if let l = r { release(p, l); chan_send(out, "got one"); } else let e = err_of(r) { chan_send(out, e); }
}

fn test_should_fail_waiters_and_new_acquires_on_close() {
    let p = new(options(1), dial_int, close_int, alive);
    let held = must(acquire(p, soon()));
    let out: chan[str] = make_chan(1);
    spawn wait_then_report(p, out);
    time.sleep(ms(10));
    close(p);
    assert((chan_recv(out) ?? "") == "pool is closed", "waiter not failed");
    if let _l = acquire(p, soon()) { panic("acquired from a closed pool"); }
    release(p, held);
    assert(stats(p).open == 0, "in-use connection not closed on release");
}

fn test_should_hand_a_discarded_slot_to_a_waiter() {
    let p = new(options(1), dial_int, close_int, alive);
    let held = must(acquire(p, soon()));
    let out: chan[str] = make_chan(1);
    spawn wait_then_report(p, out);
    time.sleep(ms(10));
    discard(p, held);
    assert((chan_recv(out) ?? "") == "got one", "waiter not given the slot");
    assert(stats(p).dials == 2, "slot not redialled");
}

fn worker(p: Pool[int], n: int, done: chan[int]) {
    let bad = 0;
    for _ in 0..n {
        let r = acquire(p, soon());
        guard let l = r else { bad = bad + 1; continue; }
        release(p, l);
    }
    chan_send(done, bad);
}

fn test_should_stay_within_max_open_under_contention() {
    let p = new(options(4), dial_int, close_int, alive);
    let done: chan[int] = make_chan(64);
    for _ in 0..64 { spawn worker(p, 200, done); }
    let bad = 0;
    for _ in 0..64 { bad = bad + (chan_recv(done) ?? 1); }
    let s = stats(p);
    assert(bad == 0, to_str(bad) + " acquires failed");
    assert(s.dials <= 4 && s.open <= 4, "opened " + to_str(s.dials));
    assert(s.waiting == 0 && s.idle == s.open, "left waiting or leased");
}
