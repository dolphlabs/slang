// Idle workers spin before they sleep, a push wakes no one while a worker
// spins and at most one otherwise, and a worker that takes a task while
// more wait wakes the next (sl_runq_spin, sl_runq_wake_one, sl_runq_took).
// None of that may strand a task. tests/run_tests.sh also runs this on 8
// workers, so most of them sleep or spin while three shapes of work come
// and go: bursts of 7 spawns at once (what a network poll does with ready
// connections), a channel ping-pong (each send resumes its partner into a
// runnext slot) and a loopback-socket ping-pong (each byte resumes the
// reader from a network poll onto the run queues). Every task must run and
// every round trip complete.
import "net";

fn ponger(from: chan[int], to: chan[int]) {
    while true {
        let v = chan_recv(from);
        guard let x = v else { return; }
        chan_send(to, x);
        if x < 0 { return; }
    }
}

fn chan_rounds(n: int) -> int {
    let a: chan[int] = make_chan(1);
    let b: chan[int] = make_chan(1);
    spawn ponger(a, b);
    let done = 0;
    let i = 0;
    while i < n {
        chan_send(a, i);
        let v = chan_recv(b);
        guard let x = v else { return done; }
        if x == i {
            done = done + 1;
        }
        i = i + 1;
    }
    chan_send(a, -1);
    let _end = chan_recv(b);
    return done;
}

fn echo(fd: int, n: int) {
    let i = 0;
    while i < n {
        let r = net.recv(fd, 1);
        guard let got = r else { return; }
        if len(got) == 0 { return; }
        let s = net.send(fd, got);
        guard let _sent = s else { return; }
        i = i + 1;
    }
}

fn net_rounds(n: int) -> int {
    let lr = net.listen(0);
    guard let lfd = lr else { return -1; }
    let pr = net.port(lfd);
    guard let port = pr else { return -1; }
    let dr = net.dial("127.0.0.1", port as int);
    guard let cfd = dr else { return -1; }
    let ar = net.accept(lfd);
    guard let sfd = ar else { return -1; }
    spawn echo(sfd as int, n);
    let done = 0;
    let i = 0;
    while i < n {
        let s = net.send(cfd as int, b"x");
        guard let _sent = s else { return done; }
        let r = net.recv(cfd as int, 1);
        guard let got = r else { return done; }
        if got == b"x" {
            done = done + 1;
        }
        i = i + 1;
    }
    net.close(cfd as int);
    net.close(sfd as int);
    net.close(lfd as int);
    return done;
}

fn leaf(i: int, out: chan[int]) {
    chan_send(out, i);
}

// Bursts like a network poll's: one task makes 7 others runnable at
// once while the rest of the workers sleep.
fn bursts(n: int, width: int) -> int {
    let out: chan[int] = make_chan(width);
    let done = 0;
    let r = 0;
    while r < n {
        let i = 0;
        while i < width {
            spawn leaf(i, out);
            i = i + 1;
        }
        i = 0;
        while i < width {
            let v = chan_recv(out);
            guard let _x = v else { return done; }
            done = done + 1;
            i = i + 1;
        }
        r = r + 1;
    }
    return done;
}

println("burst tasks: " + to_str(bursts(3000, 7)));
println("chan round trips: " + to_str(chan_rounds(20000)));
println("net round trips: " + to_str(net_rounds(5000)));
