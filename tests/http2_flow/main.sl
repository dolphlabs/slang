import "http2";
import "net";
import "time";

// Send-side flow control (RFC 9113 §5.2, §6.9).
//
// The server may not send more DATA than the peer's windows allow, at
// BOTH levels: per-stream and per-connection. Previously it sent the
// whole body regardless, which overruns a peer that advertised a small
// window -- a correctness bug, not a missing nicety, because a strict
// client treats the overrun as a FLOW_CONTROL_ERROR and drops the
// connection.
//
// Each phase asks for a body far larger than the credit on offer, then
// checks the server stops at EXACTLY the right octet and resumes for
// exactly the credit granted.

fn ms(n: int) -> int { return n * 1000000; }

fn lim() -> http2.Limits {
    return http2.Limits {
        handshake: ms(3000), idle: ms(3000),
        request: ms(3000), write: ms(3000)
    };
}

fn body_for(path: str) -> bytes {
    let n = 5000;
    if path == "/big" {
        n = 100000;
    }
    // A repeating pattern, so a mis-sliced DATA frame shows up as
    // wrong content rather than merely a wrong count.
    // Built by doubling, not by appending the unit n/10 times: the
    // latter is quadratic and takes long enough on the 100000 case to
    // be mistaken for the server refusing to send. Every intermediate
    // length stays a multiple of 10, so the period-10 pattern holds.
    let out = b"0123456789";
    while len(out) < n {
        out = out + out;
    }
    return out[0..n];
}

fn handle(stream: i32, path: str, wch: chan[http2.WMsg]) {
    let extra: [http2.Header] = [];
    chan_send(wch, http2.response_msg(stream as int, "200", extra,
                                      body_for(path)));
}

fn serve(fd: i32, out: chan[str]) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(32);
    let l = lim();
    spawn http2.writer_task(fd, wch, l.write);

    let pr = http2.accept_preface(rd, fd, wch,
                                  until_of(time.mono() + l.handshake));
    guard let _p = pr else let e = err_of(pr) {
        chan_send(out, "preface:" + e);
        return;
    }
    while true {
        let rr = http2.read_request(cn, rd, fd, wch, l);
        guard let req = rr else let e = err_of(rr) {
            chan_close(wch);
            chan_send(out, "done:" + e);
            return;
        }
        spawn handle(req.stream as i32, req.path, wch);
    }
}

// How much DATA arrived for `stream` before the peer went quiet, and
// whether the stream ended.
gc struct Got {
    octets: int,
    ended: bool,
    bad: bool,
}

// Read frames until nothing more arrives for `quiet_ns`. The timeout is
// the point: it is how we observe that the server has STOPPED, which is
// the property under test.
// `base` is this burst's absolute offset into the body: the pattern
// check is against the position in the WHOLE response, not in this
// burst, so a resumed transfer that restarts from the wrong offset is
// caught rather than silently accepted.
fn drain(rd: http2.Reader, fd: i32, stream: int, base: int,
         quiet_ns: int) -> Got {
    let g = Got { octets: 0, ended: false, bad: false };
    while true {
        let fr = http2.read_frame(rd, fd, 16384,
                                  until_of(time.mono() + quiet_ns));
        guard let f = fr else {
            return g;            // quiet: the server sent all it may
        }
        if f.ftype == http2.T_DATA && f.stream == stream {
            // Content check: every octet must match the pattern at its
            // absolute offset, so a wrongly-sliced frame is caught.
            let i = 0;
            while i < len(f.payload) {
                let want = 48 + ((base + g.octets + i) % 10);
                if f.payload[i] != want {
                    g.bad = true;
                }
                i = i + 1;
            }
            g.octets = g.octets + len(f.payload);
            if (f.flags & http2.FLAG_END_STREAM) != 0 {
                g.ended = true;
                return g;
            }
        }
    }
}

fn request(stream: int, path: str) -> bytes {
    let hs: [http2.Header] = [
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "http" },
        http2.Header { name: ":path", value: path },
        http2.Header { name: ":authority", value: "localhost" }
    ];
    let blk = http2.encode_block(hs);
    let flags = http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM;
    return http2.header_bytes(http2.T_HEADERS, flags, stream, len(blk)) + blk;
}

fn check(name: str, got: int, want: int) {
    if got != want {
        println("FAIL " + name + ": got ${got} want ${want}");
        exit(1);
    }
}

// ---- phase 1: the STREAM window is the binding constraint ------------
//
// SETTINGS_INITIAL_WINDOW_SIZE of 100 against a 5000-octet body. The
// connection window is the default 65535 and never binds here, so
// anything other than 100 octets means stream accounting is wrong.
fn phase_stream(port: i32, out: chan[str]) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else { chan_send(out, "dial failed"); return; }
    let rd = http2.reader_new();

    let s = http2.settings_frame([http2.S_INITIAL_WINDOW_SIZE], [100]);
    let sr = net.send(fd, http2.preface() + s + request(1, "/small"));
    guard let _s = sr else { chan_send(out, "send failed"); return; }

    let g1 = drain(rd, fd, 1, 0, ms(300));
    check("stream window first burst", g1.octets, 100);
    if g1.ended { println("FAIL ended early"); exit(1); }
    if g1.bad { println("FAIL corrupt payload"); exit(1); }

    // Grant 250 more to the stream. The connection still has plenty, so
    // exactly 250 must follow -- not more, not the whole remainder.
    let u1 = net.send(fd, http2.window_update(1, 250));
    guard let _u1 = u1 else { chan_send(out, "wu failed"); return; }
    let g2 = drain(rd, fd, 1, 100, ms(300));
    check("stream window second burst", g2.octets, 250);
    if g2.bad { println("FAIL corrupt payload after grant"); exit(1); }

    // Now grant the rest and require a clean END_STREAM.
    let u2 = net.send(fd, http2.window_update(1, 5000));
    guard let _u2 = u2 else { chan_send(out, "wu2 failed"); return; }
    let g3 = drain(rd, fd, 1, 350, ms(800));
    check("stream window remainder", g3.octets, 4650);
    if !g3.ended { println("FAIL never ended"); exit(1); }
    if g3.bad { println("FAIL corrupt payload at tail"); exit(1); }

    net.close(fd);
    chan_send(out, "stream window respected");
}

// ---- phase 2: the CONNECTION window is the binding constraint --------
//
// A large per-stream window against a 100000-octet body. The connection
// window is NOT raised by SETTINGS_INITIAL_WINDOW_SIZE (§6.9.2 -- it
// adjusts stream windows only), so it stays at 65535 and must be what
// stops the transfer. Getting this wrong is the classic bug: track one
// level and forget the other.
fn phase_conn(port: i32, out: chan[str]) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else { chan_send(out, "dial failed"); return; }
    let rd = http2.reader_new();

    let s = http2.settings_frame([http2.S_INITIAL_WINDOW_SIZE], [1000000]);
    let sr = net.send(fd, http2.preface() + s + request(1, "/big"));
    guard let _s = sr else { chan_send(out, "send failed"); return; }

    let g1 = drain(rd, fd, 1, 0, ms(500));
    check("connection window first burst", g1.octets, 65535);
    if g1.ended { println("FAIL ended early"); exit(1); }
    if g1.bad { println("FAIL corrupt payload"); exit(1); }

    // Connection-level credit only (stream 0). The stream has ample
    // room, so this alone must unblock exactly 20000 more.
    let u1 = net.send(fd, http2.window_update(0, 20000));
    guard let _u1 = u1 else { chan_send(out, "wu failed"); return; }
    let g2 = drain(rd, fd, 1, 65535, ms(500));
    check("connection window second burst", g2.octets, 20000);
    if g2.bad { println("FAIL corrupt payload after grant"); exit(1); }

    let u2 = net.send(fd, http2.window_update(0, 100000));
    guard let _u2 = u2 else { chan_send(out, "wu2 failed"); return; }
    let g3 = drain(rd, fd, 1, 85535, ms(1500));
    check("connection window remainder", g3.octets, 14465);
    if !g3.ended { println("FAIL never ended"); exit(1); }
    if g3.bad { println("FAIL corrupt payload at tail"); exit(1); }

    net.close(fd);
    chan_send(out, "connection window respected");
}

let lr = net.listen(0);
guard let lfd = lr else { println("listen failed"); exit(1); }
let pr2 = net.port(lfd);
guard let port = pr2 else { println("port failed"); exit(1); }

let out: chan[str] = make_chan(4);
// The server reports on its OWN channel: sharing one with the client
// lets the server's "connection closed" race ahead of the client's
// verdict and be read in its place.
let srv: chan[str] = make_chan(4);

spawn phase_stream(port, out);
let a1 = net.accept(lfd);
guard let c1 = a1 else { println("accept failed"); exit(1); }
spawn serve(c1, srv);
let r1 = chan_recv(out);
guard let v1 = r1 else { println("closed"); exit(1); }
println(v1);

spawn phase_conn(port, out);
let a2 = net.accept(lfd);
guard let c2 = a2 else { println("accept2 failed"); exit(1); }
spawn serve(c2, srv);
let r2 = chan_recv(out);
guard let v2 = r2 else { println("closed"); exit(1); }
println(v2);

net.close(lfd);
println("flow control ok");
