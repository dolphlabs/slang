# Concurrency

> M:N green threads, channels, select and mutex.

## Concurrency

`spawn` submits a function as an `sl_task` on the M:N worker pool
(sized `ncpu`); `chan[T]` is a bounded, park-aware queue.
Blocking-looking code stays blocking-looking — `net.accept`,
`net.recv`, `time.sleep`, `io.read_line`, and `chan_send`/`chan_recv` park the task
and return the OS thread to the pool. There is no colored-function
split. TLS handshake and I/O park on the same reactor as TCP
  (`SSL_ERROR_WANT_READ`/`WANT_WRITE`). DNS (`getaddrinfo`) runs on
  a dedicated thread; the dialing task parks until it finishes.

```slang
fn worker(id: i32, results: chan[i32]) {
    chan_send(results, (id * 10) as i32);
}

let results: chan[i32] = make_chan(3);
spawn worker(1, results);
spawn worker(2, results);
spawn worker(3, results);

let mut_sum = 0;
for i in 0..3 {
    let v = chan_recv(results);       // blocks until a value or close
    guard let x = v else {
        println("channel closed early");
        exit(1);
    }
    mut_sum = mut_sum + x;
}
println(mut_sum); // 60

chan_close(results);
chan_recv(results) ?? -1;  // none after close+drain -> -1
```

- **`spawn f(args...);`** evaluates every argument in the spawning
  context (no closures — nothing is captured implicitly) and submits
  `f` as a growable-stack task on the striped run queues (16 hashed
  stripes with work-stealing, plus a global doorbell for sleepers).
  `f` may be a plain top-level function, an `extern fn`, or a
  **function value** (`spawn w(1, out);`, `spawn job.run(x);`) — not a
  method and not a builtin. There is no `spawn` on `net.*`/`time.*`
  calls directly; wrap the native call in a plain function and spawn
  that instead.
  As a statement, the result is discarded. As an expression,
  `let h = spawn f(...)` has type `join[T]` when `f` returns `T`.
  `join_wait(h) -> result[T, str]` parks until `f` finishes; a panic
  in that task is `err`, not process death.
- **`chan[T]`**, built with `make_chan(capacity)` (element type
  inferred from an annotated binding, same as `none`): `chan_send(ch,
  v)` blocks while full, `chan_recv(ch) -> opt[T]` blocks while empty
  and returns `none` once the channel is closed and drained (instead
  of inventing a second return-value convention, it reuses `opt[T]`),
  `chan_close(ch)` wakes every blocked sender/receiver. Sending on a
  closed channel is a checked runtime error, not undefined behavior.
- **`select`** waits on several channels at once and runs the arm that
  becomes ready first:

  ```slang
  while running {
      select {
          case let job = chan_recv(work) {
              handle(job ?? 0);
          }
          case let q = chan_recv(quit) {
              running = false;
          }
          default {
              // optional: runs when no arm is ready, instead of blocking
          }
      }
  }
  ```

  A `case let v = chan_recv(ch)` arm binds `v` to `opt[T]` for that
  arm's body, exactly as a plain `chan_recv` would — `none` means the
  channel is closed and drained. A `case chan_send(ch, v)` arm is ready
  when the channel has buffer space and binds nothing. Sending on a
  closed channel from a send arm is the same checked runtime error as
  `chan_send` itself.

  Every arm's channel expression (and a send arm's value) is evaluated
  **once**, before the select blocks. With no `default` and nothing ever
  ready, `select` parks forever — the same as `chan_recv` on a channel
  nobody sends to. Which arm wins when several are ready is not
  specified: polling starts at a rotating offset, so a busy first
  channel cannot starve the later arms.

  **A closed channel is permanently ready.** Its recv arm fires
  immediately and forever, with `none`. This is the same as Go, but Go
  lets you disable an arm by setting its channel to `nil` and slang has
  no nil channel — so a loop that keeps selecting on a closed channel
  will spin. Structure the loop to stop instead (count the items you
  expect, or take the close as the exit condition), as
  `tests/select/main.sl` does.

- **`mutex`**, built with `make_mutex()`: `mutex_lock(m)` /
  `mutex_unlock(m)` around whatever the lock protects, and
  `mutex_trylock(m) -> bool` when you would rather do something else
  than wait. A contended lock parks the *task*, not the worker thread,
  so a handler waiting its turn costs a queue slot rather than one of
  the pool's OS threads — the same reason `chan` parks. A `mutex` is a
  handle: copying the binding aliases the same lock.

  Two things are checked rather than left to chance, because both
  otherwise present as something other than what they are:

  - Locking a mutex this task already holds is a runtime error.
    slang's mutexes are **not** recursive, and without the check the
    task would park forever on itself — a hang is the least useful
    diagnosis available.
  - Unlocking a mutex this task does not hold is a runtime error. The
    alternative is corruption in whatever the lock was protecting,
    discovered much later and somewhere else.

  There is no scope guard (no `defer`, no closures), so an early
  `return` between lock and unlock leaks the lock. Keep the critical
  section small enough to see both ends of it at once:

  ```slang
  gc struct State { tasks: [Task], next_id: int, lock: mutex }

  fn create(st: State, title: str) -> Task {
      mutex_lock(st.lock);
      let t = Task { id: st.next_id, title: title, done: false };
      st.next_id = st.next_id + 1;
      push(st.tasks, t);
      mutex_unlock(st.lock);
      return t;                 // unlock BEFORE the return, every path
  }
  ```

  A mutex is not always the right tool. `demo/samplex/server.sl` uses
  one because many handlers touch one list. `stdlib/http2/conn.sl`
  deliberately does not: its single writer task also guarantees that a
  HEADERS block and its CONTINUATION frames are never split by another
  frame, which a lock would not give.
- **Failure isolation**: a runtime error (an out-of-bounds index, a
  missing map key, integer division by zero, ...) inside a spawned
  task ends *that task* — printed to stderr as `task panicked: ...` —
  not the whole process. The same error in the main task still ends
  the process, same as today; there is no isolation boundary around
  top-level code. `exit(code)` always ends the whole process
  regardless of which task calls it — it means what it always means.

**What this does not give you.** There is no ownership/borrow checker
here — slang's answer to "many tasks, no data races" is thread
isolation plus channels for the values that need to move between
tasks, not a type system that forbids sharing mutable state. Passing
a struct, list, or map into a spawned task and mutating it from more
than one task concurrently is exactly as unsafe as it is in Go or
Java: nothing currently stops you, so don't — `mutex` is there when
you need it. `join_wait` waits for one spawned task.
`proc.active_tasks()` (see the `proc` section) is the aggregate count
of everything currently in flight,
useful for draining on shutdown but not for waiting on one task in
particular.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
