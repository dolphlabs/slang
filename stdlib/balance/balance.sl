// Client-side load balancing: pick a backend per request, spread load,
// steer away from slow ones, and stop sending to failing ones.
//
//     import "balance";
//
//     let lb = balance.new(["10.0.0.1:8080", "10.0.0.2:8080", "10.0.0.3:8080"],
//                          balance.P2C);
//     let pr = balance.pick(lb, "");
//     guard let p = pr else { return err("no backend up"); }
//     let t0 = time.mono();
//     let r = call(p.addr);
//     let worked = false;
//     if let _v = r { worked = true; }
//     balance.done(lb, p, worked, (time.mono() - t0) as int);
//
// Strategies:
//   ROUND_ROBIN  each backend in turn
//   RANDOM       uniformly at random
//   LEAST        the fewest requests in flight
//   P2C          power of two choices: two at random, the one with fewer
//                requests in flight, then the lower latency (an EWMA).
//                Nearly as good as LEAST at a fraction of the scanning,
//                and it does not herd every client onto the same backend.
//   HASH         the backend a key maps to (rendezvous hashing, so adding
//                or removing a backend moves only its share of keys); if
//                that one is ejected, the next in the key's order.
//
// A backend that fails `eject_after` times in a row is ejected for
// `eject_ns`, doubling for each ejection in a row up to `eject_max_ns`;
// the first success afterwards resets it.

import "math/shard";
import "rand";
import "time";

pub let ROUND_ROBIN = 0;
pub let RANDOM = 1;
pub let LEAST = 2;
pub let P2C = 3;
pub let HASH = 4;

pub struct Options {
    strategy: int,
    eject_after: int,      // consecutive failures; 0 never ejects
    eject_ns: int,
    eject_max_ns: int,
    // weight of the newest latency in the EWMA, from 0 to 1
    latency_weight: float,
}

pub fn options(strategy: int) -> Options {
    return Options { strategy: strategy, eject_after: 5, eject_ns: 10000000000,
                     eject_max_ns: 300000000000, latency_weight: 0.3 };
}

pub gc struct Backend {
    addr: str,
    in_flight: int,
    latency: float,        // EWMA, ns
    fails: int,            // consecutive
    ejections: int,        // in a row
    ejected_until: int,
    picks: int,
}

pub struct Pick {
    index: int,
    addr: str,
}

pub gc struct Balancer {
    o: Options,
    mu: mutex,
    backends: [Backend],
    next: int,
    rng: rand.Rng,
    hash: shard.Rendezvous,
}

pub fn new(addrs: [str], strategy: int) -> Balancer {
    return with_options(addrs, options(strategy));
}

pub fn with_options(addrs: [str], o: Options) -> Balancer {
    let seed = rand.new(time.wall() as int);
    let r = rand.from_os() ?? seed;
    let lb = Balancer { o: o, mu: make_mutex(), backends: [], next: 0, rng: r,
                        hash: shard.rendezvous(addrs) };
    set_backends(lb, addrs);
    return lb;
}

// Replaces the backend list (from service discovery, say). Backends
// that stay keep their state.
pub fn set_backends(lb: Balancer, addrs: [str]) {
    mutex_lock(lb.mu);
    let keep: [Backend] = [];
    for a in addrs {
        let found = false;
        for b in lb.backends {
            if b.addr == a { push(keep, b); found = true; break; }
        }
        if !found {
            push(keep, Backend { addr: a, in_flight: 0, latency: 0.0, fails: 0, ejections: 0,
                                 ejected_until: 0, picks: 0 });
        }
    }
    lb.backends = keep;
    lb.hash = shard.rendezvous(addrs);
    if lb.next >= len(keep) { lb.next = 0; }
    mutex_unlock(lb.mu);
}

// A backend for one request (key is used by HASH only). Report how it
// went with done. An error when every backend is ejected.
pub fn pick(lb: Balancer, key: str) -> result[Pick, str] {
    mutex_lock(lb.mu);
    let n = len(lb.backends);
    if n == 0 {
        mutex_unlock(lb.mu);
        return err("balance: no backends");
    }
    let now = time.mono() as int;
    let i = -1;
    let s = lb.o.strategy;
    if s == HASH {
        for c in lb.hash.pick_n_str(key, n) {
            if up(lb.backends[c], now) { i = c; break; }
        }
    } else if s == RANDOM {
        i = random_up(lb, now);
    } else if s == LEAST {
        for c in 0..n {
            let b = lb.backends[c];
            if up(b, now) && (i < 0 || b.in_flight < lb.backends[i].in_flight) { i = c; }
        }
    } else if s == P2C {
        let a = random_up(lb, now);
        let b = random_up(lb, now);
        i = better(lb, a, b);
    } else {
        for k in 0..n {
            let c = (lb.next + k) % n;
            if up(lb.backends[c], now) { i = c; lb.next = (c + 1) % n; break; }
        }
    }
    if i < 0 {
        mutex_unlock(lb.mu);
        return err("balance: every backend is ejected");
    }
    let b = lb.backends[i];
    b.in_flight = b.in_flight + 1;
    b.picks = b.picks + 1;
    mutex_unlock(lb.mu);
    return ok(Pick { index: i, addr: b.addr });
}

// Reports a pick's outcome and how long it took.
pub fn done(lb: Balancer, p: Pick, ok: bool, latency_ns: int) {
    mutex_lock(lb.mu);
    let found = -1;
    if p.index < len(lb.backends) && lb.backends[p.index].addr == p.addr {
        found = p.index;
    } else {
        // the list changed since the pick
        for c in 0..len(lb.backends) {
            if lb.backends[c].addr == p.addr { found = c; break; }
        }
    }
    if found < 0 {
        mutex_unlock(lb.mu);
        return;
    }
    let b = lb.backends[found];
    if b.in_flight > 0 { b.in_flight = b.in_flight - 1; }
    let w = lb.o.latency_weight;
    if b.latency == 0.0 { b.latency = latency_ns as float; }
    else { b.latency = w * (latency_ns as float) + (1.0 - w) * b.latency; }
    if ok {
        b.fails = 0;
        b.ejections = 0;
    } else {
        b.fails = b.fails + 1;
        if lb.o.eject_after > 0 && b.fails >= lb.o.eject_after {
            let wait = lb.o.eject_ns;
            for _ in 0..b.ejections {
                wait = wait * 2;
                if wait >= lb.o.eject_max_ns { wait = lb.o.eject_max_ns; break; }
            }
            b.ejected_until = (time.mono() as int) + wait;
            b.ejections = b.ejections + 1;
            b.fails = 0;
        }
    }
    mutex_unlock(lb.mu);
}

pub struct Status {
    addr: str,
    up: bool,
    in_flight: int,
    latency_ns: int,
    picks: int,
}

pub fn status(lb: Balancer) -> [Status] {
    mutex_lock(lb.mu);
    let now = time.mono() as int;
    let out: [Status] = [];
    for b in lb.backends {
        push(out, Status { addr: b.addr, up: up(b, now), in_flight: b.in_flight,
                           latency_ns: b.latency as int, picks: b.picks });
    }
    mutex_unlock(lb.mu);
    return out;
}

// ---- internals -----------------------------------------------------------

fn up(b: Backend, now: int) -> bool {
    return now >= b.ejected_until;
}

// A random backend that is up, or -1. Caller holds lb.mu.
fn random_up(lb: Balancer, now: int) -> int {
    let n = len(lb.backends);
    let start = rand.below(lb.rng, n);
    for k in 0..n {
        let c = (start + k) % n;
        if up(lb.backends[c], now) { return c; }
    }
    return -1;
}

// The better of two candidates for P2C: fewer in flight, then lower
// latency.
fn better(lb: Balancer, a: int, b: int) -> int {
    if a < 0 { return b; }
    if b < 0 { return a; }
    let x = lb.backends[a];
    let y = lb.backends[b];
    if x.in_flight != y.in_flight {
        if x.in_flight < y.in_flight { return a; }
        return b;
    }
    if y.latency < x.latency { return b; }
    return a;
}
