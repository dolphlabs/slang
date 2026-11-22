# balance

> Package balance.

Client-side load balancing: pick a backend per request, spread load,
steer away from slow backends and stop sending to failing ones.

```slang
import "balance";
import "time";

let lb = balance.new(["10.0.0.1:8080", "10.0.0.2:8080"], balance.P2C);
let pr = balance.pick(lb, "");
guard let p = pr else { return err("no backend up"); }
let t0 = time.mono();
let r = call(p.addr);
let worked = false;
if let _v = r { worked = true; }
balance.done(lb, p, worked, (time.mono() - t0) as int);
```

| Strategy | Picks |
|---|---|
| `ROUND_ROBIN` | each backend in turn |
| `RANDOM` | uniformly at random |
| `LEAST` | the fewest requests in flight |
| `P2C` | two at random, the one with fewer in flight, then the lower latency (an EWMA): nearly `LEAST`'s spread without herding every client onto one backend |
| `HASH` | the backend a key maps to (rendezvous hashing via `math/shard`), and the key's next backend while that one is ejected |

A backend that fails `eject_after` times in a row (5) is ejected for
`eject_ns` (10 s), doubling for each ejection in a row up to
`eject_max_ns` (5 minutes); a success resets it. `set_backends` replaces
the list from service discovery and keeps the state of backends that
stay. `status` reports each backend.

## API

### `let ROUND_ROBIN = 0;`

### `let RANDOM = 1;`

### `let LEAST = 2;`

### `let P2C = 3;`

### `let HASH = 4;`

### `struct Options`

### `fn options(strategy: int) -> Options`

### `gc struct Backend`

### `struct Pick`

### `gc struct Balancer`

### `fn new(addrs: [str], strategy: int) -> Balancer`

### `fn with_options(addrs: [str], o: Options) -> Balancer`

### `fn set_backends(lb: Balancer, addrs: [str])`

Replaces the backend list (from service discovery, say). Backends that stay keep their state.

### `fn pick(lb: Balancer, key: str) -> result[Pick, str]`

A backend for one request (key is used by HASH only). Report how it went with done. An error when every backend is ejected.

### `fn done(lb: Balancer, p: Pick, ok: bool, latency_ns: int)`

Reports a pick's outcome and how long it took.

### `struct Status`

### `fn status(lb: Balancer) -> [Status]`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
