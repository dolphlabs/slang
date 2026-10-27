import "fs";
import "http2";
import "net";
import "time";

// client_close must return only once the connection is closed: reader and
// writer stopped, and the transport closed by the one task that owns it.
// It used to queue a GOAWAY that made the writer close the fd while the
// reader task was still parked on it. A new connection that then got the
// same fd number shared it with a waiter that was not its own, and its
// reads -- deadlines included -- stopped waking: tests/h2_client hung about
// once in sixty runs on linux under the GC stress lists.
//
// Each round: a client makes a call and closes; its fd must be closed when
// client_close returns (fstat on it fails), and a connection opened right
// after must still have its read deadline fire.

fn ms(n: int) -> int { return n * 1000000; }

fn lim() -> http2.Limits {
    return http2.Limits { handshake: ms(3000), idle: ms(5000), request: ms(5000),
                          write: ms(3000), max_concurrent: 16 };
}

fn handle(req: http2.Req, wch: chan[http2.WMsg], g: chan[bool]) {
    let none_h: [http2.Header] = [];
    chan_send(wch, http2.response_msg(req.stream, "200", none_h, req.body));
    http2.gate_leave(g);
}

fn serve(fd: i32) {
    let t = http2.transport_fd(fd);
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(16);
    let l = lim();
    let g = http2.gate(l.max_concurrent);
    spawn http2.writer_task(t, wch, l.write);
    let pr = http2.accept_preface(rd, t, wch, until_of(time.mono() + l.handshake));
    guard let _p = pr else { return; }
    while true {
        let rr = http2.read_request(cn, rd, t, wch, l);
        guard let req = rr else {
            http2.gate_drain(g, l.max_concurrent);
            chan_close(wch);
            return;
        }
        http2.gate_enter(g);
        spawn handle(req, wch, g);
    }
}

fn accept_h2(lfd: i32) {
    while true {
        let a = net.accept(lfd as int);
        guard let fd = a else { return; }
        spawn serve(fd);
    }
}

// Accepts and never writes: a read on the client end can only end by its
// deadline.
fn accept_silent(lfd: i32, keep: chan[i32]) {
    while true {
        let a = net.accept(lfd as int);
        guard let fd = a else { return; }
        chan_send(keep, fd);
    }
}

fn read_with_deadline(fd: i32, out: chan[str]) {
    let rd = http2.reader_new();
    let fr = http2.read_frame(rd, http2.transport_fd(fd), 16384,
                              until_of(time.mono() + ms(50)));
    if let _f = fr {
        chan_send(out, "a frame arrived on a silent connection");
    } else let e = err_of(fr) {
        chan_send(out, e);
    }
}

fn watchdog(out: chan[str]) {
    time.sleep(ms(3000));
    chan_send(out, "stuck");
}

fn fail(what: str) {
    println("FAIL " + what);
    exit(1);
}

let l1 = net.listen(0);
guard let h2_lfd = l1 else { fail("listen"); exit(1); }
let p1 = net.port(h2_lfd as int);
guard let h2_port = p1 else { fail("port"); exit(1); }
let l2 = net.listen(0);
guard let silent_lfd = l2 else { fail("listen"); exit(1); }
let p2 = net.port(silent_lfd as int);
guard let silent_port = p2 else { fail("port"); exit(1); }
let keep: chan[i32] = make_chan(256);
spawn accept_h2(h2_lfd);
spawn accept_silent(silent_lfd, keep);

let none_h: [http2.Header] = [];
for round in 0..60 {
    let d = net.dial("127.0.0.1", h2_port as int);
    guard let fd = d else { fail("dial"); exit(1); }
    let sr = http2.client_start(http2.transport_fd(fd), lim());
    guard let c = sr else let e = err_of(sr) { fail("client_start: " + e); exit(1); }
    let r = http2.client_call(c, "POST", "http", "localhost", "/echo", none_h,
                              b"round", ms(3000), 1024);
    guard let resp = r else let e = err_of(r) { fail("call: " + e); exit(1); }
    if resp.body != b"round" { fail("echo body"); }
    http2.client_close(c);
    if len(fs.fstat(fd as int)) != 0 {
        fail("round " + to_str(round) + ": the client's fd was still open after client_close returned");
    }
    let d2 = net.dial("127.0.0.1", silent_port as int);
    guard let fd2 = d2 else { fail("dial silent"); exit(1); }
    let out: chan[str] = make_chan(2);
    spawn read_with_deadline(fd2, out);
    spawn watchdog(out);
    let got = chan_recv(out) ?? "closed";
    if got != "timeout" {
        fail("round " + to_str(round) + ": read on the next connection: " + got);
    }
    net.close(fd2 as int);
}
println("client close owns the fd: 60 rounds ok");
