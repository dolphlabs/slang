import "time";

fn ms(n: int) -> int { return n * 1000000; }

gc struct Backend {
    mu: mutex,
    calls: int,
    delay: int,
    fail: bool,
    blow_up: bool,
}

fn backend(delay: int) -> Backend {
    return Backend { mu: make_mutex(), calls: 0, delay: delay, fail: false, blow_up: false };
}

fn load(b: Backend, u: until) -> result[int, str] {
    mutex_lock(b.mu);
    b.calls = b.calls + 1;
    let n = b.calls;
    mutex_unlock(b.mu);
    time.sleep(b.delay);
    if b.blow_up { panic("backend exploded"); }
    if b.fail { return err("backend down"); }
    return ok(n * 100);
}

fn caller(g: Group[Backend, int], key: str, b: Backend, out: chan[str]) {
    let r = call(g, key, b, until_never());
    if let v = r { chan_send(out, to_str(v)); } else let e = err_of(r) { chan_send(out, "err " + e); }
}

fn test_should_run_once_for_concurrent_calls_and_share_the_answer() {
    let g = group(load);
    let b = backend(ms(50));
    let out: chan[str] = make_chan(32);
    for _ in 0..20 { spawn caller(g, "k", b, out); }
    for _ in 0..20 {
        let got = chan_recv(out) ?? "";
        assert(got == "100", "answer " + got);
    }
    assert(b.calls == 1, "backend called " + to_str(b.calls) + " times");
    assert(runs(g) == 1 && joins(g) == 19, "runs/joins");
}

fn test_should_run_again_once_the_call_finished() {
    let g = group(load);
    let b = backend(0);
    assert((call(g, "k", b, until_never()) ?? 0) == 100, "first");
    assert((call(g, "k", b, until_never()) ?? 0) == 200, "second did not run anew");
}

fn test_should_keep_keys_apart() {
    let g = group(load);
    let b = backend(ms(30));
    let out: chan[str] = make_chan(4);
    spawn caller(g, "a", b, out);
    spawn caller(g, "b", b, out);
    let _x = chan_recv(out);
    let _y = chan_recv(out);
    assert(b.calls == 2, "keys shared a call");
}

fn test_should_share_an_error() {
    let g = group(load);
    let b = backend(ms(30));
    b.fail = true;
    let out: chan[str] = make_chan(8);
    for _ in 0..5 { spawn caller(g, "k", b, out); }
    for _ in 0..5 { assert((chan_recv(out) ?? "") == "err backend down", "error not shared"); }
    assert(b.calls == 1, "retried per caller");
}

fn test_should_answer_waiters_when_the_call_panics() {
    let g = group(load);
    let b = backend(ms(30));
    b.blow_up = true;
    let out: chan[str] = make_chan(8);
    for _ in 0..4 { spawn caller(g, "k", b, out); }
    for _ in 0..4 {
        let got = chan_recv(out) ?? "";
        assert(len(got) > 4 && to_bytes(got)[0..4] == b"err ", "waiter got " + got);
    }
    b.blow_up = false;
    assert((call(g, "k", b, until_never()) ?? 0) > 0, "group unusable after a panic");
}

fn test_should_run_anew_after_forget() {
    let g = group(load);
    let b = backend(ms(60));
    let out: chan[str] = make_chan(4);
    spawn caller(g, "k", b, out);
    time.sleep(ms(10));
    forget(g, "k");
    spawn caller(g, "k", b, out);
    let _x = chan_recv(out);
    let _y = chan_recv(out);
    assert(b.calls == 2, "forget did not start a new call");
}
