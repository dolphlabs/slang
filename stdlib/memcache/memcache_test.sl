import "net";
import "strings";
import "time";

fn soon() -> until { return until_of(time.mono() + 5000000000); }

// A tiny memcached: the text commands this client uses, in memory.
gc struct Store {
    mu: mutex,
    vals: map[str]bytes,
    cas: map[str]int,
    next_cas: int,
    conns: int,
}

fn reply(fd: i32, s: str) { let _x = net.send(fd, to_bytes(s)); }

fn serve_conn(st: Store, fd: i32) {
    let buf = b"";
    while true {
        let i = find_crlf(buf);
        if i < 0 {
            let r = net.recv(fd, 65536);
            guard let b = r else { break; }
            if len(b) == 0 { break; }
            buf = buf + b;
            continue;
        }
        let line = to_str(buf[0..i]);
        buf = buf[i + 2..];
        let f = strings.split(line, " ");
        mutex_lock(st.mu);
        if f[0] == "get" || f[0] == "gets" {
            let out = "";
            for k in f[1..] {
                if has(st.vals, k) {
                    let v = st.vals[k];
                    out = out + "VALUE " + k + " 0 " + to_str(len(v));
                    if f[0] == "gets" { out = out + " " + to_str(st.cas[k]); }
                    out = out + "\r\n" + to_str(v) + "\r\n";
                }
            }
            mutex_unlock(st.mu);
            reply(fd, out + "END\r\n");
            continue;
        }
        if f[0] == "set" || f[0] == "add" || f[0] == "replace" || f[0] == "cas" {
            let n = to_int(f[4]) ?? 0;
            mutex_unlock(st.mu);
            while len(buf) < n + 2 {
                let r = net.recv(fd, 65536);
                guard let b = r else { return; }
                buf = buf + b;
            }
            let data = buf[0..n];
            buf = buf[n + 2..];
            mutex_lock(st.mu);
            let present = has(st.vals, f[1]);
            let res = "STORED";
            if f[0] == "add" && present { res = "NOT_STORED"; }
            else if f[0] == "replace" && !present { res = "NOT_STORED"; }
            else if f[0] == "cas" {
                if !present { res = "NOT_FOUND"; }
                else if st.cas[f[1]] != (to_int(f[5]) ?? -1) { res = "EXISTS"; }
            }
            if res == "STORED" {
                st.vals[f[1]] = data;
                st.next_cas = st.next_cas + 1;
                st.cas[f[1]] = st.next_cas;
            }
            mutex_unlock(st.mu);
            reply(fd, res + "\r\n");
            continue;
        }
        let res = "ERROR";
        if f[0] == "delete" {
            res = "NOT_FOUND";
            if has(st.vals, f[1]) { del(st.vals, f[1]); res = "DELETED"; }
        } else if f[0] == "touch" {
            res = "NOT_FOUND";
            if has(st.vals, f[1]) { res = "TOUCHED"; }
        } else if f[0] == "incr" || f[0] == "decr" {
            res = "NOT_FOUND";
            if has(st.vals, f[1]) {
                let cur = to_int(to_str(st.vals[f[1]])) ?? 0;
                let d = to_int(f[2]) ?? 0;
                if f[0] == "incr" { cur = cur + d; } else { cur = cur - d; if cur < 0 { cur = 0; } }
                st.vals[f[1]] = to_bytes(to_str(cur));
                res = to_str(cur);
            }
        }
        mutex_unlock(st.mu);
        reply(fd, res + "\r\n");
    }
    net.close(fd);
}

fn find_crlf(b: bytes) -> int {
    for i in 0..len(b) - 1 {
        if (b[i] as int) == 13 && (b[i + 1] as int) == 10 { return i; }
    }
    return -1;
}

fn listener(st: Store, lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        mutex_lock(st.mu);
        st.conns = st.conns + 1;
        mutex_unlock(st.mu);
        spawn serve_conn(st, fd);
    }
}

fn server() -> [str] {
    let a: map[str]bytes = {};
    let b: map[str]int = {};
    let st = Store { mu: make_mutex(), vals: a, cas: b, next_cas: 0, conns: 0 };
    let lfd = net.listen(0) ?? (-1 as i32);
    spawn listener(st, lfd);
    return ["127.0.0.1:" + to_str(net.port(lfd) ?? 0)];
}

fn test_should_set_get_and_miss() {
    let mc = new(server());
    assert(set(mc, "k", b"hello\r\nEND\r\n", 0, soon()) ?? false, "set");
    let got = get(mc, "k", soon());
    guard let found = got else let e = err_of(got) { panic(e); }
    assert((found ?? b"") == b"hello\r\nEND\r\n", "binary value with CRLF and END inside");
    let miss = get(mc, "nope", soon()) ?? some(b"x");
    if let _v = miss { panic("miss returned a value"); }
}

fn test_should_honour_add_replace_delete_and_touch() {
    let mc = new(server());
    assert(add(mc, "a", b"1", 0, soon()) ?? false, "first add");
    assert(!(add(mc, "a", b"2", 0, soon()) ?? true), "second add stored");
    assert(!(replace(mc, "b", b"x", 0, soon()) ?? true), "replace of an absent key");
    assert(replace(mc, "a", b"3", 0, soon()) ?? false, "replace");
    assert(touch(mc, "a", 60, soon()) ?? false, "touch");
    assert(delete(mc, "a", soon()) ?? false, "delete");
    assert(!(delete(mc, "a", soon()) ?? true), "second delete");
}

fn test_should_refuse_a_stale_cas() {
    let mc = new(server());
    let _s = set(mc, "c", b"v1", 0, soon());
    let ir = gets(mc, "c", soon());
    guard let fo = ir else { panic("gets"); }
    guard let it = fo else { panic("gets miss"); }
    let _o = set(mc, "c", b"other writer", 0, soon());
    assert(!(cas(mc, "c", b"v2", 0, it.cas, soon()) ?? true), "stale cas stored");
    let it2 = (gets(mc, "c", soon()) ?? none) ?? Item { value: b"", flags: 0, cas: 0 };
    assert(cas(mc, "c", b"v3", 0, it2.cas, soon()) ?? false, "fresh cas refused");
}

fn test_should_count_with_incr_and_decr() {
    let mc = new(server());
    if let _n = incr(mc, "n", 1, soon()) ?? some(0) { panic("incr of an absent key"); }
    let _s = set(mc, "n", b"10", 0, soon());
    assert(((incr(mc, "n", 5, soon()) ?? none) ?? 0) == 15, "incr");
    assert(((decr(mc, "n", 100, soon()) ?? none) ?? -1) == 0, "decr stops at 0");
}

fn test_should_get_many_keys_across_servers() {
    let mc = new([server()[0], server()[0]]);
    for i in 0..20 { let _s = set(mc, "k" + to_str(i), to_bytes(to_str(i)), 0, soon()); }
    let keys: [str] = [];
    for i in 0..25 { push(keys, "k" + to_str(i)); }
    let mr = get_multi(mc, keys, soon());
    guard let m = mr else let e = err_of(mr) { panic(e); }
    assert(len(m) == 20 && to_str(m["k7"]) == "7", "multi-get " + to_str(len(m)));
}

fn test_should_reuse_connections() {
    let srv = server();
    let mc = new(srv);
    for i in 0..50 { let _s = set(mc, "r", to_bytes(to_str(i)), 0, soon()); }
    assert(len(mc.idle[srv[0]]) == 1, "idle connections: " + to_str(len(mc.idle[srv[0]])));
}

fn test_should_validate_keys_and_report_dead_servers() {
    let mc = new(server());
    if let _a = set(mc, "has space", b"x", 0, soon()) { panic("key with a space"); }
    if let _b = get(mc, strings.repeat("k", 251), soon()) { panic("251-byte key"); }
    let dead = new(["127.0.0.1:1"]);
    assert(strings.contains(err_of(get(dead, "k", soon())), "127.0.0.1:1"), "dead server error");
}
