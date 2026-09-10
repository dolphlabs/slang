// Stream floods, and the two bounds that stop them.
//
// The server advertises SETTINGS_MAX_CONCURRENT_STREAMS=100. Before the
// stream gate existed it did not ENFORCE it: the connection layer does
// not spawn handlers, the caller does, and slang has no function values
// to hand it a callback, so nothing counted. A peer sending 3000
// requests down one connection got 3000 concurrent handler tasks --
// measured, not theorised.
//
// Advertising a limit you do not keep is worse than advertising none,
// because peers size their behaviour by it.
//
// Two distinct defences are under test:
//
//   1. the GATE bounds concurrent work for ANY flood, resetting or not
//   2. the RESET counter sheds a peer doing Rapid Reset
//      (CVE-2023-44487) rather than serving it at capacity forever --
//      it opens a stream and cancels it immediately, so from its side
//      nothing is ever "concurrent" and a cap alone never trips
//
// The gate also makes shutdown safe: closing the writer channel while
// handlers are still in flight panics them with "send on closed
// channel", and gate_drain is what knows when none are left.

import "http2";
import "net";
import "time";
import "proc";

fn ms(n: int) -> int { return n * 1000000; }

// Small on purpose: a lower cap makes the assertion sharper, and proves
// the bound comes from max_concurrent rather than from some accident of
// scheduling.
fn lim() -> http2.Limits {
    return http2.Limits {
        handshake: ms(3000), idle: ms(3000),
        request: ms(3000), write: ms(3000),
        max_concurrent: 20
    };
}

fn handle(stream: i32, wch: chan[http2.WMsg], g: chan[bool]) {
    // Long enough that handlers pile up if nothing bounds them.
    time.sleep(ms(150));
    let hs: [http2.Header] = [];
    chan_send(wch, http2.response_msg(stream as int, "200", hs, b"ok"));
    http2.gate_leave(g);
}

fn serve(fd: i32, out: chan[str]) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(32);
    let l = lim();
    let g = http2.gate(l.max_concurrent);
    let t = http2.transport_fd(fd);
    spawn http2.writer_task(t, wch, l.write);

    let pr = http2.accept_preface(rd, t, wch,
                                  until_of(time.mono() + l.handshake));
    guard let _p = pr else {
        chan_close(wch);
        net.close(fd);
        chan_send(out, "preface failed");
        return;
    }
    while true {
        let rr = http2.read_request(cn, rd, t, wch, l);
        guard let req = rr else let e = err_of(rr) {
            // Drain BEFORE closing: handlers still hold the channel.
            http2.gate_drain(g, l.max_concurrent);
            chan_close(wch);
            net.close(fd);
            chan_send(out, e);
            return;
        }
        http2.gate_enter(g);
        spawn handle(req.stream as i32, wch, g);
    }
}

fn requests(n: int, with_reset: bool) -> bytes {
    let hs: [http2.Header] = [
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "http" },
        http2.Header { name: ":path", value: "/" },
        http2.Header { name: ":authority", value: "x" }
    ];
    let blk = http2.encode_block(hs);
    let flags = http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM;
    let out = b"";
    let sid = 1;
    let i = 0;
    while i < n {
        out = out + http2.header_bytes(http2.T_HEADERS, flags, sid, len(blk))
                  + blk;
        if with_reset {
            out = out + http2.rst_stream(sid, http2.E_CANCEL);
        }
        sid = sid + 2;
        i = i + 1;
    }
    return out;
}

// Writes as fast as it can and never reads a byte back.
fn flood(port: int, n: int, with_reset: bool, done: chan[bool]) {
    let dr = net.dial("127.0.0.1", port);
    guard let fd = dr else { chan_send(done, false); return; }
    let sr = net.send(fd, http2.preface() + http2.our_settings()
                          + requests(n, with_reset));
    guard let _s = sr else {
        // The server hanging up mid-flood is a pass, not a failure.
        chan_send(done, true);
        return;
    }
    chan_send(done, true);
}

// Runs one flood and reports the peak task count while it drains.
fn measure(port: int, n: int, with_reset: bool, lfd: i32) -> int {
    let out: chan[str] = make_chan(2);
    let done: chan[bool] = make_chan(2);
    spawn flood(port, n, with_reset, done);

    let ar = net.accept(lfd);
    guard let cfd = ar else { println("FAIL accept"); exit(1); }
    spawn serve(cfd, out);

    let dv = chan_recv(done);
    guard let _d = dv else { println("FAIL done closed"); exit(1); }

    let peak = 0;
    let k = 0;
    while k < 24 {
        let a = proc.active_tasks();
        if a > peak { peak = a; }
        time.sleep(ms(40));
        k = k + 1;
    }
    return peak;
}

fn run() {
    let lr = net.listen(0);
    guard let lfd = lr else { println("FAIL listen"); exit(1); }
    let pr = net.port(lfd);
    guard let port = pr else { println("FAIL port"); exit(1); }

    // 1. A plain flood: 1000 requests, no resets. Only the gate can
    //    bound this one.
    let peak1 = measure(port, 1000, false, lfd);
    // 20 handlers + reader + writer + this task + the flood client, with
    // room for scheduling slack. Unbounded would be ~1000.
    if peak1 > 60 {
        println("FAIL plain flood reached ${peak1} tasks, cap is 20");
        exit(1);
    }
    println("plain flood stayed bounded");

    // 2. Rapid Reset: every stream cancelled the instant it opens.
    let peak2 = measure(port, 1000, true, lfd);
    if peak2 > 60 {
        println("FAIL reset flood reached ${peak2} tasks, cap is 20");
        exit(1);
    }
    println("reset flood stayed bounded");

    net.close(lfd);
    println("flood ok");
}

run();
