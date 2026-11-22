// Cancellation and deadlines that flow from a request through everything
// it starts: one timeout or one cancel stops all the work under it.
//
//     import "context";
//
//     let req = context.with_timeout(context.background(), 2000000000);  // 2 s
//     let db = context.with_cancel(req);         // a child: ends with req
//     let rr = net.recv_until(fd, 4096, context.deadline(db));
//     context.watch_fd(db, fd);                  // a cancel closes fd,
//                                                // waking a parked recv
//     context.cancel(req, "client went away");   // ends req and db
//     context.cause(db) ?? ""                    // "client went away"
//
// A context's deadline is the earliest of its own and its parents', and
// cancelling a context cancels every context made from it. Every slang
// API that can wait takes an `until`; pass it `context.deadline(c)`.
//
// What a deadline does on its own: operations given context.deadline(c)
// stop at it, and cause(c) reports "deadline exceeded" from then on. What
// cancel does on top: it closes the fds handed to watch_fd (a task parked
// on one wakes with "closed") and closes the done channel, so a `select`
// on done_chan(c) returns. There are no timers here: a deadline passing
// does not close watched fds -- the operations' own deadlines end them.
//
// Call cancel (or release) when a context's work is finished, as with
// Go's: until then a child stays in its parent's list.

import "net";
import "time";

pub gc struct Context {
    mu: mutex,
    cancelled: bool,
    reason: str,
    deadline_ns: int,          // absolute time.mono(); 0 for none
    parent: opt[Context],
    children: [Context],
    fds: [i32],
    done: opt[chan[bool]],
}

// The root: no deadline, never cancelled unless cancel is called on it.
pub fn background() -> Context {
    return Context {
        mu: make_mutex(), cancelled: false, reason: "", deadline_ns: 0,
        parent: none, children: [], fds: [], done: none
    };
}

// A child of parent that can be cancelled on its own.
pub fn with_cancel(parent: Context) -> Context {
    return child_of(parent, 0);
}

// A child of parent that ends ns nanoseconds from now (or at the
// parent's deadline, if that is sooner). ns <= 0 is already past.
pub fn with_timeout(parent: Context, ns: int) -> Context {
    let at = (time.mono() as int) + ns;
    if ns <= 0 {
        at = (time.mono() as int);
    }
    return child_of(parent, at);
}

// A child of parent that ends at mono_ns, an absolute time.mono() value.
pub fn with_deadline_at(parent: Context, mono_ns: int) -> Context {
    return child_of(parent, mono_ns);
}

// Cancels c and every context made from it, with reason as cause's text.
// The first cancel wins; later ones do nothing.
pub fn cancel(c: Context, reason: str) {
    mutex_lock(c.mu);
    if c.cancelled {
        mutex_unlock(c.mu);
        return;
    }
    c.cancelled = true;
    c.reason = reason;
    let kids = c.children;
    let fds = c.fds;
    let done = c.done;
    c.children = [];
    c.fds = [];
    let parent = c.parent;
    c.parent = none;
    mutex_unlock(c.mu);
    // No lock is held from here: a child takes its own, and so does the
    // parent, so two locks are never held at once.
    for fd in fds {
        net.close(fd);
    }
    if let ch = done {
        chan_close(ch);
    }
    for k in kids {
        cancel(k, reason);
    }
    if let p = parent {
        detach(p);
    }
}

// Cancel with the reason "released": for a context whose work finished.
pub fn release(c: Context) {
    cancel(c, "released");
}

// Whether c was cancelled or its deadline has passed.
pub fn is_done(c: Context) -> bool {
    if let _e = cause(c) {
        return true;
    }
    return false;
}

// Why c is done: the cancel reason, or "deadline exceeded"; none while
// it is live.
pub fn cause(c: Context) -> opt[str] {
    mutex_lock(c.mu);
    let cancelled = c.cancelled;
    let reason = c.reason;
    let dl = c.deadline_ns;
    mutex_unlock(c.mu);
    if cancelled {
        return some(reason);
    }
    if dl != 0 && (time.mono() as int) >= dl {
        return some("deadline exceeded");
    }
    return none;
}

// c's deadline as an `until` for any API that waits: never for a context
// without one, already passed for a cancelled one.
pub fn deadline(c: Context) -> until {
    mutex_lock(c.mu);
    let cancelled = c.cancelled;
    let dl = c.deadline_ns;
    mutex_unlock(c.mu);
    if cancelled {
        return until_of((time.mono() as int));
    }
    if dl == 0 {
        return until_never();
    }
    return until_of(dl);
}

// Nanoseconds until c's deadline (0 once passed or cancelled), or -1 for
// a context without one: for a timeout another protocol carries, such as
// a database statement timeout.
pub fn remaining(c: Context) -> int {
    mutex_lock(c.mu);
    let cancelled = c.cancelled;
    let dl = c.deadline_ns;
    mutex_unlock(c.mu);
    if cancelled {
        return 0;
    }
    if dl == 0 {
        return -1;
    }
    let left = dl - (time.mono() as int);
    if left < 0 {
        return 0;
    }
    return left;
}

// Closes fd when c is cancelled, waking any task parked on it with
// "closed". If c is already cancelled, closes it now. Call unwatch_fd
// before closing fd yourself, so a later cancel cannot close a reused fd
// number.
pub fn watch_fd(c: Context, fd: i32) {
    mutex_lock(c.mu);
    if c.cancelled {
        mutex_unlock(c.mu);
        net.close(fd);
        return;
    }
    push(c.fds, fd);
    mutex_unlock(c.mu);
}

// Stops watching fd. Returns false if c had already been cancelled (and
// fd closed by it).
pub fn unwatch_fd(c: Context, fd: i32) -> bool {
    mutex_lock(c.mu);
    let found = false;
    let kept: [i32] = [];
    for f in c.fds {
        if f == fd && !found {
            found = true;
        } else {
            push(kept, f);
        }
    }
    c.fds = kept;
    let cancelled = c.cancelled;
    mutex_unlock(c.mu);
    return found || !cancelled;
}

// A channel that is closed when c is cancelled, for a `select` that
// should also end on cancellation. Nothing is ever sent on it.
pub fn done_chan(c: Context) -> chan[bool] {
    mutex_lock(c.mu);
    if let ch = c.done {
        mutex_unlock(c.mu);
        return ch;
    }
    let ch: chan[bool] = make_chan(1);
    c.done = some(ch);
    let cancelled = c.cancelled;
    mutex_unlock(c.mu);
    if cancelled {
        chan_close(ch);
    }
    return ch;
}

// ---- internals -----------------------------------------------------------

fn child_of(parent: Context, own_deadline: int) -> Context {
    mutex_lock(parent.mu);
    let dl = parent.deadline_ns;
    if own_deadline != 0 && (dl == 0 || own_deadline < dl) {
        dl = own_deadline;
    }
    let k = Context {
        mu: make_mutex(), cancelled: parent.cancelled, reason: parent.reason,
        deadline_ns: dl, parent: none, children: [], fds: [], done: none
    };
    if !parent.cancelled {
        k.parent = some(parent);
        push(parent.children, k);
    }
    mutex_unlock(parent.mu);
    return k;
}

// Drops cancelled children from p's list -- the one being cancelled now
// among them, as it set its flag before calling this. Locks nest only
// parent then child, never the other way (cancel releases a child's lock
// before it comes here), so this cannot deadlock.
fn detach(p: Context) {
    mutex_lock(p.mu);
    let kept: [Context] = [];
    for k in p.children {
        mutex_lock(k.mu);
        let gone = k.cancelled;
        mutex_unlock(k.mu);
        if !gone {
            push(kept, k);
        }
    }
    p.children = kept;
    mutex_unlock(p.mu);
}
