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

// ---- control-frame and CONTINUATION floods ---------------------------
//
// Neither of these was vulnerable when audited -- they are here so that
// stays true. Both were probed first and only then pinned: a test
// written for a bug that does not exist still earns its keep by
// catching the day it starts to.

// HEADERS without END_HEADERS, then CONTINUATION forever. A server that
// simply accumulates grows without bound (CVE-2024-27316 class); the
// 64KB header-block cap is what stops it.
fn continuation_flood(port: int, out: chan[str]) {
    let dr = net.dial("127.0.0.1", port);
    guard let fd = dr else { chan_send(out, "dial failed"); return; }
    net.send(fd, http2.preface() + http2.our_settings());
    let hs: [http2.Header] = [
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "http" },
        http2.Header { name: ":path", value: "/" },
        http2.Header { name: ":authority", value: "x" }
    ];
    let blk = http2.encode_block(hs);
    net.send(fd, http2.header_bytes(http2.T_HEADERS, 0, 1, len(blk)) + blk);
    let pad = b"";
    while len(pad) < 4096 { pad = pad + b"AAAAAAAAAAAAAAAA"; }
    let j = 0;
    while j < 200 {
        let sr = net.send(fd, http2.header_bytes(http2.T_CONTINUATION, 0, 1,
                                                 len(pad)) + pad);
        guard let _q = sr else { j = 200; }   // hung up on us: expected
        j = j + 1;
    }
    net.close(fd);
    chan_send(out, "sent");
}

// PINGs from a peer that never reads: every one obliges an ACK the
// server cannot deliver. Bounded by the write and idle deadlines.
fn ping_flood(port: int, out: chan[str]) {
    let dr = net.dial("127.0.0.1", port);
    guard let fd = dr else { chan_send(out, "dial failed"); return; }
    net.send(fd, http2.preface() + http2.our_settings());
    let pings = b"";
    let i = 0;
    while i < 400 {
        pings = pings + http2.header_bytes(http2.T_PING, 0, 0, 8) + b"PINGPING";
        i = i + 1;
    }
    let sr = net.send(fd, pings);
    guard let _s = sr else { chan_send(out, "sent"); return; }
    chan_send(out, "sent");
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

    // 3. CONTINUATION flood: must be refused, not accumulated.
    let o3: chan[str] = make_chan(2);
    spawn continuation_flood(port, o3);
    let a3 = net.accept(lfd);
    guard let c3 = a3 else { println("FAIL accept3"); exit(1); }
    spawn serve(c3, o3);
    let v3a = chan_recv(o3);
    guard let _x3 = v3a else { println("FAIL o3"); exit(1); }
    let v3b = chan_recv(o3);
    guard let why = v3b else { println("FAIL o3b"); exit(1); }
    if why != "header block too large" && why != "sent" {
        println("FAIL continuation flood ended with: " + why);
        exit(1);
    }
    println("continuation flood refused");

    // 4. PING flood from a peer that never reads: must not hang.
    let o4: chan[str] = make_chan(2);
    spawn ping_flood(port, o4);
    let a4 = net.accept(lfd);
    guard let c4 = a4 else { println("FAIL accept4"); exit(1); }
    spawn serve(c4, o4);
    let v4a = chan_recv(o4);
    guard let _x4 = v4a else { println("FAIL o4"); exit(1); }
    // The point is that this RETURNS. A wedged reader never would.
    let v4b = chan_recv(o4);
    guard let _y4 = v4b else { println("FAIL o4b"); exit(1); }
    println("ping flood did not wedge the connection");

    net.close(lfd);
    println("flood ok");
}

run();
