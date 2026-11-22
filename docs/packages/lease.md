# lease

> Package lease.

Leases and leader election: one process at a time holds a named lease,
for running a scheduled job once across replicas, or for electing one
leader.

```slang
import "lease";

let e = lease.elector("jobs:nightly-report", 10000);   // a 10 s lease
// every ~3 seconds:
if lease.elect(e, redis_conn, deadline) ?? false {
    // leading: pass lease.fence(e) with the writes made, so storage can
    // refuse a stale leader's late ones
}
```

- **Redis:** `redis_acquire(conn, name, ttl_ms, deadline)` is
  `SET name token NX PX ttl`. `redis_renew` and `redis_release` are
  scripts that check the token first, so a process can never renew or
  release a lease it lost. Each acquisition takes a fencing token
  (`INCR name:fence`) that only grows: a leader that stalled past its
  lease and wakes up still believing it leads carries an older fence
  than the real leader, and storage that checks fences refuses it. A
  lease is safe to act on while `remaining_ms(l) > 0`.
- **Leader election:** `elector(name, ttl_ms)`, `elect` (renew while
  leading, try to acquire otherwise), `leading`, `fence` and `resign`,
  which hands over at once instead of after the ttl.
- **Postgres:** `pg_try_lock` and `pg_unlock` are session advisory
  locks on `key_of(name)`. They are held while the connection lives, so
  use a connection of its own, never a pooled one.

## API

### `struct Lease`

### `fn remaining_ms(l: Lease) -> int`

Milliseconds the lease is certainly still held for, by this process's clock (0 once it may have run out).

### `fn redis_acquire(c: redis.Conn, name: str, ttl_ms: int, deadline: until) -> result[opt[Lease], str]`

Takes the lease name for ttl_ms if nobody holds it: some(lease), or none while another process does.

### `fn redis_renew(c: redis.Conn, l: Lease, ttl_ms: int, deadline: until) -> result[bool, str]`

Extends a held lease to ttl_ms from now: false if it was lost (it ran out and someone else took it, or it was released).

### `fn redis_release(c: redis.Conn, l: Lease, deadline: until) -> result[bool, str]`

Gives the lease up: false if it was no longer ours.

### `gc struct Elector`

### `fn elector(name: str, ttl_ms: int) -> Elector`

### `fn elect(e: Elector, c: redis.Conn, deadline: until) -> result[bool, str]`

One round: renew the lease if this process leads, try to take it if not. Call every third of the ttl or so. Whether this process leads now; on an error it does not.

### `fn leading(e: Elector) -> bool`

Whether this process led at its last round and the lease has not run out since.

### `fn fence(e: Elector) -> int`

The fencing token of the current lease (0 when not leading).

### `fn resign(e: Elector, c: redis.Conn, deadline: until)`

Stops leading and releases the lease, so another process can take over at once instead of after the ttl.

### `fn key_of(name: str) -> int`

A stable 63-bit lock key for a name (FNV-1a), for the advisory locks.

### `fn pg_try_lock(c: pg.Conn, name: str, deadline: until) -> result[bool, str]`

Takes the session advisory lock for name without waiting: false while another session holds it.

### `fn pg_unlock(c: pg.Conn, name: str, deadline: until) -> result[bool, str]`

Releases it: false if this session did not hold it.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
