# pool

> Package pool.

A bounded pool of connections (or any costly resource) shared by many
tasks, for clients that have no pool of their own. It is the design of
`pg`'s and `mysql`'s pools, made generic over the connection type.

```slang
import "net";
import "pool";

fn dial_cache(deadline: until) -> result[i32, str] {
    return net.dial_until("cache.internal", 11211, deadline);
}
fn close_cache(fd: i32) { net.close(fd); }
fn alive(fd: i32) -> bool { return net.idle_alive(fd); }

let p = pool.new(pool.options(64), dial_cache, close_cache, alive);
let lr = pool.acquire(p, deadline);
guard let lease = lr else let e = err_of(lr) { return; }   // "timeout"
let _s = net.send(lease.v, b"version\r\n");
pool.release(p, lease);        // pool.discard(p, lease) if it broke
```

- `acquire` hands out an idle connection, dials one while fewer than
  `max_open` are open, or waits. Waiting is first come, first served: a
  release goes straight to the task that has waited longest, which wakes
  once, so the slowest waiter's latency is its place in the queue.
- An idle connection is probed (the `probe` function) before reuse only
  after `probe_after` idle, 1 s by default; one released moments ago is
  handed out as is.
- `options(max_open)` also sets `max_idle` (default `max_open`),
  `idle_timeout` (5 minutes), `max_lifetime` (none; set it behind a
  balancer so new connections reach new backends) and `probe_after`.
- `stats(p)`: open, idle and waiting now; dials, reuses, waits, total
  and longest wait, and timeouts.
- `close(p)` closes idle connections and fails waiters; leased ones close
  as they come back. Releasing a lease twice panics.

## API

### `struct Options`

### `fn options(max_open: int) -> Options`

Options with the defaults above for a pool of max_open connections.

### `gc struct Lease[T]`

One connection, on loan from acquire until release or discard.

### `struct Stats`

### `gc struct Pool[T]`

### `fn new[T](o: Options, dial: fn(until) -> result[T, str], close: fn(T), probe: fn(T) -> bool) -> Pool[T]`

A pool that opens nothing until the first acquire. dial makes a connection by a deadline, close ends one, probe says whether an idle one still works (one cheap check, such as net.idle_alive).

### `fn acquire[T](p: Pool[T], deadline: until) -> result[Lease[T], str]`

A connection for the caller's use until release or discard: an idle one, a new one if fewer than max_open are open, or else the next one released, in arrival order. "timeout" if deadline passes first, "pool is closed" after close.

### `fn release[T](p: Pool[T], l: Lease[T])`

Gives a connection back: to the task that has waited longest, else to the idle list. Closed instead once past max_lifetime, beyond max_idle, or after close. Releasing a lease twice panics: two tasks would then share one connection.

### `fn discard[T](p: Pool[T], l: Lease[T])`

Closes a connection the caller found broken, freeing its slot for the next waiter to dial.

### `fn close[T](p: Pool[T])`

Closes every idle connection and fails every waiting acquire; connections in use are closed as they come back. acquire fails from now on.

### `fn stats[T](p: Pool[T]) -> Stats`

A snapshot of the counters.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
