# resilience

> Package resilience.

Ways to fail well under load, each safe to share between tasks.

```slang
import "resilience";

let b = resilience.breaker(resilience.breaker_options());
if resilience.allow(b) {
    let r = call_upstream();
    let worked = false;
    if let _v = r { worked = true; }
    resilience.record(b, worked);
}

let per_ip = resilience.gcra(100.0, 20);        // 100/s per key, bursts of 20
let d = resilience.gcra_allow(per_ip, client_ip);
if !d.allowed { /* 429 with Retry-After from d.retry_after_ns */ }
```

- **Circuit breaker:** `breaker(o)`, `allow`, `record`. It opens when
  failures reach `failure_ratio` of the last `window` calls (once
  `min_calls` have been seen), refuses calls for `open_ns`, then lets
  `probes` trial calls through: that many successes close it, one failure
  opens it again. `breaker_state` and `trips` report it.
- **Bulkhead:** `bulkhead(limit)`, `try_enter`, `leave`. At most `limit`
  calls at once; the rest are turned away at once rather than queued.
- **Retry budget:** `retry_budget(ratio, min_per_sec)`. Each request
  `deposit`s `ratio` of a retry and each retry (`can_retry`) takes one,
  so retries cannot multiply the load in an outage.
- **Retry:** `retry(f, arg, options, budget, rng, deadline)` calls
  `f(arg, deadline)` with full-jitter backoff until it succeeds, the
  attempts run out, the budget refuses, or the deadline passes. An error
  starting with `"permanent:"` is not retried.
- **Token bucket:** `token_bucket(rate, burst)`, `take`, `take_n`,
  `wait_ns`.
- **Keyed GCRA:** `gcra(rate, burst)` and `gcra_allow(g, key)` give a
  `Decision` with `allowed`, `retry_after_ns` and `remaining`. State is
  one int per key; keys whose bucket is full again are dropped as the map
  grows, so memory follows the keys active within one burst period.
- **Hedging:** `hedge(f, arg, delay_ns, deadline)` calls `f` and, if it
  has not answered within `delay_ns`, calls it again and returns the
  first success. Use it for idempotent reads only. The slower call runs
  to its end in the background.

## API

### `struct BreakerOptions`

### `fn breaker_options() -> BreakerOptions`

### `gc struct Breaker`

### `fn breaker(o: BreakerOptions) -> Breaker`

### `fn allow(b: Breaker) -> bool`

Whether a call may go ahead. Every allowed call must be followed by record(b, ok) once it finishes.

### `fn record(b: Breaker, ok: bool)`

The outcome of a call allow let through.

### `fn breaker_state(b: Breaker) -> str`

"closed", "open" or "half-open".

### `fn trips(b: Breaker) -> int`

How many times the breaker has opened.

### `gc struct Bulkhead`

At most `limit` calls at once; the rest are turned away at once rather than queued, so one slow dependency cannot take every task with it.

### `fn bulkhead(limit: int) -> Bulkhead`

### `fn try_enter(b: Bulkhead) -> bool`

Takes a place if there is one. Every true must be followed by leave.

### `fn leave(b: Bulkhead)`

### `fn bulkhead_active(b: Bulkhead) -> int`

Calls in progress, and calls turned away so far.

### `fn bulkhead_rejected(b: Bulkhead) -> int`

### `gc struct RetryBudget`

Retries as a share of requests (Finagle's and gRPC's budget): each request deposits `ratio` of a retry, each retry withdraws one, and `min_per_sec` retries a second are always allowed. During an outage retries cannot multiply the load beyond 1 + ratio.

### `fn retry_budget(ratio: float, min_per_sec: int) -> RetryBudget`

### `fn deposit(b: RetryBudget)`

An original request (not a retry) was made.

### `fn can_retry(b: RetryBudget) -> bool`

Whether a retry may go ahead; takes one from the budget if so.

### `struct RetryOptions`

### `fn retry_options() -> RetryOptions`

### `fn retry[A, T](f: fn(A, until) -> result[T, str], a: A, o: RetryOptions, budget: RetryBudget, r: rand.Rng, deadline: until) -> result[T, str]`

Calls f(a, deadline) until it succeeds, the attempts run out, the budget refuses a retry, or the deadline passes. The last error is returned. budget may be shared by every caller of one dependency. Errors reported as "permanent: ..." by f are not retried.

### `gc struct TokenBucket`

rate tokens a second, holding at most burst: allow takes one.

### `fn token_bucket(rate_per_sec: float, burst: int) -> TokenBucket`

### `fn take(tb: TokenBucket) -> bool`

### `fn take_n(tb: TokenBucket, n: int) -> bool`

Takes n tokens if there are that many; none otherwise.

### `fn wait_ns(tb: TokenBucket, n: int) -> int`

Nanoseconds until n tokens are there (0 if they are now; -1 if n is more than the bucket holds).

### `gc struct Gcra`

The generic cell rate algorithm, per key: `rate` a second per key with bursts of `burst`, one int of state per key (its theoretical arrival time) -- the limiter Redis's redis-cell and many gateways use. Keys idle long enough to be full again are dropped as the map grows, so memory follows the keys active within one burst period.

### `struct Decision`

### `fn gcra(rate_per_sec: float, burst: int) -> Gcra`

### `fn gcra_allow(g: Gcra, key: str) -> Decision`

### `fn gcra_keys(g: Gcra) -> int`

Keys tracked now.

### `fn hedge[A, T](f: fn(A, until) -> result[T, str], a: A, delay_ns: int, deadline: until) -> result[T, str]`

Calls f(a, deadline); if it has not answered within delay_ns, calls it again and takes whichever answers first with a success. Cuts tail latency for idempotent reads at the cost of at most one extra call. The slower call is not stopped: it runs to its end in the background and its answer is dropped.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
