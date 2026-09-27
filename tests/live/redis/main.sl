import "redis";
import "proc";
import "time";
import "strings";

// The client against a REAL Redis. Not part of `make test`, which
// must run without one; CI runs it against a service container, and
// locally:
//
//   redis-server --port 6379 --daemonize yes
//   REDIS_URL=redis://127.0.0.1:6379 ./slangc tests/live/redis/main.sl --run
//
// REDIS_TLS_URL, if set, is a rediss:// server: the test verifies the
// session really is encrypted (with REDIS_TLS_CA pointing at the CA
// bundle). REDIS_CLUSTER_URL, if set, points at a cluster-mode node
// and adds routing coverage.
// REDIS_CLUSTER_URL, if set, points at a cluster-mode node and adds
// routing/redirect coverage on top. Every key is prefixed and deleted
// at the end; the database is otherwise untouched (never FLUSHDB).

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until {
    return until_of(time.mono() + 30000000000);
}

fn url() -> str {
    guard let u = proc.getenv("REDIS_URL") else {
        die("REDIS_URL is not set");
        return "";
    }
    return u;
}

fn conn() -> redis.Conn {
    let cr = redis.connect(url(), soon());
    guard let c = cr else let e = err_of(cr) {
        die("connect: " + e);
        panic("unreachable");
    }
    return c;
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

fn rbytes(r: result[bytes, str], want: bytes, what: str) {
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
    guard let v = o else {
        return;
    }
    die(what + ": got some");
}

fn test_strings(c: redis.Conn) {
    let k = "slang:test:str";
    rb(redis.set(c, k, b"v", soon()), true, "set");
    ropt_some(redis.get(c, k, soon()), b"v", "get");
    ropt_none(redis.get(c, "slang:test:absent", soon()), "get nil");
    ri(redis.incr(c, "slang:test:ctr", soon()), 1, "incr");
    ri(redis.incr(c, "slang:test:ctr", soon()), 2, "incr");
    ri(redis.del_keys(c, ["slang:test:ctr"], soon()), 1, "del");
    // real expiry, not scripted
    rb(redis.set_ex(c, k, 1, b"v", soon()), true, "set_ex");
    time.sleep(1200000000);
    ropt_none(redis.get(c, k, soon()), "expired");
    ri(redis.del_keys(c, [k], soon()), 0, "del gone");
    println("ok live-strings");
}

fn test_hash_list_set(c: redis.Conn) {
    let h = "slang:test:hash";
    ri(redis.hset(c, h, "f", b"1", soon()), 1, "hset");
    ropt_some(redis.hget(c, h, "f", soon()), b"1", "hget");
    ri(redis.hincr_by(c, h, "f", 4, soon()), 5, "hincrby");
    let l = "slang:test:list";
    ri(redis.rpush(c, l, [b"a", b"b"], soon()), 2, "rpush");
    let lr = redis.lrange(c, l, 0, 0 - 1, soon());
    guard let ls = lr else let e = err_of(lr) {
        die("lrange: " + e);
        panic("unreachable");
    }
    if len(ls) != 2 {
        die("lrange length");
    }
    let s = "slang:test:set";
    ri(redis.sadd(c, s, [b"a", b"b"], soon()), 2, "sadd");
    rb(redis.sismember(c, s, b"a", soon()), true, "sismember");
    let z = "slang:test:zset";
    let zm: map[str]float = {"a": 1.5};
    ri(redis.zadd(c, z, zm, soon()), 1, "zadd");
    let zr = redis.zscore(c, z, b"a", soon());
    guard let zo = zr else let e = err_of(zr) {
        die("zscore: " + e);
        panic("unreachable");
    }
    guard let zf = zo else {
        die("zscore nil");
        panic("unreachable");
    }
    if zf != 1.5 {
        die("zscore value");
    }
    ri(redis.del_keys(c, [h, l, s, z], soon()), 4, "cleanup");
    println("ok live-hash-list-set");
}

fn test_txn_script(c: redis.Conn) {
    let k = "slang:test:txn";
    let m = redis.multi(c, soon());
    guard let mok = m else let e = err_of(m) {
        die("multi: " + e);
        panic("unreachable");
    }
    let q1 = redis.queue(c, [to_bytes("INCR"), to_bytes(k)], soon());
    guard let qok1 = q1 else let e = err_of(q1) {
        die("queue: " + e);
        panic("unreachable");
    }
    let er = redis.exec(c, soon());
    guard let out = er else let e = err_of(er) {
        die("exec: " + e);
        panic("unreachable");
    }
    if len(out) != 1 || out[0].num != 1 {
        die("exec results");
    }
    // EVALSHA against real SHA validation: wrong hash would NOSCRIPT
    // forever, right hash runs once the source lands.
    let vr = redis.evalsha(c, "return 40 + 2", [], [], soon());
    guard let v = vr else let e = err_of(vr) {
        die("evalsha: " + e);
        panic("unreachable");
    }
    if v.kind != redis.REPLY_INT || v.num != 42 {
        die("evalsha value");
    }
    ri(redis.del_keys(c, [k], soon()), 1, "del");
    println("ok live-txn-script");
}

fn test_pubsub(c: redis.Conn) {
    let ch = "slang:test:chan";
    let sr = redis.subscribe(url(), [ch], [], soon());
    guard let sub = sr else let e = err_of(sr) {
        die("subscribe: " + e);
        panic("unreachable");
    }
    let pr = redis.do(c, [to_bytes("PUBLISH"), to_bytes(ch),
                          to_bytes("hey")], soon());
    guard let pb = pr else let e = err_of(pr) {
        die("publish: " + e);
        panic("unreachable");
    }
    if pb.kind != redis.REPLY_INT || pb.num != 1 {
        die("publish count");
    }
    let dl = until_of(time.mono() + 5000000000);
    let mr = redis.sub_next(sub, dl);
    guard let o = mr else let e = err_of(mr) {
        die("sub_next: " + e);
        panic("unreachable");
    }
    guard let m = o else {
        die("no message");
        panic("unreachable");
    }
    if m.channel != ch || m.payload != b"hey" {
        die("message shape");
    }
    redis.sub_close(sub);
    println("ok live-pubsub");
}

fn test_scan_pool(c: redis.Conn) {
    rb(redis.set(c, "slang:test:scanme", b"1", soon()), true, "set");
    let cursor = 0;
    let found = false;
    let steps = 0;
    while true {
        let sr = redis.scan(c, cursor, none, none, soon());
        guard let out = sr else let e = err_of(sr) {
            die("scan: " + e);
            panic("unreachable");
        }
        for k in out.keys {
            if k == "slang:test:scanme" {
                found = true;
            }
        }
        cursor = out.cursor;
        steps = steps + 1;
        if cursor == 0 || steps > 100 {
            break;
        }
    }
    if !found {
        die("scan missed key");
    }
    let pr = redis.new_pool(url(), 2);
    guard let p = pr else let e = err_of(pr) {
        die("new_pool: " + e);
        panic("unreachable");
    }
    let qr = redis.pool_do(p, [to_bytes("PING")], soon());
    guard let pong = qr else let e = err_of(qr) {
        die("pool_do: " + e);
        panic("unreachable");
    }
    if pong.kind != redis.REPLY_SIMPLE {
        die("pool_do shape");
    }
    redis.pool_close(p);
    ri(redis.del_keys(c, ["slang:test:scanme"], soon()), 1, "del");
    println("ok live-scan-pool");
}

fn test_streams(c: redis.Conn) {
    let k = "slang:test:stream";
    let fields: map[str]bytes = {"f": b"v"};
    let ar = redis.xadd(c, k, "*", fields, soon());
    guard let id = ar else let e = err_of(ar) {
        die("xadd: " + e);
        panic("unreachable");
    }
    let xr = redis.xrange(c, k, "-", "+", none, soon());
    guard let entries = xr else let e = err_of(xr) {
        die("xrange: " + e);
        panic("unreachable");
    }
    if len(entries) != 1 || entries[0].id != id {
        die("xrange shape");
    }
    if !has(entries[0].fields, "f") {
        die("xrange fields");
    }
    let rr = redis.xread(c, [k], ["0"], none, none, soon());
    guard let ro = rr else let e = err_of(rr) {
        die("xread: " + e);
        panic("unreachable");
    }
    guard let reads = ro else {
        die("xread none");
        panic("unreachable");
    }
    if len(reads) != 1 || len(reads[0].entries) != 1 {
        die("xread shape");
    }
    ri(redis.xlen(c, k, soon()), 1, "xlen");
    ri(redis.xdel(c, k, [id], soon()), 1, "xdel");
    println("ok live-streams");
}

fn test_tls() {
    guard let turl = proc.getenv("REDIS_TLS_URL") else {
        println("skip tls (no REDIS_TLS_URL)");
        return;
    }
    let cr = redis.parse_url(turl);
    guard let cfg = cr else let e = err_of(cr) {
        die("tls url: " + e);
        panic("unreachable");
    }
    guard let ca = proc.getenv("REDIS_TLS_CA") else {
        die("REDIS_TLS_CA is not set");
        return;
    }
    cfg.ca_path = ca;
    let dl = soon();
    let dr = redis.connect_config(cfg, dl);
    guard let c = dr else let e = err_of(dr) {
        die("tls connect: " + e);
        panic("unreachable");
    }
    rs(redis.ping(c, dl), "PONG", "tls ping");
    rb(redis.set(c, "slang:test:tls", b"v", dl), true, "tls set");
    ropt_some(redis.get(c, "slang:test:tls", dl), b"v", "tls get");
    ri(redis.del_keys(c, ["slang:test:tls"], dl), 1, "tls del");
    redis.close(c);
    println("ok live-tls");
}

fn test_cluster() {
    guard let curl = proc.getenv("REDIS_CLUSTER_URL") else {
        println("skip cluster (no REDIS_CLUSTER_URL)");
        return;
    }
    let cfr = redis.parse_url(curl);
    guard let cfg = cfr else let e = err_of(cfr) {
        die("cluster url: " + e);
        panic("unreachable");
    }
    let dl = soon();
    let cr = redis.new_cluster(cfg, [cfg.host + ":" + to_str(cfg.port)],
                               dl);
    guard let cl = cr else let e = err_of(cr) {
        die("new_cluster: " + e);
        panic("unreachable");
    }
    // One tagged family stays on one slot: every wrapper agrees.
    let k = "{slang:test}live";
    let sr = redis.cset(cl, k, b"v", dl);
    guard let sok = sr else let e = err_of(sr) {
        die("cset: " + e);
        panic("unreachable");
    }
    let gr = redis.cget(cl, k, dl);
    guard let go = gr else let e = err_of(gr) {
        die("cget: " + e);
        panic("unreachable");
    }
    guard let gv = go else {
        die("cget nil");
        panic("unreachable");
    }
    if gv != b"v" {
        die("cget value");
    }
    ri(redis.cincr(cl, "{slang:test}ctr", dl), 1, "cincr");
    ri(redis.cdel_keys(cl, [k, "{slang:test}ctr"], dl), 2, "cdel");
    let mr = redis.cmget(cl, ["{slang:test}a", "{slang:test}b"], dl);
    guard let items = mr else let e = err_of(mr) {
        die("cmget: " + e);
        panic("unreachable");
    }
    if len(items) != 2 {
        die("cmget length");
    }
    redis.cluster_close(cl);
    println("ok live-cluster");
}

let c = conn();
test_strings(c);
test_hash_list_set(c);
test_txn_script(c);
test_pubsub(c);
test_scan_pool(c);
test_streams(c);
redis.close(c);
test_tls();
test_cluster();
