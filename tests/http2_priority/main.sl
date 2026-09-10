import "http2";
import "net";
import "time";

// PRIORITY is deprecated (RFC 9113 §5.3.2) and this server acts on none
// of it -- but "ignore the prioritisation" is not "accept anything".
// A malformed PRIORITY frame is a connection error (§6.3), and letting
// one through would desync the frame stream rather than fail cleanly.
//
// Each case gets its own connection, because a well-formed one is
// expected to be ignored and served while a malformed one must end the
// connection.

fn ms(n: int) -> int { return n * 1000000; }

fn lim() -> http2.Limits {
    return http2.Limits {
        handshake: ms(2000), idle: ms(2000),
        request: ms(2000), write: ms(2000),
        max_concurrent: 100
    };
}

fn serve(fd: i32, out: chan[str]) {
    let cn = http2.conn_new();
    let rd = http2.reader_new();
    let wch: chan[http2.WMsg] = make_chan(8);
    let l = lim();
    spawn http2.writer_task(http2.transport_fd(fd), wch, l.write);

    let pr = http2.accept_preface(rd, http2.transport_fd(fd), wch,
                                  until_of(time.mono() + l.handshake));
    guard let _p = pr else let e = err_of(pr) {
        chan_close(wch);
        net.close(fd);
        chan_send(out, "preface:" + e);
        return;
    }
    let rr = http2.read_request(cn, rd, http2.transport_fd(fd), wch, l);
    guard let req = rr else let e = err_of(rr) {
        chan_close(wch);
        net.close(fd);
        chan_send(out, e);
        return;
    }
    chan_close(wch);
    net.close(fd);
    chan_send(out, "served " + req.path);
}

fn a_request(stream: int) -> bytes {
    let hs: [http2.Header] = [
        http2.Header { name: ":method", value: "GET" },
        http2.Header { name: ":scheme", value: "http" },
        http2.Header { name: ":path", value: "/ok" },
        http2.Header { name: ":authority", value: "localhost" }
    ];
    let blk = http2.encode_block(hs);
    let flags = http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM;
    return http2.header_bytes(http2.T_HEADERS, flags, stream, len(blk)) + blk;
}

fn client(port: i32, payload: bytes) {
    let dr = net.dial("127.0.0.1", port as int);
    guard let fd = dr else { return; }
    let sr = net.send(fd, http2.preface() + http2.our_settings() + payload);
    guard let _s = sr else { return; }
    // Stay connected so the server's error is its own verdict rather
    // than a premature EOF.
    time.sleep(ms(400));
    net.close(fd);
}

// One case: send `payload`, expect the server to report `want`.
fn probe(lfd: i32, port: i32, name: str, payload: bytes, want: str) {
    let out: chan[str] = make_chan(2);
    spawn client(port, payload);
    let ar = net.accept(lfd);
    guard let cfd = ar else { println("FAIL accept"); exit(1); }
    spawn serve(cfd, out);
    let rv = chan_recv(out);
    guard let got = rv else { println("FAIL channel closed"); exit(1); }
    if got != want {
        println("FAIL " + name + ": got \"" + got + "\" want \"" + want + "\"");
        exit(1);
    }
    println(name + ": " + got);
}

let lr = net.listen(0);
guard let lfd = lr else { println("listen failed"); exit(1); }
let pr2 = net.port(lfd);
guard let port = pr2 else { println("port failed"); exit(1); }

// A PRIORITY payload is a 4-octet stream dependency plus a 1-octet
// weight: exactly 5.
let weight = b"\x10";

// 1. Wrong payload length.
probe(lfd, port, "short payload",
      http2.header_bytes(http2.T_PRIORITY, 0, 1, 4) + http2.put32(0),
      "PRIORITY payload must be 5 octets");

// 2. PRIORITY is meaningless on the connection stream.
probe(lfd, port, "stream zero",
      http2.header_bytes(http2.T_PRIORITY, 0, 0, 5) + http2.put32(0) + weight,
      "PRIORITY on stream 0");

// 3. A stream may not depend on itself.
probe(lfd, port, "self dependency",
      http2.header_bytes(http2.T_PRIORITY, 0, 1, 5) + http2.put32(1) + weight,
      "PRIORITY: stream depends on itself");

// 4. A well-formed one is ignored, and the request behind it is served
//    normally -- the validation must not have broken the common path.
probe(lfd, port, "valid ignored",
      http2.header_bytes(http2.T_PRIORITY, 0, 1, 5) + http2.put32(0) + weight
        + a_request(1),
      "served /ok");

// 5. The same self-dependency rule inside a HEADERS priority field.
let blk = http2.encode_block([
    http2.Header { name: ":method", value: "GET" },
    http2.Header { name: ":path", value: "/p" }
]);
let pri = http2.put32(1) + weight;
let hflags = http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM
             | http2.FLAG_PRIORITY;
probe(lfd, port, "headers self dependency",
      http2.header_bytes(http2.T_HEADERS, hflags, 1, len(pri) + len(blk))
        + pri + blk,
      "HEADERS priority: stream depends on itself");

net.close(lfd);
println("priority validation ok");
