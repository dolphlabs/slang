// Concurrent identical calls share one execution: while a call for a key
// is running, more calls for that key wait for its answer instead of
// running again. The cure for a cache stampede -- a popular key expires
// and a thousand requests all go to the database at once.
//
//     import "singleflight";
//
//     fn load_user(id: str, deadline: until) -> result[User, str] { ... }
//
//     let g = singleflight.group(load_user);     // one group per loader
//     let r = singleflight.call(g, "user:" + id, id, deadline);
//
// The first caller for a key runs f; the others get its result. A call
// that panics answers every waiter with an error rather than leaving them
// waiting. Waiters wait for the running call to finish, which ends at the
// first caller's deadline, not their own.

pub gc struct Flight[T] {
    done: chan[bool],
    v: opt[T],
    e: str,
    shared: int,
}

pub gc struct Group[A, T] {
    f: fn(A, until) -> result[T, str],
    mu: mutex,
    flights: map[str]Flight[T],
    runs: int,
    joins: int,
}

// A group whose calls run f.
pub fn group[A, T](f: fn(A, until) -> result[T, str]) -> Group[A, T] {
    let m: map[str]Flight[T] = {};
    return Group[A, T] { f: f, mu: make_mutex(), flights: m, runs: 0, joins: 0 };
}

// g's function on a, once per key at a time; concurrent calls for the
// key share its result.
pub fn call[A, T](g: Group[A, T], key: str, a: A, deadline: until)
                 -> result[T, str] {
    mutex_lock(g.mu);
    if has(g.flights, key) {
        let fl = g.flights[key];
        fl.shared = fl.shared + 1;
        g.joins = g.joins + 1;
        mutex_unlock(g.mu);
        let _closed = chan_recv(fl.done);   // none once closed: the answer is in
        return answer(fl);
    }
    let nothing: opt[T] = none;
    let fl = Flight[T] { done: make_chan(1), v: nothing, e: "", shared: 0 };
    g.flights[key] = fl;
    g.runs = g.runs + 1;
    mutex_unlock(g.mu);
    // In a task of its own, so a panic in f is an error here (join_wait)
    // and the waiters are still answered.
    let h = spawn run(g.f, a, deadline);
    let jr = join_wait(h);
    if let r = jr {
        if let v = r {
            fl.v = some(v);
        } else {
            fl.e = err_of(r);
        }
    } else let pe = err_of(jr) {
        fl.e = "singleflight: call panicked: " + pe;
    }
    mutex_lock(g.mu);
    del(g.flights, key);
    mutex_unlock(g.mu);
    chan_close(fl.done);
    return answer(fl);
}

// Makes the next call for key run anew, even while one is in flight
// (those already waiting still get the running call's answer).
pub fn forget[A, T](g: Group[A, T], key: str) {
    mutex_lock(g.mu);
    if has(g.flights, key) {
        del(g.flights, key);
    }
    mutex_unlock(g.mu);
}

// Calls that ran f, and calls that shared another's run.
pub fn runs[A, T](g: Group[A, T]) -> int {
    mutex_lock(g.mu);
    let n = g.runs;
    mutex_unlock(g.mu);
    return n;
}

pub fn joins[A, T](g: Group[A, T]) -> int {
    mutex_lock(g.mu);
    let n = g.joins;
    mutex_unlock(g.mu);
    return n;
}

fn run[A, T](f: fn(A, until) -> result[T, str], a: A, deadline: until) -> result[T, str] {
    return f(a, deadline);
}

fn answer[T](fl: Flight[T]) -> result[T, str] {
    if let v = fl.v {
        return ok(v);
    }
    return err(fl.e);
}
