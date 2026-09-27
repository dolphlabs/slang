import "redis";
import "net";
import "time";
import "strings";

// The client against scripted fake servers: every behaviour a real
// Redis would not volunteer -- a wrong password, a malformed reply,
// a connection dropped mid-message, a server that never answers.
// Runs anywhere, with no server. tests/live/redis covers a real one.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + 5000000000);
}

fn listen() -> i32 {
    let lr = net.listen(0);
    guard let lfd = lr else let e = err_of(lr) {
        die("listen: " + e);
        panic("unreachable");
    }
    return lfd;
}

fn port_of(lfd: i32) -> int {
    let pr = net.port(lfd);
    guard let p = pr else let e = err_of(pr) {
        die("port: " + e);
        panic("unreachable");
    }
    return p;
}

fn accept_one(lfd: i32) -> i32 {
    let ar = net.accept(lfd);
    guard let fd = ar else let e = err_of(ar) {
        die("accept: " + e);
        panic("unreachable");
    }
    return fd;
}

fn send_all(fd: i32, b: bytes) {
    let sr = net.send_until(fd, b, soon());
    guard let n = sr else let e = err_of(sr) {
        die("server send: " + e);
        panic("unreachable");
    }
}

// Read bytes until one RESP2 value decodes; returns its raw reply.
fn read_cmd(fd: i32) -> redis.Reply {
    let buf = b"";
    while true {
        let r = redis.decode(buf);
        guard let o = r else let e = err_of(r) {
            die("server decode: " + e);
            panic("unreachable");
        }
        guard let d = o else {
            let rr = net.recv_until(fd, 65536, soon());
            guard let b = rr else let e = err_of(rr) {
                die("server recv: " + e);
                panic("unreachable");
            }
            if len(b) == 0 {
                die("client went away");
                panic("unreachable");
            }
            buf = buf + b;
            continue;
        }
        return d.reply;
    }
}

fn cmd_name(r: redis.Reply) -> str {
    return to_str(r.items[0].bulk ?? b"");
}

fn cmd_arg(r: redis.Reply, i: int) -> bytes {
    return r.items[i].bulk ?? b"";
}

fn check_cmd(r: redis.Reply, want: str) {
    if cmd_name(r) != want {
        die("want command " + want + ", got " + cmd_name(r));
    }
}

fn url_for(port: int) -> str {
    return "redis://127.0.0.1:" + to_str(port);
}

fn dial(url: str) -> redis.Conn {
    let cr = redis.connect(url, soon());
    guard let c = cr else let e = err_of(cr) {
        die("connect: " + e);
        panic("unreachable");
    }
    return c;
}

fn run(c: redis.Conn, args: [bytes]) -> redis.Reply {
    let r = redis.do(c, args, soon());
    guard let reply = r else let e = err_of(r) {
        die("do: " + e);
        panic("unreachable");
    }
    return reply;
}

// ---- test 1: plain PING round trip -----------------------------------

fn srv_ping(lfd: i32) {
    let fd = accept_one(lfd);
    let cmd = read_cmd(fd);
    check_cmd(cmd, "PING");
    send_all(fd, b"+PONG\r\n");
    net.close(fd);
    net.close(lfd);
}

fn test_ping() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_ping_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let r = run(c, [to_bytes("PING")]);
    if r.kind != redis.REPLY_SIMPLE || r.text != "PONG" {
        die("bad PING reply");
    }
    if !redis.usable(c) {
        die("conn unusable after PING");
    }
    redis.close(c);
    if redis.usable(c) {
        die("conn usable after close");
    }
    println("ok ping");
}

fn srv_ping_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_ping(lfd);
}

// ---- test 2: AUTH + SELECT handshake ---------------------------------

fn srv_auth(lfd: i32) {
    let fd = accept_one(lfd);
    let a = read_cmd(fd);
    check_cmd(a, "AUTH");
    if to_str(cmd_arg(a, 1)) != "secret" {
        die("bad AUTH password");
    }
    send_all(fd, b"+OK\r\n");
    let s = read_cmd(fd);
    check_cmd(s, "SELECT");
    if to_str(cmd_arg(s, 1)) != "2" {
        die("bad SELECT db");
    }
    send_all(fd, b"+OK\r\n");
    let p = read_cmd(fd);
    check_cmd(p, "PING");
    send_all(fd, b"+PONG\r\n");
    net.close(fd);
    net.close(lfd);
}

fn srv_auth_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_auth(lfd);
}

fn test_auth_select() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_auth_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial("redis://:secret@127.0.0.1:" + to_str(port) + "/2");
    let r = run(c, [to_bytes("PING")]);
    if r.text != "PONG" {
        die("bad PING after handshake");
    }
    redis.close(c);
    println("ok auth");
}

// ---- test 3: wrong password fails the handshake ----------------------

fn srv_badauth(lfd: i32) {
    let fd = accept_one(lfd);
    let a = read_cmd(fd);
    check_cmd(a, "AUTH");
    send_all(fd, b"-WRONGPASS invalid username-password pair\r\n");
    net.close(fd);
    net.close(lfd);
}

fn srv_badauth_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_badauth(lfd);
}

fn test_auth_refused() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_badauth_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let cr = redis.connect("redis://:wrong@127.0.0.1:" + to_str(port),
                           soon());
    guard let c = cr else let e = err_of(cr) {
        if !strings.contains(e, "WRONGPASS") {
            die("wrong auth error: " + e);
        }
        println("ok auth-refused");
        return;
    }
    redis.close(c);
    die("connect with wrong password succeeded");
}

// ---- test 4: reply split into 1-byte writes --------------------------

fn srv_split(lfd: i32) {
    let fd = accept_one(lfd);
    let cmd = read_cmd(fd);
    check_cmd(cmd, "ECHO");
    let reply = b"$11\r\nhello world\r\n";
    let i = 0;
    while i < len(reply) {
        send_all(fd, reply[i..i + 1]);
        i = i + 1;
    }
    net.close(fd);
    net.close(lfd);
}

fn srv_split_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_split(lfd);
}

fn test_split_reply() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_split_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let r = run(c, [to_bytes("ECHO"), to_bytes("hello world")]);
    if r.kind != redis.REPLY_BULK {
        die("bad ECHO kind");
    }
    guard let b = r.bulk else {
        die("ECHO bulk missing");
        panic("unreachable");
    }
    if b != to_bytes("hello world") {
        die("ECHO value mangled");
    }
    redis.close(c);
    println("ok split");
}

// ---- test 5: binary values round trip --------------------------------

fn srv_binary(lfd: i32) {
    let fd = accept_one(lfd);
    let cmd = read_cmd(fd);
    check_cmd(cmd, "ECHO");
    let v = cmd_arg(cmd, 1);
    let hdr = to_bytes("$" + to_str(len(v)) + "\r\n");
    send_all(fd, hdr + v + b"\r\n");
    net.close(fd);
    net.close(lfd);
}

fn srv_binary_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_binary(lfd);
}

fn test_binary() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_binary_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let raw = b"\x00\xff\r\nnaked";
    let r = run(c, [to_bytes("ECHO"), raw]);
    guard let b = r.bulk else {
        die("binary bulk missing");
        panic("unreachable");
    }
    if b != raw {
        die("binary value mangled");
    }
    redis.close(c);
    println("ok binary");
}

// ---- test 6: corrupt bytes break the connection ----------------------

fn srv_garbage(lfd: i32) {
    let fd = accept_one(lfd);
    let cmd = read_cmd(fd);
    check_cmd(cmd, "PING");
    send_all(fd, b"%not-resp\r\n");
    net.close(fd);
    net.close(lfd);
}

fn srv_garbage_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_garbage(lfd);
}

fn test_corrupt() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_garbage_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let r = redis.do(c, [to_bytes("PING")], soon());
    guard let reply = r else let e = err_of(r) {
        if !strings.contains(e, "unknown reply type") {
            die("wrong corrupt error: " + e);
        }
        if redis.usable(c) {
            die("corrupt conn still usable");
        }
        let r2 = redis.do(c, [to_bytes("PING")], soon());
        guard let reply2 = r2 else let e2 = err_of(r2) {
            if !strings.contains(e2, "broken") {
                die("wrong second error: " + e2);
            }
            redis.close(c);
            println("ok corrupt");
            return;
        }
        die("do on broken conn succeeded");
        return;
    }
    redis.close(c);
    die("garbage reply decoded");
}

// ---- test 7: server drops mid-reply ----------------------------------

fn srv_drop(lfd: i32) {
    let fd = accept_one(lfd);
    let cmd = read_cmd(fd);
    check_cmd(cmd, "GET");
    send_all(fd, b"$10\r\nabc");
    net.close(fd);
    net.close(lfd);
}

fn srv_drop_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_drop(lfd);
}

fn test_drop() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_drop_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let r = redis.do(c, [to_bytes("GET"), to_bytes("k")], soon());
    guard let reply = r else let e = err_of(r) {
        if redis.usable(c) {
            die("dropped conn still usable");
        }
        redis.close(c);
        println("ok drop");
        return;
    }
    redis.close(c);
    die("truncated reply decoded");
}

// ---- test 8: silent server hits the deadline -------------------------

fn srv_silent(lfd: i32) {
    let fd = accept_one(lfd);
    let cmd = read_cmd(fd);
    check_cmd(cmd, "PING");
    time.sleep(2000000000);
    net.close(fd);
    net.close(lfd);
}

fn srv_silent_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_silent(lfd);
}

fn test_timeout() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_silent_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let dl = until_of(time.mono() + 300000000);
    let r = redis.do(c, [to_bytes("PING")], dl);
    guard let reply = r else let e = err_of(r) {
        if !strings.contains(e, "timeout") {
            die("wrong timeout error: " + e);
        }
        if redis.usable(c) {
            die("timed-out conn still usable");
        }
        redis.close(c);
        println("ok timeout");
        return;
    }
    redis.close(c);
    die("silent server answered");
}

// ---- test 9: server-side command errors do not break -----------------

fn srv_err(lfd: i32) {
    let fd = accept_one(lfd);
    let a = read_cmd(fd);
    check_cmd(a, "INCR");
    send_all(fd, b"-WRONGTYPE Operation against a key holding the wrong kind of value\r\n");
    let b = read_cmd(fd);
    check_cmd(b, "PING");
    send_all(fd, b"+PONG\r\n");
    net.close(fd);
    net.close(lfd);
}

fn srv_err_port(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    srv_err(lfd);
}

fn test_server_error() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_err_port(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let c = dial(url_for(port));
    let r = redis.do(c, [to_bytes("INCR"), to_bytes("k")], soon());
    guard let reply = r else let e = err_of(r) {
        if !strings.contains(e, "WRONGTYPE") {
            die("wrong server error: " + e);
        }
        let p = run(c, [to_bytes("PING")]);
        if p.text != "PONG" {
            die("conn desynced after error");
        }
        redis.close(c);
        println("ok server-error");
        return;
    }
    redis.close(c);
    die("WRONGTYPE accepted");
}

test_ping();
test_auth_select();
test_auth_refused();
test_split_reply();
test_binary();
test_corrupt();
test_drop();
test_timeout();
test_server_error();
