import "net";
import "redis";
import "strings";
import "time";

fn soon() -> until { return until_of(time.mono() + 5000000000); }

gc struct Fake {
    mu: mutex,
    vals: map[str]bytes,
    exp: map[str]int,
}

fn alive(f: Fake, k: str) -> bool {
    if !has(f.vals, k) { return false; }
    if (time.mono() as int) >= f.exp[k] {
        del(f.vals, k);
        del(f.exp, k);
        return false;
    }
    return true;
}

fn arg(r: redis.Reply, i: int) -> bytes { return r.items[i].bulk ?? b""; }
fn sarg(r: redis.Reply, i: int) -> str { return to_str(arg(r, i)); }

fn bulk(b: bytes) -> bytes { return to_bytes("$" + to_str(len(b)) + "\r\n") + b + b"\r\n"; }

fn handle(f: Fake, req: redis.Reply) -> bytes {
    let cmd = strings.to_upper(sarg(req, 0));
    mutex_lock(f.mu);
    let out = b"-ERR\r\n";
    let now = time.mono() as int;
    if cmd == "SET" {
        let k = sarg(req, 1);
        if alive(f, k) { out = b"$-1\r\n"; }
        else { f.vals[k] = arg(req, 2); f.exp[k] = now + (to_int(sarg(req, 5)) ?? 0) * 1000000; out = b"+OK\r\n"; }
    } else if cmd == "GET" {
        let k = sarg(req, 1);
        if alive(f, k) { out = bulk(f.vals[k]); } else { out = b"$-1\r\n"; }
    } else if cmd == "EVAL" {
        let script = sarg(req, 1);
        let k = sarg(req, 3);
        let mine = alive(f, k) && f.vals[k] == arg(req, 4);
        if strings.contains(script, "'set'") {
            if mine { f.vals[k] = arg(req, 5); f.exp[k] = now + (to_int(sarg(req, 6)) ?? 0) * 1000000; out = b"+OK\r\n"; }
            else { out = b"$-1\r\n"; }
        } else {
            if mine { del(f.vals, k); out = b":1\r\n"; } else { out = b":0\r\n"; }
        }
    }
    mutex_unlock(f.mu);
    return out;
}

fn serve(f: Fake, fd: i32) {
    let buf = b"";
    while true {
        let dr = redis.decode(buf);
        guard let maybe = dr else { break; }
        if let d = maybe {
            buf = buf[d.consumed..];
            let _s = net.send(fd, handle(f, d.reply));
            continue;
        }
        let rr = net.recv(fd, 65536);
        guard let b = rr else { break; }
        if len(b) == 0 { break; }
        buf = buf + b;
    }
    net.close(fd);
}

fn accept_all(f: Fake, lfd: i32) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        spawn serve(f, fd);
    }
}

fn conn() -> redis.Conn {
    let a: map[str]bytes = {};
    let b: map[str]int = {};
    let f = Fake { mu: make_mutex(), vals: a, exp: b };
    let lfd = net.listen(0) ?? (-1 as i32);
    spawn accept_all(f, lfd);
    let cr = redis.connect("redis://127.0.0.1:" + to_str(net.port(lfd) ?? 0), soon());
    guard let c = cr else let e = err_of(cr) { panic(e); }
    return c;
}

fn must(r: result[Begin, str]) -> Begin {
    guard let b = r else let e = err_of(r) { panic(e); }
    return b;
}

fn test_should_run_once_and_replay_the_response() {
    let c = conn();
    let first = must(begin(c, "pay-1", "fp1", 30000, soon()));
    assert(first.state == NEW, "first request did not run");
    let during = must(begin(c, "pay-1", "fp1", 30000, soon()));
    assert(during.state == IN_PROGRESS, "a concurrent copy was allowed to run");
    assert(complete(c, "pay-1", first, b"{\"charged\":true}\r\n:x", 60000, soon()) ?? false, "complete");
    let again = must(begin(c, "pay-1", "fp1", 30000, soon()));
    assert(again.state == DONE && again.response == b"{\"charged\":true}\r\n:x", "replay");
}

fn test_should_refuse_a_key_reused_for_another_request() {
    let c = conn();
    let first = must(begin(c, "k", "body-a", 30000, soon()));
    let _d = complete(c, "k", first, b"ok", 60000, soon());
    assert(must(begin(c, "k", "body-b", 30000, soon())).state == MISMATCH, "mismatch not seen");
}

fn test_should_free_the_key_on_abandon_and_on_expiry() {
    let c = conn();
    let first = must(begin(c, "k", "fp", 30000, soon()));
    assert(abandon(c, "k", first, soon()) ?? false, "abandon");
    let retry = must(begin(c, "k", "fp", 50, soon()));
    assert(retry.state == NEW, "retry after abandon");
    time.sleep(80000000);                         // the reservation expires
    let late = must(begin(c, "k", "fp", 30000, soon()));
    assert(late.state == NEW, "expired reservation still held");
    assert(!(complete(c, "k", retry, b"stale", 60000, soon()) ?? true), "a lost reservation completed");
}

fn test_should_validate_input() {
    let c = conn();
    if let _a = begin(c, "", "fp", 1000, soon()) { panic("empty key"); }
    if let _b = begin(c, "k", "a:b", 1000, soon()) { panic("colon in fingerprint"); }
}
