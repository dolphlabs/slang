import "net";
import "redis";
import "strings";
import "time";

fn soon() -> until { return until_of(time.mono() + 5000000000); }
fn ms(n: int) -> int { return n * 1000000; }

// A fake Redis with expiring keys: SET NX PX, INCR, and the two scripts
// (recognised by what they call).
gc struct Fake {
    mu: mutex,
    vals: map[str]str,
    exp: map[str]int,
    nums: map[str]int,
}

fn alive(f: Fake, k: str) -> bool {
    if !has(f.vals, k) { return false; }
    if has(f.exp, k) && (time.mono() as int) >= f.exp[k] {
        del(f.vals, k);
        del(f.exp, k);
        return false;
    }
    return true;
}

fn arg(r: redis.Reply, i: int) -> str {
    return to_str(r.items[i].bulk ?? b"");
}

fn handle(f: Fake, req: redis.Reply) -> str {
    let cmd = strings.to_upper(arg(req, 0));
    mutex_lock(f.mu);
    let out = "-ERR unknown\r\n";
    if cmd == "SET" {
        let k = arg(req, 1);
        if alive(f, k) { out = "$-1\r\n"; }
        else {
            f.vals[k] = arg(req, 2);
            f.exp[k] = (time.mono() as int) + ms(to_int(arg(req, 5)) ?? 0);
            out = "+OK\r\n";
        }
    } else if cmd == "INCR" {
        let k = arg(req, 1);
        let n = 1;
        if has(f.nums, k) { n = f.nums[k] + 1; }
        f.nums[k] = n;
        out = ":" + to_str(n) + "\r\n";
    } else if cmd == "EVAL" {
        let script = arg(req, 1);
        let k = arg(req, 3);
        let tok = arg(req, 4);
        if !alive(f, k) || f.vals[k] != tok {
            out = ":0\r\n";
        } else if strings.contains(script, "pexpire") {
            f.exp[k] = (time.mono() as int) + ms(to_int(arg(req, 5)) ?? 0);
            out = ":1\r\n";
        } else {
            del(f.vals, k);
            out = ":1\r\n";
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
            let _s = net.send(fd, to_bytes(handle(f, d.reply)));
            continue;
        }
        let rr = net.recv(fd, 4096);
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

fn fake_url() -> str {
    let a: map[str]str = {};
    let b: map[str]int = {};
    let c: map[str]int = {};
    let f = Fake { mu: make_mutex(), vals: a, exp: b, nums: c };
    let lfd = net.listen(0) ?? (-1 as i32);
    spawn accept_all(f, lfd);
    return "redis://127.0.0.1:" + to_str(net.port(lfd) ?? 0);
}

fn conn(url: str) -> redis.Conn {
    let cr = redis.connect(url, soon());
    guard let c = cr else let e = err_of(cr) { panic("connect: " + e); }
    return c;
}

fn test_should_give_a_lease_to_one_holder_at_a_time() {
    let url = fake_url();
    let a = conn(url);
    let b = conn(url);
    let la = redis_acquire(a, "job", 200, soon()) ?? none;
    guard let l = la else { panic("first acquire"); }
    assert(remaining_ms(l) > 100, "remaining");
    if let _x = redis_acquire(b, "job", 200, soon()) ?? none { panic("second holder"); }
    assert(redis_release(a, l, soon()) ?? false, "release");
    let lb = redis_acquire(b, "job", 200, soon()) ?? none;
    guard let l2 = lb else { panic("acquire after release"); }
    assert(l2.fence > l.fence, "fencing token did not grow");
}

fn test_should_refuse_to_renew_or_release_a_lost_lease() {
    let url = fake_url();
    let a = conn(url);
    let b = conn(url);
    let la = redis_acquire(a, "job", 30, soon()) ?? none;
    guard let l = la else { panic("acquire"); }
    time.sleep(ms(50));                      // it runs out
    let lb = redis_acquire(b, "job", 1000, soon()) ?? none;
    guard let other = lb else { panic("taken over after expiry"); }
    assert(!(redis_renew(a, l, 1000, soon()) ?? true), "renewed a lease someone else holds");
    assert(!(redis_release(a, l, soon()) ?? true), "released someone else's lease");
    assert(redis_renew(b, other, 1000, soon()) ?? false, "holder could not renew");
}

fn test_should_elect_one_leader_and_hand_over_on_resign() {
    let url = fake_url();
    let a = conn(url);
    let b = conn(url);
    let ea = elector("leader", 300);
    let eb = elector("leader", 300);
    assert(elect(ea, a, soon()) ?? false, "first elector should lead");
    assert(!(elect(eb, b, soon()) ?? true), "two leaders");
    assert(elect(ea, a, soon()) ?? false, "leader renewing lost the lease");
    assert(leading(ea) && fence(ea) > 0 && !leading(eb) && fence(eb) == 0, "leading/fence");
    resign(ea, a, soon());
    assert(!leading(ea), "still leading after resign");
    assert(elect(eb, b, soon()) ?? false, "no handover after resign");
    assert(fence(eb) > 0, "new leader fence");
}

fn test_should_hash_names_to_stable_lock_keys() {
    assert(key_of("jobs:nightly") == key_of("jobs:nightly"), "stable");
    assert(key_of("a") != key_of("b") && key_of("x") >= 0, "distinct, non-negative");
}
