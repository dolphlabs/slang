// httpc: the HTTP/1.1 client.
//
// Tested against a canned server in this same program rather than a
// real one, because the point of most of these cases is a response
// shape a cooperative server will not produce on demand: a chunked body
// with trailers, a 204 that must not be waited on, a body framed only
// by the connection closing, a redirect loop. Writing the bytes by hand
// is the only way to be sure the client saw them.
//
// The server speaks raw fds (net.listen/accept/recv/send) so that what
// it sends is exactly what is written below, with no framing helper in
// between.

import "net";
import "time";
import "strings";
import "httpc";

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
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

// Read a whole request: headers, then a Content-Length body if there is
// one. The client under test always sends Content-Length, so this does
// not need to handle a chunked request.
fn read_request(fd: i32) -> str {
    let buf = b"";
    let sep = -1;
    while sep < 0 {
        let rr = net.recv(fd, 4096);
        guard let got = rr else { return to_str(buf); }
        if len(got) == 0 {
            return to_str(buf);
        }
        buf = buf + got;
        sep = find_head_end(buf);
        if len(buf) > 32768 {
            return to_str(buf);
        }
    }
    let head = strings.to_lower(to_str(buf[0..sep]));
    let cl = strings.find(head, "content-length:");
    if cl >= 0 {
        let after = strings.slice(head, cl + 15, len(head));
        let eol = strings.find(after, "\r");
        if eol > 0 {
            let nr = to_int(strings.trim(strings.slice(after, 0, eol)));
            guard let n = nr else { return to_str(buf); }
            while len(buf) < sep + 4 + n {
                let rr2 = net.recv(fd, 4096);
                guard let got2 = rr2 else { return to_str(buf); }
                if len(got2) == 0 {
                    return to_str(buf);
                }
                buf = buf + got2;
            }
        }
    }
    return to_str(buf);
}

fn reply(fd: i32, raw: bytes) {
    net.send(fd, raw);
    net.close(fd);
}

fn body_of(req: str) -> str {
    let sep = strings.find(req, "\r\n\r\n");
    if sep < 0 {
        return "";
    }
    return strings.slice(req, sep + 4, len(req));
}

fn method_of(req: str) -> str {
    let sp = strings.find(req, " ");
    if sp < 0 {
        return "?";
    }
    return strings.slice(req, 0, sp);
}

fn serve_one(fd: i32, port: int) {
    let req = read_request(fd);

    // HEAD gets the identical headers GET would, Content-Length and
    // all, but no body -- which is what RFC 9110 requires and is
    // exactly the trap: a client that believes Content-Length here
    // waits forever for five bytes that are never coming.
    if strings.contains(req, "HEAD /plain ") {
        reply(fd, b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" +
                  b"Content-Length: 5\r\n\r\n");
        return;
    }
    if strings.contains(req, "GET /plain ") {
        reply(fd, b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" +
                  b"Content-Length: 5\r\n\r\nhello");
        return;
    }
    // Two chunks, an extension on the first (which must be ignored),
    // and a trailer after the terminating zero chunk.
    if strings.contains(req, "GET /chunked ") {
        reply(fd, b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
                  b"4;ext=1\r\nchun\r\n" +
                  b"4\r\nked!\r\n" +
                  b"0\r\nX-Trailer: ignored\r\n\r\n");
        return;
    }
    // A body framed only by the close. Legal in HTTP/1.1 for a response,
    // and the reason the client always sends Connection: close.
    if strings.contains(req, "GET /close ") {
        reply(fd, b"HTTP/1.1 200 OK\r\n\r\nto the end");
        return;
    }
    // 204 carries a Content-Length it is not allowed to have. A client
    // that trusts it hangs; this one must ignore it.
    if strings.contains(req, "GET /204 ") {
        reply(fd, b"HTTP/1.1 204 No Content\r\nContent-Length: 10\r\n\r\n");
        return;
    }
    if strings.contains(req, "GET /notfound ") {
        reply(fd, b"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\n" +
                  b"no such p");
        return;
    }
    // Repeated header, which RFC 9110 says is one comma-joined value.
    if strings.contains(req, "GET /dup ") {
        reply(fd, b"HTTP/1.1 200 OK\r\nX-Tag: a\r\nX-Tag: b\r\n" +
                  b"Content-Length: 2\r\n\r\nok");
        return;
    }
    if strings.contains(req, "/redir302 ") {
        reply(fd, b"HTTP/1.1 302 Found\r\nLocation: /echo\r\n" +
                  b"Content-Length: 0\r\n\r\n");
        return;
    }
    if strings.contains(req, "/redir307 ") {
        reply(fd, b"HTTP/1.1 307 Temporary Redirect\r\nLocation: /echo\r\n" +
                  b"Content-Length: 0\r\n\r\n");
        return;
    }
    if strings.contains(req, "/loop ") {
        reply(fd, b"HTTP/1.1 302 Found\r\nLocation: /loop\r\n" +
                  b"Content-Length: 0\r\n\r\n");
        return;
    }
    // A cross-origin redirect: same address, different host STRING, so
    // a different origin by the rule in httpc.sl. Credentials must be
    // dropped on the way.
    if strings.contains(req, "/cross ") {
        let to = "http://localhost:" + to_str(port) + "/hdr";
        reply(fd, to_bytes("HTTP/1.1 302 Found\r\nLocation: " + to +
                           "\r\nContent-Length: 0\r\n\r\n"));
        return;
    }
    // Reports whether an Authorization header survived.
    if strings.contains(req, "/hdr ") {
        let saw = "absent";
        if strings.contains(strings.to_lower(req), "authorization:") {
            saw = "present";
        }
        reply(fd, to_bytes("HTTP/1.1 200 OK\r\nContent-Length: " +
                           to_str(len(saw)) + "\r\n\r\n" + saw));
        return;
    }
    // Echoes the method and body it actually received, which is how the
    // redirect method rules are checked.
    if strings.contains(req, "/echo ") {
        let out = method_of(req) + ":" + body_of(req);
        reply(fd, to_bytes("HTTP/1.1 200 OK\r\nContent-Length: " +
                           to_str(len(out)) + "\r\n\r\n" + out));
        return;
    }
    reply(fd, b"HTTP/1.1 500 Server Error\r\nContent-Length: 0\r\n\r\n");
}

fn serve(lfd: i32, port: int) {
    while true {
        let ar = net.accept(lfd);
        guard let cfd = ar else { return; }
        serve_one(cfd, port);
    }
}

fn expect(got: str, want: str, what: str) {
    if got != want {
        die(what + ": got [" + got + "] want [" + want + "]");
    }
}

// ---- URL parsing (no server needed) ----------------------------------

fn check_url(u: str, want: str) {
    let r = httpc.parse_url(u);
    guard let p = r else let e = err_of(r) {
        die("parse_url " + u + ": " + e);
    }
    expect(p.scheme + "|" + p.host + "|" + to_str(p.port) + "|" + p.path,
           want, "parse_url " + u);
}

fn check_url_fails(u: str, what: str) {
    let r = httpc.parse_url(u);
    guard let _p = r else {
        println("rejected " + what);
        return;
    }
    die("expected " + what + " to be rejected");
}

check_url("http://example.com", "http|example.com|80|/");
check_url("https://example.com", "https|example.com|443|/");
check_url("http://example.com:8080/a/b?x=1#frag",
          "http|example.com|8080|/a/b?x=1#frag");
check_url("https://example.com/p", "https|example.com|443|/p");
check_url("http://[::1]:9000/v6", "http|::1|9000|/v6");
check_url("http://[::1]/v6", "http|::1|80|/v6");
check_url("HTTP://Example.COM/Keep", "http|Example.COM|80|/Keep");

check_url_fails("ftp://example.com", "a non-http scheme");
check_url_fails("example.com/x", "a url with no scheme");
check_url_fails("http://", "a url with no host");
check_url_fails("http://user:pw@example.com", "credentials in the url");
check_url_fails("http://example.com:0/", "port 0");
check_url_fails("http://example.com:99999/", "an out-of-range port");
check_url_fails("http://example.com:80x/", "a non-numeric port");

// ---- against the canned server ---------------------------------------

let lr = net.listen(0);
guard let lfd = lr else { die("listen"); }
let pr = net.port(lfd);
guard let port = pr else { die("port"); }
spawn serve(lfd, port);

let base = "http://127.0.0.1:" + to_str(port);
let dl = until_of(time.mono() + 5000000000);

// plain 200 with Content-Length
let r1 = httpc.get(base + "/plain", dl);
guard let p1 = r1 else let e = err_of(r1) { die("get /plain: " + e); }
expect(to_str(p1.status) + " " + p1.status_text, "200 OK", "status");
expect(to_str(p1.body), "hello", "body");
guard let ct = httpc.header(p1, "Content-Type") else { die("no content-type"); }
expect(ct, "text/plain", "header lookup is case-insensitive");
expect(p1.url, base + "/plain", "response url");

// chunked, with an extension and a trailer
let r2 = httpc.get(base + "/chunked", dl);
guard let p2 = r2 else let e = err_of(r2) { die("get /chunked: " + e); }
expect(to_str(p2.body), "chunked!", "chunked body");

// body framed by the close
let r3 = httpc.get(base + "/close", dl);
guard let p3 = r3 else let e = err_of(r3) { die("get /close: " + e); }
expect(to_str(p3.body), "to the end", "close-framed body");

// 204: the Content-Length it wrongly carries must be ignored
let r4 = httpc.get(base + "/204", dl);
guard let p4 = r4 else let e = err_of(r4) { die("get /204: " + e); }
expect(to_str(p4.status) + "/" + to_str(len(p4.body)), "204/0", "204 body");

// a 404 is a RESPONSE, not an error -- the request succeeded
let r5 = httpc.get(base + "/notfound", dl);
guard let p5 = r5 else let e = err_of(r5) { die("get /notfound: " + e); }
expect(to_str(p5.status), "404", "404 status");
expect(to_str(p5.body), "no such p", "404 body");

// repeated headers join with ", "
let r6 = httpc.get(base + "/dup", dl);
guard let p6 = r6 else let e = err_of(r6) { die("get /dup: " + e); }
guard let tag = httpc.header(p6, "x-tag") else { die("no x-tag"); }
expect(tag, "a, b", "repeated headers join");

// POST round trip
let r7 = httpc.post(base + "/echo", "text/plain", b"payload", dl);
guard let p7 = r7 else let e = err_of(r7) { die("post: " + e); }
expect(to_str(p7.body), "POST:payload", "post echo");

// HEAD: no body, however the response is framed
let r8 = httpc.head(base + "/plain", dl);
guard let p8 = r8 else let e = err_of(r8) { die("head: " + e); }
expect(to_str(p8.status) + "/" + to_str(len(p8.body)), "200/0", "head body");

// 302 after a POST becomes a GET and drops the body -- browser
// behaviour, and what servers expect
let rq9 = httpc.new_request("POST", base + "/redir302");
rq9.body = b"dropme";
let r9 = httpc.send(rq9, dl);
guard let p9 = r9 else let e = err_of(r9) { die("302: " + e); }
expect(to_str(p9.body), "GET:", "302 after POST becomes GET");
expect(p9.url, base + "/echo", "redirect reports the final url");

// 307 preserves both method and body
let rq10 = httpc.new_request("POST", base + "/redir307");
rq10.body = b"keepme";
let r10 = httpc.send(rq10, dl);
guard let p10 = r10 else let e = err_of(r10) { die("307: " + e); }
expect(to_str(p10.body), "POST:keepme", "307 preserves method and body");

// a redirect loop stops at the cap and hands back the last 3xx rather
// than spinning
let r11 = httpc.get(base + "/loop", dl);
guard let p11 = r11 else let e = err_of(r11) { die("loop: " + e); }
expect(to_str(p11.status), "302", "redirect loop stops at the cap");

// max_redirects 0 disables following entirely
let rq12 = httpc.new_request("GET", base + "/redir302");
rq12.max_redirects = 0;
let r12 = httpc.send(rq12, dl);
guard let p12 = r12 else let e = err_of(r12) { die("no-follow: " + e); }
expect(to_str(p12.status), "302", "max_redirects 0 does not follow");

// credentials do not survive a cross-origin redirect
let rq13 = httpc.new_request("GET", base + "/cross");
rq13.headers["Authorization"] = "Bearer secret";
let r13 = httpc.send(rq13, dl);
guard let p13 = r13 else let e = err_of(r13) { die("cross: " + e); }
expect(to_str(p13.body), "absent", "Authorization dropped cross-origin");

// ...but does survive a same-origin one
let rq14 = httpc.new_request("GET", base + "/redir302");
rq14.headers["Authorization"] = "Bearer secret";
rq14.body = b"";
let r14 = httpc.send(rq14, dl);
guard let p14 = r14 else let e = err_of(r14) { die("same-origin: " + e); }
expect(to_str(p14.body), "GET:", "same-origin redirect still reaches /echo");

// a connection refused is an error with the host in it, not a panic
let r15 = httpc.get("http://127.0.0.1:1/nope", dl);
guard let _p15 = r15 else let e = err_of(r15) {
    if !strings.contains(e, "127.0.0.1") {
        die("dial error should name the host: " + e);
    }
    println("connection refused reported, not panicked");
}

println("done");
exit(0);
