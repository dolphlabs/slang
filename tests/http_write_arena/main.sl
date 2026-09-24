// Differential test: http.write's bytes-on-the-wire must equal
// http.serialize()'s output for every response shape, since write()
// assembles directly into an arena-backed wire (see http.sl's `emit`)
// instead of building GC bytes through serialize() -- two implementations
// of the same byte layout that must never disagree.
//
// Also covers the arena-too-small fallback: write() must fall back to
// serialize()+send_bytes rather than let a.wire(need) past capacity kill
// the task.
import "http";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn fill(dst: wire, src: bytes) {
    let i = 0;
    for b in src {
        dst[i] = b;
        i = i + 1;
    }
}

// Sends `resp` through http.write over a real loopback link, with an
// arena of `arena_bytes` capacity, and returns exactly what the peer
// received.
fn via_write(resp: http.Response, arena_bytes: int) -> bytes {
    let lr = link_listen(0);
    guard let ln = lr else { die("listen"); }
    let port = ln.port();
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let dial = dr else { die("dial"); }
    let ar = ln.accept(until_never());
    guard let s = ar else { die("accept"); }

    let sa = arena_new(arena_bytes);
    let wr = http.write(&mut s, resp, &mut sa, until_never());
    guard let _n = wr else let e = err_of(wr) { die("write: " + to_str(e)); }

    let ra = arena_new(65536);
    let buf = ra.wire(65536);
    let rr = dial.recv(buf, until_never());
    guard let n = rr else { die("recv"); }
    return to_bytes(buf[0..n]);
}

fn check(label: str, resp: http.Response, arena_bytes: int) {
    let via_arena = via_write(resp, arena_bytes);
    let via_gc = http.serialize(resp);
    let via_sized = http.serialize_sized(resp);
    let via_builder = http.serialize_builder(resp);
    if via_arena != via_gc {
        println("FAIL " + label + ": arena and serialize disagree");
        println("  arena: " + to_str(via_arena));
        println("  gc:    " + to_str(via_gc));
        exit(1);
    }
    if via_sized != via_gc {
        println("FAIL " + label + ": serialize_sized disagrees");
        exit(1);
    }
    if via_builder != via_gc {
        println("FAIL " + label + ": serialize_builder disagrees");
        exit(1);
    }
    println(label + " ok (" + to_str(len(via_gc)) + " bytes)");
}

// no headers, empty body
check("no headers, empty body", http.text_response(204, "No Content", "", ""), 512);

// one header, small body -- the shape tests/http/main.sl:62 pins
check("one header, small body", http.text_response(200, "OK", "text/plain", "hi"), 512);

// many headers
check("many headers", http.with_headers(http.text_response(200, "OK", "text/plain", "{\"ok\":true}"), ["x-a: 1", "x-b: 2", "x-c: 3", "x-request-id: req_deadbeef"]), 512);

// a body over 64 bytes (past builder's write_str fast-path threshold)
let long_body = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
check(">64-byte body", http.text_response(200, "OK", "text/plain", long_body), 512);

// the "Connection" (capitalised) quirk: escapes the lowercase-only skip
// filter and is emitted both as the user header AND the trailing
// Connection: line -- must reproduce identically, not silently fixed
check("capitalized Connection quirk", http.with_headers(http.text_response(200, "OK", "", "x"), ["Connection: close"]), 512);

// arena too small to hold the response: write() must fall back to
// serialize()+send_bytes, not kill the connection
check("arena-overflow fallback", http.text_response(200, "OK", "text/plain", long_body), 16);

println("http_write_arena ok");
