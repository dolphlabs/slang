// A method is an RFC 9110 token. One carrying a quote, a backslash or a
// control byte (ESC here, which starts a terminal escape) is refused by
// every parser, the way any other malformed request line is; unusual but
// valid methods still pass.

import "http";
import "time";

fn line(method: bytes) -> bytes {
    return method + b" /x HTTP/1.1\r\nHost: t\r\n\r\n";
}

fn check_parse(name: str, method: bytes) {
    let r = http.parse(line(method));
    let pf = http.parse_frame(line(method));
    let a = "ok";
    guard let _p = r else let e = err_of(r) {
        a = "refused";
        report(name, a, pf_word(pf));
        return;
    }
    report(name, a, pf_word(pf));
}

fn pf_word(pf: result[http.Frame, str]) -> str {
    guard let _f = pf else {
        return "refused";
    }
    return "ok";
}

fn report(name: str, a: str, b: str) {
    println(name + ": parse " + a + ", parse_frame " + b);
}

fn sender(port: int, raw: bytes) {
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let c = dr else { return; }
    let a = arena_new(4096);
    let w = a.wire(len(raw));
    let i = 0;
    while i < len(raw) {
        w[i] = raw[i];
        i = i + 1;
    }
    let _s = c.send(w, until_never());
    time.sleep(200000000);
}

fn check_read(name: str, method: bytes) {
    let lr = link_listen(0);
    guard let ln = lr else { exit(1); }
    spawn sender(ln.port(), line(method));
    let ar = ln.accept(until_never());
    guard let c = ar else { exit(1); }
    let a = arena_new(8192);
    let buf = a.wire(4096);
    let rr = http.read_frame(&mut c, buf, 0, until_of(time.mono() + 2000000000),
                             until_of(time.mono() + 2000000000),
                             until_of(time.mono() + 2000000000));
    guard let _f = rr else let e = err_of(rr) {
        println(name + ": read_frame refused (" + e + ")");
        return;
    }
    println(name + ": read_frame ok");
}

check_parse("GET", b"GET");
check_parse("BREW", b"BREW");
check_parse("M-SEARCH", b"M-SEARCH");
check_parse("ESC", b"G\x1b[31mET");
check_parse("quote", b"GE\"T");
check_parse("backslash", b"G\\ET");
check_parse("DEL", b"GE\x7fT");
check_read("PROPFIND", b"PROPFIND");
check_read("ESC", b"G\x1b[31mET");
