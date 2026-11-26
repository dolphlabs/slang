import "time";

// ---- 1. after(ns) fires when channel stays empty ----

let ch1: chan[int] = make_chan(1);
let t0 = time.mono();
let hit1 = false;
select {
    case let v = chan_recv(ch1) {
        println("FAIL: unexpected recv");
        exit(1);
    }
    case after(15000000) {
        hit1 = true;
    }
}
let dt = time.mono() - t0;
println(hit1);
println(dt >= 12000000);

// ---- 2. after(0) and after(-5) fire immediately ----

let zero_ok = false;
select {
    case let v = chan_recv(ch1) { exit(1); }
    case after(0) { zero_ok = true; }
}
let neg_ok = false;
select {
    case let v = chan_recv(ch1) { exit(1); }
    case after(-5) { neg_ok = true; }
}
println(zero_ok);
println(neg_ok);

// ---- 3. ready channel beats long after() without sleeping ----

chan_send(ch1, 42);
let t1 = time.mono();
let got3 = 0;
select {
    case let v = chan_recv(ch1) { got3 = v ?? -1; }
    case after(5000000000) { println("FAIL: long timeout"); exit(1); }
}
println(got3);
println(time.mono() - t1 < 1000000000);

// ---- 4. until(deadline) and until(until_never()) ----

let dl = until_of(time.mono() + 15000000);
let hit_until = false;
select {
    case let v = chan_recv(ch1) { exit(1); }
    case until(until_never()) { println("FAIL: until_never fired"); exit(1); }
    case until(dl) { hit_until = true; }
}
println(hit_until);

let never_fallback = false;
select {
    case let v = chan_recv(ch1) { exit(1); }
    case until(until_never()) { println("FAIL: until_never fired 2"); exit(1); }
    default { never_fallback = true; }
}
println(never_fallback);

// ---- 5. when guard short-circuits val/ch evaluation ----

let xs: [int] = [];
let send_ch: chan[int] = make_chan(1);
let took_default = false;
select {
    case chan_send(send_ch, xs[0]) when len(xs) > 0 {
        println("FAIL: disabled send fired");
        exit(1);
    }
    default {
        took_default = true;
    }
}
println(took_default);

// ---- 6. when disables a closed channel in a loop without spinning ----

fn drain_helper(a: chan[int], b: chan[int]) {
    chan_close(a);
    chan_send(b, 10);
    chan_send(b, 20);
    chan_send(b, 30);
    chan_close(b);
}

let ha: chan[int] = make_chan(1);
let hb: chan[int] = make_chan(4);
spawn drain_helper(ha, hb);
let open_a = true;
let open_b = true;
let sum = 0;
let iters = 0;
while open_a || open_b {
    iters = iters + 1;
    select {
        case let va = chan_recv(ha) when open_a {
            if let x = va {
                sum = sum + x;
            } else {
                open_a = false;
            }
        }
        case let vb = chan_recv(hb) when open_b {
            if let y = vb {
                sum = sum + y;
            } else {
                open_b = false;
            }
        }
    }
}
println(sum);
println(iters);

// ---- 7. all arms disabled with default falls through ----

let f = false;
let hit_def = false;
select {
    case let v = chan_recv(ch1) when f { exit(1); }
    case after(1000000) when f { exit(1); }
    default { hit_def = true; }
}
println(hit_def);

// ---- 8. GC stress with str payloads, when, and after timeouts ----

fn alloc_guard(i: int) -> bool {
    let tmp = "guard-" + to_str(i) + "-" + to_str(i * 2);
    return len(tmp) > 0;
}

fn str_ping(req: chan[str], resp: chan[str], n: int) {
    for i in 0..n {
        if let s = chan_recv(req) {
            chan_send(resp, s + ":ok");
        }
    }
}

let req: chan[str] = make_chan(2);
let resp: chan[str] = make_chan(2);
spawn str_ping(req, resp, 400);
let s_count = 0;
let sent_count = 0;
let timeout_count = 0;
while s_count < 400 {
    select {
        case chan_send(req, "item-" + to_str(sent_count)) when sent_count < 400 {
            sent_count = sent_count + 1;
        }
        case let got = chan_recv(resp) when alloc_guard(s_count) {
            if let txt = got {
                if len(txt) > 0 {
                    s_count = s_count + 1;
                }
            }
        }
        case after(200000000) when alloc_guard(s_count) {
            timeout_count = timeout_count + 1;
            println("FAIL: unexpected gc timeout");
            exit(1);
        }
    }
}
println(s_count);
println(timeout_count);
