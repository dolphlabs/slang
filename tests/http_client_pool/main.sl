// httpc Client: connection pooling and response decompression.
//
// "The pool works" is checked from BOTH ends. The client's own dials /
// reuses counters could be wrong in the same way the pool is wrong, so
// the canned server counts the connections it actually accepted, and the
// two have to agree.
//
// The server here keeps connections open and serves request after
// request on each one, spawning a task per connection so concurrent
// clients are real. What it sends is written by hand for the same
// reason as tests/http_client: most of these cases are behaviours a
// cooperative server will not produce on demand -- closing an idle
// connection, dropping a request without answering, mislabelling raw
// DEFLATE as "deflate".

import "net";
import "time";
import "strings";
import "compress";
import "httpc";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn expect(got: str, want: str, what: str) {
    if got != want {
        die(what + ": got [" + got + "] want [" + want + "]");
    }
}

// ---- the server ------------------------------------------------------

gc struct Stats {
    accepts: int,
    lock: mutex,
}

gc struct Req {
    method: str,
    path: str,
    head: str,        // lowercased header block
    body: str,
}

fn find_head_end(b: bytes) -> int {
    let i = 0;
    while i + 3 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

// One request off a kept-alive connection. The client never pipelines,
// so nothing after this request's body is on the wire yet.
fn read_one(fd: i32) -> opt[Req] {
    let buf = b"";
    let sep = -1;
    while sep < 0 {
        let rr = net.recv(fd, 4096);
        guard let got = rr else { return none; }
        if len(got) == 0 {
            return none;
        }
        buf = buf + got;
        sep = find_head_end(buf);
    }
    let raw_head = to_str(buf[0..sep]);
    let head = strings.to_lower(raw_head);
    let line_end = strings.find(raw_head, "\r\n");
    let line = strings.slice(raw_head, 0, line_end);
    let parts = strings.split(line, " ");
    let need = 0;
    let cl = strings.find(head, "content-length:");
    if cl >= 0 {
        let after = strings.slice(head, cl + 15, len(head));
        let eol = strings.find(after, "\r");
        if eol < 0 {
            eol = len(after);
        }
        let nr = to_int(strings.trim(strings.slice(after, 0, eol)));
        guard let n = nr else { return none; }
        need = n;
    }
    while len(buf) < sep + 4 + need {
        let rr2 = net.recv(fd, 4096);
        guard let got2 = rr2 else { return none; }
        if len(got2) == 0 {
            return none;
        }
        buf = buf + got2;
    }
    let body = to_str(buf[sep + 4..sep + 4 + need]);
    return some(Req { method: parts[0], path: parts[1], head: head,
                      body: body });
}

fn ok_text(body: str) -> bytes {
    return to_bytes("HTTP/1.1 200 OK\r\nContent-Length: " + to_str(len(body)) +
                    "\r\n\r\n" + body);
}

fn encoded(encoding: str, payload: bytes) -> bytes {
    return to_bytes("HTTP/1.1 200 OK\r\nContent-Encoding: " + encoding +
                    "\r\nContent-Length: " + to_str(len(payload)) +
                    "\r\n\r\n") + payload;
}

fn header_value(head: str, name: str) -> str {
    let at = strings.find(head, "\r\n" + name + ":");
    if at < 0 {
        return "none";
    }
    let after = strings.slice(head, at + len(name) + 3, len(head));
    let eol = strings.find(after, "\r");
    if eol < 0 {
        eol = len(after);
    }
    return strings.trim(strings.slice(after, 0, eol));
}

// Serves requests on one connection until the client closes it or a
// route decides the connection ends.
fn conn_loop(fd: i32) {
    let n = 0;
    while true {
        let rq = read_one(fd);
        guard let r = rq else {
            net.close(fd);
            return;
        }
        n = n + 1;

        if r.path == "/ka" {
            net.send(fd, ok_text("ka"));
        } else if r.path == "/conn" {
            // what Connection header the client sent
            net.send(fd, ok_text(header_value(r.head, "connection")));
        } else if r.path == "/ae" {
            net.send(fd, ok_text(header_value(r.head, "accept-encoding")));
        } else if r.path == "/closehdr" {
            net.send(fd, to_bytes("HTTP/1.1 200 OK\r\nConnection: close\r\n" +
                                  "Content-Length: 2\r\n\r\nch"));
            net.close(fd);
            return;
        } else if r.path == "/eof" {
            net.send(fd, b"HTTP/1.1 200 OK\r\n\r\ntail");
            net.close(fd);
            return;
        } else if r.path == "/eofempty" {
            // close-delimited AND empty: nothing left in the client's
            // buffer, so only end-of-connection says "do not reuse"
            net.send(fd, b"HTTP/1.1 200 OK\r\n\r\n");
            net.close(fd);
            return;
        } else if r.path == "/stale" {
            // A normal keep-alive response, then the server's own idle
            // timer fires. No Connection: close -- the client is not told.
            net.send(fd, ok_text("stale"));
            net.close(fd);
            return;
        } else if r.path == "/drop2" {
            // First request on a connection is answered. Any later one is
            // read and then dropped without a byte of response -- what a
            // client sees when the server dies with the request in hand.
            if n >= 2 {
                net.close(fd);
                return;
            }
            net.send(fd, ok_text("fresh " + r.method));
        } else if r.path == "/chunk" {
            net.send(fd, b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
                         b"2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n");
        } else if r.path == "/gz" {
            let g = compress.gzip(b"hello gzip");
            guard let gz = g else { net.close(fd); return; }
            net.send(fd, encoded("gzip", gz));
        } else if r.path == "/zlibdeflate" {
            let d = compress.deflate(b"hello zlib");
            guard let z = d else { net.close(fd); return; }
            net.send(fd, encoded("deflate", z));
        } else if r.path == "/rawdeflate" {
            // raw DEFLATE mislabelled "deflate", as a share of real
            // servers send it
            let d = compress.deflate_raw(b"hello raw");
            guard let z = d else { net.close(fd); return; }
            net.send(fd, encoded("deflate", z));
        } else if r.path == "/bomb" {
            // 40 MiB of one byte behind a 40 KiB gzip body, past the
            // client's 32 MiB ceiling
            let g = compress.gzip(to_bytes(strings.repeat("a", 41943040)));
            guard let gz = g else { net.close(fd); return; }
            net.send(fd, encoded("gzip", gz));
        } else if r.path == "/echo" {
            net.send(fd, ok_text(r.method + ":" + r.body));
        } else {
            net.send(fd, b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        }
    }
}

fn serve(lfd: i32, st: Stats) {
    while true {
        let ar = net.accept(lfd);
        guard let cfd = ar else { return; }
        mutex_lock(st.lock);
        st.accepts = st.accepts + 1;
        mutex_unlock(st.lock);
        spawn conn_loop(cfd);
    }
}

fn accepts(st: Stats) -> int {
    mutex_lock(st.lock);
    let n = st.accepts;
    mutex_unlock(st.lock);
    return n;
}

fn dl() -> until {
    return until_of(time.mono() + 10000000000);
}

fn get_body(c: httpc.Client, url: str, what: str) -> str {
    let r = httpc.client_get(c, url, dl());
    guard let resp = r else let e = err_of(r) {
        die(what + ": " + e);
    }
    return to_str(resp.body);
}

// ---- setup -----------------------------------------------------------

let lr = net.listen(0);
guard let lfd = lr else { die("listen"); }
let pr = net.port(lfd);
guard let port = pr else { die("port"); }
let st = Stats { accepts: 0, lock: make_mutex() };
spawn serve(lfd, st);
let base = "http://127.0.0.1:" + to_str(port);

// ---- A: sequential requests share one connection ---------------------

let before_a = accepts(st);
let ca = httpc.new_client();
let i = 0;
while i < 5 {
    expect(get_body(ca, base + "/ka", "A"), "ka", "A body");
    i = i + 1;
}
expect(to_str(ca.dials) + "/" + to_str(ca.reuses), "1/4", "A: 5 requests, 1 dial, 4 reuses");
expect(to_str(httpc.idle_count(ca)), "1", "A: the connection went back to the pool");
time.sleep(20000000);
expect(to_str(accepts(st) - before_a), "1", "A: server accepted one connection");
println("5 sequential requests rode one connection (client and server agree)");

// ---- B: what each mode tells the server ------------------------------

let r_os = httpc.get(base + "/conn", dl());
guard let os_resp = r_os else let e = err_of(r_os) { die("B oneshot: " + e); }
expect(to_str(os_resp.body), "close", "B: one-shot sends Connection: close");
expect(get_body(ca, base + "/conn", "B"), "none", "B: pooled client sends no Connection header");
println("one-shot says close; a pooling client says nothing (keep-alive is the default)");

// ---- C, D: responses that forbid reuse --------------------------------

// idle_count is checked straight after each response. Without it these
// cases pass even if the client pooled the connection, because the
// server here also closes it, and the probe then throws it away on the
// next request -- a control proved exactly that. A server that says
// Connection: close and lingers would not be caught by the probe.
let cc = httpc.new_client();
expect(get_body(cc, base + "/closehdr", "C1"), "ch", "C body");
expect(to_str(httpc.idle_count(cc)), "0", "C: Connection: close was not pooled");
expect(get_body(cc, base + "/closehdr", "C2"), "ch", "C body 2");
expect(to_str(cc.dials) + "/" + to_str(cc.reuses), "2/0", "C: Connection: close is honoured");

let cd = httpc.new_client();
expect(get_body(cd, base + "/eof", "D1"), "tail", "D body");
expect(to_str(httpc.idle_count(cd)), "0", "D: a close-delimited body was not pooled");
expect(get_body(cd, base + "/eof", "D2"), "tail", "D body 2");
expect(to_str(cd.dials) + "/" + to_str(cd.reuses), "2/0", "D: a close-delimited body is not reused");
// The empty case is the one that matters: a non-empty close-delimited
// body still sits in the read buffer, which blocks reuse on its own and
// hid a control that removed the end-of-connection check.
expect(get_body(cd, base + "/eofempty", "D3"), "", "D3 body");
expect(to_str(httpc.idle_count(cd)), "0", "D3: an empty close-delimited body was not pooled");
println("Connection: close and close-delimited bodies are never reused");

// ---- E: the server closed the idle connection ------------------------
//
// The sleep lets the FIN land before the next request, so this checks
// the PROBE specifically: the stale connection must be recognised before
// anything is written to it, which is what keeps a POST safe.

let ce = httpc.new_client();
expect(get_body(ce, base + "/stale", "E1"), "stale", "E body");
time.sleep(50000000);
let e_post = httpc.client_post(ce, base + "/echo", "text/plain", b"once", dl());
guard let ep = e_post else let e = err_of(e_post) { die("E post after stale: " + e); }
expect(to_str(ep.body), "POST:once", "E: POST after the server closed idle");
expect(to_str(ce.dials) + "/" + to_str(ce.reuses), "2/0", "E: the probe discarded the dead connection");
println("a connection the server closed while idle is detected before use");

// ---- F, G: the server drops a request mid-flight ---------------------
//
// Connection alive at the probe, request written, then closed with no
// response. Idempotent requests are retried once on a fresh connection;
// a POST is not, because it may already have been acted on.

let cf = httpc.new_client();
expect(get_body(cf, base + "/ka", "F1"), "ka", "F warmup");
expect(get_body(cf, base + "/drop2", "F2"), "fresh GET", "F: GET retried on a fresh connection");
expect(to_str(cf.dials) + "/" + to_str(cf.reuses), "2/1", "F: one reuse, one retry dial");

let cg = httpc.new_client();
expect(get_body(cg, base + "/ka", "G1"), "ka", "G warmup");
let g_post = httpc.client_post(cg, base + "/drop2", "text/plain", b"charge", dl());
guard let _gp = g_post else let e = err_of(g_post) {
    expect(to_str(cg.dials), "1", "G: POST was not retried");
    println("a dropped GET is retried; a dropped POST is reported, never resent");
}

// ---- H: chunked bodies are consumed exactly ---------------------------

let ch = httpc.new_client();
expect(get_body(ch, base + "/chunk", "H1"), "abcd", "H body");
expect(get_body(ch, base + "/chunk", "H2"), "abcd", "H body 2");
expect(get_body(ch, base + "/ka", "H3"), "ka", "H: a normal response after two chunked ones");
expect(to_str(ch.dials), "1", "H: chunked responses leave the connection reusable");
println("chunked responses leave the connection clean for the next request");

// ---- I: decompression -------------------------------------------------

let ci = httpc.new_client();
expect(get_body(ci, base + "/ae", "I ae"), "gzip, deflate", "I: advertised encodings");

let gzr = httpc.client_get(ci, base + "/gz", dl());
guard let gzresp = gzr else let e = err_of(gzr) { die("I gz: " + e); }
expect(to_str(gzresp.body), "hello gzip", "I: gzip decoded");
guard let _ceh = httpc.header(gzresp, "content-encoding") else {
    println("gzip response decoded, and its Content-Encoding removed");
}
expect(get_body(ci, base + "/zlibdeflate", "I zlib"), "hello zlib", "I: deflate as zlib");
expect(get_body(ci, base + "/rawdeflate", "I raw"), "hello raw", "I: deflate sent as raw DEFLATE");
println("deflate decodes whether the server sent zlib or raw DEFLATE");

// A caller who sets Accept-Encoding gets the bytes as sent.
let rq = httpc.new_request("GET", base + "/gz");
rq.headers["Accept-Encoding"] = "gzip";
let rawr = httpc.client_send(ci, rq, dl());
guard let rawresp = rawr else let e = err_of(rawr) { die("I raw passthrough: " + e); }
guard let ce_kept = httpc.header(rawresp, "content-encoding") else {
    die("I: Content-Encoding should be kept when the caller asked");
}
expect(ce_kept, "gzip", "I: header kept");
let check = compress.gunzip(rawresp.body, 1000);
guard let still = check else { die("I: passthrough body should still be gzip"); }
expect(to_str(still), "hello gzip", "I: passthrough body is the compressed bytes");
println("a caller who sets Accept-Encoding gets the compressed bytes untouched");

// ---- J: a decompression bomb in a response ----------------------------

let bombr = httpc.client_get(ci, base + "/bomb", dl());
guard let _br = bombr else let e = err_of(bombr) {
    if !strings.contains(e, "limit") {
        die("J: the error should name the limit: " + e);
    }
    println("a gzip bomb in a response is refused at the body ceiling");
}

// ---- K: one client shared by concurrent tasks ------------------------
//
// The invariant that proves the pool's bookkeeping is sound under
// contention: every request either dialed or reused a connection, so the
// two counters must sum to exactly the number of requests.

fn burst(c: httpc.Client, url: str) -> int {
    let got = 0;
    let n = 0;
    while n < 10 {
        let r = httpc.client_get(c, url, until_of(time.mono() + 10000000000));
        guard let resp = r else { return got; }
        if to_str(resp.body) == "ka" {
            got = got + 1;
        }
        n = n + 1;
    }
    return got;
}

let ck = httpc.new_client();
let hs: [join[int]] = [];
let t = 0;
while t < 16 {
    push(hs, spawn burst(ck, base + "/ka"));
    t = t + 1;
}
let total = 0;
for h in hs {
    let jr = join_wait(h);
    guard let n = jr else { die("K: a task panicked"); }
    total = total + n;
}
expect(to_str(total), "160", "K: every concurrent request succeeded");
expect(to_str(ck.dials + ck.reuses), "160", "K: dials + reuses == requests");
if ck.reuses == 0 {
    die("K: 160 requests from 16 tasks reused nothing");
}
println("16 tasks sharing one client: 160/160 correct, dials + reuses == 160");


// ---- L: TLS pooling, and the trust anchor in the pool key -------------
//
// A connection verified against one CA must never be handed to a request
// that demands a different one. If the pool were keyed by origin alone,
// the second request below would ride the connection the first one
// verified and SUCCEED -- a request that asked for other.pem would be
// served by a server other.pem does not vouch for.

fn tls_read_one(ssl: rawptr) -> bool {
    let buf = b"";
    while find_head_end(buf) < 0 {
        let rr = net.tls_recv(ssl, 4096);
        guard let got = rr else { return false; }
        if len(got) == 0 {
            return false;
        }
        buf = buf + got;
    }
    return true;       // the client sends GETs with no body here
}

fn tls_conn(ssl: rawptr) {
    while tls_read_one(ssl) {
        net.tls_send(ssl, ok_text("secure"));
    }
    net.tls_close(ssl);
}

// net.tls_accept takes the LISTENING fd and accepts itself, then
// handshakes. A failed handshake (the L2 client rejecting our cert) is
// that one connection's problem, so the loop carries on.
fn tls_serve(lfd: i32, ctx: rawptr) {
    while true {
        let hr = net.tls_accept(lfd, ctx);
        guard let ssl = hr else {
            continue;
        }
        spawn tls_conn(ssl);
    }
}

let tlr = net.listen(0);
guard let tlfd = tlr else { die("tls listen"); }
let tpr = net.port(tlfd);
guard let tport = tpr else { die("tls port"); }
let scr = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
guard let sctx = scr else let e = err_of(scr) { die("tls server ctx: " + e); }
spawn tls_serve(tlfd, sctx);
let turl = "https://localhost:" + to_str(tport) + "/ka";

fn tls_get(c: httpc.Client, url: str, ca: str) -> result[httpc.Response, str] {
    let rq = httpc.new_request("GET", url);
    rq.ca_path = ca;
    return httpc.client_send(c, rq, until_of(time.mono() + 10000000000));
}

let cl = httpc.new_client();
let l1 = tls_get(cl, turl, "tests/tls/cert.pem");
guard let l1r = l1 else let e = err_of(l1) { die("L1 trusted: " + e); }
expect(to_str(l1r.body), "secure", "L1 body");

let l2 = tls_get(cl, turl, "tests/tls/other.pem");
guard let _l2r = l2 else let e = err_of(l2) {
    if !strings.contains(e, "verify") {
        die("L2: expected a verification failure, got: " + e);
    }
    println("a pooled TLS connection is never reused under a different CA");
}

let l3 = tls_get(cl, turl, "tests/tls/cert.pem");
guard let l3r = l3 else let e = err_of(l3) { die("L3 trusted again: " + e); }
expect(to_str(l3r.body), "secure", "L3 body");
if cl.reuses < 1 {
    die("L3: the verified TLS connection should have been reused");
}
println("TLS connections pool and are reused under the same CA");

httpc.close_idle(ck);
httpc.close_idle(cl);
println("done");
exit(0);
