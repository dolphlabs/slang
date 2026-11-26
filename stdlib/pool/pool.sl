// A bounded pool of connections (or any costly resource) shared by many
// tasks: the design of pg's and mysql's pools, for any client.
//
//     import "pool";
//
//     fn dial_redis(deadline: until) -> result[i32, str] { ... }
//     fn close_redis(fd: i32) { net.close(fd); }
//     fn alive(fd: i32) -> bool { return net.idle_alive(fd); }
//
//     let p = pool.new(pool.options(64), dial_redis, close_redis, alive);
//     guard let lease = pool.acquire(p, deadline) else |e| { ... }  // "timeout"
//     use(lease.v);
//     pool.release(p, lease);          // or pool.discard if it broke
//
// Waiting is first come, first served: a release hands its connection
// straight to the task that has waited longest, which wakes once, instead
// of every waiter polling and the luckiest winning -- in pg's pool that
// lottery was the p99. A freed slot (a connection closed or a dial that
// failed) is handed on the same way, for the waiter to dial.
//
// Connections are probed before reuse only after sitting idle for
// probe_after (1 s by default): one released moments ago is handed out
// as is, which under load is nearly every acquire.

import "time";

pub struct Options {
    // Connections open at once, idle and in use together.
    max_open: int,
    // Idle connections kept; more are closed on release. Default max_open.
    max_idle: int,
    // Nanoseconds an idle connection is kept before being closed rather
    // than reused. Default 5 minutes; 0 for no limit.
    idle_timeout: int,
    // Nanoseconds a connection lives at most, idle or not: it is closed
    // at the first release after that. Default 0, no limit. Useful behind
    // a balancer, so new connections spread to new backends.
    max_lifetime: int,
    // Nanoseconds idle after which a connection is probed before reuse.
    // Default 1 second; 0 probes every reuse.
    probe_after: int,
}

// Options with the defaults above for a pool of max_open connections.
pub fn options(max_open: int) -> Options {
    return Options { max_open: max_open, max_idle: max_open,
                     idle_timeout: 300000000000, max_lifetime: 0,
                     probe_after: 1000000000 };
}

// One connection, on loan from acquire until release or discard.
pub gc struct Lease[T] {
    v: T,
    born: int,
    since: int,       // when it went idle (meaningful while in the pool)
    in_pool: bool,
}

pub struct Stats {
    open: int,        // connections open now, idle and in use
    idle: int,        // of them, idle
    waiting: int,     // tasks waiting in acquire now
    dials: int,       // connections dialled, ever
    reuses: int,      // acquisitions served by an existing connection
    waits: int,       // acquisitions that had to wait
    wait_ns: int,     // their total wait
    max_wait_ns: int, // the longest
    timeouts: int,    // acquisitions that hit their deadline waiting
}

// A task parked in acquire, in arrival order in Pool.waiters.
gc struct Waiter[T] {
    wake: chan[int],
    deadline: until,
    got: int,
    lease: opt[Lease[T]],
}

pub gc struct Pool[T] {
    o: Options,
    dial: fn(until) -> result[T, str],
    close: fn(T),
    probe: fn(T) -> bool,
    lock: mutex,
    idle: [Lease[T]],
    open: int,
    closed: bool,
    waiters: [Waiter[T]],
    whead: int,
    // Waiters done with, reused by the next wait: a wait lasts as long as
    // the queue ahead of it, long enough for a fresh one to be promoted
    // and become old garbage (3.8 MB of RSS in pg at 512 tasks on 64).
    spare: [Waiter[T]],
    reaping: bool,
    st: Stats,
}

// A pool that opens nothing until the first acquire. dial makes a
// connection by a deadline, close ends one, probe says whether an idle
// one still works (one cheap check, such as net.idle_alive).
pub fn new[T](o: Options, dial: fn(until) -> result[T, str], close: fn(T),
              probe: fn(T) -> bool) -> Pool[T] {
    let mo = o;
    if mo.max_open < 1 { mo.max_open = 1; }
    if mo.max_idle < 0 || mo.max_idle > mo.max_open { mo.max_idle = mo.max_open; }
    let idle: [Lease[T]] = [];
    let waiters: [Waiter[T]] = [];
    let spare: [Waiter[T]] = [];
    return Pool[T] {
        o: mo, dial: dial, close: close, probe: probe, lock: make_mutex(),
        idle: idle, open: 0, closed: false, waiters: waiters, whead: 0,
        spare: spare, reaping: false,
        st: Stats { open: 0, idle: 0, waiting: 0, dials: 0, reuses: 0,
                    waits: 0, wait_ns: 0, max_wait_ns: 0, timeouts: 0 }
    };
}

// A connection for the caller's use until release or discard: an idle
// one, a new one if fewer than max_open are open, or else the next one
// released, in arrival order. "timeout" if deadline passes first, "pool
// is closed" after close.
pub fn acquire[T](p: Pool[T], deadline: until) -> result[Lease[T], str] {
    mutex_lock(p.lock);
    if p.closed {
        mutex_unlock(p.lock);
        return err("pool is closed");
    }
    while len(p.idle) > 0 {
        // Off the idle list under the lock, probed after it: a probe is a
        // syscall, and every acquire and release queues behind the lock.
        let l = pop(p.idle);
        p.st.reuses = p.st.reuses + 1;
        mutex_unlock(p.lock);
        if reusable(p, l) {
            l.in_pool = false;
            return ok(l);
        }
        p.close(l.v);
        mutex_lock(p.lock);
        p.st.reuses = p.st.reuses - 1;
        p.open = p.open - 1;
        if p.closed {
            mutex_unlock(p.lock);
            return err("pool is closed");
        }
        pass_slot(p);
    }
    if p.open < p.o.max_open {
        p.open = p.open + 1;
        p.st.dials = p.st.dials + 1;
        mutex_unlock(p.lock);
        return dial_slot(p, deadline);
    }
    if until_hit(deadline) {
        p.st.timeouts = p.st.timeouts + 1;
        mutex_unlock(p.lock);
        return err("timeout");
    }
    let w = waiter(p, deadline);
    push(p.waiters, w);
    if !p.reaping {
        p.reaping = true;
        spawn reap(p);
    }
    mutex_unlock(p.lock);
    let t0 = time.mono() as int;
    // Exactly one grant is sent; its outcome was set under the lock
    // before the send, so w is settled once this returns.
    let _woke = chan_recv(w.wake);
    let waited = (time.mono() as int) - t0;
    let got = w.got;
    let granted = w.lease;
    let nothing: opt[Lease[T]] = none;
    w.lease = nothing;
    mutex_lock(p.lock);
    push(p.spare, w);
    p.st.waits = p.st.waits + 1;
    p.st.wait_ns = p.st.wait_ns + waited;
    if waited > p.st.max_wait_ns { p.st.max_wait_ns = waited; }
    if got == GOT_TIMEOUT { p.st.timeouts = p.st.timeouts + 1; }
    mutex_unlock(p.lock);
    if got == GOT_CONN {
        guard let l = granted else { return err("pool: granted nothing"); }
        return ok(l);
    }
    if got == GOT_DIAL {
        return dial_slot(p, deadline);
    }
    if got == GOT_CLOSED {
        return err("pool is closed");
    }
    return err("timeout");
}

// Gives a connection back: to the task that has waited longest, else to
// the idle list. Closed instead once past max_lifetime, beyond max_idle,
// or after close. Releasing a lease twice panics: two tasks would then
// share one connection.
pub fn release[T](p: Pool[T], l: Lease[T]) {
    if l.in_pool {
        panic("pool.release: lease released twice");
    }
    let now = time.mono() as int;
    let expired = p.o.max_lifetime > 0 && now - l.born >= p.o.max_lifetime;
    mutex_lock(p.lock);
    if p.closed || expired {
        retire(p, l);
        return;
    }
    if p.whead < len(p.waiters) {
        // Settled under the lock, woken after it: the wake is the slowest
        // step, and every other acquire and release would queue behind it.
        let w = pop_waiter(p);
        w.lease = some(l);
        w.got = GOT_CONN;
        p.st.reuses = p.st.reuses + 1;
        mutex_unlock(p.lock);
        chan_send(w.wake, 1);
        return;
    }
    if len(p.idle) >= p.o.max_idle {
        retire(p, l);
        return;
    }
    l.in_pool = true;
    l.since = now;
    push(p.idle, l);
    mutex_unlock(p.lock);
}

// Closes a connection the caller found broken, freeing its slot for the
// next waiter to dial.
pub fn discard[T](p: Pool[T], l: Lease[T]) {
    if l.in_pool {
        panic("pool.discard: lease already released");
    }
    l.in_pool = true;
    mutex_lock(p.lock);
    p.open = p.open - 1;
    if !p.closed {
        pass_slot(p);
    }
    mutex_unlock(p.lock);
    p.close(l.v);
}

// Closes every idle connection and fails every waiting acquire;
// connections in use are closed as they come back. acquire fails from
// now on.
pub fn close[T](p: Pool[T]) {
    mutex_lock(p.lock);
    p.closed = true;
    let idle = p.idle;
    let none_idle: [Lease[T]] = [];
    p.idle = none_idle;
    p.open = p.open - len(idle);
    while p.whead < len(p.waiters) {
        grant(pop_waiter(p), GOT_CLOSED);
    }
    mutex_unlock(p.lock);
    for l in idle {
        p.close(l.v);
    }
}

// A snapshot of the counters.
pub fn stats[T](p: Pool[T]) -> Stats {
    mutex_lock(p.lock);
    let s = p.st;
    s.open = p.open;
    s.idle = len(p.idle);
    s.waiting = len(p.waiters) - p.whead;
    mutex_unlock(p.lock);
    return s;
}

// ---- internals -----------------------------------------------------------

let GOT_NONE = 0;
let GOT_CONN = 1;     // a released connection, in Waiter.lease
let GOT_DIAL = 2;     // a free slot, already counted in Pool.open
let GOT_TIMEOUT = 3;
let GOT_CLOSED = 4;
// How often the reaper looks for waiters past their deadline.
let REAP_NS = 5000000;

fn waiter[T](p: Pool[T], deadline: until) -> Waiter[T] {
    if len(p.spare) > 0 {
        let w = pop(p.spare);
        w.deadline = deadline;
        w.got = GOT_NONE;
        return w;
    }
    let nothing: opt[Lease[T]] = none;
    return Waiter[T] { wake: make_chan(1), deadline: deadline, got: GOT_NONE,
                       lease: nothing };
}

// The oldest waiter, removed. Caller holds p.lock and has checked one is
// waiting.
fn pop_waiter[T](p: Pool[T]) -> Waiter[T] {
    let w = p.waiters[p.whead];
    p.whead = p.whead + 1;
    if p.whead == len(p.waiters) {
        let empty: [Waiter[T]] = [];
        p.waiters = empty;
        p.whead = 0;
    } else if p.whead >= 64 && p.whead * 2 >= len(p.waiters) {
        // Under steady contention the queue may never empty: drop the
        // served prefix once it is half the list.
        p.waiters = p.waiters[p.whead..];
        p.whead = 0;
    }
    return w;
}

// Caller holds p.lock; the wake channel has room for this one send.
fn grant[T](w: Waiter[T], got: int) {
    w.got = got;
    chan_send(w.wake, 1);
}

// A slot was freed: the oldest waiter, if any, gets it to dial. Caller
// holds p.lock.
fn pass_slot[T](p: Pool[T]) {
    if p.whead < len(p.waiters) && p.open < p.o.max_open {
        p.open = p.open + 1;
        p.st.dials = p.st.dials + 1;
        grant(pop_waiter(p), GOT_DIAL);
    }
}

// Closes l and frees its slot. Caller holds p.lock, which this releases.
fn retire[T](p: Pool[T], l: Lease[T]) {
    l.in_pool = true;
    p.open = p.open - 1;
    if !p.closed {
        pass_slot(p);
    }
    mutex_unlock(p.lock);
    p.close(l.v);
}

// Dials the slot the caller has already counted in p.open.
fn dial_slot[T](p: Pool[T], deadline: until) -> result[Lease[T], str] {
    let dr = p.dial(deadline);
    guard let v = dr else let e = err_of(dr) {
        mutex_lock(p.lock);
        p.open = p.open - 1;
        pass_slot(p);
        mutex_unlock(p.lock);
        return err(e);
    }
    let now = time.mono() as int;
    return ok(Lease[T] { v: v, born: now, since: now, in_pool: false });
}

// Whether an idle connection can be handed out. Called without p.lock,
// on a lease the caller has taken off the idle list.
fn reusable[T](p: Pool[T], l: Lease[T]) -> bool {
    let now = time.mono() as int;
    let idle_for = now - l.since;
    if p.o.idle_timeout > 0 && idle_for > p.o.idle_timeout {
        return false;
    }
    if p.o.max_lifetime > 0 && now - l.born >= p.o.max_lifetime {
        return false;
    }
    if idle_for < p.o.probe_after {
        return true;
    }
    return p.probe(l.v);
}

// Times waiters out at their deadlines while any are waiting: one task
// per pool, started by the first waiter and gone once the queue empties
// (select has no timeout arm).
fn reap[T](p: Pool[T]) {
    while true {
        time.sleep(REAP_NS);
        mutex_lock(p.lock);
        let expired = false;
        let i = p.whead;
        while i < len(p.waiters) {
            if until_hit(p.waiters[i].deadline) {
                expired = true;
                break;
            }
            i = i + 1;
        }
        if expired {
            let keep: [Waiter[T]] = [];
            i = p.whead;
            while i < len(p.waiters) {
                let w = p.waiters[i];
                if until_hit(w.deadline) {
                    grant(w, GOT_TIMEOUT);
                } else {
                    push(keep, w);
                }
                i = i + 1;
            }
            p.waiters = keep;
            p.whead = 0;
        }
        if p.whead == len(p.waiters) {
            p.reaping = false;
            mutex_unlock(p.lock);
            return;
        }
        mutex_unlock(p.lock);
    }
}
