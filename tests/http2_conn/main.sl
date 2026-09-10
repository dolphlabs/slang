import "http2";
import "time";

// End-to-end HTTP/2 over loopback: a server task and a client task, both
// slang, exchanging a real preface, SETTINGS, HEADERS and DATA. This is
// what curl --http2-prior-knowledge exercises, made self-contained so
// the suite needs no external client.

fn serve_one(c: link, out: chan[i32]) {
    let ra = arena_new(65536);
    let scratch = ra.wire(16384);
    let cn = http2.conn_new();
    let rd = http2.reader_new();

    let pr = http2.accept_preface(rd, &mut c, scratch, until_never());
    guard let _p = pr else let e = err_of(pr) {
        println("server preface: " + e);
        chan_send(out, -1);
        return;
    }
    let n = 0;
    while n < 2 {
        let rr = http2.read_request(cn, rd, &mut c, scratch, until_never());
        guard let req = rr else let e = err_of(rr) {
            println("server read: " + e);
            chan_send(out, -2);
            return;
        }
        let extra: [http2.Header] = [
            http2.Header { name: "content-type", value: "text/plain" }
        ];
        let body = to_bytes("path=" + req.path + " method=" + req.method);
        if len(req.body) > 0 {
            body = body + to_bytes(" echo=") + req.body;
        }
        let wr = http2.respond(cn, &mut c, req.stream, "200", extra, body,
                               until_never());
        guard let _w = wr else let e = err_of(wr) {
            chan_send(out, -3);
            return;
        }
        n = n + 1;
    }
    chan_send(out, 1);
}

// Minimal client: preface, SETTINGS, then one request per stream.
fn client_request(c: &mut link, rd: http2.Reader, scratch: wire,
                  stream: i32, path: str, body: bytes) -> result[str, str] {
    let hs: [http2.Header] = [
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "http" },
        http2.Header { name: ":path", value: path },
        http2.Header { name: ":authority", value: "localhost" }
    ];
    if len(body) > 0 {
        hs[0] = http2.Header { name: ":method", value: "POST" };
    }
    let blk = http2.encode_block(hs);
    let flags = http2.FLAG_END_HEADERS;
    if len(body) == 0 {
        flags = flags | http2.FLAG_END_STREAM;
    }
    let out = http2.header_bytes(http2.T_HEADERS, flags, stream as int, len(blk)) + blk;
    if len(body) > 0 {
        out = out + http2.header_bytes(http2.T_DATA, http2.FLAG_END_STREAM,
                                       stream as int, len(body)) + body;
    }
    let sr = c.send_bytes(out, until_never());
    guard let _s = sr else let e = err_of(sr) {
        return err("send: " + to_str(e));
    }
    // read frames until this stream's DATA ends
    let got = b"";
    while true {
        let fr = http2.read_frame(rd, &mut *c, scratch, 16384, until_never());
        guard let f = fr else let e = err_of(fr) {
            return err(e);
        }
        if f.ftype == http2.T_DATA && f.stream == stream as int {
            got = got + f.payload;
            if (f.flags & http2.FLAG_END_STREAM) != 0 {
                return ok(to_str(got));
            }
        }
    }
}

fn run_client(port: i32, out: chan[i32]) {
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else {
        println("client dial failed");
        chan_send(out, -10);
        return;
    }
    let ra = arena_new(65536);
    let scratch = ra.wire(16384);
    let rd = http2.reader_new();
    let sr = c.send_bytes(http2.preface() + http2.our_settings(), until_never());
    guard let _s = sr else { chan_send(out, -11); return; }

    let bad = 0;
    let r1 = client_request(&mut c, rd, scratch, 1, "/one", b"");
    guard let a = r1 else let e = err_of(r1) {
        println("client req1: " + e);
        chan_send(out, -12);
        return;
    }
    if a != "path=/one method=GET" {
        println("FAIL req1 body: [" + a + "]");
        bad = bad + 1;
    }
    let r2 = client_request(&mut c, rd, scratch, 3, "/two", b"hi there");
    guard let b2 = r2 else let e = err_of(r2) {
        println("client req2: " + e);
        chan_send(out, -13);
        return;
    }
    if b2 != "path=/two method=POST echo=hi there" {
        println("FAIL req2 body: [" + b2 + "]");
        bad = bad + 1;
    }
    if bad == 0 {
        chan_send(out, 2);
    } else {
        chan_send(out, -14);
    }
}

fn accept_one(ln: &mut link, out: chan[i32]) {
    let ar = ln.accept(until_never());
    guard let c = ar else {
        chan_send(out, -20);
        return;
    }
    spawn serve_one(c, out);
}

let lr = link_listen(0);
guard let ln = lr else { println("listen failed"); exit(1); }
let port = ln.port() as i32;

let out: chan[i32] = make_chan(4);
spawn run_client(port, out);
accept_one(&mut ln, out);

let ok_count = 0;
for i in 0..2 {
    let rv = chan_recv(out);
    guard let v = rv else { println("channel closed"); exit(1); }
    if v > 0 {
        ok_count = ok_count + v;
    } else {
        println("FAIL code ${v}");
        exit(1);
    }
}
if ok_count == 3 {
    println("http2 end-to-end ok");
} else {
    println("FAIL ok_count=${ok_count}");
    exit(1);
}
