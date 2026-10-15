// A joined spawn runs in place on the spawner (sl_protect_run), and a
// panic inside it comes back to the join_wait instead of ending the task.
// What that has to survive, each checked by carrying on afterwards:
// - many panics in a row, with collections between them (the safepoint
//   chain and the preemption depth are restored each time);
// - a stack that grew inside the call before it panicked (the saved
//   registers point into the old stack until relocation translates them);
// - a protected call inside a protected call;
// - a call that parks on a channel and is resumed;
// - all of it from the main task as well as from a spawned one.

gc struct Cell { v: int, label: str }

fn fail_at(i: int) -> int {
    let c = Cell { v: i, label: "cell " + to_str(i) };
    if i % 3 == 0 {
        panic("planned " + c.label);
    }
    return c.v;
}

fn deep(n: int, fail: bool) -> int {
    let pad = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7];
    if n == 0 {
        if fail {
            panic("deep end");
        }
        return pad[0];
    }
    return deep(n - 1, fail) + pad[7] - pad[6];
}

fn inner_fails() -> int {
    let h = spawn fail_at(3);
    let r = join_wait(h);
    if let v = r {
        return v;
    }
    return -1;
}

fn outer() -> int {
    let h = spawn inner_fails();
    let r = join_wait(h);
    return (r ?? -100) * 10;
}

fn recv_one(ch: chan[int]) -> int {
    let r = chan_recv(ch);
    guard let v = r else { panic("closed"); }
    return v;
}

fn sender(ch: chan[int]) {
    chan_send(ch, 42);
}

fn exercise(who: str) -> str {
    let ok = 0;
    let failed = 0;
    let i = 0;
    while i < 3000 {
        let h = spawn fail_at(i);
        let r = join_wait(h);
        if let v = r {
            if v != i { panic("wrong value"); }
            ok = ok + 1;
        } else let e = err_of(r) {
            if e != "planned cell " + to_str(i) + " at joined_spawn_protect.fail_at:17" {
                panic("wrong err: " + e);
            }
            failed = failed + 1;
        }
        i = i + 1;
    }
    // A deep stack inside the call, then a panic out of it.
    let hd = spawn deep(20000, true);
    let rd = join_wait(hd);
    let deep_failed = (rd ?? -1) < 0;
    let hd2 = spawn deep(20000, false);
    let deep_ok = join_wait(hd2) ?? -1;
    let nested = outer();
    let ch: chan[int] = make_chan(0);
    spawn sender(ch);
    let hr = spawn recv_one(ch);
    let got = join_wait(hr) ?? -1;
    return who + ": ok " + to_str(ok) + ", failed " + to_str(failed) +
           ", deep failed " + to_str(deep_failed) + ", deep " + to_str(deep_ok) +
           ", nested " + to_str(nested) + ", parked " + to_str(got);
}

println(exercise("main"));
let h = spawn exercise("task");
println(join_wait(h) ?? "task lost");
