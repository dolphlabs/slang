import "net";
import "time";
import "os";
import "strings";

// net.dial_until, net.dial_unix / listen_unix, net.tls_upgrade_until.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn in_ms(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

fn listener() -> i32 {
    let lr = net.listen(0);
    guard let lfd = lr else {
        die("listen");
        return -1 as i32;
    }
    return lfd;
}

fn port_of(lfd: i32) -> int {
    return net.port(lfd) ?? (0 as i32);
}

fn accept_all(lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else {
            return;
        }
        net.close(fd);
    }
}

// Is fd 0 open? getsockname on it fails with ENOTSOCK when it is (whatever
// stdin is) and EBADF when it is not; unlike a read it never blocks.
fn fd0_open() -> bool {
    let r = net.port(0);
    guard let p = r else let e = err_of(r) {
        return !strings.contains(e, "Bad file descriptor");
    }
    return true;
}

// ---- dial_until ------------------------------------------------------

fn dial() {
    let lfd = listener();
    let port = port_of(lfd);
    spawn accept_all(lfd);

    let ok_r = net.dial_until("localhost", port, in_ms(5000));
    guard let fd = ok_r else let e = err_of(ok_r) {
        die("dial_until: " + e);
        return;
    }
    net.close(fd);

    // a deadline already passed fails before any lookup or connect
    let late = net.dial_until("localhost", port, until_of(time.mono() - 1));
    guard let x = late else let e = err_of(late) {
        if e != "timeout" {
            die("expired deadline: " + e);
        }
        // a closed port is still refused, not a timeout
        let closed = listener();
        let cport = port_of(closed);
        net.close(closed);
        let ref = net.dial_until("127.0.0.1", cport, in_ms(5000));
        guard let y = ref else let e2 = err_of(ref) {
            if !strings.contains(strings.to_lower(e2), "refused") {
                die("closed port: " + e2);
            }
            println("ok dial_until");
            return;
        }
        die("dial to a closed port succeeded");
        return;
    }
    die("dial with an expired deadline succeeded");
}

// The time one dial takes here, in ns: the median of a few. A lookup plus
// connect to localhost is a few hundred microseconds on a laptop and about
// a millisecond in a Linux VM, so no fixed range of deadlines is right on
// both -- 0-400us made every dial time out on the slow one.
fn dial_scale(port: int) -> int {
    let samples: [int] = [];
    let k = 0;
    while k < 15 {
        let t0 = time.mono();
        let r = net.dial_until("localhost", port, in_ms(5000));
        let took: int = (time.mono() - t0) as int;
        guard let fd = r else let e = err_of(r) {
            die("calibration dial: " + e);
            return 0;
        }
        net.close(fd);
        push(samples, took);
        k = k + 1;
    }
    // insertion sort; 15 elements
    let a = 1;
    while a < len(samples) {
        let v = samples[a];
        let b = a - 1;
        while b >= 0 && samples[b] > v {
            samples[b + 1] = samples[b];
            b = b - 1;
        }
        samples[b + 1] = v;
        a = a + 1;
    }
    return samples[len(samples) / 2];
}

// Deadlines spread across the time a dial takes, so that some lookups are
// still inside getaddrinfo when they pass: the job is abandoned to the
// resolver thread, which must free it without touching the caller's stack.
// Every result is either a connection or "timeout", and both must occur --
// which is why the range is measured rather than fixed.
fn dial_racing() {
    let lfd = listener();
    let port = port_of(lfd);
    spawn accept_all(lfd);
    // 0 .. 3x the median, in 400 steps. The first step is a deadline that
    // has already passed, so timeouts cannot be zero; the top third is long
    // enough that dials get through even when the median is unrepresentative.
    let step = 3 * dial_scale(port) / 400;
    if step < 1 {
        step = 1;
    }
    let timeouts = 0;
    let conns = 0;
    let i = 0;
    while i < 3000 {
        let r = net.dial_until("localhost", port,
                               until_of(time.mono() + (i % 400) * step));
        guard let fd = r else let e = err_of(r) {
            if e != "timeout" {
                die("racing dial: " + e);
            }
            timeouts = timeouts + 1;
            i = i + 1;
            continue;
        }
        net.close(fd);
        conns = conns + 1;
        i = i + 1;
    }
    if timeouts + conns != 3000 || timeouts == 0 || conns == 0 {
        die("racing dial counts: " + to_str(timeouts) + " timeouts, "
            + to_str(conns) + " connections");
    }
    println("ok dial racing deadlines");
}

// ---- Unix-domain sockets ---------------------------------------------

fn echo_once(lfd: i32) {
    let ar = net.accept(lfd);
    guard let fd = ar else {
        return;
    }
    let rr = net.recv_until(fd, 64, in_ms(5000));
    guard let b = rr else {
        net.close(fd);
        return;
    }
    net.send(fd, b"echo:" + b);
    net.close(fd);
}

fn unix_sockets() {
    let path = "/tmp/sl_unix_" + to_str(os.pid()) + ".sock";
    os.remove(path);
    let lr = net.listen_unix(path);
    guard let lfd = lr else let e = err_of(lr) {
        die("listen_unix: " + e);
        return;
    }
    spawn echo_once(lfd);
    let dr = net.dial_unix(path, in_ms(5000));
    guard let fd = dr else let e = err_of(dr) {
        die("dial_unix: " + e);
        return;
    }
    net.send_until(fd, b"hi", in_ms(5000));
    let got = net.recv_until(fd, 64, in_ms(5000)) ?? b"";
    if got != b"echo:hi" {
        die("unix echo: " + to_str(got));
    }
    net.close(fd);

    // an existing file is refused, not replaced
    let again = net.listen_unix(path);
    guard let a = again else let e = err_of(again) {
        if !strings.contains(e, "in use") {
            die("listen on an existing path: " + e);
        }
        net.close(lfd);
        os.remove(path);
        let missing = net.dial_unix(path, in_ms(5000));
        guard let m = missing else let e2 = err_of(missing) {
            if !strings.contains(e2, "No such file") {
                die("missing socket: " + e2);
            }
            let long = net.dial_unix("/tmp/" + strings.repeat("x", 200), in_ms(5000));
            guard let l = long else let e3 = err_of(long) {
                if e3 != "socket path too long" {
                    die("long path: " + e3);
                }
                println("ok unix sockets");
                return;
            }
            die("dial to an overlong path succeeded");
            return;
        }
        die("dial to a missing socket succeeded");
        return;
    }
    die("listen_unix replaced an existing socket file");
}

// ---- tls_upgrade_until ------------------------------------------------

// Accepts, and never says a word: a handshake that cannot finish.
fn silent(lfd: i32, done: chan[bool]) {
    let ar = net.accept(lfd);
    guard let fd = ar else {
        return;
    }
    chan_recv(done);
    net.close(fd);
}

fn tls_deadline() {
    let lfd = listener();
    let done: chan[bool] = make_chan(1);
    spawn silent(lfd, done);
    let dr = net.dial_until("127.0.0.1", port_of(lfd), in_ms(5000));
    guard let fd = dr else let e = err_of(dr) {
        die("dial: " + e);
        return;
    }
    let cr = net.tls_client_ctx("");
    guard let ctx = cr else let e = err_of(cr) {
        die("ctx: " + e);
        return;
    }
    let t0 = time.mono();
    let ur = net.tls_upgrade_until(fd, "localhost", ctx, in_ms(200));
    let took = time.mono() - t0;
    chan_send(done, true);
    guard let ssl = ur else let e = err_of(ur) {
        if e != "timeout" || took > 3000000000 {
            die("handshake deadline: " + e);
        }
        net.close(fd);      // still the caller's after a failure
        println("ok tls handshake deadline");
        return;
    }
    die("handshake with a silent server succeeded");
}

dial();
let had_stdin = fd0_open();
dial_racing();
// The resolver thread hands each lookup back to its caller and must never
// touch it afterwards: a late read of a freed job once turned into
// close(0), which took stdin and then, once socket() reused fd 0, a live
// connection with it.
if had_stdin && !fd0_open() {
    die("fd 0 was closed under the program");
}
unix_sockets();
tls_deadline();
