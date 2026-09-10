import "http2";
import "net";
import "time";

// End-to-end HTTP/2 over loopback with CONCURRENT streams.
//
// The server dispatches each request to its own task and serialises all
// writes through one writer task fed by a chan[bytes]. The client opens
// two streams before reading either reply, and asks for the slow one
// FIRST. If streams were served one at a time the slow reply would come
// back first; concurrency is proven by the fast one arriving first.

fn handle(stream: i32, path: str, body: bytes, peer_max: i32,
          wch: chan[bytes]) {
    if path == "/slow" {
        time.sleep(300000000);
    }
    let extra: [http2.Header] = [
        http2.Header { name: "content-type", value: "text/plain" }
    ];
    let out = to_bytes("path=" + path);
    if len(body) > 0 {
        out = out + to_bytes(" echo=") + body;
    }
    chan_send(wch, http2.response_frames(peer_max as int, stream as int,
                                         "200", extra, out));
}

fn serve(fd: i32, done: chan[i32]) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[bytes] = make_chan(32);
    let lim = http2.default_limits();
    spawn http2.writer_task(fd, wch, lim.write);

    let pr = http2.accept_preface(rd, fd, wch,
                                  until_of(time.mono() + lim.handshake));
    guard let _p = pr else let e = err_of(pr) {
        println("server preface: " + e);
        chan_close(wch);
        chan_send(done, -1);
        return;
    }
    let n = 0;
    while n < 2 {
        let rr = http2.read_request(cn, rd, fd, wch, lim);
        guard let req = rr else let e = err_of(rr) {
            chan_close(wch);
            chan_send(done, -2);
            return;
        }
        spawn handle(req.stream as i32, req.path, req.body,
                     cn.peer_max_frame as i32, wch);
        n = n + 1;
    }
    chan_send(done, 1);
}

fn req_frames(stream: int, path: str, body: bytes) -> bytes {
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

fn run_client(port: i32, done: chan[i32]) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else {
        println("client dial failed");
        chan_send(done, -10);
        return;
    }
    let rd = http2.reader_new();
    let sr = net.send(fd, http2.preface() + http2.our_settings());
    guard let _s = sr else { chan_send(done, -11); return; }

    // both requests go out BEFORE either reply is read; slow one first
    let both = req_frames(1, "/slow", b"") + req_frames(3, "/quick", b"");
    let s2 = net.send(fd, both);
    guard let _t = s2 else { chan_send(done, -12); return; }

    // first DATA frame to arrive decides which stream finished first
    let first_stream = 0;
    let seen = 0;
    while seen < 2 {
        let fr = http2.read_frame(rd, fd, 16384,
                                  until_of(time.mono() + 10000000000));
        guard let f = fr else let e = err_of(fr) {
            println("client read: " + e);
            chan_send(done, -13);
            return;
        }
        if f.ftype == http2.T_DATA && (f.flags & http2.FLAG_END_STREAM) != 0 {
            if first_stream == 0 {
                first_stream = f.stream;
            }
            seen = seen + 1;
        }
    }
    if first_stream != 3 {
        println("FAIL streams were serialised: stream ${first_stream} finished first");
        chan_send(done, -14);
        return;
    }
    chan_send(done, 2);
}

let lr = net.listen(0);
guard let lfd = lr else { println("listen failed"); exit(1); }
let pr2 = net.port(lfd);
guard let port = pr2 else { println("port failed"); exit(1); }

let done: chan[i32] = make_chan(4);
spawn run_client(port, done);

let ar = net.accept(lfd);
guard let cfd = ar else { println("accept failed"); exit(1); }
spawn serve(cfd, done);

let total = 0;
for i in 0..2 {
    let rv = chan_recv(done);
    guard let v = rv else { println("channel closed"); exit(1); }
    if v > 0 {
        total = total + v;
    } else {
        println("FAIL code ${v}");
        exit(1);
    }
}
if total == 3 {
    println("http2 concurrent streams ok");
} else {
    println("FAIL total=${total}");
    exit(1);
}
