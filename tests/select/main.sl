// select: wait on several channels at once.
//
// Without it, a task can only ever block on ONE channel, so "take work,
// but stop when told to" had no expression: chan_recv(work) parks until
// work arrives, and a quit signal sitting in another channel cannot
// reach it. That shape is the last section of this file.

// ---- blocking select over two live producers -------------------------
//
// Neither channel is closed, so every one of the 1000 receives below
// genuinely blocks in select until one of the two producers gets there.
// The total is fixed regardless of interleaving, which is the point: the
// test is deterministic about the result and says nothing about order.

fn feed(ch: chan[int], n: int, base: int) {
    for i in 0..n {
        chan_send(ch, base + i);
    }
}

let a: chan[int] = make_chan(8);
let b: chan[int] = make_chan(8);
spawn feed(a, 500, 0);
spawn feed(b, 500, 1000);

let total = 0;
let count = 0;
let from_a = 0;
let from_b = 0;
while count < 1000 {
    select {
        case let v = chan_recv(a) {
            total = total + (v ?? 0);
            from_a = from_a + 1;
            count = count + 1;
        }
        case let w = chan_recv(b) {
            total = total + (w ?? 0);
            from_b = from_b + 1;
            count = count + 1;
        }
    }
}
println(total);           // sum(0..499) + sum(1000..1499)
println(from_a + from_b);
// Both arms must actually fire. If select always picked case 0 when
// both were ready, one of these would be 0 and a closed channel or a
// slow producer would starve the other arm outright.
println(from_a > 0 && from_b > 0);

// ---- default: poll without blocking ----------------------------------

let empty: chan[int] = make_chan(1);
select {
    case let v = chan_recv(empty) { println("FAIL: nothing was sent"); exit(1); }
    default { println("default"); }
}

// ---- send arms -------------------------------------------------------
//
// A send arm is ready when the buffer has room. `small` holds one, so
// the first select sends and the second falls to default.

let small: chan[int] = make_chan(1);
select {
    case chan_send(small, 1) { println("sent"); }
    default { println("FAIL: a fresh chan has room"); exit(1); }
}
select {
    case chan_send(small, 2) { println("FAIL: chan is full"); exit(1); }
    default { println("full"); }
}
println(chan_recv(small) ?? -1);

// ---- a closed channel fires immediately, with none -------------------

let done: chan[int] = make_chan(1);
chan_close(done);
select {
    case let v = chan_recv(done) {
        println(v ?? -7);     // none -> -7
    }
    default { println("FAIL: closed must be ready, not idle"); exit(1); }
}

// ---- the shape this exists for: work, or a quit signal ---------------
//
// The consumer parks on BOTH channels. It cannot be woken by the quit
// signal while sitting in chan_recv(work), which is exactly the bug
// select removes.

fn produce(work: chan[int], n: int) {
    for i in 0..n {
        chan_send(work, i);
    }
}

fn stop(quit: chan[bool]) {
    chan_send(quit, true);
}

let work: chan[int] = make_chan(4);
let quit: chan[bool] = make_chan(1);
spawn produce(work, 20);

let seen = 0;
let running = true;
while running {
    select {
        case let j = chan_recv(work) {
            seen = seen + 1;
            if seen == 20 {
                spawn stop(quit);
            }
        }
        case let q = chan_recv(quit) {
            running = false;
        }
    }
}
println(seen);
println("done");
