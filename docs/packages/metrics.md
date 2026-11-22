# metrics

> Package metrics.

Prometheus metrics: counters, gauges and histograms with labels, and the
text exposition format a Prometheus server scrapes.

```slang
import "metrics";

let reg = metrics.registry();
let reqs = metrics.counter(reg, "http_requests_total", "Requests served.",
                           ["method", "code"]);
let lat = metrics.histogram(reg, "http_request_duration_seconds",
                            "Request latency.", ["route"],
                            metrics.default_buckets());

metrics.inc(metrics.with(reqs, ["GET", "200"]));
let users = metrics.with(lat, ["/users"]);   // keep it: no lookup per update
metrics.observe(users, 0.012);

// GET /metrics: answer metrics.expose(reg), Content-Type metrics.CONTENT_TYPE
```

- `counter` (`inc`, `add`; a decrease panics), `gauge` (`set`, `add`,
  `inc`, `dec`) and `histogram` (`observe`) register a family by name;
  `with(family, label_values)` gives a series. Keeping the series makes
  an update one lock, with no label lookup. `remove` drops a series whose
  label value will not come back, so memory does not grow without bound.
- Histograms are classic fixed-bucket ones, which Prometheus scrapes:
  a few ints a series and a binary search per observation.
  `default_buckets()` are Prometheus's latency buckets in seconds;
  `exponential_buckets(start, factor, count)` makes others.
- `expose(reg)` sorts families and series, so two scrapes of an idle
  program are identical. Names and label names are checked at
  registration, and label values and help text are escaped.

## API

### `let CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8";`

### `gc struct Series`

### `gc struct Family`

### `gc struct Registry`

### `fn registry() -> Registry`

### `fn default_buckets() -> [float]`

Prometheus's default latency buckets, in seconds.

### `fn exponential_buckets(start: float, factor: float, count: int) -> [float]`

count bounds from start, each factor times the last.

### `fn counter(r: Registry, name: str, help: str, labels: [str]) -> Family`

A counter family: a value that only goes up (inc, add).

### `fn gauge(r: Registry, name: str, help: str, labels: [str]) -> Family`

A gauge family: a value that goes up and down (set, add, inc, dec).

### `fn histogram(r: Registry, name: str, help: str, labels: [str], bounds: [float]) -> Family`

A histogram family with these upper bounds (ascending; +Inf is added).

### `fn with(f: Family, values: [str]) -> Series`

The series for these label values (one per label name, in order), made on first use. Keep it to skip this lookup on every update.

### `fn remove(f: Family, values: [str])`

Drops a series (a label value that will not come back, such as a finished job's id), so a family's memory does not grow without bound.

### `fn inc(s: Series)`

### `fn add(s: Series, v: float)`

Adds v. A counter panics on a negative v: counters only go up, and a decrease reads as a reset to every rate() over it.

### `fn dec(s: Series)`

### `fn set(s: Series, v: float)`

### `fn observe(s: Series, v: float)`

Records one value into a histogram.

### `fn value(s: Series) -> float`

A counter's or gauge's value now.

### `fn expose(r: Registry) -> str`

Every family in the text exposition format, families by name and series by labels, so two scrapes of an idle program are identical.

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
