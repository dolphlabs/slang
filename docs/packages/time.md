# time

> Package time.

```slang
import "time";

let t0 = time.mono();     // monotonic clock; a `duration` (int64 ns)
time.sleep(20000000);     // sleep for a duration (ns)
let elapsed = time.mono() - t0;   // duration arithmetic
let deadline = time.mono() + 5000000;  // timeout math for net calls

let wall = time.wall();   // unix epoch time in nanoseconds
let d = time.http_date(); // "Tue, 13 Oct 2026 09:30:15 GMT", the current second
```

`time.put_http_date(w, off)` writes the same 29 bytes into a `wire` and
returns `off + 29` (with a zero-length wire it only counts): what `http`
uses for `Date`. For dates other than now, use `timez`.

## API

### `time.mono() -> duration`

### `time.wall() -> int`

### `time.sleep(int)`

### `time.http_date() -> str`

### `time.put_http_date(wire, int) -> int`

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
