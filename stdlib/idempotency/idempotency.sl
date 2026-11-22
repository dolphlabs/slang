// Idempotency keys (the Idempotency-Key header, IETF draft
// httpapi-idempotency-key): a retried request with the same key gets the
// first one's response instead of running twice -- one payment, however
// many times the client's network made it resend.
//
//     import "idempotency";
//
//     let br = idempotency.begin(conn, key, fingerprint, 30000, deadline);
//     guard let b = br else { /* 503 */ }
//     if b.state == idempotency.DONE { /* answer b.response again */ }
//     else if b.state == idempotency.IN_PROGRESS { /* 409: still running */ }
//     else if b.state == idempotency.MISMATCH { /* 422: key reused for another request */ }
//     else {  // NEW: this request runs
//         let resp = handle();
//         idempotency.complete(conn, key, b, resp, 86400000, deadline);  // keep a day
//     }
//
// The reservation is one atomic SET NX in Redis, so two copies of a request
// arriving together cannot both run. It expires after lock_ms if the
// process dies mid-request, so the key does not stay stuck; complete and
// abandon act only on the caller's own reservation. The fingerprint (say a
// hash of method, path and body) catches a key reused for a different
// request.

import "rand";
import "redis";
import "strings";
import "time";

pub let NEW = 0;
pub let IN_PROGRESS = 1;
pub let DONE = 2;
pub let MISMATCH = 3;

pub struct Begin {
    state: int,
    response: bytes,     // DONE: the stored response
    token: str,          // NEW: the reservation's owner token
    fingerprint: str,
}

let COMPLETE = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('set', KEYS[1], ARGV[2], 'PX', ARGV[3]) else return false end";
let ABANDON = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";

// Reserves key for this request, or reports what an earlier one did.
pub fn begin(c: redis.Conn, key: str, fingerprint: str, lock_ms: int, deadline: until)
            -> result[Begin, str] {
    if len(key) == 0 || len(key) > 255 { return err("idempotency: a key is 1 to 255 bytes"); }
    if strings.contains(fingerprint, ":") { return err("idempotency: a fingerprint cannot hold ':'"); }
    let rk = "idem:" + key;
    let token = new_token();
    let mine = "p:" + fingerprint + ":" + token;
    let sr = redis.do(c, [to_bytes("SET"), to_bytes(rk), to_bytes(mine), to_bytes("NX"),
                          to_bytes("PX"), to_bytes(to_str(lock_ms))], deadline);
    guard let s = sr else let e = err_of(sr) { return err("idempotency: " + e); }
    if s.text == "OK" {
        return ok(Begin { state: NEW, response: b"", token: mine, fingerprint: fingerprint });
    }
    let gr = redis.do(c, [to_bytes("GET"), to_bytes(rk)], deadline);
    guard let g = gr else let ge = err_of(gr) { return err("idempotency: " + ge); }
    guard let v = g.bulk else {
        // it expired between the SET and the GET: report it as running;
        // the client's retry will find it free
        return ok(Begin { state: IN_PROGRESS, response: b"", token: "", fingerprint: fingerprint });
    }
    // "p:<fp>:<token>" while running, "d:<fp>:<response>" once done
    let kind = to_str(v[0..2]);
    let rest = v[2..];
    let colon = find_colon(rest);
    if colon < 0 { return err("idempotency: unreadable stored state"); }
    let fp = to_str(rest[0..colon]);
    if fp != fingerprint {
        return ok(Begin { state: MISMATCH, response: b"", token: "", fingerprint: fp });
    }
    if kind == "d:" {
        return ok(Begin { state: DONE, response: rest[colon + 1..], token: "", fingerprint: fp });
    }
    return ok(Begin { state: IN_PROGRESS, response: b"", token: "", fingerprint: fp });
}

// Stores the response of a NEW request for keep_ms: false if the
// reservation was lost (it expired and another request took the key).
pub fn complete(c: redis.Conn, key: str, b: Begin, response: bytes, keep_ms: int,
                deadline: until) -> result[bool, str] {
    if b.state != NEW { return err("idempotency: complete on a request that did not begin NEW"); }
    let stored = to_bytes("d:" + b.fingerprint + ":") + response;
    let rr = redis.do(c, [to_bytes("EVAL"), to_bytes(COMPLETE), to_bytes("1"), to_bytes("idem:" + key),
                          to_bytes(b.token), stored, to_bytes(to_str(keep_ms))], deadline);
    guard let r = rr else let e = err_of(rr) { return err("idempotency: " + e); }
    return ok(r.text == "OK");
}

// Gives the key up after a failure that should let a retry run again.
pub fn abandon(c: redis.Conn, key: str, b: Begin, deadline: until) -> result[bool, str] {
    if b.state != NEW { return ok(false); }
    let rr = redis.do(c, [to_bytes("EVAL"), to_bytes(ABANDON), to_bytes("1"), to_bytes("idem:" + key),
                          to_bytes(b.token)], deadline);
    guard let r = rr else let e = err_of(rr) { return err("idempotency: " + e); }
    return ok(r.num == 1);
}

fn find_colon(b: bytes) -> int {
    for i in 0..len(b) {
        if (b[i] as int) == 58 { return i; }
    }
    return -1;
}

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
