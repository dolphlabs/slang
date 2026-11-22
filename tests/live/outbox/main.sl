import "idempotency";
import "outbox";
import "pg";
import "proc";
import "redis";
import "time";

// outbox against a real Postgres, idempotency against a real Redis. Not
// part of `make test`; CI runs it with PG_URL and REDIS_URL set. Each part
// runs only when its URL is set.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until { return until_of(time.mono() + 10000000000); }

fn publish_even(m: outbox.Message) -> bool {
    // publish ids that are even, "fail" odd ones
    return m.id % 2 == 0;
}

fn publish_all(m: outbox.Message) -> bool { return true; }

let purl = proc.getenv("PG_URL") ?? "";
if len(purl) > 0 {
    let cr = pg.connect(purl, soon());
    guard let c = cr else let e = err_of(cr) { die("pg connect: " + e); }
    let _d = pg.exec(c, "DROP TABLE IF EXISTS outbox", soon());
    let sr = pg.exec(c, outbox.schema(), soon());
    guard let _s = sr else let se = err_of(sr) { die("schema: " + se); }
    // an event in a rolled-back transaction never reaches the table
    let _b = pg.exec(c, "BEGIN", soon());
    let _a = outbox.add(c, "orders.created", b"rolled back", soon());
    let _r = pg.exec(c, "ROLLBACK", soon());
    let _b2 = pg.exec(c, "BEGIN", soon());
    for i in 0..4 { let _x = outbox.add(c, "orders.created", to_bytes("event " + to_str(i)), soon()); }
    let _c2 = pg.exec(c, "COMMIT", soon());
    if (outbox.pending(c, soon()) ?? -1) != 4 { die("pending after commit"); }
    let r1 = outbox.relay(c, 10, publish_even, soon());
    guard let n1 = r1 else let e1 = err_of(r1) { die("relay: " + e1); }
    if n1 != 2 || (outbox.pending(c, soon()) ?? -1) != 2 { die("half published: " + to_str(n1)); }
    // the failed ones are pushed back: not ready again at once
    if (outbox.relay(c, 10, publish_all, soon()) ?? -1) != 0 { die("retried at once"); }
    let _u = pg.exec(c, "UPDATE outbox SET available_at = now()", soon());
    if (outbox.relay(c, 10, publish_all, soon()) ?? -1) != 2 { die("retry"); }
    let _d2 = pg.exec(c, "DROP TABLE outbox", soon());
    pg.close(c);
    println("outbox: ok");
}

let rurl = proc.getenv("REDIS_URL") ?? "";
if len(rurl) > 0 {
    let cr = redis.connect(rurl, soon());
    guard let c = cr else let e = err_of(cr) { die("redis connect: " + e); }
    let key = "live-" + to_str(time.wall() as int);
    let br = idempotency.begin(c, key, "fp", 30000, soon());
    guard let b = br else let be = err_of(br) { die("begin: " + be); }
    if b.state != idempotency.NEW { die("first not NEW"); }
    let b2 = idempotency.begin(c, key, "fp", 30000, soon()) ?? b;
    if b2.state != idempotency.IN_PROGRESS { die("second not IN_PROGRESS"); }
    if !(idempotency.complete(c, key, b, b"resp", 60000, soon()) ?? false) { die("complete"); }
    let b3 = idempotency.begin(c, key, "fp", 30000, soon()) ?? b;
    if b3.state != idempotency.DONE || b3.response != b"resp" { die("replay"); }
    if (idempotency.begin(c, key, "other", 30000, soon()) ?? b).state != idempotency.MISMATCH { die("mismatch"); }
    let _d = redis.do(c, [to_bytes("DEL"), to_bytes("idem:" + key)], soon());
    println("idempotency: ok");
}
println("done");
