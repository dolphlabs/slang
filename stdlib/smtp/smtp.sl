// Sending mail: an SMTP client (RFC 5321) with STARTTLS or implicit TLS
// and AUTH PLAIN, and a MIME builder (RFC 5322, 2045-2047) for text,
// HTML and attachments.
//
//     import "smtp";
//
//     let cfg = smtp.config("smtp.example.com", 587);   // STARTTLS
//     cfg.username = "app@example.com";
//     cfg.password = proc.getenv("SMTP_PASSWORD") ?? "";
//     let m = smtp.message("App <app@example.com>", ["ada@example.com"], "Welcome");
//     m.text = "Hello Ada";
//     m.html = "<p>Hello <b>Ada</b></p>";
//     let r = smtp.send(cfg, m, deadline);
//
// TLS is required unless the config says otherwise: a server that does
// not offer STARTTLS is refused rather than sent the password in clear.

import "builder";
import "encoding";
import "net";
import "rand";
import "strings";
import "time";

pub struct Config {
    host: str,
    port: int,
    // "starttls" (the default; port 587), "tls" (implicit, port 465), or
    // "none" (plain text: a local relay only).
    security: str,
    username: str,      // "" sends no AUTH
    password: str,
    helo: str,          // the name given in EHLO; default "localhost"
    ca_path: str,       // "" uses the system's CA certificates
}

pub fn config(host: str, port: int) -> Config {
    let sec = "starttls";
    if port == 465 { sec = "tls"; }
    return Config { host: host, port: port, security: sec, username: "", password: "",
                    helo: "localhost", ca_path: "" };
}

pub struct Attachment {
    name: str,
    content_type: str,
    data: bytes,
}

pub struct Message {
    from: str,          // "Name <addr>" or "addr"
    to: [str],
    cc: [str],
    bcc: [str],         // sent to, never shown in a header
    reply_to: str,
    subject: str,
    text: str,
    html: str,
    attachments: [Attachment],
    headers: map[str]str,
}

pub fn message(from: str, to: [str], subject: str) -> Message {
    let none_list: [str] = [];
    let atts: [Attachment] = [];
    let hs: map[str]str = {};
    return Message { from: from, to: to, cc: none_list, bcc: none_list, reply_to: "",
                     subject: subject, text: "", html: "", attachments: atts, headers: hs };
}

// Sends m: one SMTP transaction to every recipient in to, cc and bcc.
pub fn send(cfg: Config, m: Message, deadline: until) -> result[bool, str] {
    let rcpts: [str] = [];
    for a in m.to { push(rcpts, a); }
    for a in m.cc { push(rcpts, a); }
    for a in m.bcc { push(rcpts, a); }
    if len(rcpts) == 0 { return err("smtp: no recipients"); }
    let body = build(m);
    return send_raw(cfg, address_of(m.from), rcpts, body, deadline);
}

// The RFC 5322 message for m, with CRLF line endings: what send puts
// after DATA (before dot-stuffing).
pub fn build(m: Message) -> bytes {
    let r = rand.from_os() ?? rand.new(time.wall() as int);
    let out = builder.new_bytes();
    header(out, "From", encode_address(m.from));
    if len(m.to) > 0 { header(out, "To", join_addresses(m.to)); }
    if len(m.cc) > 0 { header(out, "Cc", join_addresses(m.cc)); }
    if len(m.reply_to) > 0 { header(out, "Reply-To", encode_address(m.reply_to)); }
    header(out, "Subject", encode_word(m.subject));
    header(out, "Date", time.http_date());
    header(out, "Message-ID", "<" + token(r) + "@" + domain_of(address_of(m.from)) + ">");
    header(out, "MIME-Version", "1.0");
    for k, v in m.headers {
        header(out, k, v);
    }
    let alt = len(m.text) > 0 && len(m.html) > 0;
    let mixed = len(m.attachments) > 0;
    if mixed {
        let b = "mixed_" + token(r);
        header(out, "Content-Type", "multipart/mixed; boundary=\"" + b + "\"");
        out.write_str("\r\n");
        out.write_str("--" + b + "\r\n");
        body_part(out, m, alt, r);
        for a in m.attachments {
            out.write_str("--" + b + "\r\n");
            let ct = a.content_type;
            if len(ct) == 0 { ct = "application/octet-stream"; }
            out.write_str("Content-Type: " + ct + "; name=\"" + quote_param(a.name) + "\"\r\n");
            out.write_str("Content-Disposition: attachment; filename=\"" + quote_param(a.name) + "\"\r\n");
            out.write_str("Content-Transfer-Encoding: base64\r\n\r\n");
            base64_lines(out, a.data);
        }
        out.write_str("--" + b + "--\r\n");
    } else {
        body_part(out, m, alt, r);
    }
    return out.finish();
}

// ---- the SMTP dialogue -----------------------------------------------------

gc struct Conn {
    fd: i32,
    ssl: rawptr,
    tls: bool,
    buf: str,
}

pub fn send_raw(cfg: Config, from: str, rcpts: [str], data: bytes, deadline: until)
               -> result[bool, str] {
    let cr = connect(cfg, deadline);
    guard let c = cr else let e = err_of(cr) { return err(e); }
    let r = dialogue(cfg, c, from, rcpts, data, deadline);
    close(c);
    return r;
}

fn connect(cfg: Config, deadline: until) -> result[Conn, str] {
    if cfg.security == "tls" {
        let ctx = net.tls_client_ctx(cfg.ca_path);
        guard let cx = ctx else let ce = err_of(ctx) { return err("smtp: " + ce); }
        let dr = net.tls_dial_until(cfg.host, cfg.port, cx, deadline);
        guard let ssl = dr else let de = err_of(dr) { return err("smtp: " + de); }
        return ok(Conn { fd: -1 as i32, ssl: ssl, tls: true, buf: "" });
    }
    let dr = net.dial_until(cfg.host, cfg.port, deadline);
    guard let fd = dr else let de = err_of(dr) { return err("smtp: " + de); }
    return ok(Conn { fd: fd, ssl: nullptr, tls: false, buf: "" });
}

fn close(c: Conn) {
    if c.tls { net.tls_close(c.ssl); } else { net.close(c.fd); }
}

fn dialogue(cfg: Config, c: Conn, from: str, rcpts: [str], data: bytes, deadline: until)
           -> result[bool, str] {
    let gr = expect(c, 220, deadline);
    guard let _g = gr else let ge = err_of(gr) { return err(ge); }
    let er = ehlo(cfg, c, deadline);
    guard let caps = er else let ee = err_of(er) { return err(ee); }
    let exts = caps;
    if cfg.security == "starttls" {
        if !has_ext(exts, "STARTTLS") {
            return err("smtp: server does not offer STARTTLS (set security to \"none\" for a plain relay)");
        }
        let sr = command(c, "STARTTLS", 220, deadline);
        guard let _s = sr else let se = err_of(sr) { return err(se); }
        if len(c.buf) > 0 {
            // bytes queued behind the go-ahead would be trusted as if
            // they came inside TLS
            return err("smtp: server sent data before the TLS handshake");
        }
        let ctx = net.tls_client_ctx(cfg.ca_path);
        guard let cx = ctx else let ce = err_of(ctx) { return err("smtp: " + ce); }
        let ur = net.tls_upgrade_until(c.fd, cfg.host, cx, deadline);
        guard let ssl = ur else let ue = err_of(ur) { return err("smtp: " + ue); }
        c.ssl = ssl;
        c.tls = true;
        let er2 = ehlo(cfg, c, deadline);
        guard let caps2 = er2 else let ee2 = err_of(er2) { return err(ee2); }
        exts = caps2;
    }
    if len(cfg.username) > 0 {
        if !c.tls && cfg.security != "none" {
            return err("smtp: refusing to send a password without TLS");
        }
        if !has_auth(exts, "PLAIN") { return err("smtp: server does not offer AUTH PLAIN"); }
        // authzid NUL authcid NUL password (RFC 4616), built as bytes: a
        // str stops at its first NUL
        let cb = builder.new_bytes();
        cb.write_byte(0);
        cb.write_str(cfg.username);
        cb.write_byte(0);
        cb.write_str(cfg.password);
        let cred = encoding.base64_encode(cb.finish());
        let ar = command(c, "AUTH PLAIN " + cred, 235, deadline);
        guard let _a = ar else let ae = err_of(ar) { return err(redact(ae, cred)); }
    }
    let mr = command(c, "MAIL FROM:<" + from + ">", 250, deadline);
    guard let _m = mr else let me = err_of(mr) { return err(me); }
    for to in rcpts {
        let rr = command(c, "RCPT TO:<" + address_of(to) + ">", 250, deadline);
        guard let _r = rr else let re = err_of(rr) { return err(re); }
    }
    let dr = command(c, "DATA", 354, deadline);
    guard let _d = dr else let de = err_of(dr) { return err(de); }
    let wr = write(c, dot_stuff(data), deadline);
    guard let _w = wr else let we = err_of(wr) { return err(we); }
    let fr = expect(c, 250, deadline);
    guard let _f = fr else let fe = err_of(fr) { return err(fe); }
    let _q = command(c, "QUIT", 221, deadline);
    return ok(true);
}

fn ehlo(cfg: Config, c: Conn, deadline: until) -> result[[str], str] {
    let wr = write(c, to_bytes("EHLO " + cfg.helo + "\r\n"), deadline);
    guard let _w = wr else let we = err_of(wr) { return err(we); }
    return read_reply(c, 250, deadline);
}

fn has_ext(lines: [str], name: str) -> bool {
    for l in lines {
        let u = strings.to_upper(l);
        if u == name || strings.has_prefix(u, name + " ") { return true; }
    }
    return false;
}

fn has_auth(lines: [str], mech: str) -> bool {
    for l in lines {
        let u = strings.to_upper(l);
        if strings.has_prefix(u, "AUTH ") || strings.has_prefix(u, "AUTH=") {
            for w in strings.split(strings.slice(u, 5, len(u)), " ") {
                if w == mech { return true; }
            }
        }
    }
    return false;
}

fn command(c: Conn, line: str, want: int, deadline: until) -> result[[str], str] {
    let wr = write(c, to_bytes(line + "\r\n"), deadline);
    guard let _w = wr else let we = err_of(wr) { return err(we); }
    return read_reply(c, want, deadline);
}

fn expect(c: Conn, want: int, deadline: until) -> result[[str], str] {
    return read_reply(c, want, deadline);
}

// One reply, multi-line or not: its text lines (codes stripped) if the
// code is want, else an error carrying the server's words.
fn read_reply(c: Conn, want: int, deadline: until) -> result[[str], str] {
    let lines: [str] = [];
    while true {
        let lr = read_line(c, deadline);
        guard let line = lr else let le = err_of(lr) { return err(le); }
        if len(line) < 3 { return err("smtp: malformed reply: " + line); }
        let code = to_int(strings.slice(line, 0, 3)) ?? -1;
        let more = len(line) > 3 && strings.slice(line, 3, 4) == "-";
        let text = "";
        if len(line) > 4 { text = strings.slice(line, 4, len(line)); }
        push(lines, text);
        if !more {
            if code != want {
                return err("smtp: server replied " + line);
            }
            return ok(lines);
        }
        if len(lines) > 1000 { return err("smtp: reply too long"); }
    }
    return err("smtp: unreachable");
}

fn read_line(c: Conn, deadline: until) -> result[str, str] {
    while true {
        let i = strings.find(c.buf, "\r\n");
        if i >= 0 {
            let line = strings.slice(c.buf, 0, i);
            c.buf = strings.slice(c.buf, i + 2, len(c.buf));
            return ok(line);
        }
        if len(c.buf) > 65536 { return err("smtp: reply line too long"); }
        let rr = recv(c, deadline);
        guard let b = rr else let e = err_of(rr) { return err(e); }
        if len(b) == 0 { return err("smtp: connection closed"); }
        c.buf = c.buf + to_str(b);
    }
    return err("smtp: unreachable");
}

fn recv(c: Conn, deadline: until) -> result[bytes, str] {
    if c.tls {
        let r = net.tls_recv_until(c.ssl, 4096, deadline);
        guard let b = r else let e = err_of(r) { return err("smtp: " + e); }
        return ok(b);
    }
    let r = net.recv_until(c.fd, 4096, deadline);
    guard let b = r else let e = err_of(r) { return err("smtp: " + e); }
    return ok(b);
}

fn write(c: Conn, b: bytes, deadline: until) -> result[bool, str] {
    if c.tls {
        let r = net.tls_send_until(c.ssl, b, deadline);
        guard let _n = r else let e = err_of(r) { return err("smtp: " + e); }
        return ok(true);
    }
    let r = net.send_until(c.fd, b, deadline);
    guard let _n = r else let e = err_of(r) { return err("smtp: " + e); }
    return ok(true);
}

fn redact(msg: str, secret: str) -> str {
    return strings.replace(msg, secret, "[credentials]");
}

// Lines starting with "." get another, and the body ends with CRLF.CRLF.
fn dot_stuff(data: bytes) -> bytes {
    let s = to_str(data);
    let out = builder.new_bytes();
    let lines = strings.split(s, "\r\n");
    for i in 0..len(lines) {
        let l = lines[i];
        if i == len(lines) - 1 && len(l) == 0 { break; }
        if strings.has_prefix(l, ".") { out.write_str("."); }
        out.write_str(l);
        out.write_str("\r\n");
    }
    out.write_str(".\r\n");
    return out.finish();
}

// ---- MIME ------------------------------------------------------------------

fn body_part(out: builder.Bytes, m: Message, alt: bool, r: rand.Rng) {
    if alt {
        let b = "alt_" + token(r);
        out.write_str("Content-Type: multipart/alternative; boundary=\"" + b + "\"\r\n\r\n");
        out.write_str("--" + b + "\r\n");
        text_part(out, "text/plain", m.text);
        out.write_str("--" + b + "\r\n");
        text_part(out, "text/html", m.html);
        out.write_str("--" + b + "--\r\n");
        return;
    }
    if len(m.html) > 0 {
        text_part(out, "text/html", m.html);
        return;
    }
    text_part(out, "text/plain", m.text);
}

// A text part, base64 so any line length and any bytes survive transport.
fn text_part(out: builder.Bytes, ct: str, text: str) {
    out.write_str("Content-Type: " + ct + "; charset=utf-8\r\n");
    out.write_str("Content-Transfer-Encoding: base64\r\n\r\n");
    base64_lines(out, to_bytes(text));
}

// Base64 in 76-character lines (RFC 2045).
fn base64_lines(out: builder.Bytes, data: bytes) {
    let s = encoding.base64_encode(data);
    let at = 0;
    while at < len(s) {
        let end = at + 76;
        if end > len(s) { end = len(s); }
        out.write_str(strings.slice(s, at, end));
        out.write_str("\r\n");
        at = end;
    }
}

fn header(out: builder.Bytes, name: str, value: str) {
    // a CR or LF in a value would start a header of the caller's choosing
    let v = strings.replace(strings.replace(value, "\r", " "), "\n", " ");
    out.write_str(name + ": " + v + "\r\n");
}

fn is_ascii(s: str) -> bool {
    let b = to_bytes(s);
    for i in 0..len(b) {
        if (b[i] as int) >= 128 { return false; }
    }
    return true;
}

// RFC 2047 encoded-word for non-ASCII header text.
fn encode_word(s: str) -> str {
    if is_ascii(s) { return s; }
    return "=?UTF-8?B?" + encoding.base64_encode(to_bytes(s)) + "?=";
}

// "Name <addr>" with a non-ASCII name encoded; the address as is.
fn encode_address(a: str) -> str {
    let lt = strings.find(a, "<");
    if lt <= 0 { return a; }
    let name = strings.trim(strings.slice(a, 0, lt));
    if strings.has_prefix(name, "\"") && strings.has_suffix(name, "\"") && len(name) >= 2 {
        name = strings.slice(name, 1, len(name) - 1);
    }
    let rest = strings.slice(a, lt, len(a));
    if is_ascii(name) { return "\"" + quote_param(name) + "\" " + rest; }
    return encode_word(name) + " " + rest;
}

fn join_addresses(xs: [str]) -> str {
    let parts: [str] = [];
    for x in xs { push(parts, encode_address(x)); }
    return strings.join(parts, ", ");
}

// The bare address of "Name <addr>" or "addr".
pub fn address_of(a: str) -> str {
    let lt = strings.find(a, "<");
    let gt = strings.rfind(a, ">");
    if lt >= 0 && gt > lt { return strings.trim(strings.slice(a, lt + 1, gt)); }
    return strings.trim(a);
}

fn domain_of(addr: str) -> str {
    let at = strings.rfind(addr, "@");
    if at < 0 { return "localhost"; }
    return strings.slice(addr, at + 1, len(addr));
}

fn quote_param(s: str) -> str {
    return strings.replace(strings.replace(s, "\\", "\\\\"), "\"", "\\\"");
}

fn token(r: rand.Rng) -> str {
    let hex = "0123456789abcdef";
    let v = rand.next_u64(r);
    let parts: [str] = [];
    for i in 0..16 {
        let d = ((v >> (4 * i)) & (15 as u64)) as int;
        push(parts, strings.slice(hex, d, d + 1));
    }
    return strings.join(parts, "");
}
