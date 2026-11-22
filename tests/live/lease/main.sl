import "lease";
import "pg";
import "proc";
import "redis";
import "time";

// lease against a REAL Redis and Postgres. Not part of `make test`; CI
// runs it beside tests/live/redis and tests/live/postgres, and locally:
//
//   redis-server --port 6390 --daemonize yes
//   REDIS_URL=redis://127.0.0.1:6390 ./slangc tests/live/lease/main.sl --run
//
// PG_URL, if set, adds the advisory-lock checks.

fn die(msg: str) {
    println("FAIL " + msg);
    exit(1);
}

fn soon() -> until { return until_of(time.mono() + 5000000000); }

fn rconn(url: str) -> redis.Conn {
    let cr = redis.connect(url, soon());
    guard let c = cr else let e = err_of(cr) { die("redis connect: " + e); panic(""); }
    return c;
}

let rurl = proc.getenv("REDIS_URL") ?? "";
if len(rurl) == 0 { die("REDIS_URL not set"); }
let a = rconn(rurl);
let b = rconn(rurl);
let name = "slang-lease-test:" + to_str(time.wall() as int);

let la = lease.redis_acquire(a, name, 300, soon());
guard let maybe = la else let e = err_of(la) { die("acquire: " + e); }
guard let l = maybe else { die("acquire: not granted"); }
if let _x = lease.redis_acquire(b, name, 300, soon()) ?? none { die("second holder"); }
if !(lease.redis_renew(a, l, 300, soon()) ?? false) { die("renew"); }
time.sleep(400000000);
let lb = lease.redis_acquire(b, name, 1000, soon()) ?? none;
guard let other = lb else { die("not taken over after expiry"); }
if lease.redis_renew(a, l, 1000, soon()) ?? true { die("stale holder renewed"); }
if lease.redis_release(a, l, soon()) ?? true { die("stale holder released"); }
if other.fence <= l.fence { die("fence did not grow"); }
if !(lease.redis_release(b, other, soon()) ?? false) { die("release"); }
let _d = redis.do(a, [to_bytes("DEL"), to_bytes(name + ":fence")], soon());
println("redis leases: ok");

let purl = proc.getenv("PG_URL") ?? "";
if len(purl) > 0 {
    let p1 = pg.connect(purl, soon()) ?? panic_conn();
    let p2 = pg.connect(purl, soon()) ?? panic_conn();
    if !(lease.pg_try_lock(p1, name, soon()) ?? false) { die("pg lock"); }
    if lease.pg_try_lock(p2, name, soon()) ?? true { die("pg lock held twice"); }
    if !(lease.pg_unlock(p1, name, soon()) ?? false) { die("pg unlock"); }
    if !(lease.pg_try_lock(p2, name, soon()) ?? false) { die("pg lock after unlock"); }
    pg.close(p2);
    pg.close(p1);
    println("postgres advisory locks: ok");
}
println("done");

fn panic_conn() -> pg.Conn {
    die("pg connect");
    panic("");
}
