// Ways to fail well under load: a circuit breaker, a bulkhead, a retry
// budget and retry with backoff, rate limiters (token bucket, and keyed
// GCRA for per-client limits), and request hedging.
//
//     import "resilience";
//
//     let b = resilience.breaker(resilience.breaker_options());
//     if !resilience.allow(b) { return err("upstream unavailable"); }
//     let r = call_upstream(...);
//     let worked = false;
//     if let _v = r { worked = true; }
//     resilience.record(b, worked);
//
//     let lim = resilience.gcra(100.0, 20);    // 100/s per key, bursts of 20
//     let d = resilience.gcra_allow(lim, client_ip);
//     if !d.allowed { /* 429, Retry-After: d.retry_after_ns */ }
//
// Everything here is safe to share between tasks.

import "rand";
import "time";

fn now_ns() -> int { return time.mono() as int; }

// ---- circuit breaker -------------------------------------------------------

pub struct BreakerOptions {
    // Calls looked at: the last `window` outcomes.
    window: int,
    // No trip on fewer than this many calls in the window.
    min_calls: int,
    // Trip when the failed share of the window reaches this.
    failure_ratio: float,
    // Nanoseconds to stay open before letting probes through.
    open_ns: int,
    // Trial calls allowed at once while half-open; that many successes
    // in a row close the breaker, one failure opens it again.
    probes: int,
}

pub fn breaker_options() -> BreakerOptions {
    return BreakerOptions { window: 100, min_calls: 20, failure_ratio: 0.5,
                            open_ns: 5000000000, probes: 1 };
}

pub gc struct Breaker {
    o: BreakerOptions,
    mu: mutex,
    state: int,          // CLOSED, OPEN, HALF_OPEN
    ring: [bool],        // last outcomes, true = failure
    at: int,
    filled: int,
    failures: int,
    opened_at: int,
    trials: int,         // half-open calls let through and not yet recorded
    trial_ok: int,       // half-open successes so far
    trips: int,
}

let CLOSED = 0;
let OPEN = 1;
let HALF_OPEN = 2;

pub fn breaker(o: BreakerOptions) -> Breaker {
    let mo = o;
    if mo.window < 1 { mo.window = 1; }
    if mo.min_calls < 1 { mo.min_calls = 1; }
    if mo.probes < 1 { mo.probes = 1; }
    let ring: [bool] = [];
    for _ in 0..mo.window { push(ring, false); }
    return Breaker { o: mo, mu: make_mutex(), state: CLOSED, ring: ring, at: 0,
                     filled: 0, failures: 0, opened_at: 0, trials: 0,
                     trial_ok: 0, trips: 0 };
}

// Whether a call may go ahead. Every allowed call must be followed by
// record(b, ok) once it finishes.
pub fn allow(b: Breaker) -> bool {
    mutex_lock(b.mu);
    if b.state == OPEN {
        if now_ns() - b.opened_at < b.o.open_ns {
            mutex_unlock(b.mu);
            return false;
        }
        b.state = HALF_OPEN;
        b.trials = 0;
        b.trial_ok = 0;
    }
    if b.state == HALF_OPEN {
        if b.trials >= b.o.probes {
            mutex_unlock(b.mu);
            return false;
        }
        b.trials = b.trials + 1;
    }
    mutex_unlock(b.mu);
    return true;
}

// The outcome of a call allow let through.
pub fn record(b: Breaker, ok: bool) {
    mutex_lock(b.mu);
    if b.state == HALF_OPEN {
        if b.trials > 0 { b.trials = b.trials - 1; }
        if !ok {
            trip(b);
        } else {
            b.trial_ok = b.trial_ok + 1;
            if b.trial_ok >= b.o.probes {
                b.state = CLOSED;
                reset_window(b);
            }
        }
        mutex_unlock(b.mu);
        return;
    }
    if b.state == OPEN {
        // a call allowed before the trip, finishing after it
        mutex_unlock(b.mu);
        return;
    }
    if b.ring[b.at] && b.filled == b.o.window { b.failures = b.failures - 1; }
    b.ring[b.at] = !ok;
    if !ok { b.failures = b.failures + 1; }
    b.at = (b.at + 1) % b.o.window;
    if b.filled < b.o.window { b.filled = b.filled + 1; }
    if b.filled >= b.o.min_calls &&
       (b.failures as float) >= b.o.failure_ratio * (b.filled as float) {
        trip(b);
    }
    mutex_unlock(b.mu);
}

// "closed", "open" or "half-open".
pub fn breaker_state(b: Breaker) -> str {
    mutex_lock(b.mu);
    let s = b.state;
    if s == OPEN && now_ns() - b.opened_at >= b.o.open_ns { s = HALF_OPEN; }
    mutex_unlock(b.mu);
    if s == OPEN { return "open"; }
    if s == HALF_OPEN { return "half-open"; }
    return "closed";
}

// How many times the breaker has opened.
pub fn trips(b: Breaker) -> int {
    mutex_lock(b.mu);
    let n = b.trips;
    mutex_unlock(b.mu);
    return n;
}

fn trip(b: Breaker) {
    b.state = OPEN;
    b.opened_at = now_ns();
    b.trips = b.trips + 1;
    reset_window(b);
}

fn reset_window(b: Breaker) {
    for i in 0..b.o.window { b.ring[i] = false; }
    b.at = 0;
    b.filled = 0;
    b.failures = 0;
}

// ---- bulkhead --------------------------------------------------------------

// At most `limit` calls at once; the rest are turned away at once rather
// than queued, so one slow dependency cannot take every task with it.
pub gc struct Bulkhead {
    mu: mutex,
    limit: int,
    active: int,
    rejected: int,
}

pub fn bulkhead(limit: int) -> Bulkhead {
    let n = limit;
    if n < 1 { n = 1; }
    return Bulkhead { mu: make_mutex(), limit: n, active: 0, rejected: 0 };
}

// Takes a place if there is one. Every true must be followed by leave.
pub fn try_enter(b: Bulkhead) -> bool {
    mutex_lock(b.mu);
    if b.active >= b.limit {
        b.rejected = b.rejected + 1;
        mutex_unlock(b.mu);
        return false;
    }
    b.active = b.active + 1;
    mutex_unlock(b.mu);
    return true;
}

pub fn leave(b: Bulkhead) {
    mutex_lock(b.mu);
    if b.active > 0 { b.active = b.active - 1; }
    mutex_unlock(b.mu);
}

// Calls in progress, and calls turned away so far.
pub fn bulkhead_active(b: Bulkhead) -> int {
    mutex_lock(b.mu);
    let n = b.active;
    mutex_unlock(b.mu);
    return n;
}

pub fn bulkhead_rejected(b: Bulkhead) -> int {
    mutex_lock(b.mu);
    let n = b.rejected;
    mutex_unlock(b.mu);
    return n;
}

// ---- retry budget and retry -----------------------------------------------

// Retries as a share of requests (Finagle's and gRPC's budget): each
// request deposits `ratio` of a retry, each retry withdraws one, and
// `min_per_sec` retries a second are always allowed. During an outage
// retries cannot multiply the load beyond 1 + ratio.
pub gc struct RetryBudget {
    mu: mutex,
    // In thousandths of a retry, so ten deposits of 0.1 make exactly one
    // (in floats they make 0.9999999999999999, and the retry is refused).
    ratio_m: int,
    min_m_per_sec: int,
    tokens_m: int,
    cap_m: int,
    floor_m: int,         // the min_per_sec allowance
    last: int,
}

pub fn retry_budget(ratio: float, min_per_sec: int) -> RetryBudget {
    let r = ((ratio * 1000.0) + 0.5) as int;
    if r < 0 { r = 0; }
    let m = min_per_sec * 1000;
    if m < 0 { m = 0; }
    return RetryBudget { mu: make_mutex(), ratio_m: r, min_m_per_sec: m,
                         tokens_m: 0, cap_m: 100000 + r * 100, floor_m: m,
                         last: now_ns() };
}

// An original request (not a retry) was made.
pub fn deposit(b: RetryBudget) {
    mutex_lock(b.mu);
    b.tokens_m = b.tokens_m + b.ratio_m;
    if b.tokens_m > b.cap_m { b.tokens_m = b.cap_m; }
    mutex_unlock(b.mu);
}

// Whether a retry may go ahead; takes one from the budget if so.
pub fn can_retry(b: RetryBudget) -> bool {
    mutex_lock(b.mu);
    let now = now_ns();
    let dt = now - b.last;
    // the allowance accrues only in whole thousandths: leave the
    // remainder of the interval for next time instead of rounding it away
    let gained = (dt / 1000000) * b.min_m_per_sec / 1000;
    if gained > 0 || b.min_m_per_sec == 0 {
        b.last = now;
        b.floor_m = b.floor_m + gained;
        if b.floor_m > b.min_m_per_sec { b.floor_m = b.min_m_per_sec; }
    }
    if b.tokens_m >= 1000 {
        b.tokens_m = b.tokens_m - 1000;
        mutex_unlock(b.mu);
        return true;
    }
    if b.floor_m >= 1000 {
        b.floor_m = b.floor_m - 1000;
        mutex_unlock(b.mu);
        return true;
    }
    mutex_unlock(b.mu);
    return false;
}

pub struct RetryOptions {
    // Calls in all, the first included.
    attempts: int,
    // Backoff before retry n: a uniform draw from [0, min(cap, base * 2^n)]
    // (full jitter), in nanoseconds.
    base_ns: int,
    cap_ns: int,
}

pub fn retry_options() -> RetryOptions {
    return RetryOptions { attempts: 3, base_ns: 50000000, cap_ns: 2000000000 };
}

// Calls f(a, deadline) until it succeeds, the attempts run out, the
// budget refuses a retry, or the deadline passes. The last error is
// returned. budget may be shared by every
// caller of one dependency. Errors reported as "permanent: ..." by f are
// not retried.
pub fn retry[A, T](f: fn(A, until) -> result[T, str], a: A, o: RetryOptions,
                   budget: RetryBudget, r: rand.Rng, deadline: until)
                  -> result[T, str] {
    deposit(budget);
    let last = "retry: no attempts";
    let n = o.attempts;
    if n < 1 { n = 1; }
    for attempt in 0..n {
        if attempt > 0 {
            if !can_retry(budget) {
                return err(last);
            }
            time.sleep(rand.backoff(r, attempt - 1, o.base_ns, o.cap_ns));
            if until_hit(deadline) {
                return err(last);
            }
        }
        let res = f(a, deadline);
        if let v = res {
            return ok(v);
        }
        last = err_of(res);
        if starts(last, "permanent:") || until_hit(deadline) {
            return err(last);
        }
    }
    return err(last);
}

fn starts(s: str, p: str) -> bool {
    return len(s) >= len(p) && to_bytes(s)[0..len(p)] == to_bytes(p);
}

// ---- token bucket ----------------------------------------------------------

// rate tokens a second, holding at most burst: allow takes one.
pub gc struct TokenBucket {
    mu: mutex,
    rate: float,
    burst: float,
    tokens: float,
    last: int,
}

pub fn token_bucket(rate_per_sec: float, burst: int) -> TokenBucket {
    let b = burst as float;
    if b < 1.0 { b = 1.0; }
    return TokenBucket { mu: make_mutex(), rate: rate_per_sec, burst: b,
                         tokens: b, last: now_ns() };
}

pub fn take(tb: TokenBucket) -> bool {
    return take_n(tb, 1);
}

// Takes n tokens if there are that many; none otherwise.
pub fn take_n(tb: TokenBucket, n: int) -> bool {
    mutex_lock(tb.mu);
    refill(tb);
    let want = n as float;
    if tb.tokens >= want {
        tb.tokens = tb.tokens - want;
        mutex_unlock(tb.mu);
        return true;
    }
    mutex_unlock(tb.mu);
    return false;
}

// Nanoseconds until n tokens are there (0 if they are now; -1 if n is
// more than the bucket holds).
pub fn wait_ns(tb: TokenBucket, n: int) -> int {
    mutex_lock(tb.mu);
    refill(tb);
    let want = n as float;
    let have = tb.tokens;
    let rate = tb.rate;
    let burst = tb.burst;
    mutex_unlock(tb.mu);
    if want > burst || rate <= 0.0 { return -1; }
    if have >= want { return 0; }
    return (((want - have) / rate) * 1000000000.0) as int + 1;
}

fn refill(tb: TokenBucket) {
    let now = now_ns();
    let dt = ((now - tb.last) as float) / 1000000000.0;
    tb.last = now;
    tb.tokens = tb.tokens + dt * tb.rate;
    if tb.tokens > tb.burst { tb.tokens = tb.burst; }
}

// ---- keyed GCRA ------------------------------------------------------------

// The generic cell rate algorithm, per key: `rate` a second per key with
// bursts of `burst`, one int of state per key (its theoretical arrival
// time) -- the limiter Redis's redis-cell and many gateways use. Keys
// idle long enough to be full again are dropped as the map grows, so
// memory follows the keys active within one burst period.
pub gc struct Gcra {
    mu: mutex,
    interval: int,       // ns between requests at the steady rate
    tolerance: int,      // ns of burst on top
    tat: map[str]int,
    sweep_at: int,       // map size that triggers the next sweep
}

pub struct Decision {
    allowed: bool,
    // When refused, nanoseconds until a request for this key would pass.
    retry_after_ns: int,
    // Requests this key could still make right now.
    remaining: int,
}

pub fn gcra(rate_per_sec: float, burst: int) -> Gcra {
    let r = rate_per_sec;
    if r <= 0.0 { r = 1.0; }
    let iv = (1000000000.0 / r) as int;
    if iv < 1 { iv = 1; }
    let b = burst;
    if b < 1 { b = 1; }
    let m: map[str]int = {};
    return Gcra { mu: make_mutex(), interval: iv, tolerance: iv * (b - 1),
                  tat: m, sweep_at: 1024 };
}

pub fn gcra_allow(g: Gcra, key: str) -> Decision {
    let now = now_ns();
    mutex_lock(g.mu);
    let tat = now;
    if has(g.tat, key) && g.tat[key] > now { tat = g.tat[key]; }
    let allow_at = tat - g.tolerance;
    if now < allow_at {
        mutex_unlock(g.mu);
        return Decision { allowed: false, retry_after_ns: allow_at - now, remaining: 0 };
    }
    let next = tat + g.interval;
    g.tat[key] = next;
    if len(g.tat) >= g.sweep_at {
        sweep(g, now);
    }
    mutex_unlock(g.mu);
    // requests k more allowed now: next + (k - 1) * interval - tolerance <= now
    let room = now + g.tolerance - next;
    let left = 0;
    if room >= 0 { left = room / g.interval + 1; }
    return Decision { allowed: true, retry_after_ns: 0, remaining: left };
}

// Keys tracked now.
pub fn gcra_keys(g: Gcra) -> int {
    mutex_lock(g.mu);
    let n = len(g.tat);
    mutex_unlock(g.mu);
    return n;
}

// Drops keys whose bucket is full again (their state equals a new key's).
// Caller holds g.mu. The next sweep waits for the map to double from what
// is left, so sweeping costs O(1) per request on average.
fn sweep(g: Gcra, now: int) {
    let drop: [str] = [];
    for k, v in g.tat {
        if v <= now {
            push(drop, k);
        }
    }
    for k in drop {
        del(g.tat, k);
    }
    g.sweep_at = len(g.tat) * 2;
    if g.sweep_at < 1024 { g.sweep_at = 1024; }
}

// ---- hedging ---------------------------------------------------------------

struct Hedged[T] {
    timer: bool,
    v: opt[T],
    e: str,
}

fn hedge_run[A, T](f: fn(A, until) -> result[T, str], a: A, u: until,
                   ch: chan[Hedged[T]]) {
    let nothing: opt[T] = none;
    let r = f(a, u);
    if let v = r {
        chan_send(ch, Hedged[T] { timer: false, v: some(v), e: "" });
    } else let e = err_of(r) {
        chan_send(ch, Hedged[T] { timer: false, v: nothing, e: e });
    }
}

fn hedge_timer[T](delay: int, ch: chan[Hedged[T]]) {
    time.sleep(delay);
    let nothing: opt[T] = none;
    chan_send(ch, Hedged[T] { timer: true, v: nothing, e: "" });
}

// Calls f(a, deadline); if it has not answered within delay_ns, calls it
// again and takes whichever answers first with a success. Cuts tail
// latency for idempotent reads at the cost of at most one extra call.
// The slower call is not stopped: it runs to its end in the background
// and its answer is dropped.
pub fn hedge[A, T](f: fn(A, until) -> result[T, str], a: A, delay_ns: int,
                   deadline: until) -> result[T, str] {
    // room for every message that can arrive, so no sender ever parks
    let ch: chan[Hedged[T]] = make_chan(3);
    spawn hedge_run(f, a, deadline, ch);
    spawn hedge_timer(delay_ns, ch);
    let running = 1;
    let fired = false;
    let last = "hedge: no answer";
    while running > 0 || !fired {
        let m = chan_recv(ch);
        guard let msg = m else { break; }
        if msg.timer {
            fired = true;
            if running > 0 && !until_hit(deadline) {
                running = running + 1;
                spawn hedge_run(f, a, deadline, ch);
            }
            continue;
        }
        running = running - 1;
        if let v = msg.v {
            return ok(v);
        }
        last = msg.e;
        if running == 0 && fired {
            break;
        }
        if running == 0 && !fired {
            // the first call failed before the delay: no second call
            return err(last);
        }
    }
    return err(last);
}
