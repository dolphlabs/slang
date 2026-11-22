# context

> Package context.

Cancellation and deadlines that flow from a request through everything
it starts, so one timeout or one cancel stops all the work under it.

```slang
import "context";
import "net";

let req = context.with_timeout(context.background(), 2000000000);  // 2 s
let db = context.with_cancel(req);          // ends when req ends
context.watch_fd(db, fd);                   // a cancel closes fd
let rr = net.recv_until(fd, 4096, context.deadline(db));
context.cancel(req, "client went away");    // ends req and db
println(context.cause(db) ?? "live");       // "client went away"
context.release(db);
```

- `background()` is the root. `with_cancel(parent)`,
  `with_timeout(parent, ns)` and `with_deadline_at(parent, mono_ns)` make
  children; a child's deadline is the earlier of its own and its
  parent's, and cancelling a context cancels everything made from it.
- `deadline(c)` is an `until` for any API that waits; `remaining(c)` is
  the nanoseconds left (-1 without a deadline), for a timeout another
  protocol carries.
- `cancel(c, reason)` (the first reason wins) and `release(c)`, for a
  context whose work is done. Call one of them, as with Go's contexts:
  until then a child stays in its parent's list.
- `is_done(c)` and `cause(c)`: the cancel reason, `"deadline exceeded"`,
  or `none` while live.
- `watch_fd(c, fd)` closes `fd` on cancel, waking a task parked on it
  with `"closed"`; `unwatch_fd` before closing it yourself. `done_chan(c)`
  is closed on cancel, for a `select`.

There are no timers: a deadline passing does not close watched fds. The
operations given `deadline(c)` end at it on their own.

## API

### `gc struct Context`

### `fn background() -> Context`

The root: no deadline, never cancelled unless cancel is called on it.

### `fn with_cancel(parent: Context) -> Context`

A child of parent that can be cancelled on its own.

### `fn with_timeout(parent: Context, ns: int) -> Context`

A child of parent that ends ns nanoseconds from now (or at the parent's deadline, if that is sooner). ns <= 0 is already past.

### `fn with_deadline_at(parent: Context, mono_ns: int) -> Context`

A child of parent that ends at mono_ns, an absolute time.mono() value.

### `fn cancel(c: Context, reason: str)`

Cancels c and every context made from it, with reason as cause's text. The first cancel wins; later ones do nothing.

### `fn release(c: Context)`

Cancel with the reason "released": for a context whose work finished.

### `fn is_done(c: Context) -> bool`

Whether c was cancelled or its deadline has passed.

### `fn cause(c: Context) -> opt[str]`

Why c is done: the cancel reason, or "deadline exceeded"; none while it is live.

### `fn deadline(c: Context) -> until`

c's deadline as an `until` for any API that waits: never for a context without one, already passed for a cancelled one.

### `fn remaining(c: Context) -> int`

Nanoseconds until c's deadline (0 once passed or cancelled), or -1 for a context without one: for a timeout another protocol carries, such as a database statement timeout.

### `fn watch_fd(c: Context, fd: i32)`

Closes fd when c is cancelled, waking any task parked on it with "closed". If c is already cancelled, closes it now. Call unwatch_fd before closing fd yourself, so a later cancel cannot close a reused fd number.

### `fn unwatch_fd(c: Context, fd: i32) -> bool`

Stops watching fd. Returns false if c had already been cancelled (and fd closed by it).

### `fn done_chan(c: Context) -> chan[bool]`

A channel that is closed when c is cancelled, for a `select` that should also end on cancellation. Nothing is ever sent on it.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
