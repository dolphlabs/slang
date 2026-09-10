import "http2";
import "net";
import "time";

// Slowloris against the HTTP/2 server, in its three shapes.
//
// Each attacker connects and then behaves in a way that, before
// deadlines, would park a server task on the reactor forever while
// holding its stack and its GC roots. All three must be disconnected,
// and disconnected within the budget rather than eventually.

fn ms(n: int) -> int { return n * 1000000; }

// Deliberately tiny so the test runs in well under a second. Real
// servers want default_limits().
fn tight() -> http2.Limits {
    return http2.Limits {
        handshake: ms(200),
        idle: ms(250),
        request: ms(250),
        write: ms(200)
    };
}

// Runs one connection to completion and reports what ended it.
fn serve(fd: i32, out: chan[str]) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[bytes] = make_chan(8);
    let lim = tight();
    spawn http2.writer_task(fd, wch, lim.write);

    let pr = http2.accept_preface(rd, fd, wch,
                                  until_of(time.mono() + lim.handshake));
    guard let _p = pr else let e = err_of(pr) {
        chan_close(wch);
        net.close(fd);
        if http2.is_timeout(e) {
            chan_send(out, "handshake-timeout");
            return;
        }
        chan_send(out, "handshake-error:" + e);
        return;
    }

    let rr = http2.read_request(cn, rd, fd, wch, lim);
    guard let req = rr else let e = err_of(rr) {
        chan_close(wch);
        net.close(fd);
        if http2.is_timeout(e) {
            chan_send(out, "request-timeout");
            return;
        }
        chan_send(out, "request-error:" + e);
        return;
    }
    chan_close(wch);
    net.close(fd);
    chan_send(out, "served:" + req.path);
}

// 1. Connects and says nothing at all -- never even sends the preface.
fn silent_client(port: i32) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else { return; }
    // Hold the connection open past the server's handshake budget
    // without sending a byte.
    time.sleep(ms(600));
    net.close(fd);
}

// 2. Completes the handshake, then goes quiet forever. The connection
//    is idle, so this is the idle budget's job.
fn idle_client(port: i32) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else { return; }
    let sr = net.send(fd, http2.preface() + http2.our_settings());
    guard let _s = sr else { return; }
    time.sleep(ms(600));
    net.close(fd);
}

// 3. The real slowloris: announces a HEADERS frame and then dribbles
//    its payload one octet at a time, forever. Every individual recv
//    makes progress, so a per-read timeout would never fire -- only a
//    budget on the whole request catches this.
fn dribble_client(port: i32) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else { return; }
    let sr = net.send(fd, http2.preface() + http2.our_settings());
    guard let _s = sr else { return; }

    // Claim a 200-octet header block, then never finish sending it.
    let hdr = http2.header_bytes(http2.T_HEADERS, http2.FLAG_END_STREAM,
                                 1, 200);
    let s2 = net.send(fd, hdr);
    guard let _t = s2 else { return; }

    let i = 0;
    while i < 200 {
        let s3 = net.send(fd, b"\x00");
        guard let _u = s3 else { return; }   // server hung up: expected
        time.sleep(ms(20));
        i = i + 1;
    }
    net.close(fd);
}

let lr = net.listen(0);
guard let lfd = lr else { println("listen failed"); exit(1); }
let pr2 = net.port(lfd);
guard let port = pr2 else { println("port failed"); exit(1); }

let out: chan[str] = make_chan(8);

spawn silent_client(port);
spawn idle_client(port);
spawn dribble_client(port);

// Accept all three and serve each on its own task, exactly as a real
// listener would.
let n = 0;
while n < 3 {
    let ar = net.accept(lfd);
    guard let cfd = ar else { println("accept failed"); exit(1); }
    spawn serve(cfd, out);
    n = n + 1;
}

let t0 = time.mono();
let handshake = 0;
let request = 0;
let k = 0;
while k < 3 {
    let rv = chan_recv(out);
    guard let v = rv else { println("FAIL channel closed"); exit(1); }
    if v == "handshake-timeout" {
        handshake = handshake + 1;
    } else {
        if v == "request-timeout" {
            request = request + 1;
        } else {
            println("FAIL unexpected outcome: " + v);
            exit(1);
        }
    }
    k = k + 1;
}
let elapsed = time.mono() - t0;

// The silent client trips the handshake budget; the idle and dribbling
// ones both get past the preface and trip a read_request budget.
if handshake != 1 {
    println("FAIL handshake timeouts: ${handshake}");
    exit(1);
}
if request != 2 {
    println("FAIL request timeouts: ${request}");
    exit(1);
}
// All three budgets are well under a second, so finishing anywhere near
// the clients' own 600ms sleeps would mean the server waited for THEM
// rather than enforcing its own deadline.
if elapsed > ms(1500) {
    println("FAIL took too long to shed the connections");
    exit(1);
}
println("slowloris shed");
