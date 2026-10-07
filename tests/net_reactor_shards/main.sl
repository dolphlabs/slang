// Waiters on many fds at once, so every one of the reactor's per-fd
// lists holds some: half are sent data, half time out, and each must be
// resumed exactly once, by the right event. The data path finds a task
// through the list tag in its registration; the timeout path reaches it
// through the deadline scan of every list and the wake-time protocol
// (sl_reactor_wake_at), with no single lock covering them all. A missed
// nudge hangs a waiter; a double resume or a wrong list shows as a
// wrong count. Run again under forced preemption by tests/run_tests.sh.

import "net";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

// 1: got the byte, 2: timed out on time, negative: anything else.
fn waiter(fd: int, expect_data: bool, budget: int, done: chan[int]) {
    let t0 = time.mono();
    let r = net.recv_until(fd, 64, until_of(time.mono() + budget));
    let waited = time.mono() - t0;
    guard let got = r else let e = err_of(r) {
        if e != "timeout" || expect_data {
            chan_send(done, -1);
            return;
        }
        if waited < budget - ms(40) {
            chan_send(done, -2);
            return;
        }
        chan_send(done, 2);
        return;
    }
    if !expect_data || len(got) != 1 {
        chan_send(done, -3);
        return;
    }
    chan_send(done, 1);
}

fn run() {
    let lr = net.listen(0);
    guard let lfd = lr else { println("FAIL listen"); exit(1); }
    let pr = net.port(lfd);
    guard let port = pr else { println("FAIL port"); exit(1); }

    let n = 64;
    let done: chan[int] = make_chan(n);
    let servers: [int] = [];
    let clients: [int] = [];
    let i = 0;
    while i < n {
        let dr = net.dial("127.0.0.1", port);
        guard let cfd = dr else { println("FAIL dial"); exit(1); }
        let ar = net.accept(lfd);
        guard let sfd = ar else { println("FAIL accept"); exit(1); }
        push(servers, sfd);
        push(clients, cfd);
        // Odd waiters get data well before their deadline; even ones
        // time out, at deadlines spread so many lists hold one.
        let budget = ms(150) + (i % 8) * ms(10);
        if i % 2 == 1 {
            budget = ms(5000);
        }
        spawn waiter(sfd, i % 2 == 1, budget, done);
        i = i + 1;
    }
    time.sleep(ms(30));
    i = 1;
    while i < n {
        let sr = net.send(clients[i], to_bytes("x"));
        guard let _s = sr else { println("FAIL send"); exit(1); }
        i = i + 2;
    }

    let got = 0;
    let timed = 0;
    let j = 0;
    while j < n {
        let vr = chan_recv(done);
        guard let v = vr else { println("FAIL channel closed"); exit(1); }
        if v == 1 {
            got = got + 1;
        } else if v == 2 {
            timed = timed + 1;
        } else {
            println("FAIL waiter returned " + to_str(v));
            exit(1);
        }
        j = j + 1;
    }
    println("data " + to_str(got) + " timeouts " + to_str(timed));
    let k = 0;
    while k < n {
        net.close(servers[k]);
        net.close(clients[k]);
        k = k + 1;
    }
    net.close(lfd);
}

run();
