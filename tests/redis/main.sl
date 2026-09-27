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

fn srv_send(fd: i32, b: bytes) {
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
    srv_send(fd, b"+PONG\r\n");
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
    srv_send(fd, b"+OK\r\n");
    let s = read_cmd(fd);
    check_cmd(s, "SELECT");
    if to_str(cmd_arg(s, 1)) != "2" {
        die("bad SELECT db");
    }
    srv_send(fd, b"+OK\r\n");
    let p = read_cmd(fd);
    check_cmd(p, "PING");
    srv_send(fd, b"+PONG\r\n");
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
    srv_send(fd, b"-WRONGPASS invalid username-password pair\r\n");
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
        srv_send(fd, reply[i..i + 1]);
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
    srv_send(fd, hdr + v + b"\r\n");
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
    srv_send(fd, b"%not-resp\r\n");
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
    srv_send(fd, b"$10\r\nabc");
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
    srv_send(fd, b"-WRONGTYPE Operation against a key holding the wrong kind of value\r\n");
    let b = read_cmd(fd);
    check_cmd(b, "PING");
    srv_send(fd, b"+PONG\r\n");
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
        srv_send(fd, st.reply);
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

// ---- pool (phase 4) --------------------------------------------------------

fn test_pool_reuse() {
    let steps: [Step] = [
        Step { want: "PING", reply: b"+PONG\r\n" },
        Step { want: "PING", reply: b"+PONG\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_script(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let pr = redis.new_pool(url_for(port), 2);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        panic("unreachable");
    }
    let a = redis.acquire(p, soon());
    guard let c1 = a else let e = err_of(a) {
        die("acquire: " + e);
        panic("unreachable");
    }
    let r = redis.do(c1, [to_bytes("PING")], soon());
    guard let reply = r else let e = err_of(r) {
        die("ping: " + e);
        panic("unreachable");
    }
    redis.release(p, c1);
    let b = redis.acquire(p, soon());
    guard let c2 = b else let e = err_of(b) {
        die("reacquire: " + e);
        panic("unreachable");
    }
    let r2 = redis.do(c2, [to_bytes("PING")], soon());
    guard let reply2 = r2 else let e = err_of(r2) {
        die("ping2: " + e);
        panic("unreachable");
    }
    redis.release(p, c2);
    redis.pool_close(p);
    println("ok pool-reuse");
}

fn test_pool_exhaust() {
    let steps: [Step] = [
        Step { want: "PING", reply: b"+PONG\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_script(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let pr = redis.new_pool(url_for(port), 1);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        panic("unreachable");
    }
    let a = redis.acquire(p, soon());
    guard let c1 = a else let e = err_of(a) {
        die("acquire: " + e);
        panic("unreachable");
    }
    let dl = until_of(time.mono() + 300000000);
    let b = redis.acquire(p, dl);
    guard let c2 = b else let e = err_of(b) {
        if !strings.contains(e, "timeout") {
            die("wrong exhaust error: " + e);
        }
        redis.release(p, c1);
        let c = redis.acquire(p, soon());
        guard let c3 = c else let e = err_of(c) {
            die("reacquire: " + e);
            panic("unreachable");
        }
        let r = redis.do(c3, [to_bytes("PING")], soon());
        guard let reply = r else let e = err_of(r) {
            die("ping: " + e);
            panic("unreachable");
        }
        redis.release(p, c3);
        redis.pool_close(p);
        println("ok pool-exhaust");
        return;
    }
    redis.release(p, c1);
    redis.release(p, c2);
    redis.pool_close(p);
    die("second acquire on size-1 pool succeeded");
}

fn srv_redial(lfd: i32, pc: chan[int]) {
    chan_send(pc, port_of(lfd));
    let fd1 = accept_one(lfd);
    let a = read_cmd(fd1);
    check_cmd(a, "PING");
    srv_send(fd1, b"%garbage\r\n");
    net.close(fd1);
    let fd2 = accept_one(lfd);
    let b = read_cmd(fd2);
    check_cmd(b, "PING");
    srv_send(fd2, b"+PONG\r\n");
    net.close(fd2);
    net.close(lfd);
}

fn test_pool_discard() {
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn srv_redial(lfd, pc);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let pr = redis.new_pool(url_for(port), 2);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        panic("unreachable");
    }
    let a = redis.acquire(p, soon());
    guard let c1 = a else let e = err_of(a) {
        die("acquire: " + e);
        panic("unreachable");
    }
    let r = redis.do(c1, [to_bytes("PING")], soon());
    guard let reply = r else {
        redis.release(p, c1);
        let b = redis.acquire(p, soon());
        guard let c2 = b else let e = err_of(b) {
            die("reacquire: " + e);
            panic("unreachable");
        }
        let r2 = redis.do(c2, [to_bytes("PING")], soon());
        guard let reply2 = r2 else let e = err_of(r2) {
            die("ping after redial: " + e);
            panic("unreachable");
        }
        if reply2.text != "PONG" {
            die("bad PONG after redial");
        }
        redis.release(p, c2);
        redis.pool_close(p);
        println("ok pool-discard");
        return;
    }
    redis.release(p, c1);
    redis.pool_close(p);
    die("garbage reply decoded");
}

fn test_pool_close() {
    let pr = redis.new_pool("redis://127.0.0.1:1", 1);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        panic("unreachable");
    }
    redis.pool_close(p);
    let a = redis.acquire(p, soon());
    guard let c2 = a else let e = err_of(a) {
        if !strings.contains(e, "closed") {
            die("wrong closed error: " + e);
        }
        println("ok pool-close");
        return;
    }
    redis.release(p, c2);
    die("acquire on closed pool succeeded");
}

test_pool_reuse();
test_pool_exhaust();
test_pool_discard();
test_pool_close();

// ---- cluster (phase 5) -------------------------------------------------
// Two scripted nodes: A owns slots 0..8191, B owns 8192..16383.
// "hello" hashes to 866 (A), "foo" to 12182 (B), "axh" to 5 (A).

fn slots_reply(port_a: int, port_b: int) -> bytes {
    let id = b"0123456789abcdef0123456789abcdef01234567";
    return b"*2\r\n*3\r\n:0\r\n:8191\r\n*3\r\n$9\r\n127.0.0.1\r\n:" +
           to_bytes(to_str(port_a)) + b"\r\n$40\r\n" + id + b"\r\n" +
           b"*3\r\n:8192\r\n:16383\r\n*3\r\n$9\r\n127.0.0.1\r\n:" +
           to_bytes(to_str(port_b)) + b"\r\n$40\r\n" + id + b"\r\n";
}

fn cluster_script(lfd: i32, pc: chan[int], scripts: [[Step]]) {
    chan_send(pc, port_of(lfd));
    for script in scripts {
        let fd = accept_one(lfd);
        for st in script {
            let cmd = read_cmd(fd);
            if cmd_name(cmd) != st.want {
                die("want " + st.want + ", got " + cmd_name(cmd));
            }
            srv_send(fd, st.reply);
        }
        net.close(fd);
    }
    net.close(lfd);
}

fn cluster_cfg() -> redis.Config {
    return redis.Config { host: "127.0.0.1", port: 1, username: "",
                          password: "", db: 0, sslmode: "disable",
                          ca_path: "", tls_ctx: nullptr, pool_size: 2,
                          connect_timeout: 5000000000,
                          io_timeout: 5000000000 };
}

fn open_addrs() -> [int] {
    let la = listen();
    let lb = listen();
    let pa = port_of(la);
    let pb = port_of(lb);
    net.close(la);
    net.close(lb);
    return [pa, pb];
}

fn test_cluster_route() {
    let la = listen();
    let lb = listen();
    let pa = port_of(la);
    let pb = port_of(lb);
    let conn_a1: [Step] = [
        Step { want: "CLUSTER", reply: slots_reply(pa, pb) }
    ];
    let conn_a2: [Step] = [
        Step { want: "GET", reply: b"$2\r\nhi\r\n" },
        Step { want: "SET", reply: b"+OK\r\n" }
    ];
    let conn_b1: [Step] = [
        Step { want: "GET", reply: b"$5\r\nthere\r\n" }
    ];
    let scripts_a: [[Step]] = [conn_a1, conn_a2];
    let scripts_b: [[Step]] = [conn_b1];
    let pca: chan[int] = make_chan(1);
    let pcb: chan[int] = make_chan(1);
    spawn cluster_script(la, pca, scripts_a);
    spawn cluster_script(lb, pcb, scripts_b);
    guard let xa = chan_recv(pca) else {
        die("no port a");
        panic("unreachable");
    }
    guard let xb = chan_recv(pcb) else {
        die("no port b");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    let ha = redis.cget(cl, "hello", soon());
    guard let va = ha else let e = err_of(ha) {
        die("cget hello: " + e);
        panic("unreachable");
    }
    guard let ba = va else {
        die("hello nil");
        panic("unreachable");
    }
    if ba != b"hi" {
        die("hello value");
    }
    let hb = redis.cget(cl, "foo", soon());
    guard let vb = hb else let e = err_of(hb) {
        die("cget foo: " + e);
        panic("unreachable");
    }
    guard let bb = vb else {
        die("foo nil");
        panic("unreachable");
    }
    if bb != b"there" {
        die("foo value");
    }
    let sr = redis.cset(cl, "hello", b"w", soon());
    guard let okv = sr else let e = err_of(sr) {
        die("cset: " + e);
        panic("unreachable");
    }
    redis.cluster_close(cl);
    println("ok cluster-route");
}

fn test_cluster_moved() {
    let la = listen();
    let lb = listen();
    let pa = port_of(la);
    let pb = port_of(lb);
    // A claims foo's slot (12182) then MOVEDs it to B, the
    // migration-finished shape: the client asks the known owner,
    // follows the MOVED, and reuses the updated slot after.
    let id40 = b"$40\r\n0123456789abcdef0123456789abcdef01234567\r\n";
    let node_a = b"*3\r\n$9\r\n127.0.0.1\r\n:" + to_bytes(to_str(pa)) +
                 b"\r\n" + id40;
    let half = b"*2\r\n*3\r\n:0\r\n:8191\r\n" + node_a +
               b"*3\r\n:12182\r\n:12182\r\n" + node_a;
    let moved_to_b = b"-MOVED 12182 127.0.0.1:" + to_bytes(to_str(pb)) +
                     b"\r\n";
    let conn_a1: [Step] = [
        Step { want: "CLUSTER", reply: half }
    ];
    let conn_a2: [Step] = [
        Step { want: "GET", reply: moved_to_b }
    ];
    let conn_b1: [Step] = [
        Step { want: "GET", reply: b"$5\r\nthere\r\n" },
        Step { want: "GET", reply: b"$5\r\nthere\r\n" }
    ];
    let scripts_a: [[Step]] = [conn_a1, conn_a2];
    let scripts_b: [[Step]] = [conn_b1];
    let pca: chan[int] = make_chan(1);
    let pcb: chan[int] = make_chan(1);
    spawn cluster_script(la, pca, scripts_a);
    spawn cluster_script(lb, pcb, scripts_b);
    guard let xa = chan_recv(pca) else {
        die("no port a");
        panic("unreachable");
    }
    guard let xb = chan_recv(pcb) else {
        die("no port b");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    // First GET follows the MOVED to B; the second must reuse the
    // updated slot (same B connection, no new dial).
    let h1 = redis.cget(cl, "foo", soon());
    guard let v1 = h1 else let e = err_of(h1) {
        die("moved get 1: " + e);
        panic("unreachable");
    }
    guard let b1 = v1 else {
        die("moved get 1 nil");
        panic("unreachable");
    }
    if b1 != b"there" {
        die("moved value 1");
    }
    let h2 = redis.cget(cl, "foo", soon());
    guard let v2 = h2 else let e = err_of(h2) {
        die("moved get 2: " + e);
        panic("unreachable");
    }
    guard let b2 = v2 else {
        die("moved get 2 nil");
        panic("unreachable");
    }
    if b2 != b"there" {
        die("moved value 2");
    }
    redis.cluster_close(cl);
    println("ok cluster-moved");
}

fn test_cluster_ask() {
    let la = listen();
    let lb = listen();
    let pa = port_of(la);
    let pb = port_of(lb);
    let ask_to_b = b"-ASK 5 127.0.0.1:" + to_bytes(to_str(pb)) + b"\r\n";
    let conn_a1: [Step] = [
        Step { want: "CLUSTER", reply: slots_reply(pa, pb) }
    ];
    let conn_a2: [Step] = [
        Step { want: "GET", reply: ask_to_b }
    ];
    let conn_b1: [Step] = [
        Step { want: "ASKING", reply: b"+OK\r\n" },
        Step { want: "GET", reply: b"$1\r\nv\r\n" }
    ];
    let scripts_a: [[Step]] = [conn_a1, conn_a2];
    let scripts_b: [[Step]] = [conn_b1];
    let pca: chan[int] = make_chan(1);
    let pcb: chan[int] = make_chan(1);
    spawn cluster_script(la, pca, scripts_a);
    spawn cluster_script(lb, pcb, scripts_b);
    guard let xa = chan_recv(pca) else {
        die("no port a");
        panic("unreachable");
    }
    guard let xb = chan_recv(pcb) else {
        die("no port b");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    let h = redis.cget(cl, "axh", soon());
    guard let v = h else let e = err_of(h) {
        die("ask get: " + e);
        panic("unreachable");
    }
    guard let b = v else {
        die("ask nil");
        panic("unreachable");
    }
    if b != b"v" {
        die("ask value");
    }
    redis.cluster_close(cl);
    println("ok cluster-ask");
}

fn test_cluster_crossslot() {
    let la = listen();
    let pa = port_of(la);
    let conn_a1: [Step] = [
        Step { want: "CLUSTER", reply: slots_reply(pa, pa + 1) }
    ];
    let scripts_a: [[Step]] = [conn_a1];
    let pca: chan[int] = make_chan(1);
    spawn cluster_script(la, pca, scripts_a);
    guard let xa = chan_recv(pca) else {
        die("no port a");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    // hello (866) and foo (12182) hash apart: refused with no traffic.
    let mr = redis.cmget(cl, ["hello", "foo"], soon());
    guard let vs = mr else let e = err_of(mr) {
        if !strings.contains(e, "CROSSSLOT") {
            die("wrong crossslot error: " + e);
        }
        redis.cluster_close(cl);
        println("ok cluster-crossslot");
        return;
    }
    redis.cluster_close(cl);
    die("crossslot mget served");
}

fn test_cluster_seeds_down() {
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:1"], soon());
    guard let cl = cr else {
        println("ok cluster-seeds-down");
        return;
    }
    redis.cluster_close(cl);
    die("cluster on dead seeds connected");
}

fn test_cluster_wrappers() {
    let la = listen();
    let lb = listen();
    let pa = port_of(la);
    let pb = port_of(lb);
    let conn_a1: [Step] = [
        Step { want: "CLUSTER", reply: slots_reply(pa, pb) }
    ];
    let conn_a2: [Step] = [
        Step { want: "PING", reply: b"+PONG\r\n" },
        Step { want: "SET", reply: b"+OK\r\n" },
        Step { want: "INCR", reply: b":2\r\n" },
        Step { want: "HSET", reply: b":1\r\n" },
        Step { want: "DEL", reply: b":1\r\n" },
        Step { want: "SCAN",
               reply: b"*2\r\n$1\r\n0\r\n*1\r\n$1\r\nk\r\n" }
    ];
    let conn_b1: [Step] = [
        Step { want: "ZSCORE", reply: b"$3\r\n1.5\r\n" }
    ];
    let scripts_a: [[Step]] = [conn_a1, conn_a2];
    let scripts_b: [[Step]] = [conn_b1];
    let pca: chan[int] = make_chan(1);
    let pcb: chan[int] = make_chan(1);
    spawn cluster_script(la, pca, scripts_a);
    spawn cluster_script(lb, pcb, scripts_b);
    guard let xa = chan_recv(pca) else {
        die("no port a");
        panic("unreachable");
    }
    guard let xb = chan_recv(pcb) else {
        die("no port b");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    // hello -> 866 (A), foo -> 12182 (B).
    let pr = redis.cping(cl, soon());
    guard let pong = pr else let e = err_of(pr) {
        die("cping: " + e);
        panic("unreachable");
    }
    if pong != "PONG" {
        die("cping value");
    }
    let sr = redis.cset(cl, "hello", b"w", soon());
    guard let sok = sr else let e = err_of(sr) {
        die("cset: " + e);
        panic("unreachable");
    }
    let ir = redis.cincr(cl, "hello", soon());
    guard let iv = ir else let e = err_of(ir) {
        die("cincr: " + e);
        panic("unreachable");
    }
    if iv != 2 {
        die("cincr value");
    }
    let hr = redis.chset(cl, "hello", "f", b"v", soon());
    guard let hv = hr else let e = err_of(hr) {
        die("chset: " + e);
        panic("unreachable");
    }
    if hv != 1 {
        die("chset value");
    }
    let dr = redis.cdel_keys(cl, ["hello"], soon());
    guard let dv = dr else let e = err_of(dr) {
        die("cdel: " + e);
        panic("unreachable");
    }
    let zr = redis.czscore(cl, "foo", b"m", soon());
    guard let zo = zr else let e = err_of(zr) {
        die("czscore: " + e);
        panic("unreachable");
    }
    guard let zv = zo else {
        die("czscore nil");
        panic("unreachable");
    }
    if zv != 1.5 {
        die("czscore value");
    }
    let scr = redis.cscan(cl, 0, none, none, soon());
    guard let sout = scr else let e = err_of(scr) {
        die("cscan: " + e);
        panic("unreachable");
    }
    if len(sout.keys) != 1 {
        die("cscan shape");
    }
    redis.cluster_close(cl);
    println("ok cluster-wrappers");
}

test_cluster_route();
test_cluster_moved();
test_cluster_ask();
test_cluster_crossslot();
test_cluster_seeds_down();
test_cluster_wrappers();

// ---- transactions + scripting (phase 6) --------------------------------

fn test_multi_exec() {
    let steps: [Step] = [
        Step { want: "MULTI", reply: b"+OK\r\n" },
        Step { want: "INCR", reply: b"+QUEUED\r\n" },
        Step { want: "INCR", reply: b"+QUEUED\r\n" },
        Step { want: "EXEC", reply: b"*2\r\n:11\r\n:12\r\n" }
    ];
    let c = scripted(steps);
    let m = redis.multi(c, soon());
    guard let mok = m else let e = err_of(m) {
        die("multi: " + e);
        panic("unreachable");
    }
    let q1 = redis.queue(c, [to_bytes("INCR"), to_bytes("n")], soon());
    guard let qok1 = q1 else let e = err_of(q1) {
        die("queue1: " + e);
        panic("unreachable");
    }
    let q2 = redis.queue(c, [to_bytes("INCR"), to_bytes("n")], soon());
    guard let qok2 = q2 else let e = err_of(q2) {
        die("queue2: " + e);
        panic("unreachable");
    }
    let er = redis.exec(c, soon());
    guard let out = er else let e = err_of(er) {
        die("exec: " + e);
        panic("unreachable");
    }
    if len(out) != 2 || out[0].num != 11 || out[1].num != 12 {
        die("exec results");
    }
    // back outside: plain commands work again
    redis.close(c);
    println("ok multi-exec");
}

fn test_multi_refusals() {
    let steps: [Step] = [
        Step { want: "MULTI", reply: b"+OK\r\n" },
        Step { want: "PING", reply: b"+QUEUED\r\n" },
        Step { want: "DISCARD", reply: b"+OK\r\n" },
        Step { want: "PING", reply: b"+PONG\r\n" }
    ];
    let c = scripted(steps);
    let m = redis.multi(c, soon());
    guard let mok = m else let e = err_of(m) {
        die("multi: " + e);
        panic("unreachable");
    }
    // do() refuses inside MULTI with zero traffic
    let d = redis.do(c, [to_bytes("PING")], soon());
    guard let dr = d else let e = err_of(d) {
        if !strings.contains(e, "MULTI") {
            die("wrong do-in-multi error: " + e);
        }
        // queue works here; discard; plain commands work again
        let q = redis.queue(c, [to_bytes("PING")], soon());
        guard let qo = q else let e = err_of(q) {
            die("queue in multi: " + e);
            panic("unreachable");
        }
        let dc = redis.discard(c, soon());
        guard let dok = dc else let e = err_of(dc) {
            die("discard: " + e);
            panic("unreachable");
        }
        let p = redis.ping(c, soon());
        guard let pong = p else let e = err_of(p) {
            die("ping after discard: " + e);
            panic("unreachable");
        }
        if pong != "PONG" {
            die("bad PONG after discard");
        }
        redis.close(c);
        println("ok multi-refusals");
        return;
    }
    die("do inside MULTI served");
}

fn test_multi_refusals2() {
    let steps: [Step] = [];
    let c = scripted(steps);
    // queue/exec with no MULTI: local refusals, zero traffic
    let q = redis.queue(c, [to_bytes("PING")], soon());
    guard let qo = q else let e = err_of(q) {
        if !strings.contains(e, "MULTI") {
            die("wrong queue error: " + e);
        }
        let er = redis.exec(c, soon());
        guard let eo = er else let e = err_of(er) {
            if !strings.contains(e, "MULTI") {
                die("wrong exec error: " + e);
            }
            redis.close(c);
            println("ok multi-outside");
            return;
        }
        die("exec without multi served");
        return;
    }
    die("queue without multi served");
}

fn test_watch_abort() {
    let steps: [Step] = [
        Step { want: "WATCH", reply: b"+OK\r\n" },
        Step { want: "MULTI", reply: b"+OK\r\n" },
        Step { want: "INCR", reply: b"+QUEUED\r\n" },
        Step { want: "EXEC", reply: b"*-1\r\n" },
        Step { want: "UNWATCH", reply: b"+OK\r\n" }
    ];
    let c = scripted(steps);
    let w = redis.watch(c, ["k"], soon());
    guard let wok = w else let e = err_of(w) {
        die("watch: " + e);
        panic("unreachable");
    }
    let m = redis.multi(c, soon());
    guard let mok = m else let e = err_of(m) {
        die("multi: " + e);
        panic("unreachable");
    }
    let q = redis.queue(c, [to_bytes("INCR"), to_bytes("k")], soon());
    guard let qok = q else let e = err_of(q) {
        die("queue: " + e);
        panic("unreachable");
    }
    let er = redis.exec(c, soon());
    guard let out = er else let e = err_of(er) {
        let u = redis.unwatch(c, soon());
        guard let uok = u else let e = err_of(u) {
            die("unwatch: " + e);
            panic("unreachable");
        }
        redis.close(c);
        println("ok watch-abort");
        return;
    }
    die("aborted exec returned results");
}

fn test_evalsha_fallback() {
    let steps: [Step] = [
        Step { want: "EVALSHA",
               reply: b"-NOSCRIPT No matching script\r\n" },
        Step { want: "EVAL", reply: b"$2\r\nhi\r\n" },
        Step { want: "EVALSHA", reply: b":3\r\n" }
    ];
    let c = scripted(steps);
    let r = redis.evalsha(c, "return 'hi'", ["k"], [b"a"], soon());
    guard let reply = r else let e = err_of(r) {
        die("evalsha: " + e);
        panic("unreachable");
    }
    if reply.kind != redis.REPLY_BULK {
        die("evalsha shape");
    }
    let r2 = redis.evalsha(c, "return 3", [], [], soon());
    guard let reply2 = r2 else let e = err_of(r2) {
        die("evalsha hit: " + e);
        panic("unreachable");
    }
    if reply2.kind != redis.REPLY_INT || reply2.num != 3 {
        die("evalsha hit shape");
    }
    redis.close(c);
    println("ok evalsha");
}

test_multi_exec();
test_multi_refusals();
test_multi_refusals2();
test_watch_abort();
test_evalsha_fallback();

// ---- pub/sub (phase 7) ---------------------------------------------------

fn sub_msg(sub: redis.Sub, what: str) -> redis.Message {
    let r = redis.sub_next(sub, soon());
    guard let o = r else let e = err_of(r) {
        die(what + ": " + e);
        panic("unreachable");
    }
    guard let m = o else {
        die(what + ": got none");
        panic("unreachable");
    }
    return m;
}

fn sub_conn(lfd: i32, pc: chan[int], steps: [Step]) {
    chan_send(pc, port_of(lfd));
    let fd = accept_one(lfd);
    for st in steps {
        if st.want == "PUSH" {
            srv_send(fd, st.reply);
            continue;
        }
        let cmd = read_cmd(fd);
        if cmd_name(cmd) != st.want {
            die("want " + st.want + ", got " + cmd_name(cmd));
        }
        srv_send(fd, st.reply);
    }
    let rr = net.recv_until(fd, 65536, soon());
    net.close(fd);
    net.close(lfd);
}

fn test_sub_basic() {
    let steps: [Step] = [
        Step { want: "SUBSCRIBE",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\na\r\n:1\r\n" },
        Step { want: "PSUBSCRIBE",
               reply: b"*3\r\n$10\r\npsubscribe\r\n$2\r\nb*\r\n:2\r\n" },
        Step { want: "PUSH",
               reply: b"*3\r\n$7\r\nmessage\r\n$1\r\na\r\n$5\r\nhello\r\n" },
        Step { want: "PUSH",
               reply: b"*4\r\n$8\r\npmessage\r\n$2\r\nb*\r\n$3\r\nbzz\r\n$5\r\nworld\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn sub_conn(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let sr = redis.subscribe(url_for(port), ["a"], ["b*"], soon());
    guard let sub = sr else let e = err_of(sr) {
        die("subscribe: " + e);
        panic("unreachable");
    }
    let m1 = sub_msg(sub, "msg1");
    if m1.kind != "message" || m1.channel != "a" || m1.payload != b"hello" {
        die("msg1 shape");
    }
    if m1.pattern != "" {
        die("msg1 pattern");
    }
    let m2 = sub_msg(sub, "msg2");
    if m2.kind != "pmessage" || m2.channel != "bzz" ||
       m2.pattern != "b*" || m2.payload != b"world" {
        die("msg2 shape");
    }
    redis.sub_close(sub);
    println("ok sub-basic");
}

fn test_sub_add_pending() {
    let steps: [Step] = [
        Step { want: "SUBSCRIBE",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\na\r\n:1\r\n" },
        Step { want: "PUSH",
               reply: b"*3\r\n$7\r\nmessage\r\n$1\r\na\r\n$4\r\nrace\r\n" },
        Step { want: "SUBSCRIBE",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\nb\r\n:2\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn sub_conn(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let sr = redis.subscribe(url_for(port), ["a"], [], soon());
    guard let sub = sr else let e = err_of(sr) {
        die("subscribe: " + e);
        panic("unreachable");
    }
    let ar = redis.sub_add(sub, ["b"], [], soon());
    guard let aok = ar else let e = err_of(ar) {
        die("sub_add: " + e);
        panic("unreachable");
    }
    let m = sub_msg(sub, "pending");
    if m.payload != b"race" {
        die("pending value");
    }
    redis.sub_close(sub);
    println("ok sub-add-pending");
}

fn test_sub_timeout() {
    let steps: [Step] = [
        Step { want: "SUBSCRIBE",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\na\r\n:1\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn sub_conn(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let sr = redis.subscribe(url_for(port), ["a"], [], soon());
    guard let sub = sr else let e = err_of(sr) {
        die("subscribe: " + e);
        panic("unreachable");
    }
    let dl = until_of(time.mono() + 200000000);
    let r = redis.sub_next(sub, dl);
    guard let o = r else let e = err_of(r) {
        die("sub_next: " + e);
        panic("unreachable");
    }
    guard let m = o else {
        redis.sub_close(sub);
        println("ok sub-timeout");
        return;
    }
    redis.sub_close(sub);
    die("message from silence");
}

fn test_sub_remove() {
    let steps: [Step] = [
        Step { want: "SUBSCRIBE",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\na\r\n:1\r\n" },
        Step { want: "PUSH",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\nb\r\n:2\r\n" },
        Step { want: "UNSUBSCRIBE",
               reply: b"*3\r\n$11\r\nunsubscribe\r\n$1\r\na\r\n:1\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn sub_conn(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let sr = redis.subscribe(url_for(port), ["a", "b"], [], soon());
    guard let sub = sr else let e = err_of(sr) {
        die("subscribe: " + e);
        panic("unreachable");
    }
    let rr = redis.sub_remove(sub, ["a"], [], soon());
    guard let rok = rr else let e = err_of(rr) {
        die("sub_remove: " + e);
        panic("unreachable");
    }
    redis.sub_close(sub);
    println("ok sub-remove");
}

fn pump(sub: redis.Sub, out: chan[redis.Message]) {
    while true {
        let dl = until_of(time.mono() + 5000000000);
        let r = redis.sub_next(sub, dl);
        guard let o = r else {
            return;
        }
        guard let m = o else {
            continue;
        }
        chan_send(out, m);
    }
}

fn test_sub_pump() {
    let steps: [Step] = [
        Step { want: "SUBSCRIBE",
               reply: b"*3\r\n$9\r\nsubscribe\r\n$1\r\na\r\n:1\r\n" },
        Step { want: "PUSH",
               reply: b"*3\r\n$7\r\nmessage\r\n$1\r\na\r\n$1\r\n1\r\n" },
        Step { want: "PUSH",
               reply: b"*3\r\n$7\r\nmessage\r\n$1\r\na\r\n$1\r\n2\r\n" },
        Step { want: "PUSH",
               reply: b"*3\r\n$7\r\nmessage\r\n$1\r\na\r\n$1\r\n3\r\n" }
    ];
    let lfd = listen();
    let pc: chan[int] = make_chan(1);
    spawn sub_conn(lfd, pc, steps);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let sr = redis.subscribe(url_for(port), ["a"], [], soon());
    guard let sub = sr else let e = err_of(sr) {
        die("subscribe: " + e);
        panic("unreachable");
    }
    let out: chan[redis.Message] = make_chan(8);
    spawn pump(sub, out);
    let got = b"";
    let i = 0;
    while i < 3 {
        guard let m = chan_recv(out) else {
            die("pump closed early");
            panic("unreachable");
        }
        got = got + m.payload;
        i = i + 1;
    }
    if got != b"123" {
        die("pump values");
    }
    redis.sub_close(sub);
    println("ok sub-pump");
}

test_sub_basic();
test_sub_add_pending();
test_sub_timeout();
test_sub_remove();
test_sub_pump();

fn test_streams() {
    let entry = b"*2\r\n$15\r\n1712345678901-0\r\n*2\r\n$1\r\nf\r\n$1\r\nv\r\n";
    let steps: [Step] = [
        Step { want: "XADD", reply: b"$15\r\n1712345678901-0\r\n" },
        Step { want: "XADD", reply: b"$15\r\n1712345678901-0\r\n" },
        Step { want: "XRANGE", reply: b"*2\r\n" + entry + entry },
        Step { want: "XREVRANGE", reply: b"*1\r\n" + entry },
        Step { want: "XLEN", reply: b":2\r\n" },
        Step { want: "XTRIM", reply: b":1\r\n" },
        Step { want: "XDEL", reply: b":1\r\n" },
        Step { want: "XREAD",
               reply: b"*1\r\n*2\r\n$2\r\nmk\r\n*1\r\n" + entry },
        Step { want: "XREAD", reply: b"*-1\r\n" }
    ];
    let c = scripted(steps);
    let fields: map[str]bytes = {"f": b"v"};
    let ar = redis.xadd(c, "mk", "*", fields, soon());
    guard let id = ar else let e = err_of(ar) {
        die("xadd: " + e);
        panic("unreachable");
    }
    if id != "1712345678901-0" {
        die("xadd id");
    }
    let ar2 = redis.xadd_maxlen(c, "mk", 1000, true, "*", fields, soon());
    guard let id2 = ar2 else let e = err_of(ar2) {
        die("xadd_maxlen: " + e);
        panic("unreachable");
    }
    if id2 != "1712345678901-0" {
        die("xadd_maxlen id");
    }
    let xr = redis.xrange(c, "mk", "-", "+", none, soon());
    guard let entries = xr else let e = err_of(xr) {
        die("xrange: " + e);
        panic("unreachable");
    }
    if len(entries) != 2 || entries[0].id != "1712345678901-0" {
        die("xrange shape");
    }
    if !has(entries[0].fields, "f") {
        die("xrange fields");
    }
    let rr = redis.xrevrange(c, "mk", "+", "-", none, soon());
    guard let rentries = rr else let e = err_of(rr) {
        die("xrevrange: " + e);
        panic("unreachable");
    }
    if len(rentries) != 1 {
        die("xrevrange shape");
    }
    let lr = redis.xlen(c, "mk", soon());
    guard let ln = lr else let e = err_of(lr) {
        die("xlen: " + e);
        panic("unreachable");
    }
    if ln != 2 {
        die("xlen value");
    }
    let tr = redis.xtrim(c, "mk", 1000, true, soon());
    guard let tn = tr else let e = err_of(tr) {
        die("xtrim: " + e);
        panic("unreachable");
    }
    if tn != 1 {
        die("xtrim value");
    }
    let dr = redis.xdel(c, "mk", ["1712345678901-0"], soon());
    guard let dn = dr else let e = err_of(dr) {
        die("xdel: " + e);
        panic("unreachable");
    }
    if dn != 1 {
        die("xdel value");
    }
    let rd = redis.xread(c, ["mk"], ["0"], none, none, soon());
    guard let ro = rd else let e = err_of(rd) {
        die("xread: " + e);
        panic("unreachable");
    }
    guard let reads = ro else {
        die("xread none");
        panic("unreachable");
    }
    if len(reads) != 1 || reads[0].key != "mk" ||
       len(reads[0].entries) != 1 {
        die("xread shape");
    }
    let rd2 = redis.xread(c, ["mk"], ["$"], some(200), none, soon());
    guard let ro2 = rd2 else let e = err_of(rd2) {
        die("xread nil: " + e);
        panic("unreachable");
    }
    guard let reads2 = ro2 else {
        redis.close(c);
        println("ok xread-nil");
        println("ok streams");
        return;
    }
    die("xread data on empty");
}

test_streams();

fn test_cluster_streams() {
    let la = listen();
    let pa = port_of(la);
    let conn1: [Step] = [
        Step { want: "CLUSTER", reply: slots_reply(pa, pa) }
    ];
    let entry = b"*2\r\n$15\r\n1712345678901-0\r\n*2\r\n$1\r\nf\r\n$1\r\nv\r\n";
    let conn2: [Step] = [
        Step { want: "XADD", reply: b"$15\r\n1712345678901-0\r\n" },
        Step { want: "XLEN", reply: b":1\r\n" },
        Step { want: "XREAD",
               reply: b"*1\r\n*2\r\n$2\r\nmk\r\n*1\r\n" + entry }
    ];
    let scripts: [[Step]] = [conn1, conn2];
    let pc: chan[int] = make_chan(1);
    spawn cluster_script(la, pc, scripts);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    let fields: map[str]bytes = {"f": b"v"};
    let ar = redis.cxadd(cl, "mk", "*", fields, soon());
    guard let id = ar else let e = err_of(ar) {
        die("cxadd: " + e);
        panic("unreachable");
    }
    if id != "1712345678901-0" {
        die("cxadd id");
    }
    let lr = redis.cxlen(cl, "mk", soon());
    guard let ln = lr else let e = err_of(lr) {
        die("cxlen: " + e);
        panic("unreachable");
    }
    if ln != 1 {
        die("cxlen value");
    }
    let rr = redis.cxread(cl, ["mk"], ["0"], none, none, soon());
    guard let ro = rr else let e = err_of(rr) {
        die("cxread: " + e);
        panic("unreachable");
    }
    guard let reads = ro else {
        die("cxread none");
        panic("unreachable");
    }
    if len(reads) != 1 || len(reads[0].entries) != 1 {
        die("cxread shape");
    }
    redis.cluster_close(cl);
    println("ok cluster-streams");
}

test_cluster_streams();

fn test_cluster_empty_ip() {
    // A node announcing an empty IP (NAT, sandboxes): fall back to
    // the seed host instead of failing.
    let la = listen();
    let pa = port_of(la);
    let id40 = b"$40\r\n0123456789abcdef0123456789abcdef01234567\r\n";
    let slots = b"*1\r\n*3\r\n:0\r\n:16383\r\n*3\r\n$0\r\n\r\n:" +
                to_bytes(to_str(pa)) + b"\r\n" + id40;
    let conn1: [Step] = [
        Step { want: "CLUSTER", reply: slots }
    ];
    let conn2: [Step] = [
        Step { want: "GET", reply: b"$1\r\nv\r\n" }
    ];
    let scripts: [[Step]] = [conn1, conn2];
    let pc: chan[int] = make_chan(1);
    spawn cluster_script(la, pc, scripts);
    guard let port = chan_recv(pc) else {
        die("no port");
        panic("unreachable");
    }
    let cfg = cluster_cfg();
    let cr = redis.new_cluster(cfg, ["127.0.0.1:" + to_str(pa)], soon());
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    let h = redis.cget(cl, "hello", soon());
    guard let v = h else let e = err_of(h) {
        die("cget: " + e);
        panic("unreachable");
    }
    guard let b = v else {
        die("nil");
        panic("unreachable");
    }
    if b != b"v" {
        die("value");
    }
    redis.cluster_close(cl);
    println("ok cluster-empty-ip");
}

test_cluster_empty_ip();
test_timeout();
