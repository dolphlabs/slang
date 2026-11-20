// A reader that has seen EAGAIN but not yet parked when another task
// closes its fd must still be told "closed": before, it parked on a number
// nobody would ever signal again and only its deadline ended the wait.
// Each round races one recv against one close on another worker; a
// "timeout" means the close was missed.
import "net";
import "os";
import "time";

fn ms(n: int) -> int { return n * 1000000; }

fn reader(fd: int, out: chan[str]) {
    let r = net.recv_until(fd, 16, until_of(time.mono() + ms(400)));
    if let _b = r {
        chan_send(out, "data");
    } else let e = err_of(r) {
        chan_send(out, e);
    }
}

fn spin(n: int) -> int {
    let acc = 0;
    for i in 0..n {
        acc = acc + i;
    }
    return acc;
}

// A Unix socket: a TCP client closing first leaves its port in TIME_WAIT,
// and this many rounds would run out of ports.
let path = "/tmp/sl_close_race_" + to_str(os.pid()) + ".sock";
os.remove(path);
let lr = net.listen_unix(path);
guard let lfd = lr else let e = err_of(lr) { println("listen: " + e); exit(1); }

let rounds = 12000;
let missed = 0;
let out: chan[str] = make_chan(1);
for i in 0..rounds {
    let dr = net.dial_unix(path, until_of(time.mono() + ms(5000)));
    guard let c = dr else let e = err_of(dr) { println("dial: " + e); exit(1); }
    let ar = net.accept(lfd);
    guard let s = ar else let e = err_of(ar) { println("accept: " + e); exit(1); }
    spawn reader(c as int, out);
    spin(i % 400);
    net.close(c as int);
    let v = chan_recv(out) ?? "channel closed";
    if v == "timeout" {
        missed = missed + 1;
    }
    net.close(s as int);
}
os.remove(path);
println("missed closes: " + to_str(missed));
