// One task reads an fd while another writes it. epoll has one registration
// per fd, so the second direction's wait used to replace the first's
// interest: the first waiter was never woken, however ready its direction
// was. kqueue, one knote per filter, always passed this. The registration is
// also one-shot as a whole, so the event for one direction disarms the other
// and the waiter left behind has to be re-armed, even when that event wakes
// nobody because its waiter has already gone.
import "net";
import "time";

// More than loopback will buffer: this send parks until the peer drains it.
fn big_block() -> bytes {
    let block = b"0123456789abcdef0123456789abcdef";
    for i in 0..18 {
        block = block + block;
    }
    return block;
}

fn ms(n: int) -> int { return n * 1000000; }

fn watchdog(n: int) {
    time.sleep(ms(n));
    println("FAIL a waiter on a duplex fd was not woken");
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
    guard let b = r else {
        chan_send(out, "ended");
        return;
    }
    if len(b) > 0 {
        chan_send(out, "data");
    } else {
        chan_send(out, "ended");
    }
}

fn deadline_reader(fd: int, wait: int, out: chan[str]) {
    let r = net.recv_until(fd, 16, until_of(time.mono() + ms(wait)));
    if let _b = r {
        chan_send(out, "data");
    } else let e = err_of(r) {
        chan_send(out, e);
    }
}

fn writer(fd: int, data: bytes, out: chan[str]) {
    let r = net.send(fd, data);
    if let _n = r {
        chan_send(out, "sent");
    } else {
        chan_send(out, "ended");
    }
}

fn drain(fd: int, want: int) {
    let got = 0;
    while got < want {
        let r = net.recv(fd, 65536);
        guard let b = r else let e = err_of(r) { println("drain: " + e); exit(1); }
        if len(b) == 0 {
            println("drain: early eof");
            exit(1);
        }
        got = got + len(b);
    }
}

fn poke(fd: int) {
    let r = net.send(fd, b"z");
    guard let _n = r else let e = err_of(r) { println("poke: " + e); exit(1); }
}

fn expect(ch: chan[str], what: str) {
    let v = chan_recv(ch);
    println(what + ": " + (v ?? "channel closed"));
}

spawn watchdog(10000);
let lr = net.listen(0);
guard let lfd = lr else let e = err_of(lr) { println("listen: " + e); exit(1); }
let pr = net.port(lfd);
guard let port = pr else { println("port"); exit(1); }
let block = big_block();

// The write wait comes second: its registration must keep the read's interest.
let a = conn(lfd, port);
let a_read: chan[str] = make_chan(1);
let a_write: chan[str] = make_chan(1);
spawn reader(a[0], a_read);
time.sleep(ms(30));
spawn writer(a[0], block, a_write);
time.sleep(ms(100));
poke(a[1]);
expect(a_read, "read first, read woken");
drain(a[1], len(block));
expect(a_write, "read first, write woken");

// The read wait comes second, and the write is the one that finishes first.
let b = conn(lfd, port);
let b_read: chan[str] = make_chan(1);
let b_write: chan[str] = make_chan(1);
spawn writer(b[0], block, b_write);
time.sleep(ms(100));
spawn reader(b[0], b_read);
time.sleep(ms(30));
drain(b[1], len(block));
expect(b_write, "write first, write woken");
poke(b[1]);
expect(b_read, "write first, read woken");

// A read that left by its deadline stays in the registration. The event it
// no longer waits for wakes nobody and still disarms the parked write.
let c = conn(lfd, port);
let c_read: chan[str] = make_chan(1);
let c_write: chan[str] = make_chan(1);
spawn writer(c[0], block, c_write);
time.sleep(ms(100));
spawn deadline_reader(c[0], 50, c_read);
expect(c_read, "abandoned read");
poke(c[1]);
time.sleep(ms(30));
drain(c[1], len(block));
expect(c_write, "abandoned read, write woken");

// One event for both directions.
let d = conn(lfd, port);
let d_read: chan[str] = make_chan(1);
let d_write: chan[str] = make_chan(1);
spawn reader(d[0], d_read);
time.sleep(ms(30));
spawn writer(d[0], block, d_write);
time.sleep(ms(100));
net.close(d[1]);
expect(d_read, "peer closed, read woken");
expect(d_write, "peer closed, write woken");
exit(0);
