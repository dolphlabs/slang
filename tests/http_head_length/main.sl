// write_head sends the head write would send -- Content-Length the
// length of the body GET would carry (RFC 9110 9.3.2) -- and not one byte
// of the body: on the fast shape, the general one, one too big for the
// arena (the serialize fallback), and a 204.
import "http";
import "strings";
import "time";

fn fail(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

// Everything that arrives within 200 ms.
fn drain(s: &mut link) -> str {
    let ra = arena_new(262144);
    let inb = ra.wire(262144);
    let got = 0;
    while true {
        let rr = s.recv(inb[got..], until_of(time.mono() + 200000000));
        guard let n = rr else { break; }
        if n == 0 { break; }
        got = got + n;
    }
    return to_str(to_bytes(inb[0..got]));
}

fn head_of(c: &mut link, s: &mut link, r: http.Response, arena_size: int) -> str {
    let a = arena_new(arena_size);
    let wr = http.write_head(c, r, &mut a, until_never());
    guard let _n = wr else { fail("write_head"); }
    return drain(s);
}

fn check(label: str, raw: str, want_len: int) {
    let end = strings.find(raw, "\r\n\r\n");
    if end < 0 {
        fail(label + ": no head");
    }
    if end + 4 != len(raw) {
        fail(label + ": " + to_str(len(raw) - end - 4) + " body bytes after the head");
    }
    if want_len >= 0 && !strings.contains(raw, "Content-Length: " + to_str(want_len) + "\r\n") {
        fail(label + ": wrong Content-Length: " + raw);
    }
    if want_len < 0 && strings.contains(strings.to_lower(raw), "content-length") {
        fail(label + ": Content-Length on a 204");
    }
    println(label + " ok");
}

let lr = link_listen(0);
guard let ln = lr else { fail("listen"); }
let dr = link_dial("127.0.0.1", ln.port(), until_never());
guard let c = dr else { fail("dial"); }
let ar = ln.accept(until_never());
guard let s = ar else { fail("accept"); }

check("fast shape", head_of(&mut c, &mut s, http.ok_text("hello"), 16384), 5);
check("general shape", head_of(&mut c, &mut s,
      http.with_header(http.ok_json("{\"a\":1}"), "x-a", "1"), 16384), 7);
let big = strings.repeat("x", 100000);
check("past the arena", head_of(&mut c, &mut s, http.ok_text(big), 1024), 100000);
check("no content", head_of(&mut c, &mut s, http.text_response(204, "No Content", "", ""), 16384), -1);
// and write still sends the body
let a = arena_new(16384);
let wr = http.write(&mut c, http.ok_text("hello"), &mut a, until_never());
guard let _w = wr else { fail("write"); }
if !strings.has_suffix(drain(&mut s), "\r\n\r\nhello") {
    fail("write lost its body");
}
println("write ok");
