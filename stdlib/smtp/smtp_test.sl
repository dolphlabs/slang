import "encoding";
import "net";
import "strings";
import "time";

fn is_ok(r: result[bool, str]) -> bool {
    if let _v = r { return true; }
    return false;
}

fn soon() -> until { return until_of(time.mono() + 10000000000); }

// A scripted SMTP server: answers each command per the options and
// reports every line it received (DATA content as one entry).
gc struct Srv {
    tls: bool,
    fd: i32,
    ssl: rawptr,
    buf: str,
    offer_starttls: bool,
    reject_rcpt: bool,
}

fn srv_send(s: Srv, line: str) {
    if s.tls { let _a = net.tls_send(s.ssl, to_bytes(line + "\r\n")); }
    else { let _b = net.send(s.fd, to_bytes(line + "\r\n")); }
}

fn srv_line(s: Srv) -> str {
    while true {
        let i = strings.find(s.buf, "\r\n");
        if i >= 0 {
            let l = strings.slice(s.buf, 0, i);
            s.buf = strings.slice(s.buf, i + 2, len(s.buf));
            return l;
        }
        let r = net.recv_until(s.fd, 4096, soon());
        if s.tls { r = net.tls_recv_until(s.ssl, 4096, soon()); }
        guard let b = r else { return "<closed>"; }
        if len(b) == 0 { return "<closed>"; }
        s.buf = s.buf + to_str(b);
    }
    return "";
}

fn serve(s: Srv, out: chan[[str]]) {
    let seen: [str] = [];
    srv_send(s, "220 test.local ESMTP");
    while true {
        let l = srv_line(s);
        push(seen, l);
        let u = strings.to_upper(l);
        if l == "<closed>" { break; }
        if strings.has_prefix(u, "EHLO") {
            srv_send(s, "250-test.local");
            if s.offer_starttls { srv_send(s, "250-STARTTLS"); }
            srv_send(s, "250 AUTH LOGIN PLAIN");
        } else if strings.has_prefix(u, "AUTH PLAIN") {
            srv_send(s, "235 2.7.0 ok");
        } else if strings.has_prefix(u, "MAIL FROM") {
            srv_send(s, "250 ok");
        } else if strings.has_prefix(u, "RCPT TO") {
            if s.reject_rcpt { srv_send(s, "550 5.1.1 no such user"); } else { srv_send(s, "250 ok"); }
        } else if u == "DATA" {
            srv_send(s, "354 go ahead");
            let body = "";
            while true {
                let d = srv_line(s);
                if d == "." || d == "<closed>" { break; }
                body = body + d + "\n";
            }
            push(seen, "BODY:" + body);
            srv_send(s, "250 queued");
        } else if u == "QUIT" {
            srv_send(s, "221 bye");
            break;
        } else {
            srv_send(s, "502 unknown");
        }
    }
    if s.tls { net.tls_close(s.ssl); } else { net.close(s.fd); }
    chan_send(out, seen);
}

fn plain_server(lfd: i32, starttls: bool, reject: bool, out: chan[[str]]) {
    let fd = net.accept(lfd) ?? (-1 as i32);
    serve(Srv { tls: false, fd: fd, ssl: nullptr, buf: "", offer_starttls: starttls, reject_rcpt: reject }, out);
}

fn tls_server(lfd: i32, ctx: rawptr, out: chan[[str]]) {
    let r = net.tls_accept(lfd, ctx);
    guard let ssl = r else { let none_seen: [str] = []; chan_send(out, none_seen); return; }
    serve(Srv { tls: true, fd: -1 as i32, ssl: ssl, buf: "", offer_starttls: false, reject_rcpt: false }, out);
}

fn local(port: int, security: str) -> Config {
    let c = config("127.0.0.1", port);
    c.security = security;
    c.helo = "client.test";
    return c;
}

fn test_should_run_a_whole_transaction_through_a_plain_relay() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let out: chan[[str]] = make_chan(1);
    spawn plain_server(lfd, false, false, out);
    let m = message("App <app@example.com>", ["Ada <ada@example.com>"], "Hi");
    m.bcc = ["audit@example.com"];
    m.text = "hello";
    let r = send(local(port, "none"), m, soon());
    assert(is_ok(r), "send: " + err_of(r));
    let seen = chan_recv(out) ?? [];
    assert(seen[0] == "EHLO client.test", "ehlo: " + seen[0]);
    assert(seen[1] == "MAIL FROM:<app@example.com>", seen[1]);
    assert(seen[2] == "RCPT TO:<ada@example.com>" && seen[3] == "RCPT TO:<audit@example.com>", "rcpts");
    assert(seen[4] == "DATA", "data");
    assert(strings.contains(seen[5], "From: \"App\" <app@example.com>\n"), "from header");
    assert(!strings.contains(seen[5], "audit@example.com"), "bcc leaked into the headers");
    assert(seen[6] == "QUIT", "quit");
    net.close(lfd);
}

fn test_should_dot_stuff_the_body() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let out: chan[[str]] = make_chan(1);
    spawn plain_server(lfd, false, false, out);
    let r = send_raw(local(port, "none"), "a@x", ["b@x"], b"Subject: t\r\n\r\n.starts with a dot\r\n..two\r\nend", soon());
    assert(is_ok(r), "send_raw: " + err_of(r));
    let seen = chan_recv(out) ?? [];
    // the server sees the stuffed lines; it would strip one dot each
    assert(strings.contains(seen[4], "\n..starts with a dot\n...two\nend\n"), "stuffing: " + seen[4]);
    net.close(lfd);
}

fn test_should_refuse_a_server_without_starttls_before_any_password() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let out: chan[[str]] = make_chan(1);
    spawn plain_server(lfd, false, false, out);
    let c = local(port, "starttls");
    c.username = "user";
    c.password = "hunter2";
    let r = send(c, message("a@x", ["b@x"], "s"), soon());
    assert(strings.contains(err_of(r), "STARTTLS"), "error: " + err_of(r));
    let seen = chan_recv(out) ?? [];
    for l in seen {
        assert(!strings.contains(strings.to_upper(l), "AUTH"), "credentials sent without TLS");
    }
    net.close(lfd);
}

fn test_should_report_a_rejected_recipient() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let out: chan[[str]] = make_chan(1);
    spawn plain_server(lfd, false, true, out);
    let r = send(local(port, "none"), message("a@x", ["nobody@x"], "s"), soon());
    assert(strings.contains(err_of(r), "550 5.1.1 no such user"), "error: " + err_of(r));
    let _s = chan_recv(out);
    net.close(lfd);
}

fn test_should_authenticate_over_implicit_tls() {
    let lfd = net.listen(0) ?? (-1 as i32);
    let port = net.port(lfd) ?? 0;
    let sc = net.tls_server_ctx("tests/tls/cert.pem", "tests/tls/key.pem");
    guard let ctx = sc else let e = err_of(sc) { panic("server ctx: " + e); }
    let out: chan[[str]] = make_chan(1);
    spawn tls_server(lfd, ctx, out);
    let c = config("localhost", port);
    c.security = "tls";
    c.ca_path = "tests/tls/cert.pem";
    c.username = "user@example.com";
    c.password = "s3cret";
    let r = send(c, message("a@x", ["b@x"], "over tls"), soon());
    assert(is_ok(r), "send: " + err_of(r));
    let seen = chan_recv(out) ?? [];
    let auth = "";
    for l in seen { if strings.has_prefix(l, "AUTH PLAIN ") { auth = strings.slice(l, 11, len(l)); } }
    let dec = encoding.base64_decode(auth) ?? b"";
    assert(dec == b"\x00user@example.com\x00s3cret", "AUTH PLAIN credentials: " + auth);
    net.close(lfd);
}

fn test_should_build_mime_with_attachments_and_safe_headers() {
    let m = message("a@x", ["b@x"], "line\r\nBcc: victim@evil");
    m.text = "t";
    m.html = "<b>h</b>";
    m.attachments = [Attachment { name: "r\"q.csv", content_type: "text/csv", data: to_bytes(strings.repeat("x", 200)) }];
    let s = to_str(build(m));
    assert(!strings.contains(s, "\r\nBcc:"), "header injection");
    assert(strings.contains(s, "Content-Type: multipart/mixed; boundary=\"mixed_"), "mixed");
    assert(strings.contains(s, "Content-Type: multipart/alternative; boundary=\"alt_"), "alternative");
    assert(strings.contains(s, "filename=\"r\\\"q.csv\""), "quoted filename");
    for l in strings.split(s, "\r\n") {
        assert(len(l) <= 998, "line over the RFC 5322 limit");
    }
    assert(strings.contains(s, "\r\n" + strings.slice(encoding.base64_encode(to_bytes(strings.repeat("x", 200))), 0, 76) + "\r\n"), "76-column base64");
}
