// A memcached client (the text protocol every memcached and compatible
// server speaks), over one or more servers.
//
//     import "memcache";
//
//     let mc = memcache.new(["cache-1:11211", "cache-2:11211"]);
//     memcache.set(mc, "user:42", to_bytes(json), 300, deadline);    // 5 min
//     let gr = memcache.get(mc, "user:42", deadline);
//     guard let found = gr else let e = err_of(gr) { ... }          // I/O error
//     if let v = found { ... } else { /* a miss */ }
//
// Keys spread over servers by rendezvous hashing, so adding or removing
// a server moves only its share. get_multi asks each server once for
// all its keys. Connections are kept idle per server (up to max_idle) and
// reused; one that saw any error is closed rather than reused, so a
// half-read reply never reaches the next caller.

import "builder";
import "math/shard";
import "net";
import "strings";

pub gc struct Client {
    servers: [str],
    ring: shard.Rendezvous,
    mu: mutex,
    idle: map[str][i32],
    max_idle: int,
    max_value: int,
}

pub fn new(servers: [str]) -> Client {
    let m: map[str][i32] = {};
    return Client { servers: servers, ring: shard.rendezvous(servers), mu: make_mutex(),
                    idle: m, max_idle: 8, max_value: 1048576 };
}

pub struct Item {
    value: bytes,
    flags: int,
    cas: int,
}

// The value for key, or none on a miss.
pub fn get(c: Client, key: str, deadline: until) -> result[opt[bytes], str] {
    let ir = gets(c, key, deadline);
    guard let found = ir else let e = err_of(ir) { return err(e); }
    if let it = found { return ok(some(it.value)); }
    return ok(none);
}

// The item for key with its cas token, or none on a miss.
pub fn gets(c: Client, key: str, deadline: until) -> result[opt[Item], str] {
    let kr = check_key(key);
    guard let _k = kr else let ke = err_of(kr) { return err(ke); }
    let srv = server_of(c, key);
    let cr = conn(c, srv, deadline);
    guard let cn = cr else let ce = err_of(cr) { return err(ce); }
    let wr = send(cn, "gets " + key + "\r\n", b"", deadline);
    guard let _w = wr else let we = err_of(wr) { drop(cn); return err(we); }
    let items: map[str]Item = {};
    let rr = read_values(c, cn, items, deadline);
    guard let _r = rr else let re = err_of(rr) { drop(cn); return err(re); }
    put_back(c, srv, cn);
    if has(items, key) { return ok(some(items[key])); }
    return ok(none);
}

// The values of every key found, one request per server.
pub fn get_multi(c: Client, keys: [str], deadline: until) -> result[map[str]bytes, str] {
    let by: map[str][str] = {};
    for k in keys {
        let kr = check_key(k);
        guard let _k = kr else let ke = err_of(kr) { return err(ke); }
        let s = server_of(c, k);
        if !has(by, s) { let empty: [str] = []; by[s] = empty; }
        push(by[s], k);
    }
    let out: map[str]bytes = {};
    for srv, ks in by {
        let cr = conn(c, srv, deadline);
        guard let cn = cr else let ce = err_of(cr) { return err(ce); }
        let wr = send(cn, "get " + strings.join(ks, " ") + "\r\n", b"", deadline);
        guard let _w = wr else let we = err_of(wr) { drop(cn); return err(we); }
        let items: map[str]Item = {};
        let rr = read_values(c, cn, items, deadline);
        guard let _r = rr else let re = err_of(rr) { drop(cn); return err(re); }
        put_back(c, srv, cn);
        for k, it in items { out[k] = it.value; }
    }
    return ok(out);
}

// Stores value for ttl seconds (0: no expiry; over 30 days is read by
// memcached as a unix time).
pub fn set(c: Client, key: str, value: bytes, ttl: int, deadline: until) -> result[bool, str] {
    return store(c, "set", key, value, ttl, 0, deadline);
}

// Stores only if the key is absent: false if it was there.
pub fn add(c: Client, key: str, value: bytes, ttl: int, deadline: until) -> result[bool, str] {
    return store(c, "add", key, value, ttl, 0, deadline);
}

// Stores only if the key is present: false if it was not.
pub fn replace(c: Client, key: str, value: bytes, ttl: int, deadline: until) -> result[bool, str] {
    return store(c, "replace", key, value, ttl, 0, deadline);
}

// Stores only if the item is unchanged since gets returned cas: false if
// another writer got there first (or the key is gone).
pub fn cas(c: Client, key: str, value: bytes, ttl: int, cas_token: int,
           deadline: until) -> result[bool, str] {
    return store(c, "cas", key, value, ttl, cas_token, deadline);
}

// Deletes key: false if it was not there.
pub fn delete(c: Client, key: str, deadline: until) -> result[bool, str] {
    let rr = simple(c, key, "delete " + key + "\r\n", deadline);
    guard let line = rr else let e = err_of(rr) { return err(e); }
    if line == "DELETED" { return ok(true); }
    if line == "NOT_FOUND" { return ok(false); }
    return err("memcache: " + line);
}

// Adds delta to a numeric value: the new value, or none if the key is
// absent.
pub fn incr(c: Client, key: str, delta: int, deadline: until) -> result[opt[int], str] {
    return arith(c, "incr", key, delta, deadline);
}

// Subtracts delta, stopping at 0 as memcached does.
pub fn decr(c: Client, key: str, delta: int, deadline: until) -> result[opt[int], str] {
    return arith(c, "decr", key, delta, deadline);
}

// Gives key a new ttl: false if it was not there.
pub fn touch(c: Client, key: str, ttl: int, deadline: until) -> result[bool, str] {
    let rr = simple(c, key, "touch " + key + " " + to_str(ttl) + "\r\n", deadline);
    guard let line = rr else let e = err_of(rr) { return err(e); }
    if line == "TOUCHED" { return ok(true); }
    if line == "NOT_FOUND" { return ok(false); }
    return err("memcache: " + line);
}

// Closes every idle connection.
pub fn close(c: Client) {
    mutex_lock(c.mu);
    let all = c.idle;
    let m: map[str][i32] = {};
    c.idle = m;
    mutex_unlock(c.mu);
    for _s, fds in all {
        for fd in fds { net.close(fd); }
    }
}

// ---- internals -----------------------------------------------------------

gc struct Conn {
    fd: i32,
    buf: bytes,
}

fn check_key(key: str) -> result[bool, str] {
    let b = to_bytes(key);
    if len(b) == 0 || len(b) > 250 { return err("memcache: a key is 1 to 250 bytes"); }
    for i in 0..len(b) {
        let ch = b[i] as int;
        if ch <= 32 || ch == 127 { return err("memcache: a key cannot hold spaces or control characters"); }
    }
    return ok(true);
}

fn server_of(c: Client, key: str) -> str {
    let i = c.ring.pick_str(key) ?? 0;
    return c.servers[i];
}

fn conn(c: Client, srv: str, deadline: until) -> result[Conn, str] {
    mutex_lock(c.mu);
    if has(c.idle, srv) && len(c.idle[srv]) > 0 {
        let fd = pop(c.idle[srv]);
        mutex_unlock(c.mu);
        if net.idle_alive(fd) { return ok(Conn { fd: fd, buf: b"" }); }
        net.close(fd);
    } else {
        mutex_unlock(c.mu);
    }
    let colon = strings.rfind(srv, ":");
    if colon < 0 { return err("memcache: server needs host:port: " + srv); }
    let port = to_int(strings.slice(srv, colon + 1, len(srv))) ?? -1;
    let dr = net.dial_until(strings.slice(srv, 0, colon), port, deadline);
    guard let fd = dr else let e = err_of(dr) { return err("memcache: " + srv + ": " + e); }
    return ok(Conn { fd: fd, buf: b"" });
}

fn put_back(c: Client, srv: str, cn: Conn) {
    if len(cn.buf) > 0 { drop(cn); return; }   // stray bytes: out of step
    mutex_lock(c.mu);
    if !has(c.idle, srv) { let empty: [i32] = []; c.idle[srv] = empty; }
    if len(c.idle[srv]) < c.max_idle {
        push(c.idle[srv], cn.fd);
        mutex_unlock(c.mu);
        return;
    }
    mutex_unlock(c.mu);
    net.close(cn.fd);
}

fn drop(cn: Conn) {
    net.close(cn.fd);
}

fn send(cn: Conn, line: str, data: bytes, deadline: until) -> result[bool, str] {
    let b = builder.new_bytes();
    b.write_str(line);
    if len(data) > 0 || strings.has_prefix(line, "set ") || strings.has_prefix(line, "add ") ||
       strings.has_prefix(line, "replace ") || strings.has_prefix(line, "cas ") {
        b.write(data);
        b.write_str("\r\n");
    }
    let r = net.send_until(cn.fd, b.finish(), deadline);
    guard let _n = r else let e = err_of(r) { return err("memcache: " + e); }
    return ok(true);
}

fn fill(cn: Conn, deadline: until) -> result[bool, str] {
    let r = net.recv_until(cn.fd, 65536, deadline);
    guard let b = r else let e = err_of(r) { return err("memcache: " + e); }
    if len(b) == 0 { return err("memcache: server closed the connection"); }
    cn.buf = cn.buf + b;
    return ok(true);
}

fn read_line(cn: Conn, deadline: until) -> result[str, str] {
    while true {
        let n = len(cn.buf);
        for i in 0..n - 1 {
            if (cn.buf[i] as int) == 13 && (cn.buf[i + 1] as int) == 10 {
                let line = to_str(cn.buf[0..i]);
                cn.buf = cn.buf[i + 2..];
                return ok(line);
            }
        }
        if n > 4096 { return err("memcache: reply line too long"); }
        let fr = fill(cn, deadline);
        guard let _f = fr else let e = err_of(fr) { return err(e); }
    }
    return err("memcache: unreachable");
}

fn read_exact(cn: Conn, n: int, deadline: until) -> result[bytes, str] {
    while len(cn.buf) < n {
        let fr = fill(cn, deadline);
        guard let _f = fr else let e = err_of(fr) { return err(e); }
    }
    let out = cn.buf[0..n];
    cn.buf = cn.buf[n..];
    return ok(out);
}

// VALUE lines until END, into items.
fn read_values(c: Client, cn: Conn, items: map[str]Item, deadline: until) -> result[bool, str] {
    while true {
        let lr = read_line(cn, deadline);
        guard let line = lr else let e = err_of(lr) { return err(e); }
        if line == "END" { return ok(true); }
        let f = strings.split(line, " ");
        if len(f) < 4 || f[0] != "VALUE" { return err("memcache: " + line); }
        let size = to_int(f[3]) ?? -1;
        if size < 0 || size > c.max_value { return err("memcache: bad value size in " + line); }
        let dr = read_exact(cn, size + 2, deadline);
        guard let d = dr else let e = err_of(dr) { return err(e); }
        if d[size..] != b"\r\n" { return err("memcache: value not followed by CRLF"); }
        let casv = 0;
        if len(f) >= 5 { casv = to_int(f[4]) ?? 0; }
        items[f[1]] = Item { value: d[0..size], flags: to_int(f[2]) ?? 0, cas: casv };
    }
    return err("memcache: unreachable");
}

fn store(c: Client, cmd: str, key: str, value: bytes, ttl: int, cas_token: int,
         deadline: until) -> result[bool, str] {
    let kr = check_key(key);
    guard let _k = kr else let ke = err_of(kr) { return err(ke); }
    if len(value) > c.max_value { return err("memcache: value over max_value"); }
    let line = cmd + " " + key + " 0 " + to_str(ttl) + " " + to_str(len(value));
    if cmd == "cas" { line = line + " " + to_str(cas_token); }
    let srv = server_of(c, key);
    let cr = conn(c, srv, deadline);
    guard let cn = cr else let ce = err_of(cr) { return err(ce); }
    let wr = send(cn, line + "\r\n", value, deadline);
    guard let _w = wr else let we = err_of(wr) { drop(cn); return err(we); }
    let rr = read_line(cn, deadline);
    guard let reply = rr else let re = err_of(rr) { drop(cn); return err(re); }
    put_back(c, srv, cn);
    if reply == "STORED" { return ok(true); }
    if reply == "NOT_STORED" || reply == "EXISTS" || reply == "NOT_FOUND" { return ok(false); }
    return err("memcache: " + reply);
}

fn simple(c: Client, key: str, line: str, deadline: until) -> result[str, str] {
    let kr = check_key(key);
    guard let _k = kr else let ke = err_of(kr) { return err(ke); }
    let srv = server_of(c, key);
    let cr = conn(c, srv, deadline);
    guard let cn = cr else let ce = err_of(cr) { return err(ce); }
    let wr = send(cn, line, b"", deadline);
    guard let _w = wr else let we = err_of(wr) { drop(cn); return err(we); }
    let rr = read_line(cn, deadline);
    guard let reply = rr else let re = err_of(rr) { drop(cn); return err(re); }
    put_back(c, srv, cn);
    return ok(reply);
}

fn arith(c: Client, cmd: str, key: str, delta: int, deadline: until) -> result[opt[int], str] {
    if delta < 0 { return err("memcache: delta must not be negative"); }
    let rr = simple(c, key, cmd + " " + key + " " + to_str(delta) + "\r\n", deadline);
    guard let line = rr else let e = err_of(rr) { return err(e); }
    if line == "NOT_FOUND" { return ok(none); }
    let v = to_int(line);
    if let n = v { return ok(some(n)); }
    return err("memcache: " + line);
}
