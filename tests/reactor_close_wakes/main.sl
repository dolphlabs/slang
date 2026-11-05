// Closing an fd drops its reactor registration with no event, so a task
// parked on it used to wait forever, and a later wait on the reused number
// overwrote its slot. net.close wakes whoever is parked, read and write
// alike, and the number's next owner keeps its own wait.
import "net";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

fn watchdog(n: int) {
    time.sleep(ms(n));
    println("FAIL a parked task was not woken by close");
    exit(1);
}

fn conn(lfd: int, port: int) -> [int] {
    let dr = net.dial("127.0.0.1", port);
    guard let c = dr else let e = err_of(dr) { println("dial: " + e); exit(1); }
    let ar = net.accept(lfd);
    guard let s = ar else let e = err_of(ar) { println("accept: " + e); exit(1); }
    return [c as int, s as int];
}

fn reader(fd: int, out: chan[str]) {
    let r = net.recv(fd, 16);
    if let _b = r {
        chan_send(out, "data");
    } else let e = err_of(r) {
        chan_send(out, e);
    }
}

fn acceptor(fd: int, out: chan[str]) {
    let r = net.accept(fd);
    if let _c = r {
        chan_send(out, "accepted");
    } else let e = err_of(r) {
        chan_send(out, e);
    }
}

// Sends until the peer's window is full, then parks for write. The close
// may land between two sends instead of on the park, so what this reports
// is that the send ended, not which of the two errors ended it.
fn writer(fd: int, out: chan[str]) {
    let block = b"0123456789abcdef0123456789abcdef";
    for i in 0..14 {
        block = block + block;
    }
    while true {
        let r = net.send(fd, block);
        guard let _n = r else {
            chan_send(out, "ended");
            return;
        }
    }
}

fn expect(ch: chan[str], what: str) {
    let v = chan_recv(ch);
    println(what + ": " + (v ?? "channel closed"));
}

spawn watchdog(5000);
let lr = net.listen(0);
guard let lfd = lr else let e = err_of(lr) { println("listen: " + e); exit(1); }
let pr = net.port(lfd);
guard let port = pr else { println("port"); exit(1); }

let read_out: chan[str] = make_chan(1);
let a = conn(lfd, port);
spawn reader(a[0], read_out);
time.sleep(ms(30));
net.close(a[0]);
expect(read_out, "parked read");

let write_out: chan[str] = make_chan(1);
let b = conn(lfd, port);
spawn writer(b[0], write_out);
time.sleep(ms(100));
net.close(b[0]);
expect(write_out, "parked write");

let accept_out: chan[str] = make_chan(1);
let l2r = net.listen(0);
guard let l2 = l2r else { println("listen 2"); exit(1); }
spawn acceptor(l2 as int, accept_out);
time.sleep(ms(30));
net.close(l2 as int);
expect(accept_out, "parked accept");

// The number's next owner: the closed wait must not have left anything
// behind that takes this read's wakeups or its deadline.
let c = conn(lfd, port);
let reuse_out: chan[str] = make_chan(1);
spawn reader(c[0], reuse_out);
time.sleep(ms(30));
net.close(c[0]);
expect(reuse_out, "before reuse");
let d = conn(lfd, port);
println("number reused: ${d[0] == c[0]}");
let silent = net.recv_until(d[0], 16, until_of(time.mono() + ms(50)));
if let _x = silent {
    println("FAIL data on a silent connection");
} else let e = err_of(silent) {
    println("deadline on reused number: " + e);
}
let _s = net.send(d[1], b"z");
let got = net.recv_until(d[0], 16, until_of(time.mono() + ms(2000)));
guard let z = got else let e = err_of(got) { println("FAIL recv: " + e); exit(1); }
let same = z == b"z";
println("event on reused number: ${same}");
exit(0);
