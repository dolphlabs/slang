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

// ---- scripted command coverage (phase 3) ------------------------------

gc struct Step {
    want: str,
    reply: bytes,
}

fn srv_script(lfd: i32, pc: chan[int], steps: [Step]) {
    chan_send(pc, port_of(lfd));
    let fd = accept_one(lfd);
    for st in steps {
        let cmd = read_cmd(fd);
        if cmd_name(cmd) != st.want {
            die("want " + st.want + ", got " + cmd_name(cmd));
        }
        send_all(fd, st.reply);
    }
    net.close(fd);
    net.close(lfd);
}

fn scripted(steps: [Step]) -> redis.Conn {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_script(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    return dial(url_for(port));
}

fn ri(r: result[int, str], want: int, what: str) {
    guard let v = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    if v != want {
        die(what + ": want " + to_str(want) + ", got " + to_str(v));
    }
}

fn rb(r: result[bool, str], want: bool, what: str) {
    guard let v = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    if v != want {
        die(what + ": wrong bool");
    }
}

fn rs(r: result[str, str], want: str, what: str) {
    guard let v = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    if v != want {
        die(what + ": want " + want + ", got " + v);
    }
}

fn rby(r: result[bytes, str], want: bytes, what: str) {
    guard let v = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    if v != want {
        die(what + ": wrong bytes");
    }
}

fn ropt_some(r: result[opt[bytes], str], want: bytes, what: str) {
    guard let o = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    guard let v = o else {
        die(what + ": got none");
        panic("unreachable");
    }
    if v != want {
        die(what + ": wrong bytes");
    }
}

fn ropt_none(r: result[opt[bytes], str], what: str) {
    guard let o = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    if !bytes_is_none(o) {
        die(what + ": got some");
    }
}

fn bytes_is_none(o: opt[bytes]) -> bool {
    guard let v = o else {
        return true;
    }
    return false;
}

fn int_is_none(o: opt[int]) -> bool {
    guard let v = o else {
        return true;
    }
    return false;
}

fn float_is_none(o: opt[float]) -> bool {
    guard let v = o else {
        return true;
    }
    return false;
}

fn test_strings() {
    let steps: [Step] = [
        Step { want: "PING", reply: b"+PONG\r\n" },
        Step { want: "SET", reply: b"+OK\r\n" },
        Step { want: "GET", reply: b"$5\r\nhello\r\n" },
        Step { want: "GET", reply: b"$-1\r\n" },
        Step { want: "SET", reply: b"+OK\r\n" },
        Step { want: "SETNX", reply: b":1\r\n" },
        Step { want: "DEL", reply: b":2\r\n" },
        Step { want: "EXISTS", reply: b":1\r\n" },
        Step { want: "EXPIRE", reply: b":1\r\n" },
        Step { want: "TTL", reply: b":100\r\n" },
        Step { want: "PERSIST", reply: b":1\r\n" },
        Step { want: "INCR", reply: b":11\r\n" },
        Step { want: "DECR", reply: b":10\r\n" },
        Step { want: "INCRBY", reply: b":15\r\n" },
        Step { want: "DECRBY", reply: b":13\r\n" },
        Step { want: "APPEND", reply: b":5\r\n" },
        Step { want: "STRLEN", reply: b":5\r\n" },
        Step { want: "MGET", reply: b"*2\r\n$1\r\na\r\n$-1\r\n" },
        Step { want: "MSET", reply: b"+OK\r\n" },
        Step { want: "ECHO", reply: b"$3\r\nhey\r\n" }
    ];
    let c = scripted(steps);
    rs(redis.ping(c, soon()), "PONG", "ping");
    rb(redis.set(c, "k", b"v", soon()), true, "set");
    ropt_some(redis.get(c, "k", soon()), b"hello", "get");
    ropt_none(redis.get(c, "missing", soon()), "get nil");
    rb(redis.set_ex(c, "k", 60, b"v", soon()), true, "set_ex");
    rb(redis.set_nx(c, "k", b"v", soon()), true, "set_nx");
    ri(redis.del_keys(c, ["a", "b"], soon()), 2, "del");
    ri(redis.exists(c, ["a"], soon()), 1, "exists");
    rb(redis.expire(c, "k", 60, soon()), true, "expire");
    ri(redis.ttl(c, "k", soon()), 100, "ttl");
    rb(redis.persist(c, "k", soon()), true, "persist");
    ri(redis.incr(c, "n", soon()), 11, "incr");
    ri(redis.decr(c, "n", soon()), 10, "decr");
    ri(redis.incr_by(c, "n", 5, soon()), 15, "incrby");
    ri(redis.decr_by(c, "n", 2, soon()), 13, "decrby");
    ri(redis.append(c, "k", b"x", soon()), 5, "append");
    ri(redis.strlen(c, "k", soon()), 5, "strlen");
    let mr = redis.mget(c, ["a", "b"], soon());
    guard let items = mr else let e = err_of(mr) {
        die("mget: " + e);
        panic("unreachable");
    }
    if len(items) != 2 {
        die("mget length");
    }
    guard let first = items[0] else {
        die("mget[0] none");
        panic("unreachable");
    }
    if first != b"a" {
        die("mget[0] value");
    }
    if !bytes_is_none(items[1]) {
        die("mget[1] some");
    }
    println("ok mget-nil");
    let kv: map[str]bytes = {"a": b"1"};
    rb(redis.mset(c, kv, soon()), true, "mset");
    rby(redis.echo(c, b"hey", soon()), b"hey", "echo");
    redis.close(c);
    println("ok strings");
}

fn test_hash_list() {
    let steps: [Step] = [
        Step { want: "HSET", reply: b":1\r\n" },
        Step { want: "HGET", reply: b"$3\r\nbar\r\n" },
        Step { want: "HGET", reply: b"$-1\r\n" },
        Step { want: "HGETALL",
               reply: b"*4\r\n$1\r\nf\r\n$3\r\nbar\r\n$1\r\ng\r\n$1\r\n2\r\n" },
        Step { want: "HDEL", reply: b":1\r\n" },
        Step { want: "HEXISTS", reply: b":1\r\n" },
        Step { want: "HKEYS", reply: b"*2\r\n$1\r\nf\r\n$1\r\ng\r\n" },
        Step { want: "HVALS", reply: b"*1\r\n$3\r\nbar\r\n" },
        Step { want: "HLEN", reply: b":2\r\n" },
        Step { want: "HINCRBY", reply: b":8\r\n" },
        Step { want: "LPUSH", reply: b":2\r\n" },
        Step { want: "LRANGE", reply: b"*2\r\n$1\r\nb\r\n$1\r\na\r\n" },
        Step { want: "LPOP", reply: b"$1\r\nb\r\n" },
        Step { want: "LPOP", reply: b"$-1\r\n" },
        Step { want: "LLEN", reply: b":1\r\n" },
        Step { want: "LTRIM", reply: b"+OK\r\n" },
        Step { want: "LINDEX", reply: b"$1\r\na\r\n" },
        Step { want: "LREM", reply: b":1\r\n" },
        Step { want: "RPUSH", reply: b":2\r\n" },
        Step { want: "RPOP", reply: b"$1\r\nz\r\n" }
    ];
    let c = scripted(steps);
    ri(redis.hset(c, "h", "f", b"bar", soon()), 1, "hset");
    ropt_some(redis.hget(c, "h", "f", soon()), b"bar", "hget");
    ropt_none(redis.hget(c, "h", "no", soon()), "hget nil");
    let hr = redis.hgetall(c, "h", soon());
    guard let h = hr else let e = err_of(hr) {
        die("hgetall: " + e);
        panic("unreachable");
    }
    if len(h) != 2 || !has(h, "f") {
        die("hgetall shape");
    }
    ri(redis.hdel(c, "h", ["g"], soon()), 1, "hdel");
    rb(redis.hexists(c, "h", "f", soon()), true, "hexists");
    let kr = redis.hkeys(c, "h", soon());
    guard let ks = kr else let e = err_of(kr) {
        die("hkeys: " + e);
        panic("unreachable");
    }
    if len(ks) != 2 {
        die("hkeys length");
    }
    let vr = redis.hvals(c, "h", soon());
    guard let vs = vr else let e = err_of(vr) {
        die("hvals: " + e);
        panic("unreachable");
    }
    if len(vs) != 1 || vs[0] != b"bar" {
        die("hvals shape");
    }
    ri(redis.hlen(c, "h", soon()), 2, "hlen");
    ri(redis.hincr_by(c, "h", "n", 8, soon()), 8, "hincrby");
    ri(redis.lpush(c, "l", [b"a", b"b"], soon()), 2, "lpush");
    let lr = redis.lrange(c, "l", 0, 0 - 1, soon());
    guard let ls = lr else let e = err_of(lr) {
        die("lrange: " + e);
        panic("unreachable");
    }
    if len(ls) != 2 || ls[0] != b"b" {
        die("lrange shape");
    }
    ropt_some(redis.lpop(c, "l", soon()), b"b", "lpop");
    ropt_none(redis.lpop(c, "l", soon()), "lpop nil");
    ri(redis.llen(c, "l", soon()), 1, "llen");
    rb(redis.ltrim(c, "l", 0, 0, soon()), true, "ltrim");
    ropt_some(redis.lindex(c, "l", 0, soon()), b"a", "lindex");
    ri(redis.lrem(c, "l", 0, b"a", soon()), 1, "lrem");
    ri(redis.rpush(c, "l", [b"z"], soon()), 2, "rpush");
    ropt_some(redis.rpop(c, "l", soon()), b"z", "rpop");
    redis.close(c);
    println("ok hash-list");
}

fn test_set_zset() {
    let steps: [Step] = [
        Step { want: "SADD", reply: b":2\r\n" },
        Step { want: "SMEMBERS", reply: b"*2\r\n$1\r\na\r\n$1\r\nb\r\n" },
        Step { want: "SREM", reply: b":1\r\n" },
        Step { want: "SCARD", reply: b":1\r\n" },
        Step { want: "SISMEMBER", reply: b":1\r\n" },
        Step { want: "SPOP", reply: b"$1\r\na\r\n" },
        Step { want: "ZADD", reply: b":2\r\n" },
        Step { want: "ZRANGE", reply: b"*2\r\n$1\r\na\r\n$1\r\nb\r\n" },
        Step { want: "ZRANGE",
               reply: b"*4\r\n$1\r\na\r\n$3\r\n1.5\r\n$1\r\nb\r\n$3\r\n2.5\r\n" },
        Step { want: "ZRANK", reply: b":0\r\n" },
        Step { want: "ZRANK", reply: b"$-1\r\n" },
        Step { want: "ZSCORE", reply: b"$3\r\n1.5\r\n" },
        Step { want: "ZSCORE", reply: b"$-1\r\n" },
        Step { want: "ZREM", reply: b":1\r\n" },
        Step { want: "ZCARD", reply: b":1\r\n" },
        Step { want: "ZINCRBY", reply: b"$3\r\n3.5\r\n" },
        Step { want: "TYPE", reply: b"+zset\r\n" },
        Step { want: "RENAME", reply: b"+OK\r\n" },
        Step { want: "RENAMENX", reply: b":1\r\n" },
        Step { want: "SCAN", reply: b"*2\r\n$1\r\n0\r\n*2\r\n$1\r\na\r\n$1\r\nb\r\n" },
        Step { want: "PEXPIRE", reply: b":1\r\n" },
        Step { want: "PTTL", reply: b":999\r\n" }
    ];
    let c = scripted(steps);
    ri(redis.sadd(c, "s", [b"a", b"b"], soon()), 2, "sadd");
    let mr = redis.smembers(c, "s", soon());
    guard let ms = mr else let e = err_of(mr) {
        die("smembers: " + e);
        panic("unreachable");
    }
    if len(ms) != 2 {
        die("smembers length");
    }
    ri(redis.srem(c, "s", [b"a"], soon()), 1, "srem");
    ri(redis.scard(c, "s", soon()), 1, "scard");
    rb(redis.sismember(c, "s", b"b", soon()), true, "sismember");
    ropt_some(redis.spop(c, "s", soon()), b"a", "spop");
    let zm: map[str]float = {"a": 1.5, "b": 2.5};
    ri(redis.zadd(c, "z", zm, soon()), 2, "zadd");
    let zr = redis.zrange(c, "z", 0, 0 - 1, soon());
    guard let zs = zr else let e = err_of(zr) {
        die("zrange: " + e);
        panic("unreachable");
    }
    if len(zs) != 2 || zs[1] != b"b" {
        die("zrange shape");
    }
    let zw = redis.zrange_scores(c, "z", 0, 0 - 1, soon());
    guard let zms = zw else let e = err_of(zw) {
        die("zrange_scores: " + e);
        panic("unreachable");
    }
    if len(zms) != 2 || zms[0].score != 1.5 || zms[0].member != b"a" {
        die("zrange_scores shape");
    }
    let rkr = redis.zrank(c, "z", b"a", soon());
    guard let rko = rkr else let e = err_of(rkr) {
        die("zrank: " + e);
        panic("unreachable");
    }
    guard let rk = rko else {
        die("zrank none");
        panic("unreachable");
    }
    if rk != 0 {
        die("zrank value");
    }
    let rkr2 = redis.zrank(c, "z", b"no", soon());
    guard let rko2 = rkr2 else let e = err_of(rkr2) {
        die("zrank nil: " + e);
        panic("unreachable");
    }
    if !int_is_none(rko2) {
        die("zrank some");
    }
    println("ok zrank-nil");
    let zsr = redis.zscore(c, "z", b"a", soon());
    guard let zso = zsr else let e = err_of(zsr) {
        die("zscore: " + e);
        panic("unreachable");
    }
    guard let zsv = zso else {
        die("zscore none");
        panic("unreachable");
    }
    if zsv != 1.5 {
        die("zscore value");
    }
    let zsr2 = redis.zscore(c, "z", b"no", soon());
    guard let zso2 = zsr2 else let e = err_of(zsr2) {
        die("zscore nil: " + e);
        panic("unreachable");
    }
    if !float_is_none(zso2) {
        die("zscore some");
    }
    println("ok zscore-nil");
    ri(redis.zrem(c, "z", [b"a"], soon()), 1, "zrem");
    ri(redis.zcard(c, "z", soon()), 1, "zcard");
    let zir = redis.zincr_by(c, "z", 1.0, b"b", soon());
    guard let ziv = zir else let e = err_of(zir) {
        die("zincrby: " + e);
        panic("unreachable");
    }
    if ziv != 3.5 {
        die("zincrby value");
    }
    rs(redis.key_type(c, "z", soon()), "zset", "type");
    rb(redis.rename(c, "a", "b", soon()), true, "rename");
    rb(redis.rename_nx(c, "a", "b", soon()), true, "renamenx");
    let scr = redis.scan(c, 0, none, none, soon());
    guard let sout = scr else let e = err_of(scr) {
        die("scan: " + e);
        panic("unreachable");
    }
    if sout.cursor != 0 || len(sout.keys) != 2 {
        die("scan shape");
    }
    rb(redis.pexpire(c, "k", 999, soon()), true, "pexpire");
    ri(redis.pttl(c, "k", soon()), 999, "pttl");
    redis.close(c);
    println("ok set-zset");
}

test_strings();
test_hash_list();
test_set_zset();
