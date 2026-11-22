fn addrs() -> [str] { return ["a:1", "b:1", "c:1"]; }

fn take(lb: Balancer, key: str) -> Pick {
    let r = pick(lb, key);
    guard let p = r else let e = err_of(r) { panic(e); }
    return p;
}

fn test_should_rotate_in_order() {
    let lb = new(addrs(), ROUND_ROBIN);
    let got = "";
    for _ in 0..6 { let p = take(lb, ""); got = got + p.addr + " "; done(lb, p, true, 1000); }
    assert(got == "a:1 b:1 c:1 a:1 b:1 c:1 ", got);
}

fn test_should_prefer_the_least_loaded() {
    let lb = new(addrs(), LEAST);
    let p1 = take(lb, "");
    let p2 = take(lb, "");
    let p3 = take(lb, "");
    assert(p1.addr != p2.addr && p2.addr != p3.addr && p1.addr != p3.addr, "spread over all three");
    done(lb, p2, true, 1000);
    assert(take(lb, "").addr == p2.addr, "not the idle one");
}

fn test_should_steer_p2c_away_from_slow_and_busy_backends() {
    let o = options(P2C);
    let lb = with_options(["fast", "slow"], o);
    // teach it: fast takes 1 ms, slow 100 ms
    for _ in 0..20 {
        let p = take(lb, "");
        let lat = 1000000;
        if p.addr == "slow" { lat = 100000000; }
        done(lb, p, true, lat);
    }
    let fast = 0;
    for _ in 0..200 {
        let p = take(lb, "");
        if p.addr == "fast" { fast = fast + 1; }
        done(lb, p, true, 1000000);
    }
    // with two backends P2C compares both whenever it draws both; the
    // slow one wins only when drawn twice: about a quarter of the time
    assert(fast > 120, "fast chosen " + to_str(fast) + " of 200");
}

fn test_should_keep_keys_on_their_backend_and_fail_over_when_ejected() {
    let o = options(HASH);
    o.eject_after = 1;
    let lb = with_options(addrs(), o);
    let home = take(lb, "user-42");
    done(lb, home, true, 1);
    for _ in 0..5 {
        let p = take(lb, "user-42");
        assert(p.addr == home.addr, "key moved");
        done(lb, p, true, 1);
    }
    let bad = take(lb, "user-42");
    done(lb, bad, false, 1);                   // ejects home
    let moved = take(lb, "user-42");
    assert(moved.addr != home.addr, "ejected backend still picked");
    done(lb, moved, true, 1);
}

fn test_should_eject_after_consecutive_failures_and_report_none_up() {
    let o = options(ROUND_ROBIN);
    o.eject_after = 2;
    o.eject_ns = 50000000;
    let lb = with_options(["only"], o);
    let a = take(lb, "");
    done(lb, a, false, 1);
    let b = take(lb, "");
    done(lb, b, false, 1);
    if let _p = pick(lb, "") { panic("picked an ejected backend"); }
    assert(!status(lb)[0].up, "status says up");
}

fn test_should_keep_state_across_backend_changes() {
    let lb = new(addrs(), LEAST);
    let p = take(lb, "");
    set_backends(lb, ["x:1", p.addr]);
    let st = status(lb);
    assert(len(st) == 2, "backends");
    let kept = st[0].in_flight + st[1].in_flight;
    assert(kept == 1, "in-flight count lost");
    done(lb, p, true, 10);
    assert(status(lb)[1].in_flight == 0, "done after the change");
}
