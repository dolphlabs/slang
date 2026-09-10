// An h2c server for the independent-client interop probe.
//
// Not a test on its own -- tests/run_tests.sh never runs this, because
// it needs a Go toolchain and a network fetch. It is driven by
// tests/http2_interop/run.sh, which is the thing to run by hand.
//
// Routes are chosen to exercise the parts a same-stack client cannot
// really challenge:
//
//   /hello  a plain GET
//   /echo   POST, so DATA flows INTO the server and receive-side
//           WINDOW_UPDATE has to come back out
//   /big    a 200000-octet response, which forces send-side flow
//           control to run for real against a peer that will treat an
//           overrun as a connection error
//   /slow   sleeps, so concurrency is observable rather than asserted

import "http2";
import "net";
import "time";

fn body_for(path: str) -> bytes {
    if path != "/big" {
        return b"";
    }
    // Built by doubling; every intermediate length stays a multiple of
    // 10, so the period-10 pattern holds and the client can check any
    // octet against its absolute offset.
    let out = b"0123456789";
    while len(out) < 200000 {
        out = out + out;
    }
    return out[0..200000];
}

fn handle(stream: i32, path: str, body: bytes, wch: chan[http2.WMsg]) {
    if path == "/slow" {
        time.sleep(400000000);
    }
    if path == "/big" {
        let plain: [http2.Header] = [];
        chan_send(wch, http2.response_msg(stream as int, "200", plain,
                                          body_for(path)));
        return;
    }
    let extra: [http2.Header] = [
        http2.Header { name: "content-type", value: "text/plain" }
    ];
    let out = to_bytes("path=" + path);
    if len(body) > 0 {
        out = out + to_bytes(" echo=") + body;
    }
    chan_send(wch, http2.response_msg(stream as int, "200", extra, out));
}

fn serve(fd: i32) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(64);
    let lim = http2.default_limits();
    spawn http2.writer_task(http2.transport_fd(fd), wch, lim.write);

    let pr = http2.accept_preface(rd, http2.transport_fd(fd), wch,
                                  until_of(time.mono() + lim.handshake));
    guard let _p = pr else {
        chan_close(wch);
        net.close(fd);
        return;
    }
    while true {
        let rr = http2.read_request(cn, rd, http2.transport_fd(fd), wch, lim);
        guard let req = rr else {
            chan_close(wch);
            net.close(fd);
            return;
        }
        spawn handle(req.stream as i32, req.path, req.body, wch);
    }
}

fn accept_loop(lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let cfd = ar else { return; }
        spawn serve(cfd);
    }
}

let port = 8123;
let lr = net.listen(port);
guard let lfd = lr else let e = err_of(lr) {
    println("listen failed: " + e);
    exit(1);
}
println("h2c interop server on ${port}");
accept_loop(lfd);
