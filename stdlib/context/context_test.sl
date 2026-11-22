import "net";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

fn test_should_keep_the_earlier_deadline_of_parent_and_child() {
    let p = with_timeout(background(), ms(200));
    let k = with_timeout(p, ms(5000));
    let left = remaining(k);
    assert(left > 0 && left <= ms(200), "child kept its own later deadline: " + to_str(left));
    let k2 = with_timeout(p, ms(50));
    assert(remaining(k2) <= ms(50), "child lost its earlier deadline");
    assert(remaining(background()) == -1, "background has a deadline");
    release(k);
    release(k2);
    release(p);
}

fn test_should_cancel_every_descendant_with_the_first_reason() {
    let root = background();
    let a = with_cancel(root);
    let b = with_cancel(a);
    let c = with_timeout(b, ms(10000));
    assert(!is_done(c), "born done");
    cancel(a, "client went away");
    cancel(a, "second reason");
    assert((cause(a) ?? "") == "client went away", "first cancel lost");
    assert((cause(b) ?? "") == "client went away", "child not cancelled");
    assert((cause(c) ?? "") == "client went away", "grandchild not cancelled");
    assert(!is_done(root), "parent cancelled by its child");
    assert(remaining(c) == 0, "remaining after cancel");
}

fn test_should_make_a_cancelled_child_of_a_cancelled_parent() {
    let p = with_cancel(background());
    cancel(p, "gone");
    let k = with_cancel(p);
    assert((cause(k) ?? "") == "gone", "child of cancelled parent is live");
}

fn test_should_drop_released_children_from_the_parent() {
    let p = background();
    for _ in 0..1000 {
        let k = with_cancel(p);
        release(k);
    }
    assert(len(p.children) == 0, "released children kept: " + to_str(len(p.children)));
    let live = with_cancel(p);
    assert(len(p.children) == 1, "live child not kept");
    release(live);
}

fn test_should_report_an_expired_deadline_without_a_cancel() {
    let c = with_timeout(background(), ms(20));
    assert(!is_done(c), "done before its deadline");
    time.sleep(ms(40));
    assert((cause(c) ?? "") == "deadline exceeded", "deadline not reported");
    assert(remaining(c) == 0, "remaining after deadline");
    let z = with_timeout(background(), -5);
    assert(is_done(z), "negative timeout not already past");
}

fn parked_recv(fd: i32, out: chan[str]) {
    let rr = net.recv(fd, 64);
    if let _b = rr { chan_send(out, "data"); } else let e = err_of(rr) { chan_send(out, e); }
}

fn test_should_wake_a_parked_recv_when_cancelled() {
    let l = net.listen(0) ?? (-1 as i32);
    let port = net.port(l) ?? 0;
    let cfd = net.dial("127.0.0.1", port) ?? (-1 as i32);
    let sfd = net.accept(l) ?? (-1 as i32);
    let c = with_cancel(background());
    watch_fd(c, sfd);
    let out: chan[str] = make_chan(1);
    spawn parked_recv(sfd, out);
    time.sleep(ms(30));
    cancel(c, "shutdown");
    let got = chan_recv(out) ?? "nothing";
    assert(got == "closed", "parked recv ended with: " + got);
    net.close(cfd);
    net.close(l);
}

fn test_should_unwatch_an_fd() {
    let c = with_cancel(background());
    watch_fd(c, 12345 as i32);
    assert(unwatch_fd(c, 12345 as i32), "unwatch");
    assert(len(c.fds) == 0, "fd still watched");
    cancel(c, "x");
}

fn waiter(c: Context, out: chan[str]) {
    let never: chan[int] = make_chan(1);
    select {
        case let _v = chan_recv(done_chan(c)) { chan_send(out, cause(c) ?? "?"); }
        case let _w = chan_recv(never) { chan_send(out, "wrong"); }
    }
}

fn test_should_end_a_select_on_the_done_channel() {
    let c = with_cancel(background());
    let out: chan[str] = make_chan(1);
    spawn waiter(c, out);
    time.sleep(ms(20));
    cancel(c, "stop");
    assert((chan_recv(out) ?? "") == "stop", "select did not end on cancel");
    // a done channel asked for after the cancel is already closed
    let late = done_chan(c);
    let v = chan_recv(late);
    if let _x = v { assert(false, "a value on the done channel"); }
}

fn canceller(c: Context, i: int, out: chan[int]) {
    cancel(c, "by " + to_str(i));
    chan_send(out, i);
}

fn test_should_let_exactly_one_of_many_concurrent_cancels_win() {
    let root = background();
    let c = with_cancel(root);
    for _ in 0..50 { let _k = with_cancel(c); }
    let out: chan[int] = make_chan(16);
    for i in 0..16 { spawn canceller(c, i, out); }
    for _ in 0..16 { let _r = chan_recv(out); }
    let r = cause(c) ?? "";
    assert(strings_has_prefix(r, "by "), "reason " + r);
    assert(len(c.children) == 0, "children left after cancel");
    assert(len(root.children) == 0, "root kept the cancelled child");
}

fn strings_has_prefix(s: str, p: str) -> bool {
    return len(s) >= len(p) && to_bytes(s)[0..len(p)] == to_bytes(p);
}
