# singleflight

> Package singleflight.

Concurrent identical calls share one execution: while a call for a key
is running, more calls for that key wait for its answer instead of
running again. It is the cure for a cache stampede, where a popular key
expires and a thousand requests reach the database at once.

```slang
import "singleflight";

fn load_user(id: str, deadline: until) -> result[User, str] { ... }

let users = singleflight.group(load_user);     // one group per loader
let r = singleflight.call(users, "user:" + id, id, deadline);
```

The first caller for a key runs the function; the others get its result
or its error. A call that panics answers every waiter with an error.
Waiters wait for the running call, which ends at the first caller's
deadline, not theirs. `forget(g, key)` makes the next call run anew, and
`runs`/`joins` count calls that ran and calls that shared.

## API

### `gc struct Flight[T]`

### `gc struct Group[A, T]`

### `fn group[A, T](f: fn(A, until) -> result[T, str]) -> Group[A, T]`

A group whose calls run f.

### `fn call[A, T](g: Group[A, T], key: str, a: A, deadline: until) -> result[T, str]`

g's function on a, once per key at a time; concurrent calls for the key share its result.

### `fn forget[A, T](g: Group[A, T], key: str)`

Makes the next call for key run anew, even while one is in flight (those already waiting still get the running call's answer).

### `fn runs[A, T](g: Group[A, T]) -> int`

Calls that ran f, and calls that shared another's run.

### `fn joins[A, T](g: Group[A, T]) -> int`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
