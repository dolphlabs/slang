# outbox

> Package outbox.

Two patterns for doing a thing exactly once in effect.

**Idempotency keys** (the `Idempotency-Key` header): a retried request
with the same key gets the first one's response instead of running
twice.

```slang
import "idempotency";

let br = idempotency.begin(redis_conn, key, request_fingerprint, 30000, deadline);
guard let b = br else { return unavailable(); }
if b.state == idempotency.DONE { return replay(b.response); }
if b.state == idempotency.IN_PROGRESS { return conflict(); }          // 409
if b.state == idempotency.MISMATCH { return unprocessable(); }        // 422
let resp = handle();                                                  // NEW: run it
idempotency.complete(redis_conn, key, b, resp, 86400000, deadline);   // keep a day
```

The reservation is one atomic `SET NX`, so two copies of a request
arriving together cannot both run. It expires after `lock_ms` if the
process dies, so the key does not stay stuck. `complete` and `abandon`
act only on the caller's own reservation, and the fingerprint catches a
key reused for a different request.

**The transactional outbox:** write an event in the same Postgres
transaction as the change it describes, and let a relay publish it.
The event goes out if and only if the change commits.

```slang
import "outbox";

pg.exec(conn, outbox.schema(), deadline);                  // in a migration
// inside the business transaction:
outbox.add(conn, "orders.created", payload, deadline);
// in a relay task, in a loop (publish is fn(outbox.Message) -> bool):
let n = outbox.relay(conn, 100, publish_to_kafka, deadline);
```

`relay` claims a batch with `FOR UPDATE SKIP LOCKED`, so several relays
can share the table. Published rows are deleted, and failed ones are
retried after 2, 4, 8, ... seconds (at most an hour). Delivery is at
least once, so consumers should be idempotent too.

## API

### `fn schema() -> str`

### `fn add(c: pg.Conn, topic: str, payload: bytes, deadline: until) -> result[int, str]`

Queues an event; call it inside the transaction that makes the change. Returns the event's id.

### `struct Message`

### `fn relay(c: pg.Conn, batch: int, publish: fn(Message) -> bool, deadline: until) -> result[int, str]`

Publishes up to batch ready events with publish (true: it went out), deleting those that did and pushing back those that did not (by 2^attempts seconds, at most an hour). Returns how many were published. Uses its own transaction: call it on a connection that is not in one.

### `fn pending(c: pg.Conn, deadline: until) -> result[int, str]`

Events waiting, ready or not.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
