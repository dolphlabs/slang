// The connection pool: the same design as pg's (see stdlib/pg), over
// mysql connections.

import "net";
import "time";

let POOL_REAP = 2000000;
let GOT_NONE = 0;
let GOT_CONN = 1;
let GOT_DIAL = 2;
let GOT_TIMEOUT = 3;
let GOT_CLOSED = 4;

// ---- pool ------------------------------------------------------------

gc struct Idle {
    c: Conn,
    since: duration,
}

// A task parked in acquire, in arrival order in Pool.waiters.
gc struct Waiter {
    wake: chan[int],
    deadline: until,
    got: int,
    c: opt[Conn],
}

// A bounded set of connections to one database, shared by any number of
// tasks.
pub gc struct Pool {
    cfg: Config,
    // Connections open at once, idle and in use together. A task that
    // needs one when all are in use waits for a release.
    max_open: int,
    // Nanoseconds a connection may sit idle before it is closed instead
    // of reused. Default 5 minutes.
    idle_timeout: int,
    idle: [Idle],
    open: int,
    lock: mutex,
    closed: bool,
    // Tasks waiting for a connection, oldest first from waiters[whead].
    // A release hands its connection straight to the oldest, so a
    // waiter is served in order and wakes once, instead of every waiter
    // polling and the luckiest winning: at 512 tasks on 64 connections
    // the poll was a lottery, and the losers' wait was the p99.
    waiters: [Waiter],
    whead: int,
    // Waiters done with, for the next wait to reuse. A wait lasts as
    // long as the queue ahead of it -- long enough for its Waiter and
    // channel to be promoted -- so a fresh pair per wait was old garbage
    // at the release rate: 3.8 MB more RSS at 512 tasks on 64
    // connections. Never more than the most tasks that waited at once.
    spare: [Waiter],
    // A reaper task is running: it times waiters out at their deadlines
    // and exits when none are left.
    reaping: bool,
    // Connections dialled, and acquisitions served by an idle one.
    dials: int,
    reuses: int,
}

// Parses the url; connects nothing until the first acquire.
pub fn new_pool(url: str, max_open: int) -> result[Pool, str] {
    let cr = parse_url(url);
    guard let cfg = cr else let e = err_of(cr) {
        return err(e);
    }
    if max_open < 1 {
        return err("max_open must be at least 1");
    }
    let idle: [Idle] = [];
    let waiters: [Waiter] = [];
    let spare: [Waiter] = [];
    return ok(Pool { cfg: cfg, max_open: max_open, idle_timeout: 300000000000,
                     idle: idle, open: 0, lock: make_mutex(), closed: false,
                     waiters: waiters, whead: 0, spare: spare, reaping: false,
                     dials: 0, reuses: 0 });
}

// A waiter for this wait: a spare one if any, its channel empty (its one
// send was received before it was put back). Caller holds p.lock.
fn waiter(p: Pool, deadline: until) -> Waiter {
    if len(p.spare) > 0 {
        let w = pop(p.spare);
        w.deadline = deadline;
        w.got = GOT_NONE;
        return w;
    }
    let nothing: opt[Conn] = none;
    return Waiter { wake: make_chan(1), deadline: deadline, got: GOT_NONE,
                    c: nothing };
}

// The oldest waiter, removed from the queue. Caller holds p.lock and has
// checked p.whead < len(p.waiters).
fn pop_waiter(p: Pool) -> Waiter {
    let w = p.waiters[p.whead];
    p.whead = p.whead + 1;
    if p.whead == len(p.waiters) {
        let none_waiting: [Waiter] = [];
        p.waiters = none_waiting;
        p.whead = 0;
    } else if p.whead >= 64 && p.whead * 2 >= len(p.waiters) {
        // Under steady contention the queue may never empty: drop the
        // served prefix once it is half the list, so it stays bounded
        // by the waiters actually waiting.
        p.waiters = p.waiters[p.whead..];
        p.whead = 0;
    }
    return w;
}

// Grants w its outcome and wakes it. Caller holds p.lock; the wake
// channel has room for this one send, so it never parks.
fn grant(w: Waiter, got: int) {
    w.got = got;
    chan_send(w.wake, 1);
}

// A slot was freed (a connection closed, or a dial failed): if a task is
// waiting, the slot is its to dial. Caller holds p.lock.
fn pass_slot(p: Pool) {
    if p.whead < len(p.waiters) && p.open < p.max_open {
        p.open = p.open + 1;
        p.dials = p.dials + 1;
        grant(pop_waiter(p), GOT_DIAL);
    }
}

// Dials the slot the caller has already counted in p.open.
fn dial(p: Pool, deadline: until) -> result[Conn, str] {
    let cr = connect_config(p.cfg, deadline);
    guard let c = cr else let e = err_of(cr) {
        mutex_lock(p.lock);
        p.open = p.open - 1;
        pass_slot(p);
        mutex_unlock(p.lock);
        return err(e);
    }
    return ok(c);
}

// Times waiters out at their deadlines while any are waiting. One task
// per pool, started by the first waiter and gone once the queue empties:
// select has no timeout arm, and a timer task per waiter would leave one
// sleeping until every served waiter's deadline.
fn reap(p: Pool) {
    while true {
        time.sleep(POOL_REAP);
        mutex_lock(p.lock);
        let expired = 0;
        let i = p.whead;
        while i < len(p.waiters) {
            if until_hit(p.waiters[i].deadline) {
                expired = expired + 1;
            }
            i = i + 1;
        }
        if expired > 0 {
            let keep: [Waiter] = [];
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

// A connection for the caller's exclusive use, until release(). Prefer
// pool_query / pool_exec, which cannot forget to release; acquire is for
// a transaction, which needs several statements on one connection.
pub fn acquire(p: Pool, deadline: until) -> result[Conn, str] {
    mutex_lock(p.lock);
    if p.closed {
        mutex_unlock(p.lock);
        return err("pool is closed");
    }
    let now = time.mono();
    while len(p.idle) > 0 {
        let it = pop(p.idle);
        // Probed before reuse: the server closes idle sessions on
        // timers of its own (wait_timeout, a proxy's), and a
        // query written onto a closed connection fails in a way that
        // cannot be told from the query itself failing.
        let alive = false;
        if it.c.ssl != nullptr {
            alive = net.tls_idle_alive(it.c.ssl);
        } else if it.c.fd >= 0 {
            alive = net.idle_alive(it.c.fd);
        }
        if now - it.since > p.idle_timeout || !alive || !usable(it.c) {
            p.open = p.open - 1;
            close(it.c);
            continue;
        }
        p.reuses = p.reuses + 1;
        it.c.in_pool = false;
        mutex_unlock(p.lock);
        return ok(it.c);
    }
    if p.open < p.max_open {
        p.open = p.open + 1;
        p.dials = p.dials + 1;
        mutex_unlock(p.lock);
        return dial(p, deadline);
    }
    if until_hit(deadline) {
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
    // Exactly one grant is sent; it was made under the lock before the
    // send, so w is settled once this returns.
    chan_recv(w.wake);
    let got = w.got;
    let granted = w.c;
    let nothing: opt[Conn] = none;
    w.c = nothing;
    mutex_lock(p.lock);
    push(p.spare, w);
    mutex_unlock(p.lock);
    if got == GOT_CONN {
        guard let c = granted else {
            return err("pool: granted no connection");
        }
        return ok(c);
    }
    if got == GOT_DIAL {
        return dial(p, deadline);
    }
    if got == GOT_CLOSED {
        return err("pool is closed");
    }
    return err("timeout");
}

// Returns a connection to the pool: to the oldest waiting task if there
// is one, else to the idle list. One that is broken, closed, or still
// inside a transaction is closed instead, and its slot passed on:
// handing an open transaction to the next caller would run its
// statements inside someone else's uncommitted work.
pub fn release(p: Pool, c: Conn) {
    if c.in_pool {
        panic("mysql.release: connection released twice");
    }
    let reusable = usable(c) && !in_transaction(c) && c.mode == 0;
    mutex_lock(p.lock);
    if p.closed || !reusable {
        p.open = p.open - 1;
        if !p.closed {
            pass_slot(p);
        }
        mutex_unlock(p.lock);
        close(c);
        return;
    }
    if p.whead < len(p.waiters) {
        let w = pop_waiter(p);
        w.c = some(c);
        p.reuses = p.reuses + 1;
        grant(w, GOT_CONN);
        mutex_unlock(p.lock);
        return;
    }
    c.in_pool = true;
    push(p.idle, Idle { c: c, since: time.mono() });
    mutex_unlock(p.lock);
}

pub fn pool_query(p: Pool, sql: str, args: [Arg], deadline: until)
                  -> result[Rows, str] {
    let ar = acquire(p, deadline);
    guard let c = ar else let e = err_of(ar) {
        return err(e);
    }
    let r = query(c, sql, args, deadline);
    release(p, c);
    return r;
}

pub fn pool_exec(p: Pool, sql: str, deadline: until) -> result[int, str] {
    let ar = acquire(p, deadline);
    guard let c = ar else let e = err_of(ar) {
        return err(e);
    }
    let r = exec(c, sql, deadline);
    release(p, c);
    return r;
}

// Closes every idle connection and fails every waiting acquire.
// Connections in use are closed as they are released; acquire fails from
// now on.
pub fn pool_close(p: Pool) {
    mutex_lock(p.lock);
    p.closed = true;
    for it in p.idle {
        p.open = p.open - 1;
        close(it.c);
    }
    let none_idle: [Idle] = [];
    p.idle = none_idle;
    while p.whead < len(p.waiters) {
        grant(pop_waiter(p), GOT_CLOSED);
    }
    mutex_unlock(p.lock);
}
