// Leases and leader election: one process at a time holds a named lease,
// for running a scheduled job once across replicas, or one leader.
//
//     import "lease";
//     import "redis";
//
//     let e = lease.elector("jobs:nightly-report", 10000);      // 10 s lease
//     // every ~3 s:
//     let lr = lease.elect(e, conn, deadline);
//     if lr ?? false {
//         // the leader: pass lease.fence(e) along with writes it makes, so
//         // storage can refuse a stale leader's late writes
//     }
//
// Redis leases are `SET name token NX PX ttl`, renewed and released by
// scripts that check the token first, so a process can never renew or
// release a lease it lost. Each acquisition also takes a fencing token
// (INCR on name:fence) that only grows: a leader that paused past its
// lease (a GC stall, a slow disk) and wakes up still believing it leads
// carries an older fence than the real leader, and storage that checks
// fences refuses it. A lease is safe to act on only while
// remaining_ms(l) > 0, by this process's clock.
//
// Postgres leases are session advisory locks: held while the connection
// lives, released by pg_unlock or the connection closing. Use a
// connection of its own, never one from a pool.

import "pg";
import "rand";
import "redis";
import "strings";
import "time";

pub struct Lease {
    name: str,
    token: str,
    fence: int,
    expires_ns: int,     // time.mono() value the lease runs out at
}

// Milliseconds the lease is certainly still held for, by this process's
// clock (0 once it may have run out).
pub fn remaining_ms(l: Lease) -> int {
    let left = l.expires_ns - (time.mono() as int);
    if left <= 0 { return 0; }
    return left / 1000000;
}

// ---- Redis -----------------------------------------------------------------

let RENEW = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('pexpire', KEYS[1], ARGV[2]) else return 0 end";
let RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";

// Takes the lease name for ttl_ms if nobody holds it: some(lease), or
// none while another process does.
pub fn redis_acquire(c: redis.Conn, name: str, ttl_ms: int, deadline: until)
                    -> result[opt[Lease], str] {
    if ttl_ms <= 0 { return err("lease: ttl must be positive"); }
    let token = new_token();
    let start = time.mono() as int;
    let rr = redis.do(c, [to_bytes("SET"), to_bytes(name), to_bytes(token), to_bytes("NX"),
                          to_bytes("PX"), to_bytes(to_str(ttl_ms))], deadline);
    guard let r = rr else let e = err_of(rr) { return err("lease: " + e); }
    if r.text != "OK" {
        return ok(none);
    }
    let fr = redis.do(c, [to_bytes("INCR"), to_bytes(name + ":fence")], deadline);
    guard let f = fr else let fe = err_of(fr) { return err("lease: " + fe); }
    // measured from before the SET: the server's clock started no earlier
    return ok(some(Lease { name: name, token: token, fence: f.num,
                           expires_ns: start + ttl_ms * 1000000 }));
}

// Extends a held lease to ttl_ms from now: false if it was lost (it ran
// out and someone else took it, or it was released).
pub fn redis_renew(c: redis.Conn, l: Lease, ttl_ms: int, deadline: until) -> result[bool, str] {
    let start = time.mono() as int;
    let rr = redis.do(c, [to_bytes("EVAL"), to_bytes(RENEW), to_bytes("1"), to_bytes(l.name),
                          to_bytes(l.token), to_bytes(to_str(ttl_ms))], deadline);
    guard let r = rr else let e = err_of(rr) { return err("lease: " + e); }
    if r.num != 1 { return ok(false); }
    l.expires_ns = start + ttl_ms * 1000000;
    return ok(true);
}

// Gives the lease up: false if it was no longer ours.
pub fn redis_release(c: redis.Conn, l: Lease, deadline: until) -> result[bool, str] {
    let rr = redis.do(c, [to_bytes("EVAL"), to_bytes(RELEASE), to_bytes("1"), to_bytes(l.name),
                          to_bytes(l.token)], deadline);
    guard let r = rr else let e = err_of(rr) { return err("lease: " + e); }
    return ok(r.num == 1);
}

// ---- leader election (Redis) -----------------------------------------------

pub gc struct Elector {
    name: str,
    ttl_ms: int,
    held: opt[Lease],
}

pub fn elector(name: str, ttl_ms: int) -> Elector {
    return Elector { name: name, ttl_ms: ttl_ms, held: none };
}

// One round: renew the lease if this process leads, try to take it if
// not. Call every third of the ttl or so. Whether this process leads
// now; on an error it does not.
pub fn elect(e: Elector, c: redis.Conn, deadline: until) -> result[bool, str] {
    if let l = e.held {
        let rr = redis_renew(c, l, e.ttl_ms, deadline);
        guard let kept = rr else let re = err_of(rr) {
            e.held = none;
            return err(re);
        }
        if kept { return ok(true); }
        e.held = none;
    }
    let ar = redis_acquire(c, e.name, e.ttl_ms, deadline);
    guard let got = ar else let ae = err_of(ar) { return err(ae); }
    e.held = got;
    if let _l = got { return ok(true); }
    return ok(false);
}

// Whether this process led at its last round and the lease has not run
// out since.
pub fn leading(e: Elector) -> bool {
    if let l = e.held { return remaining_ms(l) > 0; }
    return false;
}

// The fencing token of the current lease (0 when not leading).
pub fn fence(e: Elector) -> int {
    if let l = e.held { return l.fence; }
    return 0;
}

// Stops leading and releases the lease, so another process can take over
// at once instead of after the ttl.
pub fn resign(e: Elector, c: redis.Conn, deadline: until) {
    if let l = e.held {
        let _r = redis_release(c, l, deadline);
    }
    e.held = none;
}

// ---- Postgres --------------------------------------------------------------

// A stable 63-bit lock key for a name (FNV-1a), for the advisory locks.
pub fn key_of(name: str) -> int {
    let h: u64 = 0xcbf29ce484222325;
    let b = to_bytes(name);
    for i in 0..len(b) {
        h = (h ^ ((b[i] as int) as u64)) * 0x100000001b3;
    }
    return (h >> 1) as int;
}

// Takes the session advisory lock for name without waiting: false while
// another session holds it.
pub fn pg_try_lock(c: pg.Conn, name: str, deadline: until) -> result[bool, str] {
    let rr = pg.query(c, "SELECT pg_try_advisory_lock($1)", [pg.arg_int(key_of(name))], deadline);
    guard let rows = rr else let e = err_of(rr) { return err("lease: " + e); }
    return ok(pg.get_bool(rows, 0, 0));
}

// Releases it: false if this session did not hold it.
pub fn pg_unlock(c: pg.Conn, name: str, deadline: until) -> result[bool, str] {
    let rr = pg.query(c, "SELECT pg_advisory_unlock($1)", [pg.arg_int(key_of(name))], deadline);
    guard let rows = rr else let e = err_of(rr) { return err("lease: " + e); }
    return ok(pg.get_bool(rows, 0, 0));
}

// ---- internals -------------------------------------------------------------

fn new_token() -> str {
    let r = rand.from_os() ?? rand.new(time.wall() as int);
    let hex = "0123456789abcdef";
    let out: [str] = [];
    for _ in 0..2 {
        let v = rand.next_u64(r);
        for i in 0..16 {
            let d = ((v >> (4 * i)) & (15 as u64)) as int;
            push(out, strings.slice(hex, d, d + 1));
        }
    }
    return strings.join(out, "");
}
