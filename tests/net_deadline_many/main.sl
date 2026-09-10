// Many concurrent deadlines, registered out of order.
//
// This is the test for the nudge-skip optimisation in the reactor: a
// waiter only wakes the reactor when the reactor is not already due to
// wake soon enough to see it. Get that wrong in the skipping direction
// and a deadline never fires at all -- the task hangs forever and the
// only symptom is a test that never finishes.
//
// Each task gets its own connection (the reactor allows one waiter per
// fd+direction) and its own staggered deadline, so both branches run:
// the first registration finds an idle reactor and nudges, later ones
// with longer deadlines find it already armed and skip.

import "net";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

fn waiter(fd: int, budget: int, done: chan[int]) {
    let t0 = time.mono();
    let r = net.recv_until(fd, 64, until_of(time.mono() + budget));
    let waited = time.mono() - t0;
    guard let _d = r else let e = err_of(r) {
        if e != "timeout" {
            chan_send(done, -1);
            return;
        }
        // Fired, and fired at roughly the right time rather than
        // immediately or via some unrelated event.
        if waited < budget - ms(40) {
            chan_send(done, -2);
            return;
        }
        chan_send(done, 1);
        return;
    }
    chan_send(done, -3);
}

fn run() {
    let lr = net.listen(0);
    guard let lfd = lr else { println("FAIL listen"); exit(1); }
    let pr = net.port(lfd);
    guard let port = pr else { println("FAIL port"); exit(1); }

    let n = 24;
    let done: chan[int] = make_chan(n);
    let served: [int] = [];

    // Deadlines deliberately not monotonic in spawn order: descending
    // for the first half, ascending for the second, so a later
    // registration is sometimes sooner than the reactor's armed wake
    // time and sometimes later.
    let i = 0;
    while i < n {
        let dr = net.dial("127.0.0.1", port);
        guard let cfd = dr else { println("FAIL dial"); exit(1); }
        let ar = net.accept(lfd);
        guard let sfd = ar else { println("FAIL accept"); exit(1); }
        push(served, sfd);
        push(served, cfd);
        let budget = ms(300) - i * ms(8);
        if i >= 12 {
            budget = ms(120) + i * ms(8);
        }
        spawn waiter(sfd, budget, done);
        i = i + 1;
    }

    let ok = 0;
    let j = 0;
    while j < n {
        let vr = chan_recv(done);
        guard let v = vr else { println("FAIL channel closed"); exit(1); }
        if v == 1 {
            ok = ok + 1;
        } else {
            println("FAIL waiter returned " + to_str(v));
            exit(1);
        }
        j = j + 1;
    }
    if ok != n { println("FAIL count"); exit(1); }

    let k = 0;
    while k < len(served) {
        net.close(served[k]);
        k = k + 1;
    }
    net.close(lfd);
    println("all deadlines fired");
}

run();
